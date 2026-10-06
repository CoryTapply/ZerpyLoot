--[[
Login, periodic and instance-exit discovery triggers (spec sections 7.2,
7.5), plus - once Sync/Peers.lua's Discover collects responders for a
scope - choosing a primary (and, as of Phase 6, up to MAX_SECONDARIES
secondaries) for each mismatched "set" domain and handing both to
Sync/Session.lua (spec 7.3-7.4).

Phase 7 adds the RAID scope: login/reload/join-raid/notify/periodic
triggers on the group gate, and the snapshot repair path (SNAP_GET / SNAP)
for snapshot-strategy domains such as the council session
(Data/CouncilSessionDomain.lua).

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
local MSG = Constants.MSG;
local Util = FL.Util;
local Debug = FL.Sync.Debug;

local periodicIntervalStart = {}; -- [scope] = GetTime() at the start of the CURRENT periodic window
local lastGateReason;             -- previous Gate.Status().reason, for detecting an instance-exit edge
local periodicCount = 0;          -- periodic HELLOs actually sent, for FULL_FANOUT_EVERY
local periodicGuildHandle;        -- Scheduler.Every handle of the GUILD periodic check (Coordinator.NextCheckIn)
local loginHelloDone = false;     -- the login HELLO has gone out (or is going out now)
local resumePending = false;      -- sync was turned back on; HELLO once the gate opens

-- Phase 6 review (docs/sync-deviations.md "known-user fan-out"): the
-- GUILD->WHISPER workaround whispers every online guild member by default.
-- Login and forced HELLOs still do ("all" - that's how a new addon user gets
-- discovered at all); instance-exit, notify and most periodic HELLOs only
-- whisper names already heard running the addon ("known"). Every
-- FULL_FANOUT_EVERY-th periodic HELLO goes to everyone again, so someone who
-- installs the addon mid-session is still found without them relogging.
local FULL_FANOUT_EVERY = 4;

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
local planSnapshot; -- snapshot strategy (Phase 7), defined in its own section below

local function planDomain(domain, responders)
    if (domain.strategy == "snapshot") then
        planSnapshot(domain, responders);
        return;
    end
    if (domain.strategy ~= "set") then return; end

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

--------------------------------------------------------------------------
-- Snapshot repair (spec 7.7, plan Phase 7): one SNAP_GET/SNAP round trip on
-- FLoot at NORMAL priority, independent of any history session. Every send
-- goes through the domain's own gate queue (Gate.QueueGroup for the council
-- session - no guild needed), so a request made during a boss encounter
-- waits for ENCOUNTER_END (spec 8: no addon messages during encounters).
--------------------------------------------------------------------------

-- A lost SNAP_GET or SNAP would otherwise wait for the next trigger (up to
-- the 12-minute periodic check). One retry, armed once the request has
-- actually been sent, keeps "within seconds" true on this lossy server.
local SNAP_RETRY_DELAY = 15;
local pendingGet = {}; -- [domainId] = { target, attempt, firstAt = GetTime() of attempt 1 }

-- RAID-scope snapshots only move between members of the same group: they
-- carry council votes, which aren't for the rest of the guild.
local function allowedPeer(domain, name)
    if (domain.scope ~= "RAID") then return true; end
    return FL.Sync.CouncilSessionDomain.InMyGroup(name);
end

-- Queues `fn` on `domain`'s gate: "group" (council session) or "awardUpdates".
local function queueForDomain(domain, fn, label)
    if (domain.gate == "group") then
        FL.Sync.Gate.QueueGroup(fn, label);
    else
        FL.Sync.Gate.QueueAwardUpdate(fn, label);
    end
end

local sendSnapGet;
sendSnapGet = function(domain, target, attempt)
    attempt = attempt or 1;
    local prev = pendingGet[domain.id];
    local firstAt = (attempt > 1 and prev and prev.firstAt) or GetTime();
    pendingGet[domain.id] = { target = target, attempt = attempt, firstAt = firstAt };
    queueForDomain(domain, function()
        local encoded = FL.Sync.Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.SNAP_GET, domain.id });
        FL.Sync.Transport.Send(MSG.SNAP_GET, encoded, "WHISPER", target, {
            prio = "NORMAL",
            onSent = function()
                FL.Sync.Scheduler.After(SNAP_RETRY_DELAY, 0, function()
                    local p = pendingGet[domain.id];
                    if (not p or p.target ~= target or p.attempt ~= attempt) then return; end
                    if (attempt >= 2) then
                        pendingGet[domain.id] = nil;
                        FL.Sync.Debug.Warn("COUNCIL", "sync: gave up waiting for %s's session · no answer after %d tries over %s",
                            target, attempt, Debug.FormatTime(GetTime() - p.firstAt));
                        return;
                    end
                    FL.Sync.Debug.Log("COUNCIL", 1, "sync: no session from %s within %ds · asking again",
                        target, SNAP_RETRY_DELAY);
                    sendSnapGet(domain, target, attempt + 1);
                end, "snapGetRetry");
            end,
        });
        FL.Sync.Debug.Log("COUNCIL", 1, "sync: requested session from %s (attempt %d/2)", target, attempt);
    end, "snapGet");
