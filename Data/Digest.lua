--[[
Hash-tree digests (spec section 5): one 32-bit root per tree tells two
clients whether they agree, and the month/day levels narrow a mismatch down
without transferring full ids. Two trees: window (rowTime >= cutoff, day
granularity) and archive (rowTime < cutoff but kept - pinned rows/pins and
every tombstone - month granularity only, per spec 5.4).

Not persisted (spec 5.5): entirely rebuilt from FL.DB.lootCouncil at login
and whenever the cutoff moves, so they can never drift out of sync with the
actual data. Data/Store.lua calls Add/Remove on every apply (replacing the
Phase 1 stubs); Data/Retention.lua's Prune() calls Remove per pruned row and
triggers a final Rebuild() for cutoff-boundary reclassification.
]]

local FL = ForeverLoot;
local Digest = FL.Sync.Digest;
local Util = FL.Util;

local band, bxor, lshift = bit.band, bit.bxor, bit.lshift;
local TWO32 = 4294967296;

-- Spec 5.1, verbatim: h * 16777619 mod 2^32 without losing precision, split
-- as 2^24 + 403 so the multiply never exceeds a double's 53-bit mantissa.
local function fnv1a(s)
    local h = 2166136261;
    for i = 1, #s do
        h = bxor(h, s:byte(i)) % TWO32;
        h = (lshift(band(h, 0xFF), 24) % TWO32 + h * 403) % TWO32;
    end
    return h;
end

function Digest.EntryHash(kind, id)
    return fnv1a(kind .. ":" .. id);
end

local function newAgg() return { count = 0, x = 0, s = 0 }; end

local function addToAgg(agg, hash)
    agg.count = agg.count + 1;
    agg.x = bxor(agg.x, hash);
    agg.s = (agg.s + hash) % TWO32;
end

local function removeFromAgg(agg, hash)
    agg.count = agg.count - 1;
    agg.x = bxor(agg.x, hash);
    agg.s = (agg.s - hash) % TWO32;
end

--------------------------------------------------------------------------
-- Tree state
--------------------------------------------------------------------------

-- window: day granularity (spec 5.4). archive: month granularity only -
-- "its leaves are months, not days."
local window = { root = newAgg(), months = {}, days = {} };
local archive = { root = newAgg(), months = {} };

-- located[kind..":"..id] = { tree, hash, dayKey, monthKey } - this client's
-- own bookkeeping for Remove() and for the "pin promotes its row from
-- excluded to archived" case below. hashIndex[dayKey][hash] = key and
-- archiveHashIndex[monthKey][hash] = key are the spec 5.6 "hash -> entry"
-- map, one per bucket granularity (window buckets are days; archive buckets
-- are months, per spec 5.4 - "its leaves are months, not days"). Phase 5's
-- Sync/Session.lua reads both through Digest.EntriesInBucket/Bucket/
-- HasCollision below to run the HASHES/WANT exchange.
local located = {};
local hashIndex = {};
local archiveHashIndex = {};

local cutoffCache = 0;
local selfTestOK = true;

function Digest.SelfTestOK()
    return selfTestOK;
end

local function dayKeyOf(t) return math.floor(t / 86400); end

local function monthKeyOf(t)
    local u = date("!*t", t);
    return u.year * 12 + (u.month - 1);
end

-- Reverses monthKeyOf for a day bucket's own key (used by DaysInMonth below)
-- - any timestamp within the day works, so dayKey*86400 (that UTC day's
-- midnight) is as good as any other moment in it.
local function monthKeyOfDay(dKey)
    return monthKeyOf(dKey * 86400);
end

local function ensureBucket(map, key)
    local b = map[key];
    if (not b) then b = newAgg(); map[key] = b; end
    return b;
end

--- An unpinned row past the cutoff is excluded from both trees entirely
--- (spec 10.2: "Pruned"), even though - with PRUNE_REAL=false - it is still
--- sitting on disk. Tombstones and pins are always kept somewhere (window or
--- archive), per the same table.
local function classifyRow(id, rowTime)
    if (rowTime >= cutoffCache) then return "W"; end
    if (FL.DB.lootCouncil.pins[id]) then return "A"; end
    return nil;
end

local function addEntry(kind, id, rowTime, tree)
    local key = kind .. ":" .. id;
    if (located[key]) then return; end -- already tracked; Add is idempotent

    local hash = fnv1a(key);
    local dKey = dayKeyOf(rowTime);
    local mKey = monthKeyOf(rowTime);

    if (tree == "W") then
        addToAgg(window.root, hash);
        addToAgg(ensureBucket(window.months, mKey), hash);
        addToAgg(ensureBucket(window.days, dKey), hash);
        -- A second different key hashing to the same value within this day
        -- bucket overwrites the first key's slot here (spec 5.6's collision
        -- case) - left as "last write wins" rather than tracked as a list,
        -- since Digest.HasCollision below already detects the situation from
        -- the resulting index/count mismatch, and Sync/Session.lua's bucket
        -- reconciliation falls back to full-id lists for that bucket rather
        -- than needing this index to resolve the collision itself.
        local dayHashes = hashIndex[dKey];
        if (not dayHashes) then dayHashes = {}; hashIndex[dKey] = dayHashes; end
        dayHashes[hash] = key;
    else
        addToAgg(archive.root, hash);
        addToAgg(ensureBucket(archive.months, mKey), hash);
        local monthHashes = archiveHashIndex[mKey];
        if (not monthHashes) then monthHashes = {}; archiveHashIndex[mKey] = monthHashes; end
        monthHashes[hash] = key;
    end

    located[key] = { tree = tree, hash = hash, dayKey = dKey, monthKey = mKey };
