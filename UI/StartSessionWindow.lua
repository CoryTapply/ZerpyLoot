--[[
Leader-facing "build the session list" window - replaces the old
LootCouncilAddItemsWindow. Built directly with the settings window's own
control vocabulary (UI.Colors/UI.Sizes.startSession/UI.SetFont/UI.Skin), not
FL.Theme - this window has exactly one look, it doesn't follow the active
skin. Session item data/logic (add, remove, clear, tradeable check, bag scan,
send) lives in Session/SessionItems.lua, not here.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.startSession;
local SharedLayout = FL.UI.Sizes.layout;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Widgets = FL.UI.SettingsWidgets;
local SessionItems = FL.SessionItems;
local Awards = FL.Awards;
local Util = FL.Util;
local StartSessionWindow = FL.UI.StartSessionWindow;

local WINDOW_WIDTH = Sizes.window.width;
local WINDOW_HEIGHT = Sizes.window.height;
local FALLBACK_ICON = FL.LootCouncil.FALLBACK_ICON;
local DELETE_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\trash.tga";
local PLUS_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Award\\Plus.tga";

-- Key this window's saved position is stored under (see
-- Settings.GetWindowPosition/SetWindowPosition). OLD_POSITION_KEY is the
-- deleted AddItemsWindow's own key - migrated once below so a player who had
-- that window positioned somewhere doesn't lose it.
local POSITION_KEY = "startSessionWindow";
local OLD_POSITION_KEY = "lootCouncilAddItemsWindow";

local frame, listBox, listScroll, listScrollChild, countText, clearButton, startButton;
local councilButton, councilIcon, councilCountText;
local header, footer, headerTitle, liveSummary;

-- Fallback matches the pattern used elsewhere in the addon (e.g.
-- UI/RollWindow.lua's right-click hint icon) for an atlas that may not exist
-- on every client.
local COUNCIL_ICON_ATLAS = "socialqueuing-icon-group";
local COUNCIL_ICON_FALLBACK = "Interface\\FriendsFrame\\UI-Toast-FriendOnlineIcon";
local dropZone, dropZoneBg, dropZoneIcon, dropZoneMainText, dropZoneSubText, cursorWatcher, permissionWatcher;
local createDropZone, UpdateDropZone;
local rows = {};

-- DropZone visual-state inputs: cursorHasItem/cursorItemName come from the
-- CURSOR_CHANGED watcher (see createCursorWatcher below) and handleCursorDrop
-- (which sets them synchronously on drop, see below); isOverDropZone comes
-- from the DropZone's own OnEnter/OnLeave.
local cursorHasItem = false;
local cursorItemName = nil;
local isOverDropZone = false;

--------------------------------------------------------------------------
-- Row content (name/type-slot text, quality-colored icon border) - split out
-- from Refresh() since it re-runs asynchronously once an uncached item's
-- info actually loads (see the ContinueOnItemLoad branch below).
--------------------------------------------------------------------------

local function paintRowText(row, entry)
    local name, _, quality, _, _, itemType, itemSubType, _, equipLoc = Util.GetItemInfo(entry.itemLink);

    if (name) then
        local r, g, b = Util.GetItemQualityColor(quality);
        row.nameText:SetText(name);
        row.nameText:SetTextColor(r or 1, g or 1, b or 1);
        row.iconBorder:SetBackdropBorderColor(r or 0, g or 0, b or 0);

        local slot = (equipLoc and equipLoc ~= "") and _G[equipLoc] or nil;
        local isEquippable = slot ~= nil and slot ~= "";
        row.typeText:SetText(Util.JoinTypeParts(isEquippable and slot or itemType, itemSubType));
    else
        -- Not cached yet - show the raw link text and fill in the real name/
        -- type/quality once C_Item finishes loading it.
        row.nameText:SetText(entry.itemLink);
        row.nameText:SetTextColor(unpack(Colors.text));
        row.typeText:SetText("");
        row.iconBorder:SetBackdropBorderColor(unpack(Colors.transparent));

        local item = Item:CreateFromItemLink(entry.itemLink);
        item:ContinueOnItemLoad(function()
            if (row.entry == entry) then paintRowText(row, entry); end
        end);
    end
end

--------------------------------------------------------------------------
-- Drop/drag/click-to-drop handler - wired onto the DropZone only (see
-- createDropZone below): OnReceiveDrag covers drag-and-release, OnMouseUp
-- covers click-to-pickup then click-to-place.
--------------------------------------------------------------------------

local function handleCursorDrop()
    local cursorType, _, itemLink = GetCursorInfo();
    if (cursorType ~= "item") then return; end

    SessionItems.AddFromCursor(itemLink);
    ClearCursor(); -- item snaps back into the bag either way - nothing is moved/destroyed

    -- Set these explicitly rather than waiting on CURSOR_CHANGED - that event
    -- isn't guaranteed to be processed before Refresh() below, which would
    -- otherwise leave the DropZone showing "Release to add" for one frame
    -- after a successful/rejected drop.
    cursorHasItem = false;
    cursorItemName = nil;

    StartSessionWindow.Refresh();
end

--------------------------------------------------------------------------
-- Council button data. With a session live, this is that session's council
-- (Session.council - the same set LootCouncil.CanVote checks). Otherwise it
-- previews the council a session started now would get:
-- LootCouncil.SelectedCouncilNames(), i.e. the saved roster members in the
-- group plus the viewer. Names are matched on the stripped "First Last" name
-- both sides already use.
--------------------------------------------------------------------------

-- Returns two alphabetical arrays plus whether a session is live: council
-- members currently in the raid/party ({ name, classFile, isLeader }), and
-- the names of those who aren't - with a session live, council members who
-- left the group; otherwise, saved roster members who won't be included.
local function computeCouncilRaidInfo()
    local isLive = FL.LootCouncil.IsSessionLive();
    local councilNames = isLive and FL.LootCouncil.SessionCouncilNames() or FL.LootCouncil.SelectedCouncilNames();
    local council = {};
    for _, name in ipairs(councilNames) do council[name] = true; end

    local groupsResult = FL.LootCouncilRoster.BuildGroups();
    local inRaid = {};
    local inRaidNames = {};
    for _, group in pairs(groupsResult.groups) do
        for _, member in ipairs(group.members) do
            local name = Util.stripRealm(member.name);
            if (council[name]) then
                inRaidNames[name] = true;
                table.insert(inRaid, {
                    name = name,
                    classFile = member.classFile,
                    isLeader = UnitIsGroupLeader(member.unit),
                });
            end
        end
    end

    table.sort(inRaid, function(a, b) return a.name < b.name; end);

    local notInRaid = {};
    local others = isLive and councilNames or FL.LootCouncil.RosterNames(); -- both already alphabetical
    for _, name in ipairs(others) do
        if (not inRaidNames[name]) then table.insert(notInRaid, name); end
    end

    return inRaid, notInRaid, isLive;
end

-- Recomputes the button's count/color/width. Safe to call before the button
-- exists (e.g. from the roster-changed callback registered below, which
-- fires as soon as LootCouncil.lua loads - well before this window's frame
-- is ever built).
local function updateCouncilButton()
    if (not councilButton) then return; end

    local inRaid = computeCouncilRaidInfo();
    local n = #inRaid;

    councilCountText:SetText(tostring(n));
    councilCountText:SetTextColor(unpack(n == 0 and Colors.sessionDeleteHoverIcon or Colors.text));
    councilButton:SetWidth(Sizes.councilButtonPadX * 2 + Sizes.councilButtonIconSize
        + Sizes.councilButtonIconTextGap + councilCountText:GetStringWidth());
end

-- Debounced GROUP_ROSTER_UPDATE handler (mirrors the Loot Council settings
-- page's own 0.5s debounce for the same event - a raid join/leave can fire
-- it many times in a burst).
local councilUpdatePending = false;
local function scheduleCouncilButtonUpdate()
    if (councilUpdatePending) then return; end
    councilUpdatePending = true;
    C_Timer.After(0.5, function()
        councilUpdatePending = false;
        if (frame and frame:IsVisible()) then updateCouncilButton(); end
    end);
end

-- Registered once at load time - fires on every saved roster edit, session
-- start and session council update (see LootCouncil.lua), regardless of
-- whether this window has ever been opened yet.
FL.LootCouncil.RegisterRosterChangedCallback(function()
    if (frame and frame:IsVisible()) then updateCouncilButton(); end
end);

--------------------------------------------------------------------------
-- Frame construction
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
    title:SetText("ForeverLoot - Start Session");
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
        FL.NotifyWindowClosed("StartSession");
        frame:Hide();
    end);

    return titleBar;
end

local function createHeader()
    local header = CreateFrame("Frame", nil, frame);
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", Sizes.contentPadX, -(Sizes.titleBarHeight + Sizes.contentPadTop));
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -Sizes.contentPadX, -(Sizes.titleBarHeight + Sizes.contentPadTop));
    header:SetHeight(Sizes.headerHeight);

    -- Title text + Add All button share this row so the button can center on
    -- the title line alone, without the subtitle (which needs the window's
    -- full narrower width) ever being in its way.
    local titleRow = CreateFrame("Frame", nil, header);
    titleRow:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0);
    titleRow:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 0);
    titleRow:SetHeight(Sizes.headerAddAllHeight);

    headerTitle = titleRow:CreateFontString(nil, "OVERLAY");
    SetFont(headerTitle, "pageTitle");
    headerTitle:SetTextColor(unpack(Colors.gold));
    headerTitle:SetPoint("LEFT", titleRow, "LEFT", 0, 0);
    headerTitle:SetWordWrap(false);
    headerTitle:SetText("Session Items");

    local subtitle = header:CreateFontString(nil, "OVERLAY");
    SetFont(subtitle, "small");
    subtitle:SetTextColor(unpack(Colors.muted));
    subtitle:SetPoint("TOPLEFT", titleRow, "BOTTOMLEFT", 0, -Sizes.headerSubtitleGap);
    subtitle:SetPoint("TOPRIGHT", titleRow, "BOTTOMRIGHT", 0, -Sizes.headerSubtitleGap);
    subtitle:SetJustifyH("LEFT");
    subtitle:SetText("Items the council will vote on this session.");

    local addAllButton = Widgets.CreateFlatButton(header, "Add All", "default");
    addAllButton:SetSize(Sizes.headerAddAllWidth, Sizes.headerAddAllHeight);
    addAllButton:SetPoint("RIGHT", titleRow, "RIGHT", 0, 0);
    addAllButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT");
        GameTooltip:AddLine("Add every tradeable item in your bags.", 1, 1, 1, true);
        GameTooltip:Show();
    end);
    addAllButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);
    addAllButton:SetScript("OnClick", function()
        SessionItems.AddAllTradeableFromBags();
        StartSessionWindow.Refresh();
    end);

    -- Council button: icon + in-raid council count, left of Add All. Width
    -- is set dynamically (see updateCouncilButton) once the count text
    -- exists, so it starts at 0 here and is corrected before ever being
    -- shown (the window's OnShow hook calls updateCouncilButton()).
    councilButton = CreateFrame("Button", nil, header, "BackdropTemplate");
    Skin.Button(councilButton, "default");
    councilButton:SetHeight(Sizes.councilButtonHeight);
    councilButton:SetPoint("RIGHT", addAllButton, "LEFT", -Sizes.councilButtonGap, 0);

    councilIcon = councilButton:CreateTexture(nil, "ARTWORK");
    councilIcon:SetSize(Sizes.councilButtonIconSize, Sizes.councilButtonIconSize);
    councilIcon:SetPoint("LEFT", councilButton, "LEFT", Sizes.councilButtonPadX, 0);
    if (C_Texture.GetAtlasInfo(COUNCIL_ICON_ATLAS)) then
        councilIcon:SetAtlas(COUNCIL_ICON_ATLAS);
    else
        councilIcon:SetTexture(COUNCIL_ICON_FALLBACK);
    end
    councilIcon:SetVertexColor(unpack(Colors.description));

    councilCountText = councilButton:CreateFontString(nil, "OVERLAY");
    SetFont(councilCountText, "body");
    councilCountText:SetPoint("LEFT", councilIcon, "RIGHT", Sizes.councilButtonIconTextGap, 0);
    councilCountText:SetText("0");

    councilButton:HookScript("OnEnter", function()
        councilIcon:SetVertexColor(unpack(Colors.gold));
    end);
    councilButton:HookScript("OnLeave", function()
        councilIcon:SetVertexColor(unpack(Colors.description));
    end);

    councilButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT");

        local inRaid, notInRaid, isLive = computeCouncilRaidInfo();
        GameTooltip:AddDoubleLine(isLive and "Session Council" or "Loot Council", ("%d in raid"):format(#inRaid),
            Colors.gold[1], Colors.gold[2], Colors.gold[3],
            Colors.muted[1], Colors.muted[2], Colors.muted[3]);

        if (#inRaid > 0) then
            for _, member in ipairs(inRaid) do
                local classColor = member.classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.classFile];
                local r, g, b = Colors.text[1], Colors.text[2], Colors.text[3];
                if (classColor) then r, g, b = classColor.r, classColor.g, classColor.b; end
                local suffix = member.isLeader and " |TInterface\\GroupFrame\\UI-Group-LeaderIcon:12|t" or "";
                GameTooltip:AddLine(member.name .. suffix, r, g, b);
            end
        else
            GameTooltip:AddLine("No council members in your raid \226\128\148 nobody can vote.",
                unpack(Colors.sessionDeleteHoverIcon));
        end

        if (#notInRaid > 0) then
            GameTooltip:AddLine(" ");
            GameTooltip:AddLine(isLive and "Not in raid" or "Not in raid (won't be included)", unpack(Colors.controlHover));
            for _, name in ipairs(notInRaid) do
                GameTooltip:AddLine(name, unpack(Colors.disabledText));
            end
        end

        GameTooltip:AddLine(" ");
        GameTooltip:AddLine(isLive and "Click to change the session's council"
            or "Click to add or remove council members", unpack(Colors.muted));
        GameTooltip:Show();
    end);
    councilButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);

    councilButton:SetScript("OnClick", function()
        FL.UI.SettingsWindow.Show();
        FL.UI.SettingsRegistry.SelectPage("lootcouncil");
    end);

    return header;
end

--------------------------------------------------------------------------
-- Live-session summary - shown only once a session is already active (see
-- StartSessionWindow.Refresh's mode branch below), between the header and
-- the item list. Same "<assigned> of <total> assigned" / "<n> never
-- awarded" counts row + wrapping row of the still-unassigned items' own
-- icons that UI/AwardWindow.lua's End-Session-Early popup shows, so a
-- leader adding more loot to a running session gets the same "here's what's
-- still pending" read before appending to it - built and laid out the same
-- way (see paintLiveSummary below), just under this window's own header
-- instead of a popup dialog.
--------------------------------------------------------------------------

-- Opens AwardWindow (self-gates on LootCouncil.CanAccessReviewWindow, see
-- its own Show()) - shared by the box's own click and each item icon's
-- click below, so clicking anywhere in the summary (including on an icon,
-- which would otherwise just swallow the click for its tooltip) does the
-- same thing.
local function openAwardWindow()
    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Show) then
        FL.UI.AwardWindow.Show();
    end
end

local function createLiveSummary()
    local box = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(box, Colors.sessionListBg, Colors.memberBorder, 1);
    box:Hide();

    -- Clickable through to AwardWindow - same hover-border idiom as
    -- createRow's own OnEnter/OnLeave above.
    box:EnableMouse(true);
    box:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(Colors.checkboxBorder)); end);
    box:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(Colors.memberBorder)); end);
    box:SetScript("OnMouseUp", openAwardWindow);

    box.countsText = box:CreateFontString(nil, "OVERLAY");
    SetFont(box.countsText, "small");
    box.countsText:SetTextColor(unpack(Colors.description));
    box.countsText:SetJustifyH("LEFT");
    box.countsText:SetWordWrap(false);

    box.neverText = box:CreateFontString(nil, "OVERLAY");
    SetFont(box.neverText, "small");
    box.neverText:SetTextColor(unpack(Colors.muted));
    box.neverText:SetJustifyH("RIGHT");
    box.neverText:SetWordWrap(false);

    box.icons = {};
    for i = 1, Sizes.summaryMaxIcons do
        local icon = CreateFrame("Frame", nil, box, "BackdropTemplate");
        icon:SetSize(Sizes.summaryIconSize, Sizes.summaryIconSize);
        local bt = Sizes.summaryIconBorderThickness;
        icon.tex = icon:CreateTexture(nil, "ARTWORK");
        icon.tex:SetPoint("TOPLEFT", icon, "TOPLEFT", bt, -bt);
        icon.tex:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -bt, bt);
        icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92);
        Theme.Helpers.SetFlatBackdrop(icon, nil, Colors.transparent, bt);
        icon:EnableMouse(true);
        icon:HookScript("OnEnter", function(self)
            if (not self.itemLink) then return; end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink(self.itemLink);
            GameTooltip:Show();
        end);
        icon:HookScript("OnLeave", function() GameTooltip:Hide(); end);
        icon:HookScript("OnMouseUp", openAwardWindow);
        icon:Hide();
        box.icons[i] = icon;
    end

    box.moreText = box:CreateFontString(nil, "OVERLAY");
    SetFont(box.moreText, "small");
    box.moreText:SetTextColor(unpack(Colors.muted));
    box.moreText:Hide();

    return box;
