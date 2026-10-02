--[[
Delete/pin policy (spec section 11, policy "officers"). Caches each guild
member's rank index from GetGuildRosterInfo, refreshed on GUILD_ROSTER_UPDATE
and requested fresh with C_GuildInfo.GuildRoster() at login.

GetGuildRosterInfo/GetNumGuildMembers are new to this addon - the existing
"officer" convention (LootCouncilRoster.SelectOfficers) is built on the
unit-token-based GetGuildInfo(unit) instead, which only works for a
currently-visible/grouped unit and can't answer "is this arbitrary stored
name an officer" for someone offline or out of the group. This module is
also a separate concept from Core/Settings.lua's
lootCouncil.officerRankThreshold (an unrelated "Select Officers" convenience
setting for the council-roster UI) - CanDelete/CanPin compare against
Constants.OFFICER_RANK_MAX, the guild-wide sync policy constant, not that
setting.

Keyed on Util.stripRealm(name), matching every existing name-keyed table in
this addon (LootCouncil.Roster, history rows' awardedBy/awardedTo, ...) -
GetGuildRosterInfo returns realm-qualified names for connected-realm members,
but stored names here are always bare.
]]

local FL = ForeverLoot;
local Permissions = FL.Sync.Permissions;
local Util = FL.Util;

local rankByName = {};  -- [strippedName] = rankIndex (0 = guild master, lower = higher rank)
local classByName = {}; -- [strippedName] = classFileName token ("WARRIOR", ...), for Data/Store.lua's test-row generator

local function refreshRoster()
    wipe(rankByName);
    wipe(classByName);
    local n = GetNumGuildMembers and GetNumGuildMembers() or 0;
    for i = 1, n do
        local name, _, rankIndex, _, _, _, _, _, _, _, classFileName = GetGuildRosterInfo(i);
        if (name) then
            local stripped = Util.stripRealm(name);
            rankByName[stripped] = rankIndex;
            classByName[stripped] = classFileName;
        end
    end
end

function Permissions.RankOf(name)
    return rankByName[Util.stripRealm(name or "")];
end

--- The class token ("WARRIOR", "MAGE", ...) GetGuildRosterInfo reported for
--- `name`, or nil if the name isn't a cached guild member. Used by
--- Data/Store.lua's test-row generator so fake rows get real responder
--- classes instead of leaving them nil.
function Permissions.ClassOf(name)
    return classByName[Util.stripRealm(name or "")];
end

function Permissions.CanDelete(name)
    local rank = Permissions.RankOf(name);
    return rank ~= nil and rank <= FL.Sync.Constants.OFFICER_RANK_MAX;
end

-- Spec section 10.5: "The same policy applies to manual pins."
function Permissions.CanPin(name)
    return Permissions.CanDelete(name);
end

--- Bare names of every currently-cached guild member - used by Data/Store.lua's
--- test-row generator to pick realistic responders.
function Permissions.GuildMemberNames()
    local names = {};
    for name in pairs(rankByName) do table.insert(names, name); end
    return names;
end

function Permissions.Status()
    local me = Util.UnitName("player");
    return {
        policy = FL.Sync.Constants.DELETE_POLICY,
        me = me,
        rank = Permissions.RankOf(me),
        canDelete = Permissions.CanDelete(me),
    };
end

function Permissions.Init()
    local frame = CreateFrame("Frame");
    frame:RegisterEvent("GUILD_ROSTER_UPDATE");
    frame:SetScript("OnEvent", refreshRoster);

    if (C_GuildInfo and C_GuildInfo.GuildRoster) then
        C_GuildInfo.GuildRoster(); -- request fresh data; GUILD_ROSTER_UPDATE fires when it lands
    end
    refreshRoster(); -- populate with whatever's already cached, so CanDelete works immediately
end