end

local function removeEntry(kind, id)
    local key = kind .. ":" .. id;
    local loc = located[key];
    if (not loc) then return nil; end
    located[key] = nil;

    if (loc.tree == "W") then
        removeFromAgg(window.root, loc.hash);
        local m = window.months[loc.monthKey];
        if (m) then
            removeFromAgg(m, loc.hash);
            if (m.count <= 0) then window.months[loc.monthKey] = nil; end
        end
        local d = window.days[loc.dayKey];
        if (d) then
            removeFromAgg(d, loc.hash);
            if (d.count <= 0) then window.days[loc.dayKey] = nil; end
        end
        -- Guarded by key equality, not just presence: on a collided bucket
        -- (see addEntry's comment above), this hash slot may already belong
        -- to a DIFFERENT key that overwrote `key`'s own slot - removing that
        -- survivor's index entry here would be wrong.
        local dayHashes = hashIndex[loc.dayKey];
        if (dayHashes and dayHashes[loc.hash] == key) then
            dayHashes[loc.hash] = nil;
            if (next(dayHashes) == nil) then hashIndex[loc.dayKey] = nil; end
        end
    else
        removeFromAgg(archive.root, loc.hash);
        local m = archive.months[loc.monthKey];
        if (m) then
            removeFromAgg(m, loc.hash);
            if (m.count <= 0) then archive.months[loc.monthKey] = nil; end
        end
        local monthHashes = archiveHashIndex[loc.monthKey];
        if (monthHashes and monthHashes[loc.hash] == key) then
            monthHashes[loc.hash] = nil;
            if (next(monthHashes) == nil) then archiveHashIndex[loc.monthKey] = nil; end
        end
    end

    return loc;
end

--- Adds one stored entry's digest contribution. `rowTime` is the row's
--- awardedAt, or the tombstone/pin's own rowTime field - always the
--- deleted/pinned row's original award time, never when this client heard
--- about it (spec 5.3).
function Digest.Add(kind, id, rowTime)
    if (rowTime == nil) then return; end

    local tree;
    if (kind == "R") then
        tree = classifyRow(id, rowTime);
    else
        tree = (rowTime >= cutoffCache) and "W" or "A";
    end

    if (tree) then
        addEntry(kind, id, rowTime, tree);
    end

    -- A pin on a row that was already excluded (unpinned and past the
    -- cutoff) promotes that row from excluded to archived - it must now be
    -- kept forever alongside its pin (spec 10.2). Only matters for the
    -- archive case: a window-tree row was never excluded in the first place.
    if (kind == "P" and tree == "A") then
        local rowKey = "R:" .. id;
        if (FL.LootCouncil.HistoryIndex[id] and not located[rowKey]) then
            addEntry("R", id, rowTime, "A");
        end
    end

    FL.Sync.Debug.Log("DIGEST", 3, "add kind=%s id=%s day=%d tree=%s", kind, id, dayKeyOf(rowTime), tree or "excluded");
end

--- Removes one stored entry's digest contribution. Looks up where the entry
--- actually lives via `located` rather than re-deriving it from `rowTime`
--- (kept as a parameter only for API parity with spec 12.2) - safe to call
--- for an id this client never tracked (e.g. a pre-Rebuild() prune pass),
--- which simply no-ops.
function Digest.Remove(kind, id, rowTime)
    local loc = removeEntry(kind, id);
    if (loc) then
        FL.Sync.Debug.Log("DIGEST", 3, "remove kind=%s id=%s tree=%s", kind, id, loc.tree);
    end
end

function Digest.Root(tree)
    return (tree == "A") and archive.root or window.root;
end

function Digest.Months(tree)
    local t = (tree == "A") and archive or window;
    local out = {};
    for monthKey, agg in pairs(t.months) do
        table.insert(out, { monthKey = monthKey, count = agg.count, x = agg.x, s = agg.s });
    end
    table.sort(out, function(a, b) return a.monthKey < b.monthKey; end);
    return out;
end

--- Window-tree day buckets for one month (spec 5.4: the archive tree has no
--- day level, so this only ever reads from `window`).
function Digest.DaysInMonth(monthKey)
    local out = {};
    for dKey, agg in pairs(window.days) do
        if (monthKeyOfDay(dKey) == monthKey) then
            table.insert(out, { dayKey = dKey, count = agg.count, x = agg.x, s = agg.s });
        end
    end
    table.sort(out, function(a, b) return a.dayKey < b.dayKey; end);
    return out;
end

--- The month a window day bucket belongs to (reverse of DaysInMonth's own
--- grouping) - Sync/Session.lua uses this to know which of its own months to
--- re-diff once a peer's DAYS reply names specific day keys (spec 7.3 step 3).
function Digest.MonthOfDayKey(dayKey)
    return monthKeyOfDay(dayKey);
end

--- One bucket's own aggregate: a window day (bucketKey = dayKey) or an
--- archive month (bucketKey = monthKey, spec 5.4's "its leaves are months").
--- Zero aggregate for a bucket with nothing in it (never stored as such).
function Digest.Bucket(tree, bucketKey)
    local map = (tree == "A") and archive.months or window.days;
    local agg = map[bucketKey];
    return agg and { count = agg.count, x = agg.x, s = agg.s } or { count = 0, x = 0, s = 0 };
end

--- Every {kind, id, hash} this client holds in one bucket (spec 5.6's
--- "hash -> entry map for the day buckets involved", generalized to archive's
--- month-level buckets too). Backs the HASHES contents Sync/Session.lua sends
--- for a bucket, and resolves a peer's WANT back to concrete entries via
--- Store/Digest's own id. Order is unspecified - callers needing determinism
--- (none do yet) should sort the result themselves.
function Digest.EntriesInBucket(tree, bucketKey)
    local idx = (tree == "A") and archiveHashIndex[bucketKey] or hashIndex[bucketKey];
    local out = {};
    if (idx) then
        for hash, key in pairs(idx) do
            local colon = key:find(":", 1, true);
            table.insert(out, { kind = key:sub(1, colon - 1), id = key:sub(colon + 1), hash = hash });
        end
    end
    return out;
end

--- True when two different local entries in this bucket hash to the same
--- 32-bit value (spec 5.6): addEntry's "last write wins" index means the
--- bucket's own per-hash map then has fewer entries than its aggregate
--- count, which is exactly the signal Sync/Session.lua checks before trusting
--- a hash-based exchange for this bucket.
function Digest.HasCollision(tree, bucketKey)
    return #Digest.EntriesInBucket(tree, bucketKey) < Digest.Bucket(tree, bucketKey).count;
end

--- Full rebuild from FL.DB.lootCouncil (spec 5.5): at login, and whenever
--- the cutoff moves. Entirely replaces the in-memory trees; nothing here is
--- persisted.
function Digest.Rebuild()
    local t0 = debugprofilestop();
    window.root, window.months, window.days = newAgg(), {}, {};
    archive.root, archive.months = newAgg(), {};
    wipe(located);
    wipe(hashIndex);
    wipe(archiveHashIndex);
    cutoffCache = FL.Sync.Retention.Cutoff();

    local db = FL.DB.lootCouncil;
    local totalEntries, excludedExpired = 0, 0;

    for _, row in ipairs(FL.LootCouncil.History) do
        totalEntries = totalEntries + 1;
        local tree = classifyRow(row.id, row.awardedAt);
        if (tree) then
            addEntry("R", row.id, row.awardedAt, tree);
        else
            excludedExpired = excludedExpired + 1;
        end
    end
    for id, t in pairs(db.tombstones) do
        totalEntries = totalEntries + 1;
        local tree = (t.rowTime and t.rowTime >= cutoffCache) and "W" or "A";
        addEntry("D", id, t.rowTime or 0, tree);
    end
    for id, p in pairs(db.pins) do
        totalEntries = totalEntries + 1;
        local tree = (p.rowTime and p.rowTime >= cutoffCache) and "W" or "A";
        addEntry("P", id, p.rowTime or 0, tree);
    end

    local windowMonthCount = Util.tcount(window.months);
    local windowDayCount = Util.tcount(window.days);
    local elapsed = debugprofilestop() - t0;
    FL.Sync.Debug.Log("DIGEST", 1,
        "rebuild entries=%d W=n:%d,x:%08X,s:%08X A=n:%d,x:%08X,s:%08X months=%d days=%d excludedExpired=%d t=%dms",
        totalEntries, window.root.count, window.root.x, window.root.s,
        archive.root.count, archive.root.x, archive.root.s,
        windowMonthCount, windowDayCount, excludedExpired, elapsed);
end

local function runSelfTest()
    local a, foobar = fnv1a("a"), fnv1a("foobar");
    if (a == 0xE40C292C and foobar == 0xBF9CF968) then
        selfTestOK = true;
        FL.Sync.Debug.Log("DIGEST", 1, "selftest ok");
    else
        selfTestOK = false;
        FL.Sync.Debug.Err("DIGEST", "selftest fail got=%08X want=E40C292C", a);
    end
end

function Digest.Init()
    runSelfTest();
end
