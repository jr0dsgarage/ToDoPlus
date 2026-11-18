---@diagnostic disable: undefined-global
local addonName, addon = ...
local W = addon.SettingsWidgets

-- Settings panel, built by hand like the other garage addons': a parent page plus
-- scrollable subpages of boxed sections.

local panel = CreateFrame("Frame", "ToDoPlusOptionsPanel")
panel.name = "ToDoPlus"

local function RefreshPanel()
    addon:UpdatePanelAppearance()
    addon:RenderList()
end

-------------------------------------------------------------------------------
-- Keeping widgets current
--
-- refreshers re-read each widget from the settings (they also change from the
-- panel's title bar, slash commands and drag-resizing). dependencies grey out
-- widgets a setting makes moot.
-------------------------------------------------------------------------------

local refreshers = {}
local dependencies = {}
local built = false

local function SetColorPickerEnabled(picker, enabled)
    if enabled then picker:Enable() else picker:Disable() end
    picker:SetAlpha(enabled and 1 or 0.4)
end

local function SetWidgetEnabled(widget, enabled)
    local kind = widget.todoKind
    if kind == "colorPicker" then
        SetColorPickerEnabled(widget, enabled)
    else
        widget:SetEnabled(enabled) -- checkboxes and sliders grey their own labels
        if widget.todoLabel then
            W.SetFontStringEnabled(widget.todoLabel, enabled)
        end
    end
end

-- isEnabled(db) decides whether the given widgets are usable.
local function AddDependency(isEnabled, ...)
    dependencies[#dependencies + 1] = { isEnabled = isEnabled, widgets = { ... } }
end

local function RefreshDependencies()
    for _, dependency in ipairs(dependencies) do
        local enabled = dependency.isEnabled(addon.db) and true or false
        for _, widget in ipairs(dependency.widgets) do
            SetWidgetEnabled(widget, enabled)
        end
    end
end

local function RefreshWidgets()
    for _, refresh in ipairs(refreshers) do refresh() end
    RefreshDependencies()
end

-- Only while a page is up: every page refreshes itself as it opens, and refreshing
-- re-reads the font lists, which isn't free.
local function AnyPageVisible()
    if panel:IsVisible() then return true end
    for _, page in ipairs(addon.settingsPageOrder or {}) do
        if page.frame:IsVisible() then return true end
    end
    return false
end

function addon:UpdateSettingWidgets()
    if built and AnyPageVisible() then RefreshWidgets() end
end

-------------------------------------------------------------------------------
-- Widgets. Each takes the running y offset inside its section and returns the
-- next offset plus the widget.
-------------------------------------------------------------------------------

-- Lights up `control`'s row while hovered and shows `title` and the wrapped `body`,
-- like a row of the game's Settings list. `top` is a label above the control, if any.
local function AttachTooltip(control, title, body, top)
    W.AttachHover(control, { title = title, body = body, top = top })
end

-- A setting's getter and setter by key; the setter runs onChange after saving.
local function KeyGet(key)
    return function() return addon.db[key] end
end

local function KeySet(key, onChange)
    return function(value)
        addon.db[key] = value
        if onChange then onChange(value) end
    end
end

local function CreateCheckbox(parent, text, name, tooltip, yOffset, get, set)
    local cb = W.CreateCheckbox(parent, addonName .. name .. "Check")
    cb:SetPoint("TOPLEFT", 16, yOffset)
    cb.Text:SetText(text)
    cb.todoKind = "checkbox"

    local function Refresh() cb:SetChecked(get() and true or false) end
    Refresh()
    refreshers[#refreshers + 1] = Refresh

    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        RefreshDependencies()
    end)
    AttachTooltip(cb, text, tooltip)

    return yOffset - 30, cb
end

-- Track length of every slider. Leaves room in a half-width column for the arrows
-- and the value beside them.
local SLIDER_WIDTH = 160

local function CreateSlider(parent, text, key, minVal, maxVal, step, tooltip, yOffset, onChange)
    local slider = W.CreateSlider(parent, {
        label = text, min = minVal, max = maxVal, step = step, width = SLIDER_WIDTH,
        decimals = step >= 1 and 0 or 2,
        value = addon.db[key] or minVal,
        onChange = function(value)
            addon.db[key] = value
            if onChange then onChange(value) end
            RefreshDependencies()
        end,
    })
    -- The label sits above, so this puts its top where a checkbox's would be
    slider:SetPoint("TOPLEFT", 16, yOffset - 18)
    slider.todoKind = "slider"

    -- silent: a refresh shows the stored value without saving it again
    refreshers[#refreshers + 1] = function() slider:SetValue(addon.db[key] or minVal, true) end
    AttachTooltip(slider, text, tooltip)

    return yOffset - 50, slider
end

local function CreateColorPicker(parent, text, key, yOffset, onChange)
    local container = CreateFrame("Button", nil, parent)
    container:SetSize(250, 24)
    container:SetPoint("TOPLEFT", 16, yOffset)
    container.todoKind = "colorPicker"

    local swatch = CreateFrame("Frame", nil, container)
    swatch:SetSize(20, 20)
    swatch:SetPoint("LEFT", 0, 0)

    local bg = swatch:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 1)

    local colorTex = swatch:CreateTexture(nil, "OVERLAY")
    colorTex:SetPoint("TOPLEFT", 1, -1)
    colorTex:SetPoint("BOTTOMRIGHT", -1, 1)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", swatch, "RIGHT", 5, 0)
    label:SetText(text)

    local function UpdateSwatch()
        local c = addon.db[key]
        if c then colorTex:SetColorTexture(c.r, c.g, c.b, c.a or 1) end
    end
    UpdateSwatch()
    refreshers[#refreshers + 1] = UpdateSwatch

    container:SetScript("OnClick", function()
        addon:OpenColorPicker(addon.db[key], function()
            UpdateSwatch()
            if onChange then onChange() end
        end)
    end)
    W.AttachHover(container)

    return yOffset - 30, container
end

-- Width of every dropdown's box; its previous / next buttons add ~60px around it.
local DROPDOWN_WIDTH = 180

-- The label above every dropdown. Returns the label and the dropdown's y offset.
local function CreateDropdownLabel(parent, text, yOffset)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 16, yOffset - 5)
    label:SetText(text)
    return label, yOffset - 20
end

local function FinishDropdown(dropdown, label, text, tooltip, yOffset)
    dropdown:SetPoint("TOPLEFT", 16, yOffset)
    dropdown.todoKind = "dropdown"
    dropdown.todoLabel = label
    refreshers[#refreshers + 1] = function() dropdown:Refresh() end
    AttachTooltip(dropdown, text, tooltip, label)
end

-- Dropdown over a { {text=, value=}, ... } list, or a function returning one.
local function CreateDropdown(parent, text, options, tooltip, yOffset, get, set)
    local label, dropdownY = CreateDropdownLabel(parent, text, yOffset)
    local dropdown = W.CreateChoiceDropdown(parent, DROPDOWN_WIDTH, options, get, function(value)
        set(value)
        RefreshDependencies()
    end)
    FinishDropdown(dropdown, label, text, tooltip, dropdownY)
    return yOffset - 55, dropdown
end

local function CreateButton(parent, text, width, tooltip, yOffset, onClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width, 25)
    btn:SetPoint("TOPLEFT", 16, yOffset)
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    if tooltip then AttachTooltip(btn, text, tooltip) end
    return yOffset - 35, btn
end

-- Wrapped explanatory text inside a section.
local function CreateNote(parent, text, yOffset, height)
    local note = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", 20, yOffset)
    note:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
    note:SetJustifyH("LEFT")
    note:SetText(text)
    return yOffset - (height or 30), note
end

-------------------------------------------------------------------------------
-- Fonts: every font we can find, each drawn in its own face in the menu, and
-- previewed on the panel while hovered. From TrackerPlus.
-------------------------------------------------------------------------------

-- Fonts every client ships, so the list is never empty without LibSharedMedia.
local BUILTIN_FONTS = {
    { "Friz Quadrata TT", "Fonts\\FRIZQT__.TTF" },
    { "Arial Narrow", "Fonts\\ARIALN.TTF" },
    { "Skurri", "Fonts\\SKURRI.TTF" },
    { "Morpheus", "Fonts\\MORPHEUS.TTF" },
}

local function NormalizeFontPath(path)
    return (path:lower():gsub("/", "\\"))
end

-- Font objects used to draw each menu entry in its own font, one per file. Also
-- doubles as a load test: false means the file wouldn't load, and such fonts are
-- left out of the list, since picking one would make the panel's text vanish.
local fontPreviewObjects = {}
local fontPreviewCount = 0
local function GetFontPreviewObject(path)
    local key = NormalizeFontPath(path)
    local obj = fontPreviewObjects[key]
    if obj == nil then
        fontPreviewCount = fontPreviewCount + 1
        obj = CreateFont(addonName .. "FontPreview" .. fontPreviewCount)
        -- Only an explicit false is a failure; a client that returns nothing
        -- from SetFont shouldn't lose every font.
        if obj:SetFont(path, 12, "") == false then obj = false end
        fontPreviewObjects[key] = obj
    end
    return obj or nil
end

-- Every font we can find, as a sorted { {name, path}, ... } list, deduplicated by
-- file. Built on demand so fonts registered by addons that loaded after us count:
--   * LibSharedMedia (if any addon loaded it): fonts other addons registered by name
--   * the built-in game fonts above
--   * every Font object in the UI (GetFonts), which picks up font files that
--     addons use without registering them; these are named after their file
local function GetAvailableFonts()
    local list, seen = {}, {}
    local function add(name, path)
        if type(path) ~= "string" or path == "" then return end
        local key = NormalizeFontPath(path)
        if seen[key] then return end
        seen[key] = true
        if not GetFontPreviewObject(path) then return end
        list[#list + 1] = { name = name, path = path }
    end

    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    if lsm then
        for _, name in ipairs(lsm:List("font")) do
            add(name, lsm:Fetch("font", name, true))
        end
    end

    for _, font in ipairs(BUILTIN_FONTS) do
        add(font[1], font[2])
    end

    if GetFonts then
        local ok, fontNames = pcall(GetFonts)
        if ok and type(fontNames) == "table" then
            for _, entry in ipairs(fontNames) do
                local obj = type(entry) == "string" and _G[entry] or entry
                if type(obj) == "table" and obj.GetFont then
                    local path = obj:GetFont()
                    if type(path) == "string" then
                        add(path:match("([^\\/]+)%.%w+$") or path, path)
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

local function GetFontDisplayName(path, fonts)
    if type(path) ~= "string" then return "Unknown" end
    local key = NormalizeFontPath(path)
    for _, font in ipairs(fonts or GetAvailableFonts()) do
        if NormalizeFontPath(font.path) == key then return font.name end
    end
    return path:match("([^\\/]+)%.%w+$") or path
end

-- Font dropdown. Hovering an entry previews it on the panel; leaving or closing the
-- menu puts the saved font back.
local function CreateFontDropdown(parent, text, key, tooltip, yOffset)
    local label, dropdownY = CreateDropdownLabel(parent, text, yOffset)

    -- The saved font while a hovered one is temporarily in the db; nil when not previewing.
    local previewOriginal
    local function EndPreview()
        if previewOriginal == nil then return end
        addon.db[key] = previewOriginal
        previewOriginal = nil
        RefreshPanel()
    end

    local function StartPreview(path)
        if previewOriginal == nil then previewOriginal = addon.db[key] end
        addon.db[key] = path
        RefreshPanel()
    end

    -- Checked against the saved font, not one being previewed.
    local function IsSelected(path)
        local current = previewOriginal or addon.db[key]
        return type(current) == "string" and NormalizeFontPath(current) == NormalizeFontPath(path)
    end

    local function SetSelected(path)
        previewOriginal = nil -- keep it: this is now the saved font
        addon.db[key] = path
        RefreshPanel()
    end

    local dropdown = W.CreateDropdown(parent, DROPDOWN_WIDTH, function(owner, rootDescription)
        local fonts = GetAvailableFonts()
        -- Shown when the saved font isn't in the list
        owner:SetDefaultText(GetFontDisplayName(previewOriginal or addon.db[key], fonts))
        for _, font in ipairs(fonts) do
            local radio = W.CreateFontRadio(rootDescription, font.name, GetFontPreviewObject(font.path), IsSelected, SetSelected, font.path)
            radio:SetOnEnter(function() StartPreview(font.path) end)
            radio:SetOnLeave(EndPreview)
        end
        W.LimitMenuHeight(rootDescription, #fonts)
    end)
    dropdown.Dropdown:RegisterCallback(DropdownButtonMixin.Event.OnMenuClose, EndPreview, dropdown)
    FinishDropdown(dropdown, label, text, tooltip, dropdownY)

    return yOffset - 55, dropdown
end

-------------------------------------------------------------------------------
-- Sections
-------------------------------------------------------------------------------

-- A boxed section. Anchored by its top corners only, so its height is whatever
-- EndSection sets.
local function StartSection(parent, title, yOffset)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOffset)
    frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -15, yOffset)

    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.4)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    label:SetPoint("TOPLEFT", 10, -10)
    label:SetText(title)

    return frame, -35
end

local function EndSection(frame, innerY)
    local height = math.abs(innerY) + 5
    frame:SetHeight(height)
    return height + 15
end

-- A section in one of two side-by-side columns (1 = left, 2 = right), each half of
-- the parent. Finish the pair with EndColumnRow.
local function StartColumnSection(parent, title, yOffset, column)
    local frame, innerY = StartSection(parent, title, yOffset)
    frame:ClearAllPoints()
    if column == 1 then
        frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOffset)
        frame:SetPoint("TOPRIGHT", parent, "TOP", -5, yOffset)
    else
        frame:SetPoint("TOPLEFT", parent, "TOP", 5, yOffset)
        frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -15, yOffset)
    end
    return frame, innerY
