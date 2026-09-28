--[[
Live roll-off tracker: item, timer, and the list of who is rolling, their
roll value(s), and how many times each has rolled. Built directly with the
settings window's own control vocabulary (UI.Colors/UI.Sizes.roll/
UI.SetFont/UI.Skin), not FL.Theme - this window has exactly one look, it
doesn't follow the active skin (same convention as RespondWindow/AwardWindow/
TradeQueueWindow/StartSessionWindow).

Also doubles as the "start a roll-off" prompt: alt+left-clicking a bag item
opens this same window (via ShowStartPrompt) showing just the item plus a
seconds box and a "Start Roll" button, before anything is broadcast. That
local-only pending state (pendingItemLink below) is never seen by anyone
else's client - nothing goes out over addon comm until Start Roll is
actually clicked.

All roll detection, Gargul communication, soft-reserve lookup, timer/stop
logic and the trade-queue hand-off live in RollTracker.lua/Comm.lua/
SoftRes.lua/Trade.lua and are untouched here - this file only ever reads
RollTracker.CurrentRollOff and calls RollTracker.StartRollOff/StopRollOff/
AwardItem. The roll-list sort/xN/isSR annotation lives in RollSession.lua
(non-UI).
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.roll;
local SharedLayout = FL.UI.Sizes.layout;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Util = FL.Util;
local RollTracker = FL.RollTracker;
local RollSession = FL.RollSession;
local RollWindow = FL.UI.RollWindow;

local FALLBACK_ICON = FL.LootCouncil.FALLBACK_ICON;
local DEFAULT_TIMER = 15;
local POSITION_KEY = "rollWindow";
local RIGHT_CLICK_ATLAS = "plunderstorm-pickup-mouseclick-right";
local DOT_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Dot";
local CROWN_TEXTURE = "Interface\\GroupFrame\\UI-Group-LeaderIcon";

--------------------------------------------------------------------------
-- Widgets, built once in ensureFrame() and repainted/repositioned by
-- Refresh() - see the old RollWindow.lua/AwardWindow.lua for the same
-- "forward-declared locals, assigned inside ensureFrame" shape.
--------------------------------------------------------------------------

local frame, closeButton;
local itemRow, headerIconButton, headerIconTex, headerIconBorder, headerNameText, headerTypeText;
local setupRow, setupLabel, setupBox, setupSuffix, setupButton;
local timerLabel, timerBar;
local msButton, osButton;
local hintRow, hintIcon, hintText;
local listBox, listEmptyText, listScrollFrame, listScrollChild, listScrollBar;
local rows = {};
local statusDivider, statusDot, statusMessageText;
local popup; -- Skin.ConfirmPopup controller, built lazily by ensurePopup()

-- "Unawarded rolls" guard popup - see the section above hideGuard() below.
-- guardPopup: Skin.ConfirmPopup controller, built lazily by ensureGuard().
-- guardItemLink: the newly alt-clicked item awaiting confirmation while the
-- guard is open - pure bookkeeping, never painted (the guard's own content
-- is always a function of RollTracker.CurrentRollOff, not of this - see
-- showGuard()). Distinct from pendingItemLink below, which Refresh() clears
-- the instant a real RollOff exists (i.e. for the entire time the guard can
-- be open), so it can't be reused for this.
local guardPopup;
local guardItemLink;
-- Forward-declared: ensureGuard() wires these into a one-time SetButtons()
-- call before their own `function goBack() ... end` definitions are reached
-- further down the file. Assign into them later with plain
-- `function goBack() ... end` (no `local`), not `local function goBack()`,
-- which would shadow this upvalue instead of filling it in.
local goBack, startWithoutAwarding;

-- Set only by ShowStartPrompt (i.e. only on the client that alt+left-clicked
-- the item) and cleared the moment a real RollTracker.CurrentRollOff shows up.
local pendingItemLink;

-- In-flight expand-animation state (see animateGrowTo/updateHeightAnimation) -
-- only the very first Setup -> Rolling transition animates; every later
-- height change is instant.
local heightAnim;

-- Timer-bar hover/label state, reset whenever a fresh rolling state begins.
local barHovered = false;
local lastLabelSeconds;

-- Tracks which roll-off we last saw actively rolling, and (once it stops)
-- whether that stop happened before its natural deadline - computed once,
-- the instant the transition is observed, from RollOff.startedAt/time vs
-- GetTime(), since RollTracker.LocalStop() runs identically whether the
-- timer simply expired or a StopRollOff() broadcast arrived early (see
-- RollTracker.lua) - there's no separate signal to read this off of.
local lastActiveRollOffId;
local stoppedEarly;

-- Snapshot of the roll-off id and row this popup was opened for, so
-- Refresh() can close it if a new roll-off supersedes the one it was
-- opened for while it's still up (mirrors AwardWindow's awardCountAtOpen
-- staleness guard).
local popupRollOffId, popupRollData;

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

