local FL = ForeverLoot;
local Util = FL.Util;

-- Turn a Blizzard global format string (e.g. RANDOM_ROLL_RESULT, containing
-- %s/%d or positional %1$s/%2$d tokens) into a Lua match pattern with capture
-- groups, in the same left-to-right order the tokens appear in the string.
--
-- Gargul's own Utils/Strings.lua GL:createPattern builds this via
-- string.gsub(..., "%%d", "%(%%d-%)") - a REPLACEMENT STRING containing "%("
-- and "%)". Lua's gsub only validates a replacement string's %-escapes when
-- the search pattern actually finds a match (confirmed empirically), so that
-- call is a latent "invalid use of '%' in replacement string" runtime error
-- for any format string where it matches - and this function runs at addon
-- load time (RollTracker.lua sets rollPattern = Util.createPattern(...) on
-- load), so a real match there would abort the whole addon's load. We get
-- the same capture-group result by using a replacement FUNCTION instead,
-- which sidesteps %-escaping entirely.
function Util.createPattern(formatString)
    -- Escape Lua pattern magic characters that can appear as literal text
    -- around the format specifiers (e.g. the parens/dash in "(%d-%d)").
    -- '%', '$', and digits are deliberately left alone - they're part of the
    -- format specifiers we handle next, and '$' is only special as the very
    -- last character of a whole pattern (not the case here).
    local escaped = string.gsub(formatString, "[%(%)%.%+%-%*%?%[%]]", "%%%1");

    return (string.gsub(escaped, "%%(%d*)%$?([sd])", function(_, kind)
        if (kind == "s") then
            return "(.-)";
        end
        return "(%d-)";
    end));
end

-- Roll results never include a realm suffix, so group-member matching and
-- display both work off the base (realm-stripped) name.
function Util.stripRealm(name)
    if (not name) then return name; end
    local base = string.match(name, "^([^%-]+)");
    return base or name;
end

function Util.iEquals(a, b)
    if (type(a) ~= "string" or type(b) ~= "string") then
        return a == b;
    end
    return string.lower(a) == string.lower(b);
end

-- Forever characters have two names separated by a space ("First Last"), and
-- different sources (roll messages, roster, unit names, trade window) report
-- either the full pair or just one half. All name comparisons go through the
-- helpers below rather than plain equality.
local function nameParts(name)
    local parts = {};
    for part in string.gmatch(string.lower(Util.stripRealm(name)), "%S+") do
        table.insert(parts, part);
    end
    return parts;
end

