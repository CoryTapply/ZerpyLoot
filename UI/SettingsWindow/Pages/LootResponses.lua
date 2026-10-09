--[[
"Loot Responses" settings page: the loot leader builds the response buttons
raiders see in the Respond popup (UI/RespondWindow.lua). All data-model rules
(kind counts, id allocation, label validation, session snapshot, history
copy) live in Core/Responses.lua - this file is UI only, always going through
those functions rather than touching FL.DB.responses.list directly.

Layout note: this page does NOT use page:Section() anywhere. SectionMethods:
Reflow() recomputes a section's frame height purely from stock row-builder
bookkeeping (self.items), and PageMethods:Layout() re-runs automatically
after every page selection - a section holding only hand-built content would
get silently collapsed back to header height. UI/SettingsWindow/Pages/
LootCouncil.lua's roster-grid page avoids this same trap by never calling
page:Section() either, building its grid as a fully manual frame and setting
page.contentBottomOverride directly - this page follows that same pattern.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Widgets = FL.UI.SettingsWidgets;
local Skin = FL.UI.Skin;
local Util = FL.Util;
local Responses = FL.Responses;
local ResponseRow = FL.UI.ResponseRow;

-- Mockup px * 0.65 scale, same convention as UI/Sizes.lua - kept page-local
-- (not added to the shared Sizes table) since nothing outside this page
-- reads them, same as UI/SettingsWindow/Pages/LootCouncil.lua's own local
-- pixel constants.
local LIST_ROW_HEIGHT = 31; -- mockup 48 * 0.65
local ROW_PAD_LEFT = 5;
local ROW_PAD_RIGHT = 6.5;
local ROW_GAP = 6.5; -- gap between a row's own elements
local DELETE_SIZE = 17;
local EDITBOX_HEIGHT = 21;
local ADD_BUTTON_GAP = 6.5;
local PREVIEW_PAD_TB = 14;
local PREVIEW_PAD_LR = 13;
local PREVIEW_GAP = 10;
local PILL_GAP = 4;

local MOG_ATLAS = "Crosshair_Transmogrify_32";
local PVP_ATLAS = "Crosshair_PVP_32";
local PASS_ATLAS = "talents-button-reset";

-- A fixed, hand-drawn mockup item - not a real item lookup - purely so the
-- preview shows a plausible Respond card without depending on live item
-- data (Util.GetItemInfo/ContinueOnItemLoad) that has nothing to do with
-- this page's own job.
local SAMPLE_ITEM_NAME = "[Venomstrike]";
local SAMPLE_ITEM_TYPE = "Bow";
local SAMPLE_ITEM_ICON = "Interface\\Icons\\INV_Weapon_Bow_07";
local SAMPLE_ITEM_QUALITY_COLOR = { 0.0, 0.44, 0.87 }; -- standard "rare" blue

local HOW_IT_WORKS_BULLETS = {
    "The popup widens to fit every label in full. It never gets narrower than the default size.",
    "Transmog, PvP, and Pass are icon-only. Transmog and PvP can go anywhere in the order or be hidden. Pass is always last.",
    "The color is the dot on the raider's button, the fill when it's picked, and the pill the council sees.",
    "Changes apply to the next session you start. A session already running keeps the buttons it started with.",
    "Profiles save different button sets. The active profile is the one your next session sends.",
};

-- Forward declarations - referenced by closures built well before their own
-- definitions further down this file (same convention UI/RespondWindow.lua
-- uses for its own note-popover functions).
local RebuildList, RebuildPreview, SchedulePreviewRebuild, Relayout, SetStatus, ClearStatus;

--------------------------------------------------------------------------
-- Small shared builders
--------------------------------------------------------------------------

--- Same heading look page:Section() draws (gold sectionHeader title + a
--- divider rule 6px below it) but as a plain frame, not a Section object -
--- see this file's own top-of-file note on why. `rightText`, if given, gets
--- its own small muted FontString right-aligned to the heading's top edge
--- (e.g. the "3 of 8 text buttons" count) - returned so the caller can keep
--- updating it.
local function buildHeading(parent, width, title, rightText)
    local frame = CreateFrame("Frame", nil, parent);
    frame:SetWidth(width);

    local titleText = frame:CreateFontString(nil, "OVERLAY");
    SetFont(titleText, "sectionHeader");
    titleText:SetTextColor(unpack(Colors.gold));
    titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    titleText:SetText(title);

    local rightFS;
    if (rightText ~= nil) then
        rightFS = frame:CreateFontString(nil, "OVERLAY");
        SetFont(rightFS, "small");
        rightFS:SetTextColor(unpack(Colors.muted));
        rightFS:SetJustifyH("RIGHT");
        rightFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
        rightFS:SetText(rightText);
    end

    local divider = frame:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -6);
    divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
    FL.Pixel.SetLineHeight(divider, 1);

    local height = titleText:GetStringHeight() + 6 + 1 + Sizes.layout.rowGap;
    frame:SetHeight(height);
    return frame, height, rightFS;
end

local function buildHowItWorks(parent, width)
    local frame = CreateFrame("Frame", nil, parent);
    frame:SetWidth(width);

    local cursorY = 0;
    for _, text in ipairs(HOW_IT_WORKS_BULLETS) do
        local bullet = frame:CreateFontString(nil, "OVERLAY");
        SetFont(bullet, "small");
        bullet:SetTextColor(unpack(Colors.disabledText));
        bullet:SetText("\226\128\162"); -- "*"
        bullet:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, cursorY);

        local body = frame:CreateFontString(nil, "OVERLAY");
        SetFont(body, "small");
        body:SetTextColor(unpack(Colors.description));
        body:SetJustifyH("LEFT");
        body:SetWidth(width - 14);
        body:SetText(text);
        body:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, cursorY);

        cursorY = cursorY - body:GetStringHeight() - 5;
    end

    frame:SetHeight(-cursorY);
    return frame;
