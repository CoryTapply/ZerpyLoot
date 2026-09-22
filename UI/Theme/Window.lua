--[[
Window frames and the bottom-edge resize handle. The look of both comes from
the active skin (CreateWindowChrome / ApplyWindowBackdrop /
SetWindowBorderColor and the `resizeHandle` table); this file only owns the
behavior that is the same for every skin - dragging, pixel-snapped
positioning and sizing.
]]

local ZL = ZerpyLoot;
local Theme = ZL.Theme;
local Pixel = ZL.Pixel;
local Helpers = Theme.Helpers;

local function skin()
    return Theme.GetSkin();
end

local function refreshBackdrop(frame)
    -- The skin's chrome draws its own border and background.
    if (frame.zlChrome) then return; end

    skin().ApplyWindowBackdrop(frame);
end

function Theme.ApplyBorder(frame, thicknessPx)
    frame.pixelBorderThickness = thicknessPx or 1;
    refreshBackdrop(frame);
    frame.pixelBorderReflow = function() refreshBackdrop(frame); end
end

function Theme.ApplyBackground(frame)
    frame.pixelBorderThickness = frame.pixelBorderThickness or 1;
    refreshBackdrop(frame);
end

--- Overrides a Theme.CreateWindow frame's border color (e.g. to make it
--- "pop" for something needing attention), surviving any later
--- pixelBorderReflow (a display-scale change re-applies whatever override is
--- currently set instead of silently reverting to the default border color).
--- Pass a nil/falsy `color` to go back to the default border color.
function Theme.SetWindowBorderColor(frame, color)
    frame.zlBorderColorOverride = color or nil;

    if (frame.zlChrome) then
        Helpers.SetChromeAlertBorder(frame, color);
        return;
    end

    skin().SetWindowBorderColor(frame, color);
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

    -- The skin may draw its own border/background art (returning it), or
    -- return nil to use the flat/tooltip backdrop from ApplyWindowBackdrop -
    -- also what a skin falls back to when its art is missing on this client.
    frame.zlChrome = skin().CreateWindowChrome(frame, width, height);

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

-- Bottom-edge drag-to-resize (height only, width and the top edge stay
-- fixed) for a Theme.CreateWindow frame: a thin invisible hit region
-- spanning the window's bottom margin, plus a line on the edge itself
-- whose look is set per skin by its `resizeHandle` table:
--
--   color           { r, g, b, a } of the line drawn on the window's bottom
--                   edge, or a key into the skin's colors (default "accent").
--                   false = draw no color (keep whatever `setup` applied).
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
--   hitOffsetY      vertical nudge of the invisible grab strip (positive = up,
--                   into the window), on top of its default centering on the
--                   bottom edge.
--   opacity         0-1 opacity of the line (default 1), multiplied with any
--                   alpha in `color`. Applies to whatever `setup` draws too.
--   offsetY         vertical nudge of the line (positive = up, into the window).
--   tintChrome      true = instead of drawing the line, tint the window's own
--                   bottom border art (the skin's chrome must provide
--                   chrome:SetResizeHighlight(color, strength)). While
--                   tinting, `color` is the tint, `opacity` its strength on
--                   hover and `dragOpacity` (default: `opacity`) while
--                   dragging; the line fields above are ignored. Windows
--                   without chrome fall back to the line.
--   dragOpacity     see tintChrome.
--   setup(line, frame)
--              optional hook run once per window, right after the line
--              texture is created - use it for anything the fields above
--              can't express (an atlas, a gradient, a second texture...).
--              The line's color/height are still driven by the fields
--              above afterwards; set `color = false` to keep whatever setup
--              applied (e.g. line:SetAtlas(...)).
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
    local style = skin().resizeHandle;

    -- Taller than the visible border line so the edge is easy to grab, but
    -- kept inside the window's own bottom margin (below whatever sits above
    -- it) rather than sticking out past the frame.
    local HIT_HEIGHT = style.hitHeight;

    frame:SetResizable(true);
    frame:SetResizeBounds(width, minHeight, width, maxHeight);

    local resizeHandle = CreateFrame("Button", nil, frame);
    local hitHalf = (style.hitWidthOffset or 0) / 2;
    local hitX, hitY = style.hitOffsetX or 0, style.hitOffsetY or 0;
    resizeHandle:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", hitX - hitHalf, hitY - HIT_HEIGHT / 2);
    resizeHandle:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", hitX + hitHalf, hitY - HIT_HEIGHT / 2);
    resizeHandle:SetHeight(HIT_HEIGHT);

    local resizeLine = frame:CreateTexture(nil, "OVERLAY");
    local lineHalf = (style.widthOffset or 0) / 2;
    local lineX, lineY = style.offsetX or 0, style.offsetY or 0;
    resizeLine:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", lineX - lineHalf, lineY);
    resizeLine:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", lineX + lineHalf, lineY);
    local lineColor = style.color;
    if (type(lineColor) == "string") then lineColor = Theme.colors[lineColor]; end
    if (lineColor) then resizeLine:SetColorTexture(unpack(lineColor)); end
    if (style.setup) then style.setup(resizeLine, frame); end
    resizeLine:SetAlpha(style.opacity or 1);
    resizeLine:Hide();

    -- Tint the border art itself instead of drawing the line, where the skin
    -- asks for it and this window's chrome can do it.
    local tintChrome = style.tintChrome and frame.zlChrome and frame.zlChrome.SetResizeHighlight and lineColor;

    local isResizing, isHovering = false, false;
    local function updateResizeLine()
        if (tintChrome) then
            local opacity = style.opacity or 1;
            local strength = isResizing and (style.dragOpacity or opacity) or isHovering and opacity or 0;
            frame.zlChrome:SetResizeHighlight(lineColor, strength);
            return;
        end

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