end

-- Same itemIcon fallback chain as UI/AwardWindow.lua's own local helper -
-- Session.items entries carry itemIcon once C_Item resolves it, else fall
-- back to a bag-independent lookup by itemID.
local function sessionItemIcon(item)
    return (item and (item.itemIcon or (item.itemID and Util.GetItemIcon(item.itemID)))) or FALLBACK_ICON;
end

-- Lays out liveSummary's counts row + wrapping icon grid for the active
-- session's still-unassigned items, then sizes the box to fit - identical
-- column/row math to AwardWindow.lua's ShowEndSessionEarlyPopup, just
-- wrapped to this window's own fixed content width instead of a popup's.
local function paintLiveSummary(unassigned, assignedCount, totalCount)
    local goldHex = Util.RGBToHex(Colors.gold[1], Colors.gold[2], Colors.gold[3]);
    liveSummary.countsText:SetText(("|cff%s%d|r of %d items assigned"):format(goldHex, assignedCount, totalCount));
    liveSummary.countsText:ClearAllPoints();
    liveSummary.countsText:SetPoint("TOPLEFT", liveSummary, "TOPLEFT", Sizes.summaryPadding, -Sizes.summaryPadding);

    liveSummary.neverText:SetText(("%d never awarded"):format(#unassigned));
    liveSummary.neverText:ClearAllPoints();
    liveSummary.neverText:SetPoint("TOPRIGHT", liveSummary, "TOPRIGHT", -Sizes.summaryPadding, -Sizes.summaryPadding);

    local countsHeight = math.max(liveSummary.countsText:GetStringHeight(), liveSummary.neverText:GetStringHeight());

    local showIconRow = #unassigned > 0;
    local iconRowHeight = 0;
    if (showIconRow) then
        local availWidth = WINDOW_WIDTH - Sizes.contentPadX * 2 - Sizes.summaryPadding * 2;
        local step = Sizes.summaryIconSize + Sizes.summaryIconGap;
        local columns = math.max(1, math.floor((availWidth + Sizes.summaryIconGap) / step));
        local shownCount = math.min(#unassigned, Sizes.summaryMaxIcons);
        local extra = #unassigned - shownCount;
        local totalSlots = shownCount + (extra > 0 and 1 or 0); -- "+N more" occupies a trailing slot
        local rows = math.max(1, math.ceil(totalSlots / columns));
        iconRowHeight = Sizes.summaryRowGap + rows * Sizes.summaryIconSize + (rows - 1) * Sizes.summaryIconGap;

        local rowTop = -(Sizes.summaryPadding + countsHeight + Sizes.summaryRowGap);
        for i = 1, shownCount do
            local item = unassigned[i];
            local icon = liveSummary.icons[i];
            local col = (i - 1) % columns;
            local row = math.floor((i - 1) / columns);
            icon:ClearAllPoints();
            icon:SetPoint("TOPLEFT", liveSummary, "TOPLEFT",
                Sizes.summaryPadding + col * step, rowTop - row * (Sizes.summaryIconSize + Sizes.summaryIconGap));
            icon.tex:SetTexture(sessionItemIcon(item));
            icon:SetBackdropBorderColor(unpack(Colors.muted));
            icon.itemLink = item.itemLink;
            icon:Show();
        end
        for i = shownCount + 1, Sizes.summaryMaxIcons do
            liveSummary.icons[i]:Hide();
            liveSummary.icons[i].itemLink = nil;
        end

        if (extra > 0) then
            local slot = shownCount; -- 0-based - the cell right after the last shown icon
            local col = slot % columns;
            local row = math.floor(slot / columns);
            liveSummary.moreText:SetText(("+%d more"):format(extra));
            liveSummary.moreText:ClearAllPoints();
            liveSummary.moreText:SetPoint("LEFT", liveSummary, "TOPLEFT",
                Sizes.summaryPadding + col * step, rowTop - row * (Sizes.summaryIconSize + Sizes.summaryIconGap) - Sizes.summaryIconSize / 2);
            liveSummary.moreText:Show();
        else
            liveSummary.moreText:Hide();
        end
    else
        for i = 1, Sizes.summaryMaxIcons do
            liveSummary.icons[i]:Hide();
            liveSummary.icons[i].itemLink = nil;
        end
        liveSummary.moreText:Hide();
    end

    liveSummary:SetHeight(Sizes.summaryPadding * 2 + countsHeight + iconRowHeight);
end

local function createFooter()
    local footer = CreateFrame("Frame", nil, frame);
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", Sizes.contentPadX, Sizes.footerBottomPad);
    footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Sizes.contentPadX, Sizes.footerBottomPad);
    footer:SetHeight(Sizes.footerHeight);

    local divider = footer:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, 0);
    divider:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, 0);
    Pixel.SetLineHeight(divider, 1);

    -- Buttons anchor to the footer's BOTTOM (never to the divider above), so
    -- there's always footerDividerGap of daylight between the line and the
    -- button tops regardless of anything else in the footer.
    local buttonRow = CreateFrame("Frame", nil, footer);
    buttonRow:SetPoint("BOTTOMLEFT", footer, "BOTTOMLEFT", 0, 0);
    buttonRow:SetPoint("BOTTOMRIGHT", footer, "BOTTOMRIGHT", 0, 0);
    buttonRow:SetHeight(Sizes.footerRowHeight);

    countText = buttonRow:CreateFontString(nil, "OVERLAY");
    SetFont(countText, "sectionHeader");
    countText:SetTextColor(unpack(Colors.gold));
    countText:SetPoint("LEFT", buttonRow, "LEFT", 0, 0);

    startButton = Widgets.CreateFlatButton(buttonRow, "Start Session", "primary");
    startButton.mode = "start";
    startButton:SetSize(Sizes.footerStartWidth, Sizes.footerRowHeight);
    startButton:SetPoint("RIGHT", buttonRow, "RIGHT", 0, 0);
    startButton:SetScript("OnClick", function()
        local isAdding = startButton.mode == "add";
        local ok, message = isAdding and SessionItems.SendToActiveSession() or SessionItems.Send();
        if (ok) then
            FL.NotifyWindowClosed("StartSession");
            frame:Hide();
            return;
        end
        if (message) then
            print("|cff8865ffForeverLoot|r " .. message);
        end
        StartSessionWindow.Refresh();
    end);
    startButton:HookScript("OnEnter", function(self)
        if (not SessionItems.CanSend()) then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT");
            GameTooltip:AddLine("Only the raid leader or an assistant can manage loot council sessions.", 1, 1, 1, true);
            GameTooltip:Show();
        end
    end);
    startButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);

    clearButton = Widgets.CreateFlatButton(buttonRow, "Clear", "default");
    clearButton:SetSize(Sizes.footerClearWidth, Sizes.footerRowHeight);
    clearButton:SetPoint("RIGHT", startButton, "LEFT", -Sizes.footerButtonGap, 0);
    clearButton:SetScript("OnClick", function()
        SessionItems.Clear();
        StartSessionWindow.Refresh();
    end);

    return footer;
