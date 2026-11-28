local M = MailItemLogAddon

M.sentColumns = {
    { "timestamp", "Sent at", 146 },
    { "name", "Item", 270 },
    { "count", "Qty", 55 },
    { "sender", "From", 151 },
    { "recipient", "To", 151 },
}
function M.installSendHook()
    local originalSendMail = SendMail
    SendMail = function(recipient, subject, body)
        if M.mailboxOpen and not M.pending and recipient and recipient ~= "" and subject and subject ~= "" then
            local name, count, icon, quality = M.itemDetails(GetSendMailItem())
            local hasAttachment = name and type(count) == "number" and count > 0
            local money = M.isRTSSubject(subject) and GetSendMailMoney() or 0
            if hasAttachment or M.isRTSSubject(subject) then
                M.pending = {
                    name = hasAttachment and name or nil,
                    count = hasAttachment and count or nil,
                    icon = icon,
                    itemString = hasAttachment and M.mailItemString(GetSendMailItemLink) or nil,
                    quality = quality,
                    sender = M.characterName,
                    recipient = recipient,
                }
                if M.isRTSSubject(subject) then
                    local _, _, trimmed = string.find(recipient, "^%s*(.-)%s*$")
                    M.pending.rtsKey = M.rtsMailKey(trimmed or recipient, subject, M.pending.name, M.pending.count, money)
                    M.pending.rtsSubject = subject
                    M.pending.rtsMoney = money
                end
            end
        end
        return originalSendMail(recipient, subject, body)
    end
end

function M.finishSend()
    if not M.pending then return end
    local timestamp = time()
    M.recordRTSSend(M.pending, timestamp)
    if M.pending.name and (not M.pending.rtsKey or M.db.logRTSInSent) then
        table.insert(M.db.sent, {
            timestamp = timestamp, name = M.pending.name, count = M.pending.count,
            icon = M.pending.icon, quality = M.pending.quality, itemString = M.pending.itemString,
            sender = M.pending.sender, recipient = M.pending.recipient,
        })
    end
    M.pending = nil
    if M.view == "sent" or M.view == "rts" then M.redraw() end
end
