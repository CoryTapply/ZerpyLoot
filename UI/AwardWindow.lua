--[[
Council-facing "Review and Award" window - replaces the old
UI/LootCouncilReviewWindow.lua. Built directly with the settings window's own
control vocabulary (UI.Colors/UI.Sizes.award/UI.SetFont/UI.Skin), not
FL.Theme - this window has exactly one look, it doesn't follow the active
skin.

Left panel: every item in the session, split into Unassigned/Assigned grids.
Main panel: the selected item's candidate table (response, note, equipped
gear, votes) and a right-click-to-assign flow. All candidate-list building,
sorting and permission checks live in Session/Awards.lua (FL.Awards) - this
file only ever reads FL.Awards/LootCouncil.CurrentSession and calls
FL.Awards.ToggleVote/AwardItem; it never mutates session state directly.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.award;
local RootSizes = FL.UI.Sizes;
local SharedLayout = FL.UI.Sizes.layout;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Widgets = FL.UI.SettingsWidgets;
local Util = FL.Util;
local LootCouncil = FL.LootCouncil;
local Awards = FL.Awards;
local AwardWindow = FL.UI.AwardWindow;

local FALLBACK_ICON = LootCouncil.FALLBACK_ICON;
local CHECK_BADGE_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Award\\CheckBadge";
local PLUS_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Award\\Plus";
local CHECK_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Award\\Check";
local MOUSE_HINT_ATLAS = "plunderstorm-pickup-mouseclick-right";
local DISENCHANT_ICON_ATLAS = "lootroll-toast-icon-disenchant-up";
local DISENCHANT_TOOLTIP_TEXT = "Disenchant";
local MOUSE_MIDDLE_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\MouseMiddleClick";
local CROWN_TEXTURE = "Interface\\GroupFrame\\UI-Group-LeaderIcon";
-- Same trash icon TradeQueueWindow.lua/ItemListEditor.lua already use
-- everywhere else a row can be removed - reused as-is, not a new texture,
-- for the title bar's "End session early" button below.
local DELETE_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\trash.tga";
-- No history/clock icon exists in Media/Icons - reuses a stock Blizzard
-- texture instead, same as CROWN_TEXTURE above, rather than adding new art.
local HISTORY_ICON_TEXTURE = "Interface\\Icons\\INV_Misc_PocketWatch_01";
local CHEVRON_LEFT_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\ChevronLeft";
local CHEVRON_RIGHT_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\ChevronRight";
local NEXT_UNASSIGNED_LABEL = "Next unassigned";
local LEADER_ONLY_TEXT = "Only the loot council session leader can award this item.";
local DISENCHANT_RECIPIENT = FL.Constants.LOOT_COUNCIL_DISENCHANT_RECIPIENT;

local WINDOW_WIDTH = Sizes.window.width;
local WINDOW_HEIGHT = Sizes.window.height;
local MAX_GRID_ICONS = 40; -- headroom over the ~30-item design target
local POSITION_KEY = "awardWindow";
local REFRESH_THROTTLE = 0.1;

-- Key this window's saved position is stored under (see
-- Settings.GetWindowPosition/SetWindowPosition).
local frame;
local closeButton, endEarlyButton, historyButton;
local itemPanel, itemCountText, progressTrack, progressFill, unassignedLabel, assignedLabel;
local leftScroll, leftScrollChild;
local gridIcons = {};

local mainPanel, headerIcon, headerIconBorder, headerNameText, headerTypeText;
local headerBadge, headerBadgeText, disenchantButton, prevButton, nextButton;
local tableHeaderRow;
local rightScroll, rightScrollChild;
local rowPool = {};
local rowOrder = {}; -- names in the order BuildCandidateList returned this refresh

local footer, footerHintIcon, footerHintText, footerMiddleHintIcon, footerMiddleHintText, jumpCheckboxRow;

local popup; -- Skin.ConfirmPopup controller, built lazily by ensurePopup()
local popupState; -- { mode = "assign"|"reassign", item, entry } while the popup is open

local selectedItemSession;
local pendingRefresh = false;
local refreshTimerRunning = false;
local lastRefreshTime = 0;

--------------------------------------------------------------------------
-- Small local helpers
--------------------------------------------------------------------------

local function classColorRGB(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile];
    if (c) then return c.r, c.g, c.b; end
    return 1, 1, 1;
end

local function hex(rgb)
    return ("%02x%02x%02x"):format(
        math.floor((rgb[1] or 1) * 255 + 0.5),
        math.floor((rgb[2] or 1) * 255 + 0.5),
        math.floor((rgb[3] or 1) * 255 + 0.5)
    );
end

local function setTextEllipsized(fontString, text, maxWidth)
    fontString:SetText(text);
    if (fontString:GetStringWidth() <= maxWidth or text == "") then return false; end
    while (fontString:GetStringWidth() > maxWidth and #text > 1) do
        text = text:sub(1, -2);
        fontString:SetText(text .. "...");
    end
    return true;
end

local function getSession()
    return LootCouncil.CurrentSession;
end

local function getSelectedItem()
    local Session = getSession();
    if (not Session or not selectedItemSession) then return nil; end
    return Session.items[selectedItemSession];
end

local function itemIcon(item)
    return (item and (item.itemIcon or (item.itemID and Util.GetItemIcon(item.itemID)))) or FALLBACK_ICON;
end

--------------------------------------------------------------------------
-- Forward declarations - doRefresh/selectItem/ShowPopup/HidePopup all
-- reference each other across sections below.
--------------------------------------------------------------------------

local doRefresh, selectItem, ShowPopup, HidePopup, ConfirmPopup, QuickAssignRaider, updateRightScrollChildWidth
local ShowEndSessionPopup, ConfirmEndSession
local ShowEndSessionEarlyPopup, ConfirmEndSessionEarly

--------------------------------------------------------------------------
-- Title bar
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
    title:SetText("ForeverLoot - Review and Award");
    title:SetTextColor(unpack(Colors.titlePurple));

    local divider = titleBar:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 2, 0);
    divider:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -2, 0);
    divider:SetHeight(Pixel.PixelSize(1));

    closeButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    closeButton:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -8, -8);
    Skin.CloseButton(closeButton);
    closeButton:SetScript("OnClick", function()
        FL.NotifyWindowClosed("Award");
        frame:Hide();
    end);

    -- Leader-only "End session early" - shown/hidden per-refresh in
    -- paintFooterPermissions (same Awards.CanAwardItems() gate as every other
    -- leader-only control in this window). Built by hand rather than through
    -- Skin.Button/Skin.CloseButton since neither's hover look matches this
    -- button's own spec (a distinct red hover on top of a non-close resting
    -- style) - closest existing cousin is TradeQueueWindow's own row trash
    -- button, which this mirrors in spirit (flat backdrop + trash icon +
    -- hover recolor) without sharing code, since that one has no window-chrome
    -- concerns (positioning against the close button, tooltip, etc.) this one
    -- does.
    endEarlyButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    endEarlyButton:SetSize(RootSizes.controls.close, RootSizes.controls.close);
    endEarlyButton:SetPoint("TOPRIGHT", closeButton, "TOPLEFT", -6, 0);
    endEarlyButton:RegisterForClicks("LeftButtonUp");
    Theme.Helpers.SetFlatBackdrop(endEarlyButton, Colors.defaultBg, Colors.checkboxBorder, 1);

    -- Same 0.7x icon-to-button ratio TradeQueueWindow's own trash button uses
    -- (Sizes.trashButtonSize 20 -> icon 14) - both buttons are the same 20px
    -- size here too, so this comes out to the identical 14px icon.
    local endEarlyIconSize = math.floor(RootSizes.controls.close * 0.7 + 0.5);
    endEarlyButton.icon = endEarlyButton:CreateTexture(nil, "ARTWORK");
    endEarlyButton.icon:SetSize(endEarlyIconSize, endEarlyIconSize);
    endEarlyButton.icon:SetPoint("CENTER");
    endEarlyButton.icon:SetTexture(DELETE_ICON_TEXTURE);
    endEarlyButton.icon:SetVertexColor(unpack(Colors.description));

    endEarlyButton:HookScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(Colors.skinCloseBorder));
        self.icon:SetVertexColor(unpack(Colors.sessionDeleteHoverIcon));
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT");
        GameTooltip:AddLine("End session early", 1, 1, 1);
        GameTooltip:AddLine("For when something went wrong.", unpack(Colors.muted));
        GameTooltip:Show();
    end);
    endEarlyButton:HookScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(Colors.checkboxBorder));
        self.icon:SetVertexColor(unpack(Colors.description));
        GameTooltip:Hide();
    end);
    endEarlyButton:SetScript("OnClick", function()
        if (not Awards.CanAwardItems()) then return; end
        ShowEndSessionEarlyPopup();
    end);
    endEarlyButton:Hide(); -- shown per-refresh once a session/leader state actually exists

    -- "Loot History" - opens the standalone history browser (UI/
    -- LootHistoryWindow.lua). Not session/leader-gated like endEarlyButton
    -- above (browsing past awards is available to everyone), so it's always
    -- shown, unlike that button.
    historyButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    historyButton:SetSize(RootSizes.controls.close, RootSizes.controls.close);
    historyButton:SetPoint("TOPRIGHT", endEarlyButton, "TOPLEFT", -6, 0);
    historyButton:RegisterForClicks("LeftButtonUp");
    Theme.Helpers.SetFlatBackdrop(historyButton, Colors.defaultBg, Colors.checkboxBorder, 1);

    local historyIconSize = math.floor(RootSizes.controls.close * 0.7 + 0.5);
    historyButton.icon = historyButton:CreateTexture(nil, "ARTWORK");
    historyButton.icon:SetSize(historyIconSize, historyIconSize);
    historyButton.icon:SetPoint("CENTER");
    historyButton.icon:SetTexture(HISTORY_ICON_TEXTURE);
    historyButton.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);
    historyButton.icon:SetVertexColor(unpack(Colors.description));

    historyButton:HookScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(Colors.gold));
        self.icon:SetVertexColor(unpack(Colors.gold));
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT");
        GameTooltip:AddLine("Loot History", 1, 1, 1);
        GameTooltip:AddLine("Browse past awards.", unpack(Colors.muted));
        GameTooltip:Show();
    end);
    historyButton:HookScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(Colors.checkboxBorder));
        self.icon:SetVertexColor(unpack(Colors.description));
        GameTooltip:Hide();
    end);
    historyButton:SetScript("OnClick", function()
        if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Show) then
            FL.UI.LootHistoryWindow.Show();
        end
    end);

    return titleBar;
end

--------------------------------------------------------------------------
-- Left item panel (Step 4)
--------------------------------------------------------------------------

