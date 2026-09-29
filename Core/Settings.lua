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
    ar.mode = (type(ar.mode) == "string") and ar.mode or "ask"; -- manual|need|greed|pass|ask
    ar.overrides = ar.overrides or {}; -- [itemID] = { rule = "need"|"greed"|"pass"|"manual", order = n }
    ar.nextOrder = ar.nextOrder or 1;
    ar.sessionChoices = ar.sessionChoices or {}; -- [instanceID] = "manual"|"need"|"greed"|"pass"

    -- Announcements settings page > "Raid Chat" section. Each field gates
    -- one chat announcement/reply sent by SoftRes.lua / RollTracker.lua - see
    -- FL.Settings.GetRaidChat*/SetRaidChat* below for which. All default on.
    s.raidChat = s.raidChat or {};
    local rc = s.raidChat;
    rc.softresImported = (rc.softresImported == nil) and true or (rc.softresImported == true);
    rc.softresWhisperReply = (rc.softresWhisperReply == nil) and true or (rc.softresWhisperReply == true);
    rc.rollCountdown = (rc.rollCountdown == nil) and true or (rc.rollCountdown == true);
    rc.rollCountdownSeconds = rc.rollCountdownSeconds or 5;
    rc.lootCouncilAward = (rc.lootCouncilAward == nil) and true or (rc.lootCouncilAward == true);

    -- General settings page > "Sounds" section. Both events default on, and
    -- default to the sound each played before this section had per-event
    -- LSM pickers (see FL.Constants.SOUND_RAID_WARNING_KEY/SOUND_SONIC_RING_KEY).
    s.sounds = s.sounds or {};
    local snd = s.sounds;
    snd.raidWarning = (snd.raidWarning == nil) and true or (snd.raidWarning == true);
    snd.selfSR = (snd.selfSR == nil) and true or (snd.selfSR == true);
    snd.raidWarningSound = snd.raidWarningSound or FL.Constants.SOUND_RAID_WARNING_KEY;
    snd.selfSRSound = snd.selfSRSound or FL.Constants.SOUND_SONIC_RING_KEY;

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

-- Whether RollTracker.applyStart pops open UI/RollWindow.lua for a roll-off
-- started by someone else. Sounds still play regardless (see RollTracker.lua)
-- - this only controls whether the window itself appears. Read live, not
-- cached at login, same as GroupLootRollLocked above. Never consulted for a
-- roll-off we started ourselves (Message.isSelf), which always opens it.
function Settings.GetRollOffShowForOthers()
    local enabled = FL.DB and FL.DB.settings and FL.DB.settings.rollOffShowForOthers;
    if (enabled == nil) then return true; end
    return enabled;
end

function Settings.SetRollOffShowForOthers(enabled)
    FL.DB.settings.rollOffShowForOthers = enabled and true or false;
end

-- UI/AwardWindow.lua's "Jump to next unassigned after assigning" checkbox.
-- Defaults on.
function Settings.GetJumpToNextUnassigned()
    local enabled = FL.DB and FL.DB.settings and FL.DB.settings.awardWindowJumpToNextUnassigned;
    if (enabled == nil) then return true; end
    return enabled;
end

function Settings.SetJumpToNextUnassigned(enabled)
    FL.DB.settings.awardWindowJumpToNextUnassigned = enabled and true or false;
end

--------------------------------------------------------------------------
-- General settings page (UI/SettingsWindow/Pages/General.lua), "Sounds"
-- section. Both read live by RollTracker.lua right before it plays each
-- sound, not cached at login.
--------------------------------------------------------------------------

-- The raid-warning chime played when any roll-off starts.
function Settings.GetSoundRaidWarningEnabled()
    local enabled = FL.DB and FL.DB.settings and FL.DB.settings.sounds and FL.DB.settings.sounds.raidWarning;
    if (enabled == nil) then return true; end
    return enabled;
end

function Settings.SetSoundRaidWarningEnabled(enabled)
    FL.DB.settings.sounds.raidWarning = enabled and true or false;
