--[[
General settings page: window-management options (Reset Window Positions,
moved here unchanged from the old ConfigWindow) and a full-width "Sounds"
section - left column an on-by-default enable checkbox per sound the addon
plays, right column a matching LibSharedMedia "sound" dropdown letting the
user pick which sound file plays for that event (see RollTracker.lua's
roll-off start, Util.playConfiguredSound). Full width (rather than
page:Section's normal 2-column grid) because more sounds/checkboxes are
expected here later - see LootRolls.lua's own hand-built full-width "Loot
Chat" section for the left-checkboxes/right-content pattern this follows.

Below Sounds, a full-width "Trade Queue" section with the bag highlight
toggle (BagHighlight.lua, EllesmereUI Bags or Baganator) - greyed out, with
its desc swapped for a "requires" note, when neither bag addon is loaded.
]]

local FL = ForeverLoot;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Widgets = FL.UI.SettingsWidgets;
local LSM = LibStub("LibSharedMedia-3.0");

-- Deliberately its own value, not Widgets.lua's private COLUMN_GAP (which
-- only governs the page's own top-level 2-column grid) - same reasoning as
-- LootRolls.lua's own COLUMN_GAP.
local COLUMN_GAP = 21;
-- Same value as Widgets.lua's own private ROW_SPACING - used below by
-- layoutSoundsSection's paired reflow (SectionMethods:Reflow can't be reused
-- as-is here since each side needs to advance by the OTHER side's height too
-- whenever it's the taller one - see that function's own comment).
local ROW_SPACING = Sizes.layout.rowGap;

-- `sentinelKey`, when given, is prepended as its own row so a dropdown can
-- offer a Blizzard built-in sound (FL.Constants.SOUND_RAID_WARNING_KEY or
-- SOUND_BNET_TOAST_KEY - sentinels Util.playConfiguredSound special-cases,
-- not real LSM entries) above every real LSM:List("sound") key.
local function soundOptions(sentinelKey, sentinelLabel)
    local options = {};
    if (sentinelKey) then
        table.insert(options, { value = sentinelKey, label = sentinelLabel });
    end
    for _, key in ipairs(LSM:List("sound")) do
        table.insert(options, { value = key, label = key });
    end
    return options;
end

-- Builds a full-width section shell (gold title + divider) on the page and
-- returns its outer frame plus the Y offset (inside that frame) where its
-- content starts. The caller positions the outer frame and sets its height.
local function buildFullWidthSection(page, title)
    local outer = CreateFrame("Frame", nil, page.frame);
    outer:SetWidth(page.contentWidth);

    local titleText = outer:CreateFontString(nil, "OVERLAY");
    SetFont(titleText, "sectionHeader");
    titleText:SetTextColor(unpack(Colors.gold));
    titleText:SetPoint("TOPLEFT", outer, "TOPLEFT", 0, 0);
    titleText:SetText(title);

    local divider = outer:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -6);
    divider:SetPoint("TOPRIGHT", outer, "TOPRIGHT", 0, 0);
    divider:SetHeight(FL.Pixel.PixelSize(1));

    return outer, -(titleText:GetStringHeight() + 6 + Sizes.layout.rowGap);
end

