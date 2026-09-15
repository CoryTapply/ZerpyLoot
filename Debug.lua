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

    if (msg == "") then
        if (ZL.UI.OptionsPanel and ZL.UI.OptionsPanel.Open) then
            ZL.UI.OptionsPanel.Open();
        end
    elseif (msg == "commdebug") then
        ZL.Comm.debugEnabled = not ZL.Comm.debugEnabled;
        print(("|cff8865ffZerpyLoot|r comm debug: %s"):format(ZL.Comm.debugEnabled and "ON" or "OFF"));
    elseif (msg == "roll" or msg == "rollwindow") then
        if (ZL.UI.RollWindow and ZL.UI.RollWindow.Toggle) then
            ZL.UI.RollWindow.Toggle();
        end
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
    else
        print("|cff8865ffZerpyLoot|r commands:");
        print("  /zl commdebug - toggle printing of decoded comm traffic");
        print("  /zl roll - toggle the roll tracker window");
        print("  /zl softres - open the SoftRes import window");
        print("  /zl tradequeue - open the trade queue window");
        print("  /zl options - open the settings panel");
        print("  /zl resetpositions - reset all window positions to their defaults");
    end
end;
