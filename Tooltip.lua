local M = MailItemLogAddon

local function addSellValue(tooltip, itemID, count)
    -- The original SellValue already adds its lines when GameTooltip shows.
    if type(SellValue_IDFromLink) ~= "function" or type(SellValues) ~= "table" then return end
    local price = SellValues[itemID]
    if type(price) ~= "number" then return end
    if price == 0 then
        tooltip:AddLine(ITEM_UNSELLABLE or "No sell price", 1, 1, 1)
    elseif price > 0 and type(SetTooltipMoney) == "function" then
        SetTooltipMoney(tooltip, price * count)
    end
end

function M.extendItemTooltip(tooltip, item, itemString)
    if type(QuestItem_AddTooltip) ~= "function"
        and type(SellValue_IDFromLink) ~= "function"
        and not (EnhTooltip and type(EnhTooltip.TooltipCall) == "function") then return end

    local quality = tonumber(item.quality)
    local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    local link = (color and color.hex or "|cffffffff") .. "|H" .. itemString .. "|h[" .. item.name .. "]|h|r"
    local count = math.max(1, tonumber(item.count) or 1)

    if type(QuestItem_AddTooltip) == "function" then
        -- Match QuestItem's item-link hover behavior without recording a mail stack as quest progress.
        pcall(QuestItem_AddTooltip, tooltip, item.name, link, -1, 1)
    end
    local _, _, itemID = string.find(itemString, "^(item:%d+)")
    pcall(addSellValue, tooltip, itemID, count)
    tooltip:Show()

    if EnhTooltip and type(EnhTooltip.TooltipCall) == "function" then
        pcall(EnhTooltip.TooltipCall, tooltip, item.name, link, quality or -1, count, nil, false, itemString)
    end
end
