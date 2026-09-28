--[[
Loot Rolls > Chat section (LootChat.lua): prints "X receives loot: [item]" /
"You receive loot: [item]" lines to the main chat window for items of green
rarity or higher (plus anything the user added to the "Also print these
items" list), and owns the two optional chat-frame tweaks next to it -
hiding Blizzard's own "Item Loot" messages on ChatFrame1, and a dedicated
"Loot" chat tab. Blizzard's own CHAT_MSG_LOOT messages are never suppressed
by this file directly; instead a message is only ever printed here when
ChatFrame1 isn't already going to show it natively (see
ChatFrame1:ContainsMessageGroup("LOOT") below), so enabling "Hide Blizzard
loot messages in the main chat tab" (or the user's own chat settings
removing "Item Loot" some other way) is what makes room for this module's
own line instead.
]]

local FL = ForeverLoot;
local LootChat = FL.LootChat;
local Util = FL.Util;

-- Green (Enum.ItemQuality.Uncommon) or higher always prints; anything below
-- that only prints if the user explicitly added it (Settings.IsLootExtraItem).
local MIN_QUALITY = Enum.ItemQuality.Uncommon;

--------------------------------------------------------------------------
-- "Receives loot" message shape-matching
--------------------------------------------------------------------------

-- Patterns built from Blizzard's own loot GlobalStrings via the existing
-- Util.createPattern (RollTracker.lua's own /roll-result matcher uses the
-- same helper on RANDOM_ROLL_RESULT) - built in Init (not here at file
-- scope), once every GlobalStrings global is guaranteed to be set up. Covers
-- other players ("Name receives loot: ...", singular/xN), the player's own
-- loot ("You receive loot: ..."), and items handed over without a roll
-- (quest rewards, bonus rolls: "You receive item: ...").
local RECEIVES_LOOT_TEMPLATES = {
    "LOOT_ITEM", "LOOT_ITEM_MULTIPLE",
    "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE",
    "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
};
local receivesLootPatterns = {}; -- { { template = "...", pattern = "..." }, ... }

local function buildReceivesLootPatterns()
    for _, globalName in ipairs(RECEIVES_LOOT_TEMPLATES) do
        local template = _G[globalName];
        if (template) then
            table.insert(receivesLootPatterns, { template = template, pattern = Util.createPattern(template) });
        end
    end
end

-- True if `message` matches one of the known "receives loot" shapes (other
-- CHAT_MSG_LOOT messages - currency gained, "You created: ...", etc. - never
-- match). The message itself is printed verbatim rather than rebuilt from
-- the template - it's already exactly what Blizzard produced (correctly
-- localized, real item link and all); reconstructing it via
-- string.format(template, ...) turned out to be unreliable, since a
-- template's trailing %s capture (Util.createPattern's non-greedy "(.-)")
-- matches empty whenever nothing follows it in the string to anchor
-- against - which is exactly what happened to LOOT_ITEM_SELF on this
-- client, silently dropping the item link.
local function isReceivesLootMessage(message)
    for _, entry in ipairs(receivesLootPatterns) do
        if (string.find(message, entry.pattern)) then
            return true;
        end
    end
    return false;
end

--------------------------------------------------------------------------
-- Printing
--------------------------------------------------------------------------

local function printReceivesLoot(message, itemID, quality)
    -- Re-checked here (not just by the caller) since this can run after an
    -- async item-load delay, during which the setting or ChatFrame1's own
    -- message groups could have changed.
    if (not FL.Settings.GetLootMessagesEnabled()) then return; end
    if (ChatFrame1:ContainsMessageGroup("LOOT")) then return; end

    local qualifies = (type(quality) == "number" and quality >= MIN_QUALITY) or FL.Settings.IsLootExtraItem(itemID);
    if (not qualifies) then return; end

    local info = ChatTypeInfo["LOOT"];
    DEFAULT_CHAT_FRAME:AddMessage(message, info.r, info.g, info.b, info.id);
end

local function onChatMsgLoot(message)
    -- Chat text is hidden from addons during chat lockdown; there's nothing
    -- we can parse, and touching it would throw (same guard RollTracker.lua
    -- applies to its own CHAT_MSG_SYSTEM handling).
    if (Util.isSecret(message)) then return; end
    if (not FL.Settings.GetLootMessagesEnabled()) then return; end
    -- Blizzard's own line is already about to show in the main window -
    -- printing here too would just duplicate it.
    if (ChatFrame1:ContainsMessageGroup("LOOT")) then return; end

    if (not isReceivesLootMessage(message)) then return; end

    local itemLink = FL.SessionItems.ExtractItemLinks(message)[1];
    if (not itemLink) then return; end
    local itemID = Util.itemIDFromLink(itemLink);

    local quality = Util.GetItemQuality(itemLink);
    if (type(quality) == "number") then
        printReceivesLoot(message, itemID, quality);
    else
        -- Not cached yet (rare - the item was just looted) - resolve it,
        -- then decide. `itemLink` is captured by the closure and re-read
        -- fresh rather than assumed unchanged.
        Item:CreateFromItemLink(itemLink):ContinueOnItemLoad(function()
            printReceivesLoot(message, itemID, Util.GetItemQuality(itemLink));
        end);
    end