end

local function createRow(parent, index)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate");
    row:SetPoint("TOPLEFT", 0, -(index - 1) * (Sizes.rowHeight + Sizes.rowSpacing));
    row:SetPoint("RIGHT", parent, "RIGHT");
    row:SetHeight(Sizes.rowHeight);
    Theme.Helpers.SetFlatBackdrop(row, Colors.memberBg, Colors.memberBorder, 1);

    row:EnableMouse(true);
    row:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(Colors.checkboxBorder)); end);
    row:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(Colors.memberBorder)); end);

    row.icon = row:CreateTexture(nil, "ARTWORK");
    row.icon:SetSize(Sizes.rowIconSize, Sizes.rowIconSize);
    row.icon:SetPoint("LEFT", row, "LEFT", Sizes.listPadding, 0);
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

    row.iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
    row.iconBorder:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -1, 1);
    row.iconBorder:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1);
    Theme.Helpers.SetFlatBackdrop(row.iconBorder, nil, Colors.transparent, 1);

    row.removeButton = CreateFrame("Button", nil, row, "BackdropTemplate");
    row.removeButton:SetSize(Sizes.rowButtonSize, Sizes.rowButtonSize);
    row.removeButton:SetPoint("RIGHT", row, "RIGHT", -Sizes.listPadding, 0);
    row.removeButton:RegisterForClicks("LeftButtonUp");

    row.removeButton.icon = row.removeButton:CreateTexture(nil, "ARTWORK");
    local removeIconSize = math.floor(Sizes.rowButtonSize * 0.7 + 0.5);
    row.removeButton.icon:SetSize(removeIconSize, removeIconSize);
    row.removeButton.icon:SetPoint("CENTER");
    row.removeButton.icon:SetTexture(DELETE_ICON_TEXTURE);

    local function paintRemoveDefault()
        Theme.Helpers.SetFlatBackdrop(row.removeButton, Colors.transparent, Colors.transparent, 1);
        row.removeButton.icon:SetVertexColor(unpack(Colors.muted));
    end
    local function paintRemoveHover()
        Theme.Helpers.SetFlatBackdrop(row.removeButton, Colors.sessionDeleteHoverBg, Colors.skinCloseBorder, 1);
        row.removeButton.icon:SetVertexColor(unpack(Colors.sessionDeleteHoverIcon));
    end
    paintRemoveDefault();
    row.removeButton:HookScript("OnEnter", paintRemoveHover);
    row.removeButton:HookScript("OnLeave", paintRemoveDefault);
    row.removeButton:SetScript("OnClick", function()
        if (not row.itemIndex) then return; end
        SessionItems.RemoveItem(row.itemIndex);
        StartSessionWindow.Refresh();
    end);

    row.nameText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.nameText, "body");
    row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", Sizes.rowIconTextGap, 0);
    row.nameText:SetPoint("RIGHT", row.removeButton, "LEFT", -Sizes.rowButtonTextGap, 0);
    row.nameText:SetJustifyH("LEFT");
    row.nameText:SetWordWrap(false);

    row.typeText = row:CreateFontString(nil, "OVERLAY");
    SetFont(row.typeText, "small");
    row.typeText:SetTextColor(unpack(Colors.muted));
    row.typeText:SetPoint("TOPLEFT", row.nameText, "BOTTOMLEFT", 0, -Sizes.rowTextLineGap);
    row.typeText:SetPoint("RIGHT", row.nameText, "RIGHT", 0, 0);
    row.typeText:SetJustifyH("LEFT");
    row.typeText:SetWordWrap(false);

    -- Tooltip - only over the icon itself, not the whole row. Also required
    -- to be within listScroll's own bounds (Util.IsMouseOverVisible) - a row
    -- scrolled out of the visible list still occupies its original on-screen
    -- rect as far as IsMouseOver is concerned, since ScrollFrame only clips
    -- rendering.
    row:SetScript("OnUpdate", function(self)
        if (self.entry and Util.IsMouseOverVisible(self.icon, listScroll)) then
            GameTooltip:SetOwner(self.icon, "ANCHOR_RIGHT");
            GameTooltip:SetHyperlink(self.entry.itemLink);
            GameTooltip:Show();
        elseif (GameTooltip:GetOwner() == self.icon) then
            GameTooltip:Hide();
        end
    end);

    row:Hide();
    return row;
