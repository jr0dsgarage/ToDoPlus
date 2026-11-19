---@diagnostic disable: undefined-global
local _, addon = ...
local W = addon.SettingsWidgets

-------------------------------------------------------------------------------
-- The to-do panel: a movable, resizable frame with a title bar (title, list
-- switch, lock and settings buttons) and a scrolling list below it. The list
-- itself is drawn by ListView.lua.
--
-- Adapted from TrackerPlus's tracker frame and header. This frame is never
-- protected, so none of TrackerPlus's combat handling is needed.
-------------------------------------------------------------------------------

local HEADER_H = 24
local MIN_WIDTH, MIN_HEIGHT = 160, 100
-- Gap between the list and the panel's right edge, without and with the scroll bar
-- (the bar sits 6px right of the scroll frame and is 8px wide).
local LIST_INSET_PLAIN = 6
local LIST_INSET_SCROLLBAR = 20

local FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"
local TITLE_TEXT = "To-Do List"

local panel, scrollFrame, content

-- "NONE" means no flags; SetFont wants an empty string for that.
function addon:GetFontFlags()
    local outline = self.db.fontOutline
    if outline == "OUTLINE" or outline == "THICKOUTLINE" then return outline end
    return ""
end

-- Sets a font string's font, falling back to the game font when the file won't load
-- (say, a font from an addon that has since been removed), so text never vanishes.
function addon:ApplyFont(fontString, path, size)
    local flags = self:GetFontFlags()
    if type(path) ~= "string" or fontString:SetFont(path, size, flags) == false then
        fontString:SetFont(FALLBACK_FONT, size, flags)
    end
end

-- Font files from other addons (FontMagic, SharedMedia, ...) load in the background
-- on a fresh start of the game. Text set before its font has arrived stays blank,
-- even after the font loads, until the text is set again. (A /reload never shows
-- this: the files are already loaded by then.)
--
-- So the chosen fonts are asked for as soon as the addon loads, and the panel's text
-- is set afresh a few times in the seconds after login (ScheduleTextRedraw).
local fontLoader
function addon:PreloadFonts()
    if not fontLoader then
        fontLoader = CreateFrame("Frame", nil, UIParent)
        fontLoader:SetSize(1, 1)
        fontLoader:SetPoint("TOPLEFT")
        fontLoader:SetAlpha(0)
        fontLoader.strings = {}
    end
    local db = self.db
    local paths = { db.titleFont, db.categoryFont, db.itemFont }
    for i = 1, 3 do
        local fs = fontLoader.strings[i]
        if not fs then
            fs = fontLoader:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            fs:SetPoint("TOPLEFT")
            fontLoader.strings[i] = fs
        end
        self:ApplyFont(fs, paths[i], 12)
        fs:SetText("Ag")
    end
end

-- The game's quest tracker -/+ buttons (as on TrackerPlus), or the plain -/+ buttons
-- on a client without that art. Used by the roll-up button and category headers.
local function AtlasExists(atlas)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) ~= nil
end

local COLLAPSE_ATLAS = "UI-QuestTrackerButton-Secondary-Collapse"
local EXPAND_ATLAS = "UI-QuestTrackerButton-Secondary-Expand"
local HAS_TRACKER_ATLAS = AtlasExists(COLLAPSE_ATLAS) and AtlasExists(EXPAND_ATLAS)

function addon:SetCollapseArt(button, collapsed)
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

-- The same + art on a plain texture (the list's add rows).
function addon:SetPlusArt(texture)
    if HAS_TRACKER_ATLAS then
        texture:SetAtlas(EXPAND_ATLAS)
    else
        texture:SetTexture("Interface\\Buttons\\UI-PlusButton-Up")
    end
end

-------------------------------------------------------------------------------
-- Position and size
-------------------------------------------------------------------------------

-- Pins the panel's top-left corner where it is now. Anchoring by TOPLEFT means the
-- Width and Height sliders grow it down and to the right.
local function SetTopLeft(left, top)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    addon.db.position = { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = left, y = top }
end

local function SavePosition()
    local left, top = panel:GetLeft(), panel:GetTop()
    if left and top then SetTopLeft(left, top) end
    -- Moving marks the frame user-placed, which would have the client's layout cache
    -- restore it too; ours is the saved position that counts.
    if panel.IsUserPlaced and panel:IsUserPlaced() then panel:SetUserPlaced(false) end
end

local function RestorePosition()
    local pos = addon.db.position
    panel:ClearAllPoints()
    if type(pos) == "table" and pos.point and pos.x and pos.y then
        panel:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.x, pos.y)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

