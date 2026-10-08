--[[
The running loot-council session as sync domain 2 (spec section 7.7):
strategy "snapshot", scope RAID, gate "group" (live, but open without a guild). Raid members who join late,
reload or disconnect catch up through the same HELLO handshake history uses.
The existing live council messages (LootCouncil.lua, ForeverLootLC prefix)
are unchanged; this only repairs whoever missed some of them.

Version and Bump (plan Phase 7, "single version point"). Every change to the
session goes through CouncilSessionDomain:Bump(cause), which increments
Session.rev. Each client counts a change once, at the point it actually
applies it: the network apply handlers (applyResponse, applyVote, ...), plus
the leader's own optimistic paths whose echo is ignored (AwardItem,
DisenchantItem, EndSession, EndSessionEarly). A raider's optimistic
SubmitResponse/ToggleVote is NOT counted; its echo through applyResponse/
applyVote is, exactly as on every other client. So every raid member who saw
the same messages holds the same rev, and one who missed some holds a lower
rev and imports.

Leader authority (not in the spec): revs can still drift upward on a
non-leader (a live message re-applied after an import already contained
it). For the same session, the leader's own version therefore always wins:
Compare() reports localNewer on the leader and remoteNewer when the remote
IS the leader, whatever the revs say. See docs/sync-deviations.md
"Phase 7".

Summary is { sessionId, startedAt, rev, ended, leader }. `leader` is
appended to spec 7.7's four fields: sessionId alone is each leader's own
counter (two leaders' "session 3" collide), and the leader-authority rule
needs to know who the leader is. startedAt is server time (GetServerTime)
taken when this client first saw the session - live followers stamp their
own receive time, which only matters when comparing DIFFERENT sessions.

A session is only advertised, and a snapshot only accepted, while its
leader is in our group (or is us). Without this, a member carrying an old
session in SavedVariables would push it into an unrelated raid.

Ended sessions are not advertised at all (spec 7.7 keeps them for
SESSION_END_TTL; dropped - a late joiner has no use for a finished
session). Ended is terminal: an active copy of a session we hold as ended
is always stale. The one place the ended state still travels is a
correction: when a peer advertises that same session as still active (it
missed the end), Compare reports localNewer, our HELLO_ACK carries the
ended version (SummaryFor) and the peer pulls it.
]]

local FL = ForeverLoot;
local CouncilSessionDomain = FL.Sync.CouncilSessionDomain;
local Util = FL.Util;
local Constants = FL.Sync.Constants;

CouncilSessionDomain.id       = Constants.DOMAIN_COUNCIL_SESSION;
CouncilSessionDomain.name     = "councilSession";
CouncilSessionDomain.strategy = "snapshot";
CouncilSessionDomain.scope    = "RAID";
CouncilSessionDomain.gate     = "group"; -- live, minus the guild requirement (Sync/Gate.lua computeGroup)

-- Validation caps for an incoming snapshot (spec 4.9's "validate before
-- applying" applied to this payload). Well above any real session.
local MAX_ITEMS = 200;
local MAX_CANDIDATES = 80;
local MAX_PLAYERS = 400;
local MAX_NOTE_LEN = 255;

-- Delay before a leader's "session started" HELLO (spec 7.7: NotifyChanged
-- right after a leader starts a session). The sessionStart broadcast itself
-- travels on another prefix; waiting a few seconds lets it land first, so
-- the HELLO only finds members it really missed.
local NOTIFY_DELAY = { base = 5, jitter = 2 };

local STATUS_ACTIVE, STATUS_ENDED = 1, 2;

local endedLoggedFor; -- "leader#id" whose "summary none reason=ended" line was already logged

local function session()
    return FL.LootCouncil.CurrentSession;
end

local function leaderName(s)
    return Util.stripRealm(s.initiatorFqn or "?");
end

local function sessionKey(s)
    return leaderName(s) .. "#" .. tostring(s.id);
end

--- True when `name` is in our raid/party (or is us). Loose name matching,
--- same as the rest of the council code (Forever names are "First Last").
local function inMyGroup(name)
    if (type(name) ~= "string" or name == "") then return false; end
    if (Util.namesMatch(name, Util.UnitName("player"))) then return true; end
    if (not IsInGroup()) then return false; end
    return Util.findMember(Util.groupMembers(), name) ~= nil;
end
CouncilSessionDomain.InMyGroup = inMyGroup;

--------------------------------------------------------------------------
-- Version point
--------------------------------------------------------------------------

