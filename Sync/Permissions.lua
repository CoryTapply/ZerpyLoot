--[[
Delete/pin policy (spec section 11, policy "officers"). Caches each guild
member's rank index from GetGuildRosterInfo, refreshed on GUILD_ROSTER_UPDATE
and requested fresh with C_GuildInfo.GuildRoster() at login.

LootCouncilRoster.GuildInfoForUnit also reads this cache (RankOf/
RankNameOf) as its fallback for own-guild raid members too far away for
GetGuildInfo(unit) to answer, and LootCouncilRoster.IsGuildOfficer uses
IsOfficerRank so the Loot Council page ("Select Officers", "Always include
guild officers") counts the same ranks as officer that CanDelete/CanPin do.

Keyed on Util.stripRealm(name), matching every existing name-keyed table in
this addon (LootCouncil.Roster, history rows' awardedBy/awardedTo, ...) -
GetGuildRosterInfo returns realm-qualified names for connected-realm members,
but stored names here are always bare.

Which ranks count as officer comes from the guild's own rank permissions:
a rank is officer if C_GuildInfo.GuildControlGetRankFlags marks it able to
speak in officer chat (flag 4), so guilds with several officer ranks work
without configuration. Rank flags are guild-wide, so every member's client
agrees on the officer set when validating peers' deletes/pins. If the flags
aren't available, Constants.OFFICER_RANK_MAX is the fallback cutoff.
]]

local FL = ForeverLoot;
local Permissions = FL.Sync.Permissions;
local Util = FL.Util;

local rankByName = {};  -- [strippedName] = rankIndex (0 = guild master, lower = higher rank)
local rankNameByName = {}; -- [strippedName] = guild rank name ("Officer", ...), for LootCouncilRoster.GuildInfoForUnit
local classByName = {}; -- [strippedName] = classFileName token ("WARRIOR", ...), for Data/Store.lua's test-row generator
local officerRank = {}; -- [rankIndex] = true for ranks counted as officer

local RANK_FLAG_OFFICER_CHAT_SPEAK = 4;

local function rankIsOfficer(rankIndex)
    if (rankIndex == 0) then return true; end -- guild master
    if (C_GuildInfo and C_GuildInfo.GuildControlGetRankFlags) then
        local flags = C_GuildInfo.GuildControlGetRankFlags(rankIndex + 1); -- rankOrder is 1-based
        if (type(flags) == "table" and next(flags) ~= nil) then
            return flags[RANK_FLAG_OFFICER_CHAT_SPEAK] == true;
        end
    end
    return rankIndex <= FL.Sync.Constants.OFFICER_RANK_MAX;
end

local function refreshOfficerRanks()
    wipe(officerRank);
    local numRanks = GuildControlGetNumRanks and GuildControlGetNumRanks() or 0;
    for rankIndex = 0, numRanks - 1 do
        if (rankIsOfficer(rankIndex)) then officerRank[rankIndex] = true; end
    end
end

local function refreshRoster()
    wipe(rankByName);
    wipe(rankNameByName);
    wipe(classByName);
    local n = GetNumGuildMembers and GetNumGuildMembers() or 0;
    for i = 1, n do
        local name, rankName, rankIndex, _, _, _, _, _, _, _, classFileName = GetGuildRosterInfo(i);
        if (name) then
            local stripped = Util.stripRealm(name);
            rankByName[stripped] = rankIndex;
            rankNameByName[stripped] = rankName;
            classByName[stripped] = classFileName;
        end
    end
    refreshOfficerRanks();
end

function Permissions.RankOf(name)
    return rankByName[Util.stripRealm(name or "")];
end

--- The guild rank name GetGuildRosterInfo reported for `name`, or nil if
--- the name isn't a cached guild member.
function Permissions.RankNameOf(name)
    return rankNameByName[Util.stripRealm(name or "")];
end

--- The class token ("WARRIOR", "MAGE", ...) GetGuildRosterInfo reported for
--- `name`, or nil if the name isn't a cached guild member. Used by
--- Data/Store.lua's test-row generator so fake rows get real responder
--- classes instead of leaving them nil.
function Permissions.ClassOf(name)
    return classByName[Util.stripRealm(name or "")];
end

--- Whether guild rank `rankIndex` (0 = guild master) counts as officer.
function Permissions.IsOfficerRank(rankIndex)
    return rankIndex ~= nil and officerRank[rankIndex] == true;
end

function Permissions.CanDelete(name)
    return Permissions.IsOfficerRank(Permissions.RankOf(name));
end

-- Spec section 10.5: "The same policy applies to manual pins."
function Permissions.CanPin(name)
    return Permissions.CanDelete(name);
end

--- Whether the guild roster cache has loaded at all.
function Permissions.HasRoster()
    return next(rankByName) ~= nil;
end

--- Whether `name` is in our guild, for refusing GUILD-scope history traffic
--- from anyone else (another guild's member reaching us by whisper). True
--- while the roster hasn't loaded, so a cold cache never blocks sync.
function Permissions.IsGuildPeer(name)
    if (not Permissions.HasRoster()) then return true; end
    return rankByName[Util.stripRealm(name or "")] ~= nil;
end

--- Bare names of every currently-cached guild member - used by Data/Store.lua's
--- test-row generator to pick realistic responders.
function Permissions.GuildMemberNames()
    local names = {};
    for name in pairs(rankByName) do table.insert(names, name); end
    return names;
end

function Permissions.Init()
    local frame = CreateFrame("Frame");
    frame:RegisterEvent("GUILD_ROSTER_UPDATE");
    frame:RegisterEvent("GUILD_RANKS_UPDATE");
    frame:SetScript("OnEvent", refreshRoster);

    if (C_GuildInfo and C_GuildInfo.GuildRoster) then
        C_GuildInfo.GuildRoster(); -- request fresh data; GUILD_ROSTER_UPDATE fires when it lands
    end
    refreshRoster(); -- populate with whatever's already cached, so CanDelete works immediately
end
