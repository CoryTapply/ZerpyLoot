--[[
Engine for WoW's native Group Loot (Need/Greed/Pass) rolls - START_LOOT_ROLL
and friends. Entirely separate from RollTracker.lua's custom "/roll"-based
roll-off system: that one parses CHAT_MSG_SYSTEM text for real dice rolls and
never touches the client's own group-loot popup, which is what this file
tracks instead.

Seeing what OTHER players chose comes from C_LootHistory - the same API
ElvUI's own LootRoll.lua uses for exactly this (gated to non-Retail clients
there, since C_LootHistory's per-player roll history is a Classic-era
feature). Confirmed available on TBC Classic (this addon's own
## Interface: 20506, client 2.5.6) via Warcraft Wiki's
API_C_LootHistory.GetPlayerInfo page, which lists "BCC Anniversary" 2.5.6 as
supported.

TBC Classic's Group Loot only ever offers Need/Greed/Pass - Disenchant and
Transmog are Wrath+/Retail additions - so this only ever populates rollType
0 (pass), 1 (need) and 2 (greed).
]]

local ZL = ZerpyLoot;
local GroupLootRoll = ZL.GroupLootRoll;
local Util = ZL.Util;

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";

-- Keyed by rollID: { rollID, itemLink, itemIcon, itemName, quality, canNeed,
-- canGreed, duration, startedAt, votes = { [0]=passList, [1]=needList,
-- [2]=greedList } }, each vote list an array of { name, classFile }.
-- Exposed (not local) so UI/GroupLootRollBars.lua can read it directly,
-- same convention RollTracker.CurrentRollOff uses for RollWindow.lua.
GroupLootRoll.ActiveRolls = {};
local ActiveRolls = GroupLootRoll.ActiveRolls;

-- A LOOT_HISTORY_ROLL_CHANGED event for a given rollID can arrive slightly
-- before START_LOOT_ROLL has populated ActiveRolls[rollID] - the same race
-- ElvUI's LootRoll.lua guards against with its own cachedRolls table. Staged
-- here per rollID/rollType and drained the moment the roll actually appears.
local cachedRolls = {};

local function stashVote(rollID, rollType, name, classFile)
    local roll = ActiveRolls[rollID];
    if (roll) then
        roll.votes[rollType] = roll.votes[rollType] or {};
        table.insert(roll.votes[rollType], { name = name, classFile = classFile });

        if (ZL.UI.GroupLootRollBars.Refresh) then ZL.UI.GroupLootRollBars.Refresh(rollID); end
    else
        cachedRolls[rollID] = cachedRolls[rollID] or {};
        cachedRolls[rollID][rollType] = cachedRolls[rollID][rollType] or {};
        table.insert(cachedRolls[rollID][rollType], { name = name, classFile = classFile });
    end
end

local function drainCache(rollID)
    local cached = cachedRolls[rollID];
    if (not cached) then return; end

    local roll = ActiveRolls[rollID];
    for rollType, votes in pairs(cached) do
        roll.votes[rollType] = roll.votes[rollType] or {};
        for _, vote in ipairs(votes) do
            table.insert(roll.votes[rollType], vote);
        end
    end

    cachedRolls[rollID] = nil;
end

-- Frames we've already force-hidden, so repeat suppressDefaultFrames() calls
-- (see below) don't stack duplicate OnShow hooks on the same frame.
local hookedDefaultFrames = {};

-- Unregistering START_LOOT_ROLL/CANCEL_LOOT_ROLL only stops a frame reacting
-- to FUTURE events - it does nothing if something else (Blizzard's own
-- pooling code, another addon) calls :Show() on it directly, which is
-- exactly what a pooled/lazily-created frame can do the moment it's handed
-- a roll. Hooking OnShow->Hide catches that regardless of why Show() was
-- called, not just the two events we know about.
local function forceHideFrame(frame)
    frame:UnregisterEvent("START_LOOT_ROLL");
    frame:UnregisterEvent("CANCEL_LOOT_ROLL");
    frame:Hide();

    if (not hookedDefaultFrames[frame]) then
        hookedDefaultFrames[frame] = true;
        frame:HookScript("OnShow", frame.Hide);
    end
