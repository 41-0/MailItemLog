local M = MailItemLogAddon

M.inboxColumns = {
    { "name", "Item", 275 },
    { "count", "Qty", 52 },
    { "sender", "From", 140 },
    { "recipient", "To", 140 },
    { "expires", "Expires", 166 },
}

function M.inboxKeys()
    local keys = {}
    for key in pairs(M.db.inboxes) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

StaticPopupDialogs["MAILITEMLOG_CLEAR_INBOXES"] = {
    text = "Clear saved inbox lists for all your characters? Open each character's mailbox to rebuild its list.",
    button1 = "Clear All",
    button2 = "Cancel",
    timeout = 0,
    hideOnEscape = 1,
    OnAccept = function()
        M.db.inboxes = {}
        M.inboxKey, M.page = nil, 1
        M.cancelInboxScan()
        M.redraw()
    end,
}


local scan, scanAt
local MAIL_PER_FRAME = 8
local HISTORY_PER_FRAME = 32
local SETTLE_TIME = 0.10

function M.cancelInboxScan()
    scan, scanAt = nil, nil
    M.inboxScanPending = false
    M.rts.candidate = nil
end

function M.scheduleInboxScan()
    scan = nil
    scanAt = GetTime() + SETTLE_TIME
    M.inboxScanPending = true
    M.rts.candidate = nil
end

function M.pumpInbox(now)
    if not M.inboxScanPending then return end
    local job = scan
    if not job then
        if now < scanAt then return end
        job = { index = 1, timestamp = time(), items = {}, seen = {}, eligible = 0, matches = {} }
        scan = job
    end
    local total = GetInboxNumItems()
    if scan ~= job then return end
    if job.total and job.total ~= total then
        M.scheduleInboxScan()
        return
    end
    job.total = total

    if not job.historyIndex then
        local last = math.min(job.total, job.index + MAIL_PER_FRAME - 1)
        for index = job.index, last do
            local _, _, sender, subject, money, cod, daysLeft, hasItem, _, returned, _, _, gm =
                GetInboxHeaderInfo(index)
            if scan ~= job then return end
            local name, count, icon, quality
            daysLeft = tonumber(daysLeft)
            local attached = hasItem and hasItem ~= 0
            if attached then
                name, count, icon, quality = M.inboxItem(index)
                if scan ~= job then return end
                if name and type(count) == "number" and count > 0 then
                    table.insert(job.items, {
                        name = name, count = count, icon = icon, quality = quality, sender = sender or "?",
                        expires = daysLeft and daysLeft > 0 and math.floor(job.timestamp + daysLeft * 86400) or nil,
                    })
                end
            end
            M.inspectRTSMail(job, index, sender, subject, money, cod, attached, returned, gm, name, count)
            if scan ~= job then return end
        end
        job.index = last + 1
        if job.index <= job.total then return end
        M.beginRTSHistoryCheck(job)
    end

    if not M.scanRTSHistory(job, HISTORY_PER_FRAME) then return end
    M.cancelInboxScan()
    M.db.inboxes[M.characterKey] = { timestamp = job.timestamp, items = job.items }
    M.finishRTSScan(job, now)
    if M.view == "inbox" or M.view == "rts" then M.redraw() end
end

function M.buildInboxControls(frame)
    frame.clearInboxes = M.button(frame, "Clear All", 96, 22, 535, -76, function()
        StaticPopup_Show("MAILITEMLOG_CLEAR_INBOXES")
    end)
    frame.chooseInbox = M.button(frame, "Next character", 119, 22, 639, -76, function()
        local keys = M.inboxKeys()
        for index, key in ipairs(keys) do
            if key == M.inboxKey then
                M.inboxKey = keys[index + 1] or keys[1]
                break
            end
        end
        M.page = 1
        M.redraw()
    end)
end

function M.getInboxTabItems(window)
    local items, status, inboxRecipient
    local keys = M.inboxKeys()
    if not M.inboxKey or not M.db.inboxes[M.inboxKey] then
        M.inboxKey = M.db.inboxes[M.characterKey] and M.characterKey or keys[1]
    end
    local snapshot = M.inboxKey and M.db.inboxes[M.inboxKey]
    items = {}
    if snapshot then
        items = snapshot.items
        local separator = string.find(M.inboxKey, " - ", 1, true)
        inboxRecipient = separator and string.sub(M.inboxKey, 1, separator - 1) or M.inboxKey
        status = M.inboxKey .. " | Last checked " .. M.stamp(snapshot.timestamp)
    else
        status = "Open a mailbox to load its inbox."
    end
    if M.inboxScanPending then status = status .. " | Reading mailbox..." end
    if table.getn(keys) > 1 then window.chooseInbox:Show() else window.chooseInbox:Hide() end
    return items, status, inboxRecipient
end
