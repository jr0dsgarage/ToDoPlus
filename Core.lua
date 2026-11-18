---@diagnostic disable: undefined-global
local addonName, addon = ...

_G.ToDoPlus = addon

function addon.Print(...)
    print("|cff00ff00ToDoPlus:|r", ...)
end

function addon:AcquireTooltip(owner, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    return GameTooltip
end

function addon:HideSharedTooltip()
    GameTooltip:Hide()
end

-- Edits a {r,g,b,a} table in place; onChange runs on every change and on cancel.
function addon:OpenColorPicker(color, onChange)
    local original = { r = color.r, g = color.g, b = color.b, a = color.a }

    local function apply()
        color.r, color.g, color.b = ColorPickerFrame:GetColorRGB()
        color.a = ColorPickerFrame:GetColorAlpha()
        onChange()
    end

    ColorPickerFrame:SetupColorPickerAndShow({
        r = color.r or 1,
        g = color.g or 1,
        b = color.b or 1,
        opacity = color.a or 1,
        hasOpacity = true,
        swatchFunc = apply,
        opacityFunc = apply,
        cancelFunc = function()
            color.r, color.g, color.b, color.a = original.r, original.g, original.b, original.a
            onChange()
        end,
    })
end

-------------------------------------------------------------------------------
-- Edit modifier: holding it shows the + rows and the remove buttons.
-------------------------------------------------------------------------------

local MODIFIER_TESTS = {
    CTRL = function() return IsControlKeyDown() end,
    SHIFT = function() return IsShiftKeyDown() end,
    ALT = function() return IsAltKeyDown() end,
}

function addon:GetModifierName()
    local key = self.db and self.db.modifier
    return MODIFIER_TESTS[key] and key or "CTRL"
end

function addon:IsEditModifierDown()
    return MODIFIER_TESTS[self:GetModifierName()]() and true or false
end

-------------------------------------------------------------------------------
-- Things several places change: shown, locked, which list.
-------------------------------------------------------------------------------

-- Keeps everything that shows these settings in step: the panel's header, the
-- settings page and the Titan Panel button.
function addon:NotifyStateChanged()
    if self.UpdateHeaderButtons then self:UpdateHeaderButtons() end
    if self.UpdateSettingWidgets then self:UpdateSettingWidgets() end
    if self.UpdateBroker then self:UpdateBroker() end
end

function addon:IsPanelShown()
    return self.panel ~= nil and not self.db.hidden
end

function addon:SetPanelShown(shown)
    self.db.hidden = not shown
    if self.panel then self.panel:SetShown(shown) end
    self:NotifyStateChanged()
end

function addon:TogglePanel()
    self:SetPanelShown(self.db.hidden)
end

function addon:SetLocked(locked)
    self.db.locked = locked and true or false
    if self.UpdatePanelLock then self:UpdatePanelLock() end
    self:NotifyStateChanged()
end

-- "account" or "character"
function addon:SetActiveList(key)
    if key ~= "character" then key = "account" end
    if ToDoPlusCharDB.activeList == key then return end
    ToDoPlusCharDB.activeList = key
    if self.CancelInlineEdit then self:CancelInlineEdit() end
    self:OnListChanged()
    self:NotifyStateChanged()
end

function addon:ToggleActiveList()
    self:SetActiveList(self:GetActiveListKey() == "account" and "character" or "account")
end

-- Run after anything changes the active list's contents.
function addon:OnListChanged()
    if self.RenderList then self:RenderList() end
    if self.UpdateBroker then self:UpdateBroker() end
end

-------------------------------------------------------------------------------
-- Slash commands and startup
-------------------------------------------------------------------------------

local function RegisterSlashCommands()
    SLASH_TODOPLUS1 = "/todo"
    SLASH_TODOPLUS2 = "/todoplus"
    SlashCmdList.TODOPLUS = function(msg)
        local cmd = strtrim(msg or ""):lower()
        if cmd == "" or cmd == "toggle" then
            addon:TogglePanel()
        elseif cmd == "show" then
            addon:SetPanelShown(true)
        elseif cmd == "hide" then
            addon:SetPanelShown(false)
        elseif cmd == "lock" then
            addon:SetLocked(true)
        elseif cmd == "unlock" then
            addon:SetLocked(false)
        elseif cmd == "account" or cmd == "character" then
            addon:SetActiveList(cmd)
            addon.Print("Showing the " .. addon:GetActiveListName():lower() .. " list.")
        elseif cmd == "export" then
            addon:ShowMarkdownExport()
        elseif cmd == "import" then
            addon:ShowMarkdownImport()
        elseif cmd == "config" or cmd == "settings" or cmd == "options" then
            if addon.OpenSettings then addon.OpenSettings() end
        elseif cmd == "reset" then
            addon:ResetDatabase()
            addon.Print("Settings reset to defaults (your lists are kept). /reload to refresh the settings panel.")
            if addon.ApplyAllSettings then addon:ApplyAllSettings() end
        else
            addon.Print("/todo - show or hide the to-do list")
            addon.Print("/todo lock | unlock - stop or allow moving and resizing")
            addon.Print("/todo account | character - switch lists")
            addon.Print("/todo export | import - copy the list as Markdown, or paste one in")
            addon.Print("/todo config - open settings")
            addon.Print("/todo reset - reset all settings (lists are kept)")
        end
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then
            addon:InitDatabase()
            RegisterSlashCommands()
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        addon:CreatePanel()
        self:RegisterEvent("MODIFIER_STATE_CHANGED")
    elseif event == "MODIFIER_STATE_CHANGED" then
        addon:UpdateEditMode()
    end
end)
