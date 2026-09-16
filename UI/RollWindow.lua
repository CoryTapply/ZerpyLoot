--[[
Plain-frame live roll-off tracker: item, countdown, and a list of who is
rolling, their roll value(s), and how many times each has rolled.

Also doubles as the "start a roll-off" prompt: alt+left-clicking a bag item
opens this same window (via ShowStartPrompt) showing just the item plus a
seconds box and a "Start Roll" button, before anything is broadcast. Those
two controls are local-only state (pendingItemLink below) - nobody else's
client ever sees them, since nothing goes out over addon comm until Start
Roll is actually clicked.
]]

local ZL = ZerpyLoot;
local RollWindow = ZL.UI.RollWindow;
local RollTracker = ZL.RollTracker;
local Util = ZL.Util;

local MAX_ROWS = 40;
local ROW_HEIGHT = 20;
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";
local DEFAULT_TIMER = 15;
-- Shared with the trade queue window's delete icon - see Theme.colors.danger.
local COUNTDOWN_BAR_HOVER_COLOR = ZL.Theme.colors.danger;
local COUNTDOWN_BAR_STOPPED_COLOR = { 0.5, 0.5, 0.5, 1 };

local WINDOW_WIDTH = 260;
local DEFAULT_HEIGHT = 340;
local MAX_HEIGHT = 800;

-- Shared content width every row (item, start prompt, countdown bar, MS/OS
-- buttons) lines up against, and the half-width that gives the MS/OS buttons
-- (and now the Start Roll button) a small gap between them.
local CONTENT_WIDTH = 230;
local BUTTON_GAP = 2;
local HALF_BUTTON_WIDTH = (CONTENT_WIDTH - BUTTON_GAP) / 2;

-- Key this window's saved position is stored under (see Settings.GetWindowPosition/SetWindowPosition).
local POSITION_KEY = "rollWindow";

local frame, itemButton, itemIcon, itemText, countdownText, countdownBar, countdownBarBorder, msButton, osButton, awardedText, scrollChild;
local startRow, secondsBox, startRollButton;
local rows = {};

-- Toggles the bottom-edge resize handle (see Theme.MakeBottomResizable) -
-- disabled while the compact Start Roll prompt is showing, since it sits
-- below minHeight on purpose and grabbing the handle there would otherwise
-- snap the window straight up to minHeight the instant the drag starts.
local setResizeEnabled;

