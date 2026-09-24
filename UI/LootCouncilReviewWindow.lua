--[[
Council-facing "Review & Vote" window (Phase 4, read-only): the first
two-pane window in this addon - a left-hand list of every item in the
current loot council session, and a right-hand candidate table (every group
member, their response, note, and vote tally) for whichever item is
selected. Entirely gated behind LootCouncil.CanAccessReviewWindow() - a
non-council, non-initiator player has no way to open it at all.

Voting (the [+/-] column) is live: LootCouncil.ToggleVote/applyVote
(Phase 5), gated per-row on LootCouncil.CanVote (council member or the
session's own initiator) - a separate check from CanAccessReviewWindow,
which only gates whether this whole window can be opened at all. Awarding
(Phase 6) is a right-click on a candidate row - mirrors UI/RollWindow.lua's
own roll-off award rows exactly, hover-highlighted, right-click ->
StaticPopupDialogs["FOREVERLOOT_LC_AWARD_CONFIRM"] -> LootCouncil.AwardItem,
gated on LootCouncil.CurrentSession.initiatorIsMe. There is no separate
Award button, and awarding is allowed on any row at any time, including
re-awarding an already-awarded item to someone else - the currently-awarded
candidate's row stays persistently highlighted green. See
docs/LOOT_COUNCIL_PLAN.md §4(c) for the original mockup this layout is
built from (the mockup's bottom Award button was dropped in favor of the
right-click-row mechanism).
]]

local FL = ForeverLoot;
local ReviewWindow = FL.UI.LootCouncilReviewWindow;
local LootCouncil = FL.LootCouncil;
local Util = FL.Util;
local Constants = FL.Constants;

local FALLBACK_ICON = LootCouncil.FALLBACK_ICON;

-- Response id -> color, derived once from Constants.LOOT_COUNCIL_RESPONSES
-- (which only publishes an id -> label map, LOOT_COUNCIL_RESPONSE_LABELS -
-- no id -> color equivalent exists yet).
local RESPONSE_COLOR_BY_ID = {};
for _, entry in ipairs(Constants.LOOT_COUNCIL_RESPONSES) do
    RESPONSE_COLOR_BY_ID[entry.id] = entry.color;
end

-- Response id -> its index in Constants.LOOT_COUNCIL_RESPONSES, i.e. the same
-- order the response buttons are shown to raiders in
-- (UI/LootCouncilResponseWindow.lua). The candidate table sorts responses by
-- this order below. Buttons aren't user-configurable yet, so this order is
-- effectively hardcoded to match them - once a later phase lets users
-- reorder/customize the buttons, this should derive from that config instead.
local RESPONSE_ORDER_BY_ID = {};
for i, entry in ipairs(Constants.LOOT_COUNCIL_RESPONSES) do
    RESPONSE_ORDER_BY_ID[entry.id] = i;
end

-- "Approved by me" vote button color (Phase 5). Window-local, not added to
-- Core/Constants.lua, matching RESPONSE_COLOR_BY_ID's own precedent above.
-- Constants.LOOT_COUNCIL_RESPONSE_UNSELECTED_COLOR is reused as-is for the
-- "not approved by me" state.
local VOTE_APPROVED_COLOR = { 0.25, 0.70, 0.30 };

local WINDOW_WIDTH = 744; -- 620 * 1.2
local DEFAULT_HEIGHT = 360;
local MAX_HEIGHT = 700;

local LEFT_PANE_WIDTH = 160;
local PANE_GAP = 14;
local ICON_SIZE = 28;
local LEFT_ROW_HEIGHT = 36;
local MAX_ITEM_ROWS = 30;

local RIGHT_ROW_HEIGHT = 22;
local MAX_CANDIDATE_ROWS = 45; -- generous over max raid size (40)

-- Right-pane column widths, shared between the (unscrolled) header row and
-- every candidate row so they always line up.
local NAME_COL_WIDTH = 92;
local RESPONSE_COL_WIDTH = 110; -- wide enough for "Awaiting Response"
local VOTES_COL_WIDTH = 32;
local VOTE_BTN_SIZE = 18;
local COLUMN_GAP = 8;

-- Vertical layout of the right pane's fixed top block (item title, divider,
-- column header) above where its own scroll list starts - named offsets, not
-- inlined, so the block's total height and the scroll list's start position
-- can't drift out of sync with each other.
local TOP_MARGIN = 34; -- same "below the title bar" convention every window uses
local ITEM_TITLE_HEIGHT = 18;
local DIVIDER_GAP = 4;
local HEADER_ROW_HEIGHT = 14;
local HEADER_TO_LIST_GAP = 4;
local RIGHT_LIST_TOP_OFFSET = ITEM_TITLE_HEIGHT + DIVIDER_GAP + 1 + DIVIDER_GAP + HEADER_ROW_HEIGHT + HEADER_TO_LIST_GAP;