end

-- Grows the row pool up to n frames, reusing whatever already exists. Never
-- shrinks - rows beyond the current item count are just hidden in Refresh.
local function ensureRowCount(n)
    for i = #rows + 1, n do
        rows[i] = createRow(listScrollChild, i);
    end
end

local function createList()
    listBox = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    Theme.Helpers.SetFlatBackdrop(listBox, Colors.sessionListBg, Colors.memberBorder, 1);

    local listLabel = listBox:CreateFontString(nil, "OVERLAY");
    SetFont(listLabel, "small");
    listLabel:SetTextColor(unpack(Colors.muted));
    listLabel:SetPoint("TOPLEFT", listBox, "TOPLEFT", Sizes.listPadding, -Sizes.listPadding);
    listLabel:SetText("ITEMS");

    -- Rows fill the list width minus the scrollbar's own space (bar + gap +
    -- a small inset off the listBox border) - no extra padding term here, or
    -- it leaves an empty column to the right of the rows.
    local scrollbarSpace = SharedLayout.scrollbarWidth + Sizes.listScrollbarGap + Sizes.listScrollbarInset;

    listScroll = CreateFrame("ScrollFrame", "ForeverLootStartSessionWindowScroll", listBox, "UIPanelScrollFrameTemplate");
    listScroll:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -Sizes.listLabelGap);
    listScroll:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -scrollbarSpace, Sizes.listPadding);

    listScrollChild = CreateFrame("Frame", nil, listScroll);
    listScrollChild:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0);
    listScroll:SetScrollChild(listScrollChild);
    listScroll:SetScript("OnSizeChanged", function(self, width) listScrollChild:SetWidth(width); end);

    local listScrollBar = Skin.ScrollBar(listScroll);
    if (listScrollBar) then
        listScrollBar:ClearAllPoints();
        listScrollBar:SetPoint("TOP", listScroll, "TOP", 0, 0);
        listScrollBar:SetPoint("BOTTOM", listScroll, "BOTTOM", 0, 0);
        listScrollBar:SetPoint("RIGHT", listBox, "RIGHT", -Sizes.listScrollbarInset, 0);
    end

    Theme.Helpers.EnableSmoothScroll(listScroll, { step = Sizes.rowHeight + Sizes.rowSpacing });

    ensureRowCount(1);
    createDropZone(listBox, listScroll);

    return listBox;
