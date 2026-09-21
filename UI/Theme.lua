--[[
ElvUI-style window chrome: a solid dark background plus a crisp
1-physical-pixel border, built on ZL.Pixel so the border stays exactly 1px
on any UIScale or monitor. Colors match ElvUI's own default palette
(media.backdropcolor / media.bordercolor from its Profile defaults) so
ZerpyLoot's windows sit visually flush with an ElvUI-skinned UI.

That is the "Default" theme. A second, "Blizzard" theme (see Theme.THEMES)
uses Blizzard's own modern art (the ButtonFrameTemplate metal border,
SharedButtonSmallTemplate buttons, ScrollFrameTemplate scrollbars) and leaves
them unskinned. A third, "Blizzard Thin" theme keeps every one of those
buttons, input boxes and scrollbars, and only swaps the window chrome for the
thinner action-bar-style frame art WoW Forever's BagsBar draws. The theme is
chosen once at login (Theme.Init) - every Skin* function below branches on it.
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

-- Every piece of text this addon draws uses this flag string (outline + the
-- SLUG text renderer). Exposed so the few call sites that call SetFont
-- directly (instead of inheriting a Theme.fonts object) stay in sync.
Theme.FONT_FLAGS = "OUTLINE, SLUG";
local FONT_OUTLINE = Theme.FONT_FLAGS;
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

-- Available skins. "default" is the flat dark look this file was originally
-- written for; "blizzard" leaves Blizzard's own buttons, scrollbars, close
-- buttons and input boxes alone and puts Blizzard's dialog/tooltip art behind
-- the windows instead; "blizzardthin" is "blizzard" with the window frame
-- swapped for the BagsBar's border art (see createThinChrome). THEME_ORDER is
-- the order the options dropdown lists them in.
Theme.THEMES = { default = "Default", blizzard = "Blizzard", blizzardthin = "Blizzard Thin" };
Theme.THEME_ORDER = { "default", "blizzard", "blizzardthin" };
Theme.DEFAULT_THEME = "default";

Theme.current = nil; -- set once by Theme.Init, at login

-- Blizzard-skin chrome. Tooltip-style border art (rather than the ornate
-- UI-DialogBox-Border) because its visible edge is thin enough to sit inside
-- the 12px margins every window's content is already laid out against.
local BLIZZARD_BG_TEXTURE = "Interface\\DialogFrame\\UI-DialogBox-Background";
-- Horizontal text inset inside a Blizzard-skinned InputBoxTemplate box, so text
-- clears the border caps (the template's own insets are zero).
local BLIZZARD_INPUT_TEXT_INSET = 8;
local BLIZZARD_EDGE_TEXTURE = "Interface\\Tooltips\\UI-Tooltip-Border";

-- Windows shorter than this (the Group Loot anchor header is 18px tall) get
-- a thinner border, since a full-size one's corners would overlap each other.
local BLIZZARD_SMALL_WINDOW_HEIGHT = 40;

Theme.blizzardColors = {
    background = { 1, 1, 1, 1 },
    border = { 1, 1, 1, 1 },
    input = { 0, 0, 0, 0.75 },
    inputBorder = { 1, 1, 1, 1 },
};

-- True for both Blizzard-art themes: everything except the window frame
-- (buttons, close buttons, input boxes, scrollbars, icon and bar borders,
-- fonts) is identical between them, so those all branch on this.
function Theme.IsBlizzard()
    return Theme.current == "blizzard" or Theme.current == "blizzardthin";
end

-- True only for the Blizzard Thin theme, which changes just the window frame.
function Theme.IsBlizzardThin()
    return Theme.current == "blizzardthin";
end

-- Skin calls made before Theme.Init runs (the options panel builds its
-- widgets at file-load time, before saved variables exist and so before the
-- theme is known) are queued here and replayed once it is.
local pendingSkins = {};

local function deferUntilReady(skinFn)
    return function(...)
        if (Theme.current) then return skinFn(...); end

        local args = { n = select("#", ...), ... };
        table.insert(pendingSkins, function() skinFn(unpack(args, 1, args.n)); end);
    end;
end

-- Titles are purple (the default skin's accent) or Blizzard gold to match
-- the rest of Blizzard's own headers; every FontString using these named
-- fonts follows automatically since they're font objects.
local function applyThemeFontColors()
    local color = Theme.IsBlizzard() and COLOR_GOLD or Theme.colors.accent;
    _G[Theme.fonts.title]:SetTextColor(unpack(color));
    _G[Theme.fonts.titleLarge]:SetTextColor(unpack(color));
end

--- Locks in this session's theme (see Settings.Init) and replays any skin
--- calls that were queued waiting for it.
function Theme.Init(key)
    Theme.current = Theme.THEMES[key] and key or Theme.DEFAULT_THEME;
    applyThemeFontColors();

    local queued = pendingSkins;
    pendingSkins = {};
    for _, skinFn in ipairs(queued) do skinFn(); end
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

-- Blizzard-theme window chrome: the same metal border and rock background the
-- modern ButtonFrameTemplate windows use, minus the header. That header is the
-- top border art itself in Blizzard's own ButtonFrameTemplate* layouts (their
-- top corners sit 16px above the frame and the background starts 21px down),
-- so it can't be hidden. Instead this builds a custom nine-slice from the
-- SAME "UI-Frame-Metal" atlases, reusing their thin BOTTOM corner/edge pieces
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

        local chromeFrame = CreateFrame("Frame", nil, frame);
        chromeFrame:SetAllPoints(frame);
        chromeFrame:EnableMouse(false);
        chromeFrame:SetFrameLevel(frame:GetFrameLevel());

        local bg = chromeFrame:CreateTexture(nil, "BACKGROUND", nil, -6);
        bg:SetTexture(CHROME_BG_TEXTURE, "REPEAT", "REPEAT");
        bg:SetHorizTile(true);
        bg:SetVertTile(true);
        bg:SetPoint("TOPLEFT", 2, -2);
        bg:SetPoint("BOTTOMRIGHT", -2, 2);

        NineSliceUtil.ApplyLayout(chromeFrame, CHROME_LAYOUT);

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

        return chromeFrame;
    end);

    return built and chrome or nil;
end

-- Blizzard Thin window chrome: the "UI-HUD-ActionBar-Frame" atlas, which is
-- exactly what WoW Forever's BagsBar draws as its BorderArt. That bar has no
-- separate background layer - this one atlas is the whole plate, dark fill
-- and ornate edge together - so it serves as both the border and the
-- background here too.
--
-- The atlas is 55x55 and carries its own nine-slice data: margins of 20
-- (left/right) and 25 (top/bottom), tiled. The client applies those
-- margins itself when the atlas is put on ONE texture and the texture is
-- resized, which is how the bar stretches it over any width; so this does the
-- same, rather than cutting the atlas into pieces by hand. (An earlier
-- version sliced it at a guessed 8px, which cut straight through the corner
-- ornaments and stretched them.)
local THIN_CHROME_ATLAS = "UI-HUD-ActionBar-Frame";

-- Only used if the client doesn't report the atlas's own slice margins
-- (left, top, right, bottom) - the values from the atlas data.
local THIN_CHROME_FALLBACK_MARGINS = { 20, 25, 20, 25 };

-- How far the art extends past the window's edges, exactly as the BagsBar
-- anchors it around its own buttons.
local THIN_CHROME_OUTSET = { left = 6, top = 6, right = 5, bottom = 5 };

-- Builds the chrome as a child of `frame` and returns it, or nil when the
-- atlas or the slice API isn't available (the caller then falls back to the
-- plain tooltip-art backdrop). Same contract as createChrome: content layout
-- is untouched, and the chrome sits at the window's own frame level so its
-- children draw on top of it. Unlike createChrome it also works for tiny
-- windows: the slice margins shrink to fit instead of the border being
-- dropped.
local function createThinChrome(frame)
    if (not C_Texture.GetAtlasInfo(THIN_CHROME_ATLAS)) then return nil; end

    local built, chrome = pcall(function()
        local chromeFrame = CreateFrame("Frame", nil, frame);
        chromeFrame:SetAllPoints(frame);
        chromeFrame:EnableMouse(false);
        chromeFrame:SetFrameLevel(frame:GetFrameLevel());

        local art = chromeFrame:CreateTexture(nil, "BACKGROUND", nil, -6);
        art:SetAtlas(THIN_CHROME_ATLAS);
        art:SetPoint("TOPLEFT", chromeFrame, "TOPLEFT", -THIN_CHROME_OUTSET.left, THIN_CHROME_OUTSET.top);
        art:SetPoint("BOTTOMRIGHT", chromeFrame, "BOTTOMRIGHT", THIN_CHROME_OUTSET.right, -THIN_CHROME_OUTSET.bottom);

        -- Read the margins back rather than assuming a unit: whatever
        -- SetAtlas applied is by definition in the units the setter takes.
        local left, top, right, bottom = art:GetTextureSliceMargins();
        if (not (left and top and right and bottom)) then
            left, top, right, bottom = unpack(THIN_CHROME_FALLBACK_MARGINS);
        end
        art:SetTextureSliceMode(Enum.UITextureSliceMode.Tiled);

        -- Once the art is too small for both opposite margins the corners
        -- would overlap, so all four are scaled down together (keeping the
        -- corners' shape) until they fit. OnSizeChanged passes (self, w, h).
        local appliedScale;
        local function updateMargins(_, width, height)
            width, height = width or chromeFrame:GetWidth(), height or chromeFrame:GetHeight();
            width = width + THIN_CHROME_OUTSET.left + THIN_CHROME_OUTSET.right;
            height = height + THIN_CHROME_OUTSET.top + THIN_CHROME_OUTSET.bottom;

            local scale = 1;
            if (left + right > 0 and width > 0) then scale = math.min(scale, width / (left + right)); end
            if (top + bottom > 0 and height > 0) then scale = math.min(scale, height / (top + bottom)); end

            if (scale ~= appliedScale) then
                appliedScale = scale;
                art:SetTextureSliceMargins(left * scale, top * scale, right * scale, bottom * scale);
            end
        end
        chromeFrame:SetScript("OnSizeChanged", updateMargins);
        updateMargins();

        chromeFrame.Art = art;
        return chromeFrame;
    end);

    return built and chrome or nil;
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
    -- The template chrome draws its own border and background.
    if (frame.zlChrome) then return; end

    if (Theme.IsBlizzard()) then
        local edgeSize = (frame:GetHeight() < BLIZZARD_SMALL_WINDOW_HEIGHT) and 8 or 12;
        local inset = edgeSize / 4;
        frame:SetBackdrop({
            bgFile = BLIZZARD_BG_TEXTURE,
            edgeFile = BLIZZARD_EDGE_TEXTURE,
            tile = true,
            tileSize = 32,
            edgeSize = edgeSize,
            insets = { left = inset, right = inset, top = inset, bottom = inset },
        });
        frame:SetBackdropColor(unpack(Theme.blizzardColors.background));
        frame:SetBackdropBorderColor(unpack(frame.zlBorderColorOverride or Theme.blizzardColors.border));
        return;
    end

    local edgeSize = Pixel.PixelSize(frame.pixelBorderThickness or 1);
    frame:SetBackdrop({ bgFile = CHROME_TEXTURE, edgeFile = CHROME_TEXTURE, edgeSize = edgeSize });
    frame:SetBackdropColor(unpack(Theme.colors.background));
    frame:SetBackdropBorderColor(unpack(frame.zlBorderColorOverride or Theme.colors.border));
end

local function defaultBorderColor()
    return Theme.IsBlizzard() and Theme.blizzardColors.border or Theme.colors.border;
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

    -- The template chrome's art can't be tinted, so the override is a thin
    -- flat outline drawn over it instead, shown only while one is set.
    if (frame.zlChrome) then
        if (not frame.zlAlertBorder) then
            local alert = CreateFrame("Frame", nil, frame, "BackdropTemplate");
            alert:SetAllPoints(frame);
            alert:SetFrameLevel(frame:GetFrameLevel() + 20);
            alert:EnableMouse(false);
            alert:SetBackdrop({ edgeFile = CHROME_TEXTURE, edgeSize = Pixel.PixelSize(2) });
            frame.zlAlertBorder = alert;
        end
        if (color) then frame.zlAlertBorder:SetBackdropBorderColor(unpack(color)); end
        frame.zlAlertBorder:SetShown(color ~= nil and color ~= false);
        return;
    end

    frame:SetBackdropBorderColor(unpack(color or defaultBorderColor()));
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

    -- Blizzard skin: keep the template's own artwork exactly as shipped and
    -- only swap in this addon's fonts, so the Font setting still applies to
    -- button labels. Gold normal / white highlight / grey disabled, same as
    -- Blizzard's own GameFontNormal/Highlight/Disable button labels.
    if (Theme.IsBlizzard()) then
        button:SetNormalFontObject(Theme.fonts.normal);
        button:SetHighlightFontObject(Theme.fonts.highlight);
        button:SetDisabledFontObject(Theme.fonts.buttonDisabled);
        button.zlSkinned = true;
        return;
    end

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

--- Creates a push button. Default theme: UIPanelButtonTemplate (which the
--- flat skin then strips). Blizzard theme: the current retail
--- SharedButtonSmallTemplate, falling back to the classic template on clients
--- without it. Skin it afterwards with Theme.SkinButton/SkinAccentButton.
function Theme.CreateButton(parent)
    if (Theme.IsBlizzard()) then
        local ok, button = pcall(CreateFrame, "Button", nil, parent, "SharedButtonSmallTemplate");
        if (ok and button) then return button; end
    end
    return CreateFrame("Button", nil, parent, "UIPanelButtonTemplate");
end

--- Creates a ScrollFrame. Default theme: UIPanelScrollFrameTemplate (which
--- SkinScrollBar then restyles). Blizzard theme: the modern
--- ScrollFrameTemplate, falling back to the legacy one.
function Theme.CreateScrollFrame(parent)
    if (Theme.IsBlizzard()) then
        local ok, scrollFrame = pcall(CreateFrame, "ScrollFrame", nil, parent, "ScrollFrameTemplate");
        if (ok and scrollFrame) then return scrollFrame; end
    end
    return CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate");
end

--- Skin a UIPanelButtonTemplate button with Cell's flat button look.
Theme.SkinButton = deferUntilReady(function(button)
    skinButtonBackdrop(button, Theme.colors.button, Theme.colors.buttonHover);
end);

--- Skin a UIPanelButtonTemplate button with the purple (#8865FF) accent fill,
--- for a button that should stand out from the flat default button skin
--- (e.g. "Start Roll").
Theme.SkinAccentButton = deferUntilReady(function(button)
    skinButtonBackdrop(button, Theme.colors.accent, Theme.colors.accentHover);
end);

--- Skin a UIPanelCloseButton with Cell's flat, reddish close-button look,
--- using Cell's own close.tga icon (copied into this addon's Media folder).
Theme.SkinCloseButton = deferUntilReady(function(button)
    -- Blizzard skin: the stock UIPanelCloseButton art is left untouched.
    if (Theme.IsBlizzard()) then
        button.zlSkinned = true;
        return;
    end

    skinButtonBackdrop(button, Theme.colors.close, Theme.colors.closeHover);

    if (not button.zlCloseIcon) then
        local icon = button:CreateTexture(nil, "OVERLAY");
        icon:SetTexture(CLOSE_ICON_TEXTURE);
        icon:SetSize(CLOSE_ICON_SIZE, CLOSE_ICON_SIZE);
        icon:SetVertexColor(1, 1, 1, 0.9);
        button.zlCloseIcon = icon;
        positionCloseIcon(button, 0);
    end
end);

--- Give an EditBox (single or multi-line, InputBoxTemplate or template-less)
--- Cell's flat, dark input look.
Theme.SkinEditBox = deferUntilReady(function(editBox)
    if (editBox.zlSkinned) then return; end

    -- Blizzard skin: the InputBoxTemplate's own border art is left as-is, but
    -- the template's insets are zero, so text (especially right-justified
    -- numbers) would run over the border caps - pull it inside them.
    if (Theme.IsBlizzard()) then
        editBox:SetTextInsets(BLIZZARD_INPUT_TEXT_INSET, BLIZZARD_INPUT_TEXT_INSET, 0, 0);
        editBox.zlSkinned = true;
        return;
    end

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
end);

