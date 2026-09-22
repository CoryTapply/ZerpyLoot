--[[
Small building blocks any skin may call (Theme.Helpers.*). Nothing here is
specific to one skin's look - keep it that way, so a skin can use these
without depending on another skin's file.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
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
--- (edge size computed through FL.Pixel so it lands exactly on the pixel
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

local DELETE_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\trash.tga";
local DELETE_ICON_SIZE = 16;
local DELETE_ART_BUTTON_SIZE = 24;

--- Delete/trash icon button (same look everywhere a row can be removed -
--- TradeQueueWindow, LootCouncilAddItemsWindow, ...), skin-agnostic: uses
--- the active skin's own delete-button art kit (Theme.metrics.deleteButtonArtKit)
--- when one is set and its atlas art actually exists on this client, falling
--- back to a plain trash icon with a pressed-state nudge otherwise. Caller
--- positions the returned button and sets its own OnClick.
function Helpers.CreateDeleteButton(parent, fallbackSize)
    local button = CreateFrame("Button", nil, parent);
    button:RegisterForClicks("LeftButtonUp");

    local artKit = Theme.metrics.deleteButtonArtKit;
    local useArtKit = artKit ~= nil
        and C_Texture.GetAtlasInfo(artKit) ~= nil
        and C_Texture.GetAtlasInfo(artKit .. "-Pressed") ~= nil;

    if (useArtKit) then
        button:SetSize(DELETE_ART_BUTTON_SIZE, DELETE_ART_BUTTON_SIZE);
        button:SetNormalAtlas(artKit);
        button:SetPushedAtlas(artKit .. "-Pressed");
        if (C_Texture.GetAtlasInfo(artKit .. "-Highlight")) then
            button:SetHighlightAtlas(artKit .. "-Highlight");
        end
    else
        button:SetSize(fallbackSize or DELETE_ART_BUTTON_SIZE, fallbackSize or DELETE_ART_BUTTON_SIZE);

        local highlight = button:CreateTexture(nil, "HIGHLIGHT");
        highlight:SetAllPoints(button);
        highlight:SetColorTexture(1, 1, 1, 0.12);
        button:SetHighlightTexture(highlight);

        local icon = button:CreateTexture(nil, "ARTWORK");
        icon:SetSize(DELETE_ICON_SIZE, DELETE_ICON_SIZE);
        icon:SetPoint("CENTER");
        icon:SetTexture(DELETE_ICON_TEXTURE);
        icon:SetVertexColor(unpack(Theme.colors.danger));

        -- Pressed state: nudge the icon 1px down-right while the mouse is
        -- held on the button, restoring it on release/leave/hide so it can't
        -- stick shifted.
        button:SetScript("OnMouseDown", function() icon:SetPoint("CENTER", 1, -1); end);
        for _, script in ipairs({ "OnMouseUp", "OnLeave", "OnHide" }) do
            button:SetScript(script, function() icon:SetPoint("CENTER", 0, 0); end);
        end
    end

    return button;
end