end

--------------------------------------------------------------------------
-- DropZone - the sole drop target for the item list. A single overlay frame,
-- inset inside listScroll's own rect (i.e. the same area the rows occupy),
-- sitting above listScroll in frame level so it covers the rows without
-- moving/scrolling them. UpdateDropZone() drives its 4 states: hidden (list
-- has items, nothing on cursor), idle (list empty, nothing on cursor),
-- active (item on cursor), hot (active + hovered). See handleCursorDrop and
-- createCursorWatcher below for what feeds cursorHasItem/isOverDropZone.
--------------------------------------------------------------------------

createDropZone = function(box, scroll)
    local zone = CreateFrame("Frame", nil, box);
    zone:SetPoint("TOPLEFT", scroll, "TOPLEFT", Sizes.dropZoneInset, -Sizes.dropZoneInset);
    zone:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -Sizes.dropZoneInset, Sizes.dropZoneInset);
    zone:SetFrameLevel(scroll:GetFrameLevel() + 10); -- above listScroll and every row/button inside it

    local bg = zone:CreateTexture(nil, "BACKGROUND");
    bg:SetAllPoints(zone);
    bg:SetColorTexture(0, 0, 0, 0); -- idle: no fill, listBox's own background shows through

    Skin.DashedBorder(zone, Colors.checkboxBorder[1], Colors.checkboxBorder[2], Colors.checkboxBorder[3], 1, Sizes.dropZoneDash, 1);

    local icon = zone:CreateTexture(nil, "ARTWORK");
    icon:SetSize(Sizes.dropZoneIconSize, Sizes.dropZoneIconSize);
    icon:SetTexture(PLUS_ICON_TEXTURE);

    local mainText = zone:CreateFontString(nil, "ARTWORK");
    SetFont(mainText, "body");
    mainText:SetPoint("CENTER", zone, "CENTER", 0, 0);

    icon:SetPoint("BOTTOM", mainText, "TOP", 0, Sizes.dropZoneIconGap);

    local subText = zone:CreateFontString(nil, "ARTWORK");
    SetFont(subText, "small");
    subText:SetPoint("TOP", mainText, "BOTTOM", 0, -Sizes.dropZoneLineGap);

    zone:SetScript("OnReceiveDrag", handleCursorDrop);
    zone:SetScript("OnMouseUp", handleCursorDrop);
    zone:SetScript("OnEnter", function() isOverDropZone = true; UpdateDropZone(); end);
    zone:SetScript("OnLeave", function() isOverDropZone = false; UpdateDropZone(); end);

    zone:Hide();
    zone:EnableMouse(false);

    dropZone, dropZoneBg, dropZoneIcon, dropZoneMainText, dropZoneSubText = zone, bg, icon, mainText, subText;
    return zone;
