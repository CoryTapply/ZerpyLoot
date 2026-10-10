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

Every registered window (and every Pixel.ScaleWithWindows frame) runs at a
scale where one of ITS units is a whole number of physical pixels - so every
integer SetPoint offset and SetSize inside a window is pixel-exact without
wrapping each call. That whole number is UIParent's own px-per-unit rounded
(min 1), so windows keep roughly the size they were designed at in UIParent
units. Window Scale multiplies on top: at 1.0 everything is exact, other
values are smooth but soft.
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

-- Window Scale (UI/SettingsWindow/Pages/Appearance.lua's slider). Window
-- positions (layout.x/y, saved windowPositions) stay in plain UIParent units
-- whatever the window's own scale; see Pixel.GetWindowScale for the scale.
local userScale = 1.0;

-- Frames parented to UIParent that aren't registered windows but must render
-- at the window scale (dropdown lists, the auto-roll popup) - see
-- Pixel.ScaleWithWindows.
local scaledFrames = {};

-- Last good physical height: GetPhysicalScreenSize() can report 0 mid
-- display-mode change, and a 0 here would turn every scale into inf/NaN.
local physicalHeight = 1080;

local function PhysicalHeight()
    local _, h = GetPhysicalScreenSize();
    if (h and h > 0) then physicalHeight = h; end
    return physicalHeight;
end

-- Physical pixels per UIParent unit (1.83 at 4K@0.65, 1.41 at 1080p@1.0).
local function BasePixels()
    return UIParent:GetEffectiveScale() * PhysicalHeight() / 768;
end

-- Whole physical pixels per window unit at Window Scale 1.0.
local function WholePixels()
    return math.max(1, math.floor(BasePixels() + 0.5));
end

-- Whether one window unit is currently a whole number of physical pixels
-- (true at Window Scale 1.0, and any other value that happens to land on
-- one), i.e. whether integer sizes inside a window are pixel-exact.
local function IsWholePixels()
    local px = WholePixels() * userScale;
    return math.abs(px - math.floor(px + 0.5)) < EPSILON;
end

function Pixel.GetGlobalScale()
    return userScale;
end

--- The :SetScale() value (relative to UIParent) every ForeverLoot window
--- renders at: one window unit = WholePixels() * Window Scale physical px.
function Pixel.GetWindowScale()
    return WholePixels() * userScale / BasePixels();
end

-- Re-applies the window scale to everything that renders at it - every
-- registered window (re-laid-out from its stored layout, so its layout.x/y
-- center stays fixed on screen and a hidden window works too), every
-- Pixel.ScaleWithWindows frame - then everything sized from a pixel count.
local function ApplyAll()
    local scale = Pixel.GetWindowScale();
    for frame, entry in pairs(windows) do
        frame:SetScale(scale);
        Pixel.ApplyLayout(frame, entry.layout);
        if (entry.onRescale) then entry.onRescale(); end
    end
    for frame, onRescale in pairs(scaledFrames) do
        frame:SetScale(scale);
        if (onRescale ~= true) then onRescale(); end
    end
    refreshTracked();
end

--- Sets the Window Scale and applies it to every window immediately; a
--- window registered later (opened for the first time after the slider
--- moved) picks it up in Pixel.RegisterWindow.
function Pixel.SetGlobalScale(scale)
    userScale = scale;
    ApplyAll();
end

--- Renders a frame that isn't a registered window (e.g. a dropdown list
--- parented to UIParent so it can draw over everything) at the window scale,
--- now and after every rescale - so it matches the window it opened from.
--- `onRescale` (optional) re-positions anything placed in UIParent units.
function Pixel.ScaleWithWindows(frame, onRescale)
    scaledFrames[frame] = onRescale or true;
    frame:SetScale(Pixel.GetWindowScale());
end

-- Size, in UIParent units, of exactly one physical screen pixel.
function Pixel.Unit()
    return 1 / BasePixels();
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

-- Grid a window's own width/height snaps to: whole window units while a unit
-- is whole pixels (so children anchored to its RIGHT/BOTTOM edges stay exact
-- too), otherwise one physical pixel in its self-scaled units (so at least
-- its own edges do).
local function sizeUnit(frame)
    if (IsWholePixels()) then return 1; end
    return selfUnit(frame);
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

    local driftLeft = leftPixels - math.floor(leftPixels + 0.5);
    local driftTop = topPixels - math.floor(topPixels + 0.5);

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
-- (screen-center + layout.x/y) through the window's scale, not just through
-- its raw unscaled width/height - otherwise the window's rendered center
-- silently drifts off layout.x/y.
function Pixel.ApplyLayout(frame, layout)
    local width = Pixel.SnapUp(layout.width, sizeUnit(frame));
    local height = Pixel.SnapUp(layout.height, sizeUnit(frame));
    local scale = frame:GetScale();

    local screenWidth, screenHeight = UIParent:GetWidth(), UIParent:GetHeight();
    local centerX = screenWidth / 2 + (layout.x or 0);
    local centerY = screenHeight / 2 + (layout.y or 0);

    local left = Pixel.Snap(centerX - width * scale / 2);
    local top = Pixel.Snap(centerY + height * scale / 2 - screenHeight);

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
    frame:SetScale(Pixel.GetWindowScale());
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
    local snapped = Pixel.SnapUp(height, sizeUnit(frame));
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
-- UIScale or resolution changed: the whole-pixel window scale depends on
-- both, so re-derive it (not just re-snap the layouts).
rescaleFrame:SetScript("OnEvent", ApplyAll);