end

--------------------------------------------------------------------------
-- Response list rows
--------------------------------------------------------------------------

local function countTextEntries(list)
    local count = 0;
    for _, entry in ipairs(list) do
        if (entry.kind == "text") then count = count + 1; end
    end
    return count;
end

local function updateEditBoxBorder(editBox, focused)
    editBox:SetBackdropBorderColor(unpack(focused and Colors.lrEditBoxFocus or Colors.lrEditBoxBorder));
end

local function flashEditBoxError(editBox)
    editBox:SetBackdropBorderColor(unpack(Colors.lrErrorFlash));
    C_Timer.After(1, function()
        if (editBox and editBox:IsShown()) then updateEditBoxBorder(editBox, editBox:HasFocus()); end
    end);
end

--- Commit-on-Enter/blur, revert-on-invalid EditBox for a "text" response's
--- label. Page-local (not a generic Skin.EditBox extension) since this
--- revert/flash/duplicate-check behavior has exactly one consumer today.
local function buildLabelEditBox(page, row, list, entry)
    local editBox = CreateFrame("EditBox", nil, row, "BackdropTemplate");
    editBox:SetHeight(EDITBOX_HEIGHT);
    Theme.Helpers.SetFlatBackdrop(editBox, Colors.lrEditBoxBg, Colors.lrEditBoxBorder, 1);
    SetFont(editBox, "body");
    editBox:SetTextColor(unpack(Colors.text));
    editBox:SetTextInsets(6, 6, 0, 0);
    editBox:SetAutoFocus(false);
    editBox:SetMaxLetters(Responses.MAX_LABEL_LENGTH);
    editBox:SetText(entry.label);

    editBox:SetScript("OnEditFocusGained", function(self)
        row.labelBeforeEdit = entry.label;
        updateEditBoxBorder(self, true);
    end);

    -- userInput is false for our own :SetText() calls below - only react to
    -- the player's own typing, so this can't recurse/fight itself.
    editBox:SetScript("OnTextChanged", function(self, userInput)
        if (not userInput) then return; end
        entry.label = self:GetText(); -- live, unvalidated - preview reflects it as-typed
        ClearStatus(page);
        SchedulePreviewRebuild(page);
    end);

    editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); end);
    editBox:SetScript("OnEscapePressed", function(self)
        entry.label = row.labelBeforeEdit or entry.label;
        self:SetText(entry.label);
        self:ClearFocus();
    end);

    editBox:SetScript("OnEditFocusLost", function(self)
        local ok, err = Responses.Rename(list, entry.id, self:GetText());
        if (ok) then
            self:SetText(entry.label);
            updateEditBoxBorder(self, false);
            ClearStatus(page);
        else
            entry.label = row.labelBeforeEdit or entry.label;
            self:SetText(entry.label);
            flashEditBoxError(self);
            SetStatus(page, "error", err);
        end
        SchedulePreviewRebuild(page);
    end);

    return editBox;
end

--- The icon+name+note group used by the Transmog/PvP/Pass rows (no EditBox).
local function buildIconGroup(row, atlasName, name, note)
    local group = CreateFrame("Frame", nil, row);
    group:SetHeight(LIST_ROW_HEIGHT);

    local icon = group:CreateTexture(nil, "ARTWORK");
    icon:SetSize(15, 15);
    icon:SetPoint("LEFT", group, "LEFT", 0, 0);
    if (C_Texture.GetAtlasInfo(atlasName)) then
        icon:SetAtlas(atlasName);
    else
        icon:Hide();
        Util.Print(("missing atlas '%s' for the %s row."):format(atlasName, name));
    end

    local nameText = group:CreateFontString(nil, "OVERLAY");
    SetFont(nameText, "body");
    nameText:SetTextColor(unpack(Colors.text));
    nameText:SetText(name);
    nameText:SetPoint("LEFT", icon, "RIGHT", ROW_GAP, 0);

    local noteText = group:CreateFontString(nil, "OVERLAY");
    SetFont(noteText, "small");
    noteText:SetTextColor(unpack(Colors.controlHover)); -- #8a8176
    noteText:SetText(note);
    noteText:SetPoint("LEFT", nameText, "RIGHT", ROW_GAP, 0);

    group:SetWidth(14 + ROW_GAP + nameText:GetStringWidth() + ROW_GAP + noteText:GetStringWidth());
    return group;