end

UpdateDropZone = function()
    local hasItems = #SessionItems.GetItems() > 0;

    if (hasItems and not cursorHasItem) then
        dropZone:Hide();
        dropZone:EnableMouse(false);
        return;
    end

    dropZone:Show();
    dropZone:EnableMouse(true);

    if (cursorHasItem) then
        local fill = isOverDropZone and Colors.primaryBg or Colors.sessionDropActiveBg;
        dropZoneBg:SetColorTexture(fill[1], fill[2], fill[3], fill[4] or 1);
        dropZone:SetDashColor(Colors.gold[1], Colors.gold[2], Colors.gold[3], 1);
        dropZoneIcon:SetVertexColor(Colors.gold[1], Colors.gold[2], Colors.gold[3]);
        dropZoneMainText:SetTextColor(Colors.gold[1], Colors.gold[2], Colors.gold[3]);
        dropZoneMainText:SetText(("Release to add %s"):format(cursorItemName or "item"));
        dropZoneSubText:SetShown(false);
    else
        dropZoneBg:SetColorTexture(0, 0, 0, 0);
        dropZone:SetDashColor(Colors.checkboxBorder[1], Colors.checkboxBorder[2], Colors.checkboxBorder[3], 1);
        dropZoneIcon:SetVertexColor(Colors.description[1], Colors.description[2], Colors.description[3]);
        dropZoneMainText:SetTextColor(Colors.description[1], Colors.description[2], Colors.description[3]);
        dropZoneMainText:SetText("Drag items here");
        dropZoneSubText:SetText("Shift-click an item, or use Add All.");
        dropZoneSubText:SetTextColor(Colors.controlHover[1], Colors.controlHover[2], Colors.controlHover[3]);
        dropZoneSubText:SetShown(true);
    end
