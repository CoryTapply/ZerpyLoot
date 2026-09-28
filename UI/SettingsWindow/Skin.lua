--[[
Reusable control-styling helpers for UI/SettingsWindow - the search box,
checkboxes, dropdowns, buttons and close button used across every settings
page. Like UI/SettingsWindow/Colors.lua and Init.lua, this deliberately
ignores FL.Theme's skin dispatch (Theme.SkinButton/SkinCloseButton/etc.):
every control here always looks the same regardless of the active theme, so
it's built with Theme.Helpers (skin-agnostic) and FL.UI.Colors, never
Theme.colors or Theme.GetSkin().

Each Skin.* function strips whatever template art its target control shipped
with (Blizzard's Left/Right/Middle pieces, Normal/Pushed/Highlight textures)
before drawing this look over it, rather than layering on top of it - see the
individual functions for exactly what each template brings that needs
clearing first.
]]

local FL = ForeverLoot;
local Theme = FL.Theme;
local Helpers = Theme.Helpers;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;

local Skin = {};
FL.UI.Skin = Skin;

local CLOSE_ICON_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Icons\\close.tga";
local CHECK_ICON_ATLAS = "common-dropdown-icon-checkmark-yellow";
local DASH_H_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\DashH";
local DASH_V_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\DashV";

--- Clears a texture region left over from a Blizzard template. On this
--- client, Texture:SetTexture(nil) works but the owning widget's own
--- SetNormalTexture(nil)-style setters throw ("Usage: self:SetNormalTexture
--- (asset)") - see UI/Theme/Skins/Default.lua's identical hideTexture, which
--- hit the same issue first - so the Texture object is always cleared
--- directly, never through the widget setter.
local function hideTexture(tex)
    if (tex and tex.SetTexture) then
        tex:SetTexture(nil);
        tex:SetAlpha(0);
    end
end

--- Hides every Normal/Pushed/Highlight/Disabled texture a Button-type widget
--- may have picked up from its template, plus any named Left/Right/Middle
--- region pieces (UIPanelButtonTemplate/InputBoxTemplate's border art).
local function stripButtonArt(button)
    if (button.GetNormalTexture) then hideTexture(button:GetNormalTexture()); end
    if (button.GetPushedTexture) then hideTexture(button:GetPushedTexture()); end
    if (button.GetHighlightTexture) then hideTexture(button:GetHighlightTexture()); end
    if (button.GetDisabledTexture) then hideTexture(button:GetDisabledTexture()); end
    for _, regionName in ipairs({ "Left", "Right", "Middle" }) do
        local region = button[regionName];
        if (region and region.SetTexture) then hideTexture(region); end
    end
end

--------------------------------------------------------------------------
-- Skin.Backdrop - thin, spec-named wrapper. Theme.Helpers.SetFlatBackdrop
-- already is exactly this (flat WHITE8X8 fill + edge, skin-agnostic) - kept
-- as a real function here (not just "use the Helper directly") so every
-- Skin.* control below reads consistently off Skin.*, not a mix of the two.
--------------------------------------------------------------------------

function Skin.Backdrop(frame, bg, border)
    Helpers.EnsureBackdrop(frame);
    Helpers.SetFlatBackdrop(frame, bg, border, 1);
end

--- 3px dark-to-transparent gradient along the inside top edge of `frame`,
--- inset 1px so it sits inside the 1px border Skin.Backdrop just drew. Used
--- by the search box, checkboxes and dropdown closed button alike.
function Skin.AddInnerShadow(frame)
    if (frame.zlInnerShadow) then return frame.zlInnerShadow; end
    local shadow = frame:CreateTexture(nil, "ARTWORK");
    shadow:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1);
    shadow:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1);
    shadow:SetHeight(3);
    -- SetGradient's "VERTICAL" orientation runs minColor at the bottom of the
    -- texture to maxColor at the top - this texture only covers the frame's
    -- top 3px, so maxColor (dark) needs to be the *top* argument to land
    -- right against the border, fading to transparent 3px down.
    shadow:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.45));
    frame.zlInnerShadow = shadow;
    return shadow;
end

--------------------------------------------------------------------------
-- Skin.EditBox - the sidebar "Search settings" box (SearchBoxTemplate).
-- Template art being stripped: EditBox.Left/Right/Middle (border, from
-- InputBoxVisualTemplate) plus EditBox.searchIcon and EditBox.clearButton
-- (SearchBoxTemplate's own magnifying-glass icon and X button) - confirmed
-- against Blizzard_SharedXML/Shared/InputBox/InputBoxTemplates.xml. The
-- Instructions FontString (InputBoxInstructionsTemplate's placeholder) is
-- kept - Blizzard's own OnTextChanged/OnEditFocusGained/Lost scripts already
-- show/hide it exactly per the spec ("hidden while there's text or focus"),
-- just recolored/refonted here.
--------------------------------------------------------------------------

function Skin.EditBox(editBox)
    hideTexture(editBox.Left);
    hideTexture(editBox.Right);
    hideTexture(editBox.Middle);
    if (editBox.searchIcon) then editBox.searchIcon:Hide(); end
    if (editBox.clearButton) then editBox.clearButton:Hide(); end

    Skin.Backdrop(editBox, Colors.controlBg, Colors.controlBorder);
    Skin.AddInnerShadow(editBox);

    -- "search" role (11pt) + sidebarTextInset - only caller is the sidebar
    -- search box, sized/inset to land its text on the same x as the nav
    -- item labels (Registry.lua's nav buttons use the same Sizes key).
    SetFont(editBox, "search");
    editBox:SetTextColor(unpack(Colors.textBright));
    editBox:SetTextInsets(Sizes.layout.sidebarTextInset, Sizes.layout.sidebarTextInset, 0, 0);

    if (editBox.Instructions) then
        SetFont(editBox.Instructions, "search");
        editBox.Instructions:SetTextColor(unpack(Colors.controlHover));
        editBox.Instructions:ClearAllPoints();
        editBox.Instructions:SetPoint("LEFT", editBox, "LEFT", Sizes.layout.sidebarTextInset, 0);
    end

    editBox:HookScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(Colors.controlFocus));
    end);
    editBox:HookScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(Colors.controlBorder));
    end);

    -- SearchBoxTemplate's own OnEscapePressed only clears focus
    -- (EditBox_ClearFocus) - the spec wants the text cleared too. Hooked
    -- (not replaced) so that focus-clear still runs.
    editBox:HookScript("OnEscapePressed", function(self)
        self:SetText("");
    end);
end

--------------------------------------------------------------------------
-- Skin.Checkbox - UICheckButtonTemplate. Template art being stripped:
-- Normal/Pushed/HighlightTexture (UICheckButtonArtTemplate's UI-CheckBox-Up/
-- Down/Highlight). CheckedTexture/DisabledCheckedTexture are kept, not
-- hidden - CheckButton already shows/hides those automatically off
-- GetChecked(), so reusing that (just swapped to our own icon/color/size)
-- means the check mark needs no extra OnClick bookkeeping here.
--------------------------------------------------------------------------

--- Box chrome for Skin.Checkbox: size, template-art stripping, flat backdrop
--- + inner shadow, and hover/enable/disable wiring. Leaves the
--- CheckedTexture/DisabledCheckedTexture entirely to the caller - CheckButton
--- already shows/hides those automatically off GetChecked(), so the skin
--- needs no extra OnClick bookkeeping here.
local function skinCheckBoxChrome(check)
    local boxSize = Sizes.controls.checkbox;
    check:SetSize(boxSize, boxSize);
    check:SetHitRectInsets(0, 0, 0, 0);

    hideTexture(check:GetNormalTexture());
    hideTexture(check:GetPushedTexture());
    hideTexture(check:GetHighlightTexture());

    Skin.Backdrop(check, Colors.controlBg, Colors.checkboxBorder);
    Skin.AddInnerShadow(check);

    check:HookScript("OnEnter", function(self)
        if (self:IsEnabled()) then self:SetBackdropBorderColor(unpack(Colors.controlHover)); end
    end);
    check:HookScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(Colors.checkboxBorder));
    end);
    check:HookScript("OnEnable", function(self) self:SetAlpha(1); end);
    check:HookScript("OnDisable", function(self) self:SetAlpha(0.35); end);
    check:SetAlpha(check:IsEnabled() and 1 or 0.35);

    return boxSize;
end

function Skin.Checkbox(check)
    local boxSize = skinCheckBoxChrome(check);

    check:GetCheckedTexture():SetAtlas(CHECK_ICON_ATLAS);
    check:GetDisabledCheckedTexture():SetAtlas(CHECK_ICON_ATLAS);
    -- ~3/4 of the box, same proportion the original 22px box / 16px icon used.
    local checkIconSize = math.floor(boxSize * 0.75 + 0.5);
    for _, tex in ipairs({ check:GetCheckedTexture(), check:GetDisabledCheckedTexture() }) do
        if (tex) then
            tex:ClearAllPoints();
            tex:SetPoint("CENTER");
            tex:SetSize(checkIconSize, checkIconSize);
        end
    end