local function createGridIcon(parent)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate");
    btn:SetSize(Sizes.itemPanel.gridIconSize, Sizes.itemPanel.gridIconSize);
    btn:RegisterForClicks("LeftButtonUp");

    -- Icon art is inset by the border's own thickness so the quality border
    -- (drawn on btn's own outer edge below) never overlaps the icon's
    -- pixels - otherwise a lowered-alpha icon (assignedAlpha) shows through
    -- and muddies the border color.
    local borderThickness = Sizes.itemPanel.gridIconBorderThickness;
    btn.icon = btn:CreateTexture(nil, "ARTWORK");
    btn.icon:SetPoint("TOPLEFT", btn, "TOPLEFT", borderThickness, -borderThickness);
    btn.icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -borderThickness, borderThickness);
    btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    Theme.Helpers.SetFlatBackdrop(btn, nil, Colors.transparent, borderThickness);

    btn.ring = CreateFrame("Frame", nil, btn, "BackdropTemplate");
    btn.ring:SetPoint("TOPLEFT", btn, "TOPLEFT", -(Sizes.itemPanel.selectedRingThickness + Sizes.itemPanel.selectedRingGap), (Sizes.itemPanel.selectedRingThickness + Sizes.itemPanel.selectedRingGap));
    btn.ring:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", (Sizes.itemPanel.selectedRingThickness + Sizes.itemPanel.selectedRingGap), -(Sizes.itemPanel.selectedRingThickness + Sizes.itemPanel.selectedRingGap));
    Theme.Helpers.SetFlatBackdrop(btn.ring, nil, Colors.gold, Sizes.itemPanel.selectedRingThickness);
    btn.ring:Hide();

    -- Its own child frame (not just a texture on btn) and explicitly leveled
    -- above the ring, so the badge stays visible over the gold selection
    -- ring on an assigned+selected item instead of being drawn under it.
    btn.badge = CreateFrame("Frame", nil, btn);
    btn.badge:SetSize(Sizes.itemPanel.badgeSize, Sizes.itemPanel.badgeSize);
    btn.badge:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 3, -3);
    btn.badge:SetFrameLevel(btn.ring:GetFrameLevel() + 1);
    btn.badge.tex = btn.badge:CreateTexture(nil, "ARTWORK");
    btn.badge.tex:SetAllPoints();
    btn.badge.tex:SetTexture(CHECK_BADGE_TEXTURE);
    btn.badge:Hide();

    btn:SetScript("OnClick", function(self)
        if (self.itemSession) then selectItem(self.itemSession); end
    end);

    btn:SetScript("OnUpdate", function(self)
        if (not self.itemSession or not Util.IsMouseOverVisible(self, leftScroll)) then
            if (GameTooltip:GetOwner() == self) then GameTooltip:Hide(); end
            return;
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:SetHyperlink(self.itemLink);
        if (self.winnerName == DISENCHANT_RECIPIENT) then
            GameTooltip:AddLine(" ");
            GameTooltip:AddLine("|cff8865ffLoot Council|r");
            GameTooltip:AddLine(("    " .. "To be |cff%sDisenchanted|r"):format(hex(Colors.disenchantAccent)), 1, 1, 1);
        elseif (self.winnerName) then
            GameTooltip:AddLine("|cff8865ffLoot Council|r");
            GameTooltip:AddLine(("    " .. "Awarded to %s"):format(Util.classColoredName(self.winnerName, self.winnerClass)), 1, 1, 1);
        end
        GameTooltip:Show();

        if (self.hovered) then return; end
        self.hovered = true;
        self.icon:SetVertexColor(Sizes.itemPanel.hoverBrighten, Sizes.itemPanel.hoverBrighten, Sizes.itemPanel.hoverBrighten);
    end);
    btn:HookScript("OnLeave", function(self)
        self.hovered = nil;
        self.icon:SetVertexColor(1, 1, 1);
    end);

    btn:Hide();
    return btn;
end

local function createItemPanel()
    itemPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    itemPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.borderInset, -(Sizes.titleBarHeight + Sizes.borderInset));
    itemPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", Sizes.borderInset, Sizes.borderInset);
    itemPanel:SetWidth(Sizes.itemPanel.width);
    Theme.Helpers.SetFlatBackdrop(itemPanel, Colors.sidebarBg, Colors.transparent, 0);

    local divider = itemPanel:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPRIGHT", itemPanel, "TOPRIGHT", 0, 0);
    divider:SetPoint("BOTTOMRIGHT", itemPanel, "BOTTOMRIGHT", 0, 0);
    divider:SetWidth(Pixel.PixelSize(1));

    local pad = Sizes.itemPanel.padding;

    local topRow = CreateFrame("Frame", nil, itemPanel);
    topRow:SetPoint("TOPLEFT", itemPanel, "TOPLEFT", pad, -pad);
    topRow:SetPoint("TOPRIGHT", itemPanel, "TOPRIGHT", -pad, -pad);
    topRow:SetHeight(Sizes.itemPanel.topRowHeight);

    local title = topRow:CreateFontString(nil, "OVERLAY");
    SetFont(title, "sectionHeader");
    title:SetTextColor(unpack(Colors.gold));
    title:SetPoint("LEFT", topRow, "LEFT", 0, 0);
    title:SetText("Items");

    itemCountText = topRow:CreateFontString(nil, "OVERLAY");
    SetFont(itemCountText, "small");
    itemCountText:SetTextColor(unpack(Colors.description));
    itemCountText:SetPoint("RIGHT", topRow, "RIGHT", 0, 0);

    progressTrack = itemPanel:CreateTexture(nil, "ARTWORK");
    progressTrack:SetColorTexture(unpack(Colors.controlBg));
    progressTrack:SetPoint("TOPLEFT", topRow, "BOTTOMLEFT", 0, -Sizes.itemPanel.progressBarGap);
    progressTrack:SetPoint("TOPRIGHT", topRow, "BOTTOMRIGHT", 0, -Sizes.itemPanel.progressBarGap);
    progressTrack:SetHeight(Sizes.itemPanel.progressBarHeight);

    progressFill = itemPanel:CreateTexture(nil, "ARTWORK", nil, 1);
    progressFill:SetColorTexture(unpack(Colors.gold));
    progressFill:SetPoint("TOPLEFT", progressTrack, "TOPLEFT", 0, 0);
    progressFill:SetPoint("BOTTOMLEFT", progressTrack, "BOTTOMLEFT", 0, 0);
    progressFill:SetWidth(1);

    leftScroll = CreateFrame("ScrollFrame", "ForeverLootAwardWindowItemScroll", itemPanel, "UIPanelScrollFrameTemplate");
    leftScroll:SetPoint("TOPLEFT", progressTrack, "BOTTOMLEFT", 0, -Sizes.itemPanel.sectionGap);
    leftScroll:SetPoint("BOTTOMRIGHT", itemPanel, "BOTTOMRIGHT", -6, pad);
    leftScroll:EnableMouse(true);

    leftScrollChild = CreateFrame("Frame", nil, leftScroll);
    leftScrollChild:SetPoint("TOPLEFT", leftScroll, "TOPLEFT", 0, 0);
    leftScroll:SetScrollChild(leftScrollChild);
    leftScroll:SetScript("OnSizeChanged", function(self, width) leftScrollChild:SetWidth(width); end);

    local leftScrollBar = Skin.ScrollBar(leftScroll);
    if (leftScrollBar) then
        leftScrollBar:ClearAllPoints();
        leftScrollBar:SetPoint("TOP", leftScroll, "TOP", 0, 0);
        leftScrollBar:SetPoint("BOTTOM", leftScroll, "BOTTOM", 0, 0);
        leftScrollBar:SetPoint("RIGHT", itemPanel, "RIGHT", -3, 0);
    end
    Theme.Helpers.EnableSmoothScroll(leftScroll, { step = Sizes.itemPanel.gridIconSize + Sizes.itemPanel.gridSpacing });

    unassignedLabel = leftScrollChild:CreateFontString(nil, "OVERLAY");
    SetFont(unassignedLabel, "small");
    unassignedLabel:SetTextColor(unpack(Colors.muted));
    unassignedLabel:SetPoint("TOPLEFT", leftScrollChild, "TOPLEFT", 0, 0);

    assignedLabel = leftScrollChild:CreateFontString(nil, "OVERLAY");
    SetFont(assignedLabel, "small");
    assignedLabel:SetTextColor(unpack(Colors.muted));

    for i = 1, MAX_GRID_ICONS do
        gridIcons[i] = createGridIcon(leftScrollChild);
    end
end

--------------------------------------------------------------------------
-- Main panel header (Step 5)
--------------------------------------------------------------------------

-- Skin.Button dead-centers button.text and hardcodes it back to
-- SetPoint("CENTER", 0, <0|-1>) on every OnLeave/OnMouseDown/OnMouseUp (its
-- press-bounce effect) - so nextButton's label can't just sit at true center
-- once the chevron sits to its right, or the pair reads lopsided instead of
-- centered as a unit. This re-applies the same hardcoded y-offsets with an
-- x-nudge of half the chevron+gap width, called after each of those resets
-- (and right after a mode switch) so the correction always wins. No nudge in
-- "endSession" mode, which has no chevron.
local function repositionNextLabel(yOffset)
    local offsetX = 0;
    if (nextButton.mode ~= "endSession") then
        offsetX = -(Sizes.mainPanel.navChevronSize + Sizes.mainPanel.navChevronGap) / 2;
    end
    nextButton.text:SetPoint("CENTER", offsetX, yOffset or 0);
end

