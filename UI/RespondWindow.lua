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
local ResponseRow = FL.UI.ResponseRow;
local LootCouncil = FL.LootCouncil;
local RespondWindow = FL.UI.RespondWindow;

local FALLBACK_ICON = FL.LootCouncil.FALLBACK_ICON;

local SWEEP_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Sweep";
local SOFTGLOW_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\SoftGlow";
local SENT_CHECK_TEXTURE = "Interface\\RaidFrame\\ReadyCheck-Ready";
local SORT_ARROW_TEXTURE = "Interface\\Buttons\\UI-SortArrow";
local NOTE_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\NoteIcon";
local NOTE_ICON_BADGE_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\NoteIconBadge";
local NOTE_BUBBLE_ARROW_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\NoteBubbleArrow";

-- The card/header/toggle-bar/note-popover width actually in use - starts at
-- the default (Sizes.cardWidth) and is recomputed once per session (see
-- updateCardWidthForSession) from that session's own response list, so the
-- popup always widens to fit every label in full but never gets narrower
-- than the default. A plain mutable upvalue (not Sizes.cardWidth itself)
-- since every function below that used to read Sizes.cardWidth directly
-- needs to pick up a later resize without being redefined.
local cardWidth = Sizes.cardWidth;

-- Key this window's saved position is stored under (see
-- Settings.GetWindowPosition/SetWindowPosition). Deliberately not migrated
-- from the old window's "lootCouncilResponseWindow" key - that window was a
-- single boxed panel, this one's a floating card stack, so a carried-over
-- x/y would land oddly.
local POSITION_KEY = "respondWindow";

-- Every item card has the same fixed height, derived from the same Sizes
-- this file paints every card with (icon/name/type row, response button row
-- - see paintCard). Computed once here rather than measured per card each
-- refresh. No note row anymore - the note field lives in a floating popover
-- instead (see the popover module below), not an inline card row.
local CARD_HEIGHT = Sizes.cardPadding * 2 + Sizes.iconSize + Sizes.cardSectionGap + Sizes.buttonHeight;

local ALL_SENT_CARD_HEIGHT = Sizes.cardPadding * 2 + Sizes.allSentRowHeight
    + Sizes.timerBarGap + Sizes.timerTrackHeight;

local frame, header, headerCountNumber, allSentCard, timerLabel, timerBar,
    scrollFrame, scrollChild, toggleBar,
    toggleSentText, toggleActionText, toggleArrow;

-- cards[item.session] = card frame, built lazily and reused for the
-- lifetime of the addon session - keyed by the item's stable session index
-- (not its current sort position), so a card's note EditBox keeps its
-- in-progress text/focus across the item moving between the pending and
-- sent groups. See ensureCard/paintCard below.
local cards = {};

-- Session -> the current locally-known note text for that item, independent
-- of whether a response has been sent yet. This is the note popover's real
-- source of truth (there's a single shared popover EditBox, not one per
-- card, so a card's note text has to live somewhere even while its popover
-- is closed). Initialized from candidates[myName].note the first time a
-- session id is painted (see paintCard's paintedSessionId guard) and from
-- then on only ever written by the popover itself (OnTextChanged / CloseNote)
-- - see the popover module below.
local noteDrafts = {};

-- Forward declarations: the Note button and the response buttons built by
-- UI/ResponseRow.lua's onSelect callback all need to call into the shared
-- note-popover module, which is defined later in this file (where the old
-- inline note box used to live) - see the "Note popover" section.
local notePopover, isNotePopoverOpen, dismissPopoverSilently, CloseNote, OpenNote, onResponseButtonClick, paintNoteButton;

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
-- "Sent" indicator text actually needs, so a sent card's item name can be
-- truncated to leave room for it without guessing a pixel value.
local SENT_INDICATOR_WIDTH;
do
    local probe = UIParent:CreateFontString(nil, "OVERLAY");
    SetFont(probe, "small");
    probe:SetText("Sent");
    probe:Hide();
    SENT_INDICATOR_WIDTH = probe:GetStringWidth();
end

-- Same measurement, for the longer "Awarded" text that takes over the same
-- indicator slot once an item has been awarded (see paintCard).
local AWARDED_INDICATOR_WIDTH;
do
    local probe = UIParent:CreateFontString(nil, "OVERLAY");
    SetFont(probe, "small");
    probe:SetText("Awarded");
    probe:Hide();
    AWARDED_INDICATOR_WIDTH = probe:GetStringWidth();
end

-- Measured once, off-screen: the note popover's "Done" button width, sized
-- to its own label rather than a guessed literal - same pattern as
-- SENT_INDICATOR_WIDTH above.
local DONE_BUTTON_WIDTH;
do
    local probe = UIParent:CreateFontString(nil, "OVERLAY");
    SetFont(probe, "body");
    probe:SetText("Done");
    probe:Hide();
    DONE_BUTTON_WIDTH = probe:GetStringWidth() + Sizes.popoverDoneButtonPadX * 2;
end

--------------------------------------------------------------------------
-- Item card content (name/type/quality) - split out from paintCard since it
-- re-runs asynchronously once an uncached item's info actually loads (same
-- ContinueOnItemLoad pattern StartSessionWindow.lua uses).
--------------------------------------------------------------------------