--- Cell-style flat, dark input look for a plain container frame that wraps a
--- borderless, template-less EditBox/ScrollFrame combo (e.g. the SoftRes
--- paste box, whose actual EditBox has to stay transparent so it can sit
--- inside a ScrollFrame) so the pair still reads as one input field.
Theme.SkinInputBackground = deferUntilReady(function(frame)
    if (not frame.SetBackdrop) then
        Mixin(frame, BackdropTemplateMixin);
    end

    -- Blizzard skin: the same Common-Input-Border 9-slice Blizzard's own
    -- multi-line inputs (InputScrollFrameTemplate) draw, kept inside the
    -- frame's bounds rather than overhanging them by 5px like the template.
    if (Theme.IsBlizzard()) then
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
        return;
    end

    local edgeSize = Pixel.PixelSize(1);
    frame:SetBackdrop({ bgFile = CHROME_TEXTURE, edgeFile = CHROME_TEXTURE, edgeSize = edgeSize });
    frame:SetBackdropColor(unpack(Theme.colors.input));
    frame:SetBackdropBorderColor(unpack(Theme.colors.inputBorder));
end);

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

-- Blizzard item icon border: the same UI-Quickslot2 frame Blizzard's own
-- ItemButtonTemplate draws over an item icon (64px art over a 37px button,
-- nudged 1px down), scaled proportionally to the icon's size.
local ICON_BORDER_TEXTURE = "Interface\\Buttons\\UI-Quickslot2";
local ICON_BORDER_NATIVE_ICON_SIZE = 37;
local ICON_BORDER_NATIVE_ART_SIZE = 64;
local ICON_BORDER_NATIVE_Y_OFFSET = -1;

