local RETENTION = 30 * 24 * 60 * 60
local PAGE_SIZE = 12
local SHARE_CHUNK = 72
local SHARE_LIMIT = 36000
local SHARE_PREFIX = "MIL02"
local SHARE_PATTERN = "^" .. SHARE_PREFIX .. " ([ARNLUDE]) (%d+) (.+)$"
local events = CreateFrame("Frame", "MailItemLogEvents")
local db, characterKey, characterName, realm
local mailboxOpen, pending
local view, page, inboxKey = "sent", 1, nil
local tabState = {
    sent = { sort = "timestamp", ascending = false, filters = {} },
    inbox = { sort = "name", ascending = true, filters = {} },
    shared = { sort = "name", ascending = true, filters = {} },
    rts = { sort = "timestamp", ascending = false, filters = {} },
}
local openingTabs = {
    { "last", "Last used tab" },
    { "sent", "Sent Items" },
    { "inbox", "Inbox Items" },
    { "shared", "Shared Inbox" },
    { "rts", "RTS" },
}
local filterFields = {
    { "name", "Item" },
    { "sender", "From" },
    { "recipient", "To" },
}
local window, redraw, toggleWindow
local incoming, outgoing, transfer, notice, shared, lastPrompt
local requestTarget, requestCounter = nil, 0
local sharedStatus = ""
local friendOffset = 0

local function pruneHistory(sent, cutoff)
    local nextIndex = 1
    local count = table.getn(sent)
    for index = 1, count do
        if sent[index].timestamp > cutoff then
            sent[nextIndex] = sent[index]
            nextIndex = nextIndex + 1
        end
    end
    for index = count, nextIndex, -1 do
        sent[index] = nil
    end
end

local function prune(now)
    local cutoff = now - RETENTION
    pruneHistory(db.sent, cutoff)
    pruneHistory(db.rtsHistory, cutoff)
    for key, sentAt in pairs(db.sentRTS) do
        if sentAt <= cutoff then db.sentRTS[key] = nil end
    end
    for key, snapshot in pairs(db.inboxes) do
        if snapshot.timestamp <= cutoff then
            db.inboxes[key] = nil
        end
    end
end

local function inboxItem(index)
    local name, textureOrID, count, qualityOrCount = GetInboxItem(index)
    if type(textureOrID) == "number" and type(count) ~= "number" then
        count = qualityOrCount
    end
    return name, count
end

local function updateInbox()
    local now = time()
    local items = {}
    for index = 1, GetInboxNumItems() do
        local _, _, sender, _, _, _, daysLeft = GetInboxHeaderInfo(index)
        local name, count = inboxItem(index)
        if name and type(count) == "number" and count > 0 then
            table.insert(items, {
                name = name,
                count = count,
                sender = sender or "?",
                expires = daysLeft and daysLeft > 0 and math.floor(now + daysLeft * 86400) or nil,
            })
        end
    end
    db.inboxes[characterKey] = {
        timestamp = now,
        items = items,
    }
end

local function button(parent, label, width, height, x, y, action)
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetWidth(width)
    control:SetHeight(height)
    control:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    control:SetText(label)
    control:SetScript("OnClick", action)
    return control
end

local function label(parent, template, x, y)
    local font = parent:CreateFontString(nil, "OVERLAY", template)
    font:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    font:SetJustifyH("LEFT")
    return font
end

local function sendPacket(target, kind, id, payload)
    SendChatMessage(SHARE_PREFIX .. " " .. kind .. " " .. id .. " " .. (payload or "-"), "WHISPER", nil, target)
end

local function onlineFriends()
    local names = {}
    for index = 1, GetNumFriends() do
        local name, _, _, _, connected = GetFriendInfo(index)
        if name and connected and connected ~= 0 then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

local function isOnlineFriend(name)
    for _, friend in ipairs(onlineFriends()) do
        if string.lower(friend) == string.lower(name) then return true end
    end
end

