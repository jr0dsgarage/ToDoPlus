---@diagnostic disable: undefined-global
local _, addon = ...

-------------------------------------------------------------------------------
-- The list inside the panel: uncategorized items, then each category and its
-- items. While the edit modifier is held (or a text box is open) every row gets a
-- red remove button after its text, and + rows appear for adding: after the
-- uncategorized items, after each open category's items, and at the very end (a
-- new category).
--
-- Rows are pooled by type and laid out top to bottom on every change; a to-do list
-- is small enough that a full re-layout is cheap.
-------------------------------------------------------------------------------

local ROW_PAD = 2        -- between rows
local CATEGORY_GAP = 6   -- above each category, and above the final + row
local COLLAPSE_SIZE = 14 -- category expand/collapse button
local REMOVE_GAP = 4     -- between a row's text and its remove button
local STRIKE_POSITION = 0.55 -- strike line's height within a text line, from the top

local content, measurer, editBox, hint
local editMode = false
-- The open text box: { kind = "addItem" | "addCategory" | "renameItem" | "renameCategory",
--   owner = items table (addItem, renameItem), category = ..., item = ... }
local editing = nil
local ignoreFocusLost = false
local rendering = false
-- Set while laying out: where the open text box ended up, for scrolling to it.
local editorPlaced, editorTop, editorBottom

-------------------------------------------------------------------------------
-- Textures, with fallbacks for clients that lack an art file.
-------------------------------------------------------------------------------

local function FileExists(path)
    if not GetFileIDFromPath then return true end
    return GetFileIDFromPath(path) ~= nil
end

local function FirstExisting(...)
    for i = 1, select("#", ...) do
        local path = select(i, ...)
        if FileExists(path) then return path end
    end
    return nil
end

local REMOVE_TEXTURE = FirstExisting("Interface\\RaidFrame\\ReadyCheck-NotReady", "Interface\\Buttons\\UI-GroupLoot-Pass-Up")

local function AtlasExists(atlas)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) ~= nil
end

local COLLAPSE_ATLAS = "UI-QuestTrackerButton-Secondary-Collapse"
local EXPAND_ATLAS = "UI-QuestTrackerButton-Secondary-Expand"
local HAS_TRACKER_ATLAS = AtlasExists(COLLAPSE_ATLAS) and AtlasExists(EXPAND_ATLAS)

local function SetCollapseArt(button, collapsed)
    if HAS_TRACKER_ATLAS then
        local atlas = collapsed and EXPAND_ATLAS or COLLAPSE_ATLAS
        button:SetNormalAtlas(atlas)
        button:SetPushedAtlas(atlas)
    else
        local base = collapsed and "Interface\\Buttons\\UI-PlusButton-" or "Interface\\Buttons\\UI-MinusButton-"
        button:SetNormalTexture(base .. "Up")
        button:SetPushedTexture(base .. "Down")
    end
end

-------------------------------------------------------------------------------
-- Strikethrough
--
-- Font strings have no strikethrough, so a thin line is drawn across each line of a
-- checked item's text. Wrapped text needs each line's width, which the game doesn't
-- report, so the wrap is replayed word by word in a hidden font string.
-------------------------------------------------------------------------------

local function MeasureWidth(text)
    measurer:SetText(text)
    return measurer:GetUnboundedStringWidth()
end