end

-- Prevents Blizzard's own Group Loot popup from ever appearing, so
-- ZerpyLoot's own bars are the only Group Loot UI shown - mirrors the user's
-- choice to fully replace the default popup rather than run alongside it.
--
-- Two different default UIs exist depending on client/version:
--  - The legacy popup: a fixed set of GroupLootFrame1..N globals
--    (NUM_GROUP_LOOT_FRAMES is the Blizzard FrameXML global for N), present
--    from login.
--  - The newer alert-based popup (Retail, and BCC Anniversary as of its
--    client updates): GroupLootContainer, which pools roll frames into
--    GroupLootContainer.rollFrames on demand - they may not exist yet at
--    login, only once the first roll actually happens. That's why this is
--    called again from onStartLootRoll below, not just once from Init.
local function suppressDefaultFrames()
    for i = 1, (NUM_GROUP_LOOT_FRAMES or 4) do
        local defaultFrame = _G["GroupLootFrame" .. i];
        if (defaultFrame) then forceHideFrame(defaultFrame); end
    end

    local container = _G.GroupLootContainer;
    if (container) then
        container:Hide();
        if (container.rollFrames) then
            for _, frame in ipairs(container.rollFrames) do forceHideFrame(frame); end
        end
    end
end

-- Thin wrapper so the UI layer never calls the raw WoW API directly - same
-- separation RollTracker/RollWindow keep between engine and UI.
function GroupLootRoll.RollOn(rollID, rollType)
    RollOnLoot(rollID, rollType);
end

-- rollIDs still pending a Need/Greed/Pass, persisted to SavedVariables so
-- they survive a /reload's fresh Lua state. Unlike everything else here this
-- is the one piece of roll state that MUST live in ZL.DB rather than a plain
-- local table - see restorePersistedRolls below for why the game doesn't
-- just re-fire START_LOOT_ROLL for us the way it does for a genuinely new
-- roll.
local function persistedRolls()
    ZL.DB.activeLootRolls = ZL.DB.activeLootRolls or {};
    return ZL.DB.activeLootRolls;
end

local function onStartLootRoll(rollID, rollTime)
    -- Self-heals against the pooled/lazily-created default frames described
    -- above suppressDefaultFrames - a fresh roll is exactly the moment such a
    -- frame would first come into existence.
    suppressDefaultFrames();

    local texture, name, _, quality, _, canNeed, canGreed = GetLootRollItemInfo(rollID);
    local itemLink = GetLootRollItemLink(rollID);

    ActiveRolls[rollID] = {
        rollID = rollID,
        itemLink = itemLink,
        itemIcon = texture or FALLBACK_ICON,
        itemName = name or itemLink or "",
        quality = quality,
        canNeed = canNeed,
        canGreed = canGreed,
        duration = rollTime,
        startedAt = GetTime(),
        votes = {},
    };
    persistedRolls()[rollID] = true;

    drainCache(rollID);

    if (ZL.UI.GroupLootRollBars.Acquire) then ZL.UI.GroupLootRollBars.Acquire(rollID); end
end

-- Single cleanup path for a roll that's no longer pending, whether it ended
-- normally (CANCEL_LOOT_ROLL) or GroupLootRollBars.lua's own OnUpdate safety
-- net caught it expiring without one - both need the same three things done
-- (drop the live state, drop the persisted-for-reload flag, hide the bar),
-- so neither has to duplicate the other's bookkeeping.
function GroupLootRoll.ClearActiveRoll(rollID)
    ActiveRolls[rollID] = nil;
    cachedRolls[rollID] = nil;
    persistedRolls()[rollID] = nil;

    if (ZL.UI.GroupLootRollBars.Release) then ZL.UI.GroupLootRollBars.Release(rollID); end
