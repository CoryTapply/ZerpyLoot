--[[
Pixel-perfect scale helpers. WoW converts a frame's size/position (in
UIParent-local units) to physical screen pixels via the frame's effective
scale:

    physicalPixels = unitSize * frame:GetEffectiveScale()

None of ForeverLoot's windows set a custom :SetScale(), so every frame's
effective scale is just UIParent's live UIScale - reading it at runtime
(rather than assuming a fixed value) keeps borders exactly 1 physical pixel
on any monitor, resolution, or UIScale setting without hardcoding any of
them.
]]

local FL = ForeverLoot;
local Pixel = FL.Pixel;

local EPSILON = 1e-4;
local windows = {};

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
-- plain frame:SetScale() on top of everything above - it's a coarse,
-- whole-window zoom, not a pixel-grid concept, so it deliberately does NOT
-- feed into Pixel.Unit()/PixelSize() (those keep reading UIParent's own
-- scale). Borders stay pixel-crisp at the default 1.0 and only lose that
-- crispness at other scales, same trade-off any addon's own UI-scale slider
-- has - not something this pass attempts to fix.
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
    end
end

-- Size, in UIParent units, of exactly one physical screen pixel.
function Pixel.Unit()
    return 1 / UIParent:GetEffectiveScale();
end

-- Rounds a desired UI-unit size to the nearest size that lands exactly on the
-- physical pixel grid at UIParent's current effective scale, via Blizzard's
-- own PixelUtil helper (used for e.g. backdrop edgeSize).
function Pixel.PixelSize(desiredPixels)
    return PixelUtil.GetNearestPixelSize(desiredPixels, UIParent:GetEffectiveScale());
end

-- Rounds to the nearest multiple of one physical pixel.
function Pixel.Snap(value)
    local px = Pixel.Unit();
    return math.floor((value / px) + 0.5) * px;
end

-- Rounds UP to the nearest multiple of one physical pixel, so a requested
-- size never shrinks below what was asked for.
function Pixel.SnapUp(value)
    local px = Pixel.Unit();
    return math.ceil((value / px) - EPSILON) * px;
end

-- Pixel.Snap/SnapUp only guarantee the *requested* position is a multiple of
-- one physical pixel - they can't see what WoW's own anchor-resolution pass
-- actually produces on screen. That pass can still land the frame a
-- fraction of a pixel off the grid (float rounding inside the engine's own
-- coordinate pipeline), and a texture that's exactly 1 physical pixel thick
-- will then straddle two pixel rows/columns via edge-coverage blending,
-- rendering as 2px despite the correct math. So after anchoring, re-measure
-- the frame's *actual* on-screen edges and nudge away any leftover drift.
function Pixel.CorrectDrift(frame)
    -- GetLeft()/GetTop() are in this frame's own self-scaled coordinate
    -- space (see ToSelfOffset above) - convert to true UIParent-local units
    -- before working out the physical-pixel drift.
    local selfLeft, selfTop = frame:GetLeft(), frame:GetTop();
    if (not selfLeft or not selfTop) then return; end

    local frameScale = frame:GetScale();
    local left, top = selfLeft * frameScale, selfTop * frameScale;

    local scale = UIParent:GetEffectiveScale();
    local screenHeight = UIParent:GetHeight();

    local leftPixels = left * scale;
    local topPixels = (screenHeight - top) * scale;

    local driftLeft = leftPixels - math.floor(leftPixels + 0.5);
    local driftTop = topPixels - math.floor(topPixels + 0.5);

    if (driftLeft == 0 and driftTop == 0) then return; end

    frame:AdjustPointsOffset(ToSelfOffset(frame, -driftLeft / scale), ToSelfOffset(frame, driftTop / scale));
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
    local width = Pixel.SnapUp(layout.width);
    local height = Pixel.SnapUp(layout.height);

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
function Pixel.MakeToplevelWindow(frame)
    frame:EnableMouse(true);
    frame:SetToplevel(true);
    frame:HookScript("OnShow", function() frame:Raise(); end);
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
    local snapped = Pixel.SnapUp(height);
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
end);
