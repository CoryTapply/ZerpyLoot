--[[
Fixed hex palette for the settings window (UI/SettingsWindow). Unlike the
rest of the addon's UI, this window deliberately ignores the active skin
(Theme.colors) - it always looks the same regardless of which theme is
selected - so its colors live here instead of in a skin file.
]]

local FL = ForeverLoot;

FL.UI.Colors = {
    gold           = { 1.000, 0.820, 0.000 }, -- #ffd100
    titlePurple    = { 0.647, 0.584, 1.000 }, -- #a595ff
    text           = { 0.937, 0.914, 0.875 }, -- #efe9df
    muted          = { 0.639, 0.604, 0.557 }, -- #a39a8e
    -- Blizzard-panel description line (UI/OptionsPanel.lua) - close to `text`
    -- but a hair dimmer/warmer, per that panel's own spec.
    description    = { 0.812, 0.776, 0.722 }, -- #cfc6b8
    windowBg       = { 0.082, 0.075, 0.067 }, -- #151311
    sidebarBg      = { 0.063, 0.055, 0.047 }, -- #100e0c
    border         = { 0.294, 0.267, 0.231 }, -- #4b443b
    divider        = { 0.173, 0.157, 0.137 }, -- #2c2823
    selectedFill   = { 0.165, 0.141, 0.078 }, -- #2a2414
    selectedBorder = { 0.420, 0.333, 0.125 }, -- #6b5520
    hoverBg        = { 0.114, 0.102, 0.086 }, -- #1d1a16
    optionsStripBg = { 0.067, 0.059, 0.051 }, -- #110f0d
    memberBg       = { 0.102, 0.090, 0.078 }, -- #1a1714
    memberBorder   = { 0.180, 0.165, 0.145 }, -- #2e2a25
    councilFill    = { 0.169, 0.141, 0.059 }, -- #2b240f
    councilBorder  = { 0.788, 0.635, 0.102 }, -- #c9a21a

    -- No exact hex given for the "dark-red close button" in the spec.
    closeButton      = { 0.478, 0.180, 0.180 },
    closeButtonHover = { 0.600, 0.235, 0.235 },

    -- Theme.Helpers.SetFlatBackdrop always sets a border color (even a
    -- fill-only backdrop needs one passed in, or it errors on unpack(nil)) -
    -- this is what "no visible border" uses.
    transparent = { 0, 0, 0, 0 },

    ----------------------------------------------------------------------
    -- UI/SettingsWindow/Skin.lua control palette. Added for the search box/
    -- checkbox/dropdown/button/close-button restyle - kept separate from the
    -- block above rather than reusing near-duplicate existing entries
    -- (e.g. text vs textBright) so each control's mockup hex stays exact and
    -- traceable back to the spec it came from.
    ----------------------------------------------------------------------
    textBright      = { 0.949, 0.929, 0.894 }, -- #f2ede4 - search box/dropdown/button text
    controlBg       = { 0.047, 0.043, 0.039 }, -- #0c0b0a - search box + checkbox + dropdown fill
    controlBorder   = { 0.341, 0.314, 0.290 }, -- #57504a - search box/dropdown border
    controlHover    = { 0.541, 0.506, 0.463 }, -- #8a8176 - shared hover border (checkbox/dropdown/default button) + search placeholder
    controlFocus    = { 0.612, 0.486, 0.110 }, -- #9c7c1c - search box focus border (== primaryBorder)

    checkboxBorder  = { 0.353, 0.325, 0.290 }, -- #5a534a
    disabledText    = { 0.435, 0.408, 0.373 }, -- #6f685f - disabled checkbox label / disabled button text

    arrowBoxBg      = { 0.133, 0.114, 0.082 }, -- #221d15 - dropdown arrow box
    arrowBoxBorder  = { 0.420, 0.376, 0.310 }, -- #6b604f

    primaryBg       = { 0.227, 0.173, 0.043 }, -- #3a2c0b - "Sync to Raid"-style primary button
    primaryBorder   = { 0.612, 0.486, 0.110 }, -- #9c7c1c
    primaryPressed  = { 0.169, 0.125, 0.039 }, -- #2b200a

    defaultBg       = { 0.110, 0.098, 0.086 }, -- #1c1916 - plain settings buttons + disabled primary/default bg
    disabledBorder  = { 0.227, 0.204, 0.176 }, -- #3a342d

    skinCloseBg           = { 0.361, 0.071, 0.071 }, -- #5c1212 - new close-button look (Skin.CloseButton)
    skinCloseBorder       = { 0.753, 0.224, 0.169 }, -- #c0392b
    skinCloseBgHover      = { 0.478, 0.094, 0.094 }, -- #7a1818
    skinCloseBorderHover  = { 0.878, 0.290, 0.227 }, -- #e04a3a

    -- Skin.ScrollBar's slim, arrowless scrollbar (== controlBg/border/
    -- arrowBoxBorder respectively - kept as their own named entries, same
    -- as controlFocus/primaryBorder above, so the scrollbar's look stays
    -- traceable on its own rather than borrowing another control's name).
    scrollTrack      = { 0.047, 0.043, 0.039 }, -- #0c0b0a
    scrollThumb      = { 0.294, 0.267, 0.231 }, -- #4b443b
    scrollThumbHover = { 0.420, 0.376, 0.310 }, -- #6b604f

    ----------------------------------------------------------------------
    -- UI/StartSessionWindow.lua - the 3 colors below aren't already covered
    -- by an entry above; everything else that window uses (gold, muted,
    -- windowBg, border, divider, titlePurple, optionsStripBg, checkboxBorder,
    -- memberBg, memberBorder, skinCloseBorder, controlHover) is reused as-is.
    ----------------------------------------------------------------------
    sessionListBg          = { 0.059, 0.051, 0.047 }, -- #0f0d0c - item list box fill
    sessionDeleteHoverBg   = { 0.165, 0.071, 0.071 }, -- #2a1212 - row trash button hover fill
    sessionDeleteHoverIcon = { 1.000, 0.420, 0.369 }, -- #ff6b5e - row trash button hover icon

    ----------------------------------------------------------------------
    -- UI/RespondWindow.lua - the colors below aren't already covered by an
    -- entry above; everything else that window uses (windowBg, border,
    -- titlePurple, muted, description, gold, controlBg, controlFocus,
    -- defaultBg, controlHover, transparent) is reused as-is.
    ----------------------------------------------------------------------
    respondBorderMuted      = { 0.247, 0.227, 0.200 }, -- #3f3a33 - note box / toggle bar border
    respondButtonBorder     = { 0.290, 0.263, 0.231 }, -- #4a433b - unselected response button border
    respondLabel            = { 0.902, 0.875, 0.827 }, -- #e6dfd3 - unselected response button label
    respondSentLabel        = { 0.310, 0.851, 0.392 }, -- #4fd964 - "Sent" text
    respondNotePlaceholder  = { 0.490, 0.459, 0.420 }, -- #7d756b
    respondCardBg           = { 0.082, 0.075, 0.067, 0.95 }, -- #151311 @95%
    respondToggleBarBg      = { 0.082, 0.075, 0.067, 0.90 }, -- #151311 @90%
    respondTimerTrackBorder = { 0, 0, 0, 0.6 },
    respondTimerPausedFill  = { 0.290, 0.239, 0.078 }, -- #4a3d14
};

-- Per-response-option colors (UI/RespondWindow.lua), keyed by the same `id`
-- strings as Constants.LOOT_COUNCIL_RESPONSES - deliberately independent from
-- that table's own muted `color` field (which LootCouncilReviewWindow.lua
-- still depends on unchanged). `default` is the fallback for an id this table
-- doesn't know about, so a future user-configurable response list degrades
-- gracefully instead of erroring.
-- Selected-button label is always plain white regardless of the option's
-- own fill color (kept simple after Minor's/Pass's originally-planned dark
-- text - #1a1100/#0d1a0f, for contrast against their lighter fills - read as
-- an unwanted color shift rather than intentional contrast).
FL.UI.Colors.responses = {
    MAJOR   = { color = { 0.851, 0.212, 0.212 } }, -- #d93636
    MINOR   = { color = { 0.910, 0.573, 0.165 } }, -- #e8922a
    OFFSPEC = { color = { 0.184, 0.498, 0.851 } }, -- #2f7fd9
    MOG     = { color = { 0.690, 0.310, 0.851 } }, -- #b04fd9
    PASS    = { color = { 0.247, 0.702, 0.310 } }, -- #3fb34f
    default = { color = FL.UI.Colors.controlHover },
};
