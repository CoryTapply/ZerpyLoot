--[[
Persisted appearance settings (font, statusbar texture) backed by
LibSharedMedia-3.0. Values are stored by SharedMedia key (a name, not a
file path) so they keep resolving correctly even if another addon changes
what that key points to.
]]

local FL = ForeverLoot;
local Settings = FL.Settings;
local LSM = LibStub("LibSharedMedia-3.0");

-- TEMPORARY: forces this theme regardless of the saved setting (the saved
-- value isn't touched, so it comes back once this is set to nil). Set to nil
-- to revert to the normal saved/default theme behaviour.
local FORCED_THEME = "default";

function Settings.Init()
    FL.DB.settings = FL.DB.settings or {};
    local s = FL.DB.settings;

    s.font = s.font or LSM:GetDefault("font");
    s.statusbar = s.statusbar or LSM:GetDefault("statusbar");
    s.theme = FL.Theme.THEMES[s.theme] and s.theme or FL.Theme.DEFAULT_THEME;

    -- The theme is what this session's windows get skinned with, so it's
    -- locked in here once (before any window exists) rather than re-read -
    -- changing the setting mid-session only takes effect after a /reload.
    FL.Theme.Init(FORCED_THEME or s.theme);
    FL.Theme.ApplyFont(s.font);
    FL.Theme.RefreshStatusBars(s.statusbar);
end

-- FL.DB isn't set until ADDON_LOADED fires, but UIDropDownMenu_Initialize
-- calls its init function once immediately at registration time - which
-- happens while this file's UI/OptionsPanel.lua is still loading, well
-- before that. Guard against FL.DB being nil at that point.
function Settings.GetFont()
    return FL.DB and FL.DB.settings and FL.DB.settings.font;
end

function Settings.SetFont(key)
    FL.DB.settings.font = key;
    FL.Theme.ApplyFont(key);
end

-- UI theme key (see Theme.THEMES). Unlike font/statusbar this can't be
-- applied live - the default skin strips Blizzard's own button/frame art and
-- has no way to put it back - so the value saved here is picked up at the
-- next /reload (the options panel prompts for one).
function Settings.GetTheme()
    if (FORCED_THEME) then return FORCED_THEME; end

    local theme = FL.DB and FL.DB.settings and FL.DB.settings.theme;
    return (theme and FL.Theme.THEMES[theme]) and theme or FL.Theme.DEFAULT_THEME;
end

function Settings.SetTheme(key)
    FL.DB.settings.theme = key;
end

function Settings.GetStatusBarTexture()
    return FL.DB and FL.DB.settings and FL.DB.settings.statusbar;
end

function Settings.SetStatusBarTexture(key)
    FL.DB.settings.statusbar = key;
    FL.Theme.RefreshStatusBars(key);
end

-- Last roll-off duration (seconds) entered in the roll window's start
-- prompt, re-used as the default the next time it's opened.
function Settings.GetRollOffSeconds()
    return FL.DB and FL.DB.settings and FL.DB.settings.rollOffSeconds;
end

function Settings.SetRollOffSeconds(seconds)
    FL.DB.settings.rollOffSeconds = seconds;
end

-- Roll window height (in UI units), set by dragging its bottom edge -
-- re-used as that window's height the next time it's created.
function Settings.GetRollWindowHeight()
    return FL.DB and FL.DB.settings and FL.DB.settings.rollWindowHeight;
end

function Settings.SetRollWindowHeight(height)
    FL.DB.settings.rollWindowHeight = height;
end

-- Trade queue window height (in UI units), set by dragging its bottom edge -
-- re-used as that window's height the next time it's created.
function Settings.GetTradeQueueWindowHeight()
    return FL.DB and FL.DB.settings and FL.DB.settings.tradeQueueWindowHeight;
end

function Settings.SetTradeQueueWindowHeight(height)
    FL.DB.settings.tradeQueueWindowHeight = height;
end

-- Window positions (x/y, the same CENTER-relative convention
-- Theme.CreateWindow's own x/y parameters use), set by dragging - re-used as
-- that window's position the next time it's created. Keyed by a short
-- per-window identifier (e.g. "rollWindow") rather than one field per window,
-- so resetting every window's position at once (see the /zl resetpositions
-- command) is a single table clear instead of one call per window.
function Settings.GetWindowPosition(key)
    local positions = FL.DB and FL.DB.settings and FL.DB.settings.windowPositions;
    return positions and positions[key];
end

function Settings.SetWindowPosition(key, x, y)
    FL.DB.settings.windowPositions = FL.DB.settings.windowPositions or {};
    FL.DB.settings.windowPositions[key] = { x = x, y = y };
end

function Settings.ClearWindowPosition(key)
    local positions = FL.DB and FL.DB.settings and FL.DB.settings.windowPositions;
    if (positions) then positions[key] = nil; end
end

-- Whether ForeverLoot's native Group Loot (Need/Greed/Pass) bars replace
-- Blizzard's default popup. Read once at login by GroupLootRoll.Init to
-- decide whether to suppress GroupLootFrame1..N, so toggling this requires
-- a /reload to take effect - same as every other structural setting here.
function Settings.GetGroupLootRollEnabled()
    local enabled = FL.DB and FL.DB.settings and FL.DB.settings.groupLootRollEnabled;
    if (enabled == nil) then return true; end
    return enabled;
end

function Settings.SetGroupLootRollEnabled(enabled)
    FL.DB.settings.groupLootRollEnabled = enabled and true or false;
end

-- Whether the Group Loot roll bars' draggable "Group Loot" anchor header is
-- locked - hidden (there's nothing left to drag once its position is set)
-- while the bars underneath keep stacking off wherever it was last left.
-- Unlike GroupLootRollEnabled above, this is read live by
-- GroupLootRollBars rather than only at login.
function Settings.GetGroupLootRollLocked()
    return (FL.DB and FL.DB.settings and FL.DB.settings.groupLootRollLocked) and true or false;
end

function Settings.SetGroupLootRollLocked(locked)
    FL.DB.settings.groupLootRollLocked = locked and true or false;
end
