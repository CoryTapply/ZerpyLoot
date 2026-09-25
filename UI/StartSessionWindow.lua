--[[
Leader-facing "build the session list" window - replaces the old
LootCouncilAddItemsWindow. Built directly with the settings window's own
control vocabulary (UI.Colors/UI.Sizes.startSession/UI.SetFont/UI.Skin), not
FL.Theme - this window has exactly one look, it doesn't follow the active
skin. Session item data/logic (add, remove, clear, tradeable check, bag scan,
send) lives in Session/SessionItems.lua, not here.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.startSession;
local SharedLayout = FL.UI.Sizes.layout;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Widgets = FL.UI.SettingsWidgets;
local SessionItems = FL.SessionItems;
local Util = FL.Util;
local StartSessionWindow = FL.UI.StartSessionWindow;

local WINDOW_WIDTH = Sizes.window.width;
local WINDOW_HEIGHT = Sizes.window.height;
local MAX_ROWS = 30;
local FALLBACK_ICON = FL.LootCouncil.FALLBACK_ICON;
local DELETE_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\trash.tga";

local DROP_STRIP_DEFAULT_TEXT = "+  Drop an item here, or Shift-click it in your bags";

-- Key this window's saved position is stored under (see
-- Settings.GetWindowPosition/SetWindowPosition). OLD_POSITION_KEY is the
-- deleted AddItemsWindow's own key - migrated once below so a player who had
-- that window positioned somewhere doesn't lose it.
local POSITION_KEY = "startSessionWindow";
local OLD_POSITION_KEY = "lootCouncilAddItemsWindow";

local frame, dropStrip, dropStripText, listBox, listScroll, listScrollChild, listEmptyText, countText, clearButton, startButton;
local rows = {};

--------------------------------------------------------------------------
-- Row content (name/type-slot text, quality-colored icon border) - split out
-- from Refresh() since it re-runs asynchronously once an uncached item's
-- info actually loads (see the ContinueOnItemLoad branch below).
--------------------------------------------------------------------------

local function paintRowText(row, entry)
    local name, _, quality, _, _, itemType, itemSubType, _, equipLoc = Util.GetItemInfo(entry.itemLink);

    if (name) then
        local r, g, b = Util.GetItemQualityColor(quality);
        row.nameText:SetText(name);
        row.nameText:SetTextColor(r or 1, g or 1, b or 1);
        row.iconBorder:SetBackdropBorderColor(r or 0, g or 0, b or 0);

        local slot = (equipLoc and equipLoc ~= "") and _G[equipLoc] or nil;
        local isEquippable = slot ~= nil and slot ~= "";
        row.typeText:SetText(Util.JoinTypeParts(isEquippable and slot or itemType, itemSubType));
    else
        -- Not cached yet - show the raw link text and fill in the real name/
        -- type/quality once C_Item finishes loading it.
        row.nameText:SetText(entry.itemLink);
        row.nameText:SetTextColor(unpack(Colors.text));
        row.typeText:SetText("");
        row.iconBorder:SetBackdropBorderColor(unpack(Colors.transparent));

        local item = Item:CreateFromItemLink(entry.itemLink);
        item:ContinueOnItemLoad(function()
            if (row.entry == entry) then paintRowText(row, entry); end
        end);
    end
end

--------------------------------------------------------------------------
-- Shared drop/drag/click-to-drop handler - wired onto the drop strip, the
-- item-list box, its scroll frame, and every row (see Step 4 of the design:
-- OnReceiveDrag covers drag-and-release, OnMouseUp covers click-to-pickup
-- then click-to-place).
--------------------------------------------------------------------------

local function handleCursorDrop()
    local cursorType, _, itemLink = GetCursorInfo();
    if (cursorType ~= "item") then return; end

    SessionItems.AddFromCursor(itemLink);
    ClearCursor(); -- item snaps back into the bag either way - nothing is moved/destroyed

    StartSessionWindow.Refresh();
end

--------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------

local function createTitleBar()
    local titleBar = CreateFrame("Frame", nil, frame);
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
    titleBar:SetHeight(Sizes.titleBarHeight);

    titleBar:EnableMouse(true);
    titleBar:RegisterForDrag("LeftButton");
    titleBar:SetScript("OnDragStart", function() frame:StartMoving(); end);
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing();
        Pixel.SnapPosition(frame, function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    end);

    local title = titleBar:CreateFontString(nil, "OVERLAY");
    SetFont(title, "windowTitle");
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0);
    title:SetText("ForeverLoot - Start Session");
    title:SetTextColor(unpack(Colors.titlePurple));

    local divider = titleBar:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 2, 0);
    divider:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -2, 0);
    divider:SetHeight(Pixel.PixelSize(1));

    local closeButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    closeButton:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -8, -8);
    Skin.CloseButton(closeButton);
    closeButton:SetScript("OnClick", function() frame:Hide(); end);

    return titleBar;