-- True when a and b are the same name, ignoring case and realm. With `loose`,
-- also true when they share one of their space-separated names - but never
-- when both are complete two-part names, since "Aelin Frost" and "Aelin
-- Stormrage" are different players.
function Util.namesMatch(a, b, loose)
    if (type(a) ~= "string" or type(b) ~= "string") then return false; end

    if (string.lower(Util.stripRealm(a)) == string.lower(Util.stripRealm(b))) then
        return true;
    end
    if (not loose) then return false; end

    local partsA, partsB = nameParts(a), nameParts(b);
    if (#partsA > 1 and #partsB > 1) then return false; end

    for _, partA in ipairs(partsA) do
        for _, partB in ipairs(partsB) do
            if (partA == partB) then return true; end
        end
    end

    return false;
end

-- Returns a map of base-name -> class token ("WARRIOR", "MAGE", ...) for
-- everyone currently in our group (raid, party, or just ourselves if solo).
-- The class is false when it isn't known yet, so membership can be tested
-- with `~= nil` without a missing class hiding the player.
function Util.groupMembers()
    local members = {};
    local function add(name, classFile)
        if (name and not Util.isSecret(name)) then
            members[Util.stripRealm(name)] = classFile or false;
        end
    end

    if (IsInRaid()) then
        for i = 1, GetNumGroupMembers() do
            local name, _, _, _, _, classFile = GetRaidRosterInfo(i);
            add(name, classFile);
        end
    elseif (IsInGroup()) then
        add(UnitName("player"), select(2, UnitClass("player")));

        for i = 1, (GetNumGroupMembers() or 1) - 1 do
            local unit = "party" .. i;
            if (UnitExists(unit)) then
                add(UnitName(unit), select(2, UnitClass(unit)));
            end
        end
    else
        add(UnitName("player"), select(2, UnitClass("player")));
    end

    return members;
end

-- Finds `name` in a groupMembers() map: the full name first, then any
-- roster entry sharing one of its names (used when the roster and the source
-- of `name` disagree on full-vs-half). Returns the roster's own name and the
-- class token (nil while unknown), or nil when nobody matches - or when
-- several people share a name half, since guessing would mis-colour someone.
function Util.findMember(members, name)
    if (type(members) ~= "table" or type(name) ~= "string") then return nil; end

    local exact = Util.stripRealm(name);
    if (members[exact] ~= nil) then
        return exact, members[exact] or nil;
    end

    local found, foundClass, looseMatches = nil, nil, 0;
    for memberName, classFile in pairs(members) do
        if (Util.namesMatch(memberName, exact)) then
            return memberName, classFile or nil;
        elseif (Util.namesMatch(memberName, exact, true)) then
            found, foundClass = memberName, classFile or nil;
            looseMatches = looseMatches + 1;
        end
    end

    if (looseMatches == 1) then return found, foundClass; end

    return nil;
end

-- Class token for a player name, or nil when not in the group / unknown.
function Util.lookupClass(members, name)
    local _, classFile = Util.findMember(members, name);
    return classFile;
end

-- Resolves a player name (realm suffix ignored) to a unit token ("raid5",
-- "party2", "player") for someone in our group, or nil if they aren't in it.
-- Needed because InitiateTrade takes a unit token rather than a bare name.
function Util.unitTokenForName(name)
    if (type(name) ~= "string" or name == "") then return nil; end

    local units = { "player" };
    if (IsInRaid()) then
        for i = 1, GetNumGroupMembers() do table.insert(units, "raid" .. i); end
    elseif (IsInGroup()) then
        for i = 1, (GetNumGroupMembers() or 1) - 1 do table.insert(units, "party" .. i); end
    end

    -- Full-name match beats a shared-half match, so two characters who
    -- share one name never get confused with each other.
    for _, loose in ipairs({ false, true }) do
        for _, unit in ipairs(units) do
            if (UnitExists(unit) and Util.namesMatch(UnitName(unit), name, loose)) then
                return unit;
            end
        end
    end

    return nil;
end

-- Class-colored player name, e.g. "|cffc79c6eThrall|r". Falls back to white
-- if the class token is unknown.
function Util.classColoredName(name, classFile)
    local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile];
    if (color and color.colorStr) then
        return ("|c%s%s|r"):format(color.colorStr, name);
    end

    return name;
end

-- Rarity-colored item name, e.g. "|cff0070ddSulfuron Hammer|r", for callers
-- that only have a bare item name/id (no item link, which already carries
-- its own color codes). Falls back to white if quality is unknown.
function Util.qualityColoredItemName(name, quality)
    local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality];
    if (color and color.hex) then
        return ("%s%s|r"):format(color.hex, name);
    end

    return name;
end

-- Lowercase, space-separated class name (as used by softres.it/Gargul, e.g.
-- "death knight") -> WoW class token (e.g. "DEATHKNIGHT"), for
-- RAID_CLASS_COLORS lookups.
local CLASS_NAME_TO_TOKEN = {
    druid = "DRUID", hunter = "HUNTER", mage = "MAGE", paladin = "PALADIN",
    priest = "PRIEST", rogue = "ROGUE", shaman = "SHAMAN", warlock = "WARLOCK",
    warrior = "WARRIOR", ["death knight"] = "DEATHKNIGHT",
    ["demon hunter"] = "DEMONHUNTER", evoker = "EVOKER", monk = "MONK",
};

function Util.classNameToToken(className)
    if (not className) then return nil; end
    return CLASS_NAME_TO_TOKEN[string.lower(className)];
end

-- True when `value` is a secret value (the client hides chat text from
-- addons during chat lockdown - string operations on it throw).
function Util.isSecret(value)
    return issecretvalue(value);
end

-- Item-info wrappers. The bare GetItemInfo/GetItemIcon/GetItemQualityColor
-- globals no longer exist; the C_Item namespace versions have the same return
-- values, so every caller goes through these.
function Util.GetItemInfo(itemInfo)
    return C_Item.GetItemInfo(itemInfo);
