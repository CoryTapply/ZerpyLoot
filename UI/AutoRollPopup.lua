--[[
The raid-entry popup for Automatic Rolls: shown (per FL.AutoRoll's own
policy - this file is presentation-only) when mode is "ask" and this raid
hasn't been answered yet, or on demand via /fl autoroll. A 2x2 grid of
Need/Greed/Pass/Manual choice buttons that only ever writes a per-instance
session choice (db.autoRoll.sessionChoices) - it never touches
db.autoRoll.mode.

Built with the settings window's own control vocabulary (UI.Colors/
UI.Sizes.autoRollPopup/UI.SetFont/UI.Skin), same as UI/GroupLootFrame.lua -
this window has exactly one look, it doesn't follow the active skin.
]]

local FL = ForeverLoot;
local AutoRollPopup = FL.UI.AutoRollPopup;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.autoRollPopup;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Widgets = FL.UI.SettingsWidgets;
local Theme = FL.Theme;

-- Same asset/technique as UI/GroupLootFrame.lua's skinPanel and
-- UI/RespondWindow.lua's CreateCard - a SoftGlow.tga drop shadow tinted
-- black, no shared helper exists yet to call instead.
local SOFTGLOW_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\SoftGlow";

-- Order here is the 2x2 grid's reading order (top-left, top-right,
-- bottom-left, bottom-right). No subline text was given in the spec beyond
-- each button's one-line title, so only the title is rendered.
local CHOICES = {
    { value = "need",   title = "Need on everything",  colorKey = "need" },
    { value = "greed",  title = "Greed on everything",  colorKey = "greed" },
    { value = "pass",   title = "Pass on everything",   colorKey = "pass" },
    { value = "manual", title = "I'll roll myself",     colorKey = "manual" },
};

local frame, instanceTitle, subtitleText, closeButton;
local gridButtons = {};
local noteText, footerText, viewOverridesButton;

local function closeAsManual()
    local instanceID = select(8, GetInstanceInfo());
    local instanceName = GetInstanceInfo();
    FL.Settings.SetAutoRollSessionChoice(instanceID, "manual");
    AutoRollPopup.Hide();
    FL.AutoRoll.PrintSessionChoiceMessage("manual", instanceName);
end

local function createGridButton(choice)
    local accent = Colors.autoRollPopupAccent[choice.colorKey] or Colors.muted;

    local button = CreateFrame("Button", nil, frame, "BackdropTemplate");
    button:SetHeight(Sizes.buttonHeight);
    Theme.Helpers.SetFlatBackdrop(button, Colors.defaultBg, Colors.autoRollPopupButtonBorder, 1);

    local accentBar = button:CreateTexture(nil, "ARTWORK");
    accentBar:SetColorTexture(unpack(accent));
    accentBar:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0);
    accentBar:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0);
    accentBar:SetWidth(Sizes.accentBarWidth);

    local title = button:CreateFontString(nil, "OVERLAY");
    SetFont(title, "body");
    title:SetPoint("LEFT", button, "LEFT", Sizes.accentBarWidth + 8, 0);
    title:SetPoint("RIGHT", button, "RIGHT", -6, 0);
    title:SetJustifyH("LEFT");
    title:SetWordWrap(false);
    title:SetText(choice.title);
    title:SetTextColor(unpack(accent));

    button:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(accent)); end);
    button:HookScript("OnLeave", function(self)
        if (self.zlSelected) then return; end
        self:SetBackdropBorderColor(unpack(Colors.autoRollPopupButtonBorder));
    end);

    button:SetScript("OnClick", function()
        if (choice.value == "manual") then
            closeAsManual();
            return;
        end
        local instanceID = select(8, GetInstanceInfo());
        local instanceName = GetInstanceInfo();
        FL.Settings.SetAutoRollSessionChoice(instanceID, choice.value);
        AutoRollPopup.Hide();
        FL.AutoRoll.PrintSessionChoiceMessage(choice.value, instanceName);
    end);

    button.zlAccent = accent;
    button.zlTitle = title;
    return button;
end

