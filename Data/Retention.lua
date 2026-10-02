--[[
Retention cutoff and pruning (spec section 10). Every client computes the
same cutoff from GetServerTime(), so pruning never creates a digest
mismatch and an old client can never re-introduce a pruned row.

Safety switch (plan Phase 3 build item 2): PRUNE_REAL stays false until
Phase 8. An expired, unpinned REAL row is left on disk but excluded from the
digest and never sent, exactly as if it had been pruned (Data/Digest.lua's
classifyRow already does the excluding) - Prune() below only counts it.
Expired TEST rows are always actually removed, regardless of PRUNE_REAL, so
pruning can be exercised and verified before Phase 8 turns real pruning on.
]]

local FL = ForeverLoot;
local Retention = FL.Sync.Retention;
local Util = FL.Util;

-- days_from_civil (Howard Hinnant's well-known constant-time algorithm):
-- days since 1970-01-01 for a UTC (y, m, d) triple, m in 1..12. Needed
-- because Lua's time() interprets its table argument as LOCAL wall-clock,
-- so it can't be used to turn a UTC calendar date back into an epoch
-- (date("!*t", t) is the only piece of UTC conversion Lua gives us, and it
-- only goes epoch -> UTC fields, not the reverse).
local function daysFromCivil(y, m, d)
    y = y - ((m <= 2) and 1 or 0);
    local era = math.floor((y >= 0 and y or y - 399) / 400);
    local yoe = y - era * 400;                                                    -- [0, 399]
    local doy = math.floor((153 * (m + ((m > 2) and -3 or 9)) + 2) / 5) + d - 1;   -- [0, 365]
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy;     -- [0, 146096]
    return era * 146097 + doe - 719468;
end

local lastCutoff;

--- 00:00 UTC on the first day of the month that is RETENTION_MONTHS months
--- before the current (UTC) month (spec 10.1).
function Retention.Cutoff()
    local utc = date("!*t", GetServerTime());
    local y, m = utc.year, utc.month - FL.Sync.Constants.RETENTION_MONTHS;
    while (m < 1) do m = m + 12; y = y - 1; end
    return daysFromCivil(y, m, 1) * 86400;
end

function Retention.IsExpired(rowTime)
    return rowTime < Retention.Cutoff();
end

--- 00:00 UTC epoch seconds for the first day of `monthKey` (spec 5.3's
--- year*12+(month-1)) - the reverse of Digest's own monthKeyOf. Used by
--- Sync/Session.lua to sort a mismatched bucket list "newest first" (spec
--- 7.3 step 4) across both window day buckets AND archive month buckets on
--- one shared timeline.
function Retention.MonthStart(monthKey)
    local y, m = math.floor(monthKey / 12), (monthKey % 12) + 1;
    return daysFromCivil(y, m, 1) * 86400;
end

--- At award time only (spec 10.5: "the awarding client"), checked by
--- Sync/Live.lua's Live.Award right after its LIVE_ROW broadcast - the pin
--- itself is data, so every other client just receives it like any other
--- pin, never re-evaluating KEY_ITEMS for themselves.
function Retention.AutoPin(row)
    if (not FL.Sync.Constants.KEY_ITEMS[row.itemID]) then return false; end
    FL.Sync.Debug.Log("PRUNE", 1, "autopin id=%s itemID=%d", row.id, row.itemID);
    return true;
end

--- Runs once at login (and whenever KEY_ITEMS_VERSION is bumped): pins every
--- in-window row that matches the current KEY_ITEMS set and isn't already
--- pinned, WITHOUT broadcasting (spec 10.5 - "each client pins its matching
--- in-window rows once at login... and sync spreads those pins"; broadcasting
--- here too would mean every online member re-announcing the same pins).
local function applyKeyItemsVersion()
    local db = FL.DB.lootCouncil;
    local storedVersion = db.keyItemsVersion or 0;
    local currentVersion = FL.Sync.Constants.KEY_ITEMS_VERSION;
    if (storedVersion >= currentVersion) then return; end

    local cutoff = Retention.Cutoff();
    local me = Util.stripRealm(Util.UnitName("player"));
    local pinned = 0;
    for _, row in ipairs(FL.LootCouncil.History) do
        if (row.awardedAt >= cutoff and FL.Sync.Constants.KEY_ITEMS[row.itemID] and not db.pins[row.id]) then
            local entry = { kind = "P", id = row.id, rowTime = row.awardedAt, at = GetServerTime(), by = me };
            if (FL.Sync.Store.Apply(entry, "local")) then
                pinned = pinned + 1;
            end
        end
    end

    db.keyItemsVersion = currentVersion;
    FL.Sync.Debug.Log("PRUNE", 1, "keyitems version %d->%d pinned=%d", storedVersion, currentVersion, pinned);
end

local function logCutoff()
    local cutoff = Retention.Cutoff();
    local utc = date("!*t", cutoff);
    local monthKey = utc.year * 12 + (utc.month - 1);
    FL.Sync.Debug.Log("PRUNE", 1, "cutoff=%s monthKey=%d retention=%d pruneReal=%s",
        date("!%Y-%m-%d", cutoff), monthKey, FL.Sync.Constants.RETENTION_MONTHS,
        FL.Sync.Constants.PRUNE_REAL and "yes" or "no");
end

--- Removes expired, unpinned rows in slices of 200/frame (spec 10.3), then
--- triggers a full Digest.Rebuild() - needed regardless of whether anything
--- was actually removed, since a moved cutoff reclassifies window/archive
--- membership for entries Add/Remove alone can't move between trees.
--- Candidates are scanned synchronously up front (a few ms for thousands of
--- rows, same as Digest.Rebuild() - spec 5.5); only the removals themselves
--- are sliced.
function Retention.Prune()
    local t0 = debugprofilestop();
    local db = FL.DB.lootCouncil;
    local cutoff = Retention.Cutoff();

    local toRemove = {}; -- ids actually being removed this pass (test always; real only if PRUNE_REAL)
    local removedTestTotal, removedRealTotal, expiredRealKept, keptPinned = 0, 0, 0, 0;

    for _, row in ipairs(FL.LootCouncil.History) do
        if (row.awardedAt < cutoff) then
            if (db.pins[row.id]) then
                keptPinned = keptPinned + 1;
            elseif (FL.Sync.Store.IsTestId(row.id)) then
                table.insert(toRemove, row.id);
                removedTestTotal = removedTestTotal + 1;
            elseif (FL.Sync.Constants.PRUNE_REAL) then
                table.insert(toRemove, row.id);
                removedRealTotal = removedRealTotal + 1;
            else
                expiredRealKept = expiredRealKept + 1;
            end
        end
    end

    local function finish()
        local elapsed = debugprofilestop() - t0;
        if (FL.Sync.Constants.PRUNE_REAL) then
            FL.Sync.Debug.Log("PRUNE", 1, "prune removedReal=%d removedTest=%d keptPinned=%d t=%dms",
                removedRealTotal, removedTestTotal, keptPinned, elapsed);
        else
            FL.Sync.Debug.Log("PRUNE", 1, "prune removedTest=%d expiredRealKept=%d keptPinned=%d t=%dms",
                removedTestTotal, expiredRealKept, keptPinned, elapsed);
        end
        FL.Sync.Digest.Rebuild();
    end

    if (#toRemove == 0) then
        finish();
        return;
    end

    local function removeSlice()
        local n = 0;
        while (n < 200 and #toRemove > 0) do
            local id = table.remove(toRemove);
            local removedRow = FL.LootCouncil.RemoveHistoryEntry(id);
            if (removedRow) then
                FL.Sync.Digest.Remove("R", id, removedRow.awardedAt);
            end
            n = n + 1;
        end
        if (#toRemove > 0) then
            FL.Sync.Scheduler.Enqueue(removeSlice, "prune");
        else
            finish();
            if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Refresh) then
                FL.UI.LootHistoryWindow.Refresh();
            end
        end
    end
    removeSlice();
end

--- Dry run (/fl debug prunedry): reports what Prune() would do without
--- changing anything. `wouldRemove` counts only REAL candidates (what
--- PRUNE_REAL=true would additionally remove); `test` is reported
--- separately since test rows are removed on every real Prune() run
--- regardless of PRUNE_REAL.
function Retention.PruneDry()
    local db = FL.DB.lootCouncil;
    local cutoff = Retention.Cutoff();
    local wouldRemoveReal, test, pinnedKept = 0, 0, 0;
    local oldest, newest;

    for _, row in ipairs(FL.LootCouncil.History) do
        if (row.awardedAt < cutoff) then
            if (db.pins[row.id]) then
                pinnedKept = pinnedKept + 1;
            else
                if (FL.Sync.Store.IsTestId(row.id)) then
                    test = test + 1;
                else
                    wouldRemoveReal = wouldRemoveReal + 1;
                end
                oldest = (oldest and math.min(oldest, row.awardedAt)) or row.awardedAt;
                newest = (newest and math.max(newest, row.awardedAt)) or row.awardedAt;
            end
        end
    end

    FL.Sync.Debug.Log("TEST", 1, "prunedry wouldRemove=%d oldest=%s newest=%s pinnedKept=%d test=%d",
        wouldRemoveReal, oldest and date("!%Y-%m-%d", oldest) or "-", newest and date("!%Y-%m-%d", newest) or "-",
        pinnedKept, test);
end

--- Checked at login and hourly (spec 10.3). Only an actual UTC month
--- boundary passing moves the cutoff, so the hourly tick is a no-op almost
--- every time it fires.
local function checkCutoffMoved()
    local newCutoff = Retention.Cutoff();
    if (newCutoff == lastCutoff) then return; end

    FL.Sync.Debug.Log("PRUNE", 1, "cutoff moved %s->%s rebuilding",
        date("!%Y-%m-%d", lastCutoff), date("!%Y-%m-%d", newCutoff));
    lastCutoff = newCutoff;
    Retention.Prune();
end

function Retention.Init()
    lastCutoff = Retention.Cutoff();
    logCutoff();

    FL.Sync.Digest.Rebuild();  -- spec 5.5: rebuild at login, before any Add/Remove below needs a populated tree
    applyKeyItemsVersion();
    Retention.Prune();         -- finishes with its own Digest.Rebuild() (see above)

    FL.Sync.Scheduler.Every(3600, 60, checkCutoffMoved, "retentionCutoff");
end