local function encode(value)
    return (string.gsub(value, "([^%w ._%-])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

local function decode(value)
    return (string.gsub(value, "%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function reply(accepted)
    local request = incoming
    incoming = nil
    notice:Hide()
    if not request or request.deadline <= GetTime() then return end
    if not accepted then
        sendPacket(request.name, "N", request.id)
        return
    end
    prune(time())
    local snapshot = db.inboxes[characterKey]
    if not snapshot then
        sendPacket(request.name, "U", request.id)
        return
    end

    local records = { tostring(snapshot.timestamp), "\n" }
    local now = time()
    for _, item in ipairs(snapshot.items) do
        if not item.expires or item.expires > now then
            table.insert(records, string.format("%s|%d|%s|%d\n",
                encode(item.name), item.count, encode(item.sender), math.floor(item.expires or 0)))
        end
    end
    local data = table.concat(records)
    if string.len(data) > SHARE_LIMIT then
        sendPacket(request.name, "L", request.id)
        return
    end
    transfer = { name = request.name, id = request.id, data = data, offset = 1, nextAt = GetTime(), attempts = 0 }
end

local function showApproval()
    if not notice then
        notice = CreateFrame("Frame", "MailItemLogApproval", UIParent)
        notice:SetWidth(220)
        notice:SetFrameStrata("MEDIUM")
        notice:SetMovable(true)
        notice:EnableMouse(true)
        notice:RegisterForDrag("LeftButton")
        if notice.SetClampedToScreen then notice:SetClampedToScreen(true) end
        notice:SetScript("OnDragStart", function()
            notice.dragging = true
            notice:StartMoving()
        end)
        local function finishDrag()
            if not notice.dragging then return end
            notice.dragging = nil
            notice:StopMovingOrSizing()
            local right, bottom = notice:GetRight(), notice:GetBottom()
            if right and bottom then
                db.approvalPosition = {
                    x = right - UIParent:GetRight(),
                    y = bottom - UIParent:GetBottom(),
                }
            end
        end
        notice:SetScript("OnDragStop", finishDrag)
        notice:SetScript("OnHide", finishDrag)
        notice:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        notice:SetBackdropColor(0.06, 0.06, 0.08, 0.90)
        label(notice, "GameFontNormal", 12, -9):SetText("Mail Item Log")
        notice.message = label(notice, "GameFontHighlightSmall", 12, -26)
        notice.message:SetWidth(196)
        notice.approve = button(notice, "Approve", 86, 22, 12, 0, function() reply(true) end)
        notice.decline = button(notice, "Decline", 86, 22, 103, 0, function() reply(false) end)
        notice.approve:ClearAllPoints()
        notice.approve:SetPoint("TOPLEFT", notice.message, "BOTTOMLEFT", 0, -7)
        notice.decline:ClearAllPoints()
        notice.decline:SetPoint("LEFT", notice.approve, "RIGHT", 5, 0)
    end
    notice.message:SetText(incoming.name .. " requests your inbox item list.")
    local position = db.approvalPosition or { x = -32, y = 64 }
    notice:ClearAllPoints()
    notice:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", position.x, position.y)
    notice:Show()
    local messageHeight = math.max(12, notice.message:GetHeight() or 0)
    notice:SetHeight(26 + messageHeight + 7 + 22 + 9)
end

local function finishRequest(message)
    outgoing = nil
    sharedStatus = message
    redraw()
end

local function parseSnapshot(data, sender)
    local _, headerEnd, timestamp = string.find(data, "^(%d+)\n")
    timestamp = tonumber(timestamp)
    if not timestamp or timestamp <= time() - RETENTION then return end

    local records = {}
    local cursor = headerEnd + 1
    while cursor <= string.len(data) do
        local first, last, name, count, from, expires =
            string.find(data, "([^|\n]*)|(%d+)|([^|\n]*)|(%d+)\n", cursor)
        if first ~= cursor then return end
        expires = tonumber(expires)
        local itemName = decode(name)
        local senderName = decode(from)
        if itemName == "" or string.find(itemName, "[%c|]") or string.find(senderName, "[%c|]") then return end
        table.insert(records, {
            name = itemName, count = tonumber(count), sender = senderName,
            expires = expires > 0 and expires or nil,
        })
        cursor = last + 1
    end
    return { name = sender, timestamp = timestamp, items = records }
end

local function receivePacket(message, author)
    if not author or string.len(message) > 240 then return end
    local _, _, kind, id, payload = string.find(message, SHARE_PATTERN)
    if not kind then return end
    local now = GetTime()
    if kind == "R" then
        if not incoming and not transfer and isOnlineFriend(author) and
            (not lastPrompt or now >= lastPrompt + 8) then
            lastPrompt = now
            incoming = { name = author, id = id, deadline = now + 45 }
            showApproval()
        end
        return
    end
    if kind == "A" then
        if transfer and id == transfer.id and string.lower(author) == string.lower(transfer.name)
            and transfer.offset <= string.len(transfer.data) and transfer.attempts > 0
            and tonumber(payload) == transfer.sequence then
            transfer.offset = transfer.offset + SHARE_CHUNK
            transfer.attempts = 0
            transfer.nextAt = math.max(now, transfer.sentAt + 1.25)
        end
        return
    end
    if not outgoing or id ~= outgoing.id or now >= outgoing.deadline or
        string.lower(author) ~= string.lower(outgoing.name) then return end
    if kind == "D" then
        local _, _, sequence, chunk = string.find(payload, "^(%d+):(%x+)$")
        sequence = tonumber(sequence)
        local received = table.getn(outgoing.chunks)
        if sequence and sequence >= 1 and sequence <= received and outgoing.chunks[sequence] == chunk then
            outgoing.deadline = now + 20
            sendPacket(author, "A", id, sequence)
            return
        end
        if sequence ~= received + 1 or not chunk or math.mod(string.len(chunk), 2) ~= 0 or
            outgoing.size + string.len(chunk) > 2 * SHARE_LIMIT then
            finishRequest("Incomplete inbox response.")
            return
        end
        outgoing.size = outgoing.size + string.len(chunk)
        table.insert(outgoing.chunks, chunk)
        outgoing.deadline = now + 20
        sendPacket(author, "A", id, sequence)
        if table.getn(outgoing.chunks) == 1 then
            sharedStatus = "Receiving inbox from " .. author .. "..."
            redraw()
        end
    elseif kind == "E" then
        if tonumber(payload) == table.getn(outgoing.chunks) and table.getn(outgoing.chunks) > 0 then
            local bytes = string.gsub(table.concat(outgoing.chunks), "(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            shared = parseSnapshot(bytes, author)
        end
        finishRequest(shared and "" or "Invalid or incomplete inbox response.")
    elseif kind == "N" then
        finishRequest(author .. " declined the request.")
    elseif kind == "U" then
        finishRequest(author .. " has no saved inbox. Ask them to open a mailbox.")
    elseif kind == "L" then
        finishRequest("The inbox response exceeded the transfer limit.")
    end
end

local function pumpSharing()
    local now = GetTime()
    if incoming and now >= incoming.deadline then
        incoming = nil
        notice:Hide()
    end
    if outgoing and now >= outgoing.deadline then
        finishRequest("Request timed out.")
    end
    if not transfer or now < transfer.nextAt then return end

    local offset = transfer.offset
    local sequence = math.floor((offset - 1) / SHARE_CHUNK) + 1
    local chunk = string.sub(transfer.data, offset, offset + SHARE_CHUNK - 1)
    if transfer.attempts >= 4 then
        transfer = nil
    elseif chunk == "" then
        sendPacket(transfer.name, "E", transfer.id, sequence - 1)
        if transfer.attempts == 0 then
            transfer.attempts = 1
            transfer.nextAt = now + 2
        else
            transfer = nil
        end
    else
        local hex = string.gsub(chunk, "(.)", function(byte)
            return string.format("%02X", string.byte(byte))
        end)
        transfer.sequence = sequence
        transfer.attempts = transfer.attempts + 1
        transfer.sentAt = now
        transfer.nextAt = now + 4
        sendPacket(transfer.name, "D", transfer.id, sequence .. ":" .. hex)
    end
end

StaticPopupDialogs["MAILITEMLOG_REQUEST"] = {
    text = "Send Request?\nRequest the inbox item list from %s.",
    button1 = "Yes",
    button2 = "No",
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    OnAccept = function()
        local target = requestTarget
        if not target or outgoing or not isOnlineFriend(target) then return end
        requestCounter = requestCounter + 1
        local id = string.format("%d%05d", time(), math.mod(requestCounter, 100000))
        outgoing = { name = target, id = id, deadline = GetTime() + 60, chunks = {}, size = 0 }
        shared = nil
        page = 1
        sharedStatus = "Waiting for " .. target .. " to approve..."
        sendPacket(target, "R", id)
        redraw()
    end,
}

local function addMinimapIcon()
    local icon = CreateFrame("Button", "MailItemLogMinimapButton", Minimap)
    icon:SetWidth(31)
    icon:SetHeight(31)
    icon:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    icon:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local art = icon:CreateTexture(nil, "BACKGROUND")
    art:SetWidth(19)
    art:SetHeight(19)
    art:SetPoint("CENTER", icon, "CENTER", -1, 0)
    art:SetTexture("Interface\\Icons\\INV_Letter_15")
    local border = icon:CreateTexture(nil, "OVERLAY")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    local function position()
        local angle = db.minimapAngle or 225
        icon:ClearAllPoints()
        icon:SetPoint("CENTER", Minimap, "CENTER", 78 * cos(angle), 78 * sin(angle))
    end
    icon:RegisterForClicks("LeftButtonUp")
    icon:RegisterForDrag("LeftButton")
    icon:SetScript("OnClick", function() toggleWindow() end)
    icon:SetScript("OnDragStart", function()
        icon:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local centerX, centerY = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            if centerX and centerY then
                db.minimapAngle = atan2(y / scale - centerY, x / scale - centerX)
                position()
            end
        end)
    end)
    icon:SetScript("OnDragStop", function() icon:SetScript("OnUpdate", nil) end)
    icon:SetScript("OnEnter", function()
        GameTooltip:SetOwner(icon, "ANCHOR_LEFT")
        GameTooltip:SetText("Mail Item Log")
        GameTooltip:AddLine("Click to open. Drag to move.", 1, 1, 1)
        GameTooltip:Show()
    end)
    icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
    position()
end

local sentColumns = {
    { "timestamp", "Sent at", 146 },
    { "name", "Item", 270 },
    { "count", "Qty", 55 },
    { "sender", "From", 151 },
    { "recipient", "To", 151 },
}
local inboxColumns = {
    { "name", "Item", 275 },
    { "count", "Qty", 52 },
    { "sender", "From", 140 },
    { "recipient", "To", 140 },
    { "expires", "Expires", 166 },
}

local sharedColumns = {
    { "name", "Item", 217 },
    { "count", "Qty", 45 },
    { "sender", "From", 101 },
    { "recipient", "To", 101 },
    { "expires", "Expires", 142 },
}

local rtsColumns = {
    { "timestamp", "Sent at", 137 },
    { "subject", "Subject", 155 },
    { "name", "Item", 211 },
    { "count", "Qty", 45 },
    { "recipient", "To", 120 },
    { "returnedAt", "Status", 121 },
}

local function inboxKeys()
    local keys = {}
    for key in pairs(db.inboxes) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

local function stamp(timestamp)
    return timestamp and date("%Y-%m-%d %H:%M", timestamp) or "-"
end

local columnsByTab = { sent = sentColumns, inbox = inboxColumns, shared = sharedColumns, rts = rtsColumns }

local function visibleItems(items, inboxRecipient, now)
    local state = tabState[view]
    local entries = {}
    for index, item in ipairs(items) do
        local recipient = inboxRecipient or item.recipient
        local matches = not item.expires or item.expires > now
        for _, filter in ipairs(filterFields) do
            local field = filter[1]
            local query = state.filters[field]
            local value = field == "recipient" and recipient or item[field]
            if query and not string.find(string.lower(value or ""), string.lower(query), 1, true) then
                matches = false
                break
            end
        end
        if matches then
            local value = state.sort == "recipient" and recipient or item[state.sort]
            if state.sort == "returnedAt" then value = value or 0 end
            if type(value) == "string" then value = string.lower(value) end
            table.insert(entries, { item = item, recipient = recipient, index = index, value = value })
        end
    end

    table.sort(entries, function(left, right)
        local a, b = left.value, right.value
        if a == b then
            if view == "sent" or view == "rts" then return left.index > right.index end
            return left.index < right.index
        end
        if a == nil then return false end
        if b == nil then return true end
        if state.ascending then return a < b end
        return a > b
    end)
    return entries
end

local rts = {}

local function isRTSSubject(subject)
    return subject and string.sub(subject, 1, 3) == "RTS"
end

local function rtsMailKey(otherPlayer, subject, itemName, count, money)
    -- Length prefixes keep subjects and item names unambiguous even with punctuation.
    local fields = { characterKey, string.lower(otherPlayer), subject, itemName or "",
        tostring(count or 0), tostring(money or 0) }
    for index, field in ipairs(fields) do
        fields[index] = string.len(field) .. ":" .. field
    end
    return table.concat(fields)
end

local function importRTSHistory()
    local history = {}
    for key, timestamp in pairs(db.sentRTS) do
        local fields, cursor = {}, 1
        for index = 1, 6 do
            local first, last, size = string.find(key, "(%d+):", cursor)
            if first ~= cursor then break end
            cursor = last + 1
            size = tonumber(size)
            if cursor + size - 1 > string.len(key) then break end
            fields[index] = string.sub(key, cursor, cursor + size - 1)
            cursor = cursor + size
        end
        if fields[6] and cursor == string.len(key) + 1 then
            local _, _, sender = string.find(fields[1], "^(.-) %- ")
            table.insert(history, {
                key = key, owner = fields[1], sender = sender, recipient = fields[2],
                subject = fields[3], name = fields[4] ~= "" and fields[4] or nil,
                count = tonumber(fields[5]), money = tonumber(fields[6]), timestamp = timestamp,
            })
        end
    end
    table.sort(history, function(a, b) return a.timestamp < b.timestamp end)
    return history
end

local function updateRTSReturns()
    local seen = {}
    for index = 1, GetInboxNumItems() do
        local _, _, sender, subject, money, cod, _, hasItem = GetInboxHeaderInfo(index)
        if isRTSSubject(subject) and (not cod or cod == 0) then
            if not sender or sender == "" then return end
            local name, quantity
            if hasItem and hasItem ~= 0 then
                name, quantity = inboxItem(index)
                if not name or not quantity or quantity == 0 then return end
            end
            local key = rtsMailKey(sender, subject, name, quantity, money)
            if db.sentRTS[key] then seen[key] = (seen[key] or 0) + 1 end
        end
    end
    local previous = db.rtsInboxSeen[characterKey] or {}
    local now = time()
    for key, count in pairs(seen) do
        local added = count - (previous[key] or 0)
        if added > 0 then
            for _, item in ipairs(db.rtsHistory) do
                if item.key == key and not item.returnedAt and item.timestamp > now - RETENTION then
                    item.returnedAt = now
                    added = added - 1
                    if added == 0 then break end
                end
            end
        end
    end
    db.rtsInboxSeen[characterKey] = seen
end

local function findRTSMail()
    local first, count = nil, 0
    for index = 1, GetInboxNumItems() do
        local _, _, sender, subject, money, cod, _, hasItem, _, returned, _, _, gm =
            GetInboxHeaderInfo(index)
        local canDelete = InboxItemCanDelete(index)
        local attached = hasItem and hasItem ~= 0
        if isRTSSubject(subject) and sender and sender ~= "" and (not returned or returned == 0)
            and (not gm or gm == 0) and (not canDelete or canDelete == 0)
            and (not cod or cod == 0) and (attached or (money and money > 0)) then
            local name, quantity
            if attached then name, quantity = inboxItem(index) end
            if not attached or (name and type(quantity) == "number" and quantity > 0) then
                local key = rtsMailKey(sender, subject, name, quantity, money)
                local sentAt = db.sentRTS[key]
                if not sentAt or sentAt <= time() - RETENTION then
                    first = first or index
                    count = count + 1
                end
            end
        end
    end
    return first, count
end

local function startRTSReturn(manual)
    if not mailboxOpen or rts.returning or pending then return end
    rts.returning = { manual = manual, nextAt = GetTime(), done = 0 }
end

local function stopRTSReturn(message)
    if rts.returning.manual and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("Mail Item Log: " .. message)
    end
    rts.returning = nil
end

local function pumpRTS()
    local now = GetTime()
    local returning = rts.returning
    if not returning or pending then return end
    if returning.waitUntil and now >= returning.waitUntil then
        rts.autoBlocked = true
        stopRTSReturn("Return stopped. The server did not confirm the last mail.")
    elseif not returning.waitUntil and now >= returning.nextAt then
        local index, count = findRTSMail()
        if index then
            returning.count = count
            returning.waitUntil = now + 12
            ReturnInboxItem(index)
        else
            stopRTSReturn(string.format("Returned %d RTS mail(s).", returning.done))
        end
    end
end

local function selectTab(tab)
    view, page = tab, 1
    db.lastTab = tab
    for _, field in ipairs(filterFields) do
        local key = field[1]
        local box = window.filterBoxes[key]
        box:ClearFocus()
        box:SetText(tabState[tab] and tabState[tab].filters[key] or "")
    end
    redraw()
end

local function buildWindow()
    local frame = CreateFrame("Frame", "MailItemLogWindow", UIParent)
    frame:SetWidth(825)
    frame:SetHeight(533)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:SetMovable(true)
    frame:EnableMouse(true)
    if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    frame:Hide()
    table.insert(UISpecialFrames, "MailItemLogWindow")

    label(frame, "GameFontNormalLarge", 21, -19):SetText("Mail Item Log")
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.sentTab = button(frame, "Sent Items", 110, 24, 16, -46, function()
        selectTab("sent")
    end)
    frame.inboxTab = button(frame, "Inbox Items", 110, 24, 129, -46, function()
        selectTab("inbox")
    end)
    frame.sharedTab = button(frame, "Shared Inbox", 110, 24, 242, -46, function()
        selectTab("shared")
        if ShowFriends then ShowFriends() end
    end)
    frame.rtsTab = button(frame, "RTS", 110, 24, 355, -46, function()
        selectTab("rts")
    end)
    frame.autoRTS = button(frame, "", 153, 22, 16, -138, function()
        db.autoReturnRTS = not db.autoReturnRTS
        if db.autoReturnRTS then
            rts.autoBlocked = nil
            if rts.inboxReady and findRTSMail() then startRTSReturn(false) end
        elseif rts.returning and not rts.returning.manual then
            if rts.returning.waitUntil then
                rts.returning.stopAfterCurrent = true
            else
                stopRTSReturn("Auto-return is off.")
            end
        end
        redraw()
    end)
    frame.logRTS = button(frame, "", 225, 22, 176, -138, function()
        db.logRTSInSent = not db.logRTSInSent
        redraw()
    end)
    local menu = CreateFrame("Frame", nil, frame)
    menu:SetWidth(170)
    menu:SetHeight(142)
    menu:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -17, -71)
    menu:SetFrameLevel(frame:GetFrameLevel() + 12)
    menu:EnableMouse(true)
    menu:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
    })
    menu:SetBackdropColor(0.06, 0.06, 0.08, 1)
    menu:Hide()
    frame:SetScript("OnHide", function() menu:Hide() end)
    local opener = button(frame, "", 170, 24, 638, -46, function()
        if menu:IsShown() then menu:Hide() else menu:Show() end
    end)
    for index, option in ipairs(openingTabs) do
        local key, title = option[1], option[2]
        button(menu, title, 152, 22, 9, -8 - (index - 1) * 26, function()
            db.openingTab = key
            opener:SetText("Open on: " .. title)
            menu:Hide()
        end)
        if db.openingTab == key then opener:SetText("Open on: " .. title) end
    end
    frame.friends = CreateFrame("Frame", nil, frame)
    frame.friends:SetWidth(158)
    frame.friends:SetHeight(303)
    frame.friends:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -170)
    frame.friends:EnableMouseWheel(true)
    frame.friends:SetScript("OnMouseWheel", function()
        friendOffset = friendOffset - arg1
        redraw()
    end)
    label(frame.friends, "GameFontNormal", 4, -4):SetText("Online friends")
    frame.friends.rows = {}
    for index = 1, 11 do
        local entry = button(frame.friends, "", 149, 22, 0, -23 - (index - 1) * 23, nil)
        entry:SetScript("OnClick", function()
            if outgoing or not entry.friend then return end
            requestTarget = entry.friend
            StaticPopup_Show("MAILITEMLOG_REQUEST", requestTarget)
        end)
        entry:EnableMouseWheel(true)
        entry:SetScript("OnMouseWheel", frame.friends:GetScript("OnMouseWheel"))
        frame.friends.rows[index] = entry
    end
    frame.friends.up = button(frame.friends, "Up", 71, 22, 0, -279, function()
        friendOffset = friendOffset - 1
        redraw()
    end)
    frame.friends.down = button(frame.friends, "Down", 71, 22, 78, -279, function()
        friendOffset = friendOffset + 1
        redraw()
    end)
    frame.chooseInbox = button(frame, "Next character", 119, 22, 639, -76, function()
        local keys = inboxKeys()
        for index, key in ipairs(keys) do
            if key == inboxKey then
                inboxKey = keys[index + 1] or keys[1]
                break
            end
        end
        page = 1
        redraw()
    end)
    frame.status = label(frame, "GameFontHighlightSmall", 21, -81)
    frame.sharedOwner = label(frame, "GameFontNormal", 183, -144)
    frame.filterBoxes = {}
    for index, filter in ipairs(filterFields) do
        local field = filter[1]
        local x = 21 + (index - 1) * 210
        label(frame, "GameFontNormalSmall", x, -115):SetText(filter[2])
        local box = CreateFrame("EditBox", "MailItemLogFilter" .. index, frame, "InputBoxTemplate")
        box:SetPoint("TOPLEFT", frame, "TOPLEFT", x + 44, -107)
        box:SetWidth(151)
        box:SetHeight(22)
        box:SetAutoFocus(false)
        box:SetMaxLetters(100)
        box:SetScript("OnTextChanged", function()
            local value = box:GetText() or ""
            if value == (tabState[view].filters[field] or "") then return end
            tabState[view].filters[field] = value ~= "" and value or nil
            page = 1
            redraw()
        end)
        box:SetScript("OnEnterPressed", function() box:ClearFocus() end)
        box:SetScript("OnEscapePressed", function() box:ClearFocus() end)
        frame.filterBoxes[field] = box
    end
    button(frame, "Clear filters", 97, 22, 660, -107, function()
        tabState[view].filters = {}
        selectTab(view)
    end)
    frame.headings = {}
    for index = 1, table.getn(rtsColumns) do
        local columnIndex = index
        frame.headings[index] = button(frame, "", 100, 23, 16, -170, function()
            local column = columnsByTab[view][columnIndex]
            if not column then return end
            local field = column[1]
            local state = tabState[view]
            if state.sort == field then
                state.ascending = not state.ascending
            else
                state.sort = field
                state.ascending = field ~= "timestamp" and field ~= "count"
            end
            page = 1
            redraw()
        end)
    end
    frame.rows = {}
    for index = 1, PAGE_SIZE do
        local row = frame:CreateTexture(nil, "BACKGROUND")
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -196 - (index - 1) * 23)
        row:SetWidth(773)
        row:SetHeight(23)
        row:SetTexture(1, 1, 1, 0.045 * (index - 2 * math.floor(index / 2)))
        local cells = {}
        for col = 1, table.getn(rtsColumns) do
            cells[col] = label(frame, "GameFontHighlight", 21, -201 - (index - 1) * 23)
            cells[col]:SetHeight(16)
        end
        frame.rows[index] = cells
    end
    frame.previous = button(frame, "Previous", 90, 23, 16, -487, function()
        page = page - 1
        redraw()
    end)
    frame.next = button(frame, "Next", 90, 23, 112, -487, function()
        page = page + 1
        redraw()
    end)
    frame.pageLabel = label(frame, "GameFontHighlight", 218, -493)
    return frame
