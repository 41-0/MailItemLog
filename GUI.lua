local M = MailItemLogAddon

M.tabState = {
    sent = { sort = "timestamp", ascending = false, filters = {} },
    inbox = { sort = "name", ascending = true, filters = {} },
    shared = { sort = "name", ascending = true, filters = {} },
    characters = { sort = "name", ascending = true, filters = {} },
    rts = { sort = "timestamp", ascending = false, filters = {} },
}
local openingTabs = {
    { "last", "Last used tab" },
    { "sent", "Sent Items" },
    { "inbox", "Inbox Items" },
    { "shared", "Shared Inbox" },
    { "rts", "RTS" },
    { "characters", "My Characters" },
}
local filterFields = {
    { "name", "Item" },
    { "sender", "From" },
    { "recipient", "To" },
}
local window

function M.button(parent, caption, width, height, x, y, action)
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetWidth(width)
    control:SetHeight(height)
    control:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    control:SetText(caption)
    control:SetScript("OnClick", action)
    return control
end

function M.label(parent, template, x, y)
    local font = parent:CreateFontString(nil, "OVERLAY", template)
    font:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    font:SetJustifyH("LEFT")
    return font
end

function M.addMinimapIcon()
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
        local angle = M.db.minimapAngle or 225
        icon:ClearAllPoints()
        icon:SetPoint("CENTER", Minimap, "CENTER", 78 * cos(angle), 78 * sin(angle))
    end
    icon:RegisterForClicks("LeftButtonUp")
    icon:RegisterForDrag("LeftButton")
    icon:SetScript("OnClick", function() M.toggleWindow() end)
    icon:SetScript("OnDragStart", function()
        icon:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local centerX, centerY = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            if centerX and centerY then
                M.db.minimapAngle = atan2(y / scale - centerY, x / scale - centerX)
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

function M.stamp(timestamp)
    return timestamp and date("%Y-%m-%d %H:%M", timestamp) or "-"
end

local columnsByTab = { sent = M.sentColumns, inbox = M.inboxColumns, shared = M.sharedColumns, rts = M.rtsColumns, characters = M.characterColumns }

local function visibleItems(items, inboxRecipient, now)
    local state = M.tabState[M.view]
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
            if M.view == "sent" or M.view == "rts" then return left.index > right.index end
            return left.index < right.index
        end
        if a == nil then return false end
        if b == nil then return true end
        if state.ascending then return a < b end
        return a > b
    end)
    return entries
end

