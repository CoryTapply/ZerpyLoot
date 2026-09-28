--[[
SoftRes (soft-reserve) import, broadcast, and lookup - compatible with
softres.it's "Gargul Export" format and Gargul's broadcastSoftRes wire action.

Import pipeline: base64 decode -> zlib inflate -> JSON decode (see Gargul's
Classes/SoftRes.lua:1066-1245, importGargulData). The exact original pasted
string is kept verbatim and re-broadcast unmodified, so Gargul clients (and
other ForeverLoot clients) can re-parse the identical bytes we imported.

The raw pasted string is also persisted to FL.DB.softRes.importString on
every successful import, and reloaded (re-parsed, not re-broadcast) by
SoftRes.Init() at login, so soft reserves survive a UI reload/relog.
]]

local FL = ForeverLoot;
local SoftRes = FL.SoftRes;
local Constants = FL.Constants;
local Comm = FL.Comm;
local Util = FL.Util;
local Base64 = FL.Vendor.Base64;
local Json = FL.Vendor.Json;

-- Raw, as pasted/received - re-broadcast verbatim, never re-encoded.
SoftRes.ImportString = nil;
SoftRes.MetaData = nil;

-- Materialized lookup tables (see Classes/SoftRes.lua:344-437)
SoftRes.DetailsByPlayerName = {};   -- lowercase name -> {class, note, plusOnes, Items={[idString]=count}}
SoftRes.PlayerNamesByItemID = {};    -- idString -> {name, name, ...} (display-cased, duplicated per multi-reserve)
SoftRes.HardReserveDetailsByID = {}; -- idString -> {id, reservedFor, note}

-- Corrected display name -> true, (re)built by fixPlayerNames() on every
-- Import. Flags entries whose softres.it name didn't match anyone in the
-- raid and got fuzzy-linked to the closest unreserved member instead - the
-- import window uses this to warn when the linked character's actual class
-- doesn't match the class picked on softres.it, since that combination means
-- the fuzzy match may have paired the wrong two players.
SoftRes.RenamedNames = {};

local function debugPrint(msg)
    if (Comm.debugEnabled) then
        print("|cff8865ffForeverLoot|r " .. msg);
    end
end

local function capitalize(str)
    if (type(str) ~= "string" or str == "") then return str; end
    return string.upper(string.sub(str, 1, 1)) .. string.sub(str, 2);
end

--------------------------------------------------------------------------
-- Parse + materialize
--------------------------------------------------------------------------

-- Decode the softres.it "Gargul export" blob: base64 -> zlib -> JSON.
-- Returns (true, data) on success, or (false, errorMessage).
local function decodeGargulExport(pastedString)
    local LibDeflate = LibStub("LibDeflate");

    local base64Ok, decoded = pcall(Base64.decode, pastedString);
    if (not base64Ok or not decoded) then
        return false, "Unable to base64-decode the data. Make sure you copied the full 'Gargul Export' string.";
    end

    local zlibOk, inflated = pcall(function() return LibDeflate:DecompressZlib(decoded); end);
    if (not zlibOk or not inflated) then
        return false, "Unable to zlib-decompress the data. Make sure you copied it as-is.";
    end

    local jsonOk, data = Json.decode(inflated);
    if (not jsonOk) then
        return false, "Unable to JSON-decode the data: " .. tostring(data);
    end

    return true, data;
end

local function materialize()
    local details = {};
    local playerNamesByItemID = {};
    local hardReserveDetailsByID = {};

    for _, entry in pairs(SoftRes.MetaData.SoftReserves or {}) do
        local class = string.lower(entry.class or "");
        local name = string.lower(entry.name or "");

        if (name ~= "") then
            if (not details[name]) then
                details[name] = { class = class, note = entry.note or "", plusOnes = entry.plusOnes or 0, Items = {} };
            end

            for _, itemID in pairs(entry.Items or {}) do
                local idString = tostring(itemID);
                playerNamesByItemID[idString] = playerNamesByItemID[idString] or {};
                table.insert(playerNamesByItemID[idString], capitalize(name));

                details[name].Items[idString] = (details[name].Items[idString] or 0) + 1;
            end
        end
    end

    for _, entry in pairs(SoftRes.MetaData.HardReserves or {}) do
        local id = tonumber(entry.id) or 0;
        if (id > 0) then
            hardReserveDetailsByID[tostring(id)] = {
                id = id,
                reservedFor = capitalize(entry["for"] or ""),
                note = entry.note or "",
            };
        end
    end

    SoftRes.DetailsByPlayerName = details;
    SoftRes.PlayerNamesByItemID = playerNamesByItemID;
    SoftRes.HardReserveDetailsByID = hardReserveDetailsByID;
