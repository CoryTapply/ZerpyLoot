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
  from a fresh HELLO. KNOWN GAP: the symmetric case (a bucket's HASHES, or
  a server's HASHES reply, itself getting lost before any WANT exists to
  retry) isn't covered the same way yet - only observed, so far, on the
  WANT/response side; see docs/sync-deviations.md "Phase 5" for why a naive
  "always reply to incoming HASHES" fix was rejected (ping-pong risk) and
  wasn't attempted here under time pressure.
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

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(seconds));
    local m, s = math.floor(seconds / 60), seconds % 60;
    if (m > 0) then return ("%dm%ds"):format(m, s); end
    return ("%ds"):format(s);
end

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

local abortSession; -- forward declaration: resetIdleTimer's timer closure below captures this local and calls whatever it's later assigned to (defined further down this file)
local reportSecondaryFinished; -- forward declaration (Phase 6): abortSession and onOpenReply's busy-refusal path both call this for a pull-mode session, before its own dependencies (advanceBuckets etc.) are defined
local trySessionComplete; -- forward declaration (Phase 6 fix): drainOutgoing's onSent/onFail (defined before advanceBuckets/finishSessionAsOpener exist as locals) need to re-check completion once a send actually confirms - see trySessionComplete's own comment, further down

local function resetIdleTimer(session)
    if (session.idleTimer) then Scheduler.Cancel(session.idleTimer); end
    session.idleTimer = Scheduler.After(Constants.SESSION_IDLE_TIMEOUT, 0, function()
        abortSession(session, "timeout");
    end, "sessionIdle");
end
local touchSession = resetIdleTimer;

local function cleanupSession(session)
    sessions[session.token] = nil;
    if (session.role == "server") then
        servingCount = math.max(0, servingCount - 1);
    end
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
    if (session.idleTimer) then Scheduler.Cancel(session.idleTimer); end

    local progress = session.bucketsTotalKnown and ("%d/%d"):format(session.bucketsDone or 0, session.bucketsTotalKnown) or "?";
    FL.Sync.Debug.Log("SESS", 1, "%s abort reason=%s state=%s progress=%s", session.token, reason, session.state, progress);

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

    cleanupSession(session);
end

--- Logs the plan's own sample "[SESS] k7Q2 state COMPARING->RECONCILING"
--- line (opener-only transitions: OPENING->COMPARING, COMPARING->RECONCILING).
local function setState(session, newState)
    FL.Sync.Debug.Log("SESS", 1, "%s state %s->%s", session.token, session.state, newState);
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

local function drainOutgoing(session)
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

        session.prefixBusy[prefix] = true;
        local startedAt = GetTime();
        -- onQueued (not the return value) is what guarantees "batch out" prints
        -- before "batch sent": ChatThrottleLib can call onSent/onFail
        -- SYNCHRONOUSLY from inside Transport.Send when bandwidth is available,
        -- so logging after Transport.Send returns would sometimes print the
        -- "sent" line first. See Net/Transport.lua's own comment on onQueued.
        Transport.Send(msgType, encoded, "WHISPER", session.peer, {
            prio = "BULK", prefix = prefix,
            onQueued = function()
                FL.Sync.Debug.Log("SESS", 2, "%s batch out #%d rows=%d marks=%d enc=%s prefix=%s",
                    session.token, batchNum, (chunk.kind == "ROWS") and chunk.count or 0, (chunk.kind == "MARKS") and chunk.count or 0,
                    FL.Sync.Debug.FormatBytes(stats.enc), prefix);
            end,
            onSent = function()
                FL.Sync.Debug.Log("SESS", 2, "%s batch sent #%d dur=%.1fs prefix=%s", session.token, batchNum, GetTime() - startedAt, prefix);
                session.prefixBusy[prefix] = false;
                if (not session.closed) then touchSession(session); drainOutgoing(session); trySessionComplete(session); end
            end,
            onFail = function()
                FL.Sync.Debug.Warn("SESS", "%s batch send fail #%d prefix=%s", session.token, batchNum, prefix);
                session.prefixBusy[prefix] = false;
                if (not session.closed) then drainOutgoing(session); trySessionComplete(session); end
            end,
        });
    end
