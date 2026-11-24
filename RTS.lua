local M = MailItemLogAddon

M.rtsColumns = {
    { "timestamp", "Sent at", 137 },
    { "subject", "Subject", 155 },
    { "name", "Item", 211 },
    { "count", "Qty", 45 },
    { "recipient", "To", 120 },
    { "returnedAt", "Status", 121 },
}

M.rts = {}

function M.isRTSSubject(subject)
    return subject and string.sub(subject, 1, 3) == "RTS"
end

function M.rtsMailKey(otherPlayer, subject, itemName, count, money)
    -- Length prefixes keep subjects and item names unambiguous even with punctuation.
    local fields = { M.characterKey, string.lower(otherPlayer), subject, itemName or "",
        tostring(count or 0), tostring(money or 0) }
    for index, field in ipairs(fields) do
        fields[index] = string.len(field) .. ":" .. field
    end
    return table.concat(fields)
end

function M.importRTSHistory()
    local history = {}
    for key, timestamp in pairs(M.db.sentRTS) do
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

local function hasValue(value)
    return value and value ~= 0
end

local function eligibleRTS(index, returned, gm, key, timestamp)
    local sentAt = M.db.sentRTS[key]
    return not hasValue(returned) and not hasValue(gm)
        and (not sentAt or sentAt <= timestamp - M.RETENTION)
        and not hasValue(InboxItemCanDelete(index))
end

function M.inspectRTSMail(scan, index, sender, subject, money, cod, attached, returned, gm, name, count)
    if not M.isRTSSubject(subject) or hasValue(cod) then return end
    if not sender or sender == "" or (attached and (not name or type(count) ~= "number" or count <= 0)) then
        scan.incompleteRTS = true
        return
    end
    local key = M.rtsMailKey(sender, subject, name, count, money)
    if M.db.sentRTS[key] then scan.seen[key] = (scan.seen[key] or 0) + 1 end
    if (attached or (money and money > 0)) and eligibleRTS(index, returned, gm, key, scan.timestamp) then
        scan.eligible = scan.eligible + 1
        if not scan.candidate then scan.candidate = { index = index, key = key } end
    end
end

function M.beginRTSHistoryCheck(scan)
    scan.historyIndex = 1
    if scan.incompleteRTS then return end
    local previous = M.db.rtsInboxSeen[M.characterKey] or {}
    for key, count in pairs(scan.seen) do
        local added = count - (previous[key] or 0)
        if added > 0 then scan.matches[key] = added end
    end
    scan.returnedItems = {}
end

function M.scanRTSHistory(scan, budget)
    if not scan.returnedItems or not next(scan.matches) then return true end
    local history = M.db.rtsHistory
    local last = math.min(table.getn(history), scan.historyIndex + budget - 1)
    for index = scan.historyIndex, last do
        local item = history[index]
        local available = scan.matches[item.key]
        if available and not item.returnedAt and item.timestamp > scan.timestamp - M.RETENTION then
            table.insert(scan.returnedItems, item)
            scan.matches[item.key] = available > 1 and available - 1 or nil
        end
    end
    scan.historyIndex = last + 1
    return scan.historyIndex > table.getn(history) or not next(scan.matches)
end

local function candidateStillMatches(candidate)
    local index = candidate.index
    local _, _, sender, subject, money, cod, _, hasItem, _, returned, _, _, gm = GetInboxHeaderInfo(index)
    if not sender or sender == "" or not M.isRTSSubject(subject) or hasValue(cod) then return end
    local name, count
    if hasValue(hasItem) then
        name, count = M.inboxItem(index)
        if not name or not count or count <= 0 then return end
    elseif not money or money <= 0 then
        return
    end
    local key = M.rtsMailKey(sender, subject, name, count, money)
    return key == candidate.key and eligibleRTS(index, returned, gm, key, time())
end

function M.startRTSReturn(manual)
    if not M.mailboxOpen or M.rts.returning then return end
    M.rts.returning = { manual = manual, nextAt = GetTime(), done = 0 }
    if not M.rts.inboxReady and not M.inboxScanPending then M.scheduleInboxScan() end
end

function M.stopRTSReturn(message)
    if M.rts.returning.manual and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("Mail Item Log: " .. message)
    end
    M.rts.returning = nil
end

