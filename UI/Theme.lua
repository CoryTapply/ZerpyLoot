--[[
ElvUI-style window chrome: a solid dark background plus a crisp
1-physical-pixel border, built on ZL.Pixel so the border stays exactly 1px
on any UIScale or monitor. Colors match ElvUI's own default palette
(media.backdropcolor / media.bordercolor from its Profile defaults) so
ZerpyLoot's windows sit visually flush with an ElvUI-skinned UI.
]]

local ZL = ZerpyLoot;
local Theme = ZL.Theme;
local Pixel = ZL.Pixel;
local LSM = LibStub("LibSharedMedia-3.0");

-- Flat, solid-color, Blizzard-shipped texture used for both the background and
-- border fill. Flat = nothing for the backdrop system's edge/corner sampling to
-- blur, unlike a detailed edgeFile art asset (which is what actually caused the
-- "blurred bitmap art" this file's SetBackdrop approach was previously replaced
-- for - not SetBackdrop itself).
local CHROME_TEXTURE = "Interface\\Buttons\\WHITE8X8";

-- Cell's own close/delete icon (Media/Icons/close.tga), copied into this
-- addon's own Media folder - a baked icon asset centers reliably regardless
-- of font metrics, unlike the FontString "x" glyph this used to be (which
-- ended up noticeably off-center since a single-point-anchored FontString
-- auto-sizes to the glyph's raw advance box, not its visual ink).
local CLOSE_ICON_TEXTURE = "Interface\\AddOns\\ZerpyLoot\\Media\\Icons\\close.tga";
local CLOSE_ICON_SIZE = 10;

-- Press-feedback nudge for a close button's icon, matching the -1px
-- SetPushedTextOffset every other button gets.
local CLOSE_ICON_PRESS_OFFSET = -1;

-- A fixed size anchored to the button's own CENTER, rather than inset from
-- opposite corners, is what actually guarantees centering regardless of the
-- button's own dimensions.
local function positionCloseIcon(button, yOffset)
    local icon = button.zlCloseIcon;
    icon:ClearAllPoints();
    icon:SetPoint("CENTER", button, "CENTER", 0, yOffset);
end

-- Background alpha (0.9) intentionally matches Cell's options window
-- (Cell.StylizeFrame's default color) so ZerpyLoot's windows read as part of
-- the same family of dark, semi-transparent raid-tool UIs.
Theme.colors = {
    background = { 0.1, 0.1, 0.1, 0.9 },
    border = { 0, 0, 0, 1 },

    -- Flat button skin, also modeled on Cell's default (non-accent) button:
    -- a dark, fully-opaque fill that lightens on hover.
    button = { 0.115, 0.115, 0.115, 1 },
    buttonHover = { 0.23, 0.23, 0.23, 1 },
    buttonBorder = { 0, 0, 0, 1 },

    -- Cell skins its close buttons with a reddish tint instead of a
    -- dedicated "x" texture - reused here for the same reason (recognizable
    -- as destructive/dismissive without needing separate artwork).
    close = { 0.6, 0.1, 0.1, 0.6 },
    closeHover = { 0.6, 0.1, 0.1, 1 },

    -- Cell's input fields use the same flat look as its buttons, just
    -- without a hover state.
    input = { 0.115, 0.115, 0.115, 0.9 },
    inputBorder = { 0, 0, 0, 1 },

    -- Thin purple scrollbar thumb (#8865FF) on a matching-width dark track,
    -- both outlined in black.
    scrollbarThumb = { 0x88 / 0xFF, 0x65 / 0xFF, 0xFF / 0xFF, 1 },
    scrollbarTrack = { 0.1, 0.1, 0.1, 0.9 },
    scrollbarBorder = { 0, 0, 0, 1 },

    -- Same purple (#8865FF) used as a solid accent button fill, for the
    -- "Start Roll" button - lightened on hover like every other button skin.
    accent = { 0x88 / 0xFF, 0x65 / 0xFF, 0xFF / 0xFF, 1 },
    accentHover = { 0xA0 / 0xFF, 0x85 / 0xFF, 1, 1 },

    -- Same red (#FF4F58) as the roll window's countdown bar hover color (see
    -- RollWindow.lua's COUNTDOWN_BAR_HOVER_COLOR) - shared here so any other
    -- destructive control (e.g. the trade queue row's delete icon) matches it
    -- exactly instead of drifting from a separately-hand-picked red.
    danger = { 0xff / 0xFF, 0x4f / 0xFF, 0x58 / 0xFF, 1 },

    -- Bright orange alert border - used to make a window's whole border "pop"
    -- for something that needs immediate attention (e.g. the roll tracker
    -- window when a soft-reserved item of yours is up for roll).
    warning = { 1, 0.55, 0, 1 },
};

-- Named font objects every ZerpyLoot FontString uses (instead of Blizzard's
-- global GameFontXxx objects directly - overriding those would also reskin
-- the rest of the game's UI). Every size, color, outline and shadow value
-- below is a hardcoded literal rather than copied off a Blizzard font
-- object (or, for the input font, the player's own chat-font setting) at
-- load time, so none of this can silently drift if Blizzard changes a
-- default font or the player changes an unrelated client setting. Only the
-- font FACE gets swapped later, by Theme.ApplyFont.
Theme.fonts = {
    normal = "ZerpyLootFontNormal",
    normalMedium = "ZerpyLootFontNormalMedium",
    normalLarge = "ZerpyLootFontNormalLarge",
    normalSmall = "ZerpyLootFontNormalSmall",
    highlight = "ZerpyLootFontHighlight",
    highlightMedium = "ZerpyLootFontHighlightMedium",
    highlightSmall = "ZerpyLootFontHighlightSmall",
    disableSmall = "ZerpyLootFontDisableSmall",

    -- Window/panel titles (purple accent) and button labels (white) - see
    -- DefineFont calls below for why these get their own dedicated colors.
    title = "ZerpyLootFontTitle",
    titleLarge = "ZerpyLootFontTitleLarge",
    button = "ZerpyLootFontButton",
    buttonDisabled = "ZerpyLootFontButtonDisabled",
    input = "ZerpyLootFontInput",
};

local FONT_OUTLINE = ""; -- explicitly no outline, rather than left unset
local FONT_SHADOW_OFFSET_X, FONT_SHADOW_OFFSET_Y = 1, -1;
local FONT_SHADOW_COLOR = { 0, 0, 0, 1 };

-- Blizzard's own GameFontNormal/Highlight/Disable colors, as literals -
-- kept here instead of read off those font objects so this addon's fonts
-- can't end up tracking them.
local COLOR_GOLD = { 1, 0.82, 0, 1 };
local COLOR_WHITE = { 1, 1, 1, 1 };
local COLOR_GREY = { 0.5, 0.5, 0.5, 1 };

local function DefineFont(name, size, color)
    local font = _G[name] or CreateFont(name);
    local path = LSM:Fetch("font") or "Fonts\\FRIZQT__.TTF";
    font:SetFont(path, size, FONT_OUTLINE);
    font:SetTextColor(unpack(color));
    font:SetShadowOffset(FONT_SHADOW_OFFSET_X, FONT_SHADOW_OFFSET_Y);
    font:SetShadowColor(unpack(FONT_SHADOW_COLOR));
    return font;
end

DefineFont(Theme.fonts.normal, 12, COLOR_GOLD);
-- Same size/color/shadow recipe as normalLarge, just dialed down to 14pt -
-- used where normalLarge (16pt) reads slightly too big (the roll-off item
-- link).
DefineFont(Theme.fonts.normalMedium, 14, COLOR_GOLD);
DefineFont(Theme.fonts.normalLarge, 16, COLOR_GOLD);
DefineFont(Theme.fonts.normalSmall, 10, COLOR_GOLD);
DefineFont(Theme.fonts.highlight, 12, COLOR_WHITE);
-- Same recipe as highlightSmall, just dialed up to 12pt - used where
-- highlightSmall (10pt) reads too small (the SoftRes preview's player names).
DefineFont(Theme.fonts.highlightMedium, 12, COLOR_WHITE);
DefineFont(Theme.fonts.highlightSmall, 10, COLOR_WHITE);
DefineFont(Theme.fonts.disableSmall, 10, COLOR_GREY);

-- Window/panel titles: the purple (#8865FF) accent color used throughout
-- the rest of the theme (Theme.colors.accent) instead of Blizzard's gold.
DefineFont(Theme.fonts.title, 12, Theme.colors.accent);
DefineFont(Theme.fonts.titleLarge, 16, Theme.colors.accent);

-- Button labels: plain white, applied to every themed button in
-- skinButtonBackdrop below instead of whatever font object the button's
-- template shipped with.
DefineFont(Theme.fonts.button, 12, COLOR_WHITE);
DefineFont(Theme.fonts.buttonDisabled, 12, COLOR_GREY);

-- SoftRes paste box text - fixed 14pt regardless of the player's own chat
-- font size (this used to inherit ChatFontNormal, which tracks that
-- setting).
DefineFont(Theme.fonts.input, 14, COLOR_WHITE);

-- Swaps the font FACE (via SharedMedia) on every mirrored font object,
-- keeping each one's own size/color/shadow untouched.
function Theme.ApplyFont(key)
    local path = (key and LSM:Fetch("font", key)) or LSM:Fetch("font");
    if (not path) then return; end

    for _, fontObjectName in pairs(Theme.fonts) do
        local fontObject = _G[fontObjectName];
        local _, size, flags = fontObject:GetFont();
        fontObject:SetFont(path, size, flags);
    end
end

local statusBars = {};

-- Applies the current SharedMedia statusbar texture to `bar` and remembers
-- it so future texture changes re-apply automatically.
function Theme.ApplyStatusBarTexture(bar, key)
    statusBars[bar] = true;
    local path = (key and LSM:Fetch("statusbar", key)) or LSM:Fetch("statusbar");
    if (path) then bar:SetStatusBarTexture(path); end
end

function Theme.RefreshStatusBars(key)
    for bar in pairs(statusBars) do
        Theme.ApplyStatusBarTexture(bar, key);
    end
end

-- Backs both the window's background and border with Blizzard's own
-- BackdropTemplate, using a flat solid-color texture for both bgFile and
-- edgeFile so there's no detail for the backdrop system's edge/corner
-- sampling to blur - unlike a textured/artwork edgeFile (baked corner/shadow
-- detail meant for a much larger display size, which is what actually
-- blurred when this was last tried, not SetBackdrop itself). edgeSize is
-- computed via Blizzard's own PixelUtil helper so it lands exactly on the
-- physical pixel grid.
local function refreshBackdrop(frame)
    local edgeSize = Pixel.PixelSize(frame.pixelBorderThickness or 1);
    frame:SetBackdrop({ bgFile = CHROME_TEXTURE, edgeFile = CHROME_TEXTURE, edgeSize = edgeSize });
    frame:SetBackdropColor(unpack(Theme.colors.background));
    frame:SetBackdropBorderColor(unpack(frame.zlBorderColorOverride or Theme.colors.border));
end

function Theme.ApplyBorder(frame, thicknessPx)
    frame.pixelBorderThickness = thicknessPx or 1;
    refreshBackdrop(frame);
    frame.pixelBorderReflow = function() refreshBackdrop(frame); end
end

--- Overrides a Theme.CreateWindow frame's border color (e.g. to make it
--- "pop" for something needing attention), surviving any later
--- pixelBorderReflow (a display-scale change re-applies whatever override is
--- currently set instead of silently reverting to the default border color).
--- Pass a nil/falsy `color` to go back to the default border color.
function Theme.SetWindowBorderColor(frame, color)
    frame.zlBorderColorOverride = color or nil;
    frame:SetBackdropBorderColor(unpack(color or Theme.colors.border));
end

function Theme.ApplyBackground(frame)
    frame.pixelBorderThickness = frame.pixelBorderThickness or 1;
    refreshBackdrop(frame);
end

-- Strips a Blizzard button of its default artwork (normal/pushed/highlight/
-- disabled textures plus the Left/Right/Middle pieces UIPanelButtonTemplate
-- draws them from) and replaces it with a flat, solid-color backdrop that
-- lightens on hover - the same recipe Cell uses for its own buttons.
local function skinButtonBackdrop(button, color, hoverColor)
    if (button.zlSkinned) then return; end

    if (not button.SetBackdrop) then
        Mixin(button, BackdropTemplateMixin);
    end

    -- On this client, Button:SetNormalTexture(nil) (and the Pushed/
    -- Highlight/Disabled equivalents) throws "bad argument #2 ... Usage:
    -- self:SetNormalTexture(asset)" instead of clearing it like retail
    -- does - so the existing Texture object is cleared directly instead.
    local function hideTexture(tex)
        if (tex and tex.SetTexture) then
            tex:SetTexture(nil);
            tex:SetAlpha(0);
        end
    end

    -- UIPanelButtonTemplate's own OnMouseDown/OnMouseUp/OnEnable/OnDisable
    -- scripts repaint the Left/Right/Middle pieces (swapping in Blizzard's
    -- up/down/disabled art) every time the button is pressed or its enabled
    -- state changes - clearing them once at skin time isn't enough, since
    -- those built-in scripts run again on every later press and bring the
    -- default art right back. So this has to be reapplied, not just called
    -- once.
    local function hideAllTextures()
        if (button.GetNormalTexture) then hideTexture(button:GetNormalTexture()); end
        if (button.GetPushedTexture) then hideTexture(button:GetPushedTexture()); end
        if (button.GetHighlightTexture) then hideTexture(button:GetHighlightTexture()); end
        if (button.GetDisabledTexture) then hideTexture(button:GetDisabledTexture()); end

        for _, regionName in pairs({ "Left", "Right", "Middle", "LeftDisabled", "RightDisabled", "MiddleDisabled" }) do
            local region = button[regionName];
            if (region and region.SetTexture) then region:SetTexture(nil); end
        end
    end

    hideAllTextures();

    -- Explicit white/grey button-label fonts (see Theme.fonts.button/
    -- buttonDisabled) instead of whatever font object the button's own
    -- template (UIPanelButtonTemplate, UIPanelCloseButton) shipped with.
    button:SetNormalFontObject(Theme.fonts.button);
    button:SetHighlightFontObject(Theme.fonts.button);
    button:SetDisabledFontObject(Theme.fonts.buttonDisabled);

    local edgeSize = Pixel.PixelSize(1);
    button:SetBackdrop({ bgFile = CHROME_TEXTURE, edgeFile = CHROME_TEXTURE, edgeSize = edgeSize });
    button:SetBackdropColor(unpack(color));
    button:SetBackdropBorderColor(unpack(Theme.colors.buttonBorder));

    button:HookScript("OnEnter", function()
        if (button:IsEnabled()) then button:SetBackdropColor(unpack(hoverColor)); end
    end);
    button:HookScript("OnLeave", function()
        button:SetBackdropColor(unpack(color));
    end);

    -- With the pushed texture hidden above, the only remaining "pressed"
    -- feedback is the button's own text nudging down - exactly like Cell's
    -- buttons (no separate pushed art at all). SetPushedTextOffset covers a
    -- real Button:SetText() label; a manually-added overlay icon (the close
    -- button's "x") isn't reachable through that API, so it's nudged by hand.
    button:SetPushedTextOffset(0, -1);

    button:HookScript("OnMouseDown", function()
        hideAllTextures();
        if (button.zlCloseIcon and button:IsEnabled()) then
            positionCloseIcon(button, CLOSE_ICON_PRESS_OFFSET);
        end
    end);
    button:HookScript("OnMouseUp", function()
        hideAllTextures();
        if (button.zlCloseIcon) then
            positionCloseIcon(button, 0);
        end
    end);
    button:HookScript("OnEnable", hideAllTextures);
    button:HookScript("OnDisable", hideAllTextures);

    -- These buttons are typically skinned while still hidden (e.g. msButton/
    -- osButton right after creation, before their first :Show()) - the
    -- template redraws its default Left/Right/Middle stone art the first
    -- time the button actually becomes visible, so the one-time
    -- hideAllTextures() call above isn't enough on its own; without this
    -- hook the default Blizzard texture showed until the button was clicked
    -- once (which re-triggers hideAllTextures via OnMouseDown/OnMouseUp).
    button:HookScript("OnShow", hideAllTextures);

    button.zlSkinned = true;
end

--- Skin a UIPanelButtonTemplate button with Cell's flat button look.
function Theme.SkinButton(button)
    skinButtonBackdrop(button, Theme.colors.button, Theme.colors.buttonHover);
end

--- Skin a UIPanelButtonTemplate button with the purple (#8865FF) accent fill,
--- for a button that should stand out from the flat default button skin
--- (e.g. "Start Roll").
function Theme.SkinAccentButton(button)
    skinButtonBackdrop(button, Theme.colors.accent, Theme.colors.accentHover);
end

--- Skin a UIPanelCloseButton with Cell's flat, reddish close-button look,
--- using Cell's own close.tga icon (copied into this addon's Media folder).
function Theme.SkinCloseButton(button)
    skinButtonBackdrop(button, Theme.colors.close, Theme.colors.closeHover);

    if (not button.zlCloseIcon) then
        local icon = button:CreateTexture(nil, "OVERLAY");
        icon:SetTexture(CLOSE_ICON_TEXTURE);
        icon:SetSize(CLOSE_ICON_SIZE, CLOSE_ICON_SIZE);
        icon:SetVertexColor(1, 1, 1, 0.9);
        button.zlCloseIcon = icon;
        positionCloseIcon(button, 0);
    end
end

--- Give an EditBox (single or multi-line, InputBoxTemplate or template-less)
--- Cell's flat, dark input look.
function Theme.SkinEditBox(editBox)
    if (editBox.zlSkinned) then return; end

    if (not editBox.SetBackdrop) then
        Mixin(editBox, BackdropTemplateMixin);
    end

    -- InputBoxTemplate boxes draw their border from these three textured
    -- pieces; a template-less EditBox simply won't have them.
    for _, regionName in pairs({ "Left", "Right", "Middle" }) do
        local region = editBox[regionName];
        if (region and region.SetTexture) then region:SetTexture(nil); end
    end

    local edgeSize = Pixel.PixelSize(1);
    editBox:SetBackdrop({ bgFile = CHROME_TEXTURE, edgeFile = CHROME_TEXTURE, edgeSize = edgeSize });
    editBox:SetBackdropColor(unpack(Theme.colors.input));
    editBox:SetBackdropBorderColor(unpack(Theme.colors.inputBorder));
    editBox:SetTextInsets(5, 5, 2, 2);

    editBox.zlSkinned = true;
end

--- Cell-style flat, dark input look for a plain container frame that wraps a
--- borderless, template-less EditBox/ScrollFrame combo (e.g. the SoftRes
--- paste box, whose actual EditBox has to stay transparent so it can sit
--- inside a ScrollFrame) so the pair still reads as one input field.
function Theme.SkinInputBackground(frame)
    if (not frame.SetBackdrop) then
        Mixin(frame, BackdropTemplateMixin);
    end

    local edgeSize = Pixel.PixelSize(1);
    frame:SetBackdrop({ bgFile = CHROME_TEXTURE, edgeFile = CHROME_TEXTURE, edgeSize = edgeSize });
    frame:SetBackdropColor(unpack(Theme.colors.input));
    frame:SetBackdropBorderColor(unpack(Theme.colors.inputBorder));
end

--- Draw just a border (no fill) around an arbitrary frame - e.g. a thin
--- wrapper frame anchored a pixel outside a StatusBar, so the border doesn't
--- get painted over by the bar's own fill texture. Anchoring/sizing that
--- wrapper is left to the caller; this only paints it.
function Theme.SkinBorder(frame)
    if (not frame.SetBackdrop) then
        Mixin(frame, BackdropTemplateMixin);
    end

    local edgeSize = Pixel.PixelSize(1);
    frame:SetBackdrop({ edgeFile = CHROME_TEXTURE, edgeSize = edgeSize });
    frame:SetBackdropBorderColor(unpack(Theme.colors.border));
end

--- Reskin a Blizzard UIPanelScrollFrameTemplate's scrollbar to Cell's flat,
--- borderless look (dark track, thin solid-color thumb, no arrow buttons)
--- instead of the default carved-stone artwork. Defensive throughout (every
--- step is nil-checked and the whole thing is pcall-wrapped) because the
--- scrollbar's exact sub-widgets aren't declared in this addon's own code -
--- they come from a Blizzard template this client build may structure
--- slightly differently, and a wrong guess here should degrade to "still
--- has the default scrollbar" rather than a hard Lua error like the
--- SetNormalTexture(nil) one this same file hit earlier.
function Theme.SkinScrollBar(scrollFrame)
    pcall(function()
        local bar = scrollFrame.ScrollBar;
        if (not bar) then return; end

        local pixel = Pixel.PixelSize(1);
        local thumbWidth = 6;

        for _, key in pairs({ "ScrollUpButton", "ScrollDownButton" }) do
            local arrow = bar[key];
            if (arrow) then
                arrow:Hide();
                arrow:SetAlpha(0);
            end
        end

        -- Track: same width as the thumb (rather than the full, wider bar),
        -- outlined in black. Drawn on the bar's own BACKGROUND layer - a
        -- couple of sublevels below the thumb's own layer - so it never
        -- has to chase the thumb's frame level/strata.
        if (not bar.zlTrackBorder) then
            bar.zlTrackBorder = bar:CreateTexture(nil, "BACKGROUND", nil, -3);
            bar.zlTrackFill = bar:CreateTexture(nil, "BACKGROUND", nil, -2);
        end

        local trackBorder = bar.zlTrackBorder;
        trackBorder:SetColorTexture(unpack(Theme.colors.scrollbarBorder));
        trackBorder:ClearAllPoints();
        trackBorder:SetPoint("TOP", bar, "TOP", 0, 0);
        trackBorder:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0);
        trackBorder:SetWidth(thumbWidth + 2 * pixel);

        local trackFill = bar.zlTrackFill;
        trackFill:SetColorTexture(unpack(Theme.colors.scrollbarTrack));
        trackFill:ClearAllPoints();
        trackFill:SetPoint("TOP", bar, "TOP", 0, -pixel);
        trackFill:SetPoint("BOTTOM", bar, "BOTTOM", 0, pixel);
        trackFill:SetWidth(thumbWidth);

        local thumb = bar.GetThumbTexture and bar:GetThumbTexture();
        if (thumb) then
            thumb:SetTexture(CHROME_TEXTURE);
            thumb:SetVertexColor(unpack(Theme.colors.scrollbarThumb));
            thumb:SetWidth(thumbWidth);

            -- Black outline around the thumb itself. Anchored directly to
            -- the thumb texture (not hooked/polled), so it tracks the
            -- thumb's position for free as it's dragged, and stays on the
            -- BACKGROUND layer so it always renders under the thumb, which
            -- Blizzard draws on a higher layer.
            if (not bar.zlThumbBorder) then
                bar.zlThumbBorder = bar:CreateTexture(nil, "BACKGROUND", nil, -1);
            end
            local thumbBorder = bar.zlThumbBorder;
            thumbBorder:SetColorTexture(unpack(Theme.colors.scrollbarBorder));
            thumbBorder:ClearAllPoints();
            thumbBorder:SetPoint("TOPLEFT", thumb, "TOPLEFT", -pixel, pixel);
            thumbBorder:SetPoint("BOTTOMRIGHT", thumb, "BOTTOMRIGHT", pixel, -pixel);
        end

        -- Hide the whole bar (thumb, track, border) whenever there's
        -- nothing to scroll, instead of always showing a full-length thumb
        -- that doesn't move - or whenever a caller has force-hidden it via
        -- Theme.SetScrollBarHidden (e.g. a window shrunk down near its
        -- resize minimum, where the sliver of visible list isn't worth a
        -- scrollbar even though there's technically still range to scroll).
        local function updateVisibility()
            local _, maxVal = bar:GetMinMaxValues();
            if (not bar.zlForceHidden and maxVal and maxVal > 0) then
                bar:Show();
            else
                bar:Hide();
            end
        end
        bar.zlUpdateVisibility = updateVisibility;

        if (not bar.zlAutoHideHooked) then
            scrollFrame:HookScript("OnScrollRangeChanged", updateVisibility);
            bar.zlAutoHideHooked = true;
        end
        updateVisibility();
    end);
end

-- Force-hides (or un-force-hides) a Theme.SkinScrollBar-skinned scroll
-- frame's bar regardless of whether there's scrollable content - layered on
-- top of, not replacing, that bar's own no-content auto-hide.
function Theme.SetScrollBarHidden(scrollFrame, hidden)
    local bar = scrollFrame.ScrollBar;
    if (not bar or not bar.zlUpdateVisibility) then return; end

    bar.zlForceHidden = hidden;
    bar.zlUpdateVisibility();
end

-- `x`/`y` follow the same CENTER-relative convention the old
-- SetPoint("CENTER", x, y) calls used. `onMoved(x, y)` - if given - fires
-- (with those same CENTER-relative coordinates) once after each drag, so
-- callers can persist the window's new position (e.g. to a saved-variable
-- setting) and restore it across sessions.
function Theme.CreateWindow(globalName, width, height, x, y, onMoved)
    local frame = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate");
    frame:SetMovable(true);
    frame:EnableMouse(true);
    frame:RegisterForDrag("LeftButton");
    frame:SetScript("OnDragStart", frame.StartMoving);
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing();
        Pixel.SnapPosition(self, onMoved);
    end);

    Theme.ApplyBackground(frame);
    Theme.ApplyBorder(frame, 1);

    Pixel.RegisterWindow(frame, { width = width, height = height, x = x, y = y }, function()
        frame.pixelBorderReflow();
    end);

    return frame;
end

--- Restores a Theme.CreateWindow frame to the x/y it was originally created
--- with (screen-centered, unless a different default x/y was passed to
--- CreateWindow) - used by /zl resetpositions.
function Theme.ResetWindowPosition(frame)
    Pixel.ResetPosition(frame);
end

-- Bottom-edge drag-to-resize (height only, width and the top edge stay
-- fixed) for a Theme.CreateWindow frame: a thin invisible hit region
-- spanning the window's bottom margin, plus a colored line on the edge
-- itself that's hidden at rest, twice the normal border thickness on
-- hover, and three times while actively dragging.
--
-- `onResized(height)` fires once, after the mouse is released, with the
-- final clamped/pixel-snapped height - callers use it to persist the new
-- height (e.g. to a saved-variable setting). `onResizeStart()`, if given,
-- fires once when the drag begins - callers use it to cancel any in-flight
-- programmatic height animation of their own, so it doesn't fight the drag.
--
-- Returns the resize handle itself, plus a `setResizeEnabled(enabled)`
-- function - callers use that to disable dragging while the frame is
-- currently sitting below minHeight for a legitimate reason (e.g. a compact
-- prompt state), since SetResizeBounds/SetMinResize enforce minHeight the
-- instant an interactive resize starts, which would otherwise snap the
-- frame straight up to minHeight the moment the handle is grabbed - a jump
-- unrelated to how far the mouse has actually moved.
function Theme.MakeBottomResizable(frame, width, minHeight, maxHeight, onResized, onResizeStart)
    -- Taller than the visible border line so the edge is easy to grab, but
    -- kept inside the window's own bottom margin (below whatever sits above
    -- it) rather than sticking out past the frame.
    local HIT_HEIGHT = 8;

    frame:SetResizable(true);
    -- SetResizeBounds replaced the old SetMinResize/SetMaxResize pair in
    -- newer client builds (Classic now runs the same client binary as
    -- retail) - support both since we don't know which this client has.
    if (frame.SetResizeBounds) then
        frame:SetResizeBounds(width, minHeight, width, maxHeight);
    else
        frame:SetMinResize(width, minHeight);
        frame:SetMaxResize(width, maxHeight);
    end

    local resizeHandle = CreateFrame("Button", nil, frame);
    resizeHandle:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, -HIT_HEIGHT / 2);
    resizeHandle:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, -HIT_HEIGHT / 2);
    resizeHandle:SetHeight(HIT_HEIGHT);

    local resizeLine = frame:CreateTexture(nil, "OVERLAY");
    resizeLine:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT");
    resizeLine:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT");
    resizeLine:SetColorTexture(unpack(Theme.colors.accent));
    resizeLine:Hide();

    local isResizing, isHovering = false, false;
    local function updateResizeLine()
        local px = Pixel.PixelSize(1);
        if (isResizing) then
            resizeLine:SetHeight(px * 3);
            resizeLine:Show();
        elseif (isHovering) then
            resizeLine:SetHeight(px * 2);
            resizeLine:Show();
        else
            resizeLine:Hide();
        end
    end

    resizeHandle:SetScript("OnEnter", function()
        isHovering = true;
        updateResizeLine();
    end);
    resizeHandle:SetScript("OnLeave", function()
        isHovering = false;
        updateResizeLine();
    end);
    resizeHandle:SetScript("OnMouseDown", function(_, button)
        if (button ~= "LeftButton") then return; end
        isResizing = true;
        updateResizeLine();
        if (onResizeStart) then onResizeStart(); end
        frame:StartSizing("BOTTOM");
    end);
    -- A Button (unlike a plain mouse-enabled Frame) keeps receiving
    -- OnMouseUp for the button that was pressed even once the cursor has
    -- moved off it, which a fast downward drag off this thin strip easily
    -- does - without that capture the resize would never see the mouseup
    -- and StartSizing would keep tracking the cursor indefinitely.
    resizeHandle:SetScript("OnMouseUp", function()
        if (not isResizing) then return; end
        isResizing = false;
        frame:StopMovingOrSizing();

        local clamped = math.max(minHeight, math.min(maxHeight, frame:GetHeight()));
        local finalHeight = Pixel.SetHeight(frame, clamped);
        if (onResized) then onResized(finalHeight); end

        updateResizeLine();
    end);

    -- Disabling mid-drag (shouldn't normally happen, but guard anyway) drops
    -- straight out of the resize the same way OnMouseUp does, rather than
    -- leaving StartSizing tracking a cursor the handle can no longer see.
    local function setResizeEnabled(enabled)
        if (not enabled and isResizing) then
            isResizing = false;
            frame:StopMovingOrSizing();
        end

        resizeHandle:EnableMouse(enabled);
        resizeHandle:SetShown(enabled);

        if (not enabled) then
            isHovering = false;
            updateResizeLine();
        end
    end

    return resizeHandle, setResizeEnabled;
end