end

--- The Transmog/PvP row's "Show" checkbox (Skin.Checkbox), grouped with its
--- label into one anchorable unit.
local function buildShowCheckbox(row, checked, onChange)
    local group = CreateFrame("Frame", nil, row);

    local checkbox = CreateFrame("CheckButton", nil, group, "UICheckButtonTemplate");
    Skin.Checkbox(checkbox);
    checkbox:SetPoint("LEFT", group, "LEFT", 0, 0);
    checkbox:SetChecked(checked);
    checkbox:SetScript("OnClick", function(self) onChange(self:GetChecked() and true or false); end);

    local label = group:CreateFontString(nil, "OVERLAY");
    SetFont(label, "body");
    label:SetTextColor(unpack(Colors.text));
    label:SetText("Show");
    label:SetPoint("LEFT", checkbox, "RIGHT", Sizes.controls.checkboxLabelGap or 6, 0);

    local boxSize = Sizes.controls.checkbox;
    group:SetSize(boxSize + (Sizes.controls.checkboxLabelGap or 6) + label:GetStringWidth(), math.max(boxSize, LIST_ROW_HEIGHT));
    return group;
end

local function buildRow(page, list, entry, index)
    local row = CreateFrame("Frame", nil, page._listBox);
    row:SetHeight(LIST_ROW_HEIGHT);
    row.entry = entry;

    row.hoverBg = row:CreateTexture(nil, "BACKGROUND");
    row.hoverBg:SetTexture(Theme.Helpers.FLAT_TEXTURE);
    row.hoverBg:SetAllPoints();
    row.hoverBg:SetVertexColor(unpack(Colors.lrRowHoverBg));
    row.hoverBg:Hide();
    row:EnableMouse(true);
    row:SetScript("OnEnter", function(self) self.hoverBg:Show(); end);
    row:SetScript("OnLeave", function(self) self.hoverBg:Hide(); end);

    row.divider = row:CreateTexture(nil, "ARTWORK");
    row.divider:SetColorTexture(unpack(Colors.lrRowDivider));
    row.divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0);
    row.divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0);
    FL.Pixel.SetLineHeight(row.divider, 1);
    if (index == #list) then row.divider:Hide(); end

    row.moveArrows = Skin.MoveArrows(row, {
        upTooltip = "Move left",
        downTooltip = "Move right",
        onMoveUp = function() Responses.MoveUp(list, entry.id); RebuildList(page); end,
        onMoveDown = function() Responses.MoveDown(list, entry.id); RebuildList(page); end,
    });
    row.moveArrows:SetPoint("LEFT", row, "LEFT", ROW_PAD_LEFT, 0);

    if (entry.kind == "pass") then
        row.moveArrows:ShowLock("Pass is always last");
    else
        local nextEntry = list[index + 1];
        row.moveArrows:SetEnabledStates(index > 1, nextEntry ~= nil and nextEntry.kind ~= "pass");
    end

    row.swatch = Skin.ColorSwatch(row, {
        tooltip = "Pick a color",
        onClick = function(button)
            local palette = page._palette or Skin.ColorPalette(page.frame);
            page._palette = palette;
            if (palette:IsOpenFor(button)) then palette:Close(); return; end
            palette:Open(button, entry.color, function(hex)
                Responses.Recolor(list, entry.id, hex);
                row.swatch:SetColor(hex);
                SchedulePreviewRebuild(page);
            end, nil);
        end,
    });
    row.swatch:SetPoint("LEFT", row.moveArrows, "RIGHT", ROW_GAP, 0);
    row.swatch:SetColor(entry.color);

    if (entry.kind == "text") then
        row.deleteButton = Skin.DeleteButton(row, {
            size = DELETE_SIZE,
            disabledTooltip = "Keep at least one response",
            onClick = function()
                local label = entry.label;
                local ok = Responses.DeleteText(list, entry.id);
                if (ok) then
                    RebuildList(page);
                    SetStatus(page, "info", ("Deleted \"%s\""):format(label));
                end
            end,
        });
        row.deleteButton:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD_RIGHT, 0);
        row.deleteButton:SetEnabled(countTextEntries(list) > Responses.MIN_TEXT_RESPONSES);

        row.editBox = buildLabelEditBox(page, row, list, entry);
        row.editBox:SetPoint("LEFT", row.swatch, "RIGHT", ROW_GAP, 0);
        row.editBox:SetPoint("RIGHT", row.deleteButton, "LEFT", -ROW_GAP, 0);
    elseif (entry.kind == "mog") then
        row.checkboxGroup = buildShowCheckbox(row, entry.enabled, function(checked)
            Responses.SetMogEnabled(list, checked);
            SchedulePreviewRebuild(page);
        end);
        row.checkboxGroup:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD_RIGHT, 0);

        row.content = buildIconGroup(row, MOG_ATLAS, "Transmog", "icon only");
        row.content:SetPoint("LEFT", row.swatch, "RIGHT", ROW_GAP, 0);
    elseif (entry.kind == "pvp") then
        row.checkboxGroup = buildShowCheckbox(row, entry.enabled, function(checked)
            Responses.SetPvpEnabled(list, checked);
            SchedulePreviewRebuild(page);
        end);
        row.checkboxGroup:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD_RIGHT, 0);

        row.content = buildIconGroup(row, PVP_ATLAS, "PvP", "icon only");
        row.content:SetPoint("LEFT", row.swatch, "RIGHT", ROW_GAP, 0);
    else -- pass
        row.spacer = CreateFrame("Frame", nil, row);
        row.spacer:SetSize(DELETE_SIZE, DELETE_SIZE);
        row.spacer:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD_RIGHT, 0);

        row.content = buildIconGroup(row, PASS_ATLAS, "Pass", "icon only \194\183 always last");
        row.content:SetPoint("LEFT", row.swatch, "RIGHT", ROW_GAP, 0);
    end

    row:SetPoint("TOPLEFT", page._listBox, "TOPLEFT", 0, -(index - 1) * LIST_ROW_HEIGHT);
    row:SetPoint("TOPRIGHT", page._listBox, "TOPRIGHT", 0, -(index - 1) * LIST_ROW_HEIGHT);

    return row;