--- The one place a session's version changes. `cause` is a short word for
--- the debug line: start, addItems, response, vote, award, end, endEarly,
--- council.
function CouncilSessionDomain:Bump(cause)
    local s = session();
    if (not s) then return; end

    local old = s.rev or 0;
    s.rev = old + 1;
    FL.Sync.Debug.Log("COUNCIL", 2, "session #%d changed · %s, rev %d -> %d", s.id or 0, cause, old, s.rev);

    if ((cause == "end" or cause == "endEarly") and s.status ~= "active") then
        s.endedAt = GetServerTime();
        FL.Sync.Debug.Log("COUNCIL", 1, "session #%d ended · no longer advertised to the group", s.id or 0);
    end

    if (cause == "start" and s.initiatorIsMe) then
        FL.Sync.Scheduler.After(NOTIFY_DELAY.base, NOTIFY_DELAY.jitter, function()
            FL.Sync.Domains.NotifyChanged(self.id);
        end, "snapNotify");
    end
end

--------------------------------------------------------------------------
-- Summary / Compare
--------------------------------------------------------------------------

--- Our version whatever its status - positional { sessionId, startedAt,
--- rev, ended (0/1), leader } - or nil when there's no session or its
--- leader isn't in our group.
local function localVersion()
    local s = session();
    if (not s or not s.id) then return nil; end
    if (not s.initiatorIsMe and not inMyGroup(leaderName(s))) then return nil; end
    return { s.id, s.startedAtServer or 0, s.rev or 0, (s.status ~= "active") and 1 or 0, leaderName(s) };
end

--- What HELLO advertises: our version while the session is active, nil once
--- it has ended (or there's none, or its leader isn't in our group).
function CouncilSessionDomain:Summary()
    local v = localVersion();
    if (v and v[4] == 1) then
        local key = sessionKey(session());
        if (endedLoggedFor ~= key) then
            endedLoggedFor = key;
            FL.Sync.Debug.Log("COUNCIL", 1, "sync: not advertising session #%d · it has ended", session().id or 0);
        end
        return nil;
    end
    return v;
end

local function validVersion(v)
    return type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number"
        and type(v[3]) == "number" and (v[4] == 0 or v[4] == 1) and type(v[5]) == "string";
end

local function sameIdentity(a, b)
    return a[1] == b[1] and Util.iEquals(a[5], b[5]);
end

local function isLeader(v, name)
    return v ~= nil and type(name) == "string" and Util.namesMatch(name, v[5]);
end

--- 1 when `a` is newer, -1 when `b` is, 0 when they're the same version.
--- nil means "has nothing". Same session: ended beats active (ended is
--- terminal), then the leader's copy wins, then the higher rev. Different
--- sessions: the later startedAt wins (spec 7.7), with a deterministic
--- tie-break.
local function versionOrder(a, aIsLeader, b, bIsLeader)
    if (a == nil and b == nil) then return 0; end
    if (b == nil) then return 1; end
    if (a == nil) then return -1; end

    if (sameIdentity(a, b)) then
        if (a[4] ~= b[4]) then return (a[4] > b[4]) and 1 or -1; end
        if (a[3] == b[3]) then return 0; end
        if (aIsLeader) then return 1; end
        if (bIsLeader) then return -1; end
        return (a[3] > b[3]) and 1 or -1;
    end

    if (a[2] ~= b[2]) then return (a[2] > b[2]) and 1 or -1; end
    local ka, kb = (a[5] .. "#" .. a[1]):lower(), (b[5] .. "#" .. b[1]):lower();
    return (ka > kb) and 1 or -1;
end

--- "same" | "remoteNewer" | "localNewer". `remoteName` (who sent the
--- summary) is optional; it lets the session's leader win for its own
--- session. A missing or malformed remote summary means "has nothing".
function CouncilSessionDomain:Compare(remote, remoteName)
    if (not validVersion(remote)) then remote = nil; end

    -- Ended is terminal. A peer still advertising our ended session as
    -- active missed the end: we're newer, and SummaryFor() puts the ended
    -- version in our HELLO_ACK so it can pull it. Anything else about that
    -- session is "same" - there's nothing to send.
    local raw = localVersion();
    if (raw and raw[4] == 1 and remote and sameIdentity(raw, remote)) then
        return (remote[4] == 0) and "localNewer" or "same";
    end

    local mine = self:Summary();
    local s = session();
    local order = versionOrder(mine, mine ~= nil and s.initiatorIsMe == true, remote, isLeader(remote, remoteName));
    if (order == 0) then return "same"; end
    return (order > 0) and "localNewer" or "remoteNewer";
