local M = MailItemLogAddon

local events = CreateFrame("Frame", "MailItemLogEvents")
local mailboxFailed
local reportedFailures = {}

local function reportFailure(area, message)
    if reportedFailures[area] then return end
    reportedFailures[area] = true
    local detail = "Mail Item Log (" .. area .. "): " .. tostring(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(detail)
    else
        error(detail)
    end
end

local function updateMailbox(now)
    M.pumpInbox(now)
    M.pumpRTS(now)
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
        local db = MailItemLogDB
        M.db = db
        if not M.tabState[db.openingTab] then db.openingTab = "last" end
        if not M.tabState[db.lastTab] then db.lastTab = "sent" end
        db.sent = db.sent or {}
        db.inboxes = db.inboxes or {}
        M.characterName = UnitName("player")
        M.characterKey = M.characterName .. " - " .. GetRealmName()
        M.initializeRTS()
        M.prune(time())
        M.installSendHook()
        M.addMinimapIcon()
        M.initializeSharing()
    elseif M.db then
        local rts = M.rts
        if event == "CHAT_MSG_WHISPER" then
            if arg1 then M.receivePacket(arg1, arg2) end
        elseif event == "FRIENDLIST_UPDATE" then
            if M.view == "shared" then M.redraw() end
        elseif event == "MAIL_SHOW" then
            M.mailboxOpen = true
            mailboxFailed = nil
            M.pending = nil
            rts.inboxReady, rts.autoBlocked = nil, nil
        elseif event == "MAIL_CLOSED" then
            M.mailboxOpen = false
            M.cancelInboxScan()
            rts.inboxReady, rts.returning = nil, nil
            if M.view == "inbox" then M.redraw() end
        elseif event == "MAIL_INBOX_UPDATE" and M.mailboxOpen and not mailboxFailed then
            M.scheduleInboxScan()
        elseif event == "MAIL_SEND_SUCCESS" then
            M.finishSend()
        elseif event == "MAIL_FAILED" then
            M.pending = nil
            if rts.returning and rts.returning.waitUntil then
                rts.autoBlocked = true
                M.stopRTSReturn("Return stopped. The server rejected the last mail.")
            end
        elseif event == "PLAYER_LOGOUT" then
            M.prune(time())
        end
    end
end)

local elapsed = 0
events:SetScript("OnUpdate", function()
    if not M.db then return end
    if type(arg1) == "number" then elapsed = elapsed + arg1 end
    if not reportedFailures["sharing"] then
        local ok, message = pcall(M.pumpSharing)
        if not ok then reportFailure("sharing", message) end
    end
    if M.inboxScanPending or M.rts.returning then
        local ok, message = pcall(updateMailbox, GetTime())
        if not ok then
            mailboxFailed = true
            M.cancelInboxScan()
            M.rts.returning = nil
            M.rts.inboxReady = nil
            M.rts.autoBlocked = true
            reportFailure("mailbox scan paused", message)
        end
    end
    if elapsed >= 60 then
        elapsed = 0
        M.prune(time())
        M.redraw()
    end
end)

SLASH_MAILITEMLOG1 = "/maillog"
SlashCmdList["MAILITEMLOG"] = M.toggleWindow