end

-- Which sound plays for the event above - an LSM "sound" key, or
-- FL.Constants.SOUND_RAID_WARNING_KEY for Blizzard's built-in chime (see that
-- constant's own comment). Read by Util.playConfiguredSound via RollTracker.lua.
function Settings.GetSoundRaidWarningKey()
    local key = FL.DB and FL.DB.settings and FL.DB.settings.sounds and FL.DB.settings.sounds.raidWarningSound;
    return key or FL.Constants.SOUND_RAID_WARNING_KEY;
end

function Settings.SetSoundRaidWarningKey(key)
    FL.DB.settings.sounds.raidWarningSound = key;
end

-- The alert played instead of the raid-warning chime when a roll-off starts
-- for one of your own soft-reserved items.
function Settings.GetSoundSelfSREnabled()
    local enabled = FL.DB and FL.DB.settings and FL.DB.settings.sounds and FL.DB.settings.sounds.selfSR;
    if (enabled == nil) then return true; end
    return enabled;
end

function Settings.SetSoundSelfSREnabled(enabled)
    FL.DB.settings.sounds.selfSR = enabled and true or false;
end

-- Which sound plays for the event above - an LSM "sound" key (defaults to
-- our own bundled FL.Constants.SOUND_SONIC_RING_KEY).
function Settings.GetSoundSelfSRKey()
    local key = FL.DB and FL.DB.settings and FL.DB.settings.sounds and FL.DB.settings.sounds.selfSRSound;
    return key or FL.Constants.SOUND_SONIC_RING_KEY;
end

function Settings.SetSoundSelfSRKey(key)
    FL.DB.settings.sounds.selfSRSound = key;
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
    return (FL.DB and FL.DB.settings and FL.DB.settings.autoRoll and FL.DB.settings.autoRoll.mode) or "ask";
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
-- Announcements settings page (UI/SettingsWindow/Pages/Announcements.lua),
-- "Raid Chat" section. Each checkbox individually gates one chat
-- announcement/reply - see SoftRes.lua:300 (import), SoftRes.lua's
-- sendWhisperReply (soft-reserve whisper lookup), RollTracker.lua's
-- "N seconds to roll" countdown, and LootCouncil.lua's award/disenchant
-- announcements for the call sites these guard.
--------------------------------------------------------------------------

function Settings.GetRaidChatSoftresImportedEnabled()
    local rc = FL.DB and FL.DB.settings and FL.DB.settings.raidChat;
    if (rc == nil or rc.softresImported == nil) then return true; end
    return rc.softresImported == true;
end

function Settings.SetRaidChatSoftresImportedEnabled(enabled)
    FL.DB.settings.raidChat.softresImported = enabled and true or false;
end

function Settings.GetRaidChatSoftresWhisperReplyEnabled()
    local rc = FL.DB and FL.DB.settings and FL.DB.settings.raidChat;
    if (rc == nil or rc.softresWhisperReply == nil) then return true; end
    return rc.softresWhisperReply == true;
end

function Settings.SetRaidChatSoftresWhisperReplyEnabled(enabled)
    FL.DB.settings.raidChat.softresWhisperReply = enabled and true or false;
end

function Settings.GetRaidChatRollCountdownEnabled()
    local rc = FL.DB and FL.DB.settings and FL.DB.settings.raidChat;
    if (rc == nil or rc.rollCountdown == nil) then return true; end
    return rc.rollCountdown == true;
end

function Settings.SetRaidChatRollCountdownEnabled(enabled)
    FL.DB.settings.raidChat.rollCountdown = enabled and true or false;
end

