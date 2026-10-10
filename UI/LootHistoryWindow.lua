--[[
Loot History window - a browsable, filterable view of FL.LootCouncil.History
(every loot-council award, plus manually-added entries for awards that
happened outside the addon). Built the same UI.Colors/UI.Sizes.lootHistory/
UI.SetFont/UI.Skin way as UI/TradeQueueWindow.lua and UI/AwardWindow.lua, not
FL.Theme - this window has exactly one look, it doesn't follow the active
skin.

This is the first-ever reader of FL.LootCouncil.History (until now a
write-only log); "Add Entry" below is the first-ever writer other than
LootCouncil.RecordHistory itself.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.lootHistory;
local RootSizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Util = FL.Util;
local LootCouncil = FL.LootCouncil;
local Responses = FL.Responses;
local LootHistoryWindow = FL.UI.LootHistoryWindow;

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";
local CROWN_TEXTURE = "Interface\\GroupFrame\\UI-Group-LeaderIcon";
local DOT_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Dot";
local ARROW_ATLAS = "glues-characterSelect-icon-arrowDown";
local PLUS_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Award\\Plus";
local TRASH_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\trash.tga";
local LOCK_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\Lock.tga";

local POSITION_KEY = "lootHistoryWindow";
local WINDOW_WIDTH = Sizes.window.width;
local WINDOW_HEIGHT = Sizes.window.height;

--------------------------------------------------------------------------
-- Module state
--------------------------------------------------------------------------

local frame, body;
local dateColumn, playersColumn, itemsColumn;
local filterBar;
local filterChips = {}; -- up to 2 simultaneous chips: { tag, tagText, valueText, itemIcon, itemIconBorder }
local filterCountText, filterClearText, filterClearButton, filterClearUnderline, addEntryButton;
local confirmationLine;
local resultsScroll, resultsScrollChild, emptyResultsText;
local resultRows = {};
local expandedBlock;
local candidateRows = {};
local addEntryPopup, addEntryState;
local pinPopup, pinPopupEntry;

local allEntries = {};
local indexByDay, dayKeysSorted = {}, {};
local indexByPlayer, playerNamesSorted = {}, {};
local indexByItem, itemIDsSorted = {}, {};

local currentFilter; -- nil, or { date = dayKey|nil, player = playerName|nil, item = itemID|nil }.
                      -- nil means "All history"; a filter table is never stored with all three
                      -- fields nil (applyFilter normalizes that back to nil). Invariant: player
                      -- and item are never both non-nil at once (enforced in
                      -- toggleFilterDimension, the only place that merges a click into it).
local currentResults = {};
local expandedEntryId;
local hasAppliedFilter = false;

-- Delete mode: toggled by the titlebar lock button. While active, every
-- result row's chevron is swapped for a trash icon that removes that row's
-- entry from FL.LootCouncil.History (see setDeleteMode/deleteEntry below).
-- lockButton is created once by createTitleBar; paintLockButton needs it as
-- a module-level upvalue so setDeleteMode can repaint it without threading
-- it through every caller.
local deleteModeActive = false;
local lockButton;

-- Another guild's history on this account being viewed (Data/Buckets.lua's
-- parked buckets), or nil for this character's own guild. Viewing another
-- guild is read-only: no Add Entry, no delete/pin, and no live updates.
-- Always reset to nil when the window opens.
local viewKey;
local ACTIVE_VIEW = "__active"; -- the guild picker's value for our own guild
local guildPicker, guildPickerSignature;
local windowTitle, titleBarFrame;
local WINDOW_TITLE = "ForeverLoot - Loot History";

-- Debounces GET_ITEM_INFO_RECEIVED-triggered refreshes (see ensureFrame) -
-- a cold cache on first open can answer dozens of items in a burst, and
-- each one firing its own full Refresh() would re-run rebuildIndexes() that
-- many times. Mirrors StartSessionWindow.lua's scheduleCouncilButtonUpdate.
local itemInfoRefreshPending = false;
local ITEM_INFO_REFRESH_DEBOUNCE = 0.5;

local applyFilter, toggleExpand, layoutResultRows, ensureFrame, showAddEntryPopup, deleteEntry, pinEntry;

--------------------------------------------------------------------------
-- Small local helpers
--------------------------------------------------------------------------

local function dayKey(t) return date("%Y-%m-%d", t); end
local function dayLabel(t) return date("%a %m/%d", t); end
local function timeLabel(t) return (date("%I:%M %p", t)):gsub("^0", ""); end

local function classColorRGB(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile];
    if (c) then return c.r, c.g, c.b; end
    return Colors.text[1], Colors.text[2], Colors.text[3];
end

local function setTextEllipsized(fontString, text, maxWidth)
    text = text or "";
    fontString:SetText(text);
    if (text == "" or fontString:GetStringWidth() <= maxWidth) then return false; end
    while (fontString:GetStringWidth() > maxWidth and #text > 1) do
        text = text:sub(1, -2);
        fontString:SetText(text .. "...");
    end
    return true;
end

--- Builds a response pill frame (dot + label), same construction every
--- consumer of a raw {label, color, kind} entry uses (see
--- UI/SettingsWindow/Pages/LootResponses.lua's buildPill).
local function buildPill(parent)
    local pill = CreateFrame("Frame", nil, parent);
    pill:SetHeight(Sizes.pill.height);
    Skin.Pill(pill);
    pill.dot = pill:CreateTexture(nil, "ARTWORK");
    pill.dot:SetSize(Sizes.pill.dotSize, Sizes.pill.dotSize);
    pill.dot:SetPoint("LEFT", pill, "LEFT", Sizes.pill.padX, 0);
    pill.dot:SetTexture(DOT_TEXTURE);
    pill.label = pill:CreateFontString(nil, "OVERLAY");
    SetFont(pill.label, "small");
    pill.label:SetPoint("LEFT", pill.dot, "RIGHT", Sizes.pill.dotGap, 0);
    return pill;
end

--- Paints `pill` from a {label, color(hex), kind} entry (history's own
--- stored shape) or nil (a grey "No response" pill).
local function paintResponsePill(pill, responseEntry, maxLabelWidth)
    local label = (responseEntry and responseEntry.label) or "No response";
    local r, g, b;
    if (responseEntry and responseEntry.color) then
        r, g, b = Util.HexToRGB(responseEntry.color);
    else
        r, g, b = Colors.disabledText[1], Colors.disabledText[2], Colors.disabledText[3];
    end
    pill:SetPillColor(r, g, b);
    pill.dot:SetVertexColor(r, g, b);
    pill.label:SetTextColor(unpack(Colors.text));
    Skin.FitPillLabel(pill.label, label, maxLabelWidth or 120);
    local chrome = Sizes.pill.padX * 2 + Sizes.pill.dotSize + Sizes.pill.dotGap;
    pill:SetWidth(chrome + pill.label:GetStringWidth());
end

--------------------------------------------------------------------------
-- Data / index layer - rebuilt once on open and once after any manual add,
-- never scanned per frame. See §1 of the design spec.
--------------------------------------------------------------------------

-- The rows the window shows: our own guild's history, or the parked bucket
-- being viewed. Parked buckets are never pruned, so rows our own view would
-- already have pruned (older than the cutoff, unpinned) are left out.
local function viewEntries()
    if (not viewKey) then return LootCouncil.History or {}; end
    local bucket = FL.Sync.Buckets.Get(viewKey);
    if (not bucket) then return {}; end
    local cutoff, pins, out = FL.Sync.Retention.Cutoff(), bucket.pins or {}, {};
    for _, row in ipairs(bucket.history or {}) do
        if ((row.awardedAt or 0) >= cutoff or pins[row.id]) then table.insert(out, row); end
    end
    return out;
end

local function rebuildIndexes()
    local history = viewEntries();
    allEntries = {};
    for i, entry in ipairs(history) do allEntries[i] = entry; end
    table.sort(allEntries, function(a, b) return (a.awardedAt or 0) > (b.awardedAt or 0); end);

    indexByDay, indexByPlayer, indexByItem = {}, {}, {};

    for _, entry in ipairs(allEntries) do
        local dKey = dayKey(entry.awardedAt);
        local dayBucket = indexByDay[dKey];
        if (not dayBucket) then
            dayBucket = { label = dayLabel(entry.awardedAt), entries = {} };
            indexByDay[dKey] = dayBucket;
        end
        table.insert(dayBucket.entries, entry);

        local playerBucket = indexByPlayer[entry.awardedTo];
        if (not playerBucket) then
            playerBucket = { class = nil, entries = {} };
            indexByPlayer[entry.awardedTo] = playerBucket;
        end
        table.insert(playerBucket.entries, entry);
        if (not playerBucket.class and entry.awardedToClass) then
            playerBucket.class = entry.awardedToClass;
        end

        local itemBucket = indexByItem[entry.itemID];
        if (not itemBucket) then
            itemBucket = { link = entry.itemLink, icon = entry.itemIcon, entries = {} };
            indexByItem[entry.itemID] = itemBucket;
        end
        table.insert(itemBucket.entries, entry);
    end

    dayKeysSorted = {};
    for k in pairs(indexByDay) do table.insert(dayKeysSorted, k); end
    table.sort(dayKeysSorted, function(a, b) return a > b; end);

    playerNamesSorted = {};
    for name in pairs(indexByPlayer) do table.insert(playerNamesSorted, name); end
    table.sort(playerNamesSorted, function(a, b) return a:lower() < b:lower(); end);

    itemIDsSorted = {};
    for itemID, itemBucket in pairs(indexByItem) do
        itemBucket.name = Util.GetItemInfo(itemBucket.link or itemID) or ("Item " .. tostring(itemID));
        itemBucket.quality = Util.GetItemQuality(itemBucket.link or itemID);
        table.insert(itemIDsSorted, itemID);
    end
    table.sort(itemIDsSorted, function(a, b)
        return (indexByItem[a].name or ""):lower() < (indexByItem[b].name or ""):lower();
    end);
end

--- Intersects two entry arrays by table identity (the same entry table is
--- shared across whichever of indexByDay/indexByPlayer/indexByItem it
--- belongs to), preserving `base`'s own ordering.
local function intersectEntries(base, other)
    local presentInOther = {};
    for _, e in ipairs(other) do presentInOther[e] = true; end
    local out = {};
    for _, e in ipairs(base) do
        if (presentInOther[e]) then table.insert(out, e); end
    end
    return out;
end

--------------------------------------------------------------------------
-- Incremental index maintenance - lets OnEntryUpserted (below) add/replace a
-- single history row without rebuildIndexes' full O(n log n) re-sort and
-- three full bucket rebuilds, which otherwise ran on every single award (not
-- just manual adds) while this window happened to be open. `allEntries` and
-- every bucket's `.entries` share the same "sorted by awardedAt descending"
-- invariant rebuildIndexes establishes - insertSorted keeps a list in that
-- order via one binary-search insertion instead of a full re-sort.
--------------------------------------------------------------------------

local function bsearchInsertPos(list, awardedAt)
    local lo, hi = 1, #list + 1;
    while (lo < hi) do
        local mid = math.floor((lo + hi) / 2);
        if ((list[mid].awardedAt or 0) > (awardedAt or 0)) then
            lo = mid + 1;
        else
            hi = mid;
        end
    end
    return lo;
end

local function insertSorted(list, entry)
    table.insert(list, bsearchInsertPos(list, entry.awardedAt), entry);
end

--- Linear removal by id - fine for a bucket (bounded by that day/player/item's
--- own award count, not total history) and for allEntries (only hit on the
--- much rarer reassign-replace path, never on a plain new award).
local function removeFromList(list, id)
    for i, e in ipairs(list) do
        if (e.id == id) then
            table.remove(list, i);
            return true;
        end
    end
    return false;
end

local function removeSortedKey(sortedKeys, key)
    for i, k in ipairs(sortedKeys) do
        if (k == key) then
            table.remove(sortedKeys, i);
            return;
        end
    end
end

--- Inserts `entry` into allEntries and its day/player/item buckets, creating
--- a bucket (and re-sorting that one small key array - O(distinct keys), not
--- O(history)) only when this is the first entry for that day/player/item.
local function insertEntryIntoIndexes(entry)
    insertSorted(allEntries, entry);

    local dKey = dayKey(entry.awardedAt);
    local dayBucket = indexByDay[dKey];
    if (not dayBucket) then
        dayBucket = { label = dayLabel(entry.awardedAt), entries = {} };
        indexByDay[dKey] = dayBucket;
        table.insert(dayKeysSorted, dKey);
        table.sort(dayKeysSorted, function(a, b) return a > b; end);
    end
    insertSorted(dayBucket.entries, entry);

    local playerBucket = indexByPlayer[entry.awardedTo];
    if (not playerBucket) then
        playerBucket = { class = entry.awardedToClass, entries = {} };
        indexByPlayer[entry.awardedTo] = playerBucket;
        table.insert(playerNamesSorted, entry.awardedTo);
        table.sort(playerNamesSorted, function(a, b) return a:lower() < b:lower(); end);
    elseif (not playerBucket.class and entry.awardedToClass) then
        playerBucket.class = entry.awardedToClass;
    end
    insertSorted(playerBucket.entries, entry);

    local itemBucket = indexByItem[entry.itemID];
    if (not itemBucket) then
        itemBucket = {
            link = entry.itemLink, icon = entry.itemIcon, entries = {},
            name = Util.GetItemInfo(entry.itemLink or entry.itemID) or ("Item " .. tostring(entry.itemID)),
            quality = Util.GetItemQuality(entry.itemLink or entry.itemID),
        };
        indexByItem[entry.itemID] = itemBucket;
        table.insert(itemIDsSorted, entry.itemID);
        table.sort(itemIDsSorted, function(a, b)
            return (indexByItem[a].name or ""):lower() < (indexByItem[b].name or ""):lower();
        end);
    end
    insertSorted(itemBucket.entries, entry);
end

--- Removes `entry` from allEntries and its day/player/item buckets, dropping
--- a bucket (and its key) entirely once it's left empty - mirrors
--- insertEntryIntoIndexes above. Used for the reassign-replace path (the old
--- recipient's row) - see OnEntryUpserted.
local function removeEntryFromIndexes(entry)
    removeFromList(allEntries, entry.id);

    local dKey = dayKey(entry.awardedAt);
    local dayBucket = indexByDay[dKey];
    if (dayBucket) then
        removeFromList(dayBucket.entries, entry.id);
        if (#dayBucket.entries == 0) then
            indexByDay[dKey] = nil;
            removeSortedKey(dayKeysSorted, dKey);
        end
    end

    local playerBucket = indexByPlayer[entry.awardedTo];
    if (playerBucket) then
        removeFromList(playerBucket.entries, entry.id);
        if (#playerBucket.entries == 0) then
            indexByPlayer[entry.awardedTo] = nil;
            removeSortedKey(playerNamesSorted, entry.awardedTo);
        end
    end

    local itemBucket = indexByItem[entry.itemID];
    if (itemBucket) then
        removeFromList(itemBucket.entries, entry.id);
        if (#itemBucket.entries == 0) then
            indexByItem[entry.itemID] = nil;
            removeSortedKey(itemIDsSorted, entry.itemID);
        end
    end
end

local function resolveResults(filter)
    if (not filter) then return allEntries; end

    local dateBucket = filter.date and indexByDay[filter.date];
    local otherBucket = filter.player and indexByPlayer[filter.player]
        or filter.item and indexByItem[filter.item];

    if (filter.date and (filter.player or filter.item)) then
        if (not dateBucket or not otherBucket) then return {}; end
        return intersectEntries(dateBucket.entries, otherBucket.entries);
    elseif (filter.date) then
        return (dateBucket or { entries = {} }).entries;
    elseif (filter.player or filter.item) then
        return (otherBucket or { entries = {} }).entries;
    end
    return allEntries;
end

local function filterStillValid(filter)
    if (not filter) then return true; end
    if (filter.date and not indexByDay[filter.date]) then return false; end
    if (filter.player and not indexByPlayer[filter.player]) then return false; end
    if (filter.item and not indexByItem[filter.item]) then return false; end
    return true;
end

--- The single choke point that merges a sidebar row click into currentFilter.
--- Handles both the toggle-off-on-reclick gesture and the player/item
--- mutual-exclusion invariant. In-row "jump to X" click targets bypass this
--- and call applyFilter directly since they're full-replace, not merges.
local function toggleFilterDimension(dimType, key)
    local base = currentFilter or {};
    local nextFilter = { date = base.date, player = base.player, item = base.item };

    if (dimType == "date") then
        if (nextFilter.date == key) then
            nextFilter.date = nil;
        else
            nextFilter.date = key;
        end
    elseif (dimType == "player") then
        if (nextFilter.player == key) then
            nextFilter.player = nil;
        else
            nextFilter.player, nextFilter.item = key, nil;
        end
    elseif (dimType == "item") then
        if (nextFilter.item == key) then
            nextFilter.item = nil;
        else
            nextFilter.item, nextFilter.player = key, nil;
        end
    end

    applyFilter(nextFilter);
end

--------------------------------------------------------------------------
-- Filter columns (Date / Players / Items) - one shared builder, since all
-- three share anatomy (header + optional search + scrolled pooled rows with
-- count/select/hover states) and differ only in title, search, and how a
-- row paints. See §2-3 of the design spec.
--------------------------------------------------------------------------

local function intersectMaybe(a, b)
    if (not a) then return b; end
    if (not b) then return a; end
    return intersectEntries(a, b);
end

--- The entries a column's row counts should be intersected against, built
--- from every *other* currently active filter dimension (excluding
--- `dimType` itself, since that's the one varying per row). Date, Player
--- and Item are each considered independently here - e.g. while Player is
--- unset but Item is active, Player rows still cross against that Item, even
--- though clicking one of them would go on to clear it (mutual exclusion is
--- an actual-selection rule, not a preview rule). Returns nil when nothing
--- else is active, so callers can fall back to a row's own unfiltered count.
local function crossFilterEntries(dimType)
    if (not currentFilter) then return nil; end
    local entries;
    if (dimType ~= "date" and currentFilter.date) then
        entries = intersectMaybe(entries, (indexByDay[currentFilter.date] or {}).entries);
    end
    if (dimType ~= "player" and currentFilter.player) then
        entries = intersectMaybe(entries, (indexByPlayer[currentFilter.player] or {}).entries);
    end
    if (dimType ~= "item" and currentFilter.item) then
        entries = intersectMaybe(entries, (indexByItem[currentFilter.item] or {}).entries);
    end
    return entries;
end

--- A row's displayed count: how many entries this row's bucket would
--- contribute if it (or the dimension it already represents) were combined
--- with whatever else is currently active - i.e. a live preview of what
--- clicking it would narrow results to.
-- Per-refresh cache of each dimension's cross-filter as a lookup set, so a
-- column repaint builds it once instead of once per sidebar row (that was
-- hundreds of full-history tables of garbage per filter click). Cleared at
-- the start of every column refreshRows.
local crossSetCache = {};

local function contextualRowCount(dimType, bucket)
    local set = crossSetCache[dimType];
    if (set == nil) then
        local cross = crossFilterEntries(dimType);
        if (cross) then
            set = {};
            for _, e in ipairs(cross) do set[e] = true; end
        else
            set = false;
        end
        crossSetCache[dimType] = set;
    end
    if (not set) then return #bucket.entries; end
    local count = 0;
    for _, e in ipairs(bucket.entries) do
        if (set[e]) then count = count + 1; end
    end
    return count;
end

local function paintDateRow(row, key, bucket)
    if (not row.countText) then
        row.countText = row:CreateFontString(nil, "OVERLAY");
        SetFont(row.countText, "small");
        row.countText:SetPoint("RIGHT", row, "RIGHT", -Sizes.column.rowPadRight, 0);
        row.countText:SetJustifyH("RIGHT");

        row.label = row:CreateFontString(nil, "OVERLAY");
        SetFont(row.label, "body");
        row.label:SetJustifyH("LEFT");
        row.label:SetWordWrap(false);
        row.label:SetPoint("LEFT", row, "LEFT", Sizes.column.rowPadLeft, 0);
        row.label:SetPoint("RIGHT", row.countText, "LEFT", -4, 0);
    end

    row.label:SetTextColor(unpack(Colors.text));
    setTextEllipsized(row.label, bucket.label, row.label:GetWidth());
    row.countText:SetText(tostring(contextualRowCount("date", bucket)));
end

local function paintPlayerRow(row, key, bucket)
    if (not row.countText) then
        row.countText = row:CreateFontString(nil, "OVERLAY");
        SetFont(row.countText, "small");
        row.countText:SetPoint("RIGHT", row, "RIGHT", -Sizes.column.rowPadRight, 0);
        row.countText:SetJustifyH("RIGHT");

        row.nameText = row:CreateFontString(nil, "OVERLAY");
        SetFont(row.nameText, "body");
        row.nameText:SetJustifyH("LEFT");
        row.nameText:SetWordWrap(false);
        row.nameText:SetPoint("LEFT", row, "LEFT", Sizes.column.rowPadLeft, 0);
        row.nameText:SetPoint("RIGHT", row.countText, "LEFT", -4, 0);
    end

    local r, g, b = classColorRGB(bucket.class);
    row.nameText:SetTextColor(r, g, b);
    setTextEllipsized(row.nameText, key, row.nameText:GetWidth());
    row.countText:SetText(tostring(contextualRowCount("player", bucket)));
end

local function paintItemRow(row, key, bucket)
    if (not row.countText) then
        row.countText = row:CreateFontString(nil, "OVERLAY");
        SetFont(row.countText, "small");
        row.countText:SetPoint("RIGHT", row, "RIGHT", -Sizes.column.rowPadRight, 0);
        row.countText:SetJustifyH("RIGHT");

        row.icon = row:CreateTexture(nil, "ARTWORK");
        row.icon:SetSize(Sizes.column.itemIconSize, Sizes.column.itemIconSize);
        row.icon:SetPoint("LEFT", row, "LEFT", Sizes.column.rowPadLeft, 0);
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

        row.iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
        row.iconBorder:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -1, 1);
        row.iconBorder:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1);
        Theme.Helpers.SetFlatBackdrop(row.iconBorder, nil, Colors.transparent, Sizes.column.itemIconBorder);

        row.nameText = row:CreateFontString(nil, "OVERLAY");
        SetFont(row.nameText, "body");
        row.nameText:SetJustifyH("LEFT");
        row.nameText:SetWordWrap(false);
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 5, 0);
        row.nameText:SetPoint("RIGHT", row.countText, "LEFT", -4, 0);
    end

    row.icon:SetTexture(bucket.icon or Util.GetItemIcon(key) or FALLBACK_ICON);
    local qr, qg, qb = Util.GetItemQualityColor(bucket.quality);
    qr, qg, qb = qr or 0.6, qg or 0.6, qb or 0.6;
    row.iconBorder:SetBackdropBorderColor(0.341, 0.314, 0.290);
    row.nameText:SetTextColor(qr, qg, qb);
    setTextEllipsized(row.nameText, bucket.name, row.nameText:GetWidth());
    row.countText:SetText(tostring(contextualRowCount("item", bucket)));
end

local function buildFilterColumn(parent, opts)
    local col = CreateFrame("Frame", nil, parent, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(col, Colors.sidebarBg, Colors.transparent, 1);

    local rightDivider = col:CreateTexture(nil, "ARTWORK");
    rightDivider:SetColorTexture(unpack(Colors.divider));
    rightDivider:SetPoint("TOPRIGHT", col, "TOPRIGHT", 0, 0);
    rightDivider:SetPoint("BOTTOMRIGHT", col, "BOTTOMRIGHT", 0, 0);
    Pixel.SetLineWidth(rightDivider, 1);

    ------------------------------------------------------------------
    -- Header
    ------------------------------------------------------------------
    local header = CreateFrame("Frame", nil, col);
    header:SetPoint("TOPLEFT", col, "TOPLEFT", 0, 0);
    header:SetPoint("TOPRIGHT", col, "TOPRIGHT", 0, 0);
    header:SetHeight(Sizes.column.headerHeight);

    local headerBorder = header:CreateTexture(nil, "ARTWORK");
    headerBorder:SetColorTexture(unpack(Colors.divider));
    headerBorder:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0);
    headerBorder:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0);
    Pixel.SetLineHeight(headerBorder, 1);

    local activeBar = header:CreateTexture(nil, "OVERLAY");
    activeBar:SetColorTexture(unpack(Colors.gold));
    activeBar:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0);
    activeBar:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0);
    activeBar:SetHeight(2);
    activeBar:Hide();

    local titleText = header:CreateFontString(nil, "OVERLAY");
    SetFont(titleText, "sectionHeader");
    titleText:SetPoint("LEFT", header, "LEFT", 8, 0);
    titleText:SetTextColor(unpack(Colors.muted));
    titleText:SetText(opts.title);

    local filterTag = CreateFrame("Frame", nil, header, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(filterTag, Colors.gold, Colors.gold, 1);
    local filterTagText = filterTag:CreateFontString(nil, "OVERLAY");
    SetFont(filterTagText, "tiny");
    filterTagText:SetTextColor(unpack(Colors.text));
    filterTagText:SetText("FILTER");
    filterTagText:SetPoint("CENTER", filterTag, "CENTER", 0, 0);
    filterTag:SetSize(
        filterTagText:GetStringWidth() + Sizes.column.filterTagPadX * 2,
        filterTagText:GetStringHeight() + Sizes.column.filterTagPadY * 2
    );
    filterTag:SetPoint("RIGHT", header, "RIGHT", -8, 0);
    filterTag:Hide();

    ------------------------------------------------------------------
    -- Search box (Players/Items only)
    ------------------------------------------------------------------
    local searchBox;
    if (opts.hasSearch) then
        searchBox = CreateFrame("EditBox", nil, col, "SearchBoxTemplate");
        searchBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", Sizes.column.searchMarginX, -Sizes.column.searchMarginTop);
        searchBox:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -Sizes.column.searchMarginX, -Sizes.column.searchMarginTop);
        searchBox:SetHeight(Sizes.column.searchHeight);
        searchBox:SetAutoFocus(false);
        if (searchBox.Instructions) then searchBox.Instructions:SetText(opts.searchPlaceholder or ""); end
        searchBox:SetScript("OnTextChanged", function(self)
            SearchBoxTemplate_OnTextChanged(self);
            col.refresh();
        end);
        Skin.EditBox(searchBox, true);
    end

    ------------------------------------------------------------------
    -- List
    ------------------------------------------------------------------
    local listBox = CreateFrame("Frame", nil, col);
    if (searchBox) then
        listBox:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", -Sizes.column.searchMarginX, -Sizes.column.searchMarginBottom);
        listBox:SetPoint("TOPRIGHT", searchBox, "BOTTOMRIGHT", Sizes.column.searchMarginX, -Sizes.column.searchMarginBottom);
    else
        listBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0);
        listBox:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0);
    end
    listBox:SetPoint("BOTTOMLEFT", col, "BOTTOMLEFT", 0, 0);
    listBox:SetPoint("BOTTOMRIGHT", col, "BOTTOMRIGHT", 0, 0);

    local scroll = CreateFrame("ScrollFrame", nil, listBox, "UIPanelScrollFrameTemplate");
    scroll:SetPoint("TOPLEFT", listBox, "TOPLEFT", Sizes.column.listPad, -Sizes.column.listPad);
    scroll:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -(RootSizes.layout.scrollbarWidth + 4), Sizes.column.listPad);
    local scrollChild = CreateFrame("Frame", nil, scroll);
    scrollChild:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0);
    scroll:SetScrollChild(scrollChild);
    scroll:SetScript("OnSizeChanged", function(self, width) scrollChild:SetWidth(width); end);
    local scrollBar = Skin.ScrollBar(scroll);
    if (scrollBar) then
        scrollBar:ClearAllPoints();
        scrollBar:SetPoint("TOP", scroll, "TOP", 0, 0);
        scrollBar:SetPoint("BOTTOM", scroll, "BOTTOM", 0, 0);
        scrollBar:SetPoint("RIGHT", listBox, "RIGHT", -3, 0);
    end
    Theme.Helpers.EnableSmoothScroll(scroll, { step = Sizes.column.rowHeight + Sizes.column.rowGap });

    local rows = {};
    local shownKeys = {};
    local selectedKey;

    local function createRow(index)
        local row = CreateFrame("Button", nil, scrollChild, "BackdropTemplate");
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(index - 1) * (Sizes.column.rowHeight + Sizes.column.rowGap));
        row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0);
        row:SetHeight(Sizes.column.rowHeight);
        Theme.Helpers.SetFlatBackdrop(row, Colors.transparent, Colors.transparent, 1);

        row.selectedBar = row:CreateTexture(nil, "OVERLAY");
        row.selectedBar:SetColorTexture(unpack(Colors.gold));
        row.selectedBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);
        row.selectedBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0);
        row.selectedBar:SetWidth(Sizes.column.selectedBarWidth);
        row.selectedBar:Hide();

        row:HookScript("OnEnter", function(self)
            if (self.key ~= selectedKey) then self:SetBackdropColor(unpack(Colors.hoverBg)); end
        end);
        row:HookScript("OnLeave", function(self)
            if (self.key ~= selectedKey) then self:SetBackdropColor(unpack(Colors.transparent)); end
        end);
        row:SetScript("OnClick", function(self)
            if (self.key == nil) then return; end
            toggleFilterDimension(opts.filterType, self.key);
        end);

        row:Hide();
        return row;
    end

    local function ensureRowCount(n)
        for i = #rows + 1, n do rows[i] = createRow(i); end
    end

    local function refreshRows()
        ensureRowCount(#shownKeys);
        scrollChild:SetHeight(math.max(#shownKeys * (Sizes.column.rowHeight + Sizes.column.rowGap), 1));
        wipe(crossSetCache);
        for i, row in ipairs(rows) do
            local key = shownKeys[i];
            if (key ~= nil) then
                row.key = key;
                opts.paintRow(row, key, opts.getBucket(key));
                local isSelected = (key == selectedKey);
                row.selectedBar:SetShown(isSelected);
                -- SetBackdrop allocates; only re-apply when the state flips.
                if (row.backdropSelected ~= isSelected) then
                    if (isSelected) then
                        Theme.Helpers.SetFlatBackdrop(row, Colors.selectedFill, Colors.selectedBorder, 1);
                    else
                        Theme.Helpers.SetFlatBackdrop(row, Colors.transparent, Colors.transparent, 1);
                    end
                    row.backdropSelected = isSelected;
                end
                if (row.countText) then
                    row.countText:SetTextColor(unpack(isSelected and Colors.gold or Colors.controlHover));
                end
                row:Show();
            else
                row.key = nil;
                row:Hide();
            end
        end
        if (scroll.ScrollBar and scroll.ScrollBar.zlUpdateVisibility) then scroll.ScrollBar.zlUpdateVisibility(); end
    end

    local function recomputeShownKeys()
        local query = searchBox and Util.Trim(searchBox:GetText() or ""):lower() or "";
        shownKeys = {};
        for _, key in ipairs(opts.getSortedKeys()) do
            if (query == "") then
                table.insert(shownKeys, key);
            else
                local text = (opts.getSearchText and opts.getSearchText(key, opts.getBucket(key))) or "";
                if (text:lower():find(query, 1, true)) then table.insert(shownKeys, key); end
            end
        end
    end

    function col.refresh()
        recomputeShownKeys();
        refreshRows();
    end

    function col.setActive(isActive)
        titleText:SetTextColor(unpack(isActive and Colors.gold or Colors.muted));
        activeBar:SetShown(isActive);
        filterTag:SetShown(isActive);
    end

    function col.setSelectedKey(key)
        selectedKey = key;
        refreshRows();
    end

    function col.isKeyHiddenBySearch(key)
        if (not searchBox) then return false; end
        for _, k in ipairs(shownKeys) do
            if (k == key) then return false; end
        end
        return true;
    end

    function col.clearSearch()
        if (searchBox) then
            searchBox:SetText("");
            col.refresh();
        end
    end

    function col.scrollKeyIntoView(key)
        local index;
        for i, k in ipairs(shownKeys) do
            if (k == key) then index = i; break; end
        end
        if (not index) then return; end
        local rowTop = (index - 1) * (Sizes.column.rowHeight + Sizes.column.rowGap);
        local rowBottom = rowTop + Sizes.column.rowHeight;
        local viewTop = scroll:GetVerticalScroll();
        local viewHeight = scroll:GetHeight();
        if (rowTop < viewTop) then
            scroll:SetVerticalScroll(rowTop);
        elseif (rowBottom > viewTop + viewHeight) then
            scroll:SetVerticalScroll(rowBottom - viewHeight);
        end
    end

    col.frame = col;
    return col;
end

--------------------------------------------------------------------------
-- Filter bar + confirmation line (top of the Results column). See §4.
--------------------------------------------------------------------------

local function createFilterBar(parent)
    filterBar = CreateFrame("Frame", nil, parent, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(filterBar, Colors.lhFilterBarBg, Colors.transparent, 1);
    filterBar:SetHeight(Sizes.filterBar.addButtonHeight + Sizes.filterBar.padY * 2);

    local border = filterBar:CreateTexture(nil, "ARTWORK");
    border:SetColorTexture(unpack(Colors.divider));
    border:SetPoint("BOTTOMLEFT", filterBar, "BOTTOMLEFT", 0, 0);
    border:SetPoint("BOTTOMRIGHT", filterBar, "BOTTOMRIGHT", 0, 0);
    Pixel.SetLineHeight(border, 1);

    addEntryButton = CreateFrame("Button", nil, filterBar, "BackdropTemplate");
    Skin.Button(addEntryButton, "primary");
    addEntryButton:SetHeight(Sizes.filterBar.addButtonHeight);
    addEntryButton:SetPoint("RIGHT", filterBar, "RIGHT", -Sizes.filterBar.padX, 0);
    addEntryButton.icon = addEntryButton:CreateTexture(nil, "ARTWORK");
    addEntryButton.icon:SetSize(10, 10);
    addEntryButton.icon:SetTexture(PLUS_TEXTURE);
    addEntryButton.icon:SetVertexColor(unpack(Colors.gold));
    addEntryButton.text:SetText("Add Entry");
    local iconGap = 5;
    addEntryButton:SetWidth(addEntryButton.icon:GetWidth() + iconGap + addEntryButton.text:GetStringWidth() + 24);
    addEntryButton.icon:SetPoint("LEFT", addEntryButton, "LEFT", 10, 0);
    addEntryButton.text:ClearAllPoints();
    addEntryButton.text:SetPoint("LEFT", addEntryButton.icon, "RIGHT", iconGap, 0);
    addEntryButton:SetScript("OnClick", function() showAddEntryPopup(); end);

    local function createFilterChip()
        local tag = CreateFrame("Frame", nil, filterBar, "BackdropTemplate");
        local tagText = tag:CreateFontString(nil, "OVERLAY");
        SetFont(tagText, "tiny");

        local itemIcon = filterBar:CreateTexture(nil, "ARTWORK");
        itemIcon:SetSize(Sizes.filterBar.itemIconSize, Sizes.filterBar.itemIconSize);
        itemIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92);
        local itemIconBorder = CreateFrame("Frame", nil, filterBar, "BackdropTemplate");

        local valueText = filterBar:CreateFontString(nil, "OVERLAY");
        SetFont(valueText, "body");
        valueText:SetJustifyH("LEFT");
        valueText:SetWordWrap(false);

        return { tag = tag, tagText = tagText, valueText = valueText, itemIcon = itemIcon, itemIconBorder = itemIconBorder };
    end
    filterChips[1] = createFilterChip();
    filterChips[2] = createFilterChip();

    filterCountText = filterBar:CreateFontString(nil, "OVERLAY");
    SetFont(filterCountText, "small");
    filterCountText:SetTextColor(unpack(Colors.muted));
    filterCountText:SetJustifyH("LEFT");

    filterClearText = filterBar:CreateFontString(nil, "OVERLAY");
    SetFont(filterClearText, "small");
    filterClearText:SetTextColor(unpack(Colors.muted));
    filterClearText:SetText("Clear filter");
    filterClearText:SetJustifyH("LEFT");

    filterClearUnderline = filterBar:CreateTexture(nil, "OVERLAY");
    filterClearUnderline:SetColorTexture(unpack(Colors.text));
    Pixel.SetLineHeight(filterClearUnderline, 1);
    filterClearUnderline:Hide();

    filterClearButton = CreateFrame("Button", nil, filterBar);
    filterClearButton:HookScript("OnEnter", function()
        filterClearText:SetTextColor(unpack(Colors.text));
        filterClearUnderline:ClearAllPoints();
        filterClearUnderline:SetPoint("BOTTOMLEFT", filterClearText, "BOTTOMLEFT", 0, -1);
        filterClearUnderline:SetPoint("BOTTOMRIGHT", filterClearText, "BOTTOMRIGHT", 0, -1);
        filterClearUnderline:Show();
    end);
    filterClearButton:HookScript("OnLeave", function()
        filterClearText:SetTextColor(unpack(Colors.muted));
        filterClearUnderline:Hide();
    end);
    filterClearButton:SetScript("OnClick", function() applyFilter(nil); end);

    return filterBar;
end

--- Paints one chip (`kind` = "all"|"date"|"player"|"item") and returns its
--- rightmost widget, for the next element (a separator, the count, or the
--- next chip) to anchor off of.
local function paintFilterChip(chip, kind, key)
    chip.itemIcon:Hide();
    chip.itemIconBorder:Hide();
    chip.valueText:Hide();

    if (kind == "all") then
        Theme.Helpers.SetFlatBackdrop(chip.tag, Colors.disabledBorder, Colors.disabledBorder, 1);
        chip.tagText:SetTextColor(unpack(Colors.description));
        chip.tagText:SetText("ALL");
    else
        Theme.Helpers.SetFlatBackdrop(chip.tag, Colors.gold, Colors.gold, 1);
        chip.tagText:SetTextColor(unpack(Colors.text));

        if (kind == "date") then
            chip.tagText:SetText("DATE");
        elseif (kind == "player") then
            chip.tagText:SetText("PLAYER");
        elseif (kind == "item") then
            chip.tagText:SetText("ITEM");
        end
    end

    chip.tagText:ClearAllPoints();
    chip.tagText:SetPoint("CENTER", chip.tag, "CENTER", 0, 0);
    chip.tag:SetSize(
        chip.tagText:GetStringWidth() + Sizes.filterBar.typeTagPadX * 2,
        chip.tagText:GetStringHeight() + Sizes.filterBar.typeTagPadY * 2
    );
    chip.tag:Show();

    return chip.tag;
end

local function paintFilterBar(filter, results)
    for _, chip in ipairs(filterChips) do
        chip.tag:Hide();
        chip.valueText:Hide();
        chip.itemIcon:Hide();
        chip.itemIconBorder:Hide();
    end
    -- Date is independent and always shown first; Player/Item are mutually
    -- exclusive so at most one of them ever occupies the second chip slot.
    -- "all" is a synthetic third kind so the no-filter state reuses the same
    -- single-chip painting path as a single real filter.
    local dims = {};
    if (filter and filter.date) then table.insert(dims, { kind = "date", key = filter.date }); end
    if (filter and filter.player) then
        table.insert(dims, { kind = "player", key = filter.player });
    elseif (filter and filter.item) then
        table.insert(dims, { kind = "item", key = filter.item });
    end
    if (#dims == 0) then table.insert(dims, { kind = "all" }); end

    local lastAnchor;
    for i, dim in ipairs(dims) do
        local chip = filterChips[i];
        chip.tag:ClearAllPoints();
        if (i == 1) then
            chip.tag:SetPoint("LEFT", filterBar, "LEFT", Sizes.filterBar.padX, 0);
        else
            chip.tag:SetPoint("LEFT", lastAnchor, "RIGHT", Sizes.filterBar.gap, 0);
        end
        lastAnchor = paintFilterChip(chip, dim.kind, dim.key);
    end

    local hasRealFilter = dims[1].kind ~= "all";
    filterClearButton:SetShown(hasRealFilter);
    filterClearText:SetShown(hasRealFilter);

    local count = #results;
    filterCountText:SetText(count == 1 and "1 award" or (tostring(count) .. " awards"));
    filterCountText:ClearAllPoints();
    filterCountText:SetPoint("LEFT", lastAnchor, "RIGHT", Sizes.filterBar.gap, 0);

    if (filterClearText:IsShown()) then
        filterClearText:ClearAllPoints();
        filterClearText:SetPoint("LEFT", filterCountText, "RIGHT", Sizes.filterBar.gap, 0);
        filterClearButton:ClearAllPoints();
        filterClearButton:SetPoint("TOPLEFT", filterClearText, "TOPLEFT");
        filterClearButton:SetPoint("BOTTOMRIGHT", filterClearText, "BOTTOMRIGHT");
    end
end

--------------------------------------------------------------------------
-- Result rows. See §5-6.
--------------------------------------------------------------------------

local function buildCandidateList(entry)
    local list = {};
    for name, data in pairs(entry.responses or {}) do
        table.insert(list, { name = name, response = data.response, note = data.note, votes = data.votes or 0, class = data.class });
    end
    local winnerName = entry.awardedTo;
    table.sort(list, function(a, b)
        if ((a.name == winnerName) ~= (b.name == winnerName)) then return a.name == winnerName; end
        if (a.votes ~= b.votes) then return a.votes > b.votes; end
        return a.name:lower() < b.name:lower();
    end);
    return list;
end

local function createCandidateRow(index)
    local row = CreateFrame("Frame", nil, expandedBlock.candidateList);
    row:SetHeight(Sizes.expanded.rowHeight);
    row:EnableMouse(true);

    row.fill = row:CreateTexture(nil, "BACKGROUND");
    row.fill:SetAllPoints();
    row.fill:SetColorTexture(unpack(Colors.lhCandidateFill));
    row.fill:Hide();

    row.crown = row:CreateTexture(nil, "OVERLAY");
    row.crown:SetSize(Sizes.expanded.crownSize, Sizes.expanded.crownSize);
    row.crown:SetPoint("LEFT", row, "LEFT", 0, 0);
    row.crown:SetTexture(CROWN_TEXTURE);
    row.crown:Hide();

    row.nameText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.nameText, "helper");
    row.nameText:SetTextColor(unpack(Colors.text));
    row.nameText:SetJustifyH("LEFT");
    row.nameText:SetWordWrap(false);
    row.nameText:SetPoint("LEFT", row, "LEFT", 0, 0);

    row.pill = buildPill(row);

    row.votesText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.votesText, "helper");
    row.votesText:SetTextColor(unpack(Colors.text));
    row.votesText:SetPoint("LEFT", row, "LEFT", Sizes.expanded.colCandidate + Sizes.expanded.colResponse, 0);
    row.votesText:SetWidth(Sizes.expanded.colVotes);

    row.noteText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.noteText, "helper");
    row.noteText:SetTextColor(unpack(Colors.description));
    row.noteText:SetJustifyH("LEFT");
    row.noteText:SetWordWrap(false);
    row.noteText:SetPoint("LEFT", row, "LEFT", Sizes.expanded.colCandidate + Sizes.expanded.colResponse + Sizes.expanded.colVotes, 0);
    row.noteText:SetPoint("RIGHT", row, "RIGHT", 0, 0);

    row:SetScript("OnEnter", function(self)
        if (self.noteTruncated and self.fullNote and self.fullNote ~= "") then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:AddLine(self.fullNote, 1, 1, 1, true);
            GameTooltip:Show();
        end
    end);
    row:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    return row;
end

local function paintCandidateRow(row, cand, isWinner)
    row.fill:SetShown(isWinner);
    row.crown:SetShown(isWinner);
    local nameX = isWinner and (Sizes.expanded.crownSize + Sizes.expanded.crownGap) or 0;
    row.nameText:ClearAllPoints();
    row.nameText:SetPoint("LEFT", row, "LEFT", nameX, 0);
    row.nameText:SetWidth(Sizes.expanded.colCandidate - nameX);
    row.nameText:SetTextColor(classColorRGB(cand.class));
    setTextEllipsized(row.nameText, cand.name, Sizes.expanded.colCandidate - nameX);

    row.pill:ClearAllPoints();
    row.pill:SetPoint("LEFT", row, "LEFT", Sizes.expanded.colCandidate, 0);
    paintResponsePill(row.pill, cand.response, Sizes.expanded.colResponse - 10);

    row.votesText:SetText(tostring(cand.votes or 0));

    row.fullNote = cand.note or "";
    row.noteTruncated = setTextEllipsized(row.noteText, cand.note or "", row.noteText:GetWidth());
end

local function ensureExpandedBlock()
    if (expandedBlock) then return; end
    expandedBlock = CreateFrame("Frame", nil, resultsScrollChild);

    expandedBlock.rule = expandedBlock:CreateTexture(nil, "ARTWORK");
    expandedBlock.rule:SetColorTexture(unpack(Colors.divider));
    expandedBlock.rule:SetPoint("TOPLEFT", expandedBlock, "TOPLEFT", 0, 0);
    expandedBlock.rule:SetPoint("TOPRIGHT", expandedBlock, "TOPRIGHT", 0, 0);
    Pixel.SetLineHeight(expandedBlock.rule, 1);

    expandedBlock.header = CreateFrame("Frame", nil, expandedBlock);
    expandedBlock.header:SetPoint("TOPLEFT", expandedBlock.rule, "BOTTOMLEFT", 0, -Sizes.expanded.topPad);
    expandedBlock.header:SetPoint("TOPRIGHT", expandedBlock.rule, "BOTTOMRIGHT", 0, -Sizes.expanded.topPad);
    expandedBlock.header:SetHeight(Sizes.expanded.headerRowHeight);

    local e = Sizes.expanded;
    local function headerLabel(text, x, width)
        local fs = expandedBlock.header:CreateFontString(nil, "OVERLAY");
        SetFont(fs, "tiny");
        fs:SetTextColor(unpack(Colors.controlHover));
        fs:SetText(text);
        fs:SetJustifyH("LEFT");
        fs:SetPoint("LEFT", expandedBlock.header, "LEFT", x, 0);
        if (width) then fs:SetWidth(width); end
        return fs;
    end
    headerLabel("CANDIDATE", 0, e.colCandidate);
    headerLabel("RESPONSE", e.colCandidate, e.colResponse);
    headerLabel("VOTES", e.colCandidate + e.colResponse, e.colVotes);
    local noteHeader = headerLabel("NOTE", e.colCandidate + e.colResponse + e.colVotes);
    noteHeader:SetPoint("RIGHT", expandedBlock.header, "RIGHT", 0, 0);

    expandedBlock.candidateList = CreateFrame("Frame", nil, expandedBlock);
    expandedBlock.candidateList:SetPoint("TOPLEFT", expandedBlock.header, "BOTTOMLEFT", 0, 0);
    expandedBlock.candidateList:SetPoint("TOPRIGHT", expandedBlock.header, "BOTTOMRIGHT", 0, 0);

    expandedBlock.extraLine = expandedBlock:CreateFontString(nil, "OVERLAY");
    SetFont(expandedBlock.extraLine, "small");
    expandedBlock.extraLine:SetTextColor(unpack(Colors.muted));
    expandedBlock.extraLine:SetJustifyH("LEFT");
    expandedBlock.extraLine:SetWordWrap(true);
    expandedBlock.extraLine:Hide();

    expandedBlock.fallback1 = expandedBlock:CreateFontString(nil, "OVERLAY");
    SetFont(expandedBlock.fallback1, "body");
    expandedBlock.fallback1:SetJustifyH("LEFT");
    expandedBlock.fallback1:SetWordWrap(true);
    expandedBlock.fallback1:SetPoint("TOPLEFT", expandedBlock.rule, "BOTTOMLEFT", 0, -Sizes.expanded.topPad);
    expandedBlock.fallback1:SetPoint("TOPRIGHT", expandedBlock.rule, "BOTTOMRIGHT", 0, -Sizes.expanded.topPad);
    expandedBlock.fallback1:Hide();

    expandedBlock.fallback3 = expandedBlock:CreateFontString(nil, "OVERLAY");
    SetFont(expandedBlock.fallback3, "body");
    expandedBlock.fallback3:SetTextColor(unpack(Colors.description));
    expandedBlock.fallback3:SetJustifyH("LEFT");
    expandedBlock.fallback3:SetWordWrap(true);
    expandedBlock.fallback3:Hide();
end

--- Lays out `expandedBlock` under `row` for `entry`, returning the row's
--- total (collapsed + expanded content) height.
local function layoutExpandedBlock(row, entry)
    ensureExpandedBlock();
    expandedBlock:SetParent(row);
    expandedBlock:ClearAllPoints();
    expandedBlock:SetPoint("TOPLEFT", row, "TOPLEFT", Sizes.expanded.leftInset, -Sizes.resultRow.collapsedHeight);
    expandedBlock:SetPoint("TOPRIGHT", row, "TOPRIGHT", -Sizes.expanded.rightMargin, -Sizes.resultRow.collapsedHeight);
    expandedBlock:Show();

    expandedBlock.header:Hide();
    expandedBlock.candidateList:Hide();
    expandedBlock.extraLine:Hide();
    expandedBlock.fallback1:Hide();
    expandedBlock.fallback3:Hide();

    local candidates = buildCandidateList(entry);
    local contentHeight;

    if (#candidates > 0) then
        expandedBlock.header:Show();
        expandedBlock.candidateList:Show();

        for i, cand in ipairs(candidates) do
            candidateRows[i] = candidateRows[i] or createCandidateRow(i);
            local candRow = candidateRows[i];
            candRow:ClearAllPoints();
            candRow:SetPoint("TOPLEFT", expandedBlock.candidateList, "TOPLEFT", 0, -(i - 1) * (Sizes.expanded.rowHeight + Sizes.expanded.rowGap));
            candRow:SetPoint("RIGHT", expandedBlock.candidateList, "RIGHT", 0, 0);
            paintCandidateRow(candRow, cand, cand.name == entry.awardedTo);
            candRow:Show();
        end
        for i = #candidates + 1, #candidateRows do candidateRows[i]:Hide(); end

        local n = #candidates;
        local listHeight = n * Sizes.expanded.rowHeight + math.max(n - 1, 0) * Sizes.expanded.rowGap;
        expandedBlock.candidateList:SetHeight(listHeight);
        contentHeight = Sizes.expanded.topPad + Sizes.expanded.headerRowHeight + listHeight;

        if (entry.awardedToClass == nil) then
            expandedBlock.extraLine:Show();
            expandedBlock.extraLine:ClearAllPoints();
            expandedBlock.extraLine:SetPoint("TOPLEFT", expandedBlock.candidateList, "BOTTOMLEFT", 0, -(Sizes.expanded.rowGap + 3));
            expandedBlock.extraLine:SetPoint("TOPRIGHT", expandedBlock.candidateList, "BOTTOMRIGHT", 0, -(Sizes.expanded.rowGap + 3));
            expandedBlock.extraLine:SetText(("%s was awarded this item without responding."):format(entry.awardedTo or "?"));
            contentHeight = contentHeight + Sizes.expanded.rowGap + 3 + expandedBlock.extraLine:GetStringHeight();
        end
    elseif (entry.manual) then
        for i = 1, #candidateRows do candidateRows[i]:Hide(); end

        expandedBlock.fallback1:Show();
        expandedBlock.fallback1:SetTextColor(unpack(Colors.disabledText));
        expandedBlock.fallback1:SetText("Added by hand, no candidate data.");
        contentHeight = Sizes.expanded.topPad + expandedBlock.fallback1:GetStringHeight();

        local anchorAbove = expandedBlock.fallback1;

        if (entry.note) then
            expandedBlock.fallback3:Show();
            expandedBlock.fallback3:ClearAllPoints();
            expandedBlock.fallback3:SetPoint("TOPLEFT", anchorAbove, "BOTTOMLEFT", 0, -(Sizes.expanded.rowGap + 3));
            expandedBlock.fallback3:SetPoint("TOPRIGHT", expandedBlock, "TOPRIGHT", 0, 0);
            expandedBlock.fallback3:SetText("Note: " .. entry.note);
            contentHeight = contentHeight + Sizes.expanded.rowGap + 3 + expandedBlock.fallback3:GetStringHeight();
        end
    else
        for i = 1, #candidateRows do candidateRows[i]:Hide(); end

        expandedBlock.fallback1:Show();
        expandedBlock.fallback1:SetTextColor(unpack(Colors.disabledText));
        expandedBlock.fallback1:SetText("No candidate data.");
        contentHeight = Sizes.expanded.topPad + expandedBlock.fallback1:GetStringHeight();
    end

    expandedBlock:SetHeight(contentHeight + Sizes.expanded.bottomMargin);
    return Sizes.resultRow.collapsedHeight + contentHeight + Sizes.expanded.bottomMargin;
end

local function createResultRow()
    local row = CreateFrame("Button", nil, resultsScrollChild, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(row, Colors.transparent, Colors.transparent, 1);

    row.divider = row:CreateTexture(nil, "ARTWORK");
    row.divider:SetColorTexture(unpack(Colors.lhResultDivider));
    row.divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0);
    row.divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0);
    Pixel.SetLineHeight(row.divider, 1);

    row:HookScript("OnEnter", function(self) if (not self.expanded) then self:SetBackdropColor(unpack(Colors.hoverBg)); end end);
    row:HookScript("OnLeave", function(self) if (not self.expanded) then self:SetBackdropColor(unpack(Colors.transparent)); end end);
    row:SetScript("OnClick", function(self)
        if (self.entry) then toggleExpand(self.entry.id); end
    end);

    row.icon = row:CreateTexture(nil, "ARTWORK");
    row.icon:SetSize(Sizes.resultRow.iconSize, Sizes.resultRow.iconSize);
    row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", Sizes.resultRow.pad, -Sizes.resultRow.pad);
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);
    row.iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
    row.iconBorder:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -1, 1);
    row.iconBorder:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(row.iconBorder, nil, Colors.transparent, Sizes.resultRow.iconBorder);

    -- Tooltip - only over the icon itself, not the whole row. Also required
    -- to be within resultsScroll's own bounds (Util.IsMouseOverVisible) - a
    -- row scrolled out of the visible list still occupies its original
    -- on-screen rect as far as IsMouseOver is concerned, since ScrollFrame
    -- only clips rendering.
    row:HookScript("OnUpdate", function(self)
        if (self.entry and Util.IsMouseOverVisible(self.icon, resultsScroll)) then
            GameTooltip:SetOwner(self.icon, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink(self.entry.itemLink);
            GameTooltip:Show();
        elseif (GameTooltip:GetOwner() == self.icon) then
            GameTooltip:Hide();
        end
    end);

    row.chevron = row:CreateTexture(nil, "OVERLAY");
    row.chevron:SetSize(Sizes.resultRow.chevronSize, Sizes.resultRow.chevronSize);
    row.chevron:SetPoint("TOPRIGHT", row, "TOPRIGHT", -Sizes.resultRow.pad, -(Sizes.resultRow.collapsedHeight - Sizes.resultRow.chevronSize) / 2);
    row.chevron:SetAtlas(ARROW_ATLAS);
    row.chevron:SetVertexColor(unpack(Colors.controlHover));

    -- Delete-mode overlay: a real Button sitting above row's own click area
    -- (same technique as the itemName/winner/date carve-outs below), sized
    -- and positioned exactly over row.chevron so the trash icon replaces the
    -- arrow in place. Hidden outside delete mode, so the row's own OnClick
    -- (toggleExpand) still fires everywhere else. See setDeleteMode.
    row.deleteButton = CreateFrame("Button", nil, row);
    row.deleteButton:SetFrameLevel(row:GetFrameLevel() + 1);
    row.deleteButton:SetAllPoints(row.chevron);
    row.deleteButton:Hide();

    row.trashIcon = row.deleteButton:CreateTexture(nil, "OVERLAY");
    row.trashIcon:SetAllPoints(row.deleteButton);
    row.trashIcon:SetTexture(TRASH_ICON_TEXTURE);
    row.trashIcon:SetVertexColor(unpack(Colors.muted));

    row.deleteButton:HookScript("OnEnter", function()
        row.trashIcon:SetVertexColor(unpack(Colors.sessionDeleteHoverIcon));
    end);
    row.deleteButton:HookScript("OnLeave", function()
        row.trashIcon:SetVertexColor(unpack(Colors.muted));
    end);
    row.deleteButton:SetScript("OnClick", function()
        if (row.entry) then deleteEntry(row.entry); end
    end);

    row.dateText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.dateText, "smaller");
    row.dateText:SetTextColor(unpack(Colors.description));
    row.dateText:SetJustifyH("RIGHT");
    row.dateText:SetPoint("TOPRIGHT", row.chevron, "TOPLEFT", -Sizes.resultRow.gap, 0);

    row.byText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.byText, "smaller");
    row.byText:SetTextColor(unpack(Colors.muted));
    row.byText:SetJustifyH("RIGHT");
    row.byText:SetPoint("TOPRIGHT", row.dateText, "BOTTOMRIGHT", 0, -Sizes.resultRow.textLineGap);

    row.nameText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.nameText, "body");
    row.nameText:SetJustifyH("LEFT");
    row.nameText:SetWordWrap(false);
    row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", Sizes.resultRow.gap, 0);

    row.manualTag = CreateFrame("Frame", nil, row, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(row.manualTag, Colors.transparent, Colors.lhManualTagBorder, 1);
    row.manualTag.text = row.manualTag:CreateFontString(nil, "OVERLAY");
    SetFont(row.manualTag.text, "tiny");
    row.manualTag.text:SetTextColor(unpack(Colors.lhManualTagText));
    row.manualTag.text:SetText("MANUAL");
    row.manualTag.text:SetPoint("CENTER", row.manualTag, "CENTER", 0, 0);
    row.manualTag:SetSize(row.manualTag.text:GetStringWidth() + Sizes.resultRow.manualTagPadX * 2, row.manualTag.text:GetStringHeight() + 4);
    row.manualTag:Hide();

    row.metaTo = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.metaTo, "smaller");
    row.metaTo:SetTextColor(unpack(Colors.muted));
    row.metaTo:SetJustifyH("LEFT");
    row.metaTo:SetText("to");
    row.metaTo:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -Sizes.resultRow.textLineGap);

    row.winnerName = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.winnerName, "smaller");
    row.winnerName:SetJustifyH("LEFT");
    row.winnerName:SetPoint("LEFT", row.metaTo, "RIGHT", 1, 0);

    row.pill = buildPill(row);
    row.pill:SetPoint("LEFT", row.winnerName, "RIGHT", Sizes.resultRow.metaGap, 0);

    row.votesText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.votesText, "smaller");
    row.votesText:SetTextColor(unpack(Colors.muted));
    row.votesText:SetJustifyH("LEFT");
    row.votesText:SetPoint("LEFT", row.pill, "RIGHT", Sizes.resultRow.metaGap, 0);

    -- Manual pin action (spec 10.5) - "Pin"/"Pinned" text, same small-link
    -- styling as the filter bar's "Clear filter" (filterClearText/Button).
    -- Shown only for officers (FL.Sync.Permissions.CanPin), and only while the
    -- lock button has unlocked delete mode - the same "edit history" state as
    -- the trash icon, so neither permanent action shows by default. Width
    -- and left anchor are set per-row in measureAndPaintResultRow since they
    -- depend on whether votesText is shown.
    row.pinButton = CreateFrame("Button", nil, row);
    row.pinButton:SetFrameLevel(row:GetFrameLevel() + 1);
    row.pinButton:SetHeight(Sizes.resultRow.collapsedHeight);
    row.pinButton:Hide();
    row.pinText = row.pinButton:CreateFontString(nil, "OVERLAY");
    SetFont(row.pinText, "smaller");
    row.pinText:SetPoint("LEFT", row.pinButton, "LEFT", 0, 0);
    row.pinButton:HookScript("OnEnter", function()
        if (row.entry and not FL.DB.lootCouncil.pins[row.entry.id]) then
            row.pinText:SetTextColor(unpack(Colors.text));
        end
    end);
    row.pinButton:HookScript("OnLeave", function()
        if (row.entry and not FL.DB.lootCouncil.pins[row.entry.id]) then
            row.pinText:SetTextColor(unpack(Colors.muted));
        end
    end);
    row.pinButton:SetScript("OnClick", function()
        if (row.entry and not FL.DB.lootCouncil.pins[row.entry.id]) then
            pinEntry(row.entry);
        end
    end);

    -- Click-target carve-outs (item name / winner name / date), each a real
    -- Button sitting above the row's own click area - same technique
    -- TradeQueueWindow.createRow uses for its trash button vs. main button,
    -- generalized to 3 carve-outs via an explicit higher frame level.
    local function makeClickTarget(fontString, underlineColor)
        local button = CreateFrame("Button", nil, row);
        button:SetFrameLevel(row:GetFrameLevel() + 1);
        button:SetPoint("TOPLEFT", fontString, "TOPLEFT");
        button:SetPoint("BOTTOMRIGHT", fontString, "BOTTOMRIGHT");
        local underline = row:CreateTexture(nil, "OVERLAY");
        underline:SetColorTexture(unpack(underlineColor));
        Pixel.SetLineHeight(underline, 1);
        underline:SetPoint("BOTTOMLEFT", fontString, "BOTTOMLEFT", 0, -1);
        underline:SetPoint("BOTTOMRIGHT", fontString, "BOTTOMRIGHT", 0, -1);
        underline:Hide();
        button:HookScript("OnEnter", function() underline:Show(); end);
        button:HookScript("OnLeave", function() underline:Hide(); end);
        return button;
    end

    row.itemNameButton = makeClickTarget(row.nameText, Colors.text);
    row.itemNameButton:HookScript("OnEnter", function()
        if (row.entry and row.entry.itemLink) then
            GameTooltip:SetOwner(row.itemNameButton, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink(row.entry.itemLink);
            GameTooltip:Show();
        end
    end);
    row.itemNameButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);
    row.itemNameButton:SetScript("OnClick", function()
        if (not row.entry) then return; end
        if (Util.HandleItemLinkClick(row.entry.itemLink)) then return; end
        applyFilter({ item = row.entry.itemID });
    end);

    row.winnerButton = makeClickTarget(row.winnerName, Colors.text)
    row.winnerButton:SetScript("OnClick", function()
        if (not row.entry) then return; end
        applyFilter({ player = row.entry.awardedTo });
    end);

    row.dateButton = makeClickTarget(row.dateText, Colors.description);
    row.dateButton:SetScript("OnClick", function()
        if (not row.entry) then return; end
        applyFilter({ date = dayKey(row.entry.awardedAt) });
    end);

    row:Hide();
    return row;
