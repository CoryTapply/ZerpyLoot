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
    local left, top = frame:GetLeft(), frame:GetTop();
    if (not left or not top) then return; end

    local scale = UIParent:GetEffectiveScale();
    local screenHeight = UIParent:GetHeight();

    local leftPixels = left * scale;
    local topPixels = (screenHeight - top) * scale;

    local driftLeft = leftPixels - math.floor(leftPixels + 0.5);
    local driftTop = topPixels - math.floor(topPixels + 0.5);

    if (driftLeft == 0 and driftTop == 0) then return; end

    frame:AdjustPointsOffset(-driftLeft / scale, driftTop / scale);
end

-- Applies a window's logical (unsnapped) layout - { width, height, x, y },
-- with x/y following the SetPoint("CENTER", x, y) convention - by snapping
-- its size and position onto the pixel grid and anchoring it TOPLEFT (so
-- only width/height need snapping for every edge to land on the grid).
function Pixel.ApplyLayout(frame, layout)
    local width = Pixel.SnapUp(layout.width);
    local height = Pixel.SnapUp(layout.height);

    local screenWidth, screenHeight = UIParent:GetWidth(), UIParent:GetHeight();
    local left = Pixel.Snap((screenWidth - width) / 2 + (layout.x or 0));
    local top = Pixel.Snap((layout.y or 0) - (screenHeight - height) / 2);

    frame:SetSize(width, height);
    frame:ClearAllPoints();
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, top);
    Pixel.CorrectDrift(frame);
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
    Pixel.ApplyLayout(frame, layout);
    if (onRescale) then onRescale(); end
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
-- CENTER-relative convention Pixel.ApplyLayout/Theme.CreateWindow use for
-- x/y) so a later UI_SCALE_CHANGED rescale re-applies the dragged position
-- instead of reverting to the window's create-time default. `onSnapped(x, y)`
-- - if given - fires with those same CENTER-relative coordinates, letting
-- callers persist the dragged position (e.g. to a saved-variable setting).
function Pixel.SnapPosition(frame, onSnapped)
    local left, top = frame:GetLeft(), frame:GetTop();
    if (not left or not top) then return; end

    local x = Pixel.Snap(left);
    local y = Pixel.Snap(top - UIParent:GetHeight());

    frame:ClearAllPoints();
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y);
    Pixel.CorrectDrift(frame);

    local entry = windows[frame];
    local screenWidth, screenHeight = UIParent:GetWidth(), UIParent:GetHeight();
    local width, height = frame:GetWidth(), frame:GetHeight();
    local centerX = x - (screenWidth - width) / 2;
    local centerY = y + (screenHeight - height) / 2;

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
