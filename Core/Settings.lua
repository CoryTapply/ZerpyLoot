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
    lc.officerRankThreshold = lc.officerRankThreshold or 1;

    -- Loot Rolls > Chat section (LootChat.lua). Seeded here as plain data
    -- only - NOT through the Set* functions below, which also apply live
    -- chat-frame side effects that LootChat.Init() (which runs after this)
    -- isn't ready for yet.
    s.lootMessages = s.lootMessages or {};
    local lm = s.lootMessages;
    lm.enabled = (lm.enabled == nil) and true or (lm.enabled == true);
    lm.extraItems = lm.extraItems or {}; -- [itemID] = addedOrder
    lm.nextItemOrder = lm.nextItemOrder or 0;
    lm.hideBlizzardMain = (lm.hideBlizzardMain == nil) and true or (lm.hideBlizzardMain == true);
    lm.lootTab = (lm.lootTab == true);
    lm.removedLootFromMain = (lm.removedLootFromMain == true); -- true only if WE removed LOOT from ChatFrame1
    -- lm.lootTabFrameID intentionally left as whatever it already was (nil is fine).

    -- Loot Rolls > Automatic Rolls section (AutoRoll.lua) + the raid-entry
    -- popup (UI/AutoRollPopup.lua) + /fl autoroll. Plain data only, same
    -- reasoning as s.lootMessages above.
    s.autoRoll = s.autoRoll or {};
    local ar = s.autoRoll;
    ar.mode = (type(ar.mode) == "string") and ar.mode or "manual"; -- manual|need|greed|pass|ask
    ar.overrides = ar.overrides or {}; -- [itemID] = { rule = "need"|"greed"|"pass"|"manual", order = n }
    ar.nextOrder = ar.nextOrder or 1;
    ar.sessionChoices = ar.sessionChoices or {}; -- [instanceID] = "manual"|"need"|"greed"|"pass"

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

-- Whether the Loot Council Respond window animates a card fading out and
-- the rest sliding up when a raider answers a pending item, vs. an instant
-- snap. Read live by RespondWindow.Refresh (like GroupLootRollLocked
-- above), not cached at login.
function Settings.GetRespondAnimationEnabled()
    local enabled = FL.DB and FL.DB.settings and FL.DB.settings.respondAnimationEnabled;
    if (enabled == nil) then return true; end
    return enabled;
end

function Settings.SetRespondAnimationEnabled(enabled)
    FL.DB.settings.respondAnimationEnabled = enabled and true or false;
end

-- Last roll-off duration (seconds) entered in the roll window's start
-- prompt, re-used as the default the next time it's opened.
function Settings.GetRollOffSeconds()
    return FL.DB and FL.DB.settings and FL.DB.settings.rollOffSeconds;
end

function Settings.SetRollOffSeconds(seconds)
    FL.DB.settings.rollOffSeconds = seconds;
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
-- UI/GroupLootFrame.lua rather than only at login.
function Settings.GetGroupLootRollLocked()
    return (FL.DB and FL.DB.settings and FL.DB.settings.groupLootRollLocked) and true or false;
end

function Settings.SetGroupLootRollLocked(locked)
    FL.DB.settings.groupLootRollLocked = locked and true or false;
end

-- UI/AwardWindow.lua's "Jump to next unassigned after assigning" checkbox -
-- per-character (FL.DBChar, not FL.DB), since which raider is running the
-- council on a given character is a per-character preference, unlike every
-- other setting in this file. Defaults on.
function Settings.GetJumpToNextUnassigned()
    local enabled = FL.DBChar and FL.DBChar.awardWindowJumpToNextUnassigned;
    if (enabled == nil) then return true; end
    return enabled;
end

function Settings.SetJumpToNextUnassigned(enabled)
    FL.DBChar.awardWindowJumpToNextUnassigned = enabled and true or false;
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
-- Loot Rolls settings page (UI/SettingsWindow/Pages/LootRolls.lua), "Loot
-- Chat" section (LootChat.lua)
--------------------------------------------------------------------------

