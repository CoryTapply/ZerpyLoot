--[[
Thin Blizzard-side entry point (Escape menu > Options > AddOns), registered
as a canvas category through the Settings API. A big centered name/version
splash with one button - the actual settings (Theme, Font, Status Bar
Texture, Group Loot options) live in ForeverLoot's own window, see
ConfigWindow.lua, opened here or via /fl config (/fl c).
]]

local FL = ForeverLoot;

local panel = CreateFrame("Frame", "ForeverLootOptionsPanel", UIParent);
panel.name = FL.name;

local ADDON_VERSION = C_AddOns.GetAddOnMetadata(FL.name, "Version") or "?";

local hero = panel:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.hero);
hero:SetPoint("CENTER", panel, "CENTER", 0, 70);
hero:SetText(FL.name);

local versionText = panel:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.normal);
versionText:SetPoint("TOP", hero, "BOTTOM", 0, -20);
versionText:SetText(("Version: %s"):format(ADDON_VERSION));

local instructions = panel:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlight);
instructions:SetPoint("TOP", versionText, "BOTTOM", 0, -14);
instructions:SetText("Access settings with /fl config");

-- Built when the panel is first shown rather than at load, because which
-- button template it uses depends on the theme, which isn't known until
-- login.
local openButtonHolder = CreateFrame("Frame", nil, panel);
openButtonHolder:SetSize(260, 32);
openButtonHolder:SetPoint("TOP", instructions, "BOTTOM", 0, -24);

local openButton;
local function ensureOpenButton()
    if (openButton) then return; end

    openButton = FL.Theme.CreateButton(openButtonHolder);
    openButton:SetAllPoints(openButtonHolder);
    openButton:SetText("Open Settings");
    openButton:SetScript("OnClick", function()
        if (FL.UI.ConfigWindow and FL.UI.ConfigWindow.Show) then
            FL.UI.ConfigWindow.Show();
        end
    end);
    -- Accent fill (same treatment as e.g. "Start Roll") so this one button
    -- reads as the panel's single call to action.
    FL.Theme.SkinAccentButton(openButton);
end

panel.refresh = function()
    ensureOpenButton();
end
panel:SetScript("OnShow", panel.refresh);

local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name);
Settings.RegisterAddOnCategory(category);

FL.UI.OptionsPanel.frame = panel;

function FL.UI.OptionsPanel.Open()
    Settings.OpenToCategory(category:GetID());
    Settings.OpenToCategory(category:GetID());
end
