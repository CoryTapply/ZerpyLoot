--[[
Loot Rolls settings page: the Group Loot popup-replacement/lock checkboxes
(unchanged from the old ConfigWindow), a "Loot Chat" section (LootChat.lua)
controlling the "X receives loot: [item]" chat log, and an "Automatic Rolls"
section (AutoRoll.lua, UI/AutoRollPopup.lua, /fl autoroll) controlling
auto-Need/Greed/Pass in raids (and dungeons, via /fl autoroll). Both of the latter are full-width sections
below the normal 2-column grid, each itself split into its own 2-column
layout (checkboxes/radios left, an item list right), since Widgets.lua's
page:Section only supports the page's own top-level 2-column arrangement,
not a section-internal split - see nextSectionTop below for how a second
full-width section stacks correctly under the first.

Both item lists (the "Also print these items" one here and the "Always roll
on these items" one below) are built from the shared
UI/SettingsWindow/ItemListEditor.lua widget.
]]

local FL = ForeverLoot;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Widgets = FL.UI.SettingsWidgets;
local Theme = FL.Theme;
local Util = FL.Util;
local ItemListEditor = FL.UI.ItemListEditor;

-- Anchors the start of a full-width, hand-built section (one that
-- page:Section's own 2-column bookkeeping can't see) under whatever the page
-- has built so far. PageMethods:contentBottom() only tracks the normal
-- 2-column grid's columnY/lastSection - it has NO awareness of
-- page.contentBottomOverride, which is what a previous full-width section
-- leaves behind instead. Preferring contentBottomOverride here is what lets
-- a SECOND full-width section (Automatic Rolls) stack correctly under the
-- first one (Loot Chat) rather than both landing on the same stale Y.
local function nextSectionTop(page)
    return (page.contentBottomOverride or page:contentBottom()) - Sizes.layout.sectionGap;
end

FL.UI.SettingsWindow.RegisterPage("lootrolls", "Loot Rolls", function(page)
    page:Header("Loot Rolls");

    local section = page:Section("Group Loot Roll Popup", 1);

    section:Checkbox{
        key = "loot.replacePopup",
        label = "Replace default Group Loot popup (Need/Greed/Pass)",
        tooltip = "Requires /reload to take effect.",
        default = true,
    };

    local lockRow = section:Checkbox{
        key = "loot.lockRolls",
        label = "Lock Group Loot rolls (hide header)",
        desc = "Hides the drag header so rolls can't be moved.",
        default = false,
        onChange = function()
            if (FL.UI.GroupLootFrame and FL.UI.GroupLootFrame.RefreshLock) then
                FL.UI.GroupLootFrame.RefreshLock();
            end
        end,
    };

    -- Lets GroupLootFrame.lua's own header right-click ("open Settings to
    -- this setting") scroll to and flash this row - same anchor idiom as
    -- the "autoRoll" section below, just registered on a single checkbox
    -- row's frame instead of a whole hand-built section.
    FL.UI.SettingsWindow.sectionAnchors = FL.UI.SettingsWindow.sectionAnchors or {};
    FL.UI.SettingsWindow.sectionAnchors["lockRolls"] = lockRow.frame;

    local rollOffSection = page:Section("Roll Off", 2);

    rollOffSection:Checkbox{
        key = "loot.rollOff.showForOthers",
        label = "Enable roll off window for rolls started by other players",
        desc = "When off, the roll off window only opens for rolls you start yourself. Sounds still play either way.",
        default = true,
    };

    --------------------------------------------------------------------------
    -- "Loot Chat" section - full width, its own internal 2-column split.
    --------------------------------------------------------------------------

    -- Deliberately its own value, not Widgets.lua's private COLUMN_GAP (which
    -- only governs the page's own top-level 2-column grid).
    local COLUMN_GAP = 21;

    local outerTop = nextSectionTop(page);

    local outer = CreateFrame("Frame", nil, page.frame);
    outer:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, outerTop);
    outer:SetWidth(page.contentWidth);

    local outerTitle = outer:CreateFontString(nil, "OVERLAY");
    SetFont(outerTitle, "sectionHeader");
    outerTitle:SetTextColor(unpack(Colors.gold));
    outerTitle:SetPoint("TOPLEFT", outer, "TOPLEFT", 0, 0);
    outerTitle:SetText("Chat");

    local outerDivider = outer:CreateTexture(nil, "ARTWORK");
    outerDivider:SetColorTexture(unpack(Colors.divider));
    outerDivider:SetPoint("TOPLEFT", outerTitle, "BOTTOMLEFT", 0, -6);
    outerDivider:SetPoint("TOPRIGHT", outer, "TOPRIGHT", 0, 0);
    outerDivider:SetHeight(FL.Pixel.PixelSize(1));

    local innerTop = -(outerTitle:GetStringHeight() + 6 + Sizes.layout.rowGap);
    local colWidth = math.floor((page.contentWidth - COLUMN_GAP) / 2);

    ----------------------------------------------------------------------
    -- Left column: checkboxes, via a fresh SectionMethods object (the same
    -- metatable page:Section itself returns) parented under `outer` instead
    -- of directly under `page.frame`, so :Checkbox works exactly as usual.
    ----------------------------------------------------------------------

    local leftFrame = CreateFrame("Frame", nil, outer);
    leftFrame:SetPoint("TOPLEFT", outer, "TOPLEFT", 0, innerTop);
    leftFrame:SetWidth(colWidth);

    local leftSection = setmetatable({
        page = page,
        frame = leftFrame,
        width = colWidth,
        startY = 0,
        nextRowY = 0,
        rows = {},
        items = {},
    }, Widgets.SectionMethods);

    local lootChatEditor; -- assigned below, referenced by this checkbox's onChange

    leftSection:Checkbox{
        key = "loot.chat.enabled",
        label = "Print \"receives loot\" messages",
        desc = "Uncommon (green) and better are always printed. Add anything lower you want to track, like quest items.",
        default = true,
        onChange = function() lootChatEditor:Refresh(); end,
    };

    leftSection:Checkbox{
        key = "loot.chat.hideBlizzardMain",
        label = "Hide Blizzard loot messages in the main chat tab",
        desc = "Turns off \"Item Loot\" in your first chat window.",
        default = true,
    };

    leftSection:Checkbox{
        key = "loot.chat.lootTab",
        label = "Add a \"Loot\" chat tab",
        desc = "A new tab that shows only Item Loot and Money Loot so you can see the rolls amounts on items in chat. Unchecking removes the tab.",
        default = false,
    };

    ----------------------------------------------------------------------
    -- Right column: "Also print these items" (shared ItemListEditor).
    ----------------------------------------------------------------------

    local rightFrame = CreateFrame("Frame", nil, outer);
    rightFrame:SetPoint("TOPLEFT", outer, "TOPLEFT", colWidth + COLUMN_GAP, innerTop);
    rightFrame:SetWidth(colWidth);

    local function getSortedExtraItemIDs()
        local list = {};
        for itemID, order in pairs(FL.Settings.GetLootExtraItems()) do
            table.insert(list, { itemID = itemID, order = order });
        end
        table.sort(list, function(a, b) return a.order > b.order; end);

        local ids = {};
        for _, entry in ipairs(list) do table.insert(ids, entry.itemID); end
        return ids;
    end

    lootChatEditor = ItemListEditor.Create(rightFrame, {

        width = colWidth,
        headerLabel = "Also print these items",
        emptyText = "No extra items. Only Uncommon and better will print.",
        GetItems = getSortedExtraItemIDs,
        IsAlreadyListed = FL.Settings.IsLootExtraItem,
        ValidateAdd = function(itemID, name, quality)
            if (type(quality) == "number" and quality >= Enum.ItemQuality.Uncommon) then
                return false, "info", name .. " is Uncommon or better, so it already prints.";
            end
            return true;
        end,
        AddItem = FL.Settings.AddLootExtraItem,
        RemoveItem = FL.Settings.RemoveLootExtraItem,
        FormatAddedStatus = function(name) return "Added " .. name .. "."; end,
        FormatRemovedStatus = function(name) return "Removed " .. name .. "."; end,
        GetHeaderCountText = function(items)
            return #items == 1 and "1 item" or (#items .. " items");
        end,
        IsEnabled = FL.Settings.GetLootMessagesEnabled,
    });
    -- rightFrame is never sized by anchors alone (only TOPLEFT + an explicit
    -- width) - confirmed by live diagnostic that on this client, a plain
    -- container left at its default zero declared height renders none of its
    -- children even though they're individually shown/positioned/opaque, so
    -- it must be given an explicit height matching its one real child.
    rightFrame:SetHeight(lootChatEditor.frame:GetHeight());

    -- "Also print these items" is deliberately NOT wired into
    -- page.resettableKeys - "Reset This Page" should leave this list alone
    -- rather than clearing it, unlike the "Always roll on these items" list
    -- below.
    table.insert(page.refreshers, function() lootChatEditor:Refresh(); end);

    ----------------------------------------------------------------------
    -- Let LootChat.lua report a "no free chat windows" failure back onto
    -- this section's status line, and re-sync the page (unchecking "Add a
    -- Loot chat tab") when that happens or when PLAYER_LOGIN finds the tab
    -- was closed by hand.
    ----------------------------------------------------------------------

    FL.LootChat.statusCallback = function(kind, text) lootChatEditor:SetStatus(kind, text); end;
    FL.LootChat.uiRefreshCallback = function() page:Refresh(); end;

    ----------------------------------------------------------------------
    -- Positions/sizes this whole section for a given top Y and returns
    -- where the NEXT thing should start - page:Section's own machinery has
    -- no way to see this manually-built content, same reason
    -- PageMethods:ComingSoon sets contentBottomOverride explicitly. Also
    -- the page-specific half of PageMethods:Layout's re-layout pass (see
    -- the page:AddLayoutHook call at the very end of this buildFunc) -
    -- leftSection:Reflow() re-measures its checkboxes' wrapped helper text,
    -- which can come back a line taller/shorter once this client's
    -- fonts/geometry have actually settled.
    ----------------------------------------------------------------------

    local function layoutLootChatSection(top)
        outer:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, top);
        local leftHeight = leftSection:Reflow();
        local sectionContentHeight = math.max(leftHeight, lootChatEditor.frame:GetHeight());
        local height = (-innerTop) + sectionContentHeight;
        outer:SetHeight(height);
        return top - height;
    end

    page.contentBottomOverride = layoutLootChatSection(outerTop);

    --------------------------------------------------------------------------
    -- "Automatic Rolls" section - full width, stacked under Loot Chat above,
    -- same internal 2-column split.
    --------------------------------------------------------------------------

    local arOuterTop = nextSectionTop(page);

    local arOuter = CreateFrame("Frame", nil, page.frame);
    arOuter:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, arOuterTop);
    arOuter:SetWidth(page.contentWidth);

    local arTitle = arOuter:CreateFontString(nil, "OVERLAY");
    SetFont(arTitle, "sectionHeader");
    arTitle:SetTextColor(unpack(Colors.gold));
    arTitle:SetPoint("TOPLEFT", arOuter, "TOPLEFT", 0, 0);
    arTitle:SetText("Automatic Rolls");

    local arDivider = arOuter:CreateTexture(nil, "ARTWORK");
    arDivider:SetColorTexture(unpack(Colors.divider));
    arDivider:SetPoint("TOPLEFT", arTitle, "BOTTOMLEFT", 0, -6);
    arDivider:SetPoint("TOPRIGHT", arOuter, "TOPRIGHT", 0, 0);
    arDivider:SetHeight(FL.Pixel.PixelSize(1));

    local arInnerTop = -(arTitle:GetStringHeight() + 6 + Sizes.layout.rowGap);

    ----------------------------------------------------------------------
    -- Left column: "In raid instances" radio group + warning box + note.
    ----------------------------------------------------------------------

    local arLeftFrame = CreateFrame("Frame", nil, arOuter);
    arLeftFrame:SetPoint("TOPLEFT", arOuter, "TOPLEFT", 0, arInnerTop);
    arLeftFrame:SetWidth(colWidth);

    local arLeftSection = setmetatable({
        page = page,
        frame = arLeftFrame,
        width = colWidth,
        startY = 0,
        nextRowY = 0,
        rows = {},
        items = {},
    }, Widgets.SectionMethods);

    local AR = Sizes.autoRoll;

    -- Warning box (built before the radio group so its onChange can toggle
    -- it - the frame just isn't anchored/shown until the radios exist).
    local warningBox = CreateFrame("Frame", nil, arLeftFrame, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(warningBox, Colors.councilFill, Colors.selectedBorder, 1);
    local warningText = warningBox:CreateFontString(nil, "OVERLAY");
    SetFont(warningText, "small");
    warningText:SetPoint("TOPLEFT", warningBox, "TOPLEFT", AR.warningPadding, -AR.warningPadding);
    warningText:SetPoint("TOPRIGHT", warningBox, "TOPRIGHT", -AR.warningPadding, -AR.warningPadding);
    warningText:SetJustifyH("LEFT");
    warningText:SetWordWrap(true);
    warningText:SetText("Need on everything can take gear other players need. Check your raid's loot rules first.");
    warningText:SetTextColor(unpack(Colors.text));

    local function layoutWarningBox()
        warningBox:SetHeight(warningText:GetStringHeight() + AR.warningPadding * 2);
    end

    arLeftSection:RadioGroup{
        key = "autoRoll.mode",
        default = "ask",
        options = {
            { value = "manual", label = "Manual", desc = "Roll yourself, like normal." },
            { value = "need",   label = "Need on everything" },
            { value = "greed",  label = "Greed on everything" },
            { value = "pass",   label = "Pass on everything" },
            { value = "ask",    label = "Ask when I enter a raid",
              desc = "Shows a popup when you zone into a raid. Your answer lasts until you log out, so run-backs after a wipe don't ask again. Type /fl autoroll to reopen it mid-raid." },
        },
        onChange = function(value)
            warningBox:SetShown(value == "need");
            -- warningText's GetStringHeight() comes back short while the box
            -- is hidden (same class of measurement-not-settled-yet quirk as
            -- Registry.LayoutCurrentPage's own comment below), so switching
            -- to "need" needs an immediate re-layout instead of waiting for
            -- the next tab switch to fix the wrapped height.
            FL.UI.SettingsRegistry.LayoutCurrentPage();

            -- A deliberate change made HERE, in Settings, is more specific
            -- than a stale per-instance session choice (from the raid-entry
            -- popup or /fl autoroll) - it must win immediately, so this
            -- forgets that choice for the current instance rather than
            -- letting GetEffectiveMode() keep favoring it. Only while
            -- actually in scope (raid + group loot); outside scope there's
            -- nothing to override or announce. Dungeons ignore this setting
            -- entirely, so a dungeon's /fl autoroll choice is left alone.
            if (FL.AutoRoll.ScopeOK() and not FL.AutoRoll.IsDungeon()) then
                local instanceID = select(8, GetInstanceInfo());
                if (instanceID) then
                    FL.Settings.SetAutoRollSessionChoice(instanceID, nil);
                end
                if (value == "ask") then
                    -- Forgetting the session choice is exactly what makes
                    -- this instance "unanswered" again - reopen the popup
                    -- immediately instead of printing a mode message.
                    FL.UI.AutoRollPopup.Show();
                else
                    FL.AutoRoll.PrintModeMessage(value);
                end
            end
        end,
    };

    -- Fixed relative to arLeftFrame's own (unchanging) width - set once, not
    -- part of the reflow below.
    warningBox:SetPoint("RIGHT", arLeftFrame, "RIGHT", 0, 0);

    local noteText = arLeftFrame:CreateFontString(nil, "OVERLAY");
    SetFont(noteText, "small");
    noteText:SetPoint("RIGHT", arLeftFrame, "RIGHT", 0, 0);
    noteText:SetJustifyH("LEFT");
    noteText:SetWordWrap(true);
    noteText:SetText("Automatic Rolls and overrides only work in instances set to group loot. Dungeons always roll manually unless you type /fl autoroll inside one; overrides apply in both.");
    noteText:SetTextColor(unpack(Colors.autoRollMutedNote));

    -- Positions the warning box and note under the radio group and sizes
    -- arLeftFrame to fit - advanceSection isn't reachable from here
    -- (SectionMethods-private), so this manually walks
    -- arLeftSection.nextRowY the same way advanceSection would. Re-run from
    -- the page:AddLayoutHook call below (after arLeftSection:Reflow() has
    -- re-measured the radio group's own wrapped helper text and left
    -- nextRowY at the corrected post-group position - see
    -- SectionMethods:Reflow), same reason layoutLootChatSection re-runs
    -- leftSection:Reflow() above.
    local function layoutAutoRollLeft()
        arLeftSection:Reflow();

        warningBox:SetPoint("TOPLEFT", arLeftFrame, "TOPLEFT", 0, arLeftSection.nextRowY);
        layoutWarningBox();
        arLeftSection.nextRowY = arLeftSection.nextRowY - warningBox:GetHeight() - AR.warningGap;

        noteText:SetPoint("TOPLEFT", arLeftFrame, "TOPLEFT", 0, arLeftSection.nextRowY);
        arLeftSection.nextRowY = arLeftSection.nextRowY - noteText:GetStringHeight() - AR.noteGap;

        arLeftFrame:SetHeight(-arLeftSection.nextRowY);
    end

    -- layoutAutoRollLeft() itself runs below, via layoutAutoRollSection ->
    -- page.contentBottomOverride = layoutAutoRollSection(arOuterTop) - no
    -- need to call it twice for the initial build.
    warningBox:SetShown(FL.Settings.GetAutoRollMode() == "need");

    table.insert(page.refreshers, function() warningBox:SetShown(FL.Settings.GetAutoRollMode() == "need"); end);
    table.insert(page.resettableKeys, { key = "autoRoll.clearSessionChoices", default = true });

    ----------------------------------------------------------------------
    -- Right column: "Always roll on these items" (shared ItemListEditor,
    -- with a per-row rule dropdown).
    ----------------------------------------------------------------------

    local arRightFrame = CreateFrame("Frame", nil, arOuter);
    arRightFrame:SetPoint("TOPLEFT", arOuter, "TOPLEFT", colWidth + COLUMN_GAP, arInnerTop);
    arRightFrame:SetWidth(colWidth);

    local RULE_TITLE = FL.Constants.AUTO_ROLL_RULE_TITLE;
    local RULE_ORDER = FL.Constants.AUTO_ROLL_RULE_ORDER;

    local function ruleDropdownOptions()
        local dropdownOpts = {};
        for _, rule in ipairs(RULE_ORDER) do
            table.insert(dropdownOpts, { value = rule, label = RULE_TITLE[rule], color = Colors.autoRollRule[rule] });
        end
        return dropdownOpts;
    end

    local function getSortedOverrideItemIDs()
        local list = {};
        for itemID, entry in pairs(FL.Settings.GetAutoRollOverrides()) do
            table.insert(list, { itemID = itemID, order = entry.order });
        end
        table.sort(list, function(a, b) return a.order > b.order; end);

        local ids = {};
        for _, entry in ipairs(list) do table.insert(ids, entry.itemID); end
        return ids;
    end

    local overrideEditor;
    overrideEditor = ItemListEditor.Create(arRightFrame, {
        width = colWidth,
        headerLabel = "Automatic Roll Overrides",
        emptyText = "No overrides. Every item follows the raid setting.",
        rowIconSize = AR.rowIconSize,
        extraSlotWidth = AR.dropdownWidth + AR.dropdownGap,
        GetItems = getSortedOverrideItemIDs,
        IsAlreadyListed = FL.Settings.IsAutoRollOverride,
        ValidateAdd = function() return true; end, -- no quality restriction
        AddItem = function(itemID) FL.Settings.AddOrUpdateAutoRollOverride(itemID, "need"); end,
        RemoveItem = FL.Settings.RemoveAutoRollOverride,
        FormatAddedStatus = function(name) return "Added " .. name .. " as Always Need."; end,
        FormatAlreadyListedStatus = function(name, itemID)
            local rule = FL.Settings.GetAutoRollOverride(itemID) or "need";
            return ("%s is already on the list (Always %s)."):format(name, RULE_TITLE[rule]);
        end,
        GetHeaderCountText = function(items)
            local counts = { need = 0, greed = 0, pass = 0, manual = 0 };
            for _, itemID in ipairs(items) do
                local rule = FL.Settings.GetAutoRollOverride(itemID) or "need";
                counts[rule] = counts[rule] + 1;
            end
            local parts = {};
            for _, rule in ipairs(RULE_ORDER) do
                if (counts[rule] > 0) then table.insert(parts, counts[rule] .. " " .. rule); end
            end
            return (#parts == 0) and "0 items" or table.concat(parts, " \194\183 "); -- " · "
        end,
        CreateRowExtra = function(row, extraSlotFrame)
            local dropdown = Skin.Dropdown(extraSlotFrame, {
                width = AR.dropdownWidth,
                height = AR.dropdownHeight,
                xOffset = -2,
                textPaddingLeftRight = 3,
                options = ruleDropdownOptions(),
                getValue = function() return row.itemID and (FL.Settings.GetAutoRollOverride(row.itemID) or "need"); end,
                onSelect = function(value)
                    if (not row.itemID) then return; end
                    FL.Settings.AddOrUpdateAutoRollOverride(row.itemID, value);
                    local name = Util.GetItemInfo(row.itemID) or ("Item " .. row.itemID);
                    overrideEditor:SetStatus("success", ("Changed %s to Always %s."):format(name, RULE_TITLE[value]));
                    overrideEditor:Refresh();
                end,
            });
            dropdown.button:SetPoint("RIGHT", extraSlotFrame, "RIGHT", 0, 0);
            row.ruleDropdown = dropdown;
        end,
        PaintRowExtra = function(row)
            if (row.ruleDropdown) then row.ruleDropdown.Refresh(); end
        end,
        -- IsEnabled intentionally omitted (defaults to always-true) - this
        -- list is never dimmed by mode, per spec.
    });
    FL.UI.SettingsWindow.sectionAnchors = FL.UI.SettingsWindow.sectionAnchors or {};
    FL.UI.SettingsWindow.sectionAnchors["autoRoll"] = arOuter;

    -- Same shape as layoutLootChatSection above - positions/sizes this
    -- section for a given top Y and returns where the next thing should
    -- start. overrideEditor's own rows are fixed-height (not text-wrap
    -- dependent), so only arLeftFrame's side needs a real re-layout.
    local function layoutAutoRollSection(top)
        arOuter:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, top);
        layoutAutoRollLeft();
        -- See rightFrame's own SetHeight in layoutLootChatSection above for
        -- why this container needs an explicit height.
        arRightFrame:SetHeight(overrideEditor.frame:GetHeight());
        local sectionContentHeight = math.max(arLeftFrame:GetHeight(), overrideEditor.frame:GetHeight());
        local height = (-arInnerTop) + sectionContentHeight;
        arOuter:SetHeight(height);
        return top - height;
    end

    page.contentBottomOverride = layoutAutoRollSection(arOuterTop);

    -- Re-run both full-width sections' layout once this client's
    -- fonts/geometry have actually settled (Registry.lua's
    -- Registry.LayoutCurrentPage, via PageMethods:Layout) - page:Section's
    -- own 2-column grid is redone first, so page:contentBottom() below
    -- already reflects the (possibly corrected) "Roll Popup" section;
    -- resetting contentBottomOverride to nil first is what makes
    -- nextSectionTop fall back to that instead of reusing the previous
    -- pass's final (Automatic Rolls) bottom.
    page:AddLayoutHook(function()
        page.contentBottomOverride = nil;
        page.contentBottomOverride = layoutLootChatSection(nextSectionTop(page));
        page.contentBottomOverride = layoutAutoRollSection(nextSectionTop(page));
    end);
end, 30);
