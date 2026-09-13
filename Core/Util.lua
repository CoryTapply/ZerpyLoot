local ZL = ZerpyLoot;
local Util = ZL.Util;

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

-- Returns a map of base-name -> class token ("WARRIOR", "MAGE", ...) for
-- everyone currently in our group (raid, party, or just ourselves if solo).
function Util.groupMembers()
    local members = {};

    if (IsInRaid()) then
        for i = 1, GetNumGroupMembers() do
            local name, _, _, _, _, classFile = GetRaidRosterInfo(i);
            if (name) then
                members[Util.stripRealm(name)] = classFile;
            end
        end
    elseif (IsInGroup()) then
        local _, playerClass = UnitClass("player");
        members[Util.stripRealm(UnitName("player"))] = playerClass;

        for i = 1, (GetNumGroupMembers() or 1) - 1 do
            local unit = "party" .. i;
            if (UnitExists(unit)) then
                local name = UnitName(unit);
                local _, classFile = UnitClass(unit);
                if (name) then
                    members[Util.stripRealm(name)] = classFile;
                end
            end
        end
    else
        local _, playerClass = UnitClass("player");
        members[Util.stripRealm(UnitName("player"))] = playerClass;
    end

    return members;
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
        ChatEdit_InsertLink(itemLink);
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