end

local function createHeader()
    local header = CreateFrame("Frame", nil, frame);
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.contentPadX, -(Sizes.titleBarHeight + Sizes.contentPadTop));
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.contentPadX, -(Sizes.titleBarHeight + Sizes.contentPadTop));
    header:SetHeight(Sizes.headerHeight);

    -- Title text + Add All button share this row so the button can center on
    -- the title line alone, without the subtitle (which needs the window's
    -- full narrower width) ever being in its way.
    local titleRow = CreateFrame("Frame", nil, header);
    titleRow:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0);
    titleRow:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 0);
    titleRow:SetHeight(Sizes.headerAddAllHeight);

    local title = titleRow:CreateFontString(nil, "OVERLAY");
    SetFont(title, "pageTitle");
    title:SetTextColor(unpack(Colors.gold));
    title:SetPoint("LEFT", titleRow, "LEFT", 0, 0);
    title:SetWordWrap(false);
    title:SetText("Session Items");

    local subtitle = header:CreateFontString(nil, "OVERLAY");
    SetFont(subtitle, "small");
    subtitle:SetTextColor(unpack(Colors.muted));
    subtitle:SetPoint("TOPLEFT", titleRow, "BOTTOMLEFT", 0, -Sizes.headerSubtitleGap);
    subtitle:SetPoint("TOPRIGHT", titleRow, "BOTTOMRIGHT", 0, -Sizes.headerSubtitleGap);
    subtitle:SetJustifyH("LEFT");
    subtitle:SetText("Items the council will vote on this session.");

    local addAllButton = Widgets.CreateFlatButton(header, "Add All", "default");
    addAllButton:SetSize(Sizes.headerAddAllWidth, Sizes.headerAddAllHeight);
    addAllButton:SetPoint("RIGHT", titleRow, "RIGHT", 0, 0);
    addAllButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT");
        GameTooltip:AddLine("Add every tradeable item in your bags.", 1, 1, 1, true);
        GameTooltip:Show();
    end);
    addAllButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);
    addAllButton:SetScript("OnClick", function()
        SessionItems.AddAllTradeableFromBags();
        StartSessionWindow.Refresh();
    end);

    return header;
end

-- Drop-strip visual state: idle, "item on cursor", and "item on cursor AND
-- hovering the strip/list" (a bit brighter). cursorHasItem/cursorItemName
-- come from the CURSOR_CHANGED watcher below; isOverDropZone comes from
-- OnEnter/OnLeave on the strip and the item list.
local cursorHasItem = false;
local cursorItemName = nil;
local isOverDropZone = false;

local function updateDropStripVisual()
    if (not cursorHasItem) then
        dropStrip:SetBackdropColor(unpack(Colors.optionsStripBg));
        dropStrip:SetDashColor(unpack(Colors.checkboxBorder));
        dropStripText:SetTextColor(unpack(Colors.muted));
        dropStripText:SetText(DROP_STRIP_DEFAULT_TEXT);
        return;
    end

    dropStrip:SetBackdropColor(unpack(isOverDropZone and Colors.primaryBg or Colors.councilFill));
    dropStrip:SetDashColor(unpack(Colors.gold));
    dropStripText:SetTextColor(unpack(Colors.gold));
    dropStripText:SetText(("Release to add %s"):format(cursorItemName or "item"));
end

