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

local COLUMN_GAP = 30;
local SECTION_GAP = Sizes.layout.sectionGap;
local ROW_SPACING = Sizes.layout.rowGap;
local CHECKBOX_ROW_HEIGHT = Sizes.controls.checkboxRow;
local CHECKBOX_DESC_HEIGHT = 14;
local CHILD_INDENT = 32;
-- Section title (~sectionHeader height) + 6px gap + the dropdown's own
-- closed-button height, plus breathing room.
local DROPDOWN_ROW_HEIGHT = Sizes.fonts.sectionHeader + 6 + Sizes.controls.dropdown + 6;
local BUTTON_ROW_HEIGHT = Sizes.controls.button;

--------------------------------------------------------------------------
-- Low-level primitives
--------------------------------------------------------------------------

--- Flat-backdrop push button. Every button in this window uses this rather
--- than Theme.CreateButton/SkinButton - those follow the active skin, and
--- this window deliberately ignores it (see Colors.lua). `variant` is
--- "default" (every settings button except Sync to Raid) or "primary" - see
--- Skin.Button.
---@param parent Frame
---@param label string
---@param variant string|nil "default"|"primary"
function Widgets.CreateFlatButton(parent, label, variant)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate");
    Skin.Button(button, variant);
    button.text:SetText(label);
    return button;
end

--- Builds one checkbox row (UICheckButtonTemplate + label + optional desc
--- line), unanchored - the caller positions row.frame. Shared by
--- SectionMethods:Checkbox (vertical section stacking) and directly by the
--- Loot Council page's horizontal options strip, so both get identical
--- parent/child, tooltip and read/write behavior.
---@param parent Frame
---@param opts table { key, label, tooltip, desc, onChange }
function Widgets.BuildCheckboxRow(parent, opts)
    local row = CreateFrame("Frame", nil, parent);
    row:SetHeight(opts.desc and (CHECKBOX_ROW_HEIGHT + CHECKBOX_DESC_HEIGHT) or CHECKBOX_ROW_HEIGHT);

    local checkbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate");
    checkbox:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);
    Skin.Checkbox(checkbox);

    local label = row:CreateFontString(nil, "OVERLAY");
    SetFont(label, "body");
    label:SetPoint("LEFT", checkbox, "RIGHT", 10, 0);
    label:SetText(opts.label);
    label:SetTextColor(unpack(Colors.text));

    local descText;
    if (opts.desc) then
        descText = row:CreateFontString(nil, "OVERLAY");
        SetFont(descText, "small");
        descText:SetPoint("TOPLEFT", checkbox, "BOTTOMLEFT", 10, -2);
        descText:SetText(opts.desc);
        descText:SetTextColor(unpack(Colors.muted));
    end

    -- Sized to its own content (checkbox + label) rather than stretched, so
    -- the horizontal options strip can lay several of these side by side;
    -- SectionMethods:Checkbox overrides this by also anchoring a RIGHT point
    -- (see below), which takes priority over an explicit width in WoW's
    -- anchor system.
    row:SetWidth(Sizes.controls.checkbox + 10 + (label:GetStringWidth() or 100) + 8);

    local rowObj = {
        key = opts.key,
        frame = row,
        checkbox = checkbox,
        label = label,
        desc = descText,
        labelLower = string.lower(opts.label or ""),
        children = {},
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

local function advanceSection(section, height)
    section.nextRowY = section.nextRowY - height - ROW_SPACING;
    section.frame:SetHeight(math.max(1, -section.nextRowY));
end

local function registerResettable(section, key, default)
    if (key and default ~= nil) then
        table.insert(section.page.resettableKeys, { key = key, default = default });
    end
end

--- Adds a standard vertical checkbox row to this section.
---@param opts table { key, label, tooltip, desc, parent, onChange, default }
function SectionMethods:Checkbox(opts)
    local indent = opts.parent and CHILD_INDENT or 0;
    local row = Widgets.BuildCheckboxRow(self.frame, opts);
    row.frame:SetPoint("TOPLEFT", self.frame, "TOPLEFT", indent, self.nextRowY);
    row.frame:SetPoint("RIGHT", self.frame, "RIGHT", 0, 0);

    self.page.checkboxByKey[opts.key] = row;
    table.insert(self.rows, row);
    registerResettable(self, opts.key, opts.default);

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

    advanceSection(self, row.frame:GetHeight());
    return row;
end

--- Adds a labeled dropdown row to this section, built from Skin.Dropdown -
--- a small custom popup list rather than UIDropDownMenuTemplate (whose
--- DropDownList1/2 popup frames are shared globals; skinning those in place
--- would reskin every other addon's classic dropdowns too).
---@param opts table { key, label, options = {{value, label}...}, onChange,
---                     default, width, x, advance, rowHeight, maxVisibleRows,
---                     previewTexture(value), previewFont(value) }
--- previewTexture/previewFont are resolved into each option's texture/font
--- once, here, before handing the list off to Skin.Dropdown. `x` positions
--- this row at a horizontal offset within the section instead of the usual
--- flush-left (for laying out several dropdowns side by side on one row -
--- see the Appearance page); `advance` (default true) can be set to false
--- so the caller places more controls on the same row before advancing past
--- it itself with SectionMethods:AdvanceRow.
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
    });
    dropdown.button:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6);

    registerResettable(self, opts.key, opts.default);
    table.insert(self.page.refreshers, dropdown.Refresh);

    if (opts.advance ~= false) then
        advanceSection(self, row:GetHeight());
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
    table.insert(self.page.refreshers, function() slider:SetValue(currentValue()); end);

    if (opts.advance ~= false) then
        advanceSection(self, row:GetHeight());
    end
    return { frame = row, slider = slider };
end

--- Advances this section past a row of controls built with `advance =
--- false` (several Dropdowns placed side by side via `x`, for instance) -
--- call once after the last control on that row, with any one of their
--- frame heights (they're all DROPDOWN_ROW_HEIGHT, so it doesn't matter
--- which).
function SectionMethods:AdvanceRow(height)
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

    local section = setmetatable({
        page = self,
        frame = frame,
        width = colWidth,
        nextRowY = -(titleText:GetStringHeight() + 6 + 10),
        rows = {},
    }, SectionMethods);
    frame:SetHeight(-section.nextRowY);

    self.lastSection[column] = section;
    table.insert(self.sections, section);

    return section;
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

--- Used by the 3 stub pages (Announcements/Profiles/About).
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
