--[[
Leader-facing "build the list" window (Phase 1): paste item links or bulk-add
everything still tradeable in your bags, remove any you don't want, then (in
a later phase) send the finished list to the raid.
]]

local FL = ForeverLoot;
local AddItemsWindow = FL.UI.LootCouncilAddItemsWindow;
local LootCouncil = FL.LootCouncil;
local Util = FL.Util;

local MAX_ROWS = 30;
local ROW_HEIGHT = 34;
local ICON_SIZE = 26;
local FALLBACK_ICON = LootCouncil.FALLBACK_ICON;
local ROW_BUTTON_SIZE = 20;

local WINDOW_WIDTH = 300;
local DEFAULT_HEIGHT = 400;
local MAX_HEIGHT = 700;

-- Key this window's saved position is stored under (see Settings.GetWindowPosition/SetWindowPosition).
local POSITION_KEY = "lootCouncilAddItemsWindow";

local frame, itemLinkBox, scrollChild, statusText, sendButton;
local rows = {};

local function setStatus(text, isError)
    statusText:SetText(isError and ("|cffff4444%s|r"):format(text) or ("|cff33ff33%s|r"):format(text));
end

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);
    frame = FL.Theme.CreateWindow("ForeverLootLootCouncilAddItemsWindow", WINDOW_WIDTH,
        FL.Settings.GetLootCouncilAddItemsWindowHeight() or DEFAULT_HEIGHT,
        savedPosition and savedPosition.x or 0, savedPosition and savedPosition.y or 0,
        function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    frame:Hide();

    local title = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.title);
    title:SetPoint("TOP", 0, -10);
    title:SetText("ForeverLoot Council");

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton");
    closeButton:SetSize(20, 20);
    closeButton:SetPoint("TOPRIGHT", -4, -4);
    closeButton:SetScript("OnClick", function() frame:Hide(); end);
    FL.Theme.SkinCloseButton(closeButton);

    -- Item link entry: paste box + Add button.
    local addButton = FL.Theme.CreateButton(frame);
    addButton:SetSize(50, 22);
    addButton:SetPoint("TOPRIGHT", -12, -34);
    addButton:SetText("Add");
    FL.Theme.SkinButton(addButton);

    itemLinkBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate");
    itemLinkBox:SetSize(1, 20); -- width set by anchors below
    itemLinkBox:SetPoint("LEFT", frame, "LEFT", 16, 0);
    itemLinkBox:SetPoint("TOP", addButton, "TOP", 0, 0);
    itemLinkBox:SetPoint("RIGHT", addButton, "LEFT", -6, 0);
    itemLinkBox:SetAutoFocus(false);
    itemLinkBox:SetFontObject(_G[FL.Theme.fonts.input]);
    FL.Theme.SkinEditBox(itemLinkBox);

    -- Shift-clicking a bag/inventory item only auto-inserts its link into one
    -- of Blizzard's own chat edit boxes by default - a plain custom EditBox
    -- like this one isn't wired into that. HandleModifiedItemClick is the
    -- actual function the game calls on every modified item click (this is
    -- the same global RollTracker.lua already hooks for its own alt+click
    -- feature), so hooking it here and inserting into this box ourselves
    -- when it currently holds keyboard focus covers shift-click without
    -- depending on whichever internal function Blizzard's own chat-link
    -- insertion happens to forward to.
    hooksecurefunc("HandleModifiedItemClick", function(itemLink)
        if (itemLink and IsModifiedClick("CHATLINK") and itemLinkBox:IsShown() and itemLinkBox:HasFocus()) then
            itemLinkBox:Insert(itemLink);
        end
    end);

    -- Accepts one or more item links typed/pasted/shift-clicked together.
    local function tryAddFromBox()
        local text = strtrim(itemLinkBox:GetText() or "");
        if (text == "") then return; end

        local added, skipped, found = LootCouncil.DraftAddItemsFromText(text);
        if (not found) then
            setStatus("No item link found in that text.", true);
            return;
        end

        itemLinkBox:SetText("");
        if (added > 0) then
            local suffix = skipped > 0 and (" (%d already in list)"):format(skipped) or "";
            setStatus(("Added %d item%s%s."):format(added, added == 1 and "" or "s", suffix));
        else
            setStatus("Already in the list.", true);
        end
        AddItemsWindow.Refresh();
    end

    addButton:SetScript("OnClick", tryAddFromBox);
    itemLinkBox:SetScript("OnEnterPressed", tryAddFromBox);

    -- Bulk-add: scan the player's own bags for still-tradeable BoP items.
    -- Anchored to `frame` itself (not itemLinkBox, whose own horizontal
    -- center sits left of the window's center because addButton shares its
    -- row) so its width doesn't end up centered on the wrong point and
    -- overflow the window's left edge.
    local addAllButton = FL.Theme.CreateButton(frame);
    addAllButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -62);
    addAllButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -62);
    addAllButton:SetHeight(22);
    addAllButton:SetText("Add All Tradeable From Bags");
    FL.Theme.SkinButton(addAllButton);
    addAllButton:SetScript("OnClick", function()
        local added = LootCouncil.DraftAddAllTradeable();
        if (added > 0) then
            setStatus(("Added %d item%s from your bags."):format(added, added == 1 and "" or "s"));
        else
            setStatus("No new tradeable items found in your bags.");
        end
        AddItemsWindow.Refresh();
    end);

    local scrollFrame = FL.Theme.CreateScrollFrame(frame);
    scrollFrame:SetPoint("TOPLEFT", 12, -108);
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 40);
    FL.Theme.SkinScrollBar(scrollFrame);

    -- Shrinking to minimum should leave exactly one row visible, not the
    -- whole list - measured off the frame/scroll frame's own current heights
    -- (same trick TradeQueueWindow.lua uses) so it can't drift out of sync
    -- with the layout above.
    local minHeight = frame:GetHeight() - scrollFrame:GetHeight() + ROW_HEIGHT;

    scrollChild = CreateFrame("Frame", nil, scrollFrame);
    scrollChild:SetSize(scrollFrame:GetWidth(), MAX_ROWS * ROW_HEIGHT);
    scrollFrame:SetScrollChild(scrollChild);
    scrollFrame:SetScript("OnSizeChanged", function(self, width)
        scrollChild:SetWidth(width);
    end);

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, scrollChild);
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT);
        row:SetPoint("RIGHT", scrollChild, "RIGHT");
        row:SetHeight(ROW_HEIGHT);

        row.icon = row:CreateTexture(nil, "ARTWORK");
        row.icon:SetSize(ICON_SIZE, ICON_SIZE);
        row.icon:SetPoint("LEFT", 6, 0);
        row.icon:SetTexCoord(0.0833, 0.9167, 0.0833, 0.9167);

        row.iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
        FL.Theme.SkinIconBorder(row.iconBorder, row.icon);

        -- Shift-click to chat-link the item, ctrl-click to dress it up
        -- (shared with RollWindow's/TradeQueueWindow's/SoftResImport's icons
        -- via Util). A separate Button laid exactly over the icon texture
        -- (which itself can't receive clicks) rather than making `row`
        -- itself a Button - row has no click behavior of its own here, so
        -- there's nothing for this to steal focus from.
        row.iconButton = CreateFrame("Button", nil, row);
        row.iconButton:SetAllPoints(row.icon);
        row.iconButton:RegisterForClicks("LeftButtonUp");
        row.iconButton:SetScript("OnClick", function(self)
            local parentRow = self:GetParent();
            if (not parentRow.entry) then return; end
            Util.HandleItemLinkClick(parentRow.entry.itemLink);
        end);

        -- Same delete/trash button as the trade queue window, everywhere.
        row.removeButton = FL.Theme.CreateDeleteButton(row, ROW_BUTTON_SIZE);
        row.removeButton:SetPoint("RIGHT", -2, 0);
        row.removeButton:SetScript("OnClick", function(self)
            local parentRow = self:GetParent();
            if (not parentRow.itemIndex) then return; end
            LootCouncil.DraftRemoveItem(parentRow.itemIndex);
            AddItemsWindow.Refresh();
        end);

        row.itemText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
        row.itemText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0);
        row.itemText:SetPoint("RIGHT", row.removeButton, "LEFT", -4, 0);
        row.itemText:SetJustifyH("LEFT");
        row.itemText:SetWordWrap(false);

        -- Also required to be within scrollFrame's own bounds (see
        -- Util.IsMouseOverVisible) - a row scrolled out of the visible list
        -- still occupies its original on-screen rect as far as IsMouseOver
        -- is concerned, since ScrollFrame only clips rendering.
        row:SetScript("OnUpdate", function(self)
            if (self.entry and Util.IsMouseOverVisible(self.icon, scrollFrame)) then
                GameTooltip:SetOwner(self.icon, "ANCHOR_RIGHT");
                GameTooltip:SetHyperlink(self.entry.itemLink);
                GameTooltip:Show();
            elseif (GameTooltip:GetOwner() == self.icon) then
                GameTooltip:Hide();
            end
        end);

        row:Hide();
        rows[i] = row;
    end

    sendButton = FL.Theme.CreateButton(frame);
    sendButton:SetSize(WINDOW_WIDTH - 24, 22);
    sendButton:SetPoint("BOTTOM", 0, 8);
    sendButton:SetText("Send to Raid");
    FL.Theme.SkinAccentButton(sendButton);
    sendButton:SetScript("OnClick", function()
        LootCouncil.SendToRaid();
    end);

    -- statusText sits just above the Send to Raid button, not overlapping it.
    statusText = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
    statusText:SetPoint("BOTTOMLEFT", 12, 36);
    statusText:SetPoint("RIGHT", frame, "RIGHT", -12, 0);
    statusText:SetJustifyH("LEFT");
    statusText:SetWordWrap(false);

    FL.Theme.MakeBottomResizable(frame, WINDOW_WIDTH, minHeight, MAX_HEIGHT, function(height)
        FL.Settings.SetLootCouncilAddItemsWindowHeight(height);
    end);
