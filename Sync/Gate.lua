--[[
Tracks instance, combat, encounter, loading-screen and guild-membership
state, and decides when automatic sync and guild award updates may run (spec
section 8). Nothing else in the addon tracked any of this before - this is
new infrastructure, built as its own dedicated event frame, matching the
"one small frame per concern" convention already used throughout this addon
(e.g. Trade.lua's watchFrame/sessionFrame) rather than a shared dispatcher,
since no shared dispatcher exists.

Reason precedence (not specified by the spec - derived here so a single
`reason` value can explain the sync, award-updates and group columns even when several
conditions are true at once):

    disabled > paused > noguild > encounter > loading > instance > combat > none

`disabled`/`paused` are the player's own setting (see userReason below) and
close sync only; award updates follow the environment reason underneath them.

Three gates, each "open", "closed"/"blocked", or "queued" (held):
  - sync: guild history sync sessions (Gate.CanSync).
  - awardUpdates: live award/pin/delete broadcasts to the guild (Sync/Live.lua),
    shown as "guild award updates" in the log. Allowed in instances and
    combat; held during encounters and loading screens; off without a guild.
  - group: RAID-scope sync (council session catch-up). Same as awardUpdates
    but open without a guild (computeGroup).

`instance` outranks `combat` deliberately: InCombatLockdown() flips on every
trash-pull boundary inside a dungeon, which would otherwise flap `reason`
between "combat" and "instance" every few seconds while sync stays closed
throughout regardless. `encounter` outranks both so a boss pull inside a
dungeon reports reason=encounter, not reason=instance.

OnChange(cb) is a plain array of callback functions fired in registration
order, not a CallbackHandler-1.0 embed - there's exactly one event here and
no unregistration need. CallbackHandler (vendored, used internally by
AceComm/LibSharedMedia) is a better fit for Store's EntryApplied in Phase 1,
which needs real named-event fan-out.
]]

local FL = ForeverLoot;
local Gate = FL.Sync.Gate;

local state = { inInstance = false, inCombat = false, inEncounter = false, loading = false, inGuild = true };
local lastReason, lastSync, lastAwardUpdates, lastGroup = nil, nil, nil, nil;
local heldQueue = {}; -- FIFO of { fn, label, queuedAt, gate = "awardUpdates"|"group" }
local onChangeCallbacks = {};
local combatResumeTimer;

local flushHeldQueue; -- forward declaration; defined below, used by recomputeAndMaybeLog

-- The player's own choice on the Sync settings page (UI/SettingsWindow/
-- Pages/Sync.lua): "disabled" (automatic sync turned off) or "paused" (off
-- until the next login - Core/Settings.lua clears it on an initial login,
-- not on a /reload). Either one closes sync only: award updates and the
-- RAID-scope council session keep following the environment reason.
local function userReason()
    local s = FL.DB and FL.DB.settings and FL.DB.settings.sync;
    if (not s) then return nil; end
    if (s.autoSync == false) then return "disabled"; end
    if (s.pausedThisLogin) then return "paused"; end
    return nil;
end

-- Everything except the player's own setting - what award
-- updates follow. `ignoreGuild` drops the noguild check: the "group"
-- gate below, for traffic that only goes to our own raid/party.
local function environmentReason(ignoreGuild)
    -- Also "noguild" until this login's guild history bucket is chosen
    -- (Data/Buckets.lua), so nothing syncs into the wrong guild's history.
    if (not ignoreGuild and not (state.inGuild and FL.Sync.Buckets.IsReady())) then return "noguild"; end
    if (state.inEncounter) then return "encounter"; end
    if (state.loading) then return "loading"; end
    if (state.inInstance) then return "instance"; end
    if (state.inCombat) then return "combat"; end
    return "none";
end

local function computeReason()
    return userReason() or environmentReason();
end

local SYNC_BY_REASON = { noguild = "closed", encounter = "closed", loading = "closed", instance = "closed", combat = "closed", none = "open" };
local AWARD_UPDATES_BY_REASON = { noguild = "blocked", encounter = "queued", loading = "queued", instance = "open", combat = "open", none = "open" };

local function computeSyncAndAwardUpdates(reason)
    local env = environmentReason();
    if (reason == "disabled" or reason == "paused") then
        return "closed", AWARD_UPDATES_BY_REASON[env];
    end
    return SYNC_BY_REASON[reason], AWARD_UPDATES_BY_REASON[reason];
end

