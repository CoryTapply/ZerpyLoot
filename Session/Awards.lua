--[[
Non-UI candidate-list/sort/partition logic for the "Review and Award" window
(UI/AwardWindow.lua). No UI code and no comm code here - LootCouncil.lua
still owns all actual state mutation and network traffic (SubmitResponse/
ToggleVote/AwardItem, the comm handlers); this module only reads
LootCouncil.CurrentSession and derives view-model data + delegates permission
checks and mutating calls back to LootCouncil.lua's own functions, so
AwardWindow.lua itself stays purely presentational.
]]

local FL = ForeverLoot;
local LootCouncil = FL.LootCouncil;
local Util = FL.Util;
local Constants = FL.Constants;

FL.Awards = FL.Awards or {};
local Awards = FL.Awards;

-- Response id -> its index in Constants.LOOT_COUNCIL_RESPONSES, i.e. the
-- table's sort order (Major, Minor, Offspec, Mog, Pass) - the SAME order
-- raiders see the response buttons in (UI/RespondWindow.lua). Not
-- user-configurable yet, so this is effectively hardcoded to match.
local RESPONSE_ORDER_BY_ID = {};
for i, entry in ipairs(Constants.LOOT_COUNCIL_RESPONSES) do
    RESPONSE_ORDER_BY_ID[entry.id] = i;
end

