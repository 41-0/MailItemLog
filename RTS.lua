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

local RETURN_MIN_INTERVAL = 0.25
local RETURN_BACKOFF_INTERVAL = 1.25
local RETURN_RECHECK_INTERVAL = 0.8
local RETURN_REFRESH_DELAY = 1.6

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
        local returning = M.rts.returning
        if returning and returning.waitUntil and returning.subject == subject then
            scan.incompleteReturn = true
        end
        return
    end
    local key = M.rtsMailKey(sender, subject, name, count, money)
    scan.rtsCounts[key] = (scan.rtsCounts[key] or 0) + 1
    if M.db.sentRTS[key] then scan.seen[key] = (scan.seen[key] or 0) + 1 end
    if (attached or (money and money > 0)) and eligibleRTS(index, returned, gm, key, scan.timestamp) then
        if not scan.candidate then scan.candidate = { index = index, key = key, subject = subject } end
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

function M.toggleRTSTiming()
    M.rts.timing = not M.rts.timing
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("Mail Item Log: RTS timing " .. (M.rts.timing and "on." or "off."))
    end
end

function M.noteRTSScanFrame(now)
    local batch = M.rts.returning
    local attempt = batch and batch.measurement
    if not attempt or not batch.waitUntil then return end
    attempt.frames = attempt.frames + 1
    attempt.firstScan = attempt.firstScan or now
end

local function showTiming(batch)
    if not batch.timings or not DEFAULT_CHAT_FRAME then return end
    local log = batch.timings
    local total = table.getn(log)
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "Mail Item Log RTS: %d returned from %d attempts in %.2fs%s.",
        batch.done, total, GetTime() - batch.startedAt, batch.slowMode and " (backoff used)" or ""))
    local first = log[1]
    if first then
        if batch.mailboxOpenedAt then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "RTS startup: mailbox open -> first request %.2fs.", first.sentAt - batch.mailboxOpenedAt))
            local update = M.rts.firstInboxUpdateAt
            if not batch.manual and update and update <= first.sentAt then
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "RTS startup breakdown: first inbox update %.2fs after open, then %.2fs to first request.",
                    update - batch.mailboxOpenedAt, first.sentAt - update))
            end
        end
        if batch.manual then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "RTS startup: Return RTS clicked -> first request %.2fs.", first.sentAt - batch.startedAt))
        end
    end
    for index = math.max(1, total - 11), total do
        local attempt = log[index]
        local confirm = attempt.confirmedAt
        local after = confirm and log[index + 1] and log[index + 1].sentAt - confirm
        local scan = confirm and attempt.firstScan and confirm - attempt.firstScan
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "RTS #%d: confirm %s, scan span %s (%d frames), next %s%s",
            index, confirm and string.format("%.2fs", confirm - attempt.sentAt) or "unconfirmed",
            scan and string.format("%.2fs", scan) or "-", attempt.frames,
            after and string.format("%.2fs", after) or "-",
            attempt.failed and ", mail failure" or ""))
    end
end

function M.startRTSReturn(manual)
    if not M.mailboxOpen or M.rts.returning then return end
    local now = GetTime()
    M.rts.returning = { manual = manual, nextAt = now, done = 0, startedAt = now,
        timings = M.rts.timing and {} or nil, mailboxOpenedAt = M.rts.mailboxOpenedAt }
    if not M.rts.inboxReady and not M.inboxScanPending then M.scheduleInboxScan() end
end

function M.stopRTSReturn(message, failed)
    local batch = M.rts.returning
    if not batch then return end
    if (batch.manual or failed) and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("Mail Item Log: " .. message)
    end
    showTiming(batch)
    M.rts.returning = nil
    if M.rts.inboxRefreshDeferred then
        M.rts.inboxRefreshDeferred = nil
        if M.mailboxOpen then M.scheduleInboxScan() end
    end
end

function M.noteRTSFailure()
    local returning = M.rts.returning
    if not returning or not returning.waitUntil then return end
    returning.failed = true
    if returning.measurement then returning.measurement.failed = true end
    if not M.inboxScanPending then M.scheduleInboxScan() end
end

function M.finishRTSScan(scan, now)
    if scan.returnedItems then
        for _, item in ipairs(scan.returnedItems) do item.returnedAt = scan.timestamp end
        M.db.rtsInboxSeen[M.characterKey] = scan.seen
    end
    M.rts.inboxReady, M.rts.candidate, M.rts.counts = true, scan.candidate, scan.rtsCounts
    local returning = M.rts.returning
    if returning and returning.waitUntil and not scan.incompleteReturn
        and (scan.rtsCounts[returning.key] or 0) < returning.count then
        returning.done = returning.done + 1
        if returning.measurement then returning.measurement.confirmedAt = now end
        if returning.stopAfterCurrent then
            M.stopRTSReturn("Auto-return is off.")
        else
            returning.waitUntil = nil
            returning.failed, returning.retried = nil, nil
            local interval = returning.slowMode and RETURN_BACKOFF_INTERVAL or RETURN_MIN_INTERVAL
            returning.nextAt = math.max(now, returning.sentAt + interval)
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
            local candidate = M.rts.candidate
            if returning.failed and not returning.retried and not returning.stopAfterCurrent
                and candidate and candidate.key == returning.key then
                returning.waitUntil = nil
                returning.retried = true
                returning.slowMode = true
                returning.nextAt = now
            else
                M.rts.autoBlocked = true
                local reason = returning.failed and "mail failure reported and return not confirmed."
                    or "the mailbox still shows the last mail after refresh."
                M.stopRTSReturn("RTS stopped: " .. reason, true)
            end
        elseif not M.inboxScanPending and now >= returning.recheckAt then
            returning.recheckAt = now + RETURN_RECHECK_INTERVAL
            M.scheduleInboxScan()
            if returning.refreshAt and now >= returning.refreshAt then
                returning.refreshAt = nil
                if CheckInbox then CheckInbox() end
            end
        end
        return
    end
    if M.inboxScanPending or now < returning.nextAt then return end
    local candidate = M.rts.candidate
    if not candidate then
        M.stopRTSReturn(string.format("Returned %d RTS mail(s).", returning.done))
        return
    end
    if returning.retried and candidate.key ~= returning.key then
        M.rts.autoBlocked = true
        M.stopRTSReturn("RTS stopped: the mailbox changed before the retry.", true)
        return
    end
    local stillMatches = candidateStillMatches(candidate)
    if M.inboxScanPending or not M.mailboxOpen then return end
    if not stillMatches then
        M.scheduleInboxScan()
    else
        returning.key = candidate.key
        returning.subject = candidate.subject
        returning.refreshAt = now + RETURN_REFRESH_DELAY
        returning.count = M.rts.counts[candidate.key]
        returning.recheckAt = now + RETURN_RECHECK_INTERVAL
        returning.failed = nil
        returning.sentAt = now
        returning.waitUntil = now + 12
        M.rts.candidate = nil
        if returning.timings then
            local attempt = { sentAt = now, frames = 0 }
            table.insert(returning.timings, attempt)
            returning.measurement = attempt
        end
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
        icon = mail.icon, quality = mail.quality, itemString = mail.itemString, timestamp = timestamp,
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
    control:SetPoint("TOPLEFT", MailFrame or InboxFrame, "TOPLEFT", 69, -51)
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