--- Trims `text` (with a trailing "...") until `fontString` renders it at or
--- under `maxWidth`. Same technique every other window in this addon uses.
local function setTextEllipsized(fontString, text, maxWidth)
    fontString:SetText(text);
    if (fontString:GetStringWidth() <= maxWidth or text == "") then return; end
    while (fontString:GetStringWidth() > maxWidth and #text > 1) do
        text = text:sub(1, -2);
        fontString:SetText(text .. "...");
    end
end

local function colorHex(rgb)
    return ("%02x%02x%02x"):format(
        math.floor((rgb[1] or 1) * 255 + 0.5),
        math.floor((rgb[2] or 1) * 255 + 0.5),
        math.floor((rgb[3] or 1) * 255 + 0.5)
    );
end

local function ordinalSuffix(n)
    local mod100 = n % 100;
    if (mod100 >= 11 and mod100 <= 13) then return "th"; end
    local mod10 = n % 10;
    if (mod10 == 1) then return "st"; end
    if (mod10 == 2) then return "nd"; end
    if (mod10 == 3) then return "rd"; end
    return "th";
end

-- "A" / "A and B" / "A, B and C" - the award-another-copy note box's list of
-- already-awarded names.
local function joinNamesOxford(items)
    if (#items == 0) then return ""; end
    if (#items == 1) then return items[1]; end
    if (#items == 2) then return items[1] .. " and " .. items[2]; end
    return table.concat(items, ", ", 1, #items - 1) .. " and " .. items[#items];
end

-- "A" / "A, B" - the reassign status line's list of replaced winners. Plain
-- comma join (not Oxford) to match the task's own "(replaced A, B)" wording.
local function joinNamesComma(entries)
    local names = {};
    for _, e in ipairs(entries) do
        table.insert(names, Util.classColoredName(e.name, e.class));
    end
    return table.concat(names, ", ");
end

local function currentItemLink()
    local RollOff = RollTracker.CurrentRollOff;
    return (RollOff and RollOff.item) or pendingItemLink;
end

local function statusColor(kind)
    if (kind == "error") then return Colors.sessionDeleteHoverIcon; end
    if (kind == "working") then return Colors.gold; end
    if (kind == "success") then return Colors.respondSentLabel; end
    return Colors.description; -- info
end

--------------------------------------------------------------------------
-- Start Roll (Setup state)
--------------------------------------------------------------------------

local function startRoll()
    if (not pendingItemLink) then return; end
    local seconds = tonumber(setupBox:GetText()) or DEFAULT_TIMER;
    FL.Settings.SetRollOffSeconds(seconds);
    RollTracker.StartRollOff(pendingItemLink, seconds);
end

--------------------------------------------------------------------------
-- Expand animation / countdown OnUpdate - see the file header on why only
-- the first Setup -> Rolling transition animates.
--------------------------------------------------------------------------

local function animateGrowTo(targetHeight)
    -- Re-pin the window's top-left corner to its current on-screen position
    -- before growing, so the bottom edge is the only thing that moves as
    -- height increases - the window grows straight down, never up or from
    -- the middle.
    local left, top = frame:GetLeft(), frame:GetTop();
    if (left and top) then
        frame:ClearAllPoints();
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, top - UIParent:GetHeight());
    end

    heightAnim = { startHeight = frame:GetHeight(), targetHeight = targetHeight, startTime = GetTime() };
end

local function updateHeightAnimation()
    if (not heightAnim) then return; end

    local t = math.min(1, (GetTime() - heightAnim.startTime) / Sizes.expandDuration);
    local eased = 1 - (1 - t) ^ 3; -- ease-out cubic
    local height = heightAnim.startHeight + (heightAnim.targetHeight - heightAnim.startHeight) * eased;
    Pixel.SetHeight(frame, height);

    if (t >= 1) then heightAnim = nil; end
end

local function updateCountdown()
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not RollOff.active) then return; end

    local exactRemaining = math.max(0, RollOff.time - (GetTime() - RollOff.startedAt));
    timerBar:SetProgress(exactRemaining, RollOff.time);
    timerBar:UpdateSheen(GetTime());

    if (not barHovered) then
        local seconds = math.max(math.ceil(exactRemaining), 1);
        if (seconds ~= lastLabelSeconds) then
            lastLabelSeconds = seconds;
            timerLabel:SetTextColor(unpack(Colors.text));
            timerLabel:SetText(seconds == 1 and "1 second left" or (seconds .. " seconds left"));
        end
    end
end

--------------------------------------------------------------------------
-- Unawarded-rolls guard: the check, and the shared "discard and reload"
-- reset path used both when no guard is needed and when the user explicitly
-- confirms "Start Without Awarding" (see the guard popup section below).
--------------------------------------------------------------------------

--- True only when loading a new item right now would silently discard rolls
--- nobody's been awarded: a real roll-off exists (Setup phase has none), at
--- least one roll came in, and no winner has been recorded yet. Award,
--- Award Copy and Reassign all populate RollOff.winners, so any of them
--- make this false.
local function hasUnawardedRolls()
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff) then return false; end
    if (#RollOff.Rolls == 0) then return false; end
    if (RollOff.winners and #RollOff.winners > 0) then return false; end
    return true;
end

--- Unconditionally discards whatever roll-off is currently tracked (active
--- or not - unlike the old ShowStartPrompt's conditional discard, this must
--- also work while a roll is still actively running, since "Start Without
--- Awarding" can be clicked mid-roll) and re-opens the window in Setup
--- phase for itemLink, keeping the last timer value the user typed.
local function startFresh(itemLink)
    RollTracker.CurrentRollOff = nil;
    pendingItemLink = itemLink;
    setupBox:SetText(tostring(FL.Settings.GetRollOffSeconds() or DEFAULT_TIMER));
    RollWindow.Refresh();
end

--------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootRollWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    -- Reveals the rolling-state sections from the top down as the bottom
    -- edge slides during the expand animation - the one window in this
    -- addon that needs this (every other window's content is either fixed
    -- or already fits, so none of them clip children).
    frame:SetClipsChildren(true);
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    Pixel.RegisterWindow(frame, {
        width = Sizes.window.width, height = Sizes.titleBarHeight + Sizes.padding * 2 + Sizes.header.iconSize,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    -- Title bar
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
    title:SetTextColor(unpack(Colors.titlePurple));
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0);
    title:SetText("ForeverLoot - Roll");

    local divider = titleBar:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0);
    divider:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0);
    divider:SetHeight(Pixel.PixelSize(1));

    closeButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    closeButton:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -8, -8);
    Skin.CloseButton(closeButton);
    closeButton:SetScript("OnClick", function()
        FL.NotifyWindowClosed("Roll");
        RollWindow.Hide();
    end);

    --------------------------------------------------------------------
    -- Item header (every state)
    --------------------------------------------------------------------

    -- Horizontal position/width is fixed across every state (the header
    -- always sits right below the title bar, full content width) - anchored
    -- here, once, rather than in the layout functions below, so
    -- headerNameText already has a valid width (needed for its ellipsis
    -- truncation) the first time paintHeader runs, before any layout pass
    -- has executed. Height is dynamic (the name/type text column can wrap
    -- taller than the icon) - the layout functions below set it each pass,
    -- once the real text is known.
    itemRow = CreateFrame("Frame", nil, frame);
    itemRow:SetHeight(Sizes.header.iconSize);
    itemRow:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.padding, -(Sizes.titleBarHeight + Sizes.padding));
    itemRow:SetPoint("RIGHT", frame, "RIGHT", -Sizes.padding, 0);

    headerIconButton = CreateFrame("Button", nil, itemRow);
    headerIconButton:SetSize(Sizes.header.iconSize, Sizes.header.iconSize);
    headerIconButton:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 0, 0);
    headerIconButton:RegisterForClicks("LeftButtonUp");
    headerIconButton:SetScript("OnClick", function() Util.HandleItemLinkClick(currentItemLink()); end);
    headerIconButton:SetScript("OnEnter", function()
        local link = currentItemLink();
        if (not link) then return; end
        GameTooltip:SetOwner(headerIconButton, "ANCHOR_RIGHT");
        GameTooltip:SetHyperlink(link);
        GameTooltip:Show();
    end);
    headerIconButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    headerIconTex = headerIconButton:CreateTexture(nil, "ARTWORK");
    headerIconTex:SetAllPoints(headerIconButton);
    headerIconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    headerIconBorder = CreateFrame("Frame", nil, itemRow, "BackdropTemplate");
    headerIconBorder:SetPoint("TOPLEFT", headerIconButton, "TOPLEFT", -1, 1);
    headerIconBorder:SetPoint("BOTTOMRIGHT", headerIconButton, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(headerIconBorder, nil, Colors.transparent, 1);

    headerNameText = itemRow:CreateFontString(nil, "OVERLAY");
    SetFont(headerNameText, "sectionHeader");
    headerNameText:SetPoint("TOPLEFT", headerIconButton, "TOPRIGHT", Sizes.header.iconGap, 0);
    headerNameText:SetPoint("RIGHT", itemRow, "RIGHT", 0, 0);
    headerNameText:SetJustifyH("LEFT");
    headerNameText:SetWordWrap(false);

    headerTypeText = itemRow:CreateFontString(nil, "OVERLAY");
    SetFont(headerTypeText, "small");
    headerTypeText:SetTextColor(unpack(Colors.muted));
    headerTypeText:SetPoint("TOPLEFT", headerNameText, "BOTTOMLEFT", 0, -Sizes.header.nameTypeGap);
    headerTypeText:SetPoint("RIGHT", itemRow, "RIGHT", 0, 0);
    headerTypeText:SetJustifyH("LEFT");
    headerTypeText:SetWordWrap(false);

    --------------------------------------------------------------------
    -- Setup row (State A)
    --------------------------------------------------------------------

    setupRow = CreateFrame("Frame", nil, frame);
    setupRow:SetHeight(Sizes.setup.rowHeight);

    setupLabel = setupRow:CreateFontString(nil, "OVERLAY");
    SetFont(setupLabel, "body");
    setupLabel:SetTextColor(unpack(Colors.description));
    setupLabel:SetPoint("LEFT", setupRow, "LEFT", 0, 0);
    setupLabel:SetText("Roll timer");

    setupBox = CreateFrame("EditBox", nil, setupRow, "BackdropTemplate");
    setupBox:SetSize(Sizes.setup.boxWidth, Sizes.setup.boxHeight);
    setupBox:SetPoint("LEFT", setupLabel, "RIGHT", Sizes.setup.boxGap, 0);
    Theme.Helpers.SetFlatBackdrop(setupBox, Colors.controlBg, Colors.controlBorder, 1);
    setupBox:SetAutoFocus(false);
    setupBox:SetNumeric(true);
    setupBox:SetMaxLetters(3);
    setupBox:SetJustifyH("CENTER");
    SetFont(setupBox, "body");
    setupBox:SetTextColor(unpack(Colors.textBright));
    setupBox:SetTextInsets(0, 0, 0, 0);
    setupBox:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(unpack(Colors.controlFocus)); end);
    setupBox:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(Colors.controlBorder)); end);
    setupBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); startRoll(); end);
    setupBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);

    setupSuffix = setupRow:CreateFontString(nil, "OVERLAY");
    SetFont(setupSuffix, "body");
    setupSuffix:SetTextColor(unpack(Colors.muted));
    setupSuffix:SetPoint("LEFT", setupBox, "RIGHT", Sizes.setup.secGap, 0);
    setupSuffix:SetText("sec");

    setupButton = CreateFrame("Button", nil, setupRow, "BackdropTemplate");
    setupButton:SetHeight(Sizes.setup.rowHeight);
    setupButton:SetPoint("LEFT", setupSuffix, "RIGHT", Sizes.setup.buttonGap, 0);
    setupButton:SetPoint("RIGHT", setupRow, "RIGHT", 0, 0);
    Skin.Button(setupButton, "primary");
    setupButton.text:SetText("Start Roll");
    setupButton:SetScript("OnClick", startRoll);

    --------------------------------------------------------------------
    -- Timer (State B/C/D)
    --------------------------------------------------------------------

    timerLabel = frame:CreateFontString(nil, "OVERLAY");
    SetFont(timerLabel, "body");
    timerLabel:SetTextColor(unpack(Colors.text));
    timerLabel:SetJustifyH("CENTER");
    timerLabel:SetPoint("TOP", frame, "TOP", 0, 0); -- re-anchored per refresh via ClearAllPoints below

    timerBar = Skin.TimerBar(frame, {
        height = Sizes.timer.barHeight,
        variants = {
            running = { from = Colors.controlFocus, to = Colors.gold },
            hover = { from = Colors.rollHoverFillStart, to = Colors.rollHoverFillEnd },
        },
    });
    timerBar.track:EnableMouse(true);
    timerBar.track:SetScript("OnEnter", function()
        local RollOff = RollTracker.CurrentRollOff;
        if (RollOff and RollOff.active and RollOff.initiatorIsMe) then
            barHovered = true;
            timerBar:SetVariant("hover");
            timerLabel:SetTextColor(unpack(Colors.sessionDeleteHoverIcon));
            timerLabel:SetText("Click to stop rolling");
        end
    end);
    timerBar.track:SetScript("OnLeave", function()
        barHovered = false;
        local RollOff = RollTracker.CurrentRollOff;
        if (RollOff and RollOff.active) then
            timerBar:SetVariant("running");
            lastLabelSeconds = nil;
            updateCountdown();
        end
    end);
    timerBar.track:SetScript("OnMouseUp", function()
        local RollOff = RollTracker.CurrentRollOff;
        if (RollOff and RollOff.active and RollOff.initiatorIsMe) then
            RollTracker.StopRollOff();
        end
    end);

    --------------------------------------------------------------------
    -- MS / OS roll buttons
    --------------------------------------------------------------------

    local function createRollButton(mainLabel, subLabel, onClick)
        local btn = CreateFrame("Button", nil, frame, "BackdropTemplate");
        btn:SetHeight(Sizes.rollButtons.height);
        Skin.Button(btn, "default");
        SetFont(btn.text, "sectionHeader");
        btn.text:SetTextColor(unpack(Colors.textBright));
        btn.text:SetText(mainLabel);

        btn.subText = btn:CreateFontString(nil, "OVERLAY");
        SetFont(btn.subText, "small");
        btn.subText:SetTextColor(unpack(Colors.muted));
        btn.subText:SetText(subLabel);

        -- Skin.Button's own hover/press hooks re-center btn.text at (0,0)/
        -- (0,-1) - hooked again here (hooks run in registration order, so
        -- this runs AFTER Skin.Button's) to keep the two-line layout intact
        -- through every state it manages.
        local function layoutText(pressedOffset)
            btn.text:ClearAllPoints();
            btn.text:SetPoint("CENTER", 0, 7 + pressedOffset);
            btn.subText:ClearAllPoints();
            btn.subText:SetPoint("TOP", btn.text, "BOTTOM", 0, -2);
        end
        layoutText(0);
        btn:HookScript("OnMouseDown", function() layoutText(-1); end);
        btn:HookScript("OnMouseUp", function() layoutText(0); end);
        btn:HookScript("OnLeave", function() layoutText(0); end);

        btn:SetScript("OnClick", onClick);
        return btn;
    end

    msButton = createRollButton("MS", "/roll 100", function() RandomRoll(1, 100); end);
    osButton = createRollButton("OS", "/roll 99", function() RandomRoll(1, 99); end);

    --------------------------------------------------------------------
    -- Hint row
    --------------------------------------------------------------------

    hintRow = CreateFrame("Frame", nil, frame);
    hintRow:SetHeight(Sizes.hint.height);

    hintIcon = hintRow:CreateTexture(nil, "ARTWORK");
    hintIcon:SetHeight(Sizes.hint.height);
    hintIcon:SetPoint("LEFT", hintRow, "LEFT", 0, 0);

    hintText = hintRow:CreateFontString(nil, "OVERLAY");
    SetFont(hintText, "small");
    hintText:SetJustifyH("LEFT");

    --------------------------------------------------------------------
    -- Roll list
    --------------------------------------------------------------------

    listBox = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(listBox, Colors.sessionListBg, Colors.memberBorder, 1);
    -- Horizontal position/width is fixed (same reasoning as itemRow above) -
    -- anchored here so the listScrollFrame -> listScrollChild -> row width
    -- chain (needed by paintRows' own ellipsis truncation) already resolves
    -- correctly the first time paintRows runs, before layoutActive has ever
    -- repositioned listBox itself. The Y offset here is a placeholder;
    -- layoutActive re-anchors TOPLEFT/TOPRIGHT with the real one every pass.
    listBox:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.padding, 0);
    listBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.padding, 0);
    listBox:SetHeight(Sizes.list.emptyHeight);

    listEmptyText = listBox:CreateFontString(nil, "OVERLAY");
    SetFont(listEmptyText, "small");
    listEmptyText:SetTextColor(unpack(Colors.controlHover));
    listEmptyText:SetPoint("CENTER", listBox, "CENTER", 0, 0);
    listEmptyText:SetText("No rolls yet");

    listScrollFrame = CreateFrame("ScrollFrame", nil, listBox, "UIPanelScrollFrameTemplate");
    listScrollFrame:SetPoint("TOPLEFT", listBox, "TOPLEFT", Sizes.list.padding, -Sizes.list.padding);
    listScrollFrame:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -Sizes.list.padding, Sizes.list.padding);
    listScrollFrame:EnableMouse(true);

    listScrollChild = CreateFrame("Frame", nil, listScrollFrame);
    listScrollChild:SetPoint("TOPLEFT", listScrollFrame, "TOPLEFT", 0, 0);
    listScrollFrame:SetScrollChild(listScrollChild);

    listScrollBar = Skin.ScrollBar(listScrollFrame);
    if (listScrollBar) then
        listScrollBar:ClearAllPoints();
        listScrollBar:SetPoint("TOP", listScrollFrame, "TOP", 0, 0);
        listScrollBar:SetPoint("BOTTOM", listScrollFrame, "BOTTOM", 0, 0);
        listScrollBar:SetPoint("RIGHT", listBox, "RIGHT", -3, 0);
    end

    -- listScrollChild (and so every row's own width, via
    -- row:SetPoint("RIGHT", listScrollChild, "RIGHT")) matches listScrollFrame's
    -- own width minus the scrollbar's footprint, but only while that
    -- scrollbar is actually shown - same pattern as AwardWindow's
    -- updateRightScrollChildWidth/TradeQueueWindow's equivalent - so rows
    -- never end up padded for a scrollbar that isn't there, and never sit
    -- under one that is.
    local function updateListScrollChildWidth()
        local width = listScrollFrame:GetWidth();
        if (listScrollBar and listScrollBar:IsShown()) then
            width = width - (SharedLayout.scrollbarWidth + SharedLayout.scrollbarInset);
        end
        listScrollChild:SetWidth(math.max(width, 1));
    end
    listScrollFrame:SetScript("OnSizeChanged", updateListScrollChildWidth);
    updateListScrollChildWidth(); -- seed it now rather than waiting on the first OnSizeChanged
    -- Re-run after Skin.ScrollBar's own OnScrollRangeChanged hook (registered
    -- when Skin.ScrollBar(listScrollFrame) ran above) has already shown/hidden
    -- the bar for this range change, so :IsShown() here reflects that.
    listScrollFrame:HookScript("OnScrollRangeChanged", updateListScrollChildWidth);

    Theme.Helpers.EnableSmoothScroll(listScrollFrame, { step = Sizes.list.rowHeight + Sizes.list.rowGap });

    --------------------------------------------------------------------
    -- Status line
    --------------------------------------------------------------------

    statusDivider = frame:CreateTexture(nil, "ARTWORK");
    statusDivider:SetColorTexture(unpack(Colors.divider));
    statusDivider:SetHeight(Pixel.PixelSize(1));

    statusDot = frame:CreateTexture(nil, "ARTWORK");
    statusDot:SetSize(Sizes.status.dotSize, Sizes.status.dotSize);
    statusDot:SetTexture(DOT_TEXTURE);

    statusMessageText = frame:CreateFontString(nil, "OVERLAY");
    SetFont(statusMessageText, "body");
    statusMessageText:SetJustifyH("LEFT");
    statusMessageText:SetWordWrap(true);

    frame:SetScript("OnUpdate", function()
        updateCountdown();
        updateHeightAnimation();
    end);
