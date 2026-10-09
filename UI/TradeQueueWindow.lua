--[[
Items that couldn't be auto-traded (out of range, trade window didn't open,
or we didn't have the item yet at award time). Click a row to retry it, or
Shift-click its trash icon to drop it from the queue. Fixed-look window (see
UI.Colors/UI.Sizes.tradeQueue/UI.SetFont/UI.Skin, not FL.Theme) - built the
same way as UI/StartSessionWindow.lua. All trading logic/queue data lives in
Trade.lua; this file is UI only.
]]

local FL = ForeverLoot;
local TradeQueueWindow = FL.UI.TradeQueueWindow;
local Trade = FL.Trade;
local Util = FL.Util;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.tradeQueue;
local SharedLayout = FL.UI.Sizes.layout;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;

local WINDOW_WIDTH = Sizes.window.width;
local WINDOW_HEIGHT = Sizes.window.height;
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";
local DELETE_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\trash.tga";
local CHECK_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Award\\Check.tga";
local DOT_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Dot.tga";

-- Key this window's saved position is stored under (see
-- Settings.GetWindowPosition/SetWindowPosition) - unchanged from the old
-- window, so an existing saved position carries over with no migration.
local POSITION_KEY = "tradeQueueWindow";

local frame, listBox, listScroll, listScrollChild, emptyState;
local countNumberText, countLabelText, statusDot, statusText;
local rows = {};

--------------------------------------------------------------------------
-- Per-row state -> tag text/color and border color. "queued" is the default
-- Trade.GetEntryState returns for any entry with no tracked state yet.
--------------------------------------------------------------------------

local STATE_TAG_TEXT = {
    queued = "Queued",
    busy = "Trading…",
    failed = "Failed",
};

local STATE_TAG_COLOR = {
    queued = Colors.controlHover,
    busy = Colors.gold,
    failed = Colors.sessionDeleteHoverIcon,
};

local STATE_BORDER_COLOR = {
    queued = Colors.memberBorder,
    busy = Colors.gold,
    failed = Colors.awardWarningBorder,
};

local STATUS_KIND_COLOR = {
    error = Colors.sessionDeleteHoverIcon,
    working = Colors.gold,
    success = Colors.respondSentLabel,
    info = Colors.description,
};

-- Trade.AttemptTrade's own reason strings, restated in the window's short
-- "- <reason>." style. Falls back to the raw reason (period-normalized) for
-- anything not listed here, so a future reason added in Trade.lua degrades
-- gracefully instead of showing nothing.
local FAILURE_REASON_TEXT = {
    ["You don't have this item in your bags."] = "it isn't in your bags.",
    ["You're already trading with someone else."] = "you're already trading with someone else.",
    ["Trade window did not open."] = "the trade window didn't open.",
};

local function describeFailure(reason)
    if (FAILURE_REASON_TEXT[reason]) then return FAILURE_REASON_TEXT[reason]; end
    if (reason) then return (reason:gsub("%.+$", "") .. "."); end
    return "something went wrong.";
end

--------------------------------------------------------------------------
-- SetStatus - the one function every status message in this window goes
-- through (see the Notify* functions and Retry/Delete below).
--------------------------------------------------------------------------

local function SetStatus(kind, text)
    local color = STATUS_KIND_COLOR[kind] or Colors.description;
    statusText:SetText(text or "");
    statusText:SetTextColor(unpack(color));
    statusDot:SetVertexColor(unpack(color));
    statusDot:SetShown(text ~= nil and text ~= "");
end

--------------------------------------------------------------------------
-- Row content/state painting
--------------------------------------------------------------------------

local function repaintRowState(row)
    local entry = row.entry;
    if (not entry) then return; end

    local state = Trade.GetEntryState(entry);
    row:SetBackdropBorderColor(unpack(STATE_BORDER_COLOR[state] or Colors.memberBorder));
    row:SetBackdropColor(unpack(Colors.memberBg));
    row.tagText:SetText(STATE_TAG_TEXT[state] or STATE_TAG_TEXT.queued);
    row.tagText:SetTextColor(unpack(STATE_TAG_COLOR[state] or STATE_TAG_COLOR.queued));

    -- Busy rows ignore clicks entirely (see the row-state rules below) -
    -- disabling mouse here also suppresses the hover repaint, so a busy row
    -- can't flash the hover look either.
    row.mainButton:EnableMouse(state ~= "busy");
