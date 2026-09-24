--[[
ForeverLoot's own settings window (Theme, Font, Status Bar Texture, Group
Loot options) - opened via /fl config (or /fl c), or the button on the
Blizzard-side options panel (see OptionsPanel.lua, still reachable from the
Escape menu). Everything here used to live directly on that Blizzard canvas
category; it moved into its own window so it can use the addon's own theme
chrome instead of stock Blizzard panel styling.
]]

local FL = ForeverLoot;
local ConfigWindow = FL.UI.ConfigWindow;
local LSM = LibStub("LibSharedMedia-3.0");

local WINDOW_WIDTH = 460;
local WINDOW_HEIGHT = 420;
local HEADER_HEIGHT = 50;

-- Height (in UI units) of the actual-texture preview drawn on each entry of
-- the Status Bar Texture dropdown - see InitDropdown's "statusbar" branch.
local STATUSBAR_PREVIEW_HEIGHT = 14;

-- Key this window's saved position is stored under (see Settings.GetWindowPosition/SetWindowPosition).
local POSITION_KEY = "configWindow";

local frame;

-- For "statusbar", each dropdown entry renders the actual SharedMedia
-- texture (stretched to the entry's full width via iconOnly + iconInfo's
-- tFitDropDownSizeX - the same mechanism UIDropDownMenu_AddSeparator uses
-- for its full-width divider line) with the texture's name drawn over it,
-- instead of a plain text-only entry - the same "see before you pick" look
-- LibSharedMedia texture pickers use elsewhere. info.minWidth matches this
-- dropdown's own SetWidth below: iconOnly entries are otherwise sized off
-- their (tiny, pre-stretch) icon width, which would starve every other
-- entry's width too since every entry here is iconOnly.
local function InitDropdown(dropdown, mediaType, getter, setter)
    local isStatusBar = (mediaType == "statusbar");

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

            if (isStatusBar) then
                info.icon = LSM:Fetch(mediaType, key);
                info.iconOnly = true;
                info.notCheckable = true;
                info.minWidth = 200;
                info.fontObject = _G[FL.Theme.fonts.highlightSmall];
                info.iconInfo = { tSizeY = STATUSBAR_PREVIEW_HEIGHT, tFitDropDownSizeX = true };
            end

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

local themeDropdown, fontDropdown, barDropdown;
local groupLootCheckbox, groupLootLockCheckbox;
local resetPositionsHolder, resetPositionsButton;

-- Built when the panel is first shown rather than at file load, because
-- which button template it uses depends on the theme, which isn't known
-- until login. The holder frame keeps its place in the layout in the
-- meantime.
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

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);
    frame = FL.Theme.CreateWindow("ForeverLootConfigWindow", WINDOW_WIDTH, WINDOW_HEIGHT,
        savedPosition and savedPosition.x or 0, savedPosition and savedPosition.y or 0,
        function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    frame:Hide();

    local title = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.title);
    title:SetPoint("TOP", 0, -10);
    title:SetText("ForeverLoot - Settings");

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton");
    closeButton:SetSize(20, 20);
    closeButton:SetPoint("TOPRIGHT", -4, -4);
    closeButton:SetScript("OnClick", function() frame:Hide(); end);
    FL.Theme.SkinCloseButton(closeButton);

    local themeLabel = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.normal);
    themeLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -HEADER_HEIGHT);
    themeLabel:SetText("Theme");

    themeDropdown = CreateFrame("Frame", "ForeverLootConfigWindowThemeDropDown", frame, "UIDropDownMenuTemplate");
    themeDropdown:SetPoint("TOPLEFT", themeLabel, "BOTTOMLEFT", -16, -4);
    UIDropDownMenu_SetWidth(themeDropdown, 200);
    themeDropdownText(themeDropdown);
    InitThemeDropdown(themeDropdown);

    local fontLabel = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.normal);
    fontLabel:SetPoint("TOPLEFT", themeDropdown, "BOTTOMLEFT", 16, -24);
    fontLabel:SetText("Font");

    fontDropdown = CreateFrame("Frame", "ForeverLootConfigWindowFontDropDown", frame, "UIDropDownMenuTemplate");
    fontDropdown:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", -16, -4);
    UIDropDownMenu_SetWidth(fontDropdown, 200);
    themeDropdownText(fontDropdown);
    InitDropdown(fontDropdown, "font", FL.Settings.GetFont, FL.Settings.SetFont);

    local barLabel = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.normal);
    barLabel:SetPoint("TOPLEFT", fontDropdown, "BOTTOMLEFT", 16, -24);
    barLabel:SetText("Status Bar Texture");

    barDropdown = CreateFrame("Frame", "ForeverLootConfigWindowStatusBarDropDown", frame, "UIDropDownMenuTemplate");
    barDropdown:SetPoint("TOPLEFT", barLabel, "BOTTOMLEFT", -16, -4);
    UIDropDownMenu_SetWidth(barDropdown, 200);
    themeDropdownText(barDropdown);
    InitDropdown(barDropdown, "statusbar", FL.Settings.GetStatusBarTexture, FL.Settings.SetStatusBarTexture);

    resetPositionsHolder = CreateFrame("Frame", nil, frame);
    resetPositionsHolder:SetSize(180, 22);
    resetPositionsHolder:SetPoint("TOPLEFT", barDropdown, "BOTTOMLEFT", 16, -24);

    -- Structural toggle (suppresses/registers Blizzard's native
    -- GroupLootFrames and our own roll events at login) - takes effect on
    -- the next /reload rather than live, same as every other addon setting
    -- that's read once at Init() time.
    groupLootCheckbox = CreateFrame("CheckButton", "ForeverLootConfigWindowGroupLootCheckbox", frame, "InterfaceOptionsCheckButtonTemplate");
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

    -- Purely visual, unlike groupLootCheckbox above - takes effect
    -- immediately rather than requiring a /reload.
    groupLootLockCheckbox = CreateFrame("CheckButton", "ForeverLootConfigWindowGroupLootLockCheckbox", frame, "InterfaceOptionsCheckButtonTemplate");
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

    frame:SetScript("OnShow", ConfigWindow.Refresh);
end

function ConfigWindow.Refresh()
    if (not frame) then return; end

    ensureResetPositionsButton();
    if (not (FL.DB and FL.DB.settings)) then return; end

    UIDropDownMenu_SetText(themeDropdown, FL.Theme.THEMES[FL.Settings.GetTheme()]);
    UIDropDownMenu_SetText(fontDropdown, FL.DB.settings.font);
    UIDropDownMenu_SetText(barDropdown, FL.DB.settings.statusbar);
    groupLootCheckbox:SetChecked(FL.Settings.GetGroupLootRollEnabled());
    groupLootLockCheckbox:SetChecked(FL.Settings.GetGroupLootRollLocked());
end

function ConfigWindow.Show()
    ensureFrame();
    frame:Show();
    ConfigWindow.Refresh();
end

function ConfigWindow.Hide()
    if (frame) then frame:Hide(); end
end

function ConfigWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then ConfigWindow.Hide(); else ConfigWindow.Show(); end
end

function ConfigWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then FL.Theme.ResetWindowPosition(frame); end
end
