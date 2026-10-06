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

UPDATE 2026-10-04: GUILD relay works on this server now, so GUILD sends go
out as a real GUILD message by default (see `guildDirect` below). The
fan-out described next stays as a fallback behind `/fl debug guilddirect off`.

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

Phase 6 review correction to the paragraph above: AceComm hands every chunk
to ChatThrottleLib with `queueName = prefix` (AceComm-3.0.lua's
SendCommMessage), and CTL keeps one FIFO pipe per queueName per priority -
so two same-priority messages on the same prefix can never interleave their
chunks, whatever the target. The Phase 5 corruption was most likely plain
chunk LOSS on this server, not a spool collision. The serialization stays:
it costs little, and it does still guard the one real collision case -
different priorities (e.g. an ALERT LIVE_ROW and a NORMAL control message)
on the same prefix to the same target, which use separate CTL pipes. The
same CTL fact has a second consequence: every NORMAL message on FLoot, for
every peer and every session, waits in ONE FIFO - see the known-user
fan-out below and docs/sync-deviations.md "Phase 6 review".

Phase 6 review, final word on the above: the real cause was the server
REORDERING messages sent in the same instant (measured: 9 of 30). AceComm's
multi-part reassembly can't survive that, so this file no longer uses it -
see "Order-tolerant framing" below. The per-target queue stays as pacing.
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