end

--- Whether we must answer a HELLO carrying `remote` instead of rolling for
--- it (Sync/Peers.lua decideAckReply): we lead the session we hold, and the
--- sender's copy of it is behind ours - most often a raider who was offline
--- when we ended it. A sender with no session (late joiner) still rolls, as
--- every raid member who has ours can answer that.
function CouncilSessionDomain:MustReply(remote)
    local s = session();
    if (not s or not s.initiatorIsMe or not validVersion(remote)) then return false; end
    local raw = localVersion();
    return raw ~= nil and sameIdentity(raw, remote) and self:Compare(remote) == "localNewer";
end

--- The summary to put in a HELLO_ACK answering `remote` (Sync/Peers.lua):
--- normally Summary(), but the ended version when `remote` is that same
--- session still marked active (the correction case in Compare).
function CouncilSessionDomain:SummaryFor(remote)
    local raw = localVersion();
    if (raw and raw[4] == 1 and validVersion(remote) and remote[4] == 0 and sameIdentity(raw, remote)) then
        return raw;
    end
    return self:Summary();
end

--- Whether summary `a` (from `aName`) is newer than `b` (from `bName`) -
--- Sync/Coordinator.lua's "responder with the highest version" pick.
function CouncilSessionDomain:Newer(a, aName, b, bName)
    if (not validVersion(a)) then return false; end
    if (not validVersion(b)) then return true; end
    return versionOrder(a, isLeader(a, aName), b, isLeader(b, bName)) > 0;
end

--- "#6 active rev 14, leader Anduin" or "no session", for log lines.
function CouncilSessionDomain:DescribeVersion(v)
    if (not validVersion(v)) then return "no session"; end
    return ("#%d %s rev %d, leader %s"):format(v[1], (v[4] == 1) and "ended" or "active", v[3], v[5]);
end

--- DescribeVersion of what we hold, ended or not (Summary() hides an
--- ended session, which is exactly the case the log needs to show).
function CouncilSessionDomain:DescribeLocal()
    return self:DescribeVersion(localVersion());
end

--------------------------------------------------------------------------
-- Export
--
-- Payload (positional, spec 4.1):
--   [1] leader fqn   [2] sessionId   [3] startedAt (server)   [4] status
--   [5] endedAt or 0 [6] players: flat name, classId (Codec dictionary)
--   [7] responses: flat id, kind, label, color (the session's own snapshot
--       list - candidates reference these ids, so the ids must travel)
--   [8] council: player indexes (the session council, Session.council)
--   [9] items: { itemLink, flags, awardedToIdx or 0, awardedAt, awardCount,
--                candidates, preVotes }
--       candidate: { playerIdx, responseId, note, respondedAt, approvers,
--                    equipped (flat slot, itemString) }
--       preVote:   { playerIdx, approvers }
--       approvers: player indexes in vote order
-- Session item links travel whole (they end up in history rows and chat);
-- equipped-gear links travel as item strings, which is all the Award window
-- needs (icon, quality, tooltip) and roughly halves the payload.
--------------------------------------------------------------------------

local function approverIndexes(entry, builder)
    local out, seen = {}, {};
    local approvals = entry.approvals or {};
    for _, name in ipairs(entry.voteOrder or {}) do
        if (approvals[name] and not seen[name]) then
            seen[name] = true;
            table.insert(out, builder:PlayerIndex(name, nil));
        end
    end
    local rest = {};
    for name in pairs(approvals) do
        if (not seen[name]) then table.insert(rest, name); end
    end
    table.sort(rest);
    for _, name in ipairs(rest) do table.insert(out, builder:PlayerIndex(name, nil)); end
    return out;
end

local function sortedKeys(t)
    local keys = {};
    for k in pairs(t or {}) do table.insert(keys, k); end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b); end);
    return keys;
end