-- The "group" gate: awardUpdates, except that not being in a guild doesn't
-- block it. RAID-scope sync (the council session catch-up) only talks to our own
-- raid/party, so a guildless pug can catch up too. Encounters and loading
-- screens still queue it, like awardUpdates.
local function computeGroup()
    return AWARD_UPDATES_BY_REASON[environmentReason(true)];
end

-- Gate reasons and states as log words.
local REASON_WORDS = {
    none = "all clear", instance = "in an instance", combat = "in combat", encounter = "in a boss fight",
    loading = "on a loading screen", noguild = "not in a guild", disabled = "sync turned off in settings",
    paused = "sync paused until next login",
};
local STATE_WORDS = { open = "on", closed = "off", queued = "held", blocked = "off" };

local function describeState(reason, sync, awardUpdates, group)
    return ("%s · history sync %s, guild award updates %s, council sync %s"):format(
        REASON_WORDS[reason] or tostring(reason), STATE_WORDS[sync] or tostring(sync),
        STATE_WORDS[awardUpdates] or tostring(awardUpdates), STATE_WORDS[group] or tostring(group));
end

local function recomputeAndMaybeLog(triggerEvent)
    local reason = computeReason();
    local sync, awardUpdates = computeSyncAndAwardUpdates(reason);
    local group = computeGroup();
    local changed = (reason ~= lastReason) or (sync ~= lastSync) or (awardUpdates ~= lastAwardUpdates) or (group ~= lastGroup);
    lastReason, lastSync, lastAwardUpdates, lastGroup = reason, sync, awardUpdates, group;

    if (changed) then
        FL.Sync.Debug.Log("GATE", 1, "%s", describeState(reason, sync, awardUpdates, group));
        if (group == "open") then flushHeldQueue(triggerEvent); end
        for _, cb in ipairs(onChangeCallbacks) do
            cb({ sync = sync, awardUpdates = awardUpdates, group = group, reason = reason });
        end
    end
end

local function gateOpen(gate)
    if (gate == "group") then return lastGroup == "open"; end
    return lastAwardUpdates == "open"; -- "awardUpdates"
end