end

local function enable(control, active)
    if active then control:Enable() else control:Disable() end
end

redraw = function()
    if not window or not window:IsShown() then return end

    local now = time()
    prune(now)
    local items, status, inboxRecipient
    local columns = columnsByTab[view]
    local state = tabState[view]
    enable(window.sentTab, view ~= "sent")
    enable(window.inboxTab, view ~= "inbox")
    enable(window.sharedTab, view ~= "shared")
    enable(window.rtsTab, view ~= "rts")
    if view == "rts" then
        window.autoRTS:SetText(db.autoReturnRTS and "Auto-return RTS: On" or "Auto-return RTS: Off")
        window.logRTS:SetText(db.logRTSInSent and "Record in Sent Items: On" or "Record in Sent Items: Off")
        window.autoRTS:Show()
        window.logRTS:Show()
    else
        window.autoRTS:Hide()
        window.logRTS:Hide()
    end
    if view == "shared" then
        window.friends:Show()
        window.sharedOwner:Show()
        window.sharedOwner:SetText("")
    else
        window.friends:Hide()
        window.sharedOwner:Hide()
    end
    if view == "sent" then
        items = db.sent
        status = "Successful sends | Last 30 days"
        window.chooseInbox:Hide()
    elseif view == "rts" then
        window.chooseInbox:Hide()
        items = {}
        for _, item in ipairs(db.rtsHistory) do
            if item.owner == characterKey then table.insert(items, item) end
        end
        status = "RTS sent by " .. characterName .. " | Last 30 days"
    elseif view == "shared" then
        window.chooseInbox:Hide()
        items = {}
        status = sharedStatus ~= "" and sharedStatus or "Choose an online friend to request their inbox."
        if shared and shared.timestamp > now - RETENTION then
            window.sharedOwner:SetText("Displaying " .. shared.name .. "'s Inbox")
            status = "Last checked " .. stamp(shared.timestamp)
            items = shared.items
            if table.getn(items) == 0 then status = status .. " | No items in the saved inbox." end
            inboxRecipient = shared.name
        elseif shared then
            shared = nil
        end
        local names = onlineFriends()
        local maximum = math.max(0, table.getn(names) - table.getn(window.friends.rows))
        friendOffset = math.min(maximum, math.max(0, friendOffset))
        for index, entry in ipairs(window.friends.rows) do
            entry.friend = names[friendOffset + index]
            if entry.friend then
                entry:SetText(entry.friend)
                enable(entry, not outgoing)
                entry:Show()
            else
                entry:Hide()
            end
        end
        enable(window.friends.up, friendOffset > 0)
        enable(window.friends.down, friendOffset < maximum)
    else
        local keys = inboxKeys()
        if not inboxKey or not db.inboxes[inboxKey] then
            inboxKey = db.inboxes[characterKey] and characterKey or keys[1]
        end
        local snapshot = inboxKey and db.inboxes[inboxKey]
        items = {}
        if snapshot then
            items = snapshot.items
            local separator = string.find(inboxKey, " - ", 1, true)
            inboxRecipient = separator and string.sub(inboxKey, 1, separator - 1) or inboxKey
            status = inboxKey .. " | Last checked " .. stamp(snapshot.timestamp)
        else
            status = "Open a mailbox to load its inbox."
        end
        if table.getn(keys) > 1 then window.chooseInbox:Show() else window.chooseInbox:Hide() end
    end

    local entries = visibleItems(items, inboxRecipient, now)
    local count = table.getn(entries)
    if view == "shared" and shared and table.getn(items) > 0 and count == 0 then
        status = status .. " | No items match the current filters or expiration."
    end
    local pages = math.max(1, math.ceil(count / PAGE_SIZE))
    page = math.min(pages, math.max(1, page))
    window.status:SetText(status)
    window.pageLabel:SetText(string.format("Page %d / %d  (%d items)", page, pages, count))
    enable(window.previous, page > 1)
    enable(window.next, page < pages)

    local x = view == "shared" and 183 or 16
    for index, heading in ipairs(window.headings) do
        local column = columns[index]
        if column then
            local title = column[2]
            if state.sort == column[1] then
                title = title .. (state.ascending and " +" or " -")
            end
            heading:ClearAllPoints()
            heading:SetPoint("TOPLEFT", window, "TOPLEFT", x, -170)
            heading:SetWidth(column[3])
            heading:SetText(title)
            heading:Show()
            for rowIndex, cells in ipairs(window.rows) do
                local cell = cells[index]
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", window, "TOPLEFT", x + 5, -201 - (rowIndex - 1) * 23)
                cell:SetWidth(column[3] - 10)
            end
            x = x + column[3]
        else
            heading:Hide()
        end
    end
    for index, cells in ipairs(window.rows) do
        local entry = entries[(page - 1) * PAGE_SIZE + index]
        for col, cell in ipairs(cells) do
            local column = columns[col]
            local value
            if entry and column then
                local field = column[1]
                value = field == "recipient" and entry.recipient or entry.item[field]
                if field == "timestamp" or field == "expires" then value = stamp(value) end
                if field == "returnedAt" then value = value and "Returned" or "Not seen yet" end
                if view == "rts" and field == "name" and not value and (entry.item.money or 0) > 0 then
                    value = entry.item.money .. " copper"
                end
            end
            cell:SetText(value and tostring(value) or "")
        end
    end
