--[[
Loot Council settings page: a clickable raid-roster grid for picking council
members, plus the officer options and the Clear/Select Officers/Update
Session Council footer actions. Picks are saved locally (the saved roster) and
re-selected whenever those raiders are in the group; starting a session puts
the selected in-group members (plus the leader) on that session's council. UI only - all roster/data logic lives in LootCouncilRoster.lua
(grid data) and LootCouncil.lua (roster storage + comm), per the "keep
roster/council data logic in its own module" design.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Colors = FL.UI.Colors;
local SetFont = FL.UI.SetFont;
local Widgets = FL.UI.SettingsWidgets;
local Skin = FL.UI.Skin;
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
        { key = "lootCouncil.includeOfficers", label = "Always include guild officers",
          onChange = function() page.RefreshGrid(); end },
    };

    local prevRow;
    for _, spec in ipairs(specs) do
        local row = Widgets.BuildCheckboxRow(strip, spec);
        -- LEFT anchors also center the row vertically in the strip.
        if (prevRow) then
            row.frame:SetPoint("LEFT", prevRow.frame, "RIGHT", 24, 0);
        else
            row.frame:SetPoint("LEFT", strip, "LEFT", 14, 0);
        end

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

--- `isSelf` keeps a desaturated star on your own (otherwise plain) chip
--- while you're not on the council, so you can always find yourself;
--- selecting yourself switches it to the normal council look.
local function setMemberButtonState(button, isCouncil, isSelf)
    button.star:SetDesaturated(not isCouncil);
    button.star:SetShown(isCouncil or isSelf);
    if (isCouncil) then
        Theme.Helpers.SetFlatBackdrop(button, Colors.councilFill, Colors.councilBorder, 1);
    else
        Theme.Helpers.SetFlatBackdrop(button, Colors.memberBg, Colors.memberBorder, 1);
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
        if (not self.memberName or self.lockedOfficer) then return; end
        if (LootCouncil.IsOnSavedRoster(self.memberName)) then
            LootCouncil.RosterRemove(self.memberName);
        else
            LootCouncil.RosterAdd(self.memberName);
        end
        page.RefreshGrid();
        -- Rebuild the open tooltip so its council-status line reflects the
        -- toggle immediately instead of waiting for the next hover.
        if (GameTooltip:IsOwned(self)) then
            self:GetScript("OnEnter")(self);
        end
    end);

    button:SetScript("OnEnter", function(self)
        if (not self.memberName) then return; end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:AddLine(self.memberName, 1, 1, 1);

        local guildName, guildRank = LootCouncilRoster.GuildInfoForUnit(self.memberUnit);
        if (guildName) then
            GameTooltip:AddLine(("%s (%s)"):format(guildName, guildRank or "?"), 0.6, 0.6, 0.6, true);
        end

        if (self.lockedOfficer) then
            GameTooltip:AddLine("Selected for the loot council", 0.8, 0.8, 0.8);
            GameTooltip:AddLine("Guild officer - can't be removed while \"Always include guild officers\" is checked", 0.6, 0.6, 0.6, true);
        elseif (LootCouncil.IsOnSavedRoster(self.memberName)) then
            GameTooltip:AddLine("Selected for the loot council", 0.8, 0.8, 0.8);
        elseif (self.memberUnit and UnitIsUnit(self.memberUnit, "player")) then
            GameTooltip:AddLine("You're always on the council of a session you start", 0.8, 0.8, 0.8, true);
        else
            GameTooltip:AddLine("Not selected for the loot council", 0.8, 0.8, 0.8);
        end
        if (LootCouncil.IsSessionLive()) then
            if (LootCouncil.IsCouncilMember(self.memberName)) then
                GameTooltip:AddLine("On the running session's council", 0.53, 0.4, 1);
            else
                GameTooltip:AddLine("Not on the running session's council", 0.6, 0.6, 0.6);
            end
        end
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

--- Whether the local player can push a council update right now: only the
--- initiator of a live session.
local function canUpdateSessionCouncil()
    return LootCouncil.IsSessionLive() and LootCouncil.CurrentSession.initiatorIsMe == true;
end

local function updateFooterCount(page, selectedInGroup)
    local saved = Util.tcount(LootCouncil.Roster);
    local text = ("%d selected in group"):format(selectedInGroup or 0);
    if (saved ~= selectedInGroup) then
        text = text .. (" (%d saved)"):format(saved);
    end
    page.countText:SetText(text);

    -- Text/backdrop recolor on enable/disable is handled by Skin.Button
    -- itself (hooked on OnEnable/OnDisable) - this just flips the state.
    if (canUpdateSessionCouncil()) then page.syncButton:Enable(); else page.syncButton:Disable(); end

    local groupsResult = page.lootCouncilGroupsResult;
    local inGroup = groupsResult and (groupsResult.inRaid or groupsResult.inParty);

    -- Goes gold only while our own live session's council differs from the
    -- current in-group selection - a reminder to push it.
    local pending = LootCouncil.HasPendingCouncilUpdate();
    Skin.SetButtonVariant(page.syncButton, pending and "primary" or "default");
    page.pendingText:SetShown(pending);

    local canSelectOfficers = inGroup;
    if (canSelectOfficers) then page.selectOfficersButton:Enable(); else page.selectOfficersButton:Disable(); end
end

local refreshing = false;

local function refreshGrid(page)
    -- RosterAdd below fires the council-changed callback, which refreshes
    -- this page again - skip that nested pass.
    if (refreshing) then return; end
    refreshing = true;

    local selectedInGroup = 0;
    local groupsResult = LootCouncilRoster.BuildGroups();
    page.lootCouncilGroupsResult = groupsResult;
    local includeOfficers = FL.Settings.GetIncludeGuildOfficers();

    -- All 8 group boxes (and their 5 placeholder member slots) stay visible
    -- at all times, even solo/ungrouped - BuildGroups() always seeds group 1
    -- slot 1 with the player in that case, so there's always something real
    -- to show rather than an empty-grid or "join a raid" fallback.
    for i, groupBox in ipairs(page.groupBoxes) do
        local members = (groupsResult.groups[i] or {}).members or {};
        for slot, button in ipairs(groupBox.members) do
            local member = members[slot];
            button:Show();
            if (member) then
                button:EnableMouse(true);
                button:SetAlpha(1);
                button.memberName = member.name;
                button.memberUnit = member.unit;
                -- "Always include guild officers": own-guild officers are
                -- kept on the roster (re-added here if missing, e.g. after
                -- Clear or when they join) and can't be clicked off.
                button.lockedOfficer = includeOfficers and LootCouncilRoster.IsGuildOfficer(member.unit);
                if (button.lockedOfficer) then LootCouncil.RosterAdd(member.name); end

                applyClassColor(button.nameText, member.classFile);
                truncateToWidth(button.nameText, member.name, button:GetWidth() - STAR_RESERVE - 12);
                local selected = LootCouncil.IsOnSavedRoster(member.name);
                if (selected) then selectedInGroup = selectedInGroup + 1; end
                setMemberButtonState(button, selected,
                    member.unit ~= nil and UnitIsUnit(member.unit, "player"));
            else
                button:EnableMouse(false);
                button:SetAlpha(0.4);
                button.memberName = nil;
                button.lockedOfficer = nil;
                button.nameText:SetText("");
                button.star:Hide();
                Theme.Helpers.SetFlatBackdrop(button, Colors.memberBg, Colors.memberBorder, 1);
            end
        end
    end

    updateFooterCount(page, selectedInGroup);
    FL.UI.SettingsWindow.RefreshScrollBar();
    refreshing = false;
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
-- Footer: council member count (left) + Clear/Select Officers/Update Session Council
-- (right, right-to-left so Update Session Council - the primary action - stays
-- rightmost). Built by Registry.lua into a page-owned subframe of the
-- shared footer row (see Init.lua's createFooter/RegisterPage's opts.footer)
-- rather than into the page's own scrolling frame, so it stays pinned to
-- the bottom of the content area regardless of which tab or how much grid
-- content is showing. page.countText/pendingText/syncButton/
-- selectOfficersButton are read back by updateFooterCount() above on every
-- refresh.
--------------------------------------------------------------------------

local FOOTER_BUTTON_GAP = 10;

local function buildFooter(footerFrame, page)
    local countText = footerFrame:CreateFontString(nil, "OVERLAY");
    SetFont(countText, "body");
    countText:SetTextColor(unpack(Colors.gold));
    countText:SetPoint("LEFT", footerFrame, "LEFT", 0, 0);
    page.countText = countText;

    -- Shown only while LootCouncil.HasPendingCouncilUpdate() is true (see
    -- updateFooterCount below) - reuses the MS tag's vivid orange (rather
    -- than the paler softresMissingLabel) so it reads as distinct from the
    -- yellow-gold council-count text right next to it.
    local pendingText = footerFrame:CreateFontString(nil, "OVERLAY");
    SetFont(pendingText, "small");
    pendingText:SetTextColor(unpack(Colors.rollTags.MS.text));
    pendingText:SetPoint("LEFT", countText, "RIGHT", 10, 0);
    pendingText:SetText("Session council differs - click Update Session Council");
    pendingText:Hide();
    page.pendingText = pendingText;

    -- Starts "default" (not "primary"/gold) - it only goes gold once the
    -- selection differs from our live session's council, via
    -- updateFooterCount's Skin.SetButtonVariant call above.
    local syncButton = Widgets.CreateFlatButton(footerFrame, "Update Session Council");
    syncButton:SetSize(180, FL.UI.Sizes.controls.button);
    syncButton:SetPoint("RIGHT", footerFrame, "RIGHT", 0, 0);
    -- A disabled Button doesn't dispatch OnEnter/OnLeave at all by default
    -- (Blizzard blocks mouse-motion scripts on disabled buttons unless this
    -- is set) - without it, the "why is this disabled" tooltip below would
    -- never actually show while the button is disabled.
    syncButton:SetMotionScriptsWhileDisabled(true);
    syncButton:SetScript("OnClick", function()
        if (LootCouncil.UpdateSessionCouncil()) then
            page.RefreshGrid();
        end
    end);
    syncButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        if (canUpdateSessionCouncil()) then
            GameTooltip:AddLine("Replace the running session's council with the selected raiders in your group.", 1, 1, 1, true);
        elseif (LootCouncil.IsSessionLive()) then
            GameTooltip:AddLine("Only the session leader can change the running session's council.", 1, 1, 1, true);
        else
            GameTooltip:AddLine("Selected raiders in your group become the council when you start a session. Use this to change the council while your session is running.", 1, 1, 1, true);
        end
        GameTooltip:Show();
    end);
    syncButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);
    page.syncButton = syncButton;

    local selectOfficersButton = Widgets.CreateFlatButton(footerFrame, "Select Officers");
    selectOfficersButton:SetSize(130, FL.UI.Sizes.controls.button);
    selectOfficersButton:SetPoint("RIGHT", syncButton, "LEFT", -FOOTER_BUTTON_GAP, 0);
    selectOfficersButton:SetMotionScriptsWhileDisabled(true); -- see syncButton's own comment above
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
    local header = page:Header("Loot Council", "Click a raider to select them for the council. Selected raiders in your group join each session you start.");
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

    -- Saved roster edits elsewhere (/flc council), a session starting, or a
    -- council update all change what this page shows.
    LootCouncil.RegisterRosterChangedCallback(function()
        if (page.frame:IsVisible()) then page.RefreshGrid(); end
    end);

    -- gridContainer is manually positioned (not built through page:Section()),
    -- so contentBottom() can't see it - set explicitly so Registry sizes the
    -- scrollable content to fit the grid. The Clear/Select Officers/Update
    -- Session Council footer itself lives outside this scrollable content entirely now
    -- (see buildFooter above).
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