local function onDropZoneEnter()
    isOverDropZone = true;
    updateDropStripVisual();
end

local function onDropZoneLeave()
    isOverDropZone = false;
    updateDropStripVisual();
end

local function createDropStrip(header)
    local strip = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    strip:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -Sizes.dropStripGap);
    strip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -Sizes.dropStripGap);
    strip:SetHeight(Sizes.dropStripHeight);
    Theme.Helpers.SetFlatBackdrop(strip, Colors.optionsStripBg, Colors.transparent, 0);
    Skin.DashedBorder(strip, Colors.checkboxBorder[1], Colors.checkboxBorder[2], Colors.checkboxBorder[3], 1, Sizes.dropStripDash, 1);

    local text = strip:CreateFontString(nil, "OVERLAY");
    SetFont(text, "small");
    text:SetTextColor(unpack(Colors.muted));
    text:SetPoint("CENTER", strip, "CENTER", 0, 0);
    text:SetText(DROP_STRIP_DEFAULT_TEXT);
    dropStripText = text;

    strip:EnableMouse(true);
    strip:SetScript("OnReceiveDrag", handleCursorDrop);
    strip:SetScript("OnMouseUp", handleCursorDrop);
    strip:HookScript("OnEnter", onDropZoneEnter);
    strip:HookScript("OnLeave", onDropZoneLeave);

    return strip;
end

local function createFooter()
    local footer = CreateFrame("Frame", nil, frame);
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", Sizes.contentPadX, Sizes.footerBottomPad);
    footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Sizes.contentPadX, Sizes.footerBottomPad);
    footer:SetHeight(Sizes.footerHeight);

    local divider = footer:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, 0);
    divider:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, 0);
    divider:SetHeight(Pixel.PixelSize(1));

    -- Buttons anchor to the footer's BOTTOM (never to the divider above), so
    -- there's always footerDividerGap of daylight between the line and the
    -- button tops regardless of anything else in the footer.
    local buttonRow = CreateFrame("Frame", nil, footer);
    buttonRow:SetPoint("BOTTOMLEFT", footer, "BOTTOMLEFT", 0, 0);
    buttonRow:SetPoint("BOTTOMRIGHT", footer, "BOTTOMRIGHT", 0, 0);
    buttonRow:SetHeight(Sizes.footerRowHeight);

    countText = buttonRow:CreateFontString(nil, "OVERLAY");
    SetFont(countText, "sectionHeader");
    countText:SetTextColor(unpack(Colors.gold));
    countText:SetPoint("LEFT", buttonRow, "LEFT", 0, 0);

    startButton = Widgets.CreateFlatButton(buttonRow, "Start Session", "primary");
    startButton:SetSize(Sizes.footerStartWidth, Sizes.footerRowHeight);
    startButton:SetPoint("RIGHT", buttonRow, "RIGHT", 0, 0);
    startButton:SetScript("OnClick", function()
        local ok, message = SessionItems.Send();
        if (not ok and message) then
            print("|cff8865ffForeverLoot|r " .. message);
        end
        StartSessionWindow.Refresh();
    end);
    startButton:HookScript("OnEnter", function(self)
        if (not SessionItems.CanSend()) then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT");
            GameTooltip:AddLine("Only the raid leader or an assistant can start a session.", 1, 1, 1, true);
            GameTooltip:Show();
        end
    end);
    startButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);

    clearButton = Widgets.CreateFlatButton(buttonRow, "Clear", "default");
    clearButton:SetSize(Sizes.footerClearWidth, Sizes.footerRowHeight);
    clearButton:SetPoint("RIGHT", startButton, "LEFT", -Sizes.footerButtonGap, 0);
    clearButton:SetScript("OnClick", function()
        SessionItems.Clear();
        StartSessionWindow.Refresh();
    end);

    return footer;
end

