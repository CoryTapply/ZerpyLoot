--[[
Replaces the old ElvUI-style UI/GroupLootRollBars.lua. Built directly with
the settings window's own control vocabulary (UI.Colors/UI.Sizes.groupLoot/
UI.SetFont/UI.Skin), not FL.Theme - this window has exactly one look, it
doesn't follow the active skin. All roll-tracking logic (votes, history
matching, Blizzard frame suppression) stays in GroupLootRoll.lua - this file
only reads FL.GroupLootRoll.ActiveRolls and calls GroupLootRoll.RollOn/
ConfirmRoll; it never touches the roll APIs directly.

A vertical stack - header (drag handle), an idle box, up to 5 roll rows, and
a "+N more" bar - anchored by its own TOPLEFT at the saved position and
growing downward. Pixel.SetHeight (resizes in place, leaves TOPLEFT alone)
is what makes that grow-without-moving possible; the stack is fully hidden
the instant nothing needs to be shown (locked with 0 rolls).
]]

local FL = ForeverLoot;
local GroupLootFrame = FL.UI.GroupLootFrame;
local GroupLootRoll = FL.GroupLootRoll;
local Util = FL.Util;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.groupLoot;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;

-- Same values RollOnLoot takes. Transmog (4) replaces Greed for items you
-- can't need or greed - see the plan's "Transmog, not Disenchant" decision,
-- this addon has never supported a real Disenchant roll.
local ROLL_PASS, ROLL_NEED, ROLL_GREED, ROLL_TRANSMOG = 0, 1, 2, 4;

local MAX_VISIBLE_ROWS = 5;

-- Key this stack's saved position is stored under - unchanged from the old
-- GroupLootRollBars.lua so an existing saved position isn't lost.
local POSITION_KEY = "groupLootRoll";

-- Shared with UI/SettingsWindow/Skin.lua's own timer bar glow/card shadows -
-- same asset, same "tinted texture, no template" technique.
local SOFTGLOW_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\SoftGlow";

-- Blizzard's own Group Loot button art (same textures the default
-- GroupLootFrame buttons use) - "-Up"/"-Down" is Blizzard's standard
-- two-state naming for this kind of button texture.
local ROLL_BUTTON_TEXTURES = {
    [ROLL_NEED]  = { up = [[Interface\Buttons\UI-GroupLoot-Dice-Up]],  down = [[Interface\Buttons\UI-GroupLoot-Dice-Down]] },
    [ROLL_GREED] = { up = [[Interface\Buttons\UI-GroupLoot-Coin-Up]],  down = [[Interface\Buttons\UI-GroupLoot-Coin-Down]] },
    [ROLL_PASS]  = { up = [[Interface\Buttons\UI-GroupLoot-Pass-Up]],  down = [[Interface\Buttons\UI-GroupLoot-Pass-Down]] },
};

