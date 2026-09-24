--[[
Raider-facing "Respond to Items" window (Phase 3): pops open automatically
when a loot council session starts (if any item still lacks a local
response), lets the player pick one of the fixed response options per item
plus an optional note, and shows which items have already been responded to
below a "Responded" divider - collapsed by default, click it to review or
change an earlier selection.
]]

local FL = ForeverLoot;
local ResponseWindow = FL.UI.LootCouncilResponseWindow;
local LootCouncil = FL.LootCouncil;
local Util = FL.Util;
local Constants = FL.Constants;

local MAX_ROWS = 30;
local SEPARATOR_HEIGHT = 24;
local ICON_SIZE = 42;
local FALLBACK_ICON = LootCouncil.FALLBACK_ICON;

local DEFAULT_HEIGHT = 320;
local MAX_HEIGHT = 700;
local BUTTON_GAP = 2;
local RESPONSE_BUTTON_HEIGHT = 26;
local NOTE_BOX_HEIGHT = 20;
-- Vertical gaps within a row. Row layout, top to bottom: icon (with the item
-- name to its right), the note box directly under the item name, then the
-- response buttons, then breathing room before the next row. Named (not
-- inlined at each SetPoint call below) so ROW_HEIGHT can be computed from
-- them and never drift out of sync with the actual anchors.
local ROW_TOP_INSET = 4;
local ITEM_TEXT_TO_NOTE_GAP = 10;
local NOTE_TO_BUTTONS_GAP = 8;
-- Breathing room below a row's response buttons before the next row starts -
-- this is the "gap between item rows" a reader actually sees.
local ROW_BOTTOM_PADDING = 16;
-- Computed once in computeLayout() below: the note box sits under the item
-- name (not under the icon), so the response buttons' top offset depends on
-- whichever column - icon, or item name + note box - runs taller, which in
-- turn depends on the item-name font's real rendered height.
local ROW_HEIGHT, BUTTONS_TOP_INSET;
-- Extra width added on top of a label's own measured text width when sizing
-- response buttons/the window (see computeLayout below).
local RESPONSE_BUTTON_LABEL_PADDING = 32;
local MIN_RESPONSE_BUTTON_WIDTH = 50;
-- Must match the scrollFrame TOPLEFT/BOTTOMRIGHT anchor offsets in
-- ensureFrame() below - kept as named constants (not duplicated magic
-- numbers) so the width computed for the response-button row and the
-- window's own width can never drift out of sync with that anchor layout.
local WINDOW_LEFT_MARGIN = 12;
-- Wide enough to clear the scrollbar: per UIPanelScrollFrameTemplate (see
-- Blizzard_SharedXML/SecureScrollTemplates.xml), the ScrollBar is anchored
-- 6px right of the scrollFrame's own right edge and is 16px wide - 22px
-- total - regardless of skin (Theme.SkinScrollBar only recolors/hides parts
-- of it, it never reanchors or resizes it), plus a little breathing room.
local WINDOW_RIGHT_MARGIN = 24;
-- The response-button row starts 6px in from the row's own left edge (it's
-- anchored off row.icon, which sits at x=6 - see the row-building loop
-- below), so the row needs that same 6px back on its right side too, or the
-- last button's right edge lands 6px past the scroll area's clip boundary,
-- right where the scrollbar sits - plus a little extra so the button isn't
-- flush against that clip edge either.
local RESPONSE_ROW_ICON_INSET = 6;
local RESPONSE_ROW_RIGHT_PADDING = RESPONSE_ROW_ICON_INSET + 10;

-- Little "did something just happen" bounce for the Sent indicator.
local SENT_JUMP_HEIGHT = 6;
local SENT_JUMP_DURATION = 0.12;

-- Key this window's saved position is stored under (see Settings.GetWindowPosition/SetWindowPosition).
local POSITION_KEY = "lootCouncilResponseWindow";

local frame, scrollChild, separator;
-- Indexed by item.session (NOT by sorted display position) so a row's
-- widget identity - and in particular its note EditBox's in-progress text -
-- never gets reassigned to a different item just because some other item
-- ahead of it in session order crossed into "Responded" and reshuffled
-- display order.
local rows = {};

