--[[
Login, periodic and instance-exit discovery triggers (spec sections 7.2,
7.5), plus - once Sync/Peers.lua's Discover collects responders for a
scope - choosing a primary (and, as of Phase 6, up to MAX_SECONDARIES
secondaries) for each mismatched "set" domain and handing both to
Sync/Session.lua (spec 7.3-7.4).

Deviation: the candidate selection here (who's the primary, who are the
secondaries) no longer logs its own "[SESS] plan ..." line - moved to
Sync/Session.lua's assignBucketsWithSecondaries, which is the only place
that knows the REAL per-peer bucket counts (spec's own sample line includes
"assign B=4 C=3 D=3"), known only once the primary's compare phase finishes.
Logging it here too, before that's known, would just be a second, less
useful line.
]]

local FL = ForeverLoot;
local Coordinator = FL.Sync.Coordinator;
local Constants = FL.Sync.Constants;

local periodicIntervalStart = {}; -- [scope] = GetTime() at the start of the CURRENT periodic window
local lastGateReason;             -- previous Gate.Status().reason, for detecting an instance-exit edge

--- "4m12s" / "45s" - only used for the periodic-suppression skip line's
--- "lastMatch=" field.
local function formatAgo(seconds)
    if (not seconds) then return "?"; end
    seconds = math.max(0, math.floor(seconds));
    local m, s = math.floor(seconds / 60), seconds % 60;
    if (m > 0) then return ("%dm%ds"):format(m, s); end
    return ("%ds"):format(s);
end

--- Primary = highest window count among diverged responders, random
--- tie-break (spec 7.2 step 4); up to MAX_SECONDARIES more become
--- secondaries (spec 7.4). Both are handed to Session.Open, which opens the
--- primary's full session immediately and opens each secondary's pull
--- session later, once the primary's compare phase knows the real
--- mismatched-bucket list to split between them.
local function planDomain(domain, responders)
    if (domain.strategy ~= "set") then return; end -- snapshot domains (Phase 7) use a different repair path entirely

    local candidates = {};
    for _, r in ipairs(responders) do
        local summary = r.summaries[domain.id];
        if (summary and domain:Compare(summary) == "diverged") then
            table.insert(candidates, { name = r.name, summary = summary });
        end
    end
    if (#candidates == 0) then return; end

    -- HistoryDomain's summary[1] is the window root's count (spec 4.7's
    -- positional layout - see Data/HistoryDomain.lua's Summary()); any other
    -- future "set" domain's summary would need the same [1]=count
    -- convention for this sort to keep meaning "highest window count".
    table.sort(candidates, function(a, b)
        local an, bn = a.summary[1] or 0, b.summary[1] or 0;
        if (an ~= bn) then return an > bn; end
        return math.random() < 0.5;
    end);

    local primary = candidates[1];
    local secondaryNames = {};
    for i = 2, math.min(#candidates, 1 + Constants.MAX_SECONDARIES) do
        table.insert(secondaryNames, candidates[i].name);
    end

    FL.Sync.Session.Open(domain, primary.name, primary.summary, secondaryNames);
end

local function planDomains(scope, responders)
    if (#responders == 0) then return; end
    for _, domain in ipairs(FL.Sync.Domains.InScope(scope)) do
        planDomain(domain, responders);
    end
end

local function startDiscovery(scope, trigger)
    FL.Sync.Peers.Discover(scope, trigger, function(responders)
        planDomains(scope, responders);
    end);
end

--- Spec 7.5: skip the periodic HELLO entirely if a matching broadcast was
--- already heard during the window that's closing now; otherwise behave
--- exactly like any other trigger.
local function periodicCheck(scope)
    local since = periodicIntervalStart[scope] or 0;
    periodicIntervalStart[scope] = GetTime(); -- this check always opens the NEXT window, win or skip

    if (FL.Sync.Peers.HeardMatchingRoot(scope, since)) then
        FL.Sync.Debug.Log("PEERS", 1, "hello skip scope=%s reason=suppressed lastMatch=%s",
            scope, formatAgo(FL.Sync.Peers.LastMatchAgo(scope)));
        return;
    end

    startDiscovery(scope, "periodic");
end

--- Spec 7.2: login's first HELLO waits for LOGIN_DELAY *and* an open sync
--- gate - whichever finishes last. Gate.OnChange has no unregister (see
--- Sync/Gate.lua's own header comment), so `done` guards this one-shot
--- listener from firing again on a later gate flap.
local function runWhenSyncGateOpens(fn)
    if (FL.Sync.Gate.CanSync()) then
        fn();
        return;
    end
    local done = false;
    FL.Sync.Gate.OnChange(function()
        if (not done and FL.Sync.Gate.CanSync()) then
            done = true;
            fn();
        end
    end);
end

--- /fl debug forcehello (plan Phase 4): bypasses timers and suppression -
--- always runs right now, through the same Discover/plan path every other
--- trigger uses. Peers.Discover's own gate check still applies, so this
--- still logs a plain "hello skip reason=gateClosed" inside an instance.
function Coordinator.ForceHello()
    startDiscovery("GUILD", "force");
end

--- Domains.NotifyChanged(id)'s call-through (spec 7.7: "right after a
--- leader starts a session") - not used by HistoryDomain this phase; wired
--- for the Phase 7 council-session domain's Bump(). Runs the exact same
--- discovery+plan pipeline as every other trigger.
function Coordinator.NotifyChanged(domain)
    startDiscovery(domain.scope, "notify");
end

function Coordinator.Init()
    periodicIntervalStart.GUILD = GetTime();

    FL.Sync.Scheduler.After(Constants.LOGIN_DELAY.base, Constants.LOGIN_DELAY.jitter, function()
        runWhenSyncGateOpens(function() startDiscovery("GUILD", "login"); end);
    end, "loginHello");

    FL.Sync.Scheduler.Every(Constants.PERIODIC_INTERVAL.base, Constants.PERIODIC_INTERVAL.jitter, function()
        periodicCheck("GUILD");
    end, "periodicHello");

    lastGateReason = FL.Sync.Gate.Status().reason;
    FL.Sync.Gate.OnChange(function(state)
        if (lastGateReason == "instance" and state.reason ~= "instance") then
            FL.Sync.Scheduler.After(Constants.LOGIN_DELAY.base, Constants.LOGIN_DELAY.jitter, function()
                startDiscovery("GUILD", "instanceExit");
            end, "instanceExitHello");
        end
        lastGateReason = state.reason;
    end);
end