end

--------------------------------------------------------------------------
-- Award confirmation popup (starter only)
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
    local dialog = popup.dialog;

    dialog.summary = CreateFrame("Frame", nil, dialog, "BackdropTemplate");
    Skin.Backdrop(dialog.summary, Colors.sessionListBg, Colors.memberBorder);
    dialog.summary:SetHeight(p.summaryIconSize + p.summaryPadding * 2);

    dialog.summaryIcon = dialog.summary:CreateTexture(nil, "ARTWORK");
    dialog.summaryIcon:SetSize(p.summaryIconSize, p.summaryIconSize);
    dialog.summaryIcon:SetPoint("LEFT", dialog.summary, "LEFT", p.summaryPadding, 0);
    dialog.summaryIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92);
    dialog.summaryIconBorder = CreateFrame("Frame", nil, dialog.summary, "BackdropTemplate");
    dialog.summaryIconBorder:SetPoint("TOPLEFT", dialog.summaryIcon, "TOPLEFT", -1, 1);
    dialog.summaryIconBorder:SetPoint("BOTTOMRIGHT", dialog.summaryIcon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(dialog.summaryIconBorder, nil, Colors.transparent, 1);

    dialog.summaryItemName = dialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.summaryItemName, "body");
    dialog.summaryItemName:SetPoint("TOPLEFT", dialog.summaryIcon, "TOPRIGHT", p.summaryIconGap, 0);
    dialog.summaryItemName:SetJustifyH("LEFT");
    dialog.summaryItemName:SetWordWrap(false);

    dialog.summaryToLine = dialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.summaryToLine, "small");
    dialog.summaryToLine:SetTextColor(unpack(Colors.muted));
    dialog.summaryToLine:SetText("to");
    dialog.summaryToLine:SetPoint("TOPLEFT", dialog.summaryItemName, "BOTTOMLEFT", 0, -p.summaryLineGap);
    dialog.summaryToLine:SetJustifyH("LEFT");
    dialog.summaryToLine:SetWordWrap(false);

    dialog.summaryName = dialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.summaryName, "body");
    dialog.summaryName:SetPoint("LEFT", dialog.summaryToLine, "RIGHT", 4, 0);
    dialog.summaryName:SetJustifyH("LEFT");

    dialog.summaryClassPill = CreateFrame("Frame", nil, dialog.summary);
    dialog.summaryClassPill:SetHeight(Sizes.pill.height);
    Skin.Pill(dialog.summaryClassPill);
    dialog.summaryClassPill.label = dialog.summaryClassPill:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.summaryClassPill.label, "small");
    dialog.summaryClassPill.label:SetPoint("CENTER");
    dialog.summaryClassPill.label:SetJustifyH("CENTER");
    dialog.summaryClassPill:SetPillFillColor(unpack(Colors.defaultBg));
    -- border/text color set per-open in showAwardPopup() below, from
    -- Colors.rollTags.MS/OS depending on the roll's classification.

    dialog.summarySRPill = CreateFrame("Frame", nil, dialog.summary);
    dialog.summarySRPill:SetHeight(Sizes.pill.height);
    Skin.Pill(dialog.summarySRPill);
    dialog.summarySRPill.label = dialog.summarySRPill:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.summarySRPill.label, "small");
    dialog.summarySRPill.label:SetText("SR");
    dialog.summarySRPill.label:SetPoint("CENTER");
    dialog.summarySRPill.label:SetJustifyH("CENTER");
    dialog.summarySRPill:SetPillColor(unpack(Colors.rollTags.SR.border));
    dialog.summarySRPill:SetPillFillColor(unpack(Colors.defaultBg));
    dialog.summarySRPill.label:SetTextColor(unpack(Colors.rollTags.SR.text));
    dialog.summarySRPill:SetWidth(Sizes.pill.padX * 2 + dialog.summarySRPill.label:GetStringWidth());

    dialog.summaryRollNumber = dialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.summaryRollNumber, "sectionHeader");
    dialog.summaryRollNumber:SetTextColor(unpack(Colors.gold));
    dialog.summaryRollNumber:SetJustifyH("RIGHT");

    dialog.summaryRollLabel = dialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.summaryRollLabel, "small");
    dialog.summaryRollLabel:SetTextColor(unpack(Colors.muted));
    dialog.summaryRollLabel:SetText("roll");
    dialog.summaryRollLabel:SetPoint("TOP", dialog.summaryRollNumber, "BOTTOM", 0, -2);
    dialog.summaryRollLabel:SetPoint("RIGHT", dialog.summaryRollNumber, "RIGHT", 0, 0);

    -- Shown once at least one winner already exists ("Award another copy?" /
    -- reassign). Always gold, never the old single-winner red warning - an
    -- additional copy isn't destructive, and even Reassign's own warning
    -- (that some winners already received the item) is folded into this same
    -- box's 3rd line rather than a separate red state.
    dialog.noteBox = CreateFrame("Frame", nil, dialog, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(dialog.noteBox, Colors.councilFill, Colors.selectedBorder, 1);

    local noteWidth = p.width - p.padding * 2 - p.warningPadding * 2;

    dialog.noteLine1 = dialog.noteBox:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.noteLine1, "small");
    dialog.noteLine1:SetPoint("TOPLEFT", dialog.noteBox, "TOPLEFT", p.warningPadding, -p.warningPadding);
    dialog.noteLine1:SetWidth(noteWidth);
    dialog.noteLine1:SetJustifyH("LEFT");
    dialog.noteLine1:SetWordWrap(true);

    dialog.noteLine2 = dialog.noteBox:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.noteLine2, "small");
    dialog.noteLine2:SetPoint("TOPLEFT", dialog.noteLine1, "BOTTOMLEFT", 0, -p.summaryLineGap);
    dialog.noteLine2:SetWidth(noteWidth);
    dialog.noteLine2:SetJustifyH("LEFT");
    dialog.noteLine2:SetWordWrap(true);

    dialog.noteLine3 = dialog.noteBox:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.noteLine3, "small");
    dialog.noteLine3:SetPoint("TOPLEFT", dialog.noteLine2, "BOTTOMLEFT", 0, -p.summaryLineGap);
    dialog.noteLine3:SetWidth(noteWidth);
    dialog.noteLine3:SetJustifyH("LEFT");
    dialog.noteLine3:SetWordWrap(true);

    popup.middleButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP");
        GameTooltip:AddLine("Take the item from the current winner(s) and give it to this player", 1, 1, 1, true);
        GameTooltip:Show();
    end);
    popup.middleButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);