-- Bottom margin every other window's scroll frame already leaves for the
-- resize handle. No reserved award-button strip - awarding is a right-click
-- on a candidate row (Phase 6), not a separate button.
local BOTTOM_MARGIN = 12;

-- Must match the scroll frames' own TOPLEFT/BOTTOMRIGHT anchor offsets below
-- (see the comment on WINDOW_RIGHT_MARGIN in UI/LootCouncilResponseWindow.lua
-- for why this exact margin - scrollbar width/anchor plus breathing room).
local WINDOW_LEFT_MARGIN = 12;
local WINDOW_RIGHT_MARGIN = 24;

-- Key this window's saved position is stored under (see Settings.GetWindowPosition/SetWindowPosition).
local POSITION_KEY = "lootCouncilReviewWindow";

local frame, leftScrollFrame, leftScrollChild, rightScrollFrame, rightScrollChild;
local itemTitleText;
local itemRows = {};
local candidateRows = {};

-- Which item (by item.session, stable for the session's lifetime) is shown
-- in the right pane. Not reset on Show() - re-opening the window keeps
-- whatever item the council member was last looking at.
local selectedItemSession;

--- All known candidates for `item`: the union of everyone currently in the
--- group and everyone who has responded (a responder who has since left the
--- group/logged off must not disappear from review - their class was sent
--- explicitly in the response payload for exactly this reason, see
--- docs/LOOT_COUNCIL_PLAN.md §2). Responded candidates sort first, ordered by
--- response (matching the button order raiders see, see
--- RESPONSE_ORDER_BY_ID above) then alphabetically within the same response;
--- non-responders sort last, alphabetically.
local function buildCandidateList(item)
    local members = Util.groupMembers();
    local seen = {};
    local out = {};

    for name, classFile in pairs(members) do
        seen[name] = true;
        table.insert(out, { name = name, class = classFile, candidate = item.candidates[name] });
    end
    for name, candidate in pairs(item.candidates) do
        if (not seen[name]) then
            table.insert(out, { name = name, class = candidate.class, candidate = candidate });
        end
    end

    table.sort(out, function(a, b)
        local aResponded, bResponded = a.candidate ~= nil, b.candidate ~= nil;
        if (aResponded ~= bResponded) then
            return aResponded; -- responded before not-yet-responded
        end
        if (aResponded) then
            local aOrder = RESPONSE_ORDER_BY_ID[a.candidate.response] or math.huge;
            local bOrder = RESPONSE_ORDER_BY_ID[b.candidate.response] or math.huge;
            if (aOrder ~= bOrder) then
                return aOrder < bOrder;
            end
        end
        return a.name < b.name;
    end);

    return out;
end

-- Right-click-a-row confirmation before awarding - same minimal
-- StaticPopupDialogs approach UI/RollWindow.lua:69-83 uses for roll-off
-- awards, no custom frame.
StaticPopupDialogs["FOREVERLOOT_LC_AWARD_CONFIRM"] = {
    text = "Award %s to %s?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data)
        LootCouncil.AwardItem(data.itemSession, data.playerName);
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
};

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);
    frame = FL.Theme.CreateWindow("ForeverLootLootCouncilReviewWindow", WINDOW_WIDTH,
        FL.Settings.GetLootCouncilReviewWindowHeight() or DEFAULT_HEIGHT,
        savedPosition and savedPosition.x or 0, savedPosition and savedPosition.y or 0,
        function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    frame:Hide();

    local title = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.title);
    title:SetPoint("TOP", 0, -10);
    title:SetText("ForeverLoot Council - Review & Vote");

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton");
    closeButton:SetSize(20, 20);
    closeButton:SetPoint("TOPRIGHT", -4, -4);
    closeButton:SetScript("OnClick", function() frame:Hide(); end);
    FL.Theme.SkinCloseButton(closeButton);

    -- Left pane: item list -------------------------------------------------

    leftScrollFrame = FL.Theme.CreateScrollFrame(frame);
    leftScrollFrame:SetPoint("TOPLEFT", WINDOW_LEFT_MARGIN, -TOP_MARGIN);
    leftScrollFrame:SetPoint("BOTTOMLEFT", WINDOW_LEFT_MARGIN, BOTTOM_MARGIN);
    leftScrollFrame:SetWidth(LEFT_PANE_WIDTH);
    FL.Theme.SkinScrollBar(leftScrollFrame);

    local minHeight = frame:GetHeight() - leftScrollFrame:GetHeight() + LEFT_ROW_HEIGHT;

    leftScrollChild = CreateFrame("Frame", nil, leftScrollFrame);
    leftScrollChild:SetSize(leftScrollFrame:GetWidth(), MAX_ITEM_ROWS * LEFT_ROW_HEIGHT);
    leftScrollFrame:SetScrollChild(leftScrollChild);
    leftScrollFrame:SetScript("OnSizeChanged", function(self, width)
        leftScrollChild:SetWidth(width);
    end);

    for i = 1, MAX_ITEM_ROWS do
        local row = CreateFrame("Button", nil, leftScrollChild);
        row:SetPoint("TOPLEFT", 0, -(i - 1) * LEFT_ROW_HEIGHT);
        row:SetPoint("RIGHT", leftScrollChild, "RIGHT");
        row:SetHeight(LEFT_ROW_HEIGHT);
        row:RegisterForClicks("LeftButtonUp");

        local rowHighlight = row:CreateTexture(nil, "HIGHLIGHT");
        rowHighlight:SetAllPoints(row);
        rowHighlight:SetColorTexture(1, 1, 1, 0.08);
        row:SetHighlightTexture(rowHighlight);

        -- Persistent "this is the item shown in the right pane" indicator -
        -- distinct from the hover highlight above, which only lights up
        -- while the mouse is actually over the row.
        row.selectedTexture = row:CreateTexture(nil, "ARTWORK");
        row.selectedTexture:SetAllPoints(row);
        row.selectedTexture:SetColorTexture(0.53, 0.40, 1, 0.20);
        row.selectedTexture:Hide();

        row.icon = row:CreateTexture(nil, "ARTWORK", nil, 1);
        row.icon:SetSize(ICON_SIZE, ICON_SIZE);
        row.icon:SetPoint("LEFT", 4, 0);
        row.icon:SetTexCoord(0.0833, 0.9167, 0.0833, 0.9167);

        row.iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
        FL.Theme.SkinIconBorder(row.iconBorder, row.icon);

        row.itemText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
        row.itemText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0);
        row.itemText:SetPoint("RIGHT", row, "RIGHT", -4, 0);
        row.itemText:SetJustifyH("LEFT");
        row.itemText:SetWordWrap(false);

        row:SetScript("OnUpdate", function(self)
            if (self.entry and Util.IsMouseOverVisible(self.icon, leftScrollFrame)) then
                GameTooltip:SetOwner(self.icon, "ANCHOR_RIGHT");
                GameTooltip:SetHyperlink(self.entry.itemLink);
                GameTooltip:Show();
            elseif (GameTooltip:GetOwner() == self.icon) then
                GameTooltip:Hide();
            end
        end);

        row:SetScript("OnClick", function(self)
            if (not self.entry) then return; end
            -- Shift/ctrl item-link handling takes priority over selection,
            -- same convention as every other clickable icon row in this addon.
            if (Util.HandleItemLinkClick(self.entry.itemLink)) then return; end
            selectedItemSession = self.entry.session;
            ReviewWindow.Refresh();
        end);

        row:Hide();
        itemRows[i] = row;
    end

    -- Right pane: selected item's candidate table ---------------------------

    local rightPaneLeft = WINDOW_LEFT_MARGIN + LEFT_PANE_WIDTH + PANE_GAP;

    local divider = frame:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(1, 1, 1, 0.15);
    divider:SetPoint("TOPLEFT", leftScrollFrame, "TOPRIGHT", PANE_GAP / 2, 0);
    divider:SetPoint("BOTTOMLEFT", leftScrollFrame, "BOTTOMRIGHT", PANE_GAP / 2, 0);
    divider:SetWidth(1);

    itemTitleText = frame:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightLarge);
    itemTitleText:SetPoint("TOPLEFT", rightPaneLeft, -TOP_MARGIN);
    itemTitleText:SetPoint("RIGHT", -WINDOW_RIGHT_MARGIN, 0);
    itemTitleText:SetJustifyH("LEFT");
    itemTitleText:SetWordWrap(false);

    local headerDivider = frame:CreateTexture(nil, "ARTWORK");
    headerDivider:SetColorTexture(1, 1, 1, 0.15);
    headerDivider:SetPoint("TOPLEFT", rightPaneLeft, -(TOP_MARGIN + ITEM_TITLE_HEIGHT + DIVIDER_GAP));
    headerDivider:SetPoint("RIGHT", -WINDOW_RIGHT_MARGIN, 0);
    headerDivider:SetHeight(1);

    -- Column header labels share the exact same column anchors as the
    -- candidate rows below (see the row-building loop), so header text
    -- always lines up with its column regardless of window width.
    local headerRow = CreateFrame("Frame", nil, frame);
    headerRow:SetPoint("TOPLEFT", rightPaneLeft, -(TOP_MARGIN + ITEM_TITLE_HEIGHT + DIVIDER_GAP * 2 + 1));
    headerRow:SetPoint("RIGHT", -WINDOW_RIGHT_MARGIN, 0);
    headerRow:SetHeight(HEADER_ROW_HEIGHT);

    local headerVote = headerRow:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.disableSmall);
    headerVote:SetPoint("RIGHT", headerRow, "RIGHT", 0, 0);
    headerVote:SetWidth(VOTE_BTN_SIZE);
    headerVote:SetJustifyH("CENTER");
    headerVote:SetText("");

    local headerVotes = headerRow:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.disableSmall);
    headerVotes:SetPoint("RIGHT", headerVote, "LEFT", -COLUMN_GAP, 0);
    headerVotes:SetWidth(VOTES_COL_WIDTH);
    headerVotes:SetJustifyH("CENTER");
    headerVotes:SetText("Votes");

    local headerName = headerRow:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.disableSmall);
    headerName:SetPoint("LEFT", headerRow, "LEFT", 4, 0);
    headerName:SetWidth(NAME_COL_WIDTH);
    headerName:SetJustifyH("LEFT");
    headerName:SetText("Player");

    local headerResponse = headerRow:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.disableSmall);
    headerResponse:SetPoint("LEFT", headerName, "RIGHT", COLUMN_GAP, 0);
    headerResponse:SetWidth(RESPONSE_COL_WIDTH);
    headerResponse:SetJustifyH("LEFT");
    headerResponse:SetText("Response");

    local headerNote = headerRow:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.disableSmall);
    headerNote:SetPoint("LEFT", headerResponse, "RIGHT", COLUMN_GAP, 0);
    headerNote:SetPoint("RIGHT", headerVotes, "LEFT", -COLUMN_GAP, 0);
    headerNote:SetJustifyH("LEFT");
    headerNote:SetText("Note");

    rightScrollFrame = FL.Theme.CreateScrollFrame(frame);
    rightScrollFrame:SetPoint("TOPLEFT", rightPaneLeft, -(TOP_MARGIN + RIGHT_LIST_TOP_OFFSET));
    rightScrollFrame:SetPoint("BOTTOMRIGHT", -WINDOW_RIGHT_MARGIN, BOTTOM_MARGIN);
    FL.Theme.SkinScrollBar(rightScrollFrame);

    rightScrollChild = CreateFrame("Frame", nil, rightScrollFrame);
    rightScrollChild:SetSize(rightScrollFrame:GetWidth(), MAX_CANDIDATE_ROWS * RIGHT_ROW_HEIGHT);
    rightScrollFrame:SetScrollChild(rightScrollChild);
    rightScrollFrame:SetScript("OnSizeChanged", function(self, width)
        rightScrollChild:SetWidth(width);
    end);

    for i = 1, MAX_CANDIDATE_ROWS do
        local row = CreateFrame("Button", nil, rightScrollChild);
        row:SetPoint("TOPLEFT", 0, -(i - 1) * RIGHT_ROW_HEIGHT);
        row:SetPoint("RIGHT", rightScrollChild, "RIGHT");
        row:SetHeight(RIGHT_ROW_HEIGHT);
        row:RegisterForClicks("RightButtonUp");

        -- Persistent "item is currently awarded to this candidate" wash
        -- (ARTWORK layer, same convention as the left pane's own
        -- row.selectedTexture) - reuses VOTE_APPROVED_COLOR for visual
        -- consistency with the vote-approved button state.
        row.awardedTexture = row:CreateTexture(nil, "ARTWORK");
        row.awardedTexture:SetAllPoints(row);
        row.awardedTexture:SetColorTexture(VOTE_APPROVED_COLOR[1], VOTE_APPROVED_COLOR[2], VOTE_APPROVED_COLOR[3], 0.25);
        row.awardedTexture:Hide();

        -- Hover highlight (HIGHLIGHT layer, shows/hides automatically on
        -- mouseover/mouseout) - same flat-texture approach UI/RollWindow.lua
        -- uses for its own award-by-right-click roll rows.
        local rowHighlight = row:CreateTexture(nil, "HIGHLIGHT");
        rowHighlight:SetAllPoints(row);
        rowHighlight:SetColorTexture(1, 1, 1, 0.08);
        row:SetHighlightTexture(rowHighlight);

        row.voteButton = FL.Theme.CreateButton(row);
        row.voteButton:SetSize(VOTE_BTN_SIZE, VOTE_BTN_SIZE);
        row.voteButton:SetPoint("RIGHT", row, "RIGHT", 0, 0);
        row.voteButton:SetText("+");
        FL.Theme.SkinButton(row.voteButton);
        row.voteButton:Disable(); -- corrected every Refresh(); this is just the pre-first-refresh default
        row.voteButton:SetScript("OnClick", function(self)
            local parentRow = self:GetParent();
            if (not parentRow.entry or not selectedItemSession) then return; end
            LootCouncil.ToggleVote(selectedItemSession, parentRow.entry.name);
        end);

        row.votesText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
        row.votesText:SetPoint("RIGHT", row.voteButton, "LEFT", -COLUMN_GAP, 0);
        row.votesText:SetWidth(VOTES_COL_WIDTH);
        row.votesText:SetJustifyH("CENTER");

        row.nameText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
        row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0);
        row.nameText:SetWidth(NAME_COL_WIDTH);
        row.nameText:SetJustifyH("LEFT");
        row.nameText:SetWordWrap(false);

        row.responseText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
        row.responseText:SetPoint("LEFT", row.nameText, "RIGHT", COLUMN_GAP, 0);
        row.responseText:SetWidth(RESPONSE_COL_WIDTH);
        row.responseText:SetJustifyH("LEFT");
        row.responseText:SetWordWrap(false);

        row.noteText = row:CreateFontString(nil, "OVERLAY", FL.Theme.fonts.highlightSmall);
        row.noteText:SetPoint("LEFT", row.responseText, "RIGHT", COLUMN_GAP, 0);
        row.noteText:SetPoint("RIGHT", row.votesText, "LEFT", -COLUMN_GAP, 0);
        row.noteText:SetJustifyH("LEFT");
        row.noteText:SetWordWrap(false);

        -- Right-click this row to award (or re-award) the selected item to
        -- this candidate - mirrors UI/RollWindow.lua:350-361's roll-off
        -- award row exactly. row.entry is kept up to date every Refresh()
        -- below (see the candidate-row population loop).
        row:SetScript("OnClick", function(self)
            local Session = LootCouncil.CurrentSession;
            local item = Session and selectedItemSession and Session.items[selectedItemSession];
            if (not self.entry or not item) then return; end

            if (not Session.initiatorIsMe) then
                print("|cff8865ffForeverLoot|r Only the loot council session leader can award this item.");
                return;
            end

            StaticPopup_Show("FOREVERLOOT_LC_AWARD_CONFIRM", item.itemLink, self.entry.name,
                { itemSession = selectedItemSession, playerName = self.entry.name });
        end);

        row:Hide();
        candidateRows[i] = row;
    end

    FL.Theme.MakeBottomResizable(frame, WINDOW_WIDTH, minHeight, MAX_HEIGHT, function(height)
        FL.Settings.SetLootCouncilReviewWindowHeight(height);
    end);
