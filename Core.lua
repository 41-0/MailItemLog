MailItemLogAddon = {
    RETENTION = 30 * 24 * 60 * 60,
    PAGE_SIZE = 12,
    view = "sent",
    page = 1,
}
local M = MailItemLogAddon

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

function M.prune(now)
    local cutoff = now - M.RETENTION
    pruneHistory(M.db.sent, cutoff)
    if not M.inboxScanPending then pruneHistory(M.db.rtsHistory, cutoff) end
    for key, sentAt in pairs(M.db.sentRTS) do
        if sentAt <= cutoff then M.db.sentRTS[key] = nil end
    end
    for key, snapshot in pairs(M.db.inboxes) do
        if snapshot.timestamp <= cutoff then
            M.db.inboxes[key] = nil
        end
    end
end

local function itemIconName(texture)
    if type(texture) ~= "string" then return end
    texture = string.gsub(string.lower(texture), "%.blp$", "")
    local _, _, name = string.find(texture, "^interface\\icons\\([%w_%-]+)$")
    return name
end

function M.itemDetails(name, texture, count, quality, itemQuality)
    if type(texture) == "number" and type(count) == "string" then
        texture, count, quality = count, quality, itemQuality
    end
    if type(quality) ~= "number" or quality < 0 or quality > 8 or quality ~= math.floor(quality) then
        quality = nil
    end
    return name, count, itemIconName(texture), quality
end

function M.inboxItem(index)
    return M.itemDetails(GetInboxItem(index))
end

function M.itemString(link)
    if type(link) ~= "string" then return end
    local _, _, value = string.find(link, "|H(item:[^|]+)|h")
    value = value or link
    if string.len(value) <= 160 and string.find(value, "^item:%d+[:%d%-]*$") then return value end
end

function M.mailItemString(getLink, index)
    if type(getLink) ~= "function" then return end
    local ok, link
    if index then ok, link = pcall(getLink, index) else ok, link = pcall(getLink) end
    if ok then return M.itemString(link) end
end
