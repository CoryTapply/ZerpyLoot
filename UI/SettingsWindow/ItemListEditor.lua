--[[
Shared "item list editor" widget - a header+count, a dashed add box + Add
button (Shift-click / drag-drop / typed ID), a scrolling pooled-row list
(icon + quality-colored name + optional quest tag + right-aligned ID +
optional per-row extra widget + remove button), and a status line below.

Extracted from UI/SettingsWindow/Pages/LootRolls.lua's original hand-built
"Also print these items" widget (Loot Chat section) so the same visuals/
behavior can be reused by the Automatic Rolls section's "Always roll on
these items" list - every string/check/animation below is unchanged from
that original, just parameterized through `opts` instead of hardcoded.

What's shared (never overridable): the "Enter an item ID..."/"No item with
ID %d." messages, row visuals (icon/quality border/quest pill/ID), tooltip-
on-hover, Shift-click/drag-drop wiring, and the scrolling list chrome
(Skin.ScrollBar + smooth scroll).

What's caller-supplied (see the opts doc on Create below): the data source,
add-validation policy (LootChat blocks Uncommon+; Automatic Rolls doesn't),
status wording, header-count formatting, and an optional per-row "extra"
widget slot (Automatic Rolls' rule dropdown).
]]

local FL = ForeverLoot;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Theme = FL.Theme;
local Util = FL.Util;

local ItemListEditor = {};
FL.UI.ItemListEditor = ItemListEditor;

local FALLBACK_ICON = 134400; -- INV_Misc_QuestionMark

local STATUS_KIND_COLOR = {
    error = Colors.sessionDeleteHoverIcon,
    success = Colors.respondSentLabel,
    info = Colors.description,
};

local function defaultIsEnabled() return true; end
local function defaultFormatAlreadyListed(name) return name .. " is already on the list."; end

--- opts:
---   width               (number, required) - column width.
---   headerLabel         (string)
---   addPlaceholder      (string, default "Drag an item here or type an ID")
---   emptyText           (string)
---   rowIconSize         (number, default Sizes.itemListEditor.rowIconSize)
---   extraSlotWidth      (number, default 0 - no extra per-row widget)
---   visibleRows         (number, default Sizes.itemListEditor.visibleRows)
---
---   GetItems()               -> ordered array of itemIDs (editor never sorts)
---   IsAlreadyListed(itemID)  -> bool
---   ValidateAdd(itemID, name, quality) -> ok, statusKind, statusText
---                        (consulted only after the shared existence +
---                        already-listed checks pass; statusKind/Text only
---                        used when ok is false)
---   AddItem(itemID)          -> persists a new entry
---   RemoveItem(itemID)       -> removes an entry
---   FormatAddedStatus(name, itemID) -> string (success message)
---   FormatRemovedStatus(name, itemID) -> string (info message)
---   FormatAlreadyListedStatus(name, itemID) -> string (info message,
---                        default "<name> is already on the list.")
---   GetHeaderCountText(items) -> string
---   IsEnabled()          -> bool, default always true (drives whole-widget
---                        dim + Add/remove disable)
---   CreateRowExtra(row, extraSlotFrame) -> called once per pooled row when
---                        it's first built, to mount an extra per-row widget
---                        into the reserved slot frame (already positioned/
---                        sized) between "ID n" and the remove button.
---   PaintRowExtra(row, itemID) -> called every repaint, after row.itemID is
---                        set, to refresh the extra widget for its new item.
---
--- Returns: { frame, Refresh(), SetStatus(kind, text) }
function ItemListEditor.Create(parent, opts)
    local LC = Sizes.itemListEditor;
    local rowIconSize = opts.rowIconSize or LC.rowIconSize;
    local visibleRows = opts.visibleRows or LC.visibleRows;
    local extraSlotWidth = opts.extraSlotWidth or 0;
    local isEnabled = opts.IsEnabled or defaultIsEnabled;
    local formatAlreadyListed = opts.FormatAlreadyListedStatus or defaultFormatAlreadyListed;

    local editor = {};

    local frame = CreateFrame("Frame", nil, parent);
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0);
    frame:SetWidth(opts.width);
    editor.frame = frame;

    ----------------------------------------------------------------------
    -- Header row: label + count.
    ----------------------------------------------------------------------

    local headerLabel = frame:CreateFontString(nil, "OVERLAY");
    SetFont(headerLabel, "body");
    headerLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    headerLabel:SetText(opts.headerLabel or "");
    headerLabel:SetTextColor(unpack(Colors.text));

    local headerCount = frame:CreateFontString(nil, "OVERLAY");
    SetFont(headerCount, "small");
    headerCount:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
    headerCount:SetTextColor(unpack(Colors.muted));

    ----------------------------------------------------------------------
    -- Add row: dashed EditBox + gold "Add" button.
    ----------------------------------------------------------------------

    local addRow = CreateFrame("Frame", nil, frame);
    addRow:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(LC.headerHeight + LC.addRowGap));
    addRow:SetPoint("RIGHT", frame, "RIGHT", 0, 0);
    addRow:SetHeight(LC.addRowHeight);

    local addButton = FL.UI.SettingsWidgets.CreateFlatButton(addRow, "Add", "primary");
    addButton:SetSize(LC.addButtonWidth, LC.addRowHeight);
    addButton:SetPoint("RIGHT", addRow, "RIGHT", 0, 0);

    local addBox = CreateFrame("EditBox", nil, addRow, "BackdropTemplate");
    addBox:SetAutoFocus(false);
    addBox:SetPoint("TOPLEFT", addRow, "TOPLEFT", 0, 0);
    addBox:SetPoint("RIGHT", addButton, "LEFT", -LC.rowPadX, 0);
    addBox:SetHeight(LC.addRowHeight);
    SetFont(addBox, "body");
    addBox:SetTextColor(unpack(Colors.textBright));
    addBox:SetTextInsets(6, 6, 0, 0);
    Theme.Helpers.SetFlatBackdrop(addBox, Colors.controlBg, Colors.transparent, 1);
    Skin.DashedBorder(addBox, Colors.checkboxBorder[1], Colors.checkboxBorder[2], Colors.checkboxBorder[3], 1, 4, 1);
    addBox:SetScript("OnEditFocusGained", function(self) self:SetDashColor(unpack(Colors.primaryBorder)); end);
    addBox:SetScript("OnEditFocusLost", function(self) self:SetDashColor(unpack(Colors.checkboxBorder)); end);

    local addPlaceholder = addBox:CreateFontString(nil, "OVERLAY");
    SetFont(addPlaceholder, "body");
    addPlaceholder:SetPoint("LEFT", addBox, "LEFT", 6, 0);
    addPlaceholder:SetPoint("RIGHT", addBox, "RIGHT", -6, 0);
    addPlaceholder:SetJustifyH("LEFT");
    addPlaceholder:SetWordWrap(false);
    addPlaceholder:SetText(opts.addPlaceholder or "Drag an item here or type an ID");
    addPlaceholder:SetTextColor(unpack(Colors.controlHover));

    local function updateAddPlaceholder()
        addPlaceholder:SetShown(addBox:GetText() == "");
    end
    addBox:HookScript("OnTextChanged", updateAddPlaceholder);
    updateAddPlaceholder();

    ----------------------------------------------------------------------
    -- List box: fixed height for visibleRows, then the slim scrollbar.
    ----------------------------------------------------------------------

    local listBox = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    listBox:SetPoint("TOPLEFT", addRow, "BOTTOMLEFT", 0, -LC.addRowGap);
    listBox:SetPoint("RIGHT", frame, "RIGHT", 0, 0);
    listBox:SetHeight(visibleRows * LC.rowHeight + (visibleRows - 1) * LC.rowSpacing + LC.listPadding * 2);
    Theme.Helpers.SetFlatBackdrop(listBox, Colors.sessionListBg, Colors.memberBorder, 1);
    listBox:EnableMouse(true);

    local scrollbarSpace = Sizes.layout.scrollbarWidth + Sizes.layout.scrollbarInset + 4;
    local listScroll = CreateFrame("ScrollFrame", nil, listBox, "UIPanelScrollFrameTemplate");
    listScroll:SetPoint("TOPLEFT", listBox, "TOPLEFT", LC.listPadding, -LC.listPadding);
    listScroll:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -scrollbarSpace, LC.listPadding);

    local listScrollChild = CreateFrame("Frame", nil, listScroll);
    listScrollChild:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0);
    listScroll:SetScrollChild(listScrollChild);
    listScroll:SetScript("OnSizeChanged", function(self, width) listScrollChild:SetWidth(width); end);

    local listScrollBar = Skin.ScrollBar(listScroll);
    if (listScrollBar) then
        listScrollBar:ClearAllPoints();
        listScrollBar:SetPoint("TOP", listScroll, "TOP", 0, 0);
        listScrollBar:SetPoint("BOTTOM", listScroll, "BOTTOM", 0, 0);
        listScrollBar:SetPoint("RIGHT", listBox, "RIGHT", -Sizes.layout.scrollbarInset, 0);
    end
    Theme.Helpers.EnableSmoothScroll(listScroll, { step = LC.rowHeight + LC.rowSpacing });

    local emptyText = listBox:CreateFontString(nil, "OVERLAY");
    SetFont(emptyText, "small");
    emptyText:SetPoint("LEFT", listBox, "LEFT", 10, 0);
    emptyText:SetPoint("RIGHT", listBox, "RIGHT", -10, 0);
    emptyText:SetJustifyH("CENTER");
    emptyText:SetWordWrap(true);
    emptyText:SetText(opts.emptyText or "");
    emptyText:SetTextColor(unpack(Colors.disabledText));
    emptyText:Hide();

    ----------------------------------------------------------------------
    -- Status line, below the list, hidden when empty.
    ----------------------------------------------------------------------

    local statusText = frame:CreateFontString(nil, "OVERLAY");
    SetFont(statusText, "small");
    statusText:SetPoint("TOPLEFT", listBox, "BOTTOMLEFT", 0, -LC.statusGap);
    statusText:SetPoint("RIGHT", frame, "RIGHT", 0, 0);
    statusText:SetHeight(LC.statusHeight);
    statusText:SetJustifyH("LEFT");
    statusText:SetWordWrap(false);
    statusText:SetText("");

    function editor:SetStatus(kind, text)
        local color = STATUS_KIND_COLOR[kind] or Colors.description;
        statusText:SetText(text or "");
        statusText:SetTextColor(unpack(color));
    end
    addBox:HookScript("OnTextChanged", function() editor:SetStatus(nil); end);

    frame:SetHeight(LC.headerHeight + LC.addRowGap + LC.addRowHeight + LC.addRowGap
        + listBox:GetHeight() + LC.statusGap + LC.statusHeight);

    ----------------------------------------------------------------------
    -- Item row pool
    ----------------------------------------------------------------------

    local rows = {};

    local function paintRowName(row, name, quality)
        row.nameText:SetText(name);
        local r, g, b = Util.GetItemQualityColor(quality);
        row.nameText:SetTextColor(r or 1, g or 1, b or 1);
        row.iconBorder:SetBackdropBorderColor(r or 0, g or 0, b or 0, 1);
    end

    local function paintItemRow(row, itemID)
        row.itemID = itemID;

        local _, _, _, _, icon, classID = C_Item.GetItemInfoInstant(itemID);
        row.icon:SetTexture(icon or FALLBACK_ICON);

        local isQuestItem = (classID == Enum.ItemClass.Questitem);
        row.questTag:SetShown(isQuestItem);

        row.idText:SetText("ID " .. itemID);

        row.nameText:ClearAllPoints();
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", LC.rowPadX, 0);
        if (isQuestItem) then
            row.nameText:SetPoint("RIGHT", row.questTag, "LEFT", -LC.rowPadX, 0);
        else
            row.nameText:SetPoint("RIGHT", row.idText, "LEFT", -LC.rowPadX, 0);
        end

        local name, _, quality = Util.GetItemInfo(itemID);
        if (name) then
            paintRowName(row, name, quality);
        else
            row.nameText:SetText("Loading\226\128\166");
            row.nameText:SetTextColor(unpack(Colors.muted));
            row.iconBorder:SetBackdropBorderColor(0, 0, 0, 0);
            Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
                if (row.itemID == itemID) then
                    local n, _, q = Util.GetItemInfo(itemID);
                    if (n) then paintRowName(row, n, q); end
                end
            end);
        end

        if (opts.PaintRowExtra) then opts.PaintRowExtra(row, itemID); end
    end

    local function createItemRow(scrollParent, index)
        local row = CreateFrame("Frame", nil, scrollParent, "BackdropTemplate");
        row:SetPoint("TOPLEFT", scrollParent, "TOPLEFT", 0, -(index - 1) * (LC.rowHeight + LC.rowSpacing));
        row:SetPoint("RIGHT", scrollParent, "RIGHT", 0, 0);
        row:SetHeight(LC.rowHeight);
        row:EnableMouse(true);
        Theme.Helpers.SetFlatBackdrop(row, Colors.memberBg, Colors.memberBorder, 1);
        row:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(Colors.checkboxBorder)); end);
        row:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(Colors.memberBorder)); end);

        row.icon = row:CreateTexture(nil, "ARTWORK");
        row.icon:SetSize(rowIconSize, rowIconSize);
        row.icon:SetPoint("LEFT", row, "LEFT", LC.rowPadX, 0);
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92);

        row.iconBorder = CreateFrame("Frame", nil, row, "BackdropTemplate");
        row.iconBorder:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -1, 1);
        row.iconBorder:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1);
        Theme.Helpers.SetFlatBackdrop(row.iconBorder, nil, Colors.muted, 1);

        row.removeButton = CreateFrame("Button", nil, row, "BackdropTemplate");
        row.removeButton:SetSize(LC.rowRemoveSize, LC.rowRemoveSize);
        row.removeButton:SetPoint("RIGHT", row, "RIGHT", -LC.rowPadX, 0);
        row.removeButton:RegisterForClicks("LeftButtonUp");

        row.removeButton.icon = row.removeButton:CreateTexture(nil, "ARTWORK");
        local removeIconSize = math.floor(LC.rowRemoveSize * 0.7 + 0.5);
        row.removeButton.icon:SetSize(removeIconSize, removeIconSize);
        row.removeButton.icon:SetPoint("CENTER");
        row.removeButton.icon:SetTexture("Interface\\AddOns\\ForeverLoot\\Media\\Icons\\trash.tga");

        local function paintRemoveDefault()
            Theme.Helpers.SetFlatBackdrop(row.removeButton, Colors.transparent, Colors.transparent, 1);
            row.removeButton.icon:SetVertexColor(unpack(Colors.muted));
        end
        local function paintRemoveHover()
            if (not row.removeButton:IsEnabled()) then return; end
            Theme.Helpers.SetFlatBackdrop(row.removeButton, Colors.sessionDeleteHoverBg, Colors.skinCloseBorder, 1);
            row.removeButton.icon:SetVertexColor(unpack(Colors.sessionDeleteHoverIcon));
        end
        paintRemoveDefault();
        row.removeButton:HookScript("OnEnter", paintRemoveHover);
        row.removeButton:HookScript("OnLeave", paintRemoveDefault);
        row.removeButton:SetScript("OnClick", function()
            if (not row.itemID) then return; end
            local name = Util.GetItemInfo(row.itemID) or ("item " .. row.itemID);
            local itemID = row.itemID;
            opts.RemoveItem(itemID);
            editor:SetStatus("info", (opts.FormatRemovedStatus or function(n) return "Removed " .. n .. "."; end)(name, itemID));
            editor:Refresh();
        end);

        -- Optional per-row extra widget slot (e.g. Automatic Rolls' rule
        -- dropdown), reserved between "ID n" and the remove button.
        local extraAnchor = row.removeButton;
        if (extraSlotWidth > 0) then
            row.extraSlot = CreateFrame("Frame", nil, row);
            row.extraSlot:SetSize(extraSlotWidth, LC.rowHeight);
            row.extraSlot:SetPoint("RIGHT", row.removeButton, "LEFT", -LC.rowPadX, 0);
            if (opts.CreateRowExtra) then opts.CreateRowExtra(row, row.extraSlot); end
            extraAnchor = row.extraSlot;
        end

        row.idText = row:CreateFontString(nil, "OVERLAY");
        SetFont(row.idText, "small");
        row.idText:SetPoint("RIGHT", extraAnchor, "LEFT", -LC.rowPadX, 0);
        row.idText:SetWidth(50);
        row.idText:SetJustifyH("RIGHT");
        row.idText:SetWordWrap(false);
        row.idText:SetTextColor(unpack(Colors.muted));

        row.questTag = CreateFrame("Frame", nil, row);
        row.questTag:SetPoint("RIGHT", row.idText, "LEFT", -LC.rowPadX, 0);
        row.questTag:SetHeight(LC.tagHeight);
        Skin.Pill(row.questTag);
        row.questTag:SetPillFillColor(unpack(Colors.defaultBg));
        row.questTag:SetPillColor(unpack(Colors.lootChatQuestTag));
        row.questTag.text = row.questTag:CreateFontString(nil, "OVERLAY");
        SetFont(row.questTag.text, "small");
        row.questTag.text:SetText("QUEST");
        row.questTag.text:SetTextColor(unpack(Colors.lootChatQuestTag));
        row.questTag.text:SetPoint("LEFT", row.questTag, "LEFT", LC.tagPadX, 0);
        row.questTag.text:SetPoint("RIGHT", row.questTag, "RIGHT", -LC.tagPadX, 0);
        row.questTag:SetWidth(row.questTag.text:GetStringWidth() + LC.tagPadX * 2);
        row.questTag:Hide();

        row.nameText = row:CreateFontString(nil, "OVERLAY");
        SetFont(row.nameText, "small");
        row.nameText:SetJustifyH("LEFT");
        row.nameText:SetWordWrap(false);

        row:SetScript("OnUpdate", function(self)
            if (self.itemID and Util.IsMouseOverVisible(self.icon, listScroll)) then
                GameTooltip:SetOwner(self.icon, "ANCHOR_RIGHT");
                GameTooltip:SetItemByID(self.itemID);
                GameTooltip:Show();
            elseif (GameTooltip:GetOwner() == self.icon) then
                GameTooltip:Hide();
            end
        end);

        row:Hide();
        return row;
    end

    local function ensureRowCount(n)
        for i = #rows + 1, n do
            rows[i] = createItemRow(listScrollChild, i);
        end
    end

    ----------------------------------------------------------------------
    -- Refresh
    ----------------------------------------------------------------------

    function editor:Refresh()
        local ids = opts.GetItems();
        ensureRowCount(#ids);

        -- The ScrollFrame clips to (and computes its scroll range from) the
        -- scroll child's own declared size, not just its own viewport - the
        -- child needs its height kept in sync with the real row count or
        -- content beyond a stale/zero height never renders.
        listScrollChild:SetHeight(math.max(#ids * LC.rowHeight + math.max(#ids - 1, 0) * LC.rowSpacing, 1));

        for i, row in ipairs(rows) do
            local itemID = ids[i];
            if (itemID) then
                paintItemRow(row, itemID);
                row:Show();
            else
                row.itemID = nil;
                row:Hide();
            end
        end

        headerCount:SetText(opts.GetHeaderCountText(ids));
        emptyText:SetShown(#ids == 0);
        if (listScrollBar and listScrollBar.zlUpdateVisibility) then listScrollBar.zlUpdateVisibility(); end

        local enabled = isEnabled();
        frame:SetAlpha(enabled and 1 or 0.4);
        addButton:SetEnabled(enabled);
        for _, row in ipairs(rows) do
            row.removeButton:SetEnabled(enabled);
        end
    end

    ----------------------------------------------------------------------
    -- Adding items - typed ID, Shift-click, or drag-and-drop.
    ----------------------------------------------------------------------

    local function tryAddItem(itemID)
        if (not itemID) then
            editor:SetStatus("error", "Enter an item ID (numbers only), or Shift-click an item link.");
            return;
        end

        if (not C_Item.DoesItemExistByID(itemID)) then
            editor:SetStatus("error", ("No item with ID %d."):format(itemID));
            return;
        end

        if (opts.IsAlreadyListed(itemID)) then
            local name = Util.GetItemInfo(itemID) or ("Item " .. itemID);
            editor:SetStatus("info", formatAlreadyListed(name, itemID));
            return;
        end

        Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
            local name, _, quality = Util.GetItemInfo(itemID);
            name = name or ("Item " .. itemID);

            if (opts.ValidateAdd) then
                local ok, statusKind, statusText = opts.ValidateAdd(itemID, name, quality);
                if (not ok) then
                    editor:SetStatus(statusKind, statusText);
                    return;
                end
            end

            opts.AddItem(itemID);
            editor:SetStatus("success", (opts.FormatAddedStatus or function(n) return "Added " .. n .. "."; end)(name, itemID));
            addBox:SetText("");
            editor:Refresh();
        end);
    end

    local function parseItemIDFromText(text)
        local id = tonumber(text:match("item:(%d+)"));
        if (id) then return id; end
        if (text:match("^%d+$")) then return tonumber(text); end
        return nil;
    end

    local function tryAddFromText(text)
        if (not isEnabled()) then return; end
        if (not text or text == "") then return; end
        tryAddItem(parseItemIDFromText(text));
    end

    addButton:SetScript("OnClick", function() tryAddFromText(addBox:GetText()); end);
    addBox:SetScript("OnEnterPressed", function(self) tryAddFromText(self:GetText()); end);
    addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);

    local function handleCursorDrop()
        if (not isEnabled()) then return; end
        local cursorType, itemID = GetCursorInfo();
        if (cursorType ~= "item") then return; end
        ClearCursor();
        tryAddItem(itemID);
    end
    addBox:SetScript("OnReceiveDrag", handleCursorDrop);
    addBox:SetScript("OnMouseUp", handleCursorDrop);
    listBox:SetScript("OnReceiveDrag", handleCursorDrop);
    listBox:SetScript("OnMouseUp", handleCursorDrop);

    -- Shift-click capture: HandleModifiedItemClick is the actual function the
    -- game calls on every modified item click - only take it when this exact
    -- box has focus, so a shift-click anywhere else in the UI is left for its
    -- normal handler. Each ItemListEditor instance hooks this independently
    -- (harmless to stack - every hook re-checks its own addBox's focus).
    hooksecurefunc("HandleModifiedItemClick", function(itemLink)
        if (not itemLink or not IsShiftKeyDown()) then return; end
        if (not addBox:HasFocus()) then return; end
        if (ChatEdit_GetActiveWindow() ~= nil) then return; end
        addBox:SetText(itemLink);
        addBox:HighlightText();
    end);

    editor:Refresh();
    return editor;
end
