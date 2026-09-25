--[[
Every real size in the addon's UI - font point-sizes, control dimensions,
list row/icon heights, window paddings, a handful of other windows' overall
dimensions - lives here instead of as an inline literal in the file that
uses it. See UI/Theme/Fonts.lua's UI.SetFont for how `fonts` is consumed.

`fonts.windowTitle/pageTitle/sectionHeader/body/small` are the 5 semantic
roles UI/SettingsWindow/* is fully built on (via UI.SetFont) - every other
named font below is an addon-wide Theme.fonts object keeping its own current
size unchanged (just moved out of a literal). Other windows migrate onto the
5 role keys as they get their own redesign pass later.
]]

local FL = ForeverLoot;

FL.UI.Sizes = {
    fonts = {
        -- Settings-window semantic roles - UI.SetFont, UI/SettingsWindow/* only.
        windowTitle   = 14,
        pageTitle     = 18,
        sectionHeader = 13,
        body          = 12,
        small         = 10,
        search        = 11,

        -- Every other Theme.fonts object's point size (unchanged values,
        -- just moved out of UI/Theme/Fonts.lua's old inline DefineFont calls).
        normal = 12, normalMedium = 14, normalLarge = 16, normalSmall = 10,
        highlight = 12, highlightLarge = 14, highlightMedium = 12, highlightSmall = 10,
        disableSmall = 10, title = 12, titleLarge = 16, hero = 40,
        button = 12, buttonDisabled = 12, input = 14,

        -- Blizzard-panel "Open Settings" button label (UI/OptionsPanel.lua) -
        -- one point above the `body` role it's otherwise built from. Has to
        -- live here (flat), not under `optionsPanel` below, because
        -- UI.SetFont only ever looks a size key up in this table.
        optionsPanelButton = 13,
    },

    controls = {
        button = 22, input = 22, dropdown = 24, dropdownArrow = 18,
        checkbox = 16, checkboxRow = 20, navRow = 22, close = 20, closeIcon = 10,
    },

    lists = {
        memberButton = 20, sessionRow = 36, sessionIcon = 26, reviewRow = 28,
        equippedIcon = 20, itemGridIcon = 32,
    },

    layout = {
        settingsWindow = { width = 900, height = 570 },
        sidebarWidth = 160, pagePadding = 20, rowGap = 8, sectionGap = 18, footerHeight = 34,

        -- Sidebar internal chrome (search box + nav list) - see
        -- UI/SettingsWindow/Init.lua's createSidebar and Registry.lua's
        -- Registry.Build. sidebarTextInset is shared by the search box's own
        -- text inset and the nav label inset so both always land on the same
        -- x regardless of sidebarPadX.
        sidebarPadX = 8, sidebarPadTop = 12, sidebarTextInset = 10,
        searchNavGap = 10, navItemGap = 2, navDividerGap = 6,

        -- The settings window's own slim scrollbar (Init.lua's
        -- createContentArea/Skin.ScrollBar) - scrollbarGutter is the space
        -- reserved for it outside the scrollable content's own width. 12,
        -- not 14: the window border fix (Init.lua's BORDER_INSET) costs 2px
        -- of that margin on the content area's right edge, and the window
        -- itself can't grow to cover it (kept at a fixed 900x570) - a
        -- 6-wide bar at a 4px inset (reaching 10px) still fits inside 12.
        scrollbarWidth = 6, scrollbarInset = 4, scrollbarGutter = 12,
    },

    -- Other windows' overall dimensions - deliberately not scaled down
    -- further (they haven't had their own control-level redesign pass yet).
    windows = {
        reviewVote = { width = 830, height = 495 },
    },

    -- UI/StartSessionWindow.lua - built on the settings window's own control
    -- vocabulary (UI.Colors/UI.SetFont/UI.Skin), not FL.Theme, so its layout
    -- gets its own top-level table here rather than nesting under `windows`.
    --
    -- window.height is DERIVED from the pieces below (not a literal) so the
    -- item list always shows exactly `visibleRows` rows with no partial row
    -- peeking in - see the listBoxHeight/windowHeight locals.
    startSession = (function()
        local visibleRows = 6;
        local rowHeight = 36;
        local rowSpacing = 3;
        local listPadding = 6;
        local listLabelGap = 4;
        local listLabelHeight = 12; -- rendered height of the "ITEMS" label line
        local listBorderSpace = 2; -- 1px backdrop border, top + bottom
        local titleBarHeight = 32;
        local contentPadTop = 14;
        local headerHeight = 37;
        local dropStripGap = 10;
        local dropStripHeight = 34;
        local listGap = 10;
        local footerScrollGap = 10; -- listBox bottom -> footer's top (divider) gap
        local footerRowHeight = 22;
        local footerDividerGap = 8; -- divider -> button row
        local footerDividerHeight = 1;
        local footerHeight = footerDividerHeight + footerDividerGap + footerRowHeight;
        local footerBottomPad = 12;

        local listContentHeight = visibleRows * rowHeight + (visibleRows - 1) * rowSpacing;
        local listBoxHeight = listPadding + listLabelHeight + listLabelGap + listContentHeight + listPadding + listBorderSpace;

        local windowHeight = titleBarHeight + contentPadTop + headerHeight + dropStripGap + dropStripHeight
            + listGap + listBoxHeight + footerScrollGap + footerHeight + footerBottomPad;

        return {
            window = { width = 340, height = windowHeight },
            visibleRows = visibleRows,
            titleBarHeight = titleBarHeight,
            contentPadX = 16,
            contentPadTop = contentPadTop,

            headerHeight = headerHeight,
            headerSubtitleGap = 4,
            headerAddAllWidth = 70,
            headerAddAllHeight = 22,

            dropStripGap = dropStripGap,
            dropStripHeight = dropStripHeight,
            dropStripDash = 4,

            listGap = listGap,
            listPadding = listPadding,
            listLabelGap = listLabelGap,
            listScrollbarGap = 4, -- gap between the last row column and the scrollbar
            listScrollbarInset = 3, -- scrollbar -> listBox's own right border
            listBoxHeight = listBoxHeight,
            rowHeight = rowHeight,
            rowSpacing = rowSpacing,
            rowIconSize = 26,
            rowIconTextGap = 8,
            rowTextLineGap = 2,
            rowButtonSize = 20,
            rowButtonTextGap = 6,

            footerBottomPad = footerBottomPad,
            footerRowHeight = footerRowHeight,
            footerDividerGap = footerDividerGap,
            footerHeight = footerHeight,
            footerScrollGap = footerScrollGap,
            footerButtonGap = 8,
            footerClearWidth = 70,
            footerStartWidth = 130,
        };
    end)(),

    -- UI/RespondWindow.lua - built the same way as startSession above (own
    -- top-level table, UI.Colors/UI.SetFont/UI.Skin, not FL.Theme). Unlike
    -- startSession, window height is NOT derived here - the window is a
    -- stack of floating cards whose count/content is only known at runtime
    -- (RefreshWindow() sums the actual child heights each time), so only the
    -- per-piece constants live here.
    respond = {
        cardWidth = 360,
        stackSpacing = 6,
        cardPadding = 8,
        cardSectionGap = 6,
        shadowInset = 6,
        scrollMaxHeightPct = 0.60,

        headerHeight = 26,
        headerCloseSize = 18,
        headerTitleGap = 6,

        iconSize = 28,
        iconTextGap = 8,
        nameTypeGap = 2,
        sentIconSize = 10,
        sentIconGap = 4,

        allSentIconSize = 14,
        allSentRowHeight = 16,

        noteHeight = 20,
        noteTextInset = 8,

        buttonHeight = 20,
        buttonGap = 4,
        buttonDotSize = 6,
        buttonDotLabelGap = 4,
        maxResponseButtons = 7, -- pool size per card; today's Constants table has 5

        toggleBarHeight = 24,
        toggleSegmentGap = 4,
        toggleArrowSize = 8,

        timerTrackHeight = 6,
        timerBarGap = 6,
        timerGlowInsetX = 6,
        timerGlowInsetY = 4,
        timerSheenWidth = 40,
        timerSheenSpeedPxPerSec = 60,

        autoCloseSeconds = 15,
        fadeOutDuration = 0.3,

        sweepWidthPct = 0.60,
        sweepDuration = 0.75,
        sweepAlpha = 0.35,
        borderFlashDuration = 1.2,

        togglePulseBorderDuration = 0.9,
        togglePulseGlowInset = 8,
        togglePulseGlowScaleFrom = 1.0,
        togglePulseGlowScaleTo = 1.08,
        togglePulseGlowAlphaFrom = 0.6,
    },

    -- The Blizzard-side AddOns list panel (UI/OptionsPanel.lua) - gaps
    -- between its 4 stacked elements, the version/keycap box chrome, and the
    -- Open Settings button's own size.
    optionsPanel = {
        descriptionGap = 8,  -- wordmark -> description
        versionGap     = 8,  -- description -> version badge
        buttonGap      = 20, -- version badge -> Open Settings button
        hintGap        = 8,  -- button -> "or type /fl config anytime" line
        boxHeight      = 16, -- version badge and keycap boxes
        badgePadX      = 8,  -- version badge horizontal padding
        keycapPadX     = 6,  -- keycap horizontal padding
        keycapSpacing  = 4,  -- gap either side of the keycap in the hint line
        buttonWidth    = 180,
        buttonHeight   = 26,
    },
};