end

function AddItemsWindow.Refresh()
    if (not frame) then return; end

    local items = LootCouncil.Draft.items;
    scrollChild:SetHeight(math.max(#items * ROW_HEIGHT, 1));

    for i, row in ipairs(rows) do
        local entry = items[i];
        if (entry) then
            row.entry = entry;
            row.itemIndex = i;
            row.icon:SetTexture(Util.GetItemIcon(entry.itemID) or FALLBACK_ICON);
            FL.Theme.SetIconBorderQuality(row.iconBorder, Util.GetItemQuality(entry.itemLink or entry.itemID));
            row.itemText:SetText(entry.itemLink or "?");
            row:Show();
        else
            row.entry = nil;
            row.itemIndex = nil;
            row:Hide();
        end
    end

    sendButton:SetEnabled(#items > 0);
    setStatus(("%d item%s in list"):format(#items, #items == 1 and "" or "s"));
end

function AddItemsWindow.Show()
    ensureFrame();
    frame:Show();
    AddItemsWindow.Refresh();
end

function AddItemsWindow.Hide()
    if (frame) then frame:Hide(); end
end

function AddItemsWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then AddItemsWindow.Hide(); else AddItemsWindow.Show(); end
end

function AddItemsWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then FL.Theme.ResetWindowPosition(frame); end
end