local function nameMaxWidth(isPending, isAwarded)
    local width = cardWidth - Sizes.cardPadding * 2 - Sizes.iconSize - Sizes.iconTextGap;
    if (isAwarded) then
        width = width - AWARDED_INDICATOR_WIDTH - Sizes.iconTextGap;
    elseif (not isPending) then
        width = width - SENT_INDICATOR_WIDTH - Sizes.iconTextGap;
    end
    return width;
end

local function paintCardItemInfo(card, entry)
    local name, _, quality, _, _, itemType, itemSubType, _, equipLoc = Util.GetItemInfo(entry.itemLink);

    if (name) then
        local r, g, b = Util.GetItemQualityColor(quality);
        setTextEllipsized(card.nameText, ("[%s]"):format(name), nameMaxWidth(card.isPending, card.isAwarded));
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
-- Response buttons - built by the shared UI/ResponseRow.lua (also used by
-- the Loot Responses settings page's preview), not this file. See
-- paintCard's own ResponseRow.Build call below.
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- Note popover - one shared floating frame for the whole window (only one
-- open at a time), parented to the window's root `frame` (not scrollChild,
-- so it's never subject to scrollFrame's clip rect or a card's own
-- SetClipsChildren(true)). Replaces the old always-visible inline note
-- EditBox (createNoteBox, previously here) entirely - see the card-redesign
-- plan this implements for why. Built lazily by ensurePopover(), called
-- once from ensureFrame() below.
--
-- The note text itself lives in the module-level `noteDrafts` table (see
-- its own declaration near `cards` above), not on the item/candidate
-- directly - the popover is a single shared EditBox, not one per card, so a
-- card's note text has to be readable/writable even while its own popover
-- isn't the currently-open one.
--------------------------------------------------------------------------

notePopover = { card = nil, frame = nil, editBox = nil, hint = nil, doneButton = nil, arrow = nil, noteStart = nil };

isNotePopoverOpen = function()
    return notePopover.card ~= nil;
end

-- UI-only close: hides the popover and repaints the note button, but never
-- sends anything - used when a response click on the same card already sent
-- (or is about to send) the current text itself, so CloseNote's own
-- resend-if-dirty logic would be redundant.
dismissPopoverSilently = function()
    local card = notePopover.card;
    notePopover.frame:Hide();
    notePopover.card = nil;
    notePopover.editBox:ClearFocus();
    if (card and card.noteButton) then paintNoteButton(card.noteButton, card); end
    RespondWindow.RefreshTimerState();
end