local function createRow(parent, index)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate");
    row:SetPoint("TOPLEFT", 0, -(index - 1) * (Sizes.rowHeight + Sizes.rowSpacing));
    row:SetPoint("RIGHT", parent, "RIGHT");
    row:SetHeight(Sizes.rowHeight);
    Theme.Helpers.SetFlatBackdrop(row, Colors.memberBg, Colors.memberBorder, 1);

    row:EnableMouse(true);
    row:SetScript("OnReceiveDrag", handleCursorDrop);
    row:SetScript("OnMouseUp", handleCursorDrop);
    row:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(Colors.checkboxBorder)); end);
    row:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(Colors.memberBorder)); end);

    row.icon = row:CreateTexture(nil, "ARTWORK");
    row.icon:SetSize(Sizes.rowIconSize, Sizes.rowIconSize);
    row.icon:SetPoint("LEFT", row, "LEFT", Sizes.listPadding, 0);
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    row.iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
    row.iconBorder:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -1, 1);
    row.iconBorder:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(row.iconBorder, nil, Colors.transparent, 1);

    row.removeButton = CreateFrame("Button", nil, row, "BackdropTemplate");
    row.removeButton:SetSize(Sizes.rowButtonSize, Sizes.rowButtonSize);
    row.removeButton:SetPoint("RIGHT", row, "RIGHT", -Sizes.listPadding, 0);
    row.removeButton:RegisterForClicks("LeftButtonUp");

    row.removeButton.icon = row.removeButton:CreateTexture(nil, "ARTWORK");
    local removeIconSize = math.floor(Sizes.rowButtonSize * 0.7 + 0.5);
    row.removeButton.icon:SetSize(removeIconSize, removeIconSize);
    row.removeButton.icon:SetPoint("CENTER");
    row.removeButton.icon:SetTexture(DELETE_ICON_TEXTURE);

    local function paintRemoveDefault()
        Theme.Helpers.SetFlatBackdrop(row.removeButton, Colors.transparent, Colors.transparent, 1);
        row.removeButton.icon:SetVertexColor(unpack(Colors.muted));
    end
    local function paintRemoveHover()
        Theme.Helpers.SetFlatBackdrop(row.removeButton, Colors.sessionDeleteHoverBg, Colors.skinCloseBorder, 1);
        row.removeButton.icon:SetVertexColor(unpack(Colors.sessionDeleteHoverIcon));
    end
    paintRemoveDefault();
    row.removeButton:HookScript("OnEnter", function(self)
        paintRemoveHover();
        GameTooltip:SetOwner(self, "ANCHOR_LEFT");
        GameTooltip:AddLine("Remove", 1, 1, 1);
        GameTooltip:Show();
    end);
    row.removeButton:HookScript("OnLeave", function()
        paintRemoveDefault();
        GameTooltip:Hide();
    end);
    row.removeButton:SetScript("OnClick", function()
        if (not row.itemIndex) then return; end
        SessionItems.RemoveItem(row.itemIndex);
        StartSessionWindow.Refresh();
    end);

    row.nameText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.nameText, "body");
    row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", Sizes.rowIconTextGap, 0);
    row.nameText:SetPoint("RIGHT", row.removeButton, "LEFT", -Sizes.rowButtonTextGap, 0);
    row.nameText:SetJustifyH("LEFT");
    row.nameText:SetWordWrap(false);

    row.typeText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.typeText, "small");
    row.typeText:SetTextColor(unpack(Colors.muted));
    row.typeText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -Sizes.rowTextLineGap);
    row.typeText:SetPoint("RIGHT", row.nameText, "RIGHT", 0, 0);
    row.typeText:SetJustifyH("LEFT");
    row.typeText:SetWordWrap(false);

    -- Tooltip - only over the icon itself, not the whole row. Also required
    -- to be within listScroll's own bounds (Util.IsMouseOverVisible) - a row
    -- scrolled out of the visible list still occupies its original on-screen
    -- rect as far as IsMouseOver is concerned, since ScrollFrame only clips
    -- rendering.
    row:SetScript("OnUpdate", function(self)
        if (self.entry and Util.IsMouseOverVisible(self.icon, listScroll)) then
            GameTooltip:SetOwner(self.icon, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink(self.entry.itemLink);
            GameTooltip:Show();
        elseif (GameTooltip:GetOwner() == self.icon) then
            GameTooltip:Hide();
        end
    end);

    row:Hide();
    return row;
end

local function createList()
    listBox = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(listBox, Colors.sessionListBg, Colors.memberBorder, 1);
    listBox:EnableMouse(true);
    listBox:SetScript("OnReceiveDrag", handleCursorDrop);
    listBox:SetScript("OnMouseUp", handleCursorDrop);
    listBox:HookScript("OnEnter", onDropZoneEnter);
    listBox:HookScript("OnLeave", onDropZoneLeave);

    local listLabel = listBox:CreateFontString(nil, "OVERLAY");
    SetFont(listLabel, "small");
    listLabel:SetTextColor(unpack(Colors.muted));
    listLabel:SetPoint("TOPLEFT", listBox, "TOPLEFT", Sizes.listPadding, -Sizes.listPadding);
    listLabel:SetText("ITEMS");

    -- Rows fill the list width minus the scrollbar's own space (bar + gap +
    -- a small inset off the listBox border) - no extra padding term here, or
    -- it leaves an empty column to the right of the rows.
    local scrollbarSpace = SharedLayout.scrollbarWidth + Sizes.listScrollbarGap + Sizes.listScrollbarInset;

    listScroll = CreateFrame("ScrollFrame", "ForeverLootStartSessionWindowScroll", listBox, "UIPanelScrollFrameTemplate");
    listScroll:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -Sizes.listLabelGap);
    listScroll:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -scrollbarSpace, Sizes.listPadding);
    listScroll:EnableMouse(true);
    listScroll:SetScript("OnReceiveDrag", handleCursorDrop);
    listScroll:SetScript("OnMouseUp", handleCursorDrop);

    listScrollChild = CreateFrame("Frame", nil, listScroll);
    listScrollChild:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0);
    listScroll:SetScrollChild(listScrollChild);
    listScroll:SetScript("OnSizeChanged", function(self, width) listScrollChild:SetWidth(width); end);

    local listScrollBar = Skin.ScrollBar(listScroll);
    if (listScrollBar) then
        listScrollBar:ClearAllPoints();
        listScrollBar:SetPoint("TOP", listScroll, "TOP", 0, 0);
        listScrollBar:SetPoint("BOTTOM", listScroll, "BOTTOM", 0, 0);
        listScrollBar:SetPoint("RIGHT", listBox, "RIGHT", -Sizes.listScrollbarInset, 0);
    end

    Theme.Helpers.EnableSmoothScroll(listScroll, { step = Sizes.rowHeight + Sizes.rowSpacing });

    listEmptyText = listBox:CreateFontString(nil, "OVERLAY");
    SetFont(listEmptyText, "small");
    listEmptyText:SetTextColor(unpack(Colors.controlHover));
    listEmptyText:SetPoint("CENTER", listScroll, "CENTER", 0, 0);
    listEmptyText:SetText("No items yet. Use Add All, or drop items above.");
    listEmptyText:Hide();

    for i = 1, MAX_ROWS do
        rows[i] = createRow(listScrollChild, i);
    end

    return listBox;