-- Window height while the Start Roll prompt is showing (set below, once
-- startRollButton's position is known) and in-flight grow-animation state
-- (see animateGrowTo/updateHeightAnimation) for when a pending roll-off
-- actually starts.
local compactHeight;
-- Shortest height that still fits everything above the roll list (countdown
-- bar, MS/OS buttons, "Awarded to" text) - set below in ensureFrame, once the
-- scroll frame's position is known. Below this, MS/OS would poke out past
-- the window's own background.
local minHeight;
local heightAnim;
local GROW_ANIMATION_DURATION = 0.25;

-- Set only by ShowStartPrompt (i.e. only on the client that alt+left-clicked
-- the item) and cleared the moment a real RollTracker.CurrentRollOff shows up.
local pendingItemLink;

-- Right-click confirmation before awarding - registered once at load, using
-- the plain Blizzard StaticPopupDialogs API (confirmed via Gargul's own
-- Classes/Dialog.lua that this is exactly what it uses under the hood, just
-- wrapped in a thin class - no addon-specific dialog library needed here).
StaticPopupDialogs["ZERPYLOOT_AWARD_CONFIRM"] = {
    text = "Award %s to %s?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data)
        RollTracker.AwardItem(data.player, data.rollData);
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
};

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = ZL.Settings.GetWindowPosition(POSITION_KEY);
    frame = ZL.Theme.CreateWindow("ZerpyLootRollWindow", WINDOW_WIDTH, ZL.Settings.GetRollWindowHeight() or DEFAULT_HEIGHT,
        savedPosition and savedPosition.x or 0, savedPosition and savedPosition.y or 0,
        function(x, y) ZL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    frame:Hide();

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton");
    closeButton:SetSize(20, 20);
    closeButton:SetPoint("TOPRIGHT", -4, -4);
    closeButton:SetScript("OnClick", function() RollWindow.Hide(); end);
    ZL.Theme.SkinCloseButton(closeButton);

    -- Row container purely for layout (not mouse-enabled) - only the icon
    -- itself (itemButton) triggers the tooltip, not the name text next to it.
    -- Sits in the same row as the close button, but its right edge tracks the
    -- close button's left edge (with a small gap) instead of a fixed width,
    -- so a long item name never runs under it.
    local itemRow = CreateFrame("Frame", nil, frame);
    itemRow:SetPoint("TOPLEFT", 12, -8);
    itemRow:SetPoint("RIGHT", closeButton, "LEFT", -6, 0);
    itemRow:SetHeight(30);

    itemButton = CreateFrame("Button", nil, itemRow);
    itemButton:SetSize(28, 28);
    itemButton:SetPoint("LEFT", 0, 0);

    itemIcon = itemButton:CreateTexture(nil, "ARTWORK");
    itemIcon:SetAllPoints(itemButton);
    -- Crop ~1/12 off each edge (~20% zoom) to trim the icon art's own padding.
    itemIcon:SetTexCoord(0.0833, 0.9167, 0.0833, 0.9167);

    -- A backdrop border drawn directly on itemButton would sit under the
    -- icon's own ARTWORK-layer texture (which fully covers itemButton's
    -- bounds edge-to-edge), so it's drawn on a separate wrapper frame pulled
    -- 1px outside itemButton's own bounds instead (same trick as the roller
    -- popup's countdown bar border).
    local iconBorder = CreateFrame("Frame", nil, itemRow, "BackdropTemplate");
    iconBorder:SetPoint("TOPLEFT", itemButton, "TOPLEFT", -1, 1);
    iconBorder:SetPoint("BOTTOMRIGHT", itemButton, "BOTTOMRIGHT", 1, -1);
    ZL.Theme.SkinBorder(iconBorder);

    itemText = itemRow:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.normalMedium);
    itemText:SetPoint("LEFT", itemButton, "RIGHT", 6, 0);
    itemText:SetPoint("RIGHT", itemRow, "RIGHT");
    itemText:SetJustifyH("LEFT");
    itemText:SetWordWrap(true);

    itemButton:SetScript("OnEnter", function()
        local RollOff = RollTracker.CurrentRollOff;
        local link = (RollOff and RollOff.item) or pendingItemLink;
        if (not link) then return; end
        GameTooltip:SetOwner(itemButton, "ANCHOR_RIGHT");
        GameTooltip:SetHyperlink(link);
        GameTooltip:Show();
    end);
    itemButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    -- Shift-click to chat-link the item, ctrl-click to dress it up (shared
    -- with TradeQueueWindow's and SoftResImport's icons via Util).
    itemButton:RegisterForClicks("LeftButtonUp");
    itemButton:SetScript("OnClick", function()
        local RollOff = RollTracker.CurrentRollOff;
        local link = (RollOff and RollOff.item) or pendingItemLink;
        Util.HandleItemLinkClick(link);
    end);

    -- Start-roll controls: only ever populated/shown locally by ShowStartPrompt,
    -- on the same client that alt+left-clicked the item.
    -- Anchored to `frame` (not itemButton, whose box is no longer centered
    -- now that its right edge tracks the close button) at itemButton's fixed
    -- bottom edge (-8 top - 30 tall = -38), so this row stays centered on
    -- the window itself.
    -- Single line: "Timer" label left-aligned, then the seconds box, then
    -- the Start Roll button on the right (same width as the MS/OS buttons).
    startRow = CreateFrame("Frame", nil, frame);
    startRow:SetPoint("TOP", 0, -38 - 8);
    startRow:SetSize(CONTENT_WIDTH, 22);
    startRow:Hide();

    local timerLabel = startRow:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.normal);
    timerLabel:SetPoint("LEFT", 0, 0);
    timerLabel:SetText("Timer");

    secondsBox = CreateFrame("EditBox", nil, startRow, "InputBoxTemplate");
    secondsBox:SetSize(32, 20);
    secondsBox:SetMaxLetters(3);
    secondsBox:SetPoint("LEFT", timerLabel, "RIGHT", 6, 0);
    secondsBox:SetAutoFocus(false);
    secondsBox:SetNumeric(true);
    secondsBox:SetJustifyH("RIGHT");
    ZL.Theme.SkinEditBox(secondsBox);

    local secondsSuffix = startRow:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.normal);
    secondsSuffix:SetPoint("LEFT", secondsBox, "RIGHT", 4, 0);
    secondsSuffix:SetText("s");

    startRollButton = CreateFrame("Button", nil, startRow, "UIPanelButtonTemplate");
    startRollButton:SetSize(HALF_BUTTON_WIDTH, 22);
    startRollButton:SetPoint("RIGHT", 0, 0);
    startRollButton:SetText("Start Roll");
    startRollButton:SetScript("OnClick", function()
        local seconds = tonumber(secondsBox:GetText()) or DEFAULT_TIMER;
        ZL.Settings.SetRollOffSeconds(seconds);
        RollTracker.StartRollOff(pendingItemLink, seconds);
    end);
    ZL.Theme.SkinAccentButton(startRollButton);

    -- Height that ends just below the Start Roll button, with the same 12px
    -- bottom margin the scroll frame uses (see its BOTTOMRIGHT anchor
    -- below) - measured off startRollButton's own position rather than
    -- hand-added offsets, so it can't drift out of sync with the layout.
    compactHeight = (frame:GetTop() - startRollButton:GetBottom()) + 12;

    countdownText = frame:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.highlight);
    countdownText:SetPoint("TOP", 0, -38 - 6);

    -- Thin countdown bar, no text of its own (the seconds-remaining text
    -- above already says that). Border drawn on a separate wrapper frame
    -- pulled 1px outside the bar's own bounds (same trick as the roller
    -- popup's countdown bar) since a backdrop border on the bar itself would
    -- sit under its own fill texture.
    countdownBar = CreateFrame("StatusBar", nil, frame);
    countdownBar:SetSize(230, 6);
    countdownBar:SetPoint("TOP", countdownText, "BOTTOM", 0, -6);
    ZL.Theme.ApplyStatusBarTexture(countdownBar, ZL.Settings.GetStatusBarTexture());
    countdownBar:SetStatusBarColor(unpack(ZL.Theme.colors.accent));
    countdownBar:SetMinMaxValues(0, 1);
    countdownBar:SetValue(0);
    countdownBar:Hide(); -- only shown once a roll-off is actually running

    local countdownBarBg = countdownBar:CreateTexture(nil, "BACKGROUND");
    countdownBarBg:SetAllPoints(countdownBar);
    countdownBarBg:SetColorTexture(0, 0, 0, 0.5);

    -- Clicking the bar ends the roll-off early (same broadcast as
    -- RollTracker.StopRollOff, so real Gargul clients in the group pick up
    -- the stop too, not just other ZerpyLoot ones) - only meaningful for
    -- whoever started it, same restriction as awarding a roll.
    countdownBar:EnableMouse(true);
    countdownBar:SetScript("OnEnter", function(self)
        local RollOff = RollTracker.CurrentRollOff;
        if (RollOff and RollOff.active) then
            self:SetStatusBarColor(unpack(COUNTDOWN_BAR_HOVER_COLOR));
        end
    end);
    countdownBar:SetScript("OnLeave", function(self)
        local RollOff = RollTracker.CurrentRollOff;
        if (RollOff and not RollOff.active) then
            self:SetStatusBarColor(unpack(COUNTDOWN_BAR_STOPPED_COLOR));
        else
            self:SetStatusBarColor(unpack(ZL.Theme.colors.accent));
        end
    end);
    countdownBar:SetScript("OnMouseUp", function()
        local RollOff = RollTracker.CurrentRollOff;
        if (not RollOff or not RollOff.active) then return; end

        if (not RollOff.initiatorIsMe) then
            print("|cff8865ffZerpyLoot|r Only the player who started this roll-off can end it early.");
            return;
        end

        RollTracker.StopRollOff();
    end);

    countdownBarBorder = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    countdownBarBorder:SetPoint("TOPLEFT", countdownBar, "TOPLEFT", -1, 1);
    countdownBarBorder:SetPoint("BOTTOMRIGHT", countdownBar, "BOTTOMRIGHT", 1, -1);
    ZL.Theme.SkinBorder(countdownBarBorder);
    countdownBarBorder:Hide();

    -- Same roll buttons as the roller popup, so the initiator can roll on
    -- their own roll-off from this window too, without needing that separate
    -- popup. Sized to leave a small gap between them while still together
    -- spanning exactly as wide as the bar above.
    msButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate");
    msButton:SetSize(HALF_BUTTON_WIDTH, 22);
    msButton:SetPoint("TOPLEFT", countdownBar, "BOTTOMLEFT", 0, -8);
    msButton:SetText("MS");
    msButton:SetScript("OnClick", function() RandomRoll(1, 100); end);
    ZL.Theme.SkinButton(msButton);
    msButton:Hide();

    osButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate");
    osButton:SetSize(HALF_BUTTON_WIDTH, 22);
    osButton:SetPoint("TOPRIGHT", countdownBar, "BOTTOMRIGHT", 0, -8);
    osButton:SetText("OS");
    osButton:SetScript("OnClick", function() RandomRoll(1, 99); end);
    ZL.Theme.SkinButton(osButton);
    osButton:Hide();

    awardedText = frame:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.highlightSmall);
    awardedText:SetPoint("TOPLEFT", msButton, "BOTTOMLEFT", 0, -8);
    awardedText:SetWidth(230);
    awardedText:SetJustifyH("LEFT");

    -- Anchored to awardedText's own bottom edge (rather than a fixed offset
    -- from the window top) so the row list always sits a fixed gap below
    -- whatever text actually ends up there, instead of leaving a large dead
    -- gap when that text is shorter than the space a hardcoded offset assumed.
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate");
    scrollFrame:SetPoint("TOP", awardedText, "BOTTOM", 0, -10);
    scrollFrame:SetPoint("LEFT", frame, "LEFT", 12, 0);
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 12);
    ZL.Theme.SkinScrollBar(scrollFrame);

    -- Shrinking the window down to hide the roll list (and its scrollbar)
    -- entirely means the window's height needs to be able to go as low as
    -- everything ABOVE the scroll frame plus its bottom margin, with zero
    -- left over for the scroll frame itself. Measured directly off the
    -- frame/scroll frame's own current heights (rather than hand-adding up
    -- every anchor offset above) so it can't drift out of sync with that
    -- layout - not even ROW_HEIGHT is added on top, since a single visible
    -- row is exactly what should disappear at this minimum. The extra 4px
    -- is just breathing room below the "Awarded to" text, so the window's
    -- bottom border doesn't land flush against it.
    minHeight = frame:GetHeight() - scrollFrame:GetHeight() + 6;

    -- Within 10px of that minimum, the roll list is squeezed down to a
    -- sliver too thin to be worth a scrollbar - hide it even though there's
    -- technically still scroll range, rather than showing a barely-usable
    -- stub of a thumb. Hooked to OnSizeChanged (not just checked once) so
    -- it tracks live as the window is dragged, not only after release.
    local function updateScrollBarNearMin()
        ZL.Theme.SetScrollBarHidden(scrollFrame, frame:GetHeight() <= minHeight + 10);
    end
    frame:HookScript("OnSizeChanged", updateScrollBarNearMin);
    updateScrollBarNearMin();

    -- Width tracks the scroll frame's own visible width (rather than a fixed
    -- guess at it) so rows always reach exactly to the scrollbar's edge, with
    -- no gap and no overlap, regardless of the window's fixed dimensions.
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
        row:RegisterForClicks("RightButtonUp");

        -- Flat translucent overlay (same flat-texture approach as the rest of
        -- the theme, see Theme.lua's CHROME_TEXTURE comment) rather than a
        -- stock Blizzard highlight art asset. Button's built-in highlight
        -- layer shows/hides it automatically on mouseover/mouseout.
        local rowHighlight = row:CreateTexture(nil, "HIGHLIGHT");
        rowHighlight:SetAllPoints(row);
        rowHighlight:SetColorTexture(1, 1, 1, 0.08);
        row:SetHighlightTexture(rowHighlight);

        -- Indented off row's own left edge (rather than flush with it) so the
        -- row highlight - which spans the full row - visibly extends a bit
        -- left of the roller's name instead of stopping right at it.
        row.text = row:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.highlightSmall);
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 4, 0);
        row.text:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT");
        row.text:SetJustifyH("LEFT");

        row:SetScript("OnClick", function(self)
            local RollOff = RollTracker.CurrentRollOff;
            if (not self.rollData or not RollOff) then return; end

            -- Only the player who started this roll-off may award it.
            if (not RollOff.initiatorIsMe) then
                print("|cff8865ffZerpyLoot|r Only the player who started this roll-off can award it.");
                return;
            end

            StaticPopup_Show("ZERPYLOOT_AWARD_CONFIRM", RollOff.item, self.rollData.player, { player = self.rollData.player, rollData = self.rollData });
        end);

        row:Hide();
        rows[i] = row;
    end

    local _, resizeEnabledFn = ZL.Theme.MakeBottomResizable(frame, WINDOW_WIDTH, minHeight, MAX_HEIGHT, function(height)
        ZL.Settings.SetRollWindowHeight(height);
    end);
    setResizeEnabled = resizeEnabledFn;

    frame:SetScript("OnUpdate", function()
        RollWindow.updateCountdown();
        RollWindow.updateHeightAnimation();
    end);
