--[[
Non-UI roll-list presentation logic for the roll window: sorts an active
roll-off's rolls and annotates each with its "xN" per-player ordinal and
whether the roller soft-reserved the item. Split out of UI/RollWindow.lua so
this sort/annotate logic isn't tangled with widget code. RollTracker.lua's
own roll storage/detection/comm is untouched - this only ever reads
RollTracker.CurrentRollOff.Rolls.
]]

local FL = ForeverLoot;
local RollSession = FL.RollSession;

-- MS+SR first, then OS+SR, then MS, then OS. A classification that isn't
-- exactly "MS" or "OS" (e.g. a raw "low-high" label for a nonstandard
-- bracket - see RollTracker.lua's classify()) buckets with OS, the same
-- fallback the window's old 3-tier sort used.
local function sortTier(classification, isSR)
    local isMS = classification == "MS";
    if (isMS and isSR) then return 1; end
    if (not isMS and isSR) then return 2; end
    if (isMS) then return 3; end
    return 4;
end

--- Builds the roll window's row list for `rollOff` (RollTracker.CurrentRollOff),
--- sorted MS+SR, OS+SR, MS, OS, ties broken by roll amount descending, then by
--- arrival order (each roll's own index in RollOff.Rolls, which is
--- append-only - table.sort isn't stable, so this is what keeps two
--- equal-tier equal-amount rolls from swapping places between refreshes).
---
--- Each row is a shallow copy of the underlying Rolls entry plus `isSR` and
--- `rollNumber` (this player's 1st/2nd/3rd... roll on this item so far).
--- Field names (`amount`/`classification`/`isSR`/`class`) intentionally match
--- what RollTracker.AwardItem's `rollData` param reads, so a row here can be
--- passed straight into AwardItem with no re-lookup against the original
--- Rolls entry.
---@param rollOff table|nil RollTracker.CurrentRollOff
---@return table[] rows
function RollSession.BuildRows(rollOff)
    if (not rollOff or not rollOff.Rolls) then return {}; end

    local rows = {};
    local countsByPlayer = {};
    for index, roll in ipairs(rollOff.Rolls) do
        countsByPlayer[roll.player] = (countsByPlayer[roll.player] or 0) + 1;

        rows[index] = {
            player = roll.player,
            class = roll.class,
            amount = roll.amount,
            min = roll.min,
            max = roll.max,
            time = roll.time,
            classification = roll.classification,
            isSR = FL.SoftRes ~= nil and FL.SoftRes.PlayerHasReservedItem(roll.player, rollOff.itemID) or false,
            rollNumber = countsByPlayer[roll.player],
            arrivalIndex = index,
        };
    end

    table.sort(rows, function(a, b)
        local tierA, tierB = sortTier(a.classification, a.isSR), sortTier(b.classification, b.isSR);
        if (tierA ~= tierB) then return tierA < tierB; end
        if (a.amount ~= b.amount) then return (a.amount or 0) > (b.amount or 0); end
        return a.arrivalIndex < b.arrivalIndex;
    end);

    return rows;
end
