--[[
Items that couldn't be auto-traded (out of range, trade window didn't open,
or we didn't have the item yet at award time). Click an entry to retry.
]]

local FL = ForeverLoot;
local TradeQueueWindow = FL.UI.TradeQueueWindow;
local Trade = FL.Trade;
local Util = FL.Util;

local MAX_ROWS = 20;
local ROW_HEIGHT = 34;
local ICON_SIZE = 26;
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";
local DELETE_BUTTON_SIZE = 20;

local WINDOW_WIDTH = 280;
local DEFAULT_HEIGHT = 300;
local MAX_HEIGHT = 700;

local frame, scrollChild, statusText;
local rows = {};

-- Key this window's saved position is stored under (see Settings.GetWindowPosition/SetWindowPosition).
local POSITION_KEY = "tradeQueueWindow";

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);
    frame = FL.Theme.CreateWindow("ForeverLootTradeQueueWindow", WINDOW_WIDTH, FL.Settings.GetTradeQueueWindowHeight() or DEFAULT_HEIGHT,
        savedPosition and savedPosition.x or 200, savedPosition and savedPosition.y or 0,
        function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    frame:Hide();

    local title = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.title);
    title:SetPoint("TOP", 0, -10);
    title:SetText("ForeverLoot - Trade Queue");

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton");
    closeButton:SetSize(20, 20);
    closeButton:SetPoint("TOPRIGHT", -4, -4);
    closeButton:SetScript("OnClick", function() frame:Hide(); end);
    FL.Theme.SkinCloseButton(closeButton);

    local hint = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.disableSmall);
    hint:SetPoint("TOP", 0, -30);
    hint:SetWidth(250);
    hint:SetText("Click an item to retry trading it to its winner.");

    local scrollFrame = FL.Theme.CreateScrollFrame(frame);
    scrollFrame:SetPoint("TOPLEFT", 12, -56);
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 32);
    FL.Theme.SkinScrollBar(scrollFrame);

    -- Shrinking the window down to its minimum should leave exactly one
    -- queued item visible (not the whole list, but not none either) - so
    -- unlike RollWindow's minimum (which collapses its row list away
    -- entirely), this adds one ROW_HEIGHT on top of everything ABOVE the
    -- scroll frame plus its bottom margin. That fixed part is measured
    -- directly off the frame/scroll frame's own current heights (rather
    -- than hand-adding up every anchor offset above) so it can't drift out
    -- of sync with that layout.
    local minHeight = frame:GetHeight() - scrollFrame:GetHeight() + ROW_HEIGHT;

    -- Width tracks the scroll frame's own visible width (rather than a fixed
    -- guess at it) so rows always reach exactly to the scrollbar's edge, with
    -- no gap and no overlap, regardless of the window's fixed dimensions
    -- (same trick RollWindow's row list uses).
    scrollChild = CreateFrame("Frame", nil, scrollFrame);
    scrollChild:SetSize(scrollFrame:GetWidth(), MAX_ROWS * ROW_HEIGHT);
    scrollFrame:SetScrollChild(scrollChild);
    scrollFrame:SetScript("OnSizeChanged", function(self, width)
        scrollChild:SetWidth(width);
    end);

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, scrollChild);
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT);
        row:SetPoint("RIGHT", scrollChild, "RIGHT");
        row:SetHeight(ROW_HEIGHT);
        row:RegisterForClicks("LeftButtonUp");

        -- Flat translucent row-wide highlight (same trick as RollWindow's
        -- row list) that spans the full row regardless of which part of it
        -- (icon or text) currently owns mouse focus.
        local rowHighlight = row:CreateTexture(nil, "HIGHLIGHT");
        rowHighlight:SetAllPoints(row);
        rowHighlight:SetColorTexture(1, 1, 1, 0.08);
        row:SetHighlightTexture(rowHighlight);

        row.icon = row:CreateTexture(nil, "ARTWORK");
        row.icon:SetSize(ICON_SIZE, ICON_SIZE);
        row.icon:SetPoint("LEFT", 6, 0);
        -- Crop ~1/12 off each edge (~20% zoom) to trim the icon art's own
        -- padding (same crop RollWindow's itemIcon uses).
        row.icon:SetTexCoord(0.0833, 0.9167, 0.0833, 0.9167);

        -- Border drawn on a separate wrapper frame pulled 1px outside the
        -- icon's own bounds (same trick as RollWindow's iconBorder) so it
        -- doesn't get painted over by the icon's own ARTWORK-layer texture.
        row.iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
        FL.Theme.SkinIconBorder(row.iconBorder, row.icon);

        -- Delete button (right end of the row) - a separate mouse-enabled
        -- Button sitting on top of `row` (as its child, it already gets a
        -- higher frame level automatically), so clicking it never also
        -- triggers row's own OnClick (retry). Removing a queued item is
        -- gated behind SHIFT (see its OnClick below) so a stray click can't
        -- silently drop something the group is still owed.
        row.deleteButton = FL.Theme.CreateDeleteButton(row, DELETE_BUTTON_SIZE);
        row.deleteButton:SetPoint("RIGHT", -2, 0);

        row.deleteButton:SetScript("OnClick", function(self)
            local parentRow = self:GetParent();
            if (not parentRow.entry) then return; end

            if (not IsShiftKeyDown()) then
                statusText:SetText("|cffff4444Hold SHIFT and click the delete button to remove this item.|r");
                return;
            end

            TradeQueueWindow.Delete(parentRow.queueIndex);
        end);

        -- Two separate FontStrings, each individually anchored top/bottom,
        -- rather than one "item\nto winner" string - a single FontString
        -- with only LEFT/RIGHT anchors has no defined height, which was
        -- clipping the second line (the winner's name) off entirely.
        -- Anchored to the icon's TOPRIGHT (not its vertically-centered RIGHT
        -- point) so the item name lines up with the top of the icon, and to
        -- the delete button's LEFT (not the row's own RIGHT) so long item
        -- names never run under the delete icon.
        row.itemText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
        row.itemText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0);
        row.itemText:SetPoint("RIGHT", row.deleteButton, "LEFT", -2, 0);
        row.itemText:SetJustifyH("LEFT");
        row.itemText:SetWordWrap(false);

        row.winnerText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.disableSmall);
        row.winnerText:SetPoint("TOPLEFT", row.itemText, "BOTTOMLEFT", 0, -2);
        row.winnerText:SetPoint("RIGHT", row.deleteButton, "LEFT", -2, 0);
        row.winnerText:SetJustifyH("LEFT");
        row.winnerText:SetWordWrap(false);

        -- Tooltip should only appear while hovering the icon itself, not the
        -- name/winner text next to it. Rather than a separate mouse-enabled
        -- frame over the icon (which would steal mouse focus from `row` and
        -- break the row-wide highlight above), this polls the icon's own
        -- bounds via IsMouseOver - which works on any region, no dedicated
        -- click/motion handling required - so the icon area stays part of
        -- the same clickable row instead of a competing hit-test target.
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

        row:SetScript("OnClick", function(self)
            if (not self.entry) then return; end
            -- Shift-click to chat-link the item, ctrl-click to dress it up
            -- (shared with RollWindow's and SoftResImport's icons via
            -- Util) take priority over the plain-click retry below.
            if (Util.HandleItemLinkClick(self.entry.itemLink)) then return; end
            TradeQueueWindow.Retry(self.queueIndex);
        end);

        row:Hide();
        rows[i] = row;
    end

    statusText = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
    statusText:SetPoint("BOTTOM", 0, 10);
    statusText:SetWidth(250);

    FL.Theme.MakeBottomResizable(frame, WINDOW_WIDTH, minHeight, MAX_HEIGHT, function(height)
        FL.Settings.SetTradeQueueWindowHeight(height);
    end);