end

function ReviewWindow.Refresh()
    if (not frame) then return; end

    local Session = LootCouncil.CurrentSession;
    local items = Session and Session.items or {};

    local myName = Util.stripRealm(Util.UnitName("player"));
    local iCanVote = LootCouncil.CanVote(myName, Util.playerFqn());

    if (not selectedItemSession or not items[selectedItemSession]) then
        selectedItemSession = items[1] and items[1].session or nil;
    end

    for i, row in ipairs(itemRows) do
        local item = items[i];
        if (item) then
            row.entry = item;
            row.icon:SetTexture(item.itemIcon or FALLBACK_ICON);
            FL.Theme.SetIconBorderQuality(row.iconBorder, item.itemQuality);
            local itemLabel = item.itemName and Util.qualityColoredItemName("[" .. item.itemName .. "]", item.itemQuality)
                or item.itemLink or "?";
            if (item.awardedTo) then
                itemLabel = itemLabel .. " |cff888888(Awarded)|r";
            end
            row.itemText:SetText(itemLabel);
            row.selectedTexture:SetShown(item.session == selectedItemSession);
            row:Show();
        else
            row.entry = nil;
            row:Hide();
        end
    end
    leftScrollChild:SetHeight(math.max(#items * LEFT_ROW_HEIGHT, 1));

    local selectedItem = selectedItemSession and items[selectedItemSession];

    if (not selectedItem) then
        itemTitleText:SetText(Session and "No items in this session." or "No active loot council session.");
        for _, row in ipairs(candidateRows) do row:Hide(); end
        rightScrollChild:SetHeight(1);
        return;
    end

    itemTitleText:SetText(selectedItem.itemName
        and Util.qualityColoredItemName("[" .. selectedItem.itemName .. "]", selectedItem.itemQuality)
        or selectedItem.itemLink or "?");

    local candidateList = buildCandidateList(selectedItem);
    for i, row in ipairs(candidateRows) do
        local entry = candidateList[i];
        if (entry) then
            row.nameText:SetText(Util.classColoredName(entry.name, entry.class));

            row.entry = entry;
            row.awardedTexture:SetShown(entry.name == selectedItem.awardedTo);

            if (entry.candidate) then
                local color = RESPONSE_COLOR_BY_ID[entry.candidate.response];
                if (color) then
                    row.responseText:SetTextColor(color[1], color[2], color[3]);
                else
                    row.responseText:SetTextColor(1, 1, 1);
                end
                row.responseText:SetText(Constants.LOOT_COUNCIL_RESPONSE_LABELS[entry.candidate.response]
                    or entry.candidate.response);
                row.noteText:SetText(entry.candidate.note or "");

                row.votesText:SetText(tostring(Util.tcount(entry.candidate.approvals)));

                if (iCanVote and not selectedItem.awardedTo) then row.voteButton:Enable(); else row.voteButton:Disable(); end
                local iApprove = entry.candidate.approvals[myName] == true;
                FL.Theme.SkinButton(row.voteButton,
                    iApprove and VOTE_APPROVED_COLOR or Constants.LOOT_COUNCIL_RESPONSE_UNSELECTED_COLOR);
                row.voteButton:Show();
            else
                row.responseText:SetTextColor(0.5, 0.5, 0.5);
                row.responseText:SetText("Awaiting Response");
                row.noteText:SetText("");
                row.votesText:SetText("-");
                row.voteButton:Hide();
            end

            row:Show();
        else
            row:Hide();
        end
    end
    rightScrollChild:SetHeight(math.max(#candidateList * RIGHT_ROW_HEIGHT, 1));
end

--- Called on every sessionStart (see applySessionStart in LootCouncil.lua) so
--- council members (and the session initiator, per CanAccessReviewWindow)
--- always land on Review & Vote as soon as a session goes out - unlike
--- ResponseWindow.MaybeAutoShow, this doesn't gate on "has an unanswered
--- item"; Show() already no-ops for anyone without access.
function ReviewWindow.MaybeAutoShow()
    ReviewWindow.Show();
end

--- Opens the window if the local player is allowed to see it at all -
--- ensureFrame() (and so the frame itself) is never even created for anyone
--- else, so there's no way to reach it, not even a briefly-flashing empty one.
function ReviewWindow.Show()
    if (not LootCouncil.CanAccessReviewWindow()) then return; end
    ensureFrame();
    frame:Show();
    ReviewWindow.Refresh();
end

function ReviewWindow.Hide()
    if (frame) then frame:Hide(); end
end

function ReviewWindow.Toggle()
    if (frame and frame:IsShown()) then
        ReviewWindow.Hide();
    else
        ReviewWindow.Show();
    end
end

function ReviewWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then FL.Theme.ResetWindowPosition(frame); end
end
