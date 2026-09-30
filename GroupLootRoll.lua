--[[
Engine for WoW's native Group Loot (Need/Greed/Transmog/Pass) rolls -
START_LOOT_ROLL and friends. Entirely separate from RollTracker.lua's custom
"/roll"-based roll-off system: that one parses CHAT_MSG_SYSTEM text for real
dice rolls and never touches the client's own group-loot popup, which is what
this file tracks instead.

Seeing what OTHER players chose comes from C_LootHistory's drop snapshots:
LOOT_HISTORY_UPDATE_DROP(encounterID, lootListKey) fires and
C_LootHistory.GetSortedInfoForDrop returns one drop in full, including every
player's choice (and their roll number for a Need). That replaces the old
per-player LOOT_HISTORY_ROLL_CHANGED events and C_LootHistory.GetPlayerInfo,
which no longer exist.

Each roll's votes are keyed by RollOnLoot's roll types - 0 pass, 1 need,
2 greed, 4 transmog - and each vote is { name, classFile, roll?, offSpec? }.
]]

local FL = ForeverLoot;
local GroupLootRoll = FL.GroupLootRoll;
local Util = FL.Util;

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";

-- Blizzard's own constant for how many default roll frames exist
-- (GroupLootFrame1..4) is a file-local, so it can't be read from here.
local NUM_DEFAULT_GROUP_LOOT_FRAMES = 4;

-- Keyed by rollID: { rollID, itemLink, itemIcon, itemName, itemCount, quality,
-- canNeed, canGreed, canTransmog, reasonNeed, reasonGreed, duration,
-- startedAt, lootHandle, dropKey, votes = { [0]=passList, [1]=needList,
-- [2]=greedList, [4]=transmogList } }, each vote list an array of
-- { name, classFile, roll?, offSpec? }. reasonNeed/reasonGreed are the
-- numeric LOOT_ROLL_INELIGIBLE_REASON<n> suffix for that option when its
-- matching canNeed/canGreed is false (meaningless otherwise).
-- Exposed (not local) so UI/GroupLootFrame.lua can read it directly, same
-- convention RollTracker.CurrentRollOff uses for RollWindow.lua.
GroupLootRoll.ActiveRolls = {};
local ActiveRolls = GroupLootRoll.ActiveRolls;

-- CANCEL_LOOT_ROLL can arrive for a rollID before onStartLootRoll below has
-- populated ActiveRolls[rollID]: an addon that auto-responds the instant
-- START_LOOT_ROLL fires (e.g. a WeakAura calling RollOnLoot straight from its
-- own START_LOOT_ROLL handler) can make the client fire CANCEL_LOOT_ROLL
-- before this addon's own frame gets its turn at START_LOOT_ROLL - both
-- events are dispatched synchronously to every registered frame in
-- registration order, so whichever addon's frame comes first can finish
-- responding (and trigger the cancel) first. Without this, onCancelLootRoll's
-- ActiveRolls check silently drops the cancel, onStartLootRoll then creates a
-- bar for a roll the player already responded to, and it's stuck on screen
-- (Need/Greed/Pass all now no-ops server-side) until the whole group roll's
-- timer runs out.
local earlyCancelledRolls = {};

-- Which active roll each history drop ("encounterID:lootListKey") has been
-- matched to. Nothing in the client ties a rollID to a history drop directly,
-- so the match is made once (see findRollForDrop) and remembered so later
-- updates to the same drop keep landing on the same roll.
local dropKeyToRollID = {};

-- Most recent encounterID seen via LOOT_HISTORY_UPDATE_DROP - lets
-- SyncFromHistory re-check just the one encounter a race could plausibly
-- involve (see its own comment) instead of every encounter this lockout.
local lastSeenEncounterID;