local function createHeaderRow()
    local header = CreateFrame("Frame", nil, mainPanel);
    header:SetPoint("TOPLEFT", mainPanel, "TOPLEFT", Sizes.mainPanel.padX, -Sizes.mainPanel.padTop);
    header:SetPoint("TOPRIGHT", mainPanel, "TOPRIGHT", -Sizes.mainPanel.padX, -Sizes.mainPanel.padTop);
    header:SetHeight(Sizes.mainPanel.headerIconSize);

    headerIcon = header:CreateTexture(nil, "ARTWORK");
    headerIcon:SetSize(Sizes.mainPanel.headerIconSize, Sizes.mainPanel.headerIconSize);
    headerIcon:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0);
    headerIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    headerIconBorder = CreateFrame("Frame", nil, header, "BackdropTemplate");
    headerIconBorder:SetPoint("TOPLEFT", headerIcon, "TOPLEFT", -1, 1);
    headerIconBorder:SetPoint("BOTTOMRIGHT", headerIcon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(headerIconBorder, nil, Colors.transparent, 1);

    nextButton = Widgets.CreateFlatButton(header, NEXT_UNASSIGNED_LABEL, "primary");
    nextButton.mode = "next";
    nextButton:SetHeight(Sizes.mainPanel.navButtonHeight);
    nextButton:SetPoint("RIGHT", header, "RIGHT", 0, 0);
    nextButton:SetWidth(nextButton.text:GetStringWidth() + 24 + Sizes.mainPanel.navChevronSize + Sizes.mainPanel.navChevronGap);
    nextButton:SetScript("OnClick", function()
        if (nextButton.mode == "endSession") then
            ShowEndSessionPopup();
            return;
        end
        local Session = getSession();
        if (not Session or not selectedItemSession) then return; end
        local nextSession = Awards.NextUnassignedItem(Session, selectedItemSession, 1);
        if (nextSession) then selectItem(nextSession); end
    end);
    repositionNextLabel(0);
    nextButton:HookScript("OnLeave", function(self) if (self:IsEnabled()) then repositionNextLabel(0); end end);
    nextButton:HookScript("OnMouseDown", function(self) if (self:IsEnabled()) then repositionNextLabel(-1); end end);
    nextButton:HookScript("OnMouseUp", function(self) if (self:IsEnabled()) then repositionNextLabel(0); end end);

    -- Gold button - its label is always gold (see Skin.Button's "primary"
    -- variant), so the chevron matches at full alpha whenever enabled and
    -- only dims with it on disable; no separate hover color.
    nextButton.chevron = nextButton:CreateTexture(nil, "ARTWORK");
    nextButton.chevron:SetSize(Sizes.mainPanel.navChevronSize, Sizes.mainPanel.navChevronSize);
    nextButton.chevron:SetPoint("LEFT", nextButton.text, "RIGHT", Sizes.mainPanel.navChevronGap, 0);
    nextButton.chevron:SetTexture(CHEVRON_RIGHT_TEXTURE);
    nextButton.chevron:SetVertexColor(Colors.gold[1], Colors.gold[2], Colors.gold[3], 1);
    nextButton:HookScript("OnEnable", function(self)
        self.chevron:SetVertexColor(Colors.gold[1], Colors.gold[2], Colors.gold[3], 1);
    end);
    nextButton:HookScript("OnDisable", function(self)
        self.chevron:SetVertexColor(Colors.gold[1], Colors.gold[2], Colors.gold[3], 0.4);
    end);

    prevButton = Widgets.CreateFlatButton(header, "", "default");
    prevButton:SetSize(Sizes.mainPanel.navButtonSize, Sizes.mainPanel.navButtonHeight);
    prevButton:SetPoint("RIGHT", nextButton, "LEFT", -Sizes.mainPanel.navButtonGap, 0);
    prevButton:SetScript("OnClick", function()
        local Session = getSession();
        if (not Session or not selectedItemSession) then return; end
        local prevSession = Awards.NextUnassignedItem(Session, selectedItemSession, -1);
        if (prevSession) then selectItem(prevSession); end
    end);

    -- Icon-only (see disenchantButton below for the same pattern): the
    -- FontString stays, hidden, so GetText() keeps working, while the
    -- chevron carries the meaning and mirrors the default variant's own
    -- text colors (Skin.Button's computeButtonVariant) - normal/hover/
    -- disabled - since Skin.Button itself never recolors text on hover.
    prevButton.text:Hide();
    prevButton.icon = prevButton:CreateTexture(nil, "ARTWORK");
    prevButton.icon:SetSize(Sizes.mainPanel.navChevronSize, Sizes.mainPanel.navChevronSize);
    prevButton.icon:SetPoint("CENTER", 0, 0);
    prevButton.icon:SetTexture(CHEVRON_LEFT_TEXTURE);
    prevButton.icon:SetVertexColor(Colors.textBright[1], Colors.textBright[2], Colors.textBright[3], 1);
    prevButton:HookScript("OnEnter", function(self)
        if (self:IsEnabled()) then
            self.icon:SetVertexColor(Colors.gold[1], Colors.gold[2], Colors.gold[3], 1);
        end
    end);
    prevButton:HookScript("OnLeave", function(self)
        if (self:IsEnabled()) then
            self.icon:SetVertexColor(Colors.textBright[1], Colors.textBright[2], Colors.textBright[3], 1);
        end
    end);
    prevButton:HookScript("OnEnable", function(self)
        self.icon:SetVertexColor(Colors.textBright[1], Colors.textBright[2], Colors.textBright[3], 1);
    end);
    prevButton:HookScript("OnDisable", function(self)
        self.icon:SetVertexColor(Colors.textBright[1], Colors.textBright[2], Colors.textBright[3], 0.4);
    end);

    -- Icon-only. Built with the shared flat-button vocabulary (fill/pressed/
    -- disabled behavior all come from Skin.Button's "default" variant) - only
    -- its border color is swapped to the blue-violet disenchant accent below,
    -- so it still reads as a distinct action next to the prev/next arrows.
    disenchantButton = Widgets.CreateFlatButton(header, "", "default");
    disenchantButton:SetSize(Sizes.mainPanel.navButtonSize, Sizes.mainPanel.navButtonHeight);
    disenchantButton:SetPoint("RIGHT", prevButton, "LEFT", -Sizes.mainPanel.navButtonGap, 0);
    disenchantButton.skinVariant.border = Colors.disenchantBorder;
    disenchantButton.skinVariant.hoverBorder = Colors.disenchantAccent;
    disenchantButton.applyEnabled();

    -- No visible text (the icon carries the meaning), but the button still
    -- carries the same "Disenchant" string as its GetText()/accessible name
    -- as the tooltip below - the fontstring itself stays hidden so it can
    -- never bleed out from behind the icon.
    disenchantButton.text:SetText(DISENCHANT_TOOLTIP_TEXT);
    disenchantButton.text:Hide();

    local disenchantIconSize = math.floor(Sizes.mainPanel.navButtonHeight * 0.7 + 0.5);
    disenchantButton.icon = disenchantButton:CreateTexture(nil, "ARTWORK");
    disenchantButton.icon:SetSize(disenchantIconSize, disenchantIconSize);
    disenchantButton.icon:SetPoint("CENTER", 0, 0);
    disenchantButton.icon:SetAtlas(DISENCHANT_ICON_ATLAS, false);

    disenchantButton:SetScript("OnClick", function()
        local item = getSelectedItem();
        if (not item or not Awards.CanAwardItems()) then return; end
        Awards.DisenchantItem(item.session);

        if (FL.Settings.GetJumpToNextUnassigned()) then
            local Session = getSession();
            local nextSession = Session and Awards.NextUnassignedItem(Session, item.session, 1);
            if (nextSession) then selectedItemSession = nextSession; end
        end
        doRefresh();
    end);
    disenchantButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:SetText(DISENCHANT_TOOLTIP_TEXT);
        GameTooltip:Show();
    end);
    disenchantButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);

    headerNameText = header:CreateFontString(nil, "OVERLAY");
    SetFont(headerNameText, "pageTitle");
    headerNameText:SetPoint("TOPLEFT", headerIcon, "TOPRIGHT", Sizes.mainPanel.headerIconGap, 0);
    headerNameText:SetPoint("RIGHT", disenchantButton, "LEFT", -8, 0);
    headerNameText:SetJustifyH("LEFT");
    headerNameText:SetWordWrap(false);

    headerTypeText = header:CreateFontString(nil, "OVERLAY");
    SetFont(headerTypeText, "small");
    headerTypeText:SetTextColor(unpack(Colors.description));
    headerTypeText:SetPoint("TOPLEFT", headerNameText, "BOTTOMLEFT", 0, -Sizes.mainPanel.headerNameTypeGap);
    headerTypeText:SetJustifyH("LEFT");
    headerTypeText:SetWordWrap(false);

    headerBadge = CreateFrame("Frame", nil, header);
    headerBadge:SetHeight(Sizes.mainPanel.badgeHeight);
    Skin.Pill(headerBadge);
    headerBadge:SetPillFillColor(unpack(Colors.councilFill));
    headerBadge:SetPillColor(unpack(Colors.councilBorder));
    headerBadge:Hide();

    headerBadgeText = headerBadge:CreateFontString(nil, "OVERLAY");
    SetFont(headerBadgeText, "small");
    headerBadgeText:SetPoint("LEFT", headerBadge, "LEFT", Sizes.mainPanel.badgePadX, 0);
    headerBadgeText:SetPoint("RIGHT", headerBadge, "RIGHT", -Sizes.mainPanel.badgePadX, 0);

    local divider = mainPanel:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.disabledBorder));
    divider:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -Sizes.mainPanel.headerDividerGap);
    divider:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -Sizes.mainPanel.headerDividerGap);
    divider:SetHeight(Pixel.PixelSize(1));

    return header, divider;
end

--------------------------------------------------------------------------
-- Table header row
--------------------------------------------------------------------------

local function createTableHeader(anchorAbove)
    local mp = Sizes.mainPanel;
    local row = CreateFrame("Frame", nil, mainPanel);
    row:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", 0, -10);
    row:SetPoint("TOPRIGHT", anchorAbove, "BOTTOMRIGHT", 0, -10);
    row:SetHeight(mp.columnHeaderHeight);

    local function makeLabel(text, justify)
        local fs = row:CreateFontString(nil, "OVERLAY");
        SetFont(fs, "small");
        fs:SetTextColor(unpack(Colors.muted));
        fs:SetJustifyH(justify or "LEFT");
        fs:SetText(string.upper(text));
        return fs;
    end

    local x = Sizes.rowPadX;
    local player = makeLabel("Player");
    player:SetPoint("LEFT", row, "LEFT", x, 0);
    player:SetWidth(mp.colPlayer);
    x = x + mp.colPlayer + mp.colGap;

    local equipped = makeLabel("Equipped");
    equipped:SetPoint("LEFT", row, "LEFT", x, 0);
    equipped:SetWidth(mp.colEquipped);
    x = x + mp.colEquipped + mp.colGap;

    local response = makeLabel("Response");
    response:SetPoint("LEFT", row, "LEFT", x, 0);
    response:SetWidth(mp.colResponse);
    x = x + mp.colResponse + mp.colGap;

    local note = makeLabel("Note");
    note:SetPoint("LEFT", row, "LEFT", x, 0);
    note:SetWidth(mp.colNote);
    x = x + mp.colNote + mp.colGap;

    local votes = makeLabel("Votes", "RIGHT");
    votes:SetPoint("LEFT", row, "LEFT", x, 0);
    votes:SetWidth(mp.colVotes);
    x = x + mp.colVotes + mp.colGap;
    -- vote-button column intentionally has no header label

    return row;
end

--------------------------------------------------------------------------
-- Candidate rows (Step 5-6)
--------------------------------------------------------------------------

local function hideRowTooltip(row)
    if (row.tooltipOwner) then GameTooltip:Hide(); end
    row.tooltipOwner = nil;
end