end

local function measureAndPaintResultRow(row, entry)
    row.entry = entry;
    local isExpanded = (entry.id == expandedEntryId);
    row.expanded = isExpanded;

    -- Rows are recycled constantly now, so only re-apply the backdrop when
    -- the expanded state actually changes (new rows are created transparent).
    -- SetBackdrop resolves the row's size, which is unreliable mid-layout.
    if (isExpanded) then
        if (not row.backdropExpanded) then
            Theme.Helpers.SetFlatBackdrop(row, Colors.lhExpandedBg, Colors.disabledBorder, 1);
            row.backdropExpanded = true;
        end
        row.divider:Hide();
    else
        if (row.backdropExpanded) then
            Theme.Helpers.SetFlatBackdrop(row, Colors.transparent, Colors.transparent, 1);
            row.backdropExpanded = false;
        end
        row.divider:Show();
    end

    row.icon:SetTexture(entry.itemIcon or Util.GetItemIcon(entry.itemID) or FALLBACK_ICON);
    local qr, qg, qb = Util.GetItemQualityColor(Util.GetItemQuality(entry.itemLink or entry.itemID));
    qr, qg, qb = qr or 0.6, qg or 0.6, qb or 0.6;
    row.iconBorder:SetBackdropBorderColor(qr, qg, qb);

    row.nameText:SetTextColor(qr, qg, qb);
    local itemName = entry.itemLink and Util.GetItemInfo(entry.itemLink);
    setTextEllipsized(row.nameText, "[" .. (itemName or "?") .. "]", 220);

    if (entry.manual) then
        row.manualTag:Show();
        row.manualTag:ClearAllPoints();
        row.manualTag:SetPoint("LEFT", row.nameText, "RIGHT", Sizes.resultRow.manualTagGap, 0);
    else
        row.manualTag:Hide();
    end

    local r, g, b = classColorRGB(entry.awardedToClass);
    row.winnerName:SetTextColor(r, g, b);
    row.winnerName:SetText(entry.awardedTo or "?");

    local respData = entry.responses and entry.responses[entry.awardedTo];
    local responseEntry = (respData and respData.response) or entry.response;
    paintResponsePill(row.pill, responseEntry, 90);
    row.pill:ClearAllPoints();
    row.pill:SetPoint("LEFT", row.winnerName, "RIGHT", Sizes.resultRow.metaGap, 0);

    if (respData and respData.votes) then
        row.votesText:Show();
        row.votesText:SetText("\194\183 " .. (respData.votes == 1 and "1 vote" or (tostring(respData.votes) .. " votes")));
        row.votesText:ClearAllPoints();
        row.votesText:SetPoint("LEFT", row.pill, "RIGHT", Sizes.resultRow.metaGap, 0);
    else
        row.votesText:Hide();
    end

    if (not deleteModeActive or not FL.Sync.Permissions.CanPin(Util.UnitName("player"))) then
        row.pinButton:Hide();
    else
        local isPinned = FL.DB.lootCouncil.pins[entry.id] ~= nil;
        row.pinText:SetText(isPinned and "Pinned" or "Pin");
        row.pinText:SetTextColor(unpack(isPinned and Colors.gold or Colors.muted));
        row.pinButton:SetWidth(row.pinText:GetStringWidth() + 4);
        row.pinButton:ClearAllPoints();
        row.pinButton:SetPoint("LEFT", row.votesText:IsShown() and row.votesText or row.pill, "RIGHT", Sizes.resultRow.metaGap, 0);
        row.pinButton:Show();
    end

    row.dateText:SetText(dayLabel(entry.awardedAt));
    row.byText:SetText(timeLabel(entry.awardedAt) .. " \194\183 by " .. (entry.awardedBy or "?"));

    if (deleteModeActive) then
        row.chevron:Hide();
        row.deleteButton:Show();
    else
        row.deleteButton:Hide();
        row.chevron:Show();
        row.chevron:SetRotation(isExpanded and math.pi or 0);
    end

    if (isExpanded) then
        return layoutExpandedBlock(row, entry);
    end
    return Sizes.resultRow.collapsedHeight;