-- Whether LootChat.lua listens for CHAT_MSG_LOOT and prints "receives
-- loot"/"You receive loot" lines for items of green rarity or higher (plus
-- anything in extraItems below). Read live by LootChat's event handler.
function Settings.GetLootMessagesEnabled()
    return (FL.DB and FL.DB.settings and FL.DB.settings.lootMessages and FL.DB.settings.lootMessages.enabled) and true or false;
end

function Settings.SetLootMessagesEnabled(enabled)
    FL.DB.settings.lootMessages.enabled = enabled and true or false;
end

-- Below-Uncommon items the user wants printed anyway (e.g. quest items),
-- keyed by itemID -> the order they were added in (used to sort the item
-- list newest-first). Returns the live table, not a copy - callers (the
-- Loot Chat item list widget) iterate it read-only except through
-- Add/Remove/Clear below.
function Settings.GetLootExtraItems()
    return FL.DB and FL.DB.settings and FL.DB.settings.lootMessages and FL.DB.settings.lootMessages.extraItems or {};
end

function Settings.IsLootExtraItem(itemID)
    return itemID ~= nil and Settings.GetLootExtraItems()[itemID] ~= nil;
end

function Settings.AddLootExtraItem(itemID)
    local lm = FL.DB.settings.lootMessages;
    lm.nextItemOrder = (lm.nextItemOrder or 0) + 1;
    lm.extraItems[itemID] = lm.nextItemOrder;
end

function Settings.RemoveLootExtraItem(itemID)
    FL.DB.settings.lootMessages.extraItems[itemID] = nil;
end

function Settings.ClearLootExtraItems()
    wipe(FL.DB.settings.lootMessages.extraItems);
end

-- Hides "Item Loot" on ChatFrame1 (the main chat tab) when on, restoring it
-- when off - but only if WE were the one who removed it (see
-- removedLootFromMain below); a user who already had it off before enabling
-- this keeps it off after disabling it again. The actual chat-frame mutation
-- (and its combat-lockdown deferral) lives in LootChat.ApplyHideBlizzardMain.
function Settings.GetLootHideBlizzardMain()
    return (FL.DB and FL.DB.settings and FL.DB.settings.lootMessages and FL.DB.settings.lootMessages.hideBlizzardMain) and true or false;
end

function Settings.SetLootHideBlizzardMain(enabled)
    FL.DB.settings.lootMessages.hideBlizzardMain = enabled and true or false;
    FL.LootChat.ApplyHideBlizzardMain(enabled);
end

-- A dedicated "Loot" chat tab showing only Item Loot + Money Loot. The
-- actual chat-frame creation/adoption/close (and its combat-lockdown
-- deferral) lives in LootChat.ApplyLootTab.
function Settings.GetLootTabEnabled()
    return (FL.DB and FL.DB.settings and FL.DB.settings.lootMessages and FL.DB.settings.lootMessages.lootTab) and true or false;
end

function Settings.SetLootTabEnabled(enabled)
    FL.DB.settings.lootMessages.lootTab = enabled and true or false;
    FL.LootChat.ApplyLootTab(enabled);
end

-- Internal bookkeeping (not user-facing settings) - plain data accessors
-- only, no side effects, used by LootChat.lua to remember what IT changed
-- so it can be undone correctly later.
function Settings.GetLootRemovedFromMain()
    return (FL.DB and FL.DB.settings and FL.DB.settings.lootMessages and FL.DB.settings.lootMessages.removedLootFromMain) and true or false;
end

function Settings.SetLootRemovedFromMain(removed)
    FL.DB.settings.lootMessages.removedLootFromMain = removed and true or false;
end

function Settings.GetLootTabFrameID()
    return FL.DB and FL.DB.settings and FL.DB.settings.lootMessages and FL.DB.settings.lootMessages.lootTabFrameID;
end

function Settings.SetLootTabFrameID(frameID)
    FL.DB.settings.lootMessages.lootTabFrameID = frameID;
end

-- Directly clears the saved lootTab flag without running ApplyLootTab's
-- "on"/"off" logic - used only when LootChat's own PLAYER_LOGIN reconciler
-- finds the user closed the tab by hand (their action wins, nothing is
-- recreated) or ApplyLootTab itself fails to create one (no free windows).
function Settings.ForceLootTabDisabled()
    FL.DB.settings.lootMessages.lootTab = false;
    FL.DB.settings.lootMessages.lootTabFrameID = nil;