end

--------------------------------------------------------------------------
-- Per-bucket HASHES/WANT exchange (shared by both roles - see this file's
-- header comment on why the actual exchange, once a bucket is in play, is
-- symmetric regardless of who's the opener).
--------------------------------------------------------------------------

--- `isRetry` (Phase 6 fix - see scheduleHashesRetry below) tags this send as
--- a resend of an already-sent bucket, not a fresh one - appended as a new
--- trailing field (spec 4.7's "new fields may only be appended" rule).
local function sendHashesForBucket(session, bucket, isRetry)
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
        FL.Sync.Debug.Warn("SESS", "%s hash collision %s=%s fallback=fullIds",
            session.token, (bucket.tree == "W") and "day" or "month", tostring(bucket.key));
    end

    local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.HASHES, session.token, bucket.tree, bucket.key, collision and 1 or 0, list, isRetry and 1 or 0 });
    Transport.Send(MSG.HASHES, encoded, "WHISPER", session.peer, { prio = "NORMAL" });
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

local function scheduleHashesRetry(session, bucket, tree, key)
    Scheduler.After(HASHES_RETRY_DELAY, 0, function()
        if (session.closed or bucket.recvHashesIn) then return; end
        bucket.hashesRetries = (bucket.hashesRetries or 0) + 1;
        if (bucket.hashesRetries > HASHES_RETRY_MAX) then
            FL.Sync.Debug.Warn("SESS", "%s bucket %s hashes retry exhausted", session.token, tostring(key));
            return;
        end
        FL.Sync.Debug.Log("SESS", 1, "%s bucket %s hashes retry attempt=%d", session.token, tostring(key), bucket.hashesRetries);
        sendHashesForBucket(session, bucket, true);
        scheduleHashesRetry(session, bucket, tree, key);
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

    FL.Sync.Debug.Log("SESS", 2, "%s bucket %s local=%d remote=%d want=%d give=%d",
        session.token, tostring(bucket.key), #bucket.myRawList, bucket.remoteCount or 0, bucket.wantCount, bucket.giveCount);

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

local function sendWant(session, tree, key, idMode, missing)
    local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.WANT, session.token, tree, key, idMode and 1 or 0, missing });
    Transport.Send(MSG.WANT, encoded, "WHISPER", session.peer, { prio = "NORMAL" });
end

