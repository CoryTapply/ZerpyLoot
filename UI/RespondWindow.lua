--[[
Raider-facing "Respond to Items" window - replaces the old
LootCouncilResponseWindow. Built directly with the settings window's own
control vocabulary (UI.Colors/UI.Sizes.respond/UI.SetFont/UI.Skin), not
FL.Theme - this window has exactly one look, it doesn't follow the active
skin. Response/note send-and-receive logic lives in LootCouncil.lua, not
here - this file only ever reads LootCouncil.CurrentSession and calls
LootCouncil.SubmitResponse.

Layout: an invisible container, no window chrome of its own. Everything on
screen is its own floating card (header, "all sent" card, item cards, the
toggle bar) built by the shared CreateCard() helper below. Item cards and the
toggle bar live inside a ScrollFrame capped at 70% of the screen's height;
the header and "all sent" card sit outside it, always visible.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.respond;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Util = FL.Util;
local Constants = FL.Constants;
local LootCouncil = FL.LootCouncil;
local RespondWindow = FL.UI.RespondWindow;

local FALLBACK_ICON = FL.LootCouncil.FALLBACK_ICON;

local DOT_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Dot";
local SWEEP_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Sweep";
local SOFTGLOW_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\SoftGlow";
local SENT_CHECK_TEXTURE = "Interface\\RaidFrame\\ReadyCheck-Ready";
local SORT_ARROW_TEXTURE = "Interface\\Buttons\\UI-SortArrow";

-- Key this window's saved position is stored under (see
-- Settings.GetWindowPosition/SetWindowPosition). Deliberately not migrated
-- from the old window's "lootCouncilResponseWindow" key - that window was a
-- single boxed panel, this one's a floating card stack, so a carried-over
-- x/y would land oddly.
local POSITION_KEY = "respondWindow";

-- Every item card has the same fixed height, derived from the same Sizes
-- this file paints every card with (icon/name/type row, note box, response
-- button row - see paintCard). Computed once here rather than measured per
-- card each refresh.
local CARD_HEIGHT = Sizes.cardPadding * 2 + Sizes.iconSize + Sizes.cardSectionGap * 2
    + Sizes.noteHeight + Sizes.buttonHeight;

local ALL_SENT_CARD_HEIGHT = Sizes.cardPadding * 2 + Sizes.allSentRowHeight
    + Sizes.timerBarGap + Sizes.timerTrackHeight;

local frame, header, headerCountNumber, allSentCard, timerLabel, timerTrack, timerFill,
    timerGlow, timerSheenClip, timerSheen, scrollFrame, scrollChild, toggleBar,
    toggleSentText, toggleActionText, toggleArrow;

-- Forward-declared here (not down in the "Timer state machine" section below)
-- since createAllSentCard's fade-anim OnFinished closure, defined earlier in
-- this file, needs to close over the real local - not a global - when it
-- resets these on the window finishing its close-out fade.
local timerStart, lastTimerLabelSeconds;

-- cards[item.session] = card frame, built lazily and reused for the
-- lifetime of the addon session - keyed by the item's stable session index
-- (not its current sort position), so a card's note EditBox keeps its
-- in-progress text/focus across the item moving between the pending and
-- sent groups. See ensureCard/paintCard below.
local cards = {};

-- Reset to false every Show() (not persisted) - see RespondWindow.Show().
local toggleExpanded = false;

--------------------------------------------------------------------------
-- Shared card/shadow helper. No such helper exists elsewhere in the addon -
-- every other "new style" window (StartSessionWindow) paints flat 1px-bordered
-- panels by hand with no shadow. This is the one place that look is defined
-- for RespondWindow: a flat #151311@alpha panel, 1px border, and a soft drop
-- shadow (SoftGlow, tinted black @0.5, `shadowInset` px larger on every side,
-- drawn behind it).
--------------------------------------------------------------------------

local function CreateCard(parent, width, bgColor, frameType, borderColor)
    local card = CreateFrame(frameType or "Frame", nil, parent, "BackdropTemplate");
    card:SetWidth(width);
    Theme.Helpers.SetFlatBackdrop(card, bgColor or Colors.respondCardBg, borderColor or Colors.border, 1);

    local shadow = card:CreateTexture(nil, "BACKGROUND", nil, -1);
    shadow:SetTexture(SOFTGLOW_TEXTURE);
    shadow:SetVertexColor(0, 0, 0, 0.5);
    shadow:SetPoint("TOPLEFT", card, "TOPLEFT", -Sizes.shadowInset, Sizes.shadowInset);
    shadow:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", Sizes.shadowInset, -Sizes.shadowInset);
    card.shadow = shadow;

    return card;
end

--- Trims `text` (with a trailing "...") until `fontString` renders it at or
--- under `maxWidth`. WoW FontStrings don't auto-ellipsis, so every window
--- that needs this writes its own version - kept local to this file since
--- nothing else in the addon needs it yet.
local function setTextEllipsized(fontString, text, maxWidth)
    fontString:SetText(text);
    if (fontString:GetStringWidth() <= maxWidth or text == "") then return; end
    while (fontString:GetStringWidth() > maxWidth and #text > 1) do
        text = text:sub(1, -2);
        fontString:SetText(text .. "...");
    end
end

-- Measured once, off-screen: how much width the top row's right-aligned
-- "Sent" indicator (icon + gap + text) actually needs, so a sent card's
-- item name can be truncated to leave room for it without guessing a pixel
-- value.
local SENT_INDICATOR_WIDTH;
do
    local probe = UIParent:CreateFontString(nil, "OVERLAY");
    SetFont(probe, "small");
    probe:SetText("Sent");
    probe:Hide();
    SENT_INDICATOR_WIDTH = Sizes.sentIconSize + Sizes.sentIconGap + probe:GetStringWidth();
end

--------------------------------------------------------------------------
-- Item card content (name/type/quality) - split out from paintCard since it
-- re-runs asynchronously once an uncached item's info actually loads (same
-- ContinueOnItemLoad pattern StartSessionWindow.lua uses).
--------------------------------------------------------------------------

local function nameMaxWidth(isPending)
    local width = Sizes.cardWidth - Sizes.cardPadding * 2 - Sizes.iconSize - Sizes.iconTextGap;
    if (not isPending) then
        width = width - SENT_INDICATOR_WIDTH - Sizes.iconTextGap;
    end
    return width;
end

local function paintCardItemInfo(card, entry)
    local name, _, quality, _, _, itemType, itemSubType, _, equipLoc = Util.GetItemInfo(entry.itemLink);

    if (name) then
        local r, g, b = Util.GetItemQualityColor(quality);
        setTextEllipsized(card.nameText, ("[%s]"):format(name), nameMaxWidth(card.isPending));
        card.nameText:SetTextColor(r or 1, g or 1, b or 1);
        card.iconBorder:SetBackdropBorderColor(r or 0, g or 0, b or 0);

        local slot = (equipLoc and equipLoc ~= "") and _G[equipLoc] or nil;
        local isEquippable = slot ~= nil and slot ~= "";
        card.typeText:SetText(Util.JoinTypeParts(isEquippable and slot or itemType, itemSubType));
    else
        card.nameText:SetText(entry.itemLink);
        card.nameText:SetTextColor(unpack(Colors.text));
        card.typeText:SetText("");
        card.iconBorder:SetBackdropBorderColor(unpack(Colors.transparent));

        local item = Item:CreateFromItemLink(entry.itemLink);
        item:ContinueOnItemLoad(function()
            if (card.entry == entry) then paintCardItemInfo(card, entry); end
        end);
    end
end

--------------------------------------------------------------------------
-- Response buttons
--------------------------------------------------------------------------

-- Centers the dot+label pair as a group (selected buttons show no dot, just
-- a centered label) - the pair's combined width depends on the label's own
-- rendered width, so this has to run after the label text is set.
local function layoutButtonContent(btn, showDot)
    btn.label:ClearAllPoints();
    if (showDot) then
        btn.dot:Show();
        local totalWidth = Sizes.buttonDotSize + Sizes.buttonDotLabelGap + btn.label:GetStringWidth();
        btn.dot:ClearAllPoints();
        btn.dot:SetPoint("LEFT", btn, "CENTER", -totalWidth / 2, 0);
        btn.label:SetPoint("LEFT", btn.dot, "RIGHT", Sizes.buttonDotLabelGap, 0);
    else
        btn.dot:Hide();
        btn.label:SetPoint("CENTER", btn, "CENTER", 0, 0);
    end
end

local function createResponseButton(card)
    local btn = CreateFrame("Button", nil, card, "BackdropTemplate");
    btn:SetHeight(Sizes.buttonHeight);

    btn.dot = btn:CreateTexture(nil, "ARTWORK");
    btn.dot:SetSize(Sizes.buttonDotSize, Sizes.buttonDotSize);
    btn.dot:SetTexture(DOT_TEXTURE);

    btn.label = btn:CreateFontString(nil, "OVERLAY");
    SetFont(btn.label, "body");

    -- Polled rather than OnEnter/OnLeave: clicking a response button reflows
    -- the whole card stack (see RespondWindow.Refresh), which can slide a
    -- different card's button under a mouse that never actually moved -
    -- WoW won't refire OnEnter for that, so the highlight would go stale.
    -- Edge-triggered on self.isHovered so it's a no-op most frames; paintCard
    -- resets that cache on every repaint so a post-reflow (or post-repaint)
    -- mismatch gets corrected on the very next tick.
    btn:SetScript("OnUpdate", function(self)
        if (not self.hoverColor or not self.baseBorder) then return; end
        local isHovered = Util.IsMouseOverVisible(self, scrollFrame);
        if (isHovered ~= self.isHovered) then
            self.isHovered = isHovered;
            self:SetBackdropBorderColor(unpack(isHovered and self.hoverColor or self.baseBorder));
        end
    end);

    btn:SetScript("OnClick", function(self)
        local card = self:GetParent();
        local entry = card.entry;
        if (not entry or entry.awardedTo) then return; end

        local myName = Util.stripRealm(Util.UnitName("player"));
        local candidate = entry.candidates[myName];
        if (candidate and candidate.response == self.responseId) then return; end -- already selected, no-op

        local wasPending = candidate == nil;
        LootCouncil.SubmitResponse(entry.session, self.responseId, card.noteBox:GetText());

        if (wasPending) then
            RespondWindow.PlayToggleBarPulse();
        else
            RespondWindow.PlaySendSweep(card);
        end
        RespondWindow.RefreshTimerState();
    end);

    return btn;
end

--------------------------------------------------------------------------
-- Note box - built by hand rather than via Skin.EditBox, which bakes in the
-- "search" font role, a different inset/border color, and an OnEscapePressed
-- hook that wipes the text (this spec wants Escape to only clear focus).
--------------------------------------------------------------------------

local function updateNotePlaceholder(noteBox)
    noteBox.placeholderText:SetShown(noteBox:GetText() == "" and not noteBox:HasFocus());
end

local function createNoteBox(card)
    local noteBox = CreateFrame("EditBox", nil, card, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(noteBox, Colors.controlBg, Colors.respondBorderMuted, 1);
    SetFont(noteBox, "body");
    noteBox:SetTextColor(unpack(Colors.textBright));
    noteBox:SetTextInsets(Sizes.noteTextInset, Sizes.noteTextInset, 0, 0);
    noteBox:SetAutoFocus(false);
    noteBox:SetMaxLetters(80);
    noteBox:SetHeight(Sizes.noteHeight);

    noteBox.placeholderText = noteBox:CreateFontString(nil, "OVERLAY");
    SetFont(noteBox.placeholderText, "body");
    noteBox.placeholderText:SetTextColor(unpack(Colors.respondNotePlaceholder));
    noteBox.placeholderText:SetPoint("LEFT", noteBox, "LEFT", Sizes.noteTextInset, 0);
    noteBox.placeholderText:SetJustifyH("LEFT");
    noteBox.placeholderText:SetText("Add a note (optional)");

    noteBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); end);
    noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);
    noteBox:SetScript("OnTextChanged", updateNotePlaceholder);

    noteBox:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(Colors.controlFocus));
        self.textAtFocus = self:GetText();
        RespondWindow.RefreshTimerState();
    end);
    noteBox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(Colors.respondBorderMuted));
        updateNotePlaceholder(self);

        local card = self:GetParent();
        local entry = card.entry;
        if (entry and not card.isPending and self:GetText() ~= self.textAtFocus) then
            local myName = Util.stripRealm(Util.UnitName("player"));
            local candidate = entry.candidates[myName];
            if (candidate) then
                LootCouncil.SubmitResponse(entry.session, candidate.response, self:GetText());
                RespondWindow.PlaySendSweep(card);
            end
        end
        RespondWindow.RefreshTimerState();
    end);

    return noteBox;
