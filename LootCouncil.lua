--[[
Loot council sessions: build a list of items, broadcast it to the raid with a
fixed set of response options, collect every raider's response, let a
manually-configured council vote per candidate, and award the item - which
then flows into the existing trade queue (Trade.lua) exactly like a roll-off
award does, and is recorded to a persistent history log.

This file currently only implements Phase 1 (building the local, unbroadcast
item list - see UI/LootCouncilAddItemsWindow.lua). Broadcasting, responses,
voting, and awarding are added in later phases; see the plan this was built
from for the full design.
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

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";
LootCouncil.FALLBACK_ICON = FALLBACK_ICON;

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
-- Broadcast (stub - implemented in Phase 2)
--------------------------------------------------------------------------

function LootCouncil.SendToRaid()
    print("|cff8865ffForeverLoot|r Sending the loot council list to the raid isn't implemented yet.");
end