-- How many seconds before a roll-off ends the "N seconds to roll" countdown
-- starts announcing in chat (counts down from this value to 1 in RollTracker
-- .lua's `for i = n, 1, -1` loop). Clamped to a sane range since it's read
-- straight off a free-typed EditBox.
function Settings.GetRaidChatRollCountdownSeconds()
    local rc = FL.DB and FL.DB.settings and FL.DB.settings.raidChat;
    return (rc and rc.rollCountdownSeconds) or 5;
end

function Settings.SetRaidChatRollCountdownSeconds(seconds)
    seconds = math.floor(tonumber(seconds) or 5);
    if (seconds < 1) then seconds = 1; end
    if (seconds > 30) then seconds = 30; end
    FL.DB.settings.raidChat.rollCountdownSeconds = seconds;
end

-- Gates both LootCouncil.lua award announcements ("<item> was awarded to
-- <player>!" and "<item> will be disenchanted!") behind a single checkbox.
function Settings.GetRaidChatLootCouncilAwardEnabled()
    local rc = FL.DB and FL.DB.settings and FL.DB.settings.raidChat;
    if (rc == nil or rc.lootCouncilAward == nil) then return true; end
    return rc.lootCouncilAward == true;
end

function Settings.SetRaidChatLootCouncilAwardEnabled(enabled)
    FL.DB.settings.raidChat.lootCouncilAward = enabled and true or false;
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
    ["loot.rollOff.showForOthers"] = { get = Settings.GetRollOffShowForOthers, set = Settings.SetRollOffShowForOthers },
    ["loot.chat.enabled"] = { get = Settings.GetLootMessagesEnabled, set = Settings.SetLootMessagesEnabled },
    ["loot.chat.hideBlizzardMain"] = { get = Settings.GetLootHideBlizzardMain, set = Settings.SetLootHideBlizzardMain },
    ["loot.chat.lootTab"] = { get = Settings.GetLootTabEnabled, set = Settings.SetLootTabEnabled },
    ["autoRoll.mode"] = { get = Settings.GetAutoRollMode, set = Settings.SetAutoRollMode },
    -- Reset-only path - "Reset This Page" wipes sessionChoices but never
    -- overrides (clearing those would need its own confirm first).
    ["autoRoll.clearSessionChoices"] = {
        get = function() return nil; end,
        set = function(v) if (v) then wipe(FL.DB.settings.autoRoll.sessionChoices); end end,
    },
    ["lootCouncil.includeOfficers"] = { get = Settings.GetIncludeGuildOfficers, set = Settings.SetIncludeGuildOfficers },
    ["lootCouncil.officerRankThreshold"] = { get = Settings.GetOfficerRankThreshold, set = Settings.SetOfficerRankThreshold },
    ["sounds.raidWarning"] = { get = Settings.GetSoundRaidWarningEnabled, set = Settings.SetSoundRaidWarningEnabled },
    ["sounds.raidWarningSound"] = { get = Settings.GetSoundRaidWarningKey, set = Settings.SetSoundRaidWarningKey },
    ["sounds.selfSR"] = { get = Settings.GetSoundSelfSREnabled, set = Settings.SetSoundSelfSREnabled },
    ["sounds.selfSRSound"] = { get = Settings.GetSoundSelfSRKey, set = Settings.SetSoundSelfSRKey },
    ["raidChat.softresImported"] = { get = Settings.GetRaidChatSoftresImportedEnabled, set = Settings.SetRaidChatSoftresImportedEnabled },
    ["raidChat.softresWhisperReply"] = { get = Settings.GetRaidChatSoftresWhisperReplyEnabled, set = Settings.SetRaidChatSoftresWhisperReplyEnabled },
    ["raidChat.rollCountdown"] = { get = Settings.GetRaidChatRollCountdownEnabled, set = Settings.SetRaidChatRollCountdownEnabled },
    ["raidChat.rollCountdownSeconds"] = { get = Settings.GetRaidChatRollCountdownSeconds, set = Settings.SetRaidChatRollCountdownSeconds },
    ["raidChat.lootCouncilAward"] = { get = Settings.GetRaidChatLootCouncilAwardEnabled, set = Settings.SetRaidChatLootCouncilAwardEnabled },
};

function Settings.GetPath(path)
    local entry = PATHS[path];
    return entry and entry.get();
end

function Settings.SetPath(path, value)
    local entry = PATHS[path];
    if (entry) then entry.set(value); end
end
