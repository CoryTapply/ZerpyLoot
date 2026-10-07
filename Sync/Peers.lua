--[[
HELLO / HELLO_ACK discovery (spec sections 7.2, 7.5, 7.7) and the
known-peers table. This phase (4) wires the full handshake - who replies,
with what probability, and whether a periodic check is suppressed - but
stops short of opening a real session: Sync/Coordinator.lua logs a dry-run
plan only (spec section 7.3's real sessions are Phase 5).

Deviation from spec 12.2's module table: SendHello(urgent)/
CollectResponders(window, cb) are collapsed into one Peers.Discover(scope,
trigger, cb) below, kept as local (non-public) helpers inside it. The
retry-with-urgent loop spec 7.2 step 5 describes needs both together, and
nothing in this codebase calls them separately - same reasoning as
Net/Transport.lua's Send(type, ENCODED STRING, ...) deviation: match what
callers actually need rather than the spec's abbreviated sketch. See
docs/sync-deviations.md.
]]

local FL = ForeverLoot;
local Peers = FL.Sync.Peers;
local Util = FL.Util;
local Constants = FL.Sync.Constants;
local MSG = Constants.MSG;

-- [strippedName] = { lastHeard = GetTime(), version, compares = {[domainId]=result}, summaries = {[domainId]=summaryPositional} }
local peers = {};
-- [scope] = GetTime() of the most recent HELLO/HELLO_ACK heard whose every
-- known domain compared "same" - spec 7.5's periodic-suppression signal.
local lastMatchHeardAt = {};
-- [scope] = { responders = { {name=, summaries=}, ... } } while a Discover
-- call's collection window is open; nil otherwise. Only one at a time per
-- scope - nothing in Phase 4 triggers two overlapping discoveries for the
-- same scope.
local collecting = {};

local function addonVersionString()
    local metaFn = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata;
    return (metaFn and metaFn(FL.name, "Version")) or "?";
end
Peers.AddonVersion = addonVersionString;

local lastHelloOutAt; -- GetTime() of the last HELLO actually sent, any scope (/fl sync status)
local helloOutAt = {}; -- [scope] = GetTime() of the last HELLO sent in that scope - reply timing in the log

local Debug = FL.Sync.Debug;

--- Log area for a scope: the RAID scope only carries the council session,
--- GUILD only history.
local function scopeArea(scope)
    return (scope == "RAID") and "council" or "history";
end

-- Compare() results as log words.
local RESULT_WORDS = {
    same = "in sync",
    localNewer = "they're behind",
    remoteNewer = "they have newer",
    diverged = "differs",
    incompatible = "incompatible (different retention)",
};

--------------------------------------------------------------------------
-- Peer versions and the update hint (plan Phase 8 build item 1)
--------------------------------------------------------------------------

local peerVersions = {}; -- [strippedName] = "addon/proto" last logged, so each peer logs once per change
local updateHintShown = false;

--- {1, 2, 3} from "1.2.3", or nil when any part isn't a plain number.
local function parseVersion(v)
    if (type(v) ~= "string" or v == "") then return nil; end
    local parts = {};
    for part in v:gmatch("[^%.]+") do
        local n = tonumber(part);
        if (not n) then return nil; end
        table.insert(parts, n);
    end
    return (#parts > 0) and parts or nil;
end

--- 1 if `a` is newer than `b`, -1 if older, 0 if equal, nil if either
--- doesn't parse.
local function compareVersions(a, b)
    local pa, pb = parseVersion(a), parseVersion(b);
    if (not pa or not pb) then return nil; end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0;
        if (x ~= y) then return (x > y) and 1 or -1; end
    end
    return 0;
end

--- Logs a peer's addon/proto version the first time it's seen (and when it
--- changes), and when the peer's build is newer, prints the one-per-login
--- "A newer ForeverLoot is available" chat line - the only sync message
--- shown to players with debug off - plus a matching debug line. A higher
--- PROTO_VERSION counts as newer even when the version string doesn't parse.
local function noteVersion(name, addonVersion, proto)
    local mine = addonVersionString();
    local cmp = compareVersions(addonVersion, mine);
    local newer = (cmp == 1) or (cmp == nil and (tonumber(proto) or 0) > Constants.PROTO_VERSION);

    local key = tostring(addonVersion) .. "/" .. tostring(proto);
    if (peerVersions[name] ~= key) then
        peerVersions[name] = key;
        FL.Sync.Debug.Log("PEERS", 1, "%s runs ForeverLoot %s · protocol %s%s",
            name, tostring(addonVersion), tostring(proto), newer and ", newer than mine" or "");
    end

    if (newer and not updateHintShown) then
        updateHintShown = true;
        print(("|cff8865ffForeverLoot|r A newer ForeverLoot is available (%s has %s, you have %s)."):format(
            name, tostring(addonVersion), mine));
        FL.Sync.Debug.Log("PEERS", 1, "%s has a newer ForeverLoot · theirs %s, mine %s", name, tostring(addonVersion), mine);
    end
end

--- A HELLO/HELLO_ACK from a peer on another PROTO_VERSION (Net/Transport.lua
--- drops it undispatched): read only the fixed header slots - proto, type,
--- scope, addon version - for the version line and hint. The peer is not
--- recorded as known and nothing is compared; spec 13 says such peers
--- ignore each other.
function Peers.NoteForeignProto(body, senderName)
    if (body[2] ~= MSG.HELLO and body[2] ~= MSG.HELLO_ACK) then return; end
    if (type(body[4]) ~= "string") then return; end
    noteVersion(Util.stripRealm(senderName), body[4], body[1]);
end

--------------------------------------------------------------------------
-- Known peers (spec 7.2 step 4's knownPeers, PEER_MEMORY-windowed)
--------------------------------------------------------------------------

--- With scope "RAID", only peers currently in our group count: a RAID HELLO
--- can only be answered by them, so a guild-wide count would shrink the
--- reply chance far below TARGET_RESPONDERS (two people raiding with 20
--- known guild peers would each answer only 15% of the time).
---@param scope string|nil
function Peers.KnownPeerCount(scope)
    local now, count = GetTime(), 0;
    for name, info in pairs(peers) do
        if ((now - info.lastHeard) <= Constants.PEER_MEMORY
            and (scope ~= "RAID" or FL.Sync.CouncilSessionDomain.InMyGroup(name))) then
            count = count + 1;
        end
    end
    return count;
end

local function recordPeerHeard(senderName, version)
    local name = Util.stripRealm(senderName);
    noteVersion(name, version, Constants.PROTO_VERSION);
    local isNew = peers[name] == nil;
    peers[name] = peers[name] or { compares = {}, summaries = {} };
    peers[name].lastHeard = GetTime();
    peers[name].version = version;
    if (isNew) then
        FL.Sync.Debug.Log("PEERS", 2, "now tracking %s · %d known peers", name, Peers.KnownPeerCount());
    end
end

local function recordCompare(senderName, domainId, result, summary)
    local info = peers[Util.stripRealm(senderName)];
    if (not info) then return; end
    info.compares[domainId] = result;
    info.summaries[domainId] = summary;
end

--- 1 if `version` is newer than ours, -1 if older, 0 if equal, nil if
--- either doesn't parse - the Sync settings page's version warning.
function Peers.CompareToMine(version)
    return compareVersions(version, addonVersionString());
end

Peers.CompareVersions = compareVersions;

--- After a session with `name` finished with matching digests: show the
--- peer as in sync without waiting for its next HELLO. Display only -
--- nothing in discovery or planning reads `compares`.
function Peers.MarkMatched(name, domainId)
    local info = peers[Util.stripRealm(name)];
    if (info) then info.compares[domainId] = "same"; end
end

local function pruneExpiredPeers()
    local now = GetTime();
    local expired = {};
    for name, info in pairs(peers) do
        if ((now - info.lastHeard) > Constants.PEER_MEMORY) then table.insert(expired, name); end
    end
    for _, name in ipairs(expired) do
        peers[name] = nil;
        FL.Sync.Debug.Log("PEERS", 2, "forgot %s · silent for %s, %d known peers", name,
            Debug.FormatTime(Constants.PEER_MEMORY), Peers.KnownPeerCount());
    end
end

--- Every known peer, most-recently-heard first - backs /fl sync peers.
function Peers.All()
    local now = GetTime();
    local out = {};
    for name, info in pairs(peers) do
        table.insert(out, { name = name, ago = now - info.lastHeard, compares = info.compares, summaries = info.summaries, version = info.version });
    end
    table.sort(out, function(a, b) return a.ago < b.ago; end);
    return out;
end

--- The summary `name` last reported for `domainId` (from its HELLO or
--- HELLO_ACK), or nil - lets Sync/Session.lua promote a secondary to
--- primary without another discovery round.
function Peers.SummaryOf(name, domainId)
    local info = peers[Util.stripRealm(name)];
    return info and info.summaries[domainId] or nil;
end

function Peers.HeardMatchingRoot(scope, since)
    local heardAt = lastMatchHeardAt[scope];
    return heardAt ~= nil and heardAt >= since;
end

--- Seconds since the last matching broadcast was heard for `scope`, or nil
--- if none ever was - used only for the periodic-suppression skip line's
--- "lastMatch=" field (Sync/Coordinator.lua).
function Peers.LastMatchAgo(scope)
    local heardAt = lastMatchHeardAt[scope];
    return heardAt and (GetTime() - heardAt) or nil;
end

--- Seconds since this client last sent a HELLO (any scope), or nil.
function Peers.LastHelloOutAgo()
    return lastHelloOutAt and (GetTime() - lastHelloOutAt) or nil;
end

local function markMatchHeard(scope)
    lastMatchHeardAt[scope] = GetTime();
end

--------------------------------------------------------------------------
-- Building/sending HELLO and HELLO_ACK (same body shape - spec section 6:
-- "HELLO_ACK ... Same fields as HELLO")
--------------------------------------------------------------------------

local function gateOpenFor(gateName)
    if (gateName == "awardUpdates") then return FL.Sync.Gate.CanSendAwardUpdates(); end
    if (gateName == "group") then return FL.Sync.Gate.CanGroup(); end
    return FL.Sync.Gate.CanSync(); -- default "sync"
end

--- Flat domainId, summary pairs for every domain registered in `scope`
--- whose own gate is currently open and whose Summary() didn't return nil
--- (spec 7.7 pt1), plus whether ANY domain in the scope has an open gate.
--- `remoteSummaries` ([domainId] = summary, HELLO_ACK only) lets a domain
--- answer with something other than its HELLO summary (SummaryFor - the
--- council session's ended-correction case).
local function domainSummaryPairs(scope, remoteSummaries)
    local flat, anyGateOpen = {}, false;
    for _, domain in ipairs(FL.Sync.Domains.InScope(scope)) do
        if (gateOpenFor(domain.gate)) then
            anyGateOpen = true;
            local summary;
            if (remoteSummaries and domain.SummaryFor) then
                summary = domain:SummaryFor(remoteSummaries[domain.id]);
            else
                summary = domain:Summary();
            end
            if (summary ~= nil) then
                table.insert(flat, domain.id);
                table.insert(flat, summary);
            end
        end
    end
    return flat, anyGateOpen;
end

-- freeSlots = inbound sessions this client could still accept right now
-- (spec section 6). Informational: nothing reads it on receive yet.
--
-- Phase 7: a HELLO with zero domain pairs is still sent while some domain
-- in the scope has an open gate. A raid member who joined late has no
-- council-session summary at all; its HELLO has to go out anyway, so peers
-- holding a session can answer it (see compareAndLog's absent-domain
-- handling). Only "every gate in this scope is closed" skips the HELLO.
-- History's Summary() never returns nil, so GUILD behaves as before.
local function buildHelloBody(msgType, scope, urgent, remoteSummaries)
    local domainPairs, anyGateOpen = domainSummaryPairs(scope, remoteSummaries);
    if (not anyGateOpen) then return nil, {}; end

    local freeSlots = FL.Sync.Session.FreeSlots and FL.Sync.Session.FreeSlots() or Constants.MAX_SERVE;
    local body = { Constants.PROTO_VERSION, msgType, scope, addonVersionString(), freeSlots, urgent and 1 or 0 };
    local ids = {};
    for i, v in ipairs(domainPairs) do
        table.insert(body, v);
        if (i % 2 == 1) then table.insert(ids, v); end
    end
    return body, ids;
end

--- RAID-scope messages go to the group (RAID, or PARTY in a 5-man); GUILD
--- ones to the guild (fanned out as whispers by Net/Transport.lua).
--- Returns nil when a RAID-scope message has nobody to go to.
local function scopeDistribution(scope)
    if (scope == "RAID") then
        if (IsInRaid()) then return "RAID"; end
        if (IsInGroup()) then return "PARTY"; end
        return nil;
    end
    return "GUILD";
end

-- `fanout` ("all" | "known") picks who the GUILD->WHISPER workaround
-- whispers - see Net/Transport.lua's known-users section.
-- `domains=` lists the domain ids carried (plan Phase 7's "domains=2" for
-- a RAID HELLO), "-" when none - a late joiner's RAID HELLO carries none.
local function sendHelloOut(scope, trigger, urgent, fanout)
    local dist = scopeDistribution(scope);
    if (not dist) then
        FL.Sync.Debug.Log("PEERS", 2, "%s: didn't ask · not in a group", scopeArea(scope));
        return false;
    end
    local body, domainIds = buildHelloBody(MSG.HELLO, scope, urgent);
    if (not body) then
        FL.Sync.Debug.Log("PEERS", 1, "%s: didn't ask · gate closed", scopeArea(scope));
        return false;
    end

    local encoded = FL.Sync.Codec.EncodeMessage(body);
    FL.Sync.Transport.Send(MSG.HELLO, encoded, dist, nil, { prio = "NORMAL", fanout = fanout });
    lastHelloOutAt = GetTime();
    helloOutAt[scope] = lastHelloOutAt;
    local carrying = {};
    for _, id in ipairs(domainIds) do
        local domain = FL.Sync.Domains.Get(id);
        local v = Debug.IsOn("PEERS", 1) and domain and domain.DescribeLocal and domain:DescribeLocal();
        table.insert(carrying, Debug.DomainName(id) .. (v and (" " .. v) or ""));
    end
    local who = (dist == "GUILD") and ((fanout == "known") and "known guild peers" or "the guild") or dist:lower();
    FL.Sync.Debug.Log("PEERS", 1, "%s: asked %s what they have · trigger %s%s, carrying %s, %s",
        scopeArea(scope), who, trigger, urgent and " (urgent)" or "",
        (#carrying > 0) and table.concat(carrying, "; ") or "nothing", Debug.FormatBytes(#encoded));
    return true;
end

local function sendHelloAck(scope, targetName, remoteSummaries)
    local body = buildHelloBody(MSG.HELLO_ACK, scope, false, remoteSummaries);
    if (not body) then return; end -- gate closed by the time the delayed ack fires; drop silently
    local encoded = FL.Sync.Codec.EncodeMessage(body);
    FL.Sync.Transport.Send(MSG.HELLO_ACK, encoded, "WHISPER", targetName, { prio = "NORMAL" });
end

--------------------------------------------------------------------------
-- Receiving HELLO / HELLO_ACK: compare every domain, log, and (for HELLO)
-- decide whether to reply (spec 7.2 step 3).
--------------------------------------------------------------------------

local function parseDomainPairs(body)
    local out = {};
    for i = 7, #body, 2 do
        table.insert(out, { domainId = body[i], summary = body[i + 1] });
    end
    return out;
end

local function diffLabel(diffIds)
    if (#diffIds == 0) then return "nothing"; end
    local parts = {};
    for _, id in ipairs(diffIds) do table.insert(parts, Debug.DomainName(id)); end
    return table.concat(parts, ", ");
end

--- Compares every domain pair against this client's own Compare(), logs the
--- "hello in"/"ack in" line, and returns the list of domain ids that need
--- repair: "diverged" (set domains), "remoteNewer"/"localNewer" (snapshot
--- domains). "incompatible" domains never qualify, per spec 10.1.
--- `historyDetail`, when true, also appends the remote's window count for a
--- diverged history domain (the spec's own "ack in ... W=n:3398" example;
--- its "hello in" example omits it).
---
--- Phase 7: a snapshot domain missing from the message means the sender has
--- nothing for it (spec 7.7: domains whose Summary() is nil are left out).
--- If we do have something, that's a mismatch too, compared as Compare(nil)
--- - otherwise nobody would ever answer a late joiner, whose HELLO carries
--- no council-session summary at all. Set domains keep the old behaviour
--- (absent = not compared), since their summary is never nil.
-- Headline per message kind for compareAndLog's line. %s = sender.
local COMPARE_HEADLINES = {
    hello = "%s asked what we have",
    ack = "reply from %s",
    status = "status check from %s",
    statusAck = "status reply from %s",
};

--- `kind` picks the headline (COMPARE_HEADLINES); `note`, when given, is
--- appended to it ("in 3.4s", "late, ignored ...").
local function compareAndLog(scope, senderName, pairs_, kind, historyDetail, note)
    local diffIds, parts = {}, {};
    local anyKnown, allSame = false, true;

    local present = {};
    for _, p in ipairs(pairs_) do present[p.domainId] = true; end
    local absent = {};
    for _, domain in ipairs(FL.Sync.Domains.InScope(scope)) do
        if (domain.strategy == "snapshot" and not present[domain.id] and gateOpenFor(domain.gate)
            and domain:Summary() ~= nil) then
            table.insert(absent, { domainId = domain.id, summary = nil });
        end
    end
    local all = {};
    for _, p in ipairs(pairs_) do table.insert(all, p); end
    for _, p in ipairs(absent) do table.insert(all, p); end

    for _, p in ipairs(all) do
        local domain = FL.Sync.Domains.Get(p.domainId);
        if (domain) then
            anyKnown = true;
            local result = domain:Compare(p.summary, Util.stripRealm(senderName));
            recordCompare(senderName, p.domainId, result, p.summary);

            local part = Debug.DomainName(p.domainId) .. " " .. (RESULT_WORDS[result] or result);
            if (result ~= "same" and domain.DescribeVersion and Debug.IsOn("PEERS", 1)
                and (historyDetail or domain.strategy == "snapshot")) then
                part = part .. (" (theirs %s; mine %s)"):format(domain:DescribeVersion(p.summary),
                    domain:DescribeLocal());
            end
            table.insert(parts, part);

            if (result ~= "same" and result ~= "incompatible") then table.insert(diffIds, p.domainId); end
            if (result ~= "same") then allSame = false; end
        else
            table.insert(parts, ("unknown domain %d"):format(p.domainId));
        end
    end

    local headline = COMPARE_HEADLINES[kind]:format(Util.stripRealm(senderName));
    FL.Sync.Debug.Log("PEERS", 1, "%s: %s%s · %s", scopeArea(scope), headline, note and (" " .. note) or "",
        (#parts > 0) and table.concat(parts, ", ") or "nothing to compare");
    if (anyKnown and allSame) then markMatchHeard(scope); end

    return diffIds;
end

local function decideAckReply(scope, senderName, diffIds, urgent, remoteSummaries)
    local known = Peers.KnownPeerCount(scope);

    if (#diffIds == 0) then
        FL.Sync.Debug.Log("PEERS", 1, "%s: not replying to %s · already in sync", scopeArea(scope), Util.stripRealm(senderName));
        return;
    end

    -- Each differing domain's own gate (Phase 7: the RAID-scope council
    -- session uses the group gate, so it still answers inside an instance).
    local anyGateOpen = false;
    for _, id in ipairs(diffIds) do
        local domain = FL.Sync.Domains.Get(id);
        if (domain and gateOpenFor(domain.gate)) then anyGateOpen = true; end
    end
    if (not anyGateOpen) then
        FL.Sync.Debug.Log("PEERS", 1, "%s: not replying to %s · gate closed (%s differs)",
            scopeArea(scope), Util.stripRealm(senderName), diffLabel(diffIds));
        return;
    end

    local p = math.min(1, Constants.TARGET_RESPONDERS / math.max(1, known));
    if (urgent) then p = math.min(1, p * 2); end -- spec 7.2 step 5: an urgent HELLO doubles p
    -- A domain can insist on answering (the council session's leader, when
    -- the sender is behind on that leader's own session): the leader is the
    -- one peer guaranteed to hold the right version, so leaving it to the
    -- roll can strand the sender until the next periodic check.
    local mustReply = false;
    for _, id in ipairs(diffIds) do
        local domain = FL.Sync.Domains.Get(id);
        if (domain and domain.MustReply and gateOpenFor(domain.gate)
            and domain:MustReply(remoteSummaries and remoteSummaries[id], Util.stripRealm(senderName))) then
            p = 1;
            mustReply = true;
            break;
        end
    end
    local roll = math.random();
    local odds = ("%d%% chance, %d peer%s%s"):format(math.floor(p * 100 + 0.5), known, (known == 1) and "" or "s",
        urgent and ", urgent" or "");
    if (roll > p) then
        FL.Sync.Debug.Log("PEERS", 1, "%s: leaving %s to others · lost reply roll (%s)",
            scopeArea(scope), Util.stripRealm(senderName), odds);
        return;
    end

    local delay = math.random() * Constants.HELLO_REPLY_JITTER;
    FL.Sync.Debug.Log("PEERS", 1, "%s: replying to %s in %s · %s differs, %s",
        scopeArea(scope), Util.stripRealm(senderName), Debug.FormatTime(delay), diffLabel(diffIds),
        mustReply and "I'm the session leader (always reply)" or ("won reply roll (" .. odds .. ")"));

    FL.Sync.Scheduler.After(delay, 0, function()
        sendHelloAck(scope, senderName, remoteSummaries);
    end, "helloAckDelay");
end

-- GUILD-scope discovery only with our own guild: another guild's member
-- reaching us by whisper must not compare or sync history with us.
local function otherGuildHello(scope, senderName, what)
    if (scope ~= "GUILD" or FL.Sync.Permissions.IsGuildPeer(senderName)) then return false; end
    Debug.Log("PEERS", 2, "ignored %s from %s · not in our guild", what, senderName);
    return true;
end

local function handleIncomingHello(body, senderName)
    local scope, addonVersion = body[3], body[4];
    if (otherGuildHello(scope, senderName, "hello")) then return; end
    recordPeerHeard(senderName, addonVersion);
    local pairs_ = parseDomainPairs(body);
    local diffIds = compareAndLog(scope, senderName, pairs_, "hello", false);
    local remoteSummaries = {};
    for _, p in ipairs(pairs_) do remoteSummaries[p.domainId] = p.summary; end
    decideAckReply(scope, senderName, diffIds, body[6] == 1, remoteSummaries);
end

local function handleIncomingHelloAck(body, senderName)
    local scope, addonVersion = body[3], body[4];
    if (otherGuildHello(scope, senderName, "reply")) then return; end
    recordPeerHeard(senderName, addonVersion);
    local pairs_ = parseDomainPairs(body);
    local entry = collecting[scope];
    local took = helloOutAt[scope] and (GetTime() - helloOutAt[scope]);

    -- A reply after the collection window closed is still compared (and
    -- logged), but nothing acts on it: the discovery it answered is over.
    -- Logged as late so slow whispers show up as such instead of looking
    -- like a normal reply.
    local note;
    if (entry) then
        note = took and ("in " .. Debug.FormatTime(took)) or nil;
    else
        note = ("arrived late, ignored (%s after asking, window was %ds)"):format(
            took and Debug.FormatTime(took) or "?", Constants.HELLO_COLLECT_WINDOW);
    end
    compareAndLog(scope, senderName, pairs_, "ack", true, note);

    if (entry) then
        local summaries = {};
        for _, p in ipairs(pairs_) do summaries[p.domainId] = p.summary; end
        table.insert(entry.responders, { name = Util.stripRealm(senderName), summaries = summaries, took = took });
    end
end

--------------------------------------------------------------------------
-- Collection window + retry loop (spec 7.2 steps 4-5)
--------------------------------------------------------------------------

local function describeResponder(r)
    return r.took and (r.name .. " " .. Debug.FormatTime(r.took)) or r.name;
end

local function collectResponders(scope, window, cb)
    collecting[scope] = { responders = {} };
    FL.Sync.Scheduler.After(window, 0, function()
        local entry = collecting[scope];
        collecting[scope] = nil;
        local responders = entry and entry.responders or {};

        if (#responders > 0) then
            local parts = {};
            for _, r in ipairs(responders) do table.insert(parts, describeResponder(r)); end
            FL.Sync.Debug.Log("PEERS", 1, "%s: %d repl%s within %ds · %s", scopeArea(scope), #responders,
                (#responders == 1) and "y" or "ies", window, table.concat(parts, ", "));
        end

        cb(responders);
    end, "helloCollectWindow");
end

--- Sends HELLO for `scope`, collects HELLO_ACKs for HELLO_COLLECT_WINDOW
--- seconds, and calls cb(responders). If nobody replies, retries with the
--- urgent flag up to HELLO_RETRY.maxTries times, HELLO_RETRY.delay seconds
--- apart (spec 7.2 step 5), then gives up and calls cb({}).
function Peers.Discover(scope, trigger, cb, fanout)
    local maxTries = Constants.HELLO_RETRY.maxTries;
    local attempt = 0;

    local function tryOnce(urgent)
        attempt = attempt + 1;
        if (not sendHelloOut(scope, trigger, urgent, fanout)) then
            cb({});
            return;
        end

        collectResponders(scope, Constants.HELLO_COLLECT_WINDOW, function(responders)
            if (#responders > 0) then
                cb(responders);
                return;
            end

            if (attempt < maxTries) then
                FL.Sync.Debug.Log("PEERS", 1, "%s: no replies within %ds · retrying in %ds (attempt %d/%d, urgent)",
                    scopeArea(scope), Constants.HELLO_COLLECT_WINDOW, Constants.HELLO_RETRY.delay, attempt + 1, maxTries);
            else
                FL.Sync.Debug.Log("PEERS", 1, "%s: no replies within %ds · gave up after %d tries",
                    scopeArea(scope), Constants.HELLO_COLLECT_WINDOW, maxTries);
            end

            if (attempt < maxTries) then
                FL.Sync.Scheduler.After(Constants.HELLO_RETRY.delay, 0, function() tryOnce(true); end, "helloRetry");
            else
                cb({});
            end
        end);
    end

    tryOnce(false);
end

--------------------------------------------------------------------------
-- Peer status check (docs/sync-deviations.md "Peer status check"): while
-- the Sync settings page is open, a STATUS goes out every STATUS_INTERVAL
-- seconds and every peer answers with a STATUS_ACK - even when everything
-- matches, unlike HELLO. Same body as HELLO. Display only: nothing here
-- feeds discovery (`collecting`) or opens a session.
--------------------------------------------------------------------------

local lastStatusOutAt; -- GetTime() of the last STATUS sent

--- Sends a GUILD STATUS unless one went out less than STATUS_INTERVAL
--- seconds ago or the sync gate is closed. Safe to call every frame.
function Peers.SendStatus(trigger)
    if (lastStatusOutAt and (GetTime() - lastStatusOutAt) < Constants.STATUS_INTERVAL) then return; end
    local body = buildHelloBody(MSG.STATUS, "GUILD", false);
    if (not body) then return; end -- gate closed: stay silent, same as HELLO
    lastStatusOutAt = GetTime();
    local encoded = FL.Sync.Codec.EncodeMessage(body);
    FL.Sync.Transport.Send(MSG.STATUS, encoded, "GUILD", nil, { prio = "NORMAL", fanout = "known" });
    FL.Sync.Debug.Log("PEERS", 1, "history: status check sent · trigger %s, %s", tostring(trigger), Debug.FormatBytes(#encoded));
end

local function handleIncomingStatus(body, senderName)
    local scope, addonVersion = body[3], body[4];
    recordPeerHeard(senderName, addonVersion);
    compareAndLog(scope, senderName, parseDomainPairs(body), "status", false);

    FL.Sync.Scheduler.After(math.random() * Constants.HELLO_REPLY_JITTER, 0, function()
        local reply = buildHelloBody(MSG.STATUS_ACK, scope, false);
        if (not reply) then return; end -- gate closed by the time the reply fires
        FL.Sync.Transport.Send(MSG.STATUS_ACK, FL.Sync.Codec.EncodeMessage(reply), "WHISPER", senderName, { prio = "NORMAL" });
    end, "statusAckDelay");
end

local function handleIncomingStatusAck(body, senderName)
    local scope, addonVersion = body[3], body[4];
    recordPeerHeard(senderName, addonVersion);
    compareAndLog(scope, senderName, parseDomainPairs(body), "statusAck", true);
end

--- /fl debug spamhello <n> [name] (plan Phase 8, test mode only): sends `n`
--- GUILD HELLOs back to back - to `name` alone, or to every known addon
--- user - so the receiver's rate limit can be watched. No collection window
--- and no retries: replies are handled like any other HELLO_ACK.
function Peers.SpamHello(n, target)
    n = math.floor(tonumber(n) or 0);
    if (n < 1) then
        FL.Sync.Debug.Log("TEST", 1, "spamhello: need a count · /fl debug spamhello <n> [name]");
        return;
    end
    local body = buildHelloBody(MSG.HELLO, "GUILD", false);
    if (not body) then
        FL.Sync.Debug.Log("TEST", 1, "spamhello: skipped · gate closed");
        return;
    end
    local encoded = FL.Sync.Codec.EncodeMessage(body);
    for _ = 1, n do
        if (target and target ~= "") then
            FL.Sync.Transport.Send(MSG.HELLO, encoded, "WHISPER", target, { prio = "NORMAL" });
        else
            FL.Sync.Transport.Send(MSG.HELLO, encoded, "GUILD", nil, { prio = "NORMAL", fanout = "known" });
        end
    end
    FL.Sync.Debug.Log("TEST", 1, "spamhello: sent %d HELLOs to %s · %s each", n,
        (target and target ~= "") and target or "known guild peers", Debug.FormatBytes(#encoded));
end

function Peers.Init()
    FL.Sync.Transport.Register(MSG.HELLO, handleIncomingHello);
    FL.Sync.Transport.Register(MSG.HELLO_ACK, handleIncomingHelloAck);
    FL.Sync.Transport.Register(MSG.STATUS, handleIncomingStatus);
    FL.Sync.Transport.Register(MSG.STATUS_ACK, handleIncomingStatusAck);
    FL.Sync.Scheduler.Every(60, 10, pruneExpiredPeers, "peerExpire");
end
