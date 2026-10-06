--[[
Trade Queue bag highlight: puts a "GCD" ants glow, tinted with the item's
quality color, on every bag slot holding an item that's still waiting in the
Trade Queue (FL.Trade.Queue). Two bag addons are supported, each through its
own public extension point:

- EllesmereUI Bags: EUI_Bags.RegisterItemOverlayIcon(name, fn), which runs
  fn(btn, data) for every painted slot after Ellesmere's own render - see
  "EllesmereUI Bags Custom Item Borders.md" for the rules followed here:
  btn is a pooled, secure container button, so nothing is ever stored on
  it - our glow frames live in our own weak-keyed table, parented to
  btn._textOverlay - and every non-matching slot hides whatever we drew on
  it before, since the same button is reused for a different item.

- Baganator: it has no full-slot overlay hook, only corner widgets
  (Baganator.API.RegisterCornerWidget). Its corner callback runs per item
  and only stops at the first widget in a corner that RETURNS true, so ours
  always returns false and shows its own frame itself - re-anchored over
  the whole button - leaving that corner free for Baganator's own widgets.
  Baganator hides every corner widget at the start of each item refresh,
  which clears our glow on pooled/emptied buttons for free. Registered at
  priority 1 (top-left) so it runs before anything that could claim the
  corner first; if the player drags it lower in Baganator's Corners
  settings, a widget above it that shows will stop it from running.

The glow itself is EllesmereUI's shared engine (EllesmereUI.Glows, style 5
"GCD") when EllesmereUI is loaded, else a local copy of that same flipbook
(startGlow below) - so Baganator-only users get the identical look.

Matching is by itemID (same rule as Tooltip.lua's "Pending Trade" lines),
limited to your own live bags 0-4 - the only containers Trade.lua's own bag
scan trades from, so bank, reagent-bag and other characters' (Baganator
cached view) copies stay unlit.

General settings page > "Trade Queue" toggles this
(FL.Settings.GetBagTradeQueueHighlightEnabled); the checkbox is greyed out
when BagHighlight.IsAvailable() is false (neither addon loaded).
]]

local FL = ForeverLoot;
local BagHighlight = FL.BagHighlight;

local PAINTER = "ForeverLoot_TradeQueueHighlight";
local BAGANATOR_WIDGET_ID = "foreverloot_trade_queue";
local BAGANATOR_WIDGET_LABEL = "ForeverLoot: Trade Queue glow";

-- EllesmereUI.Glows.STYLES index of "GCD", and that style's own flipbook
-- parameters (EllesmereUI_Glows.lua's GLOW_STYLES entry + StartFlipBookGlow
-- defaults) for the local copy used when EllesmereUI isn't loaded.
local GLOW_STYLE_GCD = 5;
local GCD_ATLAS = "RotationHelper_Ants_Flipbook";
local GCD_TEX_PADDING = 1.6;
local GCD_ROWS, GCD_COLUMNS, GCD_FRAMES, GCD_DURATION = 6, 5, 30, 1.0;
local GCD_ANTS_ALPHA = 0.35;

local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded;

