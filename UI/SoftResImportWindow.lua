--[[
Paste the softres.it "Gargul Export" string here to preview, import, and
broadcast soft reserves to the raid, and to see which raid members are still
missing a reserve. Fixed-look window (see UI.Colors/UI.Sizes.softres/
UI.SetFont/UI.Skin, not FL.Theme) - built the same way as
UI/TradeQueueWindow.lua and UI/StartSessionWindow.lua. All parsing/import/
broadcast/report-missing logic lives in SoftRes.lua; this file is UI only.
]]

local FL = ForeverLoot;
local SoftResImportWindow = FL.UI.SoftResImportWindow;
local SoftRes = FL.SoftRes;
local Util = FL.Util;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.softres;
local SharedLayout = FL.UI.Sizes.layout;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Widgets = FL.UI.SettingsWidgets;

local WINDOW_WIDTH = Sizes.window.width;
local WINDOW_HEIGHT = Sizes.window.height;
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";
local DOT_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Dot.tga";
local CHECK_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Award\\Check.tga";

local PARSE_DEBOUNCE = 0.3;
local ROSTER_DEBOUNCE = 0.4;

-- Key this window's saved position is stored under (see
-- Settings.GetWindowPosition/SetWindowPosition) - unchanged from the old
-- window, so an existing saved position carries over with no migration.
local POSITION_KEY = "softResImport";

local frame;
local pasteSection, editBox, placeholderText, pasteBox, pasteScroll;
local parseDot, parseText;
local missingCard, missingLabel, reportButton, missingBody, emptyCheckIcon, emptyText;
local previewLabelRow, previewCountText, listBox, listScroll, listScrollChild, previewEmptyText;
local statusDot, statusText, clearButton, importButton;
local rosterWatcher;

local tagPool = {};
local rows = {}; -- shared pool: row 1 may be the Hard Reserves row, the rest are player rows

-- Debounce/race state. parseGeneration invalidates any in-flight
-- C_Timer.After callback that's since been superseded by newer text, a
-- Clear, or a SyncExternalImport.
local parseGeneration = 0;
local pendingRosterRefresh = false;
local lastParseResult, lastParseOK = nil, false;

