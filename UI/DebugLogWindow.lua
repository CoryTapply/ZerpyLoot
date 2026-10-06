--[[
/fl debug log - a movable window holding the last DEBUG_LOG_LINES debug
lines (ForeverLootDB.debug.log) as plain, read-only, selectable text, so a
tester can Ctrl+C it and paste it back into Claude Code.

A toolbar above the log runs the common /fl debug commands as buttons, in
three rows:
  LOGGING    Debug on/off, level, category mute list, Clear
  SYNC       Sync History, Sync Loot Council Session (forcehello), Probe
  TEST DATA  test-data mode, Generate, Drop Test Rows, Purge, Wipe History
Each button calls the same Sync/Debug.lua / Data/Store.lua function its
slash command does. Generate, Drop, Wipe and Probe open a Skin.ConfirmPopup
first. Generate and Drop need test-data mode on, same as their slash
commands, and are disabled until it is.

Lines are shown color-coded (Debug.ColorizeLine: each [CAT] tag in its
category's color). Ctrl+C on an EditBox copies its color codes too, so while
the text has focus - the player is selecting to copy - it switches to the
plain buffer text, and back to colors when focus is lost.

The log repaints itself while open: Sync/Debug.lua calls OnDebugChanged on
every new line and every settings change. Log repaints are batched
(LOG_REFRESH_DELAY) and skipped while the text has focus, so selecting text
to copy isn't disturbed; it catches up when focus is lost. A log scrolled to
the bottom stays at the bottom.

Built on UI/SoftResImportWindow.lua's paste-box skeleton (ScrollFrame with
UIPanelScrollFrameTemplate + a bare EditBox set as the scroll child, width
kept in sync via OnSizeChanged), reusing the same production window chrome
(Skin/Colors/Theme.Helpers/Pixel) as every other window in the addon.

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
local LOG_REFRESH_DELAY = 0.25; -- seconds; batches a burst of new lines into one repaint

local frame, editBox, scrollFrame;
local controls = {}; -- toolbar buttons/dropdown, by name
local logRefreshPending, logDirty = false, false;

-- Level button colors, by level: normal is calm, very verbose is loud.
local LEVEL_COLORS = { Colors.syncGood, Colors.syncWarn, Colors.syncBad };

local function D() return FL.Sync.Debug; end

--------------------------------------------------------------------------
-- Small builders
--------------------------------------------------------------------------

--- A flat Skin.Button sized to its label. `tooltip` is { title, text }.
local function makeButton(parent, label, variant, onClick, tooltip)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate");
    local text = button:CreateFontString(nil, "OVERLAY");
    text:SetPoint("CENTER");
    button.text = text;
    Skin.Button(button, variant);
    button:SetHeight(Sizes.toolbar.rowHeight);
    button:SetScript("OnClick", onClick);

    function button.SetLabel(_, newLabel)
        button.text:SetText(newLabel);
        button:SetWidth(math.max(Sizes.toolbar.minButtonWidth,
            math.ceil(button.text:GetStringWidth()) + Sizes.toolbar.buttonPadX * 2));
    end
    button:SetLabel(label);

    if (tooltip) then
        button:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM");
            GameTooltip:AddLine(tooltip[1], 1, 1, 1);
            local extra = self.tooltipExtra and self.tooltipExtra();
            if (tooltip[2]) then GameTooltip:AddLine(tooltip[2], nil, nil, nil, true); end
            if (extra) then GameTooltip:AddLine(extra, unpack(Colors.syncWarn)); end
            GameTooltip:Show();
        end);
        button:HookScript("OnLeave", function() GameTooltip:Hide(); end);
    end
    return button;
end

--- Recolors a Skin.Button's label (kept through enable/disable repaints).
local function setButtonTextColor(button, color)
    button.skinVariant.textColor = color;
    if (button:IsEnabled()) then button.applyEnabled(); end
end

local function rowLabel(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY");
    SetFont(fs, "helper");
    fs:SetTextColor(unpack(Colors.muted));
    fs:SetText(text);
    fs:SetJustifyH("LEFT");
    return fs;
end

--------------------------------------------------------------------------
-- Log text
--------------------------------------------------------------------------

local function isScrolledToBottom()
    return scrollFrame:GetVerticalScroll() >= scrollFrame:GetVerticalScrollRange() - 2;
end

local function scrollToBottomSoon()
    -- The scroll range only updates once the EditBox has resized to its new
    -- text, on the next frame.
    C_Timer.After(0, function()
        if (scrollFrame) then scrollFrame:SetVerticalScroll(scrollFrame:GetVerticalScrollRange()); end
    end);
end

local function plainText()
    return table.concat(FL.DB.debug.log, "\n");
end

local function coloredText()
    local colorize = FL.Sync.Debug.ColorizeLine;
    local lines = {};
    for i, line in ipairs(FL.DB.debug.log) do lines[i] = colorize(line); end
    return table.concat(lines, "\n");
end

--- Swaps the text without moving the view (same lines, same wrapping, so
--- the same scroll offset shows the same place).
local function setTextKeepScroll(text)
    local scroll = scrollFrame:GetVerticalScroll();
    editBox:SetText(text);
    C_Timer.After(0, function()
        if (scrollFrame) then
            scrollFrame:SetVerticalScroll(math.min(scroll, scrollFrame:GetVerticalScrollRange()));
        end
    end);
end

local function refreshLog(forceBottom)
    if (not frame) then return; end
    if (editBox:HasFocus()) then
        logDirty = true; -- the player may be selecting text to copy; catch up on focus loss
        return;
    end
    logDirty = false;
    local stick = forceBottom or isScrolledToBottom();
    if (stick) then
        editBox:SetText(coloredText());
        scrollToBottomSoon();
    else
        setTextKeepScroll(coloredText());
    end
end

--------------------------------------------------------------------------
-- Toolbar state
--------------------------------------------------------------------------

local function allCategoriesOn()
    for _, c in ipairs(D().CATEGORIES) do
        if (not D().IsCategoryOn(c.name)) then return false; end
    end
    return true;
end

local function refreshControls()
    if (not frame) then return; end
    local d = FL.DB.debug;

    local b = controls.enabled;
    b:SetLabel(d.enabled and "Debug: On" or "Debug: Off");
    Skin.SetButtonVariant(b, d.enabled and "primary" or "default");

    local level = d.level or 1;
    controls.level:SetLabel("Level: " .. (D().LEVEL_NAMES[level] or tostring(level)));
    setButtonTextColor(controls.level, LEVEL_COLORS[level] or Colors.textBright);

    controls.categories.Refresh();

    local testOn = D().IsTestDataMode();
    controls.testData:SetLabel(testOn and "Test Data: Enabled" or "Test Data: Disabled");
    Skin.SetButtonVariant(controls.testData, testOn and "primary" or "default");
    controls.generate:SetEnabled(testOn);
    controls.drop:SetEnabled(testOn);
end

--------------------------------------------------------------------------
-- Popups
--------------------------------------------------------------------------

local popups = {};

local function newPopup(title)
    local p = Sizes.popup;
    local popup = Skin.ConfirmPopup(frame, {
        width = p.width, padding = p.padding, sectionGap = p.sectionGap, titleHeight = p.titleHeight,
        buttonHeight = p.buttonHeight, buttonGap = p.buttonGap, buttonWidth = p.buttonWidth,
        shadowInset = p.shadowInset, scrimTopInset = Sizes.titleBarHeight,
    });
    popup.dialog.title:SetText(title);
    return popup;
end

local function fieldLabel(dialog, text)
    local fs = dialog:CreateFontString(nil, "OVERLAY");
    SetFont(fs, "helper");
    fs:SetTextColor(unpack(Colors.muted));
    fs:SetText(text:upper());
    fs:SetJustifyH("LEFT");
    return fs;
end

--- A Skin.EditBox. `numeric` limits it to whole numbers.
local function inputBox(dialog, width, numeric)
    local box = CreateFrame("EditBox", nil, dialog, "BackdropTemplate");
    box:SetAutoFocus(false);
    box:SetSize(width, Sizes.popup.inputHeight);
    Skin.EditBox(box);
    if (numeric) then box:SetNumeric(true); end
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus(); end);
    return box;
end

--- Wrapped helper text, full popup width.
local function noteText(dialog, color)
    local fs = dialog:CreateFontString(nil, "OVERLAY");
    SetFont(fs, "small");
    fs:SetTextColor(unpack(color or Colors.description));
    fs:SetJustifyH("LEFT");
    fs:SetWordWrap(true);
    fs:SetWidth(Sizes.popup.width - Sizes.popup.padding * 2);
    return fs;
end

local function place(region, dialog, x, y)
    region:ClearAllPoints();
    region:SetPoint("TOPLEFT", dialog, "TOPLEFT", x, y);
end

--- Enables the confirm button only while every box holds a positive number.
local function requirePositive(popup, boxes)
    local function check()
        for _, box in ipairs(boxes) do
            local n = tonumber(box:GetText());
            if (not n or n <= 0) then popup:SetConfirmEnabled(false); return; end
        end
        popup:SetConfirmEnabled(true);
    end
    for _, box in ipairs(boxes) do box:HookScript("OnTextChanged", check); end
    return check;
end

-- Generate ---------------------------------------------------------------

local function showGeneratePopup()
    local popup = popups.generate;
    if (not popup) then
        popup = newPopup("Generate Test Rows");
        local dialog = popup.dialog;
        dialog.countLabel = fieldLabel(dialog, "How many rows");
        dialog.countBox = inputBox(dialog, Sizes.popup.numberWidth, true);

        dialog.oldCheck = CreateFrame("CheckButton", nil, dialog, "UICheckButtonTemplate");
        Skin.Checkbox(dialog.oldCheck);
        dialog.oldLabel = dialog:CreateFontString(nil, "OVERLAY");
        SetFont(dialog.oldLabel, "body");
        dialog.oldLabel:SetTextColor(unpack(Colors.textBright));
        dialog.oldLabel:SetText("Old rows (dated 5-6 months ago)");

        dialog.note = noteText(dialog);
        dialog.note:SetText(("Normal rows are dated across the last %d months, inside the sync window, so they sync to peers. "
            .. "Old rows are dated 5-6 months ago, past that window: they don't sync, and the next prune removes them "
            .. "unless they're pinned. Use old rows to test pruning. Rows use your real items and guild names, with ids "
            .. "starting zztest- so Purge Test Rows can remove them."):format(FL.Sync.Constants.RETENTION_MONTHS));

        popup.check = requirePositive(popup, { dialog.countBox });
        popups.generate = popup;
    end

    local dialog = popup.dialog;
    dialog.countBox:SetText("50");
    dialog.oldCheck:SetChecked(false);
    popup:SetButtons("Cancel", "Generate", function()
        FL.Sync.Store.GenerateTestRows(tonumber(dialog.countBox:GetText()), dialog.oldCheck:GetChecked() and true or false);
    end);
    popup:Show(function(dlg, y)
        local p = Sizes.popup;
        place(dlg.countLabel, dlg, p.padding, y);
        y = y - dlg.countLabel:GetStringHeight() - p.fieldLabelGap;
        place(dlg.countBox, dlg, p.padding, y);
        y = y - p.inputHeight - p.rowGap;
        place(dlg.oldCheck, dlg, p.padding, y);
        dlg.oldLabel:ClearAllPoints();
        dlg.oldLabel:SetPoint("LEFT", dlg.oldCheck, "RIGHT", 6, 0);
        y = y - dlg.oldCheck:GetHeight() - p.rowGap;
        place(dlg.note, dlg, p.padding, y);
        return y - dlg.note:GetStringHeight() - p.sectionGap;
    end);
    popup.check();
end

-- Drop test rows -----------------------------------------------------------

local function showDropPopup()
    local popup = popups.drop;
    if (not popup) then
        popup = newPopup("Drop Test Rows");
        local dialog = popup.dialog;
        dialog.countLabel = fieldLabel(dialog, "How many rows");
        dialog.countBox = inputBox(dialog, Sizes.popup.numberWidth, true);
        dialog.note = noteText(dialog);
        dialog.note:SetText("Removes the newest test rows from this client only. No delete is sent, so the next "
            .. "history sync with a peer that still has them should bring them back - that's the point: it gives "
            .. "sync something to repair. Real rows are never touched.");
        popup.check = requirePositive(popup, { dialog.countBox });
        popups.drop = popup;
    end

    local dialog = popup.dialog;
    dialog.countBox:SetText("10");
    popup:SetButtons("Cancel", "Drop Rows", function()
        FL.Sync.Store.DropLocal(tonumber(dialog.countBox:GetText()), false);
    end);
    popup:Show(function(dlg, y)
        local p = Sizes.popup;
        place(dlg.countLabel, dlg, p.padding, y);
        y = y - dlg.countLabel:GetStringHeight() - p.fieldLabelGap;
        place(dlg.countBox, dlg, p.padding, y);
        y = y - p.inputHeight - p.rowGap;
        place(dlg.note, dlg, p.padding, y);
        return y - dlg.note:GetStringHeight() - p.sectionGap;
    end);
    popup.check();
end

-- Wipe history -------------------------------------------------------------

local function showWipePopup()
    local popup = popups.wipe;
    if (not popup) then
        popup = newPopup("Wipe All History?");
        local dialog = popup.dialog;
        dialog.note = noteText(dialog, Colors.lhErrorText);
        dialog.note:SetText("This permanently deletes every history row, delete and pin on THIS client. There is no undo.");
        dialog.note2 = noteText(dialog);
        dialog.note2:SetText("Other guild members keep their copies, so history sync will bring their rows back "
            .. "unless you turn sync off first.");
        popups.wipe = popup;
    end

    popup:SetButtons("Cancel", "Wipe History", function() FL.Sync.Store.WipeHistory(); end);
    Skin.SetButtonVariant(popup.confirmButton, "danger");
    popup:Show(function(dlg, y)
        local p = Sizes.popup;
        place(dlg.note, dlg, p.padding, y);
        y = y - dlg.note:GetStringHeight() - p.noteGap;
        place(dlg.note2, dlg, p.padding, y);
        return y - dlg.note2:GetStringHeight() - p.sectionGap;
    end);
end

-- Probe ----------------------------------------------------------------------

local PROBE_PREFIXES = {
    { value = "main", label = "main" },
    { value = "s1", label = "s1" },
    { value = "s2", label = "s2" },
    { value = "s3", label = "s3" },
    { value = "rot", label = "rot (rotate all)" },
};
local PROBE_PRIORITIES = {
    { value = "NORMAL", label = "Normal" },
    { value = "ALERT", label = "Alert" },
    { value = "BULK", label = "Bulk" },
};

local probeState = { prefix = "main", prio = "NORMAL" };

local function defaultProbeTarget()
    if (IsInRaid()) then return "RAID"; end
    if (IsInGroup()) then return "PARTY"; end
    return "";
end

local function showProbePopup()
    local popup = popups.probe;
    local p = Sizes.popup;
    local inner = p.width - p.padding * 2;
    local third = math.floor((inner - p.rowGap * 2) / 3);
    local half = math.floor((inner - p.rowGap) / 2);

    if (not popup) then
        popup = newPopup("Network Probe");
        local dialog = popup.dialog;

        dialog.targetLabel = fieldLabel(dialog, "Target");
        dialog.targetBox = inputBox(dialog, inner, false);

        dialog.countLabel = fieldLabel(dialog, "Messages");
        dialog.countBox = inputBox(dialog, third, true);
        dialog.rateLabel = fieldLabel(dialog, "Per second");
        dialog.rateBox = inputBox(dialog, third, false);
        dialog.bytesLabel = fieldLabel(dialog, "Bytes each");
        dialog.bytesBox = inputBox(dialog, third, true);

        dialog.prefixLabel = fieldLabel(dialog, "Prefix");
        dialog.prefixDropdown = Skin.Dropdown(dialog, {
            width = half, height = p.inputHeight, xOffset = -2, options = PROBE_PREFIXES,
            getValue = function() return probeState.prefix; end,
            onSelect = function(v) probeState.prefix = v; end,
        });
        dialog.prioLabel = fieldLabel(dialog, "Priority");
        dialog.prioDropdown = Skin.Dropdown(dialog, {
            width = half, height = p.inputHeight, xOffset = -2, options = PROBE_PRIORITIES,
            getValue = function() return probeState.prio; end,
            onSelect = function(v) probeState.prio = v; end,
        });

        dialog.note = noteText(dialog);
        dialog.note:SetText("Sends test messages that the receiver echoes back, then reports loss and round-trip "
            .. "time in this log about 15s after the last send. Target is a player name, or PARTY, RAID or GUILD; "
            .. "the other side needs ForeverLoot. Per second 0 sends them all at once.");

        local function check()
            local target = strtrim(dialog.targetBox:GetText() or "");
            local n, rate, bytes = tonumber(dialog.countBox:GetText()), tonumber(dialog.rateBox:GetText()),
                tonumber(dialog.bytesBox:GetText());
            -- Probe.Start reads the name as every word before the first number.
            local ok = target ~= "" and not target:match("%d") and n and n > 0 and rate and rate >= 0
                and bytes and bytes > 0;
            popup:SetConfirmEnabled(ok and true or false);
        end
        for _, box in ipairs({ dialog.targetBox, dialog.countBox, dialog.rateBox, dialog.bytesBox }) do
            box:HookScript("OnTextChanged", check);
        end
        popup.check = check;
        popups.probe = popup;
    end

    local dialog = popup.dialog;
    dialog.targetBox:SetText(defaultProbeTarget());
    dialog.countBox:SetText("20");
    dialog.rateBox:SetText("2");
    dialog.bytesBox:SetText("20");
    dialog.prefixDropdown.Refresh();
    dialog.prioDropdown.Refresh();

    popup:SetButtons("Cancel", "Start Probe", function()
        FL.Sync.Probe.Start(("%s %d %s %s %s %d"):format(strtrim(dialog.targetBox:GetText()),
            tonumber(dialog.countBox:GetText()), dialog.rateBox:GetText(), probeState.prefix, probeState.prio,
            tonumber(dialog.bytesBox:GetText())));
    end);
    popup:Show(function(dlg, y)
        place(dlg.targetLabel, dlg, p.padding, y);
        y = y - dlg.targetLabel:GetStringHeight() - p.fieldLabelGap;
        place(dlg.targetBox, dlg, p.padding, y);
        y = y - p.inputHeight - p.rowGap;

        place(dlg.countLabel, dlg, p.padding, y);
        place(dlg.rateLabel, dlg, p.padding + third + p.rowGap, y);
        place(dlg.bytesLabel, dlg, p.padding + (third + p.rowGap) * 2, y);
        y = y - dlg.countLabel:GetStringHeight() - p.fieldLabelGap;
        place(dlg.countBox, dlg, p.padding, y);
        place(dlg.rateBox, dlg, p.padding + third + p.rowGap, y);
        place(dlg.bytesBox, dlg, p.padding + (third + p.rowGap) * 2, y);
        y = y - p.inputHeight - p.rowGap;

        place(dlg.prefixLabel, dlg, p.padding, y);
        place(dlg.prioLabel, dlg, p.padding + half + p.rowGap, y);
        y = y - dlg.prefixLabel:GetStringHeight() - p.fieldLabelGap;
        place(dlg.prefixDropdown.button, dlg, p.padding, y);
        place(dlg.prioDropdown.button, dlg, p.padding + half + p.rowGap, y);
        y = y - p.inputHeight - p.rowGap;

        place(dlg.note, dlg, p.padding, y);
        return y - dlg.note:GetStringHeight() - p.sectionGap;
    end);
    popup.check();
end

--------------------------------------------------------------------------
-- Toolbar
--------------------------------------------------------------------------

local function categoryOptions()
    local options = { { value = "__all", label = "All categories" } };
    for _, c in ipairs(D().CATEGORIES) do
        table.insert(options, { value = c.name, label = ("|cff%s%s|r  -  %s"):format(c.color, c.name, c.desc) });
    end
    return options;
end

local function toggleCategory(value)
    if (value == "__all") then
        -- All on -> mute all; anything muted -> turn all back on.
        local state = allCategoriesOn() and "off" or "on";
        for _, c in ipairs(D().CATEGORIES) do D().SetCategory(c.name, state); end
        return;
    end
    D().SetCategory(value, D().IsCategoryOn(value) and "off" or "on");
end

local function categoryButtonLabel()
    local on, total = 0, #D().CATEGORIES;
    for _, c in ipairs(D().CATEGORIES) do
        if (D().IsCategoryOn(c.name)) then on = on + 1; end
    end
    if (on == total) then return "Categories: all"; end
    if (on == 0) then return "Categories: none"; end
    return ("Categories: %d of %d"):format(on, total);
end

--- Lays `items` out left to right after `label`, on one toolbar row.
local function layoutRow(toolbar, label, items, y)
    local t = Sizes.toolbar;
    label:ClearAllPoints();
    label:SetPoint("LEFT", toolbar, "TOPLEFT", 0, y - t.rowHeight / 2);
    local prev;
    for _, item in ipairs(items) do
        item:ClearAllPoints();
        if (prev) then
            item:SetPoint("LEFT", prev, "RIGHT", t.buttonGap, 0);
        else
            item:SetPoint("TOPLEFT", toolbar, "TOPLEFT", t.labelWidth, y);
        end
        prev = item;
    end
end

local function createToolbar(titleBar)
    local t = Sizes.toolbar;
    local toolbar = CreateFrame("Frame", nil, frame);
    toolbar:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", Sizes.contentPadX, -Sizes.contentPadTop);
    toolbar:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -Sizes.contentPadX, -Sizes.contentPadTop);
    toolbar:SetHeight(t.rowHeight * 3 + t.rowGap * 2);

    -- Logging row
    controls.enabled = makeButton(toolbar, "Debug: Off", "default", function()
        D().SetEnabled(not FL.DB.debug.enabled);
    end, { "Debug logging", "Prints debug lines to chat and saves them to this log. Warnings are saved even when off." });

    controls.level = makeButton(toolbar, "Level: Normal", "default", function()
        D().SetLevel(((FL.DB.debug.level or 1) % 3) + 1);
    end, { "Detail level", "Click to cycle. Normal: one line per event. Verbose: per message and batch. "
        .. "Very verbose: every history write and hash." });

    controls.categories = Skin.Dropdown(toolbar, {
        width = t.categoryWidth, height = t.rowHeight, xOffset = -2, rowHeight = 22, maxVisibleRows = 19,
        options = categoryOptions(),
        isSelected = function(value)
            if (value == "__all") then return allCategoriesOn(); end
            return D().IsCategoryOn(value);
        end,
        keepOpen = true,
        buttonLabel = categoryButtonLabel,
        onSelect = toggleCategory,
    });

    controls.clear = makeButton(toolbar, "Clear", "default", function() D().ClearLog(); end,
        { "Clear the log", "Empties the saved debug log." });

    -- Sync row
    controls.syncHistory = makeButton(toolbar, "Sync History", "default", function()
        D().Log("TEST", 1, "forcehello: asking %s now", "the guild (history)");
        FL.Sync.Coordinator.ForceHello("GUILD");
    end, { "Sync History", "Asks guild peers what loot history they have right now, skipping the timers. "
        .. "Same as /fl debug forcehello." });

    controls.syncCouncil = makeButton(toolbar, "Sync Loot Council Session", "default", function()
        D().Log("TEST", 1, "forcehello: asking %s now", "the group (council)");
        FL.Sync.Coordinator.ForceHello("RAID");
    end, { "Sync Loot Council Session", "Asks your raid or party for the current council session right now. "
        .. "Same as /fl debug forcehello raid." });

    controls.probe = makeButton(toolbar, "Network Probe...", "default", showProbePopup,
        { "Network Probe", "Measures message loss and round-trip time to a player or channel." });

    -- Test data row
    controls.testData = makeButton(toolbar, "Test Data: Disabled", "default", function()
        local on = not D().IsTestDataMode();
        D().SetTestDataMode(on);
        D().Log("TEST", 1, "testdata: turned %s", on and "on" or "off");
    end, { "Test data mode", "Lets this client make and accept fake zztest- history rows, and unlocks "
        .. "Generate and Drop Test Rows." });

    local needsTestData = function()
        return (not D().IsTestDataMode()) and "Turn on Test Data first." or nil;
    end
    controls.generate = makeButton(toolbar, "Generate...", "default", showGeneratePopup,
        { "Generate test rows", "Adds fake history rows to test sync with." });
    controls.generate.tooltipExtra = needsTestData;

    controls.drop = makeButton(toolbar, "Drop Test Rows...", "default", showDropPopup,
        { "Drop test rows", "Removes some test rows from this client only, so sync has something to restore." });
    controls.drop.tooltipExtra = needsTestData;

    controls.purge = makeButton(toolbar, "Purge Test Rows", "default", function()
        FL.Sync.Store.PurgeTestRows();
    end, { "Purge test rows", "Removes every zztest- row, delete and pin from this client." });

    controls.wipe = makeButton(toolbar, "Wipe History...", "danger", showWipePopup,
        { "Wipe history", "Deletes ALL history on this client. Asks first." });

    local rowY = function(i) return -(i - 1) * (t.rowHeight + t.rowGap); end
    layoutRow(toolbar, rowLabel(toolbar, "LOGGING"),
        { controls.enabled, controls.level, controls.categories.button, controls.clear }, rowY(1));
    layoutRow(toolbar, rowLabel(toolbar, "SYNC"),
        { controls.syncHistory, controls.syncCouncil, controls.probe }, rowY(2));
    layoutRow(toolbar, rowLabel(toolbar, "TEST DATA"),
        { controls.testData, controls.generate, controls.drop, controls.purge, controls.wipe }, rowY(3));

    return toolbar;