end

local function paintRow(row, entry, members)
    row.icon:SetTexture(entry.itemIcon or Util.GetItemIcon(entry.itemID) or FALLBACK_ICON);

    local r, g, b = Util.GetItemQualityColor(Util.GetItemQuality(entry.itemLink or entry.itemID));
    row.iconBorder:SetBackdropBorderColor(r or 0, g or 0, b or 0);

    row.nameText:SetText(entry.itemLink or "?");
    row.nameText:SetTextColor(r or 1, g or 1, b or 1);

    local winner = entry.winner or "?";
    local classFile = Util.lookupClass(members, winner);
    row.winnerText:SetText(("to %s"):format(Util.classColoredName(winner, classFile)));

    repaintRowState(row);
end

--------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------

local function createRow(parent, index)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate");
    row:SetPoint("TOPLEFT", 0, -(index - 1) * (Sizes.rowHeight + Sizes.rowSpacing));
    row:SetPoint("RIGHT", parent, "RIGHT");
    row:SetHeight(Sizes.rowHeight);
    Theme.Helpers.SetFlatBackdrop(row, Colors.memberBg, Colors.memberBorder, 1);

    -- Trash button first, so the main button (below) can be sized to stop
    -- short of it and never steal its clicks despite covering the rest of
    -- the row.
    row.trashButton = CreateFrame("Button", nil, row, "BackdropTemplate");
    row.trashButton:SetSize(Sizes.trashButtonSize, Sizes.trashButtonSize);
    row.trashButton:SetPoint("RIGHT", row, "RIGHT", -Sizes.trashButtonInset, 0);
    row.trashButton:RegisterForClicks("LeftButtonUp");

    row.trashButton.icon = row.trashButton:CreateTexture(nil, "ARTWORK");
    local trashIconSize = math.floor(Sizes.trashButtonSize * 0.7 + 0.5);
    row.trashButton.icon:SetSize(trashIconSize, trashIconSize);
    row.trashButton.icon:SetPoint("CENTER");
    row.trashButton.icon:SetTexture(DELETE_ICON_TEXTURE);

    local function paintTrashDefault()
        Theme.Helpers.SetFlatBackdrop(row.trashButton, Colors.transparent, Colors.transparent, 1);
        row.trashButton.icon:SetVertexColor(unpack(Colors.muted));
    end
    local function paintTrashHover()
        Theme.Helpers.SetFlatBackdrop(row.trashButton, Colors.sessionDeleteHoverBg, Colors.skinCloseBorder, 1);
        row.trashButton.icon:SetVertexColor(unpack(Colors.sessionDeleteHoverIcon));
    end
    paintTrashDefault();
    row.trashButton:HookScript("OnEnter", paintTrashHover);
    row.trashButton:HookScript("OnLeave", paintTrashDefault);
    row.trashButton:SetScript("OnClick", function()
        if (not row.entry) then return; end

        if (not IsShiftKeyDown()) then
            SetStatus("error", ("Hold Shift and click the trash icon to remove %s from the queue."):format(row.entry.itemLink or "?"));
            return;
        end

        TradeQueueWindow.Delete(row.queueIndex);
    end);

    -- Main click target: the whole row minus the trash button. A separate
    -- mouse-enabled Button, an earlier sibling of row.trashButton (so it sits
    -- at a lower frame level), so a trash click never also triggers retry.
    row.mainButton = CreateFrame("Button", nil, row);
    row.mainButton:SetPoint("TOPLEFT", row, "TOPLEFT");
    row.mainButton:SetPoint("BOTTOMRIGHT", row.trashButton, "BOTTOMLEFT");
    row.mainButton:RegisterForClicks("LeftButtonUp");

    row.icon = row.mainButton:CreateTexture(nil, "ARTWORK");
    row.icon:SetSize(Sizes.rowIconSize, Sizes.rowIconSize);
    row.icon:SetPoint("LEFT", row, "LEFT", Sizes.listPadding, 0);
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    row.iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
    row.iconBorder:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -1, 1);
    row.iconBorder:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(row.iconBorder, nil, Colors.transparent, 1);

    row.tagText = row.mainButton:CreateFontString(nil, "OVERLAY");
    SetFont(row.tagText, "small");
    -- Anchored to `row` (its full height), not `row.mainButton` - mainButton
    -- stops short at the trash button's vertically-centered bottom edge, a
    -- few px above the row's own bottom, which would otherwise pull this
    -- text's vertical center up off the row's true center.
    row.tagText:SetPoint("RIGHT", row, "RIGHT", -(Sizes.trashButtonInset + Sizes.trashButtonSize + Sizes.rowStatusTagGap), 0);

    row.nameText = row.mainButton:CreateFontString(nil, "OVERLAY");
    SetFont(row.nameText, "body");
    row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", Sizes.rowIconTextGap, 0);
    row.nameText:SetPoint("RIGHT", row.tagText, "LEFT", -Sizes.rowStatusTagGap, 0);
    row.nameText:SetJustifyH("LEFT");
    row.nameText:SetWordWrap(false);

    row.winnerText = row.mainButton:CreateFontString(nil, "OVERLAY");
    SetFont(row.winnerText, "small");
    row.winnerText:SetTextColor(unpack(Colors.muted));
    row.winnerText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -Sizes.rowTextLineGap);
    row.winnerText:SetPoint("RIGHT", row.nameText, "RIGHT", 0, 0);
    row.winnerText:SetJustifyH("LEFT");
    row.winnerText:SetWordWrap(false);

    -- Tooltip - only over the icon itself. Also required to be within
    -- listScroll's own bounds (Util.IsMouseOverVisible) - a row scrolled out
    -- of the visible list still occupies its original on-screen rect as far
    -- as IsMouseOver is concerned, since ScrollFrame only clips rendering.
    row.mainButton:SetScript("OnUpdate", function()
        if (row.entry and Util.IsMouseOverVisible(row.icon, listScroll)) then
            GameTooltip:SetOwner(row.icon, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink(row.entry.itemLink);
            GameTooltip:Show();
        elseif (GameTooltip:GetOwner() == row.icon) then
            GameTooltip:Hide();
        end
    end);

    row.mainButton:HookScript("OnEnter", function()
        if (row.entry) then
            row:SetBackdropColor(unpack(Colors.tradeQueueRowHoverBg));
            row:SetBackdropBorderColor(unpack(Colors.primaryBorder));
        end
    end);
    row.mainButton:HookScript("OnLeave", function() repaintRowState(row); end);

    row.mainButton:SetScript("OnClick", function()
        if (not row.entry) then return; end
        -- Shift-click to chat-link the item, ctrl-click to dress it up
        -- (shared with RollWindow's/SoftResImportWindow's icons via Util) take
        -- priority over the plain-click retry below.
        if (Util.HandleItemLinkClick(row.entry.itemLink)) then return; end
        TradeQueueWindow.Retry(row.queueIndex);
    end);

    row:Hide();
    return row;
end

-- Grows the row pool up to n frames, reusing whatever already exists. Never
-- shrinks - rows beyond the current queue length are just hidden in Refresh.
local function ensureRowCount(n)
    for i = #rows + 1, n do
        rows[i] = createRow(listScrollChild, i);
    end
end

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
    title:SetText("ForeverLoot - Trade Queue");
    title:SetTextColor(unpack(Colors.titlePurple));

    local divider = titleBar:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 2, 0);
    divider:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -2, 0);
    Pixel.SetLineHeight(divider, 1);

    local closeButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    closeButton:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -8, -8);
    Skin.CloseButton(closeButton);
    closeButton:SetScript("OnClick", function()
        FL.NotifyWindowClosed("TradeQueue");
        frame:Hide();
    end);

    return titleBar;