end

toggleWindow = function()
    if not db then return end
    if not window then window = buildWindow() end
    if window:IsShown() then
        window:Hide()
    else
        local tab = db.openingTab == "last" and db.lastTab or db.openingTab
        window:Show()
        if view ~= tab then
            selectTab(tab)
        else
            db.lastTab = tab
            redraw()
        end
        if tab == "shared" and ShowFriends then ShowFriends() end
    end
end

local function installSendHook()
    local originalSendMail = SendMail
    SendMail = function(recipient, subject, body)
        if mailboxOpen and not pending and recipient and recipient ~= "" and subject and subject ~= "" then
            local name, _, count = GetSendMailItem()
            local hasAttachment = name and type(count) == "number" and count > 0
            local money = isRTSSubject(subject) and GetSendMailMoney() or 0
            if hasAttachment or isRTSSubject(subject) then
                pending = {
                    name = hasAttachment and name or nil,
                    count = hasAttachment and count or nil,
                    sender = characterName,
                    recipient = recipient,
                }
                if isRTSSubject(subject) then
                    local _, _, trimmed = string.find(recipient, "^%s*(.-)%s*$")
                    pending.rtsKey = rtsMailKey(trimmed or recipient, subject, pending.name, pending.count, money)
                    pending.rtsSubject = subject
                    pending.rtsMoney = money
                end
            end
        end
        return originalSendMail(recipient, subject, body)
    end
