--[[
The popup for Automatic Rolls: shown (per FL.AutoRoll's own policy - this
file is presentation-only) on raid entry when mode is "ask" and this raid
hasn't been answered yet, or on demand via /fl autoroll (the only way it
opens in a dungeon). A 2x2 grid of
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
-- bottom-left, bottom-right). Each button shows both `title` (accent-colored
-- heading) and `subtitle` (muted secondary line).
local CHOICES = {
    { value = "need",   title = "Need",   subtitle = "Need on everything",  colorKey = "need" },
    { value = "greed",  title = "Greed",  subtitle = "Greed on everything", colorKey = "greed" },
    { value = "pass",   title = "Pass",   subtitle = "Pass on everything",  colorKey = "pass" },
    { value = "manual", title = "Manual", subtitle = "I'll roll myself",    colorKey = "manual" },
};

local frame, instanceTitle, subtitleText, closeButton;
local gridButtons = {};
local noteText, footerText, viewOverridesButton;
-- Recomputes frame:SetHeight() from every text block's own measured height -
-- assigned inside ensureFrame() (closing over its locals), called by both
-- ensureFrame() itself and Show() (see the C_Timer.After(0) re-measure
-- below: SetWordWrap'd GetStringHeight() isn't reliably settled until a
-- frame after the text/width that drives it is set).
local resizeFrame;

local function closeAsManual()
    local instanceID = select(8, GetInstanceInfo());
    local instanceName = GetInstanceInfo();
    FL.Settings.SetAutoRollSessionChoice(instanceID, "manual");
    AutoRollPopup.Hide();
    FL.AutoRoll.PrintSessionChoiceMessage("manual", instanceName);
end

local function createGridButton(choice)
    local accent = Colors.autoRollPopupAccent[choice.colorKey] or Colors.muted;
    local titleColor = Colors.autoRollPopupTitle[choice.colorKey] or Colors.muted;

    local button = CreateFrame("Button", nil, frame, "BackdropTemplate");
    button:SetHeight(Sizes.buttonHeight);
    Theme.Helpers.SetFlatBackdrop(button, Colors.defaultBg, Colors.autoRollPopupButtonBorder, 1);

    local accentBar = button:CreateTexture(nil, "ARTWORK");
    accentBar:SetColorTexture(unpack(accent));
    accentBar:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0);
    accentBar:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0);
    accentBar:SetWidth(Sizes.accentBarWidth);

    local textLeft, textRight = Sizes.accentBarWidth + 9, -6;
    local pairGap = 1;

    local title = button:CreateFontString(nil, "OVERLAY");
    SetFont(title, "body");
    title:SetJustifyH("LEFT");
    title:SetWordWrap(false);
    title:SetText(choice.title);
    title:SetTextColor(unpack(titleColor));

    local subtitle = button:CreateFontString(nil, "OVERLAY");
    SetFont(subtitle, "helper");
    subtitle:SetJustifyH("LEFT");
    subtitle:SetWordWrap(false);
    subtitle:SetText(choice.subtitle);
    subtitle:SetTextColor(unpack(Colors.muted));

    -- Both lines are single-line/non-wrapped, so GetStringHeight() is
    -- accurate immediately after SetText - used to center the pair as a
    -- block (with a `pairGap`-px gap between them) on the button's own
    -- vertical middle, since neither line's height is a Sizes.* constant.
    local titleH, subH = title:GetStringHeight(), subtitle:GetStringHeight();
    local totalH = titleH + pairGap + subH;
    local titleCenterY = totalH / 2 - titleH / 2;
    local subCenterY = -(totalH / 2 - subH / 2);

    title:SetPoint("LEFT", button, "LEFT", textLeft, titleCenterY);
    title:SetPoint("RIGHT", button, "RIGHT", textRight, titleCenterY);
    subtitle:SetPoint("LEFT", button, "LEFT", textLeft, subCenterY);
    subtitle:SetPoint("RIGHT", button, "RIGHT", textRight, subCenterY);

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

-- Upper third of the screen, horizontally centered, with the TOPLEFT on a
-- whole physical pixel: the popup renders at the window scale (see
-- Pixel.ScaleWithWindows), so its children's integer offsets are only
-- pixel-exact if the frame itself sits on the pixel grid.
local function placeFrame()
    local scale = frame:GetScale();
    local left = FL.Pixel.Snap((UIParent:GetWidth() - frame:GetWidth() * scale) / 2);
    local top = FL.Pixel.Snap(-UIParent:GetHeight() / 3);
    frame:ClearAllPoints();
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left / scale, top / scale);
end