-- Trims and stores the current text, hides the popover, and - only if the
-- item was already sent and the trimmed text actually changed - resends the
-- existing response with the new note (playing the same gold sweep a
-- changed response already plays). Bound to Done/Enter/Escape/re-clicking
-- the same card's Note button; never discards text (no cancel).
CloseNote = function()
    local card = notePopover.card;
    if (not card) then return; end

    local trimmed = Util.Trim(notePopover.editBox:GetText());
    if (card.entry) then noteDrafts[card.entry.session] = trimmed; end

    if (card.entry) then
        local myName = Util.stripRealm(Util.UnitName("player"));
        local candidate = card.entry.candidates[myName];
        if (candidate and trimmed ~= notePopover.noteStart) then
            LootCouncil.SubmitResponse(card.entry.session, candidate.response, trimmed);
            RespondWindow.PlaySendSweep(card);
        end
    end

    dismissPopoverSilently();
end

OpenNote = function(card)
    if (notePopover.card == card) then CloseNote(); return; end -- re-click same card's note button toggles closed
    if (notePopover.card) then CloseNote(); end -- a DIFFERENT card's popover was open - close it first (commits/resends its own note if dirty)

    notePopover.card = card;
    local session = card.entry.session;
    local text = noteDrafts[session] or "";
    notePopover.editBox:SetText(text);
    notePopover.editBox.placeholderText:SetShown(text == "");
    notePopover.noteStart = text;

    notePopover.frame:ClearAllPoints();
    notePopover.frame:SetPoint("TOPLEFT", card, "BOTTOMLEFT", Sizes.popoverOffsetX, Sizes.popoverOffsetY);
    notePopover.frame:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", -Sizes.popoverOffsetX, Sizes.popoverOffsetY);
    notePopover.frame:Show();

    -- Arrow x, recomputed every open since a different card (or the same
    -- card after a scroll/reflow) means a different button position. Safe
    -- to subtract these two frames' GetCenter()/GetLeft() directly without
    -- scale correction: neither card.noteButton nor notePopover.frame ever
    -- calls :SetScale() itself (only the shared root `frame` does, via
    -- Pixel.RegisterWindow) - Core/PixelPerfect.lua's own "self-scaled
    -- coordinate space" caveat only applies to a frame reading its own
    -- GetLeft() after *it* was scaled, not to two unscaled descendants of a
    -- scaled ancestor comparing coordinates with each other. Must run after
    -- the SetPoint/Show above so notePopover.frame:GetLeft() is resolved.
    local buttonCenterX = card.noteButton:GetCenter();
    local popoverLeftX = notePopover.frame:GetLeft();
    local arrowX = buttonCenterX - popoverLeftX - Sizes.popoverArrowWidth / 2;
    notePopover.arrow:ClearAllPoints();
    notePopover.arrow:SetPoint("BOTTOMLEFT", notePopover.frame, "TOPLEFT", arrowX, Sizes.popoverArrowOffsetY);

    notePopover.editBox:SetFocus();
    paintNoteButton(card.noteButton, card);
    RespondWindow.RefreshTimerState();
end