-- EncounterLootDropRollState -> RollOnLoot roll type. NoRoll (4, "hasn't
-- chosen yet") is deliberately absent: it's not a vote.
local DROP_STATE_TO_ROLL_TYPE = {
    [0] = 1, -- NeedMainSpec
    [1] = 1, -- NeedOffSpec
    [2] = 4, -- Transmog
    [3] = 2, -- Greed
    [5] = 0, -- Pass
};
local DROP_STATE_NEED_OFFSPEC = 1;

-- Frames we've already force-hidden, so repeat suppressDefaultFrames() calls
-- (see below) don't stack duplicate OnShow hooks on the same frame.
local hookedDefaultFrames = {};

-- Hiding a default roll frame once isn't enough - Blizzard's container calls
-- :Show() on one the moment it hands it a roll, and each frame registers its
-- own CANCEL_LOOT_ROLL/CANCEL_ALL_LOOT_ROLLS handlers on every OnShow. Hooking
-- OnShow->Hide catches that regardless of why Show() was called.
local function forceHideFrame(frame)
    frame:Hide();

    if (not hookedDefaultFrames[frame]) then
        hookedDefaultFrames[frame] = true;
        frame:HookScript("OnShow", frame.Hide);
    end
end

-- Prevents Blizzard's own Group Loot popup from ever appearing, so
-- ForeverLoot's own bars are the only Group Loot UI shown - mirrors the user's
-- choice to fully replace the default popup rather than run alongside it.
--
-- START_LOOT_ROLL reaches Blizzard's UI through its event router, which calls
-- GroupLootContainer_AddRoll; that opens one of the fixed GroupLootFrame1..4
-- globals and files it in GroupLootContainer.rollFrames. Those are the frames
-- hidden here. The container is shared with Blizzard's bonus roll frame, so
-- it (and that frame) are deliberately left alone - the container hides
-- itself once the roll frames are released (see GroupLootRoll.Init).
--
-- Called again from onStartLootRoll below, not just once from Init, since
-- container.rollFrames is only populated once a roll actually happens.
local function suppressDefaultFrames()
    for i = 1, NUM_DEFAULT_GROUP_LOOT_FRAMES do
        local defaultFrame = _G["GroupLootFrame" .. i];
        if (defaultFrame) then forceHideFrame(defaultFrame); end
    end

    local container = _G.GroupLootContainer;
    if (container and container.rollFrames) then
        for _, frame in pairs(container.rollFrames) do
            if (frame ~= _G.BonusRollFrame) then forceHideFrame(frame); end
        end
    end
end

-- Thin wrapper so the UI layer never calls the raw WoW API directly - same
-- separation RollTracker/RollWindow keep between engine and UI.
function GroupLootRoll.RollOn(rollID, rollType)
    RollOnLoot(rollID, rollType);
end

-- rollIDs FL.AutoRoll auto-rolled on the player's behalf, awaiting a possible
-- CONFIRM_LOOT_ROLL (e.g. Need on a Bind-on-Pickup item) that must bypass
-- GroupLootFrame.ShowConfirm's popup entirely - see onConfirmLootRoll below.
-- Owned entirely here; FL.AutoRoll never touches this set directly, only
-- calls RollOnAuto.
local pendingAuto = {};

--- Same as GroupLootRoll.RollOn, but flags rollID as auto-rolled first so a
--- CONFIRM_LOOT_ROLL for it skips the manual-click confirmation popup.
function GroupLootRoll.RollOnAuto(rollID, rollType)
    pendingAuto[rollID] = true;
    RollOnLoot(rollID, rollType);
end

-- Finalizes a roll that CONFIRM_LOOT_ROLL flagged as needing confirmation
-- (e.g. Need on a Bind-on-Pickup item) - ConfirmLootRoll is a separate global
-- from RollOnLoot (confirmed against Blizzard's own
-- StaticPopupDialogs["CONFIRM_LOOT_ROLL"].OnAccept), not a "confirmed"
-- argument to RollOnLoot itself.
function GroupLootRoll.ConfirmRoll(rollID, rollType)
    ConfirmLootRoll(rollID, rollType);
end

local function onStartLootRoll(rollID, rollTime, lootHandle)
    -- Self-heals against the default frames described above
    -- suppressDefaultFrames - a fresh roll is exactly the moment one would
    -- first be handed a roll.
    suppressDefaultFrames();

    -- Already tracking this roll (e.g. PLAYER_ENTERING_WORLD re-running the
    -- rehydrate below after a zone change) - nothing to redo.
    if (ActiveRolls[rollID]) then return; end

    -- Consume a cancel that raced ahead of this START_LOOT_ROLL (see
    -- earlyCancelledRolls above) - the roll's already resolved for us, so
    -- don't stand up a bar for it at all.
    if (earlyCancelledRolls[rollID]) then
        earlyCancelledRolls[rollID] = nil;
        return;
    end

    local texture, name, count, quality, _, canNeed, canGreed, _, reasonNeed, reasonGreed, _, _, canTransmog = GetLootRollItemInfo(rollID);
    local itemLink = GetLootRollItemLink(rollID);

    ActiveRolls[rollID] = {
        rollID = rollID,
        itemLink = itemLink,
        itemIcon = texture or FALLBACK_ICON,
        itemName = name or itemLink or "",
        itemCount = count,
        quality = quality,
        canNeed = canNeed,
        canGreed = canGreed,
        canTransmog = canTransmog,
        reasonNeed = reasonNeed,
        reasonGreed = reasonGreed,
        duration = rollTime,
        startedAt = GetTime(),
        lootHandle = lootHandle,
        votes = {},
    };

    -- FL.AutoRoll may decide to roll this on the player's behalf (an item
    -- override, or the raid's own auto-roll mode) - when it does, this roll
    -- never gets a UI row at all. Release is a safe no-op when no row exists
    -- yet (see UI/GroupLootFrame.lua's closeRow: it's a no-op unless the
    -- rollID is actually in `order`) - cheap insurance against a future
    -- reordering of this function, not something reachable today since
    -- Acquire hasn't run yet in this same call.
    if (FL.AutoRoll and FL.AutoRoll.HandleStartLootRoll and FL.AutoRoll.HandleStartLootRoll(rollID)) then
        if (FL.UI.GroupLootFrame.Release) then FL.UI.GroupLootFrame.Release(rollID); end
    elseif (FL.UI.GroupLootFrame.Acquire) then
        FL.UI.GroupLootFrame.Acquire(rollID);
    end

    -- The history drop for this roll may already exist (its update event can
    -- fire before START_LOOT_ROLL) - pick up whatever it already shows.
    GroupLootRoll.SyncFromHistory();
end

-- Single cleanup path for a roll that's no longer pending, whether it ended
-- normally (CANCEL_LOOT_ROLL) or UI/GroupLootFrame.lua's own OnUpdate safety
-- net caught it expiring without one - both need the same things done (drop
-- the live state, hide the bar), so neither has to duplicate the other's
-- bookkeeping.
function GroupLootRoll.ClearActiveRoll(rollID)
    local roll = ActiveRolls[rollID];
    if (roll and roll.dropKey) then dropKeyToRollID[roll.dropKey] = nil; end

    ActiveRolls[rollID] = nil;
    pendingAuto[rollID] = nil;

    if (FL.UI.GroupLootFrame.Release) then FL.UI.GroupLootFrame.Release(rollID); end
end

local function onCancelLootRoll(rollID)
    if (not ActiveRolls[rollID]) then
        -- Cancel arrived before this addon's own START_LOOT_ROLL handling -
        -- stash it so onStartLootRoll can skip creating a bar for it instead
        -- of silently dropping the cancel (see earlyCancelledRolls above).
        earlyCancelledRolls[rollID] = true;
        return;
    end

    GroupLootRoll.ClearActiveRoll(rollID);
end

-- Fired by the client when every pending roll is cancelled at once. Nothing
-- else would ever tell us those bars are stale.
local function onCancelAllLootRolls()
    local rollIDs = {};
    for rollID in pairs(ActiveRolls) do table.insert(rollIDs, rollID); end
    for _, rollID in ipairs(rollIDs) do GroupLootRoll.ClearActiveRoll(rollID); end

    wipe(earlyCancelledRolls);
end

-- The client only fires START_LOOT_ROLL for a roll that's genuinely new, so a
-- roll already in progress before a /reload never gets it again.
-- GetActiveLootRollIDs lists every roll still pending - Blizzard's own group
-- loot frame rehydrates from it the same way. Run from PLAYER_ENTERING_WORLD
-- rather than PLAYER_LOGIN since that fires before the client has necessarily
-- synced this roll's state back from the server.
local function restoreActiveRolls()
    for _, rollID in ipairs(GetActiveLootRollIDs()) do
        if (not ActiveRolls[rollID]) then
            -- The roll's full duration, i.e. what START_LOOT_ROLL's rollTime
            -- would have been.
            local duration = C_Loot.GetLootRollDuration(rollID);
            if (duration and duration > 0) then
                onStartLootRoll(rollID, duration);
            end
        end
    end
end

--------------------------------------------------------------------------
-- Loot history: one snapshot per drop
--------------------------------------------------------------------------

-- Finds which active roll a history drop belongs to. Nothing in the client
-- links a rollID to a drop's lootListKey, so: same item, not already matched
-- to another drop, and preferably the roll whose START_LOOT_ROLL lootHandle
-- equals the drop's lootListKey (an exact match if the client really uses one
-- as the other). Failing that, the earliest such roll - identical items
-- rolled at the same time resolve in the order they started.
local function findRollForDrop(lootListKey, itemLink)
    local itemID = Util.itemIDFromLink(itemLink);
    if (not itemID) then return nil; end

    local alreadyMatched = {};
    for _, matchedRollID in pairs(dropKeyToRollID) do alreadyMatched[matchedRollID] = true; end

    local best;
    for rollID, roll in pairs(ActiveRolls) do
        if (not alreadyMatched[rollID] and Util.itemIDFromLink(roll.itemLink) == itemID) then
            if (roll.lootHandle ~= nil and roll.lootHandle == lootListKey) then
                return rollID;
            end

            if (not best or roll.startedAt < ActiveRolls[best].startedAt) then
                best = rollID;
            end
        end
    end

    return best;