end

local function hideAwardPopup()
    popupRollOffId = nil;
    popupRollData = nil;
    if (popup) then popup:Hide(); end
end

local function confirmAward()
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not popupRollData) then return; end
    local rollData = popupRollData;
    hideAwardPopup();
    -- AwardItem itself doesn't care whether the roll-off is still active,
    -- but the roll UI stops it first so an award always lands on a closed
    -- roll - StopRollOff is a broadcast; not waiting on its self-loopback
    -- before awarding just saves the confirm click a beat of latency. Used
    -- for both the first award AND an additional copy - the ordinal
    -- distinction lives entirely inside RollTracker.AwardItem.
    if (RollOff.active) then RollTracker.StopRollOff(); end
    RollTracker.AwardItem(rollData.player, rollData);
end

local function confirmReassign()
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not popupRollData) then return; end
    local rollData = popupRollData;
    hideAwardPopup();
    if (RollOff.active) then RollTracker.StopRollOff(); end
    RollTracker.ReassignItem(rollData.player, rollData);
end

local function showAwardPopup(rollData)
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff or not RollOff.initiatorIsMe) then return; end
    ensurePopup();

    popupRollOffId = RollOff.id;
    popupRollData = rollData;

    local p = Sizes.popup;
    local dialog = popup.dialog;
    local hasWinners = RollOff.winners and #RollOff.winners > 0;

    dialog.title:SetText(hasWinners and "Award another copy?" or "Award item?");
    -- onCancel is the window's own hideAwardPopup (not just popup:Hide())
    -- so Cancel/Escape/scrim-click also clear the staleness-guard snapshot -
    -- every onConfirm/onMiddle here already calls hideAwardPopup itself.
    if (hasWinners) then
        popup.cancelButton:SetWidth(p.buttonWidthNarrow);
        popup.middleButton:SetWidth(p.buttonWidthNarrow);
        popup.confirmButton:SetWidth(p.buttonWidthNarrow);
        popup:SetButtons("Cancel", "Award Copy", confirmAward, hideAwardPopup, "Reassign", confirmReassign);
    else
        popup.cancelButton:SetWidth(p.buttonWidth);
        popup.confirmButton:SetWidth(p.buttonWidth);
        popup:SetButtons("Cancel", "Award", confirmAward, hideAwardPopup);
    end

    -- Same nil-quality guard as paintHeader above - RollOff.itemQuality is
    -- only ever populated from this client's own item cache.
    local qr, qg, qb;
    if (RollOff.itemQuality) then
        qr, qg, qb = Util.GetItemQualityColor(RollOff.itemQuality);
    end
    dialog.summaryIcon:SetTexture(RollOff.itemIcon or FALLBACK_ICON);
    dialog.summaryIconBorder:SetBackdropBorderColor(qr or 0.6, qg or 0.6, qb or 0.6);
    dialog.summaryItemName:SetTextColor(qr or 1, qg or 1, qb or 1);
    setTextEllipsized(dialog.summaryItemName, RollOff.itemName or RollOff.item or "",
        p.width - p.summaryIconSize - p.summaryIconGap - p.summaryPadding * 2 - 60);

    dialog.summaryName:SetText(Util.classColoredName(rollData.player, rollData.class));

    local isMS = rollData.classification == "MS";
    local classColors = isMS and Colors.rollTags.MS or Colors.rollTags.OS;
    dialog.summaryClassPill.label:SetText(isMS and "MS" or "OS");
    dialog.summaryClassPill:SetPillColor(unpack(classColors.border));
    dialog.summaryClassPill.label:SetTextColor(unpack(classColors.text));
    dialog.summaryClassPill:SetWidth(Sizes.pill.padX * 2 + dialog.summaryClassPill.label:GetStringWidth());
    dialog.summaryClassPill:ClearAllPoints();
    dialog.summaryClassPill:SetPoint("LEFT", dialog.summaryName, "RIGHT", 6, 0);

    dialog.summarySRPill:SetShown(rollData.isSR and true or false);
    dialog.summarySRPill:ClearAllPoints();
    dialog.summarySRPill:SetPoint("LEFT", dialog.summaryClassPill, "RIGHT", 3, 0);

    dialog.summaryRollNumber:SetText(tostring(rollData.amount or 0));

    local showBagWarning = false;
    if (hasWinners) then
        local names = {};
        for _, w in ipairs(RollOff.winners) do
            table.insert(names, Util.classColoredName(w.name, w.class));
        end

        dialog.noteLine1:SetTextColor(unpack(Colors.text));
        dialog.noteLine1:SetText(("Already awarded to %s. This gives out another copy \226\128\148 everyone keeps theirs.")
            :format(joinNamesOxford(names)));

        dialog.noteLine2:SetTextColor(unpack(Colors.muted));
        dialog.noteLine2:SetText("Use Reassign to replace them instead.");

        local itemID = RollOff.itemID;
        local bagCount = itemID and FL.Trade.CountTradeableInBags(itemID) or 0;
        local queuedCount = itemID and FL.Trade.CountQueuedForItem(itemID) or 0;
        showBagWarning = itemID ~= nil and bagCount <= queuedCount;
        dialog.noteLine3:SetShown(showBagWarning);
        if (showBagWarning) then
            dialog.noteLine3:SetTextColor(unpack(Colors.sessionDeleteHoverIcon));
            dialog.noteLine3:SetText(("You only have %d in your bags \226\128\148 the extra trade will fail until you have another copy.")
                :format(bagCount));
        end
    end

    popup:Show(function(dlg, y)
        local secondLineHeight = math.max(dialog.summaryToLine:GetStringHeight(), Sizes.pill.height);
        local textColumnHeight = dialog.summaryItemName:GetStringHeight() + p.summaryLineGap + secondLineHeight;
        local summaryHeight = math.max(p.summaryIconSize, textColumnHeight) + p.summaryPadding * 2;
        dialog.summary:SetHeight(summaryHeight);
        dialog.summary:ClearAllPoints();
        dialog.summary:SetPoint("TOPLEFT", dlg, "TOPLEFT", p.padding, y);
        dialog.summary:SetPoint("TOPRIGHT", dlg, "TOPRIGHT", -p.padding, y);
        y = y - summaryHeight - p.sectionGap;

        local rollBlockHeight = dialog.summaryRollNumber:GetStringHeight() + 2 + dialog.summaryRollLabel:GetStringHeight();
        dialog.summaryRollNumber:ClearAllPoints();
        dialog.summaryRollNumber:SetPoint("TOPRIGHT", dialog.summary, "TOPRIGHT",
            -p.summaryPadding, -(summaryHeight - rollBlockHeight) / 2);

        if (hasWinners) then
            dialog.noteBox:ClearAllPoints();
            dialog.noteBox:SetPoint("TOPLEFT", dlg, "TOPLEFT", p.padding, y);
            dialog.noteBox:SetPoint("TOPRIGHT", dlg, "TOPRIGHT", -p.padding, y);
            local textHeight = dialog.noteLine1:GetStringHeight() + p.summaryLineGap + dialog.noteLine2:GetStringHeight();
            if (showBagWarning) then
                textHeight = textHeight + p.summaryLineGap + dialog.noteLine3:GetStringHeight();
            end
            dialog.noteBox:SetHeight(textHeight + p.warningPadding * 2);
            dialog.noteBox:Show();
            y = y - dialog.noteBox:GetHeight() - p.sectionGap;
        else
            dialog.noteBox:Hide();
        end

        return y;
    end);
end

--------------------------------------------------------------------------
-- "Unawarded rolls" guard popup - opened from ShowStartPrompt() when
-- loading a new item would silently discard rolls nobody's been awarded
-- yet. A second, independent Skin.ConfirmPopup instance (see ensurePopup()
-- above for the sibling pattern). Its content is always painted from
-- RollTracker.CurrentRollOff, never from the newly-requested item - see
-- the module-level comment on guardItemLink.
--------------------------------------------------------------------------