local function ensurePopover()
    if (notePopover.frame) then return; end

    notePopover.frame = CreateCard(frame, cardWidth - Sizes.popoverOffsetX * 2, Colors.windowBg, "Frame", Colors.controlFocus);
    notePopover.frame:SetHeight(Sizes.popoverPadding * 2 + Sizes.noteHeight);
    -- One strata above the window root's own DIALOG - same convention
    -- Skin.Dropdown's own floating list uses to sit above a DIALOG-strata
    -- window (UI/SettingsWindow/Skin.lua).
    notePopover.frame:SetFrameStrata("FULLSCREEN_DIALOG");
    notePopover.frame:SetFrameLevel(200);
    notePopover.frame:Hide();
    -- CreateCard() never clips children (only item cards' own createCard()
    -- call does that) - so the arrow, which deliberately protrudes above
    -- the frame's own rect, is never clipped.

    notePopover.arrow = notePopover.frame:CreateTexture(nil, "OVERLAY");
    notePopover.arrow:SetTexture(NOTE_BUBBLE_ARROW_TEXTURE);
    notePopover.arrow:SetSize(Sizes.popoverArrowWidth, Sizes.popoverArrowHeight);

    notePopover.doneButton = CreateFrame("Button", nil, notePopover.frame, "BackdropTemplate");
    Skin.Button(notePopover.doneButton, "primary");
    notePopover.doneButton.text:SetText("Done");
    notePopover.doneButton:SetSize(DONE_BUTTON_WIDTH, Sizes.noteHeight);
    notePopover.doneButton:SetPoint("TOPRIGHT", notePopover.frame, "TOPRIGHT", -Sizes.popoverPadding, -Sizes.popoverPadding);
    notePopover.doneButton:SetScript("OnClick", function() CloseNote(); end);

    notePopover.hint = notePopover.frame:CreateFontString(nil, "OVERLAY");
    SetFont(notePopover.hint, "tiny");
    notePopover.hint:SetTextColor(unpack(Colors.respondNotePlaceholder));
    notePopover.hint:SetText("Enter to save");
    notePopover.hint:SetPoint("RIGHT", notePopover.doneButton, "LEFT", -Sizes.popoverRowGap, 0);

    notePopover.editBox = CreateFrame("EditBox", nil, notePopover.frame, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(notePopover.editBox, Colors.controlBg, Colors.respondBorderMuted, 1);
    SetFont(notePopover.editBox, "body");
    notePopover.editBox:SetTextColor(unpack(Colors.textBright));
    notePopover.editBox:SetTextInsets(Sizes.noteTextInset, Sizes.noteTextInset, 0, 0);
    notePopover.editBox:SetAutoFocus(false);
    notePopover.editBox:SetMaxLetters(120); -- changed from the old inline box's 80
    notePopover.editBox:SetHeight(Sizes.noteHeight);
    notePopover.editBox:SetPoint("TOPLEFT", notePopover.frame, "TOPLEFT", Sizes.popoverPadding, -Sizes.popoverPadding);
    notePopover.editBox:SetPoint("RIGHT", notePopover.hint, "LEFT", -Sizes.popoverRowGap, 0);

    notePopover.editBox.placeholderText = notePopover.editBox:CreateFontString(nil, "OVERLAY");
    SetFont(notePopover.editBox.placeholderText, "body");
    notePopover.editBox.placeholderText:SetTextColor(unpack(Colors.respondNotePlaceholder));
    notePopover.editBox.placeholderText:SetPoint("LEFT", notePopover.editBox, "LEFT", Sizes.noteTextPlaceholderInset, 0);
    notePopover.editBox.placeholderText:SetJustifyH("LEFT");
    notePopover.editBox.placeholderText:SetText("Add a note for the council\226\128\166");

    notePopover.editBox:SetScript("OnTextChanged", function(self)
        self.placeholderText:SetShown(self:GetText() == "");
        if (notePopover.card and notePopover.card.entry) then
            noteDrafts[notePopover.card.entry.session] = self:GetText(); -- live, untrimmed - trimmed only at close
            paintNoteButton(notePopover.card.noteButton, notePopover.card);
        end
    end);
    -- Escape here only closes the popover, never the window (the window
    -- isn't in UISpecialFrames - see ensureFrame's own comment below).
    notePopover.editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CloseNote(); end);
    notePopover.editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); CloseNote(); end);
end

