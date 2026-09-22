--[[
Loot council sessions: build a list of items, broadcast it to the raid with a
fixed set of response options, collect every raider's response, let a
manually-configured council vote per candidate, and award the item - which
then flows into the existing trade queue (Trade.lua) exactly like a roll-off
award does, and is recorded to a persistent history log.

This file currently implements Phase 1 (building the local, unbroadcast item
list - see UI/LootCouncilAddItemsWindow.lua) and Phase 2 (broadcasting that
list to the raid over a dedicated comm channel, populating CurrentSession on
every client). Responses, voting, and awarding are added in later phases; see
the plan this was built from for the full design.
]]

local FL = ForeverLoot;
local LootCouncil = FL.LootCouncil;
local Util = FL.Util;

-- BIND_TRADE_TIME_REMAINING is the Blizzard global string shown in an item's
-- tooltip while it still has a trade timer (e.g. "You may trade this item
-- with players who were also eligible to loot it for the next %s."). Built
-- into a match pattern the same way RollTracker.lua does for
-- RANDOM_ROLL_RESULT, rather than hardcoding the wording, since global
-- strings can shift across client patches.
local tradeTimePattern;
local scanTooltip;

-- Dedicated comm layer (see the "Broadcast" section below) - forward-declared
-- so Init() can register them before their bodies are defined further down,
-- same convention as tradeTimePattern/scanTooltip above.
local lcSend, onLCMessage;
local AceComm, LibDeflate, LibSerialize;

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";
LootCouncil.FALLBACK_ICON = FALLBACK_ICON;

-- Dedicated AceComm prefix for this feature - deliberately NOT the existing
-- "GargulComm2" channel Comm.lua speaks (that one mirrors Gargul's real wire
-- protocol for third-party interop; inventing new action ids on it would
-- broadcast unrelated traffic to real Gargul clients in the raid).
local LC_PREFIX = "ForeverLootLC";
LootCouncil.CommActions = {}; -- action name (string) -> handler(Message)
LootCouncil.debugEnabled = false;

function LootCouncil.Init()
    FL.DB.lootCouncil = FL.DB.lootCouncil or {
        roster = {},
        draft = { items = {} },
        history = {},
        session = nil,
    };
    local db = FL.DB.lootCouncil;

    LootCouncil.Roster = db.roster;
    LootCouncil.Draft = db.draft;
    LootCouncil.History = db.history;
    LootCouncil.CurrentSession = db.session;

    if (BIND_TRADE_TIME_REMAINING) then
        tradeTimePattern = Util.createPattern(BIND_TRADE_TIME_REMAINING);
    end

    AceComm = LibStub("AceComm-3.0");
    LibDeflate = LibStub("LibDeflate");
    LibSerialize = LibStub("LibSerialize");
    AceComm:RegisterComm(LC_PREFIX, onLCMessage);
end

--------------------------------------------------------------------------
-- Draft list (Phase 1 - local only, never touches comm)
--------------------------------------------------------------------------

--- Adds an item to the leader's in-progress, unbroadcast draft list. The same
--- item can be added more than once (it can drop more than once in a raid) -
--- each add becomes its own separate row rather than being merged/rejected.
---@param itemLink string
---@param source string|nil "manual" (default) or "bagscan"
---@return boolean success, string|nil message
function LootCouncil.DraftAddItem(itemLink, source)
    if (not Util.isValidItemLink(itemLink)) then
        return false, "Invalid item link.";
    end

    table.insert(LootCouncil.Draft.items, {
        itemLink = itemLink,
        itemID = Util.itemIDFromLink(itemLink),
        source = source or "manual",
    });

    return true;
end

-- The "|Hitem:...|h[Name]|h" core is present in every item hyperlink
-- regardless of client version - the color wrapper around it isn't: classic
-- clients use an 8-hex-digit "|cffRRGGBB" code, but newer ones can use a
-- different (e.g. named-color) form, so a pattern that hardcodes the classic
-- shape can fail to match entirely on those clients. Matching just the core,
-- then opportunistically extending over whatever precedes/follows it, works
-- regardless of which wrapper format (or none at all) is actually present.
local ITEM_LINK_CORE_PATTERN = "|Hitem:.-|h%[.-%]|h";
-- Generous upper bound on how far back a leading color escape could start -
-- both the classic and named-color forms are well under this.
local COLOR_PREFIX_SEARCH_WINDOW = 32;

--- Every complete item hyperlink found in `text`, in the order they appear.
function LootCouncil.ExtractItemLinks(text)
    local links = {};
    if (type(text) ~= "string") then return links; end

    local searchFrom = 1;
    while (true) do
        local coreStart, coreEnd = string.find(text, ITEM_LINK_CORE_PATTERN, searchFrom);
        if (not coreStart) then break; end

        -- Extend backward over a "|c<anything but |>" immediately before the
        -- core, if one is actually there.
        local windowStart = math.max(1, coreStart - COLOR_PREFIX_SEARCH_WINDOW);
        local before = string.sub(text, windowStart, coreStart - 1);
        local colorPrefix = string.match(before, "|c[^|]*$");
        local linkStart = colorPrefix and (coreStart - #colorPrefix) or coreStart;

        -- Extend forward over a trailing "|r" reset, if present.
        local linkEnd = (string.sub(text, coreEnd + 1, coreEnd + 2) == "|r") and (coreEnd + 2) or coreEnd;

        table.insert(links, string.sub(text, linkStart, linkEnd));
        searchFrom = linkEnd + 1;
    end

    return links;
end

--- Adds every item link found in `text` to the draft, in order.
---@return number added, number skipped, boolean foundAny
function LootCouncil.DraftAddItemsFromText(text, source)
    local links = LootCouncil.ExtractItemLinks(text);
    if (#links == 0) then
        return 0, 0, false;
    end

    local added, skipped = 0, 0;
    for _, link in ipairs(links) do
        if (LootCouncil.DraftAddItem(link, source)) then
            added = added + 1;
        else
            skipped = skipped + 1;
        end
    end

    return added, skipped, true;
end

--- Removes the draft item at `index`.
function LootCouncil.DraftRemoveItem(index)
    if (not LootCouncil.Draft.items[index]) then return; end
    table.remove(LootCouncil.Draft.items, index);
end

--------------------------------------------------------------------------
-- Bag scan ("Add All Tradeable From Bags")
--------------------------------------------------------------------------

local function ensureScanTooltip()
    if (scanTooltip) then return; end
    scanTooltip = CreateFrame("GameTooltip", "ForeverLootLCScanTooltip", nil, "GameTooltipTemplate");
    scanTooltip:SetOwner(UIParent, "ANCHOR_NONE");
end

-- True if the bag item at (bag, slot) still shows a "you may trade this"
-- tooltip line - C_Container.GetContainerItemInfo's `isBound` flag alone
-- can't distinguish "still tradeable" from "timer already expired".
local function isStillTradeable(bag, slot)
    if (not tradeTimePattern) then return false; end

    ensureScanTooltip();
    scanTooltip:ClearLines();
    scanTooltip:SetBagItem(bag, slot);

    for i = 2, scanTooltip:NumLines() do
        local line = _G["ForeverLootLCScanTooltipTextLeft" .. i];
        local text = line and line:GetText();
        if (text and string.match(text, tradeTimePattern)) then
            return true;
        end
    end

    return false;
end

--- Scans the player's own bags for bound items that still have a tradeable
--- timer remaining. Returns an array of item links found (may contain
--- duplicates if the same item is stacked/split across multiple slots).
function LootCouncil.ScanBagsForTradeable()
    local found = {};

    if (not tradeTimePattern) then
        return found;
    end

    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0;
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot);
            if (info and info.isBound and info.hyperlink and isStillTradeable(bag, slot)) then
                table.insert(found, info.hyperlink);
            end
        end
    end

    return found;
end

--- Runs the bag scan and adds every newly-found item to the draft (skipping
--- ones already in it). Returns how many were actually added.
function LootCouncil.DraftAddAllTradeable()
    local added = 0;
    for _, itemLink in ipairs(LootCouncil.ScanBagsForTradeable()) do
        if (LootCouncil.DraftAddItem(itemLink, "bagscan")) then
            added = added + 1;
        end
    end
    return added;
end

--------------------------------------------------------------------------
-- Broadcast - dedicated comm channel, mirrors Comm.lua's own pipeline
-- (serialize -> compress -> encode) and anti-spoof check, but without
-- Gargul's version-handshake fields since there's no third-party protocol
-- to satisfy here.
--------------------------------------------------------------------------

local function lcDebugPrint(msg)
    if (LootCouncil.debugEnabled) then
        print("|cff8865ffForeverLoot|r " .. msg);
    end
end

lcSend = function(action, content, channel, recipient)
    local distribution, target = Util.GroupDistribution(channel or "GROUP", recipient);

    local payload = { a = action, b = content, c = Util.playerFqn() };
    if (distribution ~= "WHISPER" and recipient) then
        payload.r = recipient;
    end

    local encoded = LibDeflate:EncodeForWoWAddonChannel(
        LibDeflate:CompressDeflate(LibSerialize:Serialize(payload), { level = 5 }));

    lcDebugPrint(("SEND %s -> %s%s"):format(tostring(action), distribution, target and (":" .. target) or ""));

    AceComm:SendCommMessage(LC_PREFIX, encoded, distribution, target, "NORMAL");
end

onLCMessage = function(prefix, encoded, distribution, senderName)
    if (prefix ~= LC_PREFIX) then return; end

    local ok, decompressed = pcall(function()
        return LibDeflate:DecompressDeflate(LibDeflate:DecodeForWoWAddonChannel(encoded));
    end);
    if (not ok or not decompressed) then return; end

    local deserializeOk, payload = LibSerialize:Deserialize(decompressed);
    if (not deserializeOk or type(payload) ~= "table" or not payload.a) then return; end

    -- Not meant for us (whisper forcefully routed through raid/party channel)
    local myName = UnitName("player");
    local myFqn = Util.playerFqn();
    if (payload.r and not Util.iEquals(payload.r, myFqn) and not Util.iEquals(payload.r, myName)) then
        return;
    end

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
    Message.isSelf = Util.iEquals(Message.senderFqn, myFqn) or Util.iEquals(Message.senderName, myName);

    lcDebugPrint(("RECV %s <- %s (%s)"):format(tostring(Message.action), Message.senderFqn or "?", distribution));

    local handler = LootCouncil.CommActions[Message.action];
    if (handler) then handler(Message); end
end

--------------------------------------------------------------------------
-- Session lifecycle
--------------------------------------------------------------------------

local nextSessionId = 0;

-- Applied locally by every client (initiator included, via the self-looped
-- broadcast) when a sessionStart message is processed - mirrors
-- RollTracker.lua's applyStart. The sessionId always comes from the message,
-- never generated locally, so every client agrees on the same id.
local function applySessionStart(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.items) ~= "table" or not content.sessionId) then
        return;
    end

    local items = {};
    for i, itemLink in ipairs(content.items) do
        local itemID = Util.itemIDFromLink(itemLink);
        local itemName, _, itemQuality, _, _, _, _, _, _, itemIcon = Util.GetItemInfo(itemLink);

        -- Not cached client-side yet - explicitly request it rather than
        -- relying on GetItemInfo's implicit fetch (mirrors
        -- RollTracker.lua's applyStart). No refresh listener is wired up
        -- here since no Phase 2 UI needs to redraw when it arrives late -
        -- Phase 3's response window adds that.
        if (not itemName and itemID) then
            C_Item.RequestLoadItemDataByID(itemID);
        end

        items[i] = {
            session = i,
            itemLink = itemLink,
            itemID = itemID,
            itemName = itemName,
            itemQuality = itemQuality,
            itemIcon = itemIcon,
            awardedTo = nil,
            awardedAt = nil,
            candidates = {},
        };
    end

    FL.DB.lootCouncil.session = {
        active = true,
        id = content.sessionId,
        initiatorFqn = Message.senderFqn,
        initiatorIsMe = Message.isSelf,
        startedAt = GetTime(),
        status = "active",
        items = items,
    };
    LootCouncil.CurrentSession = FL.DB.lootCouncil.session;

    lcDebugPrint(("Loot council session %d started by %s (%d items)"):format(content.sessionId, Message.senderFqn or "?", #items));
end
LootCouncil.CommActions.sessionStart = applySessionStart;

--- Broadcasts the leader's current draft list to the raid as a new session.
---@return boolean success
function LootCouncil.SendToRaid()
    if (#LootCouncil.Draft.items == 0) then
        print("|cff8865ffForeverLoot|r Add at least one item to the list first.");
        return false;
    end

    nextSessionId = nextSessionId + 1;

    local itemLinks = {};
    for i, draftItem in ipairs(LootCouncil.Draft.items) do
        itemLinks[i] = draftItem.itemLink;
    end

    lcSend("sessionStart", { sessionId = nextSessionId, items = itemLinks }, "GROUP");

    return true;
end