local function ensureGuard()
    if (guardPopup) then return; end
    local g = Sizes.guard;

    guardPopup = Skin.ConfirmPopup(frame, {
        width = g.width,
        padding = g.padding,
        titleHeight = g.titleHeight,
        sectionGap = g.sectionGap,
        buttonHeight = g.buttonHeight,
        buttonGap = g.buttonGap,
        shadowInset = g.shadowInset,
        scrimTopInset = Sizes.titleBarHeight,
    });
    local dialog = guardPopup.dialog;

    -- Title never varies ("Nobody has been awarded yet") - set once, unlike
    -- the Award popup's own state-dependent title.
    SetFont(dialog.title, "sectionHeader"); -- override ConfirmPopup's default windowTitle role
    dialog.title:SetText("Nobody has been awarded yet");

    --------------------------------------------------------------------
    -- Item box: icon + 2-line text column (name, roll summary)
    --------------------------------------------------------------------

    dialog.guardItemBox = CreateFrame("Frame", nil, dialog, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(dialog.guardItemBox, Colors.sessionListBg, Colors.memberBorder, 1);

    dialog.guardIcon = dialog.guardItemBox:CreateTexture(nil, "ARTWORK");
    dialog.guardIcon:SetSize(g.iconSize, g.iconSize);
    dialog.guardIcon:SetPoint("LEFT", dialog.guardItemBox, "LEFT", g.itemBoxPadding, 0);
    dialog.guardIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    dialog.guardIconBorder = CreateFrame("Frame", nil, dialog.guardItemBox, "BackdropTemplate");
    dialog.guardIconBorder:SetPoint("TOPLEFT", dialog.guardIcon, "TOPLEFT", -1, 1);
    dialog.guardIconBorder:SetPoint("BOTTOMRIGHT", dialog.guardIcon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(dialog.guardIconBorder, nil, Colors.transparent, 1);

    dialog.guardItemName = dialog.guardItemBox:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.guardItemName, "body");
    dialog.guardItemName:SetPoint("TOPLEFT", dialog.guardIcon, "TOPRIGHT", g.iconTextGap, 0);
    dialog.guardItemName:SetJustifyH("LEFT");
    dialog.guardItemName:SetWordWrap(false);

    dialog.guardSummary = dialog.guardItemBox:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.guardSummary, "small");
    dialog.guardSummary:SetTextColor(unpack(Colors.description));
    dialog.guardSummary:SetPoint("TOPLEFT", dialog.guardItemName, "BOTTOMLEFT", 0, -g.lineGap);
    dialog.guardSummary:SetJustifyH("LEFT");
    dialog.guardSummary:SetWordWrap(false);

    --------------------------------------------------------------------
    -- Top roll line: "Top roll" -> class-colored name -> MS/OS pill ->
    -- SR pill (conditional) -> gold roll number (no right anchor).
    --------------------------------------------------------------------

    dialog.guardTopRollRow = CreateFrame("Frame", nil, dialog);

    dialog.guardTopLabel = dialog.guardTopRollRow:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.guardTopLabel, "small");
    dialog.guardTopLabel:SetTextColor(unpack(Colors.muted));
    dialog.guardTopLabel:SetText("Top roll");
    dialog.guardTopLabel:SetPoint("LEFT", dialog.guardTopRollRow, "LEFT", 0, 0);

    dialog.guardTopName = dialog.guardTopRollRow:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.guardTopName, "sectionHeader"); -- heavier weight than "body" - stands in for "bold"
    dialog.guardTopName:SetJustifyH("LEFT");
    dialog.guardTopName:SetWordWrap(false);
    dialog.guardTopName:SetPoint("LEFT", dialog.guardTopLabel, "RIGHT", g.topRollGap, 0);

    dialog.guardMsOsPill = CreateFrame("Frame", nil, dialog.guardTopRollRow);
    dialog.guardMsOsPill:SetHeight(Sizes.pill.height);
    Skin.Pill(dialog.guardMsOsPill);
    dialog.guardMsOsPill:SetPillFillColor(unpack(Colors.defaultBg));
    dialog.guardMsOsPill.label = dialog.guardMsOsPill:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.guardMsOsPill.label, "small");
    dialog.guardMsOsPill.label:SetPoint("CENTER");
    dialog.guardMsOsPill.label:SetJustifyH("CENTER");

    dialog.guardSRPill = CreateFrame("Frame", nil, dialog.guardTopRollRow);
    dialog.guardSRPill:SetHeight(Sizes.pill.height);
    Skin.Pill(dialog.guardSRPill);
    dialog.guardSRPill:SetPillColor(unpack(Colors.rollTags.SR.border));
    dialog.guardSRPill:SetPillFillColor(unpack(Colors.defaultBg));
    dialog.guardSRPill.label = dialog.guardSRPill:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.guardSRPill.label, "small");
    dialog.guardSRPill.label:SetTextColor(unpack(Colors.rollTags.SR.text));
    dialog.guardSRPill.label:SetText("SR");
    dialog.guardSRPill.label:SetPoint("CENTER");
    dialog.guardSRPill.label:SetJustifyH("CENTER");
    dialog.guardSRPill:SetWidth(Sizes.pill.padX * 2 + dialog.guardSRPill.label:GetStringWidth());

    dialog.guardRollNumber = dialog.guardTopRollRow:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.guardRollNumber, "sectionHeader");
    dialog.guardRollNumber:SetTextColor(unpack(Colors.gold));
    dialog.guardRollNumber:SetJustifyH("LEFT"); -- positioned per-paint, no right anchor ever set

    --------------------------------------------------------------------
    -- Warning box
    --------------------------------------------------------------------

    dialog.guardWarningBox = CreateFrame("Frame", nil, dialog, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(dialog.guardWarningBox, Colors.awardWarningBg, Colors.awardWarningBorder, 1);

    dialog.guardWarningText = dialog.guardWarningBox:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.guardWarningText, "small");
    dialog.guardWarningText:SetTextColor(unpack(Colors.awardWarningText));
    dialog.guardWarningText:SetPoint("TOPLEFT", dialog.guardWarningBox, "TOPLEFT", g.warningPadX, -g.warningPadY);
    dialog.guardWarningText:SetWidth(g.width - g.padding * 2 - g.warningPadX * 2);
    dialog.guardWarningText:SetJustifyH("LEFT");
    dialog.guardWarningText:SetWordWrap(true);

    --------------------------------------------------------------------
    -- Buttons. Skin.ConfirmPopup hardwires Escape/scrim-click to whichever
    -- button occupies the cancelButton (left) slot - "Start Without
    -- Awarding" is the left button by design, but Escape/scrim must still
    -- resolve to "Go Back", not to the left button's own label. So the
    -- left button's own OnClick is overridden below to call
    -- startWithoutAwarding() directly, while onCancel (still driving only
    -- Escape + scrim via the component's own wiring) and onConfirm (driving
    -- the right button + Enter) both resolve to goBack().
    --------------------------------------------------------------------

    guardPopup:SetButtons("Start Without Awarding", "Go Back", goBack, goBack);

    guardPopup.cancelButton:SetScript("OnClick", function()
        if (not guardPopup.shown) then return; end
        guardPopup:Hide();
        startWithoutAwarding();
    end);
    -- confirmButton ("Go Back") keeps ConfirmPopup's default "primary"/gold
    -- look untouched. cancelButton ("Start Without Awarding") keeps its
    -- default "default" look, just recolored destructive-red.
    guardPopup.cancelButton.text:SetTextColor(unpack(Colors.awardWarningIcon));
    guardPopup.cancelButton:SetWidth(guardPopup.cancelButton.text:GetStringWidth() + g.buttonPadX * 2);
    guardPopup.confirmButton:SetWidth(guardPopup.confirmButton.text:GetStringWidth() + g.buttonPadX * 2);
end

