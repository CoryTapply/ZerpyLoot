--[[
Per-guild loot history. ForeverLootDB is account-wide, so without this every
character on an account shared one history: a raider whose alt synced
another guild's history brought it back to their main's guild on the next
login, and sync spread it from there.

Each guild now has its own bucket of { history, tombstones, pins }. Only the
current character's guild bucket is active, and the active bucket stays in
FL.DB.lootCouncil.history/tombstones/pins, exactly where Store, Digest,
Retention, HistoryDomain, Live and the History UI already read it - none of
them know buckets exist. Every other guild's bucket is parked in
FL.DB.historyBuckets[guildKey] and never synced. FL.DB.lootCouncil.historyGuild
names the guild that owns the active bucket.

Keys: "<guild name>-<realm>" lowercased (Buckets.KeyForGuild). Two special
keys are never a real guild:
  - "_legacy": history saved before buckets existed. The first real guild a
    character on this account logs into claims it (one chat line says so).
  - "_none":   a guildless character's own bucket. Guild sync is closed
    without a guild anyway (Sync/Gate.lua's noguild reason).

Until a bucket is selected for this login (GetGuildInfo can answer nil for a
while after PLAYER_LOGIN), Buckets.IsReady() is false and Sync/Gate.lua keeps
history sync and guild award updates closed, so nothing sends or merges into
the wrong guild's history.

Awards from a loot council session led by another guild's raid leader go to
that guild's parked bucket (Buckets.ForeignKeyForSession +
Buckets.ApplyRowToBucket, called from LootCouncil.RecordHistory): the raider
keeps their own record of the run, and their own guild never sees it.
]]

local FL = ForeverLoot;
local Buckets = FL.Sync.Buckets;
local Util = FL.Util;

local LEGACY = "_legacy";
local NONE = "_none";
local OTHER = "_other"; -- another guild we couldn't name (leader too far away for GetGuildInfo)
Buckets.LEGACY, Buckets.NONE, Buckets.OTHER = LEGACY, NONE, OTHER;

local initialized = false; -- Buckets.Init has run (historyGuild is set)
local ready = false;    -- a bucket has been selected for this login
local initDone = false; -- Retention.Init has run (it builds the digest itself at login)

local function isGuildKey(key)
    return key ~= nil and key ~= LEGACY and key ~= NONE and key ~= OTHER;
end
Buckets.IsGuildKey = isGuildKey;

local function realmOrMine(realm)
    if (realm and realm ~= "") then return realm; end
    return (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName() or ""):gsub("%s+", "");
end

