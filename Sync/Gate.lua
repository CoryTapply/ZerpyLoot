--[[
Tracks instance, combat, encounter, loading-screen and guild-membership
state, and decides when automatic sync and live broadcasts may run (spec
section 8). Nothing else in the addon tracked any of this before - this is
new infrastructure, built as its own dedicated event frame, matching the
"one small frame per concern" convention already used throughout this addon
(e.g. Trade.lua's watchFrame/sessionFrame) rather than a shared dispatcher,
since no shared dispatcher exists.

Reason precedence (not specified by the spec - derived here so a single
`reason` value can explain both the sync and live columns even when several
conditions are true at once):

    override > noguild > encounter > loading > instance > combat > none

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
local override = "auto"; -- "auto" | "open" | "closed"
local lastReason, lastSync, lastLive = nil, nil, nil;
local liveQueue = {}; -- FIFO of { fn, label, queuedAt }
local onChangeCallbacks = {};
local combatResumeTimer;

local flushLiveQueue; -- forward declaration; defined below, used by recomputeAndMaybeLog

local function computeReason()
    if (override ~= "auto") then return "override"; end
    if (not state.inGuild) then return "noguild"; end
    if (state.inEncounter) then return "encounter"; end
    if (state.loading) then return "loading"; end
    if (state.inInstance) then return "instance"; end
    if (state.inCombat) then return "combat"; end
    return "none";
end

local SYNC_BY_REASON = { noguild = "closed", encounter = "closed", loading = "closed", instance = "closed", combat = "closed", none = "open" };
local LIVE_BY_REASON = { noguild = "blocked", encounter = "queued", loading = "queued", instance = "open", combat = "open", none = "open" };

local function computeSyncLive(reason)
    if (reason == "override") then
        if (override == "closed") then return "closed", "blocked"; end
        return "open", "open"; -- override == "open"
    end
    return SYNC_BY_REASON[reason], LIVE_BY_REASON[reason];
end

local function recomputeAndMaybeLog(triggerEvent)
    local reason = computeReason();
    local sync, live = computeSyncLive(reason);
    local changed = (reason ~= lastReason) or (sync ~= lastSync) or (live ~= lastLive);
    lastReason, lastSync, lastLive = reason, sync, live;

    if (changed) then
        FL.Sync.Debug.Log("GATE", 1, "state sync=%s live=%s reason=%s", sync, live, reason);
        if (live == "open") then flushLiveQueue(triggerEvent); end
        for _, cb in ipairs(onChangeCallbacks) do
            cb({ sync = sync, live = live, reason = reason });
        end
    end
end

-- Runs fn immediately if live broadcasts are currently allowed, otherwise
-- queues it until CanLive() becomes true again (e.g. ENCOUNTER_END, or
-- leaving a loading screen). Plain combat never blocks live broadcasts, so
-- it never queues here.
function Gate.QueueLive(fn, label)
    if (lastLive == "open") then
        fn();
        return;
    end
    table.insert(liveQueue, { fn = fn, label = label, queuedAt = GetTime() });
    FL.Sync.Debug.Log("GATE", 1, "live queued n=%d label=%s reason=%s", #liveQueue, label or "?", lastReason);
end

flushLiveQueue = function(triggerEvent)
    if (#liveQueue == 0) then return; end

    local n = #liveQueue;
    local oldestQueuedAt = liveQueue[1].queuedAt;
    local flushing = liveQueue;
    liveQueue = {};

    for _, entry in ipairs(flushing) do
        pcall(entry.fn);
    end

    local waited = GetTime() - oldestQueuedAt;
    FL.Sync.Debug.Log("GATE", 1, "live flushed n=%d after=%s waited=%ds", n, triggerEvent or "?", math.floor(waited));
end

-- Digest's self-test (Data/Digest.lua) failing "disables sync" per spec
-- section 5.1 - checked here, the single place every later phase already
-- asks before running any sync-y logic, rather than threading a second check
-- through every future caller. Live broadcasts are unaffected (CanLive()
-- doesn't consult this): a hash-function bug only matters for digest
-- comparisons, not for a plain award/delete/pin reaching the guild.
function Gate.CanSync()
    return lastSync == "open" and FL.Sync.Digest.SelfTestOK();
end

function Gate.CanLive()
    return lastLive == "open";
end

function Gate.OnChange(cb)
    table.insert(onChangeCallbacks, cb);
end

function Gate.SetOverride(newOverride)
    newOverride = newOverride or "auto";
    if (newOverride ~= "auto" and newOverride ~= "open" and newOverride ~= "closed") then
        return;
    end
    override = newOverride;
    recomputeAndMaybeLog("override");
end

function Gate.Status()
    return { sync = lastSync, live = lastLive, reason = lastReason, override = override };
end

-- Unconditionally logs the current state line (still gated on debug/category
-- being on inside Debug.Log) - used at login and whenever debug is switched
-- on, so a dev always sees the current gate state right away even if it
-- hasn't changed recently.
function Gate.LogCurrentState()
    local reason = computeReason();
    local sync, live = computeSyncLive(reason);
    FL.Sync.Debug.Log("GATE", 1, "state sync=%s live=%s reason=%s", sync, live, reason);
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
        state.loading = false;
        state.inInstance = IsInInstance();
    elseif (event == "ZONE_CHANGED_NEW_AREA") then
        state.inInstance = IsInInstance();
    elseif (event == "PLAYER_GUILD_UPDATE" or event == "GUILD_ROSTER_UPDATE") then
        state.inGuild = IsInGuild();
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