end

--------------------------------------------------------------------------
-- Skin.Radio / Skin.RadioGroup - single-select radio rows, used by the
-- Automatic Rolls section's "In raid instances" mode picker
-- (UI/SettingsWindow/Widgets.lua's SectionMethods:RadioGroup). Built as a
-- bare Button with 3 stacked textures (RadioBg/RadioRing/RadioDot, Media/
-- Buttons) rather than a UICheckButtonTemplate CheckButton - unlike
-- Skin.Checkbox's single CheckedTexture slot, the ring needs to recolor on
-- hover independently of the dot's shown/hidden selection state, and the
-- label needs to trigger that same hover (a CheckButton's own highlight
-- texture only ever responds to the box itself).
--------------------------------------------------------------------------

local RADIO_BG_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Buttons\\RadioBg";
local RADIO_RING_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Buttons\\RadioRing";
local RADIO_DOT_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Buttons\\RadioDot";
-- Box's right edge -> label's left edge - shared with Widgets.
-- BuildCheckboxRow's own checkbox rows (Sizes.controls.checkboxLabelGap) so
-- the two controls' item anatomy stays identical.
local RADIO_LABEL_GAP = Sizes.controls.checkboxLabelGap;
-- Same helper-text offset/line-spacing/height-formula Widgets.
-- BuildCheckboxRow uses - see that file's own comment for why the anchor
-- offset (-1, a hair of visual tightening) and the height formula's gap
-- (a full 1, below) deliberately don't match.
local RADIO_HELPER_OFFSET_Y = -1;
local RADIO_HELPER_LINE_SPACING = 2;

--- Builds one radio row: box (bg/ring/dot) + label + optional helper (desc)
--- text, unanchored - the caller positions the returned `frame`.
---
--- `rowWidth` (SectionMethods:RadioGroup only) is the row's total width as a
--- plain Lua number, same reasoning as Widgets.BuildCheckboxRow's own
--- `rowWidth` param: wrapping is driven off an explicit SetWidth, in the
--- order SetFont -> SetWidth -> SetText -> GetStringHeight(), never a
--- RIGHT-anchor-derived width measured immediately after. `radio.Remeasure
--- (width)` re-runs that sequence and returns the row's new height, for a
--- caller redoing layout once this client's fonts/geometry have settled
--- (PageMethods:Layout).
---@param parent Frame
---@param opts table { label, desc }
---@param rowWidth number|nil
function Skin.Radio(parent, opts, rowWidth)
    opts = opts or {};
    local boxSize = Sizes.controls.checkbox;

    local row = CreateFrame("Frame", nil, parent);
    row:SetHeight(boxSize);

    local box = CreateFrame("Button", nil, row);
    box:SetSize(boxSize, boxSize);
    box:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0);

    local bg = box:CreateTexture(nil, "BACKGROUND");
    bg:SetAllPoints(box);
    bg:SetTexture(RADIO_BG_TEXTURE);

    local ring = box:CreateTexture(nil, "BORDER");
    ring:SetAllPoints(box);
    ring:SetTexture(RADIO_RING_TEXTURE);
    ring:SetVertexColor(unpack(Colors.checkboxBorder));

    local dot = box:CreateTexture(nil, "ARTWORK");
    dot:SetAllPoints(box);
    dot:SetTexture(RADIO_DOT_TEXTURE);
    dot:SetVertexColor(unpack(Colors.gold));
    dot:Hide();

    local label = row:CreateFontString(nil, "OVERLAY");
    SetFont(label, "body");
    -- A FontString with an explicit width defaults to JustifyH("CENTER") -
    -- both justify axes need to be set explicitly or a wrapped/width-bound
    -- label reads centered instead of flush against the box.
    label:SetJustifyH("LEFT");
    label:SetJustifyV("TOP");
    -- TOPLEFT, not vertically centered on the box - the box top-aligns with
    -- the label's first line, same anatomy Widgets.BuildCheckboxRow uses.
    label:SetPoint("TOPLEFT", box, "TOPRIGHT", RADIO_LABEL_GAP, 0);
    label:SetTextColor(unpack(Colors.text));
    label:EnableMouse(true); -- so its own OnEnter/OnLeave below actually fire

    local descText;
    if (opts.desc) then
        descText = row:CreateFontString(nil, "OVERLAY");
        SetFont(descText, "helper");
        descText:SetJustifyH("LEFT");
        descText:SetJustifyV("TOP");
        descText:SetSpacing(RADIO_HELPER_LINE_SPACING);
        descText:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, RADIO_HELPER_OFFSET_Y);
        descText:SetTextColor(unpack(Colors.muted));
    end

    --- (Re-)applies this item's layout for a given total row width - see
    --- this function's own doc comment for why width must be set before
    --- text, before either is measured.
    local function applyLayout(width)
        local textWidth = width and (width - boxSize - RADIO_LABEL_GAP) or nil;
        if (textWidth) then label:SetWidth(textWidth); end
        label:SetText(opts.label);
        if (descText) then
            if (textWidth) then descText:SetWidth(textWidth); end
            descText:SetText(opts.desc);
        end

        if (width) then row:SetWidth(width); end

        local height = label:GetStringHeight();
        if (descText) then height = height + 1 + descText:GetStringHeight(); end
        row:SetHeight(math.max(boxSize, height));
        return row:GetHeight();
    end

    applyLayout(rowWidth);

    local function setRingColor(color)
        ring:SetVertexColor(unpack(color));
    end

    for _, widget in ipairs({ box, label }) do
        widget:HookScript("OnEnter", function()
            if (box:IsEnabled()) then setRingColor(Colors.controlHover); end
        end);
        widget:HookScript("OnLeave", function()
            if (box:IsEnabled()) then setRingColor(Colors.checkboxBorder); end
        end);
    end

    box:HookScript("OnEnable", function(self) self:SetAlpha(1); end);
    box:HookScript("OnDisable", function(self) self:SetAlpha(0.35); end);
    box:SetAlpha(box:IsEnabled() and 1 or 0.35);

    local radio = { frame = row, box = box, label = label, desc = descText, Remeasure = applyLayout };

    -- Purely visual (dot shown/hidden) - Skin.RadioGroup below owns which
    -- one entry is actually selected and calls this on every entry in a
    -- group whenever any one of them is clicked.
    function radio:SetSelected(selected)
        dot:SetShown(selected and true or false);
    end

    --- Enables/disables the whole row - the box's own OnEnable/OnDisable
    --- above already handles its alpha; this additionally dims the label/
    --- desc text, same split Widgets.BuildCheckboxRow's rowObj:SetEnabledState
    --- uses for Skin.Checkbox.
    function radio:SetEnabledState(enabled)
        if (enabled) then box:Enable(); else box:Disable(); end
        label:SetTextColor(unpack(enabled and Colors.text or Colors.disabledText));
        if (descText) then descText:SetAlpha(enabled and 1 or 0.4); end
    end

    -- Set by Skin.RadioGroup (or any other caller wiring selection) -
    -- clicking the box or the label both select this row.
    box:SetScript("OnClick", function()
        if (radio.onSelect) then radio.onSelect(); end
    end);
    label:SetScript("OnMouseUp", function()
        if (box:IsEnabled() and radio.onSelect) then radio.onSelect(); end
    end);

    return radio;
end

--- Wires a set of already-built Skin.Radio rows into a single-select group.
--- `entries` = { { value = <any>, radio = <Skin.Radio return> }, ... }.
--- getValue()/setValue(value) read/write the group's one canonical value -
--- Skin.RadioGroup owns no storage of its own, so a caller backed by
--- FL.Settings (or anything else) just hands in the matching accessors.
---@param entries table
---@param getValue fun(): any
---@param setValue fun(value: any)
function Skin.RadioGroup(entries, getValue, setValue)
    local function syncSelection()
        local current = getValue();
        for _, entry in ipairs(entries) do
            entry.radio:SetSelected(entry.value == current);
        end
    end

    for _, entry in ipairs(entries) do
        entry.radio.onSelect = function()
            setValue(entry.value);
            syncSelection();
        end
    end

    syncSelection();

    return { Refresh = syncSelection };
end

--------------------------------------------------------------------------
-- Skin.Button - plain frame-based buttons (this window never uses
-- UIPanelButtonTemplate, so there's no template art to strip here; every
-- caller already gets a bare BackdropTemplate Button from
-- Widgets.CreateFlatButton). `variant` is "default" or "primary" (gold) -
-- see Skin.SetButtonVariant below for switching an existing button's
-- variant at runtime (e.g. "Sync to Raid" going gold while a roster change
-- is pending).
--------------------------------------------------------------------------

