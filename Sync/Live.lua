--[[
Entry point for the existing UI: Award/Delete/Pin all go through Store:Apply
first, then (Phase 2) broadcast on the new wire format - LIVE_ROW, LIVE_DEL,
LIVE_PIN (spec section 6) on GUILD at ALERT priority, through Net/Codec.lua +
Net/Transport.lua, wrapped in Gate.QueueLive. This replaces Phase 1's
historyDelete/historyPin broadcasts on LootCouncil's own "ForeverLootLC"
prefix - those went out on GROUP (raid/party) distribution only, so a guild
member who wasn't in the raid never received them; GUILD distribution is
exactly what spec section 7.1 calls for ("an immediate live broadcast when
something happens" to the whole guild, not just the raid).

Award: deviates from Phase 1's "Live.Award never broadcasts by itself" (see
that phase's own comments, now out of date, in LootCouncil.RecordHistory and
UI/LootHistoryWindow.lua's manual Add Entry handler - both updated below).
RecordHistory calls Live.Award on EVERY client that processes an award - the
leader optimistically (source="local") AND every other raid member via the
existing "award" council broadcast (source="live", still unchanged - it
drives Session.items state, which is a council-session concern staying
exactly as it is per the plan's Phase 7 note, not a history concern). If
Live.Award broadcast unconditionally, N raid members receiving one award
would each re-broadcast it to the guild. So it only broadcasts LIVE_ROW when
source=="local" - i.e. only from whichever single client actually originated
the row (AwardItem/DisenchantItem's leader-only path, or the manual Add
Entry dialog) - matching spec 7.1's "their client" (singular). Raid members
still get the row sourced locally via the existing award broadcast as
before; LIVE_ROW is what additionally reaches the rest of the guild. See
docs/sync-deviations.md "Phase 2: Live.Award now broadcasts".

Delete/Pin: still broadcast themselves, same as Phase 1, just on the new
wire format and channel.

Automatic pin (Phase 3, spec 10.5): Live.Award also checks
Retention.AutoPin(row) in that same source=="local" branch, right after the
LIVE_ROW broadcast - same single-originating-client reasoning applies, so
only the awarding client ever creates/broadcasts the autopin.
]]

local FL = ForeverLoot;
local Live = FL.Sync.Live;
local Util = FL.Util;
local Codec = FL.Sync.Codec;
local Transport = FL.Sync.Transport;
local Gate = FL.Sync.Gate;
local Constants = FL.Sync.Constants;
local MSG = Constants.MSG;

local function typeName(msgType)
    return (msgType == MSG.LIVE_DEL) and "LIVE_DEL" or "LIVE_PIN";
end

local function logEncode(msgType, extra, stats)
    FL.Sync.Debug.Log("CODEC", 2, "encode type=%s %sser=%s cmp=%s enc=%s t=%.1fms",
        Constants.MSG_NAMES[msgType] or tostring(msgType), extra,
        FL.Sync.Debug.FormatBytes(stats.ser), FL.Sync.Debug.FormatBytes(stats.cmp),
        FL.Sync.Debug.FormatBytes(stats.enc), stats.ms);
end

--- Encodes+sends `row` as a LIVE_ROW, queued through the live gate (spec
--- section 8: live broadcasts queue during a boss encounter, allowed
--- everywhere else). Only called for a row this client itself originated -
--- see this file's header comment.
local function broadcastLiveRow(row)
    local builder = Codec.NewDictBuilder();
    local wireRow = Codec.EncodeRow(row, builder);
    local body = { Constants.PROTO_VERSION, MSG.LIVE_ROW, builder:Players(), builder:Types(), wireRow };
    local encoded, stats = Codec.EncodeMessage(body);
    logEncode(MSG.LIVE_ROW, ("rows=1 players=%d resp=%d "):format(builder:PlayerCount(), builder:TypeCount()), stats);

    local queued = not Gate.CanLive();
    Gate.QueueLive(function()
        Transport.Send(MSG.LIVE_ROW, encoded, "GUILD", nil, { prio = "ALERT" });
    end, "liveRow");
    FL.Sync.Debug.Log("LIVE", 1, "out LIVE_ROW id=%s queued=%s", row.id, queued and "yes" or "no");
end

--- Encodes+sends `mark` (a tombstone or pin) as LIVE_DEL/LIVE_PIN.
--- `originalAwardedBy` is the deleted/pinned row's own awardedBy, if the
--- caller still has it (used only for Codec.EncodeId's id-compaction
--- attempt - see Net/Codec.lua's EncodeMark).
local function broadcastLiveMark(msgType, mark, originalAwardedBy, label)
    local builder = Codec.NewDictBuilder();
    local wireMark = Codec.EncodeMark(mark, originalAwardedBy, builder);
    local body = { Constants.PROTO_VERSION, msgType, builder:Players(), wireMark };
    local encoded, stats = Codec.EncodeMessage(body);
    logEncode(msgType, "marks=1 ", stats);

    local queued = not Gate.CanLive();
    Gate.QueueLive(function()
        Transport.Send(msgType, encoded, "GUILD", nil, { prio = "ALERT" });
    end, label);
    FL.Sync.Debug.Log("LIVE", 1, "out %s id=%s queued=%s", typeName(msgType), mark.id, queued and "yes" or "no");
end

--- Applies a locally-built history row to the store, and - only when this
--- client is the one that originated it (source=="local") - broadcasts it
--- as LIVE_ROW to the whole guild. See this file's header comment for why
--- "live"-sourced rows (received via the existing council award broadcast)
--- don't re-broadcast.
---@param row table the full keyed history row (spec section 3.1)
---@param source string "local" | "live" | "test"
---@param replacedRow table|nil a same-item row this one replaces (reassignment), for the history UI's incremental index update
function Live.Award(row, source, replacedRow)
    source = source or "local";
    local entry = { kind = "R", id = row.id, row = row, replacedRow = replacedRow };
    local applied = FL.Sync.Store.Apply(entry, source);

    if (applied and not row.itemLink) then
        FL.Sync.ItemLinks.Resolve(row);
    end
    if (applied and source == "local") then
        broadcastLiveRow(row);

        -- Automatic pin (spec 10.5): only the awarding client checks
        -- KEY_ITEMS and creates the pin - every other client just receives
        -- it like any other pin, same as broadcastLiveRow above being
        -- source=="local"-only.
        if (FL.Sync.Retention.AutoPin(row)) then
            local me = Util.stripRealm(Util.UnitName("player"));
            local pinEntry = { kind = "P", id = row.id, rowTime = row.awardedAt, at = GetServerTime(), by = me };
            if (FL.Sync.Store.Apply(pinEntry, "local")) then
                broadcastLiveMark(MSG.LIVE_PIN,
                    { id = pinEntry.id, rowTime = pinEntry.rowTime, at = pinEntry.at, by = pinEntry.by },
                    row.awardedBy, "autopin");
            end
        end
    end
    return applied;
end

local function logPermission(action, name, allowed)
    local rank = FL.Sync.Permissions.RankOf(name);
    FL.Sync.Debug.Log("PERM", 1, "%s %s name=%q rank=%s max=%d",
        action, allowed and "allowed" or "denied", name, tostring(rank), FL.Sync.Constants.OFFICER_RANK_MAX);
end

--- Deletes `id`: officer-only. Tombstones it locally via Store:Apply, then
--- broadcasts LIVE_DEL so every online guild member tombstones it too.
--- Returns false (no-op) if the row isn't known locally or the local player
--- isn't permitted.
---@param id string
function Live.Delete(id)
    local index = FL.LootCouncil.HistoryIndex[id];
    local row = index and FL.LootCouncil.History[index];
    if (not row) then return false; end

    local me = Util.stripRealm(Util.UnitName("player"));
    local allowed = FL.Sync.Permissions.CanDelete(me);
    logPermission("delete", me, allowed);
    if (not allowed) then return false; end

    local entry = { kind = "D", id = id, rowTime = row.awardedAt, at = GetServerTime(), by = me };
    local applied = FL.Sync.Store.Apply(entry, "local");
    if (applied) then
        broadcastLiveMark(MSG.LIVE_DEL, { id = entry.id, rowTime = entry.rowTime, at = entry.at, by = entry.by }, row.awardedBy, "liveDelete");
    end
    return applied;
end

--- Pins `id`: officer-only, same policy as delete (spec section 10.5).
--- Called by UI/LootHistoryWindow.lua's manual "Pin" row action (Phase 3)
--- and by Live.Award's autopin check above.
---@param id string
function Live.Pin(id)
    local index = FL.LootCouncil.HistoryIndex[id];
    local row = index and FL.LootCouncil.History[index];
    if (not row) then return false; end

    local me = Util.stripRealm(Util.UnitName("player"));
    local allowed = FL.Sync.Permissions.CanPin(me);
    logPermission("pin", me, allowed);
    if (not allowed) then return false; end

    local entry = { kind = "P", id = id, rowTime = row.awardedAt, at = GetServerTime(), by = me };
    local applied = FL.Sync.Store.Apply(entry, "local");
    if (applied) then
        broadcastLiveMark(MSG.LIVE_PIN, { id = entry.id, rowTime = entry.rowTime, at = entry.at, by = entry.by }, row.awardedBy, "livePin");
    end
    return applied;
end

--- Sends a LIVE_DEL for `id` WITHOUT the local permission check and WITHOUT
--- applying it locally (/fl debug forcedelete <id>, plan phase 2). Exists
--- only to test that receivers reject a non-officer sender - see this
--- file's applyRemoteMark sender/rank checks below.
---@param id string
function Live.ForceDelete(id)
    local index = FL.LootCouncil.HistoryIndex[id];
    local row = index and FL.LootCouncil.History[index];
    local me = Util.stripRealm(Util.UnitName("player"));

    local mark = { id = id, rowTime = row and row.awardedAt or GetServerTime(), at = GetServerTime(), by = me };
    broadcastLiveMark(MSG.LIVE_DEL, mark, row and row.awardedBy, "forcedelete");
    FL.Sync.Debug.Log("TEST", 1, "forcedelete id=%s", id);
end

--------------------------------------------------------------------------
-- Receive side
--------------------------------------------------------------------------

local function onLiveRow(body, senderName)
    local players, types, wireRow = body[3], body[4], body[5];
    local t0 = debugprofilestop();
    local row, reason, field = Codec.DecodeRow(wireRow, players, types);
    local elapsed = debugprofilestop() - t0;

    if (not row) then
        local guessId = Codec.WireRowIdGuess(wireRow);
        FL.Sync.Debug.Log("CODEC", 2, "reject id=%s reason=%s%s", guessId, reason, field and (" field=" .. field) or "");
        FL.Sync.Debug.Count("codec.rowRejects", 1);
        FL.Sync.Debug.Log("CODEC", 2, "decode type=LIVE_ROW from=%q ok=0 rejected=1 t=%.1fms", senderName, elapsed);
        -- "rejected" is one of the fixed outcome words (plan's Debug system
        -- section) - this line is what makes a dropped LIVE_ROW visible at
        -- the default debug level even with CODEC's own detail line (above)
        -- muted at level 2; without it, a rejected row looked identical to
        -- one that silently never arrived at all.
        FL.Sync.Debug.Log("LIVE", 1, "in LIVE_ROW id=%s from=%q result=rejected reason=%s", guessId, senderName, reason);
        return;
    end
    FL.Sync.Debug.Log("CODEC", 2, "decode type=LIVE_ROW from=%q ok=1 rejected=0 t=%.1fms", senderName, elapsed);

    local entry = { kind = "R", id = row.id, row = row };
    local applied, result = FL.Sync.Store.Apply(entry, "live");
    if (applied and not row.itemLink) then
        FL.Sync.ItemLinks.Resolve(row);
    end
    FL.Sync.Debug.Log("LIVE", 1, "in LIVE_ROW id=%s from=%q result=%s", row.id, senderName, result);
end

-- Never trusts the sender's own claim (mirrors LootCouncil.lua's applyAward
-- re-verifying the session initiator): the broadcast must come from the
-- very player it claims performed the action, and that player must be
-- permitted RIGHT NOW (spec section 11.2 - only this live path re-checks; a
-- later synced/relayed copy is accepted as-is, per spec section 11.3).
local function applyRemoteMark(msgType, kind, mark, senderName, checkFn)
    local name = typeName(msgType);
    if (not Util.iEquals(senderName, mark.by)) then
        FL.Sync.Debug.Log("PERM", 1, "live reject type=%s from=%q by=%q reason=senderMismatch", name, senderName, mark.by);
        -- Never reaches Store:Apply, so without this it's invisible to
        -- every counter: not a codec.rowRejects (it decoded fine) and not a
        -- store.apply.* outcome (Store:Apply is never called). "rejected"
        -- is the fixed outcome word that fits (plan's Debug system section).
        FL.Sync.Debug.Count("store.apply.rejected", 1);
        return;
    end

    local allowed = checkFn(mark.by);
    if (not allowed) then
        FL.Sync.Debug.Log("PERM", 1, "live reject type=%s from=%q by=%q reason=notOfficer rank=%s",
            name, senderName, mark.by, tostring(FL.Sync.Permissions.RankOf(mark.by)));
        FL.Sync.Debug.Count("store.apply.rejected", 1);
        return;
    end

    local entry = { kind = kind, id = mark.id, rowTime = mark.rowTime, at = mark.at, by = mark.by };
    local applied, result = FL.Sync.Store.Apply(entry, "live");
    FL.Sync.Debug.Log("LIVE", 1, "in %s id=%s from=%q result=%s", name, mark.id, senderName, result);
end

local function onLiveMark(msgType, kind, checkFn)
    return function(body, senderName)
        local players, wireMark = body[3], body[4];
        local t0 = debugprofilestop();
        local mark, reason = Codec.DecodeMark(wireMark, players);
        local elapsed = debugprofilestop() - t0;
        local name = typeName(msgType);

        if (not mark) then
            FL.Sync.Debug.Log("CODEC", 2, "reject id=? reason=%s", reason);
            FL.Sync.Debug.Count("codec.rowRejects", 1);
            FL.Sync.Debug.Log("CODEC", 2, "decode type=%s from=%q ok=0 rejected=1 t=%.1fms", name, senderName, elapsed);
            FL.Sync.Debug.Log("LIVE", 1, "in %s id=? from=%q result=rejected reason=%s", name, senderName, reason);
            return;
        end
        FL.Sync.Debug.Log("CODEC", 2, "decode type=%s from=%q ok=1 rejected=0 t=%.1fms", name, senderName, elapsed);

        applyRemoteMark(msgType, kind, mark, senderName, checkFn);
    end
end

function Live.Init()
    Transport.Register(MSG.LIVE_ROW, onLiveRow);
    Transport.Register(MSG.LIVE_DEL, onLiveMark(MSG.LIVE_DEL, "D", FL.Sync.Permissions.CanDelete));
    Transport.Register(MSG.LIVE_PIN, onLiveMark(MSG.LIVE_PIN, "P", FL.Sync.Permissions.CanPin));
end