end

function TradeQueueWindow.Refresh()
    if (not frame) then return; end

    -- Scroll range (and so the auto-hide in Theme.SkinScrollBar) is driven by
    -- how tall scrollChild is relative to the visible scrollFrame, not by how
    -- many of the MAX_ROWS pooled rows exist - so this has to shrink to the
    -- actual queue length instead of always spanning all MAX_ROWS worth.
    scrollChild:SetHeight(math.max(#Trade.Queue * ROW_HEIGHT, 1));

    local members = Util.groupMembers();

    for i, row in ipairs(rows) do
        local entry = Trade.Queue[i];
        if (entry) then
            row.entry = entry;
            row.queueIndex = i;
            row.icon:SetTexture(entry.itemIcon or Util.GetItemIcon(entry.itemID) or FALLBACK_ICON);
            FL.Theme.SetIconBorderQuality(row.iconBorder, Util.GetItemQuality(entry.itemLink or entry.itemID));
            row.itemText:SetText(entry.itemLink or "?");

            local winner = entry.winner or "?";
            local classFile = Util.lookupClass(members, winner);
            row.winnerText:SetText(("to %s"):format(Util.classColoredName(winner, classFile)));
            row:Show();
        else
            row.entry = nil;
            row:Hide();
        end
    end
end

-- Re-attempt trading a queued entry. Success here only means the item is
-- sitting in the open trade window, not that it's actually been traded - the
-- entry stays queued until Trade.lua's completion watcher confirms
-- ERR_TRADE_COMPLETE and removes it (which also refreshes this window).
function TradeQueueWindow.Retry(index)
    local entry = Trade.Queue[index];
    if (not entry) then return; end

    statusText:SetText("|cffffcc00Retrying...|r");

    Trade.AttemptTrade(entry.winner, entry.itemLink, function(success, reason)
        if (success) then
            statusText:SetText(("|cff33ff33Placed %s - accept the trade to finish.|r"):format(entry.itemLink));
        else
            statusText:SetText("|cffff4444Still couldn't trade - " .. tostring(reason) .. "|r");
        end

        TradeQueueWindow.Refresh();
    end);
end

-- Removes a queued entry outright (no trade attempt) - only ever reached via
-- the row's delete button while SHIFT is held (see that button's OnClick),
-- since dropping an item here means the group is no longer owed it.
function TradeQueueWindow.Delete(index)
    local entry = Trade.Queue[index];
    if (not entry) then return; end

    Trade.QueueRemoveEntry(entry);

    local winner = entry.winner or "?";
    local classFile = Util.lookupClass(Util.groupMembers(), winner);
    statusText:SetText(("|cff33ff33Removed %s to %s from the trade queue.|r"):format(entry.itemLink or "?", Util.classColoredName(winner, classFile)));
    TradeQueueWindow.Refresh();
end

function TradeQueueWindow.Show()
    ensureFrame();
    frame:Show();
    TradeQueueWindow.Refresh();
end

function TradeQueueWindow.Hide()
    if (frame) then frame:Hide(); end
end

function TradeQueueWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then TradeQueueWindow.Hide(); else TradeQueueWindow.Show(); end
end

function TradeQueueWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then FL.Theme.ResetWindowPosition(frame); end
end
