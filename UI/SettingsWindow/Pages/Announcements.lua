--[[
Announcements settings page: per-message opt-outs for the chat lines the
addon itself sends into raid/party/whisper chat.

"Raid Chat" section - one checkbox per SendChatMessage(Safe) call site a
player might want to silence, all defaulting on (see Core/Settings.lua's own
"Raid Chat" section for the persisted keys/getters/setters, and SoftRes.lua /
RollTracker.lua / LootCouncil.lua for where each one is actually sent). The
"Announce loot council awards" checkbox gates both of LootCouncil.lua's
award-announcement call sites (the normal award and the disenchant award)
behind a single toggle, since a player thinks of those as one feature. The
roll-off countdown checkbox has a small indented EditBox under it - Widgets.lua has no numeric-
input builder yet, so that row is hand-built the same way LootRolls.lua /
LootResponses.lua hand-roll their own one-off rows, but still registered into
section.items so it participates in SectionMethods:Reflow's generic
font-settle re-layout pass like every other section row.
]]

local FL = ForeverLoot;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Theme = FL.Theme;

-- Same indent Widgets.lua's own SectionMethods:Checkbox uses for a `parent`
-- child checkbox, so this lines up under the checkbox it belongs to.
local CHILD_INDENT = 32;
local ROW_SPACING = Sizes.layout.rowGap;
-- Tighter than ROW_SPACING - ties the seconds row visually to the countdown
-- checkbox above it instead of reading as its own unrelated row.
local CHILD_ROW_GAP = 3;
local EDITBOX_WIDTH = 44;
local EDITBOX_HEIGHT = 21;

local function updateEditBoxBorder(editBox, focused)
    editBox:SetBackdropBorderColor(unpack(focused and Colors.lrEditBoxFocus or Colors.lrEditBoxBorder));
end

--- "Start announcing with this many seconds left" row: label + a small
--- commit-on-Enter/blur, revert-on-invalid numeric EditBox, indented under
--- the roll-off countdown checkbox. Manually advances `section` the same
--- way SectionMethods' own private advanceSection() would (that helper
--- isn't exposed outside Widgets.lua), and records itself into
--- section.items so a later Reflow() repositions it correctly too.
local function addRollCountdownSecondsRow(section, opts)
    -- Both dimensions set explicitly - a container Frame left at its default
    -- zero WIDTH (not just zero height) renders none of its children on this
    -- client even though nothing clips it, same class of quirk documented on
    -- LootRolls.lua's rightFrame:SetHeight call.
    local row = CreateFrame("Frame", nil, section.frame);
    row:SetSize(section.width - CHILD_INDENT, EDITBOX_HEIGHT);

    local label = row:CreateFontString(nil, "OVERLAY");
    SetFont(label, "small");
    label:SetPoint("LEFT", row, "LEFT", 0, 0);
    label:SetText(opts.label);
    label:SetTextColor(unpack(Colors.muted));

    local editBox = CreateFrame("EditBox", nil, row, "BackdropTemplate");
    editBox:SetSize(EDITBOX_WIDTH, EDITBOX_HEIGHT);
    editBox:SetPoint("LEFT", label, "RIGHT", 8, 0);
    Theme.Helpers.SetFlatBackdrop(editBox, Colors.lrEditBoxBg, Colors.lrEditBoxBorder, 1);
    SetFont(editBox, "body");
    editBox:SetTextColor(unpack(Colors.text));
    editBox:SetTextInsets(6, 6, 0, 0);
    editBox:SetAutoFocus(false);
    editBox:SetNumeric(true);
    editBox:SetMaxLetters(2);
    editBox:SetJustifyH("CENTER");

    local function refresh()
        editBox:SetText(tostring(opts.get()));
    end

    editBox:SetScript("OnEditFocusGained", function(self) updateEditBoxBorder(self, true); end);
    editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); end);
    editBox:SetScript("OnEscapePressed", function(self) refresh(); self:ClearFocus(); end);
    editBox:SetScript("OnEditFocusLost", function(self)
        local value = tonumber(self:GetText());
        if (value ~= nil) then opts.set(value); end
        refresh(); -- reflects the clamped/committed value either way
        updateEditBoxBorder(self, false);
    end);

    refresh();

    row:SetPoint("TOPLEFT", section.frame, "TOPLEFT", CHILD_INDENT, section.nextRowY);
    table.insert(section.items, { frame = row, x = CHILD_INDENT, height = row:GetHeight() });
    section.nextRowY = section.nextRowY - row:GetHeight() - ROW_SPACING;
    section.frame:SetHeight(math.max(1, -section.nextRowY));

    table.insert(section.page.refreshers, refresh);

    local rowObj = { frame = row, editBox = editBox, label = label };
    function rowObj:SetEnabledState(enabled)
        editBox:EnableMouse(enabled);
        editBox:EnableKeyboard(enabled);
        if (not enabled) then editBox:ClearFocus(); end
        label:SetTextColor(unpack(enabled and Colors.muted or Colors.disabledText));
        editBox:SetAlpha(enabled and 1 or 0.4);
    end
    return rowObj;
end

FL.UI.SettingsWindow.RegisterPage("announcements", "Announcements", function(page)
    page:Header("Announcements");

    local section = page:Section("Raid Chat", 1);

    section:Checkbox{
        key = "raidChat.softresImported",
        label = "Announce when SoftRes data is imported",
        desc = "Posts the number of soft reserves, plus a link to each hard-reserved item, to the raid/party when you import a soft-reserve sheet.",
        default = true,
    };

    section:Checkbox{
        key = "raidChat.softresWhisperReply",
        label = "Reply to whispers asking about soft-reserves",
        desc = "Whispers back a player's own soft-reserves when they whisper you !sr",
        default = true,
    };

    local secondsRow; -- assigned below, referenced by this checkbox's onChange

    local countdownRow = section:Checkbox{
        key = "raidChat.rollCountdown",
        label = "Announce roll-off countdown",
        desc = "Counts down \"N seconds to roll\" as a roll-off you started winds down.",
        default = true,
        gapAfter = CHILD_ROW_GAP,
        onChange = function(checked) secondsRow:SetEnabledState(checked); end,
    };

    secondsRow = addRollCountdownSecondsRow(section, {
        label = "Start announcing with this many seconds left:",
        get = FL.Settings.GetRaidChatRollCountdownSeconds,
        set = FL.Settings.SetRaidChatRollCountdownSeconds,
    });
    secondsRow:SetEnabledState(countdownRow.checkbox:GetChecked() and true or false);

    table.insert(page.resettableKeys, { key = "raidChat.rollCountdownSeconds", default = 5 });
    table.insert(page.refreshers, function()
        secondsRow:SetEnabledState(countdownRow.checkbox:GetChecked() and true or false);
    end);

    section:Checkbox{
        key = "raidChat.lootCouncilAward",
        label = "Announce loot council awards",
        desc = "Posts \"<item> was awarded to <player>!\" (or \"...will be disenchanted!\") when the loot council awards an item.",
        default = true,
    };
end, 50);
