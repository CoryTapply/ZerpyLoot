--[[
Adds SoftRes reservation info and pending-trade status to item tooltips,
matching Gargul's presentation (Classes/SoftRes.lua:767-851,
Classes/AwardedLoot.lua:119-198): hard-reserves take precedence and suppress
soft-res lines; otherwise a "Reserved by" header plus one class-colored line
per unique reserver, with "(Nx)" for multiple reserves. Separately (and
regardless of reservation status), a "Pending Trade" section lists anyone
still owed this item from the trade queue.
]]

local ZL = ZerpyLoot;
local Tooltip = ZL.Tooltip;
local SoftRes = ZL.SoftRes;
local Trade = ZL.Trade;
local Util = ZL.Util;

local function addLines(tooltip, itemLink)
    if (not itemLink) then return false; end

    local itemID = Util.itemIDFromLink(itemLink);
    if (not itemID) then return false; end

    local hardReserve = SoftRes.GetHardReserveForItemID(itemID);
    if (hardReserve) then
        tooltip:AddLine(" ");
        tooltip:AddLine("|cFFcc2743This item is hard-reserved|r");
        if (hardReserve.reservedFor and hardReserve.reservedFor ~= "") then
            tooltip:AddLine(("|cFFcc2743For: %s|r"):format(hardReserve.reservedFor));
        end
        if (hardReserve.note and hardReserve.note ~= "") then
            tooltip:AddLine(("|cFFcc2743Note: %s|r"):format(hardReserve.note));
        end
        return true;
    end

    local reservations = SoftRes.GetReservationsForItemID(itemID);
    if (#reservations == 0) then return false; end

    tooltip:AddLine(" ");
    tooltip:AddLine("|cFFEFB8CDReserved by|r");

    for _, r in ipairs(reservations) do
        local classToken = Util.classNameToToken(SoftRes.GetPlayerClass(r.name));
        local text = Util.classColoredName(r.name, classToken);
        if (r.count > 1) then
            text = ("%s (%dx)"):format(text, r.count);
        end
        tooltip:AddLine(text);
    end

    return true;
end

-- Shows who still owes a trade for this item, for items awarded via a
-- roll-off but not yet confirmed traded (ZL.Trade.Queue). Independent of
-- reservation status, so it's called unconditionally rather than folded into
-- addLines()'s hard-reserve early-return above.
local function addTradeQueueLines(tooltip, itemID)
    local matches = {};
    for _, entry in ipairs(Trade.Queue) do
        if (entry.itemID == itemID) then
            table.insert(matches, entry);
        end
    end
    if (#matches == 0) then return false; end

    tooltip:AddLine(" ");
    tooltip:AddLine("|cff8865ffPending Trade|r");

    for _, entry in ipairs(matches) do
        -- winnerClass is a WoW class token, recorded at award time; fall back
        -- to the current group roster for older queue entries that predate it.
        local classFile = entry.winnerClass or Util.groupMembers()[Util.stripRealm(entry.winner)];
        local text = Util.classColoredName(entry.winner, classFile);

        local detail = entry.classification or "?";
        if (entry.rollAmount) then
            text = ("%s | Roll: %d [%s]"):format(text, entry.rollAmount, detail);
        else
            text = ("%s | [%s]"):format(text, detail);
        end

        tooltip:AddLine("    " .. text);
    end

    return true;
end

local function onTooltipSetItem(tooltip)
    local _, itemLink = tooltip:GetItem();
    if (not itemLink) then return; end

    local itemID = Util.itemIDFromLink(itemLink);
    if (not itemID) then return; end

    local addedReserveLines = addLines(tooltip, itemLink);
    local addedTradeLines = addTradeQueueLines(tooltip, itemID);

    if (addedReserveLines or addedTradeLines) then
        tooltip:AddLine(" ");
    end
end

function Tooltip.Init()
    GameTooltip:HookScript("OnTooltipSetItem", onTooltipSetItem);

    if (ItemRefTooltip) then
        ItemRefTooltip:HookScript("OnTooltipSetItem", onTooltipSetItem);
    end
end