end

--------------------------------------------------------------------------
-- Item card construction/pooling
--------------------------------------------------------------------------

local function createCard(parent)
    local card = CreateCard(parent, Sizes.cardWidth);
    card:SetHeight(CARD_HEIGHT);
    card:SetClipsChildren(true);
    card:Hide();

    -- Top row: icon + quality border, name/type text, sent indicator.
    card.icon = card:CreateTexture(nil, "ARTWORK");
    card.icon:SetSize(Sizes.iconSize, Sizes.iconSize);
    card.icon:SetPoint("TOPLEFT", card, "TOPLEFT", Sizes.cardPadding, -Sizes.cardPadding);
    card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    card.iconBorder = CreateFrame("Frame", nil, card, "BackdropTemplate");
    card.iconBorder:SetPoint("TOPLEFT", card.icon, "TOPLEFT", -1, 1);
    card.iconBorder:SetPoint("BOTTOMRIGHT", card.icon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(card.iconBorder, nil, Colors.transparent, 1);

    card.iconButton = CreateFrame("Button", nil, card);
    card.iconButton:SetAllPoints(card.icon);
    card.iconButton:RegisterForClicks("LeftButtonUp");
    card.iconButton:SetScript("OnClick", function(self)
        local parentCard = self:GetParent();
        if (parentCard.entry) then Util.HandleItemLinkClick(parentCard.entry.itemLink); end
    end);

    card.nameText = card:CreateFontString(nil, "OVERLAY");
    SetFont(card.nameText, "sectionHeader");
    card.nameText:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", Sizes.iconTextGap, 0);
    card.nameText:SetJustifyH("LEFT");
    card.nameText:SetWordWrap(false);

    card.typeText = card:CreateFontString(nil, "OVERLAY");
    SetFont(card.typeText, "small");
    card.typeText:SetTextColor(unpack(Colors.muted));
    card.typeText:SetPoint("TOPLEFT", card.nameText, "BOTTOMLEFT", 0, -Sizes.nameTypeGap);
    card.typeText:SetJustifyH("LEFT");
    card.typeText:SetWordWrap(false);

    card.sentIcon = card:CreateTexture(nil, "ARTWORK");
    card.sentIcon:SetSize(Sizes.sentIconSize, Sizes.sentIconSize);
    card.sentIcon:SetTexture(SENT_CHECK_TEXTURE);
    card.sentIcon:SetPoint("TOPRIGHT", card, "TOPRIGHT", -Sizes.cardPadding, -Sizes.cardPadding);

    card.sentLabel = card:CreateFontString(nil, "OVERLAY");
    SetFont(card.sentLabel, "small");
    card.sentLabel:SetTextColor(unpack(Colors.respondSentLabel));
    card.sentLabel:SetText("Sent");
    card.sentLabel:SetPoint("RIGHT", card.sentIcon, "LEFT", -Sizes.sentIconGap, 0);

    -- Tooltip - only over the icon itself, not the whole card. A card
    -- scrolled out of view still occupies its rect for a bare IsMouseOver
    -- check, so this polls Util.IsMouseOverVisible the same way
    -- StartSessionWindow's rows do.
    card:SetScript("OnUpdate", function(self)
        if (self.entry and Util.IsMouseOverVisible(self.icon, scrollFrame)) then
            GameTooltip:SetOwner(self.icon, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink(self.entry.itemLink);
            GameTooltip:Show();
        elseif (GameTooltip:GetOwner() == self.icon) then
            GameTooltip:Hide();
        end
    end);

    -- Note box.
    card.noteBox = createNoteBox(card);
    card.noteBox:SetPoint("TOPLEFT", card, "TOPLEFT", Sizes.cardPadding, -(Sizes.cardPadding + Sizes.iconSize + Sizes.cardSectionGap));
    card.noteBox:SetPoint("TOPRIGHT", card, "TOPRIGHT", -Sizes.cardPadding, -(Sizes.cardPadding + Sizes.iconSize + Sizes.cardSectionGap));

    -- Response buttons, pooled to the largest option list this window
    -- supports (Sizes.maxResponseButtons) - extras hidden when
    -- Constants.LOOT_COUNCIL_RESPONSES has fewer entries.
    card.buttons = {};
    for i = 1, Sizes.maxResponseButtons do
        card.buttons[i] = createResponseButton(card);
    end

    -- Send sweep (gold light sweeping across the card + a gold border flash)
    -- - played whenever a sent card's response or note changes.
    card.sweep = card:CreateTexture(nil, "OVERLAY");
    card.sweep:SetTexture(SWEEP_TEXTURE);
    card.sweep:SetVertexColor(Colors.gold[1], Colors.gold[2], Colors.gold[3], Sizes.sweepAlpha);
    card.sweep:SetBlendMode("ADD");
    card.sweep:SetSize(Sizes.cardWidth * Sizes.sweepWidthPct, CARD_HEIGHT);
    card.sweep:Hide();

    card.sweepAnim = card.sweep:CreateAnimationGroup();
    local sweepMove = card.sweepAnim:CreateAnimation("Translation");
    sweepMove:SetOffset(Sizes.cardWidth + card.sweep:GetWidth(), 0);
    sweepMove:SetDuration(Sizes.sweepDuration);
    sweepMove:SetSmoothing("OUT");
    card.sweepAnim:SetScript("OnPlay", function()
        card.sweep:Show();
        card.sweep:ClearAllPoints();
        card.sweep:SetPoint("TOPLEFT", card, "TOPLEFT", -card.sweep:GetWidth(), 0);
    end);
    card.sweepAnim:SetScript("OnFinished", function() card.sweep:Hide(); end);

    card.flashBorder = CreateFrame("Frame", nil, card, "BackdropTemplate");
    card.flashBorder:SetAllPoints(card);
    Theme.Helpers.SetFlatBackdrop(card.flashBorder, nil, Colors.gold, 1);
    card.flashBorder:SetAlpha(0);

    card.flashAnim = card.flashBorder:CreateAnimationGroup();
    local flashFade = card.flashAnim:CreateAnimation("Alpha");
    flashFade:SetFromAlpha(1);
    flashFade:SetToAlpha(0);
    flashFade:SetDuration(Sizes.borderFlashDuration);

    return card;
end

function RespondWindow.PlaySendSweep(card)
    card.sweepAnim:Stop();
    card.sweepAnim:Play();
    card.flashAnim:Stop();
    card.flashAnim:Play();
end

local function ensureCard(sessionIndex)
    if (cards[sessionIndex]) then return cards[sessionIndex]; end
    local card = createCard(scrollChild);
    cards[sessionIndex] = card;
    return card;
end

local function paintCard(card, entry, isPending, myName)
    card.entry = entry;
    card.isPending = isPending;

    card.icon:SetTexture(entry.itemIcon or FALLBACK_ICON);
    paintCardItemInfo(card, entry);

    card.sentIcon:SetShown(not isPending);
    card.sentLabel:SetShown(not isPending);

    local candidate = entry.candidates[myName];

    -- Note text is only ever (re)set the first time THIS card renders data
    -- for the current session - never on a later refresh, so an in-progress
    -- unsent note is never clobbered by an unrelated event.
    local Session = LootCouncil.CurrentSession;
    if (card.paintedSessionId ~= Session.id) then
        card.noteBox:SetText(candidate and candidate.note or "");
        card.noteBox.textAtFocus = card.noteBox:GetText();
        updateNotePlaceholder(card.noteBox);
        card.paintedSessionId = Session.id;
    end

    local responses = Constants.LOOT_COUNCIL_RESPONSES;
    local n = math.max(#responses, 1);
    local buttonWidth = (Sizes.cardWidth - Sizes.cardPadding * 2 - (n - 1) * Sizes.buttonGap) / n;
    local buttonsTop = Sizes.cardPadding + Sizes.iconSize + Sizes.cardSectionGap + Sizes.noteHeight + Sizes.cardSectionGap;

    for i = 1, Sizes.maxResponseButtons do
        local btn = card.buttons[i];
        local optionEntry = responses[i];
        if (optionEntry) then
            local colorEntry = Colors.responses[optionEntry.id] or Colors.responses.default;
            btn.responseId = optionEntry.id;
            btn:SetWidth(buttonWidth);
            btn:ClearAllPoints();
            if (i == 1) then
                btn:SetPoint("TOPLEFT", card, "TOPLEFT", Sizes.cardPadding, -buttonsTop);
            else
                btn:SetPoint("LEFT", card.buttons[i - 1], "RIGHT", Sizes.buttonGap, 0);
                btn:SetPoint("TOP", card.buttons[i - 1], "TOP", 0, 0);
            end
            btn.label:SetText(optionEntry.label);
            btn.hoverColor = colorEntry.color;

            local isSelected = candidate and candidate.response == optionEntry.id;
            if (isSelected) then
                Theme.Helpers.SetFlatBackdrop(btn, colorEntry.color, colorEntry.color, 1);
                btn.label:SetTextColor(1, 1, 1);
                btn.baseBorder = colorEntry.color;
                layoutButtonContent(btn, false);
            else
                Theme.Helpers.SetFlatBackdrop(btn, Colors.defaultBg, Colors.respondButtonBorder, 1);
                btn.label:SetTextColor(unpack(isPending and Colors.respondLabel or Colors.muted));
                btn.dot:SetVertexColor(colorEntry.color[1], colorEntry.color[2], colorEntry.color[3], isPending and 1 or 0.55);
                btn.baseBorder = Colors.respondButtonBorder;
                layoutButtonContent(btn, true);
            end
            btn.isHovered = nil;
            btn:Show();
        else
            btn:Hide();
        end
    end
end

--------------------------------------------------------------------------
-- Toggle bar ("N sent - Click to change")
--------------------------------------------------------------------------

local function createToggleBar(parent)
    local bar = CreateCard(parent, Sizes.cardWidth, Colors.respondToggleBarBg, "Button", Colors.respondBorderMuted);
    bar:SetHeight(Sizes.toggleBarHeight);
    bar:RegisterForClicks("LeftButtonUp");

    bar:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(Colors.controlHover)); end);
    bar:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(Colors.respondBorderMuted)); end);

    local check = bar:CreateTexture(nil, "ARTWORK");
    check:SetSize(Sizes.sentIconSize, Sizes.sentIconSize);
    check:SetTexture(SENT_CHECK_TEXTURE);

    toggleSentText = bar:CreateFontString(nil, "OVERLAY");
    SetFont(toggleSentText, "body");
    toggleSentText:SetTextColor(unpack(Colors.description));

    local dotSeparator = bar:CreateFontString(nil, "OVERLAY");
    SetFont(dotSeparator, "body");
    dotSeparator:SetTextColor(unpack(Colors.description));
    dotSeparator:SetText("\194\183");

    toggleActionText = bar:CreateFontString(nil, "OVERLAY");
    SetFont(toggleActionText, "body");
    toggleActionText:SetTextColor(unpack(Colors.description));

    toggleArrow = bar:CreateTexture(nil, "ARTWORK");
    toggleArrow:SetSize(Sizes.toggleArrowSize, Sizes.toggleArrowSize);
    toggleArrow:SetTexture(SORT_ARROW_TEXTURE);
    toggleArrow:SetVertexColor(unpack(Colors.gold));

    bar.check = check;

    -- Pulse (gold border flash + expanding glow halo) played whenever a
    -- pending item is answered.
    bar.pulseBorder = CreateFrame("Frame", nil, bar, "BackdropTemplate");
    bar.pulseBorder:SetAllPoints(bar);
    Theme.Helpers.SetFlatBackdrop(bar.pulseBorder, nil, Colors.gold, 1);
    bar.pulseBorder:SetAlpha(0);

    bar.pulseGlow = bar:CreateTexture(nil, "OVERLAY", nil, -1);
    bar.pulseGlow:SetTexture(SOFTGLOW_TEXTURE);
    bar.pulseGlow:SetBlendMode("ADD");
    bar.pulseGlow:SetVertexColor(Colors.gold[1], Colors.gold[2], Colors.gold[3], Sizes.togglePulseGlowAlphaFrom);
    bar.pulseGlow:SetPoint("TOPLEFT", bar, "TOPLEFT", -Sizes.togglePulseGlowInset, Sizes.togglePulseGlowInset);
    bar.pulseGlow:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", Sizes.togglePulseGlowInset, -Sizes.togglePulseGlowInset);
    bar.pulseGlow:SetAlpha(0);

    bar.pulseBorderAnim = bar.pulseBorder:CreateAnimationGroup();
    local borderFade = bar.pulseBorderAnim:CreateAnimation("Alpha");
    borderFade:SetFromAlpha(1);
    borderFade:SetToAlpha(0);
    borderFade:SetDuration(Sizes.togglePulseBorderDuration);

    bar.pulseGlowAnim = bar.pulseGlow:CreateAnimationGroup();
    local glowFade = bar.pulseGlowAnim:CreateAnimation("Alpha");
    glowFade:SetFromAlpha(Sizes.togglePulseGlowAlphaFrom);
    glowFade:SetToAlpha(0);
    glowFade:SetDuration(Sizes.togglePulseBorderDuration);
    local glowGrow = bar.pulseGlowAnim:CreateAnimation("Scale");
    glowGrow:SetScale(Sizes.togglePulseGlowScaleTo / Sizes.togglePulseGlowScaleFrom, Sizes.togglePulseGlowScaleTo / Sizes.togglePulseGlowScaleFrom);
    glowGrow:SetOrigin("CENTER", 0, 0);
    glowGrow:SetDuration(Sizes.togglePulseBorderDuration);

    -- Segments are laid out and re-centered in layoutToggleBar (below) since
    -- both the sent-count digits and the "Click to change"/"Hide" label
    -- change width at runtime.
    bar.segments = { check, toggleSentText, dotSeparator, toggleActionText, toggleArrow };

    bar:SetScript("OnClick", function()
        toggleExpanded = not toggleExpanded;
        RespondWindow.Refresh();
    end);

    return bar;
