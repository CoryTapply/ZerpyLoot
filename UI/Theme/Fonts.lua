--[[
Named font objects every ForeverLoot FontString uses, plus the SharedMedia
font-face and statusbar-texture swapping.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Sizes = FL.UI.Sizes.fonts;
local LSM = LibStub("LibSharedMedia-3.0");

-- Bundled font (Media/Fonts/Expressway.ttf), registered with SharedMedia so
-- it shows up in the Appearance settings font dropdown like any other LSM
-- font. This is ForeverLoot's own default (Settings.Init and the Appearance
-- dropdown's "default" both point at this key) - it's NOT registered as the
-- global LSM default, which would silently change the default font for
-- every other addon sharing this LibSharedMedia instance.
Theme.DEFAULT_FONT_KEY = "Expressway";
LSM:Register(LSM.MediaType.FONT, Theme.DEFAULT_FONT_KEY, "Interface\\AddOns\\ForeverLoot\\Media\\Fonts\\Expressway.ttf");

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
    highlightLarge = "ForeverLootFontHighlightLarge",
    highlightMedium = "ForeverLootFontHighlightMedium",
    highlightSmall = "ForeverLootFontHighlightSmall",
    disableSmall = "ForeverLootFontDisableSmall",

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

DefineFont(Theme.fonts.normal, Sizes.normal, COLOR_GOLD);
-- Same size/color/shadow recipe as normalLarge, just dialed down - used
-- where normalLarge reads slightly too big (the roll-off item link).
DefineFont(Theme.fonts.normalMedium, Sizes.normalMedium, COLOR_GOLD);
DefineFont(Theme.fonts.normalLarge, Sizes.normalLarge, COLOR_GOLD);
DefineFont(Theme.fonts.normalSmall, Sizes.normalSmall, COLOR_GOLD);
DefineFont(Theme.fonts.highlight, Sizes.highlight, COLOR_WHITE);
-- Same recipe as highlight, just dialed up - used where highlight reads too
-- small (the loot council response window's item names).
DefineFont(Theme.fonts.highlightLarge, Sizes.highlightLarge, COLOR_WHITE);
-- Same recipe as highlightSmall, just dialed up - used where highlightSmall
-- reads too small (the SoftRes preview's player names).
DefineFont(Theme.fonts.highlightMedium, Sizes.highlightMedium, COLOR_WHITE);
DefineFont(Theme.fonts.highlightSmall, Sizes.highlightSmall, COLOR_WHITE);
DefineFont(Theme.fonts.disableSmall, Sizes.disableSmall, COLOR_GREY);

-- Button labels: plain white, applied to every flat-skinned button instead of
-- whatever font object the button's template shipped with.
DefineFont(Theme.fonts.button, Sizes.button, COLOR_WHITE);
DefineFont(Theme.fonts.buttonDisabled, Sizes.buttonDisabled, COLOR_GREY);

-- SoftRes paste box text - fixed size regardless of the player's own chat
-- font size (this used to inherit ChatFontNormal, which tracks that
-- setting).
DefineFont(Theme.fonts.input, Sizes.input, COLOR_WHITE);

-- FontStrings styled via FL.UI.SetFont below don't inherit a shared font
-- object (unlike everything using a Theme.fonts.* name), so Theme.ApplyFont
-- can't reach them through the loop below - each one registers itself here
-- instead, remembering its own size role so a later font-face change can
-- re-apply "this face, at this widget's own role size".
local roleFontStrings = {};

-- The SharedMedia key last passed to Theme.ApplyFont (set at login by
-- Settings.Init, and again whenever the user changes it on the Appearance
-- page) - kept so FL.UI.SetFont can resolve the addon's own saved font
-- instead of falling back to LSM's global default, which most players never
-- touch and won't match ForeverLoot's selection.
Theme.currentFontKey = nil;

local function GetCurrentFontPath()
    return (Theme.currentFontKey and LSM:Fetch("font", Theme.currentFontKey)) or LSM:Fetch("font") or "Fonts\\FRIZQT__.TTF";
end

--- Sizes `fontString` off FL.UI.Sizes.fonts[sizeKey] (see UI/Sizes.lua),
--- using the currently-selected SharedMedia font face and the same
--- outline/shadow every Theme.fonts object gets. Used by UI/SettingsWindow/*
--- instead of a dedicated Theme.fonts object per size - color is left to the
--- caller (SetTextColor), exactly like every other FontString in this addon.
function FL.UI.SetFont(fontString, sizeKey)
    local size = Sizes[sizeKey];
    assert(size, "UI.SetFont: unknown size key '" .. tostring(sizeKey) .. "'");

    local path = GetCurrentFontPath();
    fontString:SetFont(path, size, FONT_OUTLINE);
    fontString:SetShadowOffset(FONT_SHADOW_OFFSET_X, FONT_SHADOW_OFFSET_Y);
    fontString:SetShadowColor(unpack(FONT_SHADOW_COLOR));

    fontString.zlSizeKey = sizeKey;
    roleFontStrings[fontString] = true;
end

-- Swaps the font FACE (via SharedMedia) on every mirrored font object,
-- keeping each one's own size/color/shadow untouched.
function Theme.ApplyFont(key)
    local path = (key and LSM:Fetch("font", key)) or LSM:Fetch("font");
    if (not path) then return; end

    Theme.currentFontKey = key;

    for _, fontObjectName in pairs(Theme.fonts) do
        local fontObject = _G[fontObjectName];
        local _, size, flags = fontObject:GetFont();
        fontObject:SetFont(path, size, flags);
    end

    for fontString in pairs(roleFontStrings) do
        fontString:SetFont(path, Sizes[fontString.zlSizeKey], FONT_OUTLINE);
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