end

-- Result list virtualization. Only the rows overlapping the scroll viewport
-- (plus a little overscan) exist as bound frames; the scroll child's height
-- and every row's Y position are derived from the entry count, so a 1500+
-- row history costs the same handful of frames as a 20-row one. At most one
-- entry is expanded (taller), tracked as expandedIndex/expandedHeight.
local RESULT_OVERSCAN_ROWS = 2;
local MIN_VIEW_HEIGHT = 400;
local expandedIndex, expandedHeight, expandedExtra = nil, nil, 0;

local function resultStride()
    return Sizes.resultRow.collapsedHeight + Sizes.resultList.gap;
end

local function resultTop(i)
    local top = (i - 1) * resultStride();
    if (expandedIndex and i > expandedIndex) then top = top + expandedExtra; end
    return top;
end

local function resultHeight(i)
    if (i == expandedIndex) then return expandedHeight; end
    return Sizes.resultRow.collapsedHeight;
end

local function freeResultRow(row)
    if (expandedBlock and expandedBlock:GetParent() == row) then
        expandedBlock:Hide();
        expandedBlock:SetParent(resultsScrollChild);
    end
    row.entry = nil;
    row.index = nil;
    row:Hide();
end

local function bindResultRow(row, i)
    row.index = i;
    row:ClearAllPoints();
    row:SetPoint("TOPLEFT", resultsScrollChild, "TOPLEFT", 0, -resultTop(i));
    row:SetPoint("RIGHT", resultsScrollChild, "RIGHT", 0, 0);
    row:SetHeight(Sizes.resultRow.collapsedHeight);
    row:SetHeight(measureAndPaintResultRow(row, currentResults[i]));
    row:Show();
