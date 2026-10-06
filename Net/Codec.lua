--[[
Wire format (spec section 4): shrinks a history row/tombstone/pin down for
transmission, and the general LibSerialize -> LibDeflate -> WoW-addon-channel
pipeline every message (control or data) goes through.

Owns: the class-id map, batch-local player/response-type dictionaries, id
compaction (4.6), row/mark encode+decode with validation (4.9), and the
generic message envelope (header + pipeline). Net/Transport.lua only decodes
the envelope (PROTO_VERSION + message type) to dispatch to a handler - the
handler (Sync/Live.lua today; Sync/Session.lua from Phase 5) calls back into
this module's EncodeRow/DecodeRow/EncodeMark/DecodeMark directly on its own
body fields, and owns its own "[CODEC] encode/decode ..." debug line, since
only the handler knows what a given message type's body means (rows=1 vs
marks=1 vs a whole ROWS batch's rows=N).

Deviation from spec section 4.6 (see docs/sync-deviations.md "Phase 2: id
encoding"): the spec's id pattern assumes 5 hyphen-separated parts with a
separately-addressable realm segment. Phase 1 already found the real id
format has no such segment (LootCouncil.RecordHistory bakes the leader's
compact `name-realm` into ONE opaque prefix, via Util.playerFqn()'s own
internal hyphen) - so this module parses from the right (three trailing
numeric segments) instead of the left, and verifies the whole prefix against
`compact(awardedBy)-realm` rather than trying to split it into two parts.
]]

local FL = ForeverLoot;
local Codec = FL.Sync.Codec;
local Util = FL.Util;
local Constants = FL.Sync.Constants;
local MSG = Constants.MSG;

-- LibStub and every vendored lib load well before this file (TOC order), so
-- these can be resolved directly at file load instead of needing their own
-- Codec.Init() - this module otherwise has no Init() at all (no events, no
-- saved-variable state), matching Sync/Constants.lua's own "nothing here
-- depends on anything else loading first" convention.
local LibSerialize = LibStub("LibSerialize");
local LibDeflate = LibStub("LibDeflate");

--------------------------------------------------------------------------
-- Class id map (spec section 4.3) - built once at file load from WoW's own
-- class list, so it adapts to whatever classes WoW Forever has rather than
-- a hardcoded table.
--------------------------------------------------------------------------

local classIdByToken = {};
local classTokenById = {};

local function buildClassMap()
    local n = GetNumClasses and GetNumClasses() or 0;
    for i = 1, n do
        local _, classFile, classId = GetClassInfo(i);
        if (classFile and classId) then
            classIdByToken[classFile] = classId;
            classTokenById[classId] = classFile;
        end
    end
end
buildClassMap();

--- Numeric class id for a class file token, or 0 when unknown (spec 4.3:
--- "Use 0 when the class is unknown, for example a player who only appears
--- inside an id").
function Codec.ClassId(classFileName)
    return classIdByToken[classFileName] or 0;
end

--- Reverse of ClassId. nil for 0/unknown.
function Codec.ClassToken(classId)
    if (not classId or classId == 0) then return nil; end
    return classTokenById[classId];
end

--- `name:lower():gsub(" ", "")` (spec 4.6's compact()).
function Codec.CompactName(name)
    return (name or ""):lower():gsub(" ", "");
end

--------------------------------------------------------------------------
-- Batch-local dictionaries (spec 4.3, 4.4): a flat player (name, classId)
-- array and a flat response-type (color, kind, label) array, built in
-- first-seen order as rows/marks are encoded, then sent once per message.
--------------------------------------------------------------------------

local function newDictBuilder()
    local playerIndexByName = {};
    local playerNames = {};
    local playerClasses = {};
    local typeIndexByKey = {};
    local typeList = {};

    local builder = {};

    --- Returns this name's 1-based index into the dictionary, adding it
    --- (with `classFileName`, which may be nil) if this is the first time
    --- it's referenced in this batch. A later call for the same name keeps
    --- whichever non-nil class was supplied first.
    function builder:PlayerIndex(name, classFileName)
        if (type(name) ~= "string") then return nil; end
        local idx = playerIndexByName[name];
        if (idx) then
            if (classFileName and not playerClasses[idx]) then
                playerClasses[idx] = classFileName;
            end
            return idx;
        end
        table.insert(playerNames, name);
        idx = #playerNames;
        playerIndexByName[name] = idx;
        playerClasses[idx] = classFileName;
        return idx;
    end

    function builder:ResponseTypeIndex(respType)
        if (type(respType) ~= "table") then return nil; end
        local key = (respType.color or "") .. "|" .. (respType.kind or "") .. "|" .. (respType.label or "");
        local idx = typeIndexByKey[key];
        if (idx) then return idx; end
        table.insert(typeList, { color = respType.color, kind = respType.kind, label = respType.label });
        idx = #typeList;
        typeIndexByKey[key] = idx;
        return idx;
    end

    --- The flat { name1, classId1, name2, classId2, ... } array for the
    --- wire (spec 4.3).
    function builder:Players()
        local flat = {};
        for i, name in ipairs(playerNames) do
            flat[#flat + 1] = name;
            flat[#flat + 1] = Codec.ClassId(playerClasses[i]);
        end
        return flat;
    end

    --- The flat { color1, kind1, label1, color2, ... } array for the wire
    --- (spec 4.4).
    function builder:Types()
        local flat = {};
        for _, t in ipairs(typeList) do
            flat[#flat + 1] = t.color;
            flat[#flat + 1] = t.kind;
            flat[#flat + 1] = t.label;
        end
        return flat;
    end

    function builder:PlayerCount() return #playerNames; end
    function builder:TypeCount() return #typeList; end

    return builder;
end
Codec.NewDictBuilder = newDictBuilder;

local function playerName(players, idx)
    if (type(players) ~= "table" or type(idx) ~= "number") then return nil; end
    return players[2 * idx - 1];
end

local function playerClassToken(players, idx)
    if (type(players) ~= "table" or type(idx) ~= "number") then return nil; end
    return Codec.ClassToken(players[2 * idx]);
end

local function responseTypeAt(types, idx)
    if (type(types) ~= "table" or type(idx) ~= "number") then return nil; end
    -- Range-check against the dictionary's actual entry count, NOT against
    -- whether the fields happen to be non-nil: an old row whose response had
    -- no `response` table at all (r.response or {} -> an all-nil entry) is a
    -- perfectly valid dictionary entry once encoded, and must decode back to
    -- one instead of being mistaken for an out-of-range index.
    if (idx < 1 or idx > (#types / 3)) then return nil; end
    local base = 3 * idx - 2;
    return { color = types[base], kind = types[base + 1], label = types[base + 2] };
end

--------------------------------------------------------------------------
-- Id encoding (spec 4.6, adjusted per this file's header comment)
--------------------------------------------------------------------------

--- Encodes `id` as {playerIdx, realm, sessionId, itemSession, awardSeq} when
--- it matches the award-id shape AND its leader prefix matches
--- compact(awardedBy)-realm; otherwise returns `id` unchanged (the
--- round-trip guard - spec 4.6). `awardedBy` is the row's own awardedBy
--- field, which (per LootCouncil.RecordHistory) is always this id's
--- session-leader name already, so no separate roster lookup is needed to
--- find "the leader" - it's whichever player index `builder` already has
--- for `awardedBy`.
function Codec.EncodeId(id, awardedBy, builder)
    if (type(id) ~= "string" or type(awardedBy) ~= "string") then
        FL.Sync.Debug.Log("CODEC", 2, "sending row id %s in full · not in the usual id pattern", tostring(id));
        FL.Sync.Debug.Count("codec.rawIds", 1);
        return id;
    end

    local prefix, a, b, c = id:match("^(.-)%-(%d+)%-(%d+)%-(%d+)$");
    if (not prefix) then
        FL.Sync.Debug.Log("CODEC", 2, "sending row id %s in full · not in the usual id pattern", id);
        FL.Sync.Debug.Count("codec.rawIds", 1);
        return id;
    end

    -- Lowercased here, not just for the expectedPrefix check below: this is
    -- also the value that goes ON THE WIRE in `compact` a few lines down,
    -- and DecodeId reconstructs the id as CompactName(name) .. "-" .. realm
    -- verbatim (no further :lower()). The original id's realm segment is
    -- always lowercase too (RecordHistory lowercases the whole initiatorFqn,
    -- name and realm together, in one :lower() call) - leaving this
    -- mixed-case (GetRealmName() is normally display-cased, e.g.
    -- "ClassicBetaPvp2") made the leader-prefix check below pass (it does
    -- its own :lower()) while the round-trip guard after it failed, since
    -- the reconstructed id came out mixed-case where the original was
    -- lowercase - silently forcing every single compactable id to the raw
    -- fallback instead.
    local realm = (GetRealmName() or ""):lower():gsub("%s+", "");
    local expectedPrefix = (awardedBy .. "-" .. realm):lower():gsub("%s+", "");
    if (prefix ~= expectedPrefix) then
        FL.Sync.Debug.Log("CODEC", 2, "sending row id %s in full · id doesn't start with its awarder's name", id);
        FL.Sync.Debug.Count("codec.rawIds", 1);
        return id;
    end

    local idx = builder:PlayerIndex(awardedBy, nil);
    local compact = { idx, realm, tonumber(a), tonumber(b), tonumber(c) };

    -- Round-trip guard: decode what we just built (against the dictionary's
    -- CURRENT state - fine, PlayerIndex above already added `awardedBy`)
    -- and compare byte-for-byte before trusting the compact form.
    if (Codec.DecodeId(compact, builder:Players()) ~= id) then
        FL.Sync.Debug.Log("CODEC", 2, "sending row id %s in full · short form didn't decode back the same", id);
        FL.Sync.Debug.Count("codec.rawIds", 1);
        return id;
    end

    return compact;
end

--- Reverses EncodeId. `encoded` is either the raw id string (fallback path)
--- or the {playerIdx, realm, a, b, c} table.
function Codec.DecodeId(encoded, players)
    if (type(encoded) == "string") then return encoded; end
    if (type(encoded) ~= "table") then return nil; end

    local idx, realm, a, b, c = encoded[1], encoded[2], encoded[3], encoded[4], encoded[5];
    local name = playerName(players, idx);
    if (not name or type(realm) ~= "string" or type(a) ~= "number" or type(b) ~= "number" or type(c) ~= "number") then
        return nil;
    end
    return ("%s-%s-%d-%d-%d"):format(Codec.CompactName(name), realm, a, b, c);
end

--------------------------------------------------------------------------
-- Row encode/decode (spec 4.7, validated per 4.9)
--------------------------------------------------------------------------

local ITEM_STRING_PATTERN = "^%d+[%d:%-]*$";

--- Builds the positional wire row for `row` (spec 4.7), registering every
--- player/response-type/id it references into `builder`.
function Codec.EncodeRow(row, builder)
    local byIdx = builder:PlayerIndex(row.awardedBy, FL.Sync.Permissions.ClassOf(row.awardedBy));
    local toIdx = builder:PlayerIndex(row.awardedTo, row.awardedToClass);
    local idEncoded = Codec.EncodeId(row.id, row.awardedBy, builder);

    local names = {};
    if (row.responses) then
        for name in pairs(row.responses) do table.insert(names, name); end
        table.sort(names); -- deterministic order (spec 4.7)
    end

    local respFlat = {};
    for _, name in ipairs(names) do
        local r = row.responses[name];
        table.insert(respFlat, builder:PlayerIndex(name, r.class));
        table.insert(respFlat, builder:ResponseTypeIndex(r.response or {}));
        table.insert(respFlat, r.votes or 0);
        table.insert(respFlat, r.note or "");
    end

    return { idEncoded, row.awardedAt, byIdx, toIdx, row.sessionId or 0, row.itemSession or 0, row.itemString or "", respFlat };
end

--- Best-effort id string for a reject log line when the row itself failed
--- to decode (so `id` may not be trustworthy/available at all).
function Codec.WireRowIdGuess(wireRow)
    local v = type(wireRow) == "table" and wireRow[1] or nil;
    if (type(v) == "string") then return v; end
    if (type(v) == "table") then return ("<%s-%s-%s-%s>"):format(tostring(v[1]), tostring(v[3]), tostring(v[4]), tostring(v[5])); end
    return "?";
end

--- Decodes+validates one wire row (spec 4.9). Returns (row, nil, nil) on
--- success, or (nil, reason, field) on rejection - `reason` is one of the
--- fixed outcome words (badType, badIndex, tooManyResponses, noteTooLong,
--- future, expired, badItemString), `field` the 1-based wire position that
--- failed, when known.
function Codec.DecodeRow(wireRow, players, types)
    if (type(wireRow) ~= "table") then return nil, "badType"; end

    local idEncoded, awardedAt, byIdx, toIdx, sessionId, itemSession, itemString, respFlat =
        wireRow[1], wireRow[2], wireRow[3], wireRow[4], wireRow[5], wireRow[6], wireRow[7], wireRow[8];

    if (type(awardedAt) ~= "number") then return nil, "badType", 2; end
    if (type(sessionId) ~= "number") then return nil, "badType", 5; end
    if (type(itemSession) ~= "number") then return nil, "badType", 6; end
    if (type(itemString) ~= "string") then return nil, "badType", 7; end

    local awardedBy = playerName(players, byIdx);
    if (not awardedBy) then return nil, "badIndex", 3; end
    local awardedTo = playerName(players, toIdx);
    if (not awardedTo) then return nil, "badIndex", 4; end

    local id = Codec.DecodeId(idEncoded, players);
    if (not id) then return nil, "badIndex", 1; end

    if (not itemString:match(ITEM_STRING_PATTERN)) then return nil, "badItemString", 7; end

    if (awardedAt > GetServerTime() + 86400) then return nil, "future", 2; end
    local db = FL.DB.lootCouncil;
    if (FL.Sync.Retention.IsExpired(awardedAt) and not (db and db.pins[id])) then
        return nil, "expired", 2;
    end

    local responses, respCount = {}, 0;
    if (type(respFlat) == "table") then
        for i = 1, #respFlat, 4 do
            respCount = respCount + 1;
            if (respCount > Constants.MAX_RESPONSES) then return nil, "tooManyResponses", 8; end

            local pIdx, tIdx, votes, note = respFlat[i], respFlat[i + 1], respFlat[i + 2], respFlat[i + 3];
            local pName = playerName(players, pIdx);
            if (not pName) then return nil, "badIndex", 8; end
            local respType = responseTypeAt(types, tIdx);
            if (not respType) then return nil, "badIndex", 8; end
            if (type(note) ~= "string") then return nil, "badType", 8; end
            if (#note > Constants.NOTE_MAX_LEN) then return nil, "noteTooLong", 8; end

            responses[pName] = {
                class = playerClassToken(players, pIdx),
                response = respType,
                votes = tonumber(votes) or 0,
                note = note,
            };
        end
    end

    local itemID, _, _, _, icon = C_Item.GetItemInfoInstant("item:" .. itemString);
    local itemLink = select(2, Util.GetItemInfo("item:" .. itemString));

    local row = {
        id = id,
        awardedAt = awardedAt,
        awardedBy = awardedBy,
        awardedTo = awardedTo,
        awardedToClass = playerClassToken(players, toIdx),
        sessionId = sessionId,
        itemSession = itemSession,
        itemString = itemString,
        itemID = itemID,
        itemIcon = icon,
        itemLink = itemLink,
        responses = responses,
    };
    return row;
end

--------------------------------------------------------------------------
-- Mark encode/decode (tombstones and pins - spec 3.2/3.3, wire shape per
-- the MARKS row in spec section 6's catalog, minus the leading `kind`
-- character: the message TYPE (LIVE_DEL vs LIVE_PIN, or later a MARKS
-- batch's own per-entry kind) already says which, so EncodeMark/DecodeMark
-- only carry {id, rowTime, at, byIdx}.
--------------------------------------------------------------------------

--- `originalAwardedBy` is the deleted/pinned row's OWN awardedBy (the
--- caller - Sync/Live.lua's Live.Delete/Live.Pin - still has the local row
--- in hand at the moment it tombstones/pins it), used purely for
--- EncodeId's leader-prefix check; pass nil to always send the raw id
--- string (e.g. when the local row is no longer available).
function Codec.EncodeMark(mark, originalAwardedBy, builder)
    local idEncoded;
    if (originalAwardedBy) then
        idEncoded = Codec.EncodeId(mark.id, originalAwardedBy, builder);
    else
        idEncoded = mark.id;
        FL.Sync.Debug.Log("CODEC", 2, "sending row id %s in full · awarder unknown", tostring(mark.id));
        FL.Sync.Debug.Count("codec.rawIds", 1);
    end
    local byIdx = builder:PlayerIndex(mark.by, FL.Sync.Permissions.ClassOf(mark.by));
    return { idEncoded, mark.rowTime, mark.at, byIdx };
end

function Codec.DecodeMark(wireMark, players)
    if (type(wireMark) ~= "table") then return nil, "badType"; end
    local idEncoded, rowTime, at, byIdx = wireMark[1], wireMark[2], wireMark[3], wireMark[4];

    local id = Codec.DecodeId(idEncoded, players);
    if (not id) then return nil, "badIndex"; end
    local by = playerName(players, byIdx);
    if (not by) then return nil, "badIndex"; end
    if (type(rowTime) ~= "number" or type(at) ~= "number") then return nil, "badType"; end

    return { id = id, rowTime = rowTime, at = at, by = by };
end

--------------------------------------------------------------------------
-- Generic message envelope: LibSerialize -> LibDeflate -> WoW addon-channel
-- encoding, and back (spec 4.1). `bodyArray` must already start with
-- {PROTO_VERSION, msgType, ...}; DecodeMessage hands the whole thing back
-- for the caller (Net/Transport.lua) to read bodyArray[2] and dispatch.
-- A body from another PROTO_VERSION fails with "version" but is returned as
-- a third value, so Transport can still read a foreign HELLO's addon
-- version for the update hint (plan Phase 8) without dispatching it.
--------------------------------------------------------------------------

function Codec.EncodeMessage(bodyArray)
    local t0 = debugprofilestop();
    local serialized = LibSerialize:Serialize(bodyArray);
    local compressed = LibDeflate:CompressDeflate(serialized, { level = 9 });
    local encoded = LibDeflate:EncodeForWoWAddonChannel(compressed);
    local elapsed = debugprofilestop() - t0;
    return encoded, { ser = #serialized, cmp = #compressed, enc = #encoded, ms = elapsed };
end

function Codec.DecodeMessage(encoded)
    local ok1, compressed = pcall(LibDeflate.DecodeForWoWAddonChannel, LibDeflate, encoded);
    if (not ok1 or not compressed) then return nil, "decode"; end

    local ok2, serialized = pcall(LibDeflate.DecompressDeflate, LibDeflate, compressed);
    if (not ok2 or not serialized) then return nil, "decompress"; end

    local ok3, bodyArray = LibSerialize:Deserialize(serialized);
    if (not ok3 or type(bodyArray) ~= "table") then return nil, "deserialize"; end

    if (bodyArray[1] ~= Constants.PROTO_VERSION) then return nil, "version", bodyArray; end
    return bodyArray;
end

--------------------------------------------------------------------------
-- /fl debug roundtrip [n] - encodes the newest n (default 50) local history
-- rows as one ROWS batch, decodes it back, and compares every field.
--------------------------------------------------------------------------

local function fieldMismatch(field, localVal, decodedVal)
    return { field = field, localVal = localVal, decodedVal = decodedVal };
end

local function compareResponses(id, aResp, bResp)
    aResp, bResp = aResp or {}, bResp or {};
    for name, r in pairs(aResp) do
        local other = bResp[name];
        if (not other) then return fieldMismatch(("responses[%s]"):format(name), "present", "missing"); end
        if ((r.note or "") ~= (other.note or "")) then
            return fieldMismatch(("responses[%s].note"):format(name), r.note, other.note);
        end
        if ((r.votes or 0) ~= (other.votes or 0)) then
            return fieldMismatch(("responses[%s].votes"):format(name), r.votes, other.votes);
        end
        -- Class is carried once per player NAME in the batch dictionary
        -- (spec 4.3), not once per response - so a row whose own stored
        -- response has class=nil (incomplete older data) can legitimately
        -- decode with that same player's class FILLED IN from wherever else
        -- in this batch it was captured. That's the dictionary doing its
        -- job, not data loss, so only a genuine known-vs-known mismatch
        -- counts as a diff.
        if (r.class and r.class ~= other.class) then
            return fieldMismatch(("responses[%s].class"):format(name), r.class, other.class);
        end
        local ar, br = r.response or {}, other.response or {};
        if ((ar.label or "") ~= (br.label or "") or (ar.color or "") ~= (br.color or "") or (ar.kind or "") ~= (br.kind or "")) then
            return fieldMismatch(("responses[%s].response"):format(name), ar.label, br.label);
        end
    end
    for name in pairs(bResp) do
        if (not aResp[name]) then return fieldMismatch(("responses[%s]"):format(name), "missing", "present"); end
    end
    return nil;
end

-- itemLink is "compared by its item string" (plan's own wording) since the
-- decoded link's exact text can legitimately differ (locale, cached vs not)
-- while still describing the same item.
local function compareRows(a, b)
    if (a.id ~= b.id) then return fieldMismatch("id", a.id, b.id); end
    if (a.awardedAt ~= b.awardedAt) then return fieldMismatch("awardedAt", a.awardedAt, b.awardedAt); end
    if (a.awardedBy ~= b.awardedBy) then return fieldMismatch("awardedBy", a.awardedBy, b.awardedBy); end
    if (a.awardedTo ~= b.awardedTo) then return fieldMismatch("awardedTo", a.awardedTo, b.awardedTo); end
    if ((a.awardedToClass or false) ~= (b.awardedToClass or false)) then
        return fieldMismatch("awardedToClass", a.awardedToClass, b.awardedToClass);
    end
    if ((a.sessionId or 0) ~= (b.sessionId or 0)) then return fieldMismatch("sessionId", a.sessionId, b.sessionId); end
    if ((a.itemSession or 0) ~= (b.itemSession or 0)) then return fieldMismatch("itemSession", a.itemSession, b.itemSession); end

    local aItemString = a.itemString or FL.Sync.Store.ItemStringFromLink(a.itemLink);
    if ((aItemString or "") ~= (b.itemString or "")) then
        return fieldMismatch("itemString", aItemString, b.itemString);
    end

    return compareResponses(a.id, a.responses, b.responses);
end

--- Backs /fl debug roundtrip [n] (plan phase 2).
function Codec.Roundtrip(n)
    n = tonumber(n) or 50;

    -- Rows with no obtainable item string at all (pre-Phase-1-migration
    -- history whose itemLink never parsed - Data/Store.lua's own
    -- "migrate noItemString" warning) can never legally go on the wire
    -- (spec 4.9's badItemString check), on any client, ever - that's not a
    -- round-trip failure to report, it's the same thing missingItemString
    -- in /fl sync status already flags. Skipped here so the ok/diff counts
    -- only speak to rows that actually CAN sync.
    local candidates, skipped = {}, 0;
    for _, row in ipairs(FL.LootCouncil.History) do
        if (row.itemString or FL.Sync.Store.ItemStringFromLink(row.itemLink)) then
            table.insert(candidates, row);
        else
            skipped = skipped + 1;
        end
    end
    table.sort(candidates, function(a, b) return (a.awardedAt or 0) > (b.awardedAt or 0); end);

    local rows = {};
    for i = 1, math.min(n, #candidates) do table.insert(rows, candidates[i]); end
    if (#rows == 0) then
        print("|cff8865ffForeverLoot|r No history rows to round-trip.");
        return;
    end

    local rawIdsBefore = FL.Sync.Debug.GetCounter("codec.rawIds");

    local builder = newDictBuilder();
    local wireRows = {};
    for _, row in ipairs(rows) do
        table.insert(wireRows, Codec.EncodeRow(row, builder));
    end
    local token = "test";
    local body = { Constants.PROTO_VERSION, MSG.ROWS, token, 1, builder:Players(), builder:Types(), wireRows };
    local encoded, stats = Codec.EncodeMessage(body);
    FL.Sync.Debug.Log("CODEC", 2, "encoded ROWS · %d rows, %d players, %d responses, %s raw, %s compressed, %s on the wire, %.1fms",
        #rows, builder:PlayerCount(), builder:TypeCount(), FL.Sync.Debug.FormatBytes(stats.ser),
        FL.Sync.Debug.FormatBytes(stats.cmp), FL.Sync.Debug.FormatBytes(stats.enc), stats.ms);

    local decodedBody = Codec.DecodeMessage(encoded);
    local players, types, decodedWireRows = decodedBody[5], decodedBody[6], decodedBody[7];

    local decodedById = {};
    for _, wireRow in ipairs(decodedWireRows) do
        local row, reason, field = Codec.DecodeRow(wireRow, players, types);
        if (row) then
            decodedById[row.id] = row;
        else
            FL.Sync.Debug.Log("CODEC", 2, "rejected row %s · %s%s", tostring(Codec.WireRowIdGuess(wireRow)), tostring(reason),
                field and (" (field " .. field .. ")") or "");
        end
    end

    local ok, diff = 0, 0;
    for _, original in ipairs(rows) do
        local decoded = decodedById[original.id];
        if (not decoded) then
            diff = diff + 1;
            FL.Sync.Debug.Log("TEST", 1, "roundtrip history: row %s MISSING after decode", original.id);
        else
            local mismatch = compareRows(original, decoded);
            if (mismatch) then
                diff = diff + 1;
                FL.Sync.Debug.Log("TEST", 1, "roundtrip history: row %s MISMATCH in %s · local %q, decoded %q",
                    original.id, mismatch.field, tostring(mismatch.localVal), tostring(mismatch.decodedVal));
            else
                ok = ok + 1;
            end
        end
    end

    local rawIds = FL.Sync.Debug.GetCounter("codec.rawIds") - rawIdsBefore;
    FL.Sync.Debug.Log("TEST", 1, "roundtrip history: %s · %d rows, %d ok, %d mismatched, %d full ids, %d skipped, %s per row, %s total",
        (diff == 0) and "ok" or "MISMATCH", #rows, ok, diff, rawIds, skipped,
        FL.Sync.Debug.FormatBytes(math.floor(stats.cmp / #rows)), FL.Sync.Debug.FormatBytes(stats.cmp));
end
