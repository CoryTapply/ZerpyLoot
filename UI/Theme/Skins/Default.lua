--[[
"Default" skin: ElvUI-style window chrome - a solid dark background plus a
crisp 1-physical-pixel border, built on ZL.Pixel so the border stays exactly
1px on any UIScale or monitor. Colors match ElvUI's own default palette
(media.backdropcolor / media.bordercolor from its Profile defaults) so
ZerpyLoot's windows sit visually flush with an ElvUI-skinned UI.

This is also the root of every other skin's inheritance chain: it defines
EVERY colors/metrics/resizeHandle key and EVERY skin method, so a skin that
omits something falls back to the flat look defined here.
]]

local ZL = ZerpyLoot;
local Theme = ZL.Theme;
local Pixel = ZL.Pixel;
local Helpers = Theme.Helpers;

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

local Skin = {};

Skin.name = "Default";

-- Background alpha (0.9) intentionally matches Cell's options window
-- (Cell.StylizeFrame's default color) so ZerpyLoot's windows read as part of
-- the same family of dark, semi-transparent raid-tool UIs.
Skin.colors = {
    -- Window backdrop fill and border (see ApplyWindowBackdrop).
    windowBackground = { 0.1, 0.1, 0.1, 0.9 },
    windowBorder = { 0, 0, 0, 1 },

    -- Generic flat 1px outline (Theme.SkinBorder: icon and bar borders).
    outline = { 0, 0, 0, 1 },

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
    -- Also the window/panel title color, unless a skin sets `title`.
    accent = { 0x88 / 0xFF, 0x65 / 0xFF, 0xFF / 0xFF, 1 },
    accentHover = { 0xA0 / 0xFF, 0x85 / 0xFF, 1, 1 },

    -- Same red (#FF4F58) as the roll window's countdown bar hover color -
    -- shared here so any other destructive control (e.g. the trade queue
    -- row's delete icon) matches it exactly instead of drifting from a
    -- separately-hand-picked red.
    danger = { 0xff / 0xFF, 0x4f / 0xFF, 0x58 / 0xFF, 1 },

    -- Bright orange alert border - used to make a window's whole border "pop"
    -- for something that needs immediate attention (e.g. the roll tracker
    -- window when a soft-reserved item of yours is up for roll).
    warning = { 1, 0.55, 0, 1 },
};

Skin.metrics = {
    -- Windows shorter than this (the Group Loot anchor header is 18px tall)
    -- can't fit full-size window art (see the Blizzard skins).
    smallWindowHeight = 40,

    -- Height of the roll window's countdown bar, and the gap between the
    -- roll window's timer label and its seconds box.
    countdownBarHeight = 6,
    secondsBoxGap = 6,

    -- Atlas name prefix of a themed "delete" button art kit (Name,
    -- Name-Pressed, optional Name-Highlight) for the trade queue rows. nil
    -- = draw the flat trash icon instead.
    deleteButtonArtKit = nil,
};

-- See the block comment above Theme.MakeBottomResizable (Window.lua) for what
-- each field does.
Skin.resizeHandle = {
    color = "accent",
    restPx = 0,
    hoverPx = 2,
    dragPx = 3,
    hitHeight = 8,
    widthOffset = 0,
    hitWidthOffset = 0,
    offsetX = 0,
    hitOffsetX = 0,
    hitOffsetY = 0,
    offsetY = 0,
    opacity = 1,
    tintChrome = false,
};

-- ---------------------------------------------------------------------------
-- Windows
-- ---------------------------------------------------------------------------

--- No chrome art: windows are a plain flat backdrop (see ApplyWindowBackdrop).
function Skin.CreateWindowChrome()
    return nil;
end

--- Backs both the window's background and border with Blizzard's own
--- BackdropTemplate, using a flat solid-color texture for both bgFile and
--- edgeFile so there's no detail for the backdrop system's edge/corner
--- sampling to blur. The border thickness comes from
--- frame.pixelBorderThickness (see Theme.ApplyBorder).
function Skin.ApplyWindowBackdrop(frame)
    local colors = Theme.colors;
    Helpers.SetFlatBackdrop(frame, colors.windowBackground,
        frame.zlBorderColorOverride or colors.windowBorder, frame.pixelBorderThickness or 1);
end

function Skin.SetWindowBorderColor(frame, color)
    frame:SetBackdropBorderColor(unpack(color or Theme.colors.windowBorder));
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

--- UIPanelButtonTemplate, which SkinButton then strips down to a flat look.
function Skin.CreateButton(parent)
    return CreateFrame("Button", nil, parent, "UIPanelButtonTemplate");
end

-- A fixed size anchored to the button's own CENTER, rather than inset from
-- opposite corners, is what actually guarantees centering regardless of the
-- button's own dimensions.
local function positionCloseIcon(button, yOffset)
    local icon = button.zlCloseIcon;
    icon:ClearAllPoints();
    icon:SetPoint("CENTER", button, "CENTER", 0, yOffset);
end

-- Strips a Blizzard button of its default artwork (normal/pushed/highlight/
-- disabled textures plus the Left/Right/Middle pieces UIPanelButtonTemplate
-- draws them from) and replaces it with a flat, solid-color backdrop that
-- lightens on hover - the same recipe Cell uses for its own buttons.
local function skinButtonBackdrop(button, color, hoverColor)
    if (button.zlSkinned) then return; end

    Helpers.EnsureBackdrop(button);

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

    Helpers.SetFlatBackdrop(button, color, Theme.colors.buttonBorder, 1);

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

--- `variant` is "normal" (Cell's flat button), "accent" (solid accent fill,
--- e.g. "Start Roll") or "close" (Cell's reddish close button with its own
--- close.tga icon, copied into this addon's Media folder).
function Skin.SkinButton(button, variant)
    local colors = Theme.colors;

    if (variant == "accent") then
        skinButtonBackdrop(button, colors.accent, colors.accentHover);
    elseif (variant == "close") then
        skinButtonBackdrop(button, colors.close, colors.closeHover);

        if (not button.zlCloseIcon) then
            local icon = button:CreateTexture(nil, "OVERLAY");
            icon:SetTexture(CLOSE_ICON_TEXTURE);
            icon:SetSize(CLOSE_ICON_SIZE, CLOSE_ICON_SIZE);
            icon:SetVertexColor(1, 1, 1, 0.9);
            button.zlCloseIcon = icon;
            positionCloseIcon(button, 0);
        end
    else
        skinButtonBackdrop(button, colors.button, colors.buttonHover);
    end
end

-- ---------------------------------------------------------------------------
-- Inputs
-- ---------------------------------------------------------------------------

--- Cell's flat, dark input look.
function Skin.SkinEditBox(editBox)
    if (editBox.zlSkinned) then return; end

    Helpers.EnsureBackdrop(editBox);

    -- InputBoxTemplate boxes draw their border from these three textured
    -- pieces; a template-less EditBox simply won't have them.
    for _, regionName in pairs({ "Left", "Right", "Middle" }) do
        local region = editBox[regionName];
        if (region and region.SetTexture) then region:SetTexture(nil); end
    end

    Helpers.SetFlatBackdrop(editBox, Theme.colors.input, Theme.colors.inputBorder, 1);
    editBox:SetTextInsets(5, 5, 2, 2);

    editBox.zlSkinned = true;
end

function Skin.SkinInputBackground(frame)
    Helpers.EnsureBackdrop(frame);
    Helpers.SetFlatBackdrop(frame, Theme.colors.input, Theme.colors.inputBorder, 1);
end

-- ---------------------------------------------------------------------------
-- Borders
-- ---------------------------------------------------------------------------

function Skin.SkinBorder(frame)
    Helpers.EnsureBackdrop(frame);
    Helpers.SetFlatBackdrop(frame, nil, Theme.colors.outline, 1);
end

--- The thin flat outline pulled 1px outside the icon.
function Skin.SkinIconBorder(frame, icon)
    frame:ClearAllPoints();
    frame:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1);
    frame:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1);
    Theme.SkinBorder(frame);
end

--- The flat outline has no rarity art, so this is a no-op.
function Skin.SetIconBorderQuality() end

--- The thin flat outline pulled 1px outside the bar.
function Skin.SkinBarBorder(frame, bar)
    frame:ClearAllPoints();
    frame:SetPoint("TOPLEFT", bar, "TOPLEFT", -1, 1);
    frame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 1, -1);
    Theme.SkinBorder(frame);
end

-- ---------------------------------------------------------------------------
-- Scroll frames
-- ---------------------------------------------------------------------------

--- UIPanelScrollFrameTemplate, which StyleScrollBar then restyles.
function Skin.CreateScrollFrame(parent)
    return CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate");
end

--- Cell's flat, arrowless scrollbar (dark track, thin solid-color thumb)
--- instead of the default carved-stone artwork.
function Skin.StyleScrollBar(bar)
    local colors = Theme.colors;
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
    trackBorder:SetColorTexture(unpack(colors.scrollbarBorder));
    trackBorder:ClearAllPoints();
    trackBorder:SetPoint("TOP", bar, "TOP", 0, 0);
    trackBorder:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0);
    trackBorder:SetWidth(thumbWidth + 2 * pixel);

    local trackFill = bar.zlTrackFill;
    trackFill:SetColorTexture(unpack(colors.scrollbarTrack));
    trackFill:ClearAllPoints();
    trackFill:SetPoint("TOP", bar, "TOP", 0, -pixel);
    trackFill:SetPoint("BOTTOM", bar, "BOTTOM", 0, pixel);
    trackFill:SetWidth(thumbWidth);

    local thumb = bar.GetThumbTexture and bar:GetThumbTexture();
    if (thumb) then
        thumb:SetTexture(Helpers.FLAT_TEXTURE);
        thumb:SetVertexColor(unpack(colors.scrollbarThumb));
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
        thumbBorder:SetColorTexture(unpack(colors.scrollbarBorder));
        thumbBorder:ClearAllPoints();
        thumbBorder:SetPoint("TOPLEFT", thumb, "TOPLEFT", -pixel, pixel);
        thumbBorder:SetPoint("BOTTOMRIGHT", thumb, "BOTTOMRIGHT", pixel, -pixel);
    end
end

Theme.RegisterSkin("default", Skin);
