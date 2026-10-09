--[[
Small building blocks any skin may call (Theme.Helpers.*). Nothing here is
specific to one skin's look - keep it that way, so a skin can use these
without depending on another skin's file.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
Theme.Helpers = Theme.Helpers or {};
local Helpers = Theme.Helpers;

-- Flat, solid-color, Blizzard-shipped texture used for both the background and
-- border fill of every flat backdrop. Flat = nothing for the backdrop
-- system's edge/corner sampling to blur, unlike a detailed edgeFile art asset
-- (which is what actually caused the "blurred bitmap art" the flat approach
-- was originally adopted to avoid - not SetBackdrop itself).
Helpers.FLAT_TEXTURE = "Interface\\Buttons\\WHITE8X8";

--- Makes sure `frame` has the SetBackdrop family (frames not created from a
--- BackdropTemplate need the mixin applied first).
function Helpers.EnsureBackdrop(frame)
    if (not frame.SetBackdrop) then
        Mixin(frame, BackdropTemplateMixin);
    end
end

-- Shared so a repeat SetFlatBackdrop (hover states) hits SetBackdrop's
-- same-info early return instead of rebuilding the pieces.
local FILL_INFO = { bgFile = Helpers.FLAT_TEXTURE };

local function newStrip(frame)
    local strip = frame:CreateTexture(nil, "BORDER");
    strip:SetTexture(Helpers.FLAT_TEXTURE);
    if (strip.SetSnapToPixelGrid) then
        strip:SetSnapToPixelGrid(false);
        strip:SetTexelSnappingBias(0);
    end
    return strip;
end

-- Top/bottom span the full width; left/right sit between them so corners
-- are never drawn twice (matters for a translucent border color).
local function layoutBorder(frame, border)
    local edge = Pixel.PixelSize(border.thicknessPx, frame);
    if (border.edge == edge) then return; end
    border.edge = edge;

    local top, bottom, left, right = border.top, border.bottom, border.left, border.right;
    top:ClearAllPoints();
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
    top:SetHeight(edge);
    bottom:ClearAllPoints();
    bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0);
    bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0);
    bottom:SetHeight(edge);
    left:ClearAllPoints();
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -edge);
    left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, edge);
    left:SetWidth(edge);
    right:ClearAllPoints();
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -edge);
    right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, edge);
    right:SetWidth(edge);
end

local function setBorderColor(self, r, g, b, a)
    for _, strip in ipairs(self.flBorder.strips) do
        strip:SetVertexColor(r, g, b, a or 1);
    end
end

local function getBorderColor(self)
    return self.flBorder.top:GetVertexColor();
end

local function ensureBorder(frame)
    local border = frame.flBorder;
    if (border) then return border; end

    border = {
        top = newStrip(frame), bottom = newStrip(frame),
        left = newStrip(frame), right = newStrip(frame),
        thicknessPx = 1,
    };
    border.strips = { border.top, border.bottom, border.left, border.right };
    frame.flBorder = border;
    frame.SetBackdropBorderColor = setBorderColor;
    frame.GetBackdropBorderColor = getBorderColor;

    Pixel.Track(frame, "border", function() layoutBorder(frame, border); end);
    return border;
end