--- Repaints the guard's content from RollTracker.CurrentRollOff. Safe to
--- call repeatedly - called once when the guard opens (via showGuard) and
--- again from RollWindow.Refresh()'s live-update hook while it's open.
local function paintGuardContent()
    local RollOff = RollTracker.CurrentRollOff;
    if (not RollOff) then return; end -- defensive; callers only ever invoke this while RollOff exists
    local g = Sizes.guard;
    local dialog = guardPopup.dialog;

    -- Same nil-quality guard idiom as paintHeader() above.
    local qr, qg, qb;
    if (RollOff.itemQuality) then
        qr, qg, qb = Util.GetItemQualityColor(RollOff.itemQuality);
    end
    dialog.guardIcon:SetTexture(RollOff.itemIcon or FALLBACK_ICON);
    dialog.guardIconBorder:SetBackdropBorderColor(qr or 0.6, qg or 0.6, qb or 0.6);
    dialog.guardItemName:SetTextColor(qr or 1, qg or 1, qb or 1);
    local textWidth = g.width - g.padding * 2 - g.itemBoxPadding * 2 - g.iconSize - g.iconTextGap;
    setTextEllipsized(dialog.guardItemName, ("[%s]"):format(RollOff.itemName or RollOff.item or ""), textWidth);

    local n = #RollOff.Rolls;
    local summary = ("%d roll%s, no winner yet"):format(n, n == 1 and "" or "s");
    if (RollOff.active) then summary = summary .. " \194\183 still rolling"; end
    dialog.guardSummary:SetText(summary);

    -- Same sort RollSession.BuildRows already applies to the visible list,
    -- so [1] always matches the top row shown in the window itself.
    local rows = RollSession.BuildRows(RollOff);
    local top = rows[1];
    if (top) then
        local classColor = RAID_CLASS_COLORS and top.class and RAID_CLASS_COLORS[top.class];
        if (classColor) then
            dialog.guardTopName:SetTextColor(classColor.r, classColor.g, classColor.b);
        else
            dialog.guardTopName:SetTextColor(unpack(Colors.text));
        end
        dialog.guardTopName:SetText(top.player);

        local isMS = top.classification == "MS";
        local classColors = isMS and Colors.rollTags.MS or Colors.rollTags.OS;
        dialog.guardMsOsPill.label:SetText(isMS and "MS" or "OS");
        dialog.guardMsOsPill:SetPillColor(unpack(classColors.border));
        dialog.guardMsOsPill.label:SetTextColor(unpack(classColors.text));
        dialog.guardMsOsPill:SetWidth(Sizes.pill.padX * 2 + dialog.guardMsOsPill.label:GetStringWidth());
        dialog.guardMsOsPill:ClearAllPoints();
        dialog.guardMsOsPill:SetPoint("LEFT", dialog.guardTopName, "RIGHT", g.topRollGap, 0);

        dialog.guardSRPill:SetShown(top.isSR and true or false);
        dialog.guardSRPill:ClearAllPoints();
        dialog.guardSRPill:SetPoint("LEFT", dialog.guardMsOsPill, "RIGHT", g.topRollGap, 0);

        local lastPill = top.isSR and dialog.guardSRPill or dialog.guardMsOsPill;
        dialog.guardRollNumber:SetText(tostring(top.amount or 0));
        dialog.guardRollNumber:ClearAllPoints();
        dialog.guardRollNumber:SetPoint("LEFT", lastPill, "RIGHT", g.rollNumberGap, 0); -- no right anchor
    end

    -- Always the CURRENT RollOff's item, never guardItemLink. Plain display
    -- name (not RollOff.item's colored hyperlink) so the whole sentence
    -- stays a uniform Colors.awardWarningText.
    local itemText = ("[%s]"):format(RollOff.itemName or RollOff.item or "this item");
    dialog.guardWarningText:SetText(
        ("Starting a new roll clears these rolls. Nobody gets %s unless you award it first."):format(itemText));
end

--- buildContentFn for guardPopup:Show() - positions the 3 sections top-down.
--- Only needs to run once per Show() (box heights are static given the
--- fixed dialog width and already-set, wrapped text) - paintGuardContent's
--- live-update calls don't re-run this.
local function layoutGuardContent(dialog, y)
    local g = Sizes.guard;

    dialog.guardItemBox:ClearAllPoints();
    dialog.guardItemBox:SetPoint("TOPLEFT", dialog, "TOPLEFT", g.padding, y);
    dialog.guardItemBox:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -g.padding, y);
    local textColHeight = dialog.guardItemName:GetStringHeight() + g.lineGap + dialog.guardSummary:GetStringHeight();
    local itemBoxHeight = math.max(g.iconSize, textColHeight) + g.itemBoxPadding * 2;
    dialog.guardItemBox:SetHeight(itemBoxHeight);
    y = y - itemBoxHeight - g.sectionGap;

    dialog.guardTopRollRow:ClearAllPoints();
    dialog.guardTopRollRow:SetPoint("TOPLEFT", dialog, "TOPLEFT", g.padding, y);
    dialog.guardTopRollRow:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -g.padding, y);
    dialog.guardTopRollRow:SetHeight(g.topRollRowHeight);
    y = y - g.topRollRowHeight - g.sectionGap;

    dialog.guardWarningBox:ClearAllPoints();
    dialog.guardWarningBox:SetPoint("TOPLEFT", dialog, "TOPLEFT", g.padding, y);
    dialog.guardWarningBox:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -g.padding, y);
    local warningHeight = dialog.guardWarningText:GetStringHeight() + g.warningPadY * 2;
    dialog.guardWarningBox:SetHeight(warningHeight);
    y = y - warningHeight - g.sectionGap;

    return y;
end

--- Opens (or refreshes in place, if already open) the guard for itemLink.
--- Closes the Award confirm popup and clears bar-hover state, per spec.
--- Does NOT touch the roll timer - rolls keep coming in behind the scrim.
local function showGuard(itemLink)
    guardItemLink = itemLink;
    hideAwardPopup();
    barHovered = false;
    ensureGuard();
    paintGuardContent();
    guardPopup:Show(layoutGuardContent);
end

--- Hard-close, used by RollWindow.Hide(). Unlike goBack/startWithoutAwarding
--- (which rely on Skin.ConfirmPopup having already hidden itself before
--- firing their callback - see cancelPopup/Confirm in Skin.lua), this path
--- doesn't go through that flow, so it hides the popup explicitly.
local function hideGuard()
    guardItemLink = nil;
    if (guardPopup) then guardPopup:Hide(); end
end

--- onCancel (Go Back / Escape / scrim-click). The popup is already hidden
--- by the time this runs - nothing else changes: rolls, timer and status
--- stay exactly as they were.
function goBack()
    guardItemLink = nil;
end

--- onConfirm ("Start Without Awarding", via the right button/Enter) AND the
--- left button's own overridden OnClick above. Popup is already hidden (or
--- explicitly hidden immediately before this runs, in the left-button case).
function startWithoutAwarding()
    local link = guardItemLink;
    guardItemLink = nil;
    startFresh(link);
end

--------------------------------------------------------------------------
-- Roll list rows
--------------------------------------------------------------------------

local function paintRowBackground(row)
    if (row.isWinner) then
        Theme.Helpers.SetFlatBackdrop(row, Colors.councilFill, Colors.councilBorder, 1);
    elseif (row.wasHovered) then
        Theme.Helpers.SetFlatBackdrop(row, Colors.tradeQueueRowHoverBg, Colors.checkboxBorder, 1);
    else
        Theme.Helpers.SetFlatBackdrop(row, Colors.memberBg, Colors.transparent, 1);
    end
end

local function ensureRow(i)
    if (rows[i]) then return rows[i]; end

    local row = CreateFrame("Button", nil, listScrollChild, "BackdropTemplate");
    row:SetHeight(Sizes.list.rowHeight);
    row:SetPoint("RIGHT", listScrollChild, "RIGHT");
    row:RegisterForClicks("RightButtonUp");
    Theme.Helpers.SetFlatBackdrop(row, Colors.memberBg, Colors.transparent, 1);

    row.crown = row:CreateTexture(nil, "OVERLAY");
    row.crown:SetSize(Sizes.list.crownSize, Sizes.list.crownSize);
    row.crown:SetPoint("LEFT", row, "LEFT", Sizes.list.rowPadX, 0);
    row.crown:SetTexture(CROWN_TEXTURE);
    row.crown:Hide();

    row.countText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.countText, "small");
    row.countText:SetTextColor(unpack(Colors.disabledText));
    row.countText:SetJustifyH("RIGHT");
    row.countText:SetWidth(Sizes.list.colCount);
    row.countText:SetPoint("RIGHT", row, "RIGHT", -Sizes.list.rowPadX, 0);

    row.rollText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.rollText, "sectionHeader");
    row.rollText:SetTextColor(unpack(Colors.gold));
    row.rollText:SetJustifyH("RIGHT");
    row.rollText:SetWidth(Sizes.list.colRoll);
    row.rollText:SetPoint("RIGHT", row.countText, "LEFT", -Sizes.list.colGap, 0);

    row.tagsAnchor = CreateFrame("Frame", nil, row);
    row.tagsAnchor:SetSize(Sizes.list.colTags, Sizes.list.rowHeight);
    row.tagsAnchor:SetPoint("RIGHT", row.rollText, "LEFT", -Sizes.list.colGap, 0);

    row.msOsPill = CreateFrame("Frame", nil, row);
    row.msOsPill:SetHeight(Sizes.pill.height);
    Skin.Pill(row.msOsPill);
    row.msOsPill:SetPillFillColor(unpack(Colors.defaultBg));
    -- border/text color set per-refresh in paintRows() below, from
    -- Colors.rollTags.MS/OS depending on the roll's classification.
    row.msOsPill.label = row.msOsPill:CreateFontString(nil, "OVERLAY");
    SetFont(row.msOsPill.label, "small");
    row.msOsPill.label:SetPoint("CENTER");
    row.msOsPill.label:SetJustifyH("CENTER");
    row.msOsPill:SetPoint("LEFT", row.tagsAnchor, "LEFT", 0, 0);

    row.srPill = CreateFrame("Frame", nil, row);
    row.srPill:SetHeight(Sizes.pill.height);
    Skin.Pill(row.srPill);
    row.srPill:SetPillColor(unpack(Colors.rollTags.SR.border));
    row.srPill:SetPillFillColor(unpack(Colors.defaultBg));
    row.srPill.label = row.srPill:CreateFontString(nil, "OVERLAY");
    SetFont(row.srPill.label, "small");
    row.srPill.label:SetTextColor(unpack(Colors.rollTags.SR.text));
    row.srPill.label:SetText("SR");
    row.srPill.label:SetPoint("CENTER");
    row.srPill.label:SetJustifyH("CENTER");
    row.srPill:SetWidth(Sizes.pill.padX * 2 + row.srPill.label:GetStringWidth());

    row.nameText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.nameText, "body");
    row.nameText:SetJustifyH("LEFT");
    row.nameText:SetWordWrap(false);
    row.nameText:SetPoint("LEFT", row.crown, "RIGHT", Sizes.list.colGap, 0);
    row.nameText:SetPoint("RIGHT", row.tagsAnchor, "LEFT", -Sizes.list.colGap, 0);

    row:SetScript("OnUpdate", function(self)
        local RollOff = RollTracker.CurrentRollOff;
        local isStarter = RollOff and RollOff.initiatorIsMe or false;
        local isHovered = isStarter and Util.IsMouseOverVisible(self, listScrollFrame) or false;
        if (isHovered ~= self.wasHovered) then
            self.wasHovered = isHovered;
            paintRowBackground(self);
        end

        if (self.rollData and isHovered and Util.IsMouseOverVisible(self.countText, listScrollFrame)) then
            GameTooltip:SetOwner(self.countText, "ANCHOR_RIGHT");
            local n = self.rollData.rollNumber or 1;
            GameTooltip:AddLine(("%d%s roll by this player"):format(n, ordinalSuffix(n)));
            GameTooltip:Show();
        elseif (GameTooltip:GetOwner() == self.countText) then
            GameTooltip:Hide();
        end
    end);

    row:SetScript("OnClick", function(self)
        local RollOff = RollTracker.CurrentRollOff;
        if (not RollOff or not RollOff.initiatorIsMe or not self.rollData) then return; end
        if (self.isWinner) then return; end -- already-crowned rows can't be re-awarded, only Reassigned via another row
        showAwardPopup(self.rollData);
    end);

    rows[i] = row;
    return row;