end

--------------------------------------------------------------------------
-- Cursor-drag highlight + shift-click add
--------------------------------------------------------------------------

local function createCursorWatcher()
    local watcher = CreateFrame("Frame");
    watcher:RegisterEvent("CURSOR_CHANGED");
    watcher:SetScript("OnEvent", function()
        if (not frame:IsShown()) then return; end

        local cursorType, _, itemLink = GetCursorInfo();
        cursorHasItem = (cursorType == "item");
        cursorItemName = (cursorHasItem and itemLink) and Util.GetItemInfo(itemLink) or nil;
        updateDropStripVisual();
    end);
end

-- HandleModifiedItemClick is the actual function the game calls on every
-- modified item click (RollTracker.lua and the old AddItemsWindow both
-- hooked this same global for their own click features). Only installed
-- once, at file scope - it no-ops until `frame` exists and is shown.
hooksecurefunc("HandleModifiedItemClick", function(itemLink)
    if (not (frame and frame:IsShown())) then return; end
    if (not itemLink or not IsShiftKeyDown()) then return; end
    if (ChatEdit_GetActiveWindow() ~= nil) then return; end -- let normal link-pasting into chat happen

    if (StackSplitFrame and StackSplitFrame:IsShown()) then
        StackSplitFrame:Hide();
    end

    SessionItems.AddFromCursor(itemLink);
    StartSessionWindow.Refresh();
end);