end

--------------------------------------------------------------------------
-- Cursor-drag highlight + shift-click add
--------------------------------------------------------------------------

-- CURSOR_CHANGED is only registered while the window is shown (see the
-- OnShow/OnHide hooks in ensureFrame below) - no need to gate inside the
-- handler, since it can't fire while unregistered.
local function createCursorWatcher()
    cursorWatcher = CreateFrame("Frame");
    cursorWatcher:SetScript("OnEvent", function()
        local cursorType, _, itemLink = GetCursorInfo();
        cursorHasItem = (cursorType == "item");
        cursorItemName = (cursorHasItem and itemLink) and Util.GetItemInfo(itemLink) or nil;
        UpdateDropZone();
    end);
end

-- Refreshes startButton's enabled state the moment the player is handed (or
-- loses) leader/assist - GROUP_ROSTER_UPDATE covers promotions/demotions,
-- PARTY_LEADER_CHANGED covers a straight leader handoff in a party (which
-- doesn't always also fire a roster update). Matches the event pair
-- Blizzard_RaidFrame registers for the same leader/assist-gated buttons.
local function createPermissionWatcher()
    permissionWatcher = CreateFrame("Frame");
    permissionWatcher:SetScript("OnEvent", function(_, event)
        StartSessionWindow.Refresh();
        if (event == "GROUP_ROSTER_UPDATE") then scheduleCouncilButtonUpdate(); end
    end);
end

-- HandleModifiedItemClick is the actual function the game calls on every
-- modified item click (RollTracker.lua and the old AddItemsWindow both
-- hooked this same global for their own click features). Only installed
-- once, at file scope - it no-ops until `frame` exists and is shown.
hooksecurefunc("HandleModifiedItemClick", function(itemLink)
    if (not (frame and frame:IsShown())) then return; end
    if (not itemLink or not IsShiftKeyDown()) then return; end
    if (ChatEdit_GetActiveWindow() ~= nil) then return; end -- let normal link-pasting into chat happen

    if (StackSplitFrame and StackSplitFrame:IsShown()) then
        StackSplitFrame:Hide();
    end

    SessionItems.AddFromCursor(itemLink);
    StartSessionWindow.Refresh();
end);

--------------------------------------------------------------------------
-- Window lifecycle
--------------------------------------------------------------------------

local function ensureFrame()
    if (frame) then return; end

    if (not FL.Settings.GetWindowPosition(POSITION_KEY)) then
        local oldPosition = FL.Settings.GetWindowPosition(OLD_POSITION_KEY);
        if (oldPosition) then
            FL.Settings.SetWindowPosition(POSITION_KEY, oldPosition.x, oldPosition.y);
        end
    end
    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootStartSessionWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    Pixel.RegisterWindow(frame, {
        width = WINDOW_WIDTH, height = WINDOW_HEIGHT,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    createTitleBar();
    header = createHeader();
    footer = createFooter();

    liveSummary = createLiveSummary();
    liveSummary:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -Sizes.summaryGap);
    liveSummary:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -Sizes.summaryGap);

    createList();
    listBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -Sizes.listGap);
    listBox:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -Sizes.listGap);
    listBox:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, Sizes.footerScrollGap);
    listBox:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, Sizes.footerScrollGap);

    createCursorWatcher();
    createPermissionWatcher();

    frame:HookScript("OnShow", function()
        cursorWatcher:RegisterEvent("CURSOR_CHANGED");
        permissionWatcher:RegisterEvent("GROUP_ROSTER_UPDATE");
        permissionWatcher:RegisterEvent("PARTY_LEADER_CHANGED");
        UpdateDropZone();
        updateCouncilButton();
    end);
    frame:HookScript("OnHide", function()
        cursorWatcher:UnregisterEvent("CURSOR_CHANGED");
        permissionWatcher:UnregisterEvent("GROUP_ROSTER_UPDATE");
        permissionWatcher:UnregisterEvent("PARTY_LEADER_CHANGED");
        cursorHasItem = false;
        cursorItemName = nil;
        isOverDropZone = false;
        UpdateDropZone();
    end);
