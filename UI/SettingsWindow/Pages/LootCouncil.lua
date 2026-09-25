--[[
Loot Council settings page: a clickable raid-roster grid for picking council
members, plus the officer options and the Clear/Select Officers/Sync to Raid
footer actions. UI only - all roster/data logic lives in LootCouncilRoster.lua
(grid data) and LootCouncil.lua (roster storage + comm), per the "keep
roster/council data logic in its own module" design.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Colors = FL.UI.Colors;
local SetFont = FL.UI.SetFont;
local Widgets = FL.UI.SettingsWidgets;
local Util = FL.Util;
local LootCouncil = FL.LootCouncil;
local LootCouncilRoster = FL.LootCouncilRoster;

local GROUP_COLUMNS, GROUP_ROWS = 4, 2;
local MEMBER_SLOTS = 5;
local GROUP_BOX_GAP = 8;
local STRIP_HEIGHT = 40;
local STAR_RESERVE = 16;

local BOX_TOP_PAD, BOX_BOTTOM_PAD = 8, 8;
local LABEL_HEIGHT, LABEL_GAP = 14, 6;
local ROW_HEIGHT, ROW_GAP = FL.UI.Sizes.lists.memberButton, 3;
local BOX_HEIGHT = BOX_TOP_PAD + LABEL_HEIGHT + LABEL_GAP
    + MEMBER_SLOTS * ROW_HEIGHT + (MEMBER_SLOTS - 1) * ROW_GAP + BOX_BOTTOM_PAD;

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

--- Truncates the PLAIN (uncolored) name with "…" until it fits, always
--- reserving STAR_RESERVE px regardless of whether this member currently has
--- a star, so toggling council membership never reflows the text. Never
--- drops the trailing name token wholesale - shortens character by
--- character instead. Operates on the plain name (color is applied
--- separately via SetTextColor, not embedded escape codes) so truncation
--- can never cut into a color code.
local function truncateToWidth(fontString, plainText, maxWidth)
    fontString:SetText(plainText);
    if (fontString:GetStringWidth() <= maxWidth) then return; end

    local truncated = plainText;
    while (#truncated > 1 and fontString:GetStringWidth() > maxWidth) do
        truncated = truncated:sub(1, -2);
        fontString:SetText(truncated .. "\226\128\166");
    end
end

local function applyClassColor(fontString, classFile)
    local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile];
    if (color) then
        fontString:SetTextColor(color.r, color.g, color.b);
    else
        fontString:SetTextColor(unpack(Colors.text));
    end
end

--------------------------------------------------------------------------
-- Options strip: 2 checkboxes in a row
--------------------------------------------------------------------------

local function buildOptionsStrip(page, anchorAboveTop)
    local strip = CreateFrame("Frame", nil, page.frame, "BackdropTemplate");
    strip:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, anchorAboveTop);
    strip:SetPoint("TOPRIGHT", page.frame, "TOPRIGHT", 0, anchorAboveTop);
    strip:SetHeight(STRIP_HEIGHT);
    Theme.Helpers.SetFlatBackdrop(strip, Colors.optionsStripBg, Colors.border, 1);

    local specs = {
        { key = "lootCouncil.includeOfficers", label = "Always include guild officers" },
        { key = "lootCouncil.includeRaidLeader", label = "Always include raid leader" },
    };

    local prevRow;
    for _, spec in ipairs(specs) do
        local row = Widgets.BuildCheckboxRow(strip, spec);
        if (prevRow) then
            row.frame:SetPoint("LEFT", prevRow.frame, "RIGHT", 24, 0);
        else
            row.frame:SetPoint("LEFT", strip, "LEFT", 14, 0);
        end
        row.frame:SetPoint("TOP", strip, "TOP", 0, -10);

        table.insert(page.refreshers, function()
            row.checkbox:SetChecked(FL.Settings.GetPath(spec.key) and true or false);
        end);
        prevRow = row;
    end

    return strip;
end

--------------------------------------------------------------------------
-- Grid: 8 group boxes x 5 member slots, built once and repopulated on
-- refresh rather than recreated.
--------------------------------------------------------------------------

local function setMemberButtonState(button, isCouncil)
    if (isCouncil) then
        Theme.Helpers.SetFlatBackdrop(button, Colors.councilFill, Colors.councilBorder, 1);
        button.star:Show();
    else
        Theme.Helpers.SetFlatBackdrop(button, Colors.memberBg, Colors.memberBorder, 1);
        button.star:Hide();
    end
end

local function buildMemberButton(box, slot, page)
    local button = CreateFrame("Button", nil, box, "BackdropTemplate");
    button:SetPoint("TOPLEFT", box, "TOPLEFT", 6,
        -(BOX_TOP_PAD + LABEL_HEIGHT + LABEL_GAP + (slot - 1) * (ROW_HEIGHT + ROW_GAP)));
    button:SetPoint("RIGHT", box, "RIGHT", -6, 0);
    button:SetHeight(ROW_HEIGHT);
    Theme.Helpers.SetFlatBackdrop(button, Colors.memberBg, Colors.memberBorder, 1);

    local nameText = button:CreateFontString(nil, "OVERLAY");
    SetFont(nameText, "small");
    nameText:SetPoint("LEFT", button, "LEFT", 6, 0);
    nameText:SetPoint("RIGHT", button, "RIGHT", -(STAR_RESERVE + 6), 0);
    nameText:SetJustifyH("LEFT");
    nameText:SetWordWrap(false);

    local star = button:CreateTexture(nil, "OVERLAY");
    star:SetSize(14, 14);
    star:SetPoint("RIGHT", button, "RIGHT", -4, 0);
    star:SetAtlas("friends-icon-favorites");
    star:Hide();

    button.nameText = nameText;
    button.star = star;
    button:Hide();

    button:SetScript("OnClick", function(self)
        if (not self.memberName) then return; end
        if (LootCouncil.IsCouncilMember(self.memberName)) then
            LootCouncil.RosterRemove(self.memberName);
        else
            LootCouncil.RosterAdd(self.memberName);
        end
        page.RefreshGrid();
    end);

    button:SetScript("OnEnter", function(self)
        if (not self.memberName) then return; end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:AddLine(self.memberName, 1, 1, 1);

        local className = self.memberClass and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[self.memberClass];
        if (className) then
            local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[self.memberClass];
            if (color) then GameTooltip:AddLine(className, color.r, color.g, color.b);
            else GameTooltip:AddLine(className, 1, 1, 1); end
        end

        local guildName, guildRank = LootCouncilRoster.GuildInfoForUnit(self.memberUnit);
        if (guildName) then
            GameTooltip:AddLine(("%s (%s)"):format(guildName, guildRank or "?"), 0.6, 0.6, 0.6, true);
        end

        GameTooltip:AddLine(LootCouncil.IsCouncilMember(self.memberName)
            and "On the loot council" or "Not on the loot council", 0.8, 0.8, 0.8);
        GameTooltip:Show();
    end);
    button:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    return button;
end

local function buildGrid(page, gridContainer)
    local groupBoxes = {};
    local boxWidth = math.floor((page.contentWidth - (GROUP_COLUMNS - 1) * GROUP_BOX_GAP) / GROUP_COLUMNS);

    for i = 1, GROUP_COLUMNS * GROUP_ROWS do
        local row = math.floor((i - 1) / GROUP_COLUMNS);
        local col = (i - 1) % GROUP_COLUMNS;

        local box = CreateFrame("Frame", nil, gridContainer, "BackdropTemplate");
        box:SetSize(boxWidth, BOX_HEIGHT);
        box:SetPoint("TOPLEFT", gridContainer, "TOPLEFT",
            col * (boxWidth + GROUP_BOX_GAP), -row * (BOX_HEIGHT + GROUP_BOX_GAP));
        Theme.Helpers.SetFlatBackdrop(box, Colors.optionsStripBg, Colors.border, 1);

        local label = box:CreateFontString(nil, "OVERLAY");
        SetFont(label, "small");
        label:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -6);
        label:SetText(("GROUP %d"):format(i));
        label:SetTextColor(unpack(Colors.muted));

        local members = {};
        for slot = 1, MEMBER_SLOTS do
            members[slot] = buildMemberButton(box, slot, page);
        end

        groupBoxes[i] = { box = box, members = members };
    end

    return groupBoxes;