--------------------------------------------------------------------------
-- Note button - opens/closes the note popover for its card. Not built via
-- Skin.Button: that helper's OnEnter/OnLeave hooks unconditionally reset
-- border/bg colors on every native hover event (HookScript is additive, so
-- those hooks can't be overridden), which would fight this button's 4-state
-- paint logic below. Instead, same hand-rolled shape UI/ResponseRow.lua's
-- pooled buttons use: a one-shot flat backdrop plus an OnUpdate hover-poll
-- (native OnEnter/OnLeave can go stale across a reflow).
--------------------------------------------------------------------------

paintNoteButton = function(btn, card)
    local entry = card.entry;
    if (not entry) then return; end

    local isPopoverOpen = (notePopover.card == card);
    local hasNote = (noteDrafts[entry.session] or "") ~= "";
    local isHovered = btn.isHovered;

    local iconColor, bg, border;
    if (isPopoverOpen) then
        iconColor, bg, border = Colors.gold, Colors.selectedFill, Colors.gold;
    elseif (isHovered) then
        iconColor, bg, border = Colors.text, Colors.defaultBg, Colors.gold;
    elseif (hasNote) then
        iconColor, bg, border = Colors.gold, Colors.defaultBg, Colors.selectedBorder;
    else
        iconColor, bg, border = Colors.muted, Colors.defaultBg, Colors.checkboxBorder;
    end

    btn.pageIcon:SetVertexColor(iconColor[1], iconColor[2], iconColor[3]);
    Theme.Helpers.SetFlatBackdrop(btn, bg, border, 1);
end

local function createNoteButton(card)
    local btn = CreateFrame("Button", nil, card, "BackdropTemplate");
    btn:SetSize(Sizes.noteButtonWidth, Sizes.buttonHeight);
    Theme.Helpers.SetFlatBackdrop(btn, Colors.defaultBg, Colors.checkboxBorder, 1);

    btn.pageIcon = btn:CreateTexture(nil, "ARTWORK");
    btn.pageIcon:SetSize(Sizes.noteIconSize, Sizes.noteIconSize);
    btn.pageIcon:SetPoint("CENTER");
    btn.pageIcon:SetTexture(NOTE_ICON_TEXTURE);

    btn.badgeIcon = btn:CreateTexture(nil, "OVERLAY");
    btn.badgeIcon:SetSize(Sizes.noteIconSize, Sizes.noteIconSize);
    btn.badgeIcon:SetPoint("CENTER");
    btn.badgeIcon:SetTexture(NOTE_ICON_BADGE_TEXTURE);
    -- badgeIcon never gets SetVertexColor - keeps its own baked colors,
    -- always shown alongside pageIcon (not an on/off toggle).

    btn:SetScript("OnUpdate", function(self)
        local card = self:GetParent();
        local isHovered = Util.IsMouseOverVisible(self, scrollFrame);
        if (isHovered ~= self.isHovered) then
            self.isHovered = isHovered;
            if (card.entry) then paintNoteButton(self, card); end
        end
        if (isHovered and card.entry) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            local text = noteDrafts[card.entry.session] or "";
            GameTooltip:AddLine(text == "" and "Add a note" or ("Note: " .. text), 1, 1, 1, true);
            GameTooltip:Show();
        elseif (GameTooltip:GetOwner() == self) then
            GameTooltip:Hide();
        end
    end);

    btn:SetScript("OnClick", function(self)
        local card = self:GetParent();
        if (not card.entry) then return; end
        OpenNote(card);
    end);

    return btn;
end

--------------------------------------------------------------------------
-- Shared response-button click handler - used for every response kind
-- (text/mog/pass), via a per-card opts.onSelect wrapper paintCard hands to
-- ResponseRow.Build (see paintCard below). Popover-aware: closes a different
-- card's open popover first, folds an already-open popover's current text
-- into the submitted note, and lets CloseNote() alone handle the "clicked
-- the already-selected response but the note text changed" resend case.
--------------------------------------------------------------------------

onResponseButtonClick = function(card, responseId)
    local entry = card.entry;
    if (not entry) then return; end

    -- A DIFFERENT card's popover is open - close it first (commits/resends
    -- its own note if dirty; its text is never lost either way).
    if (notePopover.card and notePopover.card ~= card) then CloseNote(); end

    local myName = Util.stripRealm(Util.UnitName("player"));
    local candidate = entry.candidates[myName];
    local isAlreadySelected = candidate and candidate.response == responseId;
    local popoverOpenHere = (notePopover.card == card); -- re-read AFTER the close-other-card step above

    if (isAlreadySelected and not popoverOpenHere) then return; end -- unchanged existing no-op shortcut

    if (isAlreadySelected and popoverOpenHere) then
        -- No new response to submit - only a possible note-only resend,
        -- which CloseNote() itself detects via its own dirty check.
        CloseNote();
        return;
    end

    local noteText;
    if (popoverOpenHere) then
        noteText = Util.Trim(notePopover.editBox:GetText());
        noteDrafts[entry.session] = noteText;
    else
        noteText = noteDrafts[entry.session] or "";
    end

    local wasPending = candidate == nil;
    LootCouncil.SubmitResponse(entry.session, responseId, noteText);

    if (popoverOpenHere) then dismissPopoverSilently(); end -- UI-only close, no duplicate SubmitResponse

    if (wasPending) then
        RespondWindow.PlayToggleBarPulse();
    else
        RespondWindow.PlaySendSweep(card);
    end
    RespondWindow.RefreshTimerState();
