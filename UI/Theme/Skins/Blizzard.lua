--[[
"Blizzard" skin: uses Blizzard's own modern art (the ButtonFrameTemplate metal
border, SharedButtonSmallTemplate buttons, ScrollFrameTemplate scrollbars,
InputBoxTemplate inputs) and leaves them unskinned, only swapping in this
addon's fonts so the Font setting still applies. Anything not overridden here
(flat outlines, window border color overrides) comes from the Default skin.

Other skins can build on this one with `base = "blizzard"` (see
BlizzardThin.lua, which changes only the window frame art).
]]

local ZL = ZerpyLoot;
local Theme = ZL.Theme;
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

--- The current retail SharedButtonSmallTemplate, falling back to the classic
--- template on clients without it.
function Skin.CreateButton(parent)
    local ok, button = pcall(CreateFrame, "Button", nil, parent, "SharedButtonSmallTemplate");
    if (ok and button) then return button; end
    return CreateFrame("Button", nil, parent, "UIPanelButtonTemplate");
end

--- Keeps the template's own artwork exactly as shipped and only swaps in this
--- addon's fonts, so the Font setting still applies to button labels. Gold
--- normal / white highlight / grey disabled, same as Blizzard's own
--- GameFontNormal/Highlight/Disable button labels. The stock close button art
--- is left completely untouched.
function Skin.SkinButton(button, variant)
    if (button.zlSkinned) then return; end

    if (variant ~= "close") then
        button:SetNormalFontObject(Theme.fonts.normal);
        button:SetHighlightFontObject(Theme.fonts.highlight);
        button:SetDisabledFontObject(Theme.fonts.buttonDisabled);
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
