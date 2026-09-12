--[[
Interface Options panel (Font, Status Bar Texture). Which registration API
actually exists has been a moving target on TBC Classic - some client
builds only have the old InterfaceOptions_AddCategory, others have picked
up the newer Settings.RegisterCanvasLayoutCategory/RegisterAddOnCategory
pair (retail-style). Both are feature-detected here so the panel registers
either way instead of silently no-opping on whichever isn't present.
]]

local ZL = ZerpyLoot;
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

local panel = CreateFrame("Frame", "ZerpyLootOptionsPanel", UIParent);
panel.name = ZL.name;

local title = panel:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.titleLarge);
title:SetPoint("TOPLEFT", 16, -16);
title:SetText(ZL.name);

local fontLabel = panel:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.normal);
fontLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -24);
fontLabel:SetText("Font");

local fontDropdown = CreateFrame("Frame", "ZerpyLootOptionsPanelFontDropDown", panel, "UIDropDownMenuTemplate");
fontDropdown:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", -16, -4);
UIDropDownMenu_SetWidth(fontDropdown, 200);
InitDropdown(fontDropdown, "font", ZL.Settings.GetFont, ZL.Settings.SetFont);

local barLabel = panel:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.normal);
barLabel:SetPoint("TOPLEFT", fontDropdown, "BOTTOMLEFT", 16, -24);
barLabel:SetText("Status Bar Texture");

local barDropdown = CreateFrame("Frame", "ZerpyLootOptionsPanelStatusBarDropDown", panel, "UIDropDownMenuTemplate");
barDropdown:SetPoint("TOPLEFT", barLabel, "BOTTOMLEFT", -16, -4);
UIDropDownMenu_SetWidth(barDropdown, 200);
InitDropdown(barDropdown, "statusbar", ZL.Settings.GetStatusBarTexture, ZL.Settings.SetStatusBarTexture);

-- Same reset used by /zl resetpositions (see Debug.lua), exposed here too
-- so it doesn't only live behind a slash command.
local resetPositionsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate");
resetPositionsButton:SetSize(180, 22);
resetPositionsButton:SetPoint("TOPLEFT", barDropdown, "BOTTOMLEFT", 16, -24);
resetPositionsButton:SetText("Reset Window Positions");
resetPositionsButton:SetScript("OnClick", function()
    if (ZL.ResetAllWindowPositions) then
        ZL.ResetAllWindowPositions();
        print("|cff8865ffZerpyLoot|r window positions reset to default.");
    end
end);
ZL.Theme.SkinButton(resetPositionsButton);

-- Structural toggle (suppresses/registers Blizzard's native GroupLootFrames
-- and our own roll events at login) - takes effect on the next /reload
-- rather than live, same as every other addon setting that's read once at
-- Init() time.
local groupLootCheckbox = CreateFrame("CheckButton", "ZerpyLootOptionsPanelGroupLootCheckbox", panel, "InterfaceOptionsCheckButtonTemplate");
groupLootCheckbox:SetPoint("TOPLEFT", resetPositionsButton, "BOTTOMLEFT", 0, -24);
_G[groupLootCheckbox:GetName() .. "Text"]:SetText("Replace default Group Loot popup (Need/Greed/Pass)");
groupLootCheckbox:SetScript("OnClick", function(self)
    ZL.Settings.SetGroupLootRollEnabled(self:GetChecked());
end);
groupLootCheckbox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
    GameTooltip:SetText("Requires /reload to take effect.", 1, 1, 1, true);
    GameTooltip:Show();
end);
groupLootCheckbox:SetScript("OnLeave", function() GameTooltip:Hide(); end);

-- Purely visual, unlike groupLootCheckbox above - takes effect immediately
-- rather than requiring a /reload.
local groupLootLockCheckbox = CreateFrame("CheckButton", "ZerpyLootOptionsPanelGroupLootLockCheckbox", panel, "InterfaceOptionsCheckButtonTemplate");
groupLootLockCheckbox:SetPoint("TOPLEFT", groupLootCheckbox, "BOTTOMLEFT", 0, -8);
_G[groupLootLockCheckbox:GetName() .. "Text"]:SetText("Lock Group Loot rolls (hide header)");
groupLootLockCheckbox:SetScript("OnClick", function(self)
    ZL.Settings.SetGroupLootRollLocked(self:GetChecked());
    if (ZL.UI.GroupLootRollBars) then ZL.UI.GroupLootRollBars.RefreshLock(); end
end);
groupLootLockCheckbox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
    GameTooltip:SetText("Hides the draggable \"Group Loot\" header once you've positioned it.", 1, 1, 1, true);
    GameTooltip:Show();
end);
groupLootLockCheckbox:SetScript("OnLeave", function() GameTooltip:Hide(); end);

panel.refresh = function()
    if (not (ZL.DB and ZL.DB.settings)) then return; end
    UIDropDownMenu_SetText(fontDropdown, ZL.DB.settings.font);
    UIDropDownMenu_SetText(barDropdown, ZL.DB.settings.statusbar);
    groupLootCheckbox:SetChecked(ZL.Settings.GetGroupLootRollEnabled());
    groupLootLockCheckbox:SetChecked(ZL.Settings.GetGroupLootRollLocked());
end
panel:SetScript("OnShow", panel.refresh);

local category;
if (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
    category = Settings.RegisterCanvasLayoutCategory(panel, panel.name);
    Settings.RegisterAddOnCategory(category);
elseif (InterfaceOptions_AddCategory) then
    InterfaceOptions_AddCategory(panel);
else
    print("|cff8865ffZerpyLoot|r couldn't find an Interface Options registration API on this client - use /zl options to open the panel directly instead.");
end

ZL.UI.OptionsPanel.frame = panel;

function ZL.UI.OptionsPanel.Open()
    if (category and Settings and Settings.OpenToCategory) then
        Settings.OpenToCategory(category:GetID());
        Settings.OpenToCategory(category:GetID());
    elseif (InterfaceOptionsFrame_OpenToCategory) then
        -- Blizzard's own long-standing quirk: the first call sometimes
        -- doesn't select the category if Interface Options hasn't been
        -- opened yet this session, so it's called twice.
        InterfaceOptionsFrame_OpenToCategory(panel);
        InterfaceOptionsFrame_OpenToCategory(panel);
    else
        panel:Show();
    end
end