-- Rolling record of this client's own recently-CONFIRMED sends (success or
-- failure) - `dur` is the time from handing a message to AceComm until its
-- callback actually confirms the outcome, i.e. this client's own observed
-- send latency. Exists purely so a tester can see whether that latency is
-- consistently bad or just occasionally spiky, without combing through
-- "[COMM] sent ..." log lines by hand (see UI/SyncStatusWindow.lua's "Send
-- latency" section). Important limit: this only measures OUR OWN send
-- path - it says nothing about how long a PEER took to receive, process or
-- reply (that round-trip, which is what a slow handshake actually feels
-- like from this client's side, isn't observable from here at all).
local recentSends = {};
local RECENT_SENDS_MAX = 30;

local function recordSend(name, bytes, dur, ok, target)
    table.insert(recentSends, { type = name, bytes = bytes, dur = dur, ok = ok, target = target, at = GetTime() });
    while (#recentSends > RECENT_SENDS_MAX) do table.remove(recentSends, 1); end
end

--- Every recently-confirmed send this client has made, oldest first - see
--- `recentSends`'s own comment above for exactly what `dur` does and
--- doesn't measure.
function Transport.RecentSends()
    return recentSends;
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
--------------------------------------------------------------------------
-- Order-tolerant framing (docs/sync-deviations.md "Phase 6 review: the
-- server reorders"). Measured live with /fl debug probe: 30 single-piece
-- messages sent in the same instant all arrived, but 9 of them out of
-- order. AceComm's own multi-part reassembly assumes FIRST/NEXT/LAST arrive
-- in order: a LAST before its FIRST is dropped and the message silently
-- vanishes; a LAST before a NEXT splices the pieces in the wrong order and
-- the result fails to decompress/deserialize. Those are exactly the two
-- failure signatures seen since Phase 5. So this file never hands AceComm
-- anything longer than one piece: every message goes out as one or more
-- pieces of at most 255 bytes, each carrying its own position:
--   "~!" .. payload                        - the whole message in one piece
--   "~" .. id .. ":" .. i .. ":" .. n .. ":" .. slice  - piece i of n
-- The receiver collects pieces per (prefix, sender, id) in any order and
-- decodes once all n are present. "~" is printable, so AceComm never adds
-- its own escape byte (which would push a full 255-byte piece over the
-- limit and back into AceComm's multi-part path).
--------------------------------------------------------------------------

local PIECE_LIMIT = 255;
local PIECE_PAYLOAD = 239;     -- 255 minus the worst-case "~zzz:999:999:" header (14), with margin
local PARTIAL_TTL = 30;        -- seconds before an incomplete message is given up on
local ID_CHARS = "0123456789abcdefghijklmnopqrstuvwxyz";
local ID_SPACE = 36 * 36 * 36;
local nextMsgId = math.random(0, ID_SPACE - 1); -- random start: a /reload must not reuse ids a peer may still hold partials for

local function newMsgId()
    nextMsgId = (nextMsgId + 1) % ID_SPACE;
    local n, out = nextMsgId, "";
    repeat
        local d = n % 36;
        out = ID_CHARS:sub(d + 1, d + 1) .. out;
        n = math.floor(n / 36);
    until (n == 0);
    return out;
end

local function framePieces(encoded)
    if (#encoded <= PIECE_LIMIT - 2) then return { "~!" .. encoded }; end
    local id = newMsgId();
    local total = math.ceil(#encoded / PIECE_PAYLOAD);
    local pieces = {};
    for i = 1, total do
        pieces[i] = ("~%s:%d:%d:"):format(id, i, total) .. encoded:sub((i - 1) * PIECE_PAYLOAD + 1, i * PIECE_PAYLOAD);
    end
    return pieces;
end

-- "to Anduin" for a whisper, "to raid" / "to party" / "to guild" otherwise.
local function destination(dist, target)
    if (target) then return "to " .. tostring(target); end
    return "to " .. tostring(dist):lower();
end

local function sendOne(msgType, encoded, dist, target, prefix, prio, name, resolve, queuedAt)
    local pieces = framePieces(encoded);
    FL.Sync.Debug.Log("COMM", 2, "sending %s %s · %s in %d piece%s, %s priority, prefix %s",
        name, destination(dist, target), FL.Sync.Debug.FormatBytes(#encoded), #pieces, (#pieces == 1) and "" or "s",
        tostring(prio):lower(), prefix);
    FL.Sync.Debug.Count("comm.sent." .. name .. ".msgs", 1);
    FL.Sync.Debug.Count("comm.sent." .. name .. ".bytes", #encoded);

    local startedAt = GetTime();
    queuedAt = queuedAt or startedAt;
    local remaining, failed = #pieces, false;
    -- Each piece is a single-part AceComm message, so its callback fires
    -- once, with sent == total; the message as a whole is done when every
    -- piece's callback has fired. `didSend` is ChatThrottleLib's real
    -- per-message success flag (see this file's header comment).
    for _, piece in ipairs(pieces) do
        AceComm:SendCommMessage(prefix, piece, dist, target, prio, function(_, sent, total, didSend)
            if (didSend == false) then failed = true; end
            if (sent < total) then return; end
            remaining = remaining - 1;
            if (remaining > 0) then return; end

            local now = GetTime();
            local dur = now - startedAt;
            -- `wait` (Phase 6 review) is the FULL time since Transport.Send
            -- was called: this file's own per-target queue PLUS
            -- ChatThrottleLib's. `dur` alone only ever covered the CTL part,
            -- which hid local queueing.
            local wait = now - queuedAt;
            if (failed) then
                FL.Sync.Debug.Warn("COMM", "FAILED to send %s %s · %s, queued %s, sending took %s, prefix %s",
                    name, destination(dist, target), FL.Sync.Debug.FormatBytes(#encoded),
                    FL.Sync.Debug.FormatTime(wait - dur), FL.Sync.Debug.FormatTime(dur), prefix);
            else
                FL.Sync.Debug.Log("COMM", 2, "sent %s %s · %s, queued %s, sending took %s",
                    name, destination(dist, target), FL.Sync.Debug.FormatBytes(#encoded),
                    FL.Sync.Debug.FormatTime(wait - dur), FL.Sync.Debug.FormatTime(dur));
            end
            recordSend(name, #encoded, dur, not failed, target);
            resolve(not failed);
        end);
    end
end

local partials = {}; -- [prefix \t sender \t id] = { pieces = {}, got, total, at }
-- [prefix \t sender \t id] = GetTime() of a message already rejected as
-- oversize (plan Phase 8): its remaining pieces are ignored without logging
-- again, and the entry expires like a partial.
local oversized = {};

--- Drops partial messages nobody has added to for PARTIAL_TTL - each one is
--- a message that lost at least one piece on the way, logged so lost
--- pieces show up as a count instead of silence.
local function expirePartials(now)
    for key, at in pairs(oversized) do
        if (now - at > PARTIAL_TTL) then oversized[key] = nil; end
    end
    for key, p in pairs(partials) do
        if (now - p.at > PARTIAL_TTL) then
            partials[key] = nil;
            local prefix, sender = key:match("^(.-)\t(.-)\t");
            FL.Sync.Debug.Warn("COMM", "dropped incomplete message from %s · only %d of %d pieces arrived (prefix %s)",
                sender or "?", p.got, p.total, prefix or "?");
            FL.Sync.Debug.Count("comm.incomplete", 1);
        end
    end
end

--- Returns the full encoded message once every piece has arrived, nil while
--- still waiting, nil + "frame" for something that isn't one of our framed
--- pieces at all, or nil + "oversize" + bytes for a message over
--- MAX_MESSAGE_BYTES (plan Phase 8: dropped before decoding). The size check
--- runs on the first piece seen, from its piece count, so a hostile sender
--- can't make us buffer 64KB of pieces first; the exact length is checked
--- again once the last piece is in.
local function reassemble(prefix, text, sender)
    local now = GetTime();
    if (next(partials) or next(oversized)) then expirePartials(now); end

    if (text:sub(1, 2) == "~!") then return text:sub(3); end
    local id, idx, total, slice = text:match("^~(%w+):(%d+):(%d+):(.*)$");
    idx, total = tonumber(idx), tonumber(total);
    if (not id or not idx or not total or total < 1 or idx < 1 or idx > total) then
        return nil, "frame";
    end

    local key = prefix .. "\t" .. sender .. "\t" .. id;
    if (oversized[key]) then return nil; end
    local limit = Constants.MAX_MESSAGE_BYTES;
    if ((total - 1) * PIECE_PAYLOAD >= limit) then
        oversized[key] = now;
        partials[key] = nil;
        return nil, "oversize", total * PIECE_PAYLOAD;
    end
    local p = partials[key];
    if (not p or p.total ~= total) then
        p = { pieces = {}, got = 0, total = total };
        partials[key] = p;
    end
    p.at = now;
    if (not p.pieces[idx]) then
        p.pieces[idx] = slice;
        p.got = p.got + 1;
    end
    if (p.got < total) then return nil; end

    partials[key] = nil;
    local encoded = table.concat(p.pieces);
    if (#encoded > limit) then
        oversized[key] = now;
        return nil, "oversize", #encoded;
    end
    return encoded;
end

--------------------------------------------------------------------------
-- Per-sender rate limits (plan Phase 8 build item 3): at most
-- Constants.RATE_LIMITS[msgType] messages of that type per sender in any
-- RATE_LIMIT_WINDOW seconds; the rest are dropped before their handler runs.
-- Drops are summed per (sender, type) and logged as ONE warning a few
-- seconds after the first, so a flood costs one line, not one per message.
--------------------------------------------------------------------------

local RATE_REPORT_DELAY = 5;
local rateHistory = {}; -- [sender \t msgType] = { GetTime(), ... } of messages accepted inside the window
local rateDropped = {}; -- [sender \t msgType] = drops not yet reported

local function rateLimited(msgType, sender, name)
    local limit = Constants.RATE_LIMITS[msgType];
    if (not limit) then return false; end

    local key = sender .. "\t" .. msgType;
    local now, window = GetTime(), Constants.RATE_LIMIT_WINDOW;
    local hist = rateHistory[key];
    if (not hist) then hist = {}; rateHistory[key] = hist; end
    while (hist[1] and now - hist[1] > window) do table.remove(hist, 1); end

    if (#hist < limit) then
        table.insert(hist, now);
        return false;
    end

    FL.Sync.Debug.Count("comm.ratelimit." .. name, 1);
    if (not rateDropped[key]) then
        rateDropped[key] = 0;
        C_Timer.After(RATE_REPORT_DELAY, function()
            FL.Sync.Debug.Warn("COMM", "%s is flooding us · dropped %d %s messages", sender, rateDropped[key] or 0, name);
            rateDropped[key] = nil;
        end);
    end
    rateDropped[key] = rateDropped[key] + 1;
    return true;
end

local function pruneRateHistory()
    local now, window = GetTime(), Constants.RATE_LIMIT_WINDOW;
    for key, hist in pairs(rateHistory) do
        if (not hist[#hist] or now - hist[#hist] > window) then rateHistory[key] = nil; end
    end
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
-- Safety valve if a send's own callback never fires at all (the original
-- silent-loss failure mode). Scaled by chunk count (Phase 6 review): a
-- 9-chunk BULK batch sharing ChatThrottleLib's ~800B/s with two other
-- prefixes legitimately takes longer than 10s, and timing it out early
-- used to let a session believe a still-queued batch was finished.
local SEND_QUEUE_TIMEOUT = 10;
local SEND_QUEUE_TIMEOUT_PER_CHUNK = 3;
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
--
-- Phase 6 review: now 0. Measured: the server doesn't drop small bursts
-- (20 at once, 0 lost) - the "lost from a burst" losses were the server's
-- REORDERING breaking AceComm's multi-part reassembly, which the
-- order-tolerant framing below now handles. With ~6 control messages per
-- bucket the 0.3s gap had become the main throughput limit (a 121-bucket
-- primary spent minutes just waiting it out). The per-target queue itself
-- stays; it costs almost nothing when ChatThrottleLib has bandwidth.
local SEND_QUEUE_GAP = 0;

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
    -- That late callback isn't thrown away, though: it goes to
    -- `opts.onLate(ok, target)` so a caller that treated the timeout as
    -- "still possibly in flight" (Sync/Session.lua's drainOutgoing) can learn
    -- when it really finished.
    local resolved = false;
    local function resolve(ok, reason)
        if (resolved) then
            if (item.timedOut and reason ~= "timeout" and item.opts.onLate) then
                item.opts.onLate(ok, item.target);
            end
            return;
        end
        resolved = true;
        if (q.timeoutHandle) then q.timeoutHandle:Cancel(); q.timeoutHandle = nil; end
        if (ok) then
            if (item.opts.onSent) then item.opts.onSent(item.target); end
        else
            if (item.opts.onFail) then item.opts.onFail(reason or "fail", item.target); end
        end
        q.sending = false;
        if (#q.items > 0) then
            C_Timer.NewTimer(SEND_QUEUE_GAP, function() drainQueue(key); end);
        end
    end

    local chunks = math.max(1, math.ceil(#item.encoded / 255));
    local timeout = math.max(SEND_QUEUE_TIMEOUT, chunks * SEND_QUEUE_TIMEOUT_PER_CHUNK);
    q.timeoutHandle = C_Timer.NewTimer(timeout, function()
        FL.Sync.Debug.Warn("COMM", "gave up sending %s %s · stuck in the send queue for %ds (prefix %s)",
            item.name, destination(item.dist, item.target), timeout, item.prefix);
        item.timedOut = true;
        resolve(false, "timeout");
    end);

    if (item.opts.onQueued) then item.opts.onQueued(item.prefix); end
    sendOne(item.msgType, item.encoded, item.dist, item.target, item.prefix, item.prio, item.name, resolve, item.queuedAt);
end

local function enqueueSend(prefix, dist, target, prio, msgType, encoded, name, opts)
    local key = queueKey(prefix, dist, target);
    local q = sendQueues[key];
    if (not q) then q = { items = {}, sending = false }; sendQueues[key] = q; end
    table.insert(q.items, { prefix = prefix, dist = dist, target = target, prio = prio, msgType = msgType, encoded = encoded, name = name, opts = opts, queuedAt = GetTime() });
    drainQueue(key);
end

--------------------------------------------------------------------------
-- Known addon users (Phase 6 review, docs/sync-deviations.md "known-user
-- fan-out"): every sender whose message decoded cleanly is running this
-- addon. The GUILD->WHISPER fan-out below can then whisper only them
-- (`opts.fanout = "known"`) instead of every online guild member - each
-- extra recipient is one more message in ChatThrottleLib's single FIFO pipe
-- for this prefix, ahead of everything else queued behind it.
--------------------------------------------------------------------------

local KNOWN_USER_TTL = 30 * 86400; -- forget a name not heard from in 30 days

local function knownUsers()
    FL.DB.syncKnownUsers = FL.DB.syncKnownUsers or {};
    return FL.DB.syncKnownUsers;
end

local function noteKnownUser(senderName)
    knownUsers()[Util.stripRealm(senderName)] = GetServerTime();
end

function Transport.KnownUserCount()
    return Util.tcount(knownUsers());
end

-- GUILD requests go out as one real GUILD message: the server relays GUILD
-- addon messages now (retested 2026-10-04). `/fl debug guilddirect off`
-- falls back to the WHISPER fan-out below, in case the relay breaks again.
-- Session-only (a /reload turns it back on).
local guildDirect = true;

function Transport.SetGuildDirect(enabled)
    guildDirect = enabled and true or false;
end

function Transport.IsGuildDirect()
    return guildDirect;
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
--- Phase 6 review additions: `onSent(target)` / `onFail(reason, target)`
--- now receive the recipient (needed to retry one recipient of a GUILD
--- fan-out), and `reason` is "fail" (a chunk came back unsent) or
--- "timeout" (no callback within the size-scaled timeout - the message
--- may well still be sitting in ChatThrottleLib's queue). If the real
--- callback arrives after a timeout, `onLate(ok, target)` fires.
--- `fanout = "all"` (default) | "known" picks GUILD fan-out recipients (see
--- the known-users section above). `noQueue = true` bypasses this file's
--- per-target queue (debug probe only).
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

    -- Debug probe only (Sync/Probe.lua): skip this file's own per-target
    -- queue and 0.3s pacing so the probe measures AceComm/CTL + the server,
    -- not our own throttling.
    if (opts.noQueue) then
        sendOne(msgType, encoded, dist, target, prefix, prio, name, function(ok)
            if (ok and opts.onSent) then opts.onSent(target); end
            if (not ok and opts.onFail) then opts.onFail("fail", target); end
        end);
        return prefix;
    end

    if (dist == "GUILD" and not target and guildDirect) then
        FL.Sync.Debug.Log("COMM", 2, "sending %s on the real guild channel · guilddirect test mode", name);
        enqueueSend(prefix, "GUILD", nil, prio, msgType, encoded, name, opts);
        return prefix;
    end

    if (dist == "GUILD" and not target) then
        local recipients = guildMemberNames();
        local fanout = opts.fanout or "all";
        if (fanout == "known") then
            local known, filtered = knownUsers(), {};
            for _, r in ipairs(recipients) do
                if (known[r]) then table.insert(filtered, r); end
            end
            recipients = filtered;
        end
        FL.Sync.Debug.Log("COMM", 1, "sending %s to the guild as %d whispers · %s", name, #recipients,
            (fanout == "known") and "known addon users only" or "every online member");

        -- One "[COMM] fanout done" line once every recipient's send has
        -- resolved: with ChatThrottleLib holding a single FIFO per prefix,
        -- the LAST recipient can wait many seconds behind the others, and
        -- that wait was invisible before (the caller's own "out" line is
        -- logged at enqueue time).
        local pending, okCount, startedAt = #recipients, 0, GetTime();
        local function oneDone(ok)
            pending = pending - 1;
            if (ok) then okCount = okCount + 1; end
            if (pending == 0) then
                FL.Sync.Debug.Log("COMM", 2, "finished %s guild whispers · %d of %d sent, last one after %s", name, okCount,
                    #recipients, FL.Sync.Debug.FormatTime(GetTime() - startedAt));
            end
        end
        for _, recipient in ipairs(recipients) do
            enqueueSend(prefix, "WHISPER", recipient, prio, msgType, encoded, name, {
                onQueued = opts.onQueued,
                onSent = function(t) oneDone(true); if (opts.onSent) then opts.onSent(t); end end,
                onFail = function(reason, t) oneDone(false); if (opts.onFail) then opts.onFail(reason, t); end end,
            });
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

local function onCommReceived(prefix, text, distribution, senderName)
    if (Util.iEquals(Util.stripRealm(senderName or ""), Util.stripRealm(Util.UnitName("player")))) then
        return; -- our own broadcast looping back on GUILD/RAID distribution
    end

    -- /fl debug rawsend's plain "diag" payload (not Codec-encoded) - log
    -- its arrival instead of reporting a decode failure, so a raw GUILD/
    -- PARTY/CHANNEL delivery test can be read off the receiving client.
    -- /fl debug rawbytes sends "diag<n>:<test string>" - log which test
    -- strings survived, with every non-printable byte (and "|") shown as
    -- <NN> hex so a mangled byte is visible too.
    if (text:sub(1, 4) == "diag") then
        local shown = text:sub(5):gsub("[^\32-\126]", function(c) return ("<%02X>"):format(c:byte()); end):gsub("|", "<7C>");
        FL.Sync.Debug.Log("COMM", 1, "rawsend: got test message from %s · via %s, prefix %s, text %s",
            senderName, tostring(distribution):lower(), prefix, shown);
        return;
    end

    local encoded, frameErr, frameBytes = reassemble(prefix, text, Util.stripRealm(senderName or "?"));
    if (not encoded) then
        if (frameErr == "oversize") then
            -- The type is inside the compressed payload, unknown until
            -- decoded - which is exactly what this check avoids - so the
            -- line names the prefix instead of the plan's sample "type=".
            FL.Sync.Debug.Warn("COMM", "dropped oversized message from %s · %s, limit %s (prefix %s)", senderName,
                FL.Sync.Debug.FormatBytes(frameBytes or 0), FL.Sync.Debug.FormatBytes(Constants.MAX_MESSAGE_BYTES), prefix);
            FL.Sync.Debug.Count("comm.oversize", 1);
        elseif (frameErr) then
            FL.Sync.Debug.Warn("CODEC", "couldn't decode message from %s · bad framing (our protocol %d)", senderName, Constants.PROTO_VERSION);
            FL.Sync.Debug.Count("codec.decodeFail", 1);
        end
        return; -- not complete yet, or not one of our framed pieces
    end

    local body, failStep, foreignBody = Codec.DecodeMessage(encoded);
    if (not body) then
        if (failStep == "version") then
            -- Another PROTO_VERSION: ignored for sync (spec section 13),
            -- but a HELLO/HELLO_ACK still tells us the peer's addon version
            -- for the update hint. Not a WARN: in a guild mid-update this
            -- is expected traffic, not a fault.
            FL.Sync.Debug.Log("COMM", 2, "ignored message from %s · protocol %s, ours is %d", senderName,
                tostring(foreignBody and foreignBody[1]), Constants.PROTO_VERSION);
            FL.Sync.Debug.Count("comm.protoMismatch", 1);
            if (foreignBody) then FL.Sync.Peers.NoteForeignProto(foreignBody, senderName); end
            return;
        end
        FL.Sync.Debug.Warn("CODEC", "couldn't decode message from %s · failed at %s step (our protocol %d)",
            senderName, tostring(failStep), Constants.PROTO_VERSION);
        FL.Sync.Debug.Count("codec.decodeFail", 1);
        return;
    end

    local msgType = body[2];
    local name = msgName(msgType);
    if (rateLimited(msgType, Util.stripRealm(senderName or "?"), name)) then return; end
    noteKnownUser(senderName);
    FL.Sync.Debug.Log("COMM", 2, "got %s from %s · via %s, %s", name, senderName, tostring(distribution):lower(),
        FL.Sync.Debug.FormatBytes(#encoded));
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
    local now, known = GetServerTime(), knownUsers();
    for name, heardAt in pairs(known) do
        if (now - heardAt > KNOWN_USER_TTL) then known[name] = nil; end
    end
    AceComm:RegisterComm(Constants.PREFIX_MAIN, onCommReceived);
    for _, prefix in ipairs(Constants.PREFIX_SYNC) do
        AceComm:RegisterComm(prefix, onCommReceived);
    end
    FL.Sync.Scheduler.Every(300, 30, pruneRateHistory, "rateLimitPrune");
end