end

--------------------------------------------------------------------------
-- Preview
--------------------------------------------------------------------------

local function buildSampleCard(page)
    local RSizes = FL.UI.Sizes.respond;
    local card = CreateFrame("Frame", nil, page._stage, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(card, Colors.respondCardBg, Colors.border, 1);

    local icon = card:CreateTexture(nil, "ARTWORK");
    icon:SetSize(RSizes.iconSize, RSizes.iconSize);
    icon:SetPoint("TOPLEFT", card, "TOPLEFT", RSizes.cardPadding, -RSizes.cardPadding);
    icon:SetTexture(SAMPLE_ITEM_ICON);
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    local nameText = card:CreateFontString(nil, "OVERLAY");
    SetFont(nameText, "sectionHeader");
    nameText:SetTextColor(unpack(SAMPLE_ITEM_QUALITY_COLOR));
    nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", RSizes.iconTextGap, 0);
    nameText:SetText(SAMPLE_ITEM_NAME);

    local typeText = card:CreateFontString(nil, "OVERLAY");
    SetFont(typeText, "small");
    typeText:SetTextColor(unpack(Colors.muted));
    typeText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -RSizes.nameTypeGap);
    typeText:SetText(SAMPLE_ITEM_TYPE);

    return card;
end

local function buildPill(parent, entry)
    local ASizes = FL.UI.Sizes.award.mainPanel;
    local pill = CreateFrame("Frame", nil, parent);
    pill:SetHeight(ASizes.pillHeight);
    Skin.Pill(pill);

    pill.dot = pill:CreateTexture(nil, "ARTWORK");
    pill.dot:SetTexture("Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Dot");
    pill.dot:SetSize(ASizes.pillDotSize, ASizes.pillDotSize);
    pill.dot:SetPoint("LEFT", pill, "LEFT", ASizes.pillPadX, 0);

    pill.label = pill:CreateFontString(nil, "OVERLAY");
    pill.label:SetTextColor(unpack(Colors.text));
    pill.label:SetPoint("LEFT", pill.dot, "RIGHT", ASizes.pillDotGap, 0);

    local r, g, b = Util.HexToRGB(entry.color);
    pill:SetPillColor(r, g, b);
    pill.dot:SetVertexColor(r, g, b);

    -- Same max width as the award window's response column, so a long
    -- (renamed) label shrinks/truncates here exactly as it would there -
    -- short labels still shrink-wrap the pill rather than padding it out.
    local chrome = ASizes.pillPadX * 2 + ASizes.pillDotSize + ASizes.pillDotGap;
    Skin.FitPillLabel(pill.label, entry.label, ASizes.colResponse - chrome);
    pill:SetWidth(math.min(ASizes.colResponse, chrome + pill.label:GetStringWidth()));

    return pill;
end