end

--- Binds the rows overlapping the viewport. `force` repaints every visible
--- row (data, delete mode, expansion or layout changed); without it, rows
--- already bound to a still-visible entry are left alone (plain scrolling).
local isRenderingRows = false;
local function renderVisibleRows(force)
    -- GetHeight below can resolve layout and fire resultsScroll's
    -- OnSizeChanged, which calls back in here mid-render; ignore that.
    if (isRenderingRows) then return; end
    isRenderingRows = true;
    local n = #currentResults;
    if (n == 0) then
        for _, row in ipairs(resultRows) do freeResultRow(row); end
        isRenderingRows = false;
        return;
    end

    local overscan = RESULT_OVERSCAN_ROWS * resultStride();
    local viewTop = resultsScroll:GetVerticalScroll();
    local viewHeight = math.max(resultsScroll:GetHeight(), MIN_VIEW_HEIGHT);
    local topLimit, bottomLimit = viewTop - overscan, viewTop + viewHeight + overscan;

    local lo, hi = 1, n;
    while (lo < hi) do
        local mid = math.floor((lo + hi) / 2);
        if (resultTop(mid) + resultHeight(mid) > topLimit) then hi = mid; else lo = mid + 1; end
    end
    local first, last = lo, lo;
    while (last < n and resultTop(last + 1) < bottomLimit) do last = last + 1; end

    local kept, free = {}, {};
    for _, row in ipairs(resultRows) do
        local idx = row.index;
        if (not force and idx and idx >= first and idx <= last and currentResults[idx] == row.entry) then
            kept[idx] = row;
        else
            freeResultRow(row);
            free[#free + 1] = row;
        end
    end
    for i = first, last do
        if (not kept[i]) then
            local row = table.remove(free);
            if (not row) then
                row = createResultRow();
                resultRows[#resultRows + 1] = row;
            end
            bindResultRow(row, i);
        end
    end
    isRenderingRows = false;
end

function layoutResultRows(results)
    currentResults = results;

    expandedIndex, expandedHeight, expandedExtra = nil, nil, 0;
    if (expandedEntryId) then
        for i, entry in ipairs(results) do
            if (entry.id == expandedEntryId) then expandedIndex = i; break; end
        end
    end
    if (expandedIndex) then
        -- The expanded height depends on its content, so measure it on a pool
        -- row first (renderVisibleRows below frees and rebinds every row).
        local row = resultRows[1];
        if (not row) then
            row = createResultRow();
            resultRows[1] = row;
        end
        row:ClearAllPoints();
        row:SetPoint("TOPLEFT", resultsScrollChild, "TOPLEFT", 0, 0);
        row:SetPoint("RIGHT", resultsScrollChild, "RIGHT", 0, 0);
        row:SetHeight(Sizes.resultRow.collapsedHeight);
        expandedHeight = measureAndPaintResultRow(row, results[expandedIndex]);
        expandedExtra = expandedHeight - Sizes.resultRow.collapsedHeight;
    elseif (expandedBlock) then
        expandedBlock:Hide();
    end

    resultsScrollChild:SetHeight(math.max(#results * resultStride() + expandedExtra, 1));
    renderVisibleRows(true);

    emptyResultsText:SetShown(#results == 0);
    if (resultsScroll.ScrollBar and resultsScroll.ScrollBar.zlUpdateVisibility) then resultsScroll.ScrollBar.zlUpdateVisibility(); end

    if (expandedIndex) then
        local top = resultTop(expandedIndex);
        return { topY = top, bottomY = top + expandedHeight };
    end
end

function toggleExpand(entryId)
    if (expandedEntryId == entryId) then
        expandedEntryId = nil;
    else
        expandedEntryId = entryId;
    end
    local expandedRow = layoutResultRows(currentResults);
    if (expandedRow) then
        local viewTop = resultsScroll:GetVerticalScroll();
        local viewHeight = resultsScroll:GetHeight();
        if (expandedRow.bottomY > viewTop + viewHeight) then
            resultsScroll:SetVerticalScroll(expandedRow.bottomY - viewHeight);
        elseif (expandedRow.topY < viewTop) then
            resultsScroll:SetVerticalScroll(expandedRow.topY);
        end
    end
end

--------------------------------------------------------------------------
-- Filter state machine. See §3.
--------------------------------------------------------------------------

function applyFilter(newFilter)
    if (newFilter and newFilter.date == nil and newFilter.player == nil and newFilter.item == nil) then
        newFilter = nil;
    end
    currentFilter = newFilter;
    hasAppliedFilter = true;
    local results = resolveResults(newFilter);

    expandedEntryId = nil;
    resultsScroll:SetVerticalScroll(0);

    local dateKey = newFilter and newFilter.date or nil;
    local playerKey = newFilter and newFilter.player or nil;
    local itemKey = newFilter and newFilter.item or nil;

    dateColumn.setActive(dateKey ~= nil);
    playersColumn.setActive(playerKey ~= nil);
    itemsColumn.setActive(itemKey ~= nil);

    dateColumn.setSelectedKey(dateKey);
    playersColumn.setSelectedKey(playerKey);
    itemsColumn.setSelectedKey(itemKey);

    for _, pair in ipairs({
        { dateColumn, dateKey }, { playersColumn, playerKey }, { itemsColumn, itemKey },
    }) do
        local col, key = pair[1], pair[2];
        if (key ~= nil) then
            if (col.isKeyHiddenBySearch(key)) then col.clearSearch(); end
            col.scrollKeyIntoView(key);
        end
    end

    paintFilterBar(newFilter, results);
    layoutResultRows(results);
end

--------------------------------------------------------------------------
-- Delete mode - the titlebar lock button and per-row deletion. Deletes now
-- go through FL.Sync.Live.Delete (Data/Store.lua's tombstones, officer-only
-- per FL.Sync.Permissions.CanDelete), which also broadcasts them - no longer
-- the purely local-only action the header comment above used to describe.
--------------------------------------------------------------------------

local function paintLockButton()
    if (not lockButton) then return; end
    -- Re-checked on every repaint (window show, hover-leave, creation) since
    -- guild rank can change while the window stays open across logins.
    lockButton:SetShown(viewKey == nil and FL.Sync.Permissions.CanDelete(Util.UnitName("player")));
    if (deleteModeActive) then
        Theme.Helpers.SetFlatBackdrop(lockButton, Colors.sessionDeleteHoverBg, Colors.skinCloseBorder, 1);
        lockButton.icon:SetVertexColor(unpack(Colors.sessionDeleteHoverIcon));
    else
        Theme.Helpers.SetFlatBackdrop(lockButton, Colors.transparent, Colors.transparent, 1);
        lockButton.icon:SetVertexColor(unpack(Colors.muted));
    end
end

--- Toggled by lockButton's OnClick, and forced back to false whenever the
--- window is (re)shown (see LootHistoryWindow.Show) so leaving it unlocked
--- once never carries into a later session.
local function setDeleteMode(active)
    deleteModeActive = active;
    paintLockButton();
    layoutResultRows(currentResults);
end

--- Deletes `entry` via FL.Sync.Live.Delete (tombstones it in Data/Store.lua
--- and broadcasts the delete) and repaints. Only ever reachable through a
--- result row's trash button (deleteModeActive gates that button's
--- visibility, and the lock button itself is hidden for non-officers - see
--- paintLockButton), so no separate confirmation here - unlocking delete
--- mode via the lock button already is the confirmation step. Live.Delete
--- re-checks CanDelete itself regardless (rank could have changed since the
--- button was last painted), so this still no-ops safely if permission was
--- lost in between.
function deleteEntry(entry)
    if (not entry or not LootCouncil.History) then return; end
    if (not FL.Sync.Live.Delete(entry.id)) then return; end

    if (expandedEntryId == entry.id) then expandedEntryId = nil; end

    rebuildIndexes();
    dateColumn.refresh();
    playersColumn.refresh();
    itemsColumn.refresh();

    if (not filterStillValid(currentFilter)) then
        applyFilter(nil);
    else
        local results = resolveResults(currentFilter);
        paintFilterBar(currentFilter, results);
        layoutResultRows(results);
    end
end

--- Manual "Pin" action (spec 10.5): officers get the same policy as delete
--- (FL.Sync.Permissions.CanPin). Unlike deleteEntry, a pin never adds,
--- removes or moves a row - it's a separate stored entry alongside the row
--- (section 3.3) - so no rebuildIndexes()/sidebar refresh is needed, only a
--- repaint of the already-visible rows (the "EntryApplied" P-kind branch
--- below does the same repaint for every OTHER client that receives the
--- pin; this call site repaints eagerly too so the row updates instantly
--- rather than waiting on the callback round-trip).
local function doPin(entry)
    if (not FL.Sync.Live.Pin(entry.id)) then return; end
    layoutResultRows(currentResults);
end

--------------------------------------------------------------------------
-- Guild picker - view another guild's history on this account, read-only
-- (Data/Buckets.lua). Shown at the far left of the title bar, only when
-- another guild's history exists. The first option is this character's own guild, by name.
--------------------------------------------------------------------------

local function pickerOptions()
    local Buckets = FL.Sync.Buckets;
    local options = { { value = ACTIVE_VIEW, label = Buckets.LabelOf(Buckets.ActiveKey()) } };
    for _, bucket in ipairs(Buckets.List()) do
        table.insert(options, { value = bucket.key, label = bucket.label });
    end
    return options;
end

-- Skin.Dropdown builds its rows once, from the options it was given, so a
-- changed guild list gets a fresh dropdown (rare: a new guild's history
-- appears, or a guild is renamed).
local function ensureGuildPicker(options)
    local parts = {};
    for _, opt in ipairs(options) do table.insert(parts, opt.value .. "=" .. opt.label); end
    local signature = table.concat(parts, "\n");
    if (guildPicker and signature == guildPickerSignature) then return; end

    if (guildPicker) then guildPicker.button:Hide(); end
    guildPickerSignature = signature;
    guildPicker = Skin.Dropdown(titleBarFrame, {
        width = Sizes.guildPickerWidth,
        height = RootSizes.controls.close, -- same height as the close/lock buttons beside the title
        options = options,
        getValue = function() return viewKey or ACTIVE_VIEW; end,
        onSelect = function(value) LootHistoryWindow.SetView(value ~= ACTIVE_VIEW and value or nil); end,
    });
end

-- Title, Add Entry, lock button and guild picker for the current view.
local function paintViewControls()
    local viewing = viewKey ~= nil;
    addEntryButton:SetShown(not viewing);
    paintLockButton();
    windowTitle:SetText(viewing
        and ("%s \194\183 %s (view only)"):format(WINDOW_TITLE, FL.Sync.Buckets.LabelOf(viewKey))
        or WINDOW_TITLE);

    local options = pickerOptions();
    if (#options < 2) then
        if (guildPicker) then guildPicker.button:Hide(); end
        return;
    end
    ensureGuildPicker(options);
    guildPicker.button:ClearAllPoints();
    guildPicker.button:SetPoint("LEFT", titleBarFrame, "LEFT", 8, 0);
    guildPicker.button:Show();
    guildPicker.Refresh();
end

--- Shows `key`'s parked history read-only, or our own guild's for nil.
function LootHistoryWindow.SetView(key)
    viewKey = key;
    deleteModeActive = false;
    paintViewControls();
    rebuildIndexes();
    dateColumn.refresh();
    playersColumn.refresh();
    itemsColumn.refresh();
    applyFilter(nil);
end

--- Back to our own guild's history, e.g. after the active bucket changed
--- (Data/Buckets.lua's Select). Repaints if the window is open.
function LootHistoryWindow.ResetView()
    viewKey = nil;
    LootHistoryWindow.Refresh();
end

--------------------------------------------------------------------------
-- Pin confirmation popup. A pin is permanent (there is no unpin - the sync
-- system would just send a dropped pin back), so the manual Pin action asks
-- first. Built from the same pieces and metrics as the Award window's
-- assign popup (UI/AwardWindow.lua's ensurePopup): an item summary box
-- (icon, quality-colored name, "to <winner> · <date>") and the shared
-- warning box.
--------------------------------------------------------------------------

local function ensurePinPopup()
    if (pinPopup) then return; end

    local p = RootSizes.award.popup;
    pinPopup = Skin.ConfirmPopup(frame, {
        width = p.width, padding = p.padding, titleHeight = p.titleHeight, sectionGap = p.sectionGap,
        buttonHeight = p.buttonHeight, buttonGap = p.buttonGap, buttonWidth = p.buttonWidth,
        shadowInset = p.shadowInset, scrimTopInset = Sizes.titleBarHeight,
    });
    local dialog = pinPopup.dialog;
    dialog.title:SetText("Pin this row?");

    dialog.summary = CreateFrame("Frame", nil, dialog, "BackdropTemplate");
    Skin.Backdrop(dialog.summary, Colors.sessionListBg, Colors.memberBorder);
    dialog.summary:SetHeight(p.summaryIconSize + p.summaryPadding * 2);

    dialog.summaryIcon = dialog.summary:CreateTexture(nil, "ARTWORK");
    dialog.summaryIcon:SetSize(p.summaryIconSize, p.summaryIconSize);
    dialog.summaryIcon:SetPoint("LEFT", dialog.summary, "LEFT", p.summaryPadding, 0);
    dialog.summaryIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92);
    dialog.summaryIconBorder = CreateFrame("Frame", nil, dialog.summary, "BackdropTemplate");
    dialog.summaryIconBorder:SetPoint("TOPLEFT", dialog.summaryIcon, "TOPLEFT", -1, 1);
    dialog.summaryIconBorder:SetPoint("BOTTOMRIGHT", dialog.summaryIcon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(dialog.summaryIconBorder, nil, Colors.transparent, 1);

    local textWidth = p.width - p.padding * 2 - p.summaryPadding * 2 - p.summaryIconSize - p.summaryIconGap;
    dialog.summaryItemName = dialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.summaryItemName, "body");
    dialog.summaryItemName:SetPoint("TOPLEFT", dialog.summaryIcon, "TOPRIGHT", p.summaryIconGap, 0);
    dialog.summaryItemName:SetWidth(textWidth);
    dialog.summaryItemName:SetJustifyH("LEFT");
    dialog.summaryItemName:SetWordWrap(false);

    dialog.summaryToLine = dialog.summary:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.summaryToLine, "small");
    dialog.summaryToLine:SetPoint("TOPLEFT", dialog.summaryItemName, "BOTTOMLEFT", 0, -p.summaryLineGap);
    dialog.summaryToLine:SetWidth(textWidth);
    dialog.summaryToLine:SetJustifyH("LEFT");
    dialog.summaryToLine:SetWordWrap(false);

    dialog.warningBox = CreateFrame("Frame", nil, dialog, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(dialog.warningBox, Colors.awardWarningBg, Colors.awardWarningBorder, 1);
    dialog.warningIcon = dialog.warningBox:CreateTexture(nil, "ARTWORK");
    dialog.warningIcon:SetSize(p.warningIconSize, p.warningIconSize);
    dialog.warningIcon:SetPoint("LEFT", dialog.warningBox, "LEFT", p.warningPadding, 0);
    dialog.warningIcon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew");
    dialog.warningIcon:SetVertexColor(unpack(Colors.awardWarningIcon));
    dialog.warningText = dialog.warningBox:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.warningText, "small");
    dialog.warningText:SetTextColor(unpack(Colors.awardWarningText));
    dialog.warningText:SetPoint("TOPLEFT", dialog.warningBox, "TOPLEFT", p.warningPadding + p.warningIconSize + 8, -p.warningPadding);
    dialog.warningText:SetWidth(p.width - p.padding * 2 - (p.warningPadding + p.warningIconSize + 8) - p.warningPadding);
    dialog.warningText:SetJustifyH("LEFT");
    dialog.warningText:SetWordWrap(true);
    dialog.warningText:SetText("This cannot be undone. A pinned row is kept forever, is never pruned, and the pin is shared with the whole guild.");

    pinPopup:SetButtons("Cancel", "Pin", function()
        local entry = pinPopupEntry;
        pinPopupEntry = nil;
        if (entry) then doPin(entry); end
    end, function() pinPopupEntry = nil; end);
end

function pinEntry(entry)
    if (not entry) then return; end
    ensurePinPopup();
    pinPopupEntry = entry;

    local p = RootSizes.award.popup;
    local dialog = pinPopup.dialog;

    dialog.summaryIcon:SetTexture(entry.itemIcon or Util.GetItemIcon(entry.itemID) or FALLBACK_ICON);
    local qr, qg, qb = Util.GetItemQualityColor(Util.GetItemQuality(entry.itemLink or entry.itemID));
    qr, qg, qb = qr or 0.6, qg or 0.6, qb or 0.6;
    dialog.summaryIconBorder:SetBackdropBorderColor(qr, qg, qb);
    local itemName = entry.itemLink and Util.GetItemInfo(entry.itemLink);
    dialog.summaryItemName:SetTextColor(qr, qg, qb);
    dialog.summaryItemName:SetText("[" .. (itemName or "?") .. "]");

    local r, g, b = classColorRGB(entry.awardedToClass);
    dialog.summaryToLine:SetTextColor(unpack(Colors.description));
    dialog.summaryToLine:SetText(("to |cff%02x%02x%02x%s|r \194\183 %s"):format(
        math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), entry.awardedTo or "?",
        entry.awardedAt and date("%m/%d/%Y", entry.awardedAt) or "?"));

    pinPopup:Show(function(d, y)
        dialog.summary:ClearAllPoints();
        dialog.summary:SetPoint("TOPLEFT", d, "TOPLEFT", p.padding, y);
        dialog.summary:SetPoint("TOPRIGHT", d, "TOPRIGHT", -p.padding, y);
        y = y - dialog.summary:GetHeight() - p.sectionGap;

        dialog.warningBox:ClearAllPoints();
        dialog.warningBox:SetPoint("TOPLEFT", d, "TOPLEFT", p.padding, y);
        dialog.warningBox:SetPoint("TOPRIGHT", d, "TOPRIGHT", -p.padding, y);
        local textHeight = dialog.warningText:GetStringHeight();
        dialog.warningBox:SetHeight(math.max(p.warningIconSize, textHeight) + p.warningPadding * 2);
        y = y - dialog.warningBox:GetHeight() - p.sectionGap;
        return y;
    end);
end

--------------------------------------------------------------------------
-- Add Entry modal. See §7.
--------------------------------------------------------------------------

local function parseItemIDFromText(text)
    local id = tonumber(text:match("item:(%d+)"));
    if (id) then return id; end
    if (text:match("^%d+$")) then return tonumber(text); end
    return nil;
end

local function parseDate(text)
    local m, d, y = (text or ""):match("^(%d%d?)/(%d%d?)/(%d%d%d%d)$");
    if (not m) then return nil; end
    m, d, y = tonumber(m), tonumber(d), tonumber(y);
    if (m < 1 or m > 12 or d < 1 or d > 31) then return nil; end
    return y, m, d;
end

local function parseTime(text)
    local h, mi, ap = (text or ""):match("^(%d%d?):(%d%d)%s*([AaPp][Mm])$");
    if (not h) then return nil; end
    h, mi = tonumber(h), tonumber(mi);
    if (h < 1 or h > 12 or mi < 0 or mi > 59) then return nil; end
    ap = ap:upper();
    local h24 = h % 12;
    if (ap == "PM") then h24 = h24 + 12; end
    return h24, mi;
end

local function buildClassOptions()
    local options = { { value = nil, label = "Unknown" } };
    if (CLASS_SORT_ORDER) then
        for _, token in ipairs(CLASS_SORT_ORDER) do
            local label = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token;
            table.insert(options, { value = token, label = label });
        end
    end
    return options;
end

--- Response dropdown options, each carrying the FULL {label, color(hex),
--- kind} snapshot as its value (not just an id) - the value IS the shape
--- history stores, so selecting one needs no further lookup at save time.
--- Built once (settings response list rarely changes mid-session).
local function buildResponseOptions()
    local options = { { value = "none", label = "No response", color = { Colors.disabledText[1], Colors.disabledText[2], Colors.disabledText[3] } } };
    for _, entry in ipairs(Responses.SessionSnapshot()) do
        if (entry.kind ~= "pass") then
            table.insert(options, {
                value = { label = entry.label, color = entry.color, kind = entry.kind },
                label = entry.label,
                color = { Util.HexToRGB(entry.color) },
            });
        end
    end
    return options;
end

local function createNameSuggestList(editBox, onPick)
    local listFrame = CreateFrame("Frame", "ForeverLootHistorySuggestList", UIParent, "BackdropTemplate");
    listFrame:SetFrameStrata("FULLSCREEN_DIALOG");
    -- UIParent child, so match the History window's scale explicitly.
    FL.Pixel.ScaleWithWindows(listFrame);
    Skin.Backdrop(listFrame, Colors.sidebarBg, Colors.border);
    listFrame:Hide();
    tinsert(UISpecialFrames, "ForeverLootHistorySuggestList");

    local rows = {};
    local shownNames = {};
    local highlightIndex;
    local pickInProgress = false;

    local function repaintHighlight()
        for i, row in ipairs(rows) do row.highlightTex:SetShown(i == highlightIndex); end
    end

    local function close()
        listFrame:Hide();
        highlightIndex = nil;
    end

    local function ensureRow(i)
        if (rows[i]) then return rows[i]; end
        local row = CreateFrame("Button", nil, listFrame);
        row:SetHeight(Sizes.popup.suggestionRowHeight);
        row:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 0, -(i - 1) * Sizes.popup.suggestionRowHeight);
        row:SetPoint("RIGHT", listFrame, "RIGHT", 0, 0);

        row.highlightTex = row:CreateTexture(nil, "BACKGROUND");
        row.highlightTex:SetAllPoints();
        row.highlightTex:SetColorTexture(unpack(Colors.selectedFill));
        row.highlightTex:Hide();

        row.text = row:CreateFontString(nil, "OVERLAY");
        SetFont(row.text, "body");
        row.text:SetPoint("LEFT", row, "LEFT", 6, 0);
        row.text:SetJustifyH("LEFT");

        row:SetScript("OnClick", function()
            if (row.name) then
                pickInProgress = true;
                onPick(row.name);
                C_Timer.After(0, function() pickInProgress = false; end);
            end
        end);
        row:SetScript("OnEnter", function() highlightIndex = i; repaintHighlight(); end);

        rows[i] = row;
        return row;
    end

    local function open(names)
        shownNames = names;
        highlightIndex = #names > 0 and 1 or nil;
        for i = 1, math.max(#names, #rows) do
            local row = ensureRow(i);
            local name = names[i];
            if (name) then
                row.name = name;
                local r, g, b = classColorRGB(indexByPlayer[name] and indexByPlayer[name].class);
                row.text:SetTextColor(r, g, b);
                row.text:SetText(name);
                row:Show();
            else
                row.name = nil;
                row:Hide();
            end
        end
        listFrame:SetHeight(math.max(#names, 1) * Sizes.popup.suggestionRowHeight);
        listFrame:SetWidth(editBox:GetWidth());
        listFrame:ClearAllPoints();
        listFrame:SetPoint("TOPLEFT", editBox, "BOTTOMLEFT", 0, -2);
        listFrame:Show();
        repaintHighlight();
    end

    local function refilter()
        if (pickInProgress) then return; end
        local query = Util.Trim(editBox:GetText() or ""):lower();
        if (query == "") then close(); return; end
        local starts, contains = {}, {};
        for _, name in ipairs(playerNamesSorted) do
            local lower = name:lower();
            if (lower:find(query, 1, true) == 1) then
                table.insert(starts, name);
            elseif (lower:find(query, 1, true)) then
                table.insert(contains, name);
            end
        end
        local names = {};
        for _, n in ipairs(starts) do if (#names < 6) then table.insert(names, n); end end
        for _, n in ipairs(contains) do if (#names < 6) then table.insert(names, n); end end
        if (#names == 0) then close(); return; end
        open(names);
    end

    editBox:HookScript("OnTextChanged", function() refilter(); end);
    editBox:HookScript("OnEnterPressed", function()
        if (listFrame:IsShown() and highlightIndex and shownNames[highlightIndex]) then
            pickInProgress = true;
            onPick(shownNames[highlightIndex]);
            C_Timer.After(0, function() pickInProgress = false; end);
        end
    end);
    editBox:HookScript("OnEscapePressed", function() if (listFrame:IsShown()) then close(); end end);
    editBox:HookScript("OnEditFocusLost", function()
        if (not listFrame:IsMouseOver()) then close(); end
    end);
    editBox:HookScript("OnKeyDown", function(_, key)
        if (not listFrame:IsShown()) then return; end
        if (key == "DOWN") then
            highlightIndex = math.min((highlightIndex or 0) + 1, #shownNames);
            repaintHighlight();
        elseif (key == "UP") then
            highlightIndex = math.max((highlightIndex or 1) - 1, 1);
            repaintHighlight();
        end
    end);

    return { close = close };
end

local function paintItemPreview()
    local dialog = addEntryPopup.dialog;
    local state = addEntryState;
    if (state.loadingItemID) then
        dialog.itemPreview:Show();
        dialog.itemPreview.icon:Hide();
        dialog.itemPreview.iconBorder:Hide();
        dialog.itemPreview.nameText:ClearAllPoints();
        dialog.itemPreview.nameText:SetPoint("LEFT", dialog.itemPreview, "LEFT", Sizes.popup.previewPad, 0);
        dialog.itemPreview.nameText:SetTextColor(unpack(Colors.muted));
        dialog.itemPreview.nameText:SetText("Loading\226\128\166");
    elseif (state.resolvedItem) then
        dialog.itemPreview:Show();
        dialog.itemPreview.icon:Show();
        dialog.itemPreview.iconBorder:Show();
        dialog.itemPreview.icon:SetTexture(state.resolvedItem.itemIcon or FALLBACK_ICON);
        local qr, qg, qb = Util.GetItemQualityColor(state.resolvedItem.quality);
        qr, qg, qb = qr or 0.6, qg or 0.6, qb or 0.6;
        dialog.itemPreview.iconBorder:SetBackdropBorderColor(qr, qg, qb);
        dialog.itemPreview.nameText:ClearAllPoints();
        dialog.itemPreview.nameText:SetPoint("LEFT", dialog.itemPreview.icon, "RIGHT", Sizes.popup.previewPad, 0);
        dialog.itemPreview.nameText:SetTextColor(qr, qg, qb);
        dialog.itemPreview.nameText:SetText("[" .. (state.resolvedItem.name or "?") .. "]");
    else
        dialog.itemPreview:Hide();
    end
end

local function tryResolveItem(itemID)
    local dialog = addEntryPopup.dialog;
    if (not itemID or not C_Item.DoesItemExistByID(itemID)) then
        addEntryState.resolvedItem = nil;
        addEntryState.loadingItemID = nil;
        paintItemPreview();
        return;
    end

    addEntryState.loadingItemID = itemID;
    addEntryState.resolvedItem = nil;
    paintItemPreview();

    Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
        if (addEntryState.loadingItemID ~= itemID) then return; end -- superseded by a later edit
        local name, link, quality, _, _, _, _, _, _, icon = Util.GetItemInfo(itemID);
        addEntryState.loadingItemID = nil;
        addEntryState.resolvedItem = {
            itemID = itemID, itemLink = link, itemIcon = icon or Util.GetItemIcon(itemID),
            name = name or ("Item " .. itemID), quality = quality,
        };
        dialog.itemBox.zlHasError = false;
        dialog.itemBox:SetDashColor(unpack(Colors.lhDashedBorder));
        paintItemPreview();
    end);
end

local function makeValidatedField(fieldBox)
    fieldBox:HookScript("OnEditFocusGained", function(self)
        if (self.zlHasError) then self:SetBackdropBorderColor(unpack(Colors.lhErrorBorder)); end
    end);
    fieldBox:HookScript("OnTextChanged", function(self)
        if (self.zlHasError) then
            self.zlHasError = false;
            self:SetBackdropBorderColor(unpack(self:HasFocus() and Colors.controlFocus or Colors.controlBorder));
        end
    end);
    -- Plain EditBox doesn't blur itself on Escape by default (unlike an
    -- EditBox built off a template with its own OnEscapePressed) - mirrors
    -- dialog.itemBox's own explicit handler below.
    fieldBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);
    return fieldBox;
end

local function ensureAddEntryPopup()
    if (addEntryPopup) then return; end

    local p = Sizes.popup;
    addEntryPopup = Skin.ConfirmPopup(frame, {
        width = p.width, padding = p.padding, sectionGap = p.sectionGap, titleHeight = p.titleHeight,
        buttonHeight = p.buttonHeight, buttonGap = p.buttonGap, buttonWidth = p.buttonWidth,
        shadowInset = p.shadowInset, scrimTopInset = Sizes.titleBarHeight,
    });
    local dialog = addEntryPopup.dialog;
    dialog.title:SetText("Add History Entry");

    local function fieldLabel(text)
        local fs = dialog:CreateFontString(nil, "OVERLAY");
        SetFont(fs, "helper");
        fs:SetTextColor(unpack(Colors.muted));
        fs:SetText(text:upper());
        fs:SetJustifyH("LEFT");
        return fs;
    end

    ------------------------------------------------------------------
    -- Item field - dashed border + manual placeholder, same construction
    -- UI/SettingsWindow/ItemListEditor.lua's own addBox uses.
    ------------------------------------------------------------------
    dialog.itemLabel = fieldLabel("Item");
    dialog.itemBox = CreateFrame("EditBox", nil, dialog, "BackdropTemplate");
    dialog.itemBox:SetAutoFocus(false);
    dialog.itemBox:SetHeight(p.inputHeight);
    SetFont(dialog.itemBox, "body");
    dialog.itemBox:SetTextColor(unpack(Colors.textBright));
    dialog.itemBox:SetTextInsets(6, 6, 0, 0);
    Theme.Helpers.SetFlatBackdrop(dialog.itemBox, Colors.controlBg, Colors.transparent, 1);
    Skin.DashedBorder(dialog.itemBox, Colors.lhDashedBorder[1], Colors.lhDashedBorder[2], Colors.lhDashedBorder[3], 1, 4, 1);
    dialog.itemBox:SetScript("OnEditFocusGained", function(self) self:SetDashColor(unpack(Colors.primaryBorder)); end);
    dialog.itemBox:SetScript("OnEditFocusLost", function(self)
        self:SetDashColor(unpack(self.zlHasError and Colors.lhErrorBorder or Colors.lhDashedBorder));
    end);

    dialog.itemBox.placeholder = dialog.itemBox:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.itemBox.placeholder, "body");
    dialog.itemBox.placeholder:SetPoint("LEFT", dialog.itemBox, "LEFT", 8, 0);
    dialog.itemBox.placeholder:SetPoint("RIGHT", dialog.itemBox, "RIGHT", -6, 0);
    dialog.itemBox.placeholder:SetJustifyH("LEFT");
    dialog.itemBox.placeholder:SetWordWrap(false);
    dialog.itemBox.placeholder:SetText("Shift-click or drag an item here, or type an item ID");
    dialog.itemBox.placeholder:SetTextColor(unpack(Colors.controlHover));

    local function tryResolveFromText(text)
        tryResolveItem(parseItemIDFromText(text));
    end
    dialog.itemBox:HookScript("OnTextChanged", function(self)
        dialog.itemBox.placeholder:SetShown(self:GetText() == "");
        if (self.zlHasError) then self.zlHasError = false; self:SetDashColor(unpack(Colors.lhDashedBorder)); end
    end);
    dialog.itemBox:SetScript("OnEnterPressed", function(self) tryResolveFromText(self:GetText()); end);
    dialog.itemBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);
    local function handleCursorDrop()
        local cursorType, itemID = GetCursorInfo();
        if (cursorType ~= "item") then return; end
        ClearCursor();
        dialog.itemBox:SetText(tostring(itemID));
        tryResolveItem(itemID);
    end
    dialog.itemBox:SetScript("OnReceiveDrag", handleCursorDrop);
    dialog.itemBox:SetScript("OnMouseUp", handleCursorDrop);

    -- Shift-click capture - only while this box has focus, mirroring
    -- ItemListEditor.lua's own hook exactly (module-level, one-time; harmless
    -- to stack alongside that file's own identical hook).
    hooksecurefunc("HandleModifiedItemClick", function(itemLink)
        if (not itemLink or not IsShiftKeyDown()) then return; end
        if (not addEntryPopup or not addEntryPopup.shown) then return; end
        if (not dialog.itemBox:HasFocus()) then return; end
        if (ChatEdit_GetActiveWindow() ~= nil) then return; end
        dialog.itemBox:SetText(itemLink);
        dialog.itemBox:HighlightText();
        tryResolveFromText(itemLink);
    end);

    dialog.itemPreview = CreateFrame("Frame", nil, dialog, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(dialog.itemPreview, Colors.lhPreviewBg, Colors.lhPreviewBorder, 1);
    dialog.itemPreview:SetHeight(p.previewIconSize + p.previewPad * 2);
    dialog.itemPreview.icon = dialog.itemPreview:CreateTexture(nil, "ARTWORK");
    dialog.itemPreview.icon:SetSize(p.previewIconSize, p.previewIconSize);
    dialog.itemPreview.icon:SetPoint("LEFT", dialog.itemPreview, "LEFT", p.previewPad, 0);
    dialog.itemPreview.iconBorder = CreateFrame("Frame", nil, dialog.itemPreview, "BackdropTemplate");
    dialog.itemPreview.iconBorder:SetPoint("TOPLEFT", dialog.itemPreview.icon, "TOPLEFT", -1, 1);
    dialog.itemPreview.iconBorder:SetPoint("BOTTOMRIGHT", dialog.itemPreview.icon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(dialog.itemPreview.iconBorder, nil, Colors.transparent, p.previewIconBorder);
    dialog.itemPreview.nameText = dialog.itemPreview:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.itemPreview.nameText, "body");
    dialog.itemPreview.nameText:SetJustifyH("LEFT");
    dialog.itemPreview:Hide();

    ------------------------------------------------------------------
    -- Awarded To + Class row
    ------------------------------------------------------------------
    dialog.nameLabel = fieldLabel("Awarded To");
    dialog.classLabel = fieldLabel("Class");

    dialog.nameBox = CreateFrame("EditBox", nil, dialog, "BackdropTemplate");
    dialog.nameBox:SetAutoFocus(false);
    dialog.nameBox:SetHeight(p.inputHeight);
    Skin.EditBox(dialog.nameBox);
    makeValidatedField(dialog.nameBox);

    dialog.classDropdown = Skin.Dropdown(dialog, {
        width = p.classWidth,
        height = p.inputHeight,
        xOffset = p.dropdownXOffset,
        options = buildClassOptions(),
        getValue = function() return addEntryState.selectedClass; end,
        onSelect = function(value) addEntryState.selectedClass = value; end,
    });

    dialog.nameSuggestList = createNameSuggestList(dialog.nameBox, function(name)
        dialog.nameBox:SetText(name);
        addEntryState.selectedClass = (indexByPlayer[name] or {}).class;
        dialog.classDropdown.Refresh();
        dialog.nameSuggestList.close();
    end);

    ------------------------------------------------------------------
    -- Response + Date + Time row
    ------------------------------------------------------------------
    dialog.responseLabel = fieldLabel("Response");
    dialog.dateLabel = fieldLabel("Date");
    dialog.timeLabelText = fieldLabel("Time");

    dialog.responseDropdown = Skin.Dropdown(dialog, {
        width = p.width - p.padding * 2 - p.dateWidth - p.timeWidth - p.rowGap * 2,
        height = p.inputHeight,
        xOffset = p.dropdownXOffset,
        hasColorDot = true,
        options = buildResponseOptions(),
        getValue = function() return addEntryState.selectedResponseValue or "none"; end,
        onSelect = function(value) addEntryState.selectedResponseValue = value; end,
    });

    dialog.dateBox = CreateFrame("EditBox", nil, dialog, "BackdropTemplate");
    dialog.dateBox:SetAutoFocus(false);
    dialog.dateBox:SetHeight(p.inputHeight);
    Skin.EditBox(dialog.dateBox);
    dialog.dateBox:SetTextInsets(4, 4, 0, 0);
    makeValidatedField(dialog.dateBox);

    dialog.timeBox = CreateFrame("EditBox", nil, dialog, "BackdropTemplate");
    dialog.timeBox:SetAutoFocus(false);
    dialog.timeBox:SetHeight(p.inputHeight);
    Skin.EditBox(dialog.timeBox);
    makeValidatedField(dialog.timeBox);

    ------------------------------------------------------------------
    -- Note
    ------------------------------------------------------------------
    dialog.noteLabel = fieldLabel("Note");
    dialog.noteBox = CreateFrame("EditBox", nil, dialog, "BackdropTemplate");
    dialog.noteBox:SetAutoFocus(false);
    dialog.noteBox:SetHeight(p.inputHeight);
    dialog.noteBox:SetMaxLetters(p.noteMaxLetters);
    Skin.EditBox(dialog.noteBox);
    dialog.noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);

    dialog.noteBox.placeholder = dialog.noteBox:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.noteBox.placeholder, "search");
    dialog.noteBox.placeholder:SetPoint("LEFT", dialog.noteBox, "LEFT", 12, 0);
    dialog.noteBox.placeholder:SetJustifyH("LEFT");
    dialog.noteBox.placeholder:SetText("e.g. traded after the raid");
    dialog.noteBox.placeholder:SetTextColor(unpack(Colors.controlHover));
    dialog.noteBox:HookScript("OnTextChanged", function(self)
        dialog.noteBox.placeholder:SetShown(self:GetText() == "");
    end);

    ------------------------------------------------------------------
    -- Error line + footer note
    ------------------------------------------------------------------
    dialog.errorText = dialog:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.errorText, "small");
    dialog.errorText:SetTextColor(unpack(Colors.lhErrorText));
    dialog.errorText:SetJustifyH("LEFT");
    dialog.errorText:SetWordWrap(true);
    dialog.errorText:Hide();

    -- Closing the suggestion list whenever the dialog itself closes (Cancel/
    -- Escape/scrim-click, not just picking a name) - wrapped once here, not
    -- per-open, so repeated opens don't stack wrapper closures.
    local baseHide = addEntryPopup.Hide;
    addEntryPopup.Hide = function(self)
        if (dialog.nameSuggestList) then dialog.nameSuggestList.close(); end
        baseHide(self);
    end;
end

local function layoutAddEntryDialog(popupDialog, y)
    local p = Sizes.popup;
    local labelGap = p.fieldLabelGap;
    local rowGap = p.rowGap;

    popupDialog.itemLabel:ClearAllPoints();
    popupDialog.itemLabel:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y);
    y = y - popupDialog.itemLabel:GetStringHeight() - labelGap;

    popupDialog.itemBox:ClearAllPoints();
    popupDialog.itemBox:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y);
    popupDialog.itemBox:SetPoint("TOPRIGHT", popupDialog, "TOPRIGHT", -p.padding, y);
    y = y - p.inputHeight;

    if (popupDialog.itemPreview:IsShown()) then
        popupDialog.itemPreview:ClearAllPoints();
        popupDialog.itemPreview:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y - 4);
        popupDialog.itemPreview:SetPoint("TOPRIGHT", popupDialog, "TOPRIGHT", -p.padding, y - 4);
        y = y - 4 - popupDialog.itemPreview:GetHeight();
    end
    y = y - p.sectionGap;

    local fieldWidth = p.width - p.padding * 2;
    local nameWidth = fieldWidth - p.classWidth - rowGap;

    popupDialog.nameLabel:ClearAllPoints();
    popupDialog.nameLabel:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y);
    popupDialog.classLabel:ClearAllPoints();
    popupDialog.classLabel:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding + nameWidth + rowGap, y);
    y = y - popupDialog.nameLabel:GetStringHeight() - labelGap;

    popupDialog.nameBox:ClearAllPoints();
    popupDialog.nameBox:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y);
    popupDialog.nameBox:SetWidth(nameWidth);
    popupDialog.classDropdown.button:ClearAllPoints();
    popupDialog.classDropdown.button:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding + nameWidth + rowGap, y);
    y = y - p.inputHeight - p.sectionGap;

    popupDialog.responseLabel:ClearAllPoints();
    popupDialog.responseLabel:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y);
    local dateX = p.padding + (fieldWidth - p.dateWidth - p.timeWidth - rowGap);
    popupDialog.dateLabel:ClearAllPoints();
    popupDialog.dateLabel:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", dateX, y);
    popupDialog.timeLabelText:ClearAllPoints();
    popupDialog.timeLabelText:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", dateX + p.dateWidth + rowGap, y);
    y = y - popupDialog.responseLabel:GetStringHeight() - labelGap;

    popupDialog.responseDropdown.button:ClearAllPoints();
    popupDialog.responseDropdown.button:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y);
    popupDialog.dateBox:ClearAllPoints();
    popupDialog.dateBox:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", dateX, y);
    popupDialog.dateBox:SetWidth(p.dateWidth);
    popupDialog.timeBox:ClearAllPoints();
    popupDialog.timeBox:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", dateX + p.dateWidth + rowGap, y);
    popupDialog.timeBox:SetWidth(p.timeWidth);
    y = y - p.inputHeight - p.sectionGap;

    popupDialog.noteLabel:ClearAllPoints();
    popupDialog.noteLabel:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y);
    y = y - popupDialog.noteLabel:GetStringHeight() - labelGap;

    popupDialog.noteBox:ClearAllPoints();
    popupDialog.noteBox:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y);
    popupDialog.noteBox:SetPoint("TOPRIGHT", popupDialog, "TOPRIGHT", -p.padding, y);
    y = y - p.inputHeight - p.sectionGap;

    if (popupDialog.errorText:IsShown()) then
        popupDialog.errorText:ClearAllPoints();
        popupDialog.errorText:SetPoint("TOPLEFT", popupDialog, "TOPLEFT", p.padding, y);
        popupDialog.errorText:SetPoint("TOPRIGHT", popupDialog, "TOPRIGHT", -p.padding, y);
        y = y - popupDialog.errorText:GetStringHeight() - p.sectionGap;
    end

    return y;