--- Computes the color set for one button variant. Pulled out of Skin.Button
--- so Skin.SetButtonVariant (switching an already-built button's variant at
--- runtime, e.g. "Sync to Raid" going gold while a roster change is pending)
--- can recompute the same colors without re-running Skin.Button's one-time
--- setup (which would stack duplicate HookScript handlers).
local function computeButtonVariant(variant)
    local isPrimary = (variant == "primary");
    local bg = isPrimary and Colors.primaryBg or Colors.defaultBg;
    return {
        bg = bg,
        border = isPrimary and Colors.primaryBorder or Colors.checkboxBorder,
        hoverBorder = isPrimary and Colors.gold or Colors.controlHover,
        textColor = isPrimary and Colors.gold or Colors.textBright,
        pressedBg = isPrimary and Colors.primaryPressed or bg,
    };
end

function Skin.Button(button, variant)
    stripButtonArt(button);
    button.skinVariant = computeButtonVariant((variant == "primary") and "primary" or "default");

    if (not button.text) then
        local text = button:CreateFontString(nil, "OVERLAY");
        text:SetPoint("CENTER");
        button.text = text;
    end
    SetFont(button.text, "body");

    -- Stashed on the button (rather than staying purely local) so
    -- Skin.SetButtonVariant can re-apply the current enabled/disabled state
    -- immediately after swapping button.skinVariant.
    function button.applyEnabled()
        Skin.Backdrop(button, button.skinVariant.bg, button.skinVariant.border);
        button.text:SetTextColor(unpack(button.skinVariant.textColor));
    end
    function button.applyDisabled()
        Skin.Backdrop(button, Colors.defaultBg, Colors.disabledBorder);
        button.text:SetTextColor(unpack(Colors.disabledText));
    end

    if (button:IsEnabled()) then button.applyEnabled(); else button.applyDisabled(); end

    button:HookScript("OnEnter", function(self)
        if (self:IsEnabled()) then self:SetBackdropBorderColor(unpack(self.skinVariant.hoverBorder)); end
    end);
    button:HookScript("OnLeave", function(self)
        if (self:IsEnabled()) then
            self:SetBackdropBorderColor(unpack(self.skinVariant.border));
            self:SetBackdropColor(unpack(self.skinVariant.bg));
            self.text:SetPoint("CENTER", 0, 0);
        end
    end);
    button:HookScript("OnMouseDown", function(self)
        if (self:IsEnabled()) then
            self:SetBackdropColor(unpack(self.skinVariant.pressedBg));
            self.text:SetPoint("CENTER", 0, -1);
        end
    end);
    button:HookScript("OnMouseUp", function(self)
        if (self:IsEnabled()) then
            self:SetBackdropColor(unpack(self.skinVariant.bg));
            self.text:SetPoint("CENTER", 0, 0);
        end
    end);
    button:HookScript("OnEnable", button.applyEnabled);
    button:HookScript("OnDisable", button.applyDisabled);
end

--- Switches an already-built flat button (see Skin.Button) to a different
--- variant in place - e.g. "Sync to Raid" swapping from "default" to
--- "primary" (gold) while a roster change is pending. Re-applies the
--- current enabled/disabled state immediately so the new colors show right
--- away rather than waiting for the next OnEnable/OnDisable.
---@param button Frame a button previously passed through Skin.Button
---@param variant string|nil "default"|"primary"
function Skin.SetButtonVariant(button, variant)
    button.skinVariant = computeButtonVariant((variant == "primary") and "primary" or "default");
    if (button:IsEnabled()) then button.applyEnabled(); else button.applyDisabled(); end
end

--------------------------------------------------------------------------
-- Skin.CloseButton - the settings window's own titlebar close button (a
-- bare BackdropTemplate Button built in Init.lua, not UIPanelCloseButton -
-- stripButtonArt is still run defensively in case that ever changes).
--------------------------------------------------------------------------

function Skin.CloseButton(button)
    stripButtonArt(button);
    button:SetSize(Sizes.controls.close, Sizes.controls.close);

    if (not button.zlCloseIcon) then
        local icon = button:CreateTexture(nil, "ARTWORK");
        icon:SetSize(Sizes.controls.closeIcon, Sizes.controls.closeIcon);
        icon:SetPoint("CENTER");
        icon:SetTexture(CLOSE_ICON_TEXTURE);
        icon:SetVertexColor(1, 1, 1);
        button.zlCloseIcon = icon;
    end

    Skin.Backdrop(button, Colors.skinCloseBg, Colors.skinCloseBorder);

    button:HookScript("OnEnter", function(self)
        Skin.Backdrop(self, Colors.skinCloseBgHover, Colors.skinCloseBorderHover);
    end);
    button:HookScript("OnLeave", function(self)
        Skin.Backdrop(self, Colors.skinCloseBg, Colors.skinCloseBorder);
        self.zlCloseIcon:SetPoint("CENTER", 0, 0);
    end);
    button:HookScript("OnMouseDown", function(self)
        self.zlCloseIcon:SetPoint("CENTER", 1, -1);
    end);
    button:HookScript("OnMouseUp", function(self)
        self.zlCloseIcon:SetPoint("CENTER", 0, 0);
    end);
end

--------------------------------------------------------------------------
-- Skin.Slider - UISliderTemplate, used only by the Appearance page's Window
-- Scale slider. Template art being stripped: the NineSlice track (a whole
-- child frame, not a texture - hidden rather than cleared) - a flat backdrop
-- track is drawn in its place. The stock ThumbTexture is kept (Slider
-- widgets have no SetThumbTexture(nil) escape hatch the way buttons have
-- SetNormalTexture) but resized/recolored.
--------------------------------------------------------------------------

local THUMB_SIZE = 14;

function Skin.Slider(slider)
    if (slider.NineSlice) then slider.NineSlice:Hide(); end

    Skin.Backdrop(slider, Colors.controlBg, Colors.controlBorder);

    local thumb = slider:GetThumbTexture();
    if (thumb) then
        thumb:SetSize(THUMB_SIZE, THUMB_SIZE);
        thumb:SetTexture(Helpers.FLAT_TEXTURE);
        thumb:SetVertexColor(unpack(Colors.gold));
    end

    if (slider.Text) then slider.Text:Hide(); end
    if (slider.Low) then slider.Low:Hide(); end
    if (slider.High) then slider.High:Hide(); end
end

--------------------------------------------------------------------------
-- Skin.Dropdown - replaces UIDropDownMenuTemplate for the Appearance page's
-- Theme/Font/Status Bar Texture pickers. UIDropDownMenu's popup
-- (DropDownList1/2) is a single pair of frames shared by every addon on the
-- client, so skinning it in place would reskin every other addon's classic
-- dropdowns too - built as a small standalone popup instead (allowed
-- explicitly by the brief). Only a closed button + a flat popup list exist
-- to skin here; there's no Blizzard template art to strip.
--
-- opts:
--   width          - shared width of the closed button and the popup list.
--   height         - closed button height (default 36).
--   options        - { { value, label, [texture], [font] }, ... }. `texture`/
--                     `font` are resolved once by the caller (Appearance.lua)
--                     rather than passed as per-row callbacks, since every
--                     row's own value is already in hand at build time.
--   getValue()     - returns the currently selected value.
--   onSelect(value)- called when a row is chosen.
--   rowHeight      - popup row height (default 26).
--   maxVisibleRows - popup shows at most this many rows before scrolling
--                    (default 10).
--
-- Returns { button = closedButton, Refresh = function() }; Refresh() re-reads
-- getValue() and re-paints the closed button (used when the saved value
-- changes elsewhere, e.g. Reset This Page).
--------------------------------------------------------------------------

local dropdownCounter = 0;
local openList; -- at most one Skin dropdown popup open at a time

local function closeOpenList()
    if (openList) then
        openList:Hide();
        if (openList.zlCatcher) then openList.zlCatcher:Hide(); end
        openList = nil;
    end
end

