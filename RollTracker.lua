--[[
Roll-off sessions: alt+left-click a bag item to start one (Gargul-compatible
broadcast so real Gargul clients see it too), and/or observe a roll-off
started by anyone else (Gargul or ForeverLoot).

Actual roll VALUES are never sent over addon comm by Gargul or by us - players
use the stock /roll command and the server broadcasts the result to everyone
as a CHAT_MSG_SYSTEM message matching the client's localized RANDOM_ROLL_RESULT
string. We parse that exactly the way Gargul does (see Classes/RollOff.lua).
]]

local FL = ForeverLoot;
local RollTracker = FL.RollTracker;
local Constants = FL.Constants;
local Util = FL.Util;
local Comm = FL.Comm;

local rollPattern;
local rollFrame;

RollTracker.CurrentRollOff = nil; -- set while a roll-off (ours or someone else's) is active
local stopTimerHandle;

-- The most recent competing startRollOff broadcast that arrived while we had
-- our own active/unawarded roll-off in the way (see applyStart's guard and
-- tryFlushPendingStart below). receivedAt is GetTime() at the moment we
-- stashed it, used to work out how much of its timer is actually left by the
-- time we get around to it.
local pendingStart, pendingStartReceivedAt;

-- Every roll-off gets a unique id, purely so a trade-queue entry can record
-- which roll-off it came from (see AwardItem below) - two separate roll-offs
-- for the same item (it dropped twice) must never be confused with each
-- other just because their itemLink strings happen to be identical.
local nextRollOffId = 0;

-- Dedicated comm layer for syncing RollOff.winners to other clients (see the
-- "Winners sync" section below) - deliberately NOT the "GargulComm2" channel
-- Comm.lua speaks. That channel's action ids are taken directly from real
-- Gargul's own action table specifically for third-party interop; inventing
-- a new id on it risks colliding with an actual Gargul action we have no
-- source to check against. Mirrors LootCouncil.lua's own "ForeverLootLC"
-- prefix for exactly the same reason.
-- AceComm caps comm prefixes at 16 characters - "RS" for "Roll Sync",
-- matching LootCouncil.lua's own "ForeverLootLC" naming (13 chars).
local ROLL_SYNC_PREFIX = "ForeverLootRS";
local rsSend, onRollSyncMessage;
local RSAceComm, RSLibDeflate, RSLibSerialize;
local RollSyncActions = {}; -- action name (string) -> handler(Message)

local function debugPrint(msg)
    if (Comm.debugEnabled) then
        print("|cff8865ffForeverLoot|r " .. msg);
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

    -- Chat text is hidden from addons during chat lockdown; there's nothing
    -- we can parse, and touching it would throw.
    if (Util.isSecret(message)) then
        return;
    end

    for roller, roll, low, high in string.gmatch(message, rollPattern) do
        roll = tonumber(roll) or 0;
        low = tonumber(low) or 0;
        high = tonumber(high) or 0;

        local rollerBase = Util.stripRealm(roller);

        -- Only count rolls from people actually in our group (mirrors
        -- Classes/RollOff.lua:936-951 - rolls never include a realm suffix).
        -- Forever names are two words, and the roster may list a different
        -- half than the roll message, hence findMember rather than a lookup.
        local memberName, classFile = Util.findMember(Util.groupMembers(), rollerBase);
        if (memberName ~= nil) then
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

            if (FL.UI.RollWindow and FL.UI.RollWindow.Refresh) then
                FL.UI.RollWindow.Refresh();
            end
        end
    end
end

--------------------------------------------------------------------------
-- Start / stop
--------------------------------------------------------------------------

--- True when the locally-tracked roll-off has ended, was started by us, at
--- least one roll came in, and nobody's been awarded yet - i.e. starting or
--- accepting a new roll-off right now would silently discard rolls nobody
--- got anything for. Award, Award Copy and Reassign all populate
--- RollOff.winners, so any of them make this false.
function RollTracker.HasUnawardedRolls()
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff) then return false; end
    if (not RollOff.initiatorIsMe) then return false; end
    if (#RollOff.Rolls == 0) then return false; end
    if (RollOff.winners and #RollOff.winners > 0) then return false; end
    return true;
end

--- True when starting or accepting a new roll-off right now would discard
--- something still pending here: the current roll-off is still actively
--- running (ours or someone else's), or it's ours, ended, and unawarded.
function RollTracker.HasPendingRollOff()
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff) then return false; end
    if (RollOff.active) then return true; end
    return RollTracker.HasUnawardedRolls();
end

-- Called locally by every client (initiator included) once a startRollOff
-- payload is processed - mirrors Classes/RollOff.lua:324-453, minus the
-- BoostedRolls/AutoRoll/TMB integrations which are out of scope here.
local function applyStart(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.time) ~= "number" or not content.item) then
        return;
    end

    -- Don't let a competing roll-off silently clobber one we're still using
    -- (still running, or ours and not yet awarded) - stash it instead and
    -- replay it once we're done (see tryFlushPendingStart below).
    if (not Message.isSelf and RollTracker.HasPendingRollOff()) then
        pendingStart = Message;
        pendingStartReceivedAt = GetTime();
        print(("|cff8865ffForeverLoot|r %s started a roll-off for %s - you'll see it once you finish here."):format(
            Message.senderFqn or "?", content.item));
        return;
    end

    if (stopTimerHandle) then
        stopTimerHandle:Cancel();
        stopTimerHandle = nil;
    end

    local itemID = Util.itemIDFromLink(content.item);
    local itemName, _, itemQuality, _, _, _, _, _, _, itemIcon = Util.GetItemInfo(content.item);

    -- Not cached client-side yet - explicitly request it rather than relying
    -- on GetItemInfo's implicit fetch (mirrors SoftRes.lua's tryReplyWithReserves
    -- flow). refreshItemDataIfNeeded picks up the result via GET_ITEM_INFO_RECEIVED.
    if (not itemName and itemID) then
        C_Item.RequestLoadItemDataByID(itemID);
    end

    -- Whether *we* soft-reserved this item - drives the louder sound/orange
    -- border pop below, so our own reserved item up for roll doesn't get
    -- missed among everything else going on.
    local isSelfSR = FL.SoftRes ~= nil and FL.SoftRes.PlayerHasReservedItem(Util.stripRealm(Util.UnitName("player")), itemID);

    nextRollOffId = nextRollOffId + 1;

    RollTracker.CurrentRollOff = {
        active = true,
        id = nextRollOffId,
        initiatorFqn = Message.senderFqn,
        initiatorIsMe = Message.isSelf,
        item = content.item,
        itemID = itemID,
        itemName = itemName,
        itemQuality = itemQuality,
        itemIcon = itemIcon,
        time = math.floor(content.time),
        brackets = (type(content.SupportedRolls) == "table" and #content.SupportedRolls > 0) and content.SupportedRolls or Constants.DEFAULT_BRACKETS,
        startedAt = GetTime(),
        Rolls = {},
        isSelfSR = isSelfSR,
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
    if (Message.isSelf and FL.Settings.GetRaidChatRollCountdownEnabled()) then
        for i = FL.Settings.GetRaidChatRollCountdownSeconds(), 1, -1 do
            local delay = thisRollOff.time - i;
            if (delay >= 0) then
                C_Timer.After(delay, function()
                    if (RollTracker.CurrentRollOff == thisRollOff and thisRollOff.active) then
                        local channel = Util.GroupChatChannel();
                        if (channel and not Util.IsChatMessageRestricted()) then
                            local text = i == 1 and "1 second to roll" or (i .. " seconds to roll");
                            pcall(SendChatMessage, text, channel);
                        end
                    end
                end);
            end
        end
    end

    -- A louder, more exciting sound when it's our own soft-reserved item up
    -- for roll, so it stands out from every other roll-off's plain raid
    -- warning chime. Both sounds are user-configurable (which sound, and
    -- on/off) via the General settings page's "Sounds" section - see
    -- Util.playConfiguredSound and FL.Settings.GetSound*Key/*Enabled.
    if (isSelfSR) then
        if (FL.Settings.GetSoundSelfSREnabled()) then
            Util.playConfiguredSound(FL.Settings.GetSoundSelfSRKey(), "Master");
        end
    else
        if (FL.Settings.GetSoundRaidWarningEnabled()) then
            Util.playConfiguredSound(FL.Settings.GetSoundRaidWarningKey(), "Master");
        end
    end

    -- Sounds above always play regardless of this setting - it only gates
    -- the window itself, and only for a roll-off someone ELSE started; one we
    -- started ourselves always opens it (we're mid-flow setting it up).
    local shouldShowWindow = Message.isSelf or FL.Settings.GetRollOffShowForOthers();
    if (shouldShowWindow and FL.UI.RollWindow and FL.UI.RollWindow.Show) then
        FL.UI.RollWindow.Show();
    end

    debugPrint(("Roll-off started by %s for %s (%ds)"):format(Message.senderFqn or "?", content.item, content.time));
end

--- Replays a stashed competing roll-off start (see applyStart's guard above)
--- once our own active/unawarded roll-off is no longer in the way - called
--- from LocalStop (covers a roll-off that ended with zero rolls, so there's
--- nothing to award) and from AwardItem (covers the normal award case).
--- Adjusts the stashed duration down by however long we sat on it, so the
--- replayed countdown roughly lines up with everyone else's by now; drops it
--- silently if it would already be over.
local function tryFlushPendingStart()
    if (not pendingStart or RollTracker.HasPendingRollOff()) then
        return;
    end

    local Message = pendingStart;
    local elapsed = GetTime() - pendingStartReceivedAt;
    pendingStart, pendingStartReceivedAt = nil, nil;

    local remaining = (Message.content.time or 0) - elapsed;
    if (remaining < 1) then
        return;
    end

    Message.content.time = remaining;
    applyStart(Message);
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
                Util.SendChatMessageSafe("Stop your rolls!", channel, nil, nil, function()
                    debugPrint("Could not announce roll stop (missing raid warning permission?)");
                end);
            end
        end
    end

    if (FL.UI.RollWindow and FL.UI.RollWindow.Refresh) then
        FL.UI.RollWindow.Refresh();
    end

    tryFlushPendingStart();
end

--- Broadcast a roll-off start. Any player can call this (mirrors Gargul's
--- alt+left-click flow); real Gargul clients in the group will pick it up
--- and open their own roll UI for it.
---@param itemLink string
---@param seconds number Must be >= 5
function RollTracker.StartRollOff(itemLink, seconds)
    seconds = tonumber(seconds);

    if (RollTracker.HasPendingRollOff()) then
        print("|cff8865ffForeverLoot|r A roll-off is already in progress.");
        return false;
    end

    if (not Util.isValidItemLink(itemLink)) then
        print("|cff8865ffForeverLoot|r Invalid item link.");
        return false;
    end

    if (not seconds or seconds < 5) then
        print("|cff8865ffForeverLoot|r Timer needs to be 5 seconds or more.");
        return false;
    end

    Comm.Send(Constants.Actions.startRollOff, {
        item = itemLink,
        time = seconds,
        SupportedRolls = Constants.DEFAULT_BRACKETS,
    }, "GROUP");

    -- Captured locally (rather than read back off RollTracker.CurrentRollOff)
    -- since that only gets set once this broadcast loops back through Comm's
    -- own receive handler, which isn't guaranteed to have happened yet by the
    -- time this runs - relying on it here made these announcements silently
    -- drop themselves every time, not just when actually queued for combat.
    local announceStartedAt = GetTime();

    local startChannel = Util.GroupChatChannel("RAID_WARNING");
    if (startChannel) then
        Util.SendChatMessageSafe(function()
            local remaining = math.max(0, math.floor(announceStartedAt + seconds - GetTime()));
            if (remaining <= 0) then return nil; end
            return ("You have %d seconds to roll on %s"):format(remaining, itemLink), startChannel;
        end);
    end

    -- Announce SoftRes reservations for this item too, if we know of any (parity with Gargul).
    local reservedChannel = Util.GroupChatChannel();
    if (reservedChannel and FL.SoftRes and FL.SoftRes.GetReservationsForItemID) then
        local itemID = Util.itemIDFromLink(itemLink);
        local reservations = itemID and FL.SoftRes.GetReservationsForItemID(itemID);
        if (reservations and #reservations > 0) then
            local names = {};
            for _, r in ipairs(reservations) do
                table.insert(names, r.count > 1 and ("%s (%dx)"):format(r.name, r.count) or r.name);
            end
            local text = "This item was reserved by: " .. table.concat(names, ", ");
            Util.SendChatMessageSafe(function()
                if (GetTime() - announceStartedAt >= seconds) then return nil; end
                return text, reservedChannel;
            end);
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
-- Winners sync (private comm channel - see ROLL_SYNC_PREFIX above)
--------------------------------------------------------------------------

-- Mirrors LootCouncil.lua's lcSend/onLCMessage pipeline (serialize ->
-- compress -> encode, same anti-spoof check), but on its own prefix and with
-- its own tiny string-keyed action table - this feature has nothing to do
-- with loot council sessions and shouldn't be coupled to that file.
rsSend = function(action, content)
    local distribution, target = Util.GroupDistribution("GROUP", nil);

    local payload = { a = action, b = content, c = Util.playerFqn() };

    local encoded = RSLibDeflate:EncodeForWoWAddonChannel(
        RSLibDeflate:CompressDeflate(RSLibSerialize:Serialize(payload), { level = 5 }));

    debugPrint(("SEND %s -> %s"):format(tostring(action), distribution));

    RSAceComm:SendCommMessage(ROLL_SYNC_PREFIX, encoded, distribution, target, "NORMAL");
end

onRollSyncMessage = function(prefix, encoded, distribution, senderName)
    if (prefix ~= ROLL_SYNC_PREFIX) then return; end

    local ok, decompressed = pcall(function()
        return RSLibDeflate:DecompressDeflate(RSLibDeflate:DecodeForWoWAddonChannel(encoded));
    end);
    if (not ok or not decompressed) then return; end

    local deserializeOk, payload = RSLibSerialize:Deserialize(decompressed);
    if (not deserializeOk or type(payload) ~= "table" or not payload.a) then return; end

    -- Anti-spoofing: claimed sender must start with the real (server-supplied) sender name
    if (payload.c and senderName) then
        local claimed = string.lower(strtrim(payload.c));
        local real = string.lower(strtrim(senderName));
        if (string.sub(claimed, 1, #real) ~= real) then return; end
    end

    local Message = {
        action = payload.a,
        content = payload.b,
        senderFqn = payload.c or senderName,
        senderName = Util.stripRealm(payload.c or senderName),
        channel = distribution,
    };
    Message.isSelf = Util.iEquals(Message.senderFqn, Util.playerFqn()) or Util.iEquals(Message.senderName, Util.UnitName("player"));

    debugPrint(("RECV %s <- %s (%s)"):format(tostring(Message.action), Message.senderFqn or "?", distribution));

    local handler = RollSyncActions[Message.action];
    if (handler) then handler(Message); end
end

-- Broadcasts the CURRENT full winners list (not a delta) - safe/idempotent
-- to resend since replacing a list with an identical list is a no-op, and
-- only the initiator (the only one who can award/reassign) ever sends this.
-- queueEntryId is stripped since it's meaningless on another client's queue.
local function broadcastWinners(RollOff, kind)
    local sanitized = {};
    for _, w in ipairs(RollOff.winners) do
        table.insert(sanitized, {
            rollId = w.rollId, name = w.name, class = w.class,
            amount = w.amount, classification = w.classification, isSR = w.isSR,
        });
    end

    rsSend("winners", { rollOffId = RollOff.id, type = kind, winners = sanitized });
end

RollSyncActions.winners = function(Message)
    local content = Message.content;
    if (type(content) ~= "table" or not content.rollOffId or type(content.winners) ~= "table") then
        return;
    end

    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or RollOff.id ~= content.rollOffId) then
        return; -- stale or foreign roll-off
    end

    -- Only the recorded initiator may move winners around - mirrors
    -- stopRollOff's own initiator check above.
    if (not Util.iEquals(Message.senderFqn, RollOff.initiatorFqn)) then
        return;
    end

    RollOff.winners = content.winners;

    if (FL.UI.RollWindow and FL.UI.RollWindow.Refresh) then
        FL.UI.RollWindow.Refresh();
    end
end

--------------------------------------------------------------------------
-- Award (right-click a roll row -> confirm -> announce + auto-trade)
--------------------------------------------------------------------------

-- Builds this award's trade-queue entry (via the existing Trade.QueueAdd) and
-- its corresponding winners-list entry, shared by both AwardItem and
-- ReassignItem so the two stay in lockstep with each other's field shape.
local function buildWinnerAndQueueEntry(RollOff, playerName, rollData)
    local queueEntry = {
        itemLink = RollOff.item,
        itemIcon = RollOff.itemIcon,
        itemID = RollOff.itemID,
        winner = playerName,
        rollOffId = RollOff.id,
        rollSessionId = RollOff.id,
        rollAmount = rollData and rollData.amount,
        classification = rollData and rollData.classification,
        winnerClass = rollData and rollData.class,
    };
    FL.Trade.QueueAdd(queueEntry); -- assigns queueEntry.id

    local winnerEntry = {
        rollId = rollData and rollData.arrivalIndex,
        name = playerName,
        class = rollData and rollData.class,
        amount = rollData and rollData.amount,
        classification = rollData and rollData.classification,
        isSR = rollData and rollData.isSR,
        queueEntryId = queueEntry.id,
    };

    return winnerEntry, queueEntry;
end

local function attemptAutoTrade(RollOff, playerName, queueEntry)
    FL.Trade.AttemptTradeForQueueEntry(queueEntry, function(success, reason)
        if (success) then
            return;
        end

        debugPrint(("Auto-trade to %s failed: %s"):format(playerName, tostring(reason)));

        if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Show) then
            FL.UI.TradeQueueWindow.Show();
        end
    end);
end

--- Assign the current roll-off's item to a player - either the first winner
--- ("Award") or an additional copy ("Award Copy"), driven entirely by
--- whether RollOff.winners is already non-empty. Never touches an existing
--- winner or their trade-queue entry; use ReassignItem to replace winners
--- instead.
---@param playerName string
---@param rollData table|nil the winning roll entry (see RollWindow.lua's
--- buildRows) - amount/classification/isSR/class/arrivalIndex are recorded
--- on the winner entry purely so the UI can show what it was awarded for.
function RollTracker.AwardItem(playerName, rollData)
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not RollOff.item) then
        return;
    end

    -- Defense in depth: UI/RollWindow.lua already blocks the right-click for
    -- anyone but the initiator, but enforce it here too since this is the
    -- function that actually hands the item out.
    if (not RollOff.initiatorIsMe) then
        print("|cff8865ffForeverLoot|r Only the player who started this roll-off can award it.");
        return;
    end

    RollOff.winners = RollOff.winners or {};

    local winnerEntry, queueEntry = buildWinnerAndQueueEntry(RollOff, playerName, rollData);
    table.insert(RollOff.winners, winnerEntry);

    RollOff.lastAction = {
        kind = "award",
        winnerName = playerName,
        winnerClass = rollData and rollData.class,
        ordinal = #RollOff.winners,
    };

    if (FL.UI.RollWindow and FL.UI.RollWindow.Refresh) then
        FL.UI.RollWindow.Refresh();
    end

    local awardChannel = Util.GroupChatChannel();
    if (awardChannel) then
        Util.SendChatMessageSafe(("%s was awarded to %s!"):format(RollOff.item, playerName), awardChannel);
    end

    broadcastWinners(RollOff, "add");
    attemptAutoTrade(RollOff, playerName, queueEntry);

    tryFlushPendingStart();
end

--- Replace every current winner of this roll-off with a single new one:
--- drops each old winner's not-yet-traded queue entry (an already-traded
--- one is left alone and reported back via RollOff.lastAction), then awards
--- the item to the new player exactly like a first award.
---@param playerName string
---@param rollData table|nil see AwardItem
function RollTracker.ReassignItem(playerName, rollData)
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not RollOff.item) then
        return;
    end

    if (not RollOff.initiatorIsMe) then
        print("|cff8865ffForeverLoot|r Only the player who started this roll-off can award it.");
        return;
    end

    if (not RollOff.winners or #RollOff.winners == 0) then
        return; -- nothing to reassign - UI never offers Reassign in this state
    end

    local oldWinners = RollOff.winners;
    local replacedNames, alreadyTradedNames = {}, {};

    for _, w in ipairs(oldWinners) do
        table.insert(replacedNames, { name = w.name, class = w.class });

        local removed = FL.Trade.QueueRemoveByRollOffAndWinner(RollOff.id, w.name);
        if (not removed) then
            local wasTraded = false;
            for _, tradedName in ipairs(RollOff.tradedWinnerNames or {}) do
                if (Util.namesMatch(tradedName, w.name)) then
                    wasTraded = true;
                    break;
                end
            end

            if (wasTraded) then
                table.insert(alreadyTradedNames, { name = w.name, class = w.class });
            end
            -- else: manually removed from the Trade Queue window - nothing
            -- to do, and per the task's own edge case, no error either.
        end
    end

    local winnerEntry, queueEntry = buildWinnerAndQueueEntry(RollOff, playerName, rollData);
    RollOff.winners = { winnerEntry };
    RollOff.tradedWinnerNames = {};

    RollOff.lastAction = {
        kind = "reassign",
        winnerName = playerName,
        winnerClass = rollData and rollData.class,
        replacedNames = replacedNames,
        alreadyTradedNames = alreadyTradedNames,
    };

    if (FL.UI.RollWindow and FL.UI.RollWindow.Refresh) then
        FL.UI.RollWindow.Refresh();
    end

    local awardChannel = Util.GroupChatChannel();
    if (awardChannel) then
        Util.SendChatMessageSafe(("%s was awarded to %s!"):format(RollOff.item, playerName), awardChannel);
    end

    broadcastWinners(RollOff, "reassign");
    attemptAutoTrade(RollOff, playerName, queueEntry);
end

--- Called by Trade.lua whenever a queue entry created by a roll-off award is
--- confirmed actually traded (not just placed) - lets a later Reassign tell
--- "already traded" apart from "manually removed from the Trade Queue
--- window", since both look identical as a simple "entry no longer exists".
---@param entry table the Trade.Queue entry that was just traded away
function RollTracker.OnQueueEntryTraded(entry)
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not entry.rollSessionId or RollOff.id ~= entry.rollSessionId) then
        return;
    end

    RollOff.tradedWinnerNames = RollOff.tradedWinnerNames or {};
    table.insert(RollOff.tradedWinnerNames, entry.winner);
end

--------------------------------------------------------------------------
-- Comm dispatch
--------------------------------------------------------------------------

Comm.Actions[Constants.Actions.startRollOff] = applyStart;

Comm.Actions[Constants.Actions.stopRollOff] = function(Message)
    -- A stashed competing start (see applyStart's guard above) isn't
    -- RollTracker.CurrentRollOff yet, so it wouldn't be caught by the check
    -- below - cancel it here if this stop is from the same sender, rather
    -- than replaying it once we're free, later, as if it were still running.
    if (pendingStart and Util.iEquals(Message.senderFqn, pendingStart.senderFqn)) then
        print(("|cff8865ffForeverLoot|r %s stopped their roll-off before you got to it."):format(Message.senderFqn or "?"));
        pendingStart, pendingStartReceivedAt = nil, nil;
    end

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

    if (FL.UI.RollWindow and FL.UI.RollWindow.ShowStartPrompt) then
        FL.UI.RollWindow.ShowStartPrompt(itemLink);
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

    local itemName, _, itemQuality, _, _, _, _, _, _, itemIcon = Util.GetItemInfo(RollOff.item);
    if (not itemIcon) then
        return; -- still not cached - wait for the next GET_ITEM_INFO_RECEIVED
    end

    RollOff.itemIcon = itemIcon;
    RollOff.itemName = RollOff.itemName or itemName;
    RollOff.itemQuality = RollOff.itemQuality or itemQuality;

    if (FL.UI.RollWindow and FL.UI.RollWindow.Refresh) then
        FL.UI.RollWindow.Refresh();
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

    RSAceComm = LibStub("AceComm-3.0");
    RSLibDeflate = LibStub("LibDeflate");
    RSLibSerialize = LibStub("LibSerialize");
    RSAceComm:RegisterComm(ROLL_SYNC_PREFIX, onRollSyncMessage);
end