end

--- ConfirmPopup hides itself before invoking the confirm callback (so a
--- callback that opens another window never fights this popup's own Hide) -
--- which means by the time validation runs here the dialog is already
--- hidden. Re-show it so the error is actually visible instead of the popup
--- just silently closing on an invalid field.
local function flagFieldError(fieldBox, message, isDashed)
    local dialog = addEntryPopup.dialog;
    dialog.errorText:SetText(message);
    dialog.errorText:Show();
    fieldBox.zlHasError = true;
    if (isDashed) then
        fieldBox:SetDashColor(unpack(Colors.lhErrorBorder));
    else
        fieldBox:SetBackdropBorderColor(unpack(Colors.lhErrorBorder));
    end
    if (not addEntryPopup.shown) then
        addEntryPopup:Show(layoutAddEntryDialog);
    end
    fieldBox:SetFocus();
end

local function confirmAddEntry()
    local dialog = addEntryPopup.dialog;
    dialog.errorText:Hide();

    if (not addEntryState.resolvedItem) then
        flagFieldError(dialog.itemBox, "Add an item: Shift-click it, drag it in, or type its item ID.", true);
        return;
    end

    local name = Util.Trim(dialog.nameBox:GetText() or "");
    if (name == "") then
        flagFieldError(dialog.nameBox, "Enter who the item was awarded to.");
        return;
    end

    local y, m, d = parseDate(dialog.dateBox:GetText());
    if (not y) then
        flagFieldError(dialog.dateBox, "Date must look like 09/29/2026.");
        return;
    end

    local h24, mi = parseTime(dialog.timeBox:GetText());
    if (not h24) then
        flagFieldError(dialog.timeBox, "Time must look like 9:30 PM.");
        return;
    end

    local awardedAt = time({ year = y, month = m, day = d, hour = h24, min = mi, sec = 0 });

    local id = ("manual-%d-%d"):format(awardedAt, addEntryState.resolvedItem.itemID);
    if (LootCouncil.History) then
        local suffix = 2;
        local baseId = id;
        while (LootCouncil.HistoryIndex[id]) do
            id = baseId .. "-" .. suffix;
            suffix = suffix + 1;
        end
    end

    local responseValue = addEntryState.selectedResponseValue;
    local response = (responseValue ~= nil and responseValue ~= "none") and responseValue or nil;
    local note = Util.Trim(dialog.noteBox:GetText() or "");
    if (note == "") then note = nil; end

    local entry = {
        id = id,
        itemLink = addEntryState.resolvedItem.itemLink, itemID = addEntryState.resolvedItem.itemID,
        itemIcon = addEntryState.resolvedItem.itemIcon,
        awardedTo = name, awardedToClass = addEntryState.selectedClass,
        awardedBy = Util.stripRealm(Util.UnitName("player")), awardedAt = awardedAt,
        sessionId = 0, itemSession = 0, responses = {},
        manual = true, response = response, note = note,
    };
    -- Routed through Store like every other write (see LootCouncil.RecordHistory's
    -- own comment). Unlike Phase 1, this now DOES broadcast (LIVE_ROW, to
    -- the whole guild) since source is "local" here - this row only exists
    -- on this client, so Live.Award is the only thing that will ever tell
    -- anyone else about it.
    FL.Sync.Live.Award(entry, "local");

    addEntryPopup:Hide();
    rebuildIndexes();
    dateColumn.refresh();
    playersColumn.refresh();
    itemsColumn.refresh();

    applyFilter({ date = dayKey(entry.awardedAt) });
    expandedEntryId = entry.id;
    local expandedRow = layoutResultRows(currentResults);
    if (expandedRow) then
        local viewHeight = resultsScroll:GetHeight();
        resultsScroll:SetVerticalScroll(math.max(expandedRow.bottomY - viewHeight, 0));
    end

    local itemName = entry.itemLink and Util.GetItemInfo(entry.itemLink) or "Item";
    local coloredItemName = Util.qualityColoredItemName("[" .. itemName .. "]", Util.GetItemQuality(entry.itemLink or entry.itemID));
    local coloredName = Util.classColoredName(name, entry.awardedToClass);
    confirmationLine:SetText(("Added %s to %s."):format(coloredItemName, coloredName));
    confirmationLine:Show();
    C_Timer.After(Sizes.filterBar.confirmDuration, function()
        if (confirmationLine) then confirmationLine:Hide(); end
    end);
end

function showAddEntryPopup()
    addEntryState = { resolvedItem = nil, loadingItemID = nil, selectedClass = nil, selectedResponseValue = "none" };
    ensureAddEntryPopup();
    local dialog = addEntryPopup.dialog;

    dialog.itemBox:SetText("");
    dialog.itemBox.zlHasError = false;
    dialog.itemBox:SetDashColor(unpack(Colors.lhDashedBorder));
    dialog.nameBox:SetText("");
    dialog.nameBox.zlHasError = false;
    dialog.dateBox.zlHasError = false;
    dialog.timeBox.zlHasError = false;
    dialog.noteBox:SetText("");
    dialog.errorText:Hide();
    paintItemPreview();

    if (currentFilter and currentFilter.player) then
        dialog.nameBox:SetText(currentFilter.player);
        addEntryState.selectedClass = (indexByPlayer[currentFilter.player] or {}).class;
    elseif (currentFilter and currentFilter.item) then
        dialog.itemBox:SetText(tostring(currentFilter.item));
        tryResolveItem(currentFilter.item);
    end

    local defaultTimestamp = GetServerTime();
    if (currentFilter and currentFilter.date) then
        local bucket = indexByDay[currentFilter.date];
        if (bucket and bucket.entries[1]) then defaultTimestamp = bucket.entries[1].awardedAt; end
    end
    dialog.dateBox:SetText(date("%m/%d/%Y", defaultTimestamp));
    dialog.timeBox:SetText(timeLabel(GetServerTime()));

    dialog.classDropdown.Refresh();
    dialog.responseDropdown.Refresh();

    addEntryPopup:SetButtons("Cancel", "Add Entry", confirmAddEntry, function() end);

    addEntryPopup:Show(layoutAddEntryDialog);
end

--------------------------------------------------------------------------
-- Window lifecycle
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
    title:SetText(WINDOW_TITLE);
    windowTitle = title;
    titleBarFrame = titleBar; -- the guild picker's parent (paintViewControls)
    title:SetTextColor(unpack(Colors.titlePurple));

    local divider = titleBar:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 2, 0);
    divider:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -2, 0);
    Pixel.SetLineHeight(divider, 1);

    local closeButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    closeButton:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -8, -8);
    Skin.CloseButton(closeButton);
    closeButton:SetScript("OnClick", function()
        FL.NotifyWindowClosed("LootHistory");
        frame:Hide();
    end);

    lockButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    lockButton:SetSize(RootSizes.controls.close, RootSizes.controls.close);
    lockButton:SetPoint("RIGHT", closeButton, "LEFT", -6, 0);

    lockButton.icon = lockButton:CreateTexture(nil, "ARTWORK");
    lockButton.icon:SetSize(RootSizes.controls.closeIcon, RootSizes.controls.closeIcon);
    lockButton.icon:SetPoint("CENTER");
    lockButton.icon:SetTexture(LOCK_ICON_TEXTURE);

    lockButton:HookScript("OnEnter", function()
        if (not deleteModeActive) then
            Theme.Helpers.SetFlatBackdrop(lockButton, Colors.hoverBg, Colors.controlHover, 1);
            lockButton.icon:SetVertexColor(unpack(Colors.controlHover));
        end
        GameTooltip:SetOwner(lockButton, "ANCHOR_LEFT");
        GameTooltip:AddLine(deleteModeActive and "Lock: stop deleting history rows" or "Unlock to delete history rows");
        GameTooltip:Show();
    end);
    lockButton:HookScript("OnLeave", function()
        paintLockButton();
        GameTooltip:Hide();
    end);
    lockButton:SetScript("OnClick", function() setDeleteMode(not deleteModeActive); end);

    paintLockButton();

    return titleBar;