end

-- Animates the window growing from its current height to targetHeight (used
-- when a pending roll-off - shrunk to compactHeight while the Start Roll
-- prompt was showing - actually starts) rather than snapping straight to it.
local function animateGrowTo(targetHeight)
    -- Explicitly re-pin the window's top-left corner to its current
    -- on-screen position (rather than trusting whatever anchor it already
    -- has) before growing, so the bottom edge is the only thing that moves
    -- as height increases - the window grows straight down, never up or
    -- from the middle.
    local left, top = frame:GetLeft(), frame:GetTop();
    if (left and top) then
        frame:ClearAllPoints();
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, top - UIParent:GetHeight());
    end

    heightAnim = {
        startHeight = frame:GetHeight(),
        targetHeight = targetHeight,
        startTime = GetTime(),
    };
end

function RollWindow.updateHeightAnimation()
    if (not heightAnim) then return; end

    local t = math.min(1, (GetTime() - heightAnim.startTime) / GROW_ANIMATION_DURATION);
    local eased = 1 - (1 - t) ^ 3; -- ease-out cubic
    local height = heightAnim.startHeight + (heightAnim.targetHeight - heightAnim.startHeight) * eased;
    ZL.Pixel.SetHeight(frame, height);

    if (t >= 1) then
        heightAnim = nil;
    end