end

function RespondWindow.PlayToggleBarPulse()
    toggleBar.pulseBorderAnim:Stop();
    toggleBar.pulseBorderAnim:Play();
    toggleBar.pulseGlowAnim:Stop();
    toggleBar.pulseGlowAnim:Play();
end

local function layoutToggleBar(sentCount)
    toggleSentText:SetText(("%d sent"):format(sentCount));
    toggleActionText:SetText(toggleExpanded and "Hide" or "Click to change");
    toggleArrow:SetTexCoord(0, 1, toggleExpanded and 1 or 0, toggleExpanded and 0 or 1);

    local check, sentText, dotSeparator, actionText, arrow = unpack(toggleBar.segments);
    local widths = {
        Sizes.sentIconSize, sentText:GetStringWidth(), dotSeparator:GetStringWidth(),
        actionText:GetStringWidth(), Sizes.toggleArrowSize,
    };
    local totalWidth = 0;
    for i, w in ipairs(widths) do
        totalWidth = totalWidth + w + (i > 1 and Sizes.toggleSegmentGap or 0);
    end

    local x = -totalWidth / 2;
    for i, segment in ipairs(toggleBar.segments) do
        segment:ClearAllPoints();
        segment:SetPoint("LEFT", toggleBar, "CENTER", x, 0);
        x = x + widths[i] + Sizes.toggleSegmentGap;
    end