-- Forward-declared: these reference each other and are wired up by widgets
-- built earlier in the file (the paste box's OnTextChanged, the list's
-- OnSizeChanged, the roster watcher's OnEvent).
local refreshPreview, refreshMissingCard, refreshFooterButtons, reflowSections, applyMissingCardVisibility, scheduleParse, runParse;

--------------------------------------------------------------------------
-- Status line (mirrors TradeQueueWindow.lua's SetStatus exactly)
--------------------------------------------------------------------------

local STATUS_KIND_COLOR = {
    error = Colors.sessionDeleteHoverIcon,
    success = Colors.respondSentLabel,
    info = Colors.description,
};

local function SetStatus(kind, text)
    local color = STATUS_KIND_COLOR[kind] or Colors.description;
    statusText:SetText(text or "");
    statusText:SetTextColor(unpack(color));
    statusDot:SetVertexColor(unpack(color));
    statusDot:SetShown(text ~= nil and text ~= "");
end

--------------------------------------------------------------------------
-- Missing-reserves computation - local/UI-only, NOT SoftRes.PlayersWithout
-- SoftReserves(): that function reads SoftRes.DetailsByPlayerName, which
-- only reflects the last COMMITTED import, but this card must react to
-- whatever is currently parsed in the paste box, committed or not. Mirrors
-- the same lowercase-exact-name matching rule SoftRes.lua's own
-- materialize()/PlayersWithoutSoftReserves() use.
--------------------------------------------------------------------------

local function computeMissingFromParsed(result)
    local reserved = {};
    for _, entry in pairs((result and result.SoftReserves) or {}) do
        reserved[string.lower(strtrim(entry.name or ""))] = true;
    end

    local missing = {};
    for name, classToken in pairs(Util.groupMembers()) do
        if (not reserved[string.lower(strtrim(name))]) then
            table.insert(missing, { name = name, classToken = classToken });
        end
    end
    table.sort(missing, function(a, b) return string.lower(a.name) < string.lower(b.name); end);
    return missing;
end

--------------------------------------------------------------------------
-- Item icon quality border - async-safe. Guards against a recycled row/icon
-- having since moved on to a different item by the time ContinueOnItemLoad
-- fires, same guard the old window used.
--------------------------------------------------------------------------

-- Util.GetItemQualityColor errors on a nil quality (it's a thin wrapper over
-- C_Item.GetItemQualityColor, which requires one) - an uncached item's
-- quality isn't known yet, so this only paints once quality is actually
-- available, leaving the border as whatever it last was (or transparent, for
-- a freshly recycled icon) until then.
local function paintIconQuality(iconButton, itemID)
    local quality = Util.GetItemQuality(itemID);
    if (not quality) then return; end

    local r, g, b = Util.GetItemQualityColor(quality);
    iconButton.iconBorder:SetBackdropBorderColor(r or 0, g or 0, b or 0);
end

local function setIconQuality(iconButton, itemID)
    if (Util.GetItemQuality(itemID)) then
        paintIconQuality(iconButton, itemID);
        return;
    end

    iconButton.iconBorder:SetBackdropBorderColor(0, 0, 0, 0);
    Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
        if (iconButton.itemID == itemID) then
            paintIconQuality(iconButton, itemID);
        end
    end);
end

--------------------------------------------------------------------------
-- Preview row icons - pooled per row, wrap onto multiple lines instead of
-- truncating with "+N more".
--------------------------------------------------------------------------

local function createRowIcon(row)
    local iconButton = CreateFrame("Button", nil, row);
    iconButton:SetSize(Sizes.preview.iconSize, Sizes.preview.iconSize);

    iconButton.texture = iconButton:CreateTexture(nil, "ARTWORK");
    iconButton.texture:SetAllPoints(iconButton);
    iconButton.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    iconButton.iconBorder = CreateFrame("Frame", nil, iconButton, "BackdropTemplate");
    iconButton.iconBorder:SetPoint("TOPLEFT", iconButton, "TOPLEFT", -1, 1);
    iconButton.iconBorder:SetPoint("BOTTOMRIGHT", iconButton, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(iconButton.iconBorder, nil, Colors.transparent, 1);

    iconButton:SetScript("OnEnter", function(self)
        if (not self.itemID) then return; end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:SetItemByID(self.itemID);
        GameTooltip:Show();
    end);
    iconButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    iconButton:RegisterForClicks("LeftButtonUp");
    iconButton:SetScript("OnClick", function(self)
        if (not self.itemID) then return; end
        Util.HandleItemLinkClick(select(2, Util.GetItemInfo(self.itemID)));
    end);

    iconButton:Hide();
    return iconButton;
end

local function ensureIconCount(row, n)
    for i = #row.icons + 1, n do
        row.icons[i] = createRowIcon(row);
    end
end

-- Lays icons out in a grid within `availableWidth`, wrapping onto as many
-- lines as needed, and returns the pixel height that grid occupies (used by
-- the caller to grow the row to fit).
local function layoutRowIcons(row, itemIDs, availableWidth)
    local iconSize, gap = Sizes.preview.iconSize, Sizes.preview.iconSpacing;
    local perLine = math.max(1, math.floor((availableWidth + gap) / (iconSize + gap)));
    local count = #itemIDs;
    local lines = (count > 0) and math.ceil(count / perLine) or 0;
    local iconBlockHeight = (lines > 0) and (lines * iconSize + (lines - 1) * gap) or 0;

    ensureIconCount(row, count);
    for i, iconButton in ipairs(row.icons) do
        local itemID = itemIDs[i];
        if (itemID) then
            local col = (i - 1) % perLine;
            local line = math.floor((i - 1) / perLine);
            iconButton:ClearAllPoints();
            iconButton:SetPoint("TOPLEFT", row.iconArea, "TOPLEFT", col * (iconSize + gap), -line * (iconSize + gap));
            iconButton.itemID = itemID;
            iconButton.texture:SetTexture(Util.GetItemIcon(itemID) or FALLBACK_ICON);
            setIconQuality(iconButton, itemID);
            iconButton:Show();
        else
            iconButton.itemID = nil;
            iconButton:Hide();
        end
    end

    return iconBlockHeight;
end

--------------------------------------------------------------------------
-- Preview rows - one shared, grow-only pool for BOTH row shapes (Hard
-- Reserves vs. a player), since only one shape occupies any given pool slot
-- at a time. nameText's anchor is fixed (set once in createRow), so a slot
-- recycled from one shape to the other never needs re-anchoring; iconArea's
-- anchor is NOT fixed - see positionIconArea below.
--------------------------------------------------------------------------

-- Centers the icon grid vertically against the name block (which may now be
-- 1-2 wrapped lines, plus the "Not in your group" line) - the name block
-- itself always stays top-anchored at rowPadding, only the icon area moves.
local function positionIconArea(row, nameBlockHeight, iconBlockHeight)
    local yOffset = Sizes.preview.rowPadding + math.max(0, (nameBlockHeight - iconBlockHeight) / 2);
    row.iconArea:ClearAllPoints();
    row.iconArea:SetPoint("TOPLEFT", row, "TOPLEFT",
        Sizes.preview.rowPadding + Sizes.preview.rowNameWidth + Sizes.preview.rowNameIconGap, -yOffset);
end

local function paintHardReserveRow(row, hardReserves, iconAreaWidth)
    row.isHardReserve = true;
    Theme.Helpers.SetFlatBackdrop(row, Colors.awardWarningBg, Colors.awardWarningBorder, 1);
    row:SetAlpha(1);
    row.labelButton:EnableMouse(true);

    row.nameText:SetText("Hard Reserves");
    row.nameText:SetTextColor(unpack(Colors.sessionDeleteHoverIcon));
    row.subText:Hide();

    local itemIDs = {};
    for _, entry in ipairs(hardReserves) do table.insert(itemIDs, entry.id); end
    local iconBlockHeight = layoutRowIcons(row, itemIDs, iconAreaWidth);

    local nameBlockHeight = row.nameText:GetStringHeight();
    positionIconArea(row, nameBlockHeight, iconBlockHeight);

    local rowHeight = math.max(Sizes.preview.rowMinHeight,
        Sizes.preview.rowPadding * 2 + math.max(nameBlockHeight, iconBlockHeight));
    row:SetHeight(rowHeight);
end

local function paintPlayerRow(row, entry, members, iconAreaWidth)
    row.isHardReserve = false;
    Theme.Helpers.SetFlatBackdrop(row, Colors.memberBg, Colors.memberBorder, 1);
    row.labelButton:EnableMouse(false);

    local matchedName, matchedClass = Util.findMember(members, entry.name);
    local softresClassToken = entry.class and Util.classNameToToken(entry.class);
    local isAutoLinked = SoftRes.RenamedNames[entry.name];
    -- An auto-linked entry's own softres.it class selection may belong to
    -- the wrong player (that's exactly what the mismatch warning below is
    -- for) - color it by the linked character's real in-game class instead,
    -- falling back the same way a non-linked row does if that's unknown.
    local classToken = (isAutoLinked and matchedClass) or softresClassToken or matchedClass;

    row.nameText:SetTextColor(unpack(Colors.text));
    row.nameText:SetText(Util.classColoredName(entry.name, classToken));

    local inGroup = matchedName ~= nil;
    row:SetAlpha(inGroup and 1 or Sizes.preview.rowNotInGroupAlpha);

    -- Auto-renamed by SoftRes.lua's fixPlayerNames() fuzzy-name matching AND
    -- the class picked on softres.it doesn't match the linked character's
    -- actual class - that combination means the fuzzy match may have paired
    -- the wrong two players, so flag it instead of silently trusting it.
    local classMismatch = inGroup and isAutoLinked
        and softresClassToken and matchedClass and softresClassToken ~= matchedClass;

    if (not inGroup) then
        row.subText:SetTextColor(unpack(Colors.controlHover));
        row.subText:SetText("Not in your group");
        row.subText:Show();
    elseif (classMismatch) then
        row.subText:SetTextColor(unpack(Colors.softresMissingLabel));
        row.subText:SetText("Auto-linked - softres class doesn't match");
        row.subText:Show();
    elseif (inGroup and isAutoLinked) then
        row.subText:SetTextColor(unpack(Colors.softresMissingLabel));
        row.subText:SetText("Auto-linked");
        row.subText:Show();
    else
        row.subText:Hide();
    end

    local iconBlockHeight = layoutRowIcons(row, entry.Items, iconAreaWidth);

    local nameHeight = row.nameText:GetStringHeight();
    local nameBlockHeight = row.subText:IsShown()
        and (nameHeight + Sizes.preview.rowSubLineGap + row.subText:GetHeight())
        or nameHeight;
    positionIconArea(row, nameBlockHeight, iconBlockHeight);

    local rowHeight = math.max(Sizes.preview.rowMinHeight,
        Sizes.preview.rowPadding * 2 + math.max(nameBlockHeight, iconBlockHeight));
    row:SetHeight(rowHeight);
end

local function createRow(parent)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate");
    row:SetPoint("RIGHT", parent, "RIGHT");
    Theme.Helpers.SetFlatBackdrop(row, Colors.memberBg, Colors.memberBorder, 1);

    row.nameText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.nameText, "body");
    row.nameText:SetPoint("TOPLEFT", row, "TOPLEFT", Sizes.preview.rowPadding, -Sizes.preview.rowPadding);
    row.nameText:SetWidth(Sizes.preview.rowNameWidth);
    row.nameText:SetWordWrap(true);
    row.nameText:SetMaxLines(2);
    row.nameText:SetNonSpaceWrap(false);
    row.nameText:SetJustifyH("LEFT");

    -- Text/color are set per-paint in paintPlayerRow - this line can show
    -- either "Not in your group" or an auto-rename class-mismatch warning.
    row.subText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.subText, "small");
    row.subText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -Sizes.preview.rowSubLineGap);
    row.subText:SetWidth(Sizes.preview.rowNameWidth);
    row.subText:SetJustifyH("LEFT");
    row.subText:Hide();

    -- Only active (mouse-enabled) for the Hard Reserves row - see
    -- paintHardReserveRow/paintPlayerRow.
    row.labelButton = CreateFrame("Button", nil, row);
    row.labelButton:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);
    row.labelButton:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0);
    row.labelButton:SetWidth(Sizes.preview.rowPadding + Sizes.preview.rowNameWidth);
    row.labelButton:EnableMouse(false);
    row.labelButton:SetScript("OnEnter", function(self)
        if (not row.isHardReserve) then return; end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:AddLine("Hard reserved: nobody can roll on these.", 1, 1, 1, true);
        GameTooltip:Show();
    end);
    row.labelButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    -- Zero-size anchor marking the icon grid's own TOPLEFT - keeps
    -- layoutRowIcons' math independent of whether this row is currently a
    -- Hard Reserves row or a player row, since both share the same left
    -- column width.
    row.iconArea = CreateFrame("Frame", nil, row);
    row.iconArea:SetSize(1, 1);
    row.iconArea:SetPoint("TOPLEFT", row, "TOPLEFT",
        Sizes.preview.rowPadding + Sizes.preview.rowNameWidth + Sizes.preview.rowNameIconGap,
        -Sizes.preview.rowPadding);

    row.icons = {};

    row:Hide();
    return row;
