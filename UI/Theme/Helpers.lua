--[[
Small building blocks any skin may call (Theme.Helpers.*). Nothing here is
specific to one skin's look - keep it that way, so a skin can use these
without depending on another skin's file.
]]

local ZL = ZerpyLoot;
local Theme = ZL.Theme;
local Pixel = ZL.Pixel;
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

--- Flat solid-color backdrop with a border `thicknessPx` physical pixels wide
--- (edge size computed through ZL.Pixel so it lands exactly on the pixel
--- grid). Pass a nil `fillColor` for a border-only frame.
function Helpers.SetFlatBackdrop(frame, fillColor, borderColor, thicknessPx)
    frame:SetBackdrop({
        bgFile = fillColor and Helpers.FLAT_TEXTURE or nil,
        edgeFile = Helpers.FLAT_TEXTURE,
        edgeSize = Pixel.PixelSize(thicknessPx or 1),
    });
    if (fillColor) then frame:SetBackdropColor(unpack(fillColor)); end
    frame:SetBackdropBorderColor(unpack(borderColor));
end

--- Mixes `color` ({ r, g, b, ... }) with white: strength 0 = white (no tint),
--- 1 = `color`. Returns r, g, b for SetVertexColor.
function Helpers.MixWithWhite(color, strength)
    strength = math.max(0, math.min(1, strength or 0));
    return 1 + (color[1] - 1) * strength,
        1 + (color[2] - 1) * strength,
        1 + (color[3] - 1) * strength;
end

--- Creates a non-interactive child that fills `frame`, at the frame's own
--- level so the window's content draws on top of it. Used as the container
--- for a skin's window chrome (see the CreateWindowChrome skin method).
function Helpers.CreateChromeFrame(frame)
    local chromeFrame = CreateFrame("Frame", nil, frame);
    chromeFrame:SetAllPoints(frame);
    chromeFrame:EnableMouse(false);
    chromeFrame:SetFrameLevel(frame:GetFrameLevel());
    return chromeFrame;
end

--- Chrome art can't be tinted, so a window border color override (see
--- Theme.SetWindowBorderColor) is drawn as a thin flat outline over it
--- instead, shown only while one is set.
function Helpers.SetChromeAlertBorder(frame, color)
    if (not frame.zlAlertBorder) then
        local alert = CreateFrame("Frame", nil, frame, "BackdropTemplate");
        alert:SetAllPoints(frame);
        alert:SetFrameLevel(frame:GetFrameLevel() + 20);
        alert:EnableMouse(false);
        alert:SetBackdrop({ edgeFile = Helpers.FLAT_TEXTURE, edgeSize = Pixel.PixelSize(2) });
        frame.zlAlertBorder = alert;
    end
    if (color) then frame.zlAlertBorder:SetBackdropBorderColor(unpack(color)); end
    frame.zlAlertBorder:SetShown(color ~= nil and color ~= false);
end