-- Saves a drag-resize as whole pixels. Sizing leaves the frame at a fractional size, so
-- the frame is snapped to the rounded values too, keeping what's shown and saved the same.
local function SaveDraggedSize()
    local width = math.floor(panel:GetWidth() + 0.5)
    local height = math.floor(panel:GetHeight() + 0.5)
    addon.db.width = width
    addon.db.height = height
    panel:SetSize(width, height)
end

-- What the mouse is doing to the panel: "move", "size" or nil.
local activeDrag = nil

function addon:StartPanelMove()
    if self.db.locked or activeDrag then return end
    activeDrag = "move"
    panel:StartMoving()
end

function addon:StopPanelMove()
    if activeDrag ~= "move" then return end
    activeDrag = nil
    panel:StopMovingOrSizing()
    SavePosition()
end

local function StopPanelSizing()
    if activeDrag ~= "size" then return end
    activeDrag = nil
    panel:StopMovingOrSizing()
    SaveDraggedSize()
    SavePosition()
    addon:RenderList()
    if addon.UpdateSettingWidgets then addon:UpdateSettingWidgets() end
end

-- A corner drag-to-resize grip. `flip` mirrors the art for the left corner.
local function CreateResizeGrip(corner, flip)
    local grip = CreateFrame("Button", nil, panel)
    grip:SetSize(16, 16)
    grip:SetPoint(corner)
    grip:SetFrameLevel(panel:GetFrameLevel() + 20)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    if flip then
        grip:GetNormalTexture():SetTexCoord(1, 0, 0, 1)
        grip:GetHighlightTexture():SetTexCoord(1, 0, 0, 1)
        grip:GetPushedTexture():SetTexCoord(1, 0, 0, 1)
    end
    grip:SetScript("OnMouseDown", function()
        if addon.db.locked or activeDrag then return end
        activeDrag = "size"
        panel:StartSizing(corner)
    end)
    grip:SetScript("OnMouseUp", StopPanelSizing)
    return grip
end

-------------------------------------------------------------------------------
-- Header
-------------------------------------------------------------------------------

-- A 16x16 header button `offsetX` from the header's right edge.
-- tooltipText() returns the tooltip title, plus an optional body line.
local function CreateChromeButton(offsetX, tooltipText)
    local btn = CreateFrame("Button", nil, panel)
    btn:SetSize(16, 16)
    btn:SetPoint("RIGHT", panel.header, "RIGHT", offsetX, 0)
    btn:SetFrameLevel(panel:GetFrameLevel() + 20)
    btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
    btn:SetScript("OnEnter", function(self)
        local title, body = tooltipText()
        local tooltip = addon:AcquireTooltip(self, "ANCHOR_RIGHT")
        tooltip:SetText(title)
        if body then
            tooltip:AddLine(body, 1, 1, 1, true)
        end
        tooltip:Show()
    end)
    btn:SetScript("OnLeave", function() addon:HideSharedTooltip() end)
    -- The header is a drag handle too; let it keep working over the buttons' gaps.
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function() addon:StartPanelMove() end)
    btn:SetScript("OnDragStop", function() addon:StopPanelMove() end)
    return btn
end

-- Re-shows a chrome button's tooltip after a click changed what it says.
local function RefreshTooltip(btn)
    if btn:IsMouseOver() then
        btn:GetScript("OnEnter")(btn)
    end
end