end

-- Ends a pair of column sections, matching their heights so the boxes line up.
local function EndColumnRow(left, leftInnerY, right, rightInnerY)
    local consumed = math.max(EndSection(left, leftInnerY), EndSection(right, rightInnerY))
    left:SetHeight(consumed - 15)
    right:SetHeight(consumed - 15)
    return consumed
end

-- Two invisible half-width columns inside a section, for rows of paired controls.
local function CreateColumns(section)
    local left = CreateFrame("Frame", nil, section)
    left:SetPoint("TOPLEFT", section, "TOPLEFT", 0, 0)
    left:SetPoint("TOPRIGHT", section, "TOP", -5, 0)
    left:SetHeight(1)
    local right = CreateFrame("Frame", nil, section)
    right:SetPoint("TOPLEFT", section, "TOP", 5, 0)
    right:SetPoint("TOPRIGHT", section, "TOPRIGHT", 0, 0)
    right:SetHeight(1)
    return left, right
end

-------------------------------------------------------------------------------
-- Pages
-------------------------------------------------------------------------------

local LIST_OPTIONS = {
    { text = "Account", value = "account" },
    { text = "Character", value = "character" },
}

local OUTLINE_OPTIONS = {
    { text = "None", value = "NONE" },
    { text = "Outline", value = "OUTLINE" },
    { text = "Thick Outline", value = "THICKOUTLINE" },
}