--- Border for an item icon, drawn on `frame` (a separate wrapper frame, so it
--- renders over the icon's own texture instead of under it - `frame` must be
--- a BackdropTemplate frame created after the icon). Anchors `frame` to
--- `icon` (a texture or frame) and skins it: Blizzard theme = Blizzard's
--- standard item button border art, default = the thin flat outline pulled
--- 1px outside the icon.
function Theme.SkinIconBorder(frame, icon)
    frame:ClearAllPoints();

    if (not Theme.IsBlizzard()) then
        frame:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1);
        frame:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1);
        Theme.SkinBorder(frame);
        return;
    end

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

--- Tints a Blizzard-theme icon border (see SkinIconBorder) with the item's
--- rarity, using the same WhiteIconFrame overlay and bag quality colors as
--- Blizzard's own item buttons. Hidden when the quality is unknown/poor, and
--- a no-op outside the Blizzard theme.
function Theme.SetIconBorderQuality(frame, quality)
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

-- Blizzard status bar border: the same three-piece art (bordered left/right
-- caps plus a stretched middle) Blizzard's own objective-tracker progress bars
-- draw over a 15px-tall StatusBar. That art is 22px tall with 3px cap
-- overhang; here it's scaled down proportionally to a slimmer bar so the
-- border doesn't dominate the window (it stays a few pixels outside the bar).
local BAR_BORDER_TEXTURE = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-BarBorder";
local BAR_BORDER_NATIVE_BAR_HEIGHT = 15;
local BAR_BORDER_NATIVE_HEIGHT = 22;
local BAR_BORDER_NATIVE_CAP_WIDTH = 9;
local BAR_BORDER_NATIVE_CAP_OVERHANG = 3;