RebuildPreview = function(page)
    local RSizes = FL.UI.Sizes.respond;
    local list = Responses.SessionSnapshot(); -- what a session started right now would send

    local card = page._sampleCard or buildSampleCard(page);
    page._sampleCard = card;

    local buttonsTop = RSizes.cardPadding + RSizes.iconSize + RSizes.cardSectionGap;
    local naturalRowWidth = ResponseRow.MeasureNaturalWidth(list);
    local cardWidth = math.max(RSizes.cardWidth, RSizes.cardPadding * 2 + naturalRowWidth);
    card:SetWidth(cardWidth);
    card:SetHeight(RSizes.cardPadding * 2 + RSizes.iconSize + RSizes.cardSectionGap + RSizes.buttonHeight);

    local row = ResponseRow.Build(card, list, {
        displayOnly = true,
        width = cardWidth - RSizes.cardPadding * 2,
    });
    row:ClearAllPoints();
    row:SetPoint("TOPLEFT", card, "TOPLEFT", RSizes.cardPadding, -buttonsTop);

    local innerWidth = page.contentWidth - PREVIEW_PAD_LR * 2;
    local scale = math.min(1, innerWidth / cardWidth);
    card:SetScale(scale);
    card:ClearAllPoints();
    card:SetPoint("TOP", page._stage, "TOP", 0, -PREVIEW_PAD_TB);

    -- "COUNCIL SEES" pills, wrapping left to right within innerWidth.
    for _, pill in ipairs(page._pills or {}) do pill:Hide(); pill:SetParent(nil); end
    page._pills = {};

    if (not page._councilSeesLabel) then
        local label = page._pillsAnchor:CreateFontString(nil, "OVERLAY");
        SetFont(label, "small");
        label:SetTextColor(unpack(Colors.muted));
        label:SetText("COUNCIL SEES");
        page._councilSeesLabel = label;
    end
    page._councilSeesLabel:ClearAllPoints();
    page._councilSeesLabel:SetPoint("TOPLEFT", page._pillsAnchor, "TOPLEFT", 0, 0);

    local ASizes = FL.UI.Sizes.award.mainPanel;
    local cursorX = page._councilSeesLabel:GetStringWidth() + PILL_GAP;
    local cursorY = 0;
    local rowsUsed = 1;
    for _, entry in ipairs(list) do
        local pill = buildPill(page._pillsAnchor, entry);
        local w = pill:GetWidth();
        if (cursorX + w > innerWidth and cursorX > 0) then
            cursorX = 0;
            cursorY = cursorY - (ASizes.pillHeight + PILL_GAP);
            rowsUsed = rowsUsed + 1;
        end
        pill:SetPoint("TOPLEFT", page._pillsAnchor, "TOPLEFT", cursorX, cursorY);
        cursorX = cursorX + w + PILL_GAP;
        table.insert(page._pills, pill);
    end

    local pillsRowHeight = rowsUsed * ASizes.pillHeight + (rowsUsed - 1) * PILL_GAP;
    page._pillsAnchor:SetHeight(math.max(pillsRowHeight, ASizes.pillHeight));

    local cardVisualHeight = card:GetHeight() * scale;
    page._pillsAnchor:ClearAllPoints();
    page._pillsAnchor:SetPoint("TOPLEFT", page._stage, "TOPLEFT", PREVIEW_PAD_LR, -(PREVIEW_PAD_TB + cardVisualHeight + PREVIEW_GAP));
    page._pillsAnchor:SetPoint("TOPRIGHT", page._stage, "TOPRIGHT", -PREVIEW_PAD_LR, -(PREVIEW_PAD_TB + cardVisualHeight + PREVIEW_GAP));

    page._stage:SetHeight(PREVIEW_PAD_TB * 2 + cardVisualHeight + PREVIEW_GAP + page._pillsAnchor:GetHeight());

    Relayout(page);
end

SchedulePreviewRebuild = function(page)
    if (page._previewPending) then return; end
    page._previewPending = true;
    C_Timer.After(0, function()
        page._previewPending = false;
        RebuildPreview(page);
    end);
end

--------------------------------------------------------------------------
-- List rebuild / status line / layout
--------------------------------------------------------------------------