-- Computed once in ensureFrame() (see computeLayout) since the window's
-- width depends on the current response option set's label widths
-- (Constants.LOOT_COUNCIL_RESPONSES) - fixed for the addon's lifetime today
-- (the option list only changes with a reload), but this keeps the layout
-- correct automatically if that list's contents ever change without anyone
-- having to also hand-tune a hardcoded pixel width here.
local WINDOW_WIDTH, RESPONSE_BUTTON_WIDTH;

-- Responded items start tucked away every time the window is (re)opened -
-- reset in Show() below, not persisted.
local respondedExpanded = false;

-- "Add a note" placeholder only reads while the box is both empty and
-- unfocused - hidden the moment either stops being true, so it never sits
-- behind the player's cursor or their actual note text.
local function updateNotePlaceholder(noteBox)
    noteBox.placeholderText:SetShown(noteBox:GetText() == "" and not noteBox:HasFocus());
end

local function measureLabelWidth(label)
    local probe = FL.Theme.CreateButton(UIParent);
    FL.Theme.SkinButton(probe);
    probe:SetText(label);
    probe:Hide();
    local fontString = probe:GetFontString();
    return fontString and fontString:GetStringWidth() or 0;
end

-- Real rendered line height of the item-name font, so the response-button
-- row can be placed below it without guessing a pixel value that could drift
-- from the actual font (see computeLayout below).
local function measureItemTextHeight()
    local probe = UIParent:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightLarge);
    probe:SetText("Placeholder");
    probe:Hide();
    return probe:GetStringHeight();
end