end

-- A row is a winner if its roll matches an entry in RollOff.winners. `rollId`
-- (this client's own stable arrivalIndex, set on award) is an exact match
-- when available; otherwise fall back to the same content-tuple match the
-- single-winner code used before (name+amount+classification) - needed for
-- another client's rows, since arrivalIndex is only ever meaningful locally
-- (each client parses CHAT_MSG_SYSTEM independently).
local function isRowWinner(RollOff, data)
    for _, w in ipairs(RollOff.winners or {}) do
        if (data.arrivalIndex ~= nil and w.rollId ~= nil and w.rollId == data.arrivalIndex) then
            return true;
        elseif (Util.namesMatch(w.name, data.player) and w.amount == data.amount and w.classification == data.classification) then
            return true;
        end
    end
    return false;
end

--- Pools/paints one row per entry in `rollRows` (see RollSession.BuildRows),
--- hides the rest, and returns the full (unclamped) content height so the
--- caller can size listScrollChild to it.
local function paintRows(rollRows, RollOff)
    local contentHeight = 0;
    for i, data in ipairs(rollRows) do
        local row = ensureRow(i);
        row:ClearAllPoints();
        row:SetPoint("TOPLEFT", listScrollChild, "TOPLEFT", 0, -contentHeight);
        row:SetPoint("RIGHT", listScrollChild, "RIGHT");

        local isWinner = isRowWinner(RollOff, data);
        row.isWinner = isWinner;
        row.crown:SetShown(isWinner);

        local classColor = RAID_CLASS_COLORS and data.class and RAID_CLASS_COLORS[data.class];
        if (classColor) then
            row.nameText:SetTextColor(classColor.r, classColor.g, classColor.b);
        else
            row.nameText:SetTextColor(unpack(Colors.text));
        end
        setTextEllipsized(row.nameText, data.player, row.nameText:GetWidth());

        local isMS = data.classification == "MS";
        local classColors = isMS and Colors.rollTags.MS or Colors.rollTags.OS;
        row.msOsPill.label:SetText(isMS and "MS" or "OS");
        row.msOsPill:SetPillColor(unpack(classColors.border));
        row.msOsPill.label:SetTextColor(unpack(classColors.text));
        row.msOsPill:SetWidth(Sizes.pill.padX * 2 + row.msOsPill.label:GetStringWidth());
        row.msOsPill:ClearAllPoints();
        row.msOsPill:SetPoint("LEFT", row.tagsAnchor, "LEFT", 0, 0);

        row.srPill:SetShown(data.isSR and true or false);
        row.srPill:ClearAllPoints();
        row.srPill:SetPoint("LEFT", row.msOsPill, "RIGHT", 3, 0);

        row.rollText:SetText(tostring(data.amount or 0));
        row.countText:SetText("x" .. tostring(data.rollNumber or 1));
        row.rollData = data;
        row.wasHovered = false;
        paintRowBackground(row);
        row:Show();

        contentHeight = contentHeight + Sizes.list.rowHeight;
        if (i < #rollRows) then contentHeight = contentHeight + Sizes.list.rowGap; end
    end

    for i = #rollRows + 1, #rows do
        rows[i].rollData = nil;
        rows[i]:Hide();
    end

    return contentHeight;
end

--------------------------------------------------------------------------
-- Header / hint painting
--------------------------------------------------------------------------

local function paintHeader(RollOff)
    local link = currentItemLink();
    if (not link) then
        headerIconTex:SetTexture(nil);
        Theme.Helpers.SetFlatBackdrop(headerIconBorder, nil, Colors.transparent, 1);
        headerNameText:SetText("");
        headerTypeText:SetText("");
        return;
    end

    local itemID = Util.itemIDFromLink(link);
    local name, _, quality, _, _, itemType, itemSubType = Util.GetItemInfo(link);

    local icon = (RollOff and RollOff.itemIcon) or (itemID and Util.GetItemIcon(itemID)) or FALLBACK_ICON;
    headerIconTex:SetTexture(icon);

    -- itemQuality/quality can both still be nil here - each is only ever
    -- populated from THIS client's own item cache (RollTracker.lua's
    -- applyStart calls Util.GetItemInfo locally, it isn't sent over comm),
    -- so a client that hasn't cached this item yet sees nil until the async
    -- GET_ITEM_INFO_RECEIVED backfill lands and triggers another Refresh().
    -- C_Item.GetItemQualityColor errors on a nil quality, so skip the call
    -- entirely rather than passing nil through.
    local resolvedQuality = (RollOff and RollOff.itemQuality) or quality;
    local qr, qg, qb;
    if (resolvedQuality) then
        qr, qg, qb = Util.GetItemQualityColor(resolvedQuality);
    end
    headerIconBorder:SetBackdropBorderColor(qr or 0.6, qg or 0.6, qb or 0.6);

    local displayName = name or (RollOff and RollOff.itemName);
    if (displayName) then
        headerNameText:SetTextColor(qr or 1, qg or 1, qb or 1);
        setTextEllipsized(headerNameText, ("[%s]"):format(displayName), headerNameText:GetWidth());
    else
        headerNameText:SetTextColor(unpack(Colors.text));
        headerNameText:SetText(link);
    end

    local typeLine = Util.JoinTypeParts(itemType, itemSubType);
    if (itemID and FL.SoftRes and FL.SoftRes.GetReservationsForItemID) then
        local reservations = FL.SoftRes.GetReservationsForItemID(itemID);
        local count = reservations and #reservations or 0;
        if (count > 0) then
            local srText = ("%d soft reserve%s"):format(count, count == 1 and "" or "s");
            local srColored = ("|cff%s%s|r"):format(colorHex(Colors.rollSRBlue), srText);
            typeLine = (typeLine ~= "" and (typeLine .. " \194\183 ") or "") .. srColored;
        end
    end
    headerTypeText:SetTextColor(unpack(Colors.muted));
    headerTypeText:SetText(typeLine);
end

local function paintHint(RollOff)
    if (RollOff.initiatorIsMe) then
        local atlasInfo = C_Texture.GetAtlasInfo(RIGHT_CLICK_ATLAS);
        if (atlasInfo) then
            hintIcon:SetWidth(Sizes.hint.height * (atlasInfo.width / atlasInfo.height));
            hintIcon:SetAtlas(RIGHT_CLICK_ATLAS);
            hintIcon:SetVertexColor(1, 1, 1);
            hintIcon:Show();
            hintText:ClearAllPoints();
            hintText:SetPoint("LEFT", hintIcon, "RIGHT", Sizes.hint.iconGap, 0);
        else
            hintIcon:Hide();
            hintText:ClearAllPoints();
            hintText:SetPoint("LEFT", hintRow, "LEFT", 0, 0);
        end
        hintText:SetTextColor(unpack(Colors.muted));
        hintText:SetText("Right-click a roll to award");
    else
        hintIcon:Hide();
        hintText:ClearAllPoints();
        hintText:SetPoint("LEFT", hintRow, "LEFT", 0, 0);
        local name = RollOff.initiatorFqn and Util.stripRealm(RollOff.initiatorFqn) or "?";
        local classFile = Util.lookupClass(Util.groupMembers(), name);
        hintText:SetTextColor(unpack(Colors.muted));
        hintText:SetText("Started by " .. Util.classColoredName(name, classFile));
    end
end

--------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------

local function layoutSetup()
    setupRow:Show();
    timerLabel:Hide();
    timerBar.track:Hide();
    msButton:Hide();
    osButton:Hide();
    hintRow:Hide();
    listBox:Hide();
    statusDivider:Hide();
    statusDot:Hide();
    statusMessageText:Hide();

    local headerHeight = math.max(Sizes.header.iconSize,
        headerNameText:GetStringHeight() + Sizes.header.nameTypeGap + headerTypeText:GetStringHeight());
    itemRow:SetHeight(headerHeight);

    setupRow:ClearAllPoints();
    setupRow:SetPoint("TOPLEFT", itemRow, "BOTTOMLEFT", 0, -Sizes.sectionGap);
    setupRow:SetPoint("RIGHT", frame, "RIGHT", -Sizes.padding, 0);

    local windowHeight = Sizes.titleBarHeight + Sizes.padding + headerHeight + Sizes.sectionGap
        + Sizes.setup.rowHeight + Sizes.padding;

    heightAnim = nil;
    Pixel.SetHeight(frame, windowHeight);
end

--- Rolling/Stopped/Awarded layout, shared by the starter and every other
--- raider's window - only which pieces are interactive differs (gated
--- inline where each is wired up), not the layout itself.
local function layoutActive(RollOff, animateExpand)
    setupRow:Hide();
    timerLabel:Show();
    timerBar.track:Show();
    hintRow:Show();
    listBox:Show();

    local headerHeight = math.max(Sizes.header.iconSize,
        headerNameText:GetStringHeight() + Sizes.header.nameTypeGap + headerTypeText:GetStringHeight());
    itemRow:SetHeight(headerHeight);

    local y = Sizes.titleBarHeight + Sizes.padding + headerHeight + Sizes.sectionGap;

    timerLabel:ClearAllPoints();
    timerLabel:SetPoint("TOP", frame, "TOP", 0, -y);
    y = y + Sizes.timer.labelHeight + Sizes.sectionGap;

    timerBar.track:ClearAllPoints();
    timerBar.track:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.padding, -y);
    timerBar.track:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.padding, -y);
    y = y + Sizes.timer.barHeight + Sizes.sectionGap;

    -- Also covers the brief window right after confirming an award, before
    -- StopRollOff's own broadcast has round-tripped back to flip
    -- RollOff.active false (AwardItem doesn't wait on that - see
    -- confirmAward) - any winner alone is enough to know rolling is done.
    local stopped = (not RollOff.active) or (RollOff.winners and #RollOff.winners > 0);
    msButton:SetShown(true);
    osButton:SetShown(true);
    msButton:ClearAllPoints();
    msButton:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.padding, -y);
    osButton:ClearAllPoints();
    osButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.padding, -y);
    local buttonsWidth = (Sizes.window.width - Sizes.padding * 2 - Sizes.rollButtons.gap) / 2;
    msButton:SetWidth(buttonsWidth);
    osButton:SetWidth(buttonsWidth);
    if (stopped) then msButton:Disable(); osButton:Disable(); else msButton:Enable(); osButton:Enable(); end
    y = y + Sizes.rollButtons.height + Sizes.sectionGap;

    hintRow:ClearAllPoints();
    hintRow:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.padding, -y);
    hintRow:SetPoint("RIGHT", frame, "RIGHT", -Sizes.padding, 0);
    y = y + Sizes.hint.height + Sizes.sectionGap;

    local rollRows = RollSession.BuildRows(RollOff);
    local fullListHeight = paintRows(rollRows, RollOff);
    listScrollChild:SetHeight(math.max(fullListHeight, 1));

    local listBoxHeight;
    if (#rollRows == 0) then
        listEmptyText:Show();
        listBoxHeight = Sizes.list.emptyHeight;
    else
        listEmptyText:Hide();
        local visibleRows = math.min(#rollRows, Sizes.list.maxVisibleRows);
        local visibleHeight = visibleRows * Sizes.list.rowHeight + (visibleRows - 1) * Sizes.list.rowGap;
        listBoxHeight = visibleHeight + Sizes.list.padding * 2;
    end

    listBox:ClearAllPoints();
    listBox:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.padding, -y);
    listBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.padding, -y);
    listBox:SetHeight(listBoxHeight);
    y = y + listBoxHeight;

    -- Status line only takes space when it has content.
    if (statusMessageText:IsShown()) then
        y = y + Sizes.sectionGap;
        statusDivider:ClearAllPoints();
        statusDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.padding, -y);
        statusDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.padding, -y);
        y = y + 1 + Sizes.status.gap;

        statusMessageText:SetWidth(Sizes.window.width - Sizes.padding * 2 - Sizes.status.dotSize - Sizes.status.gap);
        statusDot:ClearAllPoints();
        statusDot:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.padding, -(y + 3));
        statusMessageText:ClearAllPoints();
        statusMessageText:SetPoint("TOPLEFT", statusDot, "TOPRIGHT", Sizes.status.gap, 3);
        y = y + statusMessageText:GetStringHeight();
    end

    local windowHeight = y + Sizes.padding;

    -- animateExpand is only ever true right after layoutSetup() left the
    -- window at its Setup height - animateGrowTo reads that current height
    -- as the animation's start point itself, so there's nothing to
    -- pre-adjust here.
    if (animateExpand) then
        animateGrowTo(windowHeight);
    else
        heightAnim = nil;
        Pixel.SetHeight(frame, windowHeight);
    end
