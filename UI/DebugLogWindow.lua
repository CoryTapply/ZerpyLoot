--[[
/fl debug log - a movable window holding the last DEBUG_LOG_LINES debug
lines (ForeverLootDB.debug.log) as plain, read-only, selectable text, so a
tester can Ctrl+C it and paste it back into Claude Code.

Built on UI/SoftResImportWindow.lua's paste-box skeleton (ScrollFrame with
UIPanelScrollFrameTemplate + a bare EditBox set as the scroll child, width
kept in sync via OnSizeChanged), reusing the same production window chrome
(Skin/Colors/Theme.Helpers/Pixel) as every other window in the addon rather
than hand-rolling a bare frame - those are already unconditionally loaded,
so reuse costs nothing extra here.

Every container frame below gets an explicit SetSize/SetHeight call: a
container Frame left at its default zero height renders no children on this
client even with nothing clipping it (confirmed in
UI/SettingsWindow/Pages/LootRolls.lua, UI/SettingsWindow/Pages/Announcements.lua
and UI/SettingsWindow/ItemListEditor.lua).
]]

local FL = ForeverLoot;
local DebugLogWindow = FL.UI.DebugLogWindow;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.debugLog;
local SharedLayout = FL.UI.Sizes.layout;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;

local WINDOW_WIDTH = Sizes.window.width;
local WINDOW_HEIGHT = Sizes.window.height;
local POSITION_KEY = "debugLogWindow";

local frame, editBox, scrollFrame;

local function createTitleBar()
    local titleBar = CreateFrame("Frame", nil, frame);
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
    titleBar:SetHeight(Sizes.titleBarHeight);

    titleBar:EnableMouse(true);
    titleBar:RegisterForDrag("LeftButton");
    titleBar:SetScript("OnDragStart", function() frame:StartMoving(); end);
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing();
        Pixel.SnapPosition(frame, function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    end);

    local title = titleBar:CreateFontString(nil, "OVERLAY");
    SetFont(title, "windowTitle");
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0);
    title:SetText("ForeverLoot - Debug Log");
    title:SetTextColor(unpack(Colors.titlePurple));

    local divider = titleBar:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 2, 0);
    divider:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -2, 0);
    divider:SetHeight(Pixel.PixelSize(1));

    local closeButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    closeButton:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -8, -8);
    Skin.CloseButton(closeButton);
    closeButton:SetScript("OnClick", function()
        FL.NotifyWindowClosed("DebugLog");
        frame:Hide();
    end);

    return titleBar;
end

local function createBody(titleBar)
    local body = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    body:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", Sizes.contentPadX, -Sizes.contentPadTop);
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Sizes.contentPadX, Sizes.contentPadBottom);
    Skin.Backdrop(body, Colors.controlBg, Colors.controlBorder);

    local scrollbarSpace = SharedLayout.scrollbarWidth + SharedLayout.scrollbarInset;

    scrollFrame = CreateFrame("ScrollFrame", "ForeverLootDebugLogWindowScroll", body, "UIPanelScrollFrameTemplate");
    scrollFrame:SetPoint("TOPLEFT", body, "TOPLEFT", Sizes.textInset, -Sizes.textInset);
    scrollFrame:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -(Sizes.textInset + scrollbarSpace), Sizes.textInset);

    local scrollBar = Skin.ScrollBar(scrollFrame);
    if (scrollBar) then
        scrollBar:ClearAllPoints();
        scrollBar:SetPoint("TOP", scrollFrame, "TOP", 0, 0);
        scrollBar:SetPoint("BOTTOM", scrollFrame, "BOTTOM", 0, 0);
        scrollBar:SetPoint("RIGHT", body, "RIGHT", -Sizes.textInset, 0);
    end

    editBox = CreateFrame("EditBox", nil, scrollFrame);
    editBox:SetMultiLine(true);
    editBox:SetAutoFocus(false);
    SetFont(editBox, "small");
    editBox:SetTextColor(unpack(Colors.description));
    editBox:SetWidth(scrollFrame:GetWidth());
    scrollFrame:SetScrollChild(editBox);
    scrollFrame:SetScript("OnSizeChanged", function(self, width) editBox:SetWidth(width); end);

    -- Read-only display: dropping focus re-selects everything, rather than
    -- letting a stray keypress edit the buffer.
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);
    editBox:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0); end);

    body:EnableMouse(true);
    body:SetScript("OnMouseDown", function() editBox:SetFocus(); end);
    scrollFrame:SetScript("OnMouseDown", function() editBox:SetFocus(); end);

    return body;
end

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootDebugLogWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    Pixel.RegisterWindow(frame, {
        width = WINDOW_WIDTH, height = WINDOW_HEIGHT,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    local titleBar = createTitleBar();
    createBody(titleBar);
end

function DebugLogWindow.Show()
    ensureFrame();
    editBox:SetText(table.concat(FL.DB.debug.log, "\n"));
    frame:Show();
    editBox:SetFocus();
    editBox:HighlightText();
end

function DebugLogWindow.Hide()
    if (frame) then frame:Hide(); end
end

function DebugLogWindow.IsShown()
    return frame ~= nil and frame:IsShown();
end

function DebugLogWindow.Toggle()
    if (DebugLogWindow.IsShown()) then DebugLogWindow.Hide(); else DebugLogWindow.Show(); end
end

function DebugLogWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