end

--------------------------------------------------------------------------
-- Window chrome
--------------------------------------------------------------------------

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

local function createBody(toolbar)
    local body = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    body:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -Sizes.toolbar.bottomGap);
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
    -- letting a stray keypress edit the buffer. Losing focus also catches up
    -- on lines that arrived while the player was selecting text.
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);
    -- Plain text while focused, so Ctrl+C copies no color codes.
    editBox:SetScript("OnEditFocusGained", function() setTextKeepScroll(plainText()); end);
    editBox:SetScript("OnEditFocusLost", function(self)
        self:HighlightText(0, 0);
        refreshLog(false); -- back to colors, plus any lines that arrived meanwhile
    end);

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
    local toolbar = createToolbar(titleBar);
    createBody(toolbar);
end

--------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------

--- Called by Sync/Debug.lua: "log" when the buffer changed, "settings" when
--- a debug setting did (from a button here or a slash command).
function DebugLogWindow.OnDebugChanged(what)
    if (not DebugLogWindow.IsShown()) then return; end
    if (what == "settings") then
        refreshControls();
        return;
    end
    if (logRefreshPending) then return; end
    logRefreshPending = true;
    C_Timer.After(LOG_REFRESH_DELAY, function()
        logRefreshPending = false;
        if (DebugLogWindow.IsShown()) then refreshLog(false); end
    end);
end

function DebugLogWindow.Show()
    ensureFrame();
    frame:Show();
    refreshControls();
    refreshLog(true);
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