function M.finishRTSScan(scan, now)
    if scan.returnedItems then
        for _, item in ipairs(scan.returnedItems) do item.returnedAt = scan.timestamp end
        M.db.rtsInboxSeen[M.characterKey] = scan.seen
    end
    M.rts.inboxReady, M.rts.candidate, M.rts.eligible = true, scan.candidate, scan.eligible
    local returning = M.rts.returning
    if returning and returning.waitUntil and scan.eligible < returning.count then
        returning.done = returning.done + 1
        if returning.stopAfterCurrent then
            M.stopRTSReturn("Auto-return is off.")
        else
            returning.waitUntil = nil
            returning.nextAt = now + 0.4
        end
    elseif not returning and M.db.autoReturnRTS and not M.rts.autoBlocked and M.rts.candidate then
        M.startRTSReturn(false)
    end
end

function M.pumpRTS(now)
    local returning = M.rts.returning
    if not returning or M.pending then return end
    if returning.waitUntil then
        if now >= returning.waitUntil and not M.inboxScanPending then
            M.rts.autoBlocked = true
            M.stopRTSReturn("Return stopped. The server did not confirm the last mail.")
        end
        return
    end
    if M.inboxScanPending or now < returning.nextAt then return end
    local candidate = M.rts.candidate
    if not candidate then
        M.stopRTSReturn(string.format("Returned %d RTS mail(s).", returning.done))
        return
    end
    local stillMatches = candidateStillMatches(candidate)
    if M.inboxScanPending or not M.mailboxOpen then return end
    if not stillMatches then
        M.scheduleInboxScan()
    else
        returning.count = M.rts.eligible
        returning.waitUntil = now + 12
        M.rts.candidate = nil
        ReturnInboxItem(candidate.index)
    end
end

function M.recordRTSSend(mail, timestamp)
    if not mail.rtsKey then return end
    M.db.sentRTS[mail.rtsKey] = timestamp
    table.insert(M.db.rtsHistory, {
        key = mail.rtsKey, owner = M.characterKey, sender = M.characterName,
        recipient = mail.recipient, subject = mail.rtsSubject,
        name = mail.name, count = mail.count, money = mail.rtsMoney,
        icon = mail.icon, quality = mail.quality, timestamp = timestamp,
    })
    if M.inboxScanPending or M.rts.candidate then M.scheduleInboxScan() end
end

function M.initializeRTS()
    M.db.sentRTS = M.db.sentRTS or {}
    M.db.rtsHistory = M.db.rtsHistory or M.importRTSHistory()
    M.db.rtsInboxSeen = M.db.rtsInboxSeen or {}
    if M.db.autoReturnRTS == nil then M.db.autoReturnRTS = true end
    if M.db.logRTSInSent == nil then M.db.logRTSInSent = true end
    if not InboxFrame then return end
    local control = M.button(InboxFrame, "Return RTS", 104, 23, 0, 0, function()
        M.startRTSReturn(true)
    end)
    control:ClearAllPoints()
    control:SetPoint("TOPLEFT", MailFrame or InboxFrame, "TOPLEFT", 69, -35)
end

function M.buildRTSControls(frame)
    frame.autoRTS = M.button(frame, "", 153, 22, 16, -138, function()
        M.db.autoReturnRTS = not M.db.autoReturnRTS
        if M.db.autoReturnRTS then
            M.rts.autoBlocked = nil
            if M.rts.candidate then M.startRTSReturn(false) end
        elseif M.rts.returning and not M.rts.returning.manual then
            if M.rts.returning.waitUntil then
                M.rts.returning.stopAfterCurrent = true
            else
                M.stopRTSReturn("Auto-return is off.")
            end
        end
        M.redraw()
    end)
    frame.logRTS = M.button(frame, "", 225, 22, 176, -138, function()
        M.db.logRTSInSent = not M.db.logRTSInSent
        M.redraw()
    end)
    frame.rtsHelp = M.label(frame, "GameFontHighlightSmall", 417, -138)
    frame.rtsHelp:SetWidth(380)
    frame.rtsHelp:SetText("Start the subject with RTS (e.g. RTS [1/3]).\n"
        .. "Recipient: open the mailbox with auto-return on, or click Return RTS.")
end

function M.getRTSTabItems()
    local items, status
    items = {}
    for _, item in ipairs(M.db.rtsHistory) do
        if item.owner == M.characterKey then table.insert(items, item) end
    end
    status = "RTS sent by " .. M.characterName .. " | Last 30 days"
    return items, status
end
