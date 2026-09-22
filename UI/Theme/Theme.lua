--[[
Theme core: the skin registry and the public Theme.* API every window uses.

A "skin" is one file under UI/Theme/Skins/ that calls Theme.RegisterSkin(key,
def). This file never contains skin-specific art or colors - each Theme.Skin*
/ Theme.Create* function below only forwards to the active skin, which is
chosen once at login (Theme.Init). See UI/Theme/Skins/README.md for the full
skin contract and how to add one.

Inheritance: a skin's `base` (default: "default") supplies every method and
every colors/metrics/resizeHandle value the skin doesn't define itself, so a
skin only lists what it changes. A skin can never affect another skin except
by being that skin's base.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;

Theme.Helpers = Theme.Helpers or {};

-- key -> display name, and the order the options dropdown lists them in.
-- Both are filled by RegisterSkin (registration order = TOC load order).
Theme.THEMES = {};
Theme.THEME_ORDER = {};
Theme.DEFAULT_THEME = "default";

Theme.current = nil; -- key of the active skin, set once by Theme.Init, at login
Theme.skin = nil;    -- the active skin table (see activeSkin for the pre-Init fallback)

local skins = {};

local function activeSkin()
    return Theme.skin or skins[Theme.DEFAULT_THEME];
end

--- The active skin table (the Default skin until Theme.Init has run).
function Theme.GetSkin()
    return activeSkin();
end

-- Skins read their palette and layout numbers through these instead of their
-- own tables, so a derived skin that only overrides e.g. colors.accent
-- recolors every inherited method automatically. Before Theme.Init they
-- resolve against the Default skin.
local function activeProxy(field)
    return setmetatable({}, {
        __index = function(_, key)
            local skin = activeSkin();
            return skin and skin[field][key];
        end,
    });
end

Theme.colors = activeProxy("colors");
Theme.metrics = activeProxy("metrics");

local function chainTable(tbl, baseTbl)
    tbl = tbl or {};
    if (baseTbl) then setmetatable(tbl, { __index = baseTbl }); end
    return tbl;
end

--- Registers a skin. `def.base` names an already-registered skin to inherit
--- from (defaults to "default"; the default skin itself has no base).
function Theme.RegisterSkin(key, def)
    assert(type(key) == "string" and type(def) == "table", "Theme.RegisterSkin(key, def)");
    assert(not skins[key], "Theme skin '" .. key .. "' is already registered");

    local baseKey = def.base or (key ~= Theme.DEFAULT_THEME and Theme.DEFAULT_THEME or nil);
    local base = baseKey and skins[baseKey];
    assert(not baseKey or base, ("Theme skin '%s' extends '%s', which is not registered (load its file first)"):format(key, tostring(baseKey)));

    def.key = key;
    def.name = def.name or key;
    def.colors = chainTable(def.colors, base and base.colors);
    def.metrics = chainTable(def.metrics, base and base.metrics);
    def.resizeHandle = chainTable(def.resizeHandle, base and base.resizeHandle);
    if (base) then setmetatable(def, { __index = base }); end

    skins[key] = def;
    Theme.THEMES[key] = def.name;
    table.insert(Theme.THEME_ORDER, key);
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

--- Locks in this session's theme (see Settings.Init) and replays any skin
--- calls that were queued waiting for it.
function Theme.Init(key)
    Theme.current = Theme.THEMES[key] and key or Theme.DEFAULT_THEME;
    Theme.skin = skins[Theme.current];
    Theme.ApplyFontColors();

    local queued = pendingSkins;
    pendingSkins = {};
    for _, skinFn in ipairs(queued) do skinFn(); end
end

-- ---------------------------------------------------------------------------
-- Public API: thin dispatchers onto the active skin.
-- ---------------------------------------------------------------------------

--- Creates a push button (template depends on the skin). Skin it afterwards
--- with Theme.SkinButton/SkinAccentButton.
function Theme.CreateButton(parent)
    return activeSkin().CreateButton(parent);
end

--- Creates a ScrollFrame (template depends on the skin). Style its scrollbar
--- afterwards with Theme.SkinScrollBar.
function Theme.CreateScrollFrame(parent)
    return activeSkin().CreateScrollFrame(parent);
end

--- Skin a button created by Theme.CreateButton.
Theme.SkinButton = deferUntilReady(function(button)
    activeSkin().SkinButton(button, "normal");
end);

--- Skin a button with the accent fill, for one that should stand out from the
--- normal button look (e.g. "Start Roll").
Theme.SkinAccentButton = deferUntilReady(function(button)
    activeSkin().SkinButton(button, "accent");
end);

--- Skin a UIPanelCloseButton.
Theme.SkinCloseButton = deferUntilReady(function(button)
    activeSkin().SkinButton(button, "close");
end);

--- Give an EditBox (single or multi-line, InputBoxTemplate or template-less)
--- the skin's input look.
Theme.SkinEditBox = deferUntilReady(function(editBox)
    activeSkin().SkinEditBox(editBox);
end);

--- Input look for a plain container frame that wraps a borderless,
--- template-less EditBox/ScrollFrame combo (e.g. the SoftRes paste box) so the
--- pair still reads as one input field.
Theme.SkinInputBackground = deferUntilReady(function(frame)
    activeSkin().SkinInputBackground(frame);
end);

--- Draw just a border (no fill) around an arbitrary frame - e.g. a thin
--- wrapper frame anchored a pixel outside a StatusBar. Anchoring/sizing that
--- wrapper is left to the caller; this only paints it.
function Theme.SkinBorder(frame)
    activeSkin().SkinBorder(frame);
end

--- Border for an item icon, drawn on `frame` (a separate BackdropTemplate
--- wrapper frame created after the icon, so it renders over it). Anchors
--- `frame` to `icon` (a texture or frame) and skins it.
function Theme.SkinIconBorder(frame, icon)
    activeSkin().SkinIconBorder(frame, icon);
end

--- Tints an icon border (see SkinIconBorder) with the item's rarity, for
--- skins whose border art supports it; a no-op otherwise.
function Theme.SetIconBorderQuality(frame, quality)
    activeSkin().SetIconBorderQuality(frame, quality);
end

--- Border for a StatusBar, drawn on `frame` (a separate BackdropTemplate
--- wrapper frame created after `bar`). Anchors `frame` to `bar` and skins it.
function Theme.SkinBarBorder(frame, bar)
    activeSkin().SkinBarBorder(frame, bar);
end

--- Restyle a ScrollFrame's scrollbar with the skin's look and auto-hide it
--- whenever there's nothing to scroll. Defensive throughout (the whole thing
--- is pcall-wrapped) because the scrollbar's exact sub-widgets come from a
--- Blizzard template this client build may structure slightly differently, and
--- a wrong guess here should degrade to "still has the default scrollbar"
--- rather than a hard Lua error.
Theme.SkinScrollBar = deferUntilReady(function(scrollFrame)
    pcall(function()
        local bar = scrollFrame.ScrollBar;
        if (not bar) then return; end

        activeSkin().StyleScrollBar(bar);

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