end

function RollWindow.updateCountdown()
    local RollOff = RollTracker.CurrentRollOff;
    if (not frame or not frame:IsShown() or not RollOff) then return; end

    if (not RollOff.active) then
        -- Bar/buttons' shown/disabled state and grey color are handled once,
        -- in Refresh (called right when RollTracker flips this to false) -
        -- not here, since this runs every OnUpdate frame and would otherwise
        -- repeatedly stomp the bar's hover color right back to grey.
        countdownText:SetText("|cffff4444Rolling stopped|r");
        return;
    end

    -- The bar is driven by the exact (unfloored) time remaining, ticking down
    -- every OnUpdate frame, so it glides smoothly instead of visibly jumping
    -- once a second the way the whole-number text below it does.
    local exactRemaining = math.max(0, RollOff.time - (GetTime() - RollOff.startedAt));
    countdownText:SetText(("%d seconds left"):format(math.floor(exactRemaining)));
    countdownBar:SetMinMaxValues(0, RollOff.time);
    countdownBar:SetValue(exactRemaining);
end

-- SR rolls (MS or OS alike) rank above every non-SR roll, then MS, then OS.
local function sortTier(classification, isSR)
    if (isSR) then return 1; end
    if (classification == "MS") then return 2; end
    return 3;
end