end

-- Item quality (Enum.ItemQuality) for an item link/id/name, or nil while the
-- item isn't cached yet.
function Util.GetItemQuality(itemInfo)
    return (select(3, C_Item.GetItemInfo(itemInfo)));
end

function Util.GetItemIcon(itemID)
    return C_Item.GetItemIconByID(itemID);
end

function Util.GetItemQualityColor(quality)
    return C_Item.GetItemQualityColor(quality);
end

function Util.itemIDFromLink(itemLink)
    if (type(itemLink) ~= "string") then return nil; end
    local id = string.match(itemLink, "item:(%d+)");
    return id and tonumber(id) or nil;
end

function Util.isValidItemLink(itemLink)
    return type(itemLink) == "string" and string.match(itemLink, "item:%d+") ~= nil;
end

-- Shared shift/ctrl-click behavior for every item-icon button in the addon
-- (RollWindow, TradeQueueWindow, SoftResImport): shift-click inserts the
-- item's chat link into the open chat edit box, ctrl-click opens the
-- Dressing Room preview. Returns true if the click was one of those two, so
-- a caller with its own plain-click behavior (e.g. TradeQueueWindow's
-- row-click retry) knows to skip it instead of also firing.
function Util.HandleItemLinkClick(itemLink)
    if (not itemLink) then return false; end

    if (IsModifiedClick("CHATLINK")) then
        ChatFrameUtil.InsertLink(itemLink);
        return true;
    elseif (IsModifiedClick("DRESSUP")) then
        DressUpItemLink(itemLink);
        return true;
    end

    return false;
end

-- Chat channel to announce something to the current group, or nil when we
-- aren't in one at all. SendChatMessage(..., "PARTY") while solo throws
-- ERR_NOT_IN_GROUP, so every group announcement must check this first rather
-- than assuming "not in a raid" means "in a party" (`raidChannel` lets a
-- caller ask for "RAID_WARNING" instead of the default "RAID").
function Util.GroupChatChannel(raidChannel)
    if (IsInRaid()) then
        return raidChannel or "RAID";
    elseif (IsInGroup()) then
        return "PARTY";
    end

    return nil;
end

-- Resolve a logical channel ("GROUP" or an explicit distribution) into a
-- concrete AceComm distribution + recipient. Shared by every comm layer in
-- the addon so each doesn't need its own "not grouped -> whisper myself"
-- fallback.
function Util.GroupDistribution(channel, recipient)
    if (channel ~= "GROUP") then
        return channel, recipient;
    end

    if (IsInRaid()) then
        return "RAID", recipient;
    elseif (IsInGroup()) then
        return "PARTY", recipient;
    end

    return "WHISPER", UnitName("player");
end

function Util.playerFqn()
    local realm = GetRealmName();
    realm = realm and string.gsub(realm, "%s+", "") or "";
    return UnitName("player") .. "-" .. realm;
end

-- Wraps PlaySound in a pcall so a bad/unavailable sound kit ID never breaks
-- the caller (mirrors Gargul's GL:playSound in Utils/Misc.lua).
function Util.playSound(soundKitID, channel)
    pcall(PlaySound, soundKitID, channel or "SFX");
end

-- Same pcall-wrapped safety, for a bundled Media\Sounds\*.ogg file instead of
-- a built-in SOUNDKIT id.
function Util.playSoundFile(filePath, channel)
    pcall(PlaySoundFile, filePath, channel or "SFX");
end

-- Levenshtein edit distance between two strings (case-sensitive - callers
-- normalize case first, same convention as GL:levenshtein).
function Util.levenshtein(str1, str2)
    local len1, len2 = #str1, #str2;
    if (len1 == 0) then return len2; end
    if (len2 == 0) then return len1; end
    if (str1 == str2) then return 0; end

    local matrix = {};
    for i = 0, len1 do matrix[i] = { [0] = i }; end
    for j = 0, len2 do matrix[0][j] = j; end

    for i = 1, len1 do
        for j = 1, len2 do
            local cost = (str1:byte(i) == str2:byte(j)) and 0 or 1;
            matrix[i][j] = math.min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + cost);
        end
    end

    return matrix[len1][len2];
end
