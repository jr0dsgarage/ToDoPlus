---@diagnostic disable: undefined-global
local _, addon = ...
local W = addon.SettingsWidgets

-------------------------------------------------------------------------------
-- Markdown export and import.
--
-- Addons can't write files, so the list itself lives in SavedVariables. This window
-- shows the active list as Markdown to copy out (Ctrl+C), or takes pasted Markdown
-- in (Ctrl+V):
--
--   # To-Do List
--   - [ ] an item above the first category
--   ## Category
--   - [ ] an item
--   - [x] a done item
-------------------------------------------------------------------------------

local function ItemLine(item)
    return "- [" .. (item.done and "x" or " ") .. "] " .. item.text
end

function addon:ListToMarkdown(list)
    list = list or self:GetActiveList()
    local out = { "# To-Do List", "" }
    for _, item in ipairs(list.items) do
        out[#out + 1] = ItemLine(item)
    end
    if #list.items > 0 and #list.categories > 0 then
        out[#out + 1] = ""
    end
    for i, category in ipairs(list.categories) do
        out[#out + 1] = "## " .. category.name
        for _, item in ipairs(category.items) do
            out[#out + 1] = ItemLine(item)
        end
        if i < #list.categories then
            out[#out + 1] = ""
        end
    end
    return table.concat(out, "\n") .. "\n"
end

-- Reads Markdown into a list. "## " (or deeper) headings start categories, and a
-- single "# " title is skipped. Bulleted or numbered lines are items, checked when
-- marked [x]; other non-blank lines are taken as items too, so a plain one-per-line
-- list pastes in as well. Items before the first heading go above the categories.
function addon:MarkdownToList(text)
    local list = self:NewList()
    local current = list.items
    for rawLine in (text .. "\n"):gmatch("(.-)\r?\n") do
        local line = strtrim(rawLine)
        local heading = line:match("^##+%s*(.-)$")
        -- Optional closing hashes ("## Name ##"), but not a name ending in one ("C#")
        heading = heading and strtrim((heading:gsub("%s+#+$", "")))
        if heading and heading ~= "" then
            local category = { name = heading, collapsed = false, items = {} }
            list.categories[#list.categories + 1] = category
            current = category.items
        elseif line ~= "" and not line:match("^#") then
            local body = line:match("^[-*+]%s+(.*)$") or line:match("^%d+[.)]%s+(.*)$") or line
            local done = false
            local mark, rest = body:match("^%[([ xX]?)%]%s*(.*)$")
            if mark then
                done = mark == "x" or mark == "X"
                body = rest
            end
            body = strtrim(body:match("^~~(.+)~~$") or body)
            if body ~= "" then
                current[#current + 1] = { text = body, done = done }
            end
        end
    end
    return list
end

-- Adds `incoming` to the active list. A category whose name matches an existing one
-- (ignoring case) has its items added to that one.
local function AppendList(incoming)
    local list = addon:GetActiveList()
    for _, item in ipairs(incoming.items) do
        list.items[#list.items + 1] = item
    end
    for _, category in ipairs(incoming.categories) do
        local match
        for _, existing in ipairs(list.categories) do
            if existing.name:lower() == category.name:lower() then
                match = existing
                break
            end
        end
        if match then
            for _, item in ipairs(category.items) do
                match.items[#match.items + 1] = item
            end
        else
            list.categories[#list.categories + 1] = category
        end
    end
end

local function DescribeList(list)
    local _, total = addon:CountList(list)
    return string.format("%d %s in %d %s", total, total == 1 and "item" or "items",
        #list.categories, #list.categories == 1 and "category" or "categories")
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

local dialog, editBox, scrollFrame, info
local exportText -- the text shown in export mode, restored if it's typed over
local mode -- "export" or "import"
local buttons = {}

local function FinishImport(replace)
    local incoming = addon:MarkdownToList(editBox:GetText() or "")
    local _, total = addon:CountList(incoming)
    if total == 0 and #incoming.categories == 0 then
        addon.Print("Nothing to import: paste a Markdown list first.")
        return
    end
    if replace then
        addon:ReplaceActiveList(incoming)
    else
        AppendList(incoming)
    end
    addon:OnListChanged()
    addon.Print(string.format("%s %s into the %s list.", replace and "Replaced with" or "Added",
        DescribeList(incoming), addon:GetActiveListName():lower()))
    dialog:Hide()
end

StaticPopupDialogs["TODOPLUS_IMPORT_REPLACE"] = {
    text = "Replace everything in your %s list with the pasted one? This can't be undone.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function() FinishImport(true) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function CreateButton(text, width, onClick)
    local btn = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    btn:SetSize(width, 24)
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    return btn
end

-- Lays a row of buttons along the bottom, right to left.
local function ShowButtons(list)
    for _, btn in pairs(buttons) do btn:Hide() end
    local anchor
    for i = #list, 1, -1 do
        local btn = list[i]
        btn:ClearAllPoints()
        if anchor then
            btn:SetPoint("RIGHT", anchor, "LEFT", -6, 0)
        else
            btn:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -18, 16)
        end
        btn:Show()
        anchor = btn
    end
end

local function CreateDialog()
    dialog = CreateFrame("Frame", "ToDoPlusMarkdownFrame", UIParent, "BackdropTemplate")
    dialog:SetSize(480, 440)
    dialog:SetPoint("CENTER")
    dialog:SetFrameStrata("DIALOG")
    dialog:SetToplevel(true)
    dialog:SetClampedToScreen(true)
    dialog:EnableMouse(true)
    dialog:SetMovable(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    -- Escape closes it
    tinsert(UISpecialFrames, dialog:GetName())

    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    dialog.title = title

    local close = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    info = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("TOPLEFT", 22, -44)
    info:SetPoint("RIGHT", dialog, "RIGHT", -22, 0)
    info:SetJustifyH("LEFT")

    -- The text area: a dark box holding the scrolling edit box.
    local box = CreateFrame("Frame", nil, dialog, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 18, -76)
    box:SetPoint("BOTTOMRIGHT", -18, 48)
    box:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0, 0, 0, 0.5)
    box:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

    scrollFrame = W.CreateScrollFrame(box, "ToDoPlusMarkdownScrollFrame")
    scrollFrame:SetPoint("TOPLEFT", 8, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -22, 8)

    editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(0)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(400) -- matched to the scroll frame below; a multi-line box sets its own height
    scrollFrame:SetScrollChild(editBox)
    scrollFrame:HookScript("OnSizeChanged", function(_, width)
        editBox:SetWidth(math.max(50, width))
    end)

    editBox:SetScript("OnEscapePressed", function() dialog:Hide() end)
    -- Keep the cursor in view while typing or moving through the text.
    editBox:SetScript("OnCursorChanged", function(_, _, y, _, height)
        local top = -y
        local current = scrollFrame:GetVerticalScroll()
        local view = scrollFrame:GetHeight()
        if top < current then
            scrollFrame:SetVerticalScroll(top)
        elseif top + height > current + view then
            scrollFrame:SetVerticalScroll(top + height - view)
        end
    end)
    -- The export is for copying: typing over it puts it back.
    editBox:SetScript("OnTextChanged", function(self, userInput)
        if mode == "export" and userInput then
            self:SetText(exportText)
            self:HighlightText()
        end
    end)

    -- Clicking anywhere in the box puts the cursor in the text.
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() editBox:SetFocus() end)

    buttons.selectAll = CreateButton("Select All", 110, function()
        editBox:SetFocus()
        editBox:HighlightText()
    end)
    buttons.close = CreateButton(CLOSE or "Close", 90, function() dialog:Hide() end)
    buttons.replace = CreateButton("Replace List", 120, function()
        StaticPopup_Show("TODOPLUS_IMPORT_REPLACE", addon:GetActiveListName():lower())
    end)
    buttons.append = CreateButton("Append", 90, function() FinishImport(false) end)
    buttons.cancel = CreateButton(CANCEL or "Cancel", 90, function() dialog:Hide() end)

    dialog:SetScript("OnHide", function()
        editBox:ClearFocus()
        StaticPopup_Hide("TODOPLUS_IMPORT_REPLACE")
    end)
    dialog:Hide()
end

local function Open(newMode)
    if not dialog then CreateDialog() end
    mode = newMode
    dialog:Show()
    dialog:Raise()
    scrollFrame:SetVerticalScroll(0)
end

function addon:ShowMarkdownExport()
    Open("export")
    exportText = self:ListToMarkdown()
    dialog.title:SetText("Export " .. self:GetActiveListName() .. " List")
    info:SetText("Press |cffffd100Ctrl+C|r to copy, then paste into a .md file or anywhere else.")
    editBox:SetText(exportText)
    editBox:SetFocus()
    editBox:HighlightText()
    ShowButtons({ buttons.selectAll, buttons.close })
end

function addon:ShowMarkdownImport()
    Open("import")
    exportText = nil
    dialog.title:SetText("Import into " .. self:GetActiveListName() .. " List")
    info:SetText("Paste Markdown with |cffffd100Ctrl+V|r. |cffffd100## Name|r lines become categories and "
        .. "|cffffd100- [ ]|r / |cffffd100- [x]|r lines become items.")
    editBox:SetText("")
    editBox:SetFocus()
    ShowButtons({ buttons.append, buttons.replace, buttons.cancel })
end