--------------------------------------------------------------------------
-- Candidate list (the main panel's table rows)
--------------------------------------------------------------------------

--- This item's index (1..#LOOT_COUNCIL_RESPONSES) in the response option
--- order, or math.huge for an unrecognized id so it sorts last instead of
--- erroring.
---@param responseId string
function Awards.ResponseOrder(responseId)
    return RESPONSE_ORDER_BY_ID[responseId] or math.huge;
end

--- The UI.Colors.responses entry for `responseId`, or its `default` fallback.
---@param responseId string
function Awards.ResponseColor(responseId)
    local Colors = FL.UI.Colors;
    return Colors.responses[responseId] or Colors.responses.default;
end

-- Placeholder candidate handed out below for a group member who hasn't
-- responded to this item yet - shaped like a real candidate entry (every
-- field paintRow/EquippedIcons/VoteOrder read) but with an empty/neutral
-- value for each, so the row renders as an unanswered "Awaiting Response"
-- pill instead of nil-erroring.
local function awaitingCandidate()
    return {
        response = Constants.LOOT_COUNCIL_AWAITING_RESPONSE_ID,
        note = "",
        equipped = {},
        approvals = {},
        voteOrder = {},
    };
end

--- Every player currently in the party/raid, plus anyone who responded to
--- `item` and has since left group (so a response never disappears once
--- given). Sorted by response option order, then by arrival order within
--- the same response (arrival order is a stable local tiebreak - Lua's
--- table.sort isn't stable - since LootCouncil.lua stamps
--- candidate.arrivalIndex once, the first time each candidate responds),
--- then alphabetically by full name (case-insensitive) as the final
--- tiebreak. Voting NEVER factors into this order - a row only moves when a
--- response actually arrives/changes or someone joins/leaves group. Group
--- members who haven't responded yet get a synthetic
--- Constants.LOOT_COUNCIL_AWAITING_RESPONSE_ID candidate (awaitingCandidate
--- above); Awards.ResponseOrder returns math.huge for that unrecognized id,
--- which is what sorts every "awaiting" row after every real response
--- without any special-casing here.
---
--- Class comes from the live roster when the candidate is still in group
--- (keeps a recent name change/relog's class correct), falling back to
--- candidate.class (sent explicitly in the response payload for exactly
--- this reason - see docs/LOOT_COUNCIL_PLAN.md §2) for a responder who has
--- since left the group.
---@param item table a LootCouncil.CurrentSession.items[i] entry
---@return { name: string, class: string, candidate: table }[]
function Awards.BuildCandidateList(item)
    local members = Util.groupMembers();
    local out = {};
    local seen = {};

    for name, classFile in pairs(members) do
        local candidate = item.candidates[name] or awaitingCandidate();
        table.insert(out, { name = name, class = classFile or candidate.class, candidate = candidate });
        seen[name] = true;
    end

    for name, candidate in pairs(item.candidates) do
        if (not seen[name]) then
            table.insert(out, { name = name, class = candidate.class, candidate = candidate });
        end
    end

    table.sort(out, function(a, b)
        local aOrder = Awards.ResponseOrder(a.candidate.response);
        local bOrder = Awards.ResponseOrder(b.candidate.response);
        if (aOrder ~= bOrder) then
            return aOrder < bOrder;
        end
        local aArrival = a.candidate.arrivalIndex or math.huge;
        local bArrival = b.candidate.arrivalIndex or math.huge;
        if (aArrival ~= bArrival) then
            return aArrival < bArrival;
        end
        local aName, bName = string.lower(a.name), string.lower(b.name);
        if (aName ~= bName) then
            return aName < bName;
        end
        return a.name < b.name; -- stable tiebreak for names differing only in case
    end);

    return out;
end

--- Ordered {slot, link} pairs for a candidate's equipped-item snapshot
--- (candidate.equipped, slot id -> link), sorted by slot id purely so the
--- ring/trinket/weapon pair always renders in a stable left-to-right order.
---@param candidate table
function Awards.EquippedIcons(candidate)
    local equipped = (candidate and candidate.equipped) or {};
    local slots = {};
    for slot in pairs(equipped) do
        table.insert(slots, slot);
    end
    table.sort(slots);

    local out = {};
    for _, slot in ipairs(slots) do
        table.insert(out, { slot = slot, link = equipped[slot] });
    end
    return out;
end

--- Names who voted to approve `candidate`, in the order they voted (see
--- LootCouncil.lua's updateVoteOrder). Never nil.
---@param candidate table
function Awards.VoteOrder(candidate)
    return (candidate and candidate.voteOrder) or {};
end

--------------------------------------------------------------------------
-- Item list (the left panel's Unassigned/Assigned grids)
--------------------------------------------------------------------------

--- Splits `Session.items` into unassigned/assigned arrays, each keeping the
--- items' original session order, plus the counts the left panel's header
--- and progress bar need.
---@param Session table LootCouncil.CurrentSession
---@return table unassigned, table assigned, number assignedCount, number totalCount
function Awards.PartitionItems(Session)
    local unassigned, assigned = {}, {};
    if (not Session) then return unassigned, assigned, 0, 0; end

    for _, item in ipairs(Session.items) do
        if (item.awardedTo) then
            table.insert(assigned, item);
        else
            table.insert(unassigned, item);
        end
    end

    return unassigned, assigned, #assigned, #Session.items;
end

--- The next unassigned item after `fromItemSession`, wrapping around the
--- full session item list in session order. `direction` is 1 (next) or -1
--- (prev). Returns nil if no other unassigned item exists (including when
--- `fromItemSession` is itself the only unassigned item, since "next" must
--- mean a DIFFERENT item).
---@param Session table
---@param fromItemSession number
---@param direction 1|-1
function Awards.NextUnassignedItem(Session, fromItemSession, direction)
    if (not Session or not Session.items or #Session.items == 0) then return nil; end

    local count = #Session.items;
    local startIndex;
    for i, item in ipairs(Session.items) do
        if (item.session == fromItemSession) then startIndex = i; break; end
    end
    startIndex = startIndex or 1;

    local index = startIndex;
    for _ = 1, count do
        index = ((index - 1 + direction) % count) + 1;
        local item = Session.items[index];
        if (item and not item.awardedTo and item.session ~= fromItemSession) then
            return item.session;
        end
    end
    return nil;
end

--------------------------------------------------------------------------
-- Permission / mutation delegates - thin wrappers so AwardWindow.lua only
-- ever talks to FL.Awards, never reaches into LootCouncil.lua directly.
--------------------------------------------------------------------------

function Awards.CanVote(name, fqn)
    return LootCouncil.CanVote(name, fqn);
end

function Awards.CanAwardItems()
    return LootCouncil.CanAwardItems();
end

function Awards.ToggleVote(itemSession, targetPlayer)
    LootCouncil.ToggleVote(itemSession, targetPlayer);
end

function Awards.AwardItem(itemSession, playerName)
    LootCouncil.AwardItem(itemSession, playerName);
end