local function CreateHeader()
    local header = CreateFrame("Frame", nil, panel)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(HEADER_H)
    panel.header = header

    -- Chrome buttons, right to left: roll up, settings, lock, list switch.

    -- Roll up / down: the quest tracker's -/+ button, at TrackerPlus's size and spot.
    local rollBtn = CreateChromeButton(-5, function()
        if addon.db.rolledUp then
            return "Roll Down", "Show the list again."
        end
        return "Roll Up", "Hide the list, leaving just this title bar."
    end)
    rollBtn:SetSize(24, 24)
    rollBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    rollBtn:SetScript("OnClick", function(self)
        addon:SetRolledUp(not addon.db.rolledUp)
        RefreshTooltip(self)
    end)
    panel.rollBtn = rollBtn

    local settingsBtn = CreateChromeButton(-34, function() return "Open Settings" end)
    settingsBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    settingsBtn:SetScript("OnClick", function()
        if addon.OpenSettings then addon.OpenSettings() end
    end)
    panel.settingsBtn = settingsBtn

    -- Padlock: gold when locked, grey when unlocked (tinted by UpdatePanelLock).
    local lockBtn = CreateChromeButton(-54, function()
        if addon.db.locked then
            return "Unlock Panel", "Allow moving and resizing the panel."
        end
        return "Lock Panel", "Stop the panel from being moved or resized. The list can still be checked off and edited."
    end)
    local lockTex = lockBtn:CreateTexture(nil, "ARTWORK")
    lockTex:SetAllPoints()
    lockTex:SetTexture("Interface\\PetBattles\\PetBattle-LockIcon")
    lockBtn.icon = lockTex
    lockBtn:SetScript("OnClick", function(self)
        addon:SetLocked(not addon.db.locked)
        RefreshTooltip(self)
    end)
    panel.lockBtn = lockBtn

    -- List switch: "A" for the account-wide list, "C" for this character's.
    local listBtn = CreateChromeButton(-74, function()
        if addon:GetActiveListKey() == "character" then
            return "Character List", "Only this character sees this list.\nClick to show the account list, shared by all your characters."
        end
        return "Account List", "Shared by all your characters.\nClick to show this character's own list."
    end)
    local listText = listBtn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    listText:SetPoint("CENTER", 0, 0)
    listText:SetFont(FALLBACK_FONT, 13, "OUTLINE")
    listText:SetTextColor(1, 0.82, 0, 1)
    listBtn.text = listText
    listBtn:SetScript("OnClick", function(self)
        addon:ToggleActiveList()
        RefreshTooltip(self)
    end)
    panel.listBtn = listBtn

    -- The template is only a starting font: UpdatePanelAppearance applies the chosen one.
    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", header, "LEFT", 8, 0)
    title:SetPoint("RIGHT", listBtn, "LEFT", -4, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText(TITLE_TEXT)
    panel.title = title

    -- A faint rule under the title bar, between it and the list (hidden rolled up).
    local rule = header:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 1, 1, 0.12)
    rule:SetHeight(1)
    rule:SetPoint("BOTTOMLEFT", 6, 0)
    rule:SetPoint("BOTTOMRIGHT", -6, 0)
    panel.headerRule = rule
end

function addon:UpdateHeaderButtons()
    if not panel then return end
    panel.listBtn.text:SetText(self:GetActiveListKey() == "character" and "C" or "A")
end

-------------------------------------------------------------------------------
-- Lock, appearance, scroll room
-------------------------------------------------------------------------------

-- Locked: no moving or resizing. Unlike TrackerPlus the panel stays clickable, so
-- items can still be checked off and edited.
function addon:UpdatePanelLock()
    if not panel then return end
    local locked = self.db.locked
    -- Nothing to resize while rolled up, either.
    local canResize = not locked and not self.db.rolledUp
    panel.resizeBR:SetShown(canResize)
    panel.resizeBL:SetShown(canResize)
    if locked and activeDrag then
        if activeDrag == "move" then self:StopPanelMove() else StopPanelSizing() end
    end

    local lockTex = panel.lockBtn.icon
    lockTex:SetDesaturated(not locked)
    if locked then
        lockTex:SetVertexColor(1, 1, 1, 1)
    else
        lockTex:SetVertexColor(0.6, 0.6, 0.6, 1)
    end
end

-- The panel's height: the saved one, or just the title bar while rolled up.
local function PanelHeight()
    return addon.db.rolledUp and HEADER_H or addon.db.height
end

