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
--- the 8 raid subgroups, or - outside a raid - just group 1 for a party, or
--- nothing at all when solo/ungrouped.
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
    elseif (IsInGroup()) then
        inParty = true;
        table.insert(groups[1].members,
            { name = Util.UnitName("player"), classFile = select(2, UnitClass("player")), unit = "player" });

        for i = 1, (GetNumGroupMembers() or 1) - 1 do
            local unit = "party" .. i;
            if (UnitExists(unit)) then
                table.insert(groups[1].members,
                    { name = Util.UnitName(unit), classFile = select(2, UnitClass(unit)), unit = unit });
            end
        end
    end

    return { inRaid = inRaid, inParty = inParty, groups = groups };
end

--- guildName, guildRankName, guildRankIndex, isGuildLeader for a live unit
--- token (e.g. "raid3"), or nil if the unit doesn't exist, isn't in a guild,
--- or this client doesn't have GetGuildInfo.
---@param unit string
function Roster.GuildInfoForUnit(unit)
    if (type(GetGuildInfo) ~= "function" or not UnitExists(unit)) then return nil; end
    return GetGuildInfo(unit);
end

--- Additive bulk-select for the Loot Council page's "Select Officers"
--- button: the raid leader, plus every grid member who shares the player's
--- own guild and whose guild rank index is at or below
--- Settings.GetOfficerRankThreshold(). Never removes anyone - council
--- membership stays independent of raid/guild rank as a general model (see
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

    local myGuildName = (type(GetGuildInfo) == "function") and GetGuildInfo("player") or nil;
    local threshold = FL.Settings.GetOfficerRankThreshold();

    for _, group in pairs(groupsResult.groups or {}) do
        for _, member in ipairs(group.members) do
            if (UnitIsGroupLeader(member.unit)) then
                add(member.name);
            elseif (myGuildName) then
                local guildName, _, rankIndex = Roster.GuildInfoForUnit(member.unit);
                if (guildName == myGuildName and rankIndex and rankIndex <= threshold) then
                    add(member.name);
                end
            end
        end
    end

    return names;
end
