--[[
Native minimap button (no library dependencies) - Position is stored as an angle around the minimap
in FL.DB.settings.minimap.angle; visibility is the General settings page's
"Enable minimap button" checkbox (FL.Settings.Get/SetMinimapButtonEnabled,
on by default).
]]

local FL = ForeverLoot;
local MinimapButton = FL.UI.MinimapButton;

local ICON_PATH = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\ForeverLootCrown64.tga";
local BUTTON_SIZE = 32;
local DEFAULT_ANGLE = 200;

local btn;
local isDragging = false;

local function getDB()
    return FL.DB.settings.minimap;
end

local function updatePosition()
    if (not btn) then return; end
    local angle = math.rad(getDB().angle or DEFAULT_ANGLE);
    local radius = (math.max(Minimap:GetWidth(), Minimap:GetHeight()) / 2) + 5;
    btn:ClearAllPoints();
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius);
end

-- Persistent OnUpdate handler for drag (avoids creating a closure per drag)
local function dragOnUpdate()
    local mx, my = Minimap:GetCenter();
    local cx, cy = GetCursorPosition();
    local scale = Minimap:GetEffectiveScale();
    cx, cy = cx / scale, cy / scale;
    getDB().angle = math.deg(math.atan2(cy - my, cx - mx));
    updatePosition();
end

local function create()
    btn = CreateFrame("Button", "ForeverLootMinimapButton", Minimap);
    btn:SetSize(BUTTON_SIZE, BUTTON_SIZE);
    btn:SetFrameStrata("MEDIUM");
    btn:SetFrameLevel(8);
    btn:SetClampedToScreen(true);
    btn:SetMovable(true);
    btn:RegisterForClicks("AnyUp");
    btn:RegisterForDrag("LeftButton");

    -- Black circle behind the icon
    local bg = btn:CreateTexture(nil, "BACKGROUND");
    bg:SetSize(25, 25);
    bg:SetPoint("CENTER", 0, 0);
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background");
    bg:SetVertexColor(0, 0, 0, 1);

    local icon = btn:CreateTexture(nil, "ARTWORK");
    icon:SetSize(17, 17);
    icon:SetPoint("CENTER", 0, 0);
    icon:SetTexture(ICON_PATH);

    -- Standard minimap button border ring
    local overlay = btn:CreateTexture(nil, "OVERLAY");
    overlay:SetSize(53, 53);
    overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0);
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder");

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight");

    btn:SetScript("OnClick", function(_, button)
        if (button == "LeftButton") then
            if (FL.UI.SettingsWindow and FL.UI.SettingsWindow.Show) then
                FL.UI.SettingsWindow.Show();
            end
        elseif (button == "RightButton") then
            if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Toggle) then
                FL.UI.LootHistoryWindow.Toggle();
            end
        elseif (button == "MiddleButton") then
            GameTooltip:Hide();
            FL.Settings.SetMinimapButtonEnabled(false);
            -- Keep the General page's checkbox in sync if the window is open.
            FL.UI.SettingsWindow.Refresh();
            print("|cff8865ffForeverLoot|r minimap button hidden - re-enable it in /fl config > General.");
        end
    end);

    btn:SetScript("OnDragStart", function(self)
        if (InCombatLockdown()) then return; end
        isDragging = true;
        self:LockHighlight();
        self:SetScript("OnUpdate", dragOnUpdate);
        GameTooltip:Hide();
    end);

    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil);
        self:UnlockHighlight();
        isDragging = false;
        updatePosition();
    end);

    btn:SetScript("OnEnter", function(self)
        if (isDragging) then return; end
        GameTooltip:SetOwner(self, "ANCHOR_NONE");
        GameTooltip:SetPoint("TOPRIGHT", self, "TOPLEFT", -2, 0);
        GameTooltip:AddLine("|cff8865ffForeverLoot|r");
        GameTooltip:AddLine("|cff8865ffLeft-click:|r |cffE0E0E0Open settings|r");
        GameTooltip:AddLine("|cff8865ffRight-click:|r |cffE0E0E0Loot history|r");
        GameTooltip:AddLine("|cff8865ffMiddle-click:|r |cffE0E0E0Hide minimap button|r");
        GameTooltip:Show();
    end);
    btn:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    updatePosition();
end

-- Settings.Init (earlier in the PLAYER_LOGIN module list) has already
-- seeded FL.DB.settings.minimap. The button is only created the first time
-- it's actually enabled, so a disabled button costs nothing.
function MinimapButton.Init()
    MinimapButton.ApplyShown();
end

-- Called by FL.Settings.SetMinimapButtonEnabled.
function MinimapButton.ApplyShown()
    local shown = FL.Settings.GetMinimapButtonEnabled();
    if (shown and not btn) then create(); end
    if (btn) then btn:SetShown(shown); end
end

-- /fl minimap
function MinimapButton.ToggleShown()
    local shown = not FL.Settings.GetMinimapButtonEnabled();
    FL.Settings.SetMinimapButtonEnabled(shown);
    FL.UI.SettingsWindow.Refresh();
    return shown;
end
