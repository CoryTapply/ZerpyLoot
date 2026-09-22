--[[
Named font objects every ForeverLoot FontString uses, plus the SharedMedia
font-face and statusbar-texture swapping. Skins don't touch this file: the
only per-skin input is the title color (colors.title, falling back to
colors.accent), applied by Theme.ApplyFontColors at Theme.Init.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local LSM = LibStub("LibSharedMedia-3.0");

-- Named font objects every ForeverLoot FontString uses (instead of Blizzard's
-- global GameFontXxx objects directly - overriding those would also reskin
-- the rest of the game's UI). Every size, color, outline and shadow value
-- below is a hardcoded literal rather than copied off a Blizzard font
-- object (or, for the input font, the player's own chat-font setting) at
-- load time, so none of this can silently drift if Blizzard changes a
-- default font or the player changes an unrelated client setting. Only the
-- font FACE gets swapped later, by Theme.ApplyFont.
Theme.fonts = {
    normal = "ForeverLootFontNormal",
    normalMedium = "ForeverLootFontNormalMedium",
    normalLarge = "ForeverLootFontNormalLarge",
    normalSmall = "ForeverLootFontNormalSmall",
    highlight = "ForeverLootFontHighlight",
    highlightMedium = "ForeverLootFontHighlightMedium",
    highlightSmall = "ForeverLootFontHighlightSmall",
    disableSmall = "ForeverLootFontDisableSmall",

    -- Window/panel titles (skin accent color) and button labels (white) - see
    -- DefineFont calls below for why these get their own dedicated colors.
    title = "ForeverLootFontTitle",
    titleLarge = "ForeverLootFontTitleLarge",
    button = "ForeverLootFontButton",
    buttonDisabled = "ForeverLootFontButtonDisabled",
    input = "ForeverLootFontInput",
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

-- Window/panel titles. The color here is only a placeholder: no skin is
-- registered yet when this file loads, so Theme.ApplyFontColors sets the real
-- one (the skin's colors.title, or its accent) at Theme.Init.
DefineFont(Theme.fonts.title, 12, COLOR_GOLD);
DefineFont(Theme.fonts.titleLarge, 16, COLOR_GOLD);

-- Button labels: plain white, applied to every flat-skinned button instead of
-- whatever font object the button's template shipped with.
DefineFont(Theme.fonts.button, 12, COLOR_WHITE);
DefineFont(Theme.fonts.buttonDisabled, 12, COLOR_GREY);

-- SoftRes paste box text - fixed 14pt regardless of the player's own chat
-- font size (this used to inherit ChatFontNormal, which tracks that
-- setting).
DefineFont(Theme.fonts.input, 14, COLOR_WHITE);

-- Titles follow the active skin (purple accent by default, Blizzard gold in
-- the Blizzard skins); every FontString using these named fonts follows
-- automatically since they're font objects.
function Theme.ApplyFontColors()
    local color = Theme.colors.title or Theme.colors.accent;
    _G[Theme.fonts.title]:SetTextColor(unpack(color));
    _G[Theme.fonts.titleLarge]:SetTextColor(unpack(color));
end

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
