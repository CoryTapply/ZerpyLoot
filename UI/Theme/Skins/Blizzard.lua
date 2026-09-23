--[[
"Blizzard" skin: uses Blizzard's own modern art (the ButtonFrameTemplate metal
border, SharedButtonSmallTemplate buttons, ScrollFrameTemplate scrollbars,
InputBoxTemplate inputs) and leaves them unskinned, only swapping in this
addon's fonts so the Font setting still applies. Anything not overridden here
(flat outlines, window border color overrides) comes from the Default skin.

Other skins can build on this one with `base = "blizzard"` (see
BlizzardThin.lua, which changes only the window frame art).
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Helpers = Theme.Helpers;

local Skin = {};

Skin.name = "Blizzard";

Skin.colors = {
    -- The Blizzard art carries its own colors, so these are "no tint" values
    -- (they multiply the backdrop/border textures).
    windowBackground = { 1, 1, 1, 1 },
    windowBorder = { 1, 1, 1, 1 },

    -- Titles are Blizzard gold to match the rest of Blizzard's own headers
    -- instead of the accent.
    title = { 1, 0.82, 0, 1 },
};

Skin.metrics = {
    -- The border art is scaled down proportionally to this slimmer bar height
    -- (see SkinBarBorder).
    countdownBarHeight = 8,

    -- The Blizzard InputBoxTemplate's border art overhangs the box by 5px on
    -- the left, so the roll window nudges its box right to keep that from
    -- crowding the label.
    secondsBoxGap = 11,

    -- Blizzard's own delete button art, with pressed/highlight states.
    deleteButtonArtKit = "128-RedButton-Delete",
};

Skin.resizeHandle = {
    color = "accent",
    restPx = 0,
    hoverPx = 4,
    dragPx = 5,
    hitHeight = 8,
    widthOffset = -12,
    hitWidthOffset = -12,
    offsetX = 3,
    hitOffsetX = 3,
    offsetY = 0,
    hitOffsetY = 0,
    opacity = 0.7,
    tintChrome = true,
};

-- ---------------------------------------------------------------------------
-- Windows
-- ---------------------------------------------------------------------------

-- Blizzard-skin backdrop art. Tooltip-style border art (rather than the
-- ornate UI-DialogBox-Border) because its visible edge is thin enough to sit
-- inside the 12px margins every window's content is already laid out against.
local BG_TEXTURE = "Interface\\DialogFrame\\UI-DialogBox-Background";
local EDGE_TEXTURE = "Interface\\Tooltips\\UI-Tooltip-Border";

-- Window chrome: the same metal border and rock background the modern
-- ButtonFrameTemplate windows use, minus the header. That header is the top
-- border art itself in Blizzard's own ButtonFrameTemplate* layouts (their top
-- corners sit 16px above the frame and the background starts 21px down), so
-- it can't be hidden. Instead this builds a custom nine-slice from the SAME
-- "UI-Frame-Metal" atlases, reusing their thin BOTTOM corner/edge pieces
-- flipped upside-down for the top - so all four sides match the bottom edge
-- of a real ButtonFrameTemplate window exactly. (SimplePanelTemplate is the
-- other border-only option, but it uses a different, silvery art set.)
local CHROME_BG_TEXTURE = "Interface\\FrameGeneral\\UI-Background-Rock";

