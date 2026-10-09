--[[
Pixel-perfect scale helpers. WoW lays the UI out on a virtual screen 768
units tall at effective scale 1, stretched over the monitor's real height -
so a frame's size/position (in its own units) maps to physical screen
pixels as:

    physicalPixels = unitSize * frame:GetEffectiveScale() * physicalHeight / 768

Both the effective scale (UIScale * any window :SetScale()) and the
physical height are read live (GetPhysicalScreenSize, via Blizzard's own
PixelUtil), so borders and window edges land on the real pixel grid on any
monitor, resolution, UIScale or Window Scale without hardcoding any of them.
]]

local FL = ForeverLoot;
local Pixel = FL.Pixel;

local EPSILON = 1e-4;
local windows = {};

-- region -> { [key] = applyFn }: everything sized/anchored from a pixel
-- count (backdrop edges, 1px dividers, border insets) rather than a plain
-- UI-unit value. Re-run by refreshTracked() whenever the pixel grid changes
-- (UIScale, resolution, Window Scale), so those stay whole pixels without a
-- /reload. Every tracked region is a pooled/reused frame or texture (WoW
-- never frees those anyway), so this only grows with the UI actually built.
local tracked = {};

local function refreshTracked()
    for _, fns in pairs(tracked) do
        for _, fn in pairs(fns) do fn(); end
    end
end

--- Runs `applyFn` now and again on every pixel-grid change. `key` lets a
--- region carry several independent tracked values (e.g. two anchor
--- points); re-tracking the same region+key replaces the previous fn.
function Pixel.Track(region, key, applyFn)
    local fns = tracked[region];
    if (not fns) then
        fns = {};
        tracked[region] = fns;
    end
    fns[key] = applyFn;
    applyFn();
end

-- SetPoint's (and AdjustPointsOffset's) numeric offsets are measured in the
-- CALLING frame's own effective scale, not the frame it's anchored to - so
-- the same offset value resolves to a different physical distance depending
-- on that frame's own :SetScale(). Every other position value in this file
-- (layout.x/y, and whatever Pixel.Snap/ApplyLayout compute) is worked out in
-- plain UIParent-local units instead (as if the frame's own scale were
-- always 1), so it has to be converted through the frame's own scale right
-- before it's handed to SetPoint/AdjustPointsOffset, or the anchor lands in
-- the wrong place for any window whose scale isn't 1.
local function ToSelfOffset(frame, value)
    return value / frame:GetScale();
end

-- Window Scale (UI/SettingsWindow/Pages/Appearance.lua's slider) applies a
-- plain frame:SetScale() on top of UIParent's scale. Pixel.Unit() stays in
-- UIParent units (layout.x/y and window positions live there); the window's
-- own size is snapped in its self-scaled units (see selfUnit below), and
-- Pixel.PixelSize(px, region) reads the region's full effective scale, so
-- borders stay whole pixels at any Window Scale too.
local currentScale = 1.0;

function Pixel.GetGlobalScale()
    return currentScale;
end

--- Applies `scale` to every registered window immediately, and remembers it
--- so a window registered later (opened for the first time after the slider
--- moved) still picks it up - see Pixel.RegisterWindow below.
---
--- Re-runs Pixel.ApplyLayout (which factors currentScale into its position
--- math - see below) instead of just calling frame:SetScale(), so each
--- window's layout.x/y center stays fixed on screen across a scale change
--- rather than drifting toward its bottom-right corner. Works even for a
--- currently-hidden window, since it's driven entirely by the stored layout
--- table rather than the frame's live (unshown) on-screen position.
function Pixel.SetGlobalScale(scale)
    currentScale = scale;
    for frame, entry in pairs(windows) do
        frame:SetScale(scale);
        Pixel.ApplyLayout(frame, entry.layout);
        if (entry.onRescale) then entry.onRescale(); end
    end
    refreshTracked();
end

-- Size, in UIParent units, of exactly one physical screen pixel.
-- PixelUtil.GetPixelToUIUnitFactor() is 768 / physical screen height - the
-- size of one physical pixel at effective scale 1.
function Pixel.Unit()
    return PixelUtil.GetPixelToUIUnitFactor() / UIParent:GetEffectiveScale();
end

-- Size of one physical pixel in `frame`'s own (self-scaled) units.
local function selfUnit(frame)
    return Pixel.Unit() / frame:GetScale();
end

-- Rounds a desired UI-unit size to the nearest size that lands exactly on the
-- physical pixel grid, via Blizzard's own PixelUtil helper (used for e.g.
-- backdrop edgeSize). Pass the `region` being sized so its full effective
-- scale (including any Window Scale) is used; without one, UIParent's scale
-- is assumed. Never rounds a nonzero size down to 0 pixels.
function Pixel.PixelSize(desiredPixels, region)
    local scale = region and region:GetEffectiveScale() or UIParent:GetEffectiveScale();
    return PixelUtil.GetNearestPixelSize(desiredPixels, scale, desiredPixels ~= 0 and 1 or nil);
