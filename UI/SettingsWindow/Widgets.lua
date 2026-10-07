--[[
Reusable widget builders for the settings window: the
Header/Section/Checkbox/Dropdown/Button vocabulary every page in
UI/SettingsWindow/Pages/*.lua is built from. Plain Lua metatable objects, not
a widget library - Registry.lua builds a fresh `page` object (PageMethods)
for each page the first time it's shown, and every `page:Section(...)` call
returns a fresh `section` object (SectionMethods).
]]

local FL = ForeverLoot;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;
local Widgets = {};
FL.UI.SettingsWidgets = Widgets;

-- Exposed on Widgets (not just a private local) so a page that hand-builds
-- its own 2-column layout without page:Section() (e.g. LootResponses.lua's
-- Preview block, which needs a full-width row Section() can't produce) can
-- still line its own columns up with every Section()-based page's, off the
-- same source of truth.
Widgets.COLUMN_GAP = 30;
local COLUMN_GAP = Widgets.COLUMN_GAP;
local SECTION_GAP = Sizes.layout.sectionGap;
-- Also the section heading rule -> first row gap (PageMethods:Section) -
-- see Sizes.lua's own comment on rowGap.
local ROW_SPACING = Sizes.layout.rowGap;
local CHECKBOX_LABEL_GAP = Sizes.controls.checkboxLabelGap;
-- Helper text sits 1px above where it'd flush-stack under the label
-- (label's BOTTOMLEFT -> helper's TOPLEFT), but an item's own reserved
-- height still counts a full 1px gap there - a deliberate hair of visual
-- tightening that doesn't change how much space the item actually claims in
-- the section.
local CHECKBOX_HELPER_OFFSET_Y = -1;
local CHECKBOX_HELPER_LINE_SPACING = 2;
local CHILD_INDENT = 32;
-- Section title (~sectionHeader height) + 6px gap + the dropdown's own
-- closed-button height, plus breathing room.
local DROPDOWN_ROW_HEIGHT = Sizes.fonts.sectionHeader + 6 + Sizes.controls.dropdown + 6;
local BUTTON_ROW_HEIGHT = Sizes.controls.button;

--------------------------------------------------------------------------
-- Low-level primitives
--------------------------------------------------------------------------

--- Flat-backdrop push button. `variant` is
--- "default" or "primary" - see Skin.Button. "Sync to Raid" starts
--- "default" and switches to "primary" at runtime via Skin.SetButtonVariant
--- while a roster change is pending (see UI/SettingsWindow/Pages/LootCouncil.lua).
---@param parent Frame
---@param label string
---@param variant string|nil "default"|"primary"
function Widgets.CreateFlatButton(parent, label, variant)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate");
    Skin.Button(button, variant);
    button.text:SetText(label);
    return button;
end

--- Builds one checkbox row (UICheckButtonTemplate + label + optional helper
--- text), unanchored - the caller positions row.frame. Shared by
--- SectionMethods:Checkbox (vertical section stacking) and directly by
--- UI/AwardWindow.lua's footer checkbox and the Loot Council page's
--- horizontal options strip, so all three get identical parent/child,
--- tooltip and read/write behavior.
---
--- Item anatomy (top to bottom): the box top-aligns with the label's first
--- line (TOPLEFT-to-TOPRIGHT anchoring, not vertically centered on the box);
--- the helper text (if any) sits directly under the label.
---
--- `rowWidth` (SectionMethods:Checkbox only - the two direct callers omit it
--- and get natural, unwrapped sizing) is the row's total width as a plain
--- Lua number, not a RIGHT anchor point. On this client, a FontString's wrap
--- can lag a frame behind an anchor-derived width change, so wrapping is
--- always driven off an explicit SetWidth instead. Order is load-bearing -
--- SetFont (by the caller, via SetFont(label, "body") below) -> SetWidth ->
--- SetText -> only then GetStringHeight() - never measure before both the
--- width and the text are actually set, or the wrap reflects a stale state.
--- rowObj.Remeasure(width) re-runs this exact sequence and returns the row's
--- new height, so a caller can redo it once this client's fonts/geometry
--- have actually settled (see SectionMethods:Checkbox/PageMethods:Layout).
---@param parent Frame
---@param opts table { key, label, tooltip, desc, onChange }
---@param rowWidth number|nil
function Widgets.BuildCheckboxRow(parent, opts, rowWidth)
    local row = CreateFrame("Frame", nil, parent);

    local checkbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate");
    checkbox:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);
    Skin.Checkbox(checkbox);
    local boxSize = Sizes.controls.checkbox;

    local label = row:CreateFontString(nil, "OVERLAY");
    SetFont(label, "body");
    -- A FontString with an explicit width defaults to JustifyH("CENTER") -
    -- both justify axes need to be set explicitly or a wrapped/width-bound
    -- label reads centered instead of flush against the box.
    label:SetJustifyH("LEFT");
    label:SetJustifyV("TOP");
    label:SetPoint("TOPLEFT", checkbox, "TOPRIGHT", CHECKBOX_LABEL_GAP, 0);
    label:SetTextColor(unpack(Colors.text));

    local descText;
    if (opts.desc) then
        descText = row:CreateFontString(nil, "OVERLAY");
        SetFont(descText, "helper");
        descText:SetJustifyH("LEFT");
        descText:SetJustifyV("TOP");
        descText:SetSpacing(CHECKBOX_HELPER_LINE_SPACING);
        descText:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, CHECKBOX_HELPER_OFFSET_Y);
        descText:SetTextColor(unpack(Colors.muted));
    end

    --- (Re-)applies this item's layout for a given total row width: width,
    --- then text, then measure - see this function's own doc comment for why
    --- that order matters. `width == nil` is the two direct callers' natural
    --- (unwrapped) case - no SetWidth at all, sized to the label's own
    --- content instead of a column width.
    local function applyLayout(width)
        local textWidth = width and (width - boxSize - CHECKBOX_LABEL_GAP) or nil;
        if (textWidth) then label:SetWidth(textWidth); end
        label:SetText(opts.label);
        if (descText) then
            if (textWidth) then descText:SetWidth(textWidth); end
            descText:SetText(opts.desc);
        end

        if (width) then
            row:SetWidth(width);
        else
            row:SetWidth(boxSize + CHECKBOX_LABEL_GAP + (label:GetStringWidth() or 100) + 8);
        end

        local height = label:GetStringHeight();
        if (descText) then height = height + 1 + descText:GetStringHeight(); end
        row:SetHeight(math.max(boxSize, height));
        return row:GetHeight();
    end

    applyLayout(rowWidth);

    local rowObj = {
        key = opts.key,
        frame = row,
        checkbox = checkbox,
        label = label,
        desc = descText,
        labelLower = string.lower(opts.label or ""),
        children = {},
        Remeasure = applyLayout,
    };

    -- Skin.Checkbox already dims the box itself (alpha 0.35) on
    -- Enable/Disable - this only needs to handle the label/desc text color
    -- the spec calls for beside it.
    function rowObj:SetEnabledState(enabled)
        if (enabled) then
            checkbox:Enable();
            label:SetTextColor(unpack(Colors.text));
            if (descText) then descText:SetAlpha(1); end
        else
            checkbox:Disable();
            label:SetTextColor(unpack(Colors.disabledText));
            if (descText) then descText:SetAlpha(0.4); end
        end
    end

    checkbox:SetScript("OnClick", function(self)
        local checked = self:GetChecked() and true or false;
        if (opts.key) then FL.Settings.SetPath(opts.key, checked); end
        if (opts.onChange) then opts.onChange(checked); end
        for _, child in ipairs(rowObj.children) do child:SetEnabledState(checked); end
    end);

    if (opts.tooltip) then
        checkbox:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            -- AddLine rather than SetText: SetText's (text, r, g, b, wrap) form
            -- became (text, color, alpha, wrap) on Midnight-based clients.
            GameTooltip:AddLine(opts.tooltip, 1, 1, 1, true);
            GameTooltip:Show();
        end);
        checkbox:SetScript("OnLeave", function() GameTooltip:Hide(); end);
    end

    if (opts.key) then
        checkbox:SetChecked(FL.Settings.GetPath(opts.key) and true or false);
    end

    return rowObj;
end

--------------------------------------------------------------------------
-- SectionMethods - returned by PageMethods:Section
--------------------------------------------------------------------------

local SectionMethods = {};
SectionMethods.__index = SectionMethods;
Widgets.SectionMethods = SectionMethods;

--- `gap`, when given, overrides the standard ROW_SPACING that follows this
--- row (e.g. a checkbox that wants its own related sub-row - Announcements
--- .lua's roll-countdown seconds input - tied visually closer than normal).
local function advanceSection(section, height, gap)
    section.nextRowY = section.nextRowY - height - (gap or ROW_SPACING);
    section.frame:SetHeight(math.max(1, -section.nextRowY));
end

local function registerResettable(section, key, default)
    if (key and default ~= nil) then
        table.insert(section.page.resettableKeys, { key = key, default = default });
    end
end

--- Records a {label, frame} entry into this page's searchEntries -
--- Registry.lua's global search index (built once, across every page, the
--- first time the sidebar search box is used) reads these back to list
--- matching settings and scroll/flash to the one the player picks (see
--- Init.lua's SettingsWindow.ScrollToFrame). A no-op for a label-less entry,
--- so callers can pass opts.label straight through without their own guard.
local function addSearchEntry(page, label, frame)
    if (label) then
        table.insert(page.searchEntries, { label = label, frame = frame });
    end
end

--- Re-anchors and re-measures every row this section has built, in the
--- order they were added, and resizes the section frame to fit - the
--- generic engine behind PageMethods:Layout's re-layout pass. Each
--- SectionMethods:* builder below records one entry per row/group into
--- `self.items` (x offset, frame(s), and - only for a row whose height can
--- actually change, i.e. Checkbox/RadioGroup - a `remeasure` closure); a
--- fixed-height row (Dropdown/Button/Slider) has no `remeasure`, so its
--- already-correct height is just read back and used to advance the
--- running Y, without needing to touch its frame(s) at all.
function SectionMethods:Reflow()
    local y = self.startY;
    for _, item in ipairs(self.items) do
        if (item.group) then
            for _, member in ipairs(item.group) do
                member.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", member.x, y);
            end
        else
            item.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", item.x, y);
        end
        local height = item.remeasure and item.remeasure() or item.height or item.frame:GetHeight();
        y = y - height - (item.gap or ROW_SPACING);
    end
    -- Left at the same value advanceSection would have, so a caller that
    -- keeps stacking more (unregistered) content off self.nextRowY after
    -- this section's own items - LootRolls.lua's hand-built warning
    -- box/note under its RadioGroup - sees the corrected position too.
    self.nextRowY = y;
    self.frame:SetHeight(math.max(1, -y));
    return self.frame:GetHeight();
end

--- Adds a standard vertical checkbox row to this section.
---@param opts table { key, label, tooltip, desc, parent, onChange, default,
---                     gapAfter } -- gapAfter overrides the row spacing
---                     that follows THIS row (see advanceSection's own doc
---                     comment) - default nil (the normal ROW_SPACING).
function SectionMethods:Checkbox(opts)
    local indent = opts.parent and CHILD_INDENT or 0;
    local rowWidth = self.width - indent;
    local row = Widgets.BuildCheckboxRow(self.frame, opts, rowWidth);
    row.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", indent, self.nextRowY);

    table.insert(self.items, {
        frame = row.frame,
        x = indent,
        remeasure = function() return row.Remeasure(rowWidth); end,
        gap = opts.gapAfter,
    });

    self.page.checkboxByKey[opts.key] = row;
    table.insert(self.rows, row);
    registerResettable(self, opts.key, opts.default);
    addSearchEntry(self.page, opts.label, row.frame);

    if (opts.parent) then
        local parentRow = self.page.checkboxByKey[opts.parent];
        assert(parentRow, ("Checkbox '%s': parent '%s' must be registered before it")
            :format(tostring(opts.key), tostring(opts.parent)));
        table.insert(parentRow.children, row);
        row:SetEnabledState(parentRow.checkbox:GetChecked() and true or false);
    end

    table.insert(self.page.refreshers, function()
        if (opts.key) then row.checkbox:SetChecked(FL.Settings.GetPath(opts.key) and true or false); end
    end);

    advanceSection(self, row.frame:GetHeight(), opts.gapAfter);
    return row;
end

--- Adds a single-select radio group (a stack of Skin.Radio rows) to this
--- section - one stored string value (via key/GetPath+SetPath), not N
--- independent booleans. Skin.RadioGroup owns the actual single-select
--- bookkeeping (hiding every other row's dot, calling setValue) off the
--- entries built here.
---@param opts table { key, default, options = { { value, label, desc }, ... }, onChange }
function SectionMethods:RadioGroup(opts)
    local entries = {};

    for _, opt in ipairs(opts.options) do
        local radio = Skin.Radio(self.frame, opt, self.width);
        radio.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, self.nextRowY);

        table.insert(self.items, {
            frame = radio.frame,
            x = 0,
            remeasure = function() return radio.Remeasure(self.width); end,
        });

        table.insert(entries, { value = opt.value, radio = radio });
        addSearchEntry(self.page, opt.label, radio.frame);
        advanceSection(self, radio.frame:GetHeight());
    end

    local group = Skin.RadioGroup(entries,
        function()
            local value = opts.key and FL.Settings.GetPath(opts.key);
            if (value == nil) then value = opts.default; end
            return value;
        end,
        function(value)
            if (opts.key) then FL.Settings.SetPath(opts.key, value); end
            if (opts.onChange) then opts.onChange(value); end
        end);

    registerResettable(self, opts.key, opts.default);
    table.insert(self.page.refreshers, group.Refresh);

    return { rows = entries, Refresh = group.Refresh };
end

--- Adds a labeled dropdown row to this section, built from Skin.Dropdown -
--- a small custom popup list rather than UIDropDownMenuTemplate (whose
--- DropDownList1/2 popup frames are shared globals; skinning those in place
--- would reskin every other addon's classic dropdowns too).
---@param opts table { key, label, options = {{value, label}...}, onChange,
---                     default, width, x, advance, rowHeight, maxVisibleRows,
---                     previewTexture(value), previewFont(value), onPreview(value) }
--- previewTexture/previewFont are resolved into each option's texture/font
--- once, here, before handing the list off to Skin.Dropdown. `x` positions
--- this row at a horizontal offset within the section instead of the usual
--- flush-left (for laying out several dropdowns side by side on one row -
--- see the Appearance page); `advance` (default true) can be set to false
--- so the caller places more controls on the same row before advancing past
--- it itself with SectionMethods:AdvanceRow. `onPreview`, if given, adds a
--- speaker icon to each open-list row (not the closed button) that calls
--- onPreview(value) on click instead of selecting that row - see the Sounds
--- section's LSM dropdowns in UI/SettingsWindow/Pages/General.lua.
function SectionMethods:Dropdown(opts)
    local row = CreateFrame("Frame", nil, self.frame);
    row:SetPoint("TOPLEFT", self.frame, "TOPLEFT", opts.x or 0, self.nextRowY);
    if (opts.width) then
        row:SetWidth(opts.width);
    else
        row:SetPoint("RIGHT", self.frame, "RIGHT", 0, 0);
    end
    row:SetHeight(DROPDOWN_ROW_HEIGHT);

    local label = row:CreateFontString(nil, "OVERLAY");
    SetFont(label, "body");
    label:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);
    label:SetText(opts.label);
    label:SetTextColor(unpack(Colors.text));

    local skinOptions = {};
    for _, opt in ipairs(opts.options) do
        table.insert(skinOptions, {
            value = opt.value,
            label = opt.label,
            texture = opts.previewTexture and opts.previewTexture(opt.value) or nil,
            font = opts.previewFont and opts.previewFont(opt.value) or nil,
        });
    end

    local dropdown = Skin.Dropdown(row, {
        width = opts.width or self.width,
        rowHeight = opts.rowHeight,
        maxVisibleRows = opts.maxVisibleRows,
        options = skinOptions,
        hasTexturePreview = opts.previewTexture ~= nil,
        getValue = function() return opts.key and FL.Settings.GetPath(opts.key); end,
        onSelect = function(value)
            if (opts.key) then FL.Settings.SetPath(opts.key, value); end
            if (opts.onChange) then opts.onChange(value); end
        end,
        onPreview = opts.onPreview,
    });
    dropdown.button:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6);

    registerResettable(self, opts.key, opts.default);
    addSearchEntry(self.page, opts.label, row);
    table.insert(self.page.refreshers, dropdown.Refresh);

    if (opts.advance ~= false) then
        table.insert(self.items, { frame = row, x = opts.x or 0, height = row:GetHeight() });
        advanceSection(self, row:GetHeight());
    else
        -- Grouped with whatever else shares this row (side-by-side
        -- Dropdowns/Sliders) - held until SectionMethods:AdvanceRow folds
        -- the whole group into one Reflow item (see there).
        self.pendingGroup = self.pendingGroup or {};
        table.insert(self.pendingGroup, { frame = row, x = opts.x or 0 });
    end
    return { frame = row, dropdown = dropdown.button };
end

--- Adds a push button to this section.
---@param opts table { label, onClick, width, variant }
function SectionMethods:Button(opts)
    local button = Widgets.CreateFlatButton(self.frame, opts.label, opts.variant);
    button:SetSize(opts.width or 200, BUTTON_ROW_HEIGHT);
    button:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, self.nextRowY);
    button:SetScript("OnClick", function() if (opts.onClick) then opts.onClick(); end end);

    table.insert(self.items, { frame = button, x = 0, height = BUTTON_ROW_HEIGHT });
    addSearchEntry(self.page, opts.label, button);
    advanceSection(self, BUTTON_ROW_HEIGHT);
    return button;
end

--- Adds a labeled slider row to this section - currently only used by the
--- Appearance page's "Window Scale" (UI/SettingsWindow/Pages/Appearance.lua).
---@param opts table { key, label, min, max, step, default, onChange, width, x, advance }
--- `x`/`width`/`advance` behave the same as on SectionMethods:Dropdown.
function SectionMethods:Slider(opts)
    local row = CreateFrame("Frame", nil, self.frame);
    row:SetPoint("TOPLEFT", self.frame, "TOPLEFT", opts.x or 0, self.nextRowY);
    if (opts.width) then
        row:SetWidth(opts.width);
    else
        row:SetPoint("RIGHT", self.frame, "RIGHT", 0, 0);
    end
    row:SetHeight(DROPDOWN_ROW_HEIGHT);

    local label = row:CreateFontString(nil, "OVERLAY");
    SetFont(label, "body");
    label:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);
    label:SetText(opts.label);
    label:SetTextColor(unpack(Colors.text));

    local valueText = row:CreateFontString(nil, "OVERLAY");
    SetFont(valueText, "small");
    valueText:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0);
    valueText:SetTextColor(unpack(Colors.muted));

    local slider = CreateFrame("Slider", nil, row, "UISliderTemplate");
    slider:SetOrientation("HORIZONTAL");
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -8);
    slider:SetPoint("RIGHT", row, "RIGHT", 0, 0);
    slider:SetHeight(Sizes.controls.input);
    slider:SetMinMaxValues(opts.min, opts.max);
    slider:SetValueStep(opts.step or 0.01);
    slider:SetObeyStepOnDrag(true);
    Skin.Slider(slider);

    local function currentValue()
        return (opts.key and FL.Settings.GetPath(opts.key)) or opts.default or opts.min;
    end

    slider:SetScript("OnValueChanged", function(_, value)
        valueText:SetText(("%.2fx"):format(value));
    end);

    -- Commit (save + apply) only on release, not on every drag tick - a
    -- scale change is expensive/visually disruptive (see
    -- Pixel.SetGlobalScale), so dragging should just preview the label.
    slider:SetScript("OnMouseUp", function(self)
        local value = self:GetValue();
        if (opts.key) then FL.Settings.SetPath(opts.key, value); end
        if (opts.onChange) then opts.onChange(value); end
    end);

    slider:SetValue(currentValue());

    registerResettable(self, opts.key, opts.default);
    addSearchEntry(self.page, opts.label, row);
    table.insert(self.page.refreshers, function() slider:SetValue(currentValue()); end);

    if (opts.advance ~= false) then
        table.insert(self.items, { frame = row, x = opts.x or 0, height = row:GetHeight() });
        advanceSection(self, row:GetHeight());
    else
        self.pendingGroup = self.pendingGroup or {};
        table.insert(self.pendingGroup, { frame = row, x = opts.x or 0 });
    end
    return { frame = row, slider = slider };
end

--- Advances this section past a row of controls built with `advance =
--- false` (several Dropdowns placed side by side via `x`, for instance) -
--- call once after the last control on that row, with any one of their
--- frame heights (they're all DROPDOWN_ROW_HEIGHT, so it doesn't matter
--- which). Folds every pending grouped control from that row into a single
--- Reflow item so SectionMethods:Reflow repositions the whole row together.
function SectionMethods:AdvanceRow(height)
    if (self.pendingGroup) then
        table.insert(self.items, { group = self.pendingGroup, height = height });
        self.pendingGroup = nil;
    end
    advanceSection(self, height);
end

--------------------------------------------------------------------------
-- PageMethods - the object passed into a page's RegisterPage buildFunc
--------------------------------------------------------------------------

local PageMethods = {};
PageMethods.__index = PageMethods;
Widgets.PageMethods = PageMethods;

--- Lowest (most negative) Y offset reached by either column so far - where
--- the next thing (a new Section, or the Footer) should start.
function PageMethods:contentBottom()
    local bottom = self.contentTop or 0;
    for column = 1, 2 do
        local y = self.columnY and self.columnY[column];
        local last = self.lastSection and self.lastSection[column];
        if (y) then
            local colBottom = last and (y - last.frame:GetHeight()) or y;
            if (colBottom < bottom) then bottom = colBottom; end
        end
    end
    return bottom;
end

--- Total content height built by this page - Registry uses this to size the
--- scrollable content child after (re)building/showing a page. ComingSoon()
--- (and any page building content contentBottom() has no way to see on its
--- own, e.g. LootCouncil's manually-positioned grid) sets
--- self.contentBottomOverride explicitly; everything else falls back to
--- contentBottom() computed fresh here, after the whole page has finished
--- building (so every section's rows are already accounted for in its frame
--- height). The page's footer - if any - is a separate fixed-position
--- strip outside this scrollable content entirely (see Init.lua's
--- createFooter/SetFooterShown), so it plays no part in this height.
function PageMethods:GetContentHeight()
    if (self.contentBottomOverride) then return -self.contentBottomOverride; end
    return -self:contentBottom();
end

function PageMethods:Header(title, subtitle)
    local header = CreateFrame("Frame", nil, self.frame);
    header:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0);
    header:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", 0, 0);
    header:SetHeight(subtitle and 46 or 30);

    local titleText = header:CreateFontString(nil, "OVERLAY");
    SetFont(titleText, "pageTitle");
    titleText:SetTextColor(unpack(Colors.gold));
    titleText:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0);
    titleText:SetText(title);

    if (subtitle) then
        local subtitleText = header:CreateFontString(nil, "OVERLAY");
        SetFont(subtitleText, "small");
        subtitleText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -6);
        subtitleText:SetText(subtitle);
        subtitleText:SetTextColor(unpack(Colors.muted));
    end

    self.contentTop = -(header:GetHeight() + 10);
    self.columnY = { [1] = self.contentTop, [2] = self.contentTop };
    return header;
end

--- Starts (or continues) a 2-column section. `column` is 1 or 2; sections in
--- the same column stack under each other with SECTION_GAP between them.
function PageMethods:Section(title, column)
    column = column or 1;
    self.columnY = self.columnY or { [1] = self.contentTop or 0, [2] = self.contentTop or 0 };
    self.lastSection = self.lastSection or {};
    self.sections = self.sections or {};

    local prev = self.lastSection[column];
    if (prev) then
        self.columnY[column] = self.columnY[column] - prev.frame:GetHeight() - SECTION_GAP;
    end

    local colWidth = math.floor((self.contentWidth - COLUMN_GAP) / 2);
    local xOffset = (column == 2) and (colWidth + COLUMN_GAP) or 0;

    local frame = CreateFrame("Frame", nil, self.frame);
    frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", xOffset, self.columnY[column]);
    frame:SetWidth(colWidth);

    local titleText = frame:CreateFontString(nil, "OVERLAY");
    SetFont(titleText, "sectionHeader");
    titleText:SetTextColor(unpack(Colors.gold));
    titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    titleText:SetText(title);

    local divider = frame:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -6);
    divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
    divider:SetHeight(FL.Pixel.PixelSize(1));

    local startY = -(titleText:GetStringHeight() + 6 + ROW_SPACING);
    local section = setmetatable({
        page = self,
        frame = frame,
        width = colWidth,
        column = column,
        xOffset = xOffset,
        startY = startY,
        nextRowY = startY,
        rows = {},
        items = {},
    }, SectionMethods);
    frame:SetHeight(-section.nextRowY);

    self.lastSection[column] = section;
    table.insert(self.sections, section);

    return section;
end

--- Registers a function to run at the end of every PageMethods:Layout()
--- pass, after the normal 2-column Section stacking below has been redone -
--- for a page with content Section()'s own bookkeeping can't see (e.g.
--- LootRolls.lua's hand-built full-width "Loot Chat"/"Automatic Rolls"
--- sections), so that content gets a chance to re-run its own positioning
--- off the now-current column bottoms.
function PageMethods:AddLayoutHook(fn)
    self.layoutHooks = self.layoutHooks or {};
    table.insert(self.layoutHooks, fn);
end

--- Redoes this page's row/section positioning and sizing in place, without
--- rebuilding anything - for re-running once this client's fonts/geometry
--- have actually settled (a checkbox/radio item's helper text can measure
--- one line short on the very first pass - see Registry.lua's
--- Registry.LayoutCurrentPage). Re-walks the normal 2-column Section grid
--- (same math PageMethods:Section used to build it) via each section's own
--- Reflow(), then runs any page-specific layoutHooks (LootRolls.lua's
--- hand-built full-width sections) so they can redo their own positioning
--- off the now-current column bottoms.
function PageMethods:Layout()
    -- `cursor` is where the NEXT section in each column goes (mirrors
    -- PageMethods:Section's own columnY bookkeeping while building); once
    -- the loop is done, self.columnY needs to hold where the LAST section in
    -- each column actually STARTS (its own top Y, not yet decremented for
    -- its own height) - that's the invariant contentBottom() relies on
    -- (`y - last.frame:GetHeight()`), so it's tracked separately in `top`
    -- and only written to self.columnY after the loop.
    local cursor = { [1] = self.contentTop or 0, [2] = self.contentTop or 0 };
    local top = { [1] = self.contentTop or 0, [2] = self.contentTop or 0 };
    for _, section in ipairs(self.sections or {}) do
        local column = section.column;
        top[column] = cursor[column];
        section.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", section.xOffset, top[column]);
        local height = section:Reflow();
        cursor[column] = top[column] - height - SECTION_GAP;
    end
    self.columnY = top;

    for _, fn in ipairs(self.layoutHooks or {}) do fn(self); end
end

--- The default footer content for any page that doesn't supply its own via
--- RegisterPage's `opts.footer`: "Reset This Page" (left, only shown if this
--- page registered any resettable keys) + "Changes save automatically"
--- (right). Built by Registry.lua into a page-owned subframe of the shared
--- footer row (see Init.lua's createFooter) - `footerFrame` is that
--- subframe, already sized to the row, so both elements just anchor
--- straight to its LEFT/RIGHT edges to land vertically centered.
function Widgets.BuildDefaultFooter(footerFrame, page)
    if (#page.resettableKeys > 0) then
        local resetButton = Widgets.CreateFlatButton(footerFrame, "Reset This Page");
        resetButton:SetSize(150, Sizes.controls.button);
        resetButton:SetPoint("LEFT", footerFrame, "LEFT", 0, 0);
        resetButton:SetScript("OnClick", function()
            for _, entry in ipairs(page.resettableKeys) do
                FL.Settings.SetPath(entry.key, entry.default);
            end
            page:Refresh();
        end);
    end

    local saveText = footerFrame:CreateFontString(nil, "OVERLAY");
    SetFont(saveText, "small");
    saveText:SetPoint("RIGHT", footerFrame, "RIGHT", 0, 0);
    saveText:SetText("Changes save automatically");
    saveText:SetTextColor(unpack(Colors.muted));
end

--- Used by the stub pages.
function PageMethods:ComingSoon()
    local text = self.frame:CreateFontString(nil, "OVERLAY");
    SetFont(text, "body");
    text:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, self.contentTop or -50);
    text:SetText("Coming soon");
    text:SetTextColor(unpack(Colors.muted));
    self.contentBottomOverride = (self.contentTop or -50) - 20;
end

--- Re-reads every registered checkbox/dropdown's current saved value into
--- its widget - called by Registry when a page is (re)shown, and by
--- BuildDefaultFooter's "Reset This Page" button.
function PageMethods:Refresh()
    for _, fn in ipairs(self.refreshers) do fn(); end
end