end

-- Auto-corrects SoftRes entries whose name doesn't match anyone in the
-- raid/party by pairing them with the closest-named raid member who appears
-- to have no reservation, if the edit distance is within threshold (looser
-- when their class also matches - mirrors Gargul's SoftRes:fixPlayerNames).
-- Mutates result.SoftReserves in place - called from SoftRes.Parse itself
-- (on the still-local, not-yet-returned result), so every parse - live
-- preview, Import, or a reload's re-parse of the same saved string - is
-- already name-corrected and produces the identical result for the same
-- input, with no separate "fix it after the fact" step for callers to forget.
---@return table renamed {originalName -> correctedName} for anything rewired
local function fixPlayerNames(result)
    SoftRes.RenamedNames = {}; -- reset every call - a prior parse's flags must not leak into this one

    local groupMembers = Util.groupMembers(); -- name -> classToken
    local classByLowerName = {};
    local reservedByLowerName = {};
    for name, classToken in pairs(groupMembers) do
        local lowerName = string.lower(name);
        classByLowerName[lowerName] = classToken;
        reservedByLowerName[lowerName] = false;
    end

    local unmatchedEntries = {}; -- lowercase softres name -> lowercase class name
    for _, entry in pairs(result.SoftReserves or {}) do
        local lowerName = string.lower(entry.name or "");
        if (reservedByLowerName[lowerName] ~= nil) then
            reservedByLowerName[lowerName] = true;
        else
            unmatchedEntries[lowerName] = string.lower(entry.class or "");
        end
    end

    if (not next(unmatchedEntries)) then return {}; end

    local nameDictionary = {}; -- lowercase softres name -> corrected display name
    for lowerName, reserved in pairs(reservedByLowerName) do
        if (not reserved) then
            local candidateClass = classByLowerName[lowerName];
            local bestMatch, bestDistance = nil, 99;

            for entryLowerName, entryClass in pairs(unmatchedEntries) do
                local maxDistance = (Util.classNameToToken(entryClass) == candidateClass) and 4 or 2;
                local distance = Util.levenshtein(lowerName, entryLowerName);
                if (distance <= maxDistance and distance < bestDistance) then
                    bestMatch, bestDistance = entryLowerName, distance;
                end
            end

            if (bestMatch) then
                for name in pairs(groupMembers) do
                    if (string.lower(name) == lowerName) then nameDictionary[bestMatch] = name; break; end
                end
            end
        end
    end

    if (not next(nameDictionary)) then return {}; end

    local renamed = {};
    for _, entry in pairs(result.SoftReserves or {}) do
        local corrected = nameDictionary[string.lower(entry.name or "")];
        if (corrected) then
            renamed[entry.name] = corrected;
            SoftRes.RenamedNames[corrected] = true;
            entry.name = corrected;
        end
    end

    return renamed;
end

--- Parse a softres.it "Gargul Export" string - used both by Import (below)
--- and by the import window's live preview, which must be able to show
--- entries before the user commits. Auto-corrects any entry name that
--- doesn't match a raid member (see fixPlayerNames) and refreshes
--- SoftRes.RenamedNames accordingly, but never touches SoftRes.MetaData/
--- ImportString themselves - only Import does that.
---@param pastedString string
---@return boolean success
---@return table|string result Parsed {id, createdAt, updatedAt, url, SoftReserves, HardReserves} on success, or an error message
---@return table|nil renamed {originalName -> correctedName} for anything auto-linked - only present on success
function SoftRes.Parse(pastedString)
    if (type(pastedString) ~= "string" or pastedString == "") then
        return false, "No data provided.";
    end

    local ok, data = decodeGargulExport(pastedString);
    if (not ok) then
        return false, data;
    end

    if (type(data) ~= "table" or type(data.softreserves) ~= "table" or not data.metadata or not data.metadata.id) then
        return false, "Invalid data provided. Make sure to click the 'Gargul Export' button on softres.it and paste the full contents here.";
    end

    local softReserves = {};
    for _, entry in pairs(data.softreserves) do
        local items = entry.items;
        if (type(items) == "table" and entry.name and entry.class) then
            local class = string.lower(entry.class);
            if (class == "deathknight") then class = "death knight"; end

            local playerItems = {};
            for _, item in pairs(items) do
                local itemID = tonumber(item.id) or 0;
                if (itemID > 0) then table.insert(playerItems, itemID); end
            end

            if (#playerItems > 0) then
                table.insert(softReserves, {
                    name = entry.name,
                    class = class,
                    note = entry.note or "",
                    plusOnes = math.max(tonumber(entry.plusOnes) or 0, 0),
                    Items = playerItems,
                });
            end
        end
    end

    local hardReserves = {};
    for _, entry in pairs(data.hardreserves or {}) do
        local id = tonumber(entry.id) or 0;
        if (id > 0) then
            table.insert(hardReserves, { id = id, ["for"] = entry["for"] or "", note = entry.note or "" });
        end
    end

    local result = {
        id = tostring(data.metadata.id),
        createdAt = tonumber(data.metadata.createdAt) or 0,
        updatedAt = tonumber(data.metadata.updatedAt) or 0,
        url = data.metadata.url or ("https://softres.it/raid/" .. tostring(data.metadata.id)),
        SoftReserves = softReserves,
        HardReserves = hardReserves,
    };

    local renamed = fixPlayerNames(result);

    return true, result, renamed;
end

--- Import a softres.it "Gargul Export" string (base64/zlib/JSON blob).
---@param pastedString string
---@param isFromBroadcast boolean|nil True when called from the broadcastSoftRes
---  receive handler - skips re-broadcasting (which would otherwise cause an
---  infinite raid-wide re-broadcast loop, since every receiving client would
---  import and then broadcast in turn) and the "imported" chat announcement.
---@param skipPersist boolean|nil True when called from SoftRes.Init while
---  loading the previously-saved import back out of the DB - skips writing
---  the exact same string back to the DB.
---@return boolean success
---@return string|nil errorMessage
function SoftRes.Import(pastedString, isFromBroadcast, skipPersist)
    local ok, result, renamed = SoftRes.Parse(pastedString);
    if (not ok) then
        return false, result;
    end

    SoftRes.ImportString = pastedString;
    SoftRes.MetaData = result;

    for original, corrected in pairs(renamed) do
        print(("|cff8865ffForeverLoot|r Auto name fix: the SR of '%s' is now linked to '%s'"):format(original, corrected));
    end

    materialize();

    if (not skipPersist) then
        FL.DB.softRes = FL.DB.softRes or {};
        FL.DB.softRes.importString = pastedString;
    end

    debugPrint(("SoftRes imported: %d player entries, %d hard reserves"):format(
        #result.SoftReserves, #result.HardReserves
    ));

    if (not isFromBroadcast) then
        SoftRes.Broadcast();

        local channel = Util.GroupChatChannel();
        if (channel) then
            Util.SendChatMessageSafe("Softres data was imported", channel);
        end
    end

    return true;
end

--- Wipe all locally-held SoftRes data so nothing shows up in tooltips or
--- lookups anymore. Purely local - does not tell anyone else to clear theirs
--- (there's no wire action for that; Gargul itself has no such broadcast
--- either, since receiving a *new* import is what replaces old data there).
function SoftRes.Clear()
    SoftRes.ImportString = nil;
    SoftRes.MetaData = nil;
    SoftRes.DetailsByPlayerName = {};
    SoftRes.PlayerNamesByItemID = {};
    SoftRes.HardReserveDetailsByID = {};

    if (FL.DB.softRes) then
        FL.DB.softRes.importString = nil;
    end

    debugPrint("SoftRes data cleared");
end

--------------------------------------------------------------------------
-- Broadcast / receive
--------------------------------------------------------------------------

--- Broadcast the currently-imported SoftRes data to the group, verbatim -
--- Gargul clients re-parse the exact same string on receipt.
function SoftRes.Broadcast()
    if (not SoftRes.ImportString) then
        print("|cff8865ffForeverLoot|r No SoftRes data imported yet.");
        return false;
    end

    Comm.Send(Constants.Actions.broadcastSoftRes, SoftRes.ImportString, "GROUP");
    debugPrint("Broadcast SoftRes data to group");
    return true;
end

Comm.Actions[Constants.Actions.broadcastSoftRes] = function(Message)
    if (Message.isSelf) then return; end

    local content = Message.content;
    if (type(content) ~= "string" or content == "") then return; end

    local ok, err = SoftRes.Import(content, true);
    if (ok) then
        local from = Util.stripRealm(Message.senderFqn) or Message.senderFqn or "someone";
        print(("|cff8865ffForeverLoot|r Received SoftRes data from %s (%d players, %d hard reserves)."):format(
            from, #(SoftRes.MetaData.SoftReserves or {}), #(SoftRes.MetaData.HardReserves or {})
        ));

        -- Someone else's import just replaced our data (and DB.softRes.importString,
        -- via the persist above) - if the SoftRes window is open, its preview and
        -- paste box are now stale, so sync them to match.
        if (FL.UI.SoftResImportWindow and FL.UI.SoftResImportWindow.SyncExternalImport) then
            FL.UI.SoftResImportWindow.SyncExternalImport();
        end
    else
        debugPrint("Failed to import SoftRes broadcast from " .. tostring(Message.senderFqn) .. ": " .. tostring(err));
    end
end

--------------------------------------------------------------------------
-- Lookup API (used by Tooltip.lua and RollTracker.lua)
--------------------------------------------------------------------------

--- Returns a sorted array of display names for players currently in the
--- raid/party who don't have a soft-reserve entry (names are already
--- typo-corrected by fixPlayerNames at import time, so this stays exact-match -
--- mirrors Gargul's SoftRes:playersWithoutSoftReserves).
function SoftRes.PlayersWithoutSoftReserves()
    local missing = {};
    for name in pairs(Util.groupMembers()) do
        if (not SoftRes.DetailsByPlayerName[string.lower(name)]) then
            table.insert(missing, name);
        end
    end
    table.sort(missing);
    return missing;
end

--- Announces to the group (or prints locally when solo) that the given
--- names are missing a soft-reserve. Shared by SoftRes.PostMissingSoftReserves
--- (which sources its list from the last COMMITTED import) and the Import
--- window's Report Missing button (which sources its list from whatever's
--- currently parsed in the paste box, committed or not).
function SoftRes.AnnounceMissingNames(missing)
    local channel = Util.GroupChatChannel();
    local text = (#missing == 0)
        and "Everyone in the raid has a soft-reserve registered."
        or ("Missing soft-reserves from: " .. table.concat(missing, ", "));

    if (channel) then
        Util.SendChatMessageSafe(text, channel);
    else
        print("|cff8865ffForeverLoot|r " .. text);
    end
end

--- Announces to the group (or prints locally when solo) which group members
--- haven't submitted a soft-reserve yet. Mirrors Gargul's
--- SoftRes:postMissingSoftReserves.
---@return boolean success
---@return table missingNames
function SoftRes.PostMissingSoftReserves()
    if (not SoftRes.MetaData) then
        print("|cff8865ffForeverLoot|r No SoftRes data imported yet.");
        return false, {};
    end

    local missing = SoftRes.PlayersWithoutSoftReserves();
    SoftRes.AnnounceMissingNames(missing);
    return true, missing;
end

--- Returns [{name=displayName, count=number}] sorted by count descending, or {}.
function SoftRes.GetReservationsForItemID(itemID)
    if (not itemID) then return {}; end

    local names = SoftRes.PlayerNamesByItemID[tostring(itemID)];
    if (not names or #names == 0) then return {}; end

    local counts = {};
    local order = {};
    for _, name in ipairs(names) do
        if (not counts[name]) then
            table.insert(order, name);
            counts[name] = 0;
        end
        counts[name] = counts[name] + 1;
    end

    local result = {};
    for _, name in ipairs(order) do
        table.insert(result, { name = name, count = counts[name] });
    end

    table.sort(result, function(a, b) return a.count > b.count; end);

    return result;
end

--- Returns {reservedFor, note} or nil.
function SoftRes.GetHardReserveForItemID(itemID)
    if (not itemID) then return nil; end
    return SoftRes.HardReserveDetailsByID[tostring(itemID)];
end

function SoftRes.GetPlayerClass(name)
    if (not name) then return nil; end
    local details = SoftRes.DetailsByPlayerName[string.lower(name)];
    return details and details.class or nil;
end

--- Whether `name` has a soft-reserve on `itemID` - used to flag [SR] next to
--- a roller in the roll-off window.
function SoftRes.PlayerHasReservedItem(name, itemID)
    if (not name or not itemID) then return false; end
    local details = SoftRes.DetailsByPlayerName[string.lower(name)];
    return details ~= nil and details.Items[tostring(itemID)] ~= nil;
end

--------------------------------------------------------------------------
-- Whisper command ("!sr" / "!SR") - reply with the sender's own soft
-- reserves (item links + count), mirroring Gargul's SoftRes:handleWhisperCommand.
--------------------------------------------------------------------------

-- C_PartyInfo.GetLootMethod returns a numeric Enum.LootMethod; this maps it to
-- the (string, partyID, raidID) shape Gargul's own GL.GetLootMethod shim
-- returns (Utils/Shims.lua:170-191).
local LOOT_METHOD_NAMES = {
    [0] = "freeforall", [1] = "roundrobin", [2] = "master",
    [3] = "group", [4] = "needbeforegreed", [5] = "personalloot",
};

local function currentLootMethod()
    local method, partyID, raidID = C_PartyInfo.GetLootMethod();
    return LOOT_METHOD_NAMES[method], partyID, raidID;
end

-- Only the person actually in charge of loot answers, so a raid member who
-- merely received the broadcasted SoftRes data (and could therefore also
-- answer) doesn't reply as if they were the authority on it.
local function canAnswerWhisperCommand()
    if (not IsInGroup()) then return true; end -- solo/testing

    local lootMethod, masterLooterPartyID, masterLooterRaidID = currentLootMethod();
    if (lootMethod == "master") then
        if (IsInRaid()) then
            return masterLooterRaidID ~= nil and UnitIsUnit("player", "raid" .. masterLooterRaidID);
        end
        return masterLooterPartyID ~= nil and (masterLooterPartyID == 0 or UnitIsUnit("player", "party" .. masterLooterPartyID));
    end

    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player");
end

local function sendWhisperReply(sender, text)
    Util.SendChatMessageSafe(text, "WHISPER", nil, sender);
end

-- Turns {[idString]=count} into a reply string once every item's link is
-- cached; returns false (and leaves nothing sent) if any item link isn't
-- available yet, so the caller can wait and retry.
local function tryReplyWithReserves(sender, items)
    local entries = {};

    for idString, count in pairs(items) do
        local itemID = tonumber(idString);
        local _, itemLink = Util.GetItemInfo(itemID);
        if (not itemLink) then return false; end

        if (count and count > 1) then
            table.insert(entries, ("%s (%dx)"):format(itemLink, count));
        else
            table.insert(entries, itemLink);
        end
    end

    sendWhisperReply(sender, "You reserved " .. table.concat(entries, " "));
    return true;
end

function SoftRes.HandleWhisperCommand(message, sender)
    if (Util.isSecret(message) or Util.isSecret(sender)) then return; end
    if (type(message) ~= "string" or type(sender) ~= "string") then return; end
    if (string.lower(string.sub(strtrim(message), 1, 3)) ~= "!sr") then return; end
    if (not canAnswerWhisperCommand()) then return; end

    local details = SoftRes.DetailsByPlayerName[string.lower(Util.stripRealm(sender))];
    if (not details or not next(details.Items or {})) then
        sendWhisperReply(sender, "It seems like you didn't soft-reserve anything yet, check the soft-res sheet or ask your loot master.");
        return;
    end

    if (tryReplyWithReserves(sender, details.Items)) then return; end

    -- Some item(s) aren't cached client-side yet - request them and retry
    -- once GET_ITEM_INFO_RECEIVED fires, giving up after 10s.
    for idString in pairs(details.Items) do
        C_Item.RequestLoadItemDataByID(tonumber(idString));
    end

    local waitFrame = CreateFrame("Frame");
    local elapsed = 0;
    waitFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED");
    waitFrame:SetScript("OnEvent", function(self)
        if (tryReplyWithReserves(sender, details.Items)) then
            self:UnregisterAllEvents();
            self:SetScript("OnUpdate", nil);
        end
    end);
    waitFrame:SetScript("OnUpdate", function(self, delta)
        elapsed = elapsed + delta;
        if (elapsed > 10) then
            self:UnregisterAllEvents();
            self:SetScript("OnUpdate", nil);
        end
    end);
end

local function initWhisperListener()
    local whisperFrame = CreateFrame("Frame");
    whisperFrame:RegisterEvent("CHAT_MSG_WHISPER");
    whisperFrame:SetScript("OnEvent", function(_, _, message, sender)
        SoftRes.HandleWhisperCommand(message, sender);
    end);
end

function SoftRes.Init()
    initWhisperListener();

    local saved = FL.DB.softRes and FL.DB.softRes.importString;
    if (not saved) then return; end

    local ok, err = SoftRes.Import(saved, true, true);
    if (not ok) then
        debugPrint("Failed to load saved SoftRes data from DB: " .. tostring(err));
    end
end