end

events:RegisterEvent("FRIENDLIST_UPDATE")
events:RegisterEvent("CHAT_MSG_WHISPER")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("MAIL_SHOW")
events:RegisterEvent("MAIL_CLOSED")
events:RegisterEvent("MAIL_INBOX_UPDATE")
events:RegisterEvent("MAIL_SEND_SUCCESS")
events:RegisterEvent("MAIL_FAILED")
events:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        MailItemLogDB = MailItemLogDB or {}
        db = MailItemLogDB
        if not tabState[db.openingTab] then db.openingTab = "last" end
        if not tabState[db.lastTab] then db.lastTab = "sent" end
        if db.autoReturnRTS == nil then db.autoReturnRTS = true end
        if InboxFrame then
            local returnButton = button(InboxFrame, "Return RTS", 104, 23, 0, 0, function()
                startRTSReturn(true)
            end)
            returnButton:ClearAllPoints()
            returnButton:SetPoint("TOPLEFT", MailFrame or InboxFrame, "TOPLEFT", 69, -35)
        end
        db.sent = db.sent or {}
        db.sentRTS = db.sentRTS or {}
        db.rtsHistory = db.rtsHistory or importRTSHistory()
        db.rtsInboxSeen = db.rtsInboxSeen or {}
        if db.logRTSInSent == nil then db.logRTSInSent = true end
        db.inboxes = db.inboxes or {}
        characterName = UnitName("player")
        realm = GetRealmName()
        characterKey = characterName .. " - " .. realm
        prune(time())
        installSendHook()
        addMinimapIcon()
        local originalChatEvent = ChatFrame_OnEvent
        if originalChatEvent then
            ChatFrame_OnEvent = function(chatEvent)
                if (chatEvent == "CHAT_MSG_WHISPER" or chatEvent == "CHAT_MSG_WHISPER_INFORM") and
                    arg1 and string.find(arg1, SHARE_PATTERN) then return end
                return originalChatEvent(chatEvent)
            end
        end
    elseif db then
        if event == "CHAT_MSG_WHISPER" then
            if arg1 then receivePacket(arg1, arg2) end
        elseif event == "FRIENDLIST_UPDATE" then
            if view == "shared" then redraw() end
        elseif event == "MAIL_SHOW" then
            mailboxOpen = true
            pending = nil
            rts.inboxReady, rts.autoBlocked = nil, nil
            redraw()
        elseif event == "MAIL_CLOSED" then
            mailboxOpen = false
            rts.inboxReady, rts.returning = nil, nil
            redraw()
        elseif event == "MAIL_INBOX_UPDATE" and mailboxOpen then
            updateInbox()
            updateRTSReturns()
            rts.inboxReady = true
            local returning = rts.returning
            if returning and returning.waitUntil then
                local _, count = findRTSMail()
                if count < returning.count then
                    returning.done = returning.done + 1
                    if returning.stopAfterCurrent then
                        stopRTSReturn("Auto-return is off.")
                    else
                        returning.waitUntil = nil
                        returning.nextAt = GetTime() + 0.4
                    end
                end
            elseif db.autoReturnRTS and not rts.autoBlocked and not returning and findRTSMail() then
                startRTSReturn(false)
            end
            redraw()
        elseif event == "MAIL_SEND_SUCCESS" then
            if pending then
                pending.timestamp = time()
                if pending.rtsKey then
                    db.sentRTS[pending.rtsKey] = pending.timestamp
                    table.insert(db.rtsHistory, {
                        key = pending.rtsKey, owner = characterKey, sender = characterName,
                        recipient = pending.recipient, subject = pending.rtsSubject,
                        name = pending.name, count = pending.count, money = pending.rtsMoney,
                        timestamp = pending.timestamp,
                    })
                end
                if pending.name and (not pending.rtsKey or db.logRTSInSent) then
                    table.insert(db.sent, {
                        timestamp = pending.timestamp, name = pending.name, count = pending.count,
                        sender = pending.sender, recipient = pending.recipient,
                    })
                end
                pending = nil
                prune(time())
            end
            redraw()
        elseif event == "MAIL_FAILED" then
            pending = nil
            if rts.returning and rts.returning.waitUntil then
                rts.autoBlocked = true
                stopRTSReturn("Return stopped. The server rejected the last mail.")
            end
        elseif event == "PLAYER_LOGOUT" then
            prune(time())
        end
    end
end)

local elapsed = 0
events:SetScript("OnUpdate", function()
    if not db then return end
    elapsed = elapsed + arg1
    if incoming or outgoing or transfer then pumpSharing() end
    if rts.returning then pumpRTS() end
    if elapsed >= 60 then
        elapsed = 0
        prune(time())
        redraw()
    end
end)

SLASH_MAILITEMLOG1 = "/maillog"
SlashCmdList["MAILITEMLOG"] = toggleWindow