end

--------------------------------------------------------------------------
-- "All responses sent" card + countdown timer
--------------------------------------------------------------------------

local function createAllSentCard(parent)
    local card = CreateCard(parent, Sizes.cardWidth);
    card:SetHeight(ALL_SENT_CARD_HEIGHT);
    card:Hide();

    local row = CreateFrame("Frame", nil, card);
    row:SetPoint("TOPLEFT", card, "TOPLEFT", Sizes.cardPadding, -Sizes.cardPadding);
    row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -Sizes.cardPadding, -Sizes.cardPadding);
    row:SetHeight(Sizes.allSentRowHeight);

    local check = row:CreateTexture(nil, "ARTWORK");
    check:SetSize(Sizes.allSentIconSize, Sizes.allSentIconSize);
    check:SetPoint("LEFT", row, "LEFT", 0, 0);
    check:SetTexture(SENT_CHECK_TEXTURE);

    local title = row:CreateFontString(nil, "OVERLAY");
    SetFont(title, "sectionHeader");
    title:SetTextColor(unpack(Colors.gold));
    title:SetPoint("LEFT", check, "RIGHT", Sizes.sentIconGap, 0);
    title:SetText("All responses sent");

    timerLabel = row:CreateFontString(nil, "OVERLAY");
    SetFont(timerLabel, "small");
    timerLabel:SetTextColor(unpack(Colors.muted));
    timerLabel:SetJustifyH("RIGHT");
    timerLabel:SetPoint("RIGHT", row, "RIGHT", 0, 0);

    timerTrack = CreateFrame("Frame", nil, card, "BackdropTemplate");
    timerTrack:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -Sizes.timerBarGap);
    timerTrack:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -Sizes.timerBarGap);
    timerTrack:SetHeight(Sizes.timerTrackHeight);
    Theme.Helpers.SetFlatBackdrop(timerTrack, Colors.controlBg, Colors.respondTimerTrackBorder, 1);

    timerFill = timerTrack:CreateTexture(nil, "ARTWORK");
    timerFill:SetTexture(Theme.Helpers.FLAT_TEXTURE);
    timerFill:SetPoint("TOPLEFT", timerTrack, "TOPLEFT", 0, 0);
    timerFill:SetPoint("BOTTOMLEFT", timerTrack, "BOTTOMLEFT", 0, 0);
    timerFill:SetWidth(1);

    timerGlow = timerTrack:CreateTexture(nil, "BACKGROUND", nil, -1);
    timerGlow:SetTexture(SOFTGLOW_TEXTURE);
    timerGlow:SetBlendMode("ADD");
    timerGlow:SetVertexColor(Colors.gold[1], Colors.gold[2], Colors.gold[3], 0.55);
    timerGlow:SetPoint("TOPLEFT", timerFill, "TOPLEFT", -Sizes.timerGlowInsetX, Sizes.timerGlowInsetY);
    timerGlow:SetPoint("BOTTOMRIGHT", timerFill, "BOTTOMRIGHT", Sizes.timerGlowInsetX, -Sizes.timerGlowInsetY);

    timerSheenClip = CreateFrame("Frame", nil, timerTrack);
    timerSheenClip:SetClipsChildren(true);
    timerSheenClip:SetAllPoints(timerFill);

    timerSheen = timerSheenClip:CreateTexture(nil, "OVERLAY");
    timerSheen:SetTexture(SWEEP_TEXTURE);
    timerSheen:SetSize(Sizes.timerSheenWidth, Sizes.timerTrackHeight);
    timerSheen:SetVertexColor(1, 1, 1, 0.6);
    timerSheen:SetBlendMode("ADD");
    timerSheen:SetPoint("LEFT", timerSheenClip, "LEFT", 0, 0);

    -- Fade-out (closing state) - plays on the whole window container, not
    -- just this card, since the entire stack disappears together.
    frame.fadeAnim = frame:CreateAnimationGroup();
    local fade = frame.fadeAnim:CreateAnimation("Alpha");
    fade:SetFromAlpha(1);
    fade:SetToAlpha(0);
    fade:SetDuration(Sizes.fadeOutDuration);
    frame.fadeAnim:SetScript("OnFinished", function()
        frame:Hide();
        frame:SetAlpha(1);
        RespondWindow.timerState = "off";
        timerStart = nil;
    end);

    return card;