local function showVoteTooltip(row)
    local candidate = row.candidate;
    if (not candidate) then return; end
    local voters = Awards.VoteOrder(candidate);

    GameTooltip:SetOwner(row.votesText, "ANCHOR_RIGHT");
    GameTooltip:AddLine(("Votes (%d)"):format(#voters), unpack(Colors.gold));
    if (#voters == 0) then
        GameTooltip:AddLine("No votes yet", unpack(Colors.muted));
    else
        for _, name in ipairs(voters) do
            local r, g, b = classColorRGB(candidate.class);
            -- voter's own class, not the candidate's - look it up fresh so a
            -- relog/roster change is reflected even on a cached voteOrder entry.
            local members = Util.groupMembers();
            local voterClass = members[name];
            if (voterClass) then r, g, b = classColorRGB(voterClass); end
            GameTooltip:AddLine(name, r, g, b);
        end
    end
    GameTooltip:Show();
    row.tooltipOwner = "votes";
end

local function showEquippedTooltip(row, index)
    local icon = row.equippedIcons[index];
    if (not icon or not icon.link) then return; end
    GameTooltip:SetOwner(icon, "ANCHOR_RIGHT");
    GameTooltip:SetHyperlink(icon.link);
    GameTooltip:Show();
    row.tooltipOwner = "equipped" .. index;
end

local function showNoteTooltip(row)
    if (not row.candidate or not row.candidate.note or row.candidate.note == "") then return; end
    GameTooltip:SetOwner(row.noteText, "ANCHOR_RIGHT");
    GameTooltip:AddLine(row.candidate.note, 1, 1, 1, true);
    GameTooltip:Show();
    row.tooltipOwner = "note";
end

local function createRow()
    local mp = Sizes.mainPanel;
    local row = CreateFrame("Button", nil, rightScrollChild, "BackdropTemplate");
    row:SetHeight(mp.rowHeight);
    row:SetPoint("RIGHT", rightScrollChild, "RIGHT");
    Theme.Helpers.SetFlatBackdrop(row, Colors.transparent, Colors.transparent, 1);
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp");

    local x = Sizes.rowPadX;

    -- Winner-icon slot, fixed at the row's left inset - only shown on the
    -- winner's row (paintRow). Only that row's name is then shifted right
    -- to clear it (12 + 4); every other row's name stays at x.
    row.crown = row:CreateTexture(nil, "OVERLAY");
    row.crown:SetSize(mp.crownIconSize, mp.crownIconSize);
    row.crown:SetPoint("LEFT", row, "LEFT", x, 0);
    row.crown:SetTexture(CROWN_TEXTURE);
    row.crown:Hide();

    -- Default (non-winner) placement - paintRow repositions/narrows this for
    -- the winner's row each refresh.
    row.nameText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.nameText, "body");
    row.nameText:SetPoint("LEFT", row, "LEFT", x, 0);
    row.nameText:SetWidth(mp.colPlayer);
    row.nameText:SetJustifyH("LEFT");
    row.nameText:SetWordWrap(false);

    x = Sizes.rowPadX + mp.colPlayer + mp.colGap;
    row.equippedColX = x;

    row.equippedIcons = {};
    for i = 1, 2 do
        local icon = CreateFrame("Frame", nil, row, "BackdropTemplate");
        icon:SetSize(mp.equippedIconSize, mp.equippedIconSize);
        -- Icon art is inset by the border's own thickness so the quality
        -- border (drawn on icon's own outer edge) never sits underneath the
        -- icon art, which would otherwise hide it entirely.
        local borderThickness = mp.equippedIconBorderThickness;
        icon.tex = icon:CreateTexture(nil, "ARTWORK");
        icon.tex:SetPoint("TOPLEFT", icon, "TOPLEFT", borderThickness, -borderThickness);
        icon.tex:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -borderThickness, borderThickness);
        icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92);
        Theme.Helpers.SetFlatBackdrop(icon, nil, Colors.transparent, borderThickness);
        icon:Hide();
        row.equippedIcons[i] = icon;
    end
    row.equippedNone = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.equippedNone, "body");
    row.equippedNone:SetTextColor(unpack(Colors.disabledText));
    row.equippedNone:SetText("\226\128\148");
    x = x + mp.colEquipped + mp.colGap;

    row.pill = CreateFrame("Frame", nil, row);
    row.pill:SetHeight(mp.pillHeight);
    row.pill:SetPoint("LEFT", row, "LEFT", x, 0);
    Skin.Pill(row.pill);
    row.pill.dot = row.pill:CreateTexture(nil, "ARTWORK");
    row.pill.dot:SetSize(mp.pillDotSize, mp.pillDotSize);
    row.pill.dot:SetPoint("LEFT", row.pill, "LEFT", mp.pillPadX, 0);
    row.pill.dot:SetTexture("Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Dot");
    row.pill.label = row.pill:CreateFontString(nil, "OVERLAY");
    SetFont(row.pill.label, "small");
    row.pill.label:SetTextColor(unpack(Colors.text));
    row.pill.label:SetPoint("LEFT", row.pill.dot, "RIGHT", mp.pillDotGap, 0);
    x = x + mp.colResponse + mp.colGap;

    row.noteText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.noteText, "body");
    row.noteText:SetTextColor(unpack(Colors.description));
    row.noteText:SetPoint("LEFT", row, "LEFT", x, 0);
    row.noteText:SetWidth(mp.colNote);
    row.noteText:SetJustifyH("LEFT");
    row.noteText:SetWordWrap(false);
    x = x + mp.colNote + mp.colGap;

    row.votesText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.votesText, "body");
    row.votesText:SetTextColor(unpack(Colors.text));
    row.votesText:SetPoint("LEFT", row, "LEFT", x, 0);
    row.votesText:SetWidth(mp.colVotes);
    row.votesText:SetJustifyH("RIGHT");
    x = x + mp.colVotes + mp.colGap;

    row.voteButton = CreateFrame("Button", nil, row, "BackdropTemplate");
    row.voteButton:SetSize(mp.voteButtonSize, mp.voteButtonSize);
    row.voteButton:SetPoint("LEFT", row, "LEFT", x, 0);
    row.voteButton:RegisterForClicks("LeftButtonUp");
    row.voteButton.icon = row.voteButton:CreateTexture(nil, "ARTWORK");
    row.voteButton.icon:SetSize(mp.voteIconSize, mp.voteIconSize);
    row.voteButton.icon:SetPoint("CENTER");
    row.voteButton:SetScript("OnClick", function()
        if (row.itemSession and row.candidateName) then
            Awards.ToggleVote(row.itemSession, row.candidateName);
            doRefresh();
        end
    end);
    -- Polled rather than OnEnter/OnLeave: a vote arriving anywhere on this
    -- item re-paints every visible row (see doRefresh), which can leave a
    -- stationary mouse's hover state stale until it actually moves. Voted
    -- (gold-filled) buttons have no separate hover look per spec, so this is
    -- a no-op once voted.
    row.voteButton:SetScript("OnUpdate", function(self)
        local voted = row.candidate and row.candidate.approvals[row.myName] == true;
        if (voted) then self.isHovered = nil; return; end
        local isHovered = Util.IsMouseOverVisible(self, rightScroll);
        if (isHovered == self.isHovered) then return; end
        self.isHovered = isHovered;
        if (isHovered) then
            self:SetBackdropBorderColor(unpack(Colors.gold));
            self.icon:SetVertexColor(unpack(Colors.gold));
        else
            self:SetBackdropBorderColor(unpack(Colors.checkboxBorder));
            self.icon:SetVertexColor(unpack(Colors.description));
        end
    end);

    row:SetScript("OnClick", function(self, button)
        if (button ~= "RightButton" and button ~= "MiddleButton") then return; end
        local item = getSelectedItem();
        if (not item or not self.candidateName) then return; end
        if (not Awards.CanAwardItems()) then return; end
        if (item.awardedTo == self.candidateName) then return; end -- already this item's winner
        if (button == "MiddleButton") then
            QuickAssignRaider(item, self.candidateName);
        else
            ShowPopup(item, { name = self.candidateName, class = self.class, candidate = self.candidate });
        end
    end);

    -- Polled rather than OnEnter/OnLeave for the same reflow-under-a-
    -- stationary-mouse reason as the vote button above - a live update can
    -- repaint this row (resetting its backdrop to the non-hover look)
    -- without the mouse ever leaving it.
    row:SetScript("OnUpdate", function(self)
        if (not self.candidate) then return; end

        if (not self.isWinner) then
            local isHovered = Util.IsMouseOverVisible(self, rightScroll);
            if (isHovered ~= self.rowHovered) then
                self.rowHovered = isHovered;
                Theme.Helpers.SetFlatBackdrop(self, isHovered and Colors.hoverBg or Colors.transparent, Colors.transparent, 1);
            end
        end

        local target = nil;
        if (self.equippedIcons[1]:IsShown() and Util.IsMouseOverVisible(self.equippedIcons[1], rightScroll)) then
            target = "equipped1";
        elseif (self.equippedIcons[2]:IsShown() and Util.IsMouseOverVisible(self.equippedIcons[2], rightScroll)) then
            target = "equipped2";
        elseif (self.noteTruncated and Util.IsMouseOverVisible(self.noteText, rightScroll)) then
            target = "note";
        elseif (Util.IsMouseOverVisible(self.votesText, rightScroll)) then
            target = "votes";
        end

        if (target == nil) then
            if (self.tooltipOwner) then hideRowTooltip(self); end
            return;
        end
        if (target == self.tooltipOwner) then
            if (target == "votes") then showVoteTooltip(self); end -- keep the voter list fresh
            return;
        end

        self.tooltipOwner = nil;
        if (target == "equipped1") then showEquippedTooltip(self, 1);
        elseif (target == "equipped2") then showEquippedTooltip(self, 2);
        elseif (target == "note") then showNoteTooltip(self);
        elseif (target == "votes") then showVoteTooltip(self);
        end
    end);

    row:Hide();
    return row;
end

--- Paints one already-created row for `entry` ({name, class, candidate}) on
--- `item`, at vertical slot `index` (0-based) within the visible list.
local function paintRow(row, entry, item, index, myName)
    local mp = Sizes.mainPanel;
    row:ClearAllPoints();
    row:SetPoint("TOPLEFT", rightScrollChild, "TOPLEFT", 0, -index * (mp.rowHeight + mp.rowSpacing));
    row:SetPoint("RIGHT", rightScrollChild, "RIGHT");

    row.itemSession = item.session;
    row.candidateName = entry.name;
    row.class = entry.class;
    row.candidate = entry.candidate;
    row.myName = myName;

    local isWinner = item.awardedTo == entry.name;
    row.crown:SetShown(isWinner);

    -- Only the winner's name is shifted right to clear the winner icon;
    -- every other row's name sits at the row's own left inset.
    local nameX, nameWidth = Sizes.rowPadX, mp.colPlayer;
    if (isWinner) then
        nameX = nameX + mp.crownIconSize + mp.crownIconGap;
        nameWidth = nameWidth - mp.crownIconSize - mp.crownIconGap;
    end
    row.nameText:ClearAllPoints();
    row.nameText:SetPoint("LEFT", row, "LEFT", nameX, 0);
    row.nameText:SetWidth(nameWidth);

    local r, g, b = classColorRGB(entry.class);
    row.nameText:SetTextColor(r, g, b);
    setTextEllipsized(row.nameText, entry.name, nameWidth);

    local icons = Awards.EquippedIcons(entry.candidate);
    for i = 1, 2 do
        local slotIcon = row.equippedIcons[i];
        local data = icons[i];
        if (data) then
            local _, _, quality = Util.GetItemInfo(data.link);
            local qr, qg, qb = Util.GetItemQualityColor(quality);
            slotIcon.tex:SetTexture(Util.itemIDFromLink(data.link) and Util.GetItemIcon(Util.itemIDFromLink(data.link)) or FALLBACK_ICON);
            slotIcon:SetBackdropBorderColor(qr or 0.6, qg or 0.6, qb or 0.6);
            slotIcon.link = data.link;
            slotIcon:ClearAllPoints();
            slotIcon:SetPoint("LEFT", row, "LEFT", row.equippedColX + (i - 1) * (mp.equippedIconSize + mp.equippedIconGap), 0);
            slotIcon:Show();
        else
            slotIcon:Hide();
            slotIcon.link = nil;
        end
    end
    row.equippedNone:ClearAllPoints();
    row.equippedNone:SetPoint("LEFT", row, "LEFT", row.equippedColX, 0);
    row.equippedNone:SetShown(#icons == 0);

    local colorEntry = Awards.ResponseColor(entry.candidate.response);
    row.pill:SetWidth(mp.colResponse);
    row.pill:SetPillColor(unpack(colorEntry.color));
    row.pill.dot:SetVertexColor(unpack(colorEntry.color));
    local pillLabelMaxWidth = mp.colResponse - (mp.pillPadX * 2 + mp.pillDotSize + mp.pillDotGap);
    Skin.FitPillLabel(row.pill.label, Awards.ResponseLabel(entry.candidate.response), pillLabelMaxWidth);

    row.noteText:SetTextColor(unpack(Colors.description));
    row.noteTruncated = setTextEllipsized(row.noteText, entry.candidate.note or "", mp.colNote);

    local voteCount = Util.tcount(entry.candidate.approvals);
    row.votesText:SetText(tostring(voteCount));

    local canVote = Awards.CanVote(myName, Util.playerFqn());
    row.voteButton:SetShown(canVote);
    if (canVote) then
        local voted = entry.candidate.approvals[myName] == true;
        if (voted) then
            Theme.Helpers.SetFlatBackdrop(row.voteButton, Colors.gold, Colors.gold, 1);
            row.voteButton.icon:SetTexture(CHECK_TEXTURE);
            row.voteButton.icon:SetVertexColor(unpack(Colors.awardVoteCheckDark));
        else
            Theme.Helpers.SetFlatBackdrop(row.voteButton, Colors.defaultBg, Colors.checkboxBorder, 1);
            row.voteButton.icon:SetTexture(PLUS_TEXTURE);
            row.voteButton.icon:SetVertexColor(unpack(Colors.description));
        end
    end

    row.isWinner = isWinner;
    if (isWinner) then
        Theme.Helpers.SetFlatBackdrop(row, Colors.councilFill, Colors.councilBorder, 1);
    elseif (row.rowHovered) then
        Theme.Helpers.SetFlatBackdrop(row, Colors.hoverBg, Colors.transparent, 1);
    else
        Theme.Helpers.SetFlatBackdrop(row, Colors.transparent, Colors.transparent, 1);
    end

    row:Show();
end

--------------------------------------------------------------------------
-- Footer (Step 5 bottom)
--------------------------------------------------------------------------

local function createFooter()
    footer = CreateFrame("Frame", nil, mainPanel);
    footer:SetPoint("BOTTOMLEFT", mainPanel, "BOTTOMLEFT", Sizes.mainPanel.padX, Sizes.mainPanel.padTop);
    footer:SetPoint("BOTTOMRIGHT", mainPanel, "BOTTOMRIGHT", -Sizes.mainPanel.padX, Sizes.mainPanel.padTop);
    footer:SetHeight(Sizes.mainPanel.footerRowHeight);

    local divider = footer:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, Sizes.mainPanel.footerDividerGap);
    divider:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, Sizes.mainPanel.footerDividerGap);
    divider:SetHeight(Pixel.PixelSize(1));

    footerHintIcon = footer:CreateTexture(nil, "ARTWORK");
    footerHintIcon:SetHeight(Sizes.mainPanel.mouseHintIconHeight);
    footerHintIcon:SetPoint("LEFT", footer, "LEFT", 0, 0);
    local atlasInfo = C_Texture.GetAtlasInfo(MOUSE_HINT_ATLAS);
    if (atlasInfo) then
        local aspect = atlasInfo.width / atlasInfo.height;
        footerHintIcon:SetWidth(Sizes.mainPanel.mouseHintIconHeight * aspect);
        footerHintIcon:SetAtlas(MOUSE_HINT_ATLAS);
        footerHintIcon:SetVertexColor(1, 1, 1);
    else
        footerHintIcon:Hide();
    end

    footerHintText = footer:CreateFontString(nil, "OVERLAY");
    SetFont(footerHintText, "small");
    footerHintText:SetTextColor(unpack(Colors.muted));
    footerHintText:SetPoint("LEFT", footerHintIcon, "RIGHT", Sizes.mainPanel.mouseHintIconGap, 0);

    footerMiddleHintIcon = footer:CreateTexture(nil, "ARTWORK");
    footerMiddleHintIcon:SetHeight(Sizes.mainPanel.mouseHintIconHeight);
    footerMiddleHintIcon:SetPoint("LEFT", footerHintText, "RIGHT", Sizes.mainPanel.mouseHintIconGap * 3, 0);
    footerMiddleHintIcon:SetTexture(MOUSE_MIDDLE_ICON_TEXTURE);
    footerMiddleHintIcon:SetWidth(Sizes.mainPanel.mouseHintIconHeight);
    footerMiddleHintIcon:SetVertexColor(1, 1, 1);

    footerMiddleHintText = footer:CreateFontString(nil, "OVERLAY");
    SetFont(footerMiddleHintText, "small");
    footerMiddleHintText:SetTextColor(unpack(Colors.muted));
    footerMiddleHintText:SetPoint("LEFT", footerMiddleHintIcon, "RIGHT", Sizes.mainPanel.mouseHintIconGap, 0);

    jumpCheckboxRow = Widgets.BuildCheckboxRow(footer, {
        key = nil,
        label = "Jump to next unassigned after assigning",
        onChange = function(checked) FL.Settings.SetJumpToNextUnassigned(checked); end,
    });
    jumpCheckboxRow.frame:SetPoint("RIGHT", footer, "RIGHT", 0, 0);
    jumpCheckboxRow.checkbox:SetChecked(FL.Settings.GetJumpToNextUnassigned());