end

--------------------------------------------------------------------------
-- Item card construction/pooling
--------------------------------------------------------------------------

local function createCard(parent)
    local card = CreateCard(parent, cardWidth);
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

    card.sentLabel = card:CreateFontString(nil, "OVERLAY");
    SetFont(card.sentLabel, "small");
    card.sentLabel:SetTextColor(unpack(Colors.respondSentLabel));
    card.sentLabel:SetText("Sent");
    card.sentLabel:SetPoint("TOPRIGHT", card, "TOPRIGHT", -Sizes.cardPadding, -Sizes.cardPadding);

    -- Tooltip - only over the icon itself, not the whole card. A card
    -- scrolled out of view still occupies its rect for a bare IsMouseOver
    -- check, so this polls Util.IsMouseOverVisible the same way
    -- StartSessionWindow's rows do.
    card:SetScript("OnUpdate", function(self, elapsed)
        if (self.entry and Util.IsMouseOverVisible(self.icon, scrollFrame)) then
            GameTooltip:SetOwner(self.icon, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink(self.entry.itemLink);
            GameTooltip:Show();
        elseif (GameTooltip:GetOwner() == self.icon) then
            GameTooltip:Hide();
        end
    end);

    -- Note button (opens/closes the shared popover). The response buttons
    -- themselves are built/pooled by ResponseRow.Build (UI/ResponseRow.lua)
    -- against this card as their parent - see paintCard below.
    card.noteButton = createNoteButton(card);

    -- Send sweep (gold light sweeping across the card + a gold border flash)
    -- - played whenever a sent card's response or note changes.
    card.sweep = card:CreateTexture(nil, "OVERLAY");
    card.sweep:SetTexture(SWEEP_TEXTURE);
    card.sweep:SetVertexColor(Colors.gold[1], Colors.gold[2], Colors.gold[3], Sizes.sweepAlpha);
    card.sweep:SetBlendMode("ADD");
    card.sweep:SetSize(cardWidth * Sizes.sweepWidthPct, CARD_HEIGHT);
    card.sweep:Hide();

    card.sweepAnim = card.sweep:CreateAnimationGroup();
    card.sweepMove = card.sweepAnim:CreateAnimation("Translation");
    card.sweepMove:SetOffset(cardWidth + card.sweep:GetWidth(), 0);
    card.sweepMove:SetDuration(Sizes.sweepDuration);
    card.sweepMove:SetSmoothing("OUT");
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
    card.isAwarded = entry.awardedTo ~= nil;

    card.icon:SetTexture(entry.itemIcon or FALLBACK_ICON);
    paintCardItemInfo(card, entry);

    local showIndicator = card.isAwarded or not isPending;
    card.sentLabel:SetShown(showIndicator);
    if (showIndicator) then
        if (card.isAwarded) then
            card.sentLabel:SetText("Awarded");
            card.sentLabel:SetTextColor(unpack(Colors.gold));
        else
            card.sentLabel:SetText("Sent");
            card.sentLabel:SetTextColor(unpack(Colors.respondSentLabel));
        end
    end

    local candidate = entry.candidates[myName];

    -- Note draft is only ever (re)set the first time THIS card renders data
    -- for the current session - never on a later refresh, so an in-progress
    -- unsent note is never clobbered by an unrelated event. Direct
    -- replacement for the old inline note box's identical guard.
    local Session = LootCouncil.CurrentSession;
    if (card.paintedSessionId ~= Session.id) then
        noteDrafts[entry.session] = candidate and candidate.note or "";
        card.paintedSessionId = Session.id;
    end

    -- Button row: Note button, then one button per entry in the SESSION's
    -- own response snapshot, in that snapshot's order - built/pooled by the
    -- shared ResponseRow.Build (UI/ResponseRow.lua), so this row is
    -- pixel-identical to the settings page's own preview.
    local buttonsTop = Sizes.cardPadding + Sizes.iconSize + Sizes.cardSectionGap;
    paintNoteButton(card.noteButton, card);

    local list = Session.responses or {};
    local row = ResponseRow.Build(card, list, {
        noteButton = card.noteButton,
        getSelectedId = function() return candidate and candidate.response or nil; end,
        isPending = isPending,
        scrollFrame = scrollFrame,
        width = cardWidth - Sizes.cardPadding * 2,
        onSelect = function(responseId) onResponseButtonClick(card, responseId); end,
    });
    row:ClearAllPoints();
    row:SetPoint("TOPLEFT", card, "TOPLEFT", Sizes.cardPadding, -buttonsTop);
end

--------------------------------------------------------------------------
-- Toggle bar ("N sent - Click to change")
--------------------------------------------------------------------------

local function createToggleBar(parent)
    local bar = CreateCard(parent, cardWidth, Colors.respondToggleBarBg, "Button", Colors.respondBorderMuted);
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
    local card = CreateCard(parent, cardWidth);
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

    timerBar = Skin.TimerBar(card, {
        height = Sizes.timerTrackHeight,
        sheenWidth = Sizes.timerSheenWidth,
        sheenPeriod = Sizes.sheenPeriod,
    });
    timerBar.track:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -Sizes.timerBarGap);
    timerBar.track:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -Sizes.timerBarGap);

    -- Fade-out (closing state) - plays on the whole window container, not
    -- just this card, since the entire stack disappears together.
    frame.fadeAnim = frame:CreateAnimationGroup();
    local fade = frame.fadeAnim:CreateAnimation("Alpha");
    fade:SetFromAlpha(1);
    fade:SetToAlpha(0);
    fade:SetDuration(Sizes.fadeOutDuration);
    frame.fadeAnim:SetScript("OnFinished", function()
        FL.NotifyWindowClosed("Respond");
        frame:Hide();
        frame:SetAlpha(1);
        RespondWindow.timerState = "off";
    end);

    return card;
