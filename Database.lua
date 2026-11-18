---@diagnostic disable: undefined-global
local addonName, addon = ...

local DB_VERSION = 1

-- The modifier keys that reveal the + and remove buttons, in dropdown order.
addon.MODIFIERS = {
    { text = "CTRL", value = "CTRL" },
    { text = "SHIFT", value = "SHIFT" },
    { text = "ALT", value = "ALT" },
}

-- Settings are account-wide; only the character list and which list is shown are
-- per character.
local DEFAULTS = {
    -- Behavior
    hidden = false,
    locked = false,
    modifier = "CTRL",

    -- Frame. position is { point, relativePoint, x, y }; unset centers the panel.
    width = 260,
    height = 320,
    scale = 1.0,

    -- Panel media (names resolved by UI/PanelMedia.lua, same keys as TrackerPlus)
    backgroundStyle = "Solid",
    backgroundColor = { r = 0, g = 0, b = 0, a = 0.7 },
    borderEnabled = false,
    borderStyle = "Solid",
    borderSize = 1,
    borderColor = { r = 1, g = 1, b = 1, a = 1 },

    -- Fonts (file paths)
    titleFont = "Fonts\\FRIZQT__.TTF",
    titleFontSize = 14,
    categoryFont = "Fonts\\FRIZQT__.TTF",
    categoryFontSize = 13,
    itemFont = "Fonts\\FRIZQT__.TTF",
    itemFontSize = 12,
    fontOutline = "NONE", -- "NONE", "OUTLINE", "THICKOUTLINE"

    -- Colors
    titleColor = { r = 1, g = 0.82, b = 0, a = 1 },
    categoryColor = { r = 1, g = 0.82, b = 0, a = 1 },
    itemColor = { r = 1, g = 1, b = 1, a = 1 },
    doneColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 },
}

local function DeepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = DeepCopy(v)
    end
    return copy
end
addon.DeepCopy = DeepCopy

-- Fills in missing keys, descending into nested tables (the colors).
local function MergeDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then
            target[key] = DeepCopy(value)
        elseif type(value) == "table" and type(target[key]) == "table" then
            MergeDefaults(target[key], value)
        end
    end
end

-------------------------------------------------------------------------------
-- Lists
--
-- Both lists share one shape:
--   { items = { {text=, done=}, ... },                   -- above the first category
--     categories = { {name=, collapsed=, items = {...}}, ... } }
-------------------------------------------------------------------------------

function addon:NewList()
    return { items = {}, categories = {} }
end

local function SanitizeItems(items)
    local clean = {}
    if type(items) == "table" then
        for _, item in ipairs(items) do
            if type(item) == "table" and type(item.text) == "string" then
                clean[#clean + 1] = { text = item.text, done = item.done == true }
            end
        end
    end
    return clean
end

-- Repairs a saved list that's missing pieces or was hand-edited into a bad shape.
local function SanitizeList(list)
    if type(list) ~= "table" then return addon:NewList() end
    local categories = {}
    if type(list.categories) == "table" then
        for _, category in ipairs(list.categories) do
            if type(category) == "table" and type(category.name) == "string" then
                categories[#categories + 1] = {
                    name = category.name,
                    collapsed = category.collapsed == true,
                    items = SanitizeItems(category.items),
                }
            end
        end
    end
    return { items = SanitizeItems(list.items), categories = categories }
end

function addon:InitDatabase()
    if type(ToDoPlusDB) ~= "table" then
        ToDoPlusDB = {}
    end
    ToDoPlusDB.version = DB_VERSION

    if type(ToDoPlusDB.settings) ~= "table" then
        ToDoPlusDB.settings = DeepCopy(DEFAULTS)
    else
        MergeDefaults(ToDoPlusDB.settings, DEFAULTS)
    end
    ToDoPlusDB.list = SanitizeList(ToDoPlusDB.list)

    if type(ToDoPlusCharDB) ~= "table" then
        ToDoPlusCharDB = {}
    end
    ToDoPlusCharDB.list = SanitizeList(ToDoPlusCharDB.list)
    if ToDoPlusCharDB.activeList ~= "character" then
        ToDoPlusCharDB.activeList = "account"
    end

    addon.db = ToDoPlusDB.settings
    addon.DEFAULTS = DEFAULTS
end

-- Settings only: the lists are never touched by a reset.
function addon:ResetDatabase()
    ToDoPlusDB.settings = DeepCopy(DEFAULTS)
    addon.db = ToDoPlusDB.settings
end

function addon:SetSetting(key, value)
    addon.db[key] = value
end

-- "account" or "character"
function addon:GetActiveListKey()
    return ToDoPlusCharDB and ToDoPlusCharDB.activeList or "account"
end

function addon:GetActiveListName()
    return self:GetActiveListKey() == "character" and "Character" or "Account"
end

function addon:GetActiveList()
    if self:GetActiveListKey() == "character" then
        return ToDoPlusCharDB.list
    end
    return ToDoPlusDB.list
end

-- Replaces the active list's contents in place, so references to it stay valid.
function addon:ReplaceActiveList(newList)
    local list = self:GetActiveList()
    newList = SanitizeList(newList)
    list.items = newList.items
    list.categories = newList.categories
end

-- Done and total item counts across the whole list.
function addon:CountList(list)
    list = list or self:GetActiveList()
    local done, total = 0, 0
    local function count(items)
        for _, item in ipairs(items) do
            total = total + 1
            if item.done then done = done + 1 end
        end
    end
    count(list.items)
    for _, category in ipairs(list.categories) do
        count(category.items)
    end
    return done, total
end

function addon:CountItems(items)
    local done = 0
    for _, item in ipairs(items) do
        if item.done then done = done + 1 end
    end
    return done, #items
end

-- Removes checked items everywhere in the active list. Returns how many went.
function addon:ClearCompleted()
    local list = self:GetActiveList()
    local removed = 0
    local function prune(items)
        for i = #items, 1, -1 do
            if items[i].done then
                table.remove(items, i)
                removed = removed + 1
            end
        end
    end
    prune(list.items)
    for _, category in ipairs(list.categories) do
        prune(category.items)
    end
    return removed
end

function addon:ClearList()
    self:ReplaceActiveList(self:NewList())
end