-- Transmog has no file-based art; Blizzard's own roll frame draws it from
-- these atlases (the same ones GroupLootFrame.xml's TransmogButton uses).
local TRANSMOG_ATLASES = {
    up = "lootroll-toast-icon-transmog-up",
    down = "lootroll-toast-icon-transmog-down",
    highlight = "lootroll-toast-icon-transmog-highlight",
};

local OPTION_LABELS = { [ROLL_PASS] = "Pass", [ROLL_NEED] = "Need", [ROLL_GREED] = "Greed", [ROLL_TRANSMOG] = "Transmog" };
local OPTION_COLORS = {
    [ROLL_PASS] = Colors.sessionDeleteHoverIcon,
    [ROLL_NEED] = Colors.respondSentLabel,
    [ROLL_GREED] = Colors.gold,
    [ROLL_TRANSMOG] = Colors.rollTags.OS.text,
};

-- Derived once from Sizes.groupLoot.row rather than hand-measured, so the
-- name column's truncation budget always matches the row's real anchors
-- (icon + 3 fixed-size option buttons) without a second copy of those
-- numbers living here.
local BUTTONS_WIDTH = Sizes.row.buttonSize * 3 + Sizes.row.buttonGap * 2;
local MIDDLE_WIDTH = Sizes.window.width - Sizes.row.padX * 2 - Sizes.row.iconSize - Sizes.row.partGap * 2 - BUTTONS_WIDTH;

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

local frame, header, idleBox, moreBar;
local rows = {};

-- Every active rollID, arrival order - the first MAX_VISIBLE_ROWS entries
-- are what's actually shown; the rest wait for a slot to free up.
local order = {};
-- Rebuilt at the top of every render() - only ever holds the rollIDs
-- currently bound to a visible row.
local rollIDToRow = {};
-- Set while a row's close-fade animation is playing, so a second event for
-- the same rollID (e.g. the real CANCEL_LOOT_ROLL arriving after this UI
-- already optimistically closed the row on click) is a no-op instead of a
-- second fade.
local closingRollIDs = {};

local hoveredRow, hoveredButton;

-- Set synchronously by ShowConfirm (called from GroupLootRoll.lua's
-- CONFIRM_LOOT_ROLL handler, itself fired synchronously from inside
-- RollOnLoot per Blizzard's own API docs) so the click handler that just
-- called RollOn can tell, the instant RollOn returns, whether this roll
-- needs confirmation before its row is allowed to close.
local pendingConfirmRollID;
local confirmPopup;

--------------------------------------------------------------------------
-- Forward declarations - everything below is mutually referential (render
-- paints rows, rows' buttons close rows, closing re-renders, etc.)
--------------------------------------------------------------------------

local render, paintRow, closeRow, finishClose, removeFromOrder;
local onOptionClick, onButtonEnter, onButtonLeave, updateOptionButton, showButtonTooltip;
local updateRowTimer, applyTimerVariant, updateTimers;
local truncateToWidth, skinPanel, sizeButtonIcon, buildOptionButton, createGrip, createHeader, createIdle, createMoreBar, createRow;
local ensureFrame, ensureConfirmPopup, reapplyBorders;

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

removeFromOrder = function(rollID)
    for i, id in ipairs(order) do
        if (id == rollID) then table.remove(order, i); return; end
    end
end

-- Shortens `text` (already ellipsis-appended one character at a time) until
-- it fits `maxWidth`, or leaves it alone if it already fits.
truncateToWidth = function(fontString, text, maxWidth)
    fontString:SetText(text);
    if (maxWidth <= 0 or fontString:GetStringWidth() <= maxWidth) then return; end

    local len = #text;
    while (len > 1) do
        len = len - 1;
        fontString:SetText(text:sub(1, len) .. "\226\128\166"); -- "..." (horizontal ellipsis)
        if (fontString:GetStringWidth() <= maxWidth) then return; end
    end
end

-- Solid panel chrome every piece of this stack shares: flat fill+border via
-- Theme.Helpers.SetFlatBackdrop, plus a SoftGlow.tga drop shadow tinted
-- black - same technique UI/RespondWindow.lua's card shadow uses, just
-- without the ADD blend (a plain shadow, not a glow). Called once per panel
-- at creation time only - re-coloring later (e.g. on rescale) goes through
-- SetFlatBackdrop directly so the shadow texture is never recreated.
skinPanel = function(panel, bg, border)
    local shadow = panel:CreateTexture(nil, "BACKGROUND", nil, -1);
    shadow:SetTexture(SOFTGLOW_TEXTURE);
    shadow:SetVertexColor(unpack(Colors.groupLootShadow));
    shadow:SetPoint("TOPLEFT", panel, "TOPLEFT", -Sizes.shadowInset, Sizes.shadowInset);
    shadow:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", Sizes.shadowInset, -Sizes.shadowInset);
    Theme.Helpers.SetFlatBackdrop(panel, bg, border, 1);
end

sizeButtonIcon = function(tex, size, offsetY)
    if (not tex) then return; end
    size = size or Sizes.row.buttonIconSize;
    tex:SetSize(size, size);
    tex:ClearAllPoints();
    tex:SetPoint("CENTER", 0, offsetY or 0);
end

--------------------------------------------------------------------------
-- Option buttons (Need / Greed-or-Transmog / Pass)
--------------------------------------------------------------------------

buildOptionButton = function(row, rollType)
    local button = CreateFrame("Button", nil, row, "BackdropTemplate");
    button:SetSize(Sizes.row.buttonSize, Sizes.row.buttonSize);

    -- Custom hover chrome - separate from Blizzard's own highlight texture
    -- below, only shown (by onButtonEnter) for an enabled button.
    Theme.Helpers.SetFlatBackdrop(button, Colors.groupLootButtonHoverBg, Colors.checkboxBorder, 1);
    button:SetBackdropColor(0, 0, 0, 0);
    button:SetBackdropBorderColor(0, 0, 0, 0);

    if (rollType == ROLL_TRANSMOG) then
        button:SetNormalAtlas(TRANSMOG_ATLASES.up);
        button:SetPushedAtlas(TRANSMOG_ATLASES.down);
        button:SetDisabledAtlas(TRANSMOG_ATLASES.up);
        button:SetHighlightAtlas(TRANSMOG_ATLASES.highlight, "ADD");
    else
        local textures = ROLL_BUTTON_TEXTURES[rollType];
        button:SetNormalTexture(textures.up);
        button:SetPushedTexture(textures.down);
        button:SetDisabledTexture(textures.up);
        button:SetHighlightTexture(textures.up, "ADD");
    end

    -- Pass/Greed get their own size/offset tweaks (Blizzard's Pass art
    -- reads bigger than Need/Greed at the same pixel size and sits low in
    -- its own texture bounds - see Sizes.groupLoot.row); Need/Transmog use
    -- the shared default (nil size, 0 offset).
    local iconSize, iconOffsetY;
    if (rollType == ROLL_PASS) then
        iconSize, iconOffsetY = Sizes.row.passIconSize, Sizes.row.passIconOffsetY;
    elseif (rollType == ROLL_GREED) then
        iconSize, iconOffsetY = Sizes.row.buttonIconSize, Sizes.row.greedIconOffsetY;
    end

    sizeButtonIcon(button:GetNormalTexture(), iconSize, iconOffsetY);
    sizeButtonIcon(button:GetPushedTexture(), iconSize, iconOffsetY);
    sizeButtonIcon(button:GetHighlightTexture(), iconSize, iconOffsetY);
    sizeButtonIcon(button:GetDisabledTexture(), iconSize, iconOffsetY);

    local disabledTexture = button:GetDisabledTexture();
    disabledTexture:SetDesaturated(true);
    disabledTexture:SetAlpha(0.4);

    local countText = button:CreateFontString(nil, "OVERLAY");
    SetFont(countText, "small");
    countText:SetPoint("BOTTOMRIGHT", 0, 0);
    countText:SetTextColor(1, 1, 1);

    button.countText = countText;
    button.rollType = rollType;

    button:SetScript("OnClick", function() onOptionClick(row, rollType); end);
    button:SetScript("OnEnter", function() onButtonEnter(row, button); end);
    button:SetScript("OnLeave", function() onButtonLeave(row, button); end);

    return button;
end

updateOptionButton = function(button, roll, rollType, canUse, reasonCode)
    button.rollType = rollType;
    button.canUse = canUse;
    button.reasonCode = reasonCode;

    local votes = roll.votes[rollType];
    local count = votes and #votes or 0;
    button.countText:SetText(count > 0 and tostring(count) or "");

    if (canUse) then button:Enable(); else button:Disable(); end
end

showButtonTooltip = function(button, roll, rollType, canUse, votes)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT");

    local count = #votes;
    if (canUse or count > 0) then
        local color = OPTION_COLORS[rollType] or Colors.text;
        GameTooltip:AddLine(("%s \194\183 %d"):format(OPTION_LABELS[rollType] or "", count), color[1], color[2], color[3]);
        for _, vote in ipairs(votes) do
            GameTooltip:AddLine(Util.classColoredName(vote.name, vote.classFile));
        end
    end

    if (not canUse) then
        local reasonCode = button.reasonCode;
        local reasonText = reasonCode and _G["LOOT_ROLL_INELIGIBLE_REASON" .. reasonCode];
        if (reasonText) then
            if (count > 0) then GameTooltip:AddLine(" "); end
            GameTooltip:AddLine(reasonText, Colors.sessionDeleteHoverIcon[1], Colors.sessionDeleteHoverIcon[2], Colors.sessionDeleteHoverIcon[3], true);
        end
    end

    GameTooltip:Show();
end

onButtonEnter = function(row, button)
    if (not row.rollID) then return; end
    local roll = GroupLootRoll.ActiveRolls[row.rollID];
    if (not roll) then return; end

    if (button.canUse) then
        button:SetBackdropColor(unpack(Colors.groupLootButtonHoverBg));
        button:SetBackdropBorderColor(unpack(Colors.checkboxBorder));
    end

    local rollType = button.rollType;
    local votes = roll.votes[rollType] or {};

    -- Enabled + no votes yet: no tooltip at all (spec'd rule). A disabled
    -- button always gets one (its ineligible reason).
    if (button.canUse and #votes == 0) then
        hoveredRow, hoveredButton = nil, nil;
        return;
    end

    hoveredRow, hoveredButton = row, button;
    showButtonTooltip(button, roll, rollType, button.canUse, votes);
end

onButtonLeave = function(row, button)
    if (hoveredButton == button) then hoveredRow, hoveredButton = nil, nil; end
    button:SetBackdropColor(0, 0, 0, 0);
    button:SetBackdropBorderColor(0, 0, 0, 0);
    GameTooltip:Hide();
end

onOptionClick = function(row, rollType)
    local rollID = row.rollID;
    if (not rollID) then return; end
    local roll = GroupLootRoll.ActiveRolls[rollID];
    if (not roll) then return; end

    pendingConfirmRollID = nil;
    GroupLootRoll.RollOn(rollID, rollType);

    -- CONFIRM_LOOT_ROLL is documented as firing synchronously from inside
    -- RollOnLoot, so by the time RollOn returns here, ShowConfirm (below)
    -- has already run and shown its popup if this roll needed one - in
    -- that case the row stays exactly as it was; there's nothing to
    -- restore since it was never hidden.
    if (pendingConfirmRollID == rollID) then
        pendingConfirmRollID = nil;
        return;
    end

    closeRow(rollID);
end

--------------------------------------------------------------------------
-- Timer bar
--------------------------------------------------------------------------

-- Colors.groupLootTimerDangerStart -> rollHoverFillEnd for the last-10s
-- state; everything else - the quality-color gradient, the glow's
-- width-scaled alpha, the pulse - is Skin.TimerBar's own job now (see its
-- own header comment in UI/SettingsWindow/Skin.lua), so this window's timer
-- matches UI/RespondWindow.lua's and UI/RollWindow.lua's exactly.
applyTimerVariant = function(row, roll, danger)
    local glow = Sizes.timer.glow;
    if (danger) then
        local to = Colors.rollHoverFillEnd;
        local glowColor = { to[1] * glow.colorScale, to[2] * glow.colorScale, to[3] * glow.colorScale };
        row.timerBar:SetColors(Colors.groupLootTimerDangerStart, to, glow.alphaUrgent, glowColor);
        row.secondsLabel:SetTextColor(unpack(Colors.sessionDeleteHoverIcon));
        row.timerBar:StartPulse();
    else
        row.timerBar:StopPulse();
        local r, g, b = Util.GetItemQualityColor(roll.quality or 1);
        r, g, b = r or 0.616, g or 0.616, b or 0.616;
        -- Poor(0)/Common(1) - a full-strength white/grey ADD glow reads
        -- harsh, so it gets its own lower base alpha.
        local baseAlpha = ((roll.quality or 1) <= 1) and glow.alphaWhite or glow.alpha;
        local glowColor = { r * glow.colorScale, g * glow.colorScale, b * glow.colorScale };
        row.timerBar:SetColors({ r * 0.5, g * 0.5, b * 0.5 }, { r, g, b }, baseAlpha, glowColor);
        row.secondsLabel:SetTextColor(unpack(Colors.muted));
    end
end

-- Stateless paint of one instant (this roll's own elapsed wall-clock time
-- against its own known duration - see below) - called from the container's
-- single shared OnUpdate (updateTimers below), never per-row. `now` is
-- GetTime(), captured ONCE by updateTimers and passed to every row this
-- frame, so all visible rows' sheens land on the exact same phase (see
-- Skin.TimerBar:UpdateSheen).
updateRowTimer = function(row, rollID, now)
    now = now or GetTime(); -- paintRow calls this without `now` (no shared frame clock there)
    local roll = GroupLootRoll.ActiveRolls[rollID];
    if (not roll) then return; end

    -- Computed purely from THIS roll's own startedAt/duration (both set once
    -- at creation in GroupLootRoll.lua's onStartLootRoll and never touched
    -- again) - deliberately NEVER from GetLootRollTimeLeft. That API can
    -- misreport for a roll that never itself changed, the instant a
    -- DIFFERENT roll resolves (the server appears to resolve simultaneous
    -- rolls one at a time, and the client's own bookkeeping hiccups for
    -- every OTHER pending rollID while it does) - and the bad reading can
    -- persist rather than just jitter for a frame, so clamping it (tried
    -- both up-to-full and down-to-empty here previously) still let one roll
    -- ending visibly reset, freeze, or zero out every other row. Plain
    -- wall-clock elapsed time against this roll's own known duration shares
    -- nothing with any other roll's state, so one roll ending can't touch
    -- another's countdown at all.
    --
    -- Rolls are also never cleared from here - only an actual
    -- CANCEL_LOOT_ROLL/CANCEL_ALL_LOOT_ROLLS event (see GroupLootRoll.lua)
    -- ever removes one, same as Blizzard's own default frame
    -- (GroupLootFrame_OnUpdate never removes a roll either, it only ever
    -- repaints its Timer's value) - if that event lags, this row just holds
    -- at empty instead of disappearing or resetting.
    local duration = (roll.duration and roll.duration > 0) and roll.duration or 1;
    local timeLeftMs = duration - (now - roll.startedAt) * 1000;
    if (timeLeftMs < 0) then timeLeftMs = 0; end

    row.timerBar:SetProgress(timeLeftMs, duration);
    row.timerBar:UpdateSheen(now);

    local danger = timeLeftMs <= (Sizes.timer.dangerThreshold * 1000);
    if (danger ~= row.timerDanger) then
        row.timerDanger = danger;
        applyTimerVariant(row, roll, danger);
    end

    local seconds = math.ceil(timeLeftMs / 1000);
    if (row.secondsValue ~= seconds) then
        row.secondsValue = seconds;
        row.secondsLabel:SetText(seconds .. "s");
    end
end

updateTimers = function()
    local now = GetTime();
    for i = 1, MAX_VISIBLE_ROWS do
        local row = rows[i];
        if (row.rollID) then updateRowTimer(row, row.rollID, now); end
    end
end

--------------------------------------------------------------------------
-- Row construction
--------------------------------------------------------------------------

createRow = function()
    local row = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    row:SetHeight(Sizes.row.height);
    skinPanel(row, Colors.groupLootPanelBg, Colors.border);
    row:Hide();

    local iconButton = CreateFrame("Button", nil, row);
    iconButton:SetSize(Sizes.row.iconSize, Sizes.row.iconSize);
    iconButton:SetPoint("LEFT", row, "LEFT", Sizes.row.padX, 0);

    local icon = iconButton:CreateTexture(nil, "ARTWORK");
    icon:SetAllPoints(iconButton);
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    -- 1px-outset border wrapper, same idiom used throughout the addon
    -- (a backdrop border on the icon itself would sit under its own
    -- ARTWORK-layer texture).
    local iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
    iconBorder:SetPoint("TOPLEFT", iconButton, "TOPLEFT", -1, 1);
    iconBorder:SetPoint("BOTTOMRIGHT", iconButton, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(iconBorder, nil, Colors.transparent, Sizes.row.iconBorderThickness);

    iconButton:SetScript("OnEnter", function()
        if (not row.rollID) then return; end
        GameTooltip:SetOwner(iconButton, "ANCHOR_RIGHT");
        GameTooltip:SetLootRollItem(row.rollID);
        GameTooltip:Show();
    end);
    iconButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    -- Buttons anchored right-to-left off the row's own right edge first, so
    -- the middle column below can anchor its own right edge to needButton.
    local passButton = buildOptionButton(row, ROLL_PASS);
    passButton:SetPoint("RIGHT", row, "RIGHT", -Sizes.row.padX, 0);

    local greedButton = buildOptionButton(row, ROLL_GREED);
    greedButton:SetPoint("RIGHT", passButton, "LEFT", -Sizes.row.buttonGap, 0);

    -- Transmog takes Greed's exact slot (the two are never offered
    -- together) - shown/hidden in paintRow.
    local transmogButton = buildOptionButton(row, ROLL_TRANSMOG);
    transmogButton:SetPoint("RIGHT", passButton, "LEFT", -Sizes.row.buttonGap, 0);
    transmogButton:Hide();

    local needButton = buildOptionButton(row, ROLL_NEED);
    needButton:SetPoint("RIGHT", greedButton, "LEFT", -Sizes.row.buttonGap, 0);

    -- Spans the row's own full height (not just the icon's) so the name+bar
    -- block below can be centered against the row's real 38px height, not
    -- a shorter sub-frame.
    local middle = CreateFrame("Frame", nil, row);
    middle:SetPoint("TOPLEFT", row, "TOPLEFT", Sizes.row.padX + Sizes.row.iconSize + Sizes.row.partGap, 0);
    middle:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", Sizes.row.padX + Sizes.row.iconSize + Sizes.row.partGap, 0);
    middle:SetPoint("RIGHT", needButton, "LEFT", -Sizes.row.partGap, 0);

    -- Line 1: name (+ "x<count>"), truncated with an ellipsis, then an
    -- optional bind pill immediately after it. Positioned below, once its
    -- and secondsLabel's real line heights are known.
    local nameText = middle:CreateFontString(nil, "OVERLAY");
    SetFont(nameText, "body");
    nameText:SetJustifyH("LEFT");
    nameText:SetWordWrap(false);

    local pill = CreateFrame("Frame", nil, middle);
    pill:SetHeight(Sizes.row.pillHeight);
    Skin.Pill(pill);
    local pillLabel = pill:CreateFontString(nil, "OVERLAY");
    SetFont(pillLabel, "small");
    pillLabel:SetPoint("CENTER");
    pill.label = pillLabel;
    pill:Hide();

    -- Line 2: timer bar (fills whatever's left) + seconds label. Not a
    -- child of any clipping frame, so it's never cut off.
    local secondsLabel = middle:CreateFontString(nil, "OVERLAY");
    SetFont(secondsLabel, "small");
    secondsLabel:SetJustifyH("RIGHT");
    secondsLabel:SetWordWrap(false);

    -- Measured once off the widest string it can ever show, not a guessed
    -- fixed width - roll durations aren't always under 100s (some rolls run
    -- 3 digits), and a width measured off "60s" native-truncates a 3-digit
    -- value down to "…" (SetWordWrap(false) truncates rather than clipping
    -- raw). "999s" covers up to ~16 minutes, cached onto Sizes so every row
    -- reuses the same measurement.
    if (not Sizes.row.secsWidth) then
        secondsLabel:SetText("999s");
        Sizes.row.secsWidth = secondsLabel:GetStringWidth() + 2;
    end
    secondsLabel:SetWidth(Sizes.row.secsWidth);

    -- Shared with UI/RespondWindow.lua's and UI/RollWindow.lua's own timer
    -- bars (see Skin.TimerBar's own header comment for the fill/glow/pulse
    -- mechanics) - only the track's size/position and its per-roll colors
    -- (see applyTimerVariant) are this window's own.
    local timerBar = Skin.TimerBar(middle, {
        height = Sizes.timer.trackHeight,
        glowPadX = Sizes.timer.glow.padX,
        glowPadY = Sizes.timer.glow.padY,
        pulseDuration = Sizes.timer.pulseDuration,
        -- Slower/narrower than Respond/Roll's 2.5s/40px default - these bars
        -- are short and thin, and a fast full-width sheen reads as
        -- distracting flicker at this size.
        sheenWidth = Sizes.timer.sheenWidth,
        sheenPeriod = Sizes.timer.sheenPeriod,
        sheenAlpha = Sizes.timer.sheenAlpha,
        trackColor = Colors.controlBg,
        trackBorder = Colors.groupLootTrackBorder,
    });

    -- Name+gap+bar-line treated as one block, vertically centered in the
    -- row (name on top, the bar line - track+label - on the bottom). Line
    -- heights come from the fonts themselves (GetLineHeight), not a guessed
    -- constant.
    local nameLineHeight = nameText:GetLineHeight();
    local barLineHeight = math.max(Sizes.timer.trackHeight, secondsLabel:GetLineHeight());
    local blockHeight = nameLineHeight + Sizes.row.lineGap + barLineHeight;
    local barLineCenterY = -blockHeight / 2 + barLineHeight / 2;

    nameText:SetPoint("TOPLEFT", middle, "LEFT", 0, blockHeight / 2);

    -- secondsLabel's own anchor pins the bar line's Y once; the bar's
    -- RIGHT point inherits that same Y by chaining off secondsLabel's LEFT
    -- (rather than re-deriving barLineCenterY a second time), so the two
    -- can never end up a pixel apart vertically.
    secondsLabel:SetPoint("RIGHT", middle, "RIGHT", 0, barLineCenterY);
    timerBar.track:SetPoint("LEFT", middle, "LEFT", 0, barLineCenterY);
    timerBar.track:SetPoint("RIGHT", secondsLabel, "LEFT", -Sizes.row.timerLabelGap, 0);

    -- Close/fade-out animation - plays on click (before the server even
    -- responds) or when the engine reports the roll is over; finishClose
    -- does the actual pool release once it's done.
    local fadeAnim = row:CreateAnimationGroup();
    local fade = fadeAnim:CreateAnimation("Alpha");
    fade:SetFromAlpha(1);
    fade:SetToAlpha(0);
    fade:SetDuration(Sizes.fadeOutDuration);
    fadeAnim:SetScript("OnFinished", function() finishClose(row); end);

    row.iconButton, row.icon, row.iconBorder = iconButton, icon, iconBorder;
    row.middle = middle;
    row.nameText = nameText;
    row.pill = pill;
    row.secondsLabel = secondsLabel;
    row.timerBar = timerBar;
    row.needButton, row.greedButton, row.transmogButton, row.passButton = needButton, greedButton, transmogButton, passButton;
    row.fadeAnim = fadeAnim;

    return row;
end

paintRow = function(row, rollID)
    local roll = GroupLootRoll.ActiveRolls[rollID];
    if (not roll) then
        row:Hide();
        row.rollID = nil;
        return;
    end

    local isNewBinding = row.rollID ~= rollID;
    row.rollID = rollID;
    rollIDToRow[rollID] = row;
    row:Show();

    if (isNewBinding) then
        -- Pooling: a red pulse from the roll that just vacated this slot
        -- must never carry over onto whatever roll takes it next.
        row.timerBar:StopPulse();
        row.timerDanger = nil;
        row.secondsValue = nil;
    end

    row.icon:SetTexture(roll.itemIcon);
    local qr, qg, qb = Util.GetItemQualityColor(roll.quality or 1);
    qr, qg, qb = qr or 0.616, qg or 0.616, qb or 0.616;
    row.iconBorder:SetBackdropBorderColor(qr, qg, qb);

    -- Bind pill: 1 = BoP, 2 = BoE (Enum.ItemBind), anything else (no bind,
    -- quest, BoU) gets no pill. bindType is C_Item.GetItemInfo's 14th
    -- return value.
    local bindType = select(14, Util.GetItemInfo(roll.itemLink));
    local pillLabel;
    if (bindType == 1) then pillLabel = "BoP";
    elseif (bindType == 2) then pillLabel = "BoE";
    end

    local nameMaxWidth = MIDDLE_WIDTH;
    if (pillLabel) then
        row.pill.label:SetText(pillLabel);
        if (pillLabel == "BoP") then
            row.pill:SetPillColor(unpack(Colors.awardWarningBorder));
            row.pill.label:SetTextColor(unpack(Colors.awardWarningIcon));
        else
            row.pill:SetPillColor(unpack(Colors.arrowBoxBorder));
            row.pill.label:SetTextColor(unpack(Colors.description));
        end
        row.pill:SetPillFillColor(unpack(Colors.defaultBg));
        row.pill:SetWidth(Sizes.row.pillPadX * 2 + row.pill.label:GetStringWidth());
        row.pill:Show();
        nameMaxWidth = MIDDLE_WIDTH - Sizes.row.pillGapAfterName - Sizes.row.pillReserveWidth;
    else
        row.pill:Hide();
    end

    local label = roll.itemName or "";
    if (roll.itemCount and roll.itemCount > 1) then label = label .. " x" .. roll.itemCount; end
    truncateToWidth(row.nameText, label, nameMaxWidth);
    row.nameText:SetTextColor(qr, qg, qb);

    if (pillLabel) then
        row.pill:ClearAllPoints();
        row.pill:SetPoint("LEFT", row.nameText, "RIGHT", Sizes.row.pillGapAfterName, 0);
    end

    updateOptionButton(row.needButton, roll, ROLL_NEED, roll.canNeed and true or false, roll.reasonNeed);

    if (roll.canTransmog) then
        row.greedButton:Hide();
        row.transmogButton:Show();
        updateOptionButton(row.transmogButton, roll, ROLL_TRANSMOG, true, nil);
    else
        row.transmogButton:Hide();
        row.greedButton:Show();
        updateOptionButton(row.greedButton, roll, ROLL_GREED, roll.canGreed and true or false, roll.reasonGreed);
    end

    updateOptionButton(row.passButton, roll, ROLL_PASS, true, nil);

    updateRowTimer(row, rollID);

    -- Keep an already-open tooltip on this row's buttons live as votes
    -- change (per-spec: "if a tooltip is open while its list changes,
    -- re-show it with fresh data").
    if (hoveredRow == row and hoveredButton) then
        onButtonEnter(row, hoveredButton);
    end
end

--------------------------------------------------------------------------
-- Close / release flow
--------------------------------------------------------------------------

closeRow = function(rollID)
    if (closingRollIDs[rollID]) then return; end

    local found = false;
    for _, id in ipairs(order) do
        if (id == rollID) then found = true; break; end
    end
    if (not found) then return; end

    local row = rollIDToRow[rollID];
    if (row) then
        closingRollIDs[rollID] = true;
        row.fadeAnim:Stop();
        row.fadeAnim:Play();
    else
        -- Still waiting in the overflow queue - nothing was ever shown for
        -- it, so there's nothing to animate.
        removeFromOrder(rollID);
        render();
    end
end

finishClose = function(row)
    local rollID = row.rollID;
    row:SetAlpha(1);
    if (rollID) then
        closingRollIDs[rollID] = nil;
        removeFromOrder(rollID);
    end
    render();
end

--------------------------------------------------------------------------
-- Header / idle box / more bar
--------------------------------------------------------------------------

local GRIP_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\GripDots";

createGrip = function(parent)
    local grip = parent:CreateTexture(nil, "ARTWORK");
    grip:SetTexture(GRIP_TEXTURE);
    grip:SetSize(Sizes.header.gripSize, Sizes.header.gripSize);
    grip:SetVertexColor(unpack(Colors.disabledText));
    return grip;
end

createHeader = function()
    local h = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    h:SetHeight(Sizes.header.height);
    skinPanel(h, Colors.groupLootPanelBg, Colors.border);

    h:EnableMouse(true);
    h:RegisterForDrag("LeftButton");
    h:SetScript("OnDragStart", function() frame:StartMoving(); end);
    h:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing();
        Pixel.SnapPosition(frame, function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    end);
    h:SetScript("OnEnter", function()
        h.grip:SetVertexColor(unpack(Colors.muted));
        GameTooltip:SetOwner(h, "ANCHOR_RIGHT");
        GameTooltip:AddLine("Drag to move \194\183 lock it in Settings to hide this bar", 1, 1, 1, true);
        GameTooltip:Show();
    end);
    h:SetScript("OnLeave", function()
        h.grip:SetVertexColor(unpack(Colors.disabledText));
        GameTooltip:Hide();
    end);

    local grip = createGrip(h);
    grip:SetPoint("LEFT", h, "LEFT", Sizes.header.gripInset, 0);
    h.grip = grip;

    local title = h:CreateFontString(nil, "OVERLAY");
    SetFont(title, "windowTitle");
    title:SetTextColor(unpack(Colors.titlePurple));
    title:SetText("Group Loot");
    title:SetPoint("LEFT", grip, "RIGHT", Sizes.header.titleGap, 0);

    local count = h:CreateFontString(nil, "OVERLAY");
    SetFont(count, "small");
    count:SetTextColor(unpack(Colors.controlHover));
    count:SetPoint("RIGHT", h, "RIGHT", -Sizes.header.edgeInset, 0);
    h.countText = count;

    return h;
end

createIdle = function()
    local box = CreateFrame("Frame", nil, frame);
    box:SetHeight(Sizes.idle.height);
    Skin.DashedBorder(box, Colors.disabledBorder[1], Colors.disabledBorder[2], Colors.disabledBorder[3], 1);

    local text = box:CreateFontString(nil, "OVERLAY");
    SetFont(text, "body");
    text:SetTextColor(unpack(Colors.disabledText));
    text:SetText("Rolls will appear here");
    text:SetPoint("CENTER");

    return box;
end

createMoreBar = function()
    local bar = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    bar:SetHeight(Sizes.more.height);
    skinPanel(bar, Colors.groupLootMoreBarBg, Colors.disabledBorder);

    local text = bar:CreateFontString(nil, "OVERLAY");
    SetFont(text, "small");
    text:SetTextColor(unpack(Colors.muted));
    text:SetPoint("CENTER");
    bar.text = text;

    return bar;
end

--------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------

render = function()
    if (not frame) then return; end

    local locked = FL.Settings.GetGroupLootRollLocked();
    local total = #order;
    local showHeader = not locked;
    local showIdle = not locked and total == 0;
    local visibleCount = math.min(MAX_VISIBLE_ROWS, total);
    local showMore = total > MAX_VISIBLE_ROWS;

    if (not showHeader and not showIdle and visibleCount == 0 and not showMore) then
        frame:Hide();
        frame:SetScript("OnUpdate", nil);
        return;
    end

    frame:Show();
    wipe(rollIDToRow);

    local previous;
    local height = 0;

    header:SetShown(showHeader);
    if (showHeader) then
        header:ClearAllPoints();
        header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
        header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
        header.countText:SetText(total == 0 and "Unlocked" or (total == 1 and "1 roll" or (total .. " rolls")));
        height = height + Sizes.header.height;
        previous = header;
    end

    idleBox:SetShown(showIdle);
    if (showIdle) then
        idleBox:ClearAllPoints();
        if (previous) then
            idleBox:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -Sizes.pieceGap);
            idleBox:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, -Sizes.pieceGap);
            height = height + Sizes.pieceGap;
        else
            idleBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
            idleBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
        end
        height = height + Sizes.idle.height;
        previous = idleBox;
    end

    for i = 1, MAX_VISIBLE_ROWS do
        local row = rows[i];
        local rollID = order[i];
        if (rollID) then
            row:ClearAllPoints();
            if (previous) then
                row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -Sizes.pieceGap);
                row:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, -Sizes.pieceGap);
                height = height + Sizes.pieceGap;
            else
                row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
                row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
            end
            height = height + Sizes.row.height;
            previous = row;
            paintRow(row, rollID);
        else
            row:Hide();
            row.rollID = nil;
        end
    end

    moreBar:SetShown(showMore);
    if (showMore) then
        moreBar:ClearAllPoints();
        if (previous) then
            moreBar:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -Sizes.pieceGap);
            moreBar:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, -Sizes.pieceGap);
            height = height + Sizes.pieceGap;
        else
            moreBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
            moreBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
        end
        height = height + Sizes.more.height;
        local waiting = total - MAX_VISIBLE_ROWS;
        moreBar.text:SetText(("+%d more roll%s waiting"):format(waiting, waiting == 1 and "" or "s"));
    end

    Pixel.SetHeight(frame, height);
    frame:SetScript("OnUpdate", visibleCount > 0 and updateTimers or nil);