-- Splits a word too long for a line on its own across lines, a character at a time
-- (as the game does with non-space wrapping). Returns the widths of the lines it
-- fills, and the text left over to start the next line with.
local function BreakLongWord(word, width, lines)
    local piece = ""
    for char in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local candidate = piece .. char
        if piece ~= "" and MeasureWidth(candidate) > width then
            lines[#lines + 1] = MeasureWidth(piece)
            piece = char
        else
            piece = candidate
        end
    end
    return piece
end

-- Widths of the lines `fontString` breaks `text` into at `width`.
local function MeasureLines(fontString, text, width)
    measurer:SetFont(fontString:GetFont())
    local lines = {}
    local current = ""
    for word in text:gmatch("%S+") do
        local candidate = current == "" and word or (current .. " " .. word)
        if MeasureWidth(candidate) <= width then
            current = candidate
        else
            if current ~= "" then
                lines[#lines + 1] = MeasureWidth(current)
            end
            if MeasureWidth(word) > width then
                current = BreakLongWord(word, width, lines)
            else
                current = word
            end
        end
    end
    if current ~= "" then
        lines[#lines + 1] = MeasureWidth(current)
    end
    return lines
end

-- Draws (or, with lines nil, clears) a row's strike lines.
local function DrawStrikes(row, lines, lineHeight, color, thickness)
    local strikes = row.strikes
    local count = lines and #lines or 0
    for i = 1, count do
        local strike = strikes[i]
        if not strike then
            strike = row:CreateTexture(nil, "OVERLAY")
            strikes[i] = strike
        end
        strike:ClearAllPoints()
        strike:SetPoint("TOPLEFT", row.text, "TOPLEFT", 0, -((i - 1) * lineHeight + lineHeight * STRIKE_POSITION))
        strike:SetSize(math.max(1, lines[i]), thickness)
        strike:SetColorTexture(color.r, color.g, color.b, color.a or 1)
        strike:Show()
    end
    for i = count + 1, #strikes do
        strikes[i]:Hide()
    end
end

-------------------------------------------------------------------------------
-- Finding things in the active list. Rows hold references, not indices, so they
-- stay right however the list is reordered underneath them.
-------------------------------------------------------------------------------

local function IndexOf(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return nil
end

local function OwnerInActiveList(owner)
    local list = addon:GetActiveList()
    if owner == list.items then return true end
    for _, category in ipairs(list.categories) do
        if category.items == owner then return true end
    end
    return false
end

-- Whether the open text box still points at something in the shown list (a list
-- switch, clear or import can take it away).
local function EditingTargetValid()
    if not editing then return false end
    local kind = editing.kind
    if kind == "addCategory" then
        return true
    elseif kind == "addItem" then
        return OwnerInActiveList(editing.owner)
    elseif kind == "renameItem" then
        return OwnerInActiveList(editing.owner) and IndexOf(editing.owner, editing.item) ~= nil
    elseif kind == "renameCategory" then
        return IndexOf(addon:GetActiveList().categories, editing.category) ~= nil
    end
    return false
end

-------------------------------------------------------------------------------
-- Text box: adding and renaming
-------------------------------------------------------------------------------

local function CloseEditor()
    editing = nil
    ignoreFocusLost = true
    editBox:ClearFocus()
    editBox:Hide()
    ignoreFocusLost = false
end

-- Saves what's in the text box. From Enter, adding stays open for the next entry:
-- below the new item, or (after a new category) for that category's first item.
local function CommitEdit(fromEnter)
    local e = editing
    if not e then return end
    local text = strtrim(editBox:GetText() or "")

    if text ~= "" and EditingTargetValid() then
        if e.kind == "addItem" then
            table.insert(e.owner, { text = text, done = false })
            if fromEnter then
                editBox:SetText("")
                addon:OnListChanged()
                return
            end
        elseif e.kind == "addCategory" then
            local category = { name = text, collapsed = false, items = {} }
            table.insert(addon:GetActiveList().categories, category)
            if fromEnter then
                editing = { kind = "addItem", owner = category.items, category = category }
                editBox:SetText("")
                addon:OnListChanged()
                return
            end
        elseif e.kind == "renameItem" then
            e.item.text = text
        elseif e.kind == "renameCategory" then
            e.category.name = text
        end
    end

    CloseEditor()
    addon:UpdateEditMode()
    addon:OnListChanged()
end

function addon:CancelInlineEdit()
    if not editing then return end
    CloseEditor()
    self:UpdateEditMode()
    self:RenderList()
end

local function OpenEditor(info, initialText)
    if editing then CommitEdit(false) end
    editing = info
    editMode = true
    editBox:SetText(initialText or "")
    addon:RenderList()
    if editing then
        editBox:SetFocus()
        if initialText and initialText ~= "" then
            editBox:HighlightText()
        end
    end
end

local function StartAdd(kind, owner, category)
    if category and category.collapsed then category.collapsed = false end
    OpenEditor({ kind = kind, owner = owner, category = category })
end

local function StartRenameItem(item, owner)
    OpenEditor({ kind = "renameItem", item = item, owner = owner }, item.text)
end

local function StartRenameCategory(category)
    OpenEditor({ kind = "renameCategory", category = category }, category.name)
end

local function CreateEditBox()
    local box = CreateFrame("EditBox", nil, content, "BackdropTemplate")
    -- A starting font so text can be set before PlaceEditor applies the chosen one.
    box:SetFontObject(GameFontHighlight)
    box:SetAutoFocus(false)
    box:SetMaxLetters(255)
    box:SetTextInsets(4, 4, 0, 0)
    box:SetFrameLevel(content:GetFrameLevel() + 10)
    box:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    box:SetBackdropColor(0, 0, 0, 0.6)
    box:SetBackdropBorderColor(1, 0.82, 0, 0.6)
    box:SetTextColor(1, 1, 1, 1)
    box:Hide()

    box:SetScript("OnEnterPressed", function() CommitEdit(true) end)
    box:SetScript("OnEscapePressed", function() addon:CancelInlineEdit() end)
    box:SetScript("OnEditFocusLost", function()
        if not ignoreFocusLost then CommitEdit(false) end
    end)
    return box
end

-- Puts the text box over a row: x/top from the row's top-left, in the given font.
local function PlaceEditor(row, x, top, width, height, fontPath, fontSize, rowY)
    editBox:ClearAllPoints()
    editBox:SetPoint("TOPLEFT", row, "TOPLEFT", x, -top)
    editBox:SetSize(math.max(40, width), height)
    addon:ApplyFont(editBox, fontPath, fontSize)
    editBox:Show()
    editorPlaced = true
    editorTop = rowY + top
    editorBottom = rowY + top + height
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

local function ToggleDone(item)
    item.done = not item.done
    PlaySound(item.done and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    addon:OnListChanged()
end

local function RemoveItem(item, owner)
    if editing and editing.item == item then CloseEditor() end
    local index = IndexOf(owner, item)
    if index then table.remove(owner, index) end
    addon:UpdateEditMode()
    addon:OnListChanged()
end

local function RemoveCategory(category)
    local categories = addon:GetActiveList().categories
    local index = IndexOf(categories, category)
    if not index then return end
    if editing and (editing.category == category or editing.owner == category.items) then
        CloseEditor()
    end
    table.remove(categories, index)
    addon:UpdateEditMode()
    addon:OnListChanged()
end

StaticPopupDialogs["TODOPLUS_DELETE_CATEGORY"] = {
    text = "Delete the category \"%s\" and the %d items in it?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(_, category) RemoveCategory(category) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function ConfirmRemoveCategory(category)
    if #category.items == 0 then
        RemoveCategory(category)
    else
        StaticPopup_Show("TODOPLUS_DELETE_CATEGORY", category.name, #category.items, category)
    end
end

local function ToggleCollapsed(category)
    -- Collapsing hides the + row a text box might be open in.
    if editing and editing.owner == category.items then CommitEdit(false) end
    category.collapsed = not category.collapsed
    addon:OnListChanged()
end

-------------------------------------------------------------------------------
-- Rows
-------------------------------------------------------------------------------

local function ShowTooltip(owner, title, body)
    local tooltip = addon:AcquireTooltip(owner, "ANCHOR_RIGHT")
    tooltip:SetText(title)
    if body then tooltip:AddLine(body, 1, 1, 1, true) end
    tooltip:Show()
end

local function RowOnEnter(row)
    row.highlight:Show()
    if row.renameHint and addon:IsEditModifierDown() then
        ShowTooltip(row, row.renameHint)
    end
end

local function RowOnLeave(row)
    row.highlight:Hide()
    addon:HideSharedTooltip()
end

-- A row is a button the size of its line(s); dragging it moves the panel.
local function CreateRowBase()
    local row = CreateFrame("Button", nil, content)
    row:RegisterForClicks("LeftButtonUp")
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function() addon:StartPanelMove() end)
    row:SetScript("OnDragStop", function() addon:StopPanelMove() end)
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", RowOnLeave)

    local highlight = row:CreateTexture(nil, "BACKGROUND")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.06)
    highlight:Hide()
    row.highlight = highlight
    return row
end

-- Child buttons keep their row lit while hovered.
local function ForwardHover(child, onEnter)
    child:SetScript("OnEnter", function(self)
        RowOnEnter(self:GetParent())
        if onEnter then onEnter(self) end
    end)
    child:SetScript("OnLeave", function(self) RowOnLeave(self:GetParent()) end)
    child:RegisterForDrag("LeftButton")
    child:SetScript("OnDragStart", function() addon:StartPanelMove() end)
    child:SetScript("OnDragStop", function() addon:StopPanelMove() end)
end

local function CreateRemoveButton(row, tooltipTitle)
    local btn = CreateFrame("Button", nil, row)
    if REMOVE_TEXTURE then
        btn:SetNormalTexture(REMOVE_TEXTURE)
        btn:SetHighlightTexture(REMOVE_TEXTURE, "ADD")
    else
        local x = btn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        x:SetPoint("CENTER")
        x:SetText("x")
        x:SetTextColor(1, 0.2, 0.2)
    end
    ForwardHover(btn, function(self) ShowTooltip(self, tooltipTitle) end)
    btn:Hide()
    return btn
end

local function CreateItemRow()
    local row = CreateRowBase()
    row.renameHint = "Click to rename"
    row:SetScript("OnClick", function(self)
        if addon:IsEditModifierDown() then
            StartRenameItem(self.item, self.owner)
        else
            ToggleDone(self.item)
        end
    end)

    local check = CreateFrame("CheckButton", nil, row)
    check:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    check:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    check:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:SetScript("OnClick", function(self) ToggleDone(self:GetParent().item) end)
    ForwardHover(check)
    row.check = check

    local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetWordWrap(true)
    text:SetNonSpaceWrap(true)
    row.text = text
    row.strikes = {}

    row.remove = CreateRemoveButton(row, "Remove item")
    row.remove:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        RemoveItem(parent.item, parent.owner)
    end)
    return row
end

local function CreateCategoryRow()
    local row = CreateRowBase()
    row.renameHint = "Click to rename"
    row:SetScript("OnClick", function(self)
        if addon:IsEditModifierDown() then
            StartRenameCategory(self.category)
        else
            ToggleCollapsed(self.category)
        end
    end)

    local toggle = CreateFrame("Button", nil, row)
    toggle:SetSize(COLLAPSE_SIZE, COLLAPSE_SIZE)
    toggle:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    toggle:SetScript("OnClick", function(self) ToggleCollapsed(self:GetParent().category) end)
    ForwardHover(toggle)
    row.toggle = toggle

    local name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row.text = name

    row.remove = CreateRemoveButton(row, "Delete category")
    row.remove:SetScript("OnClick", function(self)
        ConfirmRemoveCategory(self:GetParent().category)
    end)
    return row
end

local function CreateAddRow()
    local row = CreateRowBase()
    row:SetScript("OnClick", function(self)
        StartAdd(self.kind, self.owner, self.category)
    end)

    local plus = row:CreateTexture(nil, "ARTWORK")
    plus:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
    row.plus = plus

    local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetTextColor(0.6, 0.6, 0.6, 1)
    row.label = label
    return row
end

local pools = {
    item = { create = CreateItemRow, frames = {}, used = 0 },
    category = { create = CreateCategoryRow, frames = {}, used = 0 },
    add = { create = CreateAddRow, frames = {}, used = 0 },
}

local function Acquire(kind)
    local pool = pools[kind]
    pool.used = pool.used + 1
    local row = pool.frames[pool.used]
    if not row then
        row = pool.create()
        pool.frames[pool.used] = row
    end
    row:Show()
    return row
end

local function ReleaseAll()
    for _, pool in pairs(pools) do
        for _, row in ipairs(pool.frames) do
            row:Hide()
        end
        pool.used = 0
    end
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

local function LineHeight(fontPath, fontSize)
    addon:ApplyFont(measurer, fontPath, fontSize)
    measurer:SetText("Ag")
    return measurer:GetStringHeight()
end

local function GetMetrics()
    local db = addon.db
    local itemSize = db.itemFontSize
    return {
        checkSize = math.floor(itemSize * 1.5 + 2),
        removeSize = math.max(10, itemSize),
        plusSize = itemSize + 2,
        categoryIndent = COLLAPSE_SIZE + 4,
        itemLineHeight = LineHeight(db.itemFont, itemSize),
        categoryLineHeight = LineHeight(db.categoryFont, db.categoryFontSize),
        strikeThickness = math.max(1, math.floor(itemSize / 10 + 0.5)),
    }
end

local function PlaceRow(row, y)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
end

local function PlaceItem(item, owner, indent, y, width, m)
    local db = addon.db
    local row = Acquire("item")
    row.item, row.owner = item, owner
    PlaceRow(row, y)

    local check = row.check
    check:SetSize(m.checkSize, m.checkSize)
    check:ClearAllPoints()
    check:SetPoint("TOPLEFT", row, "TOPLEFT", indent, 0)
    check:SetChecked(item.done)

    local lineHeight = m.itemLineHeight
    local textLeft = indent + m.checkSize + 2
    -- Room for the remove button is kept even while it's hidden, so holding the
    -- modifier never re-wraps the list.
    local textWidth = math.max(20, width - textLeft - m.removeSize - REMOVE_GAP - 2)
    local textTop = math.max(0, (m.checkSize - lineHeight) / 2)
    local text = row.text
    local rowHeight

    if editing and editing.kind == "renameItem" and editing.item == item then
        text:Hide()
        DrawStrikes(row, nil)
        row.remove:Hide()
        local boxHeight = lineHeight + 6
        local boxTop = math.max(0, (m.checkSize - boxHeight) / 2)
        PlaceEditor(row, textLeft - 4, boxTop, textWidth + 4, boxHeight, db.itemFont, db.itemFontSize, y)
        rowHeight = math.max(m.checkSize, boxTop + boxHeight)
    else
        text:Show()
        addon:ApplyFont(text, db.itemFont, db.itemFontSize)
        text:SetWidth(textWidth)
        text:SetText(item.text)
        text:ClearAllPoints()
        text:SetPoint("TOPLEFT", row, "TOPLEFT", textLeft, -textTop)
        local color = item.done and db.doneColor or db.itemColor
        text:SetTextColor(color.r, color.g, color.b, color.a)

        local textHeight = text:GetStringHeight()
        local numLines = math.max(1, text:GetNumLines())
        local perLine = textHeight / numLines

        -- Each line's width: for the strike lines, and to put the remove button
        -- right after the text's last line.
        local lines
        if item.done or editMode then
            lines = MeasureLines(text, item.text, textWidth)
            if #lines ~= numLines then
                -- Our wrap didn't match the game's; fall back to full-width lines.
                lines = {}
                for i = 1, numLines do lines[i] = textWidth end
                if numLines == 1 then lines[1] = math.min(text:GetStringWidth(), textWidth) end
            end
        end
        DrawStrikes(row, item.done and lines or nil, perLine, db.doneColor, m.strikeThickness)

        if editMode then
            local lastWidth = math.min(lines[#lines], textWidth)
            local centerY = textTop + (numLines - 1) * perLine + perLine / 2
            local remove = row.remove
            remove:SetSize(m.removeSize, m.removeSize)
            remove:ClearAllPoints()
            remove:SetPoint("TOPLEFT", row, "TOPLEFT", textLeft + lastWidth + REMOVE_GAP, -(centerY - m.removeSize / 2))
            remove:Show()
        else
            row.remove:Hide()
        end
        rowHeight = math.max(m.checkSize, textTop + textHeight)
    end

    row:SetHeight(rowHeight)
    return rowHeight + ROW_PAD
end

local function PlaceCategory(category, y, width, m)
    local db = addon.db
    local row = Acquire("category")
    row.category = category
    PlaceRow(row, y)

    local lineHeight = m.categoryLineHeight
    local rowHeight = math.max(COLLAPSE_SIZE, lineHeight) + 4
    local middle = -rowHeight / 2

    local toggle = row.toggle
    toggle:ClearAllPoints()
    toggle:SetPoint("LEFT", row, "TOPLEFT", 0, middle)
    SetCollapseArt(toggle, category.collapsed)

    local nameLeft = COLLAPSE_SIZE + 4
    local nameWidth = math.max(20, width - nameLeft - m.removeSize - REMOVE_GAP - 2)
    local name = row.text

    if editing and editing.kind == "renameCategory" and editing.category == category then
        name:Hide()
        row.remove:Hide()
        local boxHeight = lineHeight + 6
        rowHeight = math.max(rowHeight, boxHeight + 2)
        PlaceEditor(row, nameLeft - 4, (rowHeight - boxHeight) / 2, nameWidth + 4, boxHeight, db.categoryFont, db.categoryFontSize, y)
        toggle:ClearAllPoints()
        toggle:SetPoint("LEFT", row, "TOPLEFT", 0, -rowHeight / 2)
    else
        name:Show()
        addon:ApplyFont(name, db.categoryFont, db.categoryFontSize)
        name:SetWidth(nameWidth)
        local done, total = addon:CountItems(category.items)
        local count = total > 0 and string.format("  |cff808080(%d/%d)|r", done, total) or ""
        name:SetText(category.name .. count)
        local c = db.categoryColor
        name:SetTextColor(c.r, c.g, c.b, c.a)
        name:ClearAllPoints()
        name:SetPoint("LEFT", row, "TOPLEFT", nameLeft, middle)

        if editMode then
            local remove = row.remove
            remove:SetSize(m.removeSize, m.removeSize)
            remove:ClearAllPoints()
            remove:SetPoint("LEFT", row, "TOPLEFT", nameLeft + math.min(name:GetStringWidth(), nameWidth) + REMOVE_GAP, middle)
            remove:Show()
        else
            row.remove:Hide()
        end
    end

    row:SetHeight(rowHeight)
    return rowHeight + ROW_PAD
end

-- A + row. kind "addItem" adds to `owner` (an items table); "addCategory" adds a category.
local function PlaceAdd(kind, owner, category, indent, y, width, m)
    local db = addon.db
    local row = Acquire("add")
    row.kind, row.owner, row.category = kind, owner, category
    PlaceRow(row, y)

    local lineHeight = m.itemLineHeight
    local rowHeight = math.max(m.plusSize, lineHeight) + 4
    local iconCenterX, labelLeft
    if kind == "addCategory" then
        iconCenterX = COLLAPSE_SIZE / 2
        labelLeft = COLLAPSE_SIZE + 4
    else
        iconCenterX = indent + m.checkSize / 2
        labelLeft = indent + m.checkSize + 2
    end

    local isOpen = editing and editing.kind == kind and (kind == "addCategory" or editing.owner == owner)
    if isOpen then
        row.label:Hide()
        local fontPath = kind == "addCategory" and db.categoryFont or db.itemFont
        local fontSize = kind == "addCategory" and db.categoryFontSize or db.itemFontSize
        local boxHeight = LineHeight(fontPath, fontSize) + 6
        rowHeight = math.max(rowHeight, boxHeight + 2)
        PlaceEditor(row, labelLeft - 4, (rowHeight - boxHeight) / 2, width - labelLeft + 2, boxHeight, fontPath, fontSize, y)
    else
        local label = row.label
        label:Show()
        addon:ApplyFont(label, db.itemFont, math.max(8, db.itemFontSize - 1))
        label:SetText(kind == "addCategory" and "Add category" or "Add item")
        label:ClearAllPoints()
        label:SetPoint("LEFT", row, "TOPLEFT", labelLeft, -rowHeight / 2)
        label:SetWidth(math.max(20, width - labelLeft - 2))
    end

    local plus = row.plus
    plus:SetSize(m.plusSize, m.plusSize)
    plus:ClearAllPoints()
    plus:SetPoint("CENTER", row, "TOPLEFT", iconCenterX, -rowHeight / 2)

    row:SetHeight(rowHeight)
    return rowHeight + ROW_PAD
end

-- Lays the whole list out at the scroll frame's current width. Returns its height.
local function Layout()
    local scrollFrame = addon.scrollFrame
    local width = scrollFrame:GetWidth()
    ReleaseAll()
    hint:Hide()
    editorPlaced = false
    if not width or width <= 1 then return 0 end
    content:SetWidth(width)

    local list = addon:GetActiveList()
    local m = GetMetrics()
    local y = 0

    for _, item in ipairs(list.items) do
        y = y + PlaceItem(item, list.items, 0, y, width, m)
    end
    if editMode then
        y = y + PlaceAdd("addItem", list.items, nil, 0, y, width, m)
    end

    for _, category in ipairs(list.categories) do
        if y > 0 then y = y + CATEGORY_GAP end
        y = y + PlaceCategory(category, y, width, m)
        if not category.collapsed then
            for _, item in ipairs(category.items) do
                y = y + PlaceItem(item, category.items, m.categoryIndent, y, width, m)
            end
            if editMode then
                y = y + PlaceAdd("addItem", category.items, category, m.categoryIndent, y, width, m)
            end
        end
    end

    if editMode then
        if y > 0 then y = y + CATEGORY_GAP end
        y = y + PlaceAdd("addCategory", nil, nil, 0, y, width, m)
    end

    if y == 0 then
        hint:SetText("Hold " .. addon:GetModifierName() .. " to add to your list.")
        hint:SetWidth(width - 8)
        hint:Show()
        y = hint:GetStringHeight() + 16
    end

    content:SetHeight(math.max(1, y))
    return y
end

-- Keeps the open text box in view, and the scroll position inside the list.
local function UpdateScroll(scrollFrame)
    if scrollFrame.UpdateScrollChildRect then scrollFrame:UpdateScrollChildRect() end
    local range = scrollFrame:GetVerticalScrollRange()
    local current = math.min(scrollFrame:GetVerticalScroll(), range)
    if editorPlaced then
        local view = scrollFrame:GetHeight()
        if editorBottom > current + view then
            current = editorBottom - view
        elseif editorTop < current then
            current = editorTop
        end
    end
    scrollFrame:SetVerticalScroll(math.max(0, math.min(range, current)))
end

function addon:RenderList()
    if not content or rendering then return end
    if not self.panel:IsShown() then return end -- redrawn on show
    rendering = true

    if editing and not EditingTargetValid() then
        CloseEditor()
        editMode = self:IsEditModifierDown()
    end

    local scrollFrame = self.scrollFrame
    local height = Layout()
    if self:SetScrollBarRoom(height > scrollFrame:GetHeight() + 0.5) then
        Layout() -- the list's width changed
    end

    -- The row a text box belonged to went away (its category was collapsed, say).
    local dropped = editing and not editorPlaced
    if dropped then CloseEditor() end
    UpdateScroll(scrollFrame)
    rendering = false

    if dropped then self:UpdateEditMode() end
end

-- Edit mode: the modifier is held while the panel is up, or a text box is open.
function addon:UpdateEditMode()
    local on = editing ~= nil or (self:IsPanelShown() and self:IsEditModifierDown())
    if on ~= editMode then
        editMode = on
        self:RenderList()
    end
end

function addon:CreateListView(parent)
    content = parent

    measurer = content:CreateFontString(nil, "BACKGROUND", "GameFontHighlight")
    measurer:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    measurer:SetWordWrap(false)
    measurer:SetAlpha(0)

    hint = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOP", content, "TOP", 0, -8)
    hint:SetJustifyH("CENTER")
    hint:Hide()

    editBox = CreateEditBox()
end