local function ensureFrame()
    if (frame) then return; end

    frame = CreateFrame("Frame", "ForeverLootAutoRollPopup", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    FL.Pixel.MakeToplevelWindow(frame);
    frame:SetWidth(Sizes.width);
    -- Placed fresh (see the "no position persistence" decision below), and
    -- again whenever the UI scale/resolution/Window Scale changes.
    FL.Pixel.ScaleWithWindows(frame, placeFrame);
    placeFrame();

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
    titleRow:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing();
        FL.Pixel.SnapPosition(frame);
    end);

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
    subtitleText:SetPoint("TOPLEFT", instanceTitle, "BOTTOMLEFT", 0, -Sizes.titleSubtitleGap);
    subtitleText:SetPoint("RIGHT", titleRow, "RIGHT", 0, 0);
    subtitleText:SetJustifyH("LEFT");
    subtitleText:SetWordWrap(true);
    subtitleText:SetTextColor(unpack(Colors.description));
    -- Text (raid vs dungeon) is set in paint(); titleRow's height follows it
    -- in resizeFrame below.

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
    -- Explicit SetWidth (not a TOPLEFT+RIGHT anchor pair) so GetStringHeight()
    -- below measures off a fixed wrap width instead of the frame's own
    -- not-yet-settled layout width.
    noteText:SetWidth(Sizes.width - Sizes.padding * 2);
    noteText:SetJustifyH("LEFT");
    noteText:SetJustifyV("TOP");
    noteText:SetWordWrap(true);
    noteText:SetMaxLines(0); -- no truncation, however many lines it takes
    noteText:SetTextColor(unpack(Colors.muted));
    -- "/fl autoroll" highlighted brighter within the muted note, same
    -- multi-color-fontstring technique used elsewhere in this addon.
    noteText:SetText(("Reopen this anytime with |cff%s/fl autoroll|r"):format(
        ("%02x%02x%02x"):format(Colors.text[1] * 255, Colors.text[2] * 255, Colors.text[3] * 255)));

    ----------------------------------------------------------------------
    -- Footer: divider, "Your item overrides still apply." + View Overrides.
    ----------------------------------------------------------------------

    local footerDivider = frame:CreateTexture(nil, "ARTWORK");
    footerDivider:SetColorTexture(unpack(Colors.divider));
    footerDivider:SetPoint("TOPLEFT", noteText, "BOTTOMLEFT", 0, -Sizes.gap);
    footerDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.padding, 0);
    FL.Pixel.SetLineHeight(footerDivider, Sizes.footerDividerHeight);

    viewOverridesButton = Widgets.CreateFlatButton(frame, "View Overrides", "default");
    viewOverridesButton:SetSize(viewOverridesButton.text:GetStringWidth() + 24, Sizes.viewOverridesHeight);
    viewOverridesButton:SetPoint("TOPRIGHT", footerDivider, "BOTTOMRIGHT", 0, -Sizes.footerGap);
    viewOverridesButton:SetScript("OnClick", function()
        FL.UI.SettingsWindow.Show();
        FL.UI.SettingsRegistry.SelectPage("lootrolls");
        FL.UI.SettingsWindow.ScrollToSection("autoRoll");
        FL.Pixel.BringToFront(frame); -- both DIALOG strata; keep the popup visibly on top since it must stay open
    end);

    -- footerDivider's own LEFT point sits at the (razor-thin) divider's
    -- vertical middle, not the row's - offset down to viewOverridesButton's
    -- vertical center instead, so the two anchors below agree on the same y
    -- (the RIGHT point, targeting the button directly, is already there
    -- with a 0 offset) and the label reads vertically centered against the
    -- button, not top-aligned to it.
    local footerCenterY = -(FL.Pixel.PixelSize(Sizes.footerDividerHeight) + Sizes.footerGap + Sizes.viewOverridesHeight / 2);

    footerText = frame:CreateFontString(nil, "OVERLAY");
    SetFont(footerText, "small");
    footerText:SetPoint("LEFT", footerDivider, "LEFT", 0, footerCenterY);
    footerText:SetPoint("RIGHT", viewOverridesButton, "LEFT", -8, 0);
    footerText:SetJustifyH("LEFT");
    footerText:SetWordWrap(false);
    footerText:SetText("Your item overrides still apply.");
    footerText:SetTextColor(unpack(Colors.muted));

    resizeFrame = function()
        titleRow:SetHeight(math.max(closeButton:GetHeight(),
            instanceTitle:GetStringHeight() + Sizes.titleSubtitleGap + subtitleText:GetStringHeight() + Sizes.gridTopMargin));
        frame:SetHeight(Sizes.padding + titleRow:GetHeight() + gridHeight + Sizes.gap
            + noteText:GetStringHeight() + Sizes.gap + Sizes.footerDividerHeight + Sizes.footerGap
            + viewOverridesButton:GetHeight() + Sizes.padding);
    end
    resizeFrame();

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
--- as the "current choice". Deliberately reads the raw session choice
--- (FL.Settings.GetAutoRollSessionChoice), NOT AutoRoll.GetEffectiveMode():
--- GetEffectiveMode falls back to "manual" for ask-mode with no session
--- choice yet, which would highlight the Manual button on every automatic
--- raid-entry open. checkShowPopup() only ever triggers that automatic open
--- when no session choice exists yet, so reading the raw choice here gives
--- "no highlight" on that path for free, and still highlights the right
--- button on a /fl autoroll reopen when one was already made.
local function paint()
    instanceTitle:SetText(GetInstanceInfo() or "");
    subtitleText:SetText(("How should ForeverLoot roll on loot in this %s?"):format(
        FL.AutoRoll.IsDungeon() and "dungeon" or "raid"));

    local instanceID = select(8, GetInstanceInfo());
    local current = instanceID and FL.Settings.GetAutoRollSessionChoice(instanceID);
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
    resizeFrame();
    frame:EnableKeyboard(true);
    frame:Show();
    -- noteText's wrap-driven GetStringHeight() isn't always settled the
    -- same frame SetWidth/SetText run, so re-measure one frame later.
    C_Timer.After(0, function()
        if (frame:IsShown()) then resizeFrame(); end
    end);
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