--- Flat solid-color backdrop with a border `thicknessPx` physical pixels wide.
--- Pass a nil `fillColor` for a border-only frame.
---
--- The fill is a plain BackdropTemplate bgFile (SetBackdropColor keeps
--- working). The border is NOT the backdrop's edge pieces: it is 4 texture
--- strips of our own (EllesmereUI's PP.CreateBorder approach) with the
--- engine's pixel-grid snapping turned off. With snapping on, a 1px edge
--- that lands on a fractional pixel position can round to 0px and that side
--- of the box vanishes - which side depends on the box's position, so it
--- showed up at 1440p/1080p and odd UI scales but not at 4K (2px edges).
--- Unsnapped, an edge exactly N pixels thick always covers N pixel rows.
---
--- SetBackdropBorderColor/GetBackdropBorderColor on the frame are routed to
--- the strips, so callers recolor the border exactly as before. Use
--- ClearFlatBackdrop (not SetBackdrop(nil)) to remove it. The edge thickness
--- is re-applied whenever the pixel grid changes (see Pixel.Track).
function Helpers.SetFlatBackdrop(frame, fillColor, borderColor, thicknessPx)
    if (fillColor) then
        frame:SetBackdrop(FILL_INFO);
        frame:SetBackdropColor(unpack(fillColor));
    elseif (frame.SetBackdrop) then
        frame:SetBackdrop(nil);
    end

    local border = ensureBorder(frame);
    if (border.thicknessPx ~= (thicknessPx or 1)) then
        border.thicknessPx = thicknessPx or 1;
        border.edge = nil;
    end
    layoutBorder(frame, border);
    for _, strip in ipairs(border.strips) do strip:Show(); end
    frame:SetBackdropBorderColor(unpack(borderColor));
end

--- Removes a SetFlatBackdrop fill and border (hover highlights etc.).
function Helpers.ClearFlatBackdrop(frame)
    if (frame.SetBackdrop) then frame:SetBackdrop(nil); end
    local border = frame.flBorder;
    if (border) then
        for _, strip in ipairs(border.strips) do strip:Hide(); end
    end
end

--- Wires an eased mouse-wheel scroll onto `scrollFrame` (any ScrollFrame,
--- typically one built off UIPanelScrollFrameTemplate). Replaces the
--- template's default OnMouseWheel (which jumps SetVerticalScroll by a huge
--- fixed step, instantly) with: each wheel notch nudges a target offset by
--- opts.step pixels (clamped to the frame's current scroll range), and every
--- OnUpdate tick moves the actual GetVerticalScroll() a fraction of the way
--- toward that target using elapsed-time-based exponential smoothing, so it
--- reads the same regardless of framerate. The OnUpdate script detaches
--- itself once the frame is within epsilon of target, so idle scroll frames
--- don't pay a per-frame cost.
---
--- Dragging the scrollbar's own thumb is left untouched (still instant,
--- straight through Blizzard's slider) - grabbing the thumb also cancels
--- any wheel animation still in flight, so the two input paths never fight
--- for control of the same scroll position.
function Helpers.EnableSmoothScroll(scrollFrame, opts)
    opts = opts or {};
    local step = opts.step or 36;
    local smoothTime = opts.smoothTime or 0.12; -- seconds; lower = snappier
    local epsilon = 0.5; -- px; snap + stop once this close to target

    scrollFrame:EnableMouseWheel(true);

    -- nil = not animating (actual scroll position is authoritative).
    local target = nil;

    local function clampTarget(value)
        local maxScroll = scrollFrame:GetVerticalScrollRange() or 0;
        if (maxScroll < 0) then maxScroll = 0; end
        return Clamp(value, 0, maxScroll);
    end

    local function onUpdate(self, elapsed)
        if (not target) then
            self:SetScript("OnUpdate", nil);
            return;
        end

        -- Re-clamp every tick: list content (and thus the scroll range) can
        -- shrink mid-animation (e.g. an item removed while scrolling), which
        -- would otherwise leave target pointing past the new max.
        target = clampTarget(target);

        local current = scrollFrame:GetVerticalScroll();
        if (math.abs(target - current) <= epsilon) then
            scrollFrame:SetVerticalScroll(target);
            target = nil;
            self:SetScript("OnUpdate", nil);
            return;
        end

        local alpha = 1 - math.exp(-elapsed / smoothTime);
        scrollFrame:SetVerticalScroll(current + (target - current) * alpha);
    end

    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local base = target or self:GetVerticalScroll();
        target = clampTarget(base - delta * step);
        self:SetScript("OnUpdate", onUpdate);
    end);

    -- Grabbing the scrollbar thumb should be instant and win outright over
    -- any wheel animation still converging.
    local bar = scrollFrame.ScrollBar;
    if (bar) then
        bar:HookScript("OnMouseDown", function() target = nil; end);
    end

    -- Exposed so callers that need to know the *intended* end position
    -- (e.g. a "stay pinned to bottom" check) can read it instead of the
    -- still-interpolating GetVerticalScroll(). Returns nil when idle.
    scrollFrame.zlSmoothScrollTarget = function() return target; end;
end