end

function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootHistoryWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    -- Item names/icons/quality for the sidebar and result rows are read
    -- straight from the client cache at rebuildIndexes() time - if an item
    -- isn't cached yet (e.g. right after login, before the server's async
    -- answer lands), that read falls back to "Item <id>" and nothing
    -- repaints it once the real data arrives. Mirrors TradeQueueWindow.lua's
    -- GET_ITEM_INFO_RECEIVED handling: only listen while actually open.
    -- Debounced (see itemInfoRefreshPending above) since a cold cache can
    -- answer many items in a single burst right after opening.
    frame:SetScript("OnEvent", function()
        if (itemInfoRefreshPending) then return; end
        itemInfoRefreshPending = true;
        C_Timer.After(ITEM_INFO_REFRESH_DEBOUNCE, function()
            itemInfoRefreshPending = false;
            LootHistoryWindow.Refresh();
        end);
    end);
    frame:SetScript("OnShow", function() frame:RegisterEvent("GET_ITEM_INFO_RECEIVED"); end);
    frame:SetScript("OnHide", function() frame:UnregisterEvent("GET_ITEM_INFO_RECEIVED"); end);

    Pixel.RegisterWindow(frame, {
        width = WINDOW_WIDTH, height = WINDOW_HEIGHT,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    -- NOTE: deliberately NOT added to UISpecialFrames - Escape never closes
    -- this window, matching TradeQueueWindow/RespondWindow/SoftResImportWindow.

    createTitleBar();

    -- Inset 1px (the window border's own thickness) on left/bottom/right so
    -- the filter columns' solid sidebarBg fill and the filter bar's
    -- lhFilterBarBg fill don't paint over frame's border there - same
    -- borderInset convention AwardWindow's itemPanel uses. Top is untouched:
    -- body starts below the title bar, which has no fill.
    body = CreateFrame("Frame", nil, frame);
    Pixel.SetBorderInsetPoint(body, "TOPLEFT", frame, "TOPLEFT", 1, 0, 0, -Sizes.titleBarHeight);
    Pixel.SetBorderInsetPoint(body, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1);

    dateColumn = buildFilterColumn(body, {
        title = "Date", filterType = "date", hasSearch = false,
        getSortedKeys = function() return dayKeysSorted; end,
        getBucket = function(key) return indexByDay[key]; end,
        paintRow = paintDateRow,
    });
    dateColumn.frame:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0);
    dateColumn.frame:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0);
    dateColumn.frame:SetWidth(Sizes.column.date);

    playersColumn = buildFilterColumn(body, {
        title = "Players", filterType = "player", hasSearch = true, searchPlaceholder = "Search players\226\128\166",
        getSortedKeys = function() return playerNamesSorted; end,
        getBucket = function(key) return indexByPlayer[key]; end,
        getSearchText = function(key) return key; end,
        paintRow = paintPlayerRow,
    });
    playersColumn.frame:SetPoint("TOPLEFT", dateColumn.frame, "TOPRIGHT", 0, 0);
    playersColumn.frame:SetPoint("BOTTOMLEFT", dateColumn.frame, "BOTTOMRIGHT", 0, 0);
    playersColumn.frame:SetWidth(Sizes.column.players);

    itemsColumn = buildFilterColumn(body, {
        title = "Items", filterType = "item", hasSearch = true, searchPlaceholder = "Search items\226\128\166",
        getSortedKeys = function() return itemIDsSorted; end,
        getBucket = function(key) return indexByItem[key]; end,
        getSearchText = function(key, bucket) return bucket and bucket.name or ""; end,
        paintRow = paintItemRow,
    });
    itemsColumn.frame:SetPoint("TOPLEFT", playersColumn.frame, "TOPRIGHT", 0, 0);
    itemsColumn.frame:SetPoint("BOTTOMLEFT", playersColumn.frame, "BOTTOMRIGHT", 0, 0);
    itemsColumn.frame:SetWidth(Sizes.column.items);

    local resultsColumn = CreateFrame("Frame", nil, body);
    resultsColumn:SetPoint("TOPLEFT", itemsColumn.frame, "TOPRIGHT", 0, 0);
    resultsColumn:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0);

    createFilterBar(resultsColumn);
    filterBar:SetPoint("TOPLEFT", resultsColumn, "TOPLEFT", 0, 0);
    filterBar:SetPoint("TOPRIGHT", resultsColumn, "TOPRIGHT", 0, 0);

    -- Own frame (not just a fontstring directly on resultsColumn) so its
    -- frame level can be pushed above the results scroll frame - a plain
    -- region draws at its parent's level, which sat below the scroll frame
    -- (created after it) and let an expanded row's content cover its text.
    local confirmationOverlay = CreateFrame("Frame", nil, resultsColumn);
    confirmationOverlay:SetAllPoints(resultsColumn);
    confirmationOverlay:SetFrameLevel(resultsColumn:GetFrameLevel() + 50);

    confirmationLine = confirmationOverlay:CreateFontString(nil, "OVERLAY");
    SetFont(confirmationLine, "small");
    confirmationLine:SetTextColor(unpack(Colors.lhConfirmText));
    confirmationLine:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", Sizes.filterBar.confirmLinePadX, 12);
    confirmationLine:SetPoint("TOPRIGHT", filterBar, "BOTTOMRIGHT", -Sizes.filterBar.confirmLinePadX, 12);
    confirmationLine:SetJustifyH("CENTER");

    resultsScroll = CreateFrame("ScrollFrame", "ForeverLootHistoryWindowResultsScroll", resultsColumn, "UIPanelScrollFrameTemplate");
    resultsScroll:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", Sizes.resultList.padTop, -Sizes.resultList.padTop);
    resultsScroll:SetPoint("BOTTOMRIGHT", resultsColumn, "BOTTOMRIGHT", -(RootSizes.layout.scrollbarWidth + 4), Sizes.resultList.padTop);

    resultsScrollChild = CreateFrame("Frame", nil, resultsScroll);
    resultsScrollChild:SetPoint("TOPLEFT", resultsScroll, "TOPLEFT", 0, 0);
    resultsScroll:SetScrollChild(resultsScrollChild);
    resultsScroll:SetScript("OnSizeChanged", function(self, width)
        resultsScrollChild:SetWidth(width);
        if (#currentResults > 0) then renderVisibleRows(false); end
    end);
    resultsScroll:HookScript("OnVerticalScroll", function() renderVisibleRows(false); end);

    local resultsScrollBar = Skin.ScrollBar(resultsScroll);
    if (resultsScrollBar) then
        resultsScrollBar:ClearAllPoints();
        resultsScrollBar:SetPoint("TOP", resultsScroll, "TOP", 0, 0);
        resultsScrollBar:SetPoint("BOTTOM", resultsScroll, "BOTTOM", 0, 0);
        resultsScrollBar:SetPoint("RIGHT", resultsColumn, "RIGHT", -3, 0);
    end
    Theme.Helpers.EnableSmoothScroll(resultsScroll, { step = Sizes.resultRow.collapsedHeight });

    emptyResultsText = resultsColumn:CreateFontString(nil, "OVERLAY");
    SetFont(emptyResultsText, "body");
    emptyResultsText:SetTextColor(unpack(Colors.disabledText));
    emptyResultsText:SetPoint("CENTER", resultsScroll, "CENTER", 0, 0);
    emptyResultsText:SetText("No awards match this filter.");
    emptyResultsText:Hide();
end

function LootHistoryWindow.Show()
    ensureFrame();
    deleteModeActive = false;
    viewKey = nil;
    paintViewControls();
    rebuildIndexes();
    dateColumn.refresh();
    playersColumn.refresh();
    itemsColumn.refresh();

    if (not hasAppliedFilter or not filterStillValid(currentFilter)) then
        applyFilter(nil);
    else
        local results = resolveResults(currentFilter);
        paintFilterBar(currentFilter, results);
        layoutResultRows(results);
    end

    frame:Show();
end

--- Full rebuild-and-repaint: rebuildIndexes() plus the sidebar/results
--- repaint. Correct for any change to LootCouncil.History, but O(n log n) in
--- total history size - reserved for window-open and the rare manual
--- add/delete paths (deleteEntry, the Add Entry popup). The frequent
--- per-award path goes through OnEntryUpserted below instead, which is what
--- this function used to be called for too - see its own comment for why
--- that mattered.
function LootHistoryWindow.Refresh()
    if (not frame or not frame:IsShown()) then return; end
    if (viewKey and not FL.Sync.Buckets.Get(viewKey)) then viewKey = nil; end
    paintViewControls();
    rebuildIndexes();
    dateColumn.refresh();
    playersColumn.refresh();
    itemsColumn.refresh();

    if (not filterStillValid(currentFilter)) then
        applyFilter(nil);
    else
        local results = resolveResults(currentFilter);
        paintFilterBar(currentFilter, results);
        layoutResultRows(results);
    end
end

--- Incremental counterpart to Refresh(), registered below on
--- FL.Sync.Store's "EntryApplied" callback (Data/Store.lua) instead of being
--- called directly from LootCouncil.RecordHistory - every write (a local
--- award, one arriving from another client's broadcast, a manual Add Entry,
--- or an officer's delete) now funnels through Store:Apply, which fires this
--- exactly once per actual change. Updates allEntries/indexByDay/
--- indexByPlayer/indexByItem in O(log n) (insertion/removal in a handful of
--- already-sorted lists) instead of Refresh's O(n log n) full rebuild-and-resort
--- of the entire history - the difference that matters once a guild's history
--- has grown into the hundreds/thousands of rows and an officer keeps this
--- window open through a raid night. Still ends in the same sidebar-refresh +
--- layoutResultRows repaint as Refresh - which now only repaints the rows
--- inside the scroll viewport (the result list is virtualized). No-op unless the
--- window is already open, same as Refresh.
---@param appliedEntry table the entry Store:Apply was given - { kind, id, row, replacedRow } for "R", { kind, id, removedRow } for "D"
---@param source string "local" | "live" | "sync" | "test" (unused here, kept for parity with Debug's apply logging)
---@param result string the fixed outcome word Store:Apply returned (see Data/Store.lua)
local function onEntryApplied(_event, appliedEntry, source, result)
    if (not frame or not frame:IsShown()) then return; end
    -- Live/sync changes are to our own guild's history, not the one being viewed.
    if (viewKey) then return; end

    if (appliedEntry.kind == "R" and result == "added") then
        if (appliedEntry.replacedRow) then removeEntryFromIndexes(appliedEntry.replacedRow); end
        insertEntryIntoIndexes(appliedEntry.row);
    elseif (appliedEntry.kind == "D" and result == "tombstoned" and appliedEntry.removedRow) then
        if (expandedEntryId == appliedEntry.id) then expandedEntryId = nil; end
        removeEntryFromIndexes(appliedEntry.removedRow);
    elseif (appliedEntry.kind == "P" and result == "added") then
        -- A pin doesn't add/remove/move a row (no index change needed) - just
        -- repaint the currently-visible rows so row.pinButton reflects it,
        -- whether this was our own manual pin, a received LIVE_PIN, or an
        -- autopin. Skips the sidebar refresh below (date/player/item bucket
        -- counts never depend on pin status).
        layoutResultRows(currentResults);
        return;
    else
        return; -- an outcome that changed nothing visible (dup/rejected/expired/...)
    end

    dateColumn.refresh();
    playersColumn.refresh();
    itemsColumn.refresh();

    if (not filterStillValid(currentFilter)) then
        applyFilter(nil);
    else
        local results = resolveResults(currentFilter);
        paintFilterBar(currentFilter, results);
        layoutResultRows(results);
    end
end
FL.Sync.Store.RegisterCallback(LootHistoryWindow, "EntryApplied", onEntryApplied);

function LootHistoryWindow.Hide()
    if (frame) then frame:Hide(); end
end

function LootHistoryWindow.IsShown()
    return frame ~= nil and frame:IsShown();
end

function LootHistoryWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then LootHistoryWindow.Hide(); else LootHistoryWindow.Show(); end
end

function LootHistoryWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