end

local function createHeader()
    local header = CreateFrame("Frame", nil, frame);
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.contentPadX, -(Sizes.titleBarHeight + Sizes.contentPadTop));
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.contentPadX, -(Sizes.titleBarHeight + Sizes.contentPadTop));
    header:SetHeight(Sizes.headerHeight);

    local titleRow = CreateFrame("Frame", nil, header);
    titleRow:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0);
    titleRow:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 0);
    titleRow:SetHeight(Sizes.headerTitleRowHeight);

    local title = titleRow:CreateFontString(nil, "OVERLAY");
    SetFont(title, "pageTitle");
    title:SetTextColor(unpack(Colors.gold));
    title:SetPoint("LEFT", titleRow, "LEFT", 0, 0);
    title:SetText("Trade Queue");

    -- Right-justified pair: the number sits immediately left of the label,
    -- both right-anchored so they read as one line regardless of how many
    -- digits/how the label pluralizes (see Refresh()).
    countLabelText = titleRow:CreateFontString(nil, "OVERLAY");
    SetFont(countLabelText, "body");
    countLabelText:SetTextColor(unpack(Colors.description));
    countLabelText:SetPoint("RIGHT", titleRow, "RIGHT", 0, 0);
    countLabelText:SetJustifyH("RIGHT");

    countNumberText = titleRow:CreateFontString(nil, "OVERLAY");
    SetFont(countNumberText, "body");
    countNumberText:SetTextColor(unpack(Colors.gold));
    countNumberText:SetPoint("RIGHT", countLabelText, "LEFT", 0, 0);
    countNumberText:SetJustifyH("RIGHT");

    local hint = header:CreateFontString(nil, "OVERLAY");
    SetFont(hint, "small");
    hint:SetTextColor(unpack(Colors.muted));
    hint:SetPoint("TOPLEFT", titleRow, "BOTTOMLEFT", 0, -Sizes.headerHintGap);
    hint:SetPoint("TOPRIGHT", titleRow, "BOTTOMRIGHT", 0, -Sizes.headerHintGap);
    hint:SetJustifyH("LEFT");
    hint:SetText("Click an item to retry trading it to its winner.");

    return header;
