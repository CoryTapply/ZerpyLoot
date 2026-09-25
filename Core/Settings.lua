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
    -- Forward-looking safety net for future saved-variable migrations - no
    -- migration is needed yet, this just establishes the field.
    FL.DB.version = FL.DB.version or 1;

    FL.DB.settings = FL.DB.settings or {};
    local s = FL.DB.settings;

    s.font = s.font or FL.Theme.DEFAULT_FONT_KEY;
    s.statusbar = s.statusbar or LSM:GetDefault("statusbar");
    s.theme = FL.Theme.THEMES[s.theme] and s.theme or FL.Theme.DEFAULT_THEME;
    s.windowScale = s.windowScale or 1.0;

    s.lootCouncil = s.lootCouncil or {};
    local lc = s.lootCouncil;
    lc.includeOfficers = (lc.includeOfficers == true);
    lc.includeRaidLeader = (lc.includeRaidLeader == true);
    lc.officerRankThreshold = lc.officerRankThreshold or 1;

    -- The theme is what this session's windows get skinned with, so it's
    -- locked in here once (before any window exists) rather than re-read -
    -- changing the setting mid-session only takes effect after a /reload.
    FL.Theme.Init(FORCED_THEME or s.theme);
    FL.Theme.ApplyFont(s.font);
    FL.Theme.RefreshStatusBars(s.statusbar);
    FL.Pixel.SetGlobalScale(Settings.GetWindowScale());
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

-- Loot council "Review & Vote" window height (in UI units), set by dragging
-- its bottom edge - re-used as that window's height the next time it's created.
function Settings.GetLootCouncilReviewWindowHeight()
    return FL.DB and FL.DB.settings and FL.DB.settings.lootCouncilReviewWindowHeight;
end

function Settings.SetLootCouncilReviewWindowHeight(height)
    FL.DB.settings.lootCouncilReviewWindowHeight = height;
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

--------------------------------------------------------------------------
-- Loot Council settings page (UI/SettingsWindow/Pages/LootCouncil.lua)
--------------------------------------------------------------------------

-- Whether "Select Officers" (and any future auto-roster logic) always
-- includes guild officers at/under the officer rank threshold.
function Settings.GetIncludeGuildOfficers()
    return (FL.DB and FL.DB.settings and FL.DB.settings.lootCouncil and FL.DB.settings.lootCouncil.includeOfficers) and true or false;
end

function Settings.SetIncludeGuildOfficers(v)
    FL.DB.settings.lootCouncil.includeOfficers = v and true or false;
end

-- Whether "Select Officers" (and any future auto-roster logic) always
-- includes the current raid leader.
function Settings.GetIncludeRaidLeader()
    return (FL.DB and FL.DB.settings and FL.DB.settings.lootCouncil and FL.DB.settings.lootCouncil.includeRaidLeader) and true or false;
end

function Settings.SetIncludeRaidLeader(v)
    FL.DB.settings.lootCouncil.includeRaidLeader = v and true or false;
end

-- Guild rank index (0 = Guild Master, lower = higher rank) at or below which
-- a guild member counts as an "officer" for LootCouncilRoster.SelectOfficers.
function Settings.GetOfficerRankThreshold()
    local n = FL.DB and FL.DB.settings and FL.DB.settings.lootCouncil and FL.DB.settings.lootCouncil.officerRankThreshold;
    return n or 1;
end

function Settings.SetOfficerRankThreshold(n)
    FL.DB.settings.lootCouncil.officerRankThreshold = n;
end

-- Whole-window zoom (UI/SettingsWindow/Pages/Appearance.lua's "Window Scale"
-- slider), applied via Pixel.SetGlobalScale to every ForeverLoot window at
-- once. Stored account-wide (FL.DB.settings), like every other setting in
-- this file.
function Settings.GetWindowScale()
    return (FL.DB and FL.DB.settings and FL.DB.settings.windowScale) or 1.0;
end

function Settings.SetWindowScale(scale)
    FL.DB.settings.windowScale = scale;
    FL.Pixel.SetGlobalScale(scale);
end

--------------------------------------------------------------------------
-- Dotted-path accessors (UI/SettingsWindow/Widgets.lua's Section:Checkbox
-- and Section:Dropdown read/write settings by a "key" path string, e.g.
-- "loot.replacePopup", rather than calling a named getter/setter directly -
-- this table maps each known path onto the real getter/setter above without
-- moving or renaming any of them, so every other file that already calls
-- e.g. Settings.GetGroupLootRollEnabled() directly keeps working unchanged.
--------------------------------------------------------------------------

local PATHS = {
    ["appearance.theme"] = { get = Settings.GetTheme, set = Settings.SetTheme },
    ["appearance.font"] = { get = Settings.GetFont, set = Settings.SetFont },
    ["appearance.statusbar"] = { get = Settings.GetStatusBarTexture, set = Settings.SetStatusBarTexture },
    ["appearance.windowScale"] = { get = Settings.GetWindowScale, set = Settings.SetWindowScale },
    ["loot.replacePopup"] = { get = Settings.GetGroupLootRollEnabled, set = Settings.SetGroupLootRollEnabled },
    ["loot.lockRolls"] = { get = Settings.GetGroupLootRollLocked, set = Settings.SetGroupLootRollLocked },
    ["lootCouncil.includeOfficers"] = { get = Settings.GetIncludeGuildOfficers, set = Settings.SetIncludeGuildOfficers },
    ["lootCouncil.includeRaidLeader"] = { get = Settings.GetIncludeRaidLeader, set = Settings.SetIncludeRaidLeader },
    ["lootCouncil.officerRankThreshold"] = { get = Settings.GetOfficerRankThreshold, set = Settings.SetOfficerRankThreshold },
};

function Settings.GetPath(path)
    local entry = PATHS[path];
    return entry and entry.get();
end

function Settings.SetPath(path, value)
    local entry = PATHS[path];
    if (entry) then entry.set(value); end
end