function Skin.Dropdown(parent, opts)
    local rowHeight = opts.rowHeight or 26;
    local maxVisibleRows = opts.maxVisibleRows or 10;
    local width = opts.width or 200;
    local height = opts.height or Sizes.controls.dropdown;
    local xOffset = opts.xOffset or -5;
    local textPaddingLeftRight = opts.textPaddingLeftRight or 10;

    ----------------------------------------------------------------------
    -- Closed button
    ----------------------------------------------------------------------

    local button = CreateFrame("Button", nil, parent, "BackdropTemplate");
    button:SetSize(width, height or Sizes.controls.dropdown);
    Skin.Backdrop(button, Colors.controlBg, Colors.controlBorder);
    Skin.AddInnerShadow(button);

    local arrowBox = CreateFrame("Frame", nil, button, "BackdropTemplate");
    arrowBox:SetSize(math.min(Sizes.controls.dropdownArrow, height-4), math.min(Sizes.controls.dropdownArrow, height-4));
    arrowBox:SetPoint("RIGHT", button, "RIGHT", xOffset, 0);
    Skin.Backdrop(arrowBox, Colors.arrowBoxBg, Colors.arrowBoxBorder);

    local arrow = arrowBox:CreateTexture(nil, "OVERLAY");
    arrow:SetSize(16, 16);
    arrow:SetPoint("CENTER");
    arrow:SetAtlas("glues-characterSelect-icon-arrowDown");
    arrow:SetVertexColor(unpack(Colors.gold));

    -- Behind valueText, same treatment a popup row gets (see below) - shown
    -- only when opts gives this dropdown a texture preview (Status Bar
    -- Texture) and the current value resolves one.
    local previewBar = button:CreateTexture(nil, "ARTWORK");
    previewBar:SetPoint("TOPLEFT", button, "TOPLEFT", 3, -3);
    previewBar:SetPoint("BOTTOMRIGHT", arrowBox, "BOTTOMLEFT", -2, 0);
    previewBar:Hide();

    local valueText = button:CreateFontString(nil, "OVERLAY");
    SetFont(valueText, "body");
    valueText:SetTextColor(unpack(Colors.textBright));
    valueText:SetJustifyH("RIGHT");
    valueText:SetWordWrap(false);
    valueText:SetPoint("LEFT", button, "LEFT", textPaddingLeftRight, 0);
    valueText:SetPoint("RIGHT", arrowBox, "LEFT", -textPaddingLeftRight, 0);

    button:HookScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(Colors.controlHover));
    end);
    button:HookScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(Colors.controlBorder));
    end);

    -- Only set (see paintClosedButton) when the selected value's label
    -- actually got truncated with "..." - untruncated values get no
    -- tooltip.
    button:HookScript("OnEnter", function(self)
        if (button.zlFullLabel) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
            GameTooltip:AddLine(button.zlFullLabel, 1, 1, 1, true);
            GameTooltip:Show();
        end
    end);
    button:HookScript("OnLeave", function() GameTooltip:Hide(); end);

    ----------------------------------------------------------------------
    -- Popup list (built lazily on first open)
    ----------------------------------------------------------------------

    local list, scrollFrame, scrollChild, rows;

    local function findOption(value)
        for _, opt in ipairs(opts.options) do
            if (opt.value == value) then return opt; end
        end
        return nil;
    end

    local function paintClosedButton()
        local opt = findOption(opts.getValue());
        local fullLabel = opt and opt.label or "";

        if (opt and opt.font) then
            -- Deliberately NOT SetFont via the role system: this previews
            -- `opt.font`'s own face, not the addon's globally-selected one.
            valueText:SetFont(opt.font, Sizes.fonts.body, Theme.FONT_FLAGS);
        else
            SetFont(valueText, "body");
        end

        -- Truncated char-by-char (never mid-string) against valueText's own
        -- anchor-resolved width, same technique as LootCouncil's
        -- truncateToWidth - the font must already be set above, since string
        -- width depends on it. button.zlFullLabel (read by the OnEnter
        -- tooltip hook below) is only set when truncation actually happened.
        valueText:SetText(fullLabel);
        local maxWidth = valueText:GetWidth();
        if (fullLabel ~= "" and valueText:GetStringWidth() > maxWidth) then
            local truncated = fullLabel;
            while (#truncated > 1 and valueText:GetStringWidth() > maxWidth) do
                truncated = truncated:sub(1, -2);
                valueText:SetText(truncated .. "\226\128\166");
            end
            button.zlFullLabel = fullLabel;
        else
            button.zlFullLabel = nil;
        end

        -- Optional per-option text color (e.g. the Automatic Rolls override
        -- list's rule dropdown, colored by rule) - every other caller never
        -- sets opt.color, so this always falls back to the normal look.
        valueText:SetTextColor(unpack((opt and opt.color) or Colors.textBright));

        if (opt and opt.texture) then
            previewBar:SetTexture(opt.texture);
            previewBar:SetVertexColor(0.6, 0.5, 0.2, 0.7);
            previewBar:Show();
        else
            previewBar:Hide();
        end
    end

    local function paintRows()
        local selected = opts.getValue();
        for i, row in ipairs(rows) do
            local opt = opts.options[i];
            if (opt) then
                local isSelected = (opt.value == selected);
                row.label:SetText(opt.label);
                row.check:SetShown(isSelected);
                row.selectedTex:SetShown(isSelected);

                if (row.previewBar) then
                    if (opt.texture) then
                        row.previewBar:SetTexture(opt.texture);
                        row.previewBar:SetVertexColor(0.6, 0.5, 0.2, 0.7);
                        row.previewBar:Show();
                    else
                        row.previewBar:Hide();
                    end
                end

                if (opt.font) then
                    row.label:SetFont(opt.font, Sizes.fonts.body, Theme.FONT_FLAGS);
                else
                    SetFont(row.label, "body");
                end

                row.label:SetTextColor(unpack(isSelected and Colors.gold or Colors.textBright));
                row:Show();
            else
                row:Hide();
            end
        end
    end

    local function ensureList()
        if (list) then return; end

        dropdownCounter = dropdownCounter + 1;
        local name = "ForeverLootSettingsDropdownList" .. dropdownCounter;

        -- Full-screen invisible catcher behind the list - clicking anywhere
        -- outside the list (but not the list itself, which sits above it)
        -- closes the popup. Same technique Blizzard's own DropDownList uses.
        local catcher = CreateFrame("Button", nil, UIParent);
        catcher:SetAllPoints(UIParent);
        catcher:SetFrameStrata("FULLSCREEN_DIALOG");
        catcher:Hide();
        catcher:SetScript("OnClick", closeOpenList);
        button.zlCatcher = catcher;

        list = CreateFrame("Frame", name, UIParent, "BackdropTemplate");
        list:SetFrameStrata("FULLSCREEN_DIALOG");
        list:SetFrameLevel(catcher:GetFrameLevel() + 1);
        list:SetWidth(width);
        list:Hide();
        Skin.Backdrop(list, Colors.sidebarBg, Colors.border);
        list.zlCatcher = catcher;
        tinsert(UISpecialFrames, name);

        scrollFrame = CreateFrame("ScrollFrame", nil, list);
        scrollFrame:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -1);
        scrollFrame:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -1, 1);
        scrollFrame:EnableMouseWheel(true);
        scrollFrame:SetScript("OnMouseWheel", function(self, delta)
            local current = self:GetVerticalScroll();
            local maxScroll = self:GetVerticalScrollRange();
            self:SetVerticalScroll(Clamp(current - delta * rowHeight, 0, maxScroll));
        end);

        scrollChild = CreateFrame("Frame", nil, scrollFrame);
        scrollChild:SetSize(width - 2, math.max(#opts.options * rowHeight, 1));
        scrollFrame:SetScrollChild(scrollChild);

        rows = {};
        for i, opt in ipairs(opts.options) do
            local row = CreateFrame("Button", nil, scrollChild);
            row:SetHeight(rowHeight);
            row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i - 1) * rowHeight);
            row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0);

            row.selectedTex = row:CreateTexture(nil, "BACKGROUND");
            row.selectedTex:SetAllPoints();
            row.selectedTex:SetColorTexture(unpack(Colors.selectedFill));
            row.selectedTex:Hide();

            local hoverTex = row:CreateTexture(nil, "BACKGROUND");
            hoverTex:SetAllPoints();
            hoverTex:SetColorTexture(unpack(Colors.selectedFill));
            row:SetHighlightTexture(hoverTex);

            if (opt.texture ~= nil or opts.hasTexturePreview) then
                row.previewBar = row:CreateTexture(nil, "ARTWORK");
                row.previewBar:SetPoint("TOPLEFT", 2, -2);
                row.previewBar:SetPoint("BOTTOMRIGHT", -2, 2);
                row.previewBar:Hide();
            end

            row.check = row:CreateTexture(nil, "OVERLAY");
            row.check:SetSize(14, 14);
            row.check:SetPoint("LEFT", row, "LEFT", 6, 0);
            row.check:SetAtlas("common-dropdown-icon-checkmark-yellow");
            row.check:Hide();

            row.label = row:CreateFontString(nil, "OVERLAY");
            SetFont(row.label, "body");
            row.label:SetPoint("LEFT", row, "LEFT", 20, 0);
            row.label:SetPoint("RIGHT", row, "RIGHT", -6, 0);
            row.label:SetJustifyH("LEFT");
            row.label:SetWordWrap(false);

            row:SetScript("OnClick", function()
                if (opts.onSelect) then opts.onSelect(opt.value); end
                paintClosedButton();
                paintRows();
                closeOpenList();
            end);

            rows[i] = row;
        end
    end

    button:SetScript("OnClick", function()
        if (openList == list and list and list:IsShown()) then
            closeOpenList();
            return;
        end
        closeOpenList();
        ensureList();
        paintRows();

        local visibleRows = math.min(#opts.options, maxVisibleRows);
        list:SetHeight(math.max(visibleRows * rowHeight, rowHeight) + 2);
        list:ClearAllPoints();
        list:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2);

        list.zlCatcher:Show();
        list:Show();
        openList = list;
    end);

    paintClosedButton();

    return {
        button = button,
        Refresh = function()
            paintClosedButton();
            if (list) then paintRows(); end
        end,
    };
end