RebuildList = function(page)
    local list = Responses.GetList();

    for _, row in ipairs(page._rows) do
        row:Hide();
        row:SetParent(nil);
    end
    page._rows = {};

    for index, entry in ipairs(list) do
        page._rows[index] = buildRow(page, list, entry, index);
    end

    page._listBox:SetHeight(math.max(1, #list * LIST_ROW_HEIGHT));

    local textCount = countTextEntries(list);
    page._countText:SetText(("%d of %d text buttons"):format(textCount, Responses.MAX_TEXT_RESPONSES));

    local canAdd = textCount < Responses.MAX_TEXT_RESPONSES;
    page._addButton:SetEnabled(canAdd);
    page._addButton:SetDisabledTooltip(not canAdd and "Up to 8 custom responses" or nil);

    RebuildPreview(page);
end

Relayout = function(page)
    local statusHeight = page._statusText:IsShown() and (page._statusText:GetStringHeight() + 6) or 0;
    local leftColumnHeight = page._leftHeadingHeight + 6 + page._descHeight
        + 8 + page._listBox:GetHeight() + ADD_BUTTON_GAP + page._addButton:GetHeight() + statusHeight;
    local rightColumnHeight = page._rightHeadingHeight + page._howItWorksHeight;

    page.contentBottomOverride = page.contentTop - page._previewHeadingHeight - page._stage:GetHeight()
        - Sizes.layout.sectionGap - math.max(leftColumnHeight, rightColumnHeight) - 20;

    FL.UI.SettingsRegistry.LayoutCurrentPage();
end

SetStatus = function(page, kind, text)
    local wasShown = page._statusText:IsShown();
    if (not kind) then
        page._statusText:Hide();
    else
        local color = (kind == "error" and Colors.lrErrorText)
            or (kind == "success" and Colors.lrSuccessText)
            or Colors.lrInfoText;
        page._statusText:SetTextColor(unpack(color));
        page._statusText:SetText(text);
        page._statusText:Show();
    end
    if (wasShown ~= page._statusText:IsShown()) then Relayout(page); end
end

ClearStatus = function(page)
    SetStatus(page, nil);
end

--------------------------------------------------------------------------
-- Footer: "Reset to Defaults" (left) + the profile switcher (right):
-- "Profile:" [dropdown] [New] [Duplicate] [Delete].
--------------------------------------------------------------------------

local PROFILE_DROPDOWN_WIDTH = 150;
local PROFILE_BUTTON_WIDTH = 70;
local PROFILE_BUTTON_GAP = 6;
local PROFILE_NAME_BOX_HEIGHT = 22;

local function getConfirmPopup(page)
    if (not page._confirmPopup) then
        page._confirmPopup = Skin.ConfirmPopup(page.frame, {});
    end
    return page._confirmPopup;
end

local RebuildProfileControls;

--- Everything a profile switch/create/delete has to refresh: the list +
--- preview, the dropdown (rebuilt - see RebuildProfileControls), and the
--- Delete button's enabled state.
local function afterProfileChange(page)
    if (page._palette) then page._palette:Close(); end
    ClearStatus(page);
    RebuildProfileControls(page);
    RebuildList(page);
end

--- Skin.Dropdown builds its popup rows once, on first open, from a fixed
--- options table - so a create/delete swaps in a brand new dropdown rather
--- than trying to patch the old one's rows.
RebuildProfileControls = function(page)
    local footer = page._profileFooter;
    if (page._profileDropdown) then
        page._profileDropdown.button:Hide();
        page._profileDropdown.button:SetParent(nil);
    end

    local options = {};
    for _, name in ipairs(Responses.GetProfileNames()) do
        table.insert(options, { value = name, label = name });
    end

    local dropdown = Skin.Dropdown(footer, {
        width = PROFILE_DROPDOWN_WIDTH,
        height = Sizes.controls.button,
        options = options,
        getValue = Responses.GetActiveProfile,
        onSelect = function(value)
            if (value == Responses.GetActiveProfile()) then return; end
            Responses.SetActiveProfile(value);
            afterProfileChange(page);
        end,
    });
    dropdown.button:SetPoint("RIGHT", page._profileNewButton, "LEFT", -PROFILE_BUTTON_GAP, 0);
    page._profileDropdown = dropdown;
    page._profileLabel:ClearAllPoints();
    page._profileLabel:SetPoint("RIGHT", dropdown.button, "LEFT", -PROFILE_BUTTON_GAP, 0);

    page._profileDeleteButton:SetEnabled(Responses.GetActiveProfile() ~= Responses.PROFILE_DEFAULT);
end

--- The single-EditBox content for the New/Duplicate name prompt - built once
--- into the shared confirm popup's dialog, re-anchored on every open.
local function ensureNameBox(page, popup)
    if (page._profileNameBox) then return page._profileNameBox, page._profileNameError; end
    local dialog = popup.dialog;

    local editBox = CreateFrame("EditBox", nil, dialog, "BackdropTemplate");
    editBox:SetHeight(PROFILE_NAME_BOX_HEIGHT);
    Theme.Helpers.SetFlatBackdrop(editBox, Colors.lrEditBoxBg, Colors.lrEditBoxBorder, 1);
    SetFont(editBox, "body");
    editBox:SetTextColor(unpack(Colors.text));
    editBox:SetTextInsets(6, 6, 0, 0);
    editBox:SetAutoFocus(false);
    editBox:SetMaxLetters(Responses.MAX_PROFILE_NAME_LENGTH);
    editBox:SetScript("OnEditFocusGained", function(self) updateEditBoxBorder(self, true); end);
    editBox:SetScript("OnEditFocusLost", function(self) updateEditBoxBorder(self, false); end);

    local errorText = dialog:CreateFontString(nil, "OVERLAY");
    SetFont(errorText, "small");
    errorText:SetTextColor(unpack(Colors.lrErrorText));
    errorText:SetJustifyH("LEFT");

    editBox:SetScript("OnTextChanged", function(self)
        local ok, err = Responses.ValidateProfileName(self:GetText());
        popup:SetConfirmEnabled(ok);
        -- An empty box just disables Create - no need to shout about it.
        errorText:SetText((not ok and Util.Trim(self:GetText()) ~= "") and err or "");
    end);
    editBox:SetScript("OnEnterPressed", function()
        if (popup.confirmButton:IsEnabled()) then popup:Confirm(); end
    end);
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus();
        popup:Hide();
    end);

    page._profileNameBox, page._profileNameError = editBox, errorText;
    return editBox, errorText;
end

--- New (sourceList nil -> default responses) or Duplicate (sourceList = the
--- active profile's list) - same name prompt, different seed.
local function promptNewProfile(page, title, suggestedName, sourceList)
    local popup = getConfirmPopup(page);
    local editBox, errorText = ensureNameBox(page, popup);

    popup.dialog.title:SetText(title);
    popup:SetButtons("Cancel", "Create", function()
        editBox:ClearFocus();
        local ok, err, name = Responses.CreateProfile(editBox:GetText(), sourceList);
        if (not ok) then SetStatus(page, "error", err); return; end
        afterProfileChange(page);
        SetStatus(page, "success", ("Switched to new profile \"%s\""):format(name));
    end, function() editBox:ClearFocus(); end);
    Skin.SetButtonVariant(popup.confirmButton, "primary");
    Skin.SetButtonVariant(popup.cancelButton, "default");

    popup:Show(function(dialog, y)
        local pad = popup.opts.padding;
        editBox:ClearAllPoints();
        editBox:SetPoint("TOPLEFT", dialog, "TOPLEFT", pad, y);
        editBox:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -pad, y);
        editBox:Show();
        y = y - PROFILE_NAME_BOX_HEIGHT - 4;

        errorText:ClearAllPoints();
        errorText:SetPoint("TOPLEFT", dialog, "TOPLEFT", pad, y);
        errorText:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -pad, y);
        errorText:SetText("");
        errorText:Show();
        return y - 14 - popup.opts.sectionGap;
    end);

    -- After Show() - it re-enables the confirm button itself, and SetText
    -- fires OnTextChanged, which sets the real enabled state.
    editBox:SetText(suggestedName);
    editBox:SetFocus();
    editBox:HighlightText();