--- Returns version, payload, info {rev, items} - or nil when we hold no
--- session (or its leader isn't in our group). Ended sessions export too:
--- a SNAP_GET or push for one only happens in the correction case.
function CouncilSessionDomain:Export()
    local version = localVersion();
    if (not version) then return nil; end
    local s = session();

    local builder = FL.Sync.Codec.NewDictBuilder();
    local itemStringFromLink = FL.Sync.Store.ItemStringFromLink;

    local items = {};
    for _, item in ipairs(s.items) do
        local cands = {};
        for _, name in ipairs(sortedKeys(item.candidates)) do
            local c = item.candidates[name];
            local eq = {};
            for _, slot in ipairs(sortedKeys(c.equipped)) do
                local link = c.equipped[slot];
                table.insert(eq, slot);
                table.insert(eq, itemStringFromLink(link) or link);
            end
            table.insert(cands, {
                builder:PlayerIndex(name, c.class), c.response, c.note or "", c.respondedAt or 0,
                approverIndexes(c, builder), eq,
            });
        end

        local pre = {};
        for _, name in ipairs(sortedKeys(item.preVotes)) do
            table.insert(pre, { builder:PlayerIndex(name, nil), approverIndexes(item.preVotes[name], builder) });
        end

        table.insert(items, {
            item.itemLink, item.removedEarly and 1 or 0,
            item.awardedTo and builder:PlayerIndex(item.awardedTo, nil) or 0,
            item.awardedAt or 0, item.awardCount or 0, cands, pre,
        });
    end

    local council = {};
    for _, name in ipairs(sortedKeys(s.council)) do
        table.insert(council, builder:PlayerIndex(name, nil));
    end

    local responses = {};
    for _, r in ipairs(s.responses or {}) do
        table.insert(responses, r.id);
        table.insert(responses, r.kind or "text");
        table.insert(responses, r.label or "");
        table.insert(responses, r.color or "");
    end

    local payload = {
        s.initiatorFqn or "?", s.id, s.startedAtServer or 0,
        (s.status == "active") and STATUS_ACTIVE or STATUS_ENDED, s.endedAt or 0,
        builder:Players(), responses, council, items,
    };
    return version, payload, { rev = s.rev or 0, items = #s.items };
end

--------------------------------------------------------------------------
-- Import
--------------------------------------------------------------------------

local function isNum(v) return type(v) == "number"; end

--- Decodes and validates a payload into the plain session shape
--- LootCouncil.ReplaceSession takes. Returns (plain, councilNames) or
--- (nil, reason).
local function decodePayload(p)
    if (type(p) ~= "table") then return nil, "badType"; end
    local leaderFqn, sessionId, startedAt, status, endedAt, players, responses, roster, items =
        p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9];
    if (type(leaderFqn) ~= "string" or not isNum(sessionId) or not isNum(startedAt) or not isNum(endedAt)) then
        return nil, "badType";
    end
    if (status ~= STATUS_ACTIVE and status ~= STATUS_ENDED) then return nil, "badStatus"; end
    if (type(players) ~= "table" or #players > 2 * MAX_PLAYERS) then return nil, "badPlayers"; end
    if (type(responses) ~= "table" or type(roster) ~= "table" or type(items) ~= "table") then return nil, "badType"; end
    if (#items > MAX_ITEMS) then return nil, "tooManyItems"; end

    local function name(idx)
        if (not isNum(idx)) then return nil; end
        local n = players[2 * idx - 1];
        return (type(n) == "string" and n ~= "") and n or nil;
    end
    local function class(idx)
        return FL.Sync.Codec.ClassToken(players[2 * idx]);
    end
    local function approvers(list)
        if (type(list) ~= "table") then return nil; end
        local approvals, order = {}, {};
        for _, idx in ipairs(list) do
            local n = name(idx);
            if (not n) then return nil; end
            if (not approvals[n]) then
                approvals[n] = true;
                table.insert(order, n);
            end
        end
        return approvals, order;
    end

    local responseList = {};
    for i = 1, #responses, 4 do
        local id, kind, label, color = responses[i], responses[i + 1], responses[i + 2], responses[i + 3];
        if (not isNum(id) or type(kind) ~= "string" or type(label) ~= "string" or type(color) ~= "string") then
            return nil, "badResponses";
        end
        table.insert(responseList, { id = id, kind = kind, label = label, color = color });
    end

    local councilNames = {};
    for _, idx in ipairs(roster) do
        local n = name(idx);
        if (not n) then return nil, "badIndex"; end
        table.insert(councilNames, n);
    end

    local plainItems = {};
    for i, it in ipairs(items) do
        if (type(it) ~= "table") then return nil, "badItem"; end
        local itemLink, flags, awardedToIdx, awardedAt, awardCount, cands, pre =
            it[1], it[2], it[3], it[4], it[5], it[6], it[7];
        if (not Util.isValidItemLink(itemLink) or not isNum(flags) or not isNum(awardedToIdx)
            or not isNum(awardedAt) or not isNum(awardCount) or type(cands) ~= "table" or type(pre) ~= "table") then
            return nil, "badItem";
        end
        if (#cands > MAX_CANDIDATES) then return nil, "tooManyCandidates"; end

        local awardedTo = nil;
        if (awardedToIdx ~= 0) then
            awardedTo = name(awardedToIdx);
            if (not awardedTo) then return nil, "badIndex"; end
        end

        local candidates = {};
        for _, c in ipairs(cands) do
            if (type(c) ~= "table") then return nil, "badCandidate"; end
            local pIdx, responseId, note, respondedAt, approverList, eq = c[1], c[2], c[3], c[4], c[5], c[6];
            local n = name(pIdx);
            if (not n or not isNum(responseId) or type(note) ~= "string" or #note > MAX_NOTE_LEN
                or not isNum(respondedAt) or type(eq) ~= "table") then
                return nil, "badCandidate";
            end
            local approvals, voteOrder = approvers(approverList);
            if (not approvals) then return nil, "badIndex"; end

            local equipped = {};
            for k = 1, #eq, 2 do
                local slot, itemString = eq[k], eq[k + 1];
                if (not isNum(slot) or type(itemString) ~= "string") then return nil, "badEquipped"; end
                if (Util.isValidItemLink(itemString)) then
                    equipped[slot] = itemString; -- sent whole (no item string could be taken from it)
                else
                    local link = select(2, Util.GetItemInfo("item:" .. itemString));
                    equipped[slot] = link or ("item:" .. itemString);
                end
            end

            candidates[n] = {
                class = class(pIdx), response = responseId, note = note, equipped = equipped,
                respondedAt = respondedAt, approvals = approvals, voteOrder = voteOrder,
            };
        end

        local preVotes = nil;
        for _, pv in ipairs(pre) do
            if (type(pv) ~= "table") then return nil, "badPreVote"; end
            local n = name(pv[1]);
            local approvals, voteOrder = approvers(pv[2]);
            if (not n or not approvals) then return nil, "badIndex"; end
            preVotes = preVotes or {};
            preVotes[n] = { approvals = approvals, voteOrder = voteOrder };
        end

        plainItems[i] = {
            itemLink = itemLink, removedEarly = (flags % 2 == 1) or nil, awardedTo = awardedTo,
            awardedAt = (awardedAt ~= 0) and awardedAt or nil,
            awardCount = (awardCount ~= 0) and awardCount or nil,
            candidates = candidates, preVotes = preVotes,
        };
    end

    return {
        id = sessionId,
        initiatorFqn = leaderFqn,
        startedAtServer = startedAt,
        status = (status == STATUS_ACTIVE) and "active" or "ended",
        endedAt = (endedAt ~= 0) and endedAt or nil,
        responses = responseList,
        items = plainItems,
    }, councilNames;
end
CouncilSessionDomain.DecodePayload = decodePayload;

--- Validates `payload` and applies it when `version` is newer than ours.
--- Returns result ("applied" | "stale" | "invalid"), oldRev, newRev, reason.
function CouncilSessionDomain:Import(version, payload, sender)
    local current = session();
    local oldRev = current and current.rev or 0;
    if (not validVersion(version)) then return "invalid", oldRev, 0, "badVersion"; end
    local newRev = version[3];

    local plain, councilOrReason = decodePayload(payload);
    if (not plain) then return "invalid", oldRev, newRev, councilOrReason; end
    if (plain.id ~= version[1] or not Util.iEquals(Util.stripRealm(plain.initiatorFqn), version[5])
        or (plain.status ~= "active") ~= (version[4] == 1)) then
        return "invalid", oldRev, newRev, "versionMismatch";
    end

    local leaderIsMe = Util.iEquals(plain.initiatorFqn, Util.playerFqn());
    if (not leaderIsMe and not inMyGroup(version[5])) then return "invalid", oldRev, newRev, "leaderNotInGroup"; end
    if (not inMyGroup(sender)) then return "invalid", oldRev, newRev, "senderNotInGroup"; end

    if (self:Compare(version, sender) ~= "remoteNewer") then return "stale", oldRev, newRev; end

    plain.rev = newRev;
    plain.initiatorIsMe = leaderIsMe;
    FL.LootCouncil.ReplaceSession(plain, councilOrReason);
    return "applied", oldRev, newRev;
end

--- Registered from Init (not at file load - see Sync/Domains.lua's header).
--- Also fills in the Phase 7 fields on a session saved before they existed.
function CouncilSessionDomain.Init()
    local s = session();
    if (s) then
        s.rev = s.rev or 1;
        s.startedAtServer = s.startedAtServer or 0;
    end
    FL.Sync.Domains.Register(CouncilSessionDomain);
end
