--[[
Loot Council raid-roster grid data: which raiders sit in which of the 8 raid
subgroups, guild info for a raid-roster unit, and the "Select Officers"
bulk-select helper. Pure data - no frames - used by
UI/SettingsWindow/Pages/LootCouncil.lua. Kept in its own module (separate
from that UI file, and from LootCouncil.lua's own roster/session data) so
later loot-voting code can reuse the same grid-building logic without
depending on the settings window.
]]

local FL = ForeverLoot;
local Roster = FL.LootCouncilRoster;
local Util = FL.Util;

local MAX_GROUPS = 8;

--- Builds the raid-group grid data: which raiders currently sit in each of
--- the 8 raid subgroups, or - outside a raid - just group 1 for a party.
--- Solo/ungrouped still returns the player alone in group 1's first slot, so
--- the settings-page grid always has something to show.
---@return table { inRaid: boolean, inParty: boolean, groups: table<integer, {members: table[]}> }
function Roster.BuildGroups()
    local groups = {};
    for i = 1, MAX_GROUPS do
        groups[i] = { members = {} };
    end

    local inRaid = IsInRaid();
    local inParty = false;

    if (inRaid) then
        for i = 1, GetNumGroupMembers() do
            local name, _, subgroup, _, _, classFile = GetRaidRosterInfo(i);
            local unit = "raid" .. i;
            if (name and subgroup and groups[subgroup]) then
                if (UnitExists(unit)) then
                    name = Util.FullerName(name, Util.UnitName(unit));
                end
                if (name and not Util.isSecret(name)) then
                    table.insert(groups[subgroup].members, { name = name, classFile = classFile, unit = unit });
                end
            end
        end
    else
        inParty = IsInGroup();
        table.insert(groups[1].members,
            { name = Util.UnitName("player"), classFile = select(2, UnitClass("player")), unit = "player" });

        if (inParty) then
            for i = 1, (GetNumGroupMembers() or 1) - 1 do
                local unit = "party" .. i;
                if (UnitExists(unit)) then
                    table.insert(groups[1].members,
                        { name = Util.UnitName(unit), classFile = select(2, UnitClass(unit)), unit = unit });
                end
            end
        end
    end

    return { inRaid = inRaid, inParty = inParty, groups = groups };
end

--- guildName, guildRankName, guildRankIndex for a raid-roster unit token
--- (e.g. "raid3"), or nil if the unit doesn't exist or isn't in a guild we
--- can see. GetGuildInfo(unit) only answers for units the client has loaded
--- (nearby), so members of the player's OWN guild fall back to the guild
--- roster cache (Sync/Permissions.lua), which covers them at any distance.
--- Far-away members of other guilds still return nil.
---@param unit string
function Roster.GuildInfoForUnit(unit)
    if (not UnitExists(unit)) then return nil; end

    if (type(GetGuildInfo) ~= "function") then return nil; end

    local guildName, rankName, rankIndex = GetGuildInfo(unit);
    if (guildName) then return guildName, rankName, rankIndex; end

    local myGuildName = GetGuildInfo("player");
    if (not myGuildName) then return nil; end

    local name = Util.UnitName(unit);
    local rankIndex = FL.Sync.Permissions.RankOf(name);
    if (rankIndex == nil) then return nil; end
    return myGuildName, FL.Sync.Permissions.RankNameOf(name), rankIndex;
end

--- Whether `unit` is an officer of the player's OWN guild, using the same
--- officer-rank rules as history sync (Sync/Permissions.lua's
--- IsOfficerRank: the guild's own officer-chat rank permission). Officers of
--- other guilds never count.
---@param unit string
function Roster.IsGuildOfficer(unit)
    local myGuildName = (type(GetGuildInfo) == "function") and GetGuildInfo("player") or nil;
    if (not myGuildName) then return false; end
    local guildName, _, rankIndex = Roster.GuildInfoForUnit(unit);
    return guildName == myGuildName and FL.Sync.Permissions.IsOfficerRank(rankIndex);
end

--- Additive bulk-select for the Loot Council page's "Select Officers"
--- button: every grid member who is an officer of the player's own guild
--- (Roster.IsGuildOfficer) - nobody else, raid leader included. Never
--- removes anyone - council membership stays independent of raid/guild rank as a general model (see
--- docs/LOOT_COUNCIL_PLAN.md); this is just a one-time convenience seed the
--- player can still freely edit afterward by clicking members.
---@param groupsResult table result of Roster.BuildGroups()
---@return string[] fullNames
function Roster.SelectOfficers(groupsResult)
    local names, seen = {}, {};
    local function add(name)
        if (name and not seen[name]) then
            seen[name] = true;
            table.insert(names, name);
        end
    end

    for _, group in pairs(groupsResult.groups or {}) do
        for _, member in ipairs(group.members) do
            if (Roster.IsGuildOfficer(member.unit)) then
                add(member.name);
            end
        end
    end

    return names;
end