end

--------------------------------------------------------------------------
-- Assign/reassign confirmation popup (Step 7)
--------------------------------------------------------------------------

local function ensurePopup()
    if (popup) then return; end

    local p = Sizes.popup;
    popup = Skin.ConfirmPopup(frame, {
        width = p.width,
        padding = p.padding,
        titleHeight = p.titleHeight,
        sectionGap = p.sectionGap,
        buttonHeight = p.buttonHeight,
        buttonGap = p.buttonGap,
        buttonWidth = p.buttonWidth,
        shadowInset = p.shadowInset,
        scrimTopInset = Sizes.titleBarHeight,
    });
    local popupDialog = popup.dialog;

    popupDialog.summary = CreateFrame("Frame", nil, popupDialog, "BackdropTemplate");
    Skin.Backdrop(popupDialog.summary, Colors.sessionListBg, Colors.memberBorder);
    popupDialog.summary:SetHeight(p.summaryIconSize + p.summaryPadding * 2);

    popupDialog.summaryIcon = popupDialog.summary:CreateTexture(nil, "ARTWORK");
    popupDialog.summaryIcon:SetSize(p.summaryIconSize, p.summaryIconSize);
    popupDialog.summaryIcon:SetPoint("LEFT", popupDialog.summary, "LEFT", p.summaryPadding, 0);
    popupDialog.summaryIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92);
    popupDialog.summaryIconBorder = CreateFrame("Frame", nil, popupDialog.summary, "BackdropTemplate");
    popupDialog.summaryIconBorder:SetPoint("TOPLEFT", popupDialog.summaryIcon, "TOPLEFT", -1, 1);
    popupDialog.summaryIconBorder:SetPoint("BOTTOMRIGHT", popupDialog.summaryIcon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(popupDialog.summaryIconBorder, nil, Colors.transparent, 1);

    popupDialog.summaryItemName = popupDialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.summaryItemName, "body");
    popupDialog.summaryItemName:SetPoint("TOPLEFT", popupDialog.summaryIcon, "TOPRIGHT", p.summaryIconGap, 0);
    popupDialog.summaryItemName:SetJustifyH("LEFT");
    popupDialog.summaryItemName:SetWordWrap(false);

    popupDialog.summaryToLine = popupDialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.summaryToLine, "small");
    popupDialog.summaryToLine:SetPoint("TOPLEFT", popupDialog.summaryItemName, "BOTTOMLEFT", 0, -p.summaryLineGap);
    popupDialog.summaryToLine:SetJustifyH("LEFT");
    popupDialog.summaryToLine:SetWordWrap(false);

    local mp = Sizes.mainPanel;
    popupDialog.summaryPill = CreateFrame("Frame", nil, popupDialog.summary);
    popupDialog.summaryPill:SetHeight(mp.pillHeight);
    Skin.Pill(popupDialog.summaryPill);
    popupDialog.summaryPill.dot = popupDialog.summaryPill:CreateTexture(nil, "ARTWORK");
    popupDialog.summaryPill.dot:SetSize(mp.pillDotSize, mp.pillDotSize);
    popupDialog.summaryPill.dot:SetPoint("LEFT", popupDialog.summaryPill, "LEFT", mp.pillPadX, 0);
    popupDialog.summaryPill.dot:SetTexture("Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Dot");
    popupDialog.summaryPill.label = popupDialog.summaryPill:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.summaryPill.label, "small");
    popupDialog.summaryPill.label:SetTextColor(unpack(Colors.text));
    popupDialog.summaryPill.label:SetPoint("LEFT", popupDialog.summaryPill.dot, "RIGHT", mp.pillDotGap, 0);

    popupDialog.summaryVoteCount = popupDialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.summaryVoteCount, "sectionHeader");
    popupDialog.summaryVoteCount:SetTextColor(unpack(Colors.text));
    popupDialog.summaryVoteCount:SetJustifyH("RIGHT");

    popupDialog.summaryVoteLabel = popupDialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.summaryVoteLabel, "small");
    popupDialog.summaryVoteLabel:SetTextColor(unpack(Colors.muted));
    popupDialog.summaryVoteLabel:SetPoint("TOP", popupDialog.summaryVoteCount, "BOTTOM", 0, -2);
    popupDialog.summaryVoteLabel:SetPoint("RIGHT", popupDialog.summaryVoteCount, "RIGHT", 0, 0);
    popupDialog.summaryVoteLabel:SetText("votes");

    popupDialog.noteText = popupDialog:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.noteText, "small");
    popupDialog.noteText:SetTextColor(unpack(Colors.description));
    popupDialog.noteText:SetJustifyH("LEFT");
    popupDialog.noteText:SetWidth(p.width - p.padding * 2);

    popupDialog.warningBox = CreateFrame("Frame", nil, popupDialog, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(popupDialog.warningBox, Colors.awardWarningBg, Colors.awardWarningBorder, 1);
    popupDialog.warningIcon = popupDialog.warningBox:CreateTexture(nil, "ARTWORK");
    popupDialog.warningIcon:SetSize(p.warningIconSize, p.warningIconSize);
    popupDialog.warningIcon:SetPoint("LEFT", popupDialog.warningBox, "LEFT", p.warningPadding, 0);
    popupDialog.warningIcon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew");
    popupDialog.warningIcon:SetVertexColor(unpack(Colors.awardWarningIcon));
    popupDialog.warningText = popupDialog.warningBox:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.warningText, "small");
    popupDialog.warningText:SetTextColor(unpack(Colors.awardWarningText));
    popupDialog.warningText:SetPoint("TOPLEFT", popupDialog.warningBox, "TOPLEFT", p.warningPadding + p.warningIconSize + 8, -p.warningPadding);
    popupDialog.warningText:SetWidth(p.width - p.padding * 2 - (p.warningPadding + p.warningIconSize + 8) - p.warningPadding);
    popupDialog.warningText:SetJustifyH("LEFT");
    popupDialog.warningText:SetWordWrap(true);

    popupDialog.leftRaidText = popupDialog:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.leftRaidText, "small");
    popupDialog.leftRaidText:SetTextColor(unpack(Colors.awardWarningIcon));
    popupDialog.leftRaidText:SetWidth(p.width - p.padding * 2);
    popupDialog.leftRaidText:SetJustifyH("LEFT");
    popupDialog.leftRaidText:Hide();

    ----------------------------------------------------------------------
    -- End-session-early summary box: "<assigned> of <total> assigned" /
    -- "<n> never awarded" counts row, plus a wrapping row of the unassigned
    -- items' own icons (built by ShowEndSessionEarlyPopup below).
    ----------------------------------------------------------------------
    popupDialog.endEarlySummary = CreateFrame("Frame", nil, popupDialog, "BackdropTemplate");
    Skin.Backdrop(popupDialog.endEarlySummary, Colors.sessionListBg, Colors.memberBorder);

    popupDialog.endEarlyCountsText = popupDialog.endEarlySummary:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.endEarlyCountsText, "small");
    popupDialog.endEarlyCountsText:SetTextColor(unpack(Colors.description));
    popupDialog.endEarlyCountsText:SetJustifyH("LEFT");
    popupDialog.endEarlyCountsText:SetWordWrap(false);

    popupDialog.endEarlyNeverText = popupDialog.endEarlySummary:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.endEarlyNeverText, "small");
    popupDialog.endEarlyNeverText:SetTextColor(unpack(Colors.muted));
    popupDialog.endEarlyNeverText:SetJustifyH("RIGHT");
    popupDialog.endEarlyNeverText:SetWordWrap(false);

    popupDialog.endEarlyIcons = {};
    for i = 1, p.endEarlyMaxIcons do
        local icon = CreateFrame("Frame", nil, popupDialog.endEarlySummary, "BackdropTemplate");
        icon:SetSize(p.endEarlyIconSize, p.endEarlyIconSize);
        local bt = p.endEarlyIconBorderThickness;
        icon.tex = icon:CreateTexture(nil, "ARTWORK");
        icon.tex:SetPoint("TOPLEFT", icon, "TOPLEFT", bt, -bt);
        icon.tex:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -bt, bt);
        icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92);
        Theme.Helpers.SetFlatBackdrop(icon, nil, Colors.transparent, bt);
        icon:EnableMouse(true);
        icon:HookScript("OnEnter", function(self)
            if (not self.itemLink) then return; end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink(self.itemLink);
            GameTooltip:Show();
        end);
        icon:HookScript("OnLeave", function() GameTooltip:Hide(); end);
        icon:Hide();
        popupDialog.endEarlyIcons[i] = icon;
    end

    popupDialog.endEarlyMoreText = popupDialog.endEarlySummary:CreateFontString(nil, "OVERLAY");
    SetFont(popupDialog.endEarlyMoreText, "small");
    popupDialog.endEarlyMoreText:SetTextColor(unpack(Colors.muted));
    popupDialog.endEarlyMoreText:Hide();
end

function HidePopup()
    popupState = nil;
    if (popup) then popup:Hide(); end
end