end

--- Sets `texture`'s height (a horizontal divider/rule) to `px` pixel-sized
--- units, kept whole-pixel across UIScale/resolution/Window Scale changes.
function Pixel.SetLineHeight(texture, px)
    Pixel.Track(texture, "height", function() texture:SetHeight(Pixel.PixelSize(px, texture)); end);
end

--- Same as Pixel.SetLineHeight, for a vertical divider's width.
function Pixel.SetLineWidth(texture, px)
    Pixel.Track(texture, "width", function() texture:SetWidth(Pixel.PixelSize(px, texture)); end);
end

--- SetPoint whose offsets are a whole number of window-border widths
--- (Pixel.PixelSize(1)) plus a plain UI-unit extra - e.g. a panel inset
--- exactly the border's thickness from its window's edge so its fill never
--- paints over (or leaves a sliver beside) that border. Re-applied on every
--- pixel-grid change, like the border itself.
function Pixel.SetBorderInsetPoint(region, point, relativeTo, relativePoint, xBorders, yBorders, xExtra, yExtra)
    Pixel.Track(region, "point:" .. point, function()
        local border = Pixel.PixelSize(1, region);
        region:SetPoint(point, relativeTo, relativePoint, xBorders * border + (xExtra or 0), yBorders * border + (yExtra or 0));
    end);
end

-- Rounds to the nearest multiple of one physical pixel.
function Pixel.Snap(value)
    local px = Pixel.Unit();
    return math.floor((value / px) + 0.5) * px;
end

-- Rounds UP to the nearest multiple of one physical pixel, so a requested
-- size never shrinks below what was asked for. `unit` defaults to
-- Pixel.Unit() (UIParent units).
function Pixel.SnapUp(value, unit)
    local px = unit or Pixel.Unit();
    return math.ceil((value / px) - EPSILON) * px;
end

-- Pixel.Snap/SnapUp only guarantee the *requested* position is a multiple of
-- one physical pixel - they can't see what WoW's own anchor-resolution pass
-- actually produces on screen (float rounding inside the engine's own
-- coordinate pipeline). So after anchoring, re-measure the frame's *actual*
-- on-screen edges and nudge away any leftover drift.
--
-- gridBias (in pixels, default 0) parks windows that far past a pixel
-- boundary instead of exactly on it. Only changed by the `/fl pixel bias`
-- diagnostic, while investigating 1px borders vanishing at some scales.
local gridBias = 0;

function Pixel.CorrectDrift(frame)
    -- GetLeft()/GetTop() are in this frame's own self-scaled coordinate
    -- space (see ToSelfOffset above) - convert to true UIParent-local units
    -- before working out the physical-pixel drift.
    local selfLeft, selfTop = frame:GetLeft(), frame:GetTop();
    if (not selfLeft or not selfTop) then return; end

    local frameScale = frame:GetScale();
    local left, top = selfLeft * frameScale, selfTop * frameScale;

    local px = Pixel.Unit();
    local screenHeight = UIParent:GetHeight();

    local leftPixels = left / px;
    local topPixels = (screenHeight - top) / px;

    local driftLeft = leftPixels - (math.floor(leftPixels - gridBias + 0.5) + gridBias);
    local driftTop = topPixels - (math.floor(topPixels - gridBias + 0.5) + gridBias);

    if (math.abs(driftLeft) < EPSILON and math.abs(driftTop) < EPSILON) then return; end

    frame:AdjustPointsOffset(ToSelfOffset(frame, -driftLeft * px), ToSelfOffset(frame, driftTop * px));
end

