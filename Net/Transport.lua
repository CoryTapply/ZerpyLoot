--[[
AceComm plumbing for the sync system (spec section 6): registers the
FLoot/FLootS1-3 prefixes and dispatches decoded messages to whichever module
registered a handler for that message type.

Deviation from spec's module table (12.2): Transport.Send takes an
ALREADY-ENCODED string, not a raw body table the spec's "Send(type, body,
...)" wording suggests. Encoding (and its own "[CODEC] encode ..." debug
line, which needs message-specific details like rows=/players=/resp= that
only the caller knows) stays in Net/Codec.lua and Sync/Live.lua - see
Codec.lua's own header comment. Transport only decodes the generic envelope
(PROTO_VERSION + message type, via Codec.DecodeMessage) to find out which
handler to call; the handler decodes its own body fields.

Full prefix rotation across FLootS1-3 (spec 9.2, "at most one batch in
flight per prefix") is Phase 6: `opts.lane = "sync"` still auto-rotates
PREFIX_SYNC for a single send with no concurrency tracking of its own (used
by anything that just wants "one of the bulk prefixes"), but Phase 6's real
concurrency - several batches in flight AT ONCE for one session, one per
prefix - needs the CALLER to track which prefixes are free and pick one
explicitly, since only the caller (Sync/Session.lua) knows which of its own
batches are still in flight. `opts.prefix` (see Transport.Send's own
comment) exists for exactly that.

TEMPORARY WORKAROUND, in place as of Phase 2 (see docs/sync-deviations.md
"Phase 2: GUILD-distribution addon messages don't relay on this server" for
the full writeup of how this was diagnosed): `C_ChatInfo.SendAddonMessage`
with distribution "GUILD" reports success on the SENDING client (confirmed
via a raw, non-AceComm call - this isn't a send-side error, and it isn't
ChatThrottleLib/priority related either), but the message is never relayed
to other guild members by this server - confirmed with two clients, same
guild, same group: "PARTY" distribution delivers every time, "GUILD" never
does. Since the entire point of a LIVE_ROW/LIVE_DEL/LIVE_PIN broadcast is to
reach guild members who are OFFLINE from any group (spec 7.1), falling back
to the grouped-only distribution Phase 1 already had isn't an option.
`Transport.Send` below instead fans a "GUILD" request out as one WHISPER per
currently-online guild member (`guildMemberNames()`), so every call site
(`Sync/Live.lua` today) can keep asking for "GUILD" exactly as the spec
describes and never needs to know this is happening underneath.

Known costs/follow-ups, for whoever picks this back up:
- O(n) sends instead of one broadcast - n WHISPERs instead of 1 GUILD
  message, which eats into the per-prefix throttle budget (spec section 9)
  n times instead of once. Fine for a small guild doing occasional awards;
  will need real measurement (or a different fix) before Phase 8's "whole
  guild" soak test.
- Phase 4's HELLO is also GUILD-scoped (spec 7.2) and will hit this exact
  same wall - this fan-out approach (or whatever replaces it) needs to cover
  that too when Phase 4 is built, not just LIVE_*.
- A second, independent bug found while diagnosing this (not the cause of
  the GUILD issue, but worth fixing regardless) - FIXED in Phase 5, see this
  file's sendOne() and its own comment below for the fix: the bundled
  AceComm-3.0's SendCommMessage already forwards ChatThrottleLib's real
  success boolean to its own callback as a 4th argument (`didSend`) - our
  callback here just wasn't reading it, so `sent >= total` looked satisfied
  on every call regardless of outcome. Reading that 4th argument (no
  vendored-library edit needed) is the "a corrected local ctlCallback"
  option this entry originally flagged as still open; see sendOne().
- Before ripping this fan-out out: worth asking whoever runs/maintains this
  server whether GUILD-channel addon-message relay is a known, fixable gap
  server-side - if so, reverting to a real "GUILD" send everywhere (deleting
  this whole workaround) is simpler than keeping the fan-out long-term.

SECOND TEMPORARY WORKAROUND, added in Phase 5 (see docs/sync-deviations.md
"Phase 5: per-target send serialization" for the full writeup): AceComm-3.0's
multi-chunk reassembly spool (AceComm.multipart_spool, in
Libs/AceComm-3.0/AceComm-3.0.lua) is keyed only by
`prefix.."\t"..distribution.."\t"..sender` - there is no per-message id. If
TWO multi-chunk messages to the SAME target on the SAME prefix+distribution
are ever in flight at once, their chunks land in the same spool slot and
corrupt each other (a "First" chunk from message 2 overwrites message 1's
still-incomplete spool entry outright; stray "Next"/"Last" chunks get
appended to whichever message currently occupies the slot). Found live-
testing Phase 5's Test 4: Sync/Session.lua's `sendFlatBatches` (DAYS/archive-
MONTHS batching) fired multiple batches in a tight loop with no gap between
them, and separately `advanceBuckets`/`beginCompare` already fire multiple
HASHES/MONTHS sends back-to-back to the same peer - any of these, once
individually big enough to need 2+ AceComm chunks, risked exactly this
collision. `Transport.Send` below now queues per (prefix, distribution,
target) key and only starts the next queued send once the current one's
`onSent`/`onFail` fires (with a timeout fallback for a send that never calls
back at all - the original failure mode this whole investigation started
from) - this closes the gap for every call site at once instead of requiring
each one to manage its own backpressure, and makes `Sync/Session.lua`'s own
`sendFlatBatches`/`drainOutgoing` queues layer safely on top (they decide
*when* to hand a message to `Transport.Send`; this decides when it's safe to
actually put it on the wire).
]]

