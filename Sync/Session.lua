--[[
Sync sessions with one primary peer (spec sections 7.3, 12.3): turns
Sync/Coordinator.lua's Phase 4 dry-run plan into a real session that
transfers whatever two clients' loot-history stores disagree on. After this
phase, the plan's own success test applies: `/fl sync digest` prints
identical roots on both clients once a session completes.

Phase 5 only opens full-mode sessions with a domain's single primary
responder (plan's own build list: "secondaries are ignored until phase 6"),
and only for "set"-strategy domains (history, domain 1 - the only one
registered until Phase 7's council-session domain).

State machine (spec 12.3): an OPENER session moves
OPENING -> COMPARING -> RECONCILING -> DONE, owns the mismatched-bucket
queue, and decides when the whole session is finished. A SERVER session
stays in SERVING the entire time and is purely reactive - it never builds
its own bucket queue, it just answers whatever MONTHS/HASHES/WANT arrives,
until the opener's DONE closes it out. This matches spec 12.3's table
exactly: COMPARING/RECONCILING are opener-only states; SERVING is the
server's only state.

Deviations from spec section 6's abbreviated message catalog (recorded in
full in docs/sync-deviations.md "Phase 5"):
- HASHES/WANT carry an explicit `tree, key` pair (spec's table omits this,
  describing WANT as just "a list of entry hashes") - needed so up to
  BUCKETS_IN_FLIGHT buckets can be reconciled concurrently without the two
  exchanges for different buckets becoming ambiguous.
- HASHES/WANT also carry an `idMode` flag: when Digest.HasCollision(tree,key)
  is true for the sending side's own copy of a bucket (spec 5.6), that side
  sends raw "kind:id" strings instead of 32-bit hashes for that one
  exchange, and says so via this flag - the fallback spec 5.6 describes,
  implemented as a per-message mode bit rather than a renegotiated bucket.
- DAYS carries the server's own `mismatchedMonths` key list alongside its
  day aggregates, and the archive-tier MONTHS reply always lists one entry
  per mismatched month even when that month is empty on the server's side -
  both exist so the opener can correctly diff a month that differs ONLY
  because the SERVER has nothing in it at all (which would otherwise leave
  that month's days completely absent from the reply, not just empty).
- ROWS/MARKS append `tree, key, batchIndex, totalBatches` after their
  spec-listed fields, so the receiver knows which bucket's WANT a batch is
  answering and whether it has ALL of that want's batches yet (not just
  "the one marked last" - see the batchIndex/totalBatches bullet below for
  why that distinction matters) - spec 4.7's forward-compatibility rule
  ("new fields may only be appended") is about a ROW's own fields, but the
  same reasoning (older decoders ignore trailing fields) applies to the
  enclosing batch envelope just as well. MARKS also gains a `batchNum` field
  (ROWS already has one per spec) at the same position, purely so the
  receiver's "batch in #N" log line can read it the same way regardless of
  which kind arrived.
- WANT is always sent in reply to HASHES, even with an empty list, instead
  of only when something is actually missing. Without this, "the peer's
  WANT hasn't arrived yet" and "the peer wants nothing from me" are
  indistinguishable on the receiving side (both leave its give-count at
  zero), which would finish a bucket - and on the opener, possibly the
  whole session - before the peer's real request has even been sent.
  maybeFinishBucket()'s own comment has the full reasoning.
- DAYS and the archive-tier MONTHS reply are capped at DAYS_BATCH_SIZE
  tuples per message and sent as however many messages that takes, same
  idea as ROWS/MARKS' own batching - found necessary in Phase 5 testing when
  a single large DAYS reply (a big backfill mismatching several months)
  reliably failed to decompress on arrival. See sendFlatBatches() and
  docs/sync-deviations.md "Phase 5".
- Every batched message (DAYS, archive-MONTHS-reply, ROWS, MARKS) tags
  itself with `batchIndex, totalBatches`, NOT a single "isLast" boolean on
  the final one. Found necessary live, the hard way: a middle batch (in one
  case, an entire month's worth of days) was lost while the batch marked
  "last" still arrived, and the receiver - having only ever checked for
  "last", never "all of them" - declared the compare phase (or a bucket's
  WANT) complete with a silent gap in the middle. A session can report
  `done` and look completely healthy while still missing real data this
  way, which is worse than an outright failure since nothing ever signals
  that anything is wrong. The receiver now tracks every index it has
  actually seen and only proceeds once the count matches `totalBatches`.
- A bucket's WANT is retried (resent as-is) every WANT_RETRY_DELAY seconds,
  up to WANT_RETRY_MAX times, if its ROWS/MARKS response hasn't arrived -
  found necessary when Net/Transport.lua's per-target serialization and
  pacing (see that file's own comments) still weren't enough to stop this
  server from occasionally losing a message outright. Without this, one
  lost bulk batch stalls the WHOLE session until SESSION_IDLE_TIMEOUT,
  discarding every other bucket's already-completed work just to restart
  from a fresh HELLO. The symmetric case (a lost HASHES, a lost HASHES
  reply, or a lost empty WANT) is covered by the opener's HASHES retry with
  an explicit isRetry flag - see scheduleHashesRetry.
- The COMPARING phase gets the identical retry treatment: beginCompare
  retries an unanswered MONTHS request (COMPARE_RETRY_DELAY/_MAX) exactly
  like a bucket's WANT, since even an ISOLATED, uncontended DAYS reply (the
  very first message of a fresh session, nothing else competing for
  bandwidth) was still observed to occasionally lose a chunk and fail to
  deserialize - a baseline loss rate Net/Transport.lua's pacing can reduce
  but not eliminate.
- Every MONTHS request carries a generation number (session.windowGen /
  .archiveGen), echoed back on every DAYS/archive-MONTHS-reply batch.
  scheduleCompareRetry bumps it (and resets the accumulated reply) on every
  retry; onDays/onMonths drop any batch whose echoed gen doesn't match the
  CURRENT one. Needed because a retry's own reset isn't enough by itself: a
  straggler batch from the attempt JUST retried past - delayed, not actually
  lost, this server's behavior isn't perfectly predictable - can still
  arrive AFTER the reset and, without the generation check, get silently
  merged into the new attempt's data, producing an incomplete bucket list
  that doesn't cover anywhere near the true mismatch. Observed live: a
  session finished and reported "done" with a bucket count far too small
  for how large the real divergence was. See docs/sync-deviations.md
  "Phase 5".

Phase 6 (spec 7.4, 9.2): parallel pull from up to MAX_SECONDARIES secondaries,
plus real multi-prefix concurrency within one session. See
docs/sync-deviations.md "Phase 6" for the full writeup; summarized here:

- **Round-robin bucket assignment happens in tryFinishCompare, once the real
  mismatched-bucket list is known** - not in Sync/Coordinator.lua at
  responder-selection time, since nobody knows which buckets actually
  mismatch until the primary's own COMPARING phase finishes. Coordinator
  only chooses WHO the candidates are (unchanged from Phase 5); Session.lua
  (assignBucketsWithSecondaries) decides WHICH buckets each one gets.
- **The primary's own full-mode session keeps the FULL bucket list**, not
  just its round-robin share - spec 7.4 step 3: "The primary session still
  handles the push direction for every bucket." Every bucket still gets a
  real HASHES exchange with the primary (so the primary learns what IT is
  missing from us - push, unaffected by delegation), but a bucket delegated
  to a secondary (`bucket.delegated`) has its OWN want forced to empty
  (`skipWant` in onHashesReceived) - we deliberately don't pull that bucket's
  data from the primary, since a secondary is getting it for us instead.
  The real remote hash list is still saved (`bucket.remoteList`/
  `.remoteIdMode`) so a later reassignment (below) can use it WITHOUT a
  second network round trip.
- **Pull mode reuses the full-mode bucket machinery** (advanceBuckets,
  getOrCreateBucket, onHashesReceived, onWantReceived, maybeFinishBucket,
  drainOutgoing) rather than a parallel implementation, with role/mode
  checks at the few points that differ: a pull-mode SERVER (a secondary)
  never sends a real WANT (spec 6 notes: "a secondary never requests data
  from the opener" - same `skipWant` mechanism as a delegated bucket), and
  a pull session's own finish condition only needs ITS applicable half
  (opener: wantDone only; server: giveDone only - see maybeFinishBucket).
  A pull-mode opener also skips the COMPARING state entirely (onOpenReply):
  it already knows its exact bucket list from the primary's compare, so it
  jumps straight to RECONCILING.
- **`OPEN`'s pull-mode body carries explicit `tree,key` pairs, not spec 6's
  bare "day keys"** - same reasoning as the existing HASHES/WANT `tree,key`
  deviation (Phase 5): a bare integer key is ambiguous between a window day
  bucket and an archive month bucket once both trees can be in play.
- **Reassignment on abort/timeout/refusal** (spec 7.4 step 4): a pull
  session keeps `assignedBuckets` (its original full assignment) alongside
  its own `buckets` map; on abort, `reportSecondaryFinished` compares the
  two to find whatever never finished and calls `reassignBucketToPrimary`
  for each - which flips `bucket.delegated` back off and re-runs the want
  computation using the ALREADY-SAVED `remoteList` (no re-request needed,
  per the point above). The primary session's own completion
  (`advanceBuckets`'s finish check) is gated on `secondariesRemaining <= 0`
  in addition to its own queue/in-flight being empty, so the primary can't
  declare the domain done while a secondary (or its reassigned leftovers)
  is still outstanding.
- **Multi-prefix concurrency within one session** (spec 9.2: "at most one
  batch in flight per prefix"): Phase 5's drainOutgoing serialized a WHOLE
  session to one batch in flight at a time (needed then, for the per-target
  Transport.lua serialization bug - see that file's own Phase 5 comment).
  Phase 6 relaxes this to one batch in flight PER sync prefix
  (`session.prefixBusy`, `Net/Transport.lua`'s new `opts.prefix` override) -
  safe because Transport's own per-(prefix,distribution,target) queueing
  still serializes same-prefix sends to the same peer; different prefixes
  to the SAME peer were always safe to run concurrently (separate AceComm
  multipart-spool slots), Phase 5 just never exploited that.
- **Per-session byte/rate instrumentation** (`[PERF] rate ...`, spec's own
  sample): `session.recvBytes` is now tracked directly from
  `Net/Transport.lua`'s real per-message wire size (a new 4th argument on
  every registered handler), not estimated from a row-count average.
- **The domain-wide "[SESS] sync complete ..." line** is logged by the
  PRIMARY session only, once every secondary has reported in (success or
  reassigned), combining `session.recv` (primary's own) with
  `session.secondaryRecvTotal` (accumulated as each secondary finishes).

Phase 6 review fixes (docs/sync-deviations.md "Phase 6 review"):
- A bucket reclaimed from a failed secondary before the primary reached it
  is no longer skipped (`session.reclaimed`), and a FINISHED secondary's
  buckets get a top-up check against the primary's saved hash list, since a
  secondary isn't guaranteed to hold everything the primary does.
- PING keeps the primary peer's side alive while we wait on secondaries.
- Full-mode openers wait for DONE_ACK (state FINISHING) before closing, and
  re-send whatever the server says it's still missing.
- Every retry timer is armed from its message's send confirmation, not
  from enqueue (sendControl).
- A primary that refuses OPEN is replaced by the first secondary.
]]

local FL = ForeverLoot;
local Session = FL.Sync.Session;
local Util = FL.Util;
local Constants = FL.Sync.Constants;
local MSG = Constants.MSG;
local Codec = FL.Sync.Codec;
local Transport = FL.Sync.Transport;
local Gate = FL.Sync.Gate;
local Scheduler = FL.Sync.Scheduler;

local bxor = bit.bxor;
local TWO32 = 4294967296;

local sessions = {};       -- [token] = session
local servingCount = 0;    -- active role=="server" sessions
local maxServeOverride;    -- /fl debug maxserve <n>, nil = use Constants.MAX_SERVE
local BUSY_RETRY_AFTER = 60; -- seconds suggested to a refused opener (spec 7.6: MAX_SERVE refusal)

-- [peerName] = { recvAdded, recvOther, sent } - lifetime (since login) row
-- totals per peer, independent of any single session's own counters (which
-- disappear once that session closes). Exists purely to back UI/
-- SyncStatusWindow.lua's "how many rows am I getting from each peer" view -
-- nothing in the protocol itself reads this.
local peerTotals = {};

local function notePeerRecv(peer, added, other)
    local t = peerTotals[peer] or { recvAdded = 0, recvOther = 0, sent = 0 };
    t.recvAdded = t.recvAdded + added;
    t.recvOther = t.recvOther + other;
    peerTotals[peer] = t;
end

local function notePeerSent(peer, count)
    local t = peerTotals[peer] or { recvAdded = 0, recvOther = 0, sent = 0 };
    t.sent = t.sent + count;
    peerTotals[peer] = t;
end

-- Callbacks run once per session as it closes, for any reason - see
-- Session.OnEnded.
local endedCallbacks = {};

local TOKEN_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
local function newToken()
    local out = {};
    for i = 1, 4 do
        local idx = math.random(#TOKEN_CHARS);
        out[i] = TOKEN_CHARS:sub(idx, idx);
    end
    return table.concat(out);
end

local function maxServe()
    return maxServeOverride or Constants.MAX_SERVE;
end

--- "sync with Bolvar (#a3F9)" - how every session line names its session.
local function label(session)
    return ("sync with %s (#%s)"):format(tostring(session.peer), tostring(session.token));
end

local function labelFor(token, peer)
    return ("sync with %s (#%s)"):format(tostring(peer), tostring(token));
end

local function treeWord(tree)
    return (tree == "W") and "recent" or "archive";
end

-- Looked up per call: Sync/Debug.lua (which defines it) loads after this file.
local function fmtTime(seconds) return FL.Sync.Debug.FormatTime(seconds); end

--------------------------------------------------------------------------
-- Small pure helpers: month/day aggregate diffing, hash-set membership,
-- root reconstruction from a rolled-up month/day list.
--------------------------------------------------------------------------

--- "2026-09" from a spec 5.3 month key - matches Sync/Debug.lua's own
--- (private) monthKeyToLabel, duplicated here rather than exported since
--- it's a one-line formatter and Debug.lua has no reason to depend on
--- Session.lua or vice versa.
local function monthKeyLabel(monthKey)
    return ("%04d-%02d"):format(math.floor(monthKey / 12), (monthKey % 12) + 1);
end

local function flattenAggList(list, keyField)
    local flat = {};
    for _, m in ipairs(list) do
        table.insert(flat, m[keyField]); table.insert(flat, m.count); table.insert(flat, m.x); table.insert(flat, m.s);
    end
    return flat;
end

--- Every monthKey where `localMonths` (array of {monthKey,count,x,s}) and
--- `remoteFlat` (wire-flat monthKey,count,x,s,...) disagree, including a
--- month present on only one side.
local function diffMonths(localMonths, remoteFlat)
    local remoteByKey, localByKey, mismatched, seen = {}, {}, {}, {};
    for i = 1, #remoteFlat, 4 do
        remoteByKey[remoteFlat[i]] = { count = remoteFlat[i + 1], x = remoteFlat[i + 2], s = remoteFlat[i + 3] };
    end
    for _, m in ipairs(localMonths) do localByKey[m.monthKey] = m; end

    for key, m in pairs(localByKey) do
        seen[key] = true;
        local r = remoteByKey[key];
        if (not r or r.count ~= m.count or r.x ~= m.x or r.s ~= m.s) then table.insert(mismatched, key); end
    end
    for key in pairs(remoteByKey) do
        if (not seen[key]) then table.insert(mismatched, key); end
    end
    return mismatched;
end

--- Day-level buckets that actually differ within `mismatchedMonths`, unioning
--- the opener's own days for those months with whatever days the server's
--- DAYS reply named (spec's own description of this step), so a day missing
--- entirely from one side still surfaces as a mismatch rather than being
--- silently skipped.
local function buildDayBuckets(Digest, mismatchedMonths, remoteFlatDays)
    local remoteByDay, seen = {}, {};
    for i = 1, #remoteFlatDays, 4 do
        remoteByDay[remoteFlatDays[i]] = { count = remoteFlatDays[i + 1], x = remoteFlatDays[i + 2], s = remoteFlatDays[i + 3] };
    end
    for _, monthKey in ipairs(mismatchedMonths or {}) do
        for _, d in ipairs(Digest.DaysInMonth(monthKey)) do seen[d.dayKey] = true; end
    end
    for dayKey in pairs(remoteByDay) do seen[dayKey] = true; end

    local zero = { count = 0, x = 0, s = 0 };
    local out = {};
    for dayKey in pairs(seen) do
        local localAgg = Digest.Bucket("W", dayKey);
        local remoteAgg = remoteByDay[dayKey] or zero;
        if (localAgg.count ~= remoteAgg.count or localAgg.x ~= remoteAgg.x or localAgg.s ~= remoteAgg.s) then
            table.insert(out, dayKey);
        end
    end
    return out;
end

local function rollupAgg(flat)
    local count, x, s = 0, 0, 0;
    for i = 1, #flat, 4 do
        count = count + flat[i + 1];
        x = bxor(x, flat[i + 2]);
        s = (s + flat[i + 3]) % TWO32;
    end
    return { count = count, x = x, s = s };
end

local function aggEqual(a, b)
    return a and b and a.count == b.count and a.x == b.x and a.s == b.s;
end

local function missingFrom(theirList, myList)
    local mine = {};
    for _, v in ipairs(myList) do mine[v] = true; end
    local missing = {};
    for _, v in ipairs(theirList) do
        if (not mine[v]) then table.insert(missing, v); end
    end
    return missing;
end

--------------------------------------------------------------------------
-- Session lifecycle: creation, idle timeout, abort/close, cleanup.
--------------------------------------------------------------------------

local RETRY_AFTER_ABORT = 30; -- seconds (+-10) before rediscovering after a full session aborted mid-way
local abortSession; -- forward declaration: resetIdleTimer's timer closure below captures this local and calls whatever it's later assigned to (defined further down this file)
local reportSecondaryFinished; -- forward declaration (Phase 6): abortSession and onOpenReply's busy-refusal path both call this for a pull-mode session, before its own dependencies (advanceBuckets etc.) are defined
local drainOutgoing; -- forward declaration: releasePrefix (just above it) calls back into it
local trySessionComplete; -- forward declaration (Phase 6 fix): drainOutgoing's onSent/onFail (defined before advanceBuckets/finishSessionAsOpener exist as locals) need to re-check completion once a send actually confirms - see trySessionComplete's own comment, further down

local function resetIdleTimer(session)
    if (session.idleTimer) then Scheduler.Cancel(session.idleTimer); end
    session.idleTimer = Scheduler.After(Constants.SESSION_IDLE_TIMEOUT, 0, function()
        abortSession(session, "timeout");
    end, "sessionIdle");
end
-- Phase 6 review: traffic on a secondary's pull session also keeps its
-- parent (the primary's full session) alive. The primary's own buckets
-- often finish well before its secondaries do; with nothing arriving from
-- the primary peer in that gap, the parent used to hit SESSION_IDLE_TIMEOUT
-- and close, after which a failing secondary had nowhere to hand its
-- buckets back to. The primary PEER's side is kept alive separately, by
-- PING (see startParentKeepalive).
local function touchSession(session)
    resetIdleTimer(session);
    local parent = session.parent;
    if (parent and not parent.closed) then resetIdleTimer(parent); end
end

local function cleanupSession(session)
    sessions[session.token] = nil;
    if (session.role == "server") then
        servingCount = math.max(0, servingCount - 1);
    end
    for _, cb in ipairs(endedCallbacks) do pcall(cb, session); end
end

--- Adds a new session to `sessions` and starts its idle timer. Also notes
--- both sides' window counts at the start, so the settings page can
--- estimate how many rows are still to come. The peer's count is the one
--- its OPEN was planned from (opener) or its last HELLO (server).
local function trackSession(session)
    sessions[session.token] = session;
    session.startLocalCount = FL.Sync.Digest.Root("W").count;
    local remote = session.remoteWindowRoot and session.remoteWindowRoot.count;
    if (not remote) then
        local summary = FL.Sync.Peers.SummaryOf(session.peer, session.domainId);
        remote = (type(summary) == "table") and summary[1] or nil;
    end
    session.startRemoteCount = remote;
    resetIdleTimer(session);
end

--- Called by every handler for a message that actually arrived from the
--- peer on this session (unlike touchSession, which sends and child-session
--- traffic also call). `lastHeardAt` is the only reliable "is the peer
--- still alive" signal - see onOpen's duplicate check and the parent
--- keepalive, which both used to be fooled by our own activity.
local function heardFrom(session)
    session.lastHeardAt = GetTime();
    touchSession(session);
end

local function closeSession(session)
    if (session.closed) then return; end
    session.closed = true;
    if (session.idleTimer) then Scheduler.Cancel(session.idleTimer); end
    cleanupSession(session);
end

abortSession = function(session, reason, skipSend)
    if (not session or session.closed) then return; end
    session.closed = true;
    session.endReason = reason;
    if (session.idleTimer) then Scheduler.Cancel(session.idleTimer); end

    local progress = session.bucketsTotalKnown and ("%d/%d"):format(session.bucketsDone or 0, session.bucketsTotalKnown) or "?";
    FL.Sync.Debug.Log("SESS", 1, "%s: stopped early · %s, while %s, %s buckets done", label(session), tostring(reason),
        tostring(session.state):lower(), progress);

    if (not skipSend) then
        pcall(function()
            local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.ABORT, session.token, reason });
            Transport.Send(MSG.ABORT, encoded, "WHISPER", session.peer, { prio = "NORMAL" });
        end);
    end

    -- Phase 6: a secondary's unfinished buckets go back to the primary's
    -- queue (spec 7.4 step 4) - see this file's header comment and
    -- reportSecondaryFinished's own comment below.
    if (session.mode == "pull" and session.parent) then
        reportSecondaryFinished(session.parent, session, reason);
    end

    -- An opener's full session that died mid-way (peer gone, timeout) left
    -- work undone. Spec 8 leaves that to "the next HELLO", which could be a
    -- 12-minute periodic check away - ask for one ~30s from now instead.
    -- Not for gate aborts (the instance-exit trigger covers those) or
    -- duplicates (the surviving session covers the work).
    if (session.role == "opener" and session.mode == "full" and reason ~= "gate" and reason ~= "dup") then
        -- Waits (up to ~10 checks) for anything still running - e.g. the
        -- aborted primary's secondary, still pulling its share - to finish
        -- first, so the rediscovery compares against the final state.
        local checks = 0;
        local function retryWhenIdle()
            checks = checks + 1;
            if (Session.AnyActive() and checks < 10) then
                Scheduler.After(RETRY_AFTER_ABORT, 0, retryWhenIdle, "retryAfterAbort");
                return;
            end
            FL.Sync.Coordinator.RetryAfterAbort(session.domain);
        end
        Scheduler.After(RETRY_AFTER_ABORT, 10, retryWhenIdle, "retryAfterAbort");
    end

    cleanupSession(session);
end

--- Logs the plan's own sample "[SESS] k7Q2 state COMPARING->RECONCILING"
--- line (opener-only transitions: OPENING->COMPARING, COMPARING->RECONCILING).
local function setState(session, newState)
    FL.Sync.Debug.Log("SESS", 1, "%s: %s -> %s", label(session), tostring(session.state):lower(), tostring(newState):lower());
    session.state = newState;
end

local function getOrCreateBucket(session, tree, key)
    local k = tree .. ":" .. key;
    local b = session.buckets[k];
    if (not b) then
        b = { tree = tree, key = key, sentHashesOut = false, recvHashesIn = false, wantCount = 0, giveCount = 0 };
        session.buckets[k] = b;
        session.bucketsSeen = (session.bucketsSeen or 0) + 1;
    end
    return b;
end

--------------------------------------------------------------------------
-- Outgoing data-plane queue: ROWS/MARKS batches, drained one at a time,
-- queuing the next only once Net/Transport.lua's onSent confirms the
-- previous one actually went out (spec 9.2's backpressure rule - this is
-- the thing this phase's own deviations.md entry flagged as needing
-- Transport's onSent bug fixed first; see that file).
--------------------------------------------------------------------------

-- chunk.batchIndex/chunk.totalBatches (not a single "isLast" boolean on the
-- final chunk) - same fix, same reason, as sendFlatBatches' own comment: a
-- lost middle chunk while the one marked "last" still arrives must not look
-- like a complete transfer. The receiver tracks every index it's actually
-- seen and only treats the bucket as satisfied once all of them have.
local function buildBatchBody(session, chunk)
    session.outBatchNum = session.outBatchNum + 1;
    local batchNum = session.outBatchNum;
    if (chunk.kind == "ROWS") then
        return { Constants.PROTO_VERSION, MSG.ROWS, session.token, batchNum, chunk.players, chunk.types, chunk.wireRows, chunk.tree, chunk.key, chunk.batchIndex, chunk.totalBatches }, batchNum;
    end
    -- batchNum sits at the same position (4) as ROWS, even though spec
    -- section 6's MARKS body has no such field - sharing one session-wide
    -- counter across both message kinds lets the receiver's "batch in #N"
    -- line (plan Phase 5's own sample) read position 4 the same way
    -- regardless of which kind arrived.
    return { Constants.PROTO_VERSION, MSG.MARKS, session.token, batchNum, chunk.players, chunk.flat, chunk.tree, chunk.key, chunk.batchIndex, chunk.totalBatches }, batchNum;
end

-- Phase 6: one batch in flight PER SYNC PREFIX, not one for the whole
-- session (spec 9.2: "at most one batch in flight per prefix"). Phase 5's
-- single `session.sendingBatch` gate was needed then because
-- Net/Transport.lua's per-target serialization bug (see that file's own
-- comment) hadn't been fixed yet; now that Transport queues strictly per
-- (prefix, distribution, target), two batches to the SAME peer on
-- DIFFERENT prefixes were always safe to run concurrently - this just
-- starts exploiting that for real throughput instead of rotating prefixes
-- one-at-a-time for no concurrency gain.
local function pickFreePrefix(session)
    local prefixes = Constants.PREFIX_SYNC;
    local n = #prefixes;
    for _ = 1, n do
        session.prefixCursor = (session.prefixCursor % n) + 1;
        local p = prefixes[session.prefixCursor];
        if (not session.prefixBusy[p]) then return p; end
    end
    return nil; -- every sync prefix already has a batch in flight for this session
end

--- True while this session has any batch actually in flight on the wire
--- (as opposed to merely queued) - see trySessionComplete's own comment
--- (Phase 6 bug fix) for why this distinction matters.
local function anyPrefixBusy(session)
    local prefixes = Constants.PREFIX_SYNC;
    for i = 1, #prefixes do
        if (session.prefixBusy[prefixes[i]]) then return true; end
    end
    return false;
end

-- How long a batch that hit Net/Transport.lua's send-queue timeout keeps its
-- prefix marked busy while we wait for its late real callback (onLate). A
-- timeout there means "no answer yet", not "lost" - releasing the prefix
-- immediately used to let trySessionComplete send DONE while the batch was
-- still sitting in ChatThrottleLib's BULK queue (DONE, at NORMAL priority,
-- then overtook it). See docs/sync-deviations.md "Phase 6 review".
local BATCH_LATE_GRACE = 30;

local function releasePrefix(session, prefix, batchNum)
    if (session.prefixBusy[prefix] ~= batchNum) then return; end -- already released, or reused by a later batch
    session.prefixBusy[prefix] = nil;
    if (not session.closed) then drainOutgoing(session); trySessionComplete(session); end
end

drainOutgoing = function(session)
    if (session.closed) then return; end

    while (#session.outQueue > 0) do
        local prefix = pickFreePrefix(session);
        if (not prefix) then return; end -- wait for one to free up via onSent/onFail below

        local chunk = table.remove(session.outQueue, 1);
        local body, batchNum = buildBatchBody(session, chunk);
        local encoded, stats = Codec.EncodeMessage(body);
        local msgType = (chunk.kind == "ROWS") and MSG.ROWS or MSG.MARKS;

        if (chunk.kind == "ROWS") then session.sent = session.sent + chunk.count;
        else session.marksSent = session.marksSent + chunk.count; end
        notePeerSent(session.peer, chunk.count);

        session.prefixBusy[prefix] = batchNum; -- the batch number, not just `true`, so a late release can't free a prefix a newer batch now owns
        local startedAt = GetTime();
        -- onQueued (not the return value) is what guarantees "batch out" prints
        -- before "batch sent": ChatThrottleLib can call onSent/onFail
        -- SYNCHRONOUSLY from inside Transport.Send when bandwidth is available,
        -- so logging after Transport.Send returns would sometimes print the
        -- "sent" line first. See Net/Transport.lua's own comment on onQueued.
        Transport.Send(msgType, encoded, "WHISPER", session.peer, {
            prio = "BULK", prefix = prefix,
            onQueued = function()
                FL.Sync.Debug.Log("SESS", 2, "%s: sending batch %d · %d %s, %s, prefix %s",
                    label(session), batchNum, chunk.count, (chunk.kind == "ROWS") and "rows" or "pins/deletes",
                    FL.Sync.Debug.FormatBytes(stats.enc), prefix);
            end,
            onSent = function()
                FL.Sync.Debug.Log("SESS", 2, "%s: sent batch %d · took %s", label(session), batchNum, fmtTime(GetTime() - startedAt));
                if (not session.closed) then touchSession(session); end
                releasePrefix(session, prefix, batchNum);
            end,
            onFail = function(reason)
                if (reason == "timeout") then
                    -- Possibly still queued in ChatThrottleLib, not lost -
                    -- keep the prefix busy until onLate, or the grace runs out.
                    FL.Sync.Debug.Warn("SESS", "%s: batch %d is slow to send · waiting up to %ds more (prefix %s)",
                        label(session), batchNum, BATCH_LATE_GRACE, prefix);
                    Scheduler.After(BATCH_LATE_GRACE, 0, function() releasePrefix(session, prefix, batchNum); end, "batchLateGrace");
                    return;
                end
                FL.Sync.Debug.Warn("SESS", "%s: batch %d FAILED to send (prefix %s)", label(session), batchNum, prefix);
                releasePrefix(session, prefix, batchNum);
            end,
            onLate = function(ok)
                FL.Sync.Debug.Log("SESS", 2, "%s: slow batch %d finally %s · after %s", label(session), batchNum,
                    ok and "sent" or "failed", fmtTime(GetTime() - startedAt));
                releasePrefix(session, prefix, batchNum);
            end,
        });
    end
end

--------------------------------------------------------------------------
-- Per-bucket HASHES/WANT exchange (shared by both roles - see this file's
-- header comment on why the actual exchange, once a bucket is in play, is
-- symmetric regardless of who's the opener).
--------------------------------------------------------------------------

--- Phase 6 review: every retry timer (HASHES, WANT, compare) is armed from
--- the message's own send confirmation, not from when it was queued. Every
--- NORMAL-priority FLoot message to every peer waits in ONE
--- ChatThrottleLib FIFO (see Net/Transport.lua's header), so a message can
--- easily sit there longer than a retry delay; a timer started at enqueue
--- then fired a retry for a message that hadn't even left yet, adding more
--- traffic to the very queue that was slow. `afterSend` runs once, on
--- onSent or onFail (Transport guarantees one of them fires).
local function sendControl(session, msgType, body, afterSend)
    local encoded = Codec.EncodeMessage(body);
    local opts = { prio = "NORMAL" };
    if (afterSend) then
        opts.onSent = function() afterSend(); end;
        opts.onFail = function() afterSend(); end;
    end
    Transport.Send(msgType, encoded, "WHISPER", session.peer, opts);
end

--- `isRetry` (Phase 6 fix - see scheduleHashesRetry below) tags this send as
--- a resend of an already-sent bucket, not a fresh one - appended as a new
--- trailing field (spec 4.7's "new fields may only be appended" rule).
local function sendHashesForBucket(session, bucket, isRetry, afterSend)
    local Digest = session.domain:Tree();
    local collision = Digest.HasCollision(bucket.tree, bucket.key);
    local entries = Digest.EntriesInBucket(bucket.tree, bucket.key);

    local list = {};
    for _, e in ipairs(entries) do
        table.insert(list, collision and (e.kind .. ":" .. e.id) or e.hash);
    end

    bucket.myIdMode = collision;
    bucket.myEntries = entries;
    bucket.myRawList = list;
    bucket.sentHashesOut = true;
    bucket.myLookup = nil; -- invalidate myLookupFor's cache - myEntries/myIdMode were just rebuilt above

    if (collision) then
        FL.Sync.Debug.Warn("SESS", "%s: hash collision in %s %s · comparing full id lists instead",
            label(session), (bucket.tree == "W") and "day" or "month", tostring(bucket.key));
    end

    sendControl(session, MSG.HASHES, { Constants.PROTO_VERSION, MSG.HASHES, session.token, bucket.tree, bucket.key, collision and 1 or 0, list, isRetry and 1 or 0 }, afterSend);
end

-- Phase 6 fix (closes the Phase 5 "known gap, not yet fixed" - see
-- docs/sync-deviations.md): a bucket's very first HASHES exchange had no
-- retry at all, unlike WANT and the compare phase (both fixed in Phase 5).
-- Observed live: all 3 of a fresh RECONCILING session's initial HASHES
-- sends went unanswered and the session simply sat dead until the 45s
-- idle timeout - with BUCKETS_IN_FLIGHT already saturated by stuck
-- buckets, advanceBuckets could never even try a different one.
--
-- Only the OPENER schedules this (called once, right after advanceBuckets'
-- own sendHashesForBucket - never from inside sendHashesForBucket itself,
-- so a server-role reactive reply never starts its own timer). This is
-- what avoids the ping-pong risk the Phase 5 deviations entry flagged for
-- a naive "always reply to any incoming HASHES" rule: the RESPONDER never
-- initiates on its own schedule, it only ever reacts to an explicit
-- `isRetry` flag the OPENER sets - and the opener's retries are themselves
-- capped at HASHES_RETRY_MAX, so the total number of round trips this can
-- ever produce is bounded regardless of what either side does.
local HASHES_RETRY_DELAY = 8;
local HASHES_RETRY_MAX = 3;

-- Phase 6 review: retrying stops only once the peer's WANT has arrived too,
-- not just its HASHES. An EMPTY WANT (the side that already has everything)
-- is never retried by its sender (scheduleWantRetry only runs for a
-- non-empty want), so when one was lost the opener's giveDone never became
-- true and the bucket held an in-flight slot until the session idled out.
-- A HASHES resend with isRetry makes the peer resend both its HASHES and its
-- WANT (onHashesReceived always sends a WANT). Pull-mode openers never give,
-- so they only need the HASHES.
local function scheduleHashesRetry(session, bucket, tree, key)
    Scheduler.After(HASHES_RETRY_DELAY, 0, function()
        if (session.closed or bucket.finished) then return; end
        if (bucket.recvHashesIn and (bucket.recvWant or session.mode == "pull")) then return; end
        bucket.hashesRetries = (bucket.hashesRetries or 0) + 1;
        if (bucket.hashesRetries > HASHES_RETRY_MAX) then
            FL.Sync.Debug.Warn("SESS", "%s: gave up on bucket %s · no hashes after %d tries", label(session), tostring(key), HASHES_RETRY_MAX);
            return;
        end
        FL.Sync.Debug.Log("SESS", 1, "%s: no hashes for bucket %s yet · asking again (retry %d/%d)",
            label(session), tostring(key), bucket.hashesRetries, HASHES_RETRY_MAX);
        sendHashesForBucket(session, bucket, true, function() scheduleHashesRetry(session, bucket, tree, key); end);
    end, "hashesRetry");
end

local function myLookupFor(bucket)
    if (not bucket.myLookup) then
        local map = {};
        for _, e in ipairs(bucket.myEntries) do
            map[bucket.myIdMode and (e.kind .. ":" .. e.id) or e.hash] = { kind = e.kind, id = e.id };
        end
        bucket.myLookup = map;
    end
    return bucket.myLookup;
end

local advanceBuckets;        -- forward declaration, assigned further down this file
local finishSessionAsOpener; -- forward declaration, assigned further down this file

local function maybeFinishBucket(session, bucket)
    if (not bucket.sentHashesOut or not bucket.recvHashesIn) then return; end
    -- `wantDone` is a purely local fact the instant HASHES is compared (I
    -- either need nothing, or I'm still waiting on a ROWS/MARKS isLast).
    -- `giveDone` additionally REQUIRES bucket.recvWant: without it, "the
    -- peer's WANT hasn't arrived yet" and "the peer wants nothing" are
    -- indistinguishable (both leave giveCount at its 0 default), which would
    -- finish this bucket - and, on the opener, possibly the whole session -
    -- before the peer's real request even arrives. See onHashesReceived,
    -- which always sends a WANT (even empty) specifically so recvWant has a
    -- definitive true to wait for.
    local wantDone = bucket.wantSatisfied == true;
    local giveDone = bucket.recvWant and ((bucket.giveCount == 0) or bucket.giveSatisfied);

    -- Phase 6: a pull-mode session only moves data ONE way (spec 6 notes:
    -- "a secondary never requests data from the opener"), so only HALF of
    -- the full-mode completion condition above actually applies to either
    -- side - the opener only ever wants, the server only ever gives.
    -- Checking both halves in pull mode would wait forever on a direction
    -- that's never going to happen (the opener's giveDone, or the server's
    -- wantDone, both permanently vacuous there).
    local done;
    if (session.mode == "pull") then
        if (session.role == "opener") then done = wantDone; else done = giveDone; end
    else
        done = wantDone and giveDone;
    end
    if (not done or bucket.finished) then return; end
    bucket.finished = true;

    FL.Sync.Debug.Log("SESS", 2, "%s: bucket %s compared · mine %d, theirs %d, need %d, giving %d",
        label(session), tostring(bucket.key), #bucket.myRawList, bucket.remoteCount or 0, bucket.wantCount, bucket.giveCount);

    if (session.role == "opener") then
        session.inFlightCount = session.inFlightCount - 1;
        session.bucketsDone = (session.bucketsDone or 0) + 1;
        advanceBuckets(session);
    end
end

-- Even with per-target send serialization and pacing (Net/Transport.lua),
-- Phase 5 testing confirmed this server still drops SOME messages outright
-- now and then, with zero trace - including, in one run, a bulk ROWS batch
-- answering a WANT, 27 buckets into an otherwise-cleanly-progressing
-- session. Without this retry, that one lost message stalls the WHOLE
-- session until the 45s SESSION_IDLE_TIMEOUT - discarding dozens of already-
-- completed buckets' worth of work just to start over from a fresh HELLO.
-- Retrying the one stuck WANT directly - safe, since a responder re-
-- answering a WANT it already answered is a harmless no-op via Store.Apply's
-- idempotency - recovers that one bucket without touching any other.
local WANT_RETRY_DELAY = 8;  -- seconds before resending an unsatisfied WANT
local WANT_RETRY_MAX = 3;    -- after this many retries, give up and let the session-level idle timeout be the fallback

local function sendWant(session, tree, key, idMode, missing, afterSend)
    sendControl(session, MSG.WANT, { Constants.PROTO_VERSION, MSG.WANT, session.token, tree, key, idMode and 1 or 0, missing }, afterSend);
end

--- This side's CURRENT entries for a bucket, listed in `idMode`'s format
--- (raw "kind:id" strings or 32-bit hashes) - rebuilt from the digest rather
--- than reusing bucket.myRawList, which was captured when HASHES was first
--- sent and so misses everything a secondary has delivered since.
local function currentLocalList(session, bucket, idMode)
    local list = {};
    for _, e in ipairs(session.domain:Tree().EntriesInBucket(bucket.tree, bucket.key)) do
        table.insert(list, idMode and (e.kind .. ":" .. e.id) or e.hash);
    end
    return list;
end

--- True once every entry this bucket's WANT asked for is actually in the
--- store now, however it got there (this session, a duplicate session, a
--- live broadcast). A second completion test next to the batch-index one in
--- onRowsOrMarks: it can finish a bucket whose answer batches were lost or
--- merely slow, as long as the entries themselves arrived.
local function wantFilledByContent(session, bucket)
    if (not bucket.myWant or #bucket.myWant == 0) then return false; end
    return #missingFrom(bucket.myWant, currentLocalList(session, bucket, bucket.myWantIdMode)) == 0;
end

-- Retries only count once the PEER has gone quiet. Found live (Phase 6 review
-- follow-up): a peer answering a large backfill queues every bucket's answer
-- behind the others, so a bucket can legitimately wait well past
-- WANT_RETRY_DELAY while data for OTHER buckets keeps arriving. Retrying
-- then just made the peer queue the whole answer a second and third time,
-- which slowed everything further (3 retries, "exhausted", on bucket after
-- bucket, with thousands of duplicate rows). While any ROWS/MARKS arrived
-- for this session within the delay, the timer re-arms without counting.
local function scheduleWantRetry(session, bucket, tree, key)
    Scheduler.After(WANT_RETRY_DELAY, 0, function()
        if (session.closed or bucket.wantSatisfied) then return; end -- self-checking: no handle to cancel, just a no-op if already done
        if (wantFilledByContent(session, bucket)) then
            bucket.wantSatisfied = true;
            maybeFinishBucket(session, bucket);
            return;
        end
        if (session.lastDataAt and (GetTime() - session.lastDataAt) < WANT_RETRY_DELAY) then
            scheduleWantRetry(session, bucket, tree, key); -- peer still busy answering; not a retry yet
            return;
        end
        bucket.wantRetries = (bucket.wantRetries or 0) + 1;
        if (bucket.wantRetries > WANT_RETRY_MAX) then
            FL.Sync.Debug.Warn("SESS", "%s: gave up on bucket %s · rows never came after %d tries", label(session), tostring(key), WANT_RETRY_MAX);
            return;
        end
        FL.Sync.Debug.Log("SESS", 1, "%s: rows for bucket %s haven't come · asking again (retry %d/%d)",
            label(session), tostring(key), bucket.wantRetries, WANT_RETRY_MAX);
        sendWant(session, tree, key, bucket.myWantIdMode, bucket.myWant, function() scheduleWantRetry(session, bucket, tree, key); end);
    end, "wantRetry");
end

local function onHashesReceived(session, tree, key, idMode, list, isRetry)
    local bucket = getOrCreateBucket(session, tree, key);
    -- `isRetry` forces a fresh resend of THIS side's own hash list even if
    -- already sent once - needed for the case where the ORIGINAL exchange
    -- partly succeeded (this side's own reply already went out) but that
    -- reply itself is what got lost; the plain `not bucket.sentHashesOut`
    -- guard alone would otherwise permanently skip resending it. Safe from
    -- ping-pong: this side never sets isRetry itself, only the opener's own
    -- bounded retry timer does (scheduleHashesRetry) - see that function's
    -- own comment.
    if (not bucket.sentHashesOut or isRetry) then
        sendHashesForBucket(session, bucket); -- server's reactive first reply (or resend); opener always sent its own already
    end

    bucket.recvHashesIn = true;
    bucket.remoteCount = #list;
    -- Phase 6: saved in full (not just the count) so a bucket skipped here
    -- (delegated to a secondary) can be reassigned back to the primary
    -- later WITHOUT a second HASHES round trip - reassignBucketToPrimary
    -- recomputes the real diff from these directly. Harmless to always
    -- save even when nothing ever reassigns.
    bucket.remoteList = list;
    bucket.remoteIdMode = idMode;

    -- Phase 6: two cases where this side deliberately wants NOTHING from
    -- this bucket, regardless of what the real diff would say:
    --   - `bucket.delegated` (full-mode opener only): this bucket was
    --     assigned to a secondary instead (spec 7.4 step 3, "skipped on the
    --     primary") - the data is still coming, just not from here.
    --   - pull mode, role=="server": a secondary never requests data from
    --     the opener at all (spec 6 notes) - its own "want" side is simply
    --     never used.
    -- Either way the peer still needs a real (if empty) WANT - see below.
    local skipWant = (bucket.delegated and session.role == "opener")
        or (session.mode == "pull" and session.role == "server");

    local missing = skipWant and {} or missingFrom(list, bucket.myRawList);
    bucket.wantCount = #missing;
    bucket.wantSatisfied = (#missing == 0); -- known the instant the two lists are compared, either way

    -- Always sent, even empty: the peer needs a DEFINITIVE "here is what I
    -- want from you" signal to know its own "give" side is resolved (as
    -- opposed to simply not having heard from me yet) - see
    -- maybeFinishBucket's own comment on why this can't be skipped just
    -- because `missing` is empty.
    local afterSend;
    if (#missing > 0) then
        bucket.myWant = missing;
        bucket.myWantIdMode = idMode;
        afterSend = function() scheduleWantRetry(session, bucket, tree, key); end;
    end
    sendWant(session, tree, key, idMode, missing, afterSend);

    maybeFinishBucket(session, bucket);
end

local function onWantReceived(session, tree, key, idMode, wantedList)
    local bucket = getOrCreateBucket(session, tree, key);
    local lookup = myLookupFor(bucket);

    local entries = {};
    for _, v in ipairs(wantedList) do
        local hit = lookup[v];
        if (hit) then table.insert(entries, hit); end
    end

    bucket.recvWant = true;
    bucket.giveCount = #entries;
    bucket.peerWantEntries = entries; -- kept so a DONE_ACK naming this bucket can re-send it (see onDoneAck)

    if (#entries == 0) then
        bucket.giveSatisfied = true;
    else
        local chunks = session.domain:EncodeEntries(entries);
        for i, chunk in ipairs(chunks) do
            chunk.tree = tree; chunk.key = key; chunk.batchIndex = i; chunk.totalBatches = #chunks;
            table.insert(session.outQueue, chunk);
        end
        bucket.giveSatisfied = true; -- "give" counts intent/handoff, not confirmed delivery - see drainOutgoing's own backpressure for the actual send
        drainOutgoing(session);
    end

    maybeFinishBucket(session, bucket);
end

--------------------------------------------------------------------------
-- Opener: bucket queue (RECONCILING), advancing it, and finishing the
-- session (spec 7.3 steps 4-6).
--------------------------------------------------------------------------

advanceBuckets = function(session)
    while (session.inFlightCount < Constants.BUCKETS_IN_FLIGHT and #session.bucketQueue > 0) do
        local next_ = table.remove(session.bucketQueue, 1);
        local bucket = getOrCreateBucket(session, next_.tree, next_.key);
        -- Phase 6: full-mode only, see assignBucketsWithSecondaries. A
        -- bucket reclaimed from a failed secondary before we got this far
        -- (reassignBucketToPrimary) is pulled from the primary as normal.
        bucket.delegated = next_.delegatedTo ~= nil and not (session.reclaimed and session.reclaimed[next_.tree .. ":" .. next_.key]);
        local tree, key = next_.tree, next_.key;

        -- Delegated + empty on our side: we pull nothing from the primary
        -- here (the secondary does that), and with no entries of our own
        -- there's nothing the primary could be missing from us either - the
        -- HASHES exchange would find nothing. Skipping it roughly halves
        -- the primary's work in a fresh-member backfill. The bucket is
        -- re-checked against the primary's own aggregate once its
        -- secondary finishes (reassignBucketToPrimary), so anything the
        -- secondary didn't have still gets pulled from the primary.
        if (bucket.delegated and session.domain:Tree().Bucket(tree, key).count == 0) then
            bucket.skippedPush = true;
            bucket.finished = true;
            session.bucketsDone = (session.bucketsDone or 0) + 1;
            FL.Sync.Debug.Log("SESS", 2, "%s: skipped bucket %s · nothing here to give, another peer covers it", label(session), tostring(key));
        else
            session.inFlightCount = session.inFlightCount + 1;
            sendHashesForBucket(session, bucket, false, function() scheduleHashesRetry(session, bucket, tree, key); end);
        end
    end

    trySessionComplete(session);
end

--- Phase 6 bug fix: a bucket's "give" is marked satisfied the MOMENT its
--- data is QUEUED (onWantReceived's own comment: "intent/handoff, not
--- confirmed delivery"), not once it's actually confirmed sent. With Phase
--- 5's single in-flight batch this rarely mattered in practice - by the
--- time the last bucket's give was queued, the queue had usually already
--- drained close to empty. Phase 6's multi-prefix concurrency can queue
--- several buckets' worth of give-data back-to-back far faster than
--- BUCKETS_IN_FLIGHT concurrent sends can actually clear it, so the
--- opener's bucket/queue bookkeeping alone can say "nothing left to do"
--- while real data is STILL sitting in session.outQueue or mid-flight on a
--- prefix. Finishing (and sending DONE) at that moment is fatal: the peer
--- closes the instant it receives DONE (onDone -> closeSession), so any
--- ROWS/MARKS batch that arrives after that is silently dropped by its own
--- session.closed guard. Observed live: a 121-bucket session's last ~7
--- buckets' give-data (already logged as "give=N") got dropped on the floor
--- this way, losing ~100 rows on the receiving end despite every bucket
--- having been "handled." This is checked both from advanceBuckets (every
--- time the bucket queue itself empties) and from drainOutgoing's own
--- onSent/onFail (every time a send actually confirms, in case THAT was
--- the last thing blocking completion) - only pull-mode opener sessions
--- never queue anything to flush (spec 6: "a secondary never requests data
--- from the opener"), so this is a no-op for them, not just for full mode.
trySessionComplete = function(session)
    if (session.role ~= "opener") then return; end -- server sessions have no bucketQueue/inFlightCount concept; they close on receiving DONE, not on their own initiative
    if (session.inFlightCount ~= 0 or #session.bucketQueue > 0) then return; end
    -- Phase 6: a full-mode session with secondaries can't declare itself
    -- done just because ITS OWN queue drained - the domain-wide sync isn't
    -- finished until every secondary has also reported in (success or
    -- reassigned leftovers, see reportSecondaryFinished). `secondariesRemaining`
    -- is nil/0 for every session that never had any (every Phase 5 session,
    -- and every pull-mode session, which has no secondaries of its own),
    -- so this is a no-op there.
    if ((session.secondariesRemaining or 0) > 0) then return; end
    if (#session.outQueue > 0 or anyPrefixBusy(session)) then return; end -- still flushing give-data - drainOutgoing's own onSent/onFail will re-check this once it clears
    finishSessionAsOpener(session);
end

--------------------------------------------------------------------------
-- Phase 6: secondaries (spec 7.4) - opening a pull session, round-robin
-- bucket assignment, and reassigning a failed secondary's leftovers back to
-- the primary. See this file's header comment for the overall design.
--------------------------------------------------------------------------

--- Hands a delegated bucket back to the primary (spec 7.4 step 4), or tops
--- it up (Phase 6 review). Returns true if a real WANT went to the primary.
---
--- Three cases:
---   - The primary hasn't reached this bucket yet (still in its queue), or
---     its HASHES reply hasn't arrived: mark it `reclaimed`, so
---     advanceBuckets/onHashesReceived treat it as an ordinary bucket and
---     compute a real want when its turn comes. Before this, the queue entry
---     kept `.delegatedTo` and the bucket was silently never pulled.
---   - The primary already exchanged HASHES for it: diff the primary's saved
---     list (bucket.remoteList - the primary HASHES every bucket up front
---     for the push direction) against our CURRENT entries. That also covers
---     a secondary that finished but simply didn't hold everything the
---     primary has: secondaries are chosen for differing from us, not for
---     being a superset.
---   - Nothing missing: no-op (no message sent).
local function reassignBucketToPrimary(parent, tree, key)
    local k = tree .. ":" .. key;
    parent.reclaimed[k] = true;

    local bucket = parent.buckets[k];

    -- Skipped without a HASHES exchange (advanceBuckets: delegated and empty
    -- on our side). Compare against the primary's own aggregate for this
    -- bucket from the compare phase: equal means the secondary gave us
    -- exactly what the primary holds; otherwise forget the skipped bucket
    -- and queue it again for a normal exchange (reclaimed -> not delegated).
    if (bucket and bucket.skippedPush) then
        local remoteAgg = parent.remoteAgg and parent.remoteAgg[k] or { count = 0, x = 0, s = 0 };
        if (aggEqual(parent.domain:Tree().Bucket(tree, key), remoteAgg)) then return false; end
        parent.buckets[k] = nil;
        parent.bucketsDone = math.max(0, (parent.bucketsDone or 0) - 1);
        table.insert(parent.bucketQueue, 1, { tree = tree, key = key });
        return true;
    end

    if (not bucket or not bucket.recvHashesIn) then
        if (bucket) then bucket.delegated = false; end
        return false;
    end
    bucket.delegated = false;

    local missing = missingFrom(bucket.remoteList or {}, currentLocalList(parent, bucket, bucket.remoteIdMode));
    if (#missing == 0) then return false; end

    if (bucket.finished) then
        parent.inFlightCount = parent.inFlightCount + 1;
        parent.bucketsDone = math.max(0, (parent.bucketsDone or 0) - 1);
    end
    bucket.finished = false;
    bucket.wantCount = #missing;
    bucket.wantSatisfied = false;
    bucket.wantBatchesSeen = nil; -- a different want list than any earlier one, so earlier batch indices don't apply
    bucket.wantRetries = 0;
    bucket.myWant = missing;
    bucket.myWantIdMode = bucket.remoteIdMode;
    sendWant(parent, tree, key, bucket.remoteIdMode, missing, function() scheduleWantRetry(parent, bucket, tree, key); end);
    return true;
end

--- Called once a secondary's pull session is done, one way or another
--- (normal finish, abort, timeout, or an outright OPEN_REPLY refusal).
--- Runs reassignBucketToPrimary over EVERY bucket it was assigned - its
--- unfinished ones go back to the primary (spec 7.4 step 4), and its
--- finished ones get a top-up check against the primary's own list (see
--- reassignBucketToPrimary). Then folds its received-row count into the
--- primary's domain-wide total and lets the primary's own finish check run
--- again now that one fewer secondary is outstanding. `parent.closed` can
--- legitimately already be true here (e.g. the gate closed and aborted every
--- session for this domain in the same pass) - nothing to reassign to then.
reportSecondaryFinished = function(parent, pullSession, reason)
    if (not parent or parent.closed) then return; end

    local reassigned, toppedUp = 0, 0;
    for _, b in ipairs(pullSession.assignedBuckets or {}) do
        local secBucket = pullSession.buckets[b.tree .. ":" .. b.key];
        local unfinished = (not secBucket or not secBucket.finished);
        local sentWant = reassignBucketToPrimary(parent, b.tree, b.key);
        if (unfinished) then reassigned = reassigned + 1;
        elseif (sentWant) then toppedUp = toppedUp + 1; end
    end

    parent.secondaryRecvTotal = (parent.secondaryRecvTotal or 0) + pullSession.recv;
    parent.secondaryMarksTotal = (parent.secondaryMarksTotal or 0) + pullSession.marksRecv;
    parent.secondariesRemaining = math.max(0, (parent.secondariesRemaining or 1) - 1);

    if (reassigned > 0) then
        FL.Sync.Debug.Log("SESS", 1, "history sync: moved %d buckets from %s to %s · %s",
            reassigned, pullSession.peer, parent.peer, tostring(reason));
    end
    if (toppedUp > 0) then
        FL.Sync.Debug.Log("SESS", 1, "history sync: %s finished early, gave %d more buckets to %s",
            pullSession.peer, toppedUp, parent.peer);
    end

    advanceBuckets(parent);
end

--- Opens a pull-mode session with one secondary for `bucketList` (an array
--- of {tree,key}, spec 7.4 step 2). `parent` is the primary's own full-mode
--- session - kept so a later abort/timeout/refusal can reassign leftovers
--- back to it (reportSecondaryFinished above).
local function openSecondaryPull(parent, peerName, bucketList)
    local token = newToken();
    local flat = {};
    for _, b in ipairs(bucketList) do table.insert(flat, b.tree); table.insert(flat, b.key); end

    local session = {
        token = token, domainId = parent.domainId, domain = parent.domain, role = "opener", mode = "pull",
        peer = peerName, state = "OPENING", startedAt = GetTime(), parent = parent,
        buckets = {}, bucketQueue = {}, assignedBuckets = bucketList, inFlightCount = 0, bucketsDone = 0, bucketsSeen = 0,
        sent = 0, recv = 0, marksSent = 0, marksRecv = 0,
        outQueue = {}, outBatchNum = 0, prefixBusy = {}, prefixCursor = 0, closed = false,
        bucketsTotalKnown = #bucketList,
    };
    for _, b in ipairs(bucketList) do table.insert(session.bucketQueue, { tree = b.tree, key = b.key }); end

    trackSession(session);

    FL.Sync.Debug.Log("SESS", 1, "%s: asking to pull %d buckets · helper for the main sync",
        labelFor(token, peerName), #bucketList);
    local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN, token, parent.domainId, "pull", flat });
    Transport.Send(MSG.OPEN, encoded, "WHISPER", peerName, { prio = "NORMAL" });
end

--- Splits `queue` (the primary's full mismatched-bucket list, newest first)
--- round-robin across the primary itself and `session.secondaryNames` (spec
--- 7.4 step 1), opens a pull session with each secondary that actually got
--- any buckets, and logs the real assignment counts. `session.bucketQueue`
--- stays the FULL list either way (see this file's header comment on why
--- the primary still needs every bucket for push direction) - this only
--- tags each entry a secondary now owns with `.delegatedTo`, consumed by
--- advanceBuckets/onHashesReceived above.
-- Phase 6 review (docs/sync-deviations.md "PING keepalive"): while a
-- primary session waits on its secondaries, nothing else may pass between it
-- and the primary PEER, whose server-side session would then idle out and
-- ABORT(timeout) us. touchSession already keeps OUR side alive off pull-
-- session traffic; this keeps the peer's side alive too. Stops by itself
-- once no secondary is outstanding or the session closes.
local KEEPALIVE_INTERVAL = 15;

local function startParentKeepalive(session)
    Scheduler.After(KEEPALIVE_INTERVAL, 0, function()
        if (session.closed or (session.secondariesRemaining or 0) <= 0) then return; end
        -- Pull-session traffic keeps this session's idle timer alive
        -- (touchSession), so a primary that vanished (reload, logout) would
        -- otherwise never time out while a secondary is still busy - found
        -- live: a dead primary session sat with exhausted retries, holding
        -- its unfinished buckets, until long after the secondary was done.
        -- The server answers every PING (onPing), so a live primary is
        -- always heard from at least once per KEEPALIVE_INTERVAL.
        if (GetTime() - (session.lastHeardAt or session.startedAt) > Constants.SESSION_IDLE_TIMEOUT) then
            abortSession(session, "timeout");
            return;
        end
        sendControl(session, MSG.PING, { Constants.PROTO_VERSION, MSG.PING, session.token });
        FL.Sync.Debug.Log("SESS", 2, "%s: keep-alive · waiting on %d helpers", label(session), session.secondariesRemaining);
        startParentKeepalive(session);
    end, "sessionKeepalive");
end

local function assignBucketsWithSecondaries(session, queue)
    session.bucketQueue = queue;

    local names = session.secondaryNames or {};
    if (#names == 0 or #queue == 0) then return; end

    local slots = { {} }; -- slot 1 = the primary's own share (no .name)
    for _, name in ipairs(names) do table.insert(slots, { name = name }); end

    for i, b in ipairs(queue) do
        local slotIdx = ((i - 1) % #slots) + 1;
        if (slotIdx > 1) then
            b.delegatedTo = slots[slotIdx].name;
            table.insert(slots[slotIdx], { tree = b.tree, key = b.key });
        end
    end

    local primaryCount = 0;
    for _, b in ipairs(queue) do if (not b.delegatedTo) then primaryCount = primaryCount + 1; end end

    local assignParts = { ("%s=%d"):format(session.peer, primaryCount) };
    local secondaryParts = {};
    local opened = 0;
    for slotIdx = 2, #slots do
        local slot = slots[slotIdx];
        if (#slot > 0) then
            table.insert(assignParts, ("%s=%d"):format(slot.name, #slot));
            table.insert(secondaryParts, ("%q"):format(slot.name));
            opened = opened + 1;
        end
    end

    session.secondariesTotal = opened;
    session.secondariesRemaining = opened;
    if (opened > 0) then startParentKeepalive(session); end

    FL.Sync.Debug.Log("SESS", 1, "history sync plan: main peer %s, helpers %s · buckets %s",
        session.peer, (#secondaryParts > 0) and table.concat(secondaryParts, ", ") or "none", table.concat(assignParts, " "));

    for slotIdx = 2, #slots do
        local slot = slots[slotIdx];
        if (#slot > 0) then
            openSecondaryPull(session, slot.name, slot);
        end
    end
end

--- Our current window and archive roots as six flat values, appended to
--- DONE (opener) and DONE_ACK (server) so the other side can compare final
--- digests exactly - see rootsMatchFinal.
local function finalRootFields(session)
    local Digest = session.domain:Tree();
    local w, a = Digest.Root("W"), Digest.Root("A");
    return w.count, w.x, w.s, a.count, a.x, a.s;
end

--- Whether our roots equal the peer's final roots carried at body[i..i+5],
--- or nil when the message has none (a build from before this field).
local function rootsMatchFinal(session, body, i)
    if (type(body[i]) ~= "number") then return nil; end
    local Digest = session.domain:Tree();
    return aggEqual(Digest.Root("W"), { count = body[i], x = body[i + 1], s = body[i + 2] })
        and aggEqual(Digest.Root("A"), { count = body[i + 3], x = body[i + 4], s = body[i + 5] });
end

--- The roots check when the peer sent no final roots (DONE never acked, a
--- pull session, or an older build): compares against the peer's roots
--- from the START of the session, so it reads "no" whenever rows also
--- flowed to the peer. Logged only; never shown as a result on the page.
local function computeRootsMatchOpener(session)
    local Digest = session.domain:Tree();
    if (not session.remoteWindowRoot) then return true; end
    local wMatch = aggEqual(Digest.Root("W"), session.remoteWindowRoot);
    local aMatch = (not session.remoteArchiveRoot) or aggEqual(Digest.Root("A"), session.remoteArchiveRoot);
    return wMatch and aMatch;
end

--- Phase 6 instrumentation ("[PERF] rate ..."): per-session throughput,
--- using `session.recvBytes` (real wire bytes, threaded through from
--- Net/Transport.lua's handler dispatch - see that file's own comment) for
--- kbps rather than guessing from an average row size.
local function logSessionRate(session, dur)
    local rowsPerMin = (session.recv / dur) * 60;
    local kbps = (session.recvBytes or 0) / 1024 / dur;
    FL.Sync.Debug.Log("PERF", 1, "%s speed · %d rows in %s, %d rows/min, %.2f KB/s",
        label(session), session.recv, fmtTime(dur), rowsPerMin, kbps);
end

--- Logs the final "done" line (and, for a primary with secondaries, the
--- domain-wide "sync complete" line), then closes the session.
local function completeOpener(session, acked)
    local dur = math.max(0.001, GetTime() - session.startedAt);
    -- session.finalRootsMatch: set by onDoneAck from the server's final
    -- roots (exact). Otherwise fall back to the loose start-of-session check.
    local exact = session.finalRootsMatch ~= nil;
    local rootsMatch;
    if (exact) then rootsMatch = session.finalRootsMatch; else rootsMatch = computeRootsMatchOpener(session); end
    session.rootsMatch = rootsMatch;
    session.rootsExact = exact;

    FL.Sync.Debug.Log("SESS", 1, "%s: done, %s · sent %d, got %d rows, %d pins/deletes, %d buckets, %s",
        label(session), rootsMatch and (exact and "now in sync" or "now in sync (loose check)") or "STILL DIFFERENT",
        session.sent, session.recv, session.marksSent + session.marksRecv, session.bucketsTotalKnown or 0, fmtTime(dur));
    if (acked == false) then
        FL.Sync.Debug.Warn("SESS", "%s: %s never confirmed we're done · sent it %d times", label(session), session.peer, session.doneSends or 0);
    end
    logSessionRate(session, dur);
    closeSession(session);

    if (session.mode == "pull" and session.parent) then
        reportSecondaryFinished(session.parent, session, "done");
    elseif ((session.secondariesTotal or 0) > 0) then
        -- Phase 6: the domain-wide summary (spec's own "[SESS] sync
        -- complete ..." sample) - only the primary logs this, and only
        -- once every secondary has reported in (trySessionComplete won't
        -- get here while secondariesRemaining > 0).
        local totalRows = session.recv + (session.secondaryRecvTotal or 0);
        local totalPeers = 1 + session.secondariesTotal;
        local totalRowsPerMin = (totalRows / dur) * 60;
        FL.Sync.Debug.Log("SESS", 1, "history sync finished · %d peer%s, %d rows in %s, %d rows/min",
            totalPeers, (totalPeers == 1) and "" or "s", totalRows, fmtTime(dur), totalRowsPerMin);
    end
end

-- Phase 6 review (docs/sync-deviations.md "DONE_ACK"): a full-mode opener
-- no longer closes the moment it sends DONE. "Every give batch confirmed
-- SENT" isn't "every batch ARRIVED" - this server loses whole messages, and
-- the server-side WANT retry that would recover a lost batch died the
-- instant DONE closed the session. Now the server answers DONE with a
-- DONE_ACK listing any bucket it still wants data for; the opener re-sends
-- those buckets and sends DONE again. Bounded: DONE_RETRY_MAX sends in
-- total, each re-armed from its own send confirmation, after which the
-- opener closes anyway (rootsMatch=no; the next periodic HELLO repairs it,
-- exactly as before this change).
local DONE_RETRY_DELAY = 8;
local DONE_RETRY_MAX = 4;

local function sendDone(session)
    session.doneGen = (session.doneGen or 0) + 1;
    session.doneSends = (session.doneSends or 0) + 1;
    local gen = session.doneGen;
    touchSession(session); -- the DONE retries can outlast SESSION_IDLE_TIMEOUT if nothing else arrives meanwhile
    sendControl(session, MSG.DONE, { Constants.PROTO_VERSION, MSG.DONE, session.token, session.sent, session.recv, finalRootFields(session) }, function()
        Scheduler.After(DONE_RETRY_DELAY, 0, function()
            if (session.closed or session.doneGen ~= gen) then return; end -- answered (or superseded) already
            if (session.doneSends >= DONE_RETRY_MAX) then
                completeOpener(session, false);
                return;
            end
            FL.Sync.Debug.Log("SESS", 1, "%s: no reply to done · sending it again (try %d)", label(session), session.doneSends + 1);
            sendDone(session);
        end, "doneRetry");
    end);
end

finishSessionAsOpener = function(session)
    -- Pull mode never gives data to the server (spec 6 notes), so there's
    -- nothing for a DONE_ACK to confirm - send DONE once and finish.
    if (session.mode == "pull") then
        sendControl(session, MSG.DONE, { Constants.PROTO_VERSION, MSG.DONE, session.token, session.sent, session.recv });
        completeOpener(session, true);
        return;
    end

    if (session.state == "FINISHING") then
        -- Re-entered via trySessionComplete once a DONE_ACK's re-sent
        -- batches have flushed - only then is it time for the next DONE.
        if (session.awaitingFlush) then
            session.awaitingFlush = false;
            sendDone(session);
        end
        return;
    end

    setState(session, "FINISHING");
    sendDone(session);
end

local function tryFinishCompare(session)
    if (not (session.compareDone.w and session.compareDone.a)) then return; end

    local Digest = session.domain:Tree();
    local queue = {};

    for _, dayKey in ipairs(buildDayBuckets(Digest, session.windowMismatchedMonths or {}, session.windowReplyFlat or {})) do
        table.insert(queue, { tree = "W", key = dayKey, sortKey = dayKey * 86400 });
    end
    if (session.archiveReplyFlat) then
        for i = 1, #session.archiveReplyFlat, 4 do
            local monthKey = session.archiveReplyFlat[i];
            table.insert(queue, { tree = "A", key = monthKey, sortKey = FL.Sync.Retention.MonthStart(monthKey) });
        end
    end
    table.sort(queue, function(a, b) return a.sortKey > b.sortKey; end);

    -- The primary's own per-bucket aggregates (its DAYS reply / archive
    -- MONTHS reply), kept for reassignBucketToPrimary's check on buckets the
    -- primary session skipped.
    session.remoteAgg = {};
    local function keepAgg(tree, flat)
        for i = 1, #(flat or {}), 4 do
            session.remoteAgg[tree .. ":" .. flat[i]] = { count = flat[i + 1], x = flat[i + 2], s = flat[i + 3] };
        end
    end
    keepAgg("W", session.windowReplyFlat);
    keepAgg("A", session.archiveReplyFlat);

    assignBucketsWithSecondaries(session, queue); -- Phase 6: sets session.bucketQueue (unchanged full list) and opens any secondary pull sessions
    session.bucketsTotalKnown = #queue;

    local keys = {};
    for _, b in ipairs(queue) do table.insert(keys, tostring(b.key)); end
    FL.Sync.Debug.Log("SESS", 1, "%s: %d bucket%s differ · %s", label(session), #queue, (#queue == 1) and "" or "s",
        (#keys > 0) and table.concat(keys, ", ") or "none");

    setState(session, "RECONCILING");
    if (#queue == 0) then
        finishSessionAsOpener(session);
    else
        advanceBuckets(session);
    end
end

-- Phase 5 testing found the COMPARING phase needs the exact same retry
-- discipline as a bucket's own WANT (see that constant's own comment): a
-- lost MONTHS request or DAYS/archive-MONTHS reply here had no recovery
-- short of the whole 45s session timeout, even though it's the identical
-- "one lost message stalls everything" problem. Resending the MONTHS
-- request is always safe - handleMonthsRequest is fully stateless per call,
-- so the server just recomputes and replies fresh every time, retry or not.
local COMPARE_RETRY_DELAY = 8;
local COMPARE_RETRY_MAX = 3;

-- `gen` (sent on MONTHS, echoed back on every DAYS/archive-MONTHS-reply
-- batch) tags which compare ATTEMPT a reply belongs to. Needed because a
-- retry resets windowReplyFlat/archiveReplyFlat to accumulate a FRESH
-- reply from scratch (see scheduleCompareRetry) - without a generation tag,
-- a straggler batch from the attempt JUST discarded (delayed, not actually
-- lost - this server's loss/delay behavior isn't perfectly predictable)
-- arriving after that reset would get misattributed as part of the NEW
-- attempt, corrupting it with an incomplete mix of old-and-new data. Found
-- necessary after a retry-less reset let exactly this happen live: a
-- session finished and reported `done` on a bucket list far too small for
-- how large the actual mismatch was. See docs/sync-deviations.md "Phase 5".
local function sendMonthsRequest(session, tree, afterSend)
    local Digest = session.domain:Tree();
    local flat = flattenAggList(Digest.Months(tree), "monthKey");
    local gen;
    if (tree == "W") then gen = session.windowGen; else gen = session.archiveGen; end
    sendControl(session, MSG.MONTHS, { Constants.PROTO_VERSION, MSG.MONTHS, session.token, tree, flat, gen }, afterSend);
end

local function scheduleCompareRetry(session, tree)
    Scheduler.After(COMPARE_RETRY_DELAY, 0, function()
        if (session.closed) then return; end
        -- NOT `(tree=="W") and session.compareDone.w or session.compareDone.a`:
        -- the classic Lua ternary gotcha - when compareDone.w is false (the
        -- whole reason this retry exists), `true and false` is `false`,
        -- which falls through to `or session.compareDone.a` regardless of
        -- `tree`, silently returning the ARCHIVE flag instead. Since archive
        -- is usually already done (true) when it wasn't even needed, this
        -- made `done` always true for the window tier, skipping every retry
        -- without a trace - exactly the silent no-op just observed live.
        local done;
        if (tree == "W") then done = session.compareDone.w; else done = session.compareDone.a; end
        if (done) then return; end

        local countKey = (tree == "W") and "windowRetries" or "archiveRetries";
        session[countKey] = (session[countKey] or 0) + 1;
        if (session[countKey] > COMPARE_RETRY_MAX) then
            FL.Sync.Debug.Warn("SESS", "%s: gave up comparing %s history · no answer after %d tries", label(session), treeWord(tree), COMPARE_RETRY_MAX);
            return;
        end

        FL.Sync.Debug.Log("SESS", 1, "%s: no answer comparing %s history · asking again (retry %d/%d)",
            label(session), treeWord(tree), session[countKey], COMPARE_RETRY_MAX);
        -- Bump the generation AND discard whatever partial reply accumulated
        -- from the attempt being retried - the bump is what lets onDays/
        -- onMonths reject a straggler from that old attempt instead of
        -- quietly merging it into this fresh one (see sendMonthsRequest's
        -- own comment on why the discard alone wasn't enough).
        if (tree == "W") then
            session.windowGen = session.windowGen + 1;
            session.windowReplyFlat = nil;
            session.windowMismatchedMonths = nil;
            session.windowBatchesSeen = nil;
        else
            session.archiveGen = session.archiveGen + 1;
            session.archiveReplyFlat = nil;
            session.archiveBatchesSeen = nil;
        end

        sendMonthsRequest(session, tree, function() scheduleCompareRetry(session, tree); end);
    end, "compareRetry");
end

local function beginCompare(session)
    local mine = session.domain:Summary();
    local myArchive = { count = mine[4], x = mine[5], s = mine[6] };
    local needArchive = session.remoteArchiveRoot ~= nil and (not aggEqual(myArchive, session.remoteArchiveRoot));

    session.compareDone = { w = false, a = not needArchive };
    session.windowGen = 1;
    session.archiveGen = 1;

    sendMonthsRequest(session, "W", function() scheduleCompareRetry(session, "W"); end);

    if (needArchive) then
        sendMonthsRequest(session, "A", function() scheduleCompareRetry(session, "A"); end);
    end
end

--------------------------------------------------------------------------
-- Server: reactive MONTHS-request handling (spec 7.3 step 3).
--------------------------------------------------------------------------

-- Found necessary in Phase 5 testing: a single large DAYS reply (every day
-- of every mismatched month, for a big backfill spanning several months)
-- reliably failed to decompress on the receiving end once it grew past what
-- a 2-chunk message needs - a size this server apparently can't deliver
-- intact over WHISPER, the same class of problem ROWS/MARKS already guard
-- against with their own BATCH_ROW_CHUNK capping. DAYS and the archive-tier
-- MONTHS reply (the two messages whose size scales with mismatch size
-- rather than being roughly constant) now get the same discipline: capped
-- at DAYS_BATCH_SIZE tuples per message, sent as however many messages that
-- takes, each tagged batchIndex/totalBatches. See docs/sync-deviations.md
-- "Phase 5".
local DAYS_BATCH_SIZE = 40;

--- Sends `flat` (already-built array of 4-tuples: dayKey/count/x/s or
--- monthKey/count/x/s) across one or more `msgType` messages, calling
--- `buildBody(sliceFlat, batchIndex, totalBatches)` for each to get that
--- message's full body (so the caller controls the fixed fields around the
--- slice). Always sends at least one message, even for an empty `flat`
--- (zero mismatches still needs to reach the opener as a definitive
--- "nothing here" signal, same reasoning as HASHES/WANT always sending
--- something) - that one message is batchIndex=1, totalBatches=1.
---
--- Tags every batch with its own index and the total count, NOT a single
--- "isLast" boolean on the final one - found necessary live: a middle batch
--- can be lost while the one marked "last" still arrives, and a receiver
--- that only waits for "last" declares the whole reply complete with a gap
--- in the middle (observed as an entire month's rows missing from an
--- otherwise-"done" sync). The receiver must see EVERY index 1..totalBatches
--- before considering the reply complete, not just the final one.
local function sendFlatBatches(msgType, session, buildBody, flat)
    local total = #flat / 4;
    local totalBatches = math.max(1, math.ceil(total / DAYS_BATCH_SIZE));

    if (total == 0) then
        Transport.Send(msgType, Codec.EncodeMessage(buildBody({}, 1, 1)), "WHISPER", session.peer, { prio = "NORMAL" });
        return;
    end

    local batchIndex = 0;
    for i = 1, total, DAYS_BATCH_SIZE do
        batchIndex = batchIndex + 1;
        local sliceEnd = math.min(i + DAYS_BATCH_SIZE - 1, total);
        local sliceFlat = {};
        for j = i, sliceEnd do
            local base = (j - 1) * 4 + 1;
            table.insert(sliceFlat, flat[base]); table.insert(sliceFlat, flat[base + 1]);
            table.insert(sliceFlat, flat[base + 2]); table.insert(sliceFlat, flat[base + 3]);
        end
        Transport.Send(msgType, Codec.EncodeMessage(buildBody(sliceFlat, batchIndex, totalBatches)), "WHISPER", session.peer, { prio = "NORMAL" });
    end
end

local function handleMonthsRequest(session, tree, flat, gen)
    local Digest = session.domain:Tree();
    local localMonths = Digest.Months(tree);
    local mismatched = diffMonths(localMonths, flat);

    local labels = {};
    for _, mk in ipairs(mismatched) do table.insert(labels, monthKeyLabel(mk)); end
    FL.Sync.Debug.Log("SESS", 2, "%s: compared %s months · mine %d, theirs %d, differ %s",
        label(session), treeWord(tree), #localMonths, #flat / 4, (#labels > 0) and table.concat(labels, ", ") or "none");

    if (tree == "W") then
        session.openerWindowRoot = rollupAgg(flat);
        local flatDays = {};
        for _, monthKey in ipairs(mismatched) do
            for _, d in ipairs(Digest.DaysInMonth(monthKey)) do
                table.insert(flatDays, d.dayKey); table.insert(flatDays, d.count); table.insert(flatDays, d.x); table.insert(flatDays, d.s);
            end
        end
        sendFlatBatches(MSG.DAYS, session, function(sliceFlat, batchIndex, totalBatches)
            return { Constants.PROTO_VERSION, MSG.DAYS, session.token, mismatched, sliceFlat, batchIndex, totalBatches, gen };
        end, flatDays);
    else -- "A"
        session.openerArchiveRoot = rollupAgg(flat);
        local flatOut = {};
        for _, monthKey in ipairs(mismatched) do
            local agg = Digest.Bucket("A", monthKey);
            table.insert(flatOut, monthKey); table.insert(flatOut, agg.count); table.insert(flatOut, agg.x); table.insert(flatOut, agg.s);
        end
        sendFlatBatches(MSG.MONTHS, session, function(sliceFlat, batchIndex, totalBatches)
            return { Constants.PROTO_VERSION, MSG.MONTHS, session.token, "A", sliceFlat, batchIndex, totalBatches, gen };
        end, flatOut);
    end
end

local function computeRootsMatchServer(session)
    local Digest = session.domain:Tree();
    if (not session.openerWindowRoot) then return true; end
    local wMatch = aggEqual(Digest.Root("W"), session.openerWindowRoot);
    local aMatch = (not session.openerArchiveRoot) or aggEqual(Digest.Root("A"), session.openerArchiveRoot);
    return wMatch and aMatch;
end

--------------------------------------------------------------------------
-- Wire handlers
--------------------------------------------------------------------------

local function gateOkFor(domain)
    if (domain.gate == "group") then return Gate.CanGroup(); end
    return (domain.gate == "awardUpdates") and Gate.CanSendAwardUpdates() or Gate.CanSync();
end

-- See onOpen's duplicate check: how long a peer that accepted our session
-- must have been silent on it before a fresh OPEN from them means they lost it.
local PEER_RESET_SILENCE = 5;

--- An open full-mode session for `domainId` between us and `peer`, in the
--- given role (nil = either) - used to stop two full sessions running
--- between the same pair (see onOpen and Session.Open).
local function findFullSessionWith(domainId, peer, role)
    for _, s in pairs(sessions) do
        if (not s.closed and s.mode == "full" and s.domainId == domainId
            and (role == nil or s.role == role) and Util.iEquals(s.peer, peer)) then
            return s;
        end
    end
    return nil;
end

local function findFullOpenerWith(domainId, peer)
    return findFullSessionWith(domainId, peer, "opener");
end

local function onOpen(body, senderName)
    -- body[6] (Phase 6): mode=="pull" only - a flat tree,key,tree,key,...
    -- list of the exact buckets this opener is assigning us (spec 7.4 step
    -- 2's "OPEN(pull, dayKeys)"; see this file's header comment on why it's
    -- explicit tree,key pairs, not bare day keys). Nothing on the server
    -- side actually NEEDS this list - a pull-mode server is purely reactive
    -- to whatever HASHES arrive, same code path as full mode - it only
    -- exists so the accept line below can log how many buckets were asked
    -- for.
    local token, domainId, mode, flatBuckets = body[3], body[4], body[5], body[6];
    local peer = Util.stripRealm(senderName);
    local domain = FL.Sync.Domains.Get(domainId);

    -- Sync turned off or paused by the player: stay silent, not even a
    -- refusal, so this client looks the same to peers as one without the
    -- addon. The opener's own retries give up on their own.
    if (Gate.UserStopped()) then
        FL.Sync.Debug.Log("SESS", 1, "%s: ignored request · sync is off or paused here", labelFor(token, peer));
        return;
    end

    -- Another guild's member asking for our guild's history: stay silent,
    -- the same as for a client without the addon.
    if (domain and domain.scope == "GUILD" and not FL.Sync.Permissions.IsGuildPeer(peer)) then
        FL.Sync.Debug.Log("SESS", 1, "%s: ignored request · not in our guild", labelFor(token, peer));
        return;
    end

    if (not domain or domain.strategy ~= "set" or (mode ~= "full" and mode ~= "pull")) then
        local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN_REPLY, token, 0, 0 });
        Transport.Send(MSG.OPEN_REPLY, encoded, "WHISPER", peer, { prio = "NORMAL" });
        return;
    end

    -- Gate.OnChange (registered in Init() below) only aborts a session on a
    -- FUTURE gate transition - it can't catch a gate that was ALREADY closed
    -- the instant this OPEN arrived (no "change" event ever fires for a
    -- steady-state), so that case needs its own check right here.
    if (not gateOkFor(domain)) then
        FL.Sync.Debug.Log("SESS", 1, "%s: refused · gate closed here", labelFor(token, peer));
        local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN_REPLY, token, 0, 0 });
        Transport.Send(MSG.OPEN_REPLY, encoded, "WHISPER", peer, { prio = "NORMAL" });
        return;
    end

    if (servingCount >= maxServe()) then
        FL.Sync.Debug.Log("SESS", 1, "%s: refused · already serving %d, told them to retry in %ds", labelFor(token, peer), maxServe(), BUSY_RETRY_AFTER);
        local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN_REPLY, token, 0, BUSY_RETRY_AFTER });
        Transport.Send(MSG.OPEN_REPLY, encoded, "WHISPER", peer, { prio = "NORMAL" });
        return;
    end

    -- Phase 6 review follow-up: two clients that both log in send HELLO,
    -- hear each other's HELLO_ACK, and each OPEN a full session with the
    -- other at about the same time. Full mode already moves data BOTH ways,
    -- so two such sessions transfer every missing row twice and fight over
    -- the same prefixes (found live: 2 sessions A<->C, ~4000 rows received
    -- for a 1505-row history). Both clients apply the same rule, so exactly
    -- one session survives: the one opened by the alphabetically lower name.
    if (mode == "full") then
        local mine = findFullOpenerWith(domainId, peer);
        -- Our session with this peer is already past OPENING (they accepted
        -- it) yet they're opening a new one and we haven't heard from them
        -- on ours for a while: they lost it (/reload, relog). Found live:
        -- the name rule below kept such a dead session and refused the
        -- peer's fresh one. A peer that's genuinely still serving ours never
        -- sends OPEN (Session.Open skips a peer it's serving), so the only
        -- live case is the simultaneous-open race, where ours is still
        -- OPENING or was answered moments ago.
        if (mine and mine.state ~= "OPENING" and GetTime() - (mine.lastHeardAt or mine.startedAt) > PEER_RESET_SILENCE) then
            abortSession(mine, "peerReset");
            mine = nil;
        end
        if (mine) then
            local me = Util.stripRealm(Util.UnitName("player")):lower();
            if (me < peer:lower()) then
                FL.Sync.Debug.Log("SESS", 1, "%s: refused · we both opened at once, keeping ours (#%s)", labelFor(token, peer), mine.token);
                local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN_REPLY, token, 0, 0, "dup" });
                Transport.Send(MSG.OPEN_REPLY, encoded, "WHISPER", peer, { prio = "NORMAL" });
                return;
            end
            abortSession(mine, "dup"); -- theirs wins; the ABORT tells their server side to drop ours
        end
    end

    servingCount = servingCount + 1;
    local session = {
        token = token, domainId = domainId, domain = domain, role = "server", mode = mode,
        peer = peer, state = "SERVING", startedAt = GetTime(), buckets = {}, bucketsSeen = 0,
        sent = 0, recv = 0, marksSent = 0, marksRecv = 0,
        outQueue = {}, outBatchNum = 0, prefixBusy = {}, prefixCursor = 0, closed = false,
    };
    trackSession(session);

    local bucketSuffix = "";
    if (mode == "pull" and flatBuckets) then bucketSuffix = (", %d buckets"):format(#flatBuckets / 2); end
    FL.Sync.Debug.Log("SESS", 1, "%s: accepted, serving them · %s sync%s, now serving %d/%d",
        labelFor(token, peer), mode, bucketSuffix, servingCount, maxServe());
    local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN_REPLY, token, 1, 0 });
    Transport.Send(MSG.OPEN_REPLY, encoded, "WHISPER", peer, { prio = "NORMAL" });
end

local function onOpenReply(body)
    local token, accepted, retryAfter, refuseReason = body[3], body[4], body[5], body[6];
    local session = sessions[token];
    if (not session or session.role ~= "opener" or session.closed) then return; end
    heardFrom(session);

    -- The peer already runs a full session with us that it keeps (see
    -- onOpen's duplicate check) - that one covers both directions, so just
    -- drop ours: no promotion, no retry.
    if (accepted ~= 1 and refuseReason == "dup") then
        FL.Sync.Debug.Log("SESS", 1, "%s: they refused · we both opened at once, theirs wins", label(session));
        session.endReason = "dup";
        closeSession(session);
        return;
    end

    if (accepted ~= 1) then
        -- retryAfter > 0 is a MAX_SERVE refusal; 0 means refused outright
        -- (gate closed on their side, or an unknown domain/mode).
        local reason = (retryAfter and retryAfter > 0) and "busy" or "refused";
        FL.Sync.Debug.Log("SESS", 1, "%s: they refused · %s%s", label(session), (reason == "busy") and "busy" or "gate closed there",
            (retryAfter and retryAfter > 0) and (", retry in " .. retryAfter .. "s") or "");
        session.endReason = reason;

        -- Phase 6: a secondary that flat-out refuses is treated the same as
        -- an abort for reassignment purposes (spec 7.4 step 4's "aborts or
        -- times out" covers this outcome just as well) - no retry timer for
        -- a secondary; the primary's own queue picking up the leftovers IS
        -- the fallback, not a second attempt at the same secondary.
        if (session.mode == "pull") then
            local parent = session.parent;
            closeSession(session);
            reportSecondaryFinished(parent, session, reason);
            return;
        end

        local domain, peer, remoteSummary, secondaryNames = session.domain, session.peer, session.remoteSummaryRaw, session.secondaryNames;
        closeSession(session);

        -- Spec 7.3 step 1: "If the reply is a refusal, it tries the next
        -- responder." The first secondary (already ranked next-best by
        -- Coordinator's planDomain) becomes the primary; the rest stay
        -- secondaries. Its summary comes from Peers, which recorded it from
        -- the same discovery round's HELLO_ACK.
        if (secondaryNames and #secondaryNames > 0) then
            local rest = {};
            for i = 2, #secondaryNames do table.insert(rest, secondaryNames[i]); end
            local nextPrimary = secondaryNames[1];
            FL.Sync.Debug.Log("SESS", 1, "history sync: %s is the new main peer · %s %s", nextPrimary, peer, tostring(reason));
            Session.Open(domain, nextPrimary, FL.Sync.Peers.SummaryOf(nextPrimary, domain.id), rest);
            return;
        end

        -- No other candidate: plan Phase 5's own checklist ("B logs refuse
        -- ... reason=busy, then tries again after retryAfter") - a single
        -- retry through the normal Session.Open path (its own
        -- HasActiveSession/gate checks still apply, so this is a no-op if
        -- something else already opened a session for this domain by then).
        if (retryAfter and retryAfter > 0) then
            Scheduler.After(retryAfter, 0, function()
                Session.Open(domain, peer, remoteSummary, secondaryNames);
            end, "sessionRefuseRetry");
        end
        return;
    end

    -- Phase 6: a pull-mode opener already knows its exact bucket list (the
    -- primary's compare already produced it - see assignBucketsWithSecondaries)
    -- so it skips COMPARING entirely and goes straight to reconciling.
    if (session.mode == "pull") then
        setState(session, "RECONCILING");
        advanceBuckets(session);
    else
        setState(session, "COMPARING");
        beginCompare(session);
    end
end

local function onMonths(body)
    local token, tree, flat = body[3], body[4], body[5];
    local session = sessions[token];
    if (not session or session.closed) then return; end
    heardFrom(session);

    if (session.role == "server") then
        local gen = body[6]; -- nil on an old/other sender, but this addon always sends it - handleMonthsRequest just echoes whatever arrives
        handleMonthsRequest(session, tree, flat, gen);
    else
        -- Archive-tier reply only (window uses DAYS) - body[6..8] (batchIndex/
        -- totalBatches/gen) only exist on a reply, never on the 5-field
        -- request the server branch above handles, so role already
        -- disambiguates the shape safely. A batch whose echoed gen doesn't
        -- match the CURRENT attempt is a straggler from an attempt
        -- scheduleCompareRetry already retried past - see sendMonthsRequest's
        -- own comment for why that must be dropped, not accumulated.
        local batchIndex, totalBatches, gen = body[6], body[7], body[8];
        if (gen ~= session.archiveGen) then
            FL.Sync.Debug.Log("SESS", 2, "%s: ignored an old archive-months reply · round %s, now on %d", label(session), tostring(gen), session.archiveGen);
            return;
        end

        session.archiveReplyFlat = session.archiveReplyFlat or {};
        for _, v in ipairs(flat) do table.insert(session.archiveReplyFlat, v); end

        -- Every index 1..totalBatches must be SEEN, not just whichever one
        -- happens to be the highest - see sendFlatBatches' own comment on
        -- why a single "isLast" boolean let a lost middle batch (e.g. a
        -- whole month) go unnoticed while a later batch still completed the
        -- compare phase.
        session.archiveBatchesSeen = session.archiveBatchesSeen or {};
        session.archiveBatchesSeen[batchIndex] = true;
        if (Util.tcount(session.archiveBatchesSeen) == totalBatches) then
            session.compareDone.a = true;
            tryFinishCompare(session);
        end
    end
end

local function onDays(body)
    local token, mismatchedMonths, flatDays, batchIndex, totalBatches, gen = body[3], body[4], body[5], body[6], body[7], body[8];
    local session = sessions[token];
    if (not session or session.role ~= "opener" or session.closed) then return; end
    heardFrom(session);

    if (gen ~= session.windowGen) then
        FL.Sync.Debug.Log("SESS", 2, "%s: ignored an old days reply · round %s, now on %d", label(session), tostring(gen), session.windowGen);
        return;
    end

    -- The same full mismatchedMonths list rides along on every batch (cheap,
    -- just a handful of month keys) - just overwrite each time. flatDays is
    -- accumulated across however many batches sendFlatBatches needed.
    session.windowMismatchedMonths = mismatchedMonths;
    session.windowReplyFlat = session.windowReplyFlat or {};
    for _, v in ipairs(flatDays) do table.insert(session.windowReplyFlat, v); end

    -- Every index 1..totalBatches must be SEEN, not just the highest one -
    -- see sendFlatBatches' own comment: a single "isLast" boolean let a lost
    -- middle batch (observed live: an entire month's days going missing)
    -- slip past unnoticed while a later batch still completed the compare
    -- phase.
    session.windowBatchesSeen = session.windowBatchesSeen or {};
    session.windowBatchesSeen[batchIndex] = true;
    if (Util.tcount(session.windowBatchesSeen) == totalBatches) then
        session.compareDone.w = true;
        tryFinishCompare(session);
    end
end

local function onHashes(body)
    local token, tree, key, idMode, list, isRetry = body[3], body[4], body[5], body[6], body[7], body[8];
    local session = sessions[token];
    if (not session or session.closed) then return; end
    heardFrom(session);
    onHashesReceived(session, tree, key, idMode == 1, list, isRetry == 1);
end

local function onWant(body)
    local token, tree, key, idMode, list = body[3], body[4], body[5], body[6], body[7];
    local session = sessions[token];
    if (not session or session.closed) then return; end
    heardFrom(session);
    onWantReceived(session, tree, key, idMode == 1, list);
end

local function onRowsOrMarks(msgType, body, senderName, bytes)
    local token = body[3];
    local session = sessions[token];
    if (not session or session.closed) then return; end
    heardFrom(session);
    session.lastDataAt = GetTime(); -- scheduleWantRetry: the peer is still answering, don't retry yet
    session.recvBytes = (session.recvBytes or 0) + (bytes or 0); -- Phase 6: real wire bytes for the "[PERF] rate" kbps field

    local batchNum = body[4];
    local tree, key, batchIndex, totalBatches;
    if (msgType == MSG.ROWS) then
        tree, key, batchIndex, totalBatches = body[8], body[9], body[10], body[11];
    else
        tree, key, batchIndex, totalBatches = body[7], body[8], body[9], body[10];
    end

    local result = session.domain:ApplyEntries(msgType, body, senderName);
    local total = (result.added or 0) + (result.dup or 0) + (result.tombstoned or 0) + (result.expired or 0) + (result.rejected or 0) + (result.invalid or 0);
    notePeerRecv(Util.stripRealm(senderName), result.added or 0, total - (result.added or 0));

    if (msgType == MSG.ROWS) then
        session.recv = session.recv + total;
        session.recvAdded = (session.recvAdded or 0) + (result.added or 0);
        FL.Sync.Debug.Log("SESS", 2, "%s: got batch %d · %d rows: %d new, %d already had, %d rejected",
            label(session), batchNum, total, result.added, result.dup, (result.rejected or 0) + (result.invalid or 0) + (result.expired or 0));
    else
        session.marksRecv = session.marksRecv + total;
        session.marksAdded = (session.marksAdded or 0) + (result.added or 0) + (result.tombstoned or 0); -- pins + deletes that changed something
        FL.Sync.Debug.Log("SESS", 2, "%s: got batch %d · %d pins/deletes: %d deletes applied, %d pins added",
            label(session), batchNum, total, result.tombstoned or 0, result.added or 0);
    end

    -- Every index 1..totalBatches must be SEEN, not just the highest one -
    -- same fix, same reason, as the compare-phase DAYS/archive-MONTHS
    -- batches (see sendFlatBatches' own comment): a lost middle chunk while
    -- the one marked "last" still arrives must not look like a satisfied
    -- WANT. A want-retry resending the identical request produces an
    -- equivalent (deterministic) chunk set, so accumulating indices across
    -- a retry is safe - no generation tag needed here unlike the compare
    -- phase, where the underlying mismatch computation could legitimately
    -- differ between a request and its retry.
    local bucket = getOrCreateBucket(session, tree, key);
    bucket.wantBatchesSeen = bucket.wantBatchesSeen or {};
    bucket.wantBatchesSeen[batchIndex] = true;
    if (Util.tcount(bucket.wantBatchesSeen) == totalBatches or wantFilledByContent(session, bucket)) then
        bucket.wantSatisfied = true;
        maybeFinishBucket(session, bucket);
    end
end

-- [token] = GetTime() a server session closed after an empty DONE_ACK. If
-- that ack was lost, the opener re-sends DONE for a token we no longer
-- have; answering it with another empty DONE_ACK (instead of silence) lets
-- the opener finish cleanly rather than running out its retries.
local recentlyDone = {};
local RECENTLY_DONE_TTL = 120;

-- `session`, when given, appends our final roots (body[5..10]) - only on the
-- empty ack that closes the session; the opener compares them in onDoneAck.
local function sendDoneAck(token, peer, flat, session)
    local body = { Constants.PROTO_VERSION, MSG.DONE_ACK, token, flat };
    if (session and #flat == 0) then
        for _, v in ipairs({ finalRootFields(session) }) do table.insert(body, v); end
    end
    local encoded = Codec.EncodeMessage(body);
    Transport.Send(MSG.DONE_ACK, encoded, "WHISPER", peer, { prio = "NORMAL" });
end

--- Buckets where this side asked for data (non-empty WANT) and hasn't yet
--- received every batch of the answer, as a flat tree,key,... list.
local function unsatisfiedBuckets(session)
    local flat = {};
    for _, b in pairs(session.buckets) do
        if ((b.wantCount or 0) > 0 and not b.wantSatisfied) then
            table.insert(flat, b.tree); table.insert(flat, b.key);
        end
    end
    return flat;
end

local function onDone(body, senderName)
    local token = body[3];
    local session = sessions[token];

    local now = GetTime();
    for t, at in pairs(recentlyDone) do
        if (now - at > RECENTLY_DONE_TTL) then recentlyDone[t] = nil; end
    end

    if (not session or session.closed) then
        if (recentlyDone[token]) then sendDoneAck(token, Util.stripRealm(senderName), {}); end
        return;
    end
    if (session.role ~= "server") then return; end
    heardFrom(session);

    -- Phase 6 review (DONE_ACK, see sendDone): don't close while we're
    -- still owed data - name those buckets so the opener re-sends them, and
    -- stay open (our own WANT retries keep running meanwhile).
    local pending = unsatisfiedBuckets(session);
    sendDoneAck(token, session.peer, pending, session);
    if (#pending > 0) then
        FL.Sync.Debug.Log("SESS", 1, "%s: not done yet · %d buckets incomplete, asked them to resend", label(session), #pending / 2);
        return;
    end

    local dur = GetTime() - session.startedAt;
    -- body[6..11]: the opener's final roots, taken when it sent this DONE
    -- (full mode only; pull-mode DONE and older builds carry none).
    local finalMatch = rootsMatchFinal(session, body, 6);
    local exact = finalMatch ~= nil;
    local rootsMatch;
    if (exact) then rootsMatch = finalMatch; else rootsMatch = computeRootsMatchServer(session); end
    session.rootsMatch = rootsMatch;
    session.rootsExact = exact;
    FL.Sync.Debug.Log("SESS", 1, "%s: done, %s · sent %d, got %d rows, %d pins/deletes, %d buckets, %s",
        label(session), rootsMatch and (exact and "now in sync" or "now in sync (loose check)") or "STILL DIFFERENT",
        session.sent, session.recv, session.marksSent + session.marksRecv, session.bucketsSeen or 0, fmtTime(dur));
    recentlyDone[token] = now;
    closeSession(session);
end

--- Opener side of DONE_ACK: an empty list closes the session; otherwise
--- re-queue whatever the server says it's still missing and, once that has
--- flushed, send DONE again (finishSessionAsOpener's FINISHING branch).
local function onDoneAck(body)
    local token, flat = body[3], body[4] or {};
    local session = sessions[token];
    if (not session or session.role ~= "opener" or session.closed or session.state ~= "FINISHING") then return; end
    heardFrom(session);
    session.doneGen = (session.doneGen or 0) + 1; -- disarm the pending DONE retry timer

    if (#flat == 0) then
        session.finalRootsMatch = rootsMatchFinal(session, body, 5);
        completeOpener(session, true);
        return;
    end

    local requeued = 0;
    for i = 1, #flat, 2 do
        local tree, key = flat[i], flat[i + 1];
        local bucket = session.buckets[tree .. ":" .. key];
        if (bucket and bucket.peerWantEntries and #bucket.peerWantEntries > 0) then
            -- Same entries, same order -> EncodeEntries chunks them exactly as
            -- the first time, so batchIndex/totalBatches line up with what the
            -- server has already seen (it only needs the missing indices).
            local chunks = session.domain:EncodeEntries(bucket.peerWantEntries);
            for idx, chunk in ipairs(chunks) do
                chunk.tree = tree; chunk.key = key; chunk.batchIndex = idx; chunk.totalBatches = #chunks;
                table.insert(session.outQueue, chunk);
            end
            requeued = requeued + 1;
        end
    end
    FL.Sync.Debug.Log("SESS", 1, "%s: they replied to done · %d buckets still pending, resent %d", label(session), #flat / 2, requeued);

    if (session.doneSends >= DONE_RETRY_MAX) then
        completeOpener(session, false);
        return;
    end
    session.awaitingFlush = true;
    drainOutgoing(session);
    trySessionComplete(session);
end

local function onPing(body)
    local session = sessions[body[3]];
    if (not session or session.closed) then return; end
    heardFrom(session);
    -- The server answers so the opener can tell a live primary from a dead
    -- one (startParentKeepalive). The opener never answers - no ping-pong.
    if (session.role == "server") then
        sendControl(session, MSG.PING, { Constants.PROTO_VERSION, MSG.PING, session.token });
    end
end

local function onAbort(body)
    local token, reason = body[3], body[4];
    local session = sessions[token];
    if (not session) then return; end
    -- Echoes the sender's own reason verbatim (gate/timeout/busy/version)
    -- rather than wrapping it, so a gate-triggered abort reads as
    -- "reason=gate" on BOTH clients, matching the plan's own checklist
    -- ("Expect abort reason=gate on both clients") - `skipSend=true` since
    -- an ABORT in reply to an ABORT would just ping-pong forever otherwise.
    abortSession(session, reason, true);
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

--- True while an OPENER session for `domainId` is already in flight -
--- Sync/Coordinator.lua checks this before opening a second one for the
--- same domain while one is still running.
function Session.HasActiveSession(domainId)
    for _, s in pairs(sessions) do
        if (s.domainId == domainId and s.role == "opener" and not s.closed) then return true; end
    end
    return false;
end

--- Opens a full-mode session with `peerName` (the primary) for `domain`.
--- `remoteSummary` is the positional HistoryDomain-style summary
--- Sync/Peers.lua already captured for this responder during discovery
--- (spec 7.2) - used to decide whether the archive tier needs comparing at
--- all (spec 7.3 step 2) and, loosely, for this session's own `rootsMatch`
--- line at the end. `secondaryNames` (Phase 6, spec 7.4) is the plain array
--- of up to MAX_SECONDARIES peer names Sync/Coordinator.lua chose alongside
--- the primary during the same discovery round - real per-peer bucket
--- assignment happens later, once the primary's own compare phase knows the
--- real mismatched-bucket list (see assignBucketsWithSecondaries).
function Session.Open(domain, peerName, remoteSummary, secondaryNames)
    if (Session.HasActiveSession(domain.id)) then
        FL.Sync.Debug.Log("SESS", 2, "history sync: not starting one with %s · one is already running", peerName);
        return;
    end
    if (not gateOkFor(domain)) then
        FL.Sync.Debug.Log("SESS", 2, "history sync: not starting one with %s · gate closed", peerName);
        return;
    end
    -- Already serving this peer a full session: it's symmetric, so it's
    -- already fixing whatever we'd fix by opening our own.
    if (findFullSessionWith(domain.id, peerName, "server")) then
        FL.Sync.Debug.Log("SESS", 1, "history sync: not starting one with %s · already serving them", peerName);
        return;
    end

    local token = newToken();
    local session = {
        token = token, domainId = domain.id, domain = domain, role = "opener", mode = "full",
        peer = peerName, state = "OPENING", startedAt = GetTime(),
        buckets = {}, bucketQueue = {}, inFlightCount = 0, bucketsDone = 0, bucketsSeen = 0,
        sent = 0, recv = 0, marksSent = 0, marksRecv = 0,
        outQueue = {}, outBatchNum = 0, prefixBusy = {}, prefixCursor = 0, closed = false,
        secondaryNames = secondaryNames or {}, reclaimed = {},
    };

    session.remoteSummaryRaw = remoteSummary; -- kept verbatim only to retry Session.Open with the same args after a "busy" refusal (see onOpenReply)
    if (type(remoteSummary) == "table") then
        session.remoteWindowRoot = { count = remoteSummary[1] or 0, x = remoteSummary[2] or 0, s = remoteSummary[3] or 0 };
        session.remoteArchiveRoot = { count = remoteSummary[4] or 0, x = remoteSummary[5] or 0, s = remoteSummary[6] or 0 };
    end

    trackSession(session);

    FL.Sync.Debug.Log("SESS", 1, "%s: asking to start · full sync", labelFor(token, peerName));
    local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN, token, domain.id, "full" });
    Transport.Send(MSG.OPEN, encoded, "WHISPER", peerName, { prio = "NORMAL" });
end

--- True while ANY session (opener or server, any domain) is open - spec
--- 7.5's "if ... no session is running" condition for the periodic HELLO.
function Session.AnyActive()
    for _, s in pairs(sessions) do
        if (not s.closed) then return true; end
    end
    return false;
end

--- Inbound sessions this client could still accept right now - HELLO's
--- "free session slots" field (spec section 6).
function Session.FreeSlots()
    return math.max(0, maxServe() - servingCount);
end

--- /fl debug maxserve <n>: in-memory override for testing OPEN_REPLY
--- refusals (plan Phase 5). nil restores the real Constants.MAX_SERVE.
function Session.SetMaxServeOverride(n)
    maxServeOverride = tonumber(n);
    FL.Sync.Debug.Log("TEST", 1, "maxserve: serve limit set to %s", maxServeOverride and tostring(maxServeOverride) or "default");
end

--- (outCount, inCount) of currently active sessions - backs /fl sync
--- sessions' header line.
function Session.Counts()
    local out, inCount = 0, 0;
    for _, s in pairs(sessions) do
        if (s.role == "opener") then out = out + 1; else inCount = inCount + 1; end
    end
    return out, inCount;
end

--- Every active session as a plain snapshot table - backs /fl sync sessions.
function Session.All()
    local out = {};
    for token, s in pairs(sessions) do
        table.insert(out, {
            token = token, domainId = s.domainId, role = s.role, mode = s.mode, peer = s.peer, state = s.state,
            bucketsDone = s.bucketsDone or 0, bucketsTotal = s.bucketsTotalKnown or s.bucketsSeen or 0,
            bucketsTotalKnown = s.bucketsTotalKnown ~= nil,
            sent = s.sent, recv = s.recv, recvAdded = s.recvAdded or 0, marksAdded = s.marksAdded or 0, marksSent = s.marksSent or 0, elapsed = GetTime() - s.startedAt,
            startLocalCount = s.startLocalCount,
            remoteCount = s.startRemoteCount,
            isSecondary = s.parent ~= nil,
        });
    end
    table.sort(out, function(a, b) return a.token < b.token; end);
    return out;
end

function Session.MaxServe()
    return maxServe();
end

--- Every peer we've exchanged ROWS/MARKS with since login, lifetime totals -
--- backs UI/SyncStatusWindow.lua's per-peer row view (survives individual
--- sessions opening/closing, unlike Session.All()'s per-session counters).
function Session.PeerTotals()
    local out = {};
    for name, t in pairs(peerTotals) do
        table.insert(out, { name = name, recvAdded = t.recvAdded, recvOther = t.recvOther, sent = t.sent });
    end
    table.sort(out, function(a, b) return a.name < b.name; end);
    return out;
end

--- Registers cb(session) to run once for every session as it closes:
--- completed, aborted or timed out. `session.endReason` is the abort reason
--- (nil when it finished normally) and `session.rootsMatch` whether the
--- digests matched at the end (nil when it never got that far), and
--- `session.rootsExact` whether that came from the peer's final roots
--- (true) or the loose start-of-session comparison (false).
function Session.OnEnded(cb)
    table.insert(endedCallbacks, cb);
end

--- Phase 6 instrumentation (spec's own "[COMM] ctl queue ..." sample): logs
--- Net/Transport.lua's own send-queue depth every 10s, but only while at
--- least one session is actually open - see that file's own comment on why
--- this reports OUR queue rather than ChatThrottleLib's private internals.
local function logQueueSample()
    if (Util.tcount(sessions) == 0) then return; end
    local counts, busy = Transport.QueueSample();
    FL.Sync.Debug.Log("COMM", 2, "send queue · %d bulk, %d normal, %d alert waiting, %d prefixes busy",
        counts.BULK or 0, counts.NORMAL or 0, counts.ALERT or 0, busy);
end

function Session.Init()
    Transport.Register(MSG.OPEN, onOpen);
    Transport.Register(MSG.OPEN_REPLY, onOpenReply);
    Transport.Register(MSG.MONTHS, onMonths);
    Transport.Register(MSG.DAYS, onDays);
    Transport.Register(MSG.HASHES, onHashes);
    Transport.Register(MSG.WANT, onWant);
    Transport.Register(MSG.ROWS, function(body, sender, dist, bytes) onRowsOrMarks(MSG.ROWS, body, sender, bytes); end);
    Transport.Register(MSG.MARKS, function(body, sender, dist, bytes) onRowsOrMarks(MSG.MARKS, body, sender, bytes); end);
    Transport.Register(MSG.DONE, onDone);
    Transport.Register(MSG.DONE_ACK, onDoneAck);
    Transport.Register(MSG.PING, onPing);
    Transport.Register(MSG.ABORT, onAbort);

    -- Deliberately a raw C_Timer, not Scheduler.Every - see
    -- UI/SyncStatusWindow.lua's own refresh-ticker comment for why: every
    -- Scheduler timer unconditionally logs its own "[SCHED] timer fire
    -- ..." line, which would otherwise double up with (and add pure noise
    -- ahead of) the actual "[COMM] ctl queue ..." line this already
    -- produces on its own, every 10s, forever.
    C_Timer.NewTicker(10, logQueueSample);

    -- Plan Phase 5: "Abort every session with reason=gate when the gate
    -- closes." A snapshot of tokens is iterated (not `sessions` itself)
    -- since abortSession mutates it mid-loop.
    Gate.OnChange(function()
        local tokens = {};
        for token in pairs(sessions) do table.insert(tokens, token); end
        for _, token in ipairs(tokens) do
            local session = sessions[token];
            if (session and not session.closed and not gateOkFor(session.domain)) then
                abortSession(session, "gate");
            end
        end
    end);
end
