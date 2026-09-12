--[[
Roll-off sessions: alt+left-click a bag item to start one (Gargul-compatible
broadcast so real Gargul clients see it too), and/or observe a roll-off
started by anyone else (Gargul or ZerpyLoot).

Actual roll VALUES are never sent over addon comm by Gargul or by us - players
use the stock /roll command and the server broadcasts the result to everyone
as a CHAT_MSG_SYSTEM message matching the client's localized RANDOM_ROLL_RESULT
string. We parse that exactly the way Gargul does (see Classes/RollOff.lua).
]]

local ZL = ZerpyLoot;
local RollTracker = ZL.RollTracker;
local Constants = ZL.Constants;
local Util = ZL.Util;
local Comm = ZL.Comm;

local rollPattern;
local rollFrame;

RollTracker.CurrentRollOff = nil; -- set while a roll-off (ours or someone else's) is active
local stopTimerHandle;

-- Every roll-off gets a unique id, purely so a trade-queue entry can record
-- which roll-off it came from (see AwardItem below) - two separate roll-offs
-- for the same item (it dropped twice) must never be confused with each
-- other just because their itemLink strings happen to be identical.
local nextRollOffId = 0;

local function debugPrint(msg)
    if (Comm.debugEnabled) then
        print("|cff8865ffZerpyLoot|r " .. msg);
    end
end

--------------------------------------------------------------------------
-- Roll listening (CHAT_MSG_SYSTEM)
--------------------------------------------------------------------------

local function ensureRollFrame()
    if (rollFrame) then return; end

    rollFrame = CreateFrame("Frame");
    rollFrame:SetScript("OnEvent", function(_, _, message)
        RollTracker.ProcessRoll(message);
    end);
end

local function startListeningForRolls()
    ensureRollFrame();
    rollFrame:RegisterEvent("CHAT_MSG_SYSTEM");
end

local function stopListeningForRolls()
    if (rollFrame) then
        rollFrame:UnregisterEvent("CHAT_MSG_SYSTEM");
    end
end

-- Classify a (low, high) roll range against the active roll-off's brackets.
-- Mirrors Classes/RollOff.lua:889-899 (falls back to a generic "low-high"
-- label instead of Gargul's trackAll/BoostedRolls handling, out of scope here).
local function classify(low, high)
    local brackets = RollTracker.CurrentRollOff and RollTracker.CurrentRollOff.brackets or Constants.DEFAULT_BRACKETS;

    for _, bracket in pairs(brackets) do
        if (low == bracket[2] and high == bracket[3]) then
            return bracket[1];
        end
    end

    return ("%s-%s"):format(low, high);
end

function RollTracker.ProcessRoll(message)
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not RollOff.active) then
        return;
    end

    for roller, roll, low, high in string.gmatch(message, rollPattern) do
        roll = tonumber(roll) or 0;
        low = tonumber(low) or 0;
        high = tonumber(high) or 0;

        local rollerBase = Util.stripRealm(roller);
        local members = Util.groupMembers();
        local classFile = members[rollerBase];

        -- Only count rolls from people actually in our group (mirrors
        -- Classes/RollOff.lua:936-951 - rolls never include a realm suffix).
        if (members[rollerBase] ~= nil) then
            local classification = classify(low, high);

            table.insert(RollOff.Rolls, {
                player = rollerBase,
                class = classFile,
                amount = roll,
                min = low,
                max = high,
                time = GetServerTime(),
                classification = classification,
            });

            debugPrint(("ROLL %s rolls %d (%d-%d) [%s]"):format(rollerBase, roll, low, high, classification));

            if (ZL.UI.RollWindow and ZL.UI.RollWindow.Refresh) then
                ZL.UI.RollWindow.Refresh();
            end
        end
    end
end

--------------------------------------------------------------------------
-- Start / stop
--------------------------------------------------------------------------

-- Called locally by every client (initiator included) once a startRollOff
-- payload is processed - mirrors Classes/RollOff.lua:324-453, minus the
-- BoostedRolls/AutoRoll/TMB integrations which are out of scope here.
local function applyStart(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.time) ~= "number" or not content.item) then
        return;
    end

    if (stopTimerHandle) then
        stopTimerHandle:Cancel();
        stopTimerHandle = nil;
    end

    local itemID = Util.itemIDFromLink(content.item);
    local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(content.item);

    nextRollOffId = nextRollOffId + 1;

    RollTracker.CurrentRollOff = {
        active = true,
        id = nextRollOffId,
        initiatorFqn = Message.senderFqn,
        initiatorIsMe = Message.isSelf,
        item = content.item,
        itemID = itemID,
        itemName = itemName,
        itemIcon = itemIcon,
        time = math.floor(content.time),
        brackets = (type(content.SupportedRolls) == "table" and #content.SupportedRolls > 0) and content.SupportedRolls or Constants.DEFAULT_BRACKETS,
        startedAt = GetTime(),
        Rolls = {},
    };

    startListeningForRolls();

    local thisRollOff = RollTracker.CurrentRollOff;

    stopTimerHandle = C_Timer.NewTimer(thisRollOff.time, function()
        RollTracker.LocalStop();
    end);

    -- Only the initiator counts down "5,4,3,2,1" in chat as the timer winds
    -- down. C_Timer.After callbacks can't be cancelled, so each tick
    -- re-checks it's still the same, still-active roll-off before printing -
    -- that's what guards against a stale tick firing after an early stop or
    -- a new roll-off superseding this one.
    if (Message.isSelf) then
        for i = 5, 1, -1 do
            local delay = thisRollOff.time - i;
            if (delay >= 0) then
                C_Timer.After(delay, function()
                    if (RollTracker.CurrentRollOff == thisRollOff and thisRollOff.active) then
                        local channel = Util.GroupChatChannel();
                        if (channel) then
                            local text = i == 1 and "1 second to roll" or (i .. " seconds to roll");
                            pcall(SendChatMessage, text, channel);
                        end
                    end
                end);
            end
        end
    end

    Util.playSound(SOUNDKIT.RAID_WARNING);

    if (ZL.UI.RollWindow and ZL.UI.RollWindow.Show) then
        ZL.UI.RollWindow.Show();
    end

    debugPrint(("Roll-off started by %s for %s (%ds)"):format(Message.senderFqn or "?", content.item, content.time));
end

-- Stop tracking locally without broadcasting anything (natural timer expiry,
-- or in response to a validated remote stopRollOff broadcast).
function RollTracker.LocalStop()
    if (stopTimerHandle) then
        stopTimerHandle:Cancel();
        stopTimerHandle = nil;
    end

    -- Small leeway before we stop listening, in case of server lag/jitter
    -- (mirrors Classes/RollOff.lua:585-588, RollTracking.rollOffEndLeeway).
    C_Timer.After(1, stopListeningForRolls);

    if (RollTracker.CurrentRollOff) then
        RollTracker.CurrentRollOff.active = false;

        if (RollTracker.CurrentRollOff.initiatorIsMe) then
            local channel = Util.GroupChatChannel("RAID_WARNING");
            if (channel) then
                local ok = pcall(SendChatMessage, "Stop your rolls!", channel);
                if (not ok) then debugPrint("Could not announce roll stop (missing raid warning permission?)"); end
            end
        end
    end

    if (ZL.UI.RollWindow and ZL.UI.RollWindow.Refresh) then
        ZL.UI.RollWindow.Refresh();
    end
end

--- Broadcast a roll-off start. Any player can call this (mirrors Gargul's
--- alt+left-click flow); real Gargul clients in the group will pick it up
--- and open their own roll UI for it.
---@param itemLink string
---@param seconds number Must be >= 5
function RollTracker.StartRollOff(itemLink, seconds)
    seconds = tonumber(seconds);

    if (not Util.isValidItemLink(itemLink)) then
        print("|cff8865ffZerpyLoot|r Invalid item link.");
        return false;
    end

    if (not seconds or seconds < 5) then
        print("|cff8865ffZerpyLoot|r Timer needs to be 5 seconds or more.");
        return false;
    end

    Comm.Send(Constants.Actions.startRollOff, {
        item = itemLink,
        time = seconds,
        SupportedRolls = Constants.DEFAULT_BRACKETS,
    }, "GROUP");

    local startChannel = Util.GroupChatChannel("RAID_WARNING");
    if (startChannel) then
        local announce = ("You have %d seconds to roll on %s"):format(seconds, itemLink);
        pcall(SendChatMessage, announce, startChannel);
    end

    -- Announce SoftRes reservations for this item too, if we know of any (parity with Gargul).
    local reservedChannel = Util.GroupChatChannel();
    if (reservedChannel and ZL.SoftRes and ZL.SoftRes.GetReservationsForItemID) then
        local itemID = Util.itemIDFromLink(itemLink);
        local reservations = itemID and ZL.SoftRes.GetReservationsForItemID(itemID);
        if (reservations and #reservations > 0) then
            local names = {};
            for _, r in ipairs(reservations) do
                table.insert(names, r.count > 1 and ("%s (%dx)"):format(r.name, r.count) or r.name);
            end
            pcall(SendChatMessage, "This item was reserved by: " .. table.concat(names, ", "), reservedChannel);
        end
    end

    return true;
end

--- Explicitly end a roll-off early. Only meaningful if we're the initiator -
--- Comm.OnReceiveStop otherwise ignores stops from anyone but the initiator.
function RollTracker.StopRollOff()
    Comm.Send(Constants.Actions.stopRollOff, nil, "GROUP");
end

--------------------------------------------------------------------------
-- Award (right-click a roll row -> confirm -> announce + auto-trade)
--------------------------------------------------------------------------

--- Assign the current roll-off's item to a player: records it, announces it
--- to raid/party chat, unconditionally queues it in the trade queue (it's
--- only ever removed once a trade is actually confirmed complete - see
--- Trade.lua's completion watcher), and attempts to auto-trade it right away.
---@param playerName string
---@param rollData table|nil the winning roll entry (see RollWindow.lua's
--- buildRows) - amount/classification/isSR/class are recorded on the
--- roll-off purely so the "Awarded to" line can show what it was awarded for.
function RollTracker.AwardItem(playerName, rollData)
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not RollOff.item) then
        return;
    end

    -- Defense in depth: UI/RollWindow.lua already blocks the right-click for
    -- anyone but the initiator, but enforce it here too since this is the
    -- function that actually hands the item out.
    if (not RollOff.initiatorIsMe) then
        print("|cff8865ffZerpyLoot|r Only the player who started this roll-off can award it.");
        return;
    end

    RollOff.awardedTo = playerName;
    RollOff.awardedAmount = rollData and rollData.amount;
    RollOff.awardedClassification = rollData and rollData.classification;
    RollOff.awardedIsSR = rollData and rollData.isSR;
    RollOff.awardedClass = rollData and rollData.class;

    if (ZL.UI.RollWindow and ZL.UI.RollWindow.Refresh) then
        ZL.UI.RollWindow.Refresh();
    end

    local awardChannel = Util.GroupChatChannel();
    if (awardChannel) then
        pcall(SendChatMessage, ("%s was awarded to %s!"):format(RollOff.item, playerName), awardChannel);
    end

    -- Re-awarding THIS SAME roll-off to someone else supersedes any earlier
    -- attempt still sitting in the trade queue for it. Scoped by roll-off id
    -- (not just itemLink) so a second, separate roll-off for an identical
    -- item (it dropped twice) queues its own entry instead of wiping out the
    -- first roll-off's still-pending one.
    ZL.Trade.QueueRemoveByRollOff(RollOff.id);

    ZL.Trade.QueueAdd({
        itemLink = RollOff.item,
        itemIcon = RollOff.itemIcon,
        itemID = RollOff.itemID,
        winner = playerName,
        rollOffId = RollOff.id,
        rollAmount = rollData and rollData.amount,
        classification = rollData and rollData.classification,
        winnerClass = rollData and rollData.class,
    });

    ZL.Trade.AttemptTrade(playerName, RollOff.item, function(success, reason)
        if (success) then
            print(("|cff8865ffZerpyLoot|r %s placed in the trade window with %s - accept the trade to finish."):format(RollOff.item, playerName));
            return;
        end

        debugPrint(("Auto-trade to %s failed: %s"):format(playerName, tostring(reason)));

        print(("|cff8865ffZerpyLoot|r Couldn't trade %s to %s (%s) - it stays in the trade queue."):format(
            RollOff.item, playerName, tostring(reason)
        ));

        if (ZL.UI.TradeQueueWindow and ZL.UI.TradeQueueWindow.Show) then
            ZL.UI.TradeQueueWindow.Show();
        end
    end);
end

--------------------------------------------------------------------------
-- Comm dispatch
--------------------------------------------------------------------------

Comm.Actions[Constants.Actions.startRollOff] = applyStart;

Comm.Actions[Constants.Actions.stopRollOff] = function(Message)
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not RollOff.active) then
        return;
    end

    -- Only the recorded initiator (or ourselves) may end it early - mirrors
    -- Classes/RollOff.lua:564-575.
    if (not Message.isSelf and not Util.iEquals(Message.senderFqn, RollOff.initiatorFqn)) then
        return;
    end

    RollTracker.LocalStop();
end

--------------------------------------------------------------------------
-- Alt+left-click trigger
--------------------------------------------------------------------------

local function onItemClick(itemLink)
    if (not itemLink or not Util.isValidItemLink(itemLink)) then
        return;
    end

    if (not IsAltKeyDown()) then
        return;
    end

    local button = GetMouseButtonClicked and GetMouseButtonClicked() or "LeftButton";
    if (button ~= nil and button ~= "LeftButton") then
        return;
    end

    if (ZL.UI.RollWindow and ZL.UI.RollWindow.ShowStartPrompt) then
        ZL.UI.RollWindow.ShowStartPrompt(itemLink);
    end
end

--------------------------------------------------------------------------
-- Async item data (icon may not be cached client-side yet when a roll-off
-- starts - GetItemInfo returns nil for everything until the server responds,
-- which fires GET_ITEM_INFO_RECEIVED once it does).
--------------------------------------------------------------------------

-- Re-checks the current roll-off's item data and, if the icon just became
-- available, updates it and refreshes whatever UI is showing it.
local function refreshItemDataIfNeeded()
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not RollOff.item or RollOff.itemIcon) then
        return;
    end

    local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(RollOff.item);
    if (not itemIcon) then
        return; -- still not cached - wait for the next GET_ITEM_INFO_RECEIVED
    end

    RollOff.itemIcon = itemIcon;
    RollOff.itemName = RollOff.itemName or itemName;

    if (ZL.UI.RollWindow and ZL.UI.RollWindow.Refresh) then
        ZL.UI.RollWindow.Refresh();
    end
end

local function ensureItemInfoFrame()
    local itemInfoFrame = CreateFrame("Frame");
    itemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED");
    itemInfoFrame:SetScript("OnEvent", function(_, _, itemID, success)
        local RollOff = RollTracker.CurrentRollOff;
        if (success and RollOff and RollOff.itemID == itemID) then
            refreshItemDataIfNeeded();
        end
    end);
end

function RollTracker.Init()
    rollPattern = Util.createPattern(RANDOM_ROLL_RESULT);

    hooksecurefunc("HandleModifiedItemClick", function(itemLink)
        onItemClick(itemLink);
    end);

    ensureItemInfoFrame();
end