end

local function createEmptyState(box)
    local empty = CreateFrame("Frame", nil, box);
    empty:SetPoint("CENTER", box, "CENTER", 0, 0);
    empty:SetHeight(Sizes.emptyIconSize);

    local icon = empty:CreateTexture(nil, "ARTWORK");
    icon:SetSize(Sizes.emptyIconSize, Sizes.emptyIconSize);
    icon:SetPoint("LEFT", empty, "LEFT", 0, 0);
    icon:SetTexture(CHECK_ICON_TEXTURE);
    icon:SetVertexColor(unpack(Colors.respondSentLabel));

    local text = empty:CreateFontString(nil, "OVERLAY");
    SetFont(text, "body");
    text:SetTextColor(unpack(Colors.description));
    text:SetPoint("LEFT", icon, "RIGHT", Sizes.emptyIconTextGap, 0);
    text:SetText("Nothing left to trade");

    -- Text is static, so its width (and so the group's total width) is known
    -- once, up front - a fixed-width frame anchored by its CENTER point stays
    -- centered on the list regardless of that width.
    empty:SetWidth(Sizes.emptyIconSize + Sizes.emptyIconTextGap + text:GetStringWidth());
    empty:Hide();

    emptyState = empty;
end

local function createList()
    listBox = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(listBox, Colors.sessionListBg, Colors.memberBorder, 1);

    -- Rows fill the list width minus the scrollbar's own space (bar + gap +
    -- a small inset off the listBox border) - no extra padding term here, or
    -- it leaves an empty column to the right of the rows.
    local scrollbarSpace = SharedLayout.scrollbarWidth + Sizes.listScrollbarGap + Sizes.listScrollbarInset;

    listScroll = CreateFrame("ScrollFrame", "ForeverLootTradeQueueWindowScroll", listBox, "UIPanelScrollFrameTemplate");
    listScroll:SetPoint("TOPLEFT", listBox, "TOPLEFT", Sizes.listPadding, -Sizes.listPadding);
    listScroll:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -scrollbarSpace, Sizes.listPadding);

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

    createEmptyState(listBox);
    ensureRowCount(1);

    return listBox;
end

