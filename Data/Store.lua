--[[
The single write path for loot history: rows, tombstones and pins (spec
section 12.6's Store:Apply, adapted to this addon's existing storage).

Deviation from the spec's data model (see docs/sync-deviations.md): the spec
shows ForeverLootDB.history as a fresh { rows = {[id]=...}, tombstones = {},
pins = {} } dict-of-dicts. This addon already stores rows in
FL.DB.lootCouncil.history, an ARRAY with a separate id -> index side table
(LootCouncil.HistoryIndex) that the whole History UI's sorting/incremental-
index code depends on. Restructuring that into a dict now would mean
rewriting that UI's iteration logic too, which the implementation plan says
must stay unchanged this phase. So Store layers on top of the existing array
+ HistoryIndex for rows (via LootCouncil.AddHistoryEntry/RemoveHistoryEntry),
and owns NEW dict-by-id tables, FL.DB.lootCouncil.tombstones and .pins, for
the two kinds that have no existing storage at all.

Entry shapes passed to Store.Apply:
  { kind = "R", id, row, replacedRow? }        -- row is the full keyed history row
  { kind = "D", id, rowTime, at, by }           -- tombstone
  { kind = "P", id, rowTime, at, by }           -- pin
]]

local FL = ForeverLoot;
local Store = FL.Sync.Store;
local Util = FL.Util;

-- Fires "EntryApplied" after any apply that actually changed something, so
-- the history UI (and later phases) can react without Store knowing about
-- any particular listener. See UI/LootHistoryWindow.lua's registration.
Store.callbacks = LibStub("CallbackHandler-1.0"):New(Store);

local function itemStringFromLink(link)
    return type(link) == "string" and link:match("|Hitem:([^|]+)|h") or nil;
end
-- Exported so the "what's the item string for this link" rule stays
-- defined in exactly one place.
Store.ItemStringFromLink = itemStringFromLink;

local function isTestId(id)
    return type(id) == "string" and id:match("^zztest%-") ~= nil;
end
Store.IsTestId = isTestId;

local KIND_WORDS = { R = "row", D = "delete", P = "pin" };

local function logApply(kind, id, source, result, reason)
    FL.Sync.Debug.Log("STORE", 3, "%s %s from %s · %s%s",
        KIND_WORDS[kind] or tostring(kind), id, source, result, reason and (" (" .. reason .. ")") or "");
end

