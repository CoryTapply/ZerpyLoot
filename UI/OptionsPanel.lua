--[[
Settings panel (Theme, Font, Status Bar Texture, Group Loot options), registered as a
canvas category through the Settings API.
]]

local FL = ForeverLoot;
local LSM = LibStub("LibSharedMedia-3.0");

local function InitDropdown(dropdown, mediaType, getter, setter)
    UIDropDownMenu_Initialize(dropdown, function(_, level)
        for _, key in ipairs(LSM:List(mediaType)) do
            local info = UIDropDownMenu_CreateInfo();
            info.text = key;
            info.checked = (getter() == key);
            info.func = function()
                setter(key);
                UIDropDownMenu_SetText(dropdown, key);
                CloseDropDownMenus();
            end;
            UIDropDownMenu_AddButton(info, level);
        end
    end);
end

-- UIDropDownMenuTemplate / InterfaceOptionsCheckButtonTemplate ship their own
-- Blizzard font objects; point their labels at this addon's outlined ones.
local function themeDropdownText(dropdown)
    local text = _G[dropdown:GetName() .. "Text"];
    if (text) then text:SetFontObject(_G[FL.Theme.fonts.highlightSmall]); end
end

-- The theme is locked in at login (see Theme.Init), so picking a different
-- one only takes effect after a /reload.
StaticPopupDialogs["FOREVERLOOT_RELOAD_THEME"] = {
    text = "ForeverLoot's theme changes take effect after reloading your UI. Reload now?",
    button1 = "Reload UI",
    button2 = "Later",
    OnAccept = function() ReloadUI(); end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
};

local function InitThemeDropdown(dropdown)
    UIDropDownMenu_Initialize(dropdown, function(_, level)
        for _, key in ipairs(FL.Theme.THEME_ORDER) do
            local info = UIDropDownMenu_CreateInfo();
            info.text = FL.Theme.THEMES[key];
            info.checked = (FL.Settings.GetTheme() == key);
            info.func = function()
                FL.Settings.SetTheme(key);
                UIDropDownMenu_SetText(dropdown, FL.Theme.THEMES[key]);
                CloseDropDownMenus();
                if (key ~= FL.Theme.current) then
                    StaticPopup_Show("FOREVERLOOT_RELOAD_THEME");
                end
            end;
            UIDropDownMenu_AddButton(info, level);
        end
    end);
end

local panel = CreateFrame("Frame", "ForeverLootOptionsPanel", UIParent);
panel.name = FL.name;

local title = panel:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.titleLarge);
title:SetPoint("TOPLEFT", 16, -16);
title:SetText(FL.name);

local themeLabel = panel:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.normal);
themeLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -24);
themeLabel:SetText("Theme");

local themeDropdown = CreateFrame("Frame", "ForeverLootOptionsPanelThemeDropDown", panel, "UIDropDownMenuTemplate");
themeDropdown:SetPoint("TOPLEFT", themeLabel, "BOTTOMLEFT", -16, -4);
UIDropDownMenu_SetWidth(themeDropdown, 200);
themeDropdownText(themeDropdown);
InitThemeDropdown(themeDropdown);

local fontLabel = panel:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.normal);
fontLabel:SetPoint("TOPLEFT", themeDropdown, "BOTTOMLEFT", 16, -24);
fontLabel:SetText("Font");

local fontDropdown = CreateFrame("Frame", "ForeverLootOptionsPanelFontDropDown", panel, "UIDropDownMenuTemplate");
fontDropdown:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", -16, -4);
UIDropDownMenu_SetWidth(fontDropdown, 200);
themeDropdownText(fontDropdown);
InitDropdown(fontDropdown, "font", FL.Settings.GetFont, FL.Settings.SetFont);

local barLabel = panel:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.normal);
barLabel:SetPoint("TOPLEFT", fontDropdown, "BOTTOMLEFT", 16, -24);
barLabel:SetText("Status Bar Texture");

local barDropdown = CreateFrame("Frame", "ForeverLootOptionsPanelStatusBarDropDown", panel, "UIDropDownMenuTemplate");
barDropdown:SetPoint("TOPLEFT", barLabel, "BOTTOMLEFT", -16, -4);
UIDropDownMenu_SetWidth(barDropdown, 200);
themeDropdownText(barDropdown);
InitDropdown(barDropdown, "statusbar", FL.Settings.GetStatusBarTexture, FL.Settings.SetStatusBarTexture);