end

--------------------------------------------------------------------------
-- Status line kinds - see the file header on why this is the single choke
-- point every status message flows through.
--------------------------------------------------------------------------

local function setStatus(kind, text)
    if (not text or text == "") then
        statusMessageText:Hide();
        return;
    end

    local color = statusColor(kind);
    statusDot:SetVertexColor(unpack(color));
    statusMessageText:SetTextColor(unpack(color));
    statusMessageText:SetText(text);
    statusMessageText:Show();
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

local wasStartPrompt = false; -- true only while the last-shown state was Setup

function RollWindow.Refresh()
    if (not frame) then return; end

    local RollOff = RollTracker.CurrentRollOff;

    -- A real roll-off (ours or someone else's) always supersedes a pending,
    -- not-yet-broadcast one.
    if (RollOff) then pendingItemLink = nil; end

    if (not RollOff and not pendingItemLink) then
        frame:Hide();
        return;
    end

    paintHeader(RollOff);

    if (not RollOff) then
        wasStartPrompt = true;
        layoutSetup();
        return;
    end

    -- Popup staleness guard: close it if it was opened for a roll-off that
    -- this one has since superseded.
    if (popupRollOffId and popupRollOffId ~= RollOff.id) then
        hideAwardPopup();
    end

    -- Track whether the current roll-off just stopped before its own
    -- deadline (see the module-level comment on lastActiveRollOffId).
    if (RollOff.active) then
        if (lastActiveRollOffId ~= RollOff.id) then
            lastActiveRollOffId = RollOff.id;
            stoppedEarly = nil;
            lastLabelSeconds = nil;
            -- Bounds a stuck-true hover flag (e.g. the window was hidden
            -- while the mouse sat over the bar, so OnLeave never fired) to
            -- at most one roll-off's lifetime.
            barHovered = false;
        end
    elseif (RollOff.id == lastActiveRollOffId and stoppedEarly == nil) then
        local remaining = RollOff.time - (GetTime() - RollOff.startedAt);
        stoppedEarly = remaining > 0.5;
    end

    local animateExpand = wasStartPrompt and RollOff.initiatorIsMe;
    wasStartPrompt = false;

    paintHint(RollOff);

    -- Paint the timer label/bar/status BEFORE laying out - layoutActive
    -- measures the status line's final text/visibility to size the list/
    -- window height, so it has to run after this, not before.
    if (RollOff.winners and #RollOff.winners > 0) then
        timerLabel:SetTextColor(unpack(Colors.respondSentLabel));
        timerLabel:SetText("Awarded");
        timerBar:Freeze(Colors.border);
        -- RollOff.item is the real item link string, already self-colored
        -- (and shift-clickable in chat) via its own embedded color codes -
        -- preferred over reconstructing "[Name]" by hand.
        local itemText = RollOff.item or (RollOff.itemName and ("[%s]"):format(RollOff.itemName)) or "";
        local action = RollOff.lastAction;

        if (action and action.kind == "reassign") then
            local replacedText = joinNamesComma(action.replacedNames);
            local winnerText = Util.classColoredName(action.winnerName, action.winnerClass);
            local text = ("Reassigned %s to %s (replaced %s) \194\183 trade queue updated."):format(
                itemText, winnerText, replacedText);
            local kind = "success";
            if (action.alreadyTradedNames and #action.alreadyTradedNames > 0) then
                kind = "error";
                for _, tn in ipairs(action.alreadyTradedNames) do
                    text = text .. (" %s already received it in a trade \226\128\148 get it back manually."):format(
                        Util.classColoredName(tn.name, tn.class));
                end
            end
            setStatus(kind, text);
        else
            local ordinal = (action and action.ordinal) or #RollOff.winners;
            local lastWinner = RollOff.winners[#RollOff.winners];
            local winnerName = (action and action.winnerName) or lastWinner.name;
            local winnerClass = (action and action.winnerClass) or lastWinner.class;
            local winnerText = Util.classColoredName(winnerName, winnerClass);
            local prefix = ordinal <= 1 and ("Awarded %s"):format(itemText)
                or ("Awarded a %d%s %s"):format(ordinal, ordinalSuffix(ordinal), itemText);
            setStatus("success", ("%s to %s \194\183 added to the trade queue."):format(prefix, winnerText));
        end
    elseif (not RollOff.active) then
        timerLabel:SetTextColor(unpack(Colors.sessionDeleteHoverIcon));
        timerLabel:SetText("Rolling stopped");
        timerBar:Freeze(Colors.border);
        setStatus("info", stoppedEarly and "Rolling stopped early." or "Rolling ended.");
    else
        timerBar:Unfreeze();
        timerBar:SetVariant("running");
        setStatus(nil, nil);
        updateCountdown();
    end

    layoutActive(RollOff, animateExpand);

    -- Live-update the guard's summary/top-roll line while it's open (the
    -- guard can only be shown while a real RollOff exists, so this branch
    -- of Refresh() is the only one ever reachable while it is - see
    -- startFresh/showGuard for why the earlier Setup-phase branches above
    -- can never fire in that window).
    if (guardPopup and guardPopup.shown) then paintGuardContent(); end
end

--------------------------------------------------------------------------
-- Window lifecycle
--------------------------------------------------------------------------

function RollWindow.Show()
    ensureFrame();
    frame:Show();
    RollWindow.Refresh();
end

--- Opens this window locally, pre-loaded with itemLink and a seconds box +
--- "Start Roll" button - only ever called on the client that alt+left-clicked
--- the item, so only that client ever sees those controls. If the current
--- roll-off (if any) still has rolls nobody's been awarded, shows the
--- "Nobody has been awarded yet" guard instead of silently discarding them -
--- see hasUnawardedRolls()/showGuard() above. Otherwise discards whatever
--- roll-off is sitting in RollTracker.CurrentRollOff (finished-and-awarded,
--- or empty) and loads itemLink straight into Setup phase - see startFresh().
function RollWindow.ShowStartPrompt(itemLink)
    if (not itemLink) then return; end

    ensureFrame();

    if (hasUnawardedRolls()) then
        showGuard(itemLink);
    else
        startFresh(itemLink);
    end

    frame:Show();
    RollWindow.Refresh();
end

function RollWindow.Hide()
    pendingItemLink = nil;
    hideAwardPopup();
    hideGuard();
    if (frame) then frame:Hide(); end
end

function RollWindow.IsShown()
    return frame ~= nil and frame:IsShown();
end

function RollWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then RollWindow.Hide(); else RollWindow.Show(); end
end

function RollWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