-- Applies a window's logical (unsnapped) layout - { width, height, x, y },
-- with x/y following the SetPoint("CENTER", x, y) convention - by snapping
-- its size and position onto the pixel grid and anchoring it TOPLEFT (so
-- only width/height need snapping for every edge to land on the grid).
--
-- A frame's SetScale grows/shrinks it away from its TOPLEFT anchor rather
-- than around its center (the anchor offset itself, in UIParent-local units,
-- doesn't move - only how far the opposite corners render from it does). So
-- the TOPLEFT anchor has to be solved backward from the *desired center*
-- (screen-center + layout.x/y) through currentScale, not just through the
-- window's raw unscaled width/height - otherwise the window's rendered
-- center silently drifts off layout.x/y at any scale other than 1.0.
function Pixel.ApplyLayout(frame, layout)
    -- Snapped in the frame's own self-scaled units, so the size it actually
    -- renders at (width * its scale) is a whole number of pixels at any
    -- Window Scale, not just 1.0.
    local width = Pixel.SnapUp(layout.width, selfUnit(frame));
    local height = Pixel.SnapUp(layout.height, selfUnit(frame));

    local screenWidth, screenHeight = UIParent:GetWidth(), UIParent:GetHeight();
    local centerX = screenWidth / 2 + (layout.x or 0);
    local centerY = screenHeight / 2 + (layout.y or 0);

    local left = Pixel.Snap(centerX - width * currentScale / 2);
    local top = Pixel.Snap(centerY + height * currentScale / 2 - screenHeight);

    frame:SetSize(width, height);
    frame:ClearAllPoints();
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", ToSelfOffset(frame, left), ToSelfOffset(frame, top));
    Pixel.CorrectDrift(frame);
end

-- Every ForeverLoot window is a direct UIParent child sharing the same
-- SetFrameStrata, so without this, two overlapping windows tie for frame
-- level and their children interleave/poke through each other. SetToplevel
-- makes the engine auto-raise `frame` (cascading to descendants, so their
-- own relative SetFrameLevel offsets stay intact) above its same-strata
-- siblings whenever it or a mouse-enabled descendant is clicked/dragged.
-- SetToplevel only reacts to mouse input, not a programmatic Show(), so the
-- OnShow hook covers opening/reopening a window bringing it to front too -
-- and guarantees any two open windows land on distinct levels the moment
-- each was last shown, fixing the at-rest tie as well as the click case.
-- EnableMouse on the window itself makes its whole rect opaque to clicks:
-- without it, padding/labels/backgrounds pass clicks straight through to
-- whatever window (or the 3D world) is underneath, and since nothing
-- mouse-enabled in this window was hit, SetToplevel doesn't raise it either.
--
-- What Raise() does NOT fix: it changes which window DRAWS in front, but
-- not the frame levels the engine uses to pick what the mouse is over
-- (measured in game: Start Session drawn over History still reported level
-- 1 vs History's 10). So a covered window's icons keep winning the hover
-- and pop their tooltips through the window in front, and GetFrameLevel()
-- can't tell us which window is really in front either.
--
-- So ForeverLoot tracks the front-to-back order itself (`zOrder`, last =
-- front): a window moves to the front when shown, or when clicked at a
-- spot no window in front of it covers. The GameTooltip OnShow hook below
-- then hides any tooltip whose owner sits in a window that a window in
-- front of it covers at the cursor.
local toplevels = {};
local zOrder = {};

local function MoveToFront(frame)
    for i, f in ipairs(zOrder) do
        if (f == frame) then table.remove(zOrder, i); break; end
    end
    table.insert(zOrder, frame);
end

function Pixel.BringToFront(frame)
    MoveToFront(frame);
    frame:Raise();
end

local function OwningWindow(frame)
    while (frame) do
        if (toplevels[frame]) then return frame; end
        frame = frame.GetParent and frame:GetParent();
    end
end

-- The front-most visible window under the cursor, by zOrder.
local function FrontWindowAtCursor()
    for i = #zOrder, 1, -1 do
        local frame = zOrder[i];
        if (frame:IsVisible() and frame:IsMouseOver()) then return frame; end
    end
end

GameTooltip:HookScript("OnShow", function(tooltip)
    local window = OwningWindow(tooltip:GetOwner());
    if (window) then
        local front = FrontWindowAtCursor();
        if (front and front ~= window) then
            tooltip:Hide();
        end
    end
end);

-- Clicking a window brings it to the front - but only the window that is
-- visibly front-most at the cursor, never one whose buried icon happened to
-- win the engine's hit-test. Uses IsMouseOver rather than the mouse focus
-- for exactly that reason.
local clickWatcher = CreateFrame("Frame");
clickWatcher:RegisterEvent("GLOBAL_MOUSE_DOWN");
clickWatcher:SetScript("OnEvent", function()
    local front = FrontWindowAtCursor();
    if (front and zOrder[#zOrder] ~= front) then
        Pixel.BringToFront(front);
    end
end);

function Pixel.MakeToplevelWindow(frame)
    toplevels[frame] = true;
    frame:EnableMouse(true);
    frame:SetToplevel(true);
    frame:HookScript("OnShow", function() Pixel.BringToFront(frame); end);
    if (frame:IsShown()) then MoveToFront(frame); end
end

-- Tracks a frame so its layout is re-snapped whenever the pixel grid changes
-- (UIScale edited, or the game window moved to a different-resolution
-- monitor). `onRescale` is an optional callback for anything else that
-- depends on Pixel.Unit() (e.g. border thickness) and needs to be redrawn.
--
-- The create-time x/y are also kept separately as defaultX/defaultY (never
-- mutated by a later drag - see SnapPosition) so Pixel.ResetPosition can
-- restore exactly the position the window was created with, even for a
-- window whose default isn't dead-center (e.g. the trade queue window's
-- x=200).
function Pixel.RegisterWindow(frame, layout, onRescale)
    windows[frame] = { layout = layout, onRescale = onRescale, defaultX = layout.x or 0, defaultY = layout.y or 0 };
    frame:SetScale(currentScale);
    Pixel.ApplyLayout(frame, layout);
    if (onRescale) then onRescale(); end
    -- Anything this window's children tracked before the SetScale above was
    -- sized at scale 1 - re-size it for the scale the window now renders at.
    refreshTracked();
    Pixel.MakeToplevelWindow(frame);
end

-- Snaps a registered window to a new height in place, leaving its current
-- top-left position untouched - unlike Pixel.ApplyLayout, which always
-- re-centers the frame from its original creation-time x/y. Used after an
-- interactive bottom-edge resize (see RollWindow.lua), where the top edge
-- must stay exactly where it was. Also updates the registered layout's
-- height so a later UI_SCALE_CHANGED rescale keeps the resized height
-- instead of reverting to the size the window was created with. Returns
-- the actual (pixel-snapped) height applied.
function Pixel.SetHeight(frame, height)
    local entry = windows[frame];
    local snapped = Pixel.SnapUp(height, selfUnit(frame));
    if (entry) then
        entry.layout.height = snapped;
    end

    frame:SetHeight(snapped);
    Pixel.CorrectDrift(frame);
    return snapped;
end

-- Re-snaps a frame to its current on-screen position - used after the
-- player drags a window, since a drag can land it at an arbitrary
-- sub-pixel position again.
--
-- Also updates the registered window's layout.x/y (converted into the same
-- CENTER-relative convention Pixel.ApplyLayout uses for x/y) so a later
-- UI_SCALE_CHANGED rescale re-applies the dragged position
-- instead of reverting to the window's create-time default. `onSnapped(x, y)`
-- - if given - fires with those same CENTER-relative coordinates, letting
-- callers persist the dragged position (e.g. to a saved-variable setting).
function Pixel.SnapPosition(frame, onSnapped)
    -- GetLeft()/GetTop() are in this frame's own self-scaled coordinate
    -- space (see ToSelfOffset above), same as everything SetPoint reads -
    -- convert to true UIParent-local units before doing any layout math in
    -- that convention (screenWidth/Height, layout.x/y, Pixel.Snap).
    local selfLeft, selfTop = frame:GetLeft(), frame:GetTop();
    if (not selfLeft or not selfTop) then return; end

    local scale = frame:GetScale();
    local left, top = selfLeft * scale, selfTop * scale;

    local x = Pixel.Snap(left);
    local y = Pixel.Snap(top - UIParent:GetHeight());

    frame:ClearAllPoints();
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", ToSelfOffset(frame, x), ToSelfOffset(frame, y));
    Pixel.CorrectDrift(frame);

    local entry = windows[frame];
    local screenWidth, screenHeight = UIParent:GetWidth(), UIParent:GetHeight();
    local width, height = frame:GetWidth(), frame:GetHeight();
    local centerX = x + width * scale / 2 - screenWidth / 2;
    local centerY = y + screenHeight / 2 - height * scale / 2;

    if (entry) then
        entry.layout.x = centerX;
        entry.layout.y = centerY;
    end

    if (onSnapped) then onSnapped(centerX, centerY); end
end

-- Restores a registered window to the x/y it was originally created with
-- (see the defaultX/defaultY captured by RegisterWindow above), leaving its
-- current size untouched - used by /zl resetpositions. No-ops for a frame
-- that was never registered via Pixel.RegisterWindow.
function Pixel.ResetPosition(frame)
    local entry = windows[frame];
    if (not entry) then return; end

    entry.layout.x = entry.defaultX;
    entry.layout.y = entry.defaultY;
    Pixel.ApplyLayout(frame, entry.layout);
    if (entry.onRescale) then entry.onRescale(); end
end

local rescaleFrame = CreateFrame("Frame");
rescaleFrame:RegisterEvent("UI_SCALE_CHANGED");
rescaleFrame:RegisterEvent("DISPLAY_SIZE_CHANGED");
rescaleFrame:SetScript("OnEvent", function()
    for frame, entry in pairs(windows) do
        Pixel.ApplyLayout(frame, entry.layout);
        if (entry.onRescale) then entry.onRescale(); end
    end
    refreshTracked();
end);

--------------------------------------------------------------------------
-- `/fl pixel` diagnostics (routed from Debug.lua), for tracking down 1px
-- borders that vanish at some resolutions/UI scales:
--   /fl pixel            - screen/scale values, plus the 4 border strips
--                          (Theme.Helpers.SetFlatBackdrop) of the frame
--                          under the mouse, in physical pixels
--   /fl pixel bias <px>  - gridBias above, re-applied to every window
--------------------------------------------------------------------------

local BORDER_STRIPS = { "top", "bottom", "left", "right" };

local function out(fmt, ...)
    print("|cff8865ffForeverLoot|r " .. fmt:format(...));
end

local function physical(region)
    local _, physH = GetPhysicalScreenSize();
    local k = region:GetEffectiveScale() * physH / 768;
    local l, t, w, h = region:GetLeft(), region:GetTop(), region:GetWidth(), region:GetHeight();
    if (not l) then return nil; end
    local screenTop = UIParent:GetTop() * UIParent:GetEffectiveScale() * physH / 768;
    return l * k, screenTop - t * k, w * k, h * k;
end

local function mouseFrame()
    if (GetMouseFoci) then return (GetMouseFoci())[1]; end
    if (GetMouseFocus) then return GetMouseFocus(); end
end

local function describe(frame)
    local l, t, w, h = physical(frame);
    out("frame %s  left=%.3f top=%.3f w=%.3f h=%.3f px  effScale=%.4f",
        tostring(frame:GetName() or frame:GetObjectType()), l or -1, t or -1, w or -1, h or -1, frame:GetEffectiveScale());
    local border = frame.flBorder;
    if (not border) then
        out("  (no ForeverLoot border on this frame - hover the box itself)");
        return;
    end
    out("  edge=%.5f units (%d px wanted)", border.edge or -1, border.thicknessPx);
    for _, name in ipairs(BORDER_STRIPS) do
        local strip = border[name];
        local pl, pt, pw, ph = physical(strip);
        local snap = strip.IsSnappingToPixelGrid and tostring(strip:IsSnappingToPixelGrid()) or "?";
        out("  %-6s shown=%s left=%.3f top=%.3f w=%.3f h=%.3f snap=%s",
            name, tostring(strip:IsShown()), pl or -1, pt or -1, pw or -1, ph or -1, snap);
    end
end

function Pixel.HandleSlash(rest)
    local cmd, arg = string.match(rest or "", "^(%S*)%s*(.-)$");
    if (cmd == "bias") then
        gridBias = tonumber(arg) or 0;
        for frame, entry in pairs(windows) do Pixel.ApplyLayout(frame, entry.layout); end
        out("window grid bias set to %.3f px.", gridBias);
    else
        local pw, ph = GetPhysicalScreenSize();
        out("physical %dx%d  useUiScale=%s uiScale=%s  UIParent effScale=%.5f height=%.3f",
            pw, ph, tostring(GetCVar("useUiScale")), tostring(GetCVar("uiScale")),
            UIParent:GetEffectiveScale(), UIParent:GetHeight());
        out("Pixel.Unit=%.5f units  PixelSize(1)=%.5f units  windowScale=%.2f  bias=%.3f",
            Pixel.Unit(), Pixel.PixelSize(1), currentScale, gridBias);
        local frame = mouseFrame();
        if (frame and frame ~= WorldFrame) then describe(frame); else out("(hover a ForeverLoot box to inspect its border)"); end
    end
end