-- Every individual roll gets its own row (no grouping by player). Sorted by
-- tier first (MS+SR, then MS, then everything else/OS), and by amount within
-- a tier - repeated rolls by the same player simply show as repeated rows.
-- Each roll is tagged with its 1-based ordinal among that player's rolls this
-- roll-off (x1, x2, x3...), computed from the chronological order rolls
-- actually came in (RollOff.Rolls is append-only) before the display order
-- gets sorted.
local function buildRows()
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff) then return {}; end

    local result = {};
    local countsByPlayer = {};
    for _, roll in ipairs(RollOff.Rolls) do
        countsByPlayer[roll.player] = (countsByPlayer[roll.player] or 0) + 1;
        roll.rollNumber = countsByPlayer[roll.player];
        roll.isSR = ZL.SoftRes ~= nil and ZL.SoftRes.PlayerHasReservedItem(roll.player, RollOff.itemID);
        table.insert(result, roll);
    end

    table.sort(result, function(a, b)
        local tierA, tierB = sortTier(a.classification, a.isSR), sortTier(b.classification, b.isSR);
        if (tierA ~= tierB) then return tierA < tierB; end
        return (a.amount or 0) > (b.amount or 0);
    end);

    return result;
end

-- "Awarded to: <name> for <roll> [SR/MS/OS]" - SR takes priority over the
-- MS/OS classification, same tiering buildRows uses to sort the roll list.
local function awardedLabel(RollOff)
    local name = Util.classColoredName(RollOff.awardedTo, RollOff.awardedClass);
    local tag = RollOff.awardedIsSR and "SR" or tostring(RollOff.awardedClassification or "OS");
    return ("|cff33ff33Awarded to: %s for %d [%s]|r"):format(name, RollOff.awardedAmount or 0, tag);
