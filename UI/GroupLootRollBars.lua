--[[
ElvUI-style bars for GroupLootRoll.lua's native Group Loot rolls: item icon
(full item tooltip on hover), item name, a countdown bar tinted the item's
rarity color, and Need/Greed/Pass icon buttons (Blizzard's own dice/coin/pass
button art, same as the default popup and ElvUI's LootRoll.lua) - each
showing a live count of how many players picked it, and listing their
class-colored names on hover. One bar per simultaneous roll, stacking
vertically below a small draggable anchor header whose position is persisted
the same way every other ZerpyLoot window's position is (see
ZL.Settings.GetWindowPosition/SetWindowPosition).

Bars themselves have no background/border of their own (their contents float
directly over whatever sits behind them, matching ElvUI's look) and aren't
full ZL.Theme.CreateWindow windows - only the anchor header needs to be
draggable/pixel-registered; the bars underneath just follow it.
]]

local ZL = ZerpyLoot;
local GroupLootRollBars = ZL.UI.GroupLootRollBars;
local GroupLootRoll = ZL.GroupLootRoll;
local Util = ZL.Util;
local Theme = ZL.Theme;

-- Same values RollOnLoot takes. Transmog (4) replaces Greed for items you
-- can't need or greed.
local ROLL_PASS, ROLL_NEED, ROLL_GREED, ROLL_TRANSMOG = 0, 1, 2, 4;

local BAR_WIDTH = 300;
local BUTTON_GAP = 4;
local ICON_SIZE = 28;
local ROLL_BUTTON_SIZE = 22;
-- Blizzard's Pass art carries more built-in padding than the Dice/Coin
-- textures, so it reads noticeably bigger at the same pixel size even after
-- one shrink already - cut down further so it actually reads as the same
-- size as Need/Greed instead of just "smaller than before".
local PASS_BUTTON_SIZE = 18;
local BAR_GAP = -8;
local ANCHOR_HEIGHT = 18;

-- Every vertical offset used to build a single bar's layout below, named so
-- barHeight (right underneath) can be computed straight from these instead
-- of by measuring a live frame - see barHeight's own comment for why that
-- measurement was the actual cause of two simultaneous rolls' bars
-- overlapping.
local TOP_PADDING = 8;
local COUNTDOWN_BAR_HEIGHT = 6;
local BOTTOM_PADDING = 8;

local ITEM_TEXT_GAP_AFTER_ICON = 6;
local ITEM_TEXT_GAP_BEFORE_BUTTONS = 8;
-- itemText's available width, derived from the same layout constants
-- createBar anchors it with rather than measured live off the frame (see
-- barHeight's own comment above for why a live measurement right after
-- layout isn't reliable) - safe to precompute since BAR_WIDTH is fixed, the
-- bars aren't resizable.
local ITEM_TEXT_MAX_WIDTH = (BAR_WIDTH - 2 * TOP_PADDING)
    - (ICON_SIZE + ITEM_TEXT_GAP_AFTER_ICON)
    - (ROLL_BUTTON_SIZE * 2 + PASS_BUTTON_SIZE + BUTTON_GAP * 2 + ITEM_TEXT_GAP_BEFORE_BUTTONS);
-- Floor for the shrink-to-fit below - past this an item name just clips
-- against needButton rather than shrinking down to unreadable.
local ITEM_TEXT_MIN_FONT_HEIGHT = 8;

-- Blizzard's own Group Loot button art (same textures the default
-- GroupLootFrame buttons and ElvUI's LootRoll.lua use) - "-Up"/"-Down" is
-- Blizzard's standard two-state naming for this kind of button texture.
local ROLL_BUTTON_TEXTURES = {
    [ROLL_NEED]  = { up = [[Interface\Buttons\UI-GroupLoot-Dice-Up]],  down = [[Interface\Buttons\UI-GroupLoot-Dice-Down]] },
    [ROLL_GREED] = { up = [[Interface\Buttons\UI-GroupLoot-Coin-Up]],  down = [[Interface\Buttons\UI-GroupLoot-Coin-Down]] },
    [ROLL_PASS]  = { up = [[Interface\Buttons\UI-GroupLoot-Pass-Up]],  down = [[Interface\Buttons\UI-GroupLoot-Pass-Down]] },
};

-- Transmog has no file-based art; Blizzard's own roll frame draws it from
-- these atlases (the same ones GroupLootFrame.xml's TransmogButton uses).
local TRANSMOG_ATLASES = {
    up = "lootroll-toast-icon-transmog-up",
    down = "lootroll-toast-icon-transmog-down",
    highlight = "lootroll-toast-icon-transmog-highlight",
};

-- Key this stack's saved anchor position is stored under (see
-- Settings.GetWindowPosition/SetWindowPosition - same mechanism RollWindow.lua
-- uses for its own window).
local POSITION_KEY = "groupLootRoll";

local anchor;
-- Every bar ever created, pooled and reused across rolls (a bar with
-- bar.rollID == nil is free) - same pooling idiom as RollWindow.lua's row
-- pool, just sized on demand instead of a fixed MAX_ROWS, since the number of
-- simultaneous rolls isn't bounded the way a scrollable list's row count is.
local bars = {};
local barByRollID = {};
-- Display order (append on Acquire, remove on Release) so bars keep a stable
-- stacking order instead of jumping around as rolls come and go.
local order = {};

-- Computed straight from the offset constants above (topRow's height plus
-- the padding around it) rather than measured off a live bar's
-- GetTop()/GetBottom() - querying a frame's position immediately after
-- creating and anchoring it isn't guaranteed to resolve until the next
-- frame render, so that measurement could silently come back as (or fall
-- back to) 0 for the very first bar. Every later bar would then inherit
-- that too-small cached height, so stacking a second simultaneous roll's
-- bar under it visually overlapped the first bar's real (much taller)
-- content instead of sitting below it.
--
-- countdownBar no longer adds its own height here - it's inset inside
-- topRow now (see createBar), bottom-aligned to the icon rather than a
-- separate full-width strip underneath it.
local barHeight = TOP_PADDING + ICON_SIZE + BOTTOM_PADDING;

local function buildRollButton(parent, rollType)
    local size = (rollType == ROLL_PASS) and PASS_BUTTON_SIZE or ROLL_BUTTON_SIZE;

    local button = CreateFrame("Button", nil, parent);
    button:SetSize(size, size);

    if (rollType == ROLL_TRANSMOG) then
        button:SetNormalAtlas(TRANSMOG_ATLASES.up);
        button:SetPushedAtlas(TRANSMOG_ATLASES.down);
        button:SetDisabledAtlas(TRANSMOG_ATLASES.up);
        button:SetHighlightAtlas(TRANSMOG_ATLASES.highlight, "ADD");
    else
        local textures = ROLL_BUTTON_TEXTURES[rollType];
        button:SetNormalTexture(textures.up);
        button:SetPushedTexture(textures.down);
        button:SetDisabledTexture(textures.up);
        button:SetHighlightTexture(textures.up, "ADD");
    end

    -- Disabled state (can't Need/Greed this item) reuses the same "up"
    -- texture, greyed out - Blizzard's own button art has no separate
    -- disabled variant either.
    local disabledTexture = button:GetDisabledTexture();
    disabledTexture:SetDesaturated(true);
    disabledTexture:SetAlpha(0.4);

    button.countText = button:CreateFontString(nil, "OVERLAY", Theme.fonts.highlightSmall);
    button.countText:SetPoint("BOTTOMRIGHT", 0, 0);
    -- Heavier shadow than the shared font's default (see
    -- Theme/Fonts.lua's FONT_SHADOW_OFFSET_X/Y) so the vote count
    -- stays legible over any button texture color, without changing every
    -- other highlightSmall label elsewhere in the addon.
    do
        local fontFile, fontHeight = button.countText:GetFont();
        button.countText:SetFont(fontFile, fontHeight, Theme.FONT_FLAGS);
    end
    button.countText:SetShadowOffset(2, -2);
    button.countText:SetShadowColor(0, 0, 0, 1);

    return button;
end

local function createBar()
    -- No background/border on the row itself (unlike this addon's other
    -- windows) - a boxed panel behind icon+name+buttons+bar didn't fit the
    -- ElvUI look this is going for, which floats those elements directly over
    -- the alert-frame area instead.
    local bar = CreateFrame("Frame", nil, UIParent);
    bar:SetSize(BAR_WIDTH, barHeight);
    -- Placeholder anchor, replaced the moment the bar is actually acquired
    -- and stacked under the anchor header (see layout()).
    bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0);
    bar:Hide();

    -- Single row - icon, name, countdown bar and the three roll buttons all
    -- share the icon's own height, with the countdown bar inset beside the
    -- icon (bottom-flush with it) rather than as a separate strip
    -- underneath. A dedicated row frame (rather than anchoring everything
    -- straight to bar) means the roll buttons can align to ITS LEFT/RIGHT
    -- points - which sit at the row's own vertical center - so they end up
    -- vertically centered against the icon without hand-computed offsets.
    local topRow = CreateFrame("Frame", nil, bar);
    topRow:SetPoint("TOPLEFT", bar, "TOPLEFT", TOP_PADDING, -TOP_PADDING);
    topRow:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -TOP_PADDING, -TOP_PADDING);
    topRow:SetHeight(ICON_SIZE);

    -- Same icon + separate 1px-outset border-wrapper trick RollWindow.lua's
    -- itemButton/iconBorder use (a backdrop border on the icon itself would
    -- sit under its own ARTWORK-layer texture).
    local itemButton = CreateFrame("Button", nil, topRow);
    itemButton:SetSize(ICON_SIZE, ICON_SIZE);
    itemButton:SetPoint("LEFT", topRow, "LEFT", 0, 0);

    local itemIcon = itemButton:CreateTexture(nil, "ARTWORK");
    itemIcon:SetAllPoints(itemButton);
    itemIcon:SetTexCoord(0.0833, 0.9167, 0.0833, 0.9167);

    local iconBorder = CreateFrame("Frame", nil, bar, "BackdropTemplate");
    Theme.SkinIconBorder(iconBorder, itemButton);

    itemButton:SetScript("OnEnter", function()
        if (not bar.rollID) then return; end
        GameTooltip:SetOwner(itemButton, "ANCHOR_RIGHT");
        GameTooltip:SetLootRollItem(bar.rollID);
        GameTooltip:Show();
    end);
    itemButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    itemButton:RegisterForClicks("LeftButtonUp");
    itemButton:SetScript("OnClick", function()
        local roll = bar.rollID and GroupLootRoll.ActiveRolls[bar.rollID];
        if (roll) then Util.HandleItemLinkClick(roll.itemLink); end
    end);

    -- Buttons anchored right-to-left off topRow's own right edge first, so
    -- itemText below can then be anchored between the icon and needButton
    -- (whatever space is left over).
    local passButton = buildRollButton(topRow, ROLL_PASS);
    -- Nudged up 2px - Blizzard's Pass art sits slightly low within its own
    -- texture bounds, so at the same vertical center as Need/Greed it read
    -- as visually lower than them.
    passButton:SetPoint("RIGHT", topRow, "RIGHT", 0, 6);

    local greedButton = buildRollButton(topRow, ROLL_GREED);
    greedButton:SetPoint("RIGHT", passButton, "LEFT", -BUTTON_GAP, -2);

    -- Transmog takes Greed's exact slot (the two are never offered together,
    -- same as Blizzard's own roll frame) - shown/hidden in Refresh.
    local transmogButton = buildRollButton(topRow, ROLL_TRANSMOG);
    transmogButton:SetPoint("RIGHT", passButton, "LEFT", -BUTTON_GAP, -2);
    transmogButton:Hide();

    local needButton = buildRollButton(topRow, ROLL_NEED);
    needButton:SetPoint("RIGHT", greedButton, "LEFT", -BUTTON_GAP, 0);

    -- Smaller than the old normalMedium (14pt) so a full item name fits
    -- comfortably next to the icon; recolored per-roll to the item's rarity
    -- in Refresh below (overriding the font object's own base color, same
    -- way countdownBar's fill color is overridden there too). Anchored to
    -- the icon's TOP (rather than vertically centered on it) so countdownBar
    -- below has room to sit inset against the icon's bottom instead of the
    -- two overlapping.
    local itemText = topRow:CreateFontString(nil, "OVERLAY", Theme.fonts.normal);
    itemText:SetPoint("TOPLEFT", itemButton, "TOPRIGHT", ITEM_TEXT_GAP_AFTER_ICON, 0);
    itemText:SetPoint("RIGHT", needButton, "LEFT", -ITEM_TEXT_GAP_BEFORE_BUTTONS, 0);
    itemText:SetJustifyH("LEFT");
    itemText:SetWordWrap(false);
    -- Heavier shadow than the shared font's default (see
    -- Theme/Fonts.lua's FONT_SHADOW_OFFSET_X/Y) so the item name
    -- stays legible over the alert-frame area's varied backgrounds, without
    -- changing every other normal-font label elsewhere in the addon. Base
    -- font file/height stashed on the bar itself so Refresh's shrink-to-fit
    -- below always has the un-shrunk size to start back from, even once this
    -- pooled bar has been reused by a roll with a shorter name.
    local itemTextFontFile, itemTextBaseFontHeight;
    do
        local fontFile, fontHeight = itemText:GetFont();
        itemTextFontFile, itemTextBaseFontHeight = fontFile, fontHeight;
        itemText:SetFont(fontFile, fontHeight, Theme.FONT_FLAGS);
    end
    itemText:SetShadowOffset(2, -2);
    itemText:SetShadowColor(0, 0, 0, 1);

    -- Thin countdown bar inset beside the icon, running under the item name
    -- AND the roll buttons to the row's own right edge - anchored only by
    -- its BOTTOM (plus the explicit SetHeight below) so it stays flush with
    -- the icon's own bottom edge regardless of itemText's height, with the
    -- leftover space above it falling between itemText/buttons and the bar.
    -- Border on a separate wrapper frame pulled 1px outside its own bounds -
    -- same trick as RollWindow.lua's countdownBar.
    local countdownBar = CreateFrame("StatusBar", nil, topRow);
    countdownBar:SetHeight(COUNTDOWN_BAR_HEIGHT);
    countdownBar:SetPoint("BOTTOMLEFT", itemButton, "BOTTOMRIGHT", 6, 0);
    countdownBar:SetPoint("RIGHT", topRow, "RIGHT", 0, 0);
    -- Pinned to topRow's own frame level (one below its children's default
    -- level) so it draws BEHIND the roll buttons it now runs under, rather
    -- than on top of them - same-level siblings would otherwise draw in
    -- creation order, and the buttons already exist by this point.
    countdownBar:SetFrameLevel(topRow:GetFrameLevel());
    Theme.ApplyStatusBarTexture(countdownBar, ZL.Settings.GetStatusBarTexture());
    countdownBar:SetStatusBarColor(unpack(Theme.colors.accent));
    countdownBar:SetMinMaxValues(0, 1);
    countdownBar:SetValue(0);

    local countdownBarBg = countdownBar:CreateTexture(nil, "BACKGROUND");
    countdownBarBg:SetAllPoints(countdownBar);
    countdownBarBg:SetColorTexture(0, 0, 0, 0.5);

    local countdownBarBorder = CreateFrame("Frame", nil, bar, "BackdropTemplate");
    countdownBarBorder:SetPoint("TOPLEFT", countdownBar, "TOPLEFT", -1, 1);
    countdownBarBorder:SetPoint("BOTTOMRIGHT", countdownBar, "BOTTOMRIGHT", 1, -1);
    Theme.SkinBorder(countdownBarBorder);

    -- Hover a choice to see who picked it, class-colored - mirrors ElvUI's
    -- own per-button SetTip. Reuses the existing Util.classColoredName
    -- helper rather than duplicating RAID_CLASS_COLORS lookup logic.
    local function showVotersTooltip(button, label, rollType)
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT");
        GameTooltip:AddLine(label);

        local roll = bar.rollID and GroupLootRoll.ActiveRolls[bar.rollID];
        local votes = roll and roll.votes[rollType];
        if (votes and #votes > 0) then
            for _, vote in ipairs(votes) do
                local line = Util.classColoredName(vote.name, vote.classFile);
                -- The roll number (Needs only) and whether a Need was off-spec.
                if (vote.roll) then line = ("%s  |cffffffff%d|r"):format(line, vote.roll); end
                if (vote.offSpec) then line = line .. "  |cff888888(off spec)|r"; end
                GameTooltip:AddLine(line);
            end
        else
            GameTooltip:AddLine("|cff888888No one yet|r");
        end

        GameTooltip:Show();
    end

    needButton:SetScript("OnClick", function() if (bar.rollID) then GroupLootRoll.RollOn(bar.rollID, ROLL_NEED); end end);
    needButton:SetScript("OnEnter", function() showVotersTooltip(needButton, NEED or "Need", ROLL_NEED); end);
    needButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    greedButton:SetScript("OnClick", function() if (bar.rollID) then GroupLootRoll.RollOn(bar.rollID, ROLL_GREED); end end);
    greedButton:SetScript("OnEnter", function() showVotersTooltip(greedButton, GREED or "Greed", ROLL_GREED); end);
    greedButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    transmogButton:SetScript("OnClick", function() if (bar.rollID) then GroupLootRoll.RollOn(bar.rollID, ROLL_TRANSMOG); end end);
    transmogButton:SetScript("OnEnter", function() showVotersTooltip(transmogButton, TRANSMOGRIFICATION or "Transmog", ROLL_TRANSMOG); end);
    transmogButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    passButton:SetScript("OnClick", function() if (bar.rollID) then GroupLootRoll.RollOn(bar.rollID, ROLL_PASS); end end);
    passButton:SetScript("OnEnter", function() showVotersTooltip(passButton, PASS or "Pass", ROLL_PASS); end);
    passButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    bar.itemButton, bar.itemIcon, bar.itemText = itemButton, itemIcon, itemText;
    bar.iconBorder = iconBorder;
    bar.itemTextFontFile, bar.itemTextBaseFontHeight = itemTextFontFile, itemTextBaseFontHeight;
    bar.countdownBar = countdownBar;
    bar.needButton, bar.greedButton, bar.passButton = needButton, greedButton, passButton;
    bar.transmogButton = transmogButton;

    bar:SetScript("OnUpdate", function(self)
        if (not self.rollID) then return; end

        local timeLeftMs = GetLootRollTimeLeft(self.rollID);
        if (not timeLeftMs or timeLeftMs <= 0) then
            -- Safety net for the same real-world quirk ElvUI's LootRoll.lua
            -- works around: some other addon (or the server) can leave a
            -- roll expired without ever firing CANCEL_LOOT_ROLL for it.
            -- Routed through GroupLootRoll.ClearActiveRoll (rather than
            -- clearing ActiveRolls directly) so its other per-roll state
            -- (cached votes, history-drop match) gets dropped too.
            GroupLootRoll.ClearActiveRoll(self.rollID);
            return;
        end

        local roll = GroupLootRoll.ActiveRolls[self.rollID];
        if (not roll) then return; end

        roll.duration = roll.duration and math.max(roll.duration, timeLeftMs) or timeLeftMs;
        countdownBar:SetMinMaxValues(0, roll.duration);
        countdownBar:SetValue(timeLeftMs);
    end);

    table.insert(bars, bar);
    return bar;
end

local function ensureAnchor()
    if (anchor) then return; end

    local savedPosition = ZL.Settings.GetWindowPosition(POSITION_KEY);
    anchor = Theme.CreateWindow("ZerpyLootGroupLootRollAnchor", BAR_WIDTH, ANCHOR_HEIGHT,
        savedPosition and savedPosition.x or 0, savedPosition and savedPosition.y or 200,
        function(x, y) ZL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    anchor:Hide();

    local label = anchor:CreateFontString(nil, "OVERLAY", Theme.fonts.title);
    label:SetPoint("CENTER");
    label:SetText("Group Loot");
end

local function findFreeBar()
    for _, bar in ipairs(bars) do
        if (not bar.rollID) then return bar; end
    end

    return createBar();
end

local function layout()
    if (not anchor) then return; end

    if (#order == 0) then
        anchor:Hide();
        return;
    end

    -- Locked hides the header (nothing left to drag once it's positioned) -
    -- the bars below still stack off it since a hidden frame keeps whatever
    -- position it was last anchored/dragged to.
    if (ZL.Settings.GetGroupLootRollLocked()) then
        anchor:Hide();
    else
        anchor:Show();
    end

    local previous = anchor;
    for _, rollID in ipairs(order) do
        local bar = barByRollID[rollID];
        bar:ClearAllPoints();
        bar:SetPoint("TOP", previous, "BOTTOM", 0, -BAR_GAP);
        previous = bar;
    end
end

-- Shrinks bar.itemText's font one point at a time until roll.itemName's
-- string width fits within ITEM_TEXT_MAX_WIDTH, down to
-- ITEM_TEXT_MIN_FONT_HEIGHT - long item names (trinket/weapon names with
-- "of the Whatever" suffixes) would otherwise just clip against needButton
-- instead of reading in full. Always starts back from the bar's own base
-- font height first so a pooled bar's previous (possibly shrunk) size
-- doesn't carry over onto a shorter name.
local function fitItemText(bar)
    local itemText = bar.itemText;
    local height = bar.itemTextBaseFontHeight;
    itemText:SetFont(bar.itemTextFontFile, height, Theme.FONT_FLAGS);

    while (itemText:GetStringWidth() > ITEM_TEXT_MAX_WIDTH and height > ITEM_TEXT_MIN_FONT_HEIGHT) do
        height = height - 1;
        itemText:SetFont(bar.itemTextFontFile, height, Theme.FONT_FLAGS);
    end
end

function GroupLootRollBars.Refresh(rollID)
    local bar = barByRollID[rollID];
    local roll = GroupLootRoll.ActiveRolls[rollID];
    if (not bar or not roll) then return; end

    bar.itemIcon:SetTexture(roll.itemIcon);
    Theme.SetIconBorderQuality(bar.iconBorder, roll.quality);
    bar.itemText:SetText(roll.itemName);
    fitItemText(bar);

    -- Tint both the countdown bar and the item name with the item's own
    -- rarity color (poor through legendary), same as the default popup and
    -- ElvUI's LootRoll.lua - falls back to the flat accent color on the rare
    -- nil (GetItemQualityColor only fails for an out-of-range quality index,
    -- which a real roll never has).
    local r, g, b = Util.GetItemQualityColor(roll.quality or 1);
    r, g, b = r or Theme.colors.accent[1], g or Theme.colors.accent[2], b or Theme.colors.accent[3];
    bar.countdownBar:SetStatusBarColor(r, g, b);
    bar.itemText:SetTextColor(r, g, b);

    if (roll.canNeed) then bar.needButton:Enable(); else bar.needButton:Disable(); end
    if (roll.canGreed) then bar.greedButton:Enable(); else bar.greedButton:Disable(); end

    -- Transmog replaces Greed when the item offers it (Blizzard's own roll
    -- frame does the same swap).
    bar.greedButton:SetShown(not roll.canTransmog);
    bar.transmogButton:SetShown(roll.canTransmog and true or false);

    for _, entry in ipairs({ { bar.needButton, ROLL_NEED }, { bar.greedButton, ROLL_GREED }, { bar.transmogButton, ROLL_TRANSMOG }, { bar.passButton, ROLL_PASS } }) do
        local button, rollType = entry[1], entry[2];
        local votes = roll.votes[rollType];
        button.countText:SetText((votes and #votes > 0) and tostring(#votes) or "");
    end
end

function GroupLootRollBars.Acquire(rollID)
    ensureAnchor();

    local bar = barByRollID[rollID];
    if (not bar) then
        bar = findFreeBar();
        bar.rollID = rollID;
        barByRollID[rollID] = bar;
        table.insert(order, rollID);
    end

    bar:Show();
    GroupLootRollBars.Refresh(rollID);
    layout();
end

function GroupLootRollBars.Release(rollID)
    local bar = barByRollID[rollID];
    if (not bar) then return; end

    bar.rollID = nil;
    bar:Hide();
    barByRollID[rollID] = nil;

    for i, id in ipairs(order) do
        if (id == rollID) then
            table.remove(order, i);
            break;
        end
    end

    layout();
end

-- Re-applies the locked header's visibility immediately (rather than only
-- the next time a roll starts/ends) - called by OptionsPanel.lua when the
-- lock checkbox is toggled while roll bars may already be showing.
function GroupLootRollBars.RefreshLock()
    layout();
end

function GroupLootRollBars.ResetPosition()
    ZL.Settings.ClearWindowPosition(POSITION_KEY);
    if (anchor) then Theme.ResetWindowPosition(anchor); end
end
