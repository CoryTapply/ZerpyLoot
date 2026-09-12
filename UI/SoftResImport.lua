--[[
Paste the softres.it "Gargul Export" string here. The list of soft-reserved
players previews live as you paste (before anything is committed), then
"Import & Broadcast" commits it and sends it to the group.
]]

local ZL = ZerpyLoot;
local SoftResImport = ZL.UI.SoftResImport;
local SoftRes = ZL.SoftRes;
local Util = ZL.Util;

local MAX_PREVIEW_ROWS = 30;
local ROW_HEIGHT = 38;
local ICON_SIZE = 28;
local ICON_SPACING = 4;
local MAX_ICONS_PER_ROW = 6;
local NAME_WIDTH = 130;
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";

local frame, editBox, statusText, previewHint, previewScrollFrame, previewScrollChild;
local previewRows = {};
local hardReserveRow;

-- Key this window's saved position is stored under (see Settings.GetWindowPosition/SetWindowPosition).
local POSITION_KEY = "softResImport";

-- The preview scroll frame's original fixed height (window height minus its
-- top offset and the bottom margin reserved for the status text/buttons) -
-- now used as a cap: the frame shrinks to fit however many rows are
-- actually shown, but never grows past the space that used to be reserved
-- for it.
local PREVIEW_MAX_HEIGHT = 480 - 166 - 76;

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = ZL.Settings.GetWindowPosition(POSITION_KEY);
    frame = ZL.Theme.CreateWindow("ZerpyLootSoftResImport", 440, 480,
        savedPosition and savedPosition.x or 0, savedPosition and savedPosition.y or 0,
        function(x, y) ZL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    frame:SetFrameStrata("DIALOG");
    frame:Hide();

    local title = frame:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.title);
    title:SetPoint("TOP", 0, -10);
    title:SetText("ZerpyLoot - Import SoftRes");

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton");
    closeButton:SetSize(20, 20);
    closeButton:SetPoint("TOPRIGHT", -4, -4);
    closeButton:SetScript("OnClick", function() frame:Hide(); end);
    ZL.Theme.SkinCloseButton(closeButton);

    local hint = frame:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.disableSmall);
    hint:SetPoint("TOP", 0, -30);
    hint:SetText("Paste the softres.it 'Gargul Export' string below:");

    -- Paste box (top section). The EditBox itself has to stay borderless/
    -- transparent so it can sit inside a ScrollFrame, so the flat, dark,
    -- Cell-style input look is drawn onto a background frame behind it.
    local pasteBg = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    ZL.Theme.SkinInputBackground(pasteBg);
    pasteBg:SetPoint("TOPLEFT", 14, -48);
    pasteBg:SetPoint("TOPRIGHT", -12, -48);
    pasteBg:SetHeight(94);

    local pasteScrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate");
    pasteScrollFrame:SetPoint("TOPLEFT", pasteBg, "TOPLEFT", 6, -6);
    pasteScrollFrame:SetPoint("BOTTOMRIGHT", pasteBg, "BOTTOMRIGHT", -24, 6);
    pasteScrollFrame:SetFrameLevel(pasteBg:GetFrameLevel() + 1);
    ZL.Theme.SkinScrollBar(pasteScrollFrame);

    editBox = CreateFrame("EditBox", nil, pasteScrollFrame);
    editBox:SetMultiLine(true);
    editBox:SetFontObject(_G[ZL.Theme.fonts.input]);
    editBox:SetWidth(380);
    editBox:SetAutoFocus(false);
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);
    editBox:SetScript("OnTextChanged", function(self, isUserInput)
        SoftResImport.RefreshPreview(self:GetText());

        -- This box only exists to receive one paste - drop focus right after
        -- so the pasted text doesn't sit there still "being edited".
        if (isUserInput) then
            self:ClearFocus();
        end
    end);
    pasteScrollFrame:SetScrollChild(editBox);

    -- A multi-line EditBox's own bounds shrink to fit its (possibly empty)
    -- text, so clicking the flat panel drawn behind it - most of what's
    -- visually "the box" whenever it's short on text - would otherwise miss
    -- the actual EditBox entirely. Forward clicks anywhere in the panel to
    -- it, same as Cell's own scrollable edit boxes do.
    pasteBg:EnableMouse(true);
    pasteBg:SetScript("OnMouseDown", function() editBox:SetFocus(); end);
    pasteScrollFrame:SetScript("OnMouseDown", function() editBox:SetFocus(); end);

    -- Preview section (middle - fills the remaining space)
    local previewLabel = frame:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.normalSmall);
    previewLabel:SetPoint("TOPLEFT", 16, -148);
    previewLabel:SetText("Preview:");

    previewHint = frame:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.disableSmall);
    previewHint:SetPoint("TOPLEFT", 16, -166);
    previewHint:SetText("Paste a valid export above to preview its reservations here.");

    previewScrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate");
    previewScrollFrame:SetPoint("TOPLEFT", 16, -166);
    previewScrollFrame:SetPoint("TOPRIGHT", -34, -166);
    previewScrollFrame:SetHeight(PREVIEW_MAX_HEIGHT);
    ZL.Theme.SkinScrollBar(previewScrollFrame);

    -- Width tracks the scroll frame's own visible width (same trick
    -- RollWindow's and TradeQueueWindow's row lists use) so rows always
    -- reach full-width to the scrollbar's edge, with no gap and no overlap.
    previewScrollChild = CreateFrame("Frame", nil, previewScrollFrame);
    previewScrollChild:SetSize(previewScrollFrame:GetWidth(), MAX_PREVIEW_ROWS * ROW_HEIGHT);
    previewScrollFrame:SetScrollChild(previewScrollChild);
    previewScrollFrame:SetScript("OnSizeChanged", function(self, width)
        previewScrollChild:SetWidth(width);
    end);

    -- Builds one preview row (name/label text + a strip of item icons +
    -- overflow text). Shared by the pinned Hard Reserves summary row and the
    -- per-player soft-reserve rows below it - the vertical TOPLEFT offset is
    -- left for the caller/refresh to set since it depends on whether the
    -- Hard Reserves row is shown.
    local function createPreviewRow()
        local row = CreateFrame("Button", nil, previewScrollChild);
        row:SetPoint("RIGHT", previewScrollChild, "RIGHT");
        row:SetHeight(ROW_HEIGHT);

        -- Flat translucent row-wide highlight (same trick as RollWindow's
        -- and TradeQueueWindow's row lists).
        local rowHighlight = row:CreateTexture(nil, "HIGHLIGHT");
        rowHighlight:SetAllPoints(row);
        rowHighlight:SetColorTexture(1, 1, 1, 0.08);
        row:SetHighlightTexture(rowHighlight);

        row.text = row:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.highlightMedium);
        row.text:SetPoint("LEFT", 4, 0);
        row.text:SetWidth(NAME_WIDTH);
        row.text:SetJustifyH("LEFT");

        row.icons = {};
        for j = 1, MAX_ICONS_PER_ROW do
            local iconButton = CreateFrame("Button", nil, row);
            iconButton:SetSize(ICON_SIZE, ICON_SIZE);
            if (j == 1) then
                iconButton:SetPoint("LEFT", row.text, "RIGHT", 6, 0);
            else
                iconButton:SetPoint("LEFT", row.icons[j - 1], "RIGHT", ICON_SPACING, 0);
            end

            iconButton.texture = iconButton:CreateTexture(nil, "ARTWORK");
            iconButton.texture:SetAllPoints(iconButton);
            -- Crop ~1/12 off each edge (~20% zoom) to trim the icon art's own
            -- padding (same crop RollWindow's/TradeQueueWindow's icons use).
            iconButton.texture:SetTexCoord(0.0833, 0.9167, 0.0833, 0.9167);

            -- Border drawn on a separate wrapper frame pulled 1px outside the
            -- icon's own bounds (same trick as RollWindow's/TradeQueueWindow's
            -- iconBorder) so it doesn't get painted over by the icon's own
            -- ARTWORK-layer texture.
            local iconBorder = CreateFrame("Frame", nil, iconButton, "BackdropTemplate");
            iconBorder:SetPoint("TOPLEFT", iconButton, "TOPLEFT", -1, 1);
            iconBorder:SetPoint("BOTTOMRIGHT", iconButton, "BOTTOMRIGHT", 1, -1);
            ZL.Theme.SkinBorder(iconBorder);

            iconButton:SetScript("OnEnter", function(self)
                if (not self.itemID) then return; end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
                GameTooltip:SetHyperlink("item:" .. self.itemID);
                GameTooltip:Show();
            end);
            iconButton:SetScript("OnLeave", function() GameTooltip:Hide(); end);

            -- Shift-click to chat-link the item, ctrl-click to dress it up
            -- (shared with RollWindow's and TradeQueueWindow's icons via
            -- Util). Only itemID is tracked here, not a full link, but by
            -- the time a click happens the item's data is virtually always
            -- already cached (hovering to see the tooltip above triggers
            -- the load), so GetItemInfo's link is reliably available.
            iconButton:RegisterForClicks("LeftButtonUp");
            iconButton:SetScript("OnClick", function(self)
                if (not self.itemID) then return; end
                Util.HandleItemLinkClick(select(2, GetItemInfo(self.itemID)));
            end);

            iconButton:Hide();
            row.icons[j] = iconButton;
        end

        row.overflowText = row:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.disableSmall);
        row.overflowText:SetPoint("LEFT", row.icons[MAX_ICONS_PER_ROW], "RIGHT", 4, 0);
        row.overflowText:Hide();

        row:Hide();
        return row;
    end

    hardReserveRow = createPreviewRow();
    hardReserveRow.text:SetTextColor(1, 0, 0);

    for i = 1, MAX_PREVIEW_ROWS do
        previewRows[i] = createPreviewRow();
    end

    statusText = frame:CreateFontString(nil, "OVERLAY", ZL.Theme.fonts.highlightSmall);
    statusText:SetPoint("BOTTOM", 0, 46);
    statusText:SetWidth(400);

    local importButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate");
    importButton:SetSize(150, 22);
    importButton:SetPoint("BOTTOMLEFT", 20, 14);
    importButton:SetText("Import & Broadcast");
    importButton:SetScript("OnClick", function()
        editBox:ClearFocus();
        local ok, err = SoftRes.Import(editBox:GetText());
        if (ok) then
            statusText:SetText(("|cff33ff33Imported and broadcast: %d player entries, %d hard reserves.|r"):format(
                #(SoftRes.MetaData.SoftReserves or {}), #(SoftRes.MetaData.HardReserves or {})
            ));
        else
            statusText:SetText("|cffff4444" .. tostring(err) .. "|r");
        end
    end);
    ZL.Theme.SkinButton(importButton);

    local reportMissingButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate");
    reportMissingButton:SetSize(130, 22);
    reportMissingButton:SetPoint("LEFT", importButton, "RIGHT", 10, 0);
    reportMissingButton:SetText("Report Missing");
    reportMissingButton:SetScript("OnClick", function()
        editBox:ClearFocus();
        local ok, missing = SoftRes.PostMissingSoftReserves();
        if (not ok) then
            statusText:SetText("|cffff4444No SoftRes data imported yet.|r");
        elseif (#missing == 0) then
            statusText:SetText("|cff33ff33Everyone has a soft-reserve registered.|r");
        else
            statusText:SetText(("|cffffcc00Missing soft-reserves from: %s|r"):format(table.concat(missing, ", ")));
        end
    end);
    ZL.Theme.SkinButton(reportMissingButton);

    local clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate");
    clearButton:SetSize(70, 22);
    clearButton:SetPoint("LEFT", reportMissingButton, "RIGHT", 10, 0);
    clearButton:SetText("Clear");
    clearButton:SetScript("OnClick", function()
        editBox:SetText("");
        editBox:ClearFocus();
        SoftRes.Clear();
        statusText:SetText("|cff33ff33SoftRes data cleared - tooltips will no longer show reservations.|r");
    end);
    ZL.Theme.SkinButton(clearButton);
end

-- Shared by RefreshPreview's empty/error states and by SyncExternalImport
-- (which needs to blank the preview if a broadcast arrives with no usable
-- data, even though the paste box itself was never touched).
local function clearPreview(hintText)
    previewHint:Show();
    previewHint:SetText(hintText);
    hardReserveRow:Hide();
    for _, row in pairs(previewRows) do row:Hide(); end
    previewScrollFrame:SetHeight(0);
    previewScrollChild:SetHeight(0);
end

-- Renders a parsed {SoftReserves, HardReserves} result (from SoftRes.Parse
-- or, for a live broadcast, straight off SoftRes.MetaData) as the scrollable
-- preview list. Split out from RefreshPreview so SyncExternalImport can
-- render the currently-active import without needing its raw string sitting
-- in the paste box.
local function renderPreview(result)
    previewHint:Hide();

    -- Hard Reserves get one pinned summary row above the soft-reserve list -
    -- red "Hard Reserves" label plus one icon per hard-reserved item (unlike
    -- soft-reserve rows, each hardreserves entry is already a single item).
    local hardReserves = result.HardReserves or {};
    local rowOffset = 0;
    if (#hardReserves > 0) then
        hardReserveRow:SetPoint("TOPLEFT", 0, 0);
        hardReserveRow.text:SetText("Hard Reserves");

        local overflow = #hardReserves - MAX_ICONS_PER_ROW;
        for j, iconButton in ipairs(hardReserveRow.icons) do
            local entry = hardReserves[j];
            if (entry) then
                iconButton.itemID = entry.id;
                iconButton.texture:SetTexture(GetItemIcon(entry.id) or FALLBACK_ICON);
                iconButton:Show();
            else
                iconButton.itemID = nil;
                iconButton:Hide();
            end
        end

        if (overflow > 0) then
            hardReserveRow.overflowText:SetText(("+%d more"):format(overflow));
            hardReserveRow.overflowText:Show();
        else
            hardReserveRow.overflowText:Hide();
        end

        hardReserveRow:Show();
        rowOffset = 1;
    else
        hardReserveRow:Hide();
    end

    -- The scroll child is sized to exactly the rows actually shown (not the
    -- fixed MAX_PREVIEW_ROWS capacity) so the scroll range - and therefore
    -- whether the scrollbar shows at all - reflects real content, while the
    -- visible frame itself is capped so it never grows past the space
    -- reserved for it.
    local rowCount = math.min(#(result.SoftReserves or {}), MAX_PREVIEW_ROWS);
    local totalRows = rowCount + rowOffset;
    previewScrollChild:SetHeight(totalRows * ROW_HEIGHT);
    previewScrollFrame:SetHeight(math.min(totalRows * ROW_HEIGHT, PREVIEW_MAX_HEIGHT));

    for i, row in pairs(previewRows) do
        local entry = result.SoftReserves[i];
        if (entry) then
            row:SetPoint("TOPLEFT", 0, -(rowOffset + i - 1) * ROW_HEIGHT);

            local classToken = Util.classNameToToken(entry.class);
            local name = Util.classColoredName(entry.name, classToken);
            if (entry.note and entry.note ~= "") then
                name = name .. ("  |cffaaaaaa%s|r"):format(entry.note);
            end
            row.text:SetText(name);

            -- One icon per reserved item - entry.Items already repeats an
            -- itemID once per reservation, so a player who soft-reserved the
            -- same item twice gets that icon shown twice, not deduplicated.
            -- Tooltip on hover; a plain item link ("item:<id>") is enough for
            -- SetHyperlink to look up name/icon/tooltip text even without
            -- full enchant/gem data.
            local itemIDs = entry.Items;
            local overflow = #itemIDs - MAX_ICONS_PER_ROW;
            for j, iconButton in ipairs(row.icons) do
                local itemID = itemIDs[j];
                if (itemID) then
                    iconButton.itemID = itemID;
                    iconButton.texture:SetTexture(GetItemIcon(itemID) or FALLBACK_ICON);
                    iconButton:Show();
                else
                    iconButton.itemID = nil;
                    iconButton:Hide();
                end
            end

            if (overflow > 0) then
                row.overflowText:SetText(("+%d more"):format(overflow));
                row.overflowText:Show();
            else
                row.overflowText:Hide();
            end

            row:Show();
        else
            row:Hide();
        end
    end
end

-- Parses (without committing) whatever is currently in the paste box and
-- renders the resulting soft-reserve entries as a scrollable list, so the
-- user can see what they're about to import/broadcast before doing either.
function SoftResImport.RefreshPreview(text)
    if (not previewScrollChild) then return; end

    if (type(text) ~= "string" or text == "") then
        clearPreview("Paste a valid export above to preview its reservations here.");
        return;
    end

    local ok, result = SoftRes.Parse(text);
    if (not ok) then
        clearPreview("|cffff4444" .. tostring(result) .. "|r");
        return;
    end

    renderPreview(result);
end

-- Called after another player's SoftRes import lands via broadcast
-- (Comm.Actions[broadcastSoftRes] in SoftRes.lua). Only touches the window
-- if it's already been created this session - nothing to sync into a window
-- nobody has opened yet.
--
-- The paste box is cleared rather than repopulated with the new raw string:
-- whatever was sitting there (typed, or left over from a previous session)
-- no longer describes what's active now that someone else's import replaced
-- it, so showing it would be misleading. The preview list is still updated,
-- rendered straight from SoftRes.MetaData rather than by re-parsing the
-- (now-empty) box.
function SoftResImport.SyncExternalImport()
    if (not frame) then return; end

    editBox:SetText("");
    editBox:ClearFocus();

    if (SoftRes.MetaData) then
        renderPreview(SoftRes.MetaData);
        statusText:SetText(("|cff33ff33Updated - received new SoftRes data (%d player entries, %d hard reserves).|r"):format(
            #(SoftRes.MetaData.SoftReserves or {}), #(SoftRes.MetaData.HardReserves or {})
        ));
    else
        clearPreview("Paste a valid export above to preview its reservations here.");
    end
end

function SoftResImport.Show()
    ensureFrame();
    frame:Show();

    -- If nothing's been pasted into this box yet but data is already loaded
    -- (e.g. reloaded from the DB at login), show it rather than an empty box.
    if (editBox:GetText() == "" and SoftRes.ImportString) then
        editBox:SetText(SoftRes.ImportString);
    end

    SoftResImport.RefreshPreview(editBox:GetText());
end

function SoftResImport.Hide()
    if (frame) then frame:Hide(); end
end

function SoftResImport.Toggle()
    ensureFrame();
    if (frame:IsShown()) then SoftResImport.Hide(); else SoftResImport.Show(); end
end

function SoftResImport.ResetPosition()
    ZL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then ZL.Theme.ResetWindowPosition(frame); end
end
