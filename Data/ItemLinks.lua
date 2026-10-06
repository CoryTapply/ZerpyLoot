--[[
Rebuilds `itemLink` from `itemString` for rows that arrive over the wire
without one cached locally (spec section 4.5) - LIVE_ROW, and later phases'
ROWS batches, only ever carry the item string, never the display link.
`itemID`/`itemIcon` come back synchronously via C_Item.GetItemInfoInstant
(done in Net/Codec.lua's DecodeRow, not here), but the full link needs the
item to be cached, which can take an async server round trip the first time
a given item is seen on this client.

Resolution is capped at 20 starts per frame (spec section 9.4), so a big
batch of never-before-seen items (a future backfill) can't spike
C_Item's request traffic all in one frame. That's a distinct throttle from
Sync/Scheduler.lua's time-budgeted work queue: issuing a
Item:ContinueOnItemLoad call is cheap regardless of how many items are still
loading server-side, so a time budget alone wouldn't cap it - hence this
module's own small dedicated frame, matching Sync/Gate.lua's "one small
frame per concern" convention.

Mirrors UI/LootHistoryWindow.lua's own tryResolveItem (its manual "Add Entry"
item lookup), which already uses the same Item:CreateFromItemID(...):Continue-
OnItemLoad(...) pattern this addon has established for async item lookups.
]]

local FL = ForeverLoot;
local ItemLinks = FL.Sync.ItemLinks;
local Util = FL.Util;

local MAX_PER_FRAME = 20;
local UNRESOLVED_WARN_DELAY = 30;

local queue = {}; -- FIFO of row tables waiting to start resolving
local driverFrame;

local function startResolve(row)
    local startedAt = GetTime();
    local itemString = "item:" .. row.itemString;

    -- CreateFromItemID(row.itemID) only triggers/awaits the cache load; the
    -- link itself is re-read from the full item STRING below, not the bare
    -- id, so the bonus ids/gems/enchants baked into row.itemString (the
    -- entire reason spec section 4.5 carries itemString on the wire) are
    -- preserved instead of rebuilding a generic, unmodified link.
    Item:CreateFromItemID(row.itemID):ContinueOnItemLoad(function()
        if (row.itemLink) then return; end -- already filled by some other path in the meantime

        local _, link = Util.GetItemInfo(itemString);
        if (not link) then return; end

        row.itemLink = link;
        FL.Sync.Debug.Log("ITEM", 2, "item info arrived for row %s · after %s", row.id, FL.Sync.Debug.FormatTime(GetTime() - startedAt));
        if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Refresh) then
            FL.UI.LootHistoryWindow.Refresh();
        end
    end);

    C_Timer.After(UNRESOLVED_WARN_DELAY, function()
        if (not row.itemLink) then
            FL.Sync.Debug.Warn("ITEM", "item info never arrived for row %s · item %d, waited %ds", row.id, row.itemID, UNRESOLVED_WARN_DELAY);
        end
    end);
end

--- Queues `row` (already stored) to have its itemLink rebuilt from
--- itemString asynchronously. No-op if it already has a link, or has
--- nothing usable to resolve one from (shouldn't happen for a row that
--- passed Net/Codec.lua's decode validation, but local/manual rows always
--- already have a link and should never be queued here).
---@param row table the full keyed history row (spec section 3.1)
function ItemLinks.Resolve(row)
    if (row.itemLink or not row.itemString or not row.itemID) then return; end
    FL.Sync.Debug.Log("ITEM", 2, "waiting on item info for row %s · item %d", row.id, row.itemID);
    table.insert(queue, row);
end

function ItemLinks.Init()
    driverFrame = CreateFrame("Frame");
    driverFrame:SetScript("OnUpdate", function()
        if (#queue == 0) then return; end
        local n = math.min(MAX_PER_FRAME, #queue);
        for _ = 1, n do
            startResolve(table.remove(queue, 1));
        end
    end);
end