end

--------------------------------------------------------------------------
-- Timer state machine
--------------------------------------------------------------------------

RespondWindow.timerState = "off";

local function onTimerUpdate()
    local remaining = Sizes.autoCloseSeconds - (GetTime() - timerStart);
    if (remaining <= 0) then
        RespondWindow.EnterTimerClosing();
        return;
    end

    local trackWidth = timerTrack:GetWidth();
    local width = math.max(trackWidth * (remaining / Sizes.autoCloseSeconds), 0.01);
    timerFill:SetWidth(width);
    timerFill:SetShown(width >= 1);
    timerGlow:SetShown(width >= 1);

    local fillWidth = timerFill:GetWidth();
    local sheenX = ((GetTime() * Sizes.timerSheenSpeedPxPerSec) % (fillWidth + Sizes.timerSheenWidth)) - Sizes.timerSheenWidth;
    timerSheen:ClearAllPoints();
    timerSheen:SetPoint("LEFT", timerSheenClip, "LEFT", sheenX, 0);

    local seconds = math.max(math.ceil(remaining), 1);
    if (seconds ~= lastTimerLabelSeconds) then
        lastTimerLabelSeconds = seconds;
        timerLabel:SetText(("Closing in %ds"):format(seconds));
    end
end

local function stopTimerUpdate()
    allSentCard:SetScript("OnUpdate", nil);