local function computeLayout()
    local maxLabelWidth = 0;
    for _, entry in ipairs(Constants.LOOT_COUNCIL_RESPONSES) do
        maxLabelWidth = math.max(maxLabelWidth, measureLabelWidth(entry.label));
    end

    local numButtons = math.max(#Constants.LOOT_COUNCIL_RESPONSES, 1);
    RESPONSE_BUTTON_WIDTH = math.max(maxLabelWidth + RESPONSE_BUTTON_LABEL_PADDING, MIN_RESPONSE_BUTTON_WIDTH);
    local contentWidth = numButtons * RESPONSE_BUTTON_WIDTH + (numButtons - 1) * BUTTON_GAP;
    WINDOW_WIDTH = contentWidth + RESPONSE_ROW_RIGHT_PADDING + WINDOW_LEFT_MARGIN + WINDOW_RIGHT_MARGIN;

    local iconColumnBottom = ROW_TOP_INSET + ICON_SIZE;
    local textColumnBottom = ROW_TOP_INSET + measureItemTextHeight() + ITEM_TEXT_TO_NOTE_GAP + NOTE_BOX_HEIGHT;
    BUTTONS_TOP_INSET = math.max(iconColumnBottom, textColumnBottom) + NOTE_TO_BUTTONS_GAP;
    ROW_HEIGHT = BUTTONS_TOP_INSET + RESPONSE_BUTTON_HEIGHT + ROW_BOTTOM_PADDING;
end

local function ensureFrame()
    if (frame) then return; end

    computeLayout();

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);
    frame = FL.Theme.CreateWindow("ForeverLootLootCouncilResponseWindow", WINDOW_WIDTH,
        FL.Settings.GetLootCouncilResponseWindowHeight() or DEFAULT_HEIGHT,
        savedPosition and savedPosition.x or 0, savedPosition and savedPosition.y or 0,
        function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    frame:Hide();

    local title = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.title);
    title:SetPoint("TOP", 0, -10);
    title:SetText("ForeverLoot Council - Respond");

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton");
    closeButton:SetSize(20, 20);
    closeButton:SetPoint("TOPRIGHT", -4, -4);
    closeButton:SetScript("OnClick", function() frame:Hide(); end);
    FL.Theme.SkinCloseButton(closeButton);

    local scrollFrame = FL.Theme.CreateScrollFrame(frame);
    scrollFrame:SetPoint("TOPLEFT", WINDOW_LEFT_MARGIN, -34);
    scrollFrame:SetPoint("BOTTOMRIGHT", -WINDOW_RIGHT_MARGIN, 12);
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

    separator = CreateFrame("Button", nil, scrollChild);
    separator:SetHeight(SEPARATOR_HEIGHT);
    separator:SetPoint("LEFT", scrollChild, "LEFT");
    separator:RegisterForClicks("LeftButtonUp");
    local separatorHighlight = separator:CreateTexture(nil, "HIGHLIGHT");
    separatorHighlight:SetAllPoints(separator);
    separatorHighlight:SetColorTexture(1, 1, 1, 0.08);
    separator:SetHighlightTexture(separatorHighlight);
    local separatorText = separator:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.disableSmall);
    separatorText:SetPoint("CENTER");
    separatorText:SetText("Click to change selections");
    separator:SetScript("OnClick", function()
        respondedExpanded = not respondedExpanded;
        ResponseWindow.Refresh();
    end);
    separator:Hide();

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, scrollChild);
        row:SetHeight(ROW_HEIGHT);
        row:Hide();

        row.icon = row:CreateTexture(nil, "ARTWORK");
        row.icon:SetSize(ICON_SIZE, ICON_SIZE);
        row.icon:SetPoint("TOPLEFT", 6, -ROW_TOP_INSET);
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

        row.itemText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightLarge);
        row.itemText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0);
        row.itemText:SetPoint("RIGHT", row, "RIGHT", -60, 0);
        row.itemText:SetJustifyH("LEFT");
        row.itemText:SetWordWrap(false);

        -- Directly under the item name, next to the icon - not under the
        -- icon itself, and not below the response buttons.
        row.noteBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate");
        row.noteBox:SetSize(1, NOTE_BOX_HEIGHT); -- width set by anchors below
        row.noteBox:SetPoint("TOPLEFT", row.itemText, "BOTTOMLEFT", 6, -ITEM_TEXT_TO_NOTE_GAP);
        row.noteBox:SetPoint("RIGHT", row, "RIGHT", -4, 0);
        row.noteBox:SetAutoFocus(false);
        row.noteBox:SetMaxLetters(80);
        row.noteBox:SetFontObject(_G[FL.Theme.fonts.input]);
        row.noteBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); end);
        row.noteBox:SetScript("OnEditFocusGained", function(self)
            self.textAtFocus = self:GetText();
            updateNotePlaceholder(self);
        end);
        -- Re-submits the existing response with the edited note whenever the
        -- note box loses focus (which also covers Enter, via ClearFocus
        -- above) - but only if the text actually changed, and only if this
        -- item already has a response to resubmit (nothing to send otherwise).
        row.noteBox:SetScript("OnEditFocusLost", function(self)
            updateNotePlaceholder(self);
            local parentRow = self:GetParent();
            local newText = self:GetText();
            if (not parentRow.entry or newText == self.textAtFocus) then return; end
            local myName = Util.stripRealm(Util.UnitName("player"));
            local candidate = parentRow.entry.candidates[myName];
            if (not candidate) then return; end
            LootCouncil.SubmitResponse(parentRow.entry.session, candidate.response, newText);
        end);
        row.noteBox:SetScript("OnTextChanged", updateNotePlaceholder);
        FL.Theme.SkinEditBox(row.noteBox);

        row.noteBox.placeholderText = row.noteBox:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.disableSmall);
        row.noteBox.placeholderText:SetPoint("LEFT", row.noteBox, "LEFT", row.noteBox:GetTextInsets(), 0);
        row.noteBox.placeholderText:SetJustifyH("LEFT");
        row.noteBox.placeholderText:SetText("Add a note");
        updateNotePlaceholder(row.noteBox);

        -- Text set dynamically each Refresh (see below) - "Sent" or, if the
        -- last send attempt errored, a red "Failed to send".
        row.sentText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
        row.sentText:SetPoint("TOPRIGHT", -4, -4);
        row.sentText:Hide();

        -- Little up-then-back-down bounce, played whenever this row's
        -- response is (re)sent (see the lastSignature tracking in Refresh).
        row.sentAnim = row.sentText:CreateAnimationGroup();
        local jumpUp = row.sentAnim:CreateAnimation("Translation");
        jumpUp:SetOffset(0, SENT_JUMP_HEIGHT);
        jumpUp:SetDuration(SENT_JUMP_DURATION);
        jumpUp:SetOrder(1);
        jumpUp:SetSmoothing("OUT");
        local jumpDown = row.sentAnim:CreateAnimation("Translation");
        jumpDown:SetOffset(0, -SENT_JUMP_HEIGHT);
        jumpDown:SetDuration(SENT_JUMP_DURATION);
        jumpDown:SetOrder(2);
        jumpDown:SetSmoothing("IN");

        row.responseButtons = {};
        local previousButton;
        for _, entry in ipairs(Constants.LOOT_COUNCIL_RESPONSES) do
            local btn = FL.Theme.CreateButton(row);
            btn:SetSize(RESPONSE_BUTTON_WIDTH, RESPONSE_BUTTON_HEIGHT);
            if (previousButton) then
                btn:SetPoint("TOPLEFT", previousButton, "TOPRIGHT", BUTTON_GAP, 0);
            else
                -- Below whichever column runs taller - the icon, or the item
                -- name + note box (see BUTTONS_TOP_INSET in computeLayout).
                btn:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -BUTTONS_TOP_INSET);
            end
            btn:SetText(entry.label);
            btn.responseId = entry.id;
            btn.color = entry.color;
            FL.Theme.SkinButton(btn, entry.color);
            btn:SetScript("OnClick", function(self)
                local parentRow = self:GetParent();
                if (not parentRow.entry) then return; end
                -- Always sends, even if this response is already selected -
                -- re-clicking the current response is the only way to push a
                -- note-only edit, since there's no separate "save note"
                -- control. Do NOT early-return on "already selected".
                LootCouncil.SubmitResponse(parentRow.entry.session, self.responseId, parentRow.noteBox:GetText());
            end);

            table.insert(row.responseButtons, btn);
            previousButton = btn;
        end

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

        rows[i] = row;
    end

    FL.Theme.MakeBottomResizable(frame, WINDOW_WIDTH, minHeight, MAX_HEIGHT, function(height)
        FL.Settings.SetLootCouncilResponseWindowHeight(height);
    end);