-- Same reset used by /zl resetpositions (see Debug.lua), exposed here too
-- so it doesn't only live behind a slash command.
-- Built when the panel is first shown rather than at load, because which
-- button template it uses depends on the theme, which isn't known until login.
-- The holder frame keeps its place in the layout in the meantime.
local resetPositionsHolder = CreateFrame("Frame", nil, panel);
resetPositionsHolder:SetSize(180, 22);
resetPositionsHolder:SetPoint("TOPLEFT", barDropdown, "BOTTOMLEFT", 16, -24);

local resetPositionsButton;
local function ensureResetPositionsButton()
    if (resetPositionsButton) then return; end

    resetPositionsButton = FL.Theme.CreateButton(resetPositionsHolder);
    resetPositionsButton:SetAllPoints(resetPositionsHolder);
    resetPositionsButton:SetText("Reset Window Positions");
    resetPositionsButton:SetScript("OnClick", function()
        if (FL.ResetAllWindowPositions) then
            FL.ResetAllWindowPositions();
            print("|cff8865ffForeverLoot|r window positions reset to default.");
        end
    end);
    FL.Theme.SkinButton(resetPositionsButton);
end

-- Structural toggle (suppresses/registers Blizzard's native GroupLootFrames
-- and our own roll events at login) - takes effect on the next /reload
-- rather than live, same as every other addon setting that's read once at
-- Init() time.
local groupLootCheckbox = CreateFrame("CheckButton", "ForeverLootOptionsPanelGroupLootCheckbox", panel, "InterfaceOptionsCheckButtonTemplate");
groupLootCheckbox:SetPoint("TOPLEFT", resetPositionsHolder, "BOTTOMLEFT", 0, -24);
_G[groupLootCheckbox:GetName() .. "Text"]:SetFontObject(_G[FL.Theme.fonts.highlight]);
_G[groupLootCheckbox:GetName() .. "Text"]:SetText("Replace default Group Loot popup (Need/Greed/Pass)");
groupLootCheckbox:SetScript("OnClick", function(self)
    FL.Settings.SetGroupLootRollEnabled(self:GetChecked());
end);
groupLootCheckbox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
    -- AddLine rather than SetText: SetText's (text, r, g, b, wrap) form became
    -- (text, color, alpha, wrap) on Midnight-based clients.
    GameTooltip:AddLine("Requires /reload to take effect.", 1, 1, 1, true);
    GameTooltip:Show();
end);
groupLootCheckbox:SetScript("OnLeave", function() GameTooltip:Hide(); end);

-- Purely visual, unlike groupLootCheckbox above - takes effect immediately
-- rather than requiring a /reload.
local groupLootLockCheckbox = CreateFrame("CheckButton", "ForeverLootOptionsPanelGroupLootLockCheckbox", panel, "InterfaceOptionsCheckButtonTemplate");
groupLootLockCheckbox:SetPoint("TOPLEFT", groupLootCheckbox, "BOTTOMLEFT", 0, -8);
_G[groupLootLockCheckbox:GetName() .. "Text"]:SetFontObject(_G[FL.Theme.fonts.highlight]);
_G[groupLootLockCheckbox:GetName() .. "Text"]:SetText("Lock Group Loot rolls (hide header)");
groupLootLockCheckbox:SetScript("OnClick", function(self)
    FL.Settings.SetGroupLootRollLocked(self:GetChecked());
    if (FL.UI.GroupLootRollBars) then FL.UI.GroupLootRollBars.RefreshLock(); end
end);
groupLootLockCheckbox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
    GameTooltip:AddLine("Hides the draggable \"Group Loot\" header once you've positioned it.", 1, 1, 1, true);
    GameTooltip:Show();
end);
groupLootLockCheckbox:SetScript("OnLeave", function() GameTooltip:Hide(); end);

panel.refresh = function()
    ensureResetPositionsButton();
    if (not (FL.DB and FL.DB.settings)) then return; end
    UIDropDownMenu_SetText(themeDropdown, FL.Theme.THEMES[FL.Settings.GetTheme()]);
    UIDropDownMenu_SetText(fontDropdown, FL.DB.settings.font);
    UIDropDownMenu_SetText(barDropdown, FL.DB.settings.statusbar);
    groupLootCheckbox:SetChecked(FL.Settings.GetGroupLootRollEnabled());
    groupLootLockCheckbox:SetChecked(FL.Settings.GetGroupLootRollLocked());
end
panel:SetScript("OnShow", panel.refresh);

local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name);
Settings.RegisterAddOnCategory(category);

FL.UI.OptionsPanel.frame = panel;

function FL.UI.OptionsPanel.Open()
    Settings.OpenToCategory(category:GetID());
    Settings.OpenToCategory(category:GetID());
end