-- Drag-resizing can't make the panel smaller than this (it can't drag-resize at all
-- rolled up, but the limit is lowered then so it never fights the title-bar height).
local function SetMinimumSize(width, height)
    if panel.SetResizeBounds then
        panel:SetResizeBounds(width, height)
    elseif panel.SetMinResize then
        panel:SetMinResize(width, height)
    end
end

-- Rolled up: only the title bar shows, its top edge staying where it was (the panel
-- is anchored by its top-left corner). The saved height is kept for rolling back down.
function addon:UpdateRollUp()
    if not panel then return end
    local rolledUp = self.db.rolledUp

    if rolledUp then
        if activeDrag == "size" then StopPanelSizing() end
        if self.CancelInlineEdit then self:CancelInlineEdit() end
    end

    SetMinimumSize(MIN_WIDTH, rolledUp and HEADER_H or MIN_HEIGHT)
    panel:SetHeight(PanelHeight())
    scrollFrame:SetShown(not rolledUp)
    panel.headerRule:SetShown(not rolledUp)
    self:SetCollapseArt(panel.rollBtn, rolledUp)
    self:UpdatePanelLock() -- the resize grips

    self:UpdateEditMode()
    self:RenderList()
end

-- Background, border, size, scale and title font, from the settings.
function addon:UpdatePanelAppearance()
    if not panel then return end
    local db = self.db

    -- Background: Solid takes the Background color; textures keep their own colors.
    local bg = panel.bg
    local backgroundFile = self:ResolvePanelMedia("background", db.backgroundStyle)
    if self:IsSolidPanelMedia(backgroundFile) then
        bg:SetVertexColor(1, 1, 1, 1)
        local c = db.backgroundColor
        bg:SetColorTexture(c.r, c.g, c.b, c.a)
    else
        bg:SetTexture(backgroundFile)
        bg:SetHorizTile(false)
        bg:SetVertTile(false)
        bg:SetTexCoord(0, 1, 0, 1)
        bg:SetVertexColor(1, 1, 1, 1)
    end

    -- Border, pushed out so the inner edge of its art sits on the panel's edge.
    if db.borderEnabled then
        local border = panel.border
        if not border then
            border = CreateFrame("Frame", nil, panel, "BackdropTemplate")
            panel.border = border
        end
        border:SetFrameLevel(panel:GetFrameLevel() + 15)

        local borderFile, _, innerEdge = self:ResolvePanelMedia("border", db.borderStyle)
        local edgeSize = db.borderSize or 1
        local outset = math.floor(edgeSize * innerEdge + 0.5)
        border:ClearAllPoints()
        border:SetPoint("TOPLEFT", -outset, outset)
        border:SetPoint("BOTTOMRIGHT", outset, -outset)

        -- A new table each time: SetBackdrop ignores the table it already has.
        border:SetBackdrop({ edgeFile = borderFile, edgeSize = edgeSize })
        local color = self:IsSolidPanelMedia(borderFile) and db.borderColor or { r = 1, g = 1, b = 1, a = 1 }
        border:SetBackdropBorderColor(color.r, color.g, color.b, color.a)
        border:Show()
    elseif panel.border then
        panel.border:Hide()
    end

    -- Scale around the top-left corner, so the panel doesn't drift across the screen.
    local oldScale = panel:GetScale()
    local newScale = db.scale or 1
    if math.abs(oldScale - newScale) > 0.001 then
        local left, top = panel:GetLeft(), panel:GetTop()
        panel:SetScale(newScale)
        if left and top then
            SetTopLeft(left * oldScale / newScale, top * oldScale / newScale)
        end
    end

    if activeDrag ~= "size" then
        panel:SetSize(db.width, PanelHeight())
    end

    self:ApplyFont(panel.title, db.titleFont, db.titleFontSize)
    local c = db.titleColor
    panel.title:SetTextColor(c.r, c.g, c.b, c.a)
end

-- Makes room beside the list for the scroll bar, or gives it back. Returns true when
-- that changed the list's width.
function addon:SetScrollBarRoom(needed)
    if not scrollFrame then return false end
    needed = needed and true or false
    if scrollFrame.hasBarRoom == needed then return false end
    scrollFrame.hasBarRoom = needed
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -(needed and LIST_INSET_SCROLLBAR or LIST_INSET_PLAIN), 8)
    return true
