--[[
Thin Blizzard-side entry point (Escape menu > Options > AddOns), registered
as a canvas category through the Settings API. A big centered wordmark/
description/version/button splash - the actual settings (Font, Group Loot
options) live in ForeverLoot's own window, see UI/SettingsWindow/, opened
here or via /fl config (/fl c).

Built with FL.UI.Colors/Sizes/SetFont/Skin. Everything hangs off one
centered anchor frame (`container`) so the block re-centers if the Settings
canvas is ever resized.
]]

local FL = ForeverLoot;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;

local panel = CreateFrame("Frame", "ForeverLootOptionsPanel", UIParent);
panel.name = FL.name;

-- C_AddOns is the current namespace; the bare global is the pre-namespace
-- fallback for older clients that don't have it.
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata;
local ADDON_VERSION = GetAddOnMetadata(FL.name, "Version") or "?";

----------------------------------------------------------------------------
-- Single centering anchor - not a Blizzard-canvas-edge offset, so the whole
-- block re-centers automatically if the Settings canvas is resized.
----------------------------------------------------------------------------

local container = CreateFrame("Frame", nil, panel);
container:SetPoint("CENTER", panel, "CENTER", 0, 40);
container:SetSize(1, 1);

----------------------------------------------------------------------------
-- 1. Wordmark
----------------------------------------------------------------------------

local wordmark = container:CreateFontString(nil, "OVERLAY");
SetFont(wordmark, "hero");
wordmark:SetTextColor(unpack(Colors.titlePurple));
wordmark:SetPoint("CENTER", container, "CENTER", 0, 0);
wordmark:SetText(FL.name);

----------------------------------------------------------------------------
-- 2. Description
----------------------------------------------------------------------------

local description = container:CreateFontString(nil, "OVERLAY");
SetFont(description, "body");
description:SetTextColor(unpack(Colors.description));
description:SetPoint("TOP", wordmark, "BOTTOM", 0, -Sizes.optionsPanel.descriptionGap);
description:SetText("Loot council and group loot rolls for your raid");

----------------------------------------------------------------------------
-- 3. Version badge - square-cornered, border only, sized to fit its text.
----------------------------------------------------------------------------

local versionBadge = CreateFrame("Frame", nil, container, "BackdropTemplate");
Skin.Backdrop(versionBadge, nil, Colors.disabledBorder);
versionBadge:SetHeight(Sizes.optionsPanel.boxHeight);
versionBadge:SetPoint("TOP", description, "BOTTOM", 0, -Sizes.optionsPanel.versionGap);

local versionText = versionBadge:CreateFontString(nil, "OVERLAY");
SetFont(versionText, "small");
versionText:SetTextColor(unpack(Colors.muted));
versionText:SetPoint("CENTER", versionBadge, "CENTER", 0, 0);
versionText:SetText("Version " .. ADDON_VERSION);
versionBadge:SetWidth(versionText:GetStringWidth() + Sizes.optionsPanel.badgePadX * 2);

----------------------------------------------------------------------------
-- 4. Open Settings button + "or type /fl config anytime" hint line.
----------------------------------------------------------------------------

local openButton = CreateFrame("Button", nil, container, "BackdropTemplate");
Skin.Button(openButton, "primary");
SetFont(openButton.text, "optionsPanelButton");
openButton.text:SetText("Open Settings");
openButton:SetSize(Sizes.optionsPanel.buttonWidth, Sizes.optionsPanel.buttonHeight);
openButton:SetPoint("TOP", versionBadge, "BOTTOM", 0, -Sizes.optionsPanel.buttonGap);

openButton:SetScript("OnClick", function()
    if (SettingsPanel and SettingsPanel:IsShown() and not InCombatLockdown()) then
        HideUIPanel(SettingsPanel);
    end
    if (FL.UI.SettingsWindow and FL.UI.SettingsWindow.Show) then
        FL.UI.SettingsWindow.Show();
    end
end);

-- Built as one row so "/fl config" can sit inline between the two text
-- pieces without wrapping: width comes from measuring all three pieces
-- first, then the row frame is sized to fit and anchored as a whole.
local hintPrefix = container:CreateFontString(nil, "OVERLAY");
SetFont(hintPrefix, "small");
hintPrefix:SetTextColor(unpack(Colors.muted));
hintPrefix:SetText("or type");

local hintSuffix = container:CreateFontString(nil, "OVERLAY");
SetFont(hintSuffix, "small");
hintSuffix:SetTextColor(unpack(Colors.muted));
hintSuffix:SetText("anytime");

local keycap = CreateFrame("Frame", nil, container, "BackdropTemplate");
Skin.Backdrop(keycap, Colors.controlBg, Colors.checkboxBorder);
keycap:SetHeight(Sizes.optionsPanel.boxHeight);

local keycapText = keycap:CreateFontString(nil, "OVERLAY");
SetFont(keycapText, "body");
keycapText:SetTextColor(unpack(Colors.text));
keycapText:SetPoint("CENTER", keycap, "CENTER", 0, 0);
keycapText:SetText("/fl config");
keycap:SetWidth(keycapText:GetStringWidth() + Sizes.optionsPanel.keycapPadX * 2);

local hintRow = CreateFrame("Frame", nil, container);
local keycapSpacing = Sizes.optionsPanel.keycapSpacing;
local hintRowWidth = hintPrefix:GetStringWidth() + keycapSpacing + keycap:GetWidth()
    + keycapSpacing + hintSuffix:GetStringWidth();
hintRow:SetSize(hintRowWidth, Sizes.optionsPanel.boxHeight);
hintRow:SetPoint("TOP", openButton, "BOTTOM", 0, -Sizes.optionsPanel.hintGap);

hintPrefix:SetPoint("LEFT", hintRow, "LEFT", 0, 0);
keycap:SetPoint("LEFT", hintPrefix, "RIGHT", keycapSpacing, 0);
hintSuffix:SetPoint("LEFT", keycap, "RIGHT", keycapSpacing, 0);

----------------------------------------------------------------------------

local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name);
Settings.RegisterAddOnCategory(category);

FL.UI.OptionsPanel.frame = panel;

function FL.UI.OptionsPanel.Open()
    Settings.OpenToCategory(category:GetID());
    Settings.OpenToCategory(category:GetID());
end