local FL = ForeverLoot;
local Transport = FL.Sync.Transport;
local Codec = FL.Sync.Codec;
local Constants = FL.Sync.Constants;
local Util = FL.Util;

local AceComm;
local handlers = {}; -- [msgType] = fn(body, senderName, distribution)
local syncCursor = 0;

local function msgName(msgType)
    return Constants.MSG_NAMES[msgType] or tostring(msgType);
end

local function prefixForLane(lane)
    if (lane == "sync") then
        local syncPrefixes = Constants.PREFIX_SYNC;
        syncCursor = (syncCursor % #syncPrefixes) + 1;
        return syncPrefixes[syncCursor];
    end
    return Constants.PREFIX_MAIN;
end

-- Bare names of every currently-online guild member except the local player
-- (stripped, matching every other name-keyed convention in this addon - see
-- Sync/Permissions.lua's own header comment). GetGuildRosterInfo's 9th
-- return is isOnline; offline members are skipped since whispering them
-- would just be a wasted send (and could error).
local function guildMemberNames()
    local names = {};
    local myName = Util.stripRealm(Util.UnitName("player"));
    local n = GetNumGuildMembers and GetNumGuildMembers() or 0;
    for i = 1, n do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i);
        if (name and isOnline) then
            local stripped = Util.stripRealm(name);
            if (not Util.iEquals(stripped, myName)) then
                table.insert(names, stripped);
            end
        end
    end
    return names;
end

-- AceComm-3.0's SendCommMessage calls our callback as
-- (callbackArg, sent, total, didSend) - `didSend` is CTL's real per-chunk
-- success boolean (see this file's header comment: previously unread here,
-- which is why "sent >= total" alone always looked like success). A
-- multi-chunk message's chunks may report success/failure individually;
-- `failed` tracks that an EARLIER chunk already came back false so the final
-- sent>=total call still reports the message as a whole correctly.
--
-- `resolve(ok)` is this message's own completion signal for sendQueues'
-- drain loop below (see this file's header comment, "SECOND TEMPORARY
-- WORKAROUND") - it decides whether to call the caller's onSent/onFail
-- (never both, and never more than once: `resolve` itself is the single
-- idempotency guard shared with the queue's own timeout fallback), then
-- lets the next queued send to this target start.
local function sendOne(msgType, encoded, dist, target, prefix, prio, name, resolve)
    FL.Sync.Debug.Log("COMM", 2, "send type=%s dist=%s prefix=%s prio=%s bytes=%d chunks=%d%s",
        name, dist, prefix, prio, #encoded, math.max(1, math.ceil(#encoded / 255)),
        target and (" target=" .. target) or "");
    FL.Sync.Debug.Count("comm.sent." .. name .. ".msgs", 1);
    FL.Sync.Debug.Count("comm.sent." .. name .. ".bytes", #encoded);

    local startedAt = GetTime();
    local failed = false;
    AceComm:SendCommMessage(prefix, encoded, dist, target, prio, function(_, sent, total, didSend)
        if (didSend == false) then failed = true; end
        if (sent >= total) then
            if (failed) then
                FL.Sync.Debug.Warn("COMM", "send fail type=%s bytes=%d dur=%.1fs target=%s", name, total, GetTime() - startedAt, tostring(target));
            else
                FL.Sync.Debug.Log("COMM", 2, "sent type=%s bytes=%d dur=%.1fs", name, total, GetTime() - startedAt);
            end
            resolve(not failed);
        end
    end);
end

--------------------------------------------------------------------------
-- Per-(prefix,distribution,target) send queue - see this file's header
-- comment ("SECOND TEMPORARY WORKAROUND") for why this exists: AceComm's
-- receive-side reassembly can only track ONE in-flight multi-chunk message
-- per (prefix,distribution,sender) key, so two multi-chunk sends to the same
-- target must never overlap on the wire. GUILD-fanout's per-recipient
-- WHISPERs each get their own key (different target), so the fan-out itself
-- stays fully parallel - only sends to the SAME target are serialized.
--------------------------------------------------------------------------

local sendQueues = {}; -- [key] = { items = {...}, sending = false }
local SEND_QUEUE_TIMEOUT = 10; -- seconds: safety valve if a send's own callback never fires at all (the original silent-loss failure mode)
-- A deliberate pause between consecutive sends to the SAME target, on top of
-- the serialization above. Found necessary in Phase 5 testing: even with
-- overlapping multi-chunk sends eliminated, a burst of several back-to-back
-- sends (e.g., 3 DAYS batches, 8 addon-message chunks total) still lost one
-- outright - no corruption, no warning, just gone. ChatThrottleLib's burst/
-- refill model assumes Blizzard's retail limits; spec section 2 itself
-- already flags "the exact limits in WoW Forever should be confirmed during
-- beta" as an open question. Pacing OUR OWN sends more conservatively than
-- CTL's model thinks is necessary costs a little latency on a bulk transfer
-- but doesn't require knowing this server's exact real limit. Only inserted
-- BETWEEN items already waiting in a queue - the first/only send to an
-- otherwise-idle target still fires immediately, same as before.
local SEND_QUEUE_GAP = 0.3;

local function queueKey(prefix, dist, target)
    return prefix .. "\t" .. dist .. "\t" .. tostring(target);
end

local drainQueue; -- forward declaration (drainQueue and the item's resolve() are mutually recursive)

drainQueue = function(key)
    local q = sendQueues[key];
    if (not q or q.sending or #q.items == 0) then return; end

    local item = table.remove(q.items, 1);
    q.sending = true;

    -- `resolved` is shared by BOTH ways this send can finish (AceComm's own
    -- callback, or the timeout below) - without it, a send that times out
    -- here but whose AceComm callback eventually DOES fire later (just very
    -- slowly) would call the caller's onFail AND onSent for the same send.
    local resolved = false;
    local function resolve(ok)
        if (resolved) then return; end
        resolved = true;
        if (q.timeoutHandle) then q.timeoutHandle:Cancel(); q.timeoutHandle = nil; end
        if (ok) then
            if (item.opts.onSent) then item.opts.onSent(); end
        else
            if (item.opts.onFail) then item.opts.onFail(); end
        end
        q.sending = false;
        if (#q.items > 0) then
            C_Timer.NewTimer(SEND_QUEUE_GAP, function() drainQueue(key); end);
        end
    end

    q.timeoutHandle = C_Timer.NewTimer(SEND_QUEUE_TIMEOUT, function()
        FL.Sync.Debug.Warn("COMM", "send queue timeout type=%s prefix=%s dist=%s target=%s",
            item.name, item.prefix, item.dist, tostring(item.target));
        resolve(false);
    end);

    if (item.opts.onQueued) then item.opts.onQueued(item.prefix); end
    sendOne(item.msgType, item.encoded, item.dist, item.target, item.prefix, item.prio, item.name, resolve);
end

local function enqueueSend(prefix, dist, target, prio, msgType, encoded, name, opts)
    local key = queueKey(prefix, dist, target);
    local q = sendQueues[key];
    if (not q) then q = { items = {}, sending = false }; sendQueues[key] = q; end
    table.insert(q.items, { prefix = prefix, dist = dist, target = target, prio = prio, msgType = msgType, encoded = encoded, name = name, opts = opts });
    drainQueue(key);
end

--- Sends an already-Codec-encoded message. `opts` = { prio = "BULK"|
--- "NORMAL"|"ALERT" (default NORMAL), lane = "main" (default) | "sync",
--- prefix = explicit PREFIX_SYNC member (overrides `lane`'s auto-rotation -
--- see Phase 6's per-prefix concurrency note below), onQueued = fn(prefix),
--- onSent = fn(), onFail = fn() }. The actual AceComm dispatch is queued per
--- (prefix, distribution, target) - see this file's header comment ("SECOND
--- TEMPORARY WORKAROUND") - so `onQueued` now fires once this specific send
--- reaches the front of ITS target's queue, not necessarily synchronously
--- within this call; it is still guaranteed to fire strictly before
--- `onSent`/`onFail` for the same send. `onSent` fires once every chunk of
--- the message is CONFIRMED sent (the backpressure signal spec 9.2
--- describes); `onFail` fires instead if any chunk came back unsent, OR if
--- nothing was heard back at all within SEND_QUEUE_TIMEOUT (the original
--- silent-loss failure mode this queue was added to guard against). Phase
--- 5's Sync/Session.lua queues its next outgoing batch off of onSent.
--- Returns the prefix this send will use.
---
--- Phase 6: `opts.prefix` lets a caller pick a SPECIFIC sync prefix instead
--- of `prefixForLane`'s shared rotation, so Sync/Session.lua can keep up to
--- #PREFIX_SYNC batches in flight AT ONCE for one session (spec 9.2: "at
--- most one batch in flight per prefix") - each prefix is its own
--- (prefix,distribution,target) queue key, so this is safe and doesn't
--- reintroduce the Phase 5 multipart-spool collision (that collision is
--- keyed by prefix too; different prefixes never share a spool slot).
---
--- `dist == "GUILD"` (with no explicit `target`) is currently rewritten
--- into one WHISPER per online guild member - see this file's header
--- comment ("TEMPORARY WORKAROUND") for why. Each recipient gets its own
--- queue key, so the fan-out itself is still fully parallel.
function Transport.Send(msgType, encoded, dist, target, opts)
    opts = opts or {};
    local prefix = opts.prefix or prefixForLane(opts.lane);
    local prio = opts.prio or "NORMAL";
    local name = msgName(msgType);

    if (dist == "GUILD" and not target) then
        local recipients = guildMemberNames();
        FL.Sync.Debug.Log("COMM", 1, "guildfanout type=%s recipients=%d", name, #recipients);
        for _, recipient in ipairs(recipients) do
            enqueueSend(prefix, "WHISPER", recipient, prio, msgType, encoded, name, opts);
        end
        return prefix;
    end

    enqueueSend(prefix, dist, target, prio, msgType, encoded, name, opts);
    return prefix;
end

--- Registers `fn(body, senderName, distribution, bytes)` for `msgType`.
--- `body` is the full positional array Codec.DecodeMessage returned -
--- body[1]/body[2] are PROTO_VERSION/msgType (already validated/matched by
--- the time the handler is called); the handler reads its own fields
--- starting at body[3], per spec section 6's per-type body layout. `bytes`
--- (Phase 6 addition) is the encoded wire size of this one message - every
--- existing handler ignores the extra argument harmlessly; Sync/Session.lua
--- reads it to track real received bytes per session for its throughput
--- "[PERF] rate" line, instead of guessing from a row-count average.
function Transport.Register(msgType, fn)
    handlers[msgType] = fn;
end

local function onCommReceived(prefix, encoded, distribution, senderName)
    if (Util.iEquals(Util.stripRealm(senderName or ""), Util.stripRealm(Util.UnitName("player")))) then
        return; -- our own broadcast looping back on GUILD/RAID distribution
    end

    local body, failStep = Codec.DecodeMessage(encoded);
    if (not body) then
        FL.Sync.Debug.Warn("CODEC", "decode fail from=%q step=%s proto=%d", senderName, failStep, Constants.PROTO_VERSION);
        FL.Sync.Debug.Count("codec.decodeFail", 1);
        return;
    end

    local msgType = body[2];
    local name = msgName(msgType);
    FL.Sync.Debug.Log("COMM", 2, "recv type=%s from=%q dist=%s bytes=%d", name, senderName, distribution, #encoded);
    FL.Sync.Debug.Count("comm.recv." .. name .. ".msgs", 1);
    FL.Sync.Debug.Count("comm.recv." .. name .. ".bytes", #encoded);

    local handler = handlers[msgType];
    if (handler) then
        handler(body, senderName, distribution, #encoded);
    end
end

--- Phase 6 instrumentation (spec's own "[COMM] ctl queue ..." sample line):
--- counts THIS ADDON's own outstanding sends by priority, and how many sync
--- prefixes currently have a send in flight. Deviation: ChatThrottleLib's
--- own internal queues aren't part of its public API and vary by bundled
--- version, so this reports Net/Transport.lua's own per-target send queue
--- (sendQueues above) instead - the more directly relevant number for "is
--- our own backpressure keeping up," and the thing Sync/Session.lua's
--- multi-prefix concurrency (Transport.Send's `opts.prefix`) actually feeds.
function Transport.QueueSample()
    local counts = { BULK = 0, NORMAL = 0, ALERT = 0 };
    local busyPrefixes = {};
    for key, q in pairs(sendQueues) do
        for _, item in ipairs(q.items) do
            counts[item.prio] = (counts[item.prio] or 0) + 1;
        end
        if (q.sending) then
            local prefix = key:match("^(.-)\t");
            busyPrefixes[prefix] = true;
        end
    end
    return counts, Util.tcount(busyPrefixes);
end

function Transport.Init()
    AceComm = LibStub("AceComm-3.0");
    AceComm:RegisterComm(Constants.PREFIX_MAIN, onCommReceived);
    for _, prefix in ipairs(Constants.PREFIX_SYNC) do
        AceComm:RegisterComm(prefix, onCommReceived);
    end
end