local function selectTab(tab)
    M.view, M.page = tab, 1
    M.db.lastTab = tab
    if tab == "characters" then M.reloadCharacters() end
    for _, field in ipairs(filterFields) do
        local key = field[1]
        local box = window.filterBoxes[key]
        box:ClearFocus()
        box:SetText(M.tabState[tab] and M.tabState[tab].filters[key] or "")
    end
    M.redraw()
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

    M.label(frame, "GameFontNormalLarge", 21, -19):SetText("Mail Item Log")
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.sentTab = M.button(frame, "Sent Items", 110, 24, 16, -46, function()
        selectTab("sent")
    end)
    frame.inboxTab = M.button(frame, "Inbox Items", 110, 24, 129, -46, function()
        selectTab("inbox")
    end)
    frame.sharedTab = M.button(frame, "Shared Inbox", 110, 24, 242, -46, function()
        selectTab("shared")
        if ShowFriends then ShowFriends() end
    end)
    frame.rtsTab = M.button(frame, "RTS", 110, 24, 355, -46, function()
        selectTab("rts")
    end)
    if M.characterModuleLoaded then
        frame.characterTab = M.button(frame, "My Characters", 121, 24, 468, -46, function()
            selectTab("characters")
        end)
        M.buildCharacterControls(frame)
    end
    M.buildRTSControls(frame)
    local menu = CreateFrame("Frame", nil, frame)
    menu:SetWidth(170)
    menu:SetHeight(M.characterModuleLoaded and 168 or 142)
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
    local opener = M.button(frame, "", 170, 24, 638, -46, function()
        if menu:IsShown() then menu:Hide() else menu:Show() end
    end)
    for index, option in ipairs(openingTabs) do
        local key, title = option[1], option[2]
        if key ~= "characters" or M.characterModuleLoaded then
            M.button(menu, title, 152, 22, 9, -8 - (index - 1) * 26, function()
                M.db.openingTab = key
                opener:SetText("Open on: " .. title)
                menu:Hide()
            end)
            if M.db.openingTab == key then opener:SetText("Open on: " .. title) end
        end
    end
    M.buildSharedControls(frame)
    M.buildInboxControls(frame)
    frame.status = M.label(frame, "GameFontHighlightSmall", 21, -81)
    frame.sharedOwner = M.label(frame, "GameFontNormal", 183, -144)
    frame.filterBoxes = {}
    for index, filter in ipairs(filterFields) do
        local field = filter[1]
        local x = 21 + (index - 1) * 210
        M.label(frame, "GameFontNormalSmall", x, -115):SetText(filter[2])
        local box = CreateFrame("EditBox", "MailItemLogFilter" .. index, frame, "InputBoxTemplate")
        box:SetPoint("TOPLEFT", frame, "TOPLEFT", x + 44, -107)
        box:SetWidth(151)
        box:SetHeight(22)
        box:SetAutoFocus(false)
        box:SetMaxLetters(100)
        box:SetScript("OnTextChanged", function()
            local value = box:GetText() or ""
            if value == (M.tabState[M.view].filters[field] or "") then return end
            M.tabState[M.view].filters[field] = value ~= "" and value or nil
            M.page = 1
            M.redraw()
        end)
        box:SetScript("OnEnterPressed", function() box:ClearFocus() end)
        box:SetScript("OnEscapePressed", function() box:ClearFocus() end)
        frame.filterBoxes[field] = box
    end
    M.button(frame, "Clear filters", 97, 22, 660, -107, function()
        M.tabState[M.view].filters = {}
        selectTab(M.view)
    end)
    frame.headings = {}
    for index = 1, table.getn(M.rtsColumns) do
        local columnIndex = index
        frame.headings[index] = M.button(frame, "", 100, 23, 16, -170, function()
            local column = columnsByTab[M.view][columnIndex]
            if not column then return end
            local field = column[1]
            local state = M.tabState[M.view]
            if state.sort == field then
                state.ascending = not state.ascending
            else
                state.sort = field
                state.ascending = field ~= "timestamp" and field ~= "count"
            end
            M.page = 1
            M.redraw()
        end)
    end
    frame.rows = {}
    frame.itemIcons = {}
    for index = 1, M.PAGE_SIZE do
        local row = frame:CreateTexture(nil, "BACKGROUND")
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -196 - (index - 1) * 23)
        row:SetWidth(773)
        row:SetHeight(23)
        row:SetTexture(1, 1, 1, 0.045 * (index - 2 * math.floor(index / 2)))
        local cells = {}
        for col = 1, table.getn(M.rtsColumns) do
            cells[col] = M.label(frame, "GameFontHighlight", 21, -201 - (index - 1) * 23)
            cells[col]:SetHeight(16)
        end
        frame.rows[index] = cells
        local icon = frame:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(16)
        icon:SetHeight(16)
        icon:Hide()
        frame.itemIcons[index] = icon
    end
    frame.previous = M.button(frame, "Previous", 90, 23, 16, -487, function()
        M.page = M.page - 1
        M.redraw()
    end)
    frame.next = M.button(frame, "Next", 90, 23, 112, -487, function()
        M.page = M.page + 1
        M.redraw()
    end)
    frame.pageLabel = M.label(frame, "GameFontHighlight", 218, -493)
    return frame
end

function M.enable(control, active)
    if active then control:Enable() else control:Disable() end
end