end

--------------------------------------------------------------------------
-- Timer state machine
--------------------------------------------------------------------------

RespondWindow.timerState = "off";

local function stopTimerUpdate()
    timerBar:Stop();
end

local function paintPausedTimer()
    timerBar:Freeze(Colors.respondTimerPausedFill);
    timerLabel:SetText("Timer paused while you make changes");
end

local function enterOff()
    if (RespondWindow.timerState == "closing") then
        frame.fadeAnim:Stop();
        frame:SetAlpha(1);
    end
    RespondWindow.timerState = "off";
    stopTimerUpdate();
    allSentCard:Hide();
end

local function enterRunning()
    RespondWindow.timerState = "running";
    allSentCard:Show();
    timerBar:Start(Sizes.autoCloseSeconds, {
        onTick = function(seconds) timerLabel:SetText(("Closing in %ds"):format(seconds)); end,
        onExpire = function() RespondWindow.EnterTimerClosing(); end,
    });
end

local function enterPaused()
    RespondWindow.timerState = "paused";
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
end

--- Run after every change that could affect the timer (response click,
--- toggle open/close, note popover open/close, items added/removed, window
--- shown) - see the state table in the design spec this window implements.
--- Gated on the popover being OPEN, not its EditBox being focused (the
--- popover can be open with focus elsewhere, e.g. tabbed away, and must
--- still pause) - see isNotePopoverOpen in the note-popover module above.
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
        if (not toggleExpanded and not isNotePopoverOpen()) then enterRunning(); else enterPaused(); end
    elseif (state == "running") then
        if (toggleExpanded or isNotePopoverOpen()) then enterPaused(); end
    elseif (state == "paused") then
        if (not toggleExpanded and not isNotePopoverOpen()) then enterRunning(); end
    end
    -- state == "closing": only exits via the fade AnimationGroup's
    -- OnFinished, or via the pendingCount>0 branch above.