end

local function paintPausedTimer()
    timerFill:Show();
    timerFill:SetWidth(timerTrack:GetWidth());
    timerFill:SetVertexColor(Colors.respondTimerPausedFill[1], Colors.respondTimerPausedFill[2], Colors.respondTimerPausedFill[3], 1);
    timerGlow:Hide();
    timerSheenClip:Hide();
    timerLabel:SetText("Timer paused while you make changes");
end

local function paintRunningTimer()
    -- SetGradient fully overwrites per-vertex color regardless of any prior
    -- SetVertexColor call (the paused look uses one), so no reset is needed
    -- here first.
    timerFill:SetGradient("HORIZONTAL", CreateColor(unpack(Colors.controlFocus)), CreateColor(unpack(Colors.gold)));
    timerSheenClip:Show();
    lastTimerLabelSeconds = nil;
end

local function enterOff()
    if (RespondWindow.timerState == "closing") then
        frame.fadeAnim:Stop();
        frame:SetAlpha(1);
    end
    RespondWindow.timerState = "off";
    timerStart = nil;
    stopTimerUpdate();
    allSentCard:Hide();
end

local function enterRunning()
    RespondWindow.timerState = "running";
    timerStart = GetTime();
    allSentCard:Show();
    paintRunningTimer();
    allSentCard:SetScript("OnUpdate", onTimerUpdate);
end

local function enterPaused()
    RespondWindow.timerState = "paused";
    timerStart = nil;
    stopTimerUpdate();
    allSentCard:Show();
    paintPausedTimer();