--------------------------------------------------------------------------
-- Skin.DashedBorder - a repeating-dash outline on all 4 edges of `frame`,
-- for spots a solid Skin.Backdrop border would look too heavy (the Start
-- Session window's item drop strip). Not a backdrop at all - 4 separate
-- REPEAT-tiled textures, since SetBackdrop's edgeFile can't tile a short
-- dash pattern around a rectangle's corners. `frame:SetDashColor(r,g,b,a)`
-- is attached for later recoloring (e.g. the drag-highlight state) without
-- rebuilding the edges.
--------------------------------------------------------------------------

function Skin.DashedBorder(frame, r, g, b, a, dash, thickness)
    dash = dash or 4;
    thickness = thickness or 1;
    local edges = {};

    local function makeEdge(file, p1, p2, horiz)
        local tex = frame:CreateTexture(nil, "BORDER");
        tex:SetTexture(file, "REPEAT", "REPEAT", "NEAREST");
        tex:SetVertexColor(r, g, b, a or 1);
        tex:SetPoint(p1[1], frame, p1[1], p1[2], p1[3]);
        tex:SetPoint(p2[1], frame, p2[1], p2[2], p2[3]);
        if (horiz) then tex:SetHeight(thickness); else tex:SetWidth(thickness); end
        tex.zlHoriz = horiz;
        table.insert(edges, tex);
    end

    makeEdge(DASH_H_TEXTURE, { "TOPLEFT", 0, 0 }, { "TOPRIGHT", 0, 0 }, true);
    makeEdge(DASH_H_TEXTURE, { "BOTTOMLEFT", 0, 0 }, { "BOTTOMRIGHT", 0, 0 }, true);
    makeEdge(DASH_V_TEXTURE, { "TOPLEFT", 0, 0 }, { "BOTTOMLEFT", 0, 0 }, false);
    makeEdge(DASH_V_TEXTURE, { "TOPRIGHT", 0, 0 }, { "BOTTOMRIGHT", 0, 0 }, false);

    local function refresh()
        local w, h = frame:GetSize();
        for _, tex in ipairs(edges) do
            local repeats = (tex.zlHoriz and w or h) / (dash * 2); -- one repeat = dash + gap
            if (tex.zlHoriz) then tex:SetTexCoord(0, repeats, 0, 1);
            else tex:SetTexCoord(0, 1, 0, repeats); end
        end
    end
    frame:HookScript("OnSizeChanged", refresh);
    refresh();

    frame.SetDashColor = function(_, r2, g2, b2, a2)
        for _, tex in ipairs(edges) do tex:SetVertexColor(r2, g2, b2, a2 or 1); end
    end;

    return edges;
end

--------------------------------------------------------------------------
-- Skin.ScrollBar - the settings window's own slim, arrowless scrollbar for
-- its main content ScrollFrame (UIPanelScrollFrameTemplate). Mirrors
-- Theme.SkinScrollBar's auto-hide technique (UI/Theme/Theme.lua: hook
-- OnScrollRangeChanged, stash bar.zlUpdateVisibility so a caller can
-- re-trigger it manually after a layout change the event might not have
-- fired for yet - Registry.lua does this on page switch/search filtering,
-- LootCouncil.lua's page on roster updates) but with this window's own
-- fixed palette/sizing instead of following the active skin, same as every
-- other Skin.* function in this file. Positioning is left to the caller
-- (Init.lua), same as Skin.Dropdown leaves its button's anchor to callers.
--------------------------------------------------------------------------

function Skin.ScrollBar(scrollFrame)
    local bar = scrollFrame.ScrollBar;
    if (not bar) then return nil; end

    for _, key in ipairs({ "ScrollUpButton", "ScrollDownButton" }) do
        local arrowButton = bar[key];
        if (arrowButton) then
            arrowButton:Hide();
            arrowButton:SetAlpha(0);
            arrowButton:EnableMouse(false);
        end
    end

    local width = Sizes.layout.scrollbarWidth;
    bar:SetWidth(width);

    if (not bar.zlTrack) then
        bar.zlTrack = bar:CreateTexture(nil, "BACKGROUND", nil, -2);
    end
    bar.zlTrack:SetColorTexture(unpack(Colors.scrollTrack));
    bar.zlTrack:ClearAllPoints();
    bar.zlTrack:SetPoint("TOP", bar, "TOP", 0, 0);
    bar.zlTrack:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0);
    bar.zlTrack:SetWidth(width);

    local thumb = bar.GetThumbTexture and bar:GetThumbTexture();
    if (thumb) then
        thumb:SetTexture(Helpers.FLAT_TEXTURE);
        thumb:SetVertexColor(unpack(Colors.scrollThumb));
        thumb:SetWidth(width);

        if (not bar.zlHoverHooked) then
            bar:HookScript("OnEnter", function() thumb:SetVertexColor(unpack(Colors.scrollThumbHover)); end);
            bar:HookScript("OnLeave", function() thumb:SetVertexColor(unpack(Colors.scrollThumb)); end);
            bar.zlHoverHooked = true;
        end
    end

    local function updateVisibility()
        local range = scrollFrame:GetVerticalScrollRange();
        bar:SetShown(range ~= nil and range > 0.5);
    end
    bar.zlUpdateVisibility = updateVisibility;

    if (not bar.zlAutoHideHooked) then
        scrollFrame:HookScript("OnScrollRangeChanged", updateVisibility);
        bar.zlAutoHideHooked = true;
    end
    updateVisibility();

    return bar;
end

--------------------------------------------------------------------------
-- Skin.Pill - a horizontally-stretchy pill/capsule background (PillFill.tga
-- + PillBorder.tga, each a left-cap/middle/right-cap 3-slice image) for
-- response-style pills (UI/AwardWindow.lua's Response column and its
-- assign/reassign popup summary). No Blizzard template art to strip - the
-- caller hands in a bare Frame it draws its own textures on. `pill` must
-- already have its final height set (SetHeight) before calling this - the
-- cap width is derived from it (see createPillSlices).
--------------------------------------------------------------------------

local PILL_FILL_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\PillFill";
local PILL_BORDER_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\PillBorder";

-- Slices `file` (a 64x32 image: left quarter = left cap, middle half =
-- stretchy fill, right quarter = right cap) into 3 textures so the pill can
-- render at any width without its rounded ends stretching. Cap width is
-- half of `parent`'s own height, matching the source art's own 1:2
-- cap-width:height proportions.
local function createPillSlices(parent, file, layer, sublevel)
    local height = parent:GetHeight();
    local capWidth = height / 2;

    local left = parent:CreateTexture(nil, layer, nil, sublevel);
    local middle = parent:CreateTexture(nil, layer, nil, sublevel);
    local right = parent:CreateTexture(nil, layer, nil, sublevel);
    for _, tex in ipairs({ left, middle, right }) do tex:SetTexture(file); end

    left:SetTexCoord(0, 0.25, 0, 1);
    left:SetSize(capWidth, height);
    left:SetPoint("LEFT", parent, "LEFT", 0, 0);

    right:SetTexCoord(0.75, 1, 0, 1);
    right:SetSize(capWidth, height);
    right:SetPoint("RIGHT", parent, "RIGHT", 0, 0);

    middle:SetTexCoord(0.25, 0.75, 0, 1);
    middle:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0);
    middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", 0, 0);

    return { left, middle, right };
end