end

--------------------------------------------------------------------------
-- Header
--------------------------------------------------------------------------

local function createHeader()
    header = CreateCard(frame, cardWidth);
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
        FL.NotifyWindowClosed("Respond");
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
        width = cardWidth, height = Sizes.headerHeight,
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
    scrollChild:SetSize(cardWidth, 1);
    scrollFrame:SetScrollChild(scrollChild);

    Theme.Helpers.EnableSmoothScroll(scrollFrame, { step = CARD_HEIGHT + Sizes.stackSpacing });

    toggleBar = createToggleBar(scrollChild);
    toggleBar:Hide();

    ensurePopover();

    frame:SetScript("OnShow", RespondWindow.RefreshTimerState);
end

--------------------------------------------------------------------------
-- Card width - recomputed once per session from that session's own response
-- list (Core/Responses.lua's SessionSnapshot, carried on the session as
-- Session.responses - see LootCouncil.lua's applySessionStart), so the
-- popup always widens to fit every label in full but never gets narrower
-- than the default, and the clamp never exceeds 60% of the screen.
--------------------------------------------------------------------------

local cardWidthSessionId;

local function applyCardWidth(newWidth)
    if (newWidth == cardWidth) then return; end
    cardWidth = newWidth;
    if (not frame) then return; end -- not built yet - ensureFrame() will read the already-updated local

    frame:SetWidth(cardWidth);
    header:SetWidth(cardWidth);
    allSentCard:SetWidth(cardWidth);
    scrollChild:SetWidth(cardWidth);
    toggleBar:SetWidth(cardWidth);
    if (notePopover.frame) then
        notePopover.frame:SetWidth(cardWidth - Sizes.popoverOffsetX * 2);
    end
    for _, card in pairs(cards) do
        card:SetWidth(cardWidth);
        card.sweep:SetWidth(cardWidth * Sizes.sweepWidthPct);
        card.sweepMove:SetOffset(cardWidth + card.sweep:GetWidth(), 0);
    end
end

local function updateCardWidthForSession(Session)
    if (not Session or not Session.responses or cardWidthSessionId == Session.id) then return; end
    cardWidthSessionId = Session.id;

    local naturalRowWidth = ResponseRow.MeasureNaturalWidth(Session.responses);
    local desired = math.max(Sizes.cardWidth, Sizes.cardPadding * 2 + naturalRowWidth);
    desired = math.min(desired, Sizes.cardWidthMaxPct * UIParent:GetWidth());
    applyCardWidth(desired);
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

    updateCardWidthForSession(Session);

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
            noteDrafts[sessionIndex] = nil;
            if (notePopover.card == card) then dismissPopoverSilently(); end
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
        local newTop = placeNext(CARD_HEIGHT);
        card:ClearAllPoints();
        card:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -newTop);
        card:Show();
    end

    if (#sent > 0) then
        local toggleNewTop = placeNext(Sizes.toggleBarHeight);
        toggleBar:ClearAllPoints();
        toggleBar:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -toggleNewTop);
        toggleBar:Show();
        layoutToggleBar(#sent);

        if (toggleExpanded) then
            for _, item in ipairs(sent) do
                local card = cards[item.session];
                local sentNewTop = placeNext(CARD_HEIGHT);
                card:ClearAllPoints();
                card:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -sentNewTop);
                card:Show();
            end
        else
            for _, item in ipairs(sent) do
                cards[item.session]:Hide();
            end
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

function RespondWindow.IsShown()
    return frame ~= nil and frame:IsShown();
end

function RespondWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