--- Height a StatusBar should have in the Blizzard theme (the border art is
--- scaled to match; the default skin's thin 1px-outlined bars keep their own).
Theme.BLIZZARD_BAR_HEIGHT = 8;

--- Border for a StatusBar, drawn on `frame` (a separate wrapper frame, so it
--- renders over the bar's own fill instead of under it - `frame` must be a
--- BackdropTemplate frame created after `bar`). Anchors `frame` to `bar` and
--- skins it: Blizzard theme = Blizzard's bar border art, default = the thin
--- flat outline pulled 1px outside the bar.
function Theme.SkinBarBorder(frame, bar)
    frame:ClearAllPoints();

    if (not Theme.IsBlizzard()) then
        frame:SetPoint("TOPLEFT", bar, "TOPLEFT", -1, 1);
        frame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 1, -1);
        Theme.SkinBorder(frame);
        return;
    end

    frame:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0);
    frame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0);
    -- Explicitly above the bar: a sibling created later isn't guaranteed to
    -- draw over it, and the bar's fill would otherwise cover the art.
    frame:SetFrameStrata(bar:GetFrameStrata());
    frame:SetFrameLevel(bar:GetFrameLevel() + 2);
    if (frame.zlBarBorderLeft) then return; end

    local scale = Theme.BLIZZARD_BAR_HEIGHT / BAR_BORDER_NATIVE_BAR_HEIGHT;
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