local function ensureFrame()
    if (frame) then return; end

    frame = CreateFrame("Frame", "ForeverLootAutoRollPopup", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    frame:SetWidth(Sizes.width);
    -- Centered in the upper third of the screen - re-centers on every Show()
    -- (see the "no position persistence" decision below), so this is always
    -- computed fresh rather than a fixed literal.
    frame:SetPoint("TOP", UIParent, "TOP", 0, -(UIParent:GetHeight() / 3));

    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.controlFocus, 1);

    local shadow = frame:CreateTexture(nil, "BACKGROUND", nil, -1);
    shadow:SetTexture(SOFTGLOW_TEXTURE);
    shadow:SetVertexColor(unpack(Colors.groupLootShadow));
    shadow:SetPoint("TOPLEFT", frame, "TOPLEFT", -Sizes.shadowInset, Sizes.shadowInset);
    shadow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", Sizes.shadowInset, -Sizes.shadowInset);

    ----------------------------------------------------------------------
    -- Title row: instance name + subtitle, draggable, with a close X.
    ----------------------------------------------------------------------

    local titleRow = CreateFrame("Frame", nil, frame);
    titleRow:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.padding, -Sizes.padding);
    titleRow:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.padding, -Sizes.padding);
    titleRow:EnableMouse(true);
    titleRow:RegisterForDrag("LeftButton");
    titleRow:SetScript("OnDragStart", function() frame:StartMoving(); end);
    titleRow:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); end);

    closeButton = CreateFrame("Button", nil, titleRow, "BackdropTemplate");
    closeButton:SetPoint("TOPRIGHT", titleRow, "TOPRIGHT", 0, 0);
    Skin.CloseButton(closeButton);
    closeButton:SetScript("OnClick", closeAsManual);
    closeButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT");
        GameTooltip:AddLine("Close (roll manually)", 1, 1, 1, true);
        GameTooltip:Show();
    end);
    closeButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);

    instanceTitle = titleRow:CreateFontString(nil, "OVERLAY");
    SetFont(instanceTitle, "sectionHeader");
    instanceTitle:SetPoint("TOPLEFT", titleRow, "TOPLEFT", 0, 0);
    instanceTitle:SetPoint("RIGHT", closeButton, "LEFT", -8, 0);
    instanceTitle:SetJustifyH("LEFT");
    instanceTitle:SetWordWrap(false);
    instanceTitle:SetTextColor(unpack(Colors.gold));

    subtitleText = titleRow:CreateFontString(nil, "OVERLAY");
    SetFont(subtitleText, "small");
    subtitleText:SetPoint("TOPLEFT", instanceTitle, "BOTTOMLEFT", 0, -4);
    subtitleText:SetPoint("RIGHT", titleRow, "RIGHT", 0, 0);
    subtitleText:SetJustifyH("LEFT");
    subtitleText:SetWordWrap(true);
    subtitleText:SetText("How should ForeverLoot roll on loot in this raid?");
    subtitleText:SetTextColor(unpack(Colors.description));

    titleRow:SetHeight(math.max(closeButton:GetHeight(), instanceTitle:GetStringHeight() + 4 + 22 + subtitleText:GetStringHeight()));

    ----------------------------------------------------------------------
    -- 2x2 choice grid.
    ----------------------------------------------------------------------

    local gridWidth = Sizes.width - Sizes.padding * 2;
    local colWidth = math.floor((gridWidth - Sizes.gridGap) / 2);

    for i, choice in ipairs(CHOICES) do
        local button = createGridButton(choice);
        button:SetWidth(colWidth);
        local col = (i - 1) % 2;
        local row = math.floor((i - 1) / 2);
        button:SetPoint("TOPLEFT", titleRow, "BOTTOMLEFT",
            col * (colWidth + Sizes.gridGap), -(Sizes.gap + row * (Sizes.buttonHeight + Sizes.gridGap)));
        gridButtons[choice.value] = button;
    end

    local gridBottom = titleRow;
    local gridHeight = Sizes.gap + 2 * Sizes.buttonHeight + Sizes.gridGap;

    ----------------------------------------------------------------------
    -- Note line.
    ----------------------------------------------------------------------

    noteText = frame:CreateFontString(nil, "OVERLAY");
    SetFont(noteText, "small");
    noteText:SetPoint("TOPLEFT", gridBottom, "BOTTOMLEFT", 0, -(gridHeight + Sizes.gap));
    noteText:SetPoint("RIGHT", frame, "RIGHT", -Sizes.padding, 0);
    noteText:SetJustifyH("LEFT");
    noteText:SetWordWrap(true);
    noteText:SetTextColor(unpack(Colors.muted));
    -- "/fl autoroll" highlighted brighter within the muted note, same
    -- multi-color-fontstring technique used elsewhere in this addon.
    noteText:SetText(("Reopen this anytime with |cff%s/fl autoroll|r, or change the default in Settings \226\134\146 Loot Rolls."):format(
        ("%02x%02x%02x"):format(Colors.text[1] * 255, Colors.text[2] * 255, Colors.text[3] * 255)));

    ----------------------------------------------------------------------
    -- Footer: divider, "Your item overrides still apply." + View Overrides.
    ----------------------------------------------------------------------

    local footerDivider = frame:CreateTexture(nil, "ARTWORK");
    footerDivider:SetColorTexture(unpack(Colors.divider));
    footerDivider:SetPoint("TOPLEFT", noteText, "BOTTOMLEFT", 0, -Sizes.gap);
    footerDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.padding, 0);
    footerDivider:SetHeight(FL.Pixel.PixelSize(Sizes.footerDividerHeight));

    viewOverridesButton = Widgets.CreateFlatButton(frame, "View Overrides", "default");
    viewOverridesButton:SetSize(viewOverridesButton.text:GetStringWidth() + 24, Sizes.viewOverridesHeight);
    viewOverridesButton:SetPoint("TOPRIGHT", footerDivider, "BOTTOMRIGHT", 0, -Sizes.gap);
    viewOverridesButton:SetScript("OnClick", function()
        FL.UI.SettingsWindow.Show();
        FL.UI.SettingsRegistry.SelectPage("lootrolls");
        FL.UI.SettingsWindow.ScrollToSection("autoRoll");
        frame:Raise(); -- both DIALOG strata; keep the popup visibly on top since it must stay open
    end);

    footerText = frame:CreateFontString(nil, "OVERLAY");
    SetFont(footerText, "small");
    footerText:SetPoint("LEFT", footerDivider, "LEFT", 0, 0);
    footerText:SetPoint("RIGHT", viewOverridesButton, "LEFT", -8, 0);
    footerText:SetPoint("TOP", viewOverridesButton, "TOP", 0, 0);
    footerText:SetJustifyH("LEFT");
    footerText:SetWordWrap(false);
    footerText:SetText("Your item overrides still apply.");
    footerText:SetTextColor(unpack(Colors.muted));

    frame:SetHeight(Sizes.padding + titleRow:GetHeight() + gridHeight + Sizes.gap
        + noteText:GetStringHeight() + Sizes.gap + Sizes.footerDividerHeight + Sizes.gap
        + viewOverridesButton:GetHeight() + Sizes.padding);

    frame:EnableKeyboard(false);
    frame:SetScript("OnKeyDown", function(self, key)
        if (key == "ESCAPE") then
            self:SetPropagateKeyboardInput(false);
            closeAsManual();
        else
            self:SetPropagateKeyboardInput(true);
        end
    end);