end

function RespondWindow.EnterTimerClosing()
    RespondWindow.timerState = "closing";
    stopTimerUpdate();
    frame.fadeAnim:Stop();
    frame.fadeAnim:Play();
end

--- Stops everything and hides the window immediately, no fade - used by the
--- close button and by Hide().
local function stopTimerHard()
    stopTimerUpdate();
    if (frame.fadeAnim) then frame.fadeAnim:Stop(); end
    frame:SetAlpha(1);
    RespondWindow.timerState = "off";
    timerStart = nil;
end

local function anyNoteBoxFocused()
    for _, card in pairs(cards) do
        if (card.entry and card.noteBox:HasFocus()) then return true; end
    end
    return false;
end

--- Run after every change that could affect the timer (response click,
--- toggle open/close, note focus gained/lost, items added/removed, window
--- shown) - see the state table in the design spec this window implements.
function RespondWindow.RefreshTimerState()
    if (not frame or not frame:IsShown()) then return; end

    local Session = LootCouncil.CurrentSession;
    local pendingCount = 0;
    if (Session) then
        local myName = Util.stripRealm(Util.UnitName("player"));
        for _, item in ipairs(Session.items) do
            if (not item.candidates[myName]) then pendingCount = pendingCount + 1; end
        end
    end

    if (pendingCount > 0) then
        if (RespondWindow.timerState ~= "off") then enterOff(); end
        return;
    end

    local state = RespondWindow.timerState;
    if (state == "off") then
        if (not toggleExpanded and not anyNoteBoxFocused()) then enterRunning(); else enterPaused(); end
    elseif (state == "running") then
        if (toggleExpanded or anyNoteBoxFocused()) then enterPaused(); end
    elseif (state == "paused") then
        if (not toggleExpanded and not anyNoteBoxFocused()) then enterRunning(); end
    end
    -- state == "closing": only exits via the fade AnimationGroup's
    -- OnFinished, or via the pendingCount>0 branch above.
end

--------------------------------------------------------------------------
-- Header
--------------------------------------------------------------------------

local function createHeader()
    header = CreateCard(frame, Sizes.cardWidth);
    header:SetHeight(Sizes.headerHeight);
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);

    header:EnableMouse(true);
    header:RegisterForDrag("LeftButton");
    header:SetScript("OnDragStart", function() frame:StartMoving(); end);
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing();
        Pixel.SnapPosition(frame, function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    end);

    local title = header:CreateFontString(nil, "OVERLAY");
    SetFont(title, "windowTitle");
    title:SetTextColor(unpack(Colors.titlePurple));
    title:SetPoint("LEFT", header, "LEFT", Sizes.cardPadding, 0);
    title:SetText("ForeverLoot Council");

    local subtitle = header:CreateFontString(nil, "OVERLAY");
    SetFont(subtitle, "body");
    subtitle:SetTextColor(unpack(Colors.muted));
    subtitle:SetPoint("LEFT", title, "RIGHT", Sizes.headerTitleGap, 0);
    subtitle:SetText("Respond");

    local closeButton = CreateFrame("Button", nil, header, "BackdropTemplate");
    closeButton:SetPoint("RIGHT", header, "RIGHT", -Sizes.cardPadding, 0);
    Skin.CloseButton(closeButton);
    closeButton:SetSize(Sizes.headerCloseSize, Sizes.headerCloseSize); -- override Skin.CloseButton's shared 20px default
    closeButton:SetScript("OnClick", function()
        stopTimerHard();
        frame:Hide();
    end);

    local countLabel = header:CreateFontString(nil, "OVERLAY");
    SetFont(countLabel, "body");
    countLabel:SetTextColor(unpack(Colors.description));
    countLabel:SetText(" left");
    countLabel:SetPoint("RIGHT", closeButton, "LEFT", -Sizes.headerTitleGap, 0);

    headerCountNumber = header:CreateFontString(nil, "OVERLAY");
    SetFont(headerCountNumber, "body");
    headerCountNumber:SetTextColor(unpack(Colors.gold));
    headerCountNumber:SetPoint("RIGHT", countLabel, "LEFT", 0, 0);
end

--------------------------------------------------------------------------
-- Window lifecycle
--------------------------------------------------------------------------

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootRespondWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    -- No SetFlatBackdrop - the root container itself is invisible; only its
    -- child cards are visible. Not added to UISpecialFrames (Escape must not
    -- close it) and never clamped to the screen (nothing in Pixel.* clamps).

    Pixel.RegisterWindow(frame, {
        width = Sizes.cardWidth, height = Sizes.headerHeight,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, nil);

    createHeader();

    allSentCard = createAllSentCard(frame);
    allSentCard:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -Sizes.stackSpacing);
    allSentCard:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -Sizes.stackSpacing);

    -- No template (in particular, not UIPanelScrollFrameTemplate) - that
    -- template brings its own ScrollBar child with a built-in
    -- OnScrollRangeChanged handler (bound in its XML, independent of
    -- anything this file does) that re-shows the bar itself whenever the
    -- scroll range changes, so a one-time :Hide() call doesn't stick. A bare
    -- ScrollFrame has no scrollbar object at all to fight - the card stack
    -- only ever scrolls via mouse wheel (EnableSmoothScroll below), which
    -- doesn't need one.
    scrollFrame = CreateFrame("ScrollFrame", "ForeverLootRespondWindowScroll", frame);
    scrollFrame:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -Sizes.stackSpacing);
    scrollFrame:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -Sizes.stackSpacing);
    scrollFrame:SetHeight(1);

    scrollChild = CreateFrame("Frame", nil, scrollFrame);
    scrollChild:SetSize(Sizes.cardWidth, 1);
    scrollFrame:SetScrollChild(scrollChild);

    Theme.Helpers.EnableSmoothScroll(scrollFrame, { step = CARD_HEIGHT + Sizes.stackSpacing });

    toggleBar = createToggleBar(scrollChild);
    toggleBar:Hide();

    frame:SetScript("OnShow", RespondWindow.RefreshTimerState);