end

--------------------------------------------------------------------------
-- BoP/confirm popup
--------------------------------------------------------------------------

ensureConfirmPopup = function()
    if (confirmPopup) then return; end
    confirmPopup = Skin.ConfirmPopup(frame, { width = 260 });
end

function GroupLootFrame.ShowConfirm(rollID, rollType, confirmReason)
    local roll = GroupLootRoll.ActiveRolls[rollID];
    if (not roll or not frame) then return; end

    pendingConfirmRollID = rollID;
    ensureConfirmPopup();

    local r, g, b = Util.GetItemQualityColor(roll.quality or 1);
    confirmPopup.title:SetText(roll.itemName or "");
    confirmPopup.title:SetTextColor(r or 1, g or 1, b or 1);

    confirmPopup:SetButtons("Cancel", "Roll",
        function()
            GroupLootRoll.ConfirmRoll(rollID, rollType);
            closeRow(rollID);
        end,
        function() end -- cancelled: the row was never hidden, nothing to restore
    );

    confirmPopup:Show(function(dialog, y)
        local body = dialog.confirmBody;
        if (not body) then
            body = dialog:CreateFontString(nil, "OVERLAY");
            SetFont(body, "body");
            body:SetTextColor(unpack(Colors.text));
            body:SetJustifyH("LEFT");
            body:SetJustifyV("TOP");
            body:SetWordWrap(true);
            dialog.confirmBody = body;
        end
        body:ClearAllPoints();
        body:SetPoint("TOPLEFT", dialog, "TOPLEFT", confirmPopup.opts.padding, y);
        body:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -confirmPopup.opts.padding, y);
        body:SetText(confirmReason or "");
        return y - body:GetStringHeight() - confirmPopup.opts.sectionGap;
    end);