local function applyAward(item, candidateName)
    Awards.AwardItem(item.session, candidateName);

    if (FL.Settings.GetJumpToNextUnassigned()) then
        local Session = getSession();
        local nextSession = Session and Awards.NextUnassignedItem(Session, item.session, 1);
        if (nextSession) then selectedItemSession = nextSession; end
    end
    doRefresh();
end

function ConfirmPopup()
    if (not popupState) then return; end
    local item, entry = popupState.item, popupState.entry;
    HidePopup();
    applyAward(item, entry.name);
end

-- Middle-click quick assign - same effect as the right-click popup's
-- confirm, minus the confirmation step (Step 7's "just award it" path).
function QuickAssignRaider(item, candidateName)
    applyAward(item, candidateName);
end

function ShowPopup(item, entry)
    ensurePopup();
    local p = Sizes.popup;
    local popupDialog = popup.dialog;
    local isReassign = item.awardedTo ~= nil;
    -- item is a live reference into Session.items, so item.awardedTo/
    -- awardCount keep changing under popupState as the session mutates -
    -- awardCountAtOpen is the one snapshot taken at open time, used below to
    -- detect "an award for this item arrived from elsewhere while this was
    -- open" without it being trivially always-equal-to-itself.
    popupState = { item = item, entry = entry, mode = isReassign and "reassign" or "assign", awardCountAtOpen = item.awardCount or 0 };

    popupDialog.title:SetText(isReassign and "Reassign item?" or "Assign item?");
    -- Every button role reverts to its own conventional look here - a prior
    -- End Session Early open (see ShowEndSessionEarlyPopup below) swaps both
    -- buttons' variants and overrides confirmButton's text color, since this
    -- whole popup/dialog/button trio is one shared singleton across every
    -- mode.
    Skin.SetButtonVariant(popup.cancelButton, "default");
    Skin.SetButtonVariant(popup.confirmButton, "primary");
    -- onCancel is the window's own HidePopup (not just popup:Hide()) so a
    -- dismiss via Cancel/Escape/scrim-click also clears popupState - onConfirm
    -- is ConfirmPopup, which already calls HidePopup itself before awarding.
    popup:SetButtons("Cancel", isReassign and "Reassign" or "Assign", ConfirmPopup, HidePopup);
    popupDialog.endEarlySummary:Hide();
    -- The End Session popups hide the summary box; this mode must re-show it.
    popupDialog.summary:Show();

    local quality = Util.GetItemQuality(item.itemLink);
    local qr, qg, qb = Util.GetItemQualityColor(quality);
    popupDialog.summaryIcon:SetTexture(itemIcon(item));
    popupDialog.summaryIconBorder:SetBackdropBorderColor(qr or 0.6, qg or 0.6, qb or 0.6);
    popupDialog.summaryItemName:SetTextColor(qr or 1, qg or 1, qb or 1);
    setTextEllipsized(popupDialog.summaryItemName, item.itemName or item.itemLink or "", p.width - p.summaryIconSize - p.summaryIconGap - p.summaryPadding * 2 - 60);
    popupDialog.summaryToLine:SetTextColor(unpack(Colors.description));
    popupDialog.summaryToLine:SetText("to " .. Util.classColoredName(entry.name, entry.class));

    local mp = Sizes.mainPanel;
    local colorEntry = Awards.ResponseColor(entry.candidate.response);
    popupDialog.summaryPill:SetPillColor(unpack(colorEntry.color));
    popupDialog.summaryPill.dot:SetVertexColor(unpack(colorEntry.color));
    popupDialog.summaryPill.label:SetText(Awards.ResponseLabel(entry.candidate.response));
    popupDialog.summaryPill:SetWidth(mp.pillPadX + mp.pillDotSize + mp.pillDotGap + popupDialog.summaryPill.label:GetStringWidth() + mp.pillPadX);
    popupDialog.summaryPill:ClearAllPoints();
    popupDialog.summaryPill:SetPoint("LEFT", popupDialog.summaryToLine, "RIGHT", 2, 0);

    local voteCount = Util.tcount(entry.candidate.approvals);
    popupDialog.summaryVoteCount:SetText(tostring(voteCount));

    local stillInRaid = Util.groupMembers()[entry.name] ~= nil or Util.UnitName("player") == entry.name;

    popup:Show(function(dialog, y)
        -- Summary box height fits its 2-line text column (name / to+pill) or
        -- the icon, whichever is taller.
        local secondLineHeight = math.max(popupDialog.summaryToLine:GetStringHeight(), mp.pillHeight);
        local textColumnHeight = popupDialog.summaryItemName:GetStringHeight() + p.summaryLineGap
            + secondLineHeight;
        local summaryHeight = math.max(p.summaryIconSize, textColumnHeight) + p.summaryPadding * 2;
        popupDialog.summary:SetHeight(summaryHeight);
        popupDialog.summary:ClearAllPoints();
        popupDialog.summary:SetPoint("TOPLEFT", dialog, "TOPLEFT", p.padding, y);
        popupDialog.summary:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -p.padding, y);
        y = y - summaryHeight - p.sectionGap;

        local voteBlockHeight = popupDialog.summaryVoteCount:GetStringHeight() + 2
            + popupDialog.summaryVoteLabel:GetStringHeight();
        popupDialog.summaryVoteCount:ClearAllPoints();
        popupDialog.summaryVoteCount:SetPoint("TOPRIGHT", popupDialog.summary, "TOPRIGHT",
            -p.summaryPadding, -(summaryHeight - voteBlockHeight) / 2);

        local note = entry.candidate.note;
        if (note and note ~= "") then
            popupDialog.noteText:ClearAllPoints();
            popupDialog.noteText:SetPoint("TOPLEFT", dialog, "TOPLEFT", p.padding, y);
            popupDialog.noteText:SetText(('Note: "%s"'):format(note));
            popupDialog.noteText:Show();
            y = y - popupDialog.noteText:GetStringHeight() - p.sectionGap;
        else
            popupDialog.noteText:Hide();
        end

        if (isReassign) then
            local prevWinner = item.awardedTo;
            local prevClass;
            local members = Util.groupMembers();
            prevClass = members[prevWinner];
            popupDialog.warningText:SetText(("Currently assigned to %s. Reassigning will replace them.")
                :format(Util.classColoredName(prevWinner, prevClass)));
            popupDialog.warningBox:ClearAllPoints();
            popupDialog.warningBox:SetPoint("TOPLEFT", dialog, "TOPLEFT", p.padding, y);
            popupDialog.warningBox:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -p.padding, y);
            local textHeight = popupDialog.warningText:GetStringHeight();
            popupDialog.warningBox:SetHeight(math.max(p.warningIconSize, textHeight) + p.warningPadding * 2);
            popupDialog.warningBox:Show();
            y = y - popupDialog.warningBox:GetHeight() - p.sectionGap;
        else
            popupDialog.warningBox:Hide();
        end

        if (not stillInRaid) then
            popupDialog.leftRaidText:ClearAllPoints();
            popupDialog.leftRaidText:SetPoint("TOPLEFT", dialog, "TOPLEFT", p.padding, y);
            popupDialog.leftRaidText:SetText(("%s is no longer in the raid"):format(entry.name));
            popupDialog.leftRaidText:Show();
            y = y - popupDialog.leftRaidText:GetStringHeight() - p.sectionGap;
        else
            popupDialog.leftRaidText:Hide();
        end

        return y;
    end);

    popup:SetConfirmEnabled(stillInRaid);
end

--------------------------------------------------------------------------
-- End Session confirmation - reuses the same Skin.ConfirmPopup controller
-- and warning-box styling as the assign/reassign popup above, just with its
-- own (simpler) content: no per-candidate summary, only a warning.
--------------------------------------------------------------------------

function ConfirmEndSession()
    if (not popupState or popupState.mode ~= "endSession") then return; end
    HidePopup();
    Awards.EndSession();
end

function ShowEndSessionPopup()
    ensurePopup();
    local p = Sizes.popup;
    local popupDialog = popup.dialog;
    popupState = { mode = "endSession" };

    popupDialog.title:SetText("End session?");
    -- See ShowPopup's own reset comment above - this popup/dialog/button trio
    -- is a shared singleton, so every mode reasserts its own button look.
    Skin.SetButtonVariant(popup.cancelButton, "default");
    Skin.SetButtonVariant(popup.confirmButton, "primary");
    popup:SetButtons("Cancel", "End Session", ConfirmEndSession, HidePopup);

    popupDialog.summary:Hide();
    popupDialog.noteText:Hide();
    popupDialog.leftRaidText:Hide();
    popupDialog.endEarlySummary:Hide();
    popupDialog.warningText:SetText(
        "This ends the loot council session for everyone. Any remaining unassigned items stay unassigned, and this window can't be reopened once it's ended."
    );

    popup:Show(function(dialog, y)
        popupDialog.warningBox:ClearAllPoints();
        popupDialog.warningBox:SetPoint("TOPLEFT", dialog, "TOPLEFT", p.padding, y);
        popupDialog.warningBox:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -p.padding, y);
        local textHeight = popupDialog.warningText:GetStringHeight();
        popupDialog.warningBox:SetHeight(math.max(p.warningIconSize, textHeight) + p.warningPadding * 2);
        popupDialog.warningBox:Show();
        y = y - popupDialog.warningBox:GetHeight() - p.sectionGap;

        return y;
    end);
end

--------------------------------------------------------------------------
-- End session EARLY confirmation - same Skin.ConfirmPopup controller and
-- warning-box styling as End Session above, but reachable at any point (see
-- the title bar's endEarlyButton) rather than only once every item is
-- assigned, so it carries its own richer content: an assigned/unassigned
-- count + the unassigned items' own icons, ahead of the warning box.
--
-- Button roles are intentionally inverted from every other popup in this
-- file: Skin.ConfirmPopup always wires Escape/scrim-click to the CANCEL
-- button's own action (see ConfirmPopupMethods' OnKeyDown/scrim OnMouseUp),
-- and the spec requires Escape to keep the session running - so "Keep
-- Session" has to BE the cancel button (gold/primary-styled here to read as
-- the safe default choice) while "End Session" takes the confirm button's
-- slot (default-styled, red text) even though that puts the destructive
-- action on Enter. That mirrors ShowEndSessionPopup's own existing
-- End-Session-on-Enter convention above, just with Keep Session now also
-- getting Escape.
--------------------------------------------------------------------------

function ConfirmEndSessionEarly()
    if (not popupState or popupState.mode ~= "endSessionEarly") then return; end
    HidePopup();
    Awards.EndSessionEarly();
end