end

--------------------------------------------------------------------------
-- Combat-lockdown deferral for the two chat-frame tweaks below. Neither
-- AddMessageGroup/RemoveMessageGroup nor FCF_OpenNewWindow/FCF_Close is
-- actually engine-protected (chat tabs aren't secure UI the way action bars
-- are), so this is defensive-only - but cheap, and matches the addon's own
-- existing convention for deferring a chat-touching action
-- (Util.SendChatMessageSafe/FlushChatMessageQueue in Core/Util.lua).
--------------------------------------------------------------------------

local pendingChatFrameActions = {};

local function flushPendingChatFrameActions()
    if (#pendingChatFrameActions == 0 or InCombatLockdown()) then return; end
    local queued = pendingChatFrameActions;
    pendingChatFrameActions = {};
    for _, fn in ipairs(queued) do fn(); end
end

local function runOrQueue(fn)
    if (InCombatLockdown()) then
        table.insert(pendingChatFrameActions, fn);
    else
        fn();
    end
end

--------------------------------------------------------------------------
-- "Hide Blizzard loot messages in the main chat tab"
--------------------------------------------------------------------------

function LootChat.ApplyHideBlizzardMain(enabled)
    runOrQueue(function()
        if (enabled) then
            if (ChatFrame1:ContainsMessageGroup("LOOT")) then
                ChatFrame1:RemoveMessageGroup("LOOT");
                FL.Settings.SetLootRemovedFromMain(true);
            end
            -- Already off (the user's own doing, or a prior run) - leave the
            -- bookkeeping flag false, so turning this back off later won't
            -- touch something we never changed.
        else
            if (FL.Settings.GetLootRemovedFromMain()) then
                ChatFrame1:AddMessageGroup("LOOT");
                FL.Settings.SetLootRemovedFromMain(false);
            end
        end
    end);
end

--------------------------------------------------------------------------
-- "Add a 'Loot' chat tab"
--------------------------------------------------------------------------

-- Finds a live chat window frame named "Loot" - the one we created/adopted
-- before (by saved frame id) if it still checks out, otherwise any existing
-- docked tab already named "Loot" (so a matching tab the user made by hand,
-- or one left over from before a settings wipe, is adopted rather than
-- duplicated).
local function findExistingLootTabFrame()
    local savedID = FL.Settings.GetLootTabFrameID();
    if (savedID and FCF_GetChatWindowInfo(savedID) == "Loot") then
        return _G["ChatFrame" .. savedID];
    end

    for i = 1, Constants.ChatFrameConstants.MaxChatWindows do
        if (FCF_GetChatWindowInfo(i) == "Loot") then
            return _G["ChatFrame" .. i];
        end
    end

    return nil;
end

function LootChat.ApplyLootTab(enabled)
    runOrQueue(function()
        if (enabled) then
            local frame = findExistingLootTabFrame();
            if (not frame) then
                frame = FCF_OpenNewWindow("Loot", true); -- true = don't seed SAY/YELL/etc.
                if (not frame) then
                    if (LootChat.statusCallback) then
                        LootChat.statusCallback("error", "No free chat windows. Close a chat tab and try again.");
                    end
                    FL.Settings.ForceLootTabDisabled();
                    if (LootChat.uiRefreshCallback) then LootChat.uiRefreshCallback(); end
                    return;
                end
            end

            frame:RemoveAllMessageGroups();
            frame:RemoveAllChannels();
            frame:AddMessageGroup("LOOT");
            frame:AddMessageGroup("MONEY");
            FL.Settings.SetLootTabFrameID(frame:GetID());
        else
            local savedID = FL.Settings.GetLootTabFrameID();
            if (savedID and FCF_GetChatWindowInfo(savedID) == "Loot") then
                FCF_Close(_G["ChatFrame" .. savedID]);
            end
            FL.Settings.SetLootTabFrameID(nil);
        end
    end);
end

--------------------------------------------------------------------------
-- Init / PLAYER_LOGIN reconciliation
--------------------------------------------------------------------------

function LootChat.Init()
    buildReceivesLootPatterns();

    -- ChatFrame1's own message-group state is Blizzard's, not something we
    -- persist ourselves - re-run the on-path (idempotent) so a Blizzard
    -- chat-settings reset doesn't quietly bring "Item Loot" back.
    if (FL.Settings.GetLootHideBlizzardMain()) then
        LootChat.ApplyHideBlizzardMain(true);
    end

    if (FL.Settings.GetLootTabEnabled()) then
        local frame = findExistingLootTabFrame();
        if (frame) then
            FL.Settings.SetLootTabFrameID(frame:GetID());
        else
            -- The user closed it by hand since last login - their action
            -- wins, it's not recreated out from under them.
            FL.Settings.ForceLootTabDisabled();
            if (LootChat.uiRefreshCallback) then LootChat.uiRefreshCallback(); end
        end
    end

    local eventFrame = CreateFrame("Frame");
    eventFrame:RegisterEvent("CHAT_MSG_LOOT");
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED");
    eventFrame:SetScript("OnEvent", function(_, event, message)
        if (event == "PLAYER_REGEN_ENABLED") then
            flushPendingChatFrameActions();
        else
            onChatMsgLoot(message);
        end
    end);
end
