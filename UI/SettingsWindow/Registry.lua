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
    frame:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, 0);
    frame:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, 0);

    local page = setmetatable({
        frame = frame,
        contentWidth = contentFrame:GetWidth(),
        checkboxByKey = {},
        resettableKeys = {},
        refreshers = {},
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

function Registry.ApplySearch(text)
    currentSearchText = string.lower(strtrim(text or ""));
    local entry = currentEntry;
    if (not entry or not entry.page) then return; end
    local page = entry.page;

    for _, row in pairs(page.checkboxByKey) do
        local visible = (currentSearchText == "") or (string.find(row.labelLower, currentSearchText, 1, true) ~= nil);
        row.frame:SetShown(visible);
    end

    for _, section in ipairs(page.sections or {}) do
        local anyVisible = (#section.rows == 0);
        for _, row in ipairs(section.rows) do
            if (row.frame:IsShown()) then anyVisible = true; break; end
        end
        section.frame:SetShown(anyVisible);
    end

    SettingsWindow.RefreshScrollBar();
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
end

function Registry.RefreshCurrentPage()
    if (currentEntry and currentEntry.page) then
        currentEntry.page:Refresh();
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

    table.sort(pageEntries, function(a, b) return a.order < b.order; end);

    local padX = Sizes.layout.sidebarPadX;
    local textInset = Sizes.layout.sidebarTextInset;

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
