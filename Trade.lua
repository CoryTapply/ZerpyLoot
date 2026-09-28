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
-- {id, itemLink, itemIcon, itemID, winner, rollOffId, rollSessionId, rollAmount, classification, winnerClass}
--
-- `id` is assigned by QueueAdd if the entry doesn't already have one - a
-- stable per-entry identity, needed once a single rollOffId can have more
-- than one queue entry (multi-copy roll awards - see RollTracker.lua). Not
-- persisted deliberately: it's regenerated fresh each session, which is fine
-- since queue entries are already short-lived by nature.
-- `rollSessionId` is only ever set by roll-off awards (an alias of
-- rollOffId, added so RollTracker's lookups read clearly); LootCouncil.lua's
-- entries simply don't have it, same as they don't have rollAmount.
--
-- Backed directly by FL.DB.tradeQueue (see Trade.Init) - every entry here is
-- plain serializable data (strings/numbers, no frames or closures), so
-- pointing this at the saved-variable table itself means every existing
-- table.insert/table.remove call below already persists it, with no separate
-- save step needed. Defaults to a plain local table here since FL.DB isn't
-- set until ADDON_LOADED, well before Trade.Init reassigns it.
Trade.Queue = {};

local nextEntryId = 0;

function Trade.QueueAdd(entry)
    if (not entry.id) then
        nextEntryId = nextEntryId + 1;
        entry.id = nextEntryId;
    end

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

-- Same idea as QueueRemoveByRollOff, but scoped to one winner within that
-- roll-off - used by a roll-off Reassign (RollTracker.ReassignItem), which
-- must drop only the specific winner(s) being replaced and leave any other
-- still-pending copies of the same roll-off untouched. Returns whether an
-- entry was actually found/removed, so the caller can tell "already traded
-- (auto-removed on completion)" and "manually removed from the Trade Queue
-- window" apart from "still here" - RollTracker distinguishes the first two
-- via its own tradedWinnerNames record (see OnQueueEntryTraded below).
function Trade.QueueRemoveByRollOffAndWinner(rollOffId, winnerName)
    for i = #Trade.Queue, 1, -1 do
        local entry = Trade.Queue[i];
        if (entry.rollOffId == rollOffId and Util.namesMatch(entry.winner, winnerName)) then
            table.remove(Trade.Queue, i);
            if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Refresh) then
                FL.UI.TradeQueueWindow.Refresh();
            end
            return true;
        end
    end

    return false;
end

-- Per-entry UI state (queued/busy/failed) for the trade queue window's row
-- display. Keyed by object identity on a WEAK table, deliberately not a field
-- on the entry itself - entries here are the literal FL.DB.tradeQueue rows
-- (see Trade.Queue above), so a plain field would get written into the saved
-- variables at next logout. This is purely transient UI state: it resets to
-- "queued" (the default GetEntryState returns for anything unset) on reload,
-- which is fine since nothing durable depends on it.
local entryState = setmetatable({}, { __mode = "k" });

function Trade.GetEntryState(entry)
    return entryState[entry] or "queued";
end

function Trade.SetEntryState(entry, state)
    entryState[entry] = state;
end

-- How many tradeable copies of an item this player is currently holding.
-- Reuses SessionItems' own bag scan (bound items with a tradeable-timer
-- remaining) rather than a plain bag count, since an already-BoP'd item past
-- its trade window couldn't be handed off anyway.
function Trade.CountTradeableInBags(itemID)
    if (not itemID or not FL.SessionItems or not FL.SessionItems.ScanBagsForTradeable) then
        return 0;
    end

    local count = 0;
    for _, link in ipairs(FL.SessionItems.ScanBagsForTradeable()) do
        if (Util.itemIDFromLink(link) == itemID) then
            count = count + 1;
        end
    end

    return count;
end

-- How many queue entries currently claim a copy of this item (traded or not
-- yet attempted - entries are only ever removed once actually traded or
-- manually deleted). Compared against Trade.CountTradeableInBags by the
-- award-another-copy popup to warn when there isn't a free copy left.
function Trade.CountQueuedForItem(itemID)
    local count = 0;
    for _, entry in ipairs(Trade.Queue) do
        if (entry.itemID == itemID) then
            count = count + 1;
        end
    end

    return count;
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

--- Same as Trade.AttemptTrade, but for a queued entry specifically: tracks its
--- busy/failed UI state (see entryState above) and notifies the trade queue
--- window at each step, on top of the identical underlying AttemptTrade call.
--- Used by both the window's own retry-click and the automatic attempt made
--- right after an award (RollTracker.lua/LootCouncil.lua), so both paths show
--- the same "Trading..." row state and status message.
---@param entry table one of Trade.Queue's own entries
---@param onResult fun(success: boolean, reason: string|nil)
function Trade.AttemptTradeForQueueEntry(entry, onResult)
    onResult = onResult or function() end;

    Trade.SetEntryState(entry, "busy");
    if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.NotifyAttemptStarted) then
        FL.UI.TradeQueueWindow.NotifyAttemptStarted(entry);
    end

    Trade.AttemptTrade(entry.winner, entry.itemLink, function(success, reason)
        if (not success) then
            Trade.SetEntryState(entry, "failed");
        end
        -- On success the item is only placed, not yet actually traded - stays
        -- "busy" until onItemActuallyTraded (below) confirms completion and
        -- removes the entry outright.

        if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.NotifyAttemptResult) then
            FL.UI.TradeQueueWindow.NotifyAttemptResult(entry, success, reason);
        end

        onResult(success, reason);
    end);
end

-- Fires whenever a queued item is confirmed actually traded away (not just
-- placed). Used to notify the player and refresh the trade queue window.
local function onItemActuallyTraded(entry)
    print(("|cff8865ffForeverLoot|r Confirmed: %s traded to %s."):format(entry.itemLink or "?", entry.winner or "?"));

    -- Roll-off awards want to know an entry was genuinely traded (as opposed
    -- to manually removed from the Trade Queue window), so a later Reassign
    -- can tell the two apart - see RollTracker.OnQueueEntryTraded. Only
    -- entries created by a roll-off award carry rollSessionId.
    if (entry.rollSessionId and FL.RollTracker and FL.RollTracker.OnQueueEntryTraded) then
        pcall(FL.RollTracker.OnQueueEntryTraded, entry);
    end

    if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.NotifySuccess) then
        FL.UI.TradeQueueWindow.NotifySuccess(entry);
    end
    if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Refresh) then
        FL.UI.TradeQueueWindow.Refresh();
    end
end

-- Persistent (not per-attempt) trade-session watcher: the only thing that's
-- allowed to remove an item from Trade.Queue, and only once ERR_TRADE_COMPLETE
-- actually fires for it. Kept separate from Trade.AttemptTrade's own per-call
-- watch frame, which only cares about opening the window and placing an item.
--
-- Removes at most ONE matching entry per completion event - a single trade
-- only ever completes once, but with multi-copy roll awards two queue
-- entries can now share the same winner+itemLink (e.g. the same player
-- awarded two copies), and removing every match here would wrongly drop both
-- on one real trade.
local function onTradeComplete()
    for i = #Trade.Queue, 1, -1 do
        local entry = Trade.Queue[i];
        if (activeSession.partner
            and Util.namesMatch(entry.winner, activeSession.partner, true)
            and activeSession.placedItemLinks[entry.itemLink]) then
            table.remove(Trade.Queue, i);
            onItemActuallyTraded(entry);
            return;
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