end

local function onCancelLootRoll(rollID)
    if (not ActiveRolls[rollID]) then return; end

    GroupLootRoll.ClearActiveRoll(rollID);
end

-- The client only fires START_LOOT_ROLL for a roll that's genuinely new, so
-- a roll already in progress before a /reload never gets it again - there's
-- also no "list current rolls" API to rediscover it blind (GetLootRollItemInfo
-- needs a rollID you already have). Rolling IDs aren't reset by /reload
-- though (confirmed via Warcraft Wiki's GetLootRollItemInfo page), so the
-- rollIDs stashed in persistedRolls() by onStartLootRoll are still valid to
-- query - GetLootRollTimeLeft on each tells us whether it's actually still
-- pending (survived the reload) or has since expired/resolved (stale entry
-- to drop). Run from PLAYER_ENTERING_WORLD rather than PLAYER_LOGIN since
-- that fires before the client has necessarily synced this roll's state back
-- from the server.
local function restorePersistedRolls()
    for rollID in pairs(persistedRolls()) do
        local timeLeft = GetLootRollTimeLeft(rollID);
        if (timeLeft and timeLeft > 0) then
            onStartLootRoll(rollID, timeLeft);
        else
            persistedRolls()[rollID] = nil;
        end
    end
end

local function onLootHistoryRollChanged(itemIdx, playerIdx)
    local name, classToken, rollType = C_LootHistory.GetPlayerInfo(itemIdx, playerIdx);
    local rollID = C_LootHistory.GetItem(itemIdx);
    if (not name or not rollID) then return; end

    stashVote(rollID, rollType, Util.stripRealm(name), classToken);
end

-- Clears any stale cached votes once the client considers every roll in this
-- batch resolved - LOOT_HISTORY_ROLL_COMPLETE/LOOT_ROLLS_COMPLETE both mean
-- the same thing here (mirrors ElvUI's ClearLootRollCache, aliased to both).
local function onLootRollsComplete()
    wipe(cachedRolls);
end

local eventFrame = CreateFrame("Frame");
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if (event == "START_LOOT_ROLL") then
        onStartLootRoll(...);
    elseif (event == "CANCEL_LOOT_ROLL") then
        onCancelLootRoll(...);
    elseif (event == "LOOT_HISTORY_ROLL_CHANGED") then
        onLootHistoryRollChanged(...);
    elseif (event == "PLAYER_ENTERING_WORLD") then
        restorePersistedRolls();
    else
        onLootRollsComplete();
    end
end);

function GroupLootRoll.Init()
    if (not ZL.Settings.GetGroupLootRollEnabled()) then return; end

    suppressDefaultFrames();

    -- GroupLootContainer_Update is what Blizzard calls whenever the pooled
    -- alert-based popup (see suppressDefaultFrames) acquires or lays out a
    -- roll frame - the same hook point ElvUI's AlertFrame.lua uses to
    -- reposition that container. Re-running suppression here catches a
    -- pooled frame the instant it's assigned, on top of the onStartLootRoll
    -- call below.
    if (_G.GroupLootContainer_Update) then
        hooksecurefunc("GroupLootContainer_Update", suppressDefaultFrames);
    end

    -- CANCEL_ALL_LOOT_ROLLS deliberately not registered - it's a Retail-only
    -- event (confirmed via ElvUI's own LootRoll.lua, which only registers it
    -- behind an E.Retail check).
    eventFrame:RegisterEvent("START_LOOT_ROLL");
    eventFrame:RegisterEvent("CANCEL_LOOT_ROLL");
    eventFrame:RegisterEvent("LOOT_HISTORY_ROLL_CHANGED");
    eventFrame:RegisterEvent("LOOT_HISTORY_ROLL_COMPLETE");
    eventFrame:RegisterEvent("LOOT_ROLLS_COMPLETE");
    -- Restores any roll still pending from before a /reload - see
    -- restorePersistedRolls above.
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD");
end