local function scheduleWantRetry(session, bucket, tree, key)
    Scheduler.After(WANT_RETRY_DELAY, 0, function()
        if (session.closed or bucket.wantSatisfied) then return; end -- self-checking: no handle to cancel, just a no-op if already done
        bucket.wantRetries = (bucket.wantRetries or 0) + 1;
        if (bucket.wantRetries > WANT_RETRY_MAX) then
            FL.Sync.Debug.Warn("SESS", "%s bucket %s want retry exhausted", session.token, tostring(key));
            return;
        end
        FL.Sync.Debug.Log("SESS", 1, "%s bucket %s want retry attempt=%d", session.token, tostring(key), bucket.wantRetries);
        sendWant(session, tree, key, bucket.myWantIdMode, bucket.myWant);
        scheduleWantRetry(session, bucket, tree, key);
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
    sendWant(session, tree, key, idMode, missing);

    if (#missing > 0) then
        bucket.myWant = missing;
        bucket.myWantIdMode = idMode;
        scheduleWantRetry(session, bucket, tree, key);
    end

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
        bucket.delegated = next_.delegatedTo ~= nil; -- Phase 6: full-mode only, see assignBucketsWithSecondaries
        session.inFlightCount = session.inFlightCount + 1;
        sendHashesForBucket(session, bucket);
        scheduleHashesRetry(session, bucket, next_.tree, next_.key);
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

--- Undoes a bucket's delegation and re-runs its want computation for real,
--- using the remote hash list already saved in onHashesReceived - no second
--- HASHES round trip needed, since the primary already exchanged HASHES for
--- EVERY bucket up front (spec 7.4 step 3's push direction already required
--- that). If the bucket had already finished (its push-direction giveDone
--- completed before this reassignment), its completion bookkeeping is
--- undone first so maybeFinishBucket can correctly redo it once the pull
--- side is also resolved.
local function reassignBucketToPrimary(parent, tree, key)
    local bucket = parent.buckets[tree .. ":" .. key];
    if (not bucket) then return; end -- shouldn't happen: the primary HASHES every bucket up front

    if (bucket.finished) then
        parent.inFlightCount = parent.inFlightCount + 1;
        parent.bucketsDone = math.max(0, (parent.bucketsDone or 0) - 1);
    end
    bucket.finished = false;
    bucket.delegated = false;

    local missing = missingFrom(bucket.remoteList or {}, bucket.myRawList or {});
    bucket.wantCount = #missing;
    bucket.wantSatisfied = (#missing == 0);
    sendWant(parent, tree, key, bucket.remoteIdMode, missing);
    if (#missing > 0) then
        bucket.myWant = missing;
        bucket.myWantIdMode = bucket.remoteIdMode;
        scheduleWantRetry(parent, bucket, tree, key);
    end

    maybeFinishBucket(parent, bucket);
end

--- Called once a secondary's pull session is done, one way or another
--- (normal finish, abort, timeout, or an outright OPEN_REPLY refusal) -
--- reassigns whatever it never finished back to the primary's own queue
--- (spec 7.4 step 4), folds its received-row count into the primary's
--- domain-wide total, and lets the primary's own finish check (above) run
--- again now that one fewer secondary is outstanding. `parent.closed` can
--- legitimately already be true here (e.g. the whole domain's gate closed
--- and aborted every session for it, primary included, in the same pass) -
--- nothing to reassign to in that case, so this is just a no-op.
reportSecondaryFinished = function(parent, pullSession, reason)
    if (not parent or parent.closed) then return; end

    local reassigned = 0;
    for _, b in ipairs(pullSession.assignedBuckets or {}) do
        local secBucket = pullSession.buckets[b.tree .. ":" .. b.key];
        if (not secBucket or not secBucket.finished) then
            reassignBucketToPrimary(parent, b.tree, b.key);
            reassigned = reassigned + 1;
        end
    end

    parent.secondaryRecvTotal = (parent.secondaryRecvTotal or 0) + pullSession.recv;
    parent.secondaryMarksTotal = (parent.secondaryMarksTotal or 0) + pullSession.marksRecv;
    parent.secondariesRemaining = math.max(0, (parent.secondariesRemaining or 1) - 1);

    if (reassigned > 0) then
        FL.Sync.Debug.Log("SESS", 1, "reassign d%d from=%q buckets=%d to=%q reason=%s",
            parent.domainId, pullSession.peer, reassigned, parent.peer, reason);
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

    sessions[token] = session;
    resetIdleTimer(session);

    FL.Sync.Debug.Log("SESS", 1, "%s open d%d mode=pull role=opener peer=%q buckets=%d",
        token, parent.domainId, peerName, #bucketList);
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

    FL.Sync.Debug.Log("SESS", 1, "plan d%d primary=%q secondaries=[%s] assign %s",
        session.domainId, session.peer, table.concat(secondaryParts, ","), table.concat(assignParts, " "));

    for slotIdx = 2, #slots do
        local slot = slots[slotIdx];
        if (#slot > 0) then
            openSecondaryPull(session, slot.name, slot);
        end
    end
end

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
    FL.Sync.Debug.Log("PERF", 1, "rate %s peer=%q rows=%d dur=%s rowsPerMin=%d kbps=%.2f",
        session.token, session.peer, session.recv, formatDuration(dur), rowsPerMin, kbps);
end

finishSessionAsOpener = function(session)
    local dur = math.max(0.001, GetTime() - session.startedAt);
    local rootsMatch = computeRootsMatchOpener(session);

    FL.Sync.Debug.Log("SESS", 1, "%s done d%d sent=%d recv=%d marks=%d buckets=%d dur=%s rootsMatch=%s",
        session.token, session.domainId, session.sent, session.recv, session.marksSent + session.marksRecv,
        session.bucketsTotalKnown or 0, formatDuration(dur), rootsMatch and "yes" or "no");
    logSessionRate(session, dur);

    local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.DONE, session.token, session.sent, session.recv });
    Transport.Send(MSG.DONE, encoded, "WHISPER", session.peer, { prio = "NORMAL" });
    closeSession(session);

    if (session.mode == "pull" and session.parent) then
        reportSecondaryFinished(session.parent, session, "done");
    elseif ((session.secondariesTotal or 0) > 0) then
        -- Phase 6: the domain-wide summary (spec's own "[SESS] sync
        -- complete ..." sample) - only the primary logs this, and only
        -- once every secondary has reported in (reportSecondaryFinished's
        -- advanceBuckets call is what re-triggers this function once
        -- secondariesRemaining reaches 0 - see advanceBuckets' own finish
        -- check above).
        local totalRows = session.recv + (session.secondaryRecvTotal or 0);
        local totalPeers = 1 + session.secondariesTotal;
        local totalRowsPerMin = (totalRows / dur) * 60;
        FL.Sync.Debug.Log("SESS", 1, "sync complete d%d peers=%d rows=%d dur=%s rowsPerMin=%d",
            session.domainId, totalPeers, totalRows, formatDuration(dur), totalRowsPerMin);
    end
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

    assignBucketsWithSecondaries(session, queue); -- Phase 6: sets session.bucketQueue (unchanged full list) and opens any secondary pull sessions
    session.bucketsTotalKnown = #queue;

    local keys = {};
    for _, b in ipairs(queue) do table.insert(keys, tostring(b.key)); end
    FL.Sync.Debug.Log("SESS", 1, "%s buckets n=%d [%s]", session.token, #queue, table.concat(keys, ","));

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
local function sendMonthsRequest(session, tree)
    local Digest = session.domain:Tree();
    local flat = flattenAggList(Digest.Months(tree), "monthKey");
    local gen;
    if (tree == "W") then gen = session.windowGen; else gen = session.archiveGen; end
    local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.MONTHS, session.token, tree, flat, gen });
    Transport.Send(MSG.MONTHS, encoded, "WHISPER", session.peer, { prio = "NORMAL" });
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
            FL.Sync.Debug.Warn("SESS", "%s compare %s retry exhausted", session.token, tree);
            return;
        end

        FL.Sync.Debug.Log("SESS", 1, "%s compare %s retry attempt=%d", session.token, tree, session[countKey]);
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

        sendMonthsRequest(session, tree);
        scheduleCompareRetry(session, tree);
    end, "compareRetry");
end

local function beginCompare(session)
    local mine = session.domain:Summary();
    local myArchive = { count = mine[4], x = mine[5], s = mine[6] };
    local needArchive = session.remoteArchiveRoot ~= nil and (not aggEqual(myArchive, session.remoteArchiveRoot));

    session.compareDone = { w = false, a = not needArchive };
    session.windowGen = 1;
    session.archiveGen = 1;

    sendMonthsRequest(session, "W");
    scheduleCompareRetry(session, "W");

    if (needArchive) then
        sendMonthsRequest(session, "A");
        scheduleCompareRetry(session, "A");
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
    FL.Sync.Debug.Log("SESS", 2, "%s months %s local=%d remote=%d mismatched=[%s]",
        session.token, tree, #localMonths, #flat / 4, table.concat(labels, ","));

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
    return (domain.gate == "live") and Gate.CanLive() or Gate.CanSync();
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
        FL.Sync.Debug.Log("SESS", 1, "%s refuse peer=%q reason=gate", token, peer);
        local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN_REPLY, token, 0, 0 });
        Transport.Send(MSG.OPEN_REPLY, encoded, "WHISPER", peer, { prio = "NORMAL" });
        return;
    end

    if (servingCount >= maxServe()) then
        FL.Sync.Debug.Log("SESS", 1, "%s refuse peer=%q reason=busy retryAfter=%ds", token, peer, BUSY_RETRY_AFTER);
        local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN_REPLY, token, 0, BUSY_RETRY_AFTER });
        Transport.Send(MSG.OPEN_REPLY, encoded, "WHISPER", peer, { prio = "NORMAL" });
        return;
    end

    servingCount = servingCount + 1;
    local session = {
        token = token, domainId = domainId, domain = domain, role = "server", mode = mode,
        peer = peer, state = "SERVING", startedAt = GetTime(), buckets = {}, bucketsSeen = 0,
        sent = 0, recv = 0, marksSent = 0, marksRecv = 0,
        outQueue = {}, outBatchNum = 0, prefixBusy = {}, prefixCursor = 0, closed = false,
    };
    sessions[token] = session;
    resetIdleTimer(session);

    local bucketSuffix = "";
    if (mode == "pull" and flatBuckets) then bucketSuffix = (" buckets=%d"):format(#flatBuckets / 2); end
    FL.Sync.Debug.Log("SESS", 1, "%s accept d%d role=server mode=%s peer=%q serving=%d/%d%s",
        token, domainId, mode, peer, servingCount, maxServe(), bucketSuffix);
    local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN_REPLY, token, 1, 0 });
    Transport.Send(MSG.OPEN_REPLY, encoded, "WHISPER", peer, { prio = "NORMAL" });