local function createFooter()
    local footer = CreateFrame("Frame", nil, frame);
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", Sizes.contentPadX, Sizes.contentPadBottom);
    footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Sizes.contentPadX, Sizes.contentPadBottom);
    footer:SetHeight(Sizes.footerHeight);

    local divider = footer:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, 0);
    divider:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, 0);
    Pixel.SetLineHeight(divider, Sizes.footerDividerHeight);

    local statusArea = CreateFrame("Frame", nil, footer);
    statusArea:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -Sizes.footerDividerGap);
    statusArea:SetPoint("TOPRIGHT", divider, "BOTTOMRIGHT", 0, -Sizes.footerDividerGap);
    statusArea:SetHeight(Sizes.footerStatusHeight);

    statusDot = statusArea:CreateTexture(nil, "ARTWORK");
    statusDot:SetSize(Sizes.footerDotSize, Sizes.footerDotSize);
    statusDot:SetTexture(DOT_TEXTURE);
    -- Aligned with the first line's center, not the whole (up to 2-line)
    -- area's center - half the body font's own point size reads close
    -- enough to that first-line center without needing exact font metrics.
    statusDot:SetPoint("TOPLEFT", statusArea, "TOPLEFT", 0, -(FL.UI.Sizes.fonts.body / 2));

    statusText = statusArea:CreateFontString(nil, "OVERLAY");
    SetFont(statusText, "body");
    statusText:SetPoint("TOPLEFT", statusArea, "TOPLEFT", Sizes.footerDotSize + Sizes.footerDotGap, 0);
    statusText:SetPoint("TOPRIGHT", statusArea, "TOPRIGHT", 0, 0);
    statusText:SetHeight(Sizes.footerStatusHeight);
    statusText:SetJustifyH("LEFT");
    statusText:SetJustifyV("TOP");
    statusText:SetWordWrap(true);
    statusText:SetMaxLines(2);
    statusText:SetText("");

    statusDot:Hide();

    return footer;
end

--------------------------------------------------------------------------
-- Window lifecycle
--------------------------------------------------------------------------

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootTradeQueueWindow", UIParent, "BackdropTemplate");

    -- A queue entry's row (paintRow below) reads its item's quality straight
    -- from the client cache - for an entry restored from saved variables on
    -- login, or queued before this item was ever looted/linked this session,
    -- that cache can still be empty at paint time. Nothing else re-paints the
    -- row once the async backfill lands, so this window listens for it
    -- itself - but only while actually open (this window sits closed for
    -- ~99% of playtime), registering on OnShow and unregistering on OnHide
    -- rather than holding a standing GET_ITEM_INFO_RECEIVED listener for the
    -- addon's whole lifetime.
    frame:SetScript("OnEvent", function(_, _, _, success)
        if (success) then TradeQueueWindow.Refresh(); end
    end);
    frame:SetScript("OnShow", function() frame:RegisterEvent("GET_ITEM_INFO_RECEIVED"); end);
    frame:SetScript("OnHide", function() frame:UnregisterEvent("GET_ITEM_INFO_RECEIVED"); end);

    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    -- NOTE: deliberately NOT added to UISpecialFrames - the old FL.Theme-based
    -- window never closed on Escape either, and this keeps that exact
    -- behavior rather than adopting StartSessionWindow's own choice.
    Pixel.RegisterWindow(frame, {
        width = WINDOW_WIDTH, height = WINDOW_HEIGHT,
        x = savedPosition and savedPosition.x or 200, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    createTitleBar();
    local header = createHeader();
    local footer = createFooter();

    createList();
    listBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -Sizes.sectionGap);
    listBox:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -Sizes.sectionGap);
    listBox:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, Sizes.sectionGap);
    listBox:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, Sizes.sectionGap);
end