end

function ResponseWindow.Refresh()
    if (not frame) then return; end

    local Session = LootCouncil.CurrentSession;
    if (not Session) then
        for _, row in ipairs(rows) do row:Hide(); end
        separator:Hide();
        scrollChild:SetHeight(1);
        return;
    end

    local myName = Util.stripRealm(Util.UnitName("player"));

    -- sorted[] determines each row's Y-order only; row WIDGET identity is
    -- always rows[item.session], never sorted position (see comment above
    -- the `rows` declaration).
    local sorted = {};
    for _, item in ipairs(Session.items) do
        table.insert(sorted, item);
    end
    table.sort(sorted, function(a, b)
        local aCandidate, bCandidate = a.candidates[myName], b.candidates[myName];
        if ((aCandidate ~= nil) ~= (bCandidate ~= nil)) then
            return aCandidate == nil; -- pending before responded
        end
        if (not aCandidate) then
            -- A send that failed (see LootCouncil.SubmitResponse) stays
            -- pending, but sinks to the bottom of the pending group rather
            -- than sitting at its normal session-order spot, so it doesn't
            -- masquerade as an item nobody has touched yet.
            local aFailed, bFailed = a.sendFailed == true, b.sendFailed == true;
            if (aFailed ~= bFailed) then
                return bFailed;
            end
            return a.session < b.session;
        end
        if (aCandidate.respondedAt == bCandidate.respondedAt) then
            return a.session < b.session; -- tiebreak: GetServerTime() has 1s resolution
        end
        return aCandidate.respondedAt < bCandidate.respondedAt;
    end);

    local pendingCount = 0;
    for _, item in ipairs(sorted) do
        if (not item.candidates[myName]) then
            pendingCount = pendingCount + 1;
        end
    end
    local respondedCount = #sorted - pendingCount;

    local usedSessions = {};
    for position, item in ipairs(sorted) do
        local row = rows[item.session];
        if (row) then
            usedSessions[item.session] = true;

            local isPending = position <= pendingCount;
            local visible = isPending or respondedExpanded;

            if (visible) then
                local y;
                if (isPending) then
                    y = -(position - 1) * ROW_HEIGHT;
                else
                    y = -(pendingCount * ROW_HEIGHT + SEPARATOR_HEIGHT + (position - pendingCount - 1) * ROW_HEIGHT);
                end
                row:ClearAllPoints();
                row:SetPoint("TOPLEFT", 0, y);
                row:SetPoint("RIGHT", scrollChild, "RIGHT");
            end

            row.entry = item;
            row.icon:SetTexture(item.itemIcon or FALLBACK_ICON);
            FL.Theme.SetIconBorderQuality(row.iconBorder, item.itemQuality);
            row.itemText:SetText(item.itemName and Util.qualityColoredItemName("[" .. item.itemName .. "]", item.itemQuality)
                or item.itemLink or "?");

            local candidate = item.candidates[myName];
            if (item.awardedTo) then
                row.sentText:SetText("|cff888888Awarded|r");
                row.sentText:Show();
            elseif (item.sendFailed) then
                row.sentText:SetText("|cffff4444Failed to send|r");
                row.sentText:Show();
            elseif (candidate) then
                row.sentText:SetText("|cff33ff33Sent|r");
                row.sentText:Show();
            else
                row.sentText:Hide();
            end

            -- Only ever (re)set on the first render of THIS session's data
            -- for this row - never on a later refresh, so an in-progress,
            -- unsent note is never clobbered by an unrelated event (another
            -- raider's response, a late item-icon arrival, etc.).
            local signature = candidate and (candidate.response .. "\30" .. candidate.note) or nil;
            if (row.sessionId ~= Session.id) then
                row.noteBox:SetText(candidate and candidate.note or "");
                updateNotePlaceholder(row.noteBox);
                row.sessionId = Session.id;
                row.lastSignature = signature; -- baseline - no jump on first render
            elseif (signature ~= row.lastSignature) then
                row.lastSignature = signature;
                if (candidate) then
                    row.sentAnim:Stop();
                    row.sentAnim:Play();
                end
            end

            for _, btn in ipairs(row.responseButtons) do
                if (candidate and btn.responseId ~= candidate.response) then
                    FL.Theme.SkinButton(btn, Constants.LOOT_COUNCIL_RESPONSE_UNSELECTED_COLOR);
                else
                    FL.Theme.SkinButton(btn, btn.color);
                end
                if (item.awardedTo) then btn:Disable(); else btn:Enable(); end
            end

            row:SetShown(visible);
        end
    end

    for session, row in pairs(rows) do
        if (not usedSessions[session]) then
            row.entry = nil;
            row:Hide();
        end
    end

    if (respondedCount > 0) then
        separator:ClearAllPoints();
        separator:SetPoint("TOPLEFT", 0, -(pendingCount * ROW_HEIGHT));
        separator:SetPoint("RIGHT", scrollChild, "RIGHT");
        separator:Show();
    else
        separator:Hide();
    end

    local visibleRespondedCount = respondedExpanded and respondedCount or 0;
    local totalHeight = pendingCount * ROW_HEIGHT + visibleRespondedCount * ROW_HEIGHT
        + (respondedCount > 0 and SEPARATOR_HEIGHT or 0);
    scrollChild:SetHeight(math.max(totalHeight, 1));
end

--- Opens the window if the local player still hasn't responded to at least
--- one item in the current session. Called from applySessionStart so the
--- window auto-pops on a genuinely new session, without forcing itself open
--- on a catch-up/re-sync sessionStart where everything's already answered.
function ResponseWindow.MaybeAutoShow()
    local Session = LootCouncil.CurrentSession;
    if (not Session) then return; end

    local myName = Util.stripRealm(Util.UnitName("player"));
    for _, item in ipairs(Session.items) do
        if (not item.candidates[myName]) then
            ResponseWindow.Show();
            return;
        end
    end
end

function ResponseWindow.Show()
    ensureFrame();
    respondedExpanded = false;
    frame:Show();
    ResponseWindow.Refresh();
end

function ResponseWindow.Hide()
    if (frame) then frame:Hide(); end
end

function ResponseWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then ResponseWindow.Hide(); else ResponseWindow.Show(); end
end

function ResponseWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then FL.Theme.ResetWindowPosition(frame); end
end
