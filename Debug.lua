local FL = ForeverLoot;

-- Shared with the options panel's "Reset Window Positions" button.
local function resetAllWindowPositions()
    if (FL.UI.RollWindow and FL.UI.RollWindow.ResetPosition) then FL.UI.RollWindow.ResetPosition(); end
    if (FL.UI.GroupLootRollBars and FL.UI.GroupLootRollBars.ResetPosition) then FL.UI.GroupLootRollBars.ResetPosition(); end
    if (FL.UI.SoftResImport and FL.UI.SoftResImport.ResetPosition) then FL.UI.SoftResImport.ResetPosition(); end
    if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.ResetPosition) then FL.UI.TradeQueueWindow.ResetPosition(); end
    if (FL.UI.LootCouncilAddItemsWindow and FL.UI.LootCouncilAddItemsWindow.ResetPosition) then FL.UI.LootCouncilAddItemsWindow.ResetPosition(); end
end
FL.ResetAllWindowPositions = resetAllWindowPositions;

-- Loot Council entry point. Phase 1: with no arguments, always opens the
-- leader's Add Items window. Later phases extend the no-argument case to show
-- the raider response window (if a session is active) or a "no active
-- session" panel with a request button (Phase 9) instead, depending on the
-- player's role and local session state.
SLASH_FOREVERLOOTLC1 = "/flc";
SlashCmdList["FOREVERLOOTLC"] = function(msg)
    local firstWord, rest = string.match(strtrim(msg or ""), "^(%S*)%s*(.-)$");

    if (firstWord and string.lower(firstWord) == "add") then
        local added, skipped, found = FL.LootCouncil.DraftAddItemsFromText(rest);
        if (not found) then
            print("|cff8865ffForeverLoot|r No item link found. Usage: /flc add [item link] [item link] ...");
        else
            local suffix = skipped > 0 and (" (%d already in list)"):format(skipped) or "";
            print(("|cff8865ffForeverLoot|r Added %d item%s to the loot council list%s."):format(added, added == 1 and "" or "s", suffix));
            if (FL.UI.LootCouncilAddItemsWindow and FL.UI.LootCouncilAddItemsWindow.Show) then
                FL.UI.LootCouncilAddItemsWindow.Show();
            end
        end
        return;
    end

    if (FL.UI.LootCouncilAddItemsWindow and FL.UI.LootCouncilAddItemsWindow.Toggle) then
        FL.UI.LootCouncilAddItemsWindow.Toggle();
    end
end;

SLASH_FOREVERLOOT1 = "/fl";
SlashCmdList["FOREVERLOOT"] = function(msg)
    msg = string.lower(strtrim(msg or ""));

    if (msg == "") then
        if (FL.UI.OptionsPanel and FL.UI.OptionsPanel.Open) then
            FL.UI.OptionsPanel.Open();
        end
    elseif (msg == "commdebug") then
        FL.Comm.debugEnabled = not FL.Comm.debugEnabled;
        print(("|cff8865ffForeverLoot|r comm debug: %s"):format(FL.Comm.debugEnabled and "ON" or "OFF"));
    elseif (msg == "roll" or msg == "rollwindow") then
        if (FL.UI.RollWindow and FL.UI.RollWindow.Toggle) then
            FL.UI.RollWindow.Toggle();
        end
    elseif (msg == "softres" or msg == "sr") then
        if (FL.UI.SoftResImport and FL.UI.SoftResImport.Toggle) then
            FL.UI.SoftResImport.Toggle();
        end
    elseif (msg == "tradequeue" or msg == "tq" or msg == "trade") then
        if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Toggle) then
            FL.UI.TradeQueueWindow.Toggle();
        end
    elseif (msg == "options" or msg == "config" or msg == "settings") then
        if (FL.UI.OptionsPanel and FL.UI.OptionsPanel.Open) then
            FL.UI.OptionsPanel.Open();
        end
    elseif (msg == "resetpositions" or msg == "resetpos") then
        resetAllWindowPositions();
        print("|cff8865ffForeverLoot|r window positions reset to default.");
    else
        print("|cff8865ffForeverLoot|r commands:");
        print("  /fl commdebug - toggle printing of decoded comm traffic");
        print("  /fl roll - toggle the roll tracker window");
        print("  /fl softres - open the SoftRes import window");
        print("  /fl tradequeue - open the trade queue window");
        print("  /flc - open the loot council window");
        print("  /flc add [item link] [item link] ... - add item(s) to the loot council list");
        print("  /fl options - open the settings panel");
        print("  /fl resetpositions - reset all window positions to their defaults");
    end
end;
