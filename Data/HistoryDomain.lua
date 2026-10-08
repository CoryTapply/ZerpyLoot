--[[
Loot history as sync domain 1 (spec section 7.7): strategy "set", scope
GUILD, gate "sync". Summary()/Compare() are real since Phase 4. Phase 5 fills
in the set-strategy repair methods a real Sync/Session.lua calls:
Tree()/EncodeEntries()/ApplyEntries() (plan's Phase 4 build list: "The set
methods stay stubs until phase 5" - this is that phase).

Summary() returns a POSITIONAL array, not a keyed table (spec 7.7's
Domain:Summary() comment: "small positional table for HELLO") - it goes
straight onto the wire inside a HELLO/HELLO_ACK body, and spec 4.1 says
every message, including control messages, is built as a positional table
with no string keys. Compare() reads a remote peer's summary by the same
fixed positions: [1]=window count, [2]=window x, [3]=window s,
[4]=archive count, [5]=archive x, [6]=archive s, [7]=cutoff month key,
[8]=retention months.
]]

local FL = ForeverLoot;
local HistoryDomain = FL.Sync.HistoryDomain;

HistoryDomain.id       = FL.Sync.Constants.DOMAIN_HISTORY;
HistoryDomain.name     = "history";
HistoryDomain.strategy = "set";
HistoryDomain.scope    = "GUILD";
HistoryDomain.gate     = "sync";

local function cutoffMonthKey()
    local utc = date("!*t", FL.Sync.Retention.Cutoff());
    return utc.year * 12 + (utc.month - 1);
end

--- Positional {wCount, wX, wS, aCount, aX, aS, cutoffMonthKey, retention}
--- for the outgoing HELLO/HELLO_ACK body, and for comparing against a peer's
--- own summary in Compare() below.
function HistoryDomain:Summary()
    local w, a = FL.Sync.Digest.Root("W"), FL.Sync.Digest.Root("A");
    local cutoffKey = cutoffMonthKey();
    local retention = FL.Sync.Constants.RETENTION_MONTHS;

    FL.Sync.Debug.Log("DOMAIN", 2, "history summary · %d recent (hash %08X/%08X), %d archived (hash %08X/%08X), cutoff month %d, keep %d months",
        w.count, w.x, w.s, a.count, a.x, a.s, cutoffKey, retention);

    return { w.count, w.x, w.s, a.count, a.x, a.s, cutoffKey, retention };
end

--- "same" | "diverged" | "incompatible" (spec 7.7's strategy table, and
--- 10.1: a different retention value - or a different cutoff month, which
--- only ever differs at a month-boundary clock skew - "do not sync with
--- us" at all, rather than being treated as an ordinary mismatch).
function HistoryDomain:Compare(remote)
    if (type(remote) ~= "table") then return "diverged"; end

    local mine = self:Summary();
    if (remote[7] ~= mine[7] or remote[8] ~= mine[8]) then
        return "incompatible";
    end
    if (remote[1] == mine[1] and remote[2] == mine[2] and remote[3] == mine[3]
        and remote[4] == mine[4] and remote[5] == mine[5] and remote[6] == mine[6]) then
        return "same";
    end
    return "diverged";
end

--- "3398 recent, 120 archived" for log lines.
function HistoryDomain:DescribeVersion(v)
    if (type(v) ~= "table") then return "nothing"; end
    return ("%d recent, %d archived"):format(v[1] or 0, v[4] or 0);
end

--- DescribeVersion of our own history, read straight from the digest
--- (Summary() logs a line of its own on every call).
function HistoryDomain:DescribeLocal()
    local w, a = FL.Sync.Digest.Root("W"), FL.Sync.Digest.Root("A");
    return self:DescribeVersion({ w.count, nil, nil, a.count });
end

--------------------------------------------------------------------------
-- Set-strategy repair methods (spec 7.7's "set" row in its strategy table;
-- the actual HASHES/WANT/ROWS/MARKS exchange lives in Sync/Session.lua,
-- which calls these only for the domain-specific parts: what the digest API
-- is, how to turn a list of (kind,id) entries into wire batches, and how to
-- apply a received batch).
--------------------------------------------------------------------------

--- Session.lua reads buckets/hashes through the Digest module directly
--- (Root/Months/DaysInMonth/Bucket/EntriesInBucket/HasCollision) - returning
--- it here satisfies spec 12.2's "Tree() returns ... the Digest API" without
--- HistoryDomain needing its own forwarding wrappers for every method.
function HistoryDomain:Tree()
    return FL.Sync.Digest;
end

local MSG = FL.Sync.Constants.MSG;
-- Spec 9.2's own worked example ("about 4KB serialized... roughly a 40-row
-- batch") used as a row-count heuristic instead of re-serializing after each
-- row to check size: simpler, and close enough to BATCH_TARGET_BYTES for
-- this addon's row sizes (spec 4.8's ~165-300B/row estimate). See
-- docs/sync-deviations.md.
local BATCH_ROW_CHUNK = 40;

--- `originalAwardedBy` for EncodeMark's id-compaction attempt: the row may
--- still be present locally (a pin never removes its row; a tombstone
--- always does), so this recovers it from the still-live row when possible
--- and falls back to the raw id string (via EncodeMark's own nil handling)
--- when it isn't.
local function awardedByOf(id)
    local index = FL.LootCouncil.HistoryIndex[id];
    return index and FL.LootCouncil.History[index].awardedBy or nil;
end

--- Builds wire-ready ROWS/MARKS chunks for a list of `{kind, id}` entries
--- (resolved by Sync/Session.lua from a bucket's EntriesInBucket + the
--- hashes a peer's WANT named). Returns an array of
--- `{kind="ROWS", wireRows, players, types, count, playerCount, typeCount}`
--- and/or `{kind="MARKS", flat, players, count, playerCount}` chunks -
--- deliberately NOT full message bodies: Session.lua owns the token, the
--- session-wide batch number and the bucket-completion fields (see that
--- file's own header comment on why those can't be left as nil placeholders
--- in a positional array LibSerialize will walk).
function HistoryDomain:EncodeEntries(entries)
    local Codec = FL.Sync.Codec;
    local db = FL.DB.lootCouncil;

    local rows, marks = {}, {};
    for _, e in ipairs(entries) do
        if (e.kind == "R") then
            local index = FL.LootCouncil.HistoryIndex[e.id];
            if (index) then table.insert(rows, FL.LootCouncil.History[index]); end
        else
            local store = (e.kind == "D") and db.tombstones or db.pins;
            local m = store and store[e.id];
            if (m) then
                table.insert(marks, {
                    kind = e.kind, id = e.id, rowTime = m.rowTime,
                    at = (e.kind == "D") and m.deletedAt or m.pinnedAt,
                    by = (e.kind == "D") and m.deletedBy or m.pinnedBy,
                });
            end
        end
    end

    local chunks = {};

    for i = 1, #rows, BATCH_ROW_CHUNK do
        local builder = Codec.NewDictBuilder();
        local wireRows = {};
        for j = i, math.min(i + BATCH_ROW_CHUNK - 1, #rows) do
            table.insert(wireRows, Codec.EncodeRow(rows[j], builder));
        end
        table.insert(chunks, {
            kind = "ROWS", wireRows = wireRows, players = builder:Players(), types = builder:Types(),
            count = #wireRows, playerCount = builder:PlayerCount(), typeCount = builder:TypeCount(),
        });
    end

    for i = 1, #marks, BATCH_ROW_CHUNK do
        local builder = Codec.NewDictBuilder();
        local flat = {};
        for j = i, math.min(i + BATCH_ROW_CHUNK - 1, #marks) do
            local m = marks[j];
            local wireMark = Codec.EncodeMark(m, awardedByOf(m.id), builder);
            table.insert(flat, m.kind);
            table.insert(flat, wireMark[1]);
            table.insert(flat, wireMark[2]);
            table.insert(flat, wireMark[3]);
            table.insert(flat, wireMark[4]);
        end
        table.insert(chunks, {
            kind = "MARKS", flat = flat, players = builder:Players(),
            count = (#flat / 5), playerCount = builder:PlayerCount(),
        });
    end

    return chunks;
end

--- Applies one already-Codec-decoded ROWS or MARKS message body (`msgType`
--- says which) through Store.Apply, same as Sync/Live.lua's receive side,
--- with source="sync". Returns per-outcome counts for Sync/Session.lua's
--- "[SESS] batch in" line.
---
--- Runs synchronously inside the comm handler, not through
--- Scheduler.Enqueue as plan Phase 5 item 2 asked: a batch is capped at
--- BATCH_ROW_CHUNK (40) entries, which stays well inside one frame, and
--- Sync/Session.lua's batch-completion bookkeeping needs the counts right
--- away. If plan Phase 6 step 5 (gameplay check) shows "[PERF] overrun"
--- around batch arrivals, this is the place to slice. See
--- docs/sync-deviations.md "Phase 6 review".
function HistoryDomain:ApplyEntries(msgType, decoded, sender)
    local Codec = FL.Sync.Codec;
    local result = { added = 0, dup = 0, tombstoned = 0, expired = 0, rejected = 0, invalid = 0 };

    local function record(outcome)
        result[outcome] = (result[outcome] or 0) + 1;
    end

    -- Session.lua already refuses sessions with other guilds' members; this
    -- is the last stop before anything reaches our history.
    if (not FL.Sync.Permissions.IsGuildPeer(sender)) then
        local n = (msgType == MSG.ROWS) and #(decoded[7] or {}) or math.floor(#(decoded[6] or {}) / 5);
        result.rejected = n;
        FL.Sync.Debug.Log("STORE", 1, "rejected %d entries from %s · not in our guild", n, tostring(sender));
        return result;
    end

    if (msgType == MSG.ROWS) then
        local players, types, wireRows = decoded[5], decoded[6], decoded[7];
        for _, wireRow in ipairs(wireRows) do
            local row, reason, field = Codec.DecodeRow(wireRow, players, types);
            if (not row) then
                record("invalid");
                FL.Sync.Debug.Log("CODEC", 2, "rejected row %s · %s%s", tostring(Codec.WireRowIdGuess(wireRow)), tostring(reason),
                    field and (" (field " .. field .. ")") or "");
            else
                local applied, outcome = FL.Sync.Store.Apply({ kind = "R", id = row.id, row = row }, "sync");
                record(outcome);
                if (applied and not row.itemLink) then FL.Sync.ItemLinks.Resolve(row); end
            end
        end
    else -- MSG.MARKS
        -- decoded[4] is the shared session-wide batch number Sync/Session.lua
        -- stamps onto both ROWS and MARKS bodies (spec section 6's own MARKS
        -- layout has no such field) - unused here, only players/flat matter
        -- for applying entries.
        local players, flat = decoded[5], decoded[6];
        for i = 1, #flat, 5 do
            local kind, idEncoded, rowTime, at, byIdx = flat[i], flat[i + 1], flat[i + 2], flat[i + 3], flat[i + 4];
            local mark, reason = Codec.DecodeMark({ idEncoded, rowTime, at, byIdx }, players);
            if (not mark) then
                record("invalid");
            else
                local applied, outcome = FL.Sync.Store.Apply({ kind = kind, id = mark.id, rowTime = mark.rowTime, at = mark.at, by = mark.by }, "sync");
                record(outcome);
            end
        end
    end

    return result;
end

--- Registered here (not at file load - see Sync/Domains.lua's own header
--- comment) so Debug/FL.DB already exist by the time Domains.Register logs
--- the registration line.
function HistoryDomain.Init()
    FL.Sync.Domains.Register(HistoryDomain);
end
