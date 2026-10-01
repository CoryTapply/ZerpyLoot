--[[
Appearance settings page: Font dropdown, moved here unchanged from the old
ConfigWindow (same saved key, same live-apply behavior).
]]

local FL = ForeverLoot;
local LSM = LibStub("LibSharedMedia-3.0");

local function mediaOptions(mediaType)
    local options = {};
    for _, key in ipairs(LSM:List(mediaType)) do
        table.insert(options, { value = key, label = key });
    end
    return options;
end

local COLUMN_WIDTH = 218;

FL.UI.SettingsWindow.RegisterPage("appearance", "Appearance", function(page)
    page:Header("Appearance");

    local section = page:Section("Display", 1);

    local fontDropdown = section:Dropdown{
        key = "appearance.font",
        label = "Font",
        options = mediaOptions("font"),
        default = FL.Theme.DEFAULT_FONT_KEY,
        width = COLUMN_WIDTH,
        x = 0,
        advance = false,
        rowHeight = 20,
        maxVisibleRows = 12,
        previewFont = function(key) return LSM:Fetch("font", key); end,
    };

    -- Status Bar Texture dropdown - not wired to anything right now (nothing
    -- in the addon consumes the saved value), kept here unregistered for
    -- reuse once something does. Needs a "key" (a PATHS entry + Settings
    -- getter/setter, see Core/Settings.lua) reconnected before use.
    --[[
    section:Dropdown{
        key = "appearance.statusbar",
        label = "Status Bar Texture",
        options = mediaOptions("statusbar"),
        default = LSM:GetDefault("statusbar"),
        width = COLUMN_WIDTH,
        x = COLUMN_WIDTH + 16,
        advance = false,
        rowHeight = 20,
        maxVisibleRows = 12,
        previewTexture = function(key) return LSM:Fetch("statusbar", key); end,
    };
    ]]

    section:AdvanceRow(fontDropdown.frame:GetHeight());

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
