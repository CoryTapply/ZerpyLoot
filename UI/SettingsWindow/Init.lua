--[[
Settings window chrome: frame, draggable title bar, close button, sidebar
shell + search box, scrollable content area. Deliberately bypasses FL.Theme's
skin dispatch entirely (Theme.CreateWindow/SkinButton/etc.) - this window
always looks the same regardless of the active theme, unlike every other
ForeverLoot window - so it's built directly with CreateFrame +
Theme.Helpers.SetFlatBackdrop (skin-agnostic) and FL.Pixel (no skin
knowledge either). Registry.lua builds the nav buttons/pages into the frame
this file creates; page content itself lives in UI/SettingsWindow/Pages/*.lua.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local SettingsWindow = FL.UI.SettingsWindow;

local WINDOW_WIDTH = Sizes.layout.settingsWindow.width;
local WINDOW_HEIGHT = Sizes.layout.settingsWindow.height;
local TITLE_BAR_HEIGHT = 48;
local SIDEBAR_WIDTH = Sizes.layout.sidebarWidth;
local CONTENT_PAD_X = Sizes.layout.pagePadding;
local CONTENT_PAD_Y = Sizes.layout.pagePadding;
local SCROLLBAR_GUTTER = Sizes.layout.scrollbarGutter;

-- Anchors the sidebar/content area 1px inside the window's own border
-- (Colors.border, drawn on `frame` itself in ensureFrame) instead of flush
-- with it - flush left either of those opaque backgrounds paints directly
-- over the border pixel, hiding it along that edge.
local BORDER_INSET = 1;

-- Footer strip pinned to the bottom of the content area (see
-- SettingsWindow.SetFooterShown below): a 1px divider along its top edge,
-- then the fixed-height button row every page's footer content is built
-- into. FOOTER_SCROLL_GAP is the breathing room left between the scroll
-- area's bottom edge and the footer's divider.
local FOOTER_HEIGHT = Sizes.layout.footerHeight;
local FOOTER_BOTTOM_PAD = 14;
local FOOTER_ROW_HEIGHT = Sizes.controls.button + 10;
local FOOTER_SCROLL_GAP = 8;

-- Key this window's saved position is stored under (see
-- Settings.GetWindowPosition/SetWindowPosition) - kept as the pre-rebuild
-- "configWindow" string so an existing saved position isn't dropped.
local POSITION_KEY = "configWindow";

local frame;
-- Kept as upvalues (rather than locals inside ensureFrame) so
-- SettingsWindow.SetFooterShown, called from Registry.lua on every page
-- switch, can re-anchor the scroll frame's bottom edge without needing
-- ensureFrame to thread them through.
local contentArea, scrollFrame, footer;

local function createTitleBar()
    local titleBar = CreateFrame("Frame", nil, frame);
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
    titleBar:SetHeight(TITLE_BAR_HEIGHT);

    -- Only the title bar drags the window - the content area below is dense
    -- with clickable widgets.
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
    title:SetText("ForeverLoot - Settings");
    title:SetTextColor(unpack(Colors.titlePurple));

    local divider = titleBar:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 1, 0);
    divider:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -1, 0);
    divider:SetHeight(Pixel.PixelSize(1));

    local closeButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    closeButton:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -8, -8);
    Skin.CloseButton(closeButton);
    closeButton:SetScript("OnClick", function()
        FL.NotifyWindowClosed("Settings");
        frame:Hide();
    end);

    return titleBar;
end

local function createSidebar()
    local sidebar = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", BORDER_INSET, -TITLE_BAR_HEIGHT);
    sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", BORDER_INSET, BORDER_INSET);
    sidebar:SetWidth(SIDEBAR_WIDTH);
    Theme.Helpers.SetFlatBackdrop(sidebar, Colors.sidebarBg, Colors.transparent, 0);

    local edgeDivider = sidebar:CreateTexture(nil, "ARTWORK");
    edgeDivider:SetColorTexture(unpack(Colors.divider));
    edgeDivider:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 0, 0);
    edgeDivider:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 0);
    edgeDivider:SetWidth(Pixel.PixelSize(1));

    local searchBox = CreateFrame("EditBox", nil, sidebar, "SearchBoxTemplate");
    searchBox:SetPoint("TOPLEFT", sidebar, "TOPLEFT", Sizes.layout.sidebarPadX, -Sizes.layout.sidebarPadTop);
    searchBox:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -Sizes.layout.sidebarPadX, -Sizes.layout.sidebarPadTop);
    searchBox:SetHeight(Sizes.controls.input);
    if (searchBox.Instructions) then searchBox.Instructions:SetText("Search settings\226\128\166"); end -- "Search settings…"
    searchBox:SetScript("OnTextChanged", function(self)
        SearchBoxTemplate_OnTextChanged(self);
        FL.UI.SettingsRegistry.ApplySearch(self:GetText());
    end);
    Skin.EditBox(searchBox);

    return sidebar, searchBox;
end

--- Builds the footer strip once: a fixed-height container pinned to the
--- bottom of the content area, with a top-edge divider and a button row
--- that page footer content (default or page-supplied) is built into. See
--- SettingsWindow.SetFooterShown for how the scroll frame's bottom anchor
--- switches between this and the content area's own bottom padding.
local function createFooter(content)
    local footerFrame = CreateFrame("Frame", nil, content, "BackdropTemplate");
    footerFrame:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", CONTENT_PAD_X, FOOTER_BOTTOM_PAD);
    footerFrame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -CONTENT_PAD_X, FOOTER_BOTTOM_PAD);
    footerFrame:SetHeight(FOOTER_HEIGHT);
    -- Solid background matching the window so nothing scrolled behind it
    -- (long pages' last rows) can show through.
    Theme.Helpers.SetFlatBackdrop(footerFrame, Colors.windowBg, Colors.transparent, 0);

    local divider = footerFrame:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPLEFT", footerFrame, "TOPLEFT", 0, 0);
    divider:SetPoint("TOPRIGHT", footerFrame, "TOPRIGHT", 0, 0);
    divider:SetHeight(Pixel.PixelSize(1));

    footerFrame.row = CreateFrame("Frame", nil, footerFrame);
    footerFrame.row:SetPoint("BOTTOMLEFT", footerFrame, "BOTTOMLEFT", 0, 0);
    footerFrame.row:SetPoint("BOTTOMRIGHT", footerFrame, "BOTTOMRIGHT", 0, 0);
    footerFrame.row:SetHeight(FOOTER_ROW_HEIGHT);

    return footerFrame;
end

local function createContentArea(sidebar)
    local content = CreateFrame("Frame", nil, frame);
    content:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 0, 0);
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -BORDER_INSET, BORDER_INSET);

    footer = createFooter(content);

    local scroll = CreateFrame("ScrollFrame", "ForeverLootSettingsWindowScroll", content, "UIPanelScrollFrameTemplate");
    scroll:SetPoint("TOPLEFT", content, "TOPLEFT", CONTENT_PAD_X, -CONTENT_PAD_Y);
    -- Frame level above the footer so nothing scrolled underneath (or its
    -- scrollbar) draws over the footer's own solid background/divider.
    scroll:SetFrameLevel(footer:GetFrameLevel() + 1);

    local scrollChild = CreateFrame("Frame", nil, scroll);
    scrollChild:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0);
    scroll:SetScrollChild(scrollChild);

    -- Computed from fixed constants rather than scroll:GetWidth() - every
    -- piece feeding that (window/sidebar/pad sizes) is already known at this
    -- point, so this avoids depending on anchor-chain geometry being
    -- resolved by the time this line runs. The trailing (BORDER_INSET * 2)
    -- matches the 1px the sidebar's left edge and the content area's right
    -- edge each give up to the window border fix above - leave it out and
    -- this declares 2px more than the scroll viewport's real width.
    local scrollWidth = WINDOW_WIDTH - SIDEBAR_WIDTH - (CONTENT_PAD_X * 2) - SCROLLBAR_GUTTER - (BORDER_INSET * 2);
    scrollChild:SetSize(scrollWidth, 1);

    -- Slim custom scrollbar (Skin.ScrollBar hides the template's up/down
    -- arrows, restyles the track/thumb, and wires its own auto-hide) -
    -- positioned here rather than inside Skin.ScrollBar since only this
    -- file has `content` in scope; the bar tracks `scroll`'s own TOP/BOTTOM
    -- so it automatically follows SetFooterShown's re-anchoring below.
    local scrollBar = Skin.ScrollBar(scroll);
    if (scrollBar) then
        scrollBar:ClearAllPoints();
        scrollBar:SetPoint("TOP", scroll, "TOP", 0, 0);
        scrollBar:SetPoint("BOTTOM", scroll, "BOTTOM", 0, 0);
        scrollBar:SetPoint("RIGHT", content, "RIGHT", -Sizes.layout.scrollbarInset, 0);
    end

    -- Page content is freeform (sections/controls, not uniform rows), so
    -- this uses EnableSmoothScroll's own default step rather than a
    -- row-height-derived one like the other windows' list scroll areas.
    Theme.Helpers.EnableSmoothScroll(scroll);

    contentArea = content;
    scrollFrame = scroll;
    SettingsWindow.SetFooterShown(true);

    return scroll, scrollChild, footer.row;
end

--- Re-checks whether the slim scrollbar should be shown - called after any
--- layout change that might not fire the ScrollFrame's own
--- OnScrollRangeChanged synchronously (page switch, search filtering,
--- LootCouncil's roster-driven grid refresh - see Registry.lua and
--- UI/SettingsWindow/Pages/LootCouncil.lua).
function SettingsWindow.RefreshScrollBar()
    local bar = scrollFrame and scrollFrame.ScrollBar;
    if (bar and bar.zlUpdateVisibility) then bar.zlUpdateVisibility(); end
end

--- A page's full-width, hand-built section (one page:Section's own
--- bookkeeping never sees, e.g. LootRolls.lua's "Automatic Rolls") registers
--- its outer frame here under a page-chosen id, so code elsewhere (a raid
--- popup's "View Overrides" button) can scroll to and flash it without
--- LootRolls.lua exposing any of its own locals.
SettingsWindow.sectionAnchors = SettingsWindow.sectionAnchors or {};

--- Scrolls the content area so `id`'s registered section frame sits at the
--- top of the viewport, then flashes a gold outline around it. Deferred one
--- frame: called right after SelectPage, whose page may only just now be
--- getting its real height (a fresh page is built lazily on first show), so
--- GetTop()/the scroll range can still be stale on the same frame.
function SettingsWindow.ScrollToSection(id)
    local sectionFrame = SettingsWindow.sectionAnchors[id];
    if (not sectionFrame or not scrollFrame) then return; end

    C_Timer.After(0, function()
        local sectionTop, viewTop = sectionFrame:GetTop(), scrollFrame:GetTop();
        if (not sectionTop or not viewTop) then return; end

        local current = scrollFrame:GetVerticalScroll();
        local target = Clamp(current + (viewTop - sectionTop), 0, scrollFrame:GetVerticalScrollRange() or 0);
        scrollFrame:SetVerticalScroll(target);
        SettingsWindow.FlashSection(sectionFrame);
    end);
end

--- Flashes a 1px gold outline around `sectionFrame`, fading out over
--- Sizes.autoRoll.overrideFlashDuration seconds - same one-shot border-flash
--- idiom as UI/RespondWindow.lua's own per-card flash, generalized here as
--- the settings window's first reusable version of it. The overlay is
--- parented to the top-level window frame (not sectionFrame, which lives
--- inside scrollFrame's scroll child) so its 5px margin isn't clipped by
--- the scroll frame's rect on the left/right edges.
function SettingsWindow.FlashSection(sectionFrame)
    if (not sectionFrame.zlFlashAnim) then
        local overlay = CreateFrame("Frame", nil, frame, "BackdropTemplate");
        overlay:SetPoint("TOPLEFT", sectionFrame, "TOPLEFT", -5, 5);
        overlay:SetPoint("BOTTOMRIGHT", sectionFrame, "BOTTOMRIGHT", 5, -5);
        overlay:SetFrameLevel(frame:GetFrameLevel() + 50);
        Theme.Helpers.SetFlatBackdrop(overlay, nil, Colors.gold, 1);
        overlay:SetAlpha(0);

        local anim = overlay:CreateAnimationGroup();
        local fade = anim:CreateAnimation("Alpha");
        fade:SetFromAlpha(1);
        fade:SetToAlpha(0);
        fade:SetDuration(Sizes.autoRoll.overrideFlashDuration);

        sectionFrame.zlFlashAnim = anim;
    end

    sectionFrame.zlFlashAnim:Stop();
    sectionFrame.zlFlashAnim:Play();
end

--- Called by Registry.lua on every page switch. When `shown` is true, the
--- scroll frame's bottom edge sits FOOTER_SCROLL_GAP above the footer's
--- divider so the scrollable region (and its scrollbar) never runs under
--- the footer; a page whose footer opt is `false` instead gets the scroll
--- frame's bottom anchored straight to the content area's own bottom
--- padding, with the footer container hidden.
function SettingsWindow.SetFooterShown(shown)
    footer:SetShown(shown);
    scrollFrame:ClearAllPoints();
    scrollFrame:SetPoint("TOPLEFT", contentArea, "TOPLEFT", CONTENT_PAD_X, -CONTENT_PAD_Y);
    if (shown) then
        scrollFrame:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", -SCROLLBAR_GUTTER, FOOTER_SCROLL_GAP);
    else
        scrollFrame:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -(CONTENT_PAD_X + SCROLLBAR_GUTTER), CONTENT_PAD_Y);
    end
end

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);
    frame = CreateFrame("Frame", "ForeverLootSettingsWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    Pixel.RegisterWindow(frame, {
        width = WINDOW_WIDTH, height = WINDOW_HEIGHT,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    createTitleBar();
    local sidebar, searchBox = createSidebar();
    local scroll, scrollChild, footerRow = createContentArea(sidebar);

    FL.UI.SettingsRegistry.Build(sidebar, scrollChild, searchBox, footerRow);

    frame:SetScript("OnShow", SettingsWindow.Refresh);
end

function SettingsWindow.Refresh()
    if (not frame) then return; end
    FL.UI.SettingsRegistry.RefreshCurrentPage();
end

function SettingsWindow.Show()
    ensureFrame();
    frame:Show();
    SettingsWindow.Refresh();
end

function SettingsWindow.Hide()
    if (frame) then frame:Hide(); end
    -- A Loot Responses row's color palette popover (Skin.ColorPalette) is
    -- its own DIALOG-strata frame, not a child the window hiding otherwise
    -- clips/hides - close it explicitly so it never survives the window
    -- closing under it.
    Skin.CloseAnyOpenColorPalette();
end

function SettingsWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then SettingsWindow.Hide(); else SettingsWindow.Show(); end
end

function SettingsWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
