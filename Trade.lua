--[[
Trade automation: given a player name and an item link, open a trade with
them and place the item in it. Modeled directly on Gargul's own
Classes/TradeWindow.lua / Classes/AwardedLoot.lua, since trading touches
semi-protected client behavior and that's a known-working reference:

- InitiateTrade(name) accepts a plain player name, no unit-token resolution
  needed. There's no CheckInteractDistance anywhere in Gargul either -
  failure (out of range, player not found) is inferred purely from the
  native TRADE_SHOW event not firing within ~1 second (Gargul's own timeout
  constant).
- Once TRADE_SHOW fires, the trade partner's name is read via Util.UnitName("NPC")
  - "NPC" is the real unit token WoW exposes for "the other side of an active
  trade", regardless of them being a player. Goes through the wrapper (not a
  bare UnitName call) since Forever's UnitName returns first/last name as two
  separate values that need combining - see Core/Util.lua.
- Items are placed with UseContainerItem(bag, slot) while the trade window
  is open (WoW auto-routes a "used" item into the next free trade slot) -
  NOT PickupContainerItem + a cursor drop.
- An item can "bounce" back out of the trade slot right after being added;
  a single ITEM_UNLOCKED-triggered re-attempt within Gargul's own 0.5s
  bounce window covers that.
- Finalizing the trade (clicking "Trade") is never done here, on purpose -
  Gargul's own code documents that Blizzard blocks the equivalent action
  "for security reasons"; that step is always left to the human.
]]

local FL = ForeverLoot;
local Trade = FL.Trade;
local Util = FL.Util;

local TRADE_OPEN_TIMEOUT = 1;
local BOUNCE_WINDOW = 0.6; -- slightly past Gargul's own 0.5s bounce window
local ERR_TRADE_COMPLETE = ERR_TRADE_COMPLETE;

-- Classic has no native "trade completed" event; like Gargul
-- (Classes/TradeWindow.lua:362-374), the only real signal is the stock
-- UI_INFO_MESSAGE system message matching ERR_TRADE_COMPLETE. TRADE_CLOSED
-- fires on both a completed AND a cancelled trade with no way to tell them
-- apart, so it must never be treated as success on its own.
local activeSession = { partner = nil, placedItemLinks = {} };

local function containerItemID(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot);
    return info and info.itemID or nil;
end

local function findItemInBags(itemID)
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0;
        for slot = 1, numSlots do
            if (containerItemID(bag, slot) == itemID) then
                return bag, slot;
            end
        end
    end

    return nil;
end

-- Shared queue of items that couldn't be auto-traded (out of range, trade
-- window didn't open, or we simply didn't have the item at award time).
-- {itemLink, itemIcon, itemID, winner, rollOffId, rollAmount, classification, winnerClass}
--
-- Backed directly by FL.DB.tradeQueue (see Trade.Init) - every entry here is
-- plain serializable data (strings/numbers, no frames or closures), so
-- pointing this at the saved-variable table itself means every existing
-- table.insert/table.remove call below already persists it, with no separate
-- save step needed. Defaults to a plain local table here since FL.DB isn't
-- set until ADDON_LOADED, well before Trade.Init reassigns it.
Trade.Queue = {};

function Trade.QueueAdd(entry)
    table.insert(Trade.Queue, entry);

    -- Keep an already-open trade queue window in sync immediately - without
    -- this, an item added while the window happened to be open (or was open
    -- from an earlier award) simply wouldn't appear until manually reopened,
    -- which looks indistinguishable from "never got queued at all."
    if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Refresh) then
        FL.UI.TradeQueueWindow.Refresh();
    end
end

-- Removal is by object identity, not index: Trade.AttemptTrade is
-- asynchronous (up to ~1.6s), so an index captured when a retry starts can
-- point at the wrong entry by the time its callback fires if the queue
-- changed shape in the meantime (another retry finished first, or a new
-- item got queued).
function Trade.QueueRemoveEntry(entry)
    for i, queued in ipairs(Trade.Queue) do
        if (queued == entry) then
            table.remove(Trade.Queue, i);
            return true;
        end
    end

    return false;
end

-- Drops any queued entry from a specific roll-off - used when that roll-off's
-- item is re-awarded to someone else, so a stale "still owes this to the old
-- winner" entry can't linger after the decision changed. Scoped by roll-off
-- id rather than itemLink so a second, separate roll-off for an identical
-- item (it dropped twice) queues its own independent entry instead of wiping
-- out an earlier roll-off's still-pending one just because the item matches.
function Trade.QueueRemoveByRollOff(rollOffId)
    for i = #Trade.Queue, 1, -1 do
        if (Trade.Queue[i].rollOffId == rollOffId) then
            table.remove(Trade.Queue, i);
        end
    end
end