end

-- Returns true if the pool actually grew (new row widgets were created).
local function ensureRowCount(n)
    local grew = false;
    for i = #rows + 1, n do
        rows[i] = createRow(listScrollChild);
        grew = true;
    end
    return grew;
end

--------------------------------------------------------------------------
-- Missing-reserves card - name tag pool (wrapping flow layout) + empty state
--------------------------------------------------------------------------

local function createTag(parent)
    local tag = CreateFrame("Frame", nil, parent, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(tag, Colors.memberBg, Colors.memberBorder, 1);
    tag:SetHeight(Sizes.card.tagHeight);

    tag.text = tag:CreateFontString(nil, "OVERLAY");
    SetFont(tag.text, "body");
    tag.text:SetPoint("LEFT", tag, "LEFT", Sizes.card.tagPadX, 0);
    tag.text:SetPoint("RIGHT", tag, "RIGHT", -Sizes.card.tagPadX, 0);
    tag.text:SetJustifyH("LEFT");
    tag.text:SetWordWrap(false);

    tag:Hide();
    return tag;
end

-- Returns true if the pool actually grew (new FontStrings were created).
local function ensureTagCount(n)
    local grew = false;
    for i = #tagPool + 1, n do
        tagPool[i] = createTag(missingBody);
        grew = true;
    end
    return grew;
end

-- Hand-rolled wrap flow (no existing precedent in this codebase - every
-- other tag/pill list here is a single fixed row) - walks a cursor left to
-- right, wrapping to a new line whenever the next tag would overflow the
-- card's own width. Returns the total height the flow used.
local function layoutTags(missing)
    local n = #missing;
    -- A brand-new FontString's GetStringWidth() can read 0 (or stale) on the
    -- very same tick it's first shown - a known WoW quirk. When the pool just
    -- grew, this pass may size some tags off that bad measurement, so a
    -- one-frame-later re-layout self-corrects them once the client has
    -- actually rendered them once.
    local grew = ensureTagCount(n);
    if (grew) then
        C_Timer.After(0, function()
            if (lastParseResult) then refreshMissingCard(); end
        end);
    end

    local availableWidth = math.max(1, missingBody:GetWidth());
    local cursorX, cursorY = 0, 0;
    local lineHeight = Sizes.card.tagHeight;

    for i, tag in ipairs(tagPool) do
        local info = missing[i];
        if (info) then
            tag.text:SetTextColor(unpack(Colors.text));
            tag.text:SetText(Util.classColoredName(info.name, info.classToken));

            local tagWidth = math.min(availableWidth, Sizes.card.tagPadX * 2 + tag.text:GetStringWidth());
            tag:SetWidth(tagWidth);

            if (cursorX > 0 and cursorX + tagWidth > availableWidth) then
                cursorX = 0;
                cursorY = cursorY + lineHeight + Sizes.card.tagSpacing;
            end

            tag:ClearAllPoints();
            tag:SetPoint("TOPLEFT", missingBody, "TOPLEFT", cursorX, -cursorY);
            tag:Show();

            cursorX = cursorX + tagWidth + Sizes.card.tagSpacing;
        else
            tag:Hide();
        end
    end

    return (n > 0) and (cursorY + lineHeight) or 0;
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
    title:SetText("ForeverLoot - Import SoftRes");
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
        FL.NotifyWindowClosed("SoftResImport");
        frame:Hide();
    end);

    return titleBar;
