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

--------------------------------------------------------------------------
-- Known peers (spec 7.2 step 4's knownPeers, PEER_MEMORY-windowed)
--------------------------------------------------------------------------

function Peers.KnownPeerCount()
    local now, count = GetTime(), 0;
    for _, info in pairs(peers) do
        if ((now - info.lastHeard) <= Constants.PEER_MEMORY) then count = count + 1; end
    end
    return count;
end

local function recordPeerHeard(senderName, version)
    local name = Util.stripRealm(senderName);
    local isNew = peers[name] == nil;
    peers[name] = peers[name] or { compares = {}, summaries = {} };
    peers[name].lastHeard = GetTime();
    peers[name].version = version;
    if (isNew) then
        FL.Sync.Debug.Log("PEERS", 2, "known add=%q total=%d", name, Peers.KnownPeerCount());
    end
end

local function recordCompare(senderName, domainId, result, summary)
    local info = peers[Util.stripRealm(senderName)];
    if (not info) then return; end
    info.compares[domainId] = result;
    info.summaries[domainId] = summary;
end

local function pruneExpiredPeers()
    local now = GetTime();
    local expired = {};
    for name, info in pairs(peers) do
        if ((now - info.lastHeard) > Constants.PEER_MEMORY) then table.insert(expired, name); end
    end
    for _, name in ipairs(expired) do
        peers[name] = nil;
        FL.Sync.Debug.Log("PEERS", 2, "known expire=%q total=%d", name, Peers.KnownPeerCount());
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

local function markMatchHeard(scope)
    lastMatchHeardAt[scope] = GetTime();
end

--------------------------------------------------------------------------
-- Building/sending HELLO and HELLO_ACK (same body shape - spec section 6:
-- "HELLO_ACK ... Same fields as HELLO")
--------------------------------------------------------------------------

local function gateOpenFor(gateName)
    if (gateName == "live") then return FL.Sync.Gate.CanLive(); end
    return FL.Sync.Gate.CanSync(); -- default "sync"
end

--- Flat domainId, summary pairs for every domain registered in `scope`
--- whose own gate is currently open and whose Summary() didn't return nil
--- (spec 7.7 pt1).
local function domainSummaryPairs(scope)
    local flat = {};
    for _, domain in ipairs(FL.Sync.Domains.InScope(scope)) do
        if (gateOpenFor(domain.gate)) then
            local summary = domain:Summary();
            if (summary ~= nil) then
                table.insert(flat, domain.id);
                table.insert(flat, summary);
            end
        end
    end
    return flat;
end

-- freeSlots is a placeholder (MAX_SERVE) until Phase 5's Coordinator tracks
-- actually-active inbound sessions - nothing reads this field yet.
local function buildHelloBody(msgType, scope, urgent)
    local domainPairs = domainSummaryPairs(scope);
    if (#domainPairs == 0) then return nil, 0; end

    local body = { Constants.PROTO_VERSION, msgType, scope, addonVersionString(), Constants.MAX_SERVE, urgent and 1 or 0 };
    for _, v in ipairs(domainPairs) do table.insert(body, v); end
    return body, (#domainPairs / 2);
end

local function sendHelloOut(scope, trigger, urgent)
    local body, domainCount = buildHelloBody(MSG.HELLO, scope, urgent);
    if (not body) then
        FL.Sync.Debug.Log("PEERS", 1, "hello skip scope=%s reason=gateClosed", scope);
        return false;
    end

    local encoded = FL.Sync.Codec.EncodeMessage(body);
    FL.Sync.Transport.Send(MSG.HELLO, encoded, "GUILD", nil, { prio = "NORMAL" });
    FL.Sync.Debug.Log("PEERS", 1, "hello out scope=%s trigger=%s urgent=%s domains=%d bytes=%d",
        scope, trigger, urgent and "yes" or "no", domainCount, #encoded);
    return true;
end

local function sendHelloAck(scope, targetName)
    local body = buildHelloBody(MSG.HELLO_ACK, scope, false);
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
    if (#diffIds == 0) then return "-"; end
    local parts = {};
    for _, id in ipairs(diffIds) do table.insert(parts, "d" .. id); end
    return table.concat(parts, ",");
end

--- Compares every domain pair against this client's own Compare(), logs the
--- "hello in"/"ack in" line, and returns the list of domain ids that came
--- back "diverged" (candidates for a future sync session - "incompatible"
--- domains never qualify, per spec 10.1). `historyDetail`, when true, also
--- appends the remote's window count for a diverged history domain (the
--- spec's own "ack in ... W=n:3398" example; its "hello in" example omits
--- it).
local function compareAndLog(scope, senderName, pairs_, logPrefix, historyDetail)
    local diffIds, parts = {}, {};
    local anyKnown, allSame = false, true;

    for _, p in ipairs(pairs_) do
        local domain = FL.Sync.Domains.Get(p.domainId);
        if (domain) then
            anyKnown = true;
            local result = domain:Compare(p.summary);
            recordCompare(senderName, p.domainId, result, p.summary);

            local part = ("d%d=%s"):format(p.domainId, result);
            if (historyDetail and result == "diverged" and p.domainId == Constants.DOMAIN_HISTORY) then
                part = part .. (" W=n:%d"):format(p.summary[1] or 0);
            end
            table.insert(parts, part);

            if (result == "diverged") then table.insert(diffIds, p.domainId); end
            if (result ~= "same") then allSame = false; end
        else
            table.insert(parts, ("d%d=unknown"):format(p.domainId));
        end
    end

    FL.Sync.Debug.Log("PEERS", 1, "%s from=%q scope=%s %s", logPrefix, senderName, scope, table.concat(parts, " "));
    if (anyKnown and allSame) then markMatchHeard(scope); end

    return diffIds;
end

local function decideAckReply(scope, senderName, diffIds)
    local known = Peers.KnownPeerCount();

    if (#diffIds == 0) then
        FL.Sync.Debug.Log("PEERS", 1, "ack decide from=%q diff=- known=%d -> silent reason=allSame", senderName, known);
        return;
    end

    if (not FL.Sync.Gate.CanSync()) then
        FL.Sync.Debug.Log("PEERS", 1, "ack decide from=%q diff=%s known=%d -> silent reason=gateClosed",
            senderName, diffLabel(diffIds), known);
        return;
    end

    local p = math.min(1, Constants.TARGET_RESPONDERS / math.max(1, known));
    local roll = math.random();
    if (roll > p) then
        FL.Sync.Debug.Log("PEERS", 1, "ack decide from=%q diff=%s known=%d p=%.2f roll=%.2f -> silent reason=roll",
            senderName, diffLabel(diffIds), known, p, roll);
        return;
    end

    local delay = math.random() * Constants.HELLO_REPLY_JITTER;
    FL.Sync.Debug.Log("PEERS", 1, "ack decide from=%q diff=%s known=%d p=%.2f roll=%.2f -> reply delay=%.1fs",
        senderName, diffLabel(diffIds), known, p, roll, delay);

    FL.Sync.Scheduler.After(delay, 0, function()
        sendHelloAck(scope, senderName);
    end, "helloAckDelay");
end

local function handleIncomingHello(body, senderName)
    local scope, addonVersion = body[3], body[4];
    recordPeerHeard(senderName, addonVersion);
    local diffIds = compareAndLog(scope, senderName, parseDomainPairs(body), "hello in", false);
    decideAckReply(scope, senderName, diffIds);
end

local function handleIncomingHelloAck(body, senderName)
    local scope, addonVersion = body[3], body[4];
    recordPeerHeard(senderName, addonVersion);
    local pairs_ = parseDomainPairs(body);
    compareAndLog(scope, senderName, pairs_, "ack in", true);

    local entry = collecting[scope];
    if (entry) then
        local summaries = {};
        for _, p in ipairs(pairs_) do summaries[p.domainId] = p.summary; end
        table.insert(entry.responders, { name = Util.stripRealm(senderName), summaries = summaries });
    end
end

--------------------------------------------------------------------------
-- Collection window + retry loop (spec 7.2 steps 4-5)
--------------------------------------------------------------------------

local function describeResponder(r)
    local hist = r.summaries[Constants.DOMAIN_HISTORY];
    if (hist) then return ("%q n=%d"):format(r.name, hist[1] or 0); end
    return ("%q"):format(r.name);
end

local function collectResponders(scope, window, cb)
    collecting[scope] = { responders = {} };
    FL.Sync.Scheduler.After(window, 0, function()
        local entry = collecting[scope];
        collecting[scope] = nil;
        local responders = entry and entry.responders or {};

        local parts = {};
        for _, r in ipairs(responders) do table.insert(parts, describeResponder(r)); end
        FL.Sync.Debug.Log("PEERS", 1, "responders window=%ds got=%d [%s]", window, #responders, table.concat(parts, ", "));

        cb(responders);
    end, "helloCollectWindow");
end

--- Sends HELLO for `scope`, collects HELLO_ACKs for HELLO_COLLECT_WINDOW
--- seconds, and calls cb(responders). If nobody replies, retries with the
--- urgent flag up to HELLO_RETRY.maxTries times, HELLO_RETRY.delay seconds
--- apart (spec 7.2 step 5), then gives up and calls cb({}).
function Peers.Discover(scope, trigger, cb)
    local maxTries = Constants.HELLO_RETRY.maxTries;
    local attempt = 0;

    local function tryOnce(urgent)
        attempt = attempt + 1;
        if (not sendHelloOut(scope, trigger, urgent)) then
            cb({});
            return;
        end

        collectResponders(scope, Constants.HELLO_COLLECT_WINDOW, function(responders)
            if (#responders > 0) then
                cb(responders);
                return;
            end

            FL.Sync.Debug.Log("PEERS", 1, "no responders attempt=%d/%d retry=%ds urgent=yes",
                attempt, maxTries, Constants.HELLO_RETRY.delay);

            if (attempt < maxTries) then
                FL.Sync.Scheduler.After(Constants.HELLO_RETRY.delay, 0, function() tryOnce(true); end, "helloRetry");
            else
                cb({});
            end
        end);
    end

    tryOnce(false);
end

function Peers.Init()
    FL.Sync.Transport.Register(MSG.HELLO, handleIncomingHello);
    FL.Sync.Transport.Register(MSG.HELLO_ACK, handleIncomingHelloAck);
    FL.Sync.Scheduler.Every(60, 10, pruneExpiredPeers, "peerExpire");
end