end

--- The name box/error line live in the shared popup's dialog - hide them
--- whenever that popup is reused for a plain confirm (Reset/Delete).
local function hideNameBox(page)
    if (page._profileNameBox) then
        page._profileNameBox:Hide();
        page._profileNameError:Hide();
    end
end

local function showDangerConfirm(page, title, confirmText, onConfirm)
    local popup = getConfirmPopup(page);
    hideNameBox(page);
    popup.dialog.title:SetText(title);
    popup:SetButtons("Cancel", confirmText, onConfirm);
    Skin.SetButtonVariant(popup.confirmButton, "danger");
    Skin.SetButtonVariant(popup.cancelButton, "primary");
    popup:Show();
end

local function buildFooter(footerFrame, page)
    local resetButton = Widgets.CreateFlatButton(footerFrame, "Reset to Defaults");
    resetButton:SetSize(150, Sizes.controls.button);
    resetButton:SetPoint("LEFT", footerFrame, "LEFT", 0, 0);
    resetButton:SetScript("OnClick", function()
        showDangerConfirm(page, ("Reset \"%s\" to the default buttons?"):format(Responses.GetActiveProfile()), "Reset", function()
            Responses.ResetToDefaults();
            RebuildList(page);
        end);
    end);

    page._profileFooter = footerFrame;

    local deleteButton = Widgets.CreateFlatButton(footerFrame, "Delete");
    deleteButton:SetSize(PROFILE_BUTTON_WIDTH, Sizes.controls.button);
    deleteButton:SetPoint("RIGHT", footerFrame, "RIGHT", 0, 0);
    deleteButton:SetMotionScriptsWhileDisabled(true);
    deleteButton:HookScript("OnEnter", function(self)
        if (self:IsEnabled()) then return; end
        GameTooltip:SetOwner(self, "ANCHOR_TOP");
        GameTooltip:AddLine("The Default profile can't be deleted");
        GameTooltip:Show();
    end);
    deleteButton:HookScript("OnLeave", function(self)
        if (GameTooltip:IsOwned(self)) then GameTooltip:Hide(); end
    end);
    deleteButton:SetScript("OnClick", function()
        local name = Responses.GetActiveProfile();
        showDangerConfirm(page, ("Delete the \"%s\" profile?"):format(name), "Delete", function()
            local ok, err = Responses.DeleteProfile(name);
            if (not ok) then SetStatus(page, "error", err); return; end
            afterProfileChange(page);
            SetStatus(page, "info", ("Deleted \"%s\" - switched to %s"):format(name, Responses.GetActiveProfile()));
        end);
    end);
    page._profileDeleteButton = deleteButton;

    local duplicateButton = Widgets.CreateFlatButton(footerFrame, "Duplicate");
    duplicateButton:SetSize(PROFILE_BUTTON_WIDTH, Sizes.controls.button);
    duplicateButton:SetPoint("RIGHT", deleteButton, "LEFT", -PROFILE_BUTTON_GAP, 0);
    duplicateButton:SetScript("OnClick", function()
        local active = Responses.GetActiveProfile();
        promptNewProfile(page, "Duplicate Profile", Responses.UniqueProfileName(active .. " Copy"), Responses.GetList());
    end);

    local newButton = Widgets.CreateFlatButton(footerFrame, "New");
    newButton:SetSize(PROFILE_BUTTON_WIDTH, Sizes.controls.button);
    newButton:SetPoint("RIGHT", duplicateButton, "LEFT", -PROFILE_BUTTON_GAP, 0);
    newButton:SetScript("OnClick", function()
        promptNewProfile(page, "New Profile", Responses.UniqueProfileName("New Profile"), nil);
    end);
    page._profileNewButton = newButton;

    local profileLabel = footerFrame:CreateFontString(nil, "OVERLAY");
    SetFont(profileLabel, "small");
    profileLabel:SetTextColor(unpack(Colors.muted));
    profileLabel:SetText("Profile:");
    page._profileLabel = profileLabel;

    RebuildProfileControls(page);