end

function RollWindow.Refresh()
    if (not frame) then return; end

    local RollOff = RollTracker.CurrentRollOff;

    -- Pop the whole window's border orange for as long as a roll-off is
    -- actively up for an item we soft-reserved (see the louder sound in
    -- RollTracker.applyStart) - reverts to the normal border the moment it
    -- stops or there's no roll-off at all.
    ZL.Theme.SetWindowBorderColor(frame, (RollOff and RollOff.active and RollOff.isSelfSR) and ZL.Theme.colors.warning or nil);

    -- A real roll-off (ours or someone else's) always supersedes a pending,
    -- not-yet-broadcast one.
    if (RollOff) then
        pendingItemLink = nil;
    end

    if (not RollOff) then
        for _, row in pairs(rows) do
            row.rollData = nil;
            row:Hide();
        end
        scrollChild:SetHeight(1);

        countdownBar:SetMinMaxValues(0, 1);
        countdownBar:SetValue(0);
        countdownBar:Hide();
        countdownBarBorder:Hide();
        msButton:Hide();
        osButton:Hide();

        if (pendingItemLink) then
            itemIcon:SetTexture(select(10, GetItemInfo(pendingItemLink)) or FALLBACK_ICON);
            itemText:SetText(pendingItemLink);
            countdownText:SetText("");
            awardedText:SetText("");
            secondsBox:SetText(tostring(ZL.Settings.GetRollOffSeconds() or DEFAULT_TIMER));
            startRow:Show();
            -- Shrink down to just fit the prompt - cancels any leftover
            -- grow animation from a previous roll-off, so alt+clicking a
            -- new item right after one wraps up doesn't fight it.
            heightAnim = nil;
            ZL.Pixel.SetHeight(frame, compactHeight);
            -- compactHeight sits below minHeight on purpose - disable the
            -- resize handle so grabbing it can't snap the window straight up
            -- to minHeight the instant a drag starts (see setResizeEnabled).
            setResizeEnabled(false);
        else
            itemIcon:SetTexture(nil);
            itemText:SetText("");
            countdownText:SetText("");
            awardedText:SetText("");
            startRow:Hide();
            setResizeEnabled(true);
        end
        return;
    end

    startRow:Hide();
    setResizeEnabled(true);

    -- Outside the Start Roll prompt, the window always belongs at the saved
    -- height (or the default) - never at minHeight, and never left stuck at
    -- compactHeight (e.g. from closing the prompt via the X, which clears
    -- pendingItemLink without restoring the height). Animate there only if
    -- this roll-off is the local player's own (they just pressed Start
    -- Roll) - otherwise (someone else's roll-off) it should already be at
    -- that height the moment it appears.
    local targetHeight = math.max(ZL.Settings.GetRollWindowHeight() or DEFAULT_HEIGHT, minHeight);
    if (frame:GetHeight() ~= targetHeight) then
        if (RollOff.initiatorIsMe) then
            animateGrowTo(targetHeight);
        else
            heightAnim = nil;
            ZL.Pixel.SetHeight(frame, targetHeight);
        end
    end

    -- Shown/enabled state changes exactly once here, right when RollOff.active
    -- actually flips (this runs on both the initial start and RollTracker's
    -- stop) - not every OnUpdate frame, which would otherwise fight the bar's
    -- own hover-color script.
    countdownBar:Show();
    countdownBarBorder:Show();
    msButton:Show();
    osButton:Show();
    if (RollOff.active) then
        countdownBar:SetStatusBarColor(unpack(ZL.Theme.colors.accent));
        msButton:Enable();
        osButton:Enable();
    else
        -- Leave the bar's min/max/value exactly where the last active tick
        -- left them - just grey it out, rather than resetting it, so it
        -- reads as "stopped here" instead of snapping back to empty.
        countdownBar:SetStatusBarColor(unpack(COUNTDOWN_BAR_STOPPED_COLOR));
        msButton:Disable();
        osButton:Disable();
    end

    itemIcon:SetTexture(RollOff.itemIcon or FALLBACK_ICON);
    -- RollOff.item is the full item link (rarity color codes baked in by the
    -- client) and is always set whenever RollOff exists - prefer it over the
    -- plain itemName from GetItemInfo so the name shows its rarity color.
    itemText:SetText(RollOff.item or RollOff.itemName or "");
    if (RollOff.initiatorIsMe) then
        awardedText:SetText(RollOff.awardedTo and awardedLabel(RollOff) or "|cff888888Right-click a roll to award|r");
    else
        awardedText:SetText(RollOff.awardedTo and awardedLabel(RollOff) or "|cff888888See rolls down below|r");
    end

    local rollRows = buildRows();
    -- Scroll range (and so the auto-hide in Theme.SkinScrollBar) is driven by
    -- how tall scrollChild is relative to the visible scrollFrame, not by how
    -- many of the MAX_ROWS pooled rows exist - so this has to shrink to the
    -- actual row count instead of always spanning all MAX_ROWS worth.
    scrollChild:SetHeight(math.max(#rollRows * ROW_HEIGHT, 1));
    for i, row in pairs(rows) do
        local data = rollRows[i];
        if (data) then
            local name = Util.classColoredName(data.player, data.class);
            local srTag = data.isSR and "  |cff33ccff[SR]|r" or "";
            row.text:SetText(("%s  |cffffcc00%d|r  [%s]%s  |cff888888x%d|r"):format(
                name, data.amount or 0, tostring(data.classification), srTag, data.rollNumber or 1
            ));
            row.rollData = data;
            row:Show();
        else
            row.rollData = nil;
            row:Hide();
        end
    end
end

function RollWindow.Show()
    ensureFrame();
    frame:Show();
    RollWindow.Refresh();
end

-- Opens this window locally, pre-loaded with itemLink and a seconds box +
-- "Start Roll" button - only ever called on the client that alt+left-clicked
-- the item, so only that client ever sees those controls. A finished
-- roll-off (still sitting in RollTracker.CurrentRollOff so it can be awarded
-- late) is discarded here, so alt+clicking a new item after one wraps up
-- clears the window instead of leaving the old result on screen.
function RollWindow.ShowStartPrompt(itemLink)
    if (not itemLink) then return; end

    local RollOff = RollTracker.CurrentRollOff;
    if (RollOff and not RollOff.active) then
        RollTracker.CurrentRollOff = nil;
    end

    ensureFrame();
    pendingItemLink = itemLink;
    frame:Show();
    RollWindow.Refresh();
end

function RollWindow.Hide()
    pendingItemLink = nil;
    if (frame) then frame:Hide(); end
end

function RollWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then RollWindow.Hide(); else RollWindow.Show(); end
end

function RollWindow.ResetPosition()
    ZL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then ZL.Theme.ResetWindowPosition(frame); end
end