M.redraw = function()
    if not window or not window:IsShown() then return end

    local now = time()
    local items, status, inboxRecipient
    local columns = columnsByTab[M.view]
    local state = M.tabState[M.view]
    M.enable(window.sentTab, M.view ~= "sent")
    M.enable(window.inboxTab, M.view ~= "inbox")
    M.enable(window.sharedTab, M.view ~= "shared")
    M.enable(window.rtsTab, M.view ~= "rts")
    if window.characterTab then
        if M.view == "characters" then
            window.characterList:Show()
            window.characterMode:Show()
            window.characterInfo:Show()
        else
            window.characterList:Hide()
            window.characterMode:Hide()
            window.characterInfo:Hide()
        end
        M.enable(window.characterTab, M.view ~= "characters")
    end
    if M.view == "inbox" then
        window.clearInboxes:Show()
        M.enable(window.clearInboxes, next(M.db.inboxes) ~= nil)
    else
        window.clearInboxes:Hide()
    end
    if M.view == "rts" then
        window.autoRTS:SetText(M.db.autoReturnRTS and "Auto-return RTS: On" or "Auto-return RTS: Off")
        window.logRTS:SetText(M.db.logRTSInSent and "Record in Sent Items: On" or "Record in Sent Items: Off")
        window.autoRTS:Show()
        window.logRTS:Show()
        window.rtsHelp:Show()
    else
        window.autoRTS:Hide()
        window.logRTS:Hide()
        window.rtsHelp:Hide()
    end
    if M.view == "shared" then
        window.friends:Show()
        window.sharedOwner:Show()
        window.sharedOwner:SetText("")
    else
        window.friends:Hide()
        window.sharedOwner:Hide()
    end
    if M.view ~= "inbox" then window.chooseInbox:Hide() end
    if M.view == "sent" then
        items, status = M.db.sent, "Successful sends | Last 30 days"
    elseif M.view == "rts" then
        items, status = M.getRTSTabItems()
    elseif M.view == "characters" then
        items, status, inboxRecipient = M.getCharacterTabItems(window)
    elseif M.view == "shared" then
        items, status, inboxRecipient = M.getSharedTabItems(window, now)
    else
        items, status, inboxRecipient = M.getInboxTabItems(window)
    end

    local entries = visibleItems(items, inboxRecipient, now)
    local count = table.getn(entries)
    if M.view == "shared" and M.sharedSnapshot and table.getn(items) > 0 and count == 0 then
        status = status .. " | No items match the current filters or expiration."
    end
    local pages = math.max(1, math.ceil(count / M.PAGE_SIZE))
    M.page = math.min(pages, math.max(1, M.page))
    window.status:SetText(status)
    window.pageLabel:SetText(string.format("Page %d / %d  (%d items)", M.page, pages, count))
    M.enable(window.previous, M.page > 1)
    M.enable(window.next, M.page < pages)

    local x = (M.view == "shared" or M.view == "characters") and 183 or 16
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
                local inset = 5
                if column[1] == "name" then
                    local icon = window.itemIcons[rowIndex]
                    icon:ClearAllPoints()
                    icon:SetPoint("TOPLEFT", window, "TOPLEFT", x + 5, -199 - (rowIndex - 1) * 23)
                    inset = inset + 21
                end
                cell:SetPoint("TOPLEFT", window, "TOPLEFT", x + inset, -201 - (rowIndex - 1) * 23)
                cell:SetWidth(column[3] - inset - 5)
            end
            x = x + column[3]
        else
            heading:Hide()
        end
    end
    for index, cells in ipairs(window.rows) do
        local entry = entries[(M.page - 1) * M.PAGE_SIZE + index]
        local item = entry and entry.item
        local icon = window.itemIcons[index]
        if item and item.icon then
            icon:SetTexture("Interface\\Icons\\" .. item.icon)
            icon:Show()
        else
            icon:Hide()
        end
        local color = item and item.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[item.quality]
        for col, cell in ipairs(cells) do
            local column = columns[col]
            local value
            if entry and column then
                local field = column[1]
                value = field == "recipient" and entry.recipient or entry.item[field]
                if field == "timestamp" or field == "expires" then value = M.stamp(value) end
                if field == "delta" and value and value > 0 then value = "+" .. value end
                if field == "returnedAt" then value = value and "Returned" or "Not seen yet" end
                if M.view == "rts" and field == "name" and not value and (entry.item.money or 0) > 0 then
                    value = entry.item.money .. " copper"
                end
            end
            if column and column[1] == "name" and color then
                cell:SetTextColor(color.r, color.g, color.b)
            else
                cell:SetTextColor(1, 1, 1)
            end
            cell:SetText(value and tostring(value) or "")
        end
    end
end

function M.toggleWindow()
    if not M.db then return end
    if not window then window = buildWindow() end
    if window:IsShown() then
        window:Hide()
    else
        local tab = M.db.openingTab == "last" and M.db.lastTab or M.db.openingTab
        window:Show()
        if M.view ~= tab then
            selectTab(tab)
        else
            if tab == "characters" then M.reloadCharacters() end
            M.db.lastTab = tab
            M.redraw()
        end
        if tab == "shared" and ShowFriends then ShowFriends() end
    end
end
