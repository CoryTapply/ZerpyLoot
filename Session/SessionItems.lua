--[[
Leader's in-progress, unbroadcast session item list - what UI/StartSessionWindow
builds and, later, what UI/AwardWindow's own edit path will also
draw on. No UI here, no comm code either - LootCouncil.lua owns the actual
broadcast (SendToRaid/lcSend/nextSessionId); SessionItems.Send() only decides
whether a send is allowed to happen and hands off to it.

Backed by the same FL.DB.lootCouncil.draft.items SavedVariables table
LootCouncil.lua creates in its own Init() (so an in-progress draft survives
a /reload same as before), just no longer read/written through LootCouncil's
public API.
]]

local FL = ForeverLoot;
local Util = FL.Util;

FL.SessionItems = FL.SessionItems or {};
local SessionItems = FL.SessionItems;

-- BIND_TRADE_TIME_REMAINING is the Blizzard global string shown in an item's
-- tooltip while it still has a trade timer (e.g. "You may trade this item
-- with players who were also eligible to loot it for the next %s."). Built
-- into a match pattern the same way RollTracker.lua does for
-- RANDOM_ROLL_RESULT, rather than hardcoding the wording, since global
-- strings can shift across client patches.
local tradeTimePattern;
local scanTooltip;

-- Set in Init() once FL.DB.lootCouncil exists (LootCouncil.Init() creates it
-- earlier in the same PLAYER_LOGIN module pass - see Core/Init.lua's module
-- list, SessionItems is registered right after LootCouncil there).
local items;

function SessionItems.Init()
    items = FL.DB.lootCouncil.draft.items;

    if (BIND_TRADE_TIME_REMAINING) then
        tradeTimePattern = Util.createPattern(BIND_TRADE_TIME_REMAINING);
    end
end

--------------------------------------------------------------------------
-- Item list
--------------------------------------------------------------------------

--- The live session item array - iterate, don't hold onto across a Clear().
function SessionItems.GetItems()
    return items;
end

--- Adds an item to the leader's in-progress, unbroadcast list. The same item
--- can be added more than once (it can drop more than once in a raid, and
--- de-duplication was explicitly ruled out) - each add becomes its own
--- separate row rather than being merged/rejected.
---@param itemLink string
---@param source string|nil "manual" (default), "bagscan", or "cursor" (drag/shift-click)
---@return boolean success, string|nil message
function SessionItems.AddFromLink(itemLink, source)
    if (not Util.isValidItemLink(itemLink)) then
        return false, "Invalid item link.";
    end

    table.insert(items, {
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
function SessionItems.ExtractItemLinks(text)
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

--- Adds every item link found in `text` to the list, in order.
---@return number added, number skipped, boolean foundAny
function SessionItems.AddItemsFromText(text, source)
    local links = SessionItems.ExtractItemLinks(text);
    if (#links == 0) then
        return 0, 0, false;
    end

    local added, skipped = 0, 0;
    for _, link in ipairs(links) do
        if (SessionItems.AddFromLink(link, source)) then
            added = added + 1;
        else
            skipped = skipped + 1;
        end
    end

    return added, skipped, true;
end

--- Removes the item at `index`.
function SessionItems.RemoveItem(index)
    if (not items[index]) then return; end
    table.remove(items, index);
end

--- Empties the list.
function SessionItems.Clear()
    wipe(items);
end

--------------------------------------------------------------------------
-- Drag/drop and shift-click ("drop an item here")
--------------------------------------------------------------------------

--- Adds an item picked up off the cursor (drag-and-drop or shift-click) -
--- any item, no tradeable gate. That check only applies to the bulk "Add All
--- Tradeable From Bags" scan (ScanBagsForTradeable/AddAllTradeableFromBags
--- below), which specifically auto-finds BoP loot still inside its trade
--- window; a deliberate one-at-a-time drag/shift-click add isn't gated by it.
---@param itemLink string
---@return boolean success
function SessionItems.AddFromCursor(itemLink)
    if (not Util.isValidItemLink(itemLink)) then return false; end
    return SessionItems.AddFromLink(itemLink, "cursor");
end

--------------------------------------------------------------------------
-- Bag scan ("Add All Tradeable From Bags")
--------------------------------------------------------------------------

local function ensureScanTooltip()
    if (scanTooltip) then return; end
    scanTooltip = CreateFrame("GameTooltip", "ForeverLootSessionItemsScanTooltip", nil, "GameTooltipTemplate");
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
        local line = _G["ForeverLootSessionItemsScanTooltipTextLeft" .. i];
        local text = line and line:GetText();
        if (text and string.match(text, tradeTimePattern)) then
            return true;
        end
    end

    return false;
end

--- Whether the item in bag/slot is bound and still has a tradeable timer
--- remaining - the bag scan's own per-slot check.
function SessionItems.IsBagSlotTradeable(bag, slot)
    if (not tradeTimePattern) then return false; end

    local info = C_Container.GetContainerItemInfo(bag, slot);
    if (not info or not info.isBound or not info.hyperlink) then return false; end

    return isStillTradeable(bag, slot);
end

--- Scans the player's own bags for bound items that still have a tradeable
--- timer remaining. Returns an array of item links found (may contain
--- duplicates if the same item is stacked/split across multiple slots).
function SessionItems.ScanBagsForTradeable()
    local found = {};

    if (not tradeTimePattern) then
        return found;
    end

    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0;
        for slot = 1, numSlots do
            if (SessionItems.IsBagSlotTradeable(bag, slot)) then
                local info = C_Container.GetContainerItemInfo(bag, slot);
                table.insert(found, info.hyperlink);
            end
        end
    end

    return found;
end

--- Runs the bag scan and adds every item found to the list. Returns how many
--- were added.
function SessionItems.AddAllTradeableFromBags()
    local added = 0;
    for _, itemLink in ipairs(SessionItems.ScanBagsForTradeable()) do
        if (SessionItems.AddFromLink(itemLink, "bagscan")) then
            added = added + 1;
        end
    end
    return added;
end

--------------------------------------------------------------------------
-- Send
--------------------------------------------------------------------------

--- Whether the local player is allowed to start a session - leader/assistant
--- only, matching the same check UI/SettingsWindow/Pages/LootCouncil.lua's
--- "Sync to Raid" button already uses. Unlike that button, this is a NEW
--- restriction: LootCouncil.SendToRaid() itself has never gated who could
--- call it.
function SessionItems.CanSend()
    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player");
end

--- Validates permission and a non-empty list, then broadcasts via
--- LootCouncil.SendToRaid() (which owns the actual comm transport). Clears
--- the draft on success so a later SendToActiveSession() call doesn't
--- re-send items that already went out with this session.
---@return boolean success, string|nil message
function SessionItems.Send()
    if (not SessionItems.CanSend()) then
        return false, "Only the raid leader or an assistant can start a session.";
    end
    if (#items == 0) then
        return false, "Add at least one item to the list first.";
    end

    local ok = FL.LootCouncil.SendToRaid();
    if (ok) then
        SessionItems.Clear();
    end
    return ok;
end

--- Same validation as Send(), but appends the draft list to the session
--- that's already running (via LootCouncil.AddItemsToSession()) instead of
--- starting a new one. Also clears the draft on success.
---@return boolean success, string|nil message
function SessionItems.SendToActiveSession()
    if (not SessionItems.CanSend()) then
        return false, "Only the raid leader or an assistant can add items to the session.";
    end
    if (#items == 0) then
        return false, "Add at least one item to the list first.";
    end
    if (not FL.LootCouncil.IsSessionLive()) then
        return false, "There's no active session to add items to.";
    end

    local ok = FL.LootCouncil.AddItemsToSession(items);
    if (ok) then
        SessionItems.Clear();
    end
    return ok;
end
