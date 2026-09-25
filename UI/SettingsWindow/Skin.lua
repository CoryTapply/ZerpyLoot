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

function Skin.Checkbox(check)
    local boxSize = Sizes.controls.checkbox;
    check:SetSize(boxSize, boxSize);
    check:SetHitRectInsets(0, 0, 0, 0);

    hideTexture(check:GetNormalTexture());
    hideTexture(check:GetPushedTexture());
    hideTexture(check:GetHighlightTexture());

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
end

--------------------------------------------------------------------------
-- Skin.Button - plain frame-based buttons (this window never uses
-- UIPanelButtonTemplate, so there's no template art to strip here; every
-- caller already gets a bare BackdropTemplate Button from
-- Widgets.CreateFlatButton). `variant` is "default" (every settings button
-- except...) or "primary" (Sync to Raid).
--------------------------------------------------------------------------

function Skin.Button(button, variant)
    variant = (variant == "primary") and "primary" or "default";
    stripButtonArt(button);

    local isPrimary = (variant == "primary");
    local bg = isPrimary and Colors.primaryBg or Colors.defaultBg;
    local border = isPrimary and Colors.primaryBorder or Colors.checkboxBorder;
    local hoverBorder = isPrimary and Colors.gold or Colors.controlHover;
    local textColor = isPrimary and Colors.gold or Colors.textBright;
    local pressedBg = isPrimary and Colors.primaryPressed or bg;

    if (not button.text) then
        local text = button:CreateFontString(nil, "OVERLAY");
        text:SetPoint("CENTER");
        button.text = text;
    end
    SetFont(button.text, "body");

    local function applyEnabled()
        Skin.Backdrop(button, bg, border);
        button.text:SetTextColor(unpack(textColor));
    end
    local function applyDisabled()
        Skin.Backdrop(button, Colors.defaultBg, Colors.disabledBorder);
        button.text:SetTextColor(unpack(Colors.disabledText));
    end

    if (button:IsEnabled()) then applyEnabled(); else applyDisabled(); end

    button:HookScript("OnEnter", function(self)
        if (self:IsEnabled()) then self:SetBackdropBorderColor(unpack(hoverBorder)); end
    end);
    button:HookScript("OnLeave", function(self)
        if (self:IsEnabled()) then
            self:SetBackdropBorderColor(unpack(border));
            self:SetBackdropColor(unpack(bg));
            self.text:SetPoint("CENTER", 0, 0);
        end
    end);
    button:HookScript("OnMouseDown", function(self)
        if (self:IsEnabled()) then
            self:SetBackdropColor(unpack(pressedBg));
            self.text:SetPoint("CENTER", 0, -1);
        end
    end);
    button:HookScript("OnMouseUp", function(self)
        if (self:IsEnabled()) then
            self:SetBackdropColor(unpack(bg));
            self.text:SetPoint("CENTER", 0, 0);
        end
    end);
    button:HookScript("OnEnable", applyEnabled);
    button:HookScript("OnDisable", applyDisabled);
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

    ----------------------------------------------------------------------
    -- Closed button
    ----------------------------------------------------------------------

    local button = CreateFrame("Button", nil, parent, "BackdropTemplate");
    button:SetSize(width, opts.height or Sizes.controls.dropdown);
    Skin.Backdrop(button, Colors.controlBg, Colors.controlBorder);
    Skin.AddInnerShadow(button);

    local arrowBox = CreateFrame("Frame", nil, button, "BackdropTemplate");
    arrowBox:SetSize(Sizes.controls.dropdownArrow, Sizes.controls.dropdownArrow);
    arrowBox:SetPoint("RIGHT", button, "RIGHT", -5, 0);
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
    valueText:SetPoint("LEFT", button, "LEFT", 10, 0);
    valueText:SetPoint("RIGHT", arrowBox, "LEFT", -10, 0);

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