-- Dropdown options for a panel texture kind ("border" or "background").
local function GetPanelMediaOptions(kind)
    return function()
        local options = {}
        for i, entry in ipairs(addon:GetPanelMediaList(kind)) do
            options[i] = { text = entry.name, value = entry.name }
        end
        return options
    end
end

-- The color pickers only apply to Solid; textures are drawn in their own colors.
local function IsSolid(kind, name)
    return addon:IsSolidPanelMedia((addon:ResolvePanelMedia(kind, name)))
end

local function InitUI()
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("ToDoPlus")

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 2)
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local addonVersion = getMetadata and getMetadata(addonName, "Version")
    version:SetText(addonVersion and ("v" .. addonVersion) or "")

    ---------------------------------------------------------------------------
    -- Parent page
    ---------------------------------------------------------------------------
    local s, sy, left, leftY

    left, leftY = StartColumnSection(panel, "Panel", -45, 1)
    leftY = CreateCheckbox(left, "Show Panel", "shown",
        "Show the to-do list. Also toggled by /todo and the Titan Panel button.", leftY,
        function() return not addon.db.hidden end,
        function(checked) addon:SetPanelShown(checked) end)
    leftY = CreateCheckbox(left, "Lock Panel", "locked",
        "Stop the panel from being moved or resized. The list can still be checked off and edited. Also toggled by the padlock in the panel's title bar.", leftY,
        KeyGet("locked"),
        function(checked) addon:SetLocked(checked) end)
    leftY = CreateButton(left, "Reset All Settings", 150,
        "Put every setting back to its default and reload the UI. Your lists are kept.", leftY - 5,
        function() StaticPopup_Show("TODOPLUS_RESET_CONFIRM") end)

    s, sy = StartColumnSection(panel, "List", -45, 2)
    sy = CreateDropdown(s, "Active List", LIST_OPTIONS,
        "Which list the panel shows. The account list is shared by all your characters; each character also has a list of its own. Also switched by the A / C button in the panel's title bar.", sy,
        function() return addon:GetActiveListKey() end,
        function(value) addon:SetActiveList(value) end)
    sy = CreateDropdown(s, "Edit Modifier", addon.MODIFIERS,
        "Hold this key to show the + and remove buttons, and to rename things by clicking them.", sy,
        KeyGet("modifier"),
        KeySet("modifier", function()
            addon:UpdateEditMode()
            addon:RenderList()
        end))

    local consumed = EndColumnRow(left, leftY, s, sy)

    local overview = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    overview:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, -45 - consumed)
    overview:SetPoint("RIGHT", panel, "RIGHT", -24, 0)
    overview:SetJustifyH("LEFT")
    overview:SetSpacing(3)
    overview:SetText(
        "|cffffd100Using the list|r\n"
        .. "Click an item or its box to check it off. Click a category to collapse or expand it.\n"
        .. "Hold the Edit Modifier to edit: |cffffd100+|r rows add items and categories, and the red "
        .. "|cffff4040X|r after anything removes it. While holding it, click an item or category to rename it.\n"
        .. "In a text box, Enter saves (and stays open for the next item) and Escape cancels.\n\n"
        .. "|cffffd100Saving|r\n"
        .. "Lists are saved with your settings when you log out or /reload. Addons can't write files, "
        .. "so use Export on the List page to copy a list out as Markdown.\n\n"
        .. "|cffffd100Commands|r\n"
        .. "/todo shows or hides the list. /todo help lists the rest.")

    local orderedPages = {}

    local function CreateSettingsPage(id, pageTitle, pageDescription)
        local page = CreateFrame("Frame", "ToDoPlusOptionsPage" .. id)
        page.name = pageTitle
        page.parent = panel.name

        local titleText = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        titleText:SetPoint("TOPLEFT", 16, -16)
        titleText:SetText(pageTitle)

        local descText = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        descText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -8)
        descText:SetPoint("RIGHT", page, "RIGHT", -16, 0)
        descText:SetJustifyH("LEFT")
        descText:SetText(pageDescription or "")

        local scrollFrame = W.CreateScrollFrame(page, addonName .. "SettingsScrollFrame" .. id)
        scrollFrame:SetPoint("TOPLEFT", 5, -55)
        scrollFrame:SetPoint("BOTTOMRIGHT", -18, 4)

        local content = CreateFrame("Frame", nil, scrollFrame)
        content:SetSize(600, 100)
        scrollFrame:SetScrollChild(content)
        scrollFrame:SetScript("OnShow", function(self) self:SetVerticalScroll(0) end)
        page:HookScript("OnShow", RefreshWidgets)

        local pageInfo = { id = id, name = pageTitle, frame = page, content = content }
        table.insert(orderedPages, pageInfo)
        return pageInfo
    end

    local y

    ---------------------------------------------------------------------------
    -- Appearance
    ---------------------------------------------------------------------------
    local appearance = CreateSettingsPage("Appearance", "Appearance", "Panel size, background and border, fonts and colors.").content
    y = -5

    left, leftY = StartColumnSection(appearance, "Dimensions", y, 1)
    leftY = CreateSlider(left, "Width", "width", 160, 800, 1, "Width of the panel. Dragging a bottom corner of the panel changes it too.", leftY, RefreshPanel)
    leftY = CreateSlider(left, "Height", "height", 100, 1000, 1, "Height of the panel. Dragging a bottom corner of the panel changes it too.", leftY, RefreshPanel)
    leftY = CreateSlider(left, "Scale", "scale", 0.5, 2.0, 0.05, "Scale of the whole panel, text included.", leftY, RefreshPanel)

    local backgroundColorPicker, borderStyleDropdown, borderColorPicker, borderSizeSlider
    s, sy = StartColumnSection(appearance, "Panel Styling", y, 2)
    sy = CreateDropdown(s, "Background", GetPanelMediaOptions("background"),
        "The texture behind the list, stretched to fill it: Solid, the game's own backgrounds, or any other addons registered with LibSharedMedia.", sy,
        KeyGet("backgroundStyle"), KeySet("backgroundStyle", RefreshPanel))
    sy, backgroundColorPicker = CreateColorPicker(s, "Background Color", "backgroundColor", sy, RefreshPanel)
    sy = CreateCheckbox(s, "Show Border", "borderEnabled", "Draw a border around the panel.", sy,
        KeyGet("borderEnabled"), KeySet("borderEnabled", RefreshPanel))
    sy, borderStyleDropdown = CreateDropdown(s, "Border Style", GetPanelMediaOptions("border"),
        "The border drawn around the outside of the panel: the game's own borders, plus any other addons registered with LibSharedMedia. Picking one sets Border Size to suit it.", sy,
        KeyGet("borderStyle"),
        KeySet("borderStyle", function(name)
            -- Picking a border also sets Border Size to the size that texture is drawn for.
            local _, edgeSize = addon:ResolvePanelMedia("border", name)
            addon.db.borderSize = edgeSize
            RefreshWidgets()
            RefreshPanel()
        end))
    sy, borderColorPicker = CreateColorPicker(s, "Border Color", "borderColor", sy, RefreshPanel)
    sy, borderSizeSlider = CreateSlider(s, "Border Size", "borderSize", 1, 32, 1,
        "How thick the border is, in pixels; it grows outwards from the panel. Textured borders look best at the size picking them sets.", sy, RefreshPanel)
    AddDependency(function(db) return IsSolid("background", db.backgroundStyle) end, backgroundColorPicker)
    AddDependency(function(db) return db.borderEnabled end, borderStyleDropdown, borderSizeSlider)
    AddDependency(function(db) return db.borderEnabled and IsSolid("border", db.borderStyle) end, borderColorPicker)
    y = y - EndColumnRow(left, leftY, s, sy)

    -- Fonts: one row per kind of text, the font on the left and its size on the right.
    s, sy = StartSection(appearance, "Fonts", y)
    local fontLeft, fontRight = CreateColumns(s)
    local FONT_ROWS = {
        { "Title Font", "titleFont", "Title Size", "titleFontSize", 8, 32, "the \"To-Do List\" title" },
        { "Category Font", "categoryFont", "Category Size", "categoryFontSize", 8, 32, "category names" },
        { "Item Font", "itemFont", "Item Size", "itemFontSize", 8, 32, "to-do items" },
    }
    for _, row in ipairs(FONT_ROWS) do
        CreateFontDropdown(fontLeft, row[1], row[2], "Font used for " .. row[7] .. ". Lists every font available, including ones installed by other addons. Hover a font to preview it on the panel.", sy)
        CreateSlider(fontRight, row[3], row[4], row[5], row[6], 1, "Size of " .. row[7] .. ".", sy, RefreshPanel)
        sy = sy - 60
    end
    sy = CreateDropdown(fontLeft, "Outline", OUTLINE_OPTIONS, "Outline drawn around all of the panel's text.", sy,
        KeyGet("fontOutline"), KeySet("fontOutline", RefreshPanel))
    y = y - EndSection(s, sy)

    -- Colors, in two columns.
    s, sy = StartSection(appearance, "Colors", y)
    local colorLeft, colorRight = CreateColumns(s)
    local leftColorY = CreateColorPicker(colorLeft, "Title", "titleColor", sy, RefreshPanel)
    leftColorY = CreateColorPicker(colorLeft, "Categories", "categoryColor", leftColorY, RefreshPanel)
    local rightColorY = CreateColorPicker(colorRight, "Items", "itemColor", sy, RefreshPanel)
    rightColorY = CreateColorPicker(colorRight, "Completed Items", "doneColor", rightColorY, RefreshPanel)
    sy = math.min(leftColorY, rightColorY)
    sy = CreateNote(s, "Completed items are also struck through, in the Completed Items color.", sy, 20)
    y = y - EndSection(s, sy)

    appearance:SetHeight(math.abs(y) + 20)

    ---------------------------------------------------------------------------
    -- List
    ---------------------------------------------------------------------------
    local listPage = CreateSettingsPage("List", "List", "Copy the list out as Markdown, paste one in, or clear it out.").content
    y = -5

    local activeNote
    s, sy = StartSection(listPage, "Active List", y)
    sy, activeNote = CreateNote(s, "", sy, 36)
    refreshers[#refreshers + 1] = function()
        local done, total = addon:CountList()
        activeNote:SetText(string.format(
            "These act on the |cffffd100%s|r list, the one the panel is showing (%d of %d done). Switch lists on the main ToDoPlus page or with the A / C button in the panel's title bar.",
            addon:GetActiveListName():lower(), done, total))
    end
    y = y - EndSection(s, sy)

    left, leftY = StartColumnSection(listPage, "Markdown", y, 1)
    leftY = CreateButton(left, "Export as Markdown", 180,
        "Show the list as Markdown, ready to copy with Ctrl+C and paste into a .md file. Also /todo export.", leftY,
        function() addon:ShowMarkdownExport() end)
    leftY = CreateButton(left, "Import from Markdown", 180,
        "Paste a Markdown list in, to add to the list or replace it. \"## Name\" lines become categories and \"- [ ]\" / \"- [x]\" lines become items. Also /todo import.", leftY,
        function() addon:ShowMarkdownImport() end)

    s, sy = StartColumnSection(listPage, "Clean Up", y, 2)
    sy = CreateButton(s, "Clear Completed Items", 180, "Remove every checked item from the list.", sy, function()
        if addon.CancelInlineEdit then addon:CancelInlineEdit() end
        local removed = addon:ClearCompleted()
        addon:OnListChanged()
        addon:UpdateSettingWidgets()
        addon.Print(string.format("Removed %d completed %s.", removed, removed == 1 and "item" or "items"))
    end)
    sy = CreateButton(s, "Clear List", 180, "Remove every item and category from the list. Asks first.", sy, function()
        StaticPopup_Show("TODOPLUS_CLEAR_LIST", addon:GetActiveListName():lower())
    end)
    y = y - EndColumnRow(left, leftY, s, sy)

    listPage:SetHeight(math.abs(y) + 20)

    panel:HookScript("OnShow", RefreshWidgets)

    addon.settingsPageOrder = orderedPages
    addon.settingsPages = {}
    for _, page in ipairs(orderedPages) do
        addon.settingsPages[page.id] = page
    end

    -- Every widget read its value as it was made; only the greying is left to apply.
    built = true
    RefreshDependencies()
end

StaticPopupDialogs["TODOPLUS_RESET_CONFIRM"] = {
    text = "Reset all ToDoPlus settings to their defaults? Your lists are kept.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        addon:ResetDatabase()
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["TODOPLUS_CLEAR_LIST"] = {
    text = "Remove everything from your %s list? This can't be undone.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        if addon.CancelInlineEdit then addon:CancelInlineEdit() end
        addon:ClearList()
        addon:OnListChanged()
        addon:UpdateSettingWidgets()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local settingsLoaded = false
addon.settingsSubcategories = {}
local settingsFrame = CreateFrame("Frame")
settingsFrame:RegisterEvent("PLAYER_LOGIN")
settingsFrame:SetScript("OnEvent", function()
    if settingsLoaded then return end
    settingsLoaded = true

    if not addon.db then addon:InitDatabase() end
    InitUI()

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "ToDoPlus")
        Settings.RegisterAddOnCategory(category)
        addon.settingsCategory = category
        for _, page in ipairs(addon.settingsPageOrder) do
            addon.settingsSubcategories[page.id] = Settings.RegisterCanvasLayoutSubcategory(category, page.frame, page.name)
        end
    else
        InterfaceOptions_AddCategory(panel)
        for _, page in ipairs(addon.settingsPageOrder) do
            InterfaceOptions_AddCategory(page.frame)
        end
    end

    -- Opens a settings page by id (default: the parent page); used by /todo config,
    -- the panel's gear button and Shift-clicking the Titan Panel button.
    addon.OpenSettings = function(pageID)
        if Settings and Settings.OpenToCategory then
            local target = (pageID and addon.settingsSubcategories[pageID]) or addon.settingsCategory
            local id = target and target:GetID()
            if id then Settings.OpenToCategory(id) end
        elseif InterfaceOptionsFrame_OpenToCategory then
            local target = (pageID and addon.settingsPages[pageID] and addon.settingsPages[pageID].frame) or panel
            InterfaceOptionsFrame_OpenToCategory(target)
            InterfaceOptionsFrame_OpenToCategory(target)
        end
    end
end)