end

local function createHeader()
    local header = CreateFrame("Frame", nil, frame);
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.contentPadX, -(Sizes.titleBarHeight + Sizes.contentPadTop));
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.contentPadX, -(Sizes.titleBarHeight + Sizes.contentPadTop));
    header:SetHeight(Sizes.header.titleHeight + Sizes.header.subtitleGap + Sizes.header.subtitleHeight);

    local title = header:CreateFontString(nil, "OVERLAY");
    SetFont(title, "pageTitle");
    title:SetTextColor(unpack(Colors.gold));
    title:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0);
    title:SetText("Import SoftRes");

    local subtitle = header:CreateFontString(nil, "OVERLAY");
    SetFont(subtitle, "small");
    subtitle:SetTextColor(unpack(Colors.muted));
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -Sizes.header.subtitleGap);
    subtitle:SetPoint("RIGHT", header, "RIGHT", 0, 0);
    subtitle:SetJustifyH("LEFT");
    subtitle:SetText("Paste the softres.it \"Gargul Export\" string below.");

    return header;
end

local function updatePlaceholder()
    placeholderText:SetShown(editBox:GetText() == "" and not editBox:HasFocus());
end

-- No existing modern window has a multi-line paste box (Skin.EditBox is
-- built for the single-line search box's SearchBoxTemplate, which this bare
-- EditBox doesn't have), so this hand-rolls the placeholder/focus-border/
-- click-forwarding behavior Skin.EditBox would normally give for free.
local function createPasteSection()
    local section = CreateFrame("Frame", nil, frame);
    section:SetHeight(Sizes.paste.boxHeight + Sizes.paste.parseLineGap + Sizes.paste.parseLineHeight);

    pasteBox = CreateFrame("Frame", nil, section, "BackdropTemplate");
    pasteBox:SetPoint("TOPLEFT", section, "TOPLEFT", 0, 0);
    pasteBox:SetPoint("TOPRIGHT", section, "TOPRIGHT", 0, 0);
    pasteBox:SetHeight(Sizes.paste.boxHeight);
    Skin.Backdrop(pasteBox, Colors.controlBg, Colors.controlBorder);
    Skin.AddInnerShadow(pasteBox);

    local scrollbarSpace = SharedLayout.scrollbarWidth + Sizes.preview.listScrollbarGap + Sizes.preview.listScrollbarInset;

    pasteScroll = CreateFrame("ScrollFrame", "ForeverLootSoftResImportWindowPasteScroll", pasteBox, "UIPanelScrollFrameTemplate");
    pasteScroll:SetPoint("TOPLEFT", pasteBox, "TOPLEFT", Sizes.paste.textInset, -Sizes.paste.textInset);
    pasteScroll:SetPoint("BOTTOMRIGHT", pasteBox, "BOTTOMRIGHT", -(Sizes.paste.textInset + scrollbarSpace), Sizes.paste.textInset);

    -- Re-anchor TOP-to-TOP/BOTTOM-to-BOTTOM, same as listScroll's bar below.
    -- Left on the template's own default anchors, this bar's handle travel
    -- was observed flipped top-to-bottom against the actual scroll position
    -- (scrolled to top -> handle at the bottom of the track, and vice versa)
    -- - listScroll's bar gets this same re-anchor and doesn't show that bug.
    local pasteScrollBar = Skin.ScrollBar(pasteScroll);
    if (pasteScrollBar) then
        pasteScrollBar:ClearAllPoints();
        pasteScrollBar:SetPoint("TOP", pasteScroll, "TOP", 0, 0);
        pasteScrollBar:SetPoint("BOTTOM", pasteScroll, "BOTTOM", 0, 0);
        pasteScrollBar:SetPoint("RIGHT", pasteBox, "RIGHT", -Sizes.preview.listScrollbarInset, 0);
    end

    editBox = CreateFrame("EditBox", nil, pasteScroll);
    editBox:SetMultiLine(true);
    editBox:SetAutoFocus(false);
    SetFont(editBox, "small");
    editBox:SetTextColor(unpack(Colors.description));
    editBox:SetWidth(pasteScroll:GetWidth());
    pasteScroll:SetScrollChild(editBox);
    pasteScroll:SetScript("OnSizeChanged", function(self, width) editBox:SetWidth(width); end);

    placeholderText = pasteBox:CreateFontString(nil, "OVERLAY");
    SetFont(placeholderText, "small");
    placeholderText:SetTextColor(unpack(Colors.disabledText));
    placeholderText:SetPoint("TOPLEFT", pasteScroll, "TOPLEFT", 0, 0);
    placeholderText:SetPoint("RIGHT", pasteScroll, "RIGHT", 0, 0);
    placeholderText:SetJustifyH("LEFT");
    placeholderText:SetJustifyV("TOP");
    placeholderText:SetText("Paste the export string here…");
    placeholderText:EnableMouse(false);

    editBox:SetScript("OnEditFocusGained", function(self)
        pasteBox:SetBackdropBorderColor(unpack(Colors.controlFocus));
        updatePlaceholder();
        self:HighlightText();
    end);
    editBox:SetScript("OnEditFocusLost", function()
        pasteBox:SetBackdropBorderColor(unpack(Colors.controlBorder));
        updatePlaceholder();
    end);
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);
    editBox:SetScript("OnTextChanged", function(self, isUserInput)
        updatePlaceholder();
        scheduleParse(self:GetText());
        -- This box only exists to receive one paste - drop focus right after,
        -- same as the old window did.
        if (isUserInput) then self:ClearFocus(); end
    end);

    -- A short/empty multiline EditBox's own frame shrinks to fit its text, so
    -- clicking the flat panel drawn behind it would otherwise miss the
    -- actual EditBox entirely - forward clicks to it, same as the old window.
    pasteBox:EnableMouse(true);
    pasteBox:SetScript("OnMouseDown", function() editBox:SetFocus(); end);
    pasteScroll:SetScript("OnMouseDown", function() editBox:SetFocus(); end);

    parseText = section:CreateFontString(nil, "OVERLAY");
    SetFont(parseText, "small");
    parseText:SetPoint("TOPLEFT", pasteBox, "BOTTOMLEFT", Sizes.paste.dotSize + Sizes.paste.dotGap, -Sizes.paste.parseLineGap);
    parseText:SetPoint("RIGHT", section, "RIGHT", 0, 0);
    parseText:SetJustifyH("LEFT");
    parseText:SetWordWrap(false);

    parseDot = section:CreateTexture(nil, "ARTWORK");
    parseDot:SetSize(Sizes.paste.dotSize, Sizes.paste.dotSize);
    parseDot:SetTexture(DOT_TEXTURE);
    parseDot:SetPoint("RIGHT", parseText, "LEFT", -Sizes.paste.dotGap, 0);

    parseDot:Hide();
    parseText:Hide();

    return section;
