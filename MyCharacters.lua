local M = MailItemLogAddon

local FILE_NAME = "MailItemLog_Characters"
local BAG_SLOTS_PER_FRAME = 12
local HISTORY_LIMIT = 200
local records, selected, mode = {}, nil, "Bags"
local characterOffset = 0
local scan, scanAt, saveAt, pending, fileError
local supported

M.characterColumns = {
    { "name", "Item", 220 },
    { "count", "Qty", 65 },
    { "delta", "Change", 80 },
    { "sender", "From", 120 },
    { "timestamp", "Recorded", 130 },
}

local function escape(value)
    if value == nil then return "" end
    return (string.gsub(tostring(value), "[%%|%c]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

local function fields(line)
    local parts, cursor = {}, 1
    while true do
        local first = string.find(line, "|", cursor, true)
        local value = string.sub(line, cursor, first and first - 1 or -1)
        table.insert(parts, (string.gsub(value, "%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)))
        if not first then return parts end
        cursor = first + 1
    end
end

local function key(realm, name)
    return realm .. "\n" .. name
end

local function readRecords()
    local ok, data = pcall(ImportFile, FILE_NAME)
    if not ok then return nil end
    if not data or data == "" then return {} end
    if string.sub(data, 1, 5) ~= "MIL1\n" or string.sub(data, -4) ~= "END\n" then return nil end
    local result, record = {}, nil
    local cursor = 6
    while cursor <= string.len(data) - 4 do
        local first, last, line = string.find(data, "([^\n]+)\n", cursor)
        if first ~= cursor then return nil end
        cursor = last + 1
        local f = fields(line)
        if f[1] == "C" and f[10] then
            local realm, name = f[2], f[3]
            record = {
                realm = realm, name = name, class = f[4], level = tonumber(f[5]),
                gold = tonumber(f[6]), bagAt = tonumber(f[7]), inboxAt = tonumber(f[8]),
                mailCount = tonumber(f[9]), mailTotal = tonumber(f[10]), bags = {}, inbox = {}, changes = {},
            }
            result[key(realm, name)] = record
        elseif record and (f[1] == "B" or f[1] == "I" or f[1] == "D") and f[9] and tonumber(f[4]) then
            local row = {
                name = f[3], count = tonumber(f[4]), icon = f[5] ~= "" and f[5] or nil,
                quality = tonumber(f[6]), sender = f[7] ~= "" and f[7] or nil,
                timestamp = tonumber(f[8]), delta = tonumber(f[9]),
                itemString = M.itemString(f[10]) or (f[1] == "B" and M.itemString(f[2]) or nil),
            }
            if f[1] == "B" then record.bags[f[2]] = row
            elseif f[1] == "I" then table.insert(record.inbox, row)
            else table.insert(record.changes, row) end
        else
            return nil
        end
    end
    return result
end

local function writeRecords(all)
    local lines = { "MIL1" }
    local function line(values)
        for index, value in ipairs(values) do values[index] = escape(value) end
        table.insert(lines, table.concat(values, "|"))
    end
    local function row(kind, id, item)
        line({kind, id, item.name, item.count, item.icon or "", item.quality or "",
            item.sender or "", item.timestamp or "", item.delta or "", item.itemString or ""})
    end
    for _, record in pairs(all) do
        line({"C", record.realm, record.name, record.class, record.level or "", record.gold or "",
            record.bagAt or "", record.inboxAt or "", record.mailCount or "", record.mailTotal or ""})
        for id, item in pairs(record.bags) do row("B", id, item) end
        for _, item in ipairs(record.inbox) do row("I", "", item) end
        for _, item in ipairs(record.changes) do row("D", "", item) end
    end
    table.insert(lines, "END\n")
    return pcall(ExportFile, FILE_NAME, table.concat(lines, "\n"))
end

local function inCombat()
    if UnitAffectingCombat then
        local active = UnitAffectingCombat("player")
        return active and active ~= 0
    end
    return M.characterCombat
end

function M.reloadCharacters()
    if not supported then return end
    local latest = readRecords()
    fileError = not latest
    if latest then records = latest end
end

local function queue(snapshot, field)
    pending = pending or {}
    pending[field] = snapshot
    saveAt = GetTime() + 0.35
end

function M.recordCharacterInbox(job)
    if not supported then return end
    queue({
        timestamp = job.timestamp, items = job.items, count = job.total,
        total = job.mailTotal, gold = GetMoney(),
    }, "inbox")
end

local function recordChanges(record, bag)
    local changed = not record.bagAt
    if record.bagAt then
        local function add(item, delta)
            changed = true
            table.insert(record.changes, {
                name = item.name, count = item.count, icon = item.icon,
                quality = item.quality, timestamp = bag.timestamp, delta = delta, itemString = item.itemString,
            })
        end
        for id, item in pairs(bag.items) do
            local previous = record.bags[id] and record.bags[id].count or 0
            if item.count ~= previous then add(item, item.count - previous) end
        end
        for id, item in pairs(record.bags) do
            if not bag.items[id] then
                add({name = item.name, count = 0, icon = item.icon, quality = item.quality, itemString = item.itemString}, -item.count)
            end
        end
        if record.gold and bag.gold ~= record.gold then
            add({name = "Money (copper)", count = bag.gold}, bag.gold - record.gold)
        end
    end
    if table.getn(record.changes) > HISTORY_LIMIT then
        local recent = {}
        for index = table.getn(record.changes) - HISTORY_LIMIT + 1, table.getn(record.changes) do
            table.insert(recent, record.changes[index])
        end
        record.changes = recent
    end
    if changed then record.bags, record.bagAt, record.gold = bag.items, bag.timestamp, bag.gold end
    return changed
end

local function savePending()
    local latest = readRecords()
    if not latest then fileError = true return end
    local realm, name = GetRealmName(), UnitName("player")
    local id = key(realm, name)
    local class, level = UnitClass("player"), UnitLevel("player")
    local record = latest[id] or { realm = realm, name = name, bags = {}, inbox = {}, changes = {} }
    local changed = record.class ~= class or record.level ~= level
    record.class, record.level = class or "", level
    if pending.bag then changed = recordChanges(record, pending.bag) or changed end
    if pending.inbox then
        record.inbox, record.inboxAt = pending.inbox.items, pending.inbox.timestamp
        record.mailCount, record.mailTotal = pending.inbox.count, pending.inbox.total
        if not record.bagAt then record.gold = pending.inbox.gold end
    end
    latest[id] = record
    if (not changed and not pending.inbox) or writeRecords(latest) then
        records, pending, fileError = latest, nil, nil
    else
        fileError = true
    end
end

local function noteBagOpened()
    if inCombat() then return end
    if not scan and not scanAt then scanAt = GetTime() + 0.10 end
end

function M.initializeCharacters()
    supported = type(ImportFile) == "function" and type(ExportFile) == "function"
    if not supported then return end
    M.reloadCharacters()
    local original = ContainerFrame_GenerateFrame
    if type(original) == "function" then
        ContainerFrame_GenerateFrame = function(frame, size, id)
            local result = original(frame, size, id)
            if type(id) == "number" and id >= 0 and id <= 4 then noteBagOpened() end
            return result
        end
    elseif type(OpenBag) == "function" then
        local open = OpenBag
        OpenBag = function(id)
            local result = open(id)
            if type(id) == "number" and id >= 0 and id <= 4 then noteBagOpened() end
            return result
        end
    end
end

function M.characterBagChanged()
    if scan or scanAt then
        scan, scanAt = nil, nil
        noteBagOpened()
    end
end

function M.pumpCharacters(now)
    if not scanAt and not saveAt then return end
    if inCombat() then
        scanAt, scan = nil, nil
        return
    end
    if scanAt and now >= scanAt then
        scan = scan or { bag = 0, slot = 1, items = {} }
        local budget = BAG_SLOTS_PER_FRAME
        while scan.bag <= 4 and budget > 0 do
            if scan.slot > (GetContainerNumSlots(scan.bag) or 0) then
                scan.bag, scan.slot = scan.bag + 1, 1
            else
                local link = GetContainerItemLink(scan.bag, scan.slot)
                if link then
                    local _, _, id, name = string.find(link, "|H(item:[^|]+)|h%[(.-)%]")
                    local texture, count = GetContainerItemInfo(scan.bag, scan.slot)
                    id, name = id or link, name or link
                    local row = scan.items[id]
                    if not row then
                        local _, _, icon = M.itemDetails(name, texture, count)
                        row = {name = name, count = 0, icon = icon, itemString = M.itemString(link)}
                        scan.items[id] = row
                    end
                    row.count = row.count + (count or 1)
                end
                scan.slot, budget = scan.slot + 1, budget - 1
            end
        end
        if scan.bag > 4 then
            queue({ timestamp = time(), items = scan.items, gold = GetMoney() }, "bag")
            scanAt, scan = nil, nil
        end
    end
    if saveAt and now >= saveAt and not M.inboxScanPending and not M.rts.returning then
        saveAt = nil
        savePending()
        if M.view == "characters" then M.redraw() end
    end
end

local function characterKeys()
    local keys, realm = {}, GetRealmName()
    for id, record in pairs(records) do
        if record.realm == realm then table.insert(keys, id) end
    end
    table.sort(keys)
    return keys
end

function M.buildCharacterControls(frame)
    local sidebar = CreateFrame("Frame", nil, frame)
    frame.characterList = sidebar
    sidebar:SetWidth(158)
    sidebar:SetHeight(303)
    sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -170)
    sidebar:EnableMouseWheel(true)
    local function scroll(delta)
        characterOffset = characterOffset + delta
        M.redraw()
    end
    local function wheel() scroll(-(tonumber(arg1) or 0)) end
    sidebar:SetScript("OnMouseWheel", wheel)
    M.label(sidebar, "GameFontNormal", 4, -4):SetText("Characters")
    sidebar.rows = {}
    for index = 1, 11 do
        local entry = M.button(sidebar, "", 149, 22, 0, -23 - (index - 1) * 23, nil)
        entry:SetScript("OnClick", function()
            if not entry.characterKey then return end
            selected = entry.characterKey
            M.page = 1
            M.redraw()
        end)
        entry:EnableMouseWheel(true)
        entry:SetScript("OnMouseWheel", wheel)
        sidebar.rows[index] = entry
    end
    sidebar.up = M.button(sidebar, "Up", 71, 22, 0, -279, function() scroll(-1) end)
    sidebar.down = M.button(sidebar, "Down", 71, 22, 78, -279, function() scroll(1) end)
    frame.characterMode = M.button(frame, "", 110, 22, 639, -76, function()
        mode = mode == "Bags" and "Inbox" or mode == "Inbox" and "Changes" or "Bags"
        M.page = 1
        M.redraw()
    end)
    frame.characterInfo = M.label(frame, "GameFontHighlightSmall", 183, -145)
end

function M.getCharacterTabItems(frame)
    local keys = characterKeys()
    local record = selected and records[selected]
    if not record or record.realm ~= GetRealmName() then
        local own = key(GetRealmName(), UnitName("player"))
        selected = records[own] and own or keys[1]
        record = selected and records[selected]
    end
    frame.characterMode:SetText(mode)
    local list = frame.characterList
    local maximum = math.max(0, table.getn(keys) - table.getn(list.rows))
    characterOffset = math.min(maximum, math.max(0, characterOffset))
    for index, entry in ipairs(list.rows) do
        local id = keys[characterOffset + index]
        entry.characterKey = id
        if id then
            entry:SetText(records[id].name)
            M.enable(entry, id ~= selected)
            entry:Show()
        else
            entry:Hide()
        end
    end
    M.enable(list.up, characterOffset > 0)
    M.enable(list.down, characterOffset < maximum)
    M.enable(frame.characterMode, record ~= nil)
    frame.characterInfo:SetText("")
    if not supported then return {}, "My Characters requires ImportFile and ExportFile." end
    if not record then
        return {}, fileError and "Could not read the shared character file." or "Open a bag or mailbox to record a character."
    end
    local status = record.name .. " | " .. record.class .. " | Level " .. tostring(record.level or "?")
    if record.gold then
        local gold = record.gold
        status = status .. string.format(" | %dg %ds %dc", math.floor(gold / 10000),
            math.mod(math.floor(gold / 100), 100), math.mod(gold, 100))
    end
    local rows, info = {}, ""
    if mode == "Bags" then
        for _, item in pairs(record.bags) do table.insert(rows, item) end
        info = record.bagAt and ("Bags recorded " .. M.stamp(record.bagAt)) or "Bags not recorded yet."
    elseif mode == "Inbox" then
        rows = record.inbox
        if record.inboxAt then
            local count = record.mailTotal or record.mailCount
            info = "Inbox recorded " .. M.stamp(record.inboxAt) .. " | " .. count .. " / 100 mails"
            if record.mailTotal and record.mailCount < record.mailTotal then
                info = info .. " (" .. record.mailCount .. " loaded)"
            end
        else
            info = "Inbox not recorded yet."
        end
    else
        rows, info = record.changes, "Bag and money changes since the first record"
    end
    if fileError then info = info .. " | Shared file read/write failed." end
    frame.characterInfo:SetText(info)
    return rows, status, record.name
end

M.characterModuleLoaded = true