-- itemID -> true for every entry currently in FL.Trade.Queue, rebuilt by
-- BagHighlight.Refresh whenever the queue changes (Trade.lua's queueChanged).
local queuedItemIDs = {};

-- wrapper -> "r:g:b" of its running glow, so a repaint of a slot that's
-- already glowing the same color doesn't restart the flipbook animation.
local activeColor = setmetatable({}, { __mode = "k" });
-- wrapper -> our local flipbook regions (only when EllesmereUI isn't loaded).
local flipData = setmetatable({}, { __mode = "k" });

local ellesmereRegistered = false;
local baganatorRegistered = false;

local function isLoaded(addonName)
    return IsAddOnLoaded and IsAddOnLoaded(addonName) and true or false;
end

local function ellesmereGlowsAvailable()
    return EllesmereUI ~= nil and EllesmereUI.Glows ~= nil and EllesmereUI.Glows.StartGlow ~= nil;
end

local function ellesmereBagsAvailable()
    return isLoaded("EllesmereUIBags") and EUI_Bags ~= nil and EUI_Bags.RegisterItemOverlayIcon ~= nil
        and ellesmereGlowsAvailable();
end

local function baganatorAvailable()
    return isLoaded("Baganator") and Baganator ~= nil and Baganator.API ~= nil
        and Baganator.API.RegisterCornerWidget ~= nil;
end

--- True when a supported bag addon (EllesmereUI Bags or Baganator) is loaded.
function BagHighlight.IsAvailable()
    return ellesmereBagsAvailable() or baganatorAvailable();
end

local function isEnabled()
    return FL.Settings.GetBagTradeQueueHighlightEnabled();
end

local function qualityColor(quality)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality or 1];
    if (c) then return c.r, c.g, c.b; end
    return 1, 1, 1;
end

--------------------------------------------------------------------------
-- Glow: EllesmereUI's engine when present, else a local GCD flipbook copy
--------------------------------------------------------------------------

local function ensureFlip(wrapper)
    local d = flipData[wrapper];
    if (d) then return d; end

    local function flipbookTexture(blendMode)
        local tex = wrapper:CreateTexture(nil, "OVERLAY", nil, 7);
        tex:SetPoint("CENTER");
        if (blendMode) then tex:SetBlendMode(blendMode); end
        tex:SetAtlas(GCD_ATLAS);
        local ag = tex:CreateAnimationGroup();
        ag:SetLooping("REPEAT");
        local anim = ag:CreateAnimation("FlipBook");
        anim:SetFlipBookRows(GCD_ROWS);
        anim:SetFlipBookColumns(GCD_COLUMNS);
        anim:SetFlipBookFrames(GCD_FRAMES);
        anim:SetDuration(GCD_DURATION);
        anim:SetFlipBookFrameWidth(0);
        anim:SetFlipBookFrameHeight(0);
        tex:Hide();
        return tex, ag;
    end

    d = {};
    d.tex, d.ag = flipbookTexture(nil);
    d.ants, d.antsAg = flipbookTexture("ADD");
    d.ants:SetAlpha(GCD_ANTS_ALPHA);
    flipData[wrapper] = d;
    return d;
end

local function startGlow(wrapper, w, h, r, g, b)
    if (ellesmereGlowsAvailable()) then
        EllesmereUI.Glows.StartGlow(wrapper, GLOW_STYLE_GCD, w, r, g, b, nil, h);
        return;
    end

    local d = ensureFlip(wrapper);
    -- Tinted layer (desaturated + quality color) plus an untinted ants
    -- layer on top at low alpha - same two layers Ellesmere draws.
    d.tex:SetSize(w * GCD_TEX_PADDING, h * GCD_TEX_PADDING);
    d.tex:SetDesaturated(true);
    d.tex:SetVertexColor(r, g, b);
    d.ants:SetSize(w * GCD_TEX_PADDING, h * GCD_TEX_PADDING);
    d.tex:Show();
    d.ants:Show();
    d.ag:Stop(); d.ag:Play();
    d.antsAg:Stop(); d.antsAg:Play();
end

local function stopGlow(wrapper)
    if (not activeColor[wrapper]) then return; end
    activeColor[wrapper] = nil;

    local d = flipData[wrapper];
    if (d) then
        d.ag:Stop(); d.tex:Hide();
        d.antsAg:Stop(); d.ants:Hide();
    end
    if (ellesmereGlowsAvailable()) then
        EllesmereUI.Glows.StopGlow(wrapper);
    end
end

-- Starts (or recolors) the glow on `wrapper`, sized to `w` x `h`. A no-op
-- when it's already glowing in this color, unless `force` (Baganator path,
-- whose widget was hidden and re-shown since the last call).
local function showGlow(wrapper, w, h, quality, force)
    local r, g, b = qualityColor(quality);
    local colorKey = ("%.3f:%.3f:%.3f"):format(r, g, b);
    if (activeColor[wrapper] == colorKey and not force) then return; end

    if (not w or w == 0) then w, h = 34, 34; end
    startGlow(wrapper, w, h, r, g, b);
    activeColor[wrapper] = colorKey;
end

local function isQueuedInOwnBags(itemID, bag)
    return itemID ~= nil and queuedItemIDs[itemID] == true
        and bag ~= nil and bag >= 0 and bag <= 4;
end