end

-- Replaces the matched roll's whole vote set from one drop snapshot (the
-- snapshot already contains every player's choice, so there's nothing to
-- append to).
local function applyDropInfo(encounterID, dropInfo)
    if (type(dropInfo) ~= "table" or not dropInfo.lootListKey) then return; end

    local key = encounterID .. ":" .. dropInfo.lootListKey;
    local rollID = dropKeyToRollID[key];

    if (not rollID or not ActiveRolls[rollID]) then
        -- A drop that already has a winner (or everyone passed) is history, not
        -- a live roll - never match one of those to a new roll, or an old drop
        -- of the same item could claim it.
        if (dropInfo.winner or dropInfo.allPassed) then return; end

        rollID = findRollForDrop(dropInfo.lootListKey, dropInfo.itemHyperlink);
        if (not rollID) then return; end

        dropKeyToRollID[key] = rollID;
        ActiveRolls[rollID].dropKey = key;
    end

    local votes = {};
    for _, rollInfo in ipairs(dropInfo.rollInfos or {}) do
        local rollType = DROP_STATE_TO_ROLL_TYPE[rollInfo.state];
        if (rollType) then
            votes[rollType] = votes[rollType] or {};
            table.insert(votes[rollType], {
                -- Full name (character-realm when Blizzard includes one),
                -- unlike the stripped name used elsewhere for matching -
                -- this is display-only (UI/GroupLootFrame.lua's tooltip),
                -- nothing here matches votes back to a player by name.
                name = rollInfo.playerName,
                classFile = rollInfo.playerClass,
                roll = rollInfo.roll,
                offSpec = (rollInfo.state == DROP_STATE_NEED_OFFSPEC) or nil,
            });
        end
    end

    ActiveRolls[rollID].votes = votes;
    if (FL.UI.GroupLootFrame.Refresh) then FL.UI.GroupLootFrame.Refresh(rollID); end
end

local function onLootHistoryUpdateDrop(encounterID, lootListKey)
    if (not encounterID or not lootListKey) then return; end
    lastSeenEncounterID = encounterID;
    applyDropInfo(encounterID, C_LootHistory.GetSortedInfoForDrop(encounterID, lootListKey));
end

--- Re-reads the current encounter's drops and applies them to the matching
--- active roll. Used when a roll starts (its drop may have been reported
--- before START_LOOT_ROLL, via onLootHistoryUpdateDrop above, at a time when
--- no active roll existed yet to match it to - see findRollForDrop's early
--- return). That race can only involve the encounter the raced drop actually
--- belongs to (lastSeenEncounterID), not encounters killed earlier tonight -
--- those are long since fully resolved and already reflected in ActiveRolls.
--- Scoping to just that one encounter keeps this O(dropsInOneEncounter)
--- instead of O(everyDropThisLockout), which otherwise grows with every boss
--- already killed tonight. pcall-wrapped: it's a best-effort catch-up, and a
--- failure here must never stop the roll's bar from appearing.
---
--- Falls back to a one-time full scan (setting lastSeenEncounterID as it
--- goes) when nothing's been seen yet this session - e.g. right after
--- /reload, when restoreActiveRolls needs to catch up rolls whose drops
--- were already recorded before this client ever saw a
--- LOOT_HISTORY_UPDATE_DROP event. Every SyncFromHistory call after that
--- first one takes the cheap scoped path above.
function GroupLootRoll.SyncFromHistory()
    pcall(function()
        if (lastSeenEncounterID) then
            for _, dropInfo in ipairs(C_LootHistory.GetSortedDropsForEncounter(lastSeenEncounterID) or {}) do
                applyDropInfo(lastSeenEncounterID, dropInfo);
            end
            return;
        end

        for _, encounter in ipairs(C_LootHistory.GetAllEncounterInfos() or {}) do
            lastSeenEncounterID = encounter.encounterID;
            for _, dropInfo in ipairs(C_LootHistory.GetSortedDropsForEncounter(encounter.encounterID) or {}) do
                applyDropInfo(encounter.encounterID, dropInfo);
            end
        end
    end);
end

-- Every roll in this batch is resolved, so any cancel we stashed for a roll
-- that never showed up is stale.
local function onLootRollsComplete()
    wipe(earlyCancelledRolls);
end

-- Fired synchronously from inside RollOnLoot (per Blizzard's own API docs)
-- when the roll just requested needs confirmation before it's actually sent
-- - e.g. Need on a Bind-on-Pickup item. The roll itself is untouched (no
-- CANCEL_LOOT_ROLL follows this), so the UI just needs to ask the player
-- and, on accept, call GroupLootRoll.ConfirmRoll to finish what RollOnLoot
-- started.
local function onConfirmLootRoll(rollID, rollType, confirmReason)
    -- An auto-rolled item's BoP confirm must never block on the player -
    -- bypass GroupLootFrame.ShowConfirm's popup entirely and finish the roll
    -- FL.AutoRoll already decided on. A roll the player clicked themselves is
    -- never in this set, so its own confirm popup is untouched.
    if (pendingAuto[rollID]) then
        pendingAuto[rollID] = nil;
        GroupLootRoll.ConfirmRoll(rollID, rollType);
        return;
    end

    if (FL.UI.GroupLootFrame.ShowConfirm) then
        FL.UI.GroupLootFrame.ShowConfirm(rollID, rollType, confirmReason);
    end
end

local eventFrame = CreateFrame("Frame");
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if (event == "START_LOOT_ROLL") then
        onStartLootRoll(...);
    elseif (event == "CANCEL_LOOT_ROLL") then
        onCancelLootRoll(...);
    elseif (event == "CANCEL_ALL_LOOT_ROLLS") then
        onCancelAllLootRolls();
    elseif (event == "LOOT_HISTORY_UPDATE_DROP") then
        onLootHistoryUpdateDrop(...);
    elseif (event == "PLAYER_ENTERING_WORLD") then
        restoreActiveRolls();
    elseif (event == "LOOT_ROLLS_COMPLETE") then
        onLootRollsComplete();
    elseif (event == "CONFIRM_LOOT_ROLL") then
        onConfirmLootRoll(...);
    end
end);

function GroupLootRoll.Init()
    -- Roll IDs used to be persisted here to survive a /reload; the client can
    -- list pending rolls itself now (see restoreActiveRolls), so drop any
    -- leftover saved copy.
    if (FL.DB) then FL.DB.activeLootRolls = nil; end

    if (not FL.Settings.GetGroupLootRollEnabled()) then return; end

    -- Shows the unlocked header/idle box immediately at login rather than
    -- only after the first roll of the session (GroupLootFrame otherwise
    -- only builds itself lazily, on the first Acquire).
    if (FL.UI.GroupLootFrame.Init) then FL.UI.GroupLootFrame.Init(); end

    suppressDefaultFrames();

    -- GroupLootContainer_AddFrame is where Blizzard hands a roll to one of
    -- the default frames. Hiding that frame (see forceHideFrame) leaves the
    -- container still believing the slot is occupied, so its bookkeeping
    -- grows with every roll; releasing the frame straight back keeps it
    -- empty - and lets the container hide itself, so we never have to force
    -- it hidden (which would take Blizzard's bonus roll frame down with it).
    -- Deferred a frame so it runs outside Blizzard's own call.
    hooksecurefunc("GroupLootContainer_AddFrame", function(container, frame)
        if (not hookedDefaultFrames[frame]) then return; end

        C_Timer.After(0, function()
            pcall(GroupLootContainer_RemoveFrame, container, frame);
        end);
    end);

    -- GroupLootContainer_Update is what Blizzard calls whenever the container
    -- acquires or lays out a roll frame. Re-running suppression here catches a
    -- frame the instant it's assigned, on top of the onStartLootRoll call.
    hooksecurefunc("GroupLootContainer_Update", suppressDefaultFrames);

    eventFrame:RegisterEvent("START_LOOT_ROLL");
    eventFrame:RegisterEvent("CANCEL_LOOT_ROLL");
    eventFrame:RegisterEvent("CANCEL_ALL_LOOT_ROLLS");
    eventFrame:RegisterEvent("LOOT_HISTORY_UPDATE_DROP");
    eventFrame:RegisterEvent("LOOT_ROLLS_COMPLETE");
    eventFrame:RegisterEvent("CONFIRM_LOOT_ROLL");
    -- Restores any roll still pending from before a /reload - see
    -- restoreActiveRolls above.
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD");
end