local function applyRow(entry, source)
    local db = FL.DB.lootCouncil;
    local id = entry.id;
    local row = entry.row;

    if (db.tombstones[id]) then
        logApply("R", id, source, "tombstoned");
        return false, "tombstoned";
    end
    if (FL.LootCouncil.HistoryIndex[id]) then
        logApply("R", id, source, "dup");
        return false, "dup";
    end
    if (isTestId(id) and not FL.Sync.Debug.IsTestDataMode()) then
        logApply("R", id, source, "rejected", "testdata");
        return false, "rejected";
    end
    -- Test ids are exempt from the retention-expiry reject (see
    -- docs/sync-deviations.md "Phase 3": /fl debug gen <n> old exists
    -- specifically to simulate already-expired data for testing
    -- Retention.Prune(), which would be impossible if Store.Apply rejected
    -- it on arrival like a real stale row.
    if (not isTestId(id) and FL.Sync.Retention.IsExpired(row.awardedAt) and not db.pins[id]) then
        logApply("R", id, source, "expired");
        return false, "expired";
    end

    if (row.itemString == nil) then
        row.itemString = itemStringFromLink(row.itemLink);
        if (row.itemString == nil) then
            FL.Sync.Debug.Warn("STORE", "upgrade: couldn't read the item in row %s · link %s", id, tostring(row.itemLink));
        end
    end

    FL.LootCouncil.AddHistoryEntry(row);
    FL.Sync.Digest.Add("R", id, row.awardedAt);
    -- A same-item reassignment (LootCouncil.RecordHistory) already removed
    -- the superseded row from FL.LootCouncil.History itself before calling
    -- Live.Award/Store.Apply - but never told Digest, which would otherwise
    -- keep hashing an id no client's storage has anymore, a permanent
    -- mismatch against any peer that only ever saw the final award.
    if (entry.replacedRow) then
        FL.Sync.Digest.Remove("R", entry.replacedRow.id, entry.replacedRow.awardedAt);
    end

    logApply("R", id, source, "added");
    Store.callbacks:Fire("EntryApplied", entry, source, "added");
    return true, "added";
end

local function applyTombstone(entry, source)
    local db = FL.DB.lootCouncil;
    local id = entry.id;

    if (db.tombstones[id]) then
        logApply("D", id, source, "dup");
        return false, "dup";
    end

    local removedRow;
    if (FL.LootCouncil.HistoryIndex[id]) then
        removedRow = FL.LootCouncil.RemoveHistoryEntry(id);
        FL.Sync.Digest.Remove("R", id, entry.rowTime);
    end
    local removedPin = db.pins[id] ~= nil;
    if (removedPin) then
        db.pins[id] = nil;
        FL.Sync.Digest.Remove("P", id, entry.rowTime);
    end

    db.tombstones[id] = { rowTime = entry.rowTime, deletedAt = entry.at, deletedBy = entry.by };
    FL.Sync.Digest.Add("D", id, entry.rowTime);

    FL.Sync.Debug.Log("STORE", 1, "deleted row %s · by %s%s%s", id, tostring(entry.by),
        removedRow and "" or ", row wasn't here", removedPin and ", pin removed" or "");
    logApply("D", id, source, "tombstoned");

    entry.removedRow = removedRow;
    Store.callbacks:Fire("EntryApplied", entry, source, "tombstoned");
    return true, "tombstoned";
end

local function applyPin(entry, source)
    local db = FL.DB.lootCouncil;
    local id = entry.id;

    if (db.tombstones[id] or db.pins[id]) then
        logApply("P", id, source, "dup");
        return false, "dup";
    end

    db.pins[id] = { rowTime = entry.rowTime, pinnedAt = entry.at, pinnedBy = entry.by };
    FL.Sync.Digest.Add("P", id, entry.rowTime);

    logApply("P", id, source, "added");
    Store.callbacks:Fire("EntryApplied", entry, source, "added");
    return true, "added";
end

--- The single write path for loot history. `source` is "local" | "live" |
--- "sync" | "test", for debug logging only. Returns (changed, result), where
--- result is one of the fixed outcome words: added, dup, tombstoned,
--- expired, rejected.
function Store.Apply(entry, source)
    source = source or "local";
    if (entry.kind == "D") then
        return applyTombstone(entry, source);
    elseif (entry.kind == "P") then
        return applyPin(entry, source);
    else
        return applyRow(entry, source);
    end
end

local function printField(key, value, indent)
    if (type(value) == "table") then
        print(("%s%s:"):format(indent, tostring(key)));
        for k, v in pairs(value) do
            printField(k, v, indent .. "  ");
        end
    else
        print(("%s%s = %s"):format(indent, tostring(key), tostring(value)));
    end
end

--------------------------------------------------------------------------
-- Test-data tools (/fl debug gen|purgetest|droplocal). Generated/dropped
-- here, not in Sync/Debug.lua, since they need direct access to history
-- storage - Debug.lua's HandleSlash just parses arguments and calls these.
--------------------------------------------------------------------------

local TEST_NOTES = {
    "Solid upgrade for this spec.",
    "Would use as an off-spec item.",
    "Best in slot for me right now.",
    "Minor upgrade, mostly for the stats.",
    "Needed for a specific encounter.",
};

-- Only used when this client's history has no real row yet to copy an item
-- string from (e.g. a brand-new install).
local FALLBACK_TEST_ITEM_LINKS = {
    "|cffffffff|Hitem:6948::::::::1:::::|h[Hearthstone]|h|r",
    "|cff1eff00|Hitem:2512::::::::1:::::|h[Worn Battleaxe]|h|r",
};

local function realHistoryRows()
    local rows = {};
    for _, row in ipairs(FL.LootCouncil.History) do
        if (not isTestId(row.id) and row.itemLink) then
            table.insert(rows, row);
        end
    end
    return rows;
end

local function randomGuildMemberNames(count)
    local names = FL.Sync.Permissions.GuildMemberNames();
    local picked = {};
    for _ = 1, count do
        if (#names == 0) then break; end
        table.insert(picked, names[math.random(#names)]);
    end
    return picked;
end

-- Rows generated per Scheduler frame-slice (see GenerateTestRows below).
-- Found empirically in Phase 5 testing: `/fl debug gen 500` run as one
-- synchronous loop hit WoW's "script ran too long" watchdog on this Classic
-- client, well under what the loop body's own actual cost would suggest -
-- this interpreter's execution-time budget for one protected call is
-- apparently tighter than it looks. 20/frame keeps each slice comfortably
-- under that regardless of exactly where the budget actually sits.
local GEN_ROWS_PER_SLICE = 20;

--- Creates `n` fake rows with ids zztest-<n>-<random>, 5 responses from
--- current guild members and item strings copied from real rows when any
--- exist. Rejected (and counted as 0 added) unless test-data mode is on -
--- see Data/Store.lua's applyRow testdata guard. `awardedAt` is spread
--- randomly over the last 4 months, or - when `old` is true (/fl debug gen
--- <n> old, plan Phase 3) - 5-6 months ago, i.e. past the default 4-month
--- retention cutoff, for exercising Retention.Prune().
---
--- Sliced across frames via Scheduler.Enqueue (GEN_ROWS_PER_SLICE at a
--- time), same pattern as Retention.Prune's removeSlice - see
--- GEN_ROWS_PER_SLICE's own comment for why a synchronous loop over `n`
--- isn't safe here even for n in the low hundreds. `t=` in the final log
--- line sums each slice's own profiled time, not wall-clock across frames,
--- so it still reads as "how much real work this took" despite spanning
--- several real-world frames.
function Store.GenerateTestRows(n, old)
    n = tonumber(n);
    if (not n or n <= 0) then
        print("|cff8865ffForeverLoot|r Usage: /fl debug gen <n> [old]");
        return;
    end

    local templates = realHistoryRows();
    local now = GetServerTime();
    local rangeStart, rangeEnd;
    if (old) then
        rangeStart, rangeEnd = now - (6 * 30 * 86400), now - (5 * 30 * 86400);
    else
        rangeStart, rangeEnd = now - (4 * 30 * 86400), now;
    end

    local added, i, elapsed = 0, 1, 0;

    local function genSlice()
        local sliceStart = debugprofilestop();
        local sliceEnd = math.min(i + GEN_ROWS_PER_SLICE - 1, n);

        while (i <= sliceEnd) do
            local template = (#templates > 0) and templates[math.random(#templates)] or nil;
            local itemLink = template and template.itemLink or FALLBACK_TEST_ITEM_LINKS[math.random(#FALLBACK_TEST_ITEM_LINKS)];

            local responderNames = randomGuildMemberNames(5);
            local awardedTo = responderNames[1] or Util.UnitName("player");

            local responses = {};
            for _, name in ipairs(responderNames) do
                responses[name] = {
                    response = { label = "Upgrade", color = "e6c229", kind = "text" },
                    note = TEST_NOTES[math.random(#TEST_NOTES)],
                    votes = math.random(0, 3),
                    class = FL.Sync.Permissions.ClassOf(name),
                };
            end

            local id = ("zztest-%d-%d"):format(i, math.random(100000, 999999));
            local row = {
                id = id,
                itemLink = itemLink,
                itemID = template and template.itemID or Util.itemIDFromLink(itemLink),
                itemIcon = template and template.itemIcon or nil,
                awardedTo = awardedTo,
                awardedToClass = FL.Sync.Permissions.ClassOf(awardedTo),
                awardedBy = Util.stripRealm(Util.UnitName("player")),
                awardedAt = math.random(rangeStart, rangeEnd),
                sessionId = 0,
                itemSession = 0,
                responses = responses,
            };

            local applied = Store.Apply({ kind = "R", id = id, row = row }, "test");
            if (applied) then added = added + 1; end
            i = i + 1;
        end

        elapsed = elapsed + (debugprofilestop() - sliceStart);

        if (i <= n) then
            FL.Sync.Scheduler.Enqueue(genSlice, "gen");
        else
            FL.Sync.Debug.Log("TEST", 1, "gen: added %d test rows · %s to %s, %dms", added,
                date("%Y-%m-%d", rangeStart), date("%Y-%m-%d", rangeEnd), elapsed);
            if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Refresh) then
                FL.UI.LootHistoryWindow.Refresh();
            end
        end
    end

    genSlice();
end

--- Removes every zztest- row/tombstone/pin locally, with no tombstones of
--- its own and no broadcast.
function Store.PurgeTestRows()
    local db = FL.DB.lootCouncil;
    local removed = 0;

    local ids = {};
    for id in pairs(FL.LootCouncil.HistoryIndex) do
        if (isTestId(id)) then table.insert(ids, id); end
    end
    for _, id in ipairs(ids) do
        local removedRow = FL.LootCouncil.RemoveHistoryEntry(id);
        if (removedRow) then FL.Sync.Digest.Remove("R", id, removedRow.awardedAt); end
        removed = removed + 1;
    end

    for id in pairs(db.tombstones) do
        if (isTestId(id)) then
            db.tombstones[id] = nil;
            FL.Sync.Digest.Remove("D", id, nil);
            removed = removed + 1;
        end
    end
    for id in pairs(db.pins) do
        if (isTestId(id)) then
            db.pins[id] = nil;
            FL.Sync.Digest.Remove("P", id, nil);
            removed = removed + 1;
        end
    end

    FL.Sync.Debug.Log("TEST", 1, "purgetest: removed %d test rows", removed);
    if (removed > 0 and FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Refresh) then
        FL.UI.LootHistoryWindow.Refresh();
    end
end

--- Removes EVERY history row, tombstone and pin on this client - real and
--- test alike - with no tombstones of its own and no broadcast. Not part of
--- the plan's own command list; added as a one-off so pre-Phase-2 dev/test
--- history (old id formats, missing itemStrings) can be cleared before
--- generating fresh test rows, instead of hand-editing SavedVariables.
--- Irreversible, so /fl debug wipehistory requires a literal "confirm" arg -
--- see Sync/Debug.lua's HandleSlash.
function Store.WipeHistory()
    local db = FL.DB.lootCouncil;
    local removed = 0;

    local ids = {};
    for id in pairs(FL.LootCouncil.HistoryIndex) do table.insert(ids, id); end
    for _, id in ipairs(ids) do
        local removedRow = FL.LootCouncil.RemoveHistoryEntry(id);
        if (removedRow) then FL.Sync.Digest.Remove("R", id, removedRow.awardedAt); end
        removed = removed + 1;
    end

    for id in pairs(db.tombstones) do
        db.tombstones[id] = nil;
        FL.Sync.Digest.Remove("D", id, nil);
        removed = removed + 1;
    end
    for id in pairs(db.pins) do
        db.pins[id] = nil;
        FL.Sync.Digest.Remove("P", id, nil);
        removed = removed + 1;
    end

    FL.Sync.Debug.Log("TEST", 1, "wipehistory: removed %d entries (rows, deletes and pins)", removed);
    if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Refresh) then
        FL.UI.LootHistoryWindow.Refresh();
    end
end

--- Removes the newest `n` rows locally, with no tombstones and no broadcast.
--- Test rows only, unless `real` is true. Fakes a client that missed data
--- (phase 5+) or a local mistake to clean up (manual add gone wrong).
function Store.DropLocal(n, real)
    n = tonumber(n);
    if (not n or n <= 0) then
        print("|cff8865ffForeverLoot|r Usage: /fl debug droplocal <n> [real]");
        return;
    end

    local candidates = {};
    for _, row in ipairs(FL.LootCouncil.History) do
        if (real or isTestId(row.id)) then
            table.insert(candidates, row);
        end
    end
    table.sort(candidates, function(a, b) return (a.awardedAt or 0) > (b.awardedAt or 0); end);

    local newestId, oldestId;
    local removed = 0;
    for i = 1, math.min(n, #candidates) do
        local row = candidates[i];
        FL.LootCouncil.RemoveHistoryEntry(row.id);
        FL.Sync.Digest.Remove("R", row.id, row.awardedAt);
        newestId = newestId or row.id;
        oldestId = row.id;
        removed = removed + 1;
    end

    FL.Sync.Debug.Log("TEST", 1, "droplocal: dropped %d %s rows · newest %s, oldest %s",
        removed, real and "real" or "test", newestId or "?", oldestId or "?");
    if (removed > 0 and FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Refresh) then
        FL.UI.LootHistoryWindow.Refresh();
    end
end

--------------------------------------------------------------------------
-- Migration (schema 1 -> 2). FL.DB.lootCouncil has no schema field at all
-- before this - treated as schema 1 implicitly. Must run after
-- LootCouncil.Init() (which creates FL.DB.lootCouncil and aliases
-- LootCouncil.History) - see Core/Init.lua's PLAYER_LOGIN module order.
--------------------------------------------------------------------------

function Store.Init()
    local db = FL.DB.lootCouncil;
    db.schema = db.schema or 1;
    db.tombstones = db.tombstones or {};
    db.pins = db.pins or {};

    if (db.schema < 2) then
        local t0 = debugprofilestop();
        local rows, withItemString, missingLink = 0, 0, 0;

        for _, row in ipairs(db.history) do
            rows = rows + 1;
            if (row.itemString == nil) then
                row.itemString = itemStringFromLink(row.itemLink);
            end
            if (row.itemString ~= nil) then
                withItemString = withItemString + 1;
            else
                missingLink = missingLink + 1;
                FL.Sync.Debug.Warn("STORE", "upgrade: couldn't read the item in row %s · link %s", tostring(row.id), tostring(row.itemLink));
            end
        end

        db.schema = 2;
        local elapsed = debugprofilestop() - t0;
        FL.Sync.Debug.Log("STORE", 1, "upgraded saved history to schema 2 · %d rows, %d with items, %d missing links, %dms",
            rows, withItemString, missingLink, elapsed);
    end
end