-- Same tiling/atlas handling as Blizzard's own NineSlice piece setup, plus a
-- vertical flip for the pieces marked flipVertical (texture coordinates have
-- to be set before the atlas is applied, as Blizzard's own code does).
local function setupChromePiece(_, piece, setup, pieceLayout)
    if (pieceLayout.flipVertical) then
        piece:SetTexCoord(0, 1, 1, 0);
    else
        piece:SetTexCoord(0, 1, 0, 1);
    end

    local info = C_Texture.GetAtlasInfo(pieceLayout.atlas);
    piece:SetHorizTile(info and info.tilesHorizontally or false);
    piece:SetVertTile(info and info.tilesVertically or false);
    if (info) then piece:SetAtlas(pieceLayout.atlas, true); end
end

-- Offsets are the ones ButtonFrameTemplateNoPortrait uses for its bottom
-- corners, mirrored to the top (y = +3 instead of -3). The left corners are
-- pulled in to x = -4 (Blizzard's own value is -8) - at -8 the wider left
-- corner art pokes out past the border as small grey corners.
local CHROME_LAYOUT = {
    disableSharpening = true,
    setupPieceVisualsFunction = setupChromePiece,
    TopLeftCorner = { layer = "OVERLAY", atlas = "UI-Frame-Metal-CornerBottomLeft", flipVertical = true, x = -12, y = 12 },
    TopRightCorner = { layer = "OVERLAY", atlas = "UI-Frame-Metal-CornerBottomRight", flipVertical = true, x = 8, y = 12 },
    BottomLeftCorner = { layer = "OVERLAY", atlas = "UI-Frame-Metal-CornerBottomLeft", x = -12, y = -8 },
    BottomRightCorner = { layer = "OVERLAY", atlas = "UI-Frame-Metal-CornerBottomRight", x = 8, y = -8 },
    TopEdge = { layer = "OVERLAY", atlas = "_UI-Frame-Metal-EdgeBottom", flipVertical = true },
    BottomEdge = { layer = "OVERLAY", atlas = "_UI-Frame-Metal-EdgeBottom" },
    LeftEdge = { layer = "OVERLAY", atlas = "!UI-Frame-Metal-EdgeLeft" },
    RightEdge = { layer = "OVERLAY", atlas = "!UI-Frame-Metal-EdgeRight" },
};

-- Resize-handle highlight: the original chrome pieces are never tinted.
-- Instead the straight bottom edge and a bottom band of each bottom corner
-- get a duplicate texture drawn over them (see createChrome), so every
-- highlighted part composites the same way over the untouched art and the
-- edge's soft shadow looks continuous across the bottom of the frame. The
-- corners are cropped to a band because their art also wraps up the sides of
-- the window, which shouldn't be tinted.
local RESIZE_HIGHLIGHT_CORNERS = { "BottomLeftCorner", "BottomRightCorner" };

-- Height, in the corner atlas's own pixels, of the band of each bottom corner
-- that takes the tint. nil = use the height of the straight bottom edge art,
-- which turned out to be about as tall as the whole corner, so set this to
-- something smaller (roughly the border's visible horizontal thickness) to
-- keep the tint off the part of the corner that curves up the sides.
local RESIZE_HIGHLIGHT_CORNER_HEIGHT = 15;

-- Builds the chrome as a child filling `frame` and returns it, or nil if
-- anything it needs is missing on this client (the caller then falls back to
-- a plain tooltip-art backdrop). Content layout is untouched: the chrome is
-- created first at the same frame level as the window's own children, so
-- they all draw on top of it.
local function createChrome(frame)
    local built, chrome = pcall(function()
        if (not (NineSliceUtil and NineSliceUtil.ApplyLayout)) then error("no NineSliceUtil"); end
        for _, piece in pairs(CHROME_LAYOUT) do
            if (type(piece) == "table" and not C_Texture.GetAtlasInfo(piece.atlas)) then
                error("missing atlas " .. piece.atlas);
            end
        end

        local chromeFrame = Helpers.CreateChromeFrame(frame);

        local bg = chromeFrame:CreateTexture(nil, "BACKGROUND", nil, -6);
        bg:SetTexture(CHROME_BG_TEXTURE, "REPEAT", "REPEAT");
        bg:SetHorizTile(true);
        bg:SetVertTile(true);
        bg:SetPoint("TOPLEFT", 2, -2);
        bg:SetPoint("BOTTOMRIGHT", -2, 2);

        NineSliceUtil.ApplyLayout(chromeFrame, CHROME_LAYOUT);

        -- Highlight duplicates for the resize handle: a second copy of the
        -- bottom edge (same atlas and tiling, filling the edge piece) plus,
        -- for each bottom corner, a copy of its atlas anchored along the
        -- bottom of that corner piece with its height and texture
        -- coordinates cropped to the horizontal part (kept in step with the
        -- piece's own cropping in updateChromeHeight). All hidden until
        -- SetResizeHighlight shows them.
        local highlightTextures = {};

        -- CHROME_LAYOUT.disableSharpening turns off pixel-grid snapping on the
        -- real pieces (NineSliceUtil.DisableSharpening), so they sit at exact
        -- sub-pixel positions. The duplicates must match, or the client
        -- snaps them to the pixel grid and they land slightly off the art
        -- they cover.
        local function newHighlightTexture()
            local texture = chromeFrame:CreateTexture(nil, "OVERLAY", nil, 1);
            texture:SetTexelSnappingBias(0);
            texture:SetSnapToPixelGrid(false);
            texture:SetDesaturated(true);
            texture:Hide();
            table.insert(highlightTextures, texture);
            return texture;
        end

        local edgeAtlasInfo = C_Texture.GetAtlasInfo(CHROME_LAYOUT.BottomEdge.atlas);
        local edgeBand = newHighlightTexture();
        edgeBand:SetHorizTile(edgeAtlasInfo and edgeAtlasInfo.tilesHorizontally or false);
        edgeBand:SetVertTile(edgeAtlasInfo and edgeAtlasInfo.tilesVertically or false);
        edgeBand:SetAtlas(CHROME_LAYOUT.BottomEdge.atlas, true);
        edgeBand:SetAllPoints(chromeFrame.BottomEdge);

        local edgeHeight = RESIZE_HIGHLIGHT_CORNER_HEIGHT or (edgeAtlasInfo and edgeAtlasInfo.height);
        local cornerBands = {};
        if (edgeHeight) then
            for _, name in ipairs(RESIZE_HIGHLIGHT_CORNERS) do
                local band = newHighlightTexture();
                band:SetAtlas(CHROME_LAYOUT[name].atlas);
                band:SetPoint("BOTTOMLEFT", chromeFrame[name], "BOTTOMLEFT");
                band:SetPoint("BOTTOMRIGHT", chromeFrame[name], "BOTTOMRIGHT");
                cornerBands[name] = band;
            end
        end

        -- The side edges are anchored between the top and bottom corners, so
        -- once the frame is too short for the corners to clear each other
        -- that span goes negative and the edge art draws inverted, sticking
        -- out past all four corners (e.g. the Roll window while it's shrunk
        -- to just the Start Roll prompt). In that case the side edges are
        -- hidden and each corner is cropped to half of the frame's height
        -- (keeping the outer, curved part of the art and trimming the part
        -- that would normally run into the edge), so they meet in the middle
        -- instead of overlapping.
        -- OnSizeChanged passes (self, width, height).
        local function updateChromeHeight(_, _, height)
            height = height or chromeFrame:GetHeight();
            -- Vertical space between the top corners' top and the bottom
            -- corners' bottom, including the overhang past the frame.
            local extent = height + CHROME_LAYOUT.TopLeftCorner.y - CHROME_LAYOUT.BottomLeftCorner.y;
            local half = extent / 2;
            local fullHeights = 0;

            for _, name in ipairs({ "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner" }) do
                local layout = CHROME_LAYOUT[name];
                local info = C_Texture.GetAtlasInfo(layout.atlas);
                local piece = chromeFrame[name];
                if (info) then
                    local cropped = math.min(info.height, half);
                    local keep = cropped / info.height;
                    -- Texture coordinates on an atlas piece are relative to
                    -- the atlas region (0-1), same as setupChromePiece. v
                    -- grows downward: the bottom corners keep the bottom of
                    -- the art; the top corners are drawn vertically flipped
                    -- and so keep it as their top.
                    if (layout.flipVertical) then
                        piece:SetTexCoord(0, 1, 1, 1 - keep);
                    else
                        piece:SetTexCoord(0, 1, 1 - keep, 1);
                    end
                    piece:SetHeight(cropped);

                    local band = cornerBands[name];
                    if (band) then
                        local bandHeight = math.min(edgeHeight, cropped);
                        band:SetHeight(bandHeight);
                        band:SetTexCoord(0, 1, 1 - bandHeight / info.height, 1);
                    end
                    if (name == "TopLeftCorner" or name == "BottomLeftCorner") then
                        fullHeights = fullHeights + info.height;
                    end
                end
            end

            local hasRoom = extent > fullHeights;
            chromeFrame.LeftEdge:SetShown(hasRoom);
            chromeFrame.RightEdge:SetShown(hasRoom);
        end
        chromeFrame:SetScript("OnSizeChanged", updateChromeHeight);
        updateChromeHeight();

        -- The recessed body panel Blizzard's windows show inside the border,
        -- filling the window since there's no title or button bar to leave
        -- room for.
        local inset = CreateFrame("Frame", nil, chromeFrame, "InsetFrameTemplate");
        inset:SetPoint("TOPLEFT", chromeFrame, "TOPLEFT", 3, 2);
        inset:SetPoint("BOTTOMRIGHT", chromeFrame, "BOTTOMRIGHT", 3, 2);
        chromeFrame.Inset = inset;

        -- Resize-handle hover/drag feedback (see Theme.MakeBottomResizable's
        -- tintChrome): shows the desaturated duplicates (bottom edge plus the
        -- horizontal band of each bottom corner) tinted over the untouched
        -- art, but not the parts of the corner art that wrap up the sides.
        -- Desaturating first makes the tint read as a clean hue rather than
        -- a muddy multiply of grey-brown; strength 0 hides them again.
        function chromeFrame:SetResizeHighlight(color, strength)
            local active = color ~= nil and (strength or 0) > 0;
            local r, g, b = 1, 1, 1;
            if (active) then r, g, b = Helpers.MixWithWhite(color, strength); end

            for _, highlight in ipairs(highlightTextures) do
                highlight:SetVertexColor(r, g, b);
                highlight:SetShown(active);
            end
        end

        return chromeFrame;
    end);

    return built and chrome or nil;
end

--- Tiny windows (the Group Loot header) can't fit the template chrome's
--- corners, so they get nil here and keep the plain tooltip-art backdrop.
function Skin.CreateWindowChrome(frame, _, height)
    if (height >= Theme.metrics.smallWindowHeight) then
        return createChrome(frame);
    end
    return nil;
end

--- Tooltip-art backdrop, used for windows without chrome.
function Skin.ApplyWindowBackdrop(frame)
    local colors = Theme.colors;
    local edgeSize = (frame:GetHeight() < Theme.metrics.smallWindowHeight) and 8 or 12;
    local inset = edgeSize / 4;
    frame:SetBackdrop({
        bgFile = BG_TEXTURE,
        edgeFile = EDGE_TEXTURE,
        tile = true,
        tileSize = 32,
        edgeSize = edgeSize,
        insets = { left = inset, right = inset, top = inset, bottom = inset },
    });
    frame:SetBackdropColor(unpack(colors.windowBackground));
    frame:SetBackdropBorderColor(unpack(frame.zlBorderColorOverride or colors.windowBorder));
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

-- Custom recolored replacement for the stock "128-RedButton" atlas art
-- (Media/Buttons/128RedButton.tga) - same 512x2048 layout as the game's own
-- underlying file (FileDataID 1536801/7367529, confirmed against the live
-- UiTextureAtlas/UiTextureAtlasMember DB2 data, since this addon has no
-- registered atlas of its own to draw on and there's no supported way to
-- register a brand new named atlas from an addon). ThreeSliceButtonMixin
-- only ever addresses this art by ATLAS NAME ("128-redbutton-left" etc,
-- resolved against the client's compiled atlas table), so instead this
-- overrides the Left/Right/Center regions' texture + tex-coords directly,
-- by hand, using the exact same pixel rectangles the real atlas entries use
-- (so the custom art lines up exactly where the stock art did) - reapplied
-- every time ThreeSliceButtonMixin:UpdateButton re-runs SetAtlas on those
-- regions, via the same OnMouseDown/OnMouseUp/OnEnable/OnDisable/OnShow
-- hooks already used for the color tint below (HookScript chains onto
-- whatever UpdateButton() is already wired to those events).
local CUSTOM_BUTTON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Buttons\\128RedButton.tga";
local CUSTOM_BUTTON_CANVAS_WIDTH, CUSTOM_BUTTON_CANVAS_HEIGHT = 512, 2048;

-- { left, right, top, bottom } pixel rects, copied verbatim from the live
-- UiTextureAtlasMember DB2 rows for 128-redbutton-left/-right/
-- _128-redbutton-center (and their -pressed/-disabled variants) and
-- 128-redbutton-highlight - same canvas, same rectangles, just read out of
-- our own file instead of the client's.
--
-- Left.PUSHED is the one exception: the DB2 row places it at
-- { 391, 505, 1171, 1299 }, but in this custom file that spot is blank -
-- the actual left-pressed art was drawn at { 378, 492, 1042, 1170 } instead
-- (confirmed visually, not from DB2 - this custom file's own layout, not
-- Blizzard's). Left.DISABLED's canonical DB2 slot overlaps this same art
-- almost entirely (391-505,1041-1169 vs 378-492,1042-1170), so the
-- "disabled" look may turn out to be this same pressed art rather than a
-- distinct grey-out - not yet confirmed, only PUSHED has been fixed here.
local CUSTOM_BUTTON_RECTS = {
    Left = {
        NORMAL   = { 391, 505, 911, 1039 },
        PUSHED   = { 378, 491, 1041, 1169 },
        DISABLED = { 262, 376, 1041, 1169 },
    },
    Right = {
        NORMAL   = { 0, 293, 521, 649 },
        PUSHED   = { 0, 293, 781, 909 },
        DISABLED = { 0, 293, 651, 779 },
    },
    Center = {
        NORMAL   = { 0, 64, 1, 129 },
        PUSHED   = { 0, 64, 261, 389 },
        DISABLED = { 0, 64, 131, 259 },
    },
};
local CUSTOM_BUTTON_HIGHLIGHT_RECT = { 1, 442, 391, 519 };

-- Every rect above is 128px tall, and the carved-stone border trim reads as
-- a uniform ~20px band on whichever edge is an outer edge of the button (top
-- and bottom on all three pieces; additionally the left edge of Left and the
-- right edge of Right - their other edge butts against Center, where there's
-- no border) - confirmed by sampling 128RedButton.tga directly (a flat black
-- seam separates the border trim from the face bevel at ~20px in from each
-- such edge, consistently). CUSTOM_BUTTON_FACE_RECTS below insets each rect
-- by that amount on its border edges only, giving a "face only" crop used to
-- tint just the interior (see applyCustomButtonFillArt) while
-- Left/Right/Center keep showing this same art un-desaturated, so the trim
-- reads as a constant neutral stone frame regardless of tint color.
local BORDER_TRIM_PX = 20;

local function insetRect(rect, left, right, top, bottom)
    return { rect[1] + left, rect[2] - right, rect[3] + top, rect[4] - bottom };
end

local CUSTOM_BUTTON_FACE_RECTS = { Left = {}, Right = {}, Center = {} };
for state, rect in pairs(CUSTOM_BUTTON_RECTS.Left) do
    CUSTOM_BUTTON_FACE_RECTS.Left[state] = insetRect(rect, BORDER_TRIM_PX, 0, BORDER_TRIM_PX, BORDER_TRIM_PX);
end
for state, rect in pairs(CUSTOM_BUTTON_RECTS.Right) do
    CUSTOM_BUTTON_FACE_RECTS.Right[state] = insetRect(rect, 0, BORDER_TRIM_PX, BORDER_TRIM_PX, BORDER_TRIM_PX);
end
for state, rect in pairs(CUSTOM_BUTTON_RECTS.Center) do
    CUSTOM_BUTTON_FACE_RECTS.Center[state] = insetRect(rect, 0, 0, BORDER_TRIM_PX, BORDER_TRIM_PX);
end

local function setCustomRegionTexture(region, rect)
    if (not region or not rect) then return; end
    region:SetTexture(CUSTOM_BUTTON_TEXTURE);
    region:SetTexCoord(
        rect[1] / CUSTOM_BUTTON_CANVAS_WIDTH, rect[2] / CUSTOM_BUTTON_CANVAS_WIDTH,
        rect[3] / CUSTOM_BUTTON_CANVAS_HEIGHT, rect[4] / CUSTOM_BUTTON_CANVAS_HEIGHT
    );
end

-- Mirrors ThreeSliceButtonMixin:UpdateButton's own state resolution
-- (ThreeSliceButtonTemplate.lua) so the piece picked here always matches
-- what Blizzard's own code just set via SetAtlas, right before this
-- overrides it: `buttonState = buttonState or self:GetButtonState()`, then
-- forced to DISABLED regardless if the button isn't enabled. `explicitState`
-- mirrors the parameter that call takes - callers matching Blizzard's own
-- OnMouseDown/OnMouseUp scripts (which pass "PUSHED"/"NORMAL" directly
-- rather than reading GetButtonState()) MUST pass it too: GetButtonState()
-- is not guaranteed to already read "PUSHED" the instant OnMouseDown's
-- HookScript handler runs (nor "NORMAL" the instant OnMouseUp's does) - that
-- mismatch was showing up as the pressed art flashing in a frame late (after
-- mouseup instead of during mousedown) and, since our two art layers
-- (border via applyCustomButtonArt, face via applyCustomButtonFillArt) could
-- each land on a different stale read, an occasional mismatched Left crop.
-- Shared by applyCustomButtonArt and applyCustomButtonFillArt, since both
-- need to pick the same NORMAL/PUSHED/DISABLED rect.
local function resolveButtonArtState(button, explicitState)
    local buttonState = explicitState or button:GetButtonState();
    if (not button:IsEnabled()) then buttonState = "DISABLED"; end
    return buttonState;
end

local function applyCustomButtonArt(button, explicitState)
    if (not button.Left or not button.Right or not button.Center) then
        return; -- not a ThreeSliceButtonTemplate (classic UIPanelButtonTemplate fallback)
    end

    local buttonState = resolveButtonArtState(button, explicitState);
    setCustomRegionTexture(button.Left, CUSTOM_BUTTON_RECTS.Left[buttonState] or CUSTOM_BUTTON_RECTS.Left.NORMAL);
    setCustomRegionTexture(button.Right, CUSTOM_BUTTON_RECTS.Right[buttonState] or CUSTOM_BUTTON_RECTS.Right.NORMAL);
    setCustomRegionTexture(button.Center, CUSTOM_BUTTON_RECTS.Center[buttonState] or CUSTOM_BUTTON_RECTS.Center.NORMAL);
end

-- The inset "face only" counterpart to applyCustomButtonArt above - lays a
-- second, smaller copy of the same art over just the interior of each piece
-- (see CUSTOM_BUTTON_FACE_RECTS), on separate texture regions
-- (button.zlFillLeft/Center/Right, created by ensureButtonFillTextures) so
-- it can be desaturated/tinted independently of the border trim underneath.
local function applyCustomButtonFillArt(button, explicitState)
    local buttonState = resolveButtonArtState(button, explicitState);
    setCustomRegionTexture(button.zlFillLeft, CUSTOM_BUTTON_FACE_RECTS.Left[buttonState] or CUSTOM_BUTTON_FACE_RECTS.Left.NORMAL);
    setCustomRegionTexture(button.zlFillRight, CUSTOM_BUTTON_FACE_RECTS.Right[buttonState] or CUSTOM_BUTTON_FACE_RECTS.Right.NORMAL);
    setCustomRegionTexture(button.zlFillCenter, CUSTOM_BUTTON_FACE_RECTS.Center[buttonState] or CUSTOM_BUTTON_FACE_RECTS.Center.NORMAL);
end

-- Native height, in the source art's pixels, of every rect above (confirmed
-- against the live DB2 rows the same way CUSTOM_BUTTON_RECTS was) - lets
-- BORDER_TRIM_PX convert to an on-screen inset via the button's actual
-- current height, whatever size this particular button template uses
-- (SharedButtonSmallTemplate is 28px tall, others differ - see
-- ThreeSliceButtonTemplate.xml).
local BUTTON_PIECE_NATIVE_HEIGHT = 128;

-- Lazily creates the inset "face" overlays the first time a button is
-- tinted, and anchors them inset from their corresponding Left/Center/Right
-- piece by the border trim's on-screen thickness. Left only insets its outer
-- (left) edge, Right only its outer (right) edge - neither insets the edge
-- that butts against Center, since there's no border there to exclude - and
-- Center insets neither side edge, only top/bottom (see CUSTOM_BUTTON_FACE_RECTS).
-- Anchored once: none of this addon's buttons resize after creation, and the
-- anchors track Left/Center/Right's own rendered edges (including
-- ThreeSliceButtonMixin:UpdateScale's width-clipping), so they stay correct
-- even though this only runs once.
local function ensureButtonFillTextures(button)
    if (button.zlFillLeft) then return; end
    if (not button.Left or not button.Right or not button.Center) then return; end

    local insetPx = BORDER_TRIM_PX * (button:GetHeight() / BUTTON_PIECE_NATIVE_HEIGHT);

    local fillLeft = button:CreateTexture(nil, "ARTWORK");
    fillLeft:SetPoint("TOPLEFT", button.Left, "TOPLEFT", insetPx, -insetPx);
    fillLeft:SetPoint("BOTTOMRIGHT", button.Left, "BOTTOMRIGHT", 0, insetPx);

    local fillCenter = button:CreateTexture(nil, "ARTWORK");
    fillCenter:SetPoint("TOPLEFT", button.Center, "TOPLEFT", 0, -insetPx);
    fillCenter:SetPoint("BOTTOMRIGHT", button.Center, "BOTTOMRIGHT", 0, insetPx);

    local fillRight = button:CreateTexture(nil, "ARTWORK");
    fillRight:SetPoint("TOPLEFT", button.Right, "TOPLEFT", 0, -insetPx);
    fillRight:SetPoint("BOTTOMRIGHT", button.Right, "BOTTOMRIGHT", -insetPx, insetPx);

    button.zlFillLeft, button.zlFillCenter, button.zlFillRight = fillLeft, fillCenter, fillRight;
end

-- Set once (per button, the first time it's tinted, tracked via
-- zlCustomHighlightApplied below) - unlike Left/Right/Center, the highlight
-- texture isn't re-applied per interaction state, just shown/hidden by the
-- Button widget's own built-in highlight mechanism. Untinted buttons never
-- call this, so they keep the template's stock highlight art.
local function applyCustomButtonHighlight(button)
    local highlightTexture = button.GetHighlightTexture and button:GetHighlightTexture();
    setCustomRegionTexture(highlightTexture, CUSTOM_BUTTON_HIGHLIGHT_RECT);
end

--- The current retail SharedButtonSmallTemplate, falling back to the classic
--- template on clients without it. Left with the template's own stock
--- "128-RedButton" art untouched - the custom recolorable texture (see
--- CUSTOM_BUTTON_TEXTURE above) is only swapped in for buttons that end up
--- tinted, via SkinButton/applyButtonTint below, so an untinted button still
--- reads as the standard Blizzard red.
function Skin.CreateButton(parent)
    local ok, button = pcall(CreateFrame, "Button", nil, parent, "SharedButtonSmallTemplate");
    if (ok and button) then
        return button;
    end
    return CreateFrame("Button", nil, parent, "UIPanelButtonTemplate");
end

-- A translucent color rectangle laid over the button's native art read as a
-- flat, muddy block (the art's own colors and the wash multiplying together
-- under it), so this tints the actual face textures instead: desaturate them
-- first, then apply a clean vertex-color tint - the same trick
-- Theme.MakeBottomResizable's tintChrome uses for the window border's resize
-- highlight (see chromeFrame:SetResizeHighlight above), just applied
-- directly to the button's own textures rather than a duplicate.
--
-- SharedButtonSmallTemplate is a ThreeSliceButtonTemplate under the hood
-- (Blizzard_SharedXML/Shared/Button/ThreeSliceButtonTemplate.xml/.lua,
-- confirmed against the client source) - its face art is three regions
-- parentKey'd "Left"/"Right"/"Center" (NOT "Middle", the older
-- UIPanelButtonTemplate's naming this originally - and wrongly - reused).
-- Those regions themselves are left un-desaturated always (see
-- applyCustomButtonArt) so their border trim reads as a constant neutral
-- stone frame - only the inset "face" overlays over them
-- (zlFillLeft/Center/Right, see ensureButtonFillTextures/
-- applyCustomButtonFillArt) get tinted here. The UIPanelButtonTemplate
-- fallback (older clients without SharedButtonSmallTemplate) has no such
-- split; its GetNormalTexture()/GetPushedTexture() slots are tinted
-- directly, uncropped, as before.
local BUTTON_FILL_KEYS = { "zlFillLeft", "zlFillRight", "zlFillCenter" };

local function forEachButtonFaceTexture(button, fn)
    if (button.GetNormalTexture) then fn(button:GetNormalTexture()); end
    if (button.GetPushedTexture) then fn(button:GetPushedTexture()); end
    for _, key in ipairs(BUTTON_FILL_KEYS) do
        fn(button[key]);
    end
end

-- The native art (SharedButtonSmallTemplate's "128-RedButton" atlas) is a
-- fairly dark red/maroon stone texture - desaturating it produces a fairly
-- dark grey, and multiplying a fully-saturated response color onto that
-- comes out dark and muddy. Mixing the tint color toward white first (same
-- helper Theme.MakeBottomResizable's tintChrome uses for the window
-- border's resize highlight) keeps the result light enough to read clearly
-- against the dark base art while still clearly carrying that hue.
local BUTTON_TINT_STRENGTH = 1;

local function applyButtonTint(button, explicitState)
    local color = button.zlTintColor;

    -- Only a tinted button swaps in the custom recolorable art - an
    -- untinted one keeps the stock "128-RedButton" look Skin.CreateButton
    -- left it with, native atlas and all.
    if (color) then
        applyCustomButtonArt(button, explicitState);
        ensureButtonFillTextures(button);
        applyCustomButtonFillArt(button, explicitState);
        if (not button.zlCustomHighlightApplied) then
            applyCustomButtonHighlight(button);
            button.zlCustomHighlightApplied = true;
        end
    end

    forEachButtonFaceTexture(button, function(tex)
        if (not tex or not tex.SetDesaturated) then return; end
        if (color) then
            tex:SetDesaturated(true);
            tex:SetVertexColor(Helpers.MixWithWhite(color, BUTTON_TINT_STRENGTH));
        else
            tex:SetDesaturated(false);
            tex:SetVertexColor(1, 1, 1);
        end
    end);
end

--- Keeps the template's own artwork exactly as shipped and only swaps in this
--- addon's fonts, so the Font setting still applies to button labels. Gold
--- normal / white highlight / grey disabled, same as Blizzard's own
--- GameFontNormal/Highlight/Disable button labels. The stock close button art
--- is left completely untouched.
---
--- `variant` may also be a custom { r, g, b } color table (e.g. one loot
--- council response option's color) - applied as a desaturate + vertex-color
--- tint over the native face art (see applyButtonTint above) rather than the
--- Default skin's full flat-backdrop recolor, since there's no flat backdrop
--- here to replace. Font setup only ever needs to run once (tracked
--- separately via zlFontSkinned) so the tint itself can still be freely
--- reapplied/changed afterwards, e.g. to grey out an unselected loot council
--- response button. Re-applied on every interaction-state change too, in
--- case the template's own scripts repaint the face art the way
--- UIPanelButtonTemplate's do (see the Default skin's hideAllTextures for
--- that exact, confirmed failure mode on a different template).
function Skin.SkinButton(button, variant)
    if (variant ~= "close" and not button.zlFontSkinned) then
        button:SetNormalFontObject(Theme.fonts.normal);
        button:SetHighlightFontObject(Theme.fonts.highlight);
        button:SetDisabledFontObject(Theme.fonts.buttonDisabled);
        button.zlFontSkinned = true;
    end

    button.zlTintColor = (type(variant) == "table") and variant or nil;
    applyButtonTint(button);

    if (not button.zlTintHooked) then
        -- OnMouseDown/OnMouseUp get their state passed explicitly, matching
        -- ThreeSliceButtonMixin:OnMouseDown/OnMouseUp (which call
        -- UpdateButton("PUSHED")/UpdateButton("NORMAL") directly rather than
        -- reading GetButtonState()) - see resolveButtonArtState above for
        -- why that matters. OnEnable/OnDisable/OnShow have no explicit state
        -- of their own to pass (Blizzard wires them straight to
        -- UpdateButton with no argument too), so they fall through to
        -- GetButtonState(), same as Blizzard's own resolution there.
        local EVENT_STATES = { OnMouseDown = "PUSHED", OnMouseUp = "NORMAL" };
        for _, script in ipairs({ "OnMouseDown", "OnMouseUp", "OnEnable", "OnDisable", "OnShow" }) do
            local explicitState = EVENT_STATES[script];
            -- Only re-applies the custom art (it re-sets the region's
            -- SetTexture/SetTexCoord, which UpdateButton's own SetAtlas call
            -- just overwrote) when the button is tinted - see
            -- applyButtonTint above. An untinted button is left alone here,
            -- so it keeps whatever stock atlas UpdateButton just set.
            button:HookScript(script, function(self)
                applyButtonTint(self, explicitState);
            end);
        end
        button.zlTintHooked = true;
    end

    button.zlSkinned = true;
end

-- ---------------------------------------------------------------------------
-- Inputs
-- ---------------------------------------------------------------------------

-- Horizontal text inset inside a Blizzard-skinned InputBoxTemplate box, so text
-- clears the border caps (the template's own insets are zero).
local INPUT_TEXT_INSET = 8;

--- The InputBoxTemplate's own border art is left as-is, but the template's
--- insets are zero, so text (especially right-justified numbers) would run
--- over the border caps - pull it inside them.
function Skin.SkinEditBox(editBox)
    if (editBox.zlSkinned) then return; end

    editBox:SetTextInsets(INPUT_TEXT_INSET, INPUT_TEXT_INSET, 0, 0);
    editBox.zlSkinned = true;
end

--- The same Common-Input-Border 9-slice Blizzard's own multi-line inputs
--- (InputScrollFrameTemplate) draw, kept inside the frame's bounds rather than
--- overhanging them by 5px like the template.
function Skin.SkinInputBackground(frame)
    Helpers.EnsureBackdrop(frame);

    if (frame.zlInputBorder) then return; end
    frame.zlInputBorder = true;

    local function slice(suffix)
        local tex = frame:CreateTexture(nil, "BACKGROUND");
        tex:SetTexture("Interface\\Common\\Common-Input-Border-" .. suffix);
        return tex;
    end

    local corner = 8;
    local tl, tr, bl, br = slice("TL"), slice("TR"), slice("BL"), slice("BR");
    local top, bottom, left, right, middle = slice("T"), slice("B"), slice("L"), slice("R"), slice("M");

    tl:SetSize(corner, corner); tl:SetPoint("TOPLEFT");
    tr:SetSize(corner, corner); tr:SetPoint("TOPRIGHT");
    bl:SetSize(corner, corner); bl:SetPoint("BOTTOMLEFT");
    br:SetSize(corner, corner); br:SetPoint("BOTTOMRIGHT");

    top:SetPoint("TOPLEFT", tl, "TOPRIGHT"); top:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT");
    bottom:SetPoint("TOPLEFT", bl, "TOPRIGHT"); bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT");
    left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT"); left:SetPoint("BOTTOMRIGHT", bl, "TOPRIGHT");
    right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT"); right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT");
    middle:SetPoint("TOPLEFT", left, "TOPRIGHT"); middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT");
end

-- ---------------------------------------------------------------------------
-- Borders
-- ---------------------------------------------------------------------------

-- Item icon border: the same UI-Quickslot2 frame Blizzard's own
-- ItemButtonTemplate draws over an item icon (64px art over a 37px button,
-- nudged 1px down), scaled proportionally to the icon's size.
local ICON_BORDER_TEXTURE = "Interface\\Buttons\\UI-Quickslot2";
local ICON_BORDER_NATIVE_ICON_SIZE = 37;
local ICON_BORDER_NATIVE_ART_SIZE = 64;
local ICON_BORDER_NATIVE_Y_OFFSET = -1;

function Skin.SkinIconBorder(frame, icon)
    frame:ClearAllPoints();
    frame:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0);
    frame:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0);
    if (frame.zlIconBorderArt) then return; end

    local scale = icon:GetWidth() / ICON_BORDER_NATIVE_ICON_SIZE;
    local art = frame:CreateTexture(nil, "OVERLAY");
    art:SetTexture(ICON_BORDER_TEXTURE);
    art:SetSize(ICON_BORDER_NATIVE_ART_SIZE * scale, ICON_BORDER_NATIVE_ART_SIZE * scale);
    art:SetPoint("CENTER", frame, "CENTER", 0, ICON_BORDER_NATIVE_Y_OFFSET * scale);
    frame.zlIconBorderArt = art;
end

local ICON_QUALITY_BORDER_TEXTURE = "Interface\\Common\\WhiteIconFrame";

--- Tints the icon border (see SkinIconBorder) with the item's rarity, using
--- the same WhiteIconFrame overlay and bag quality colors as Blizzard's own
--- item buttons. Hidden when the quality is unknown/poor.
function Skin.SetIconBorderQuality(frame, quality)
    local art = frame.zlIconBorderArt;
    if (not art) then return; end

    local color = quality and ColorManager and ColorManager.GetColorDataForBagItemQuality(quality);
    if (not color) then
        if (frame.zlIconQualityBorder) then frame.zlIconQualityBorder:Hide(); end
        return;
    end

    if (not frame.zlIconQualityBorder) then
        local overlay = frame:CreateTexture(nil, "OVERLAY", nil, 1);
        overlay:SetTexture(ICON_QUALITY_BORDER_TEXTURE);
        overlay:SetAllPoints(frame);
        frame.zlIconQualityBorder = overlay;
    end

    frame.zlIconQualityBorder:SetVertexColor(color.r, color.g, color.b);
    frame.zlIconQualityBorder:Show();
end

-- Status bar border: the same three-piece art (bordered left/right caps plus
-- a stretched middle) Blizzard's own objective-tracker progress bars draw
-- over a 15px-tall StatusBar. That art is 22px tall with 3px cap overhang;
-- here it's scaled down proportionally to a slimmer bar (metrics.
-- countdownBarHeight) so the border doesn't dominate the window (it stays a
-- few pixels outside the bar).
local BAR_BORDER_TEXTURE = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-BarBorder";
local BAR_BORDER_NATIVE_BAR_HEIGHT = 15;
local BAR_BORDER_NATIVE_HEIGHT = 22;
local BAR_BORDER_NATIVE_CAP_WIDTH = 9;
local BAR_BORDER_NATIVE_CAP_OVERHANG = 3;

function Skin.SkinBarBorder(frame, bar)
    frame:ClearAllPoints();
    frame:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0);
    frame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0);
    -- Explicitly above the bar: a sibling created later isn't guaranteed to
    -- draw over it, and the bar's fill would otherwise cover the art.
    frame:SetFrameStrata(bar:GetFrameStrata());
    frame:SetFrameLevel(bar:GetFrameLevel() + 2);
    if (frame.zlBarBorderLeft) then return; end

    local scale = Theme.metrics.countdownBarHeight / BAR_BORDER_NATIVE_BAR_HEIGHT;
    local capWidth = BAR_BORDER_NATIVE_CAP_WIDTH * scale;
    local artHeight = BAR_BORDER_NATIVE_HEIGHT * scale;
    local overhang = BAR_BORDER_NATIVE_CAP_OVERHANG * scale;

    local left = frame:CreateTexture(nil, "ARTWORK");
    left:SetTexture(BAR_BORDER_TEXTURE);
    left:SetSize(capWidth, artHeight);
    left:SetTexCoord(0.007843, 0.043137, 0.193548, 0.774193);
    left:SetPoint("LEFT", frame, "LEFT", -overhang, 0);

    local right = frame:CreateTexture(nil, "ARTWORK");
    right:SetTexture(BAR_BORDER_TEXTURE);
    right:SetSize(capWidth, artHeight);
    right:SetTexCoord(0.043137, 0.007843, 0.193548, 0.774193);
    right:SetPoint("RIGHT", frame, "RIGHT", overhang, 0);

    local middle = frame:CreateTexture(nil, "ARTWORK");
    middle:SetTexture(BAR_BORDER_TEXTURE);
    middle:SetTexCoord(0.113726, 0.1490196, 0.193548, 0.774193);
    middle:SetPoint("TOPLEFT", left, "TOPRIGHT");
    middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT");

    frame.zlBarBorderLeft = left;
end

-- ---------------------------------------------------------------------------
-- Scroll frames
-- ---------------------------------------------------------------------------

--- The modern ScrollFrameTemplate, falling back to the legacy one.
function Skin.CreateScrollFrame(parent)
    local ok, scrollFrame = pcall(CreateFrame, "ScrollFrame", nil, parent, "ScrollFrameTemplate");
    if (ok and scrollFrame) then return scrollFrame; end
    return CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate");
end

--- Keeps the stock scrollbar art (arrows, stone thumb).
function Skin.StyleScrollBar() end

Theme.RegisterSkin("blizzard", Skin);
