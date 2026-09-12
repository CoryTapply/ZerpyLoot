local ZL = ZerpyLoot;

-- Shared with the options panel's "Reset Window Positions" button.
local function resetAllWindowPositions()
    if (ZL.UI.RollWindow and ZL.UI.RollWindow.ResetPosition) then ZL.UI.RollWindow.ResetPosition(); end
    if (ZL.UI.GroupLootRollBars and ZL.UI.GroupLootRollBars.ResetPosition) then ZL.UI.GroupLootRollBars.ResetPosition(); end
    if (ZL.UI.SoftResImport and ZL.UI.SoftResImport.ResetPosition) then ZL.UI.SoftResImport.ResetPosition(); end
    if (ZL.UI.TradeQueueWindow and ZL.UI.TradeQueueWindow.ResetPosition) then ZL.UI.TradeQueueWindow.ResetPosition(); end
end
ZL.ResetAllWindowPositions = resetAllWindowPositions;

SLASH_ZERPYLOOT1 = "/zl";
SlashCmdList["ZERPYLOOT"] = function(msg)
    msg = string.lower(strtrim(msg or ""));

    if (msg == "commdebug") then
        ZL.Comm.debugEnabled = not ZL.Comm.debugEnabled;
        print(("|cff8865ffZerpyLoot|r comm debug: %s"):format(ZL.Comm.debugEnabled and "ON" or "OFF"));
    elseif (msg == "roll" or msg == "rollwindow") then
        if (ZL.UI.RollWindow and ZL.UI.RollWindow.Toggle) then
            ZL.UI.RollWindow.Toggle();
        end
    elseif (msg == "grouploot" or msg == "gl") then
        local enabled = not ZL.Settings.GetGroupLootRollEnabled();
        ZL.Settings.SetGroupLootRollEnabled(enabled);
        print(("|cff8865ffZerpyLoot|r Group Loot roll UI: %s (reload UI for this to take effect)"):format(enabled and "ON" or "OFF"));
    elseif (msg == "softres" or msg == "sr") then
        if (ZL.UI.SoftResImport and ZL.UI.SoftResImport.Toggle) then
            ZL.UI.SoftResImport.Toggle();
        end
    elseif (msg == "tradequeue" or msg == "tq" or msg == "trade") then
        if (ZL.UI.TradeQueueWindow and ZL.UI.TradeQueueWindow.Toggle) then
            ZL.UI.TradeQueueWindow.Toggle();
        end
    elseif (msg == "options" or msg == "config" or msg == "settings") then
        if (ZL.UI.OptionsPanel and ZL.UI.OptionsPanel.Open) then
            ZL.UI.OptionsPanel.Open();
        end
    elseif (msg == "resetpositions" or msg == "resetpos") then
        resetAllWindowPositions();
        print("|cff8865ffZerpyLoot|r window positions reset to default.");
    elseif (msg == "pixeldebug" or msg == "pxdebug") then
        if (ZL.UI.SoftResImport and ZL.UI.SoftResImport.Show) then
            ZL.UI.SoftResImport.Show();
        end

        local frame = _G.ZerpyLootSoftResImport;
        if (not frame) then
            print("|cff8865ffZerpyLoot|r pixeldebug: SoftRes window not available");
            return;
        end

        local scale = UIParent:GetEffectiveScale();
        local screenH = UIParent:GetHeight();
        print(("|cff8865ffZerpyLoot|r scale=%.8f unit=%.8f uiScale cvar=%s useUiScale cvar=%s"):format(
            scale, ZL.Pixel.Unit(), tostring(GetCVar("uiScale")), tostring(GetCVar("useUiScale"))
        ));

        local l, r, t, b = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom();
        print(("frame units: L=%.6f R=%.6f T=%.6f B=%.6f W=%.6f H=%.6f"):format(
            l, r, t, b, frame:GetWidth(), frame:GetHeight()
        ));
        print(("frame px:    L=%.6f R=%.6f T=%.6f B=%.6f W=%.6f H=%.6f"):format(
            l * scale, r * scale, (screenH - t) * scale, (screenH - b) * scale,
            frame:GetWidth() * scale, frame:GetHeight() * scale
        ));

        local bd = frame:GetBackdrop();
        if (bd and bd.edgeSize) then
            print(("border edgeSize: %.6f units -> %.6f px"):format(bd.edgeSize, bd.edgeSize * scale));
        else
            print("pixeldebug: no backdrop edgeSize on frame");
        end
    elseif (msg:match("^borderthick")) then
        local frame = _G.ZerpyLootSoftResImport;
        if (not frame) then
            print("|cff8865ffZerpyLoot|r borderthick: open the SoftRes window first with /zl softres");
            return;
        end

        local px = tonumber(msg:match("^borderthick%s+(%S+)$"));
        if (not px) then
            print("|cff8865ffZerpyLoot|r usage: /zl borderthick <pixels, e.g. 0.5, 0.9, 1, 1.5, 2>");
            return;
        end

        ZL.Theme.ApplyBorder(frame, px);
        print(("|cff8865ffZerpyLoot|r border thickness requested at %.4fpx"):format(px));
    else
        print("|cff8865ffZerpyLoot|r commands:");
        print("  /zl commdebug - toggle printing of decoded comm traffic");
        print("  /zl roll - toggle the roll tracker window");
        print("  /zl grouploot - toggle the native Group Loot roll UI (reload required)");
        print("  /zl softres - open the SoftRes import window");
        print("  /zl tradequeue - open the trade queue window");
        print("  /zl options - open the settings panel");
        print("  /zl resetpositions - reset all window positions to their defaults");
        print("  /zl pixeldebug - dump SoftRes window/border pixel math for border-thickness debugging");
        print("  /zl borderthick <px> - live-set the SoftRes border's requested thickness, no reload needed");
    end
end;