end

--------------------------------------------------------------------------
-- Page assembly
--------------------------------------------------------------------------

FL.UI.SettingsWindow.RegisterPage("lootresponses", "Loot Responses", function(page)
    page:Header("Loot Responses",
        "The buttons raiders click when they respond to council loot. Your list is sent to everyone when you start a session.");

    local contentWidth = page.contentWidth;
    local colWidth = math.floor((contentWidth - Widgets.COLUMN_GAP) / 2);
    page._colWidth = colWidth;
    page._rows = {};
    page._pills = {};

    -- Preview (full width).
    local previewHeading, previewHeadingHeight = buildHeading(page.frame, contentWidth, "Preview");
    previewHeading:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, page.contentTop);
    page._previewHeadingHeight = previewHeadingHeight;

    local stage = CreateFrame("Frame", nil, page.frame, "BackdropTemplate");
    stage:SetPoint("TOPLEFT", previewHeading, "BOTTOMLEFT", 0, 0);
    stage:SetPoint("TOPRIGHT", previewHeading, "BOTTOMRIGHT", 0, 0);
    Theme.Helpers.SetFlatBackdrop(stage, Colors.controlBg, Colors.divider, 1);
    stage:SetHeight(1); -- resized by RebuildPreview once real content exists
    page._stage = stage;
    page._pillsAnchor = CreateFrame("Frame", nil, stage);
    page._pillsAnchor:SetHeight(1);

    -- 2-column row.
    local leftHeading, leftHeadingHeight, countFS = buildHeading(page.frame, colWidth, "Response Buttons", "");
    leftHeading:SetPoint("TOPLEFT", stage, "BOTTOMLEFT", 0, -Sizes.layout.sectionGap);
    page._leftHeadingHeight = leftHeadingHeight;
    page._countText = countFS;

    local rightHeading, rightHeadingHeight = buildHeading(page.frame, colWidth, "How it works");
    rightHeading:SetPoint("TOPLEFT", stage, "BOTTOMLEFT", colWidth + Widgets.COLUMN_GAP, -Sizes.layout.sectionGap);
    page._rightHeadingHeight = rightHeadingHeight;

    local descText = page.frame:CreateFontString(nil, "OVERLAY");
    SetFont(descText, "small");
    descText:SetTextColor(unpack(Colors.muted));
    descText:SetJustifyH("LEFT");
    descText:SetWidth(colWidth);
    descText:SetText("Top to bottom = left to right on the raider's popup. Labels can be up to 18 characters.");
    descText:SetPoint("TOPLEFT", leftHeading, "BOTTOMLEFT", 0, 0);
    page._descHeight = descText:GetStringHeight();

    local listBox = CreateFrame("Frame", nil, page.frame, "BackdropTemplate");
    listBox:SetWidth(colWidth);
    Theme.Helpers.SetFlatBackdrop(listBox, Colors.lrListBg, Colors.lrListBorder, 1);
    listBox:SetPoint("TOPLEFT", descText, "BOTTOMLEFT", 0, -8);
    listBox:SetHeight(1);
    page._listBox = listBox;

    local addButton = Skin.DashedAddButton(page.frame, { label = "Add Response" });
    addButton:SetWidth(colWidth);
    addButton:SetPoint("TOPLEFT", listBox, "BOTTOMLEFT", 0, -ADD_BUTTON_GAP);
    addButton:SetScript("OnClick", function()
        local list = Responses.GetList();
        local entry, err = Responses.AddText(list);
        if (not entry) then SetStatus(page, "error", err); return; end
        RebuildList(page);
        for _, row in ipairs(page._rows) do
            if (row.entry == entry and row.editBox) then
                row.editBox:SetFocus();
                row.editBox:HighlightText();
                break;
            end
        end
        SetStatus(page, "success", "Added a response. Give it a label and color.");
    end);
    page._addButton = addButton;

    local statusText = page.frame:CreateFontString(nil, "OVERLAY");
    SetFont(statusText, "small");
    statusText:SetJustifyH("LEFT");
    statusText:SetWidth(colWidth);
    statusText:SetPoint("TOPLEFT", addButton, "BOTTOMLEFT", 0, -6);
    statusText:Hide();
    page._statusText = statusText;

    local howItWorks = buildHowItWorks(page.frame, colWidth);
    howItWorks:SetPoint("TOPLEFT", rightHeading, "BOTTOMLEFT", 0, 0);
    page._howItWorksHeight = howItWorks:GetHeight();

    page.frame:HookScript("OnHide", function()
        if (page._palette) then page._palette:Close(); end
    end);

    RebuildList(page);
end, 45, { footer = buildFooter });