end

--------------------------------------------------------------------------
-- Loot Rolls settings page - "Automatic Rolls" section (AutoRoll.lua,
-- UI/AutoRollPopup.lua).
--------------------------------------------------------------------------

function Settings.GetAutoRollMode()
    return (FL.DB and FL.DB.settings and FL.DB.settings.autoRoll and FL.DB.settings.autoRoll.mode) or "manual";
end

function Settings.SetAutoRollMode(mode)
    FL.DB.settings.autoRoll.mode = mode;
end

-- Live table, not a copy - same convention as GetLootExtraItems.
function Settings.GetAutoRollOverrides()
    return (FL.DB and FL.DB.settings and FL.DB.settings.autoRoll and FL.DB.settings.autoRoll.overrides) or {};
end

function Settings.GetAutoRollOverride(itemID)
    local entry = itemID and Settings.GetAutoRollOverrides()[itemID];
    return entry and entry.rule;
end

function Settings.IsAutoRollOverride(itemID)
    return Settings.GetAutoRollOverride(itemID) ~= nil;
end

-- Changing an existing entry's rule keeps its original `order` (only a
-- brand-new entry consumes the next order number), so re-picking a
-- different rule on an item already in the list doesn't bump it to the
-- top of the sorted list.
function Settings.AddOrUpdateAutoRollOverride(itemID, rule)
    local ar = FL.DB.settings.autoRoll;
    local existing = ar.overrides[itemID];
    if (existing) then
        existing.rule = rule;
    else
        ar.overrides[itemID] = { rule = rule, order = ar.nextOrder };
        ar.nextOrder = ar.nextOrder + 1;
    end
end

function Settings.RemoveAutoRollOverride(itemID)
    FL.DB.settings.autoRoll.overrides[itemID] = nil;
end

function Settings.GetAutoRollSessionChoice(instanceID)
    local choices = FL.DB and FL.DB.settings and FL.DB.settings.autoRoll and FL.DB.settings.autoRoll.sessionChoices;
    return instanceID and choices and choices[instanceID];
end

function Settings.SetAutoRollSessionChoice(instanceID, choice)
    FL.DB.settings.autoRoll.sessionChoices[instanceID] = choice;
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
    ["appearance.enableRespondAnimation"] = { get = Settings.GetRespondAnimationEnabled, set = Settings.SetRespondAnimationEnabled },
    ["loot.replacePopup"] = { get = Settings.GetGroupLootRollEnabled, set = Settings.SetGroupLootRollEnabled },
    ["loot.lockRolls"] = { get = Settings.GetGroupLootRollLocked, set = Settings.SetGroupLootRollLocked },
    ["loot.chat.enabled"] = { get = Settings.GetLootMessagesEnabled, set = Settings.SetLootMessagesEnabled },
    ["loot.chat.hideBlizzardMain"] = { get = Settings.GetLootHideBlizzardMain, set = Settings.SetLootHideBlizzardMain },
    ["loot.chat.lootTab"] = { get = Settings.GetLootTabEnabled, set = Settings.SetLootTabEnabled },
    -- No real "value" of its own - reset-only path so "Reset This Page" can
    -- clear the extra-items list the same way it resets every other key
    -- (Settings.SetPath(key, default) with default=true; see LootRolls.lua).
    ["loot.chat.clearExtraItems"] = { get = function() return nil; end, set = function(v) if (v) then Settings.ClearLootExtraItems(); end end },
    ["autoRoll.mode"] = { get = Settings.GetAutoRollMode, set = Settings.SetAutoRollMode },
    -- Reset-only path - "Reset This Page" wipes sessionChoices but never
    -- overrides (clearing those would need its own confirm first).
    ["autoRoll.clearSessionChoices"] = {
        get = function() return nil; end,
        set = function(v) if (v) then wipe(FL.DB.settings.autoRoll.sessionChoices); end end,
    },
    ["lootCouncil.includeOfficers"] = { get = Settings.GetIncludeGuildOfficers, set = Settings.SetIncludeGuildOfficers },
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