--- Builds the fill+border 3-slice pill on `pill`. Fill defaults to
--- Colors.defaultBg (#1c1916); call pill:SetPillColor(r, g, b) to tint the
--- border per use (e.g. a response option's own color) and
--- pill:SetPillFillColor(r, g, b) to tint the fill away from that default
--- (e.g. the award window's "Assigned to" badge).
function Skin.Pill(pill)
    pill.fill = createPillSlices(pill, PILL_FILL_TEXTURE, "BACKGROUND", 0);
    for _, tex in ipairs(pill.fill) do tex:SetVertexColor(unpack(Colors.defaultBg)); end

    pill.border = createPillSlices(pill, PILL_BORDER_TEXTURE, "BORDER", 1);

    function pill:SetPillColor(r, g, b)
        for _, tex in ipairs(self.border) do tex:SetVertexColor(r, g, b); end
    end

    function pill:SetPillFillColor(r, g, b)
        for _, tex in ipairs(self.fill) do tex:SetVertexColor(r, g, b); end
    end
end

--------------------------------------------------------------------------
-- Skin.TimerBar - a countdown progress bar (track/glow/fill/sheen), shared
-- by UI/RespondWindow.lua's "closing in Ns" timer, UI/RollWindow.lua's roll
-- timer, and UI/GroupLootFrame.lua's per-row timer, so all three always
-- look and animate identically.
--
-- Layer order is load-bearing, not cosmetic: track's own dark fill is a
-- plain BACKGROUND-layer texture (sublevel -8, i.e. as far back as
-- possible) so it can never be drawn on top of the glow, which sits on the
-- BORDER layer (categorically above BACKGROUND regardless of sublevel) -
-- SoftGlow.tga's own soft falloff means most of its visible halo extends
-- well past the (thin) track/fill anyway, but the part that overlaps the
-- track must not be painted over. The crisp fill itself sits on ARTWORK
-- (above the glow), track -> glow -> fill, back to front.
--
-- Color is set two ways: SetVariant(name) picks a named entry from this
-- bar's own `variants` table (RollWindow's "running"/"hover"); SetColors
-- (from, to, glowAlpha) sets an arbitrary one directly, for a caller like
-- GroupLootFrame that needs a fresh per-roll quality color rather than a
-- small fixed set of named looks. Both only touch the fill's gradient/glow
-- tint - never the fill's own vertex color/texture (a tinted or
-- vertex-colored fill visibly desaturates or pinks out a solid gradient,
-- which is why nothing in this file calls SetVertexColor/SetColorTexture on
-- `fill`). Only call either when the color should actually change - redoing
-- the same gradient every frame is wasted work, not a correctness issue,
-- but callers (GroupLootFrame's danger-threshold flip, RollWindow's hover
-- enter/leave) already only call in on a real state change.
--
-- The glow's ALPHA (as opposed to its color) still recomputes every
-- SetProgress call, since it's deliberately tied to how wide the fill
-- currently is (see SetProgress below) - a short sliver near the end of a
-- countdown doesn't get a halo sized for a full-width bar.
--
-- The bar never owns an authoritative clock: SetProgress(remaining, total)
-- just paints one instant, so a caller whose real timer lives elsewhere
-- (RollTracker's own C_Timer, for the roll window) can drive it from that
-- caller's own OnUpdate without the bar ever independently deciding
-- anything expired. Start/Stop is a convenience self-driving wrapper for a
-- caller (RespondWindow) that doesn't need that separation - it owns its
-- own OnUpdate off GetTime(), the same way the original inline code did.
--------------------------------------------------------------------------

local TIMERBAR_SOFTGLOW_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\SoftGlow";
local TIMERBAR_SWEEP_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\Sweep";

local TimerBarMethods = {};
TimerBarMethods.__index = TimerBarMethods;

--- Sets the fill's gradient and the glow's tint/base alpha directly, for a
--- caller that needs an arbitrary per-instance color (GroupLootFrame's
--- per-roll quality color) rather than one of this bar's fixed named
--- `variants`. `glowAlpha` is the glow's BASE strength before SetProgress's
--- own width-based falloff (see SetProgress) - defaults to this bar's own
--- opts.glowAlpha if omitted. `glowColor` lets a caller (GroupLootFrame)
--- tint the glow differently from the fill's own `to` endpoint (e.g. a
--- dimmed-down version of it) - defaults to `to`, so a caller that never
--- passes it (RespondWindow/RollWindow's SetVariant) is unaffected.
function TimerBarMethods:SetColors(from, to, glowAlpha, glowColor)
    self.fill:SetGradient("HORIZONTAL", CreateColor(unpack(from)), CreateColor(unpack(to)));
    self.glowColor = glowColor or to;
    self.glowBaseAlpha = glowAlpha or self.defaultGlowAlpha;
end

--- Swaps to a named entry in this bar's own `variants` table (e.g.
--- "running"/"hover") - a thin wrapper over SetColors for a bar whose
--- caller only ever needs a small fixed set of looks. No-ops if `name` is
--- already current, so re-entering the same state every frame (a caller
--- polling its own condition in OnUpdate) never redoes the gradient.
function TimerBarMethods:SetVariant(name)
    if (self.currentVariant == name) then return; end
    self.currentVariant = name;
    local variant = self.variants[name] or self.variants.running;
    self:SetColors(variant.from, variant.to, variant.glowAlpha);
end

--- Stateless paint of one instant: fill width (linear, LEFT-anchored), the
--- glow's width-scaled alpha, and sheen phase, all derived from
--- `remaining`/`total` - never accumulated elapsed time, so a caller can
--- call this from its own GetTime()-based OnUpdate with no drift.
function TimerBarMethods:SetProgress(remaining, total)
    total = (total and total > 0) and total or 1;
    remaining = math.max(0, math.min(remaining or 0, total));

    local trackWidth = self.track:GetWidth();
    if (trackWidth <= 0) then return; end -- not laid out yet - try again next frame

    local fillWidth = trackWidth * (remaining / total);
    local fillShown = fillWidth >= 1;
    self.fill:SetShown(fillShown);
    if (fillShown) then self.fill:SetWidth(fillWidth); end

    -- The glow shrinks (in strength, not size) with the fill so a
    -- near-empty sliver doesn't carry a halo sized for a full bar - fully
    -- hidden below glowHideWidth entirely, since SoftGlow.tga's own soft
    -- edges read as a shapeless smudge at that point rather than a halo
    -- around anything.
    local glowShown = fillWidth >= self.glowHideWidth;
    self.glow:SetShown(glowShown);
    if (glowShown) then
        local strength = math.min(1, fillWidth / self.glowStrengthWidth);
        local c = self.glowColor;
        self.glow:SetVertexColor(c[1], c[2], c[3], self.glowBaseAlpha * strength);
    end

    -- Cached for UpdateSheen below - SetProgress no longer positions the
    -- sheen itself (see that method's own comment for why).
    self.lastFillWidth = fillWidth;
end

--- Positions the sheen for this exact instant. `now` is GetTime(), captured
--- ONCE by the caller's own single OnUpdate and passed in - never read
--- fresh here - so every bar sharing the same sheenPeriod (e.g. every
--- visible UI/GroupLootFrame.lua row) lands on the exact same phase this
--- frame, regardless of when each one's own countdown happened to start.
--- This used to live inside SetProgress, phased off `total - remaining`
--- (that bar's OWN elapsed time) - correct in isolation, but that means two
--- different bars' sheens are only ever in sync by coincidence, AND it
--- silently assumed remaining/total (and so sheenPeriod) share one unit;
--- UI/GroupLootFrame.lua calls SetProgress in milliseconds, so the same
--- "2.5" sheenPeriod meant for seconds wrapped every 2.5ms instead of every
--- 2.5s - about 1000x too fast. Using GetTime() directly sidesteps both
--- problems: it's one shared absolute clock, and it's always in seconds no
--- matter what unit a caller's own SetProgress happens to use.
---
--- Must be called by exactly one OnUpdate per bar per frame - GroupLootFrame
--- and RollWindow each own one bar and call this from their own single
--- shared OnUpdate; RespondWindow's self-driving Start() (below) calls it
--- from its own internal OnUpdate. Skin.TimerBar itself never starts an
--- OnUpdate just for this.
function TimerBarMethods:UpdateSheen(now)
    local fillWidth = self.lastFillWidth or 0;
    local shown = fillWidth >= self.sheenHideWidth;
    self.sheen:SetShown(shown);
    if (not shown) then return; end

    local phase = (now % self.sheenPeriod) / self.sheenPeriod;
    local sheenX = -self.sheenWidth + phase * (fillWidth + self.sheenWidth);
    self.sheen:ClearAllPoints();
    self.sheen:SetPoint("LEFT", self.sheenClip, "LEFT", sheenX, 0);
end

--- Loops a gentle opacity-only pulse (1 -> 0.55 -> 1 over pulseDuration) on
--- the fill+glow together (both live in `self.holder`, an unclipped frame
--- sized to the track, so one Alpha animation on it covers both in perfect
--- sync) - used for a bar's "running out" state. No Scale/Translation/color
--- animation is involved; only Alpha.
function TimerBarMethods:StartPulse()
    self.holder:SetAlpha(1);
    self.pulseAnim:Play();
end

--- Stops the pulse and resets the holder's alpha to 1 - called when leaving
--- the low state, when a row/card closes, and when a pooled bar is about to
--- be reused for a new roll, so a red pulse never carries over onto the
--- next thing that bar displays.
function TimerBarMethods:StopPulse()
    self.pulseAnim:Stop();
    self.holder:SetAlpha(1);
end

--- Flat, frozen look (Respond's "paused" state, Roll's "stopped" state) -
--- full-width solid `color`, no glow, no sheen, no pulse. A flat
--- from==to gradient (not SetVertexColor - see this section's header
--- comment) is what actually paints the solid color. Does not touch any
--- OnUpdate (a Start()-driven bar should Stop() first; a caller driving its
--- own OnUpdate just stops calling SetProgress).
function TimerBarMethods:Freeze(color)
    self.frozen = true;
    self.fill:Show();
    self.fill:SetWidth(self.track:GetWidth());
    self:SetColors(color, color, 0);
    self.glow:Hide();
    self.sheenClip:Hide();
    self:StopPulse();
end

--- Restores the sheen/glow after Freeze(), repainting the last-set variant's
--- colors. Does not by itself resume any progress/driving - the caller is
--- expected to call SetProgress (or Start) again.
function TimerBarMethods:Unfreeze()
    self.frozen = false;
    self.sheenClip:Show();
    -- SetVariant no-ops when `name` already matches self.currentVariant
    -- (see its own comment) - Freeze left that name untouched but DID
    -- repaint the fill/glow to its flat frozen color, so it must be forced
    -- to actually reapply here rather than skip as "unchanged".
    local name = self.currentVariant or "running";
    self.currentVariant = nil;
    self:SetVariant(name);
end

--- Self-driving convenience wrapper: runs its own GetTime()-based OnUpdate
--- for `durationSeconds`, calling SetProgress every tick and
--- callbacks.onTick(secondsRemaining) only when the displayed integer
--- second actually changes, then callbacks.onExpire() once it reaches zero.
--- See the file-header comment - only a caller with no separate timer
--- authority of its own should use this (RespondWindow); a caller mirroring
--- someone else's clock (RollWindow, mirroring RollTracker's own timer)
--- should call SetProgress directly from its own OnUpdate instead.
function TimerBarMethods:Start(durationSeconds, callbacks)
    self:Unfreeze();
    self.driveStart = GetTime();
    self.driveDuration = durationSeconds;
    self.driveCallbacks = callbacks or {};
    self.lastLabelSeconds = nil;
    self.track:SetScript("OnUpdate", function()
        local now = GetTime();
        local remaining = self.driveDuration - (now - self.driveStart);
        if (remaining <= 0) then
            self:Stop();
            if (self.driveCallbacks.onExpire) then self.driveCallbacks.onExpire(); end
            return;
        end

        self:SetProgress(remaining, self.driveDuration);
        self:UpdateSheen(now);

        if (self.driveCallbacks.onTick) then
            local seconds = math.max(math.ceil(remaining), 1);
            if (seconds ~= self.lastLabelSeconds) then
                self.lastLabelSeconds = seconds;
                self.driveCallbacks.onTick(seconds);
            end
        end
    end);
end

--- Clears the self-driving OnUpdate started by Start(). Safe to call even if
--- it was never started.
function TimerBarMethods:Stop()
    self.track:SetScript("OnUpdate", nil);
end

--- Builds a new timer bar as a child of `parent` - the caller anchors/sizes
--- `bar.track` itself (this only sets its height) the same way callers
--- position a Skin.Pill or Skin.Dropdown.
---
--- opts (all optional, default to RespondWindow's original tuning):
---   height, sheenWidth, sheenPeriod, glowPadX, glowPadY, glowAlpha,
---   glowStrengthWidth, glowHideWidth, pulseDuration, sheenAlpha,
---   trackColor, trackBorder,
---   variants - { [name] = { from = {r,g,b}, to = {r,g,b}, glowAlpha? } },
---     must include at least "running". Defaults to a single "running"
---     variant using controlFocus -> gold, Respond's own gradient.
function Skin.TimerBar(parent, opts)
    opts = opts or {};
    local height = opts.height or 6;
    local sheenWidth = opts.sheenWidth or 40;
    local sheenPeriod = opts.sheenPeriod or 2.5;
    local sheenAlpha = opts.sheenAlpha or 0.6;
    local sheenHideWidth = opts.sheenHideWidth or 12;
    -- SoftGlow.tga fades to transparent over its outer ~20% width / ~45%
    -- height - padding this small would just show the texture's own
    -- already-faded edge instead of its brighter core, reading as "no glow
    -- at all". These defaults are sized for a 4-6px bar; a much taller bar
    -- may want bigger opts.glowPadY.
    local glowPadX = opts.glowPadX or 8;
    local glowPadY = opts.glowPadY or 7;
    local pulseDuration = opts.pulseDuration or 1.0;

    local track = CreateFrame("Frame", nil, parent, "BackdropTemplate");
    track:SetHeight(height);
    -- Border only (no bgFile) - the dark fill color below is its own plain
    -- texture instead, specifically so it can be placed on the BACKGROUND
    -- layer at a sublevel behind everything, never at risk of drawing over
    -- the glow the way a backdrop's own internal layering could.
    Helpers.SetFlatBackdrop(track, nil, opts.trackBorder or Colors.respondTimerTrackBorder, 1);

    local trackBg = track:CreateTexture(nil, "BACKGROUND", nil, -8);
    trackBg:SetAllPoints(track);
    trackBg:SetTexture(Helpers.FLAT_TEXTURE);
    trackBg:SetVertexColor(unpack(opts.trackColor or Colors.controlBg));

    -- Fill and glow both live here (not directly on track) so the last-10s
    -- pulse (StartPulse/StopPulse) can fade both together with one Alpha
    -- animation via a single frame's alpha. Parented to track (not
    -- unclipped-but-detached from it) so a caller hiding/showing the track
    -- (e.g. UI/RollWindow.lua's timerBar.track:Hide()) still hides/shows
    -- the fill+glow with it - track itself never sets SetClipsChildren, so
    -- this is still "not a child of any clipping frame" as required.
    local holder = CreateFrame("Frame", nil, track);
    holder:SetAllPoints(track);
    -- A child frame defaults to parent-level+1, which would put fill/glow
    -- in a strictly-later draw bucket than track's own BACKGROUND-layer
    -- trackBg and the sheenClip/sheen (still parented directly to track) -
    -- section 3's BACKGROUND/BORDER/ARTWORK/OVERLAY layer ordering only
    -- resolves correctly when everything shares one frame level.
    holder:SetFrameLevel(track:GetFrameLevel());

    -- ARTWORK (above the glow's BORDER layer) - crisp on top, explicit
    -- BLEND (never ADD/anything else) so SetGradient's colors render
    -- exactly as set. No SetVertexColor/SetColorTexture calls exist on this
    -- texture anywhere in this bar - either would tint or fade the
    -- gradient (this is what previously read as a "pale pink" bar instead
    -- of solid red).
    local fill = holder:CreateTexture(nil, "ARTWORK");
    fill:SetTexture(Helpers.FLAT_TEXTURE);
    fill:SetBlendMode("BLEND");
    fill:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0);
    fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 0, 0);
    fill:SetWidth(1);

    -- BORDER layer (above track's BACKGROUND, below fill's ARTWORK) -
    -- guarantees it draws in front of track's own fill color regardless of
    -- sublevel numbers, which is what made the glow "basically invisible"
    -- before (it and the track's old backdrop fill were both on
    -- BACKGROUND, and the backdrop drew on top).
    local glow = holder:CreateTexture(nil, "BORDER");
    glow:SetTexture(TIMERBAR_SOFTGLOW_TEXTURE);
    glow:SetBlendMode("ADD");
    glow:SetPoint("TOPLEFT", fill, "TOPLEFT", -glowPadX, glowPadY);
    glow:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", glowPadX, -glowPadY);

    local sheenClip = CreateFrame("Frame", nil, track);
    sheenClip:SetClipsChildren(true);
    sheenClip:SetAllPoints(fill);

    local sheen = sheenClip:CreateTexture(nil, "OVERLAY");
    sheen:SetTexture(TIMERBAR_SWEEP_TEXTURE);
    sheen:SetSize(sheenWidth, height);
    sheen:SetVertexColor(1, 1, 1, sheenAlpha);
    sheen:SetBlendMode("ADD");
    sheen:SetPoint("LEFT", sheenClip, "LEFT", 0, 0);

    -- One looping Alpha-only AnimationGroup on the holder - see StartPulse/
    -- StopPulse. No Scale/Translation/color animation anywhere on this bar.
    local pulseAnim = holder:CreateAnimationGroup();
    pulseAnim:SetLooping("REPEAT");
    local pulseDown = pulseAnim:CreateAnimation("Alpha");
    pulseDown:SetOrder(1);
    pulseDown:SetFromAlpha(1);
    pulseDown:SetToAlpha(0.55);
    pulseDown:SetDuration(pulseDuration / 2);
    pulseDown:SetSmoothing("IN_OUT");
    local pulseUp = pulseAnim:CreateAnimation("Alpha");
    pulseUp:SetOrder(2);
    pulseUp:SetFromAlpha(0.55);
    pulseUp:SetToAlpha(1);
    pulseUp:SetDuration(pulseDuration / 2);
    pulseUp:SetSmoothing("IN_OUT");

    local bar = setmetatable({
        track = track, trackBg = trackBg, holder = holder, fill = fill, glow = glow,
        sheenClip = sheenClip, sheen = sheen, sheenWidth = sheenWidth, sheenPeriod = sheenPeriod,
        sheenHideWidth = sheenHideWidth, lastFillWidth = 0,
        pulseAnim = pulseAnim,
        defaultGlowAlpha = opts.glowAlpha or 0.5,
        glowStrengthWidth = opts.glowStrengthWidth or 40,
        glowHideWidth = opts.glowHideWidth or 6,
        variants = opts.variants or { running = { from = Colors.controlFocus, to = Colors.gold } },
    }, TimerBarMethods);

    bar:SetVariant("running");

    return bar;
end

--------------------------------------------------------------------------
-- Skin.ConfirmPopup - the scrim+dialog+shadow+Cancel/primary-buttons+
-- Enter/Escape-keys chrome shared by UI/AwardWindow.lua's assign/reassign
-- popup and UI/RollWindow.lua's award/reassign popup, so both always look
-- and behave identically. Extracted from AwardWindow's original hand-built
-- popup (ensurePopup/ShowPopup/HidePopup/ConfirmPopup) - only the CHROME is
-- shared here; each caller still builds and lays out its own summary
-- content (see Show below), since that part is irreducibly per-window (a
-- hand-accumulated top-down y cursor through whatever rows that window's
-- summary needs).
--------------------------------------------------------------------------

local CONFIRMPOPUP_SHADOW_TEXTURE = "Interface\\AddOns\\ForeverLoot\\Media\\Respond\\SoftGlow";

--- Same 3-line flat button Widgets.CreateFlatButton builds - inlined here
--- rather than depending on UI/SettingsWindow/Widgets.lua, which loads AFTER
--- this file (see ForeverLoot.toc) and itself depends on Skin.Button.
local function makeFlatButton(parent, label, variant)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate");
    local text = button:CreateFontString(nil, "OVERLAY");
    text:SetPoint("CENTER");
    button.text = text;
    Skin.Button(button, variant);
    button.text:SetText(label);
    return button;
end

local ConfirmPopupMethods = {};
ConfirmPopupMethods.__index = ConfirmPopupMethods;

--- Sets the buttons' labels and click handlers. `onConfirm`/`onCancel`/
--- `onMiddle` fire AFTER the popup is already hidden (mirrors the original
--- AwardWindow's HidePopup-then-applyAward order), so a handler that reopens
--- another window/popup never fights this one's own Hide().
---
--- `middleText`/`onMiddle` are optional - when omitted, the 3rd button stays
--- hidden and the layout is the original 2-button one (AwardWindow.lua never
--- passes them). When given, a 3rd button appears between Cancel and the
--- primary button; unlike Confirm/Cancel it isn't wired to Enter/Escape.
function ConfirmPopupMethods:SetButtons(cancelText, confirmText, onConfirm, onCancel, middleText, onMiddle)
    self.cancelButton.text:SetText(cancelText or "Cancel");
    self.confirmButton.text:SetText(confirmText or "Confirm");
    self.onConfirm = onConfirm;
    self.onCancel = onCancel;

    if (middleText) then
        self.middleButton.text:SetText(middleText);
        self.middleButton:SetScript("OnClick", function()
            if (not self.shown) then return; end
            self:Hide();
            if (onMiddle) then onMiddle(); end
        end);
        self.middleButton:Show();
    else
        self.middleButton:Hide();
    end
end

function ConfirmPopupMethods:SetConfirmEnabled(enabled)
    self.confirmButton:SetEnabled(enabled ~= false);
end

function ConfirmPopupMethods:Hide()
    self.shown = false;
    self.dialog:EnableKeyboard(false);
    self.dialog:Hide();
    self.scrim:Hide();
end

function ConfirmPopupMethods:Confirm()
    if (not self.shown) then return; end
    local onConfirm = self.onConfirm;
    self:Hide();
    if (onConfirm) then onConfirm(); end
end

local function cancelPopup(self)
    if (not self.shown) then return; end
    local onCancel = self.onCancel;
    self:Hide();
    if (onCancel) then onCancel(); end
end

--- Opens the popup. `buildContentFn(dialog, y)` - if given - is called fresh
--- every open to lay out this caller's own summary/warning/note content
--- below the title (which the caller sets directly via `popup.title:SetText`
--- before calling this), returning the new (more negative) y cursor to
--- continue from - same top-down accumulation AwardWindow's original
--- ShowPopup used. This function finishes the layout itself (buttons, then
--- SetHeight) after the callback returns.
function ConfirmPopupMethods:Show(buildContentFn)
    self.confirmButton:SetEnabled(true);

    local p = self.opts;
    local y = -p.padding;
    self.dialog.title:ClearAllPoints();
    self.dialog.title:SetPoint("TOP", self.dialog, "TOP", 0, y);
    y = y - p.titleHeight - p.sectionGap;

    if (buildContentFn) then
        y = buildContentFn(self.dialog, y);
    end

    self.confirmButton:ClearAllPoints();
    self.confirmButton:SetPoint("TOPRIGHT", self.dialog, "TOPRIGHT", -p.padding, y);

    self.cancelButton:ClearAllPoints();
    self.middleButton:ClearAllPoints();
    if (self.middleButton:IsShown()) then
        self.middleButton:SetPoint("TOPRIGHT", self.confirmButton, "TOPLEFT", -p.buttonGap, 0);
        self.cancelButton:SetPoint("TOPRIGHT", self.middleButton, "TOPLEFT", -p.buttonGap, 0);
    else
        self.cancelButton:SetPoint("TOPRIGHT", self.confirmButton, "TOPLEFT", -p.buttonGap, 0);
    end

    y = y - p.buttonHeight - p.padding;

    self.dialog:SetHeight(-y);

    self.scrim:Show();
    self.dialog:Show();
    self.dialog:EnableKeyboard(true);
    self.shown = true;
end

--- Builds a new confirm popup as a child of `parent` (a window's own root
--- frame) - scrim, dialog (with drop shadow), title, and Cancel/primary
--- buttons, all pre-styled. `popup.dialog`/`popup.title` are exposed for the
--- caller to anchor its own content to.
---
--- opts: width, padding, titleHeight, sectionGap, buttonWidth, buttonHeight,
---   buttonGap, shadowInset, overlayColor (default Colors.awardOverlay), and
---   scrimTopInset - how far down from `parent`'s own top the scrim starts,
---   so it clears a caller's own title bar instead of covering it too.
function Skin.ConfirmPopup(parent, opts)
    opts = opts or {};
    opts.padding = opts.padding or 14;
    opts.titleHeight = opts.titleHeight or 18;
    opts.sectionGap = opts.sectionGap or 10;
    opts.buttonHeight = opts.buttonHeight or 22;
    opts.buttonGap = opts.buttonGap or 8;
    opts.buttonWidth = opts.buttonWidth or 90;
    opts.shadowInset = opts.shadowInset or 8;
    opts.width = opts.width or 290;
    opts.scrimTopInset = opts.scrimTopInset or 0;

    local scrim = CreateFrame("Frame", nil, parent);
    scrim:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -opts.scrimTopInset);
    scrim:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0);
    scrim:SetFrameLevel(parent:GetFrameLevel() + 50);
    scrim:EnableMouse(true);
    local scrimTex = scrim:CreateTexture(nil, "BACKGROUND");
    scrimTex:SetAllPoints();
    scrimTex:SetColorTexture(unpack(opts.overlayColor or Colors.awardOverlay));
    scrim:Hide();

    local dialog = CreateFrame("Frame", nil, scrim, "BackdropTemplate");
    dialog:SetFrameLevel(scrim:GetFrameLevel() + 5);
    dialog:SetWidth(opts.width);
    dialog:SetPoint("CENTER", scrim, "CENTER", 0, 0);
    dialog:EnableMouse(true);
    Skin.Backdrop(dialog, Colors.windowBg, Colors.controlFocus);

    local shadow = dialog:CreateTexture(nil, "BACKGROUND", nil, -1);
    shadow:SetTexture(CONFIRMPOPUP_SHADOW_TEXTURE);
    shadow:SetPoint("TOPLEFT", dialog, "TOPLEFT", -opts.shadowInset, opts.shadowInset);
    shadow:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", opts.shadowInset, -opts.shadowInset);

    dialog.title = dialog:CreateFontString(nil, "OVERLAY");
    SetFont(dialog.title, "windowTitle");
    dialog.title:SetTextColor(unpack(Colors.gold));

    local popup = setmetatable({ scrim = scrim, dialog = dialog, opts = opts }, ConfirmPopupMethods);

    scrim:SetScript("OnMouseUp", function() cancelPopup(popup); end);

    popup.cancelButton = makeFlatButton(dialog, "Cancel", "default");
    popup.cancelButton:SetSize(opts.buttonWidth, opts.buttonHeight);
    popup.cancelButton:SetScript("OnClick", function() cancelPopup(popup); end);

    -- Optional 3rd button (e.g. RollWindow.lua's "Reassign") - built once,
    -- hidden by default, so every existing 2-button caller (AwardWindow.lua)
    -- is unaffected unless it opts in via SetButtons' extra args.
    popup.middleButton = makeFlatButton(dialog, "", "default");
    popup.middleButton:SetSize(opts.buttonWidth, opts.buttonHeight);
    popup.middleButton:Hide();

    popup.confirmButton = makeFlatButton(dialog, "Confirm", "primary");
    popup.confirmButton:SetSize(opts.buttonWidth, opts.buttonHeight);
    popup.confirmButton:SetScript("OnClick", function() popup:Confirm(); end);

    dialog:EnableKeyboard(false);
    dialog:SetScript("OnKeyDown", function(self, key)
        if (key == "ESCAPE") then
            self:SetPropagateKeyboardInput(false);
            cancelPopup(popup);
        elseif (key == "ENTER") then
            self:SetPropagateKeyboardInput(false);
            if (popup.confirmButton:IsEnabled()) then popup:Confirm(); end
        else
            self:SetPropagateKeyboardInput(true);
        end
    end);

    dialog:Hide();

    return popup;
end