--------------------------------------------------------------------------
-- Window lifecycle
--------------------------------------------------------------------------

local function ensureFrame()
    if (frame) then return; end

    if (not FL.Settings.GetWindowPosition(POSITION_KEY)) then
        local oldPosition = FL.Settings.GetWindowPosition(OLD_POSITION_KEY);
        if (oldPosition) then
            FL.Settings.SetWindowPosition(POSITION_KEY, oldPosition.x, oldPosition.y);
        end
    end
    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootStartSessionWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    Pixel.RegisterWindow(frame, {
        width = WINDOW_WIDTH, height = WINDOW_HEIGHT,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    createTitleBar();
    local header = createHeader();
    dropStrip = createDropStrip(header);
    local footer = createFooter();

    createList();
    listBox:SetPoint("TOPLEFT", dropStrip, "BOTTOMLEFT", 0, -Sizes.listGap);
    listBox:SetPoint("TOPRIGHT", dropStrip, "BOTTOMRIGHT", 0, -Sizes.listGap);
    listBox:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, Sizes.footerScrollGap);
    listBox:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, Sizes.footerScrollGap);

    createCursorWatcher();

    frame:HookScript("OnHide", function()
        cursorHasItem = false;
        cursorItemName = nil;
        isOverDropZone = false;
        updateDropStripVisual();
    end);

    tinsert(UISpecialFrames, "ForeverLootStartSessionWindow");
end

function StartSessionWindow.Refresh()
    if (not frame) then return; end

    -- If the list was already scrolled to the bottom, stay pinned there so a
    -- newly-added item (which lands at the bottom) scrolls into view. The
    -- ScrollFrame doesn't recompute its scroll range synchronously when the
    -- scroll child resizes below - GetVerticalScrollRange() and the clamp
    -- inside SetVerticalScroll both still see the pre-resize range for the
    -- rest of this frame - so the actual re-scroll is deferred to the next
    -- frame via C_Timer.After(0, ...), by which point the range is current.
    local pendingTarget = listScroll.zlSmoothScrollTarget and listScroll.zlSmoothScrollTarget();
    local effectiveScroll = pendingTarget or listScroll:GetVerticalScroll();
    local wasAtBottom = effectiveScroll >= (listScroll:GetVerticalScrollRange() - 1);

    local sessionItems = SessionItems.GetItems();
    local count = #sessionItems;

    listScrollChild:SetHeight(math.max(count * (Sizes.rowHeight + Sizes.rowSpacing), 1));

    if (wasAtBottom) then
        C_Timer.After(0, function()
            if (listScroll) then
                listScroll:SetVerticalScroll(listScroll:GetVerticalScrollRange());
            end
        end);
    end

    for i, row in ipairs(rows) do
        local entry = sessionItems[i];
        if (entry) then
            row.entry = entry;
            row.itemIndex = i;
            row.icon:SetTexture(Util.GetItemIcon(entry.itemID) or FALLBACK_ICON);
            paintRowText(row, entry);
            row:Show();
        else
            row.entry = nil;
            row.itemIndex = nil;
            row:Hide();
        end
    end

    listEmptyText:SetShown(count == 0);
    countText:SetText(("%d item%s"):format(count, count == 1 and "" or "s"));

    local canSend = SessionItems.CanSend();
    clearButton:SetEnabled(count > 0);
    startButton:SetEnabled(count > 0 and canSend);

    if (listScroll.ScrollBar and listScroll.ScrollBar.zlUpdateVisibility) then
        listScroll.ScrollBar.zlUpdateVisibility();
    end
end

function StartSessionWindow.Show()
    ensureFrame();
    frame:Show();
    StartSessionWindow.Refresh();
end

function StartSessionWindow.Hide()
    if (frame) then frame:Hide(); end
end

function StartSessionWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then StartSessionWindow.Hide(); else StartSessionWindow.Show(); end
end

function StartSessionWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
