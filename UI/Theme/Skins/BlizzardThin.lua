--[[
"Blizzard Thin" skin: the Blizzard skin (every button, input box and scrollbar
unchanged) with only the window chrome swapped for the thinner action-bar-style
frame art WoW Forever's BagsBar draws. It shows what a derived skin looks like:
everything not defined here comes from `base = "blizzard"`.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Helpers = Theme.Helpers;

local Skin = {};

Skin.name = "Blizzard Thin";
Skin.base = "blizzard";

-- Only the fields that differ from Blizzard's (= Default's) resize handle:
-- pulled in to sit inside this art's rounded ends and moved up onto its edge.
Skin.resizeHandle = {
    widthOffset = -9,
    hitWidthOffset = -9,
    offsetX = -0.5,
    hitOffsetX = -2,
    offsetY = -2,
};

-- Window chrome: the "UI-HUD-ActionBar-Frame" atlas, which is exactly what WoW
-- Forever's BagsBar draws as its BorderArt. That bar has no separate
-- background layer - this one atlas is the whole plate, dark fill and ornate
-- edge together - so it serves as both the border and the background here too.
--
-- The atlas is 55x55 and carries its own nine-slice data: margins of 20
-- (left/right) and 25 (top/bottom), tiled. The client applies those
-- margins itself when the atlas is put on ONE texture and the texture is
-- resized, which is how the bar stretches it over any width; so this does the
-- same, rather than cutting the atlas into pieces by hand. (An earlier
-- version sliced it at a guessed 8px, which cut straight through the corner
-- ornaments and stretched them.)
local CHROME_ATLAS = "UI-HUD-ActionBar-Frame";

-- Only used if the client doesn't report the atlas's own slice margins
-- (left, top, right, bottom) - the values from the atlas data.
local CHROME_FALLBACK_MARGINS = { 20, 25, 20, 25 };

-- Height, in the same units as the slice margins, of the strip of border art
-- that takes the resize-handle tint (see SetResizeHighlight). Tune this if it
-- covers too little or too much of the bottom border.
local RESIZE_HIGHLIGHT_HEIGHT = 5;

-- How far the art extends past the window's edges, exactly as the BagsBar
-- anchors it around its own buttons.
local CHROME_OUTSET = { left = 6, top = 6, right = 5, bottom = 5 };

--- Builds the chrome as a child of `frame` and returns it, or nil when the
--- atlas or the slice API isn't available (the window then falls back to the
--- plain tooltip-art backdrop inherited from the Blizzard skin). Content
--- layout is untouched: the chrome sits at the window's own frame level so its
--- children draw on top of it. Unlike the Blizzard skin's chrome it also works
--- for tiny windows: the slice margins shrink to fit instead of the border
--- being dropped.
function Skin.CreateWindowChrome(frame)
    if (not C_Texture.GetAtlasInfo(CHROME_ATLAS)) then return nil; end

    local built, chrome = pcall(function()
        local chromeFrame = Helpers.CreateChromeFrame(frame);

        local art = chromeFrame:CreateTexture(nil, "BACKGROUND", nil, -6);
        art:SetAtlas(CHROME_ATLAS);
        art:SetPoint("TOPLEFT", chromeFrame, "TOPLEFT", -CHROME_OUTSET.left, CHROME_OUTSET.top);
        art:SetPoint("BOTTOMRIGHT", chromeFrame, "BOTTOMRIGHT", CHROME_OUTSET.right, -CHROME_OUTSET.bottom);

        -- Read the margins back rather than assuming a unit: whatever
        -- SetAtlas applied is by definition in the units the setter takes.
        local left, top, right, bottom = art:GetTextureSliceMargins();
        if (not (left and top and right and bottom)) then
            left, top, right, bottom = unpack(CHROME_FALLBACK_MARGINS);
        end
        art:SetTextureSliceMode(Enum.UITextureSliceMode.Tiled);

        -- Resize-handle hover/drag feedback (see Theme.MakeBottomResizable's
        -- tintChrome). The atlas is one texture with the dark fill baked in,
        -- so tinting `art` would tint the whole plate. Instead a second copy
        -- of the same art, anchored exactly like `art`, sits inside a child
        -- frame that clips to just the bottom strip; only that copy is
        -- tinted, and it is shown only while highlighted. The strip is as
        -- tall as the border's horizontal thickness (RESIZE_HIGHLIGHT_HEIGHT)
        -- but spans the full width, so it colors the bottom edge and the
        -- horizontal part of both corners without running up the sides.
        --
        -- The strip frame sits one level ABOVE the chrome frame: frames at
        -- the same level have no guaranteed draw order, and if it were drawn
        -- first it would be hidden under the opaque `art`. And since
        -- SetClipsChildren clips child frames, the copy lives in an inner
        -- frame (filling the same rect as `art`) rather than directly on the
        -- strip.
        local strip = CreateFrame("Frame", nil, chromeFrame);
        strip:SetClipsChildren(true);
        strip:EnableMouse(false);
        strip:SetFrameLevel(chromeFrame:GetFrameLevel() + 1);
        strip:SetPoint("BOTTOMLEFT", chromeFrame, "BOTTOMLEFT", -CHROME_OUTSET.left, -CHROME_OUTSET.bottom);
        strip:SetPoint("BOTTOMRIGHT", chromeFrame, "BOTTOMRIGHT", CHROME_OUTSET.right, -CHROME_OUTSET.bottom);
        strip:Hide();

        local stripInner = CreateFrame("Frame", nil, strip);
        stripInner:EnableMouse(false);
        stripInner:SetFrameLevel(strip:GetFrameLevel());
        stripInner:SetPoint("TOPLEFT", chromeFrame, "TOPLEFT", -CHROME_OUTSET.left, CHROME_OUTSET.top);
        stripInner:SetPoint("BOTTOMRIGHT", chromeFrame, "BOTTOMRIGHT", CHROME_OUTSET.right, -CHROME_OUTSET.bottom);

        local stripArt = stripInner:CreateTexture(nil, "OVERLAY");
        stripArt:SetAtlas(CHROME_ATLAS);
        stripArt:SetAllPoints(stripInner);
        stripArt:SetTextureSliceMode(Enum.UITextureSliceMode.Tiled);
        stripArt:SetDesaturated(true);

        -- Once the art is too small for both opposite margins the corners
        -- would overlap, so all four are scaled down together (keeping the
        -- corners' shape) until they fit. OnSizeChanged passes (self, w, h).
        local appliedScale;
        local function updateMargins(_, width, height)
            width, height = width or chromeFrame:GetWidth(), height or chromeFrame:GetHeight();
            width = width + CHROME_OUTSET.left + CHROME_OUTSET.right;
            height = height + CHROME_OUTSET.top + CHROME_OUTSET.bottom;

            local scale = 1;
            if (left + right > 0 and width > 0) then scale = math.min(scale, width / (left + right)); end
            if (top + bottom > 0 and height > 0) then scale = math.min(scale, height / (top + bottom)); end

            if (scale ~= appliedScale) then
                appliedScale = scale;
                art:SetTextureSliceMargins(left * scale, top * scale, right * scale, bottom * scale);
                stripArt:SetTextureSliceMargins(left * scale, top * scale, right * scale, bottom * scale);
                strip:SetHeight(RESIZE_HIGHLIGHT_HEIGHT * scale);
            end
        end
        chromeFrame:SetScript("OnSizeChanged", updateMargins);
        updateMargins();

        function chromeFrame:SetResizeHighlight(color, strength)
            if (color and (strength or 0) > 0) then
                stripArt:SetVertexColor(Helpers.MixWithWhite(color, strength));
                strip:Show();
            else
                strip:Hide();
            end
        end

        chromeFrame.Art = art;
        return chromeFrame;
    end);

    return built and chrome or nil;
end

Theme.RegisterSkin("blizzardthin", Skin);