end

local function sendSnap(domain, target, isPush)
    queueForDomain(domain, function()
        local version, payload, info = domain:Export();
        if (not version) then
            FL.Sync.Debug.Log("COUNCIL", 1, "sync: nothing to send %s · no session for this group", target);
            return;
        end
        local encoded = FL.Sync.Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.SNAP, domain.id, version, payload });
        FL.Sync.Transport.Send(MSG.SNAP, encoded, "WHISPER", target, { prio = "NORMAL" });
        FL.Sync.Debug.Log("COUNCIL", 1, "sync: sent session to %s%s · rev %d, %d items, %s", target,
            isPush and " unasked (they're behind)" or "", info.rev, info.items, Debug.FormatBytes(#encoded));
    end, isPush and "snapPush" or "snapReply");
end

--- remoteNewer: SNAP_GET from the responder with the highest version (one
--- is enough). Otherwise push our SNAP to every responder that is behind
--- (spec 7.7 step 4). Responders whose HELLO_ACK carried no summary for
--- this domain have nothing, which Compare(nil) reports as localNewer.
planSnapshot = function(domain, responders)
    local best, behind = nil, {};
    for _, r in ipairs(responders) do
        local summary = r.summaries[domain.id];
        local result = domain:Compare(summary, r.name);
        if (Debug.IsOn("COUNCIL", 1)) then
            local words = (result == "remoteNewer") and "has a newer copy"
                or (result == "localNewer") and "is behind"
                or "matches";
            FL.Sync.Debug.Log("COUNCIL", 1, "sync: %s %s · theirs %s; mine %s",
                r.name, words, domain:DescribeVersion(summary), domain:DescribeLocal());
        end
        if (result == "remoteNewer") then
            if (not best or domain:Newer(summary, r.name, best.summary, best.name)) then
                best = { name = r.name, summary = summary };
            end
        elseif (result == "localNewer") then
            table.insert(behind, r.name);
        end
    end

    if (best) then
        sendSnapGet(domain, best.name);
        return;
    end
    for _, name in ipairs(behind) do
        sendSnap(domain, name, true);
    end
end

local function onSnapGet(body, senderName)
    local domain = FL.Sync.Domains.Get(body[3]);
    local sender = Util.stripRealm(senderName);
    if (not domain or domain.strategy ~= "snapshot") then return; end
    if (not allowedPeer(domain, sender)) then
        FL.Sync.Debug.Log("COUNCIL", 1, "sync: ignored session request from %s · not in our group", sender);
        return;
    end
    FL.Sync.Debug.Log("COUNCIL", 2, "sync: %s asked for our session", sender);
    sendSnap(domain, sender, false);
end

local function onSnap(body, senderName)
    local domain = FL.Sync.Domains.Get(body[3]);
    local sender = Util.stripRealm(senderName);
    if (not domain or domain.strategy ~= "snapshot") then return; end

    local p = pendingGet[domain.id];
    local took;
    if (p and Util.iEquals(p.target, sender)) then
        pendingGet[domain.id] = nil;
        took = GetTime() - p.firstAt;
    end

    local result, oldRev, newRev, reason = domain:Import(body[4], body[5], sender);
    local tookText = took and (", reply took " .. Debug.FormatTime(took)) or ", unasked";
    if (result == "applied") then
        local s = FL.LootCouncil.CurrentSession;
        FL.Sync.Debug.Log("COUNCIL", 1, "sync: applied %s's session · rev %d -> %d, now %s%s", sender,
            oldRev or 0, newRev or 0, (s and s.status) or "?", tookText);
    elseif (result == "stale") then
        FL.Sync.Debug.Log("COUNCIL", 1, "sync: kept ours over %s's session · theirs isn't newer (rev %d vs our %d)%s",
            sender, newRev or 0, oldRev or 0, tookText);
    else
        FL.Sync.Debug.Log("COUNCIL", 1, "sync: rejected %s's session · %s%s", sender, tostring(reason), tookText);
    end
end

local function planDomains(scope, responders)
    if (#responders == 0) then return; end
    for _, domain in ipairs(FL.Sync.Domains.InScope(scope)) do
        planDomain(domain, responders);
    end
end

-- RAID-scope discovery runs one at a time: Peers keeps a single collection
-- window per scope, and the RAID triggers (join, reload, notify, periodic)
-- can easily overlap. GUILD keeps its Phase 6 behaviour untouched.
local discovering = {};

local function startDiscovery(scope, trigger, fanout)
    if (scope == "RAID") then
        if (discovering.RAID) then
            FL.Sync.Debug.Log("PEERS", 2, "council: didn't ask (%s) · already waiting on replies", trigger);
            return;
        end
        discovering.RAID = true;
    end
    FL.Sync.Peers.Discover(scope, trigger, function(responders)
        if (scope == "RAID") then discovering.RAID = nil; end
        planDomains(scope, responders);
    end, fanout);
end

--- RAID-scope triggers run on the group gate (spec 7.7 "Gating per domain"
--- says live; group is live without the guild requirement): anywhere,
--- including inside instances and without a guild, but queued during a
--- boss encounter or loading screen until the gate reopens.
local function raidHello(trigger)
    FL.Sync.Gate.QueueGroup(function()
        startDiscovery("RAID", trigger);
    end, "raidHello:" .. trigger);
end

--- Spec 7.5: skip the periodic HELLO entirely if a matching broadcast was
--- already heard during the window that's closing now; otherwise behave
--- exactly like any other trigger.
local function periodicCheck(scope)
    local since = periodicIntervalStart[scope] or 0;
    periodicIntervalStart[scope] = GetTime(); -- this check always opens the NEXT window, win or skip

    if (scope == "RAID" and not IsInGroup()) then return; end
    if (FL.Sync.Peers.HeardMatchingRoot(scope, since)) then
        FL.Sync.Debug.Log("PEERS", 1, "%s: skipped periodic check · a matching peer was heard %s ago",
            (scope == "RAID") and "council" or "history", formatAgo(FL.Sync.Peers.LastMatchAgo(scope)));
        return;
    end
    -- Spec 7.5 step 1: "if the gate is open and no session is running" -
    -- the running session is already reconciling; a HELLO now would only
    -- add traffic to the same queue it's using.
    -- (Not for RAID: snapshot repairs are independent of history sessions,
    -- spec 7.7 step 5.)
    if (scope == "GUILD" and FL.Sync.Session.AnyActive()) then
        FL.Sync.Debug.Log("PEERS", 1, "history: skipped periodic check · a sync is already running");
        return;
    end

    if (scope == "RAID") then
        raidHello("periodic");
        return;
    end
    periodicCount = periodicCount + 1;
    startDiscovery(scope, "periodic", (periodicCount % FULL_FANOUT_EVERY == 0) and "all" or "known");
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
function Coordinator.ForceHello(scope)
    if (scope == "RAID") then
        startDiscovery("RAID", "force");
        return;
    end
    startDiscovery("GUILD", "force", "all");
end

--- Sync/Session.lua, after an opener's full session aborted mid-way (peer
--- reloaded or went silent): rediscover now rather than waiting for the
--- next periodic check. "known" fan-out - the peers we need are ones we've
--- just been syncing with.
function Coordinator.RetryAfterAbort(domain)
    startDiscovery(domain.scope, "retry", "known");
end

--- Domains.NotifyChanged(id)'s call-through (spec 7.7: "right after a
--- leader starts a session") - not used by HistoryDomain this phase; wired
--- for the Phase 7 council-session domain's Bump(). Runs the exact same
--- discovery+plan pipeline as every other trigger.
function Coordinator.NotifyChanged(domain)
    if (domain.scope == "RAID") then
        raidHello("notify");
        return;
    end
    startDiscovery(domain.scope, "notify", "known");
end

--- RAID-scope triggers (spec 7.7 "Triggers", plan Phase 7): logging in or
--- /reloading inside a group, and joining one (GROUP_ROSTER_UPDATE with
--- IsInGroup() turning true). Any group, not just a raid: a council session
--- runs in a 5-man party too, and Peers sends the HELLO on PARTY there.
--- Converting a party to a raid isn't a join - everyone in it already has
--- the session. Each waits a few jittered seconds, so the roster has loaded
--- and a group that forms at once doesn't HELLO in the same second (spec 8:
--- jitter everywhere).
local RAID_TRIGGER_DELAY = { base = 4, jitter = 3 };

