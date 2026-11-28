local M = MailItemLogAddon

local SHARE_CHUNK = 72
local SHARE_LIMIT = 36000
local SHARE_PREFIX = "MIL02"
local SHARE_PATTERN = "^" .. SHARE_PREFIX .. " ([ARNLUDE]) (%d+) (.+)$"
local incoming, transfer, notice, lastPrompt
local requestCounter = 0
M.sharedStatus = ""

local function sendPacket(target, kind, id, payload)
    SendChatMessage(SHARE_PREFIX .. " " .. kind .. " " .. id .. " " .. (payload or "-"), "WHISPER", nil, target)
end

function M.onlineFriends()
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
    for _, friend in ipairs(M.onlineFriends()) do
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
    M.prune(time())
    local snapshot = M.db.inboxes[M.characterKey]
    if not snapshot then
        sendPacket(request.name, "U", request.id)
        return
    end

    local records = { tostring(snapshot.timestamp), "\n" }
    local now = time()
    for _, item in ipairs(snapshot.items) do
        if not item.expires or item.expires > now then
            local line = string.format("%s|%d|%s|%d",
                encode(item.name), item.count, encode(item.sender), math.floor(item.expires or 0))
            if request.itemAppearance then
                line = line .. "|" .. (item.icon or "") .. "|" .. tostring(item.quality or -1)
            end
            if request.itemLinks and item.itemString then
                line = line .. "|" .. item.itemString
            end
            table.insert(records, line .. "\n")
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
                M.db.approvalPosition = {
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
        M.label(notice, "GameFontNormal", 12, -9):SetText("Mail Item Log")
        notice.message = M.label(notice, "GameFontHighlightSmall", 12, -26)
        notice.message:SetWidth(196)
        notice.approve = M.button(notice, "Approve", 86, 22, 12, 0, function() reply(true) end)
        notice.decline = M.button(notice, "Decline", 86, 22, 103, 0, function() reply(false) end)
        notice.approve:ClearAllPoints()
        notice.approve:SetPoint("TOPLEFT", notice.message, "BOTTOMLEFT", 0, -7)
        notice.decline:ClearAllPoints()
        notice.decline:SetPoint("LEFT", notice.approve, "RIGHT", 5, 0)
    end
    notice.message:SetText(incoming.name .. " requests your inbox item list.")
    local position = M.db.approvalPosition or { x = -32, y = 64 }
    notice:ClearAllPoints()
    notice:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", position.x, position.y)
    notice:Show()
    local messageHeight = math.max(12, notice.message:GetHeight() or 0)
    notice:SetHeight(26 + messageHeight + 7 + 22 + 9)
end

local function finishRequest(message)
    M.shareOutgoing = nil
    M.sharedStatus = message
    M.redraw()
end

local function parseSnapshot(data, sender)
    local _, headerEnd, timestamp = string.find(data, "^(%d+)\n")
    timestamp = tonumber(timestamp)
    if not timestamp or timestamp <= time() - M.RETENTION then return end

    local records = {}
    local cursor = headerEnd + 1
    while cursor <= string.len(data) do
        local first, last, name, count, from, expires, icon, quality, itemString =
            string.find(data, "([^|\n]*)|(%d+)|([^|\n]*)|(%d+)|([%w_%-]*)|(-?%d+)|(item:[%d:%-]+)\n", cursor)
        if first ~= cursor then
            first, last, name, count, from, expires, icon, quality =
                string.find(data, "([^|\n]*)|(%d+)|([^|\n]*)|(%d+)|([%w_%-]*)|(-?%d+)\n", cursor)
            itemString = nil
            if first ~= cursor then
                first, last, name, count, from, expires =
                    string.find(data, "([^|\n]*)|(%d+)|([^|\n]*)|(%d+)\n", cursor)
                if first ~= cursor then return end
                icon, quality = nil, nil
            end
        end
        quality = tonumber(quality)
        expires = tonumber(expires)
        local itemName = decode(name)
        local senderName = decode(from)
        if itemName == "" or string.find(itemName, "[%c|]") or string.find(senderName, "[%c|]") then return end
        table.insert(records, {
            name = itemName, count = tonumber(count), sender = senderName,
            icon = icon and icon ~= "" and icon or nil,
            quality = quality and quality >= 0 and quality <= 8 and quality or nil,
            itemString = M.itemString(itemString),
            expires = expires > 0 and expires or nil,
        })
        cursor = last + 1
    end
    return { name = sender, timestamp = timestamp, items = records }
end

function M.receivePacket(message, author)
    if not author or string.len(message) > 240 then return end
    local _, _, kind, id, payload = string.find(message, SHARE_PATTERN)
    if not kind then return end
    local now = GetTime()
    if kind == "R" then
        if not incoming and not transfer and isOnlineFriend(author) and
            (not lastPrompt or now >= lastPrompt + 8) then
            lastPrompt = now
            incoming = { name = author, id = id, deadline = now + 45, itemAppearance = payload == "I" }
            showApproval()
        end
        return
    end
    if kind == "A" then
        if payload == "I" and incoming and incoming.itemAppearance and incoming.id == id
            and string.lower(author) == string.lower(incoming.name) then
            incoming.itemLinks = true
            return
        end
        if transfer and id == transfer.id and string.lower(author) == string.lower(transfer.name)
            and transfer.offset <= string.len(transfer.data) and transfer.attempts > 0
            and tonumber(payload) == transfer.sequence then
            transfer.offset = transfer.offset + SHARE_CHUNK
            transfer.attempts = 0
            transfer.nextAt = math.max(now, transfer.sentAt + 1.25)
        end
        return
    end
    if not M.shareOutgoing or id ~= M.shareOutgoing.id or now >= M.shareOutgoing.deadline or
        string.lower(author) ~= string.lower(M.shareOutgoing.name) then return end
    if kind == "D" then
        local _, _, sequence, chunk = string.find(payload, "^(%d+):(%x+)$")
        sequence = tonumber(sequence)
        local received = table.getn(M.shareOutgoing.chunks)
        if sequence and sequence >= 1 and sequence <= received and M.shareOutgoing.chunks[sequence] == chunk then
            M.shareOutgoing.deadline = now + 20
            sendPacket(author, "A", id, sequence)
            return
        end
        if sequence ~= received + 1 or not chunk or math.mod(string.len(chunk), 2) ~= 0 or
            M.shareOutgoing.size + string.len(chunk) > 2 * SHARE_LIMIT then
            finishRequest("Incomplete inbox response.")
            return
        end
        M.shareOutgoing.size = M.shareOutgoing.size + string.len(chunk)
        table.insert(M.shareOutgoing.chunks, chunk)
        M.shareOutgoing.deadline = now + 20
        sendPacket(author, "A", id, sequence)
        if table.getn(M.shareOutgoing.chunks) == 1 then
            M.sharedStatus = "Receiving inbox from " .. author .. "..."
            M.redraw()
        end
    elseif kind == "E" then
        if tonumber(payload) == table.getn(M.shareOutgoing.chunks) and table.getn(M.shareOutgoing.chunks) > 0 then
            local bytes = string.gsub(table.concat(M.shareOutgoing.chunks), "(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            M.sharedSnapshot = parseSnapshot(bytes, author)
        end
        finishRequest(M.sharedSnapshot and "" or "Invalid or incomplete inbox response.")
    elseif kind == "N" then
        finishRequest(author .. " declined the request.")
    elseif kind == "U" then
        finishRequest(author .. " has no saved inbox. Ask them to open a mailbox.")
    elseif kind == "L" then
        finishRequest("The inbox response exceeded the transfer limit.")
    end
end

function M.pumpSharing()
    if not incoming and not M.shareOutgoing and not transfer then return end
    local now = GetTime()
    if incoming and now >= incoming.deadline then
        incoming = nil
        notice:Hide()
    end
    if M.shareOutgoing and now >= M.shareOutgoing.deadline then
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
        local target = M.shareTarget
        if not target or M.shareOutgoing or not isOnlineFriend(target) then return end
        requestCounter = requestCounter + 1
        local id = string.format("%d%05d", time(), math.mod(requestCounter, 100000))
        M.shareOutgoing = { name = target, id = id, deadline = GetTime() + 60, chunks = {}, size = 0 }
        M.sharedSnapshot = nil
        M.page = 1
        M.sharedStatus = "Waiting for " .. target .. " to approve..."
        -- Legacy recipients already understand the appearance request and ignore a nonnumeric ACK.
        sendPacket(target, "R", id, "I")
        sendPacket(target, "A", id, "I")
        M.redraw()
    end,
}

function M.initializeSharing()
    local originalChatEvent = ChatFrame_OnEvent
    if not originalChatEvent then return end
    ChatFrame_OnEvent = function(chatEvent)
        if (chatEvent == "CHAT_MSG_WHISPER" or chatEvent == "CHAT_MSG_WHISPER_INFORM") and
            arg1 and string.find(arg1, SHARE_PATTERN) then return end
        return originalChatEvent(chatEvent)
    end
end
M.sharedColumns = {
    { "name", "Item", 217 },
    { "count", "Qty", 45 },
    { "sender", "From", 101 },
    { "recipient", "To", 101 },
    { "expires", "Expires", 142 },
}

local friendOffset = 0

function M.buildSharedControls(frame)
    frame.friends = CreateFrame("Frame", nil, frame)
    frame.friends:SetWidth(158)
    frame.friends:SetHeight(303)
    frame.friends:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -170)
    frame.friends:EnableMouseWheel(true)
    frame.friends:SetScript("OnMouseWheel", function()
        friendOffset = friendOffset - arg1
        M.redraw()
    end)
    M.label(frame.friends, "GameFontNormal", 4, -4):SetText("Online friends")
    frame.friends.rows = {}
    for index = 1, 11 do
        local entry = M.button(frame.friends, "", 149, 22, 0, -23 - (index - 1) * 23, nil)
        entry:SetScript("OnClick", function()
            if M.shareOutgoing or not entry.friend then return end
            M.shareTarget = entry.friend
            StaticPopup_Show("MAILITEMLOG_REQUEST", M.shareTarget)
        end)
        entry:EnableMouseWheel(true)
        entry:SetScript("OnMouseWheel", frame.friends:GetScript("OnMouseWheel"))
        frame.friends.rows[index] = entry
    end
    frame.friends.up = M.button(frame.friends, "Up", 71, 22, 0, -279, function()
        friendOffset = friendOffset - 1
        M.redraw()
    end)
    frame.friends.down = M.button(frame.friends, "Down", 71, 22, 78, -279, function()
        friendOffset = friendOffset + 1
        M.redraw()
    end)