end

-- Everything the settings control, applied at once (after a reset, say).
function addon:ApplyAllSettings()
    if not panel then return end
    self:UpdatePanelAppearance()
    panel:SetShown(not self.db.hidden)
    self:UpdateRollUp() -- also the lock state, edit mode and the list
    self:NotifyStateChanged()
end

-- Sets all of the panel's text afresh, in case a font finished loading after the
-- text was set (see PreloadFonts).
function addon:RedrawText()
    if not panel then return end
    self:ApplyFont(panel.title, self.db.titleFont, self.db.titleFontSize)
    panel.title:SetText("")
    panel.title:SetText(TITLE_TEXT)
    panel.listBtn.text:SetText("")
    self:UpdateHeaderButtons()
    self:RedrawListText()
end

-- After login. Font files usually arrive within a moment; the later passes are for
-- a slow disk.
local REDRAW_DELAYS = { 0.5, 2, 5 }

function addon:ScheduleTextRedraw()
    for _, delay in ipairs(REDRAW_DELAYS) do
        C_Timer.After(delay, function() addon:RedrawText() end)
    end
end

-------------------------------------------------------------------------------
-- Creation
-------------------------------------------------------------------------------

function addon:CreatePanel()
    if panel then return panel end

    panel = CreateFrame("Frame", "ToDoPlusFrame", UIParent)
    self.panel = panel
    panel:SetSize(self.db.width, PanelHeight())
    panel:SetScale(self.db.scale or 1)
    panel:SetFrameStrata("MEDIUM")
    panel:SetToplevel(true)
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:SetResizable(true)
    SetMinimumSize(MIN_WIDTH, MIN_HEIGHT) -- lowered by UpdateRollUp while rolled up
    -- Our own saved position is the one used, not the client's layout cache.
    if panel.SetDontSavePosition then panel:SetDontSavePosition(true) end
    RestorePosition()
    -- First run starts centered; pin that by the top-left corner like any other spot.
    if not self.db.position then SavePosition() end

    panel.bg = panel:CreateTexture(nil, "BACKGROUND")
    panel.bg:SetAllPoints()

    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function() addon:StartPanelMove() end)
    panel:SetScript("OnDragStop", function() addon:StopPanelMove() end)

    CreateHeader()

    scrollFrame = W.CreateScrollFrame(panel, "ToDoPlusScrollFrame")
    scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -(HEADER_H + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -LIST_INSET_PLAIN, 8)
    scrollFrame.hasBarRoom = false
    scrollFrame:EnableMouseWheel(true)
    if not scrollFrame:GetScript("OnMouseWheel") then
        scrollFrame:SetScript("OnMouseWheel", function(self, delta)
            local range = self:GetVerticalScrollRange()
            local value = self:GetVerticalScroll() - delta * 20
            self:SetVerticalScroll(math.max(0, math.min(range, value)))
        end)
    end
    self.scrollFrame = scrollFrame

    content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(MIN_WIDTH, 1)
    scrollFrame:SetScrollChild(content)
    self.listContent = content

    -- Wrapping depends on the width, and whether the scroll bar is needed on the height.
    scrollFrame:HookScript("OnSizeChanged", function() addon:RenderList() end)

    panel.resizeBR = CreateResizeGrip("BOTTOMRIGHT", false)
    panel.resizeBL = CreateResizeGrip("BOTTOMLEFT", true)

    panel:SetScript("OnShow", function()
        addon:UpdateEditMode()
        addon:RenderList()
    end)
    panel:SetScript("OnHide", function()
        if addon.CancelInlineEdit then addon:CancelInlineEdit() end
        if activeDrag == "move" then addon:StopPanelMove() elseif activeDrag == "size" then StopPanelSizing() end
    end)

    self:CreateListView(content)
    self:UpdatePanelAppearance()
    self:UpdateHeaderButtons()
    panel:SetShown(not self.db.hidden)
    self:UpdateRollUp() -- also the lock state, and draws the list unless rolled up
    self:NotifyStateChanged()

    return panel
end