end

--------------------------------------------------------------------------
-- Window lifecycle / public API
--------------------------------------------------------------------------

reapplyBorders = function()
    if (not frame) then return; end
    Theme.Helpers.SetFlatBackdrop(header, Colors.groupLootPanelBg, Colors.border, 1);
    Theme.Helpers.SetFlatBackdrop(moreBar, Colors.groupLootMoreBarBg, Colors.disabledBorder, 1);
    for i = 1, MAX_VISIBLE_ROWS do
        Theme.Helpers.SetFlatBackdrop(rows[i], Colors.groupLootPanelBg, Colors.border, 1);
    end
end

ensureFrame = function()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootGroupLootFrame", UIParent);
    frame:Hide();
    frame:SetMovable(true);

    -- Children must exist before Pixel.RegisterWindow below: it invokes
    -- onRescale (reapplyBorders) immediately, and that reads header/moreBar/
    -- rows.
    header = createHeader();
    idleBox = createIdle();
    moreBar = createMoreBar();

    for i = 1, MAX_VISIBLE_ROWS do rows[i] = createRow(); end

    Pixel.RegisterWindow(frame, {
        width = Sizes.window.width,
        height = Sizes.header.height + Sizes.idle.height,
        x = savedPosition and savedPosition.x or 0,
        y = savedPosition and savedPosition.y or 200,
    }, reapplyBorders);

    render();
end

-- Called once from GroupLootRoll.Init() (gated behind the same "replace
-- default popup" setting) so the unlocked header/idle box shows from login,
-- not only after the first roll of the session.
function GroupLootFrame.Init()
    ensureFrame();
end

function GroupLootFrame.Acquire(rollID)
    ensureFrame();
    table.insert(order, rollID);
    render();
end

function GroupLootFrame.Release(rollID)
    if (not frame) then return; end
    closeRow(rollID);
end

function GroupLootFrame.Refresh(rollID)
    if (not frame) then return; end
    local row = rollIDToRow[rollID];
    if (row) then paintRow(row, rollID); end
end

-- Re-applies the locked header/idle box visibility immediately (rather than
-- only the next time a roll starts/ends) - called by
-- UI/SettingsWindow/Pages/LootRolls.lua when the lock checkbox is toggled.
function GroupLootFrame.RefreshLock()
    render();
end

function GroupLootFrame.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