end

function M.getSharedTabItems(window, now)
    local items, status, inboxRecipient
    items = {}
    status = M.sharedStatus ~= "" and M.sharedStatus or "Choose an online friend to request their inbox."
    if M.sharedSnapshot and M.sharedSnapshot.timestamp > now - M.RETENTION then
        window.sharedOwner:SetText("Displaying " .. M.sharedSnapshot.name .. "'s Inbox")
        status = "Last checked " .. M.stamp(M.sharedSnapshot.timestamp)
        items = M.sharedSnapshot.items
        if table.getn(items) == 0 then status = status .. " | No items in the saved inbox." end
        inboxRecipient = M.sharedSnapshot.name
    elseif M.sharedSnapshot then
        M.sharedSnapshot = nil
    end
    local names = M.onlineFriends()
    local maximum = math.max(0, table.getn(names) - table.getn(window.friends.rows))
    friendOffset = math.min(maximum, math.max(0, friendOffset))
    for index, entry in ipairs(window.friends.rows) do
        entry.friend = names[friendOffset + index]
        if entry.friend then
            entry:SetText(entry.friend)
            M.enable(entry, not M.shareOutgoing)
            entry:Show()
        else
            entry:Hide()
        end
    end
    M.enable(window.friends.up, friendOffset > 0)
    M.enable(window.friends.down, friendOffset < maximum)
    return items, status, inboxRecipient
end