end

--- Repaints the instance name/subtitle and which grid button (if any) shows
--- as the "current choice" - AutoRoll.GetEffectiveMode() for the automatic
--- trigger, or whatever's already highlighted for a /fl autoroll reopen
--- (same function either way; GetEffectiveMode already folds in a session
--- choice if one exists).
local function paint()
    instanceTitle:SetText(GetInstanceInfo() or "");

    local current = FL.AutoRoll.GetEffectiveMode();
    for value, button in pairs(gridButtons) do
        local isCurrent = (value == current);
        button.zlSelected = isCurrent;
        if (isCurrent) then
            Theme.Helpers.SetFlatBackdrop(button, Colors.selectedFill, button.zlAccent, 1);
        else
            Theme.Helpers.SetFlatBackdrop(button, Colors.defaultBg, Colors.autoRollPopupButtonBorder, 1);
        end
    end
end

function AutoRollPopup.Show()
    ensureFrame();
    paint();
    frame:EnableKeyboard(true);
    frame:Show();
end

--- Hides WITHOUT storing anything - used when scope is lost (leaving the
--- raid, or the RL switching off a roll loot method) while the popup is
--- open, per FL.AutoRoll's own policy.
function AutoRollPopup.Hide()
    if (not frame) then return; end
    frame:EnableKeyboard(false);
    frame:Hide();
end

function AutoRollPopup.IsShown()
    return frame and frame:IsShown() or false;
end
