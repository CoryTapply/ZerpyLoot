--[[
Persisted appearance settings (font, statusbar texture) backed by
LibSharedMedia-3.0. Values are stored by SharedMedia key (a name, not a
file path) so they keep resolving correctly even if another addon changes
what that key points to.
]]

local ZL = ZerpyLoot;
local Settings = ZL.Settings;
local LSM = LibStub("LibSharedMedia-3.0");

function Settings.Init()
    ZL.DB.settings = ZL.DB.settings or {};
    local s = ZL.DB.settings;

    s.font = s.font or LSM:GetDefault("font");
    s.statusbar = s.statusbar or LSM:GetDefault("statusbar");

    ZL.Theme.ApplyFont(s.font);
    ZL.Theme.RefreshStatusBars(s.statusbar);
end

-- ZL.DB isn't set until ADDON_LOADED fires, but UIDropDownMenu_Initialize
-- calls its init function once immediately at registration time - which
-- happens while this file's UI/OptionsPanel.lua is still loading, well
-- before that. Guard against ZL.DB being nil at that point.
function Settings.GetFont()
    return ZL.DB and ZL.DB.settings and ZL.DB.settings.font;
end

function Settings.SetFont(key)
    ZL.DB.settings.font = key;
    ZL.Theme.ApplyFont(key);
end

function Settings.GetStatusBarTexture()
    return ZL.DB and ZL.DB.settings and ZL.DB.settings.statusbar;
end

function Settings.SetStatusBarTexture(key)
    ZL.DB.settings.statusbar = key;
    ZL.Theme.RefreshStatusBars(key);
end

-- Last roll-off duration (seconds) entered in the roll window's start
-- prompt, re-used as the default the next time it's opened.
function Settings.GetRollOffSeconds()
    return ZL.DB and ZL.DB.settings and ZL.DB.settings.rollOffSeconds;
end

function Settings.SetRollOffSeconds(seconds)
    ZL.DB.settings.rollOffSeconds = seconds;
end

-- Roll window height (in UI units), set by dragging its bottom edge -
-- re-used as that window's height the next time it's created.
function Settings.GetRollWindowHeight()
    return ZL.DB and ZL.DB.settings and ZL.DB.settings.rollWindowHeight;
end

function Settings.SetRollWindowHeight(height)
    ZL.DB.settings.rollWindowHeight = height;
end

-- Trade queue window height (in UI units), set by dragging its bottom edge -
-- re-used as that window's height the next time it's created.
function Settings.GetTradeQueueWindowHeight()
    return ZL.DB and ZL.DB.settings and ZL.DB.settings.tradeQueueWindowHeight;
end

function Settings.SetTradeQueueWindowHeight(height)
    ZL.DB.settings.tradeQueueWindowHeight = height;
end

-- Window positions (x/y, the same CENTER-relative convention
-- Theme.CreateWindow's own x/y parameters use), set by dragging - re-used as
-- that window's position the next time it's created. Keyed by a short
-- per-window identifier (e.g. "rollWindow") rather than one field per window,
-- so resetting every window's position at once (see the /zl resetpositions
-- command) is a single table clear instead of one call per window.
function Settings.GetWindowPosition(key)
    local positions = ZL.DB and ZL.DB.settings and ZL.DB.settings.windowPositions;
    return positions and positions[key];
end

function Settings.SetWindowPosition(key, x, y)
    ZL.DB.settings.windowPositions = ZL.DB.settings.windowPositions or {};
    ZL.DB.settings.windowPositions[key] = { x = x, y = y };
end

function Settings.ClearWindowPosition(key)
    local positions = ZL.DB and ZL.DB.settings and ZL.DB.settings.windowPositions;
    if (positions) then positions[key] = nil; end
end

-- Whether ZerpyLoot's native Group Loot (Need/Greed/Pass) bars replace
-- Blizzard's default popup. Read once at login by GroupLootRoll.Init to
-- decide whether to suppress GroupLootFrame1..N, so toggling this requires
-- a /reload to take effect - same as every other structural setting here.
function Settings.GetGroupLootRollEnabled()
    local enabled = ZL.DB and ZL.DB.settings and ZL.DB.settings.groupLootRollEnabled;
    if (enabled == nil) then return true; end
    return enabled;
end

function Settings.SetGroupLootRollEnabled(enabled)
    ZL.DB.settings.groupLootRollEnabled = enabled and true or false;
end

-- Whether the Group Loot roll bars' draggable "Group Loot" anchor header is
-- locked - hidden (there's nothing left to drag once its position is set)
-- while the bars underneath keep stacking off wherever it was last left.
-- Unlike GroupLootRollEnabled above, this is read live by
-- GroupLootRollBars rather than only at login.
function Settings.GetGroupLootRollLocked()
    return (ZL.DB and ZL.DB.settings and ZL.DB.settings.groupLootRollLocked) and true or false;
end

function Settings.SetGroupLootRollLocked(locked)
    ZL.DB.settings.groupLootRollLocked = locked and true or false;
end