local function initRaidTriggers()
    local inGroup; -- nil until the first PLAYER_ENTERING_WORLD has been evaluated
    local seenFirstPEW = false;

    local frame = CreateFrame("Frame");
    frame:RegisterEvent("PLAYER_ENTERING_WORLD");
    frame:RegisterEvent("GROUP_ROSTER_UPDATE");
    frame:SetScript("OnEvent", function(_, event, isInitialLogin, isReloadingUi)
        if (event == "PLAYER_ENTERING_WORLD") then
            if (seenFirstPEW) then return; end -- later ones are zone changes, not logins
            seenFirstPEW = true;
            local trigger = (isReloadingUi == true) and "reloadInGroup" or "login";
            FL.Sync.Scheduler.After(RAID_TRIGGER_DELAY.base, RAID_TRIGGER_DELAY.jitter, function()
                inGroup = IsInGroup();
                if (inGroup) then raidHello(trigger); end
            end, "raidLoginHello");
        elseif (event == "GROUP_ROSTER_UPDATE") then
            if (inGroup == nil) then return; end
            local now = IsInGroup();
            if (now and not inGroup) then
                FL.Sync.Scheduler.After(RAID_TRIGGER_DELAY.base, RAID_TRIGGER_DELAY.jitter, function()
                    if (IsInGroup()) then raidHello("joinGroup"); end
                end, "raidJoinHello");
            end
            inGroup = now;
        end
    end);
