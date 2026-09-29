--[[
Every real size in the addon's UI - font point-sizes, control dimensions,
list row/icon heights, window paddings, a handful of other windows' overall
dimensions - lives here instead of as an inline literal in the file that
uses it. See UI/Theme/Fonts.lua's UI.SetFont for how `fonts` is consumed.

`fonts.windowTitle/pageTitle/sectionHeader/body/small/helper` are the 6
semantic roles UI/SettingsWindow/* is fully built on (via UI.SetFont) - every
other named font below is an addon-wide Theme.fonts object keeping its own
current size unchanged (just moved out of a literal). Other windows migrate
onto these role keys as they get their own redesign pass later.
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
        -- Checkbox/radio helper text (Widgets.BuildCheckboxRow, Skin.Radio) -
        -- one size down from `small`, per the item-anatomy spec those two
        -- share.
        helper        = 9,
        smaller       = 8, -- two sizes down from `small`; AwardWindow response-pill label's last shrink step before it ellipsizes
        tiny          = 7.5, -- RespondWindow note popover's "Enter to save" hint

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
        checkbox = 16, navRow = 22, close = 20, closeIcon = 10,
        -- Box's right edge -> label's left edge, for both Widgets.
        -- BuildCheckboxRow's checkbox rows and Skin.Radio's radio rows -
        -- shared so the two controls' item anatomy stays identical.
        checkboxLabelGap = 6,
    },

    lists = {
        memberButton = 20, sessionRow = 36, sessionIcon = 26,
        equippedIcon = 20, itemGridIcon = 32,
    },

    layout = {
        settingsWindow = { width = 900, height = 570 },
        -- rowGap: the constant gap between a section's rows, whatever a
        -- row's own (measured, not fixed) height is - mockup 13px * the
        -- shared 0.65 scale. Doubles as the section heading rule -> first
        -- row gap (PageMethods:Section, and LootRolls.lua's two hand-built
        -- full-width sections).
        sidebarWidth = 160, pagePadding = 20, rowGap = 8.5, sectionGap = 18, footerHeight = 34,

        -- Sidebar internal chrome (search box + nav list) - see
        -- UI/SettingsWindow/Init.lua's createSidebar and Registry.lua's
        -- Registry.Build. sidebarTextInset is shared by the search box's own
        -- text inset and the nav label inset so both always land on the same
        -- x regardless of sidebarPadX.
        sidebarPadX = 8, sidebarPadTop = 12, sidebarTextInset = 10,
        searchNavGap = 10, navItemGap = 2, navDividerGap = 6,

        -- Sidebar search-results list (Registry.lua's Registry.ApplySearch) -
        -- replaces the nav button list while a query is active. Each row is
        -- two lines (the setting's own label, then its page name in muted
        -- text), and its height is MEASURED per-row from the label's own
        -- (possibly wrapped) height rather than a fixed guess - a label
        -- longer than the sidebar is wide wraps to 2-3 lines. These are just
        -- the padding/gaps around that measured text.
        searchResultPadY = 4, searchResultLineGap = 2, searchResultGap = 4,

        -- The settings window's own slim scrollbar (Init.lua's
        -- createContentArea/Skin.ScrollBar) - scrollbarGutter is the space
        -- reserved for it outside the scrollable content's own width. 12,
        -- not 14: the window border fix (Init.lua's BORDER_INSET) costs 2px
        -- of that margin on the content area's right edge, and the window
        -- itself can't grow to cover it (kept at a fixed 900x570) - a
        -- 6-wide bar at a 4px inset (reaching 10px) still fits inside 12.
        scrollbarWidth = 6, scrollbarInset = 4, scrollbarGutter = 12,
    },

    -- UI/SettingsWindow/ItemListEditor.lua - the shared list widget (add row +
    -- scrollable item list + status line) used by both "Also print these
    -- items" (Loot Chat) and "Always roll on these items" (Automatic Rolls).
    itemListEditor = {
        addRowHeight = 24, addButtonWidth = 60, addRowGap = 8,
        rowHeight = 30, rowSpacing = 3, rowIconSize = 20, rowRemoveSize = 14, rowPadX = 6,
        visibleRows = 5, listPadding = 6,
        headerHeight = 16, statusHeight = 16, statusGap = 6,
        tagHeight = 13, tagPadX = 5,
    },

    -- UI/SettingsWindow/Pages/LootRolls.lua's "Automatic Rolls" section -
    -- pieces beyond the shared ItemListEditor above (the radio group's
    -- warning box, the rule dropdown, the section's flash-outline duration).
    autoRoll = {
        warningPadding = 8, warningGap = 8, noteGap = 10,
        rowIconSize = 15, -- mockup 24px/1.6 - overrides itemListEditor's default for this list
        dropdownWidth = 70, dropdownHeight = 16, dropdownGap = 6, -- mockup 96/25.6/6.4
        overrideFlashDuration = 1.4,
    },

    -- UI/AutoRollPopup.lua - the raid-entry popup. Own top-level table (like
    -- startSession/tradeQueue below), built the same IIFE-derived way since
    -- its content is fixed and its height is fully knowable up front.
    autoRollPopup = (function()
        local padding, gap = 11, 9; -- mockup 17.6/1.6, 14.4/1.6
        return {
            width = 312, padding = padding, gap = gap,
            titleBarHeight = 20, accentBarWidth = 3,
            gridTopMargin = 16, gridGap = 5, buttonHeight = 39, -- mockup 62.4/1.6
            -- Title -> subtitle gap (own value, distinct from `gap` above -
            -- this one's inside the header, not between sections).
            titleSubtitleGap = 3,
            -- Divider -> footer row gap - narrower than every other section
            -- gap above (`gap`), per the popup's own spec.
            footerGap = 7,
            footerDividerHeight = 1, viewOverridesHeight = 19,
            shadowInset = 6, -- same SoftGlow drop-shadow technique as UI/GroupLootFrame.lua
        };
    end)(),

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
        local listGap = 10;
        local footerScrollGap = 10; -- listBox bottom -> footer's top (divider) gap
        local footerRowHeight = 22;
        local footerDividerGap = 8; -- divider -> button row
        local footerDividerHeight = 1;
        local footerHeight = footerDividerHeight + footerDividerGap + footerRowHeight;
        local footerBottomPad = 12;

        local listContentHeight = visibleRows * rowHeight + (visibleRows - 1) * rowSpacing;
        local listBoxHeight = listPadding + listLabelHeight + listLabelGap + listContentHeight + listPadding + listBorderSpace;

        local windowHeight = titleBarHeight + contentPadTop + headerHeight
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

            -- Council button (left of Add All): icon + gap + count, sized to
            -- fit its own content rather than a fixed width.
            councilButtonHeight = 22,
            councilButtonGap = 6, -- gap to Add All's left edge
            councilButtonPadX = 3, -- left/right inset around the icon+count group
            councilButtonIconSize = 14,
            councilButtonIconTextGap = 4,

            dropZoneInset = 4, -- DropZone overlay's inset from listScroll's edges, each side
            dropZoneDash = 4,
            dropZoneIconSize = 12,
            dropZoneIconGap = 6, -- icon bottom -> main line top
            dropZoneLineGap = 2, -- main line bottom -> second line top

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
        -- Card/header/toggle-bar width never exceeds this fraction of
        -- UIParent's width, however wide the session's response list's
        -- labels naturally want to be (see RespondWindow.lua's
        -- updateCardWidthForSession) - same idiom as scrollMaxHeightPct
        -- above, just for width instead of height.
        cardWidthMaxPct = 0.60,

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

        -- noteHeight: the note's own control height - was the inline note
        -- EditBox's height (card redesign removed that row); now shared by
        -- the note popover's EditBox and Done button (both "~19 tall" by
        -- spec, deliberately locked to the same value). noteTextInset
        -- carries over unchanged to the popover's EditBox.
        noteHeight = 19,
        noteTextInset = 8,
        noteTextPlaceholderInset = 12,

        buttonHeight = 20,
        buttonGap = 4,
        buttonDotSize = 6,
        buttonDotLabelGap = 4,

        -- Button-row redesign: Note button + icon-only Transmog/Pass buttons,
        -- and the shared note popover (UI/RespondWindow.lua).
        noteButtonWidth = 19,
        iconButtonWidth = 26, -- Transmog/Pass width, both share this
        noteIconSize = 11, -- NoteIcon/NoteIconBadge layer size (stacked, centered)
        responseIconSize = 15, -- Transmog/Pass atlas icon size

        popoverPadding = 5,
        popoverRowGap = 5,
        popoverArrowWidth = 12,
        popoverArrowHeight = 6,
        popoverOffsetX = 5, -- popover TOPLEFT/TOPRIGHT x-inset from the card's BOTTOMLEFT/BOTTOMRIGHT
        popoverOffsetY = 3, -- popover y-offset from the card's bottom edge
        popoverArrowOffsetY = -1, -- arrow BOTTOMLEFT y-offset from the popover's TOPLEFT (overlaps the top border)
        popoverDoneButtonPadX = 12, -- horizontal text padding used to size the Done button off its own label width

        toggleBarHeight = 24,
        toggleSegmentGap = 4,
        toggleArrowSize = 8,

        timerTrackHeight = 6,
        timerBarGap = 6,
        timerSheenWidth = 40,
        sheenPeriod = 2.5,

        autoCloseSeconds = 15,
        fadeOutDuration = 0.3,

        -- Pending-card reflow: the just-answered card fades out while the
        -- remaining pending cards simultaneously slide up - deliberately
        -- much snappier than fadeOutDuration above, which is a
        -- whole-window close-out fade, not a per-card micro-transition.
        answeredCardFadeDuration = 0.12,
        pendingSlideDuration = 0.24,

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

    -- UI/AwardWindow.lua - built the same way as startSession/respond above
    -- (own top-level table, UI.Colors/UI.SetFont/UI.Skin, not FL.Theme).
    -- Replaces the old FL.Theme-based UI/LootCouncilReviewWindow.lua, whose
    -- own dimensions used to live in a now-removed `windows.reviewVote` entry.
    --
    -- Fixed 830x495 (no resize handle, unlike startSession's derived height).
    -- mainPanel.left/width and colNote are still DERIVED, not literals, so
    -- the item panel's width and the table's column widths can never drift
    -- out of sync with the panels/columns they're built from.
    award = (function()
        local windowWidth, windowHeight = 830, 495;
        local borderInset = 1; -- both panels sit inset 1 from the window border

        local itemPanelWidth = 196;
        local mainPanelLeft = borderInset + itemPanelWidth;
        local mainPanelWidth = windowWidth - borderInset - mainPanelLeft;

        local padX = 14;
        local rowPadX = 8; -- horizontal inset of row/column-header content from its own row's edges (distinct from padX, the mainPanel's own outer margin)
        local colPlayer, colEquipped, colResponse, colVotes, colVoteBtn = 130, 54, 86, 46, 26;
        local colGap = 8;
        local colNote = mainPanelWidth - padX * 2 - rowPadX * 2
            - (colPlayer + colEquipped + colResponse + colVotes + colVoteBtn) - colGap * 5;

        return {
            window = { width = windowWidth, height = windowHeight },
            titleBarHeight = 32,
            borderInset = borderInset,
            rowPadX = rowPadX,

            itemPanel = {
                width = itemPanelWidth,
                padding = 10,
                topRowHeight = 16,
                progressBarGap = 8,
                progressBarHeight = 4,
                sectionLabelHeight = 12,
                sectionLabelGap = 6,
                sectionGap = 10, -- between the two grids
                gridColumns = 5,
                gridIconSize = 32,
                gridSpacing = 4, -- 5*32 + 4*4 = 176 == itemPanelWidth - padding*2
                -- Quality border sits OUTSIDE the icon art (art is inset by
                -- this many px on each side) so a lowered-alpha icon (see
                -- assignedAlpha) never bleeds through/under the border ring.
                gridIconBorderThickness = 1,
                -- selectedRingGap is negative: the ring frame is only pulled
                -- (thickness + gap) px outside the icon, so with thickness=2
                -- and gap=-1 the drawn 2px-wide ring band spans from 1px
                -- outside the icon to 1px inside it - fully covering the 1px
                -- quality border underneath instead of just sitting next to it.
                selectedRingThickness = 2,
                selectedRingGap = -1,
                badgeSize = 12, -- CheckBadge.tga
                assignedAlpha = 0.45,
                hoverBrighten = 1.2, -- vertex-color multiplier, not a palette color
            },

            mainPanel = {
                left = mainPanelLeft,
                width = mainPanelWidth,
                padX = padX,
                padTop = 10,

                headerIconSize = 34,
                headerIconGap = 10,
                headerNameTypeGap = 2,
                badgeHeight = 16,
                badgePadX = 8,
                navButtonSize = 22, -- "‹" prev button (square)
                navButtonHeight = 22, -- "Next unassigned ›" (width auto per label)
                navButtonGap = 6,
                headerDividerGap = 10,

                columnHeaderHeight = 20,
                colPlayer = colPlayer, colEquipped = colEquipped, colResponse = colResponse,
                colNote = colNote, colVotes = colVotes, colVoteBtn = colVoteBtn, colGap = colGap,
                rowHeight = 28,
                rowSpacing = 2,
                equippedIconSize = 20,
                equippedIconGap = 3,
                -- Quality border sits OUTSIDE the icon art, same reasoning as
                -- itemPanel.gridIconBorderThickness.
                equippedIconBorderThickness = 1,
                pillHeight = 16, pillPadX = 8, pillDotSize = 6, pillDotGap = 4,
                voteButtonSize = 20,
                voteIconSize = 12, -- Plus.tga/Check.tga
                crownIconSize = 12, -- winner-icon slot in the Player cell; always reserved, icon shown only on the winner's row
                crownIconGap = 4, -- slot -> name

                footerDividerGap = 8,
                footerRowHeight = 20,
                mouseHintIconHeight = 22,
                mouseHintIconGap = 4,
            },

            popup = {
                width = 290,
                padding = 14,
                sectionGap = 10,
                titleHeight = 18,
                summaryPadding = 8,
                summaryIconSize = 28,
                summaryIconGap = 8,
                summaryLineGap = 4, -- item name -> "to <name>" -> response pill
                noteMaxLines = 3,
                warningPadding = 8,
                warningIconSize = 16,
                shadowInset = 8,
                buttonHeight = 22,
                buttonGap = 8,
                buttonWidth = 90,

                -- "End session early" confirm (Step: End Session Early) -
                -- summary box's counts row + wrapping unassigned-item icon row.
                endEarlySummaryPadding = 8,
                endEarlyRowGap = 8, -- counts row -> icon row
                endEarlyIconSize = 17,
                endEarlyIconBorderThickness = 1,
                endEarlyIconGap = 2.5,
                endEarlyMaxIcons = 12,
            },
        };
    end)(),

    -- UI/TradeQueueWindow.lua - built the same way as startSession above (own
    -- top-level table, UI.Colors/UI.SetFont/UI.Skin, not FL.Theme). Like
    -- startSession, window.height is DERIVED so the list always shows exactly
    -- `visibleRows` rows with no partial row peeking in.
    tradeQueue = (function()
        local visibleRows = 6;
        local rowHeight = 36;
        local rowSpacing = 3;
        local listPadding = 6;
        local listBorderSpace = 2; -- 1px backdrop border, top + bottom
        local titleBarHeight = 32;
        local contentPadTop = 14;
        local contentPadBottom = 12;
        local headerHeight = 37; -- title/count row + hint row
        local headerTitleRowHeight = 22;
        local sectionGap = 10; -- header->list and list->footer gap
        local footerDividerHeight = 1;
        local footerDividerGap = 8; -- divider -> status area
        local footerStatusHeight = 30; -- fixed: 2 lines of body font, never resizes
        local footerHeight = footerDividerHeight + footerDividerGap + footerStatusHeight;

        local listContentHeight = visibleRows * rowHeight + (visibleRows - 1) * rowSpacing;
        local listBoxHeight = listPadding + listContentHeight + listPadding + listBorderSpace;

        local windowHeight = titleBarHeight + contentPadTop + headerHeight
            + sectionGap + listBoxHeight + sectionGap + footerHeight + contentPadBottom;

        return {
            window = { width = 340, height = windowHeight },
            visibleRows = visibleRows,
            titleBarHeight = titleBarHeight,
            contentPadX = 16,
            contentPadTop = contentPadTop,
            contentPadBottom = contentPadBottom,

            headerHeight = headerHeight,
            headerTitleRowHeight = headerTitleRowHeight,
            headerHintGap = 4,
            sectionGap = sectionGap,

            listPadding = listPadding,
            listBoxHeight = listBoxHeight,
            listScrollbarGap = 4, -- gap between the last row column and the scrollbar
            listScrollbarInset = 3, -- scrollbar -> listBox's own right border
            rowHeight = rowHeight,
            rowSpacing = rowSpacing,
            rowIconSize = 26,
            rowIconTextGap = 8,
            rowTextLineGap = 2,
            rowStatusTagGap = 8, -- text block -> status tag, and status tag -> the main button's own right edge
            trashButtonSize = 20,
            trashButtonInset = 6, -- from the row's right edge

            footerHeight = footerHeight,
            footerDividerHeight = footerDividerHeight,
            footerDividerGap = footerDividerGap,
            footerStatusHeight = footerStatusHeight,
            footerDotSize = 6,
            footerDotGap = 6,

            emptyIconSize = 16,
            emptyIconTextGap = 6,
        };
    end)(),

    -- UI/LootHistoryWindow.lua - built the same way as startSession/respond/
    -- award/tradeQueue above (own top-level table, UI.Colors/UI.SetFont/
    -- UI.Skin, not FL.Theme). Sizes below come straight from the feature
    -- spec (already given in UI units); popup.padding/sectionGap use the
    -- codebase's own established Skin.ConfirmPopup values (14/10) rather than
    -- the spec's slightly-off 13/9, per "if a size is slightly different from
    -- the existing code, use the code's value."
    lootHistory = (function()
        return {
            window = { width = 930, height = 533 },
            titleBarHeight = 32,

            column = {
                date = 110, players = 150, items = 200,
                headerHeight = 26,
                filterTagPadX = 4, filterTagPadY = 1,

                searchHeight = 20, searchMarginX = 6.5, searchMarginTop = 5, searchMarginBottom = 2.5,

                listPad = 4,
                rowHeight = 21, rowGap = 1, rowPadLeft = 6, rowPadRight = 5,
                selectedBarWidth = 2,

                itemIconSize = 13, itemIconBorder = 1,
            },

            filterBar = {
                padY = 8, padX = 10, gap = 6.5,
                typeTagPadX = 5, typeTagPadY = 1,
                itemIconSize = 17, itemIconBorder = 1,
                addButtonHeight = 22,
                confirmLinePadX = 10,
                confirmDuration = 4,
            },

            resultList = { padTop = 8, gap = 4 },

            -- Shared response-pill metrics for the result row's meta line and
            -- the expanded candidate table - smaller than award.mainPanel's
            -- 16/8/6/4 pill to fit these tighter rows.
            pill = { height = 14, padX = 6, dotSize = 5, dotGap = 3 },

            resultRow = {
                collapsedHeight = 40, pad = 6, gap = 8,
                iconSize = 26, iconBorder = 1,
                textLineGap = 5, metaGap = 5,
                chevronSize = 16,
                manualTagGap = 5, manualTagPadX = 4,
            },

            expanded = {
                leftInset = 40, rightMargin = 6.5, bottomMargin = 6.5, topPad = 5,
                headerRowHeight = 14, rowHeight = 18, rowGap = 1,
                colCandidate = 104, colResponse = 72, colVotes = 39,
                crownSize = 9, crownGap = 3,
            },

            -- Add Entry modal (Skin.ConfirmPopup).
            popup = {
                width = 338, padding = 14, sectionGap = 10, titleHeight = 18,
                buttonHeight = 22, buttonGap = 8, buttonWidth = 90, shadowInset = 8,

                fieldLabelGap = 3, rowGap = 8,
                inputHeight = 22, dropdownXOffset = -2,
                classWidth = 97, dateWidth = 84, timeWidth = 71,
                previewPad = 5, previewIconSize = 15, previewIconBorder = 1,
                suggestionMaxRows = 6, suggestionRowHeight = 20,
                noteMaxLetters = 120,
            },
        };
    end)(),

    -- UI/RollWindow.lua - built the same way as startSession/respond/award
    -- above (own top-level table, UI.Colors/UI.SetFont/UI.Skin, not
    -- FL.Theme). Every state's height is content-driven and computed at
    -- runtime (even Setup's - the item header's text column can wrap taller
    -- than its icon depending on the item name/type, which isn't knowable
    -- until real FontStrings exist), so no window/section height is
    -- precomputed here, only the per-piece constants.
    --
    -- pill.height alone determines Skin.Pill's cap width (height / 2, see
    -- UI/SettingsWindow/Skin.lua's createPillSlices) - 14 here yields the
    -- spec's 7px caps with no separate key needed.
    roll = (function()
        local padding = 12;
        local titleBarHeight = 32;
        local headerIconSize = 26;

        return {
            window = { width = 300 },
            padding = padding,
            sectionGap = 9,
            titleBarHeight = titleBarHeight,
            expandDuration = 0.35,

            header = {
                iconSize = headerIconSize,
                iconGap = 8,
                nameTypeGap = 2,
            },

            setup = {
                rowHeight = 22,
                boxWidth = 36,
                boxHeight = 22,
                boxGap = 6,
                secGap = 4,
                buttonGap = 8,
            },

            -- Label -> bar uses the same top-level sectionGap as every other
            -- numbered piece in the "top to bottom, 9 apart" rolling layout.
            timer = {
                labelHeight = 16,
                barHeight = 8,
            },

            rollButtons = {
                height = 30,
                gap = 6,
            },

            hint = {
                height = 14,
                iconGap = 4,
            },

            list = {
                padding = 4,
                rowHeight = 22,
                rowGap = 2,
                maxVisibleRows = 6,
                emptyHeight = 40,
                rowPadX = 6,
                colGap = 6,
                colTags = 50,
                colRoll = 26,
                colCount = 18,
                crownSize = 12,
            },

            pill = {
                height = 14,
                padX = 6,
            },

            status = {
                dotSize = 6,
                gap = 8,
            },

            popup = {
                width = 290,
                padding = 14,
                sectionGap = 10,
                titleHeight = 18,
                summaryPadding = 8,
                summaryIconSize = 28,
                summaryIconGap = 8,
                summaryLineGap = 4,
                warningPadding = 8,
                warningIconSize = 16,
                shadowInset = 8,
                buttonHeight = 22,
                buttonGap = 8,
                buttonWidth = 90,
                -- 3-button "Award another copy?" row (Cancel/Reassign/Award
                -- Copy): 3*80 + 2*8 = 256 <= 290 - 2*14 = 262.
                buttonWidthNarrow = 80,
                rollNumberWidth = 40,
            },

            -- "Unawarded rolls" guard (RollWindow.lua's ensureGuard/showGuard) -
            -- a second, independent Skin.ConfirmPopup instance from popup
            -- above. width = window.width (300) minus a 10px inset each side.
            guard = {
                width = 280,
                padding = 11,
                sectionGap = 9,
                titleHeight = 18,
                shadowInset = 8,
                buttonHeight = 22,
                buttonGap = 6,
                buttonPadX = 14, -- text-fit padding - "Go Back" and "Start Without
                                 -- Awarding" are very different lengths, no shared
                                 -- fixed buttonWidth here
                itemBoxPadding = 8,
                iconSize = 25,
                iconTextGap = 8,
                lineGap = 4,
                topRollRowHeight = 18,
                topRollGap = 5,
                rollNumberGap = 6,
                warningPadX = 7,
                warningPadY = 6,
            },
        };
    end)(),

    -- UI/GroupLootFrame.lua - replaces the old ElvUI-style GroupLootRollBars.
    -- No fixed window height (same reason as roll above: the stack grows/
    -- shrinks with the header/idle box/row count/more bar, all content-
    -- driven at runtime via Pixel.SetHeight).
    groupLoot = {
        window = { width = 325 },
        pieceGap = 3,

        header = { height = 20, gripSize = 12, gripInset = 6, edgeInset = 8, titleGap = 6 },
        idle = { height = 36 },
        more = { height = 15 },

        row = {
            height = 38,
            padX = 6,
            partGap = 7,
            iconSize = 26,
            iconBorderThickness = 1,
            lineGap = 5,
            pillHeight = 11,
            pillPadX = 4,
            pillGapAfterName = 5,
            -- Upper-bound width reserved for a bind pill ("BoP"/"BoE", both
            -- 3 characters in the same small bold font) when deciding how
            -- much of the item name to truncate to - the pill itself is
            -- still sized exactly off its own rendered label width
            -- (Skin.Pill convention), this is only for the name's own
            -- truncation budget.
            pillReserveWidth = 34,
            buttonSize = 22,
            buttonIconSize = 18,
            -- Pass reads bigger than Need/Greed at the same pixel size and
            -- sits low in its own texture bounds - shrunk and nudged up;
            -- Greed nudged down to match. Need/Transmog use buttonIconSize
            -- centered, untouched.
            passIconSize = 14,
            passIconOffsetY = 0,
            greedIconOffsetY = -1,
            buttonGap = 2,
            -- Not a guessed literal: UI/GroupLootFrame.lua measures "60s" in
            -- the seconds label's own font the first time a row is built and
            -- caches the result here, so every row's label is exactly wide
            -- enough to never clip.
            secsWidth = nil,
            timerLabelGap = 5,
        },

        timer = {
            trackHeight = 4,
            -- All group-loot-specific glow tuning in one spot (see
            -- UI/GroupLootFrame.lua's applyTimerVariant) - kept deliberately
            -- subtle: small padding, and a color scaled well below the
            -- fill's own full brightness, so the ADD glow reads as a soft
            -- halo instead of a wash over the row.
            glow = {
                -- SoftGlow.tga's own soft falloff needs at least a little
                -- padding past the (thin) fill to show a halo at all - see
                -- UI/SettingsWindow/Skin.lua's Skin.TimerBar.
                padX = 5,
                padY = 4,
                alpha = 0.75,
                alphaWhite = 0.60, -- poor/common items - same dimmer-than-`alpha` ratio as before
                alphaUrgent = 0.75, -- last-10s red state - still visibly more urgent than `alpha`
                colorScale = 0.6, -- glow tint = fill color * this, never the fill's own full brightness
            },
            dangerThreshold = 20,
            pulseDuration = 1.0, -- full 1->0.55->1 cycle, not one half of it
            -- Slower/narrower than Skin.TimerBar's own 2.5s/40px default
            -- (Respond/Roll) - these rows are short and thin.
            sheenWidth = 24,
            sheenPeriod = 3.5,
            sheenAlpha = 0.35,
        },

        shadowInset = 4,
        fadeOutDuration = 0.15,
    },

    -- UI/SoftResImportWindow.lua - built the same way as tradeQueue/
    -- startSession above (own top-level table, UI.Colors/UI.SetFont/UI.Skin,
    -- not FL.Theme). window.width/height are fixed literals (unlike
    -- startSession's derived height) - the preview list fills whatever
    -- vertical space is left rather than being row-count-derived.
    softres = (function()
        local titleBarHeight = 32;
        local contentPadX = 15;
        local contentPadTop = 12;
        local contentPadBottom = 11;
        local sectionGap = 9; -- header->paste, paste->card/preview, card->preview, preview->footer

        local headerTitleHeight = 20;
        local headerSubtitleGap = 4;
        local headerSubtitleHeight = 12;

        local pasteBoxHeight = 55;
        local pasteTextInset = 6;
        local parseLineGap = 4;
        local parseLineHeight = 14;
        local parseDotSize = 6;
        local parseDotGap = 6;

        local cardPadding = 6;
        local cardHeaderHeight = 18;
        local cardHeaderBodyGap = 6;
        local reportButtonWidth = 100;
        local reportButtonHeight = 18;
        local tagHeight = 15;
        local tagPadX = 6;
        local tagSpacing = 4; -- gap between tags AND between wrapped tag lines
        local emptyCheckSize = 10;
        local emptyIconGap = 6;

        local previewLabelHeight = 14;
        local previewLabelGap = 6; -- label row -> list box
        local listPadding = 5;
        local listScrollbarGap = 4;
        local listScrollbarInset = 3;
        local rowMinHeight = 29;
        local rowSpacing = 3;
        local rowPadding = 5;
        local rowNameWidth = 135;
        local rowNameIconGap = 8;
        local rowSubLineGap = 2; -- name line -> "Not in your group" line
        local rowNotInGroupAlpha = 0.55;
        local iconSize = 22;
        local iconSpacing = 4;

        local footerDividerHeight = 1;
        local footerDividerGap = 6;
        local footerDotSize = 6;
        local footerDotGap = 6;
        local footerStatusHeight = 14; -- one line - reserved even while empty, so the button row never jumps
        local footerStatusButtonGap = 6;
        local footerRowHeight = 22;
        local footerButtonGap = 8;
        local footerClearWidth = 70;
        local footerImportWidth = 130;

        return {
            window = { width = 380, height = 550 },
            titleBarHeight = titleBarHeight,
            contentPadX = contentPadX,
            contentPadTop = contentPadTop,
            contentPadBottom = contentPadBottom,
            sectionGap = sectionGap,

            header = {
                titleHeight = headerTitleHeight,
                subtitleGap = headerSubtitleGap,
                subtitleHeight = headerSubtitleHeight,
            },

            paste = {
                boxHeight = pasteBoxHeight,
                textInset = pasteTextInset,
                parseLineGap = parseLineGap,
                parseLineHeight = parseLineHeight,
                dotSize = parseDotSize,
                dotGap = parseDotGap,
            },

            card = {
                padding = cardPadding,
                headerHeight = cardHeaderHeight,
                headerBodyGap = cardHeaderBodyGap,
                reportButtonWidth = reportButtonWidth,
                reportButtonHeight = reportButtonHeight,
                tagHeight = tagHeight,
                tagPadX = tagPadX,
                tagSpacing = tagSpacing,
                emptyCheckSize = emptyCheckSize,
                emptyIconGap = emptyIconGap,
            },

            preview = {
                labelHeight = previewLabelHeight,
                labelGap = previewLabelGap,
                listPadding = listPadding,
                listScrollbarGap = listScrollbarGap,
                listScrollbarInset = listScrollbarInset,
                rowMinHeight = rowMinHeight,
                rowSpacing = rowSpacing,
                rowPadding = rowPadding,
                rowNameWidth = rowNameWidth,
                rowNameIconGap = rowNameIconGap,
                rowSubLineGap = rowSubLineGap,
                rowNotInGroupAlpha = rowNotInGroupAlpha,
                iconSize = iconSize,
                iconSpacing = iconSpacing,
            },

            footer = {
                dividerHeight = footerDividerHeight,
                dividerGap = footerDividerGap,
                dotSize = footerDotSize,
                dotGap = footerDotGap,
                statusHeight = footerStatusHeight,
                statusButtonGap = footerStatusButtonGap,
                rowHeight = footerRowHeight,
                buttonGap = footerButtonGap,
                clearWidth = footerClearWidth,
                importWidth = footerImportWidth,
            },
        };
    end)(),

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