--------------------------------------------------------------------------
-- EllesmereUI Bags backend
--------------------------------------------------------------------------

-- Our glow wrapper per Ellesmere button - weak keys, never stored on btn.
local ellesmereWrappers = setmetatable({}, { __mode = "k" });

---@param btn Button
---@param data { bag: number, slot: number, info: table?, itemLink: string? }
local function ellesmerePaint(btn, data)
    local info = data.info;
    if (not (info and isQueuedInOwnBags(info.itemID, data.bag)) or not btn._textOverlay) then
        local wrapper = ellesmereWrappers[btn];
        if (wrapper) then stopGlow(wrapper); end
        return;
    end

    local wrapper = ellesmereWrappers[btn];
    if (not wrapper) then
        wrapper = CreateFrame("Frame", nil, btn._textOverlay);
        wrapper:SetAllPoints(btn._textOverlay);
        ellesmereWrappers[btn] = wrapper;
    end

    local w, h = btn._textOverlay:GetSize();
    showGlow(wrapper, w, h, info.quality, false);
end

local function applyEllesmere()
    if (not ellesmereBagsAvailable()) then return; end

    if (isEnabled()) then
        EUI_Bags.RegisterItemOverlayIcon(PAINTER, ellesmerePaint);
        ellesmereRegistered = true;
    elseif (ellesmereRegistered) then
        EUI_Bags.UnregisterItemOverlayIcon(PAINTER);
        for _, wrapper in pairs(ellesmereWrappers) do stopGlow(wrapper); end
        if (EUI_Bags.RefreshInventory) then EUI_Bags:RefreshInventory(); end
        ellesmereRegistered = false;
    end
end

--------------------------------------------------------------------------
-- Baganator backend
--------------------------------------------------------------------------

-- Corner widget frame -> the item button it belongs to (from onInit).
local baganatorButtons = setmetatable({}, { __mode = "k" });

local function baganatorInit(itemButton)
    local widget = CreateFrame("Frame", nil, itemButton);
    widget:SetSize(1, 1);
    baganatorButtons[widget] = itemButton;
    return widget;
end

-- Always returns false (see this file's header comment) - when the item is
-- queued, the widget is shown and stretched over the button here instead.
local function baganatorUpdate(widget, details)
    local itemButton = baganatorButtons[widget];
    local location = details and details.itemLocation;
    if (not itemButton or not isEnabled()
        or not isQueuedInOwnBags(details.itemID, location and location.bagID)) then
        return false;
    end

    -- Baganator anchors the widget to one corner (ApplyItemDetailSettings);
    -- cover the whole button instead so the glow surrounds the icon.
    widget:ClearAllPoints();
    widget:SetAllPoints(itemButton);
    widget:Show();

    local w, h = itemButton:GetSize();
    showGlow(widget, w, h, details.quality, true);
    return false;
end

local function applyBaganator()
    if (not baganatorAvailable()) then return; end

    -- Baganator has no unregister API - register once and gate on the
    -- setting inside baganatorUpdate instead.
    if (not baganatorRegistered) then
        Baganator.API.RegisterCornerWidget(BAGANATOR_WIDGET_LABEL, BAGANATOR_WIDGET_ID,
            baganatorUpdate, baganatorInit, { corner = "top_left", priority = 1 }, true);
        baganatorRegistered = true;
    end
end

--------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------

--- Rebuilds the queued-item set and repaints the bags (a no-op while
--- they're closed - they repaint on open anyway).
function BagHighlight.Refresh()
    wipe(queuedItemIDs);
    for _, entry in ipairs(FL.Trade.Queue or {}) do
        if (entry.itemID) then queuedItemIDs[entry.itemID] = true; end
    end

    if (ellesmereRegistered and EUI_Bags and EUI_Bags.RefreshInventory) then
        EUI_Bags:RefreshInventory();
    end
    if (baganatorRegistered and Baganator.API.RequestItemButtonsRefresh) then
        Baganator.API.RequestItemButtonsRefresh();
    end
end

--- Registers/unregisters with each loaded bag addon to match the setting.
function BagHighlight.Apply()
    applyEllesmere();
    applyBaganator();
    BagHighlight.Refresh();
end

function BagHighlight.Init()
    BagHighlight.Apply();
end
