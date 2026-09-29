--[[
Page registry + sidebar navigation + search filtering for the settings
window. Each UI/SettingsWindow/Pages/*.lua file calls
SettingsWindow.RegisterPage once, at load time, to add itself (and,
optionally, a footer builder - see RegisterPage's opts.footer below);
Init.lua calls Registry.Build(sidebar, scrollChild, searchBox, footerRow)
once, the first time the window is shown, to build the nav buttons, wire the
search box, and hand over the scroll child and footer row every page's body
and footer content get built into.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Widgets = FL.UI.SettingsWidgets;
local SettingsWindow = FL.UI.SettingsWindow;

local Registry = {};
FL.UI.SettingsRegistry = Registry;

local NAV_BUTTON_HEIGHT = Sizes.controls.navRow;
-- The spec asks for exactly one fixed divider (before Profiles) - not a
-- general "insert a divider here" feature, since nothing else needs one.
local DIVIDER_BEFORE_ID = "profiles";

local pageEntries = {}; -- array of { id, label, buildFunc, order, footerOpt, page, footerFrame, built }
local pagesById = {};
local navButtonsById = {};
local currentEntry;
local currentSearchText = "";
local contentFrame; -- the scroll child every page's frame is anchored into
local footerRowFrame; -- the footer container's button row; each page gets its own subframe of this

-- Sidebar search (see Registry.ApplySearch/Registry.Build below). While a
-- query is active, the nav button list (navButtonsById + profileDivider) is
-- swapped out for resultsContainer, a flat cross-page list of matching
-- settings built from every page's own searchEntries (see Widgets.lua's
-- addSearchEntry) the first time it's actually needed.
local searchBoxRef; -- the sidebar EditBox itself (Init.lua's `topAnchor`) - cleared on a result click so the nav list reappears
local profileDivider; -- the one fixed divider before "Profiles" (DIVIDER_BEFORE_ID) - hidden alongside the nav buttons during a search
local resultsContainer;
local resultButtons = {}; -- pooled result-row buttons, reused across searches/keystrokes
local searchIndex; -- built lazily, once, on first non-empty query: array of { label, labelLower, frame, pageId, pageLabel }
local RESULT_ROW_PAD_Y = Sizes.layout.searchResultPadY;
local RESULT_ROW_LINE_GAP = Sizes.layout.searchResultLineGap;
local RESULT_ROW_GAP = Sizes.layout.searchResultGap;

--- `opts.footer` (optional): a page-owned footer builder `function(footerFrame,
--- page)`, `false` for no footer at all, or omitted for the default footer
--- ("Reset This Page" + "Changes save automatically" - see
--- Widgets.BuildDefaultFooter).
function SettingsWindow.RegisterPage(id, label, buildFunc, order, opts)
    local entry = { id = id, label = label, buildFunc = buildFunc, order = order or 0, footerOpt = opts and opts.footer };
    table.insert(pageEntries, entry);
    pagesById[id] = entry;
end

local function setNavButtonState(button, selected, hovering)
    if (selected) then
        Theme.Helpers.SetFlatBackdrop(button, Colors.selectedFill, Colors.selectedBorder, 1);
        button.text:SetTextColor(unpack(Colors.gold));
    elseif (hovering) then
        Theme.Helpers.SetFlatBackdrop(button, Colors.hoverBg, Colors.transparent, 1);
        button.text:SetTextColor(unpack(Colors.text));
    else
        button:SetBackdrop(nil);
        button.text:SetTextColor(unpack(Colors.text));
    end
end

local function ensurePageBuilt(entry)
    if (entry.built) then return; end

    local frame = CreateFrame("Frame", nil, contentFrame);
    -- Starts hidden (frames default to shown) so the Show() call below is a
    -- real hidden->shown transition on first build - a page whose buildFunc
    -- relies on OnShow to do its first refresh (LootCouncil.lua's roster
    -- grid) would otherwise never fire it: the frame would already be
    -- "shown" by the time SelectPage calls :Show(), since it's created
    -- while already attached to visible ancestors.
    frame:Hide();
    frame:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, 0);
    frame:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, 0);

    local page = setmetatable({
        frame = frame,
        contentWidth = contentFrame:GetWidth(),
        checkboxByKey = {},
        resettableKeys = {},
        refreshers = {},
        searchEntries = {},
    }, Widgets.PageMethods);

    entry.page = page;
    entry.buildFunc(page);

    -- Sized to the page's own real content, computed only now that
    -- buildFunc has finished (GetContentHeight() reads contentTop/columnY/
    -- contentBottomOverride, all set during buildFunc) - no more hardcoded
    -- guess, and no longer left at an undefined 0 height either.
    frame:SetHeight(math.max(1, page:GetContentHeight()));

    -- Footer content is built lazily here too (same "first show" timing as
    -- the page body above), into a page-owned subframe of the shared footer
    -- row rather than into the page's own (scrolling) frame - see
    -- Init.lua's createFooter/SetFooterShown. Deferred until after
    -- buildFunc so the default footer's "Reset This Page" button can see
    -- every resettable key the page just registered.
    if (entry.footerOpt ~= false) then
        local footerFrame = CreateFrame("Frame", nil, footerRowFrame);
        footerFrame:SetAllPoints(footerRowFrame);
        footerFrame:Hide();
        if (type(entry.footerOpt) == "function") then
            entry.footerOpt(footerFrame, page);
        else
            Widgets.BuildDefaultFooter(footerFrame, page);
        end
        entry.footerFrame = footerFrame;
    end

    entry.built = true;
end

local function setNavChromeShown(shown)
    for _, button in pairs(navButtonsById) do button:SetShown(shown); end
    if (profileDivider) then profileDivider:SetShown(shown); end
end

--- Forces every page to build (see ensurePageBuilt) so each one's
--- searchEntries is populated, then flattens them into one cross-page list -
--- built once, lazily, the first time the search box actually has text in
--- it (not at window-open time), and cached from then on since a page's
--- widget labels/frames never change once built.
local function buildSearchIndex()
    if (searchIndex) then return; end
    searchIndex = {};
    for _, entry in ipairs(pageEntries) do
        ensurePageBuilt(entry);
        for _, se in ipairs(entry.page.searchEntries) do
            table.insert(searchIndex, {
                label = se.label,
                labelLower = string.lower(se.label),
                frame = se.frame,
                pageId = entry.id,
                pageLabel = entry.label,
            });
        end
    end
end

--- Returns resultButtons[index], creating it the first time that slot is
--- needed - same reuse-across-searches pooling idiom as the rest of this
--- window, so retyping a query doesn't churn frames every keystroke. Sized
--- (width AND height) fresh by the caller on every population pass below,
--- not here - a row's real height depends on how many lines its own label
--- wraps to, which isn't known until that label's actually set.
local function acquireResultButton(index)
    local button = resultButtons[index];
    if (button) then return button; end

    button = CreateFrame("Button", nil, resultsContainer, "BackdropTemplate");

    local title = button:CreateFontString(nil, "OVERLAY");
    SetFont(title, "body");
    title:SetJustifyH("LEFT");
    title:SetJustifyV("TOP");
    title:SetPoint("TOPLEFT", button, "TOPLEFT", Sizes.layout.sidebarTextInset, -RESULT_ROW_PAD_Y);
    title:SetTextColor(unpack(Colors.text));
    button.title = title;

    local subtitle = button:CreateFontString(nil, "OVERLAY");
    SetFont(subtitle, "small");
    subtitle:SetJustifyH("LEFT");
    subtitle:SetJustifyV("TOP");
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -RESULT_ROW_LINE_GAP);
    subtitle:SetTextColor(unpack(Colors.muted));
    button.subtitle = subtitle;

    button:SetScript("OnEnter", function(self) Theme.Helpers.SetFlatBackdrop(self, Colors.hoverBg, Colors.transparent, 1); end);
    button:SetScript("OnLeave", function(self) self:SetBackdrop(nil); end);

    resultButtons[index] = button;
    return button;
end

--- Clears the search box (so the nav list reappears), switches to the
--- match's page, then scrolls/flashes the exact row the player picked - same
--- SelectPage-then-scroll-to-it pattern already used by
--- UI/AutoRollPopup.lua's "View Overrides" and UI/GroupLootFrame.lua's
--- right-click-to-settings (see Init.lua's ScrollToSection), just resolved
--- straight from the match's own frame instead of a fixed sectionAnchors id.
local function selectSearchResult(match)
    if (searchBoxRef) then searchBoxRef:SetText(""); searchBoxRef:ClearFocus(); end
    Registry.SelectPage(match.pageId);
    SettingsWindow.ScrollToFrame(match.frame);
end

--- Drives the sidebar search box (Init.lua's searchBox OnTextChanged). Empty
--- text restores the normal nav button list; non-empty text hides it and
--- shows resultsContainer instead, filled with every setting (across every
--- page, not just the one currently open) whose label contains the query -
--- clicking one navigates to and flashes it (see selectSearchResult above).
--- Deliberately no longer hides non-matching rows in place on the current
--- page - that old behavior collapsed page layout out from under the player
--- and couldn't find a setting on another page at all.
function Registry.ApplySearch(text)
    currentSearchText = string.lower(strtrim(text or ""));

    if (currentSearchText == "") then
        if (resultsContainer) then resultsContainer:Hide(); end
        setNavChromeShown(true);
        return;
    end

    if (not resultsContainer) then return; end -- ApplySearch("") can fire before Registry.Build has run its course

    buildSearchIndex();
    setNavChromeShown(false);
    resultsContainer:Show();
    resultsContainer.emptyText:Hide();
    resultsContainer.moreText:Hide();
    for _, button in pairs(resultButtons) do button:Hide(); end

    local matches = {};
    for _, e in ipairs(searchIndex) do
        if (string.find(e.labelLower, currentSearchText, 1, true) ~= nil) then
            table.insert(matches, e);
        end
    end

    if (#matches == 0) then
        resultsContainer.emptyText:Show();
        return;
    end

    -- Each row's height is MEASURED from its own (possibly wrapped) label
    -- text, not assumed fixed - a label longer than the sidebar is wide
    -- wraps to 2-3 lines, and a fixed row height would let that spill into
    -- the next row instead of pushing it down. Rows are added one at a time
    -- until they've used up the space actually available below the search
    -- box (resultsContainer:GetHeight()), with a "+N more" hint for whatever
    -- didn't fit - always showing at least one match, however tall, so a
    -- single very long label never results in an empty-looking list.
    local containerHeight = resultsContainer:GetHeight();
    local rowWidth = resultsContainer:GetWidth();
    local textWidth = math.max(1, rowWidth - (Sizes.layout.sidebarTextInset * 2));

    local y = 0;
    local shown = 0;
    for i = 1, #matches do
        local match = matches[i];
        local button = acquireResultButton(i);

        -- Width -> text -> measure, in that order (same rule
        -- Widgets.BuildCheckboxRow's own comment spells out) - an explicit
        -- SetWidth measures correctly the same frame, unlike a width derived
        -- from a RIGHT anchor point, which can lag a frame behind on this
        -- client.
        button.title:SetWidth(textWidth);
        button.title:SetText(match.label);
        button.subtitle:SetWidth(textWidth);
        button.subtitle:SetText(match.pageLabel);

        local rowHeight = RESULT_ROW_PAD_Y + button.title:GetStringHeight()
            + RESULT_ROW_LINE_GAP + button.subtitle:GetStringHeight() + RESULT_ROW_PAD_Y;

        if (shown > 0 and (-y + rowHeight) > containerHeight) then break; end

        button:ClearAllPoints();
        button:SetPoint("TOPLEFT", resultsContainer, "TOPLEFT", 0, y);
        button:SetWidth(rowWidth);
        button:SetHeight(rowHeight);
        button:SetScript("OnClick", function() selectSearchResult(match); end);
        button:Show();

        y = y - rowHeight - RESULT_ROW_GAP;
        shown = shown + 1;
    end

    if (shown < #matches) then
        resultsContainer.moreText:ClearAllPoints();
        resultsContainer.moreText:SetPoint("TOPLEFT", resultsContainer, "TOPLEFT", Sizes.layout.sidebarTextInset, y);
        resultsContainer.moreText:SetPoint("RIGHT", resultsContainer, "RIGHT", -Sizes.layout.sidebarTextInset, 0);
        resultsContainer.moreText:SetText(("+%d more - keep typing to narrow it down"):format(#matches - shown));
        resultsContainer.moreText:Show();
    end
end

function Registry.SelectPage(id)
    local entry = pagesById[id];
    if (not entry) then return; end

    if (currentEntry and currentEntry ~= entry) then
        if (currentEntry.page) then currentEntry.page.frame:Hide(); end
        if (currentEntry.footerFrame) then currentEntry.footerFrame:Hide(); end
    end

    for entryId, button in pairs(navButtonsById) do
        setNavButtonState(button, entryId == id, false);
    end

    ensurePageBuilt(entry);
    entry.page.frame:Show();
    SettingsWindow.SetFooterShown(entry.footerOpt ~= false);
    if (entry.footerFrame) then entry.footerFrame:Show(); end
    currentEntry = entry;

    contentFrame:SetHeight(math.max(1, entry.page:GetContentHeight()));
    SettingsWindow.RefreshScrollBar();

    entry.page:Refresh();
    Registry.ApplySearch(currentSearchText);

    -- On this client, a checkbox/radio item's wrapped helper text can
    -- measure a line short on this very first pass (fonts/geometry not
    -- fully settled yet) - re-running layout one frame later catches that
    -- once things have actually settled. Guarded by the entry still being
    -- current in case the player switches pages again before this fires.
    C_Timer.After(0, function()
        if (currentEntry == entry) then Registry.LayoutCurrentPage(); end
    end);
end

function Registry.RefreshCurrentPage()
    if (currentEntry and currentEntry.page) then
        currentEntry.page:Refresh();
        contentFrame:SetHeight(math.max(1, currentEntry.page:GetContentHeight()));
        SettingsWindow.RefreshScrollBar();
    end
end

--- Re-runs the current page's row/section positioning in place (see
--- PageMethods:Layout) and resizes the scrollable content child to match -
--- for the delayed re-layout in Registry.SelectPage above. Deliberately not
--- wired to the content child's own OnSizeChanged (resizing a frame from
--- inside its own OnSizeChanged handler is its own can of worms on this
--- client) - this SetHeight call is one-shot, not a persistent reaction to
--- itself.
function Registry.LayoutCurrentPage()
    if (currentEntry and currentEntry.page) then
        currentEntry.page:Layout();
        contentFrame:SetHeight(math.max(1, currentEntry.page:GetContentHeight()));
        SettingsWindow.RefreshScrollBar();
    end
end

--- Builds the sidebar's nav button list into `sidebar` and remembers
--- `content` as the scroll child every page's frame anchors into, and
--- `footerRow` as the shared footer container's button row that each page's
--- own footer subframe is built into. Called once, from Init.lua's
--- ensureFrame.
function Registry.Build(sidebar, content, topAnchor, footerRow)
    contentFrame = content;
    footerRowFrame = footerRow;
    searchBoxRef = topAnchor;

    table.sort(pageEntries, function(a, b) return a.order < b.order; end);

    local padX = Sizes.layout.sidebarPadX;
    local textInset = Sizes.layout.sidebarTextInset;

    -- Search results list: occupies the same sidebar space as the nav button
    -- list below, swapped in by Registry.ApplySearch while a query is
    -- active. Anchored off topAnchor (the search box itself) rather than
    -- padX/sidebar directly, so it picks up the exact same left/right inset
    -- the search box already has. Built once, up front, so it exists (even
    -- if hidden and empty) by the time the very first Registry.SelectPage
    -- call below runs its own Registry.ApplySearch("").
    resultsContainer = CreateFrame("Frame", nil, sidebar);
    resultsContainer:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, -Sizes.layout.searchNavGap);
    resultsContainer:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, -Sizes.layout.searchNavGap);
    resultsContainer:SetPoint("BOTTOM", sidebar, "BOTTOM", 0, Sizes.layout.sidebarPadTop);
    resultsContainer:SetClipsChildren(true);
    resultsContainer:Hide();

    local emptyText = resultsContainer:CreateFontString(nil, "OVERLAY");
    SetFont(emptyText, "small");
    emptyText:SetJustifyH("LEFT");
    emptyText:SetPoint("TOPLEFT", resultsContainer, "TOPLEFT", textInset, -4);
    emptyText:SetPoint("RIGHT", resultsContainer, "RIGHT", -textInset, 0);
    emptyText:SetText("No matching settings.");
    emptyText:SetTextColor(unpack(Colors.muted));
    emptyText:Hide();
    resultsContainer.emptyText = emptyText;

    local moreText = resultsContainer:CreateFontString(nil, "OVERLAY");
    SetFont(moreText, "small");
    moreText:SetJustifyH("LEFT");
    moreText:SetTextColor(unpack(Colors.muted));
    moreText:Hide();
    resultsContainer.moreText = moreText;

    -- Nav buttons/divider are inset padX from both sidebar edges - same
    -- width as the search box above them, not edge to edge (an inset pill
    -- when selected/hovered, not a full-width bar) - only the vertical
    -- stacking comes from prevAnchor. The gap above each depends on what
    -- it's stacking under: the search box (searchNavGap), the Profiles
    -- divider (navDividerGap, both above AND below it), or another nav
    -- item (navItemGap).
    local prevAnchor = topAnchor;
    local prevWasDivider = false;
    for _, entry in ipairs(pageEntries) do
        if (entry.id == DIVIDER_BEFORE_ID) then
            local divider = sidebar:CreateTexture(nil, "ARTWORK");
            divider:SetColorTexture(unpack(Colors.divider));
            divider:SetPoint("TOP", prevAnchor, "BOTTOM", 0, -Sizes.layout.navDividerGap);
            divider:SetPoint("LEFT", sidebar, "LEFT", padX, 0);
            divider:SetPoint("RIGHT", sidebar, "RIGHT", -padX, 0);
            divider:SetHeight(FL.Pixel.PixelSize(1));
            prevAnchor = divider;
            prevWasDivider = true;
            profileDivider = divider;
        end

        local gapAbove;
        if (prevAnchor == topAnchor) then
            gapAbove = Sizes.layout.searchNavGap;
        elseif (prevWasDivider) then
            gapAbove = Sizes.layout.navDividerGap;
        else
            gapAbove = Sizes.layout.navItemGap;
        end

        local button = CreateFrame("Button", nil, sidebar, "BackdropTemplate");
        button:SetPoint("TOP", prevAnchor, "BOTTOM", 0, -gapAbove);
        button:SetPoint("LEFT", sidebar, "LEFT", padX, 0);
        button:SetPoint("RIGHT", sidebar, "RIGHT", -padX, 0);
        button:SetHeight(NAV_BUTTON_HEIGHT);

        local text = button:CreateFontString(nil, "OVERLAY");
        SetFont(text, "body");
        text:SetPoint("LEFT", button, "LEFT", textInset, 0);
        text:SetText(entry.label);
        button.text = text;

        button:SetScript("OnClick", function() Registry.SelectPage(entry.id); end);
        button:SetScript("OnEnter", function(self)
            if (currentEntry ~= entry) then setNavButtonState(self, false, true); end
        end);
        button:SetScript("OnLeave", function(self)
            if (currentEntry ~= entry) then setNavButtonState(self, false, false); end
        end);

        setNavButtonState(button, false, false);
        navButtonsById[entry.id] = button;
        prevAnchor = button;
        prevWasDivider = false;
    end

    if (pageEntries[1]) then
        Registry.SelectPage(pageEntries[1].id);
    end
end