end

--------------------------------------------------------------------------
-- Refresh: pulls FL.LootCouncilRoster.BuildGroups() into the fixed grid.
--------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame");
local activePage;
local pendingRefresh = false;

local function updateFooterCount(page)
    local n = Util.tcount(LootCouncil.Roster);
    page.countText:SetText(("%d council member%s"):format(n, n == 1 and "" or "s"));

    local canSync = UnitIsGroupLeader("player") or UnitIsGroupAssistant("player");
    -- Text/backdrop recolor on enable/disable is handled by Skin.Button
    -- itself (hooked on OnEnable/OnDisable) - this just flips the state.
    if (canSync) then page.syncButton:Enable(); else page.syncButton:Disable(); end

    local groupsResult = page.lootCouncilGroupsResult;
    local canSelectOfficers = groupsResult and (groupsResult.inRaid or groupsResult.inParty);
    if (canSelectOfficers) then page.selectOfficersButton:Enable(); else page.selectOfficersButton:Disable(); end
end

local function refreshGrid(page)
    local groupsResult = LootCouncilRoster.BuildGroups();
    page.lootCouncilGroupsResult = groupsResult;

    local showGrid = groupsResult.inRaid or groupsResult.inParty;
    page.gridContainer:SetShown(showGrid);
    page.soloText:SetShown(not showGrid);
    page.soloList:SetShown(not showGrid);

    if (not showGrid) then
        local names = LootCouncil.RosterNames();
        page.soloList:SetText(#names > 0 and table.concat(names, "\n") or "(none saved)");
        updateFooterCount(page);
        FL.UI.SettingsWindow.RefreshScrollBar();
        return;
    end

    for i, groupBox in ipairs(page.groupBoxes) do
        -- A party only ever populates group 1 - every other box stays
        -- entirely hidden rather than shown-empty.
        local groupActive = groupsResult.inRaid or i == 1;
        groupBox.box:SetShown(groupActive);
        if (groupActive) then
            local members = (groupsResult.groups[i] or {}).members or {};
            for slot, button in ipairs(groupBox.members) do
                local member = members[slot];
                button:Show();
                if (member) then
                    button:EnableMouse(true);
                    button:SetAlpha(1);
                    button.memberName = member.name;
                    button.memberUnit = member.unit;
                    button.memberClass = member.classFile;

                    applyClassColor(button.nameText, member.classFile);
                    truncateToWidth(button.nameText, member.name, button:GetWidth() - STAR_RESERVE - 12);
                    setMemberButtonState(button, LootCouncil.IsCouncilMember(member.name));
                else
                    button:EnableMouse(false);
                    button:SetAlpha(0.4);
                    button.memberName = nil;
                    button.nameText:SetText("");
                    button.star:Hide();
                    Theme.Helpers.SetFlatBackdrop(button, Colors.memberBg, Colors.memberBorder, 1);
                end
            end
        end
    end

    updateFooterCount(page);
    FL.UI.SettingsWindow.RefreshScrollBar();
end

eventFrame:SetScript("OnEvent", function()
    -- Debounced, and only does real work while the page is actually on
    -- screen (checked at fire time, not just registration time - see the
    -- OnShow/OnHide comment below).
    if (not activePage or pendingRefresh) then return; end
    pendingRefresh = true;
    C_Timer.After(0.5, function()
        pendingRefresh = false;
        if (activePage and activePage.frame:IsVisible()) then refreshGrid(activePage); end
    end);
end);

--------------------------------------------------------------------------
-- Footer: council member count (left) + Clear/Select Officers/Sync to Raid
-- (right, right-to-left so Sync to Raid - the primary action - stays
-- rightmost). Built by Registry.lua into a page-owned subframe of the
-- shared footer row (see Init.lua's createFooter/RegisterPage's opts.footer)
-- rather than into the page's own scrolling frame, so it stays pinned to
-- the bottom of the content area regardless of which tab or how much grid
-- content is showing. page.countText/syncButton/selectOfficersButton are
-- read back by updateFooterCount() above on every refresh.
--------------------------------------------------------------------------

local FOOTER_BUTTON_GAP = 10;

local function buildFooter(footerFrame, page)
    local countText = footerFrame:CreateFontString(nil, "OVERLAY");
    SetFont(countText, "body");
    countText:SetTextColor(unpack(Colors.gold));
    countText:SetPoint("LEFT", footerFrame, "LEFT", 0, 0);
    page.countText = countText;

    local syncButton = Widgets.CreateFlatButton(footerFrame, "Sync to Raid", "primary");
    syncButton:SetSize(120, FL.UI.Sizes.controls.button);
    syncButton:SetPoint("RIGHT", footerFrame, "RIGHT", 0, 0);
    syncButton:SetScript("OnClick", function()
        if (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
            LootCouncil.SyncCouncilSettings();
        end
    end);
    syncButton:HookScript("OnEnter", function(self)
        if (not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player"))) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:AddLine("Only the raid leader or an assistant can sync council settings.", 1, 1, 1, true);
            GameTooltip:Show();
        end
    end);
    syncButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);
    page.syncButton = syncButton;

    local selectOfficersButton = Widgets.CreateFlatButton(footerFrame, "Select Officers");
    selectOfficersButton:SetSize(130, FL.UI.Sizes.controls.button);
    selectOfficersButton:SetPoint("RIGHT", syncButton, "LEFT", -FOOTER_BUTTON_GAP, 0);
    selectOfficersButton:SetScript("OnClick", function()
        local groupsResult = page.lootCouncilGroupsResult;
        if (not groupsResult or not (groupsResult.inRaid or groupsResult.inParty)) then return; end
        for _, name in ipairs(LootCouncilRoster.SelectOfficers(groupsResult)) do
            LootCouncil.RosterAdd(name);
        end
        page.RefreshGrid();
    end);
    selectOfficersButton:HookScript("OnEnter", function(self)
        local groupsResult = page.lootCouncilGroupsResult;
        if (not (groupsResult and (groupsResult.inRaid or groupsResult.inParty))) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:AddLine("Join a raid to select officers.", 1, 1, 1, true);
            GameTooltip:Show();
        end
    end);
    selectOfficersButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);
    page.selectOfficersButton = selectOfficersButton;

    local clearButton = Widgets.CreateFlatButton(footerFrame, "Clear");
    clearButton:SetSize(70, FL.UI.Sizes.controls.button);
    clearButton:SetPoint("RIGHT", selectOfficersButton, "LEFT", -FOOTER_BUTTON_GAP, 0);
    clearButton:SetScript("OnClick", function()
        LootCouncil.RosterClear();
        page.RefreshGrid();
    end);
end

--------------------------------------------------------------------------
-- Page assembly
--------------------------------------------------------------------------

FL.UI.SettingsWindow.RegisterPage("lootcouncil", "Loot Council", function(page)
    local header = page:Header("Loot Council", "Click a raider to add or remove them from the council.");
    local headerBottom = page.contentTop;

    local strip = buildOptionsStrip(page, headerBottom);

    local gridTop = headerBottom - STRIP_HEIGHT - 14;
    local gridContainer = CreateFrame("Frame", nil, page.frame);
    gridContainer:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, gridTop);
    gridContainer:SetPoint("TOPRIGHT", page.frame, "TOPRIGHT", 0, gridTop);

    local gridHeight = BOX_HEIGHT * GROUP_ROWS + GROUP_BOX_GAP * (GROUP_ROWS - 1);
    gridContainer:SetHeight(gridHeight);
    page.groupBoxes = buildGrid(page, gridContainer);
    page.gridContainer = gridContainer;
    page.RefreshGrid = function() refreshGrid(page); end;

    local soloText = page.frame:CreateFontString(nil, "OVERLAY");
    SetFont(soloText, "body");
    soloText:SetPoint("TOPLEFT", gridContainer, "TOPLEFT", 4, -6);
    soloText:SetText("Join a raid to pick council members");
    soloText:SetTextColor(unpack(Colors.muted));
    soloText:Hide();

    local soloList = page.frame:CreateFontString(nil, "OVERLAY");
    SetFont(soloList, "small");
    soloList:SetPoint("TOPLEFT", soloText, "BOTTOMLEFT", 0, -10);
    soloList:SetJustifyH("LEFT");
    soloList:SetTextColor(unpack(Colors.text));
    soloList:Hide();
    page.soloText = soloText;
    page.soloList = soloList;

    -- gridContainer/soloList are manually positioned (not built through
    -- page:Section()), so contentBottom() can't see them - set explicitly
    -- so Registry sizes the scrollable content to fit the grid. The
    -- Clear/Select Officers/Sync to Raid footer itself lives outside this
    -- scrollable content entirely now (see buildFooter above).
    page.contentBottomOverride = gridTop - gridHeight - 20;

    -- The event stays registered while this page is simply the current tab
    -- but the whole settings window is closed (OnHide only fires on this
    -- frame's own Hide(), not an ancestor's) - harmless, since the debounced
    -- handler above checks activePage.frame:IsVisible() before doing work.
    page.frame:SetScript("OnShow", function()
        activePage = page;
        eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE");
        page.RefreshGrid();
    end);
    page.frame:SetScript("OnHide", function()
        if (activePage == page) then activePage = nil; end
        eventFrame:UnregisterEvent("GROUP_ROSTER_UPDATE");
    end);
end, 40, { footer = buildFooter });