FL.UI.SettingsWindow.RegisterPage("general", "General", function(page)
    page:Header("General");

    local section = page:Section("Windows", 1);
    section:Button{
        label = "Reset Window Positions",
        width = 200,
        onClick = function()
            if (FL.ResetAllWindowPositions) then
                FL.ResetAllWindowPositions();
                print("|cff8865ffForeverLoot|r window positions reset to default.");
            end
        end,
    };
    section:Checkbox{
        key = "general.minimapButton",
        label = "Enable minimap button",
        desc = "Shows the ForeverLoot button on the minimap. Middle-clicking the button also turns this off.",
        default = true,
    };

    --------------------------------------------------------------------------
    -- "Sounds" section - full width, below the normal 2-column grid above.
    -- Anchored off page:contentBottom() (not a second page:Section column),
    -- since page:Section's own 2-column bookkeeping has no full-width option.
    --------------------------------------------------------------------------

    local soundsTop = page:contentBottom() - Sizes.layout.sectionGap;

    local soundsOuter, soundsInnerTop = buildFullWidthSection(page, "Sounds");
    soundsOuter:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, soundsTop);
    local colWidth = math.floor((page.contentWidth - COLUMN_GAP) / 2);

    ----------------------------------------------------------------------
    -- Left column: one enable checkbox per sound event.
    ----------------------------------------------------------------------

    local leftFrame = CreateFrame("Frame", nil, soundsOuter);
    leftFrame:SetPoint("TOPLEFT", soundsOuter, "TOPLEFT", 0, soundsInnerTop);
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

    leftSection:Checkbox{
        key = "sounds.raidWarning",
        label = "Roll-off start sound",
        desc = "Plays a sound when a roll-off starts.",
        default = true,
    };

    leftSection:Checkbox{
        key = "sounds.selfSR",
        label = "Your soft-reserve roll alert",
        desc = "Plays a different sound when a roll-off starts for one of your own soft-reserved items.",
        default = true,
    };

    ----------------------------------------------------------------------
    -- Right column: which sound plays for each event above, via a fresh
    -- SectionMethods object (same as the left column) so :Dropdown works
    -- exactly as it does on the page's normal 2-column grid.
    ----------------------------------------------------------------------

    local rightFrame = CreateFrame("Frame", nil, soundsOuter);
    rightFrame:SetPoint("TOPLEFT", soundsOuter, "TOPLEFT", colWidth + COLUMN_GAP, soundsInnerTop);
    rightFrame:SetWidth(colWidth);

    local rightSection = setmetatable({
        page = page,
        frame = rightFrame,
        width = colWidth,
        startY = 0,
        nextRowY = 0,
        rows = {},
        items = {},
    }, Widgets.SectionMethods);

    -- Plays a row's sound once on the Master channel so the user can hear it
    -- before picking it - same resolver RollTracker.lua's real playback uses,
    -- so the preview always matches what actually plays.
    local function previewSound(key)
        FL.Util.playConfiguredSound(key, "Master");
    end

    rightSection:Dropdown{
        key = "sounds.raidWarningSound",
        label = "Roll-off start sound",
        options = soundOptions(FL.Constants.SOUND_RAID_WARNING_KEY, "Raid Warning (Blizzard default)"),
        default = FL.Constants.SOUND_RAID_WARNING_KEY,
        rowHeight = 20,
        maxVisibleRows = 12,
        onPreview = previewSound,
    };

    rightSection:Dropdown{
        key = "sounds.selfSRSound",
        label = "Soft-reserve alert sound",
        options = soundOptions(FL.Constants.SOUND_BNET_TOAST_KEY, "Battle.net Toast (Blizzard default)"),
        default = FL.Constants.SOUND_BNET_TOAST_KEY,
        rowHeight = 20,
        maxVisibleRows = 12,
        onPreview = previewSound,
    };

    -- Positions/sizes this section for a given top Y and returns where the
    -- next thing should start - same shape as LootRolls.lua's
    -- layoutLootChatSection/layoutAutoRollSection, EXCEPT it doesn't call
    -- leftSection:Reflow()/rightSection:Reflow() independently (those each
    -- advance purely off their OWN column's row heights, and a checkbox's
    -- wrapped desc text is almost always taller than its paired dropdown's
    -- fixed row height, so the two columns drift out of sync after the
    -- first row). Instead this walks both columns' item lists in lockstep,
    -- one pair (checkbox + its dropdown) at a time, anchoring both at the
    -- SAME y and advancing both by whichever of the two is taller - keeping
    -- every checkbox lined up with its own dropdown. Relies on
    -- leftSection.items and rightSection.items having one entry per sound
    -- event, added in the same order (true as long as each event gets
    -- exactly one leftSection:Checkbox + one rightSection:Dropdown call
    -- above, in event order).
    local function layoutSoundsSection(top)
        soundsOuter:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, top);

        local y = 0;
        for i = 1, #leftSection.items do
            local leftItem = leftSection.items[i];
            local rightItem = rightSection.items[i];

            leftItem.frame:SetPoint("TOPLEFT", leftFrame, "TOPLEFT", leftItem.x, y);
            rightItem.frame:SetPoint("TOPLEFT", rightFrame, "TOPLEFT", rightItem.x, y);

            local leftHeight = leftItem.remeasure and leftItem.remeasure() or leftItem.height or leftItem.frame:GetHeight();
            local rightHeight = rightItem.remeasure and rightItem.remeasure() or rightItem.height or rightItem.frame:GetHeight();

            y = y - math.max(leftHeight, rightHeight) - ROW_SPACING;
        end

        leftFrame:SetHeight(math.max(1, -y));
        rightFrame:SetHeight(math.max(1, -y));

        local height = (-soundsInnerTop) + math.max(1, -y);
        soundsOuter:SetHeight(height);
        return top - height;
    end

    --------------------------------------------------------------------------
    -- "Trade Queue" section - full width, below Sounds. One column (a single
    -- SectionMethods spanning the whole width), so it reflows normally.
    --------------------------------------------------------------------------

    local tradeOuter, tradeInnerTop = buildFullWidthSection(page, "Trade Queue");

    local tradeFrame = CreateFrame("Frame", nil, tradeOuter);
    tradeFrame:SetPoint("TOPLEFT", tradeOuter, "TOPLEFT", 0, tradeInnerTop);
    tradeFrame:SetWidth(page.contentWidth);

    local tradeSection = setmetatable({
        page = page,
        frame = tradeFrame,
        width = page.contentWidth,
        startY = 0,
        nextRowY = 0,
        rows = {},
        items = {},
    }, Widgets.SectionMethods);

    local bagsAvailable = FL.BagHighlight.IsAvailable();
    local highlightRow = tradeSection:Checkbox{
        key = "bags.tradeQueueHighlight",
        label = "Highlight Trade Queue items in bags",
        desc = bagsAvailable
            and "Adds a glow, colored by item quality, to items in your bags that are waiting in the Trade Queue. Works with EllesmereUI Bags and Baganator."
            or "Requires EllesmereUI Bags or Baganator to be enabled.",
        default = true,
    };
    if (not bagsAvailable) then highlightRow:SetEnabledState(false); end

    -- Same contract as layoutSoundsSection: position at `top`, return where
    -- the next thing should start.
    local function layoutTradeQueueSection(top)
        tradeOuter:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, top);
        local innerHeight = tradeSection:Reflow();
        local height = (-tradeInnerTop) + innerHeight;
        tradeOuter:SetHeight(height);
        return top - height;
    end

    local function layoutFullWidthSections(top)
        local afterSounds = layoutSoundsSection(top);
        return layoutTradeQueueSection(afterSounds - Sizes.layout.sectionGap);
    end

    page.contentBottomOverride = layoutFullWidthSections(soundsTop);

    -- Re-run once this client's fonts/geometry have actually settled
    -- (Registry.LayoutCurrentPage, via PageMethods:Layout) - page:Section's
    -- own 2-column grid ("Windows") is redone first, so page:contentBottom()
    -- below already reflects it.
    page:AddLayoutHook(function()
        page.contentBottomOverride = nil;
        page.contentBottomOverride = layoutFullWidthSections(page:contentBottom() - Sizes.layout.sectionGap);
    end);

    -- No opts.footer passed to RegisterPage below - this page gets the
    -- default footer ("Changes save automatically", plus "Reset This Page"
    -- now that the Sounds checkboxes/dropdowns above have registered
    -- resettable keys).
end, 10);