--- The bucket key for a guild, from GetGuildInfo's name and realm returns
--- (realm is nil for a guild on the player's own realm).
function Buckets.KeyForGuild(guildName, guildRealm)
    if (not guildName or guildName == "") then return nil; end
    return (guildName .. "-" .. realmOrMine(guildRealm)):lower();
end

--- This character's bucket key: its guild's key, NONE when not in a guild,
--- or nil while the guild name hasn't loaded yet.
function Buckets.MyKey()
    if (not IsInGuild()) then return NONE; end
    local guildName, _, _, guildRealm = GetGuildInfo("player");
    return Buckets.KeyForGuild(guildName, guildRealm);
end

function Buckets.ActiveKey()
    return FL.DB.lootCouncil.historyGuild;
end

function Buckets.IsReady()
    return ready;
end

local function hasData(history, tombstones, pins)
    return #history > 0 or next(tombstones) ~= nil or next(pins) ~= nil;
end

local function parked()
    FL.DB.historyBuckets = FL.DB.historyBuckets or {};
    return FL.DB.historyBuckets;
end

local function bucketFor(key)
    local all = parked();
    local bucket = all[key];
    if (not bucket) then
        bucket = { history = {}, tombstones = {}, pins = {} };
        all[key] = bucket;
    end
    return bucket;
end

local function announceAdopted(key, rows)
    if (rows == 0) then return; end
    print(("|cff8865ffForeverLoot|r Your existing loot history (%d rows) now belongs to %s. Characters in other guilds on this account keep separate history from now on."):format(
        rows, GetGuildInfo("player") or key));
end

--- Makes `key`'s bucket the active one, parking the current one. Rebuilds
--- the history index, digest and History window for the new bucket.
function Buckets.Select(key)
    local db = FL.DB.lootCouncil;
    local current = db.historyGuild;
    if (key == current) then
        ready = true;
        return;
    end

    -- History saved before buckets existed is active and unclaimed: the
    -- first real guild just takes it over in place, no swap. Anything
    -- already parked for that guild (awards from its raids seen on another
    -- character) is folded in.
    if (current == LEGACY and isGuildKey(key)) then
        local extra = parked()[key];
        if (extra) then
            for _, row in ipairs(extra.history) do
                if (not FL.LootCouncil.HistoryIndex[row.id]) then FL.LootCouncil.AddHistoryEntry(row); end
            end
            for id, t in pairs(extra.tombstones) do db.tombstones[id] = db.tombstones[id] or t; end
            for id, p in pairs(extra.pins) do db.pins[id] = db.pins[id] or p; end
            parked()[key] = nil;
        end
        db.historyGuild = key;
        db.historyGuildLabel = GetGuildInfo("player") or (extra and extra.label);
        ready = true;
        FL.Sync.Debug.Log("STORE", 1, "history bucket: %s claimed the saved history · %d rows", key, #db.history);
        announceAdopted(key, #db.history);
        if (extra and initDone) then
            FL.Sync.Retention.Prune(); -- finishes with Digest.Rebuild()
            if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Refresh) then
                FL.UI.LootHistoryWindow.Refresh();
            end
        end
        return;
    end

    local all = parked();
    if (current and hasData(db.history, db.tombstones, db.pins)) then
        all[current] = { history = db.history, tombstones = db.tombstones, pins = db.pins, label = db.historyGuildLabel };
    end

    local nextBucket, adopted = all[key], false;
    if (not nextBucket and isGuildKey(key) and all[LEGACY]) then
        nextBucket, adopted = all[LEGACY], true;
        all[LEGACY] = nil;
    end
    all[key] = nil;
    nextBucket = nextBucket or {};

    db.history = nextBucket.history or {};
    db.tombstones = nextBucket.tombstones or {};
    db.pins = nextBucket.pins or {};
    db.historyGuild = key;
    db.historyGuildLabel = (isGuildKey(key) and GetGuildInfo("player")) or nextBucket.label;
    FL.LootCouncil.History = db.history;
    FL.LootCouncil.RebuildHistoryIndex();
    ready = true;

    FL.Sync.Debug.Log("STORE", 1, "history bucket: switched %s -> %s · %d rows", tostring(current), key, #db.history);
    if (adopted) then announceAdopted(key, #db.history); end

    -- At login Retention.Init builds the digest right after this; later
    -- (guild changed mid-session) prune + rebuild it for the new bucket.
    if (initDone) then
        FL.Sync.Retention.Prune(); -- finishes with Digest.Rebuild()
        if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.ResetView) then
            FL.UI.LootHistoryWindow.ResetView(); -- back to the new active guild, and repaint
        end
    end
end

--- Selects this character's bucket if its guild is known yet. Called at
--- login and from Sync/Gate.lua's guild events.
function Buckets.Resolve()
    if (not initialized) then return; end
    local key = Buckets.MyKey();
    if (key) then Buckets.Select(key); end
end

--- The bucket key an award in `Session` belongs to when that's NOT the
--- active bucket (the session leader is in another guild), else nil. The
--- answer is cached on the session once it's known for sure.
function Buckets.ForeignKeyForSession(Session)
    local active = FL.DB.lootCouncil.historyGuild;
    if (not isGuildKey(active) or Session.initiatorIsMe) then return nil; end

    if (Session.historyGuildKey) then
        return (Session.historyGuildKey ~= active) and Session.historyGuildKey or nil;
    end

    local leader = Util.stripRealm(Session.initiatorFqn or "");
    if (leader == "" or leader == "?") then return nil; end

    -- Our own guild roster covers our guildmates at any distance.
    if (FL.Sync.Permissions.RankOf(leader) ~= nil) then
        Session.historyGuildKey = active;
        return nil;
    end

    local unit = Util.unitTokenForName(leader);
    local guildName, _, _, guildRealm = nil, nil, nil, nil;
    if (unit) then guildName, _, _, guildRealm = GetGuildInfo(unit); end
    local key = Buckets.KeyForGuild(guildName, guildRealm);
    if (key) then
        Session.historyGuildKey = key;
        Session.historyGuildLabel = guildName;
        return (key ~= active) and key or nil;
    end

    -- Not in our roster and too far away to name their guild. Only trust
    -- that once the roster has actually loaded; before then, keep the old
    -- behaviour (record into the active bucket).
    if (FL.Sync.Permissions.HasRoster()) then
        Session.historyGuildKey = OTHER;
        return OTHER;
    end
    return nil;
end

--- Stores `row` in the parked bucket `key` without touching the active
--- bucket, the digest or the network. A re-award replaces the row with the
--- same itemKey, like LootCouncil.RecordHistory does for the active bucket.
function Buckets.ApplyRowToBucket(key, row, label)
    local bucket = bucketFor(key);
    bucket.label = bucket.label or label;
    local history = bucket.history;
    for i = #history, 1, -1 do
        local existing = history[i];
        if (existing.id == row.id) then return false; end
        if (row.itemKey and existing.itemKey == row.itemKey) then
            table.remove(history, i);
        end
    end
    if (bucket.tombstones[row.id]) then return false; end
    if (row.itemString == nil) then row.itemString = FL.Sync.Store.ItemStringFromLink(row.itemLink); end
    table.insert(history, row);
    FL.Sync.Debug.Log("STORE", 1, "award %s from another guild's raid · kept in %s's history, not synced", tostring(row.itemLink or row.id), key);
    return true;
end

local SPECIAL_LABELS = { [LEGACY] = "Older history", [OTHER] = "Other guilds", [NONE] = "No guild" };

--- The name to show for bucket `key`: its guild's name when known.
function Buckets.LabelOf(key)
    if (key == FL.DB.lootCouncil.historyGuild) then
        return GetGuildInfo("player") or FL.DB.lootCouncil.historyGuildLabel or SPECIAL_LABELS[key] or key;
    end
    local bucket = parked()[key];
    return (bucket and bucket.label) or SPECIAL_LABELS[key] or key;
end

--- Every parked bucket with rows in it, as { key, label, rows }, sorted by
--- label - the History window's guild picker.
function Buckets.List()
    local out = {};
    for key, bucket in pairs(parked()) do
        if (#(bucket.history or {}) > 0) then
            table.insert(out, { key = key, label = Buckets.LabelOf(key), rows = #bucket.history });
        end
    end
    table.sort(out, function(a, b) return a.label:lower() < b.label:lower(); end);
    return out;
end

--- A parked bucket { history, tombstones, pins, label }, or nil. Read-only
--- for callers: nothing outside this file writes to parked buckets.
function Buckets.Get(key)
    return parked()[key];
end

--- Runs after Store.Init (which ensures tombstones/pins exist) and before
--- Retention.Init (which builds the digest from whatever bucket is active).
function Buckets.Init()
    local db = FL.DB.lootCouncil;
    if (db.historyGuild == nil) then db.historyGuild = LEGACY; end
    parked();
    initialized = true;
    Buckets.Resolve();
    -- Gate.Init ran before this, while no bucket was selected yet.
    FL.Sync.Gate.RefreshGuild();
end

--- Called once Retention.Init has built the digest, so later bucket swaps
--- rebuild it themselves.
function Buckets.MarkInitDone()
    initDone = true;
end