-- The default skin's flat, arrowless scrollbar look (see SkinScrollBar).
local function skinScrollBarFlat(bar)
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
Theme.SkinScrollBar = deferUntilReady(function(scrollFrame)
    pcall(function()
        local bar = scrollFrame.ScrollBar;
        if (not bar) then return; end

        -- Blizzard skin keeps the stock scrollbar art (arrows, stone thumb);
        -- the auto-hide below applies to both skins.
        if (not Theme.IsBlizzard()) then
            skinScrollBarFlat(bar);
        end

        -- Hide the whole bar (thumb, track, border) whenever there's
        -- nothing to scroll, instead of always showing a full-length thumb
        -- that doesn't move - or whenever a caller has force-hidden it via
        -- Theme.SetScrollBarHidden (e.g. a window shrunk down near its
        -- resize minimum, where the sliver of visible list isn't worth a
        -- scrollbar even though there's technically still range to scroll).
        local function updateVisibility()
            local range = scrollFrame:GetVerticalScrollRange();
            if (not bar.zlForceHidden and range and range > 0) then
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
end);

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

    -- Tiny windows (the Group Loot header) can't fit the template chrome's
    -- corners, so they keep the plain tooltip-art backdrop. The thin chrome
    -- scales its own corners down, so it is used for every window.
    if (Theme.IsBlizzardThin()) then
        frame.zlChrome = createThinChrome(frame);
    elseif (Theme.IsBlizzard() and height >= BLIZZARD_SMALL_WINDOW_HEIGHT) then
        frame.zlChrome = createChrome(frame);
    end

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

-- ---------------------------------------------------------------------------
-- RESIZE HANDLE STYLES - edit these to restyle the bottom-edge drag handle
-- (Theme.MakeBottomResizable, used by the roll window and trade queue
-- window) separately for each theme. Keys match Theme.THEMES.
--
--   color           { r, g, b, a } of the line drawn on the window's bottom edge.
--   restPx          line thickness, in physical pixels, when idle. 0 = hidden.
--   hoverPx         line thickness while the cursor is over the handle.
--   dragPx          line thickness while actively dragging.
--   hitHeight       height (in UI units) of the invisible grab strip; it is
--                   centered on the bottom edge, so half of it sits inside
--                   the window's bottom margin.
--   widthOffset     the line always spans the full window width; this grows
--                   (positive) or shrinks (negative) it by that many UI
--                   units in total, split evenly between the two sides
--                   (e.g. -8 pulls each end in by 4).
--   hitWidthOffset  same, for the invisible grab strip.
--   offsetX         horizontal nudge of the line (positive = right).
--   hitOffsetX      same, for the invisible grab strip.
--   offsetY         vertical nudge of the line (positive = up, into the window).
--   setup(line, frame)
--              optional hook run once per window, right after the line
--              texture is created - use it for anything the fields above
--              can't express (an atlas, a gradient, a second texture...).
--              The line's color/height are still driven by the fields
--              above afterwards; set `color = nil` to keep whatever setup
--              applied (e.g. line:SetAtlas(...)).
-- ---------------------------------------------------------------------------
Theme.resizeHandleStyles = {
    default = {
        color = Theme.colors.accent,
        restPx = 0,
        hoverPx = 2,
        dragPx = 3,
        hitHeight = 8,
        widthOffset = 0,
        hitWidthOffset = 0,
        offsetX = 0,
        hitOffsetX = 0,
        offsetY = 0,
    },
    blizzard = {
        color = Theme.colors.accent,
        restPx = 0,
        hoverPx = 2,
        dragPx = 3,
        hitHeight = 8,
        widthOffset = 0,
        hitWidthOffset = 0,
        offsetX = 0,
        hitOffsetX = 0,
        offsetY = 0,
    },
    blizzardthin = {
        color = Theme.colors.accent,
        restPx = 0,
        hoverPx = 2,
        dragPx = 3,
        hitHeight = 8,
        widthOffset = -9,
        hitWidthOffset = -9,
        offsetX = -0.5,
        hitOffsetX = -2,
        offsetY = -2,
    },
};

-- Bottom-edge drag-to-resize (height only, width and the top edge stay
-- fixed) for a Theme.CreateWindow frame: a thin invisible hit region
-- spanning the window's bottom margin, plus a line on the edge itself
-- whose look is set per theme by Theme.resizeHandleStyles above.
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
    local style = Theme.resizeHandleStyles[Theme.current] or Theme.resizeHandleStyles[Theme.DEFAULT_THEME];

    -- Taller than the visible border line so the edge is easy to grab, but
    -- kept inside the window's own bottom margin (below whatever sits above
    -- it) rather than sticking out past the frame.
    local HIT_HEIGHT = style.hitHeight;

    frame:SetResizable(true);
    frame:SetResizeBounds(width, minHeight, width, maxHeight);

    local resizeHandle = CreateFrame("Button", nil, frame);
    local hitHalf = (style.hitWidthOffset or 0) / 2;
    local hitX = style.hitOffsetX or 0;
    resizeHandle:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", hitX - hitHalf, -HIT_HEIGHT / 2);
    resizeHandle:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", hitX + hitHalf, -HIT_HEIGHT / 2);
    resizeHandle:SetHeight(HIT_HEIGHT);

    local resizeLine = frame:CreateTexture(nil, "OVERLAY");
    local lineHalf = (style.widthOffset or 0) / 2;
    local lineX, lineY = style.offsetX or 0, style.offsetY or 0;
    resizeLine:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", lineX - lineHalf, lineY);
    resizeLine:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", lineX + lineHalf, lineY);
    if (style.color) then resizeLine:SetColorTexture(unpack(style.color)); end
    if (style.setup) then style.setup(resizeLine, frame); end
    resizeLine:Hide();

    local isResizing, isHovering = false, false;
    local function updateResizeLine()
        local thicknessPx = isResizing and style.dragPx or isHovering and style.hoverPx or style.restPx;
        if (thicknessPx > 0) then
            resizeLine:SetHeight(Pixel.PixelSize(1) * thicknessPx);
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