end

local function onOpenReply(body)
    local token, accepted, retryAfter = body[3], body[4], body[5];
    local session = sessions[token];
    if (not session or session.role ~= "opener" or session.closed) then return; end
    touchSession(session);

    if (accepted ~= 1) then
        FL.Sync.Debug.Log("SESS", 1, "%s refuse peer=%q reason=busy retryAfter=%ds", token, session.peer, retryAfter or 0);

        -- Phase 6: a secondary that flat-out refuses is treated the same as
        -- an abort for reassignment purposes (spec 7.4 step 4's "aborts or
        -- times out" covers this outcome just as well) - no retry timer for
        -- a secondary; the primary's own queue picking up the leftovers IS
        -- the fallback, not a second attempt at the same secondary.
        if (session.mode == "pull") then
            local parent = session.parent;
            closeSession(session);
            reportSecondaryFinished(parent, session, "busy");
            return;
        end

        local domain, peer, remoteSummary, secondaryNames = session.domain, session.peer, session.remoteSummaryRaw, session.secondaryNames;
        closeSession(session);
        -- Plan Phase 5's own checklist: "B logs refuse ... reason=busy, then
        -- tries again after retryAfter" - a single retry through the normal
        -- Session.Open path (its own HasActiveSession/gate checks still
        -- apply, so this is a no-op if something else already opened a
        -- session with this domain by the time the delay elapses).
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
    touchSession(session);

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
            FL.Sync.Debug.Log("SESS", 2, "%s months A stale gen=%s current=%d - dropped", session.token, tostring(gen), session.archiveGen);
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
    touchSession(session);

    if (gen ~= session.windowGen) then
        FL.Sync.Debug.Log("SESS", 2, "%s days stale gen=%s current=%d - dropped", session.token, tostring(gen), session.windowGen);
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
    touchSession(session);
    onHashesReceived(session, tree, key, idMode == 1, list, isRetry == 1);
end

local function onWant(body)
    local token, tree, key, idMode, list = body[3], body[4], body[5], body[6], body[7];
    local session = sessions[token];
    if (not session or session.closed) then return; end
    touchSession(session);
    onWantReceived(session, tree, key, idMode == 1, list);
end

local function onRowsOrMarks(msgType, body, senderName, bytes)
    local token = body[3];
    local session = sessions[token];
    if (not session or session.closed) then return; end
    touchSession(session);
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
        FL.Sync.Debug.Log("SESS", 2, "%s batch in #%d rows=%d added=%d dup=%d rejected=%d",
            token, batchNum, total, result.added, result.dup, (result.rejected or 0) + (result.invalid or 0) + (result.expired or 0));
    else
        session.marksRecv = session.marksRecv + total;
        FL.Sync.Debug.Log("SESS", 2, "%s batch in #%d marks=%d tombstoned=%d added=%d", token, batchNum, total, result.tombstoned or 0, result.added or 0);
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
    if (Util.tcount(bucket.wantBatchesSeen) == totalBatches) then
        bucket.wantSatisfied = true;
        maybeFinishBucket(session, bucket);
    end
end

local function onDone(body)
    local token = body[3];
    local session = sessions[token];
    if (not session or session.closed) then return; end

    if (session.role == "server") then
        local dur = GetTime() - session.startedAt;
        local rootsMatch = computeRootsMatchServer(session);
        FL.Sync.Debug.Log("SESS", 1, "%s done d%d sent=%d recv=%d marks=%d buckets=%d dur=%s rootsMatch=%s",
            session.token, session.domainId, session.sent, session.recv, session.marksSent + session.marksRecv,
            session.bucketsSeen or 0, formatDuration(dur), rootsMatch and "yes" or "no");
    end

    closeSession(session);
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
        FL.Sync.Debug.Log("SESS", 2, "skip open d%d reason=alreadyActive peer=%q", domain.id, peerName);
        return;
    end
    if (not gateOkFor(domain)) then
        FL.Sync.Debug.Log("SESS", 2, "skip open d%d reason=gateClosed peer=%q", domain.id, peerName);
        return;
    end

    local token = newToken();
    local session = {
        token = token, domainId = domain.id, domain = domain, role = "opener", mode = "full",
        peer = peerName, state = "OPENING", startedAt = GetTime(),
        buckets = {}, bucketQueue = {}, inFlightCount = 0, bucketsDone = 0, bucketsSeen = 0,
        sent = 0, recv = 0, marksSent = 0, marksRecv = 0,
        outQueue = {}, outBatchNum = 0, prefixBusy = {}, prefixCursor = 0, closed = false,
        secondaryNames = secondaryNames or {},
    };

    session.remoteSummaryRaw = remoteSummary; -- kept verbatim only to retry Session.Open with the same args after a "busy" refusal (see onOpenReply)
    if (type(remoteSummary) == "table") then
        session.remoteWindowRoot = { count = remoteSummary[1] or 0, x = remoteSummary[2] or 0, s = remoteSummary[3] or 0 };
        session.remoteArchiveRoot = { count = remoteSummary[4] or 0, x = remoteSummary[5] or 0, s = remoteSummary[6] or 0 };
    end

    sessions[token] = session;
    resetIdleTimer(session);

    FL.Sync.Debug.Log("SESS", 1, "%s open d%d mode=full role=opener peer=%q", token, domain.id, peerName);
    local encoded = Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.OPEN, token, domain.id, "full" });
    Transport.Send(MSG.OPEN, encoded, "WHISPER", peerName, { prio = "NORMAL" });
end

--- /fl debug maxserve <n>: in-memory override for testing OPEN_REPLY
--- refusals (plan Phase 5). nil restores the real Constants.MAX_SERVE.
function Session.SetMaxServeOverride(n)
    maxServeOverride = tonumber(n);
    FL.Sync.Debug.Log("TEST", 1, "maxserve=%s", maxServeOverride and tostring(maxServeOverride) or "default");
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
            sent = s.sent, recv = s.recv, elapsed = GetTime() - s.startedAt,
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

--- Phase 6 instrumentation (spec's own "[COMM] ctl queue ..." sample): logs
--- Net/Transport.lua's own send-queue depth every 10s, but only while at
--- least one session is actually open - see that file's own comment on why
--- this reports OUR queue rather than ChatThrottleLib's private internals.
local function logQueueSample()
    if (Util.tcount(sessions) == 0) then return; end
    local counts, busy = Transport.QueueSample();
    FL.Sync.Debug.Log("COMM", 2, "ctl queue bulk=%d normal=%d alert=%d prefixesBusy=%d",
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
    Transport.Register(MSG.ABORT, onAbort);

    Scheduler.Every(10, 0, logQueueSample, "syncQueueSample");

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
