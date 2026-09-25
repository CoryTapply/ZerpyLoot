--[[
Appearance settings page: Theme, Font, and Status Bar Texture dropdowns,
moved here unchanged from the old ConfigWindow (same saved keys, same
live-apply/reload-required behavior).
]]

local FL = ForeverLoot;
local LSM = LibStub("LibSharedMedia-3.0");

-- The theme is locked in at login (see Theme.Init), so picking a different
-- one only takes effect after a /reload.
StaticPopupDialogs["FOREVERLOOT_RELOAD_THEME"] = {
    text = "ForeverLoot's theme changes take effect after reloading your UI. Reload now?",
    button1 = "Reload UI",
    button2 = "Later",
    OnAccept = function() ReloadUI(); end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
};

local function themeOptions()
    local options = {};
    for _, key in ipairs(FL.Theme.THEME_ORDER) do
        table.insert(options, { value = key, label = FL.Theme.THEMES[key] });
    end
    return options;
end

local function mediaOptions(mediaType)
    local options = {};
    for _, key in ipairs(LSM:List(mediaType)) do
        table.insert(options, { value = key, label = key });
    end
    return options;
end

-- Theme/Font/Status Bar Texture sit in one 3-column row (218 wide each, 16
-- between) rather than stacked - Window Scale then reuses the same column
-- width one row down, left column. 3*218 + 2*16 = 686px, wider than the
-- 680px this page had to work with - Sizes.layout.settingsWindow.width was
-- widened by 20px (see Sizes.lua) so the row (plus its 14px right margin)
-- actually fits instead of clipping against the scroll frame's edge.
local COLUMN_WIDTH = 218;
local COLUMN_GAP = 16;

FL.UI.SettingsWindow.RegisterPage("appearance", "Appearance", function(page)
    page:Header("Appearance");

    local section = page:Section("Display", 1);

    local themeDropdown = section:Dropdown{
        key = "appearance.theme",
        label = "Theme",
        options = themeOptions(),
        default = FL.Theme.DEFAULT_THEME,
        width = COLUMN_WIDTH,
        x = 0,
        advance = false,
        rowHeight = 20,
        maxVisibleRows = 12,
        onChange = function(key)
            if (key ~= FL.Theme.current) then
                StaticPopup_Show("FOREVERLOOT_RELOAD_THEME");
            end
        end,
    };

    section:Dropdown{
        key = "appearance.font",
        label = "Font",
        options = mediaOptions("font"),
        default = FL.Theme.DEFAULT_FONT_KEY,
        width = COLUMN_WIDTH,
        x = COLUMN_WIDTH + COLUMN_GAP,
        advance = false,
        rowHeight = 20,
        maxVisibleRows = 12,
        previewFont = function(key) return LSM:Fetch("font", key); end,
    };

    section:Dropdown{
        key = "appearance.statusbar",
        label = "Status Bar Texture",
        options = mediaOptions("statusbar"),
        default = LSM:GetDefault("statusbar"),
        width = COLUMN_WIDTH,
        x = (COLUMN_WIDTH + COLUMN_GAP) * 2,
        advance = false,
        rowHeight = 20,
        maxVisibleRows = 12,
        previewTexture = function(key) return LSM:Fetch("statusbar", key); end,
    };

    section:AdvanceRow(themeDropdown.frame:GetHeight());

    -- Whole-window zoom (Pixel.SetGlobalScale, per-character) - a coarse
    -- escape hatch layered on top of the corrected base sizes in
    -- UI/Sizes.lua, not a replacement for them.
    section:Slider{
        key = "appearance.windowScale",
        label = "Window Scale",
        min = 0.8,
        max = 1.4,
        step = 0.05,
        default = 1.0,
        width = COLUMN_WIDTH,
        x = 0,
    };
end, 20);