function TradeQueueWindow.Refresh()
    if (not frame) then return; end

    local queue = Trade.Queue;
    local count = #queue;

    ensureRowCount(count);
    listScrollChild:SetHeight(math.max(count * (Sizes.rowHeight + Sizes.rowSpacing), 1));

    local members = Util.groupMembers();

    for i, row in ipairs(rows) do
        local entry = queue[i];
        if (entry) then
            row.entry = entry;
            row.queueIndex = i;
            paintRow(row, entry, members);
            row:Show();
        else
            row.entry = nil;
            row.queueIndex = nil;
            row:Hide();
        end
    end

    countNumberText:SetText(tostring(count));
    countLabelText:SetText(count == 1 and " item to trade" or " items to trade");

    emptyState:SetShown(count == 0);

    if (listScroll.ScrollBar and listScroll.ScrollBar.zlUpdateVisibility) then
        listScroll.ScrollBar.zlUpdateVisibility();
    end
end

-- Re-attempt trading a queued entry. Ignored while it's already busy (a prior
-- attempt still in flight). Success here only means the item is sitting in
-- the open trade window, not that it's actually been traded - the row stays
-- "busy" until Trade.lua's completion watcher confirms ERR_TRADE_COMPLETE and
-- removes it (see NotifySuccess below).
function TradeQueueWindow.Retry(index)
    local entry = Trade.Queue[index];
    if (not entry or Trade.GetEntryState(entry) == "busy") then return; end

    Trade.AttemptTradeForQueueEntry(entry);
end

-- Removes a queued entry outright (no trade attempt) - only ever reached via
-- the row's trash button while SHIFT is held (see its OnClick above), since
-- dropping an item here means the group is no longer owed it.
function TradeQueueWindow.Delete(index)
    local entry = Trade.Queue[index];
    if (not entry) then return; end

    Trade.QueueRemoveEntry(entry);

    local classFile = Util.lookupClass(Util.groupMembers(), entry.winner);
    SetStatus("info", ("Removed %s (to %s) from the trade queue."):format(entry.itemLink or "?", Util.classColoredName(entry.winner or "?", classFile)));
    TradeQueueWindow.Refresh();
end

-- Called from Trade.AttemptTradeForQueueEntry (both the manual retry above
-- and the automatic attempt made right after an award) just before the
-- underlying Trade.AttemptTrade call.
function TradeQueueWindow.NotifyAttemptStarted(entry)
    if (not frame) then return; end

    local classFile = Util.lookupClass(Util.groupMembers(), entry.winner);
    SetStatus("working", ("Opening trade with %s…"):format(Util.classColoredName(entry.winner or "?", classFile)));
    TradeQueueWindow.Refresh();
end

-- Called from Trade.AttemptTradeForQueueEntry once the underlying
-- Trade.AttemptTrade call resolves. `success` here means the item was placed
-- in the trade window, not that the trade has actually completed - see
-- NotifySuccess below for that.
function TradeQueueWindow.NotifyAttemptResult(entry, success, reason)
    if (not frame) then return; end

    local classFile = Util.lookupClass(Util.groupMembers(), entry.winner);
    local coloredWinner = Util.classColoredName(entry.winner or "?", classFile);

    if (success) then
        SetStatus("working", ("Waiting for %s to accept the trade for %s."):format(coloredWinner, entry.itemLink or "?"));
    else
        SetStatus("error", ("Couldn't trade %s to %s — %s"):format(entry.itemLink or "?", coloredWinner, describeFailure(reason)));
    end

    TradeQueueWindow.Refresh();
end

-- Called from Trade.lua's onItemActuallyTraded once ERR_TRADE_COMPLETE
-- confirms a queued item was really traded away, right before the entry is
-- removed and Trade.lua calls Refresh() itself.
function TradeQueueWindow.NotifySuccess(entry)
    if (not frame) then return; end

    local classFile = Util.lookupClass(Util.groupMembers(), entry.winner);
    SetStatus("success", ("Traded %s to %s."):format(entry.itemLink or "?", Util.classColoredName(entry.winner or "?", classFile)));
end

function TradeQueueWindow.Show()
    ensureFrame();
    frame:Show();
    TradeQueueWindow.Refresh();
end

function TradeQueueWindow.Hide()
    if (frame) then frame:Hide(); end
end

function TradeQueueWindow.IsShown()
    return frame ~= nil and frame:IsShown();
end

function TradeQueueWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then TradeQueueWindow.Hide(); else TradeQueueWindow.Show(); end
end

function TradeQueueWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