function ShowEndSessionEarlyPopup()
    -- Closes any already-open Assign/Reassign confirm (reachable while this
    -- window's title bar - unlike its item list/main panel - stays clickable
    -- under that popup's own scrim, see Skin.ConfirmPopup's scrimTopInset).
    HidePopup();
    ensurePopup();

    local Session = getSession();
    if (not Session) then return; end

    local p = Sizes.popup;
    local popupDialog = popup.dialog;
    local unassigned, _, assignedCount, totalCount = Awards.PartitionItems(Session);

    -- Everything's already assigned, so ending now isn't "early" - fall back
    -- to the normal End Session popup instead of the early-specific one
    -- (with its unassigned-items summary/icon grid that'd otherwise show 0).
    if (#unassigned == 0) then
        ShowEndSessionPopup();
        return;
    end

    popupState = { mode = "endSessionEarly" };

    popupDialog.title:SetText("End this session early?");

    Skin.SetButtonVariant(popup.cancelButton, "primary");
    Skin.SetButtonVariant(popup.confirmButton, "default");
    -- cancelButton/onCancel = "Keep Session" (Escape/scrim-click/click all
    -- route through it - see the comment above), confirmButton/onConfirm =
    -- "End Session".
    popup:SetButtons("Keep Session", "End Session", ConfirmEndSessionEarly, HidePopup);

    popupDialog.summary:Hide();
    popupDialog.noteText:Hide();
    popupDialog.leftRaidText:Hide();

    popupDialog.endEarlyCountsText:SetText(("|cff%s%d|r of %d items assigned"):format(hex(Colors.gold), assignedCount, totalCount));
    popupDialog.endEarlyCountsText:ClearAllPoints();
    popupDialog.endEarlyCountsText:SetPoint("TOPLEFT", popupDialog.endEarlySummary, "TOPLEFT", p.endEarlySummaryPadding, -p.endEarlySummaryPadding);

    popupDialog.endEarlyNeverText:SetText(("%d never awarded"):format(#unassigned));
    popupDialog.endEarlyNeverText:ClearAllPoints();
    popupDialog.endEarlyNeverText:SetPoint("TOPRIGHT", popupDialog.endEarlySummary, "TOPRIGHT", -p.endEarlySummaryPadding, -p.endEarlySummaryPadding);

    local countsHeight = math.max(popupDialog.endEarlyCountsText:GetStringHeight(), popupDialog.endEarlyNeverText:GetStringHeight());

    -- Wrapping icon grid, laid out the same top-down col/row way
    -- paintItemPanel's own layoutGrid does, just with a column count derived
    -- from this popup's fixed width instead of a hardcoded constant (that
    -- window's item panel has its own fixed pixel width too, its gridColumns
    -- is just precomputed by hand instead - see UI/Sizes.lua's comment there).
    local showIconRow = #unassigned > 0;
    local iconRowHeight = 0;
    if (showIconRow) then
        local availWidth = p.width - p.padding * 2 - p.endEarlySummaryPadding * 2;
        local step = p.endEarlyIconSize + p.endEarlyIconGap;
        local columns = math.max(1, math.floor((availWidth + p.endEarlyIconGap) / step));
        local shownCount = math.min(#unassigned, p.endEarlyMaxIcons);
        local extra = #unassigned - shownCount;
        local totalSlots = shownCount + (extra > 0 and 1 or 0); -- "+N more" occupies a trailing slot
        local rows = math.max(1, math.ceil(totalSlots / columns));
        iconRowHeight = p.endEarlyRowGap + rows * p.endEarlyIconSize + (rows - 1) * p.endEarlyIconGap;

        local rowTop = -(p.endEarlySummaryPadding + countsHeight + p.endEarlyRowGap);
        for i = 1, shownCount do
            local item = unassigned[i];
            local icon = popupDialog.endEarlyIcons[i];
            local col = (i - 1) % columns;
            local row = math.floor((i - 1) / columns);
            icon:ClearAllPoints();
            icon:SetPoint("TOPLEFT", popupDialog.endEarlySummary, "TOPLEFT",
                p.endEarlySummaryPadding + col * step, rowTop - row * (p.endEarlyIconSize + p.endEarlyIconGap));
            local quality = Util.GetItemQuality(item.itemLink);
            local qr, qg, qb = Util.GetItemQualityColor(quality);
            icon.tex:SetTexture(itemIcon(item));
            icon:SetBackdropBorderColor(qr or 0.6, qg or 0.6, qb or 0.6);
            icon.itemLink = item.itemLink;
            icon:Show();
        end
        for i = shownCount + 1, p.endEarlyMaxIcons do
            popupDialog.endEarlyIcons[i]:Hide();
            popupDialog.endEarlyIcons[i].itemLink = nil;
        end

        if (extra > 0) then
            local slot = shownCount; -- 0-based - the cell right after the last shown icon
            local col = slot % columns;
            local row = math.floor(slot / columns);
            popupDialog.endEarlyMoreText:SetText(("+%d more"):format(extra));
            popupDialog.endEarlyMoreText:ClearAllPoints();
            popupDialog.endEarlyMoreText:SetPoint("LEFT", popupDialog.endEarlySummary, "TOPLEFT",
                p.endEarlySummaryPadding + col * step, rowTop - row * (p.endEarlyIconSize + p.endEarlyIconGap) - p.endEarlyIconSize / 2);
            popupDialog.endEarlyMoreText:Show();
        else
            popupDialog.endEarlyMoreText:Hide();
        end
    else
        for i = 1, p.endEarlyMaxIcons do
            popupDialog.endEarlyIcons[i]:Hide();
            popupDialog.endEarlyIcons[i].itemLink = nil;
        end
        popupDialog.endEarlyMoreText:Hide();
    end

    popupDialog.warningText:SetText(
        "Unassigned items stay in your bags and leave the session. Everyone's Review & Vote window closes and their votes are discarded. Items already assigned stay in the trade queue."
    );

    popup:Show(function(dialog, y)
        local summaryHeight = p.endEarlySummaryPadding * 2 + countsHeight + iconRowHeight;
        popupDialog.endEarlySummary:SetHeight(summaryHeight);
        popupDialog.endEarlySummary:ClearAllPoints();
        popupDialog.endEarlySummary:SetPoint("TOPLEFT", dialog, "TOPLEFT", p.padding, y);
        popupDialog.endEarlySummary:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -p.padding, y);
        popupDialog.endEarlySummary:Show();
        y = y - summaryHeight - p.sectionGap;

        popupDialog.warningBox:ClearAllPoints();
        popupDialog.warningBox:SetPoint("TOPLEFT", dialog, "TOPLEFT", p.padding, y);
        popupDialog.warningBox:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -p.padding, y);
        local textHeight = popupDialog.warningText:GetStringHeight();
        popupDialog.warningBox:SetHeight(math.max(p.warningIconSize, textHeight) + p.warningPadding * 2);
        popupDialog.warningBox:Show();
        y = y - popupDialog.warningBox:GetHeight() - p.sectionGap;

        return y;
    end);

    -- Set after Show() (which unconditionally re-enables confirmButton, and
    -- so would re-fire OnEnable -> applyEnabled -> reset this back to the
    -- "default" variant's own text color if set any earlier).
    popup.confirmButton.text:SetTextColor(unpack(Colors.awardWarningIcon));
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

local function paintItemPanel()
    local Session = getSession();
    local unassigned, assigned, assignedCount, totalCount = Awards.PartitionItems(Session);
    local ip = Sizes.itemPanel

    itemCountText:SetText(("|cff%s%d|r / %d assigned"):format(hex(Colors.gold), assignedCount, totalCount));

    local pct = (totalCount > 0) and (assignedCount / totalCount) or 0;
    local trackWidth = progressTrack:GetWidth();
    if (trackWidth and trackWidth > 0) then
        progressFill:SetWidth(math.max(1, trackWidth * pct));
    end

    local columns, iconSize, spacing = ip.gridColumns, ip.gridIconSize, ip.gridSpacing;
    -- The selected-ring frame is drawn outside each icon's own bounds (see
    -- createGridIcon), so the leftmost column needs a matching inset here or
    -- the scroll frame clips the ring's left edge off entirely.
    local ringInset = ip.selectedRingThickness + ip.selectedRingGap;
    local function layoutGrid(list, startIndex, top)
        for i, item in ipairs(list) do
            local slot = gridIcons[startIndex + i - 1];
            if (slot) then
                local col = (i - 1) % columns;
                local row = math.floor((i - 1) / columns);
                slot:ClearAllPoints();
                slot:SetPoint("TOPLEFT", leftScrollChild, "TOPLEFT", ringInset + col * (iconSize + spacing), top - row * (iconSize + spacing));
                slot.itemSession = item.session;
                slot.itemLink = item.itemLink;
                slot.icon:SetTexture(itemIcon(item));
                local quality = Util.GetItemQuality(item.itemLink);
                local qr, qg, qb = Util.GetItemQualityColor(quality);
                slot:SetBackdropBorderColor(qr or 0.6, qg or 0.6, qb or 0.6);
                slot.ring:SetShown(item.session == selectedItemSession);
                if (item.awardedTo) then
                    slot.icon:SetAlpha(ip.assignedAlpha);
                    slot.badge:Show();
                    slot.winnerName = item.awardedTo;
                    local members = Util.groupMembers();
                    slot.winnerClass = members[item.awardedTo];
                else
                    slot.icon:SetAlpha(1);
                    slot.badge:Hide();
                    slot.winnerName = nil;
                    slot.winnerClass = nil;
                end
                slot:Show();
            end
        end
        local rows = math.ceil(#list / columns);
        return rows * (iconSize + spacing);
    end

    local y = -14; -- below the "UNASSIGNED · N" label
    unassignedLabel:SetText(("UNASSIGNED \194\183 %d"):format(#unassigned));
    unassignedLabel:ClearAllPoints();
    unassignedLabel:SetPoint("TOPLEFT", leftScrollChild, "TOPLEFT", 0, 0);
    local unassignedHeight = layoutGrid(unassigned, 1, y);
    y = y - unassignedHeight - ip.sectionGap - 14;

    assignedLabel:SetText(("ASSIGNED \194\183 %d"):format(#assigned));
    assignedLabel:ClearAllPoints();
    assignedLabel:SetPoint("TOPLEFT", leftScrollChild, "TOPLEFT", 0, y + 14);
    local assignedHeight = layoutGrid(assigned, #unassigned + 1, y);
    y = y - assignedHeight;

    for i = #unassigned + #assigned + 1, MAX_GRID_ICONS do
        local slot = gridIcons[i];
        if (slot) then slot:Hide(); slot.itemSession = nil; end
    end

    leftScrollChild:SetHeight(math.max(-y, 1));
    if (leftScroll.ScrollBar and leftScroll.ScrollBar.zlUpdateVisibility) then
        leftScroll.ScrollBar.zlUpdateVisibility();
    end
end

local function paintHeader(item, candidateCount, voteTotal)
    local Session = getSession();
    -- "No more unassigned items" turns the nav button into a leader-only
    -- "End Session" action instead - a non-leader with everything assigned
    -- just sees Next unassigned go permanently disabled, same as it always
    -- has when NextUnassignedItem has nowhere left to go.
    local _, _, assignedCount, totalCount = Awards.PartitionItems(Session);
    local canEndSession = totalCount > 0 and assignedCount == totalCount and Awards.CanAwardItems();
    local nextMode = canEndSession and "endSession" or "next";
    if (nextButton.mode ~= nextMode) then
        nextButton.mode = nextMode;
        nextButton.text:SetText(canEndSession and "End Session" or NEXT_UNASSIGNED_LABEL);
        nextButton.chevron:SetShown(not canEndSession);
        local width = nextButton.text:GetStringWidth() + 24;
        if (not canEndSession) then
            width = width + Sizes.mainPanel.navChevronSize + Sizes.mainPanel.navChevronGap;
        end
        nextButton:SetWidth(width);
        repositionNextLabel(0);
    end

    if (not item) then
        headerNameText:SetText("");
        headerTypeText:SetText("");
        headerIcon:SetTexture(FALLBACK_ICON);
        headerBadge:Hide();
        disenchantButton:SetEnabled(false);
        prevButton:SetEnabled(false);
        nextButton:SetEnabled(canEndSession);
        return;
    end

    headerIcon:SetTexture(itemIcon(item));
    local quality = Util.GetItemQuality(item.itemLink);
    local qr, qg, qb = Util.GetItemQualityColor(quality);
    headerIconBorder:SetBackdropBorderColor(qr or 0.6, qg or 0.6, qb or 0.6);
    headerNameText:SetTextColor(qr or 1, qg or 1, qb or 1);
    -- Drop the addon-wide font outline just for this large title - at
    -- pageTitle size it reads as a heavy border around the text. Re-applied
    -- every repaint (cheap, idempotent) so a live font-face change
    -- (FL.Theme.ApplyFont re-stamping every registered role fontstring with
    -- the shared outline flag) can't silently bring it back while this
    -- window stays open.
    do
        local fontPath, fontSize = headerNameText:GetFont();
        if (fontPath) then headerNameText:SetFont(fontPath, fontSize, ""); end
    end

    local name, _, _, _, _, _, itemSubType, _, _ = Util.GetItemInfo(item.itemLink);
    if (name) then
        setTextEllipsized(headerNameText, ("[%s]"):format(name), headerNameText:GetWidth());
        local typeLine = Util.JoinTypeParts(itemSubType);
        typeLine = Util.JoinTypeParts(typeLine, ("%d response%s"):format(candidateCount, candidateCount == 1 and "" or "s"));
        typeLine = Util.JoinTypeParts(typeLine, ("%d vote%s"):format(voteTotal, voteTotal == 1 and "" or "s"));
        headerTypeText:SetText(typeLine);
    else
        headerNameText:SetText(item.itemLink or "");
        headerTypeText:SetText("");
        local it = Item:CreateFromItemLink(item.itemLink);
        it:ContinueOnItemLoad(function()
            if (getSelectedItem() == item) then doRefresh(); end
        end);
    end

    if (item.awardedTo == DISENCHANT_RECIPIENT) then
        headerBadgeText:SetText(("To be |cff%sDisenchanted|r"):format(hex(Colors.disenchantAccent)));
        headerBadgeText:SetTextColor(unpack(Colors.gold));
        headerBadge:SetWidth(headerBadgeText:GetStringWidth() + Sizes.mainPanel.badgePadX * 2);
        headerBadge:ClearAllPoints();
        headerBadge:SetPoint("LEFT", headerTypeText, "RIGHT", 8, 0);
        headerBadge:Show();
    elseif (item.awardedTo) then
        local members = Util.groupMembers();
        headerBadgeText:SetText("Assigned to " .. Util.classColoredName(item.awardedTo, members[item.awardedTo]));
        headerBadgeText:SetTextColor(unpack(Colors.gold));
        headerBadge:SetWidth(headerBadgeText:GetStringWidth() + Sizes.mainPanel.badgePadX * 2);
        headerBadge:ClearAllPoints();
        headerBadge:SetPoint("LEFT", headerTypeText, "RIGHT", 8, 0);
        headerBadge:Show();
    else
        headerBadge:Hide();
    end

    disenchantButton:SetEnabled(Awards.CanAwardItems());

    local prevSession = Awards.NextUnassignedItem(Session, item.session, -1);
    local nextSession = Awards.NextUnassignedItem(Session, item.session, 1);
    prevButton:SetEnabled(prevSession ~= nil);
    nextButton:SetEnabled(canEndSession or nextSession ~= nil);
end

local function paintFooterPermissions()
    local canAward = Awards.CanAwardItems();
    footerHintIcon:SetShown(canAward and C_Texture.GetAtlasInfo(MOUSE_HINT_ATLAS) ~= nil);
    footerHintText:SetText(canAward and "Right-click to assign" or LEADER_ONLY_TEXT);
    footerMiddleHintIcon:SetShown(canAward);
    footerMiddleHintText:SetShown(canAward);
    footerMiddleHintText:SetText("Middle-click to quick assign");
    jumpCheckboxRow.frame:SetShown(canAward);
    endEarlyButton:SetShown(canAward);

    -- historyButton sits left of endEarlyButton when that button is showing
    -- (initiator), but endEarlyButton being hidden doesn't collapse the gap
    -- it reserved - re-anchor straight off closeButton for non-initiators so
    -- the two visible buttons sit flush together.
    historyButton:ClearAllPoints();
    historyButton:SetPoint("TOPRIGHT", canAward and endEarlyButton or closeButton, "TOPLEFT", -6, 0);
end

doRefresh = function()
    if (not frame) then return; end

    local Session = getSession();
    -- A session that isn't active anymore (see LootCouncil.EndSession) closes
    -- this window on every client, not just the one that ended it - matches
    -- RespondWindow.Refresh's own status=="active" gate. Show() below then
    -- refuses to reopen it for as long as this Session stays the current one.
    if (Session and Session.status ~= "active") then
        HidePopup();
        frame:Hide();
        return;
    end

    local leftScrollPos = leftScroll:GetVerticalScroll();
    local rightScrollPos = rightScroll:GetVerticalScroll();

    paintItemPanel();

    if (Session and (not selectedItemSession or not Session.items[selectedItemSession])) then
        selectedItemSession = Session.items[1] and Session.items[1].session or nil;
    end

    local item = getSelectedItem();
    local myName = Util.stripRealm(Util.UnitName("player"));

    local entries = item and Awards.BuildCandidateList(item) or {};
    local voteTotal = 0;
    for _, entry in ipairs(entries) do
        voteTotal = voteTotal + Util.tcount(entry.candidate.approvals);
    end
    -- #entries now also counts not-yet-responded group members (their
    -- placeholder "Awaiting" rows) - the header's "N responses" text still
    -- means actual responses, so it counts item.candidates directly instead.
    local responseCount = item and Util.tcount(item.candidates) or 0;
    paintHeader(item, responseCount, voteTotal);

    local seen = {};
    for i, entry in ipairs(entries) do
        local row = rowPool[entry.name];
        if (not row) then
            row = createRow();
            rowPool[entry.name] = row;
        end
        paintRow(row, entry, item, i - 1, myName);
        seen[entry.name] = true;
    end
    for name, row in pairs(rowPool) do
        if (not seen[name]) then
            row:Hide();
            row.candidate = nil;
            hideRowTooltip(row);
        end
    end

    rightScrollChild:SetHeight(math.max(#entries * (Sizes.mainPanel.rowHeight + Sizes.mainPanel.rowSpacing), 1));
    rightScroll:SetVerticalScroll(math.min(rightScrollPos, math.max(0, rightScroll:GetVerticalScrollRange())));
    leftScroll:SetVerticalScroll(math.min(leftScrollPos, math.max(0, leftScroll:GetVerticalScrollRange())));
    if (rightScroll.ScrollBar and rightScroll.ScrollBar.zlUpdateVisibility) then
        rightScroll.ScrollBar.zlUpdateVisibility();
    end
    updateRightScrollChildWidth();

    paintFooterPermissions();

    -- If an award for this exact item arrived (from any client, including
    -- this one via a different row) while the popup was open, close it and
    -- let the fresh table speak for itself. Otherwise re-run the popup's own
    -- layout so its "still in the raid" check and vote count stay live. Only
    -- assign/reassign popupState carries an .item to resync against - the
    -- End Session and End Session Early popups have no per-item data, so they
    -- just stay open until Cancel/Confirm (or the status-guard above hides
    -- the whole window once the session's actually ended).
    if (popupState and (popupState.mode == "assign" or popupState.mode == "reassign")) then
        local currentAwardCount = popupState.item.awardCount or 0;
        if (currentAwardCount ~= popupState.awardCountAtOpen) then
            HidePopup();
        else
            ShowPopup(popupState.item, popupState.entry);
        end
    end
end

selectItem = function(itemSession)
    selectedItemSession = itemSession;
    doRefresh();
end

function AwardWindow.Refresh()
    if (not frame) then return; end
    pendingRefresh = true;
    if (refreshTimerRunning) then return; end

    local elapsed = GetTime() - lastRefreshTime;
    local delay = math.max(0, REFRESH_THROTTLE - elapsed);
    refreshTimerRunning = true;
    C_Timer.After(delay, function()
        refreshTimerRunning = false;
        if (pendingRefresh) then
            pendingRefresh = false;
            lastRefreshTime = GetTime();
            doRefresh();
        end
    end);
end

--- The scroll child (and so every row's own width, via row:SetPoint("RIGHT",
--- rightScrollChild, "RIGHT")) matches rightScroll's own width, minus the
--- scrollbar's footprint (bar + inset gap) only while that scrollbar is
--- actually shown - so row content never ends up padded for a scrollbar
--- that isn't there, and never sits under one that is.
updateRightScrollChildWidth = function()
    if (not rightScroll or not rightScrollChild) then return; end
    local width = rightScroll:GetWidth();
    local bar = rightScroll.ScrollBar;
    if (bar and bar:IsShown()) then
        width = width - (SharedLayout.scrollbarWidth + SharedLayout.scrollbarInset);
    end
    rightScrollChild:SetWidth(math.max(width, 1));
end

--------------------------------------------------------------------------
-- Window lifecycle
--------------------------------------------------------------------------

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootAwardWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    Pixel.RegisterWindow(frame, {
        width = WINDOW_WIDTH, height = WINDOW_HEIGHT,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    createTitleBar();
    createItemPanel();

    mainPanel = CreateFrame("Frame", nil, frame);
    mainPanel:SetPoint("TOPLEFT", itemPanel, "TOPRIGHT", 0, 0);
    mainPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Sizes.borderInset, Sizes.borderInset);

    local header, headerDivider = createHeaderRow();
    createFooter();

    tableHeaderRow = createTableHeader(headerDivider);

    rightScroll = CreateFrame("ScrollFrame", "ForeverLootAwardWindowRowScroll", mainPanel, "UIPanelScrollFrameTemplate");
    rightScroll:SetPoint("TOPLEFT", tableHeaderRow, "BOTTOMLEFT", 0, -4);
    rightScroll:SetPoint("TOPRIGHT", tableHeaderRow, "BOTTOMRIGHT", 0, -4);
    rightScroll:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, Sizes.mainPanel.footerDividerGap + 8);
    rightScroll:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, Sizes.mainPanel.footerDividerGap + 8);
    rightScroll:EnableMouse(true);

    rightScrollChild = CreateFrame("Frame", nil, rightScroll);
    rightScrollChild:SetPoint("TOPLEFT", rightScroll, "TOPLEFT", 0, 0);
    rightScroll:SetScrollChild(rightScrollChild);
    rightScroll:SetScript("OnSizeChanged", updateRightScrollChildWidth);

    local rightScrollBar = Skin.ScrollBar(rightScroll);
    if (rightScrollBar) then
        rightScrollBar:ClearAllPoints();
        rightScrollBar:SetPoint("TOP", rightScroll, "TOP", 0, 0);
        rightScrollBar:SetPoint("BOTTOM", rightScroll, "BOTTOM", 0, 0);
        rightScrollBar:SetPoint("RIGHT", mainPanel, "RIGHT", -3, 0);
    end
    -- Re-run after Skin.ScrollBar's own OnScrollRangeChanged hook (registered
    -- above, so it runs first) has updated the bar's shown state.
    rightScroll:HookScript("OnScrollRangeChanged", updateRightScrollChildWidth);
    Theme.Helpers.EnableSmoothScroll(rightScroll, { step = Sizes.mainPanel.rowHeight + Sizes.mainPanel.rowSpacing });

    frame:HookScript("OnHide", function() HidePopup(); end);
end

--- Opens the window if the local player is allowed to see it at all -
--- ensureFrame() (and so the frame itself) is never even created for anyone
--- else, so there's no way to reach it, not even a briefly-flashing empty one.
function AwardWindow.Show()
    if (not LootCouncil.CanAccessReviewWindow()) then return; end
    -- Once a session is ended (see LootCouncil.EndSession) this window can't
    -- be reopened for it - not via the chat "reopen" link, Debug's Toggle, or
    -- a later councilSettingsSync auto-show - until a new sessionStart
    -- replaces Session with a fresh, active one.
    local Session = getSession();
    if (Session and Session.status ~= "active") then return; end
    ensureFrame();
    frame:Show();
    doRefresh();
end

function AwardWindow.Hide()
    if (frame) then frame:Hide(); end
end

function AwardWindow.IsShown()
    return frame ~= nil and frame:IsShown();
end

function AwardWindow.Toggle()
    if (frame and frame:IsShown()) then
        AwardWindow.Hide();
    else
        AwardWindow.Show();
    end
end

-- Called on every sessionStart broadcast (LootCouncil.lua's applySessionStart)
-- so a council member/initiator lands straight on the award window as soon
-- as a session goes out - doesn't gate on "has an unassigned item", Show()
-- itself already no-ops for anyone without access.
function AwardWindow.MaybeAutoShow()
    AwardWindow.Show();
end

function AwardWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