end

function StartSessionWindow.Refresh()
    if (not frame) then return; end

    -- If the list was already scrolled to the bottom, stay pinned there so a
    -- newly-added item (which lands at the bottom) scrolls into view. The
    -- ScrollFrame doesn't recompute its scroll range synchronously when the
    -- scroll child resizes below - GetVerticalScrollRange() and the clamp
    -- inside SetVerticalScroll both still see the pre-resize range for the
    -- rest of this frame - so the actual re-scroll is deferred to the next
    -- frame via C_Timer.After(0, ...), by which point the range is current.
    local pendingTarget = listScroll.zlSmoothScrollTarget and listScroll.zlSmoothScrollTarget();
    local effectiveScroll = pendingTarget or listScroll:GetVerticalScroll();
    local wasAtBottom = effectiveScroll >= (listScroll:GetVerticalScrollRange() - 1);

    local sessionItems = SessionItems.GetItems();
    local count = #sessionItems;

    ensureRowCount(count);
    listScrollChild:SetHeight(math.max(count * (Sizes.rowHeight + Sizes.rowSpacing), 1));

    if (wasAtBottom) then
        C_Timer.After(0, function()
            if (listScroll) then
                listScroll:SetVerticalScroll(listScroll:GetVerticalScrollRange());
            end
        end);
    end

    for i, row in ipairs(rows) do
        local entry = sessionItems[i];
        if (entry) then
            row.entry = entry;
            row.itemIndex = i;
            row.icon:SetTexture(Util.GetItemIcon(entry.itemID) or FALLBACK_ICON);
            paintRowText(row, entry);
            row:Show();
        else
            row.entry = nil;
            row.itemIndex = nil;
            row:Hide();
        end
    end

    UpdateDropZone();
    countText:SetText(("%d item%s"):format(count, count == 1 and "" or "s"));

    local canSend = SessionItems.CanSend();
    clearButton:SetEnabled(count > 0);
    startButton:SetEnabled(canSend);

    -- Once a session is already running, this button appends to it instead
    -- of starting a new one - only repaint text/width on an actual mode
    -- transition (mirrors AwardWindow.lua's nextButton.mode idiom).
    local Session = FL.LootCouncil.CurrentSession;
    local mode = FL.LootCouncil.IsSessionLive() and "add" or "start";
    if (startButton.mode ~= mode) then
        startButton.mode = mode;
        startButton.text:SetText(mode == "add" and "Add to Session" or "Start Session");
        startButton:SetWidth(math.max(Sizes.footerStartWidth, startButton.text:GetStringWidth() + 24));
    end

    -- Live-session summary (see createLiveSummary/paintLiveSummary above) -
    -- shown only in "add" mode, between the header and the item list. Text
    -- and icon repaint every refresh (the active session's own assigned
    -- count can change while this window stays open), but the listBox
    -- re-anchor only runs on an actual mode transition, same idiom as
    -- startButton.mode above.
    local isAdding = mode == "add";
    headerTitle:SetText(isAdding and "Add to Live Session" or "Session Items");
    if (isAdding) then
        local unassigned, _, assignedCount, totalCount = Awards.PartitionItems(Session);
        paintLiveSummary(unassigned, assignedCount, totalCount);
    end
    if (liveSummary.shown ~= isAdding) then
        liveSummary.shown = isAdding;
        liveSummary:SetShown(isAdding);
        listBox:ClearAllPoints();
        listBox:SetPoint("TOPLEFT", isAdding and liveSummary or header, "BOTTOMLEFT", 0, -Sizes.listGap);
        listBox:SetPoint("TOPRIGHT", isAdding and liveSummary or header, "BOTTOMRIGHT", 0, -Sizes.listGap);
        listBox:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, Sizes.footerScrollGap);
        listBox:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, Sizes.footerScrollGap);
    end

    if (listScroll.ScrollBar and listScroll.ScrollBar.zlUpdateVisibility) then
        listScroll.ScrollBar.zlUpdateVisibility();
    end
end

function StartSessionWindow.Show()
    ensureFrame();
    frame:Show();
    StartSessionWindow.Refresh();
end

function StartSessionWindow.Hide()
    if (frame) then frame:Hide(); end
end

function StartSessionWindow.IsShown()
    return frame ~= nil and frame:IsShown();
end

function StartSessionWindow.Toggle()
    ensureFrame();
    if (frame:IsShown()) then StartSessionWindow.Hide(); else StartSessionWindow.Show(); end
end

function StartSessionWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