--- Attempt to trade `itemLink` to `playerName`. Always calls onResult(success,
--- reason) exactly once, synchronously or asynchronously.
---@param playerName string
---@param itemLink string
---@param onResult fun(success: boolean, reason: string|nil)
function Trade.AttemptTrade(playerName, itemLink, onResult)
    onResult = onResult or function() end;

    local itemID = Util.itemIDFromLink(itemLink);

    -- NOTE: `bag, slot = itemID and findItemInBags(itemID) or nil` would
    -- silently discard `slot` - a multi-return call used as an `and`/`or`
    -- operand gets truncated to its first return value in Lua.
    local bag, slot;
    if (itemID) then
        bag, slot = findItemInBags(itemID);
    end

    if (not bag) then
        onResult(false, "You don't have this item in your bags.");
        return;
    end

    local tradeAlreadyOpen = TradeFrame and TradeFrame:IsShown();
    local currentPartner = tradeAlreadyOpen and Util.UnitName("NPC");

    if (tradeAlreadyOpen and not (currentPartner and Util.namesMatch(currentPartner, playerName, true))) then
        onResult(false, "You're already trading with someone else.");
        return;
    end

    local finished = false;
    local watchFrame = CreateFrame("Frame");
    watchFrame:RegisterEvent("ITEM_UNLOCKED");
    if (not tradeAlreadyOpen) then
        watchFrame:RegisterEvent("TRADE_SHOW");
    end

    local timeoutTimer;

    local function finish(success, reason)
        if (finished) then return; end
        finished = true;
        watchFrame:UnregisterAllEvents();
        onResult(success, reason);
    end

    local function placeItem()
        if (TradeFrame and TradeFrame:IsShown()) then
            C_Container.UseContainerItem(bag, slot);
        end
    end

    -- Shared by both the "trade window already open with this partner" path
    -- and the "just watched TRADE_SHOW fire for this partner" path: place the
    -- item, wait out the bounce window, then resolve success and record the
    -- item as actually part of this trade session (activeSession, kept by the
    -- persistent completion watcher below - that's what lets a later
    -- ERR_TRADE_COMPLETE know this item was really traded, not just queued).
    local function placeAndResolve()
        placeItem();

        C_Timer.After(BOUNCE_WINDOW, function()
            activeSession.placedItemLinks[itemLink] = true;
            finish(true);
        end);
    end

    -- The event handler is wired up before anything is placed or initiated,
    -- in both branches, so a bounce-back ITEM_UNLOCKED can never fire before
    -- OnEvent is listening for it.
    watchFrame:SetScript("OnEvent", function(_, event, ...)
        if (finished) then return; end

        if (event == "TRADE_SHOW") then
            local partner = Util.UnitName("NPC");
            if (not partner or not Util.namesMatch(partner, playerName, true)) then
                return; -- some other trade window opened, not ours - keep waiting
            end

            if (timeoutTimer) then timeoutTimer:Cancel(); end
            placeAndResolve();
        elseif (event == "ITEM_UNLOCKED") then
            local unlockedBag, unlockedSlot = ...;
            if (unlockedBag == bag and unlockedSlot == slot) then
                placeItem(); -- bounced back out of the trade slot - try once more
            end
        end
    end);

    if (tradeAlreadyOpen) then
        placeAndResolve();
    else
        -- InitiateTrade takes a unit token; the bare name is only a fallback
        -- for someone we can't find in the group, and may well be rejected.
        InitiateTrade(Util.unitTokenForName(playerName) or playerName);

        timeoutTimer = C_Timer.NewTimer(TRADE_OPEN_TIMEOUT, function()
            finish(false, "Trade window did not open.");
        end);
    end
end

-- Fires whenever a queued item is confirmed actually traded away (not just
-- placed). Used to notify the player and refresh the trade queue window.
local function onItemActuallyTraded(entry)
    print(("|cff8865ffForeverLoot|r Confirmed: %s traded to %s."):format(entry.itemLink or "?", entry.winner or "?"));

    if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Refresh) then
        FL.UI.TradeQueueWindow.Refresh();
    end
end

-- Persistent (not per-attempt) trade-session watcher: the only thing that's
-- allowed to remove an item from Trade.Queue, and only once ERR_TRADE_COMPLETE
-- actually fires for it. Kept separate from Trade.AttemptTrade's own per-call
-- watch frame, which only cares about opening the window and placing an item.
local function onTradeComplete()
    for i = #Trade.Queue, 1, -1 do
        local entry = Trade.Queue[i];
        if (activeSession.partner
            and Util.namesMatch(entry.winner, activeSession.partner, true)
            and activeSession.placedItemLinks[entry.itemLink]) then
            table.remove(Trade.Queue, i);
            onItemActuallyTraded(entry);
        end
    end
end

function Trade.Init()
    FL.DB.tradeQueue = FL.DB.tradeQueue or {};
    Trade.Queue = FL.DB.tradeQueue;

    -- Queued items persist in the saved variables across a login/reload, so
    -- surface the window immediately instead of leaving already-owed trades
    -- silently sitting in the queue until it's manually opened.
    if (#Trade.Queue > 0 and FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Show) then
        FL.UI.TradeQueueWindow.Show();
    end

    local sessionFrame = CreateFrame("Frame");
    sessionFrame:RegisterEvent("TRADE_SHOW");
    sessionFrame:RegisterEvent("UI_INFO_MESSAGE");

    -- NOTE: deliberately NOT registering TRADE_CLOSED. Confirmed directly in
    -- Gargul's own Classes/TradeWindow.lua ("We don't want resetState to
    -- trigger since TRADE_CLOSED is fired before TRADE_COMPLETED"): for a
    -- real successful trade, the native TRADE_CLOSED event fires BEFORE the
    -- UI_INFO_MESSAGE/ERR_TRADE_COMPLETE completion signal, not after.
    -- Resetting activeSession on TRADE_CLOSED would wipe the partner/placed-
    -- items data the completion check below still needs moments later,
    -- silently making every successful trade look uncompleted. Instead,
    -- session state is simply left alone until the next TRADE_SHOW (this
    -- trade retrying, or an unrelated new one) naturally starts a fresh one -
    -- a cancelled trade (no completion message ever arrives) just leaves it
    -- stale until then, which is harmless since nothing else can trigger a
    -- spurious ERR_TRADE_COMPLETE in the meantime.
    sessionFrame:SetScript("OnEvent", function(_, event, ...)
        if (event == "TRADE_SHOW") then
            activeSession.partner = Util.UnitName("NPC");
            activeSession.placedItemLinks = {};
        elseif (event == "UI_INFO_MESSAGE") then
            local _, message = ...;
            if (message == ERR_TRADE_COMPLETE) then
                onTradeComplete();
            end
        end
    end);
end
