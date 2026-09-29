--[[
Shared response-button row builder - used by both UI/RespondWindow.lua (the
raider-facing Respond popup) and UI/SettingsWindow/Pages/LootResponses.lua's
preview, so the preview is pixel-identical to what raiders actually see.
Reuses UI/RespondWindow's own control vocabulary (UI.Colors/UI.Sizes.respond/
UI.SetFont/UI.Skin) - this file has no look of its own.

A response list here is always SESSION-shaped: an ordered array of
{id, kind, label, color} (Core/Responses.lua's SessionSnapshot shape - never
the settings module's live list with its extra `enabled` field, and never
indexed by anything but its own array position for layout purposes - ids are
still the only thing that ever identifies a specific response).
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.respond;
local SetFont = FL.UI.SetFont;
local Util = FL.Util;

FL.UI.ResponseRow = FL.UI.ResponseRow or {};
local ResponseRow = FL.UI.ResponseRow;

local DOT_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Dot";
local MOG_ATLAS = "Crosshair_Transmogrify_32";
local PVP_ATLAS = "Crosshair_PVP_32";
local PASS_ATLAS = "talents-button-reset";

local MIN_TEXT_BUTTON_WIDTH = 47;
local TEXT_BUTTON_PAD = 8; -- horizontal padding each side, inside a text button

--------------------------------------------------------------------------
-- Width measurement (also used by RespondWindow.lua's card-width calc)
--------------------------------------------------------------------------

-- Hidden off-screen FontString used only to measure a label's rendered
-- width before any button exists for it - same "probe FontString" pattern
-- RespondWindow.lua's own SENT_INDICATOR_WIDTH/DONE_BUTTON_WIDTH already use.
local measureFS;
local function ensureMeasureFontString()
    if (measureFS) then return; end
    measureFS = UIParent:CreateFontString(nil, "OVERLAY");
    SetFont(measureFS, "body");
    measureFS:Hide();
end

local function measureLabelWidth(label)
    ensureMeasureFontString();
    measureFS:SetText(label);
    if (measureFS.GetUnboundedStringWidth) then
        return measureFS:GetUnboundedStringWidth();
    end
    return measureFS:GetStringWidth();
end

--- The width a single entry's button would naturally render at - a "text"
--- kind sizes to its label, an icon kind is always the fixed icon width.
function ResponseRow.NaturalButtonWidth(entry)
    if (entry.kind ~= "text") then return Sizes.iconButtonWidth; end
    local labelWidth = measureLabelWidth(entry.label);
    return math.max(MIN_TEXT_BUTTON_WIDTH,
        TEXT_BUTTON_PAD + Sizes.buttonDotSize + Sizes.buttonDotLabelGap + labelWidth + TEXT_BUTTON_PAD);
end

--- The whole row's natural width (Note button + every entry's own natural
--- width + a gap between every element) - what RespondWindow.lua's
--- card-width calc anchors to, and what Build() below compares its own
--- `opts.width` against to decide whether to grow the text buttons (extra
--- space) or shrink/truncate them (not enough space).
---@param list table session-shaped response array
---@param opts table|nil { includeNote = boolean (default true) }
function ResponseRow.MeasureNaturalWidth(list, opts)
    local includeNote = not opts or opts.includeNote ~= false;
    local n = #list;
    local total = includeNote and Sizes.noteButtonWidth or 0;
    for _, entry in ipairs(list) do
        total = total + ResponseRow.NaturalButtonWidth(entry);
    end
    local gaps = includeNote and n or math.max(0, n - 1);
    return total + Sizes.buttonGap * gaps;
end

--------------------------------------------------------------------------
-- Slot pool - one pooled frame per row position, generalized to render
-- either a "text" (dot+label) or an "icon" (mog/pvp/pass) response depending on
-- what's currently at that position, since order is now arbitrary and the
-- count varies release to release. Both visual layers are built once and
-- toggled with Show/Hide rather than recreated, same idea Skin.MoveArrows
-- uses for its arrow-pair/lock toggle.
--------------------------------------------------------------------------

-- Centers the dot+label pair as a group (a selected text button shows no
-- dot, just a centered label) - the pair's combined width depends on the
-- label's own rendered width, so this has to run after the label text is
-- set. Identical to RespondWindow.lua's old local layoutButtonContent.
local function layoutTextContent(slot, showDot)
    slot.label:ClearAllPoints();
    if (showDot) then
        slot.dot:Show();
        local totalWidth = Sizes.buttonDotSize + Sizes.buttonDotLabelGap + slot.label:GetStringWidth();
        slot.dot:ClearAllPoints();
        slot.dot:SetPoint("LEFT", slot, "CENTER", -totalWidth / 2, 0);
        slot.label:SetPoint("LEFT", slot.dot, "RIGHT", Sizes.buttonDotLabelGap, 0);
    else
        slot.dot:Hide();
        slot.label:SetPoint("CENTER", slot, "CENTER", 0, 0);
    end
end

local function buildSlot(row, opts)
    local slot = CreateFrame("Button", nil, row, "BackdropTemplate");
    slot:SetHeight(Sizes.buttonHeight);

    -- Text-mode children.
    slot.dot = slot:CreateTexture(nil, "ARTWORK");
    slot.dot:SetSize(Sizes.buttonDotSize, Sizes.buttonDotSize);
    slot.dot:SetTexture(DOT_TEXTURE);

    slot.label = slot:CreateFontString(nil, "OVERLAY");
    SetFont(slot.label, "body");

    -- Icon-mode children.
    slot.icon = slot:CreateTexture(nil, "ARTWORK");
    slot.icon:SetSize(Sizes.responseIconSize, Sizes.responseIconSize);
    slot.icon:SetPoint("CENTER");

    -- Fallback shown instead of the icon when its atlas doesn't resolve on
    -- this client (see paintIconSlot) - same guard RespondWindow.lua's old
    -- createIconResponseButton already used, just no longer silently blank.
    slot.iconFallback = slot:CreateFontString(nil, "OVERLAY");
    SetFont(slot.iconFallback, "tiny");
    slot.iconFallback:SetPoint("CENTER");
    slot.iconFallback:Hide();

    if (not opts.displayOnly) then
        slot:SetScript("OnUpdate", function(self)
            if (not self.hoverColor or not self.baseBorder) then return; end
            local isHovered = Util.IsMouseOverVisible(self, opts.scrollFrame);
            if (isHovered ~= self.isHovered) then
                self.isHovered = isHovered;
                self:SetBackdropBorderColor(unpack(isHovered and self.hoverColor or self.baseBorder));
            end
            if (self.tooltipText) then
                if (isHovered) then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
                    GameTooltip:AddLine(self.tooltipText);
                    GameTooltip:Show();
                elseif (GameTooltip:GetOwner() == self) then
                    GameTooltip:Hide();
                end
            end
        end);
        slot:SetScript("OnClick", function(self)
            if (opts.onSelect) then opts.onSelect(self.responseId); end
        end);
    else
        -- Preview mode: hover still works (a plain backdrop-border color
        -- swap on native OnEnter/OnLeave is enough - nothing here ever
        -- reflows mid-hover the way a real card stack does), but there's no
        -- click/tooltip.
        slot:EnableMouse(true);
        slot:SetScript("OnEnter", function(self)
            if (self.hoverColor) then self:SetBackdropBorderColor(unpack(self.hoverColor)); end
        end);
        slot:SetScript("OnLeave", function(self)
            if (self.baseBorder) then self:SetBackdropBorderColor(unpack(self.baseBorder)); end
        end);
    end

    return slot;
end

local function paintTextSlot(slot, entry, width, opts)
    slot.kind = "text";
    slot.responseId = entry.id;
    slot.tooltipText = nil;
    slot:SetWidth(width);
    slot.icon:Hide();
    slot.iconFallback:Hide();
    slot.dot:Show();
    slot.label:Show();

    local r, g, b = Util.HexToRGB(entry.color);
    slot.label:SetText(entry.label);
    slot.hoverColor = { r, g, b };

    local isSelected = opts.getSelectedId and opts.getSelectedId() == entry.id;
    if (isSelected) then
        Theme.Helpers.SetFlatBackdrop(slot, { r, g, b }, { r, g, b }, 1);
        slot.label:SetTextColor(1, 1, 1);
        slot.baseBorder = { r, g, b };
        layoutTextContent(slot, false);
    else
        Theme.Helpers.SetFlatBackdrop(slot, Colors.defaultBg, Colors.respondButtonBorder, 1);
        slot.label:SetTextColor(unpack(opts.isPending and Colors.respondLabel or Colors.muted));
        slot.dot:SetVertexColor(r, g, b, opts.isPending and 1 or 0.55);
        slot.baseBorder = Colors.respondButtonBorder;
        layoutTextContent(slot, true);
    end
    slot.isHovered = nil; -- forces the OnUpdate poll (if any) to reconcile the border next tick
end

local function paintIconSlot(slot, entry, width, opts)
    slot.kind = entry.kind;
    slot.responseId = entry.id;
    slot.tooltipText = entry.label;
    slot:SetWidth(width);
    slot.dot:Hide();
    slot.label:Hide();

    local atlasName = (entry.kind == "mog") and MOG_ATLAS or (entry.kind == "pvp") and PVP_ATLAS or PASS_ATLAS;
    if (C_Texture.GetAtlasInfo(atlasName)) then
        slot.icon:SetAtlas(atlasName);
        slot.icon:Show();
        slot.iconFallback:Hide();
    else
        slot.icon:Hide();
        slot.iconFallback:SetText(entry.label);
        slot.iconFallback:Show();
        Util.Print(("missing atlas '%s' for the %s button - showing its label instead."):format(atlasName, entry.label));
    end

    local r, g, b = Util.HexToRGB(entry.color);
    slot.hoverColor = { r, g, b };

    local isSelected = opts.getSelectedId and opts.getSelectedId() == entry.id;
    if (isSelected) then
        Theme.Helpers.SetFlatBackdrop(slot, { r, g, b, Colors.respondIconSelectedBgAlpha }, { r, g, b }, 1);
        slot.baseBorder = { r, g, b };
        slot.icon:SetAlpha(1);
        slot.iconFallback:SetTextColor(1, 1, 1);
    else
        Theme.Helpers.SetFlatBackdrop(slot, Colors.defaultBg, Colors.respondButtonBorder, 1);
        slot.baseBorder = Colors.respondButtonBorder;
        slot.icon:SetAlpha(opts.isPending and 1 or 0.5);
        slot.iconFallback:SetTextColor(unpack(opts.isPending and Colors.respondLabel or Colors.muted));
    end
    slot.isHovered = nil;
end

--------------------------------------------------------------------------
-- Decorative Note button - the settings preview's stand-in for
-- RespondWindow's real, popover-wired Note button (opts.noteButton), which
-- has no session/entry to attach to in a static preview card.
--------------------------------------------------------------------------

local NOTE_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\NoteIcon";
local NOTE_ICON_BADGE_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\NoteIconBadge";

local function buildDecorativeNoteButton(row)
    local btn = CreateFrame("Frame", nil, row, "BackdropTemplate");
    btn:SetSize(Sizes.noteButtonWidth, Sizes.buttonHeight);
    Theme.Helpers.SetFlatBackdrop(btn, Colors.defaultBg, Colors.checkboxBorder, 1);
    btn:SetAlpha(0.6); -- inert/decorative, never interactive

    local icon = btn:CreateTexture(nil, "ARTWORK");
    icon:SetSize(Sizes.noteIconSize, Sizes.noteIconSize);
    icon:SetPoint("CENTER");
    icon:SetTexture(NOTE_ICON_TEXTURE);
    icon:SetVertexColor(unpack(Colors.muted));

    local badge = btn:CreateTexture(nil, "OVERLAY");
    badge:SetSize(Sizes.noteIconSize, Sizes.noteIconSize);
    badge:SetPoint("CENTER");
    badge:SetTexture(NOTE_ICON_BADGE_TEXTURE);

    return btn;
end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

--- Builds (or repaints, if already built for this `parent`) one row of
--- response buttons: a Note button first, then one button per `list` entry
--- in list order. Returns the row frame and its natural (unclamped) width.
---
---@param parent Frame
---@param list table session-shaped response array ({id,kind,label,color}[])
---@param opts table {
---   displayOnly: boolean - preview mode, hover-only, no click/tooltip/note-popover.
---   includeNote: boolean|nil - default true. false omits the Note button entirely.
---   noteButton: Frame|nil - a real, caller-owned Note button (RespondWindow's
---     popover-wired one) to place first instead of the decorative stand-in.
---   getSelectedId: function|nil - () -> id|nil, the candidate's current response.
---   isPending: boolean - true = full-brightness "not yet sent" treatment for
---     an unselected button, false = dimmed "already sent" treatment.
---   onSelect: function|nil - (id) called on click (ignored when displayOnly).
---   scrollFrame: ScrollFrame|nil - passed to Util.IsMouseOverVisible for the
---     hover poll, so a card scrolled out of view never shows a stale hover.
---   width: number|nil - if given and larger than the natural width, the
---     slack is distributed evenly across TEXT buttons only (icon buttons
---     stay fixed); if smaller, text buttons shrink evenly toward their
---     47px floor and, as a last resort, truncate their labels.
--- }
---@return Frame row, number naturalWidth
function ResponseRow.Build(parent, list, opts)
    opts = opts or {};
    ensureMeasureFontString();

    local row = parent._responseRow;
    if (not row) then
        row = CreateFrame("Frame", nil, parent);
        parent._responseRow = row;
        row._pool = {};
    end
    row:Show();

    local includeNote = opts.includeNote ~= false;
    local noteButton;
    if (includeNote) then
        noteButton = opts.noteButton;
        if (not noteButton) then
            noteButton = row._decorativeNoteButton or buildDecorativeNoteButton(row);
            row._decorativeNoteButton = noteButton;
        end
        noteButton:ClearAllPoints();
        noteButton:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);
        noteButton:Show();
    elseif (row._decorativeNoteButton) then
        row._decorativeNoteButton:Hide();
    end
    if (opts.noteButton and not includeNote) then opts.noteButton:Hide(); end

    local naturalWidths = {};
    for i, entry in ipairs(list) do
        naturalWidths[i] = ResponseRow.NaturalButtonWidth(entry);
    end
    local naturalWidth = ResponseRow.MeasureNaturalWidth(list, opts);

    local widths = naturalWidths;
    if (opts.width and opts.width ~= naturalWidth) then
        local textIndices = {};
        for i, entry in ipairs(list) do
            if (entry.kind == "text") then table.insert(textIndices, i); end
        end
        if (#textIndices > 0) then
            widths = {};
            for i, w in ipairs(naturalWidths) do widths[i] = w; end
            local delta = opts.width - naturalWidth;
            if (delta > 0) then
                -- Extra space: grow every text button evenly.
                local per = delta / #textIndices;
                for _, i in ipairs(textIndices) do widths[i] = widths[i] + per; end
            else
                -- Not enough space: shrink every text button evenly toward
                -- its 47px floor. If that alone still doesn't fit, truncate
                -- labels (handled by the caller measuring against the
                -- resulting widths - Build() itself always honors whatever
                -- width it's given for layout purposes).
                local shrinkable = 0;
                for _, i in ipairs(textIndices) do shrinkable = shrinkable + (widths[i] - MIN_TEXT_BUTTON_WIDTH); end
                local need = math.min(-delta, math.max(0, shrinkable));
                if (shrinkable > 0) then
                    for _, i in ipairs(textIndices) do
                        local share = (widths[i] - MIN_TEXT_BUTTON_WIDTH) / shrinkable;
                        widths[i] = math.max(MIN_TEXT_BUTTON_WIDTH, widths[i] - need * share);
                    end
                end
            end
        end
    end

    local pool = row._pool;
    local prev = includeNote and noteButton or nil;
    for i, entry in ipairs(list) do
        local slot = pool[i];
        if (not slot) then
            slot = buildSlot(row, opts);
            pool[i] = slot;
        end

        if (entry.kind == "text") then
            paintTextSlot(slot, entry, widths[i], opts);
            -- Last-resort truncation: only reached when even the 47px floor
            -- doesn't fit (opts.width forced narrower than the row can
            -- shrink to) - SetWidth above already clipped the button, so
            -- ellipsize the label to match.
            if (widths[i] < ResponseRow.NaturalButtonWidth(entry)) then
                local maxLabelWidth = widths[i] - (TEXT_BUTTON_PAD * 2 + Sizes.buttonDotSize + Sizes.buttonDotLabelGap);
                local label = entry.label;
                slot.label:SetText(label);
                while (slot.label:GetStringWidth() > maxLabelWidth and #label > 1) do
                    label = label:sub(1, -2);
                    slot.label:SetText(label .. "\226\128\166");
                end
            end
        else
            paintIconSlot(slot, entry, widths[i], opts);
        end

        slot:ClearAllPoints();
        if (prev) then
            slot:SetPoint("LEFT", prev, "RIGHT", Sizes.buttonGap, 0);
        else
            slot:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);
        end
        slot:SetPoint("TOP", row, "TOP", 0, 0);
        slot:Show();
        prev = slot;
    end
    for i = #list + 1, #pool do pool[i]:Hide(); end

    local rowWidth = opts.width or naturalWidth;
    row:SetSize(rowWidth, Sizes.buttonHeight);

    return row, naturalWidth;
end