local function queueOn(gate, fn, label)
    if (gateOpen(gate)) then
        fn();
        return;
    end
    table.insert(heldQueue, { fn = fn, label = label, queuedAt = GetTime(), gate = gate });
    FL.Sync.Debug.Log("GATE", 1, "holding %s until the %s gate opens · %s, %d waiting",
        label or "?", gate, REASON_WORDS[lastReason] or tostring(lastReason), #heldQueue);
end

-- Runs fn immediately if guild award updates are currently allowed,
-- otherwise holds it until CanSendAwardUpdates() becomes true again (e.g.
-- ENCOUNTER_END, or leaving a loading screen). Plain combat never blocks
-- award updates, so it never holds here.
function Gate.QueueAwardUpdate(fn, label)
    queueOn("awardUpdates", fn, label);
end

--- QueueAwardUpdate for the "group" gate (see computeGroup): RAID-scope sync sends.
function Gate.QueueGroup(fn, label)
    queueOn("group", fn, label);
end

-- Runs every queued entry whose own gate is open now, in queue order; the
-- rest stay queued (an "awardUpdates" entry while only "group" is open - no guild).
flushHeldQueue = function(triggerEvent)
    if (#heldQueue == 0) then return; end

    local flushing, keep = {}, {};
    for _, entry in ipairs(heldQueue) do
        table.insert(gateOpen(entry.gate) and flushing or keep, entry);
    end
    if (#flushing == 0) then return; end
    heldQueue = keep;

    local oldestQueuedAt = flushing[1].queuedAt;
    for _, entry in ipairs(flushing) do
        pcall(entry.fn);
    end

    local waited = GetTime() - oldestQueuedAt;
    FL.Sync.Debug.Log("GATE", 1, "released %d held message%s · after %s, oldest waited %s%s", #flushing,
        (#flushing == 1) and "" or "s", triggerEvent or "?", FL.Sync.Debug.FormatTime(waited),
        (#keep > 0) and (", " .. #keep .. " still held") or "");
end

-- Digest's self-test (Data/Digest.lua) failing "disables sync" per spec
-- section 5.1 - checked here, the single place every later phase already
-- asks before running any sync-y logic, rather than threading a second check
-- through every future caller. Award updates are unaffected
-- (CanSendAwardUpdates() doesn't consult this): a hash-function bug only matters for digest
-- comparisons, not for a plain award/delete/pin reaching the guild.
function Gate.CanSync()
    return lastSync == "open" and FL.Sync.Digest.SelfTestOK();
end

function Gate.CanSendAwardUpdates()
    return lastAwardUpdates == "open";
end

--- Whether RAID-scope sync may send right now (see computeGroup).
function Gate.CanGroup()
    return lastGroup == "open";
end

function Gate.OnChange(cb)
    table.insert(onChangeCallbacks, cb);
end

function Gate.Status()
    return { sync = lastSync, awardUpdates = lastAwardUpdates, group = lastGroup, reason = lastReason };
end

--- True while the player has automatic sync turned off or paused. Such a
--- client stays silent: no HELLO_ACK, and an incoming OPEN gets no reply at
--- all (see Sync/Session.lua's onOpen), not even a refusal.
function Gate.UserStopped()
    return userReason() ~= nil;
end

--- Recomputes after Data/Buckets.lua selects this login's history bucket
--- (Gate.Init runs before that, so it starts out reporting noguild).
function Gate.RefreshGuild()
    state.inGuild = IsInGuild();
    recomputeAndMaybeLog("historyBucket");
end

--- Re-reads the player's sync setting after the Sync settings page changes
--- it. Fires OnChange like any other transition, so open sessions abort
--- with reason=gate.
function Gate.RefreshUserSetting()
    recomputeAndMaybeLog("setting");
end

-- Unconditionally logs the current state line (still gated on debug/category
-- being on inside Debug.Log) - used at login and whenever debug is switched
-- on, so a dev always sees the current gate state right away even if it
-- hasn't changed recently.
function Gate.LogCurrentState()
    local reason = computeReason();
    local sync, awardUpdates = computeSyncAndAwardUpdates(reason);
    FL.Sync.Debug.Log("GATE", 1, "%s", describeState(reason, sync, awardUpdates, computeGroup()));
end

local function onEvent(_, event, ...)
    if (event == "PLAYER_REGEN_DISABLED") then
        state.inCombat = true;
    elseif (event == "PLAYER_REGEN_ENABLED") then
        if (combatResumeTimer) then combatResumeTimer:Cancel(); end
        combatResumeTimer = C_Timer.NewTimer(FL.Sync.Constants.COMBAT_RESUME_DELAY, function()
            state.inCombat = InCombatLockdown();
            recomputeAndMaybeLog(event);
        end);
        return; -- state.inCombat stays true until the delay above elapses
    elseif (event == "ENCOUNTER_START") then
        state.inEncounter = true;
    elseif (event == "ENCOUNTER_END") then
        state.inEncounter = false;
    elseif (event == "LOADING_SCREEN_ENABLED") then
        state.loading = true;
    elseif (event == "PLAYER_ENTERING_WORLD") then
        -- "Pause until next login" ends on a real login (including a
        -- disconnect relog), never on a /reload.
        local isInitialLogin = ...;
        if (isInitialLogin and FL.DB and FL.DB.settings and FL.DB.settings.sync) then
            FL.DB.settings.sync.pausedThisLogin = false;
        end
        state.loading = false;
        state.inInstance = IsInInstance();
    elseif (event == "ZONE_CHANGED_NEW_AREA") then
        state.inInstance = IsInInstance();
    elseif (event == "PLAYER_GUILD_UPDATE" or event == "GUILD_ROSTER_UPDATE") then
        state.inGuild = IsInGuild();
        FL.Sync.Buckets.Resolve(); -- the guild name may only now be known, or it changed
    end

    recomputeAndMaybeLog(event);
end

function Gate.Init()
    state.inInstance = IsInInstance();
    state.inCombat = InCombatLockdown();
    state.inGuild = IsInGuild();

    local frame = CreateFrame("Frame");
    frame:RegisterEvent("PLAYER_ENTERING_WORLD");
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA");
    frame:RegisterEvent("PLAYER_REGEN_DISABLED");
    frame:RegisterEvent("PLAYER_REGEN_ENABLED");
    frame:RegisterEvent("ENCOUNTER_START");
    frame:RegisterEvent("ENCOUNTER_END");
    frame:RegisterEvent("LOADING_SCREEN_ENABLED");
    frame:RegisterEvent("PLAYER_GUILD_UPDATE");
    frame:RegisterEvent("GUILD_ROSTER_UPDATE");
    frame:SetScript("OnEvent", onEvent);

    -- Compute the initial reason/sync/live state without the "changed" gate
    -- (lastReason etc. start nil, so recomputeAndMaybeLog would always log
    -- here anyway) and announce it once at login.
    recomputeAndMaybeLog("login");
end