end

local function createMissingCard()
    missingCard = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(missingCard, Colors.sessionListBg, Colors.memberBorder, 1);

    local headerRow = CreateFrame("Frame", nil, missingCard);
    headerRow:SetPoint("TOPLEFT", missingCard, "TOPLEFT", Sizes.card.padding, -Sizes.card.padding);
    headerRow:SetPoint("TOPRIGHT", missingCard, "TOPRIGHT", -Sizes.card.padding, -Sizes.card.padding);
    headerRow:SetHeight(Sizes.card.headerHeight);

    missingLabel = headerRow:CreateFontString(nil, "OVERLAY");
    SetFont(missingLabel, "small");
    missingLabel:SetPoint("LEFT", headerRow, "LEFT", 0, 0);

    reportButton = Widgets.CreateFlatButton(headerRow, "Report Missing", "default");
    reportButton:SetSize(Sizes.card.reportButtonWidth, Sizes.card.reportButtonHeight);
    reportButton:SetPoint("RIGHT", headerRow, "RIGHT", 0, 0);
    SetFont(reportButton.text, "small");
    -- Sources its list from whatever's currently parsed in the paste box
    -- (same as the missing-reserves card above it), not SoftRes.MetaData - so
    -- this works even before Import & Broadcast has been clicked. The button
    -- is only enabled while that list is non-empty (see refreshMissingCard).
    reportButton:SetScript("OnClick", function()
        if (not lastParseResult) then return; end

        local names = {};
        for _, entry in ipairs(computeMissingFromParsed(lastParseResult)) do
            table.insert(names, entry.name);
        end
        SoftRes.AnnounceMissingNames(names);

        local channel = Util.GroupChatChannel();
        if (channel == "RAID") then
            SetStatus("info", ("Posted %d missing reserves to raid chat."):format(#names));
        elseif (channel == "PARTY") then
            SetStatus("info", ("Posted %d missing reserves to party chat."):format(#names));
        else
            SetStatus("info", ("Printed %d missing reserves locally (not in a group)."):format(#names));
        end
    end);

    missingBody = CreateFrame("Frame", nil, missingCard);
    missingBody:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -Sizes.card.headerBodyGap);
    missingBody:SetPoint("TOPRIGHT", headerRow, "BOTTOMRIGHT", 0, -Sizes.card.headerBodyGap);

    emptyCheckIcon = missingBody:CreateTexture(nil, "ARTWORK");
    emptyCheckIcon:SetSize(Sizes.card.emptyCheckSize, Sizes.card.emptyCheckSize);
    emptyCheckIcon:SetPoint("TOPLEFT", missingBody, "TOPLEFT", 0, 0);
    emptyCheckIcon:SetTexture(CHECK_ICON_TEXTURE);
    emptyCheckIcon:SetVertexColor(unpack(Colors.respondSentLabel));

    emptyText = missingBody:CreateFontString(nil, "OVERLAY");
    SetFont(emptyText, "body");
    emptyText:SetTextColor(unpack(Colors.respondSentLabel));
    emptyText:SetPoint("LEFT", emptyCheckIcon, "RIGHT", Sizes.card.emptyIconGap, 0);
    emptyText:SetText("Everyone in your raid has a reserve");

    missingCard:SetHeight(Sizes.card.padding * 2 + Sizes.card.headerHeight);
    missingCard:Hide();
end

local function createPreviewLabelRow()
    previewLabelRow = CreateFrame("Frame", nil, frame);
    previewLabelRow:SetHeight(Sizes.preview.labelHeight);

    local label = previewLabelRow:CreateFontString(nil, "OVERLAY");
    SetFont(label, "small");
    label:SetTextColor(unpack(Colors.muted));
    label:SetPoint("LEFT", previewLabelRow, "LEFT", 0, 0);
    label:SetText("PREVIEW");

    previewCountText = previewLabelRow:CreateFontString(nil, "OVERLAY");
    SetFont(previewCountText, "small");
    previewCountText:SetTextColor(unpack(Colors.muted));
    previewCountText:SetPoint("RIGHT", previewLabelRow, "RIGHT", 0, 0);
end

local function createPreviewList()
    listBox = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(listBox, Colors.sessionListBg, Colors.memberBorder, 1);

    local scrollbarSpace = SharedLayout.scrollbarWidth + Sizes.preview.listScrollbarGap + Sizes.preview.listScrollbarInset;

    listScroll = CreateFrame("ScrollFrame", "ForeverLootSoftResImportWindowListScroll", listBox, "UIPanelScrollFrameTemplate");
    listScroll:SetPoint("TOPLEFT", listBox, "TOPLEFT", Sizes.preview.listPadding, -Sizes.preview.listPadding);
    listScroll:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -scrollbarSpace, Sizes.preview.listPadding);

    listScrollChild = CreateFrame("Frame", nil, listScroll);
    listScrollChild:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0);
    listScroll:SetScrollChild(listScrollChild);

    -- Row layout only depends on width (icon wrapping), but this frame's
    -- HEIGHT also changes every time the missing-reserves card above it
    -- resizes (its own height change moves previewLabelRow -> listBox's top
    -- anchor -> this ScrollFrame's height) - refreshMissingCard() alone does
    -- that twice per import (once directly, once again a tick later from
    -- layoutTags' own metrics self-correction). Without this guard, each of
    -- those height-only churns re-triggers a full hide-all/show-subset pass
    -- over every pooled row, several times in a row - which is not just
    -- wasteful but can leave the list visibly out of sync with its data,
    -- since WoW doesn't guarantee a clean repaint of a frame reparented that
    -- many times in a handful of ticks.
    local lastKnownWidth;
    listScroll:SetScript("OnSizeChanged", function(self, width)
        listScrollChild:SetWidth(width);
        if (lastKnownWidth == width) then return; end
        lastKnownWidth = width;
        refreshPreview();
    end);

    local listScrollBar = Skin.ScrollBar(listScroll);
    if (listScrollBar) then
        listScrollBar:ClearAllPoints();
        listScrollBar:SetPoint("TOP", listScroll, "TOP", 0, 0);
        listScrollBar:SetPoint("BOTTOM", listScroll, "BOTTOM", 0, 0);
        listScrollBar:SetPoint("RIGHT", listBox, "RIGHT", -Sizes.preview.listScrollbarInset, 0);
    end

    Theme.Helpers.EnableSmoothScroll(listScroll, { step = Sizes.preview.rowMinHeight + Sizes.preview.rowSpacing });

    previewEmptyText = listBox:CreateFontString(nil, "OVERLAY");
    SetFont(previewEmptyText, "body");
    previewEmptyText:SetTextColor(unpack(Colors.controlHover));
    previewEmptyText:SetPoint("CENTER", listBox, "CENTER", 0, 0);
    previewEmptyText:SetText("Paste an export string to preview reserves.");
    previewEmptyText:Hide();
end

local function createFooter()
    local footer = CreateFrame("Frame", nil, frame);
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", Sizes.contentPadX, Sizes.contentPadBottom);
    footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Sizes.contentPadX, Sizes.contentPadBottom);
    footer:SetHeight(Sizes.footer.dividerHeight + Sizes.footer.dividerGap + Sizes.footer.statusHeight
        + Sizes.footer.statusButtonGap + Sizes.footer.rowHeight);

    local divider = footer:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, 0);
    divider:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, 0);
    Pixel.SetLineHeight(divider, Sizes.footer.dividerHeight);

    statusText = footer:CreateFontString(nil, "OVERLAY");
    SetFont(statusText, "body");
    statusText:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", Sizes.footer.dotSize + Sizes.footer.dotGap, -Sizes.footer.dividerGap);
    statusText:SetPoint("RIGHT", footer, "RIGHT", 0, 0);
    statusText:SetHeight(Sizes.footer.statusHeight);
    statusText:SetJustifyH("LEFT");
    statusText:SetJustifyV("TOP");
    statusText:SetWordWrap(false);
    statusText:SetText("");

    statusDot = footer:CreateTexture(nil, "ARTWORK");
    statusDot:SetSize(Sizes.footer.dotSize, Sizes.footer.dotSize);
    statusDot:SetTexture(DOT_TEXTURE);
    statusDot:SetPoint("RIGHT", statusText, "LEFT", -Sizes.footer.dotGap, 0);
    statusDot:Hide();

    local buttonRow = CreateFrame("Frame", nil, footer);
    buttonRow:SetPoint("BOTTOMLEFT", footer, "BOTTOMLEFT", 0, 0);
    buttonRow:SetPoint("BOTTOMRIGHT", footer, "BOTTOMRIGHT", 0, 0);
    buttonRow:SetHeight(Sizes.footer.rowHeight);

    clearButton = Widgets.CreateFlatButton(buttonRow, "Clear", "default");
    clearButton:SetSize(Sizes.footer.clearWidth, Sizes.footer.rowHeight);
    clearButton:SetPoint("LEFT", buttonRow, "LEFT", 0, 0);
    clearButton:SetScript("OnClick", function()
        editBox:SetText(""); -- fires OnTextChanged -> scheduleParse("") which clears the parse line/card/preview
        editBox:ClearFocus();
        SoftRes.Clear();
        SetStatus(nil);
    end);

    importButton = Widgets.CreateFlatButton(buttonRow, "Import & Broadcast", "primary");
    importButton:SetSize(Sizes.footer.importWidth, Sizes.footer.rowHeight);
    importButton:SetPoint("RIGHT", buttonRow, "RIGHT", 0, 0);
    importButton:SetScript("OnClick", function()
        editBox:ClearFocus();
        local ok, err = SoftRes.Import(editBox:GetText());
        if (ok) then
            SetStatus("success", ("Imported %d soft reserves and %d hard reserve(s)"):format(
                #(SoftRes.MetaData.SoftReserves or {}), #(SoftRes.MetaData.HardReserves or {})
            ));

            -- SoftRes.Import parsed the text again itself, into its own
            -- result table (see the "Auto name fix" print for any entries
            -- that needed it) - swap in the now-canonical SoftRes.MetaData
            -- (same shape) and repaint, same as SyncExternalImport does, so
            -- this window renders from the same source every other refresh
            -- path here (Show(), the roster watcher) uses from here on.
            lastParseResult, lastParseOK = SoftRes.MetaData, true;
            applyMissingCardVisibility();
            refreshMissingCard();
            refreshPreview();
            refreshFooterButtons();
        else
            local message = tostring(err);
            message = message:sub(1, 1):lower() .. message:sub(2);
            SetStatus("error", "Couldn't import — " .. message);
        end
    end);
    importButton:SetEnabled(false);

    return footer;
end

-- Recomputes the missing card only while the window is shown, throttled -
-- same OnShow/OnHide-scoped registration StartSessionWindow.lua's permission
-- watcher uses, same debounce idiom UI/SettingsWindow/Pages/LootCouncil.lua
-- uses for its own roster-driven refresh.
local function createRosterWatcher()
    rosterWatcher = CreateFrame("Frame");
    rosterWatcher:SetScript("OnEvent", function()
        if (pendingRosterRefresh) then return; end
        pendingRosterRefresh = true;
        C_Timer.After(ROSTER_DEBOUNCE, function()
            pendingRosterRefresh = false;
            if (frame and frame:IsShown()) then refreshMissingCard(); end
        end);
    end);
end

--------------------------------------------------------------------------
-- Refresh / reflow
--------------------------------------------------------------------------

-- The missing card's own top anchor (below pasteSection) never changes, but
-- the preview section's top anchor moves depending on whether the card is
-- currently shown - this is the only anchor that needs re-wiring when that
-- visibility flips (listBox itself stays anchored to previewLabelRow and to
-- the footer, so it always fills whatever's left).
reflowSections = function()
    previewLabelRow:ClearAllPoints();
    if (missingCard:IsShown()) then
        previewLabelRow:SetPoint("TOPLEFT", missingCard, "BOTTOMLEFT", 0, -Sizes.sectionGap);
        previewLabelRow:SetPoint("TOPRIGHT", missingCard, "BOTTOMRIGHT", 0, -Sizes.sectionGap);
    else
        previewLabelRow:SetPoint("TOPLEFT", pasteSection, "BOTTOMLEFT", 0, -Sizes.sectionGap);
        previewLabelRow:SetPoint("TOPRIGHT", pasteSection, "BOTTOMRIGHT", 0, -Sizes.sectionGap);
    end
end

-- The card is shown whenever something is currently parsed - covers both a
-- live paste-box parse AND SyncExternalImport's straight-from-MetaData
-- render (which clears the box but should keep the card/preview populated,
-- matching the old window's own behavior).
applyMissingCardVisibility = function()
    missingCard:SetShown(lastParseResult ~= nil);
    reflowSections();
end

refreshMissingCard = function()
    if (not lastParseResult) then return; end -- card is hidden; nothing to paint

    local missing = computeMissingFromParsed(lastParseResult);
    local n = #missing;

    missingLabel:SetText(("IN YOUR RAID WITHOUT A RESERVE · %d"):format(n));
    missingLabel:SetTextColor(unpack(n > 0 and Colors.softresMissingLabel or Colors.muted));
    reportButton:SetEnabled(n > 0);

    local bodyHeight;
    if (n > 0) then
        emptyCheckIcon:Hide();
        emptyText:Hide();
        bodyHeight = layoutTags(missing);
    else
        for _, tag in ipairs(tagPool) do tag:Hide(); end
        emptyCheckIcon:Show();
        emptyText:Show();
        bodyHeight = math.max(Sizes.card.emptyCheckSize, emptyText:GetHeight());
    end

    bodyHeight = math.max(bodyHeight, 1);
    missingBody:SetHeight(bodyHeight);
    missingCard:SetHeight(Sizes.card.padding * 2 + Sizes.card.headerHeight + Sizes.card.headerBodyGap + bodyHeight);
end

refreshPreview = function()
    if (not listScrollChild) then return; end

    local result = lastParseResult;
    local players = (result and result.SoftReserves) or {};
    local hardReserves = (result and result.HardReserves) or {};

    previewCountText:SetText(("%d players"):format(#players));

    if (not result) then
        previewEmptyText:Show();
        for _, row in ipairs(rows) do row:Hide(); end
        listScrollChild:SetHeight(1);
        listScroll:SetVerticalScroll(0);
        listScroll:UpdateScrollChildRect();
        return;
    end
    previewEmptyText:Hide();

    local sortedPlayers = {};
    for _, entry in ipairs(players) do table.insert(sortedPlayers, entry); end
    table.sort(sortedPlayers, function(a, b) return string.lower(a.name or "") < string.lower(b.name or ""); end);

    local totalRows = (#hardReserves > 0 and 1 or 0) + #sortedPlayers;
    -- Same brand-new-FontString-metrics quirk layoutTags works around: a
    -- freshly created row's nameText:GetHeight() can read wrong on the same
    -- tick it's first shown, so re-run once more a frame later whenever the
    -- pool just grew.
    local grew = ensureRowCount(totalRows);
    if (grew) then
        C_Timer.After(0, function()
            if (lastParseResult) then refreshPreview(); end
        end);
    end

    -- Hide every pooled row up front, then only re-show the ones actually
    -- painted below - if painting a row ever errors partway through (bad
    -- data in one entry), whatever's left in the pool from a PRIOR refresh
    -- stays hidden instead of lingering on screen under the new rows.
    for _, row in ipairs(rows) do row:Hide(); end

    local members = Util.groupMembers();
    local iconAreaWidth = math.max(1, listScrollChild:GetWidth()
        - Sizes.preview.rowPadding - Sizes.preview.rowNameWidth - Sizes.preview.rowNameIconGap - Sizes.preview.rowPadding);

    local yCursor, rowIndex = 0, 1;

    if (#hardReserves > 0) then
        local row = rows[rowIndex];
        row:ClearAllPoints();
        row:SetPoint("TOPLEFT", listScrollChild, "TOPLEFT", 0, -yCursor);
        row:SetPoint("RIGHT", listScrollChild, "RIGHT", 0, 0);
        paintHardReserveRow(row, hardReserves, iconAreaWidth);
        row:Show();
        yCursor = yCursor + row:GetHeight() + Sizes.preview.rowSpacing;
        rowIndex = rowIndex + 1;
    end

    for _, entry in ipairs(sortedPlayers) do
        local row = rows[rowIndex];
        row:ClearAllPoints();
        row:SetPoint("TOPLEFT", listScrollChild, "TOPLEFT", 0, -yCursor);
        row:SetPoint("RIGHT", listScrollChild, "RIGHT", 0, 0);
        paintPlayerRow(row, entry, members, iconAreaWidth);
        row:Show();
        yCursor = yCursor + row:GetHeight() + Sizes.preview.rowSpacing;
        rowIndex = rowIndex + 1;
    end

    for i = rowIndex, #rows do rows[i]:Hide(); end

    listScrollChild:SetHeight(math.max(yCursor - Sizes.preview.rowSpacing, 1));
    listScroll:UpdateScrollChildRect();

    if (listScroll.ScrollBar and listScroll.ScrollBar.zlUpdateVisibility) then
        listScroll.ScrollBar.zlUpdateVisibility();
    end
end

refreshFooterButtons = function()
    importButton:SetEnabled(lastParseOK);
end

-- Debounces a re-parse of `text` 0.3s. An empty box short-circuits
-- synchronously (nothing to wait on), clearing the parse line/card/preview.
scheduleParse = function(text)
    parseGeneration = parseGeneration + 1;

    if (text == "") then
        lastParseResult, lastParseOK = nil, false;
        parseDot:Hide();
        parseText:Hide();
        applyMissingCardVisibility();
        refreshMissingCard();
        refreshPreview();
        refreshFooterButtons();
        return;
    end

    local myGeneration = parseGeneration;
    C_Timer.After(PARSE_DEBOUNCE, function()
        if (myGeneration ~= parseGeneration) then return; end -- superseded by newer text/Clear/SyncExternalImport
        runParse(text);
    end);
end

-- Paints the paste-box's own "Parsed N players..." success line - shared by
-- a live parse (runParse, below) and Show()'s reload-from-DB path, which
-- renders straight from SoftRes.MetaData instead of re-running
-- SoftRes.Parse (see SoftResImportWindow.Show for why).
local function showParseSuccessLine(result)
    local reserveCount = 0;
    for _, entry in ipairs(result.SoftReserves) do reserveCount = reserveCount + #entry.Items; end

    parseText:SetText(("Parsed %d players · %d soft reserves · %d hard reserve(s)"):format(
        #result.SoftReserves, reserveCount, #result.HardReserves
    ));
    parseText:SetTextColor(unpack(Colors.respondSentLabel));
    parseDot:SetVertexColor(unpack(Colors.respondSentLabel));
    parseDot:Show();
    parseText:Show();
end

runParse = function(text)
    local ok, result = SoftRes.Parse(text);
    lastParseOK = ok;
    lastParseResult = ok and result or nil;

    if (ok) then
        showParseSuccessLine(result);
    else
        parseText:SetText("That doesn't look like a Gargul export string. Copy it from softres.it → Gargul Export.");
        parseText:SetTextColor(unpack(Colors.sessionDeleteHoverIcon));
        parseDot:SetVertexColor(unpack(Colors.sessionDeleteHoverIcon));
        parseDot:Show();
        parseText:Show();
    end

    applyMissingCardVisibility();
    refreshMissingCard();
    refreshPreview();
    refreshFooterButtons();
end

--------------------------------------------------------------------------
-- Window lifecycle
--------------------------------------------------------------------------

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootSoftResImportWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    -- NOTE: deliberately NOT added to UISpecialFrames - matches the old
    -- FL.Theme-based window's behavior and TradeQueueWindow.lua's own
    -- explicit choice to preserve it rather than adopt StartSessionWindow's
    -- Escape-closes behavior.
    Pixel.RegisterWindow(frame, {
        width = WINDOW_WIDTH, height = WINDOW_HEIGHT,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    createTitleBar();
    local header = createHeader();
    local footer = createFooter();
    pasteSection = createPasteSection();
    createMissingCard();
    createPreviewLabelRow();
    createPreviewList();

    pasteSection:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -Sizes.sectionGap);
    pasteSection:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -Sizes.sectionGap);

    missingCard:SetPoint("TOPLEFT", pasteSection, "BOTTOMLEFT", 0, -Sizes.sectionGap);
    missingCard:SetPoint("TOPRIGHT", pasteSection, "BOTTOMRIGHT", 0, -Sizes.sectionGap);

    -- Initial state: card hidden, so the preview label row starts anchored
    -- directly under pasteSection - reflowSections() re-anchors it if/when
    -- the card is shown.
    previewLabelRow:SetPoint("TOPLEFT", pasteSection, "BOTTOMLEFT", 0, -Sizes.sectionGap);
    previewLabelRow:SetPoint("TOPRIGHT", pasteSection, "BOTTOMRIGHT", 0, -Sizes.sectionGap);

    listBox:SetPoint("TOPLEFT", previewLabelRow, "BOTTOMLEFT", 0, -Sizes.preview.labelGap);
    listBox:SetPoint("TOPRIGHT", previewLabelRow, "BOTTOMRIGHT", 0, -Sizes.preview.labelGap);
    listBox:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, Sizes.sectionGap);
    listBox:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, Sizes.sectionGap);

    createRosterWatcher();
    frame:HookScript("OnShow", function() rosterWatcher:RegisterEvent("GROUP_ROSTER_UPDATE"); end);
    frame:HookScript("OnHide", function() rosterWatcher:UnregisterEvent("GROUP_ROSTER_UPDATE"); end);

    refreshPreview();
    refreshFooterButtons();
end

function SoftResImportWindow.Show()
    ensureFrame();
    frame:Show();

    -- If nothing's been pasted into this box yet but data is already loaded
    -- (e.g. reloaded from the DB at login), show the raw string as text and
    -- render straight from SoftRes.MetaData immediately rather than waiting
    -- on the reparse SetText's OnTextChanged schedules below - SoftRes.Parse
    -- now runs the same auto-rename fixup Import does (see fixPlayerNames),
    -- so that reparse harmlessly produces the identical result once it
    -- fires; this just avoids the blank "paste an export string" flash for
    -- the ~0.3s it'd otherwise take to land.
    if (editBox:GetText() == "" and SoftRes.ImportString) then
        editBox:SetText(SoftRes.ImportString); -- fires scheduleParse via OnTextChanged

        if (SoftRes.MetaData) then
            lastParseResult, lastParseOK = SoftRes.MetaData, true;
            showParseSuccessLine(SoftRes.MetaData);
        end

        applyMissingCardVisibility();
        refreshMissingCard();
        refreshPreview();
        refreshFooterButtons();
    else
        refreshMissingCard(); -- roster may have changed since this window was last shown
    end
end

function SoftResImportWindow.Hide()
    if (frame) then frame:Hide(); end
end

function SoftResImportWindow.IsShown()
    return frame ~= nil and frame:IsShown();
end

function SoftResImportWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then SoftResImportWindow.Hide(); else SoftResImportWindow.Show(); end
end

function SoftResImportWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end

-- Called after another player's SoftRes import lands via broadcast
-- (Comm.Actions[broadcastSoftRes] in SoftRes.lua). Only touches the window
-- if it's already been created this session. The paste box is cleared
-- rather than repopulated with the new raw string (whatever was sitting
-- there no longer describes what's active), but the preview/missing card
-- still render straight from SoftRes.MetaData, matching the old window.
function SoftResImportWindow.SyncExternalImport()
    if (not frame) then return; end

    editBox:SetText("");
    editBox:ClearFocus();
    parseDot:Hide();
    parseText:Hide();

    if (SoftRes.MetaData) then
        lastParseResult, lastParseOK = SoftRes.MetaData, true;
        SetStatus("info", ("Received new SoftRes data · %d soft reserves, %d hard reserve(s)."):format(
            #(SoftRes.MetaData.SoftReserves or {}), #(SoftRes.MetaData.HardReserves or {})
        ));
    else
        lastParseResult, lastParseOK = nil, false;
        SetStatus(nil);
    end

    applyMissingCardVisibility();
    refreshMissingCard();
    refreshPreview();
    refreshFooterButtons();
end