end

function RespondWindow.Refresh()
    if (not frame) then return; end

    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.status ~= "active") then
        if (frame:IsShown()) then
            stopTimerHard();
            frame:Hide();
        end
        return;
    end

    local myName = Util.stripRealm(Util.UnitName("player"));
    local pending, sent = {}, {};
    for _, item in ipairs(Session.items) do
        if (item.candidates[myName]) then
            table.insert(sent, item);
        else
            table.insert(pending, item);
        end
    end
    table.sort(sent, function(a, b)
        local ca, cb = a.candidates[myName], b.candidates[myName];
        if (ca.respondedAt == cb.respondedAt) then return a.session < b.session; end
        return ca.respondedAt < cb.respondedAt;
    end);

    headerCountNumber:SetText(tostring(#pending));

    -- Paint every card's content up front (regardless of visibility), then
    -- position/show only the ones actually visible below.
    local usedSessions = {};
    for _, item in ipairs(Session.items) do
        local card = ensureCard(item.session);
        usedSessions[item.session] = true;
        paintCard(card, item, item.candidates[myName] == nil, myName);
    end
    for sessionIndex, card in pairs(cards) do
        if (not usedSessions[sessionIndex]) then
            card.entry = nil;
            card:Hide();
        end
    end

    -- Places the next piece `height` tall, returning the y-offset to anchor
    -- it at. Gaps go BEFORE each piece (skipped for the very first one)
    -- rather than after, so `y` is always exactly the content height used so
    -- far - no "was the last piece followed by a gap?" bookkeeping needed
    -- once the loop ends (that mismatch used to shrink the measured height
    -- by one stackSpacing whenever the toggle bar was the last visible
    -- piece, clipping its own bottom edge).
    local y = 0;
    local function placeNext(height)
        if (y > 0) then y = y + Sizes.stackSpacing; end
        local top = y;
        y = y + height;
        return top;
    end

    for _, item in ipairs(pending) do
        local card = cards[item.session];
        card:ClearAllPoints();
        card:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -placeNext(CARD_HEIGHT));
        card:Show();
    end

    if (#sent > 0) then
        toggleBar:ClearAllPoints();
        toggleBar:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -placeNext(Sizes.toggleBarHeight));
        toggleBar:Show();
        layoutToggleBar(#sent);

        if (toggleExpanded) then
            for _, item in ipairs(sent) do
                local card = cards[item.session];
                card:ClearAllPoints();
                card:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -placeNext(CARD_HEIGHT));
                card:Show();
            end
        else
            for _, item in ipairs(sent) do cards[item.session]:Hide(); end
        end
    else
        toggleBar:Hide();
    end

    local contentHeight = y;
    scrollChild:SetHeight(math.max(contentHeight, 1));

    allSentCard:SetShown(#pending == 0);

    local scrollAnchor = allSentCard:IsShown() and allSentCard or header;
    scrollFrame:ClearAllPoints();
    scrollFrame:SetPoint("TOPLEFT", scrollAnchor, "BOTTOMLEFT", 0, -Sizes.stackSpacing);
    scrollFrame:SetPoint("TOPRIGHT", scrollAnchor, "BOTTOMRIGHT", 0, -Sizes.stackSpacing);

    local maxScrollHeight = Sizes.scrollMaxHeightPct * UIParent:GetHeight();
    local scrollHeight = math.min(contentHeight, maxScrollHeight);
    scrollFrame:SetHeight(scrollHeight);

    -- UIPanelScrollFrameTemplate used to re-clamp the scroll offset itself
    -- whenever the range changed (a built-in OnScrollRangeChanged handler
    -- bound in its XML) - this window doesn't use that template (see the
    -- scrollFrame creation comment above), so it has to do the same
    -- clamping by hand, or a raider who scrolled down through a long
    -- pending list ends up with the toggle bar pushed up out of view once
    -- the list shrinks back down to just the toggle bar.
    local scrollRange = math.max(contentHeight - scrollHeight, 0);
    if (scrollFrame:GetVerticalScroll() > scrollRange) then
        scrollFrame:SetVerticalScroll(scrollRange);
    end

    -- Belt and suspenders on top of the clamp above: when everything
    -- already fits (the common "just the toggle bar" case), disable mouse
    -- wheel input on the scroll frame outright, so it's mechanically
    -- impossible to nudge it out of place regardless of any stale scroll
    -- state left over from EnableSmoothScroll's own wheel-animation target.
    scrollFrame:EnableMouseWheel(scrollRange > 0.5);

    local totalHeight = Sizes.headerHeight;
    if (allSentCard:IsShown()) then
        totalHeight = totalHeight + Sizes.stackSpacing + ALL_SENT_CARD_HEIGHT;
    end
    totalHeight = totalHeight + Sizes.stackSpacing + scrollHeight;
    Pixel.SetHeight(frame, totalHeight);

    RespondWindow.RefreshTimerState();
end

--- Opens the window if the local player still hasn't responded to at least
--- one item in the current session. Called from LootCouncil.applySessionStart
--- so the window auto-pops on a genuinely new session, without forcing
--- itself open on a catch-up/re-sync sessionStart where everything's
--- already answered.
function RespondWindow.MaybeAutoShow()
    local Session = LootCouncil.CurrentSession;
    if (not Session) then return; end

    local myName = Util.stripRealm(Util.UnitName("player"));
    for _, item in ipairs(Session.items) do
        if (not item.candidates[myName]) then
            RespondWindow.Show();
            return;
        end
    end
end

function RespondWindow.Show()
    ensureFrame();
    toggleExpanded = false;
    frame:Show();
    RespondWindow.Refresh();
end

function RespondWindow.Hide()
    if (frame) then
        stopTimerHard();
        frame:Hide();
    end
end

function RespondWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