end

-- Short: the player just asked for sync back, so they're likely watching.
local RESUME_DELAY = { base = 3, jitter = 2 };

--- Seconds until the next periodic GUILD check, or nil before Init. The
--- check itself may still be skipped (a matching HELLO was heard, or a
--- session is running) - see periodicCheck.
function Coordinator.NextCheckIn()
    return FL.Sync.Scheduler.NextFireIn(periodicGuildHandle);
end

function Coordinator.Init()
    periodicIntervalStart.GUILD = GetTime();
    periodicIntervalStart.RAID = GetTime();

    FL.Sync.Transport.Register(MSG.SNAP_GET, onSnapGet);
    FL.Sync.Transport.Register(MSG.SNAP, onSnap);
    initRaidTriggers();
    FL.Sync.Scheduler.Every(Constants.PERIODIC_INTERVAL.base, Constants.PERIODIC_INTERVAL.jitter, function()
        periodicCheck("RAID");
    end, "periodicRaidHello");

    FL.Sync.Scheduler.After(Constants.LOGIN_DELAY.base, Constants.LOGIN_DELAY.jitter, function()
        runWhenSyncGateOpens(function()
            loginHelloDone = true;
            startDiscovery("GUILD", "login", "all");
        end);
    end, "loginHello");

    periodicGuildHandle = FL.Sync.Scheduler.Every(Constants.PERIODIC_INTERVAL.base, Constants.PERIODIC_INTERVAL.jitter, function()
        periodicCheck("GUILD");
    end, "periodicHello");

    lastGateReason = FL.Sync.Gate.Status().reason;
    FL.Sync.Gate.OnChange(function(state)
        -- The player turned sync back on (Sync settings page). Catch up as
        -- soon as the gate opens (now, or after combat etc.) rather than at
        -- the next periodic check. Not before the login HELLO:
        -- runWhenSyncGateOpens above already sends that one.
        local wasStopped = (lastGateReason == "disabled" or lastGateReason == "paused");
        local isStopped = (state.reason == "disabled" or state.reason == "paused");
        if (wasStopped and not isStopped) then resumePending = true; end
        if (isStopped) then resumePending = false; end
        if (resumePending and state.sync == "open" and loginHelloDone) then
            resumePending = false;
            FL.Sync.Scheduler.After(RESUME_DELAY.base, RESUME_DELAY.jitter, function()
                startDiscovery("GUILD", "resume", "all");
            end, "resumeHello");
        end
        if (lastGateReason == "instance" and state.reason ~= "instance") then
            FL.Sync.Scheduler.After(Constants.LOGIN_DELAY.base, Constants.LOGIN_DELAY.jitter, function()
                startDiscovery("GUILD", "instanceExit", "known");
            end, "instanceExitHello");
        end
        lastGateReason = state.reason;
    end);
end
