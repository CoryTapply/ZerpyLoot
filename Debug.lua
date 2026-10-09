local FL = ForeverLoot;

-- Shared with the options panel's "Reset Window Positions" button.
local function resetAllWindowPositions()
    if (FL.UI.RollWindow and FL.UI.RollWindow.ResetPosition) then FL.UI.RollWindow.ResetPosition(); end
    if (FL.UI.GroupLootFrame and FL.UI.GroupLootFrame.ResetPosition) then FL.UI.GroupLootFrame.ResetPosition(); end
    if (FL.UI.SoftResImportWindow and FL.UI.SoftResImportWindow.ResetPosition) then FL.UI.SoftResImportWindow.ResetPosition(); end
    if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.ResetPosition) then FL.UI.TradeQueueWindow.ResetPosition(); end
    if (FL.UI.StartSessionWindow and FL.UI.StartSessionWindow.ResetPosition) then FL.UI.StartSessionWindow.ResetPosition(); end
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.ResetPosition) then FL.UI.RespondWindow.ResetPosition(); end
    if (FL.UI.AwardWindow and FL.UI.AwardWindow.ResetPosition) then FL.UI.AwardWindow.ResetPosition(); end
    if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.ResetPosition) then FL.UI.LootHistoryWindow.ResetPosition(); end
    if (FL.UI.SettingsWindow and FL.UI.SettingsWindow.ResetPosition) then FL.UI.SettingsWindow.ResetPosition(); end
    if (FL.UI.DebugLogWindow and FL.UI.DebugLogWindow.ResetPosition) then FL.UI.DebugLogWindow.ResetPosition(); end
end
FL.ResetAllWindowPositions = resetAllWindowPositions;

-- Shared between "/flc help" and "/fl"'s full command dump below, so the
-- two lists can't drift out of sync with each other.
local function printLootCouncilHelp()
    print("|cff8865ffForeverLoot|r loot council commands:");
    print("  /flc start - open the start session window");
    print("  /flc history (or /flc h) - open the loot history window");
    print("  /flc add [item link] [item link] ... - add item(s) to the loot council session");
    print("  /flc - open the loot council award window if you are on the council");
end

-- Loot Council entry point. With no arguments: council members (and a
-- session initiator who isn't on the council - see
-- LootCouncil.CanAccessReviewWindow) get the Review and Award window;
-- everyone else gets the leader's Start Session window.
SLASH_FOREVERLOOTLC1 = "/flc";
SlashCmdList["FOREVERLOOTLC"] = function(msg)
    local firstWord, rest = string.match(strtrim(msg or ""), "^(%S*)%s*(.-)$");

    if (firstWord and string.lower(firstWord) == "help") then
        printLootCouncilHelp();
        return;
    end

    if (firstWord and string.lower(firstWord) == "start") then
        if (FL.UI.StartSessionWindow and FL.UI.StartSessionWindow.Show) then
            FL.UI.StartSessionWindow.Show();
        end
        return;
    end

    if (firstWord and (string.lower(firstWord) == "history" or string.lower(firstWord) == "h")) then
        if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Toggle) then
            FL.UI.LootHistoryWindow.Toggle();
        end
        return;
    end

    if (firstWord and string.lower(firstWord) == "add") then
        local added, skipped, found = FL.SessionItems.AddItemsFromText(rest);
        if (not found) then
            print("|cff8865ffForeverLoot|r No item link found. Usage: /flc add [item link] [item link] ...");
        else
            local suffix = skipped > 0 and (" (%d already in list)"):format(skipped) or "";
            print(("|cff8865ffForeverLoot|r Added %d item%s to the loot council list%s."):format(added, added == 1 and "" or "s", suffix));
            if (FL.UI.StartSessionWindow and FL.UI.StartSessionWindow.Show) then
                FL.UI.StartSessionWindow.Show();
            end
        end
        return;
    end

    if (FL.LootCouncil.CanAccessReviewWindow and FL.LootCouncil.CanAccessReviewWindow()) then
        if (FL.UI.AwardWindow and FL.UI.AwardWindow.Toggle) then
            FL.UI.AwardWindow.Toggle();
        end
        return;
    end

    if (FL.UI.StartSessionWindow and FL.UI.StartSessionWindow.Toggle) then
        FL.UI.StartSessionWindow.Toggle();
    end
end;

SLASH_FOREVERLOOT1 = "/fl";
SlashCmdList["FOREVERLOOT"] = function(rawMsg)
    -- `original` keeps its case for item links ("/fl roll") and the
    -- unknown-command line; every branch matches on the lowercased `msg`.
    local original = strtrim(rawMsg or "");
    local msg = string.lower(original);

    if (msg == "") then
        if (FL.UI.SettingsWindow and FL.UI.SettingsWindow.Show) then
            FL.UI.SettingsWindow.Show();
        end
    elseif (msg == "commdebug") then
        -- Retired command, kept only to point at its replacement.
        print("|cff8865ffForeverLoot|r Council, roll and softres debug lines are now part of /fl debug (categories COUNCIL, ROLL, SOFTRES; Gargul-channel traffic is COMM at level 2).");
    elseif (string.match(msg, "^roll%s") or msg == "roll") then
        -- Same as alt+left-clicking the item: opens the roll window's
        -- Start Roll prompt, with its in-progress and unawarded-rolls guards.
        local itemLink = FL.SessionItems.ExtractItemLinks(original)[1];
        if (not itemLink) then
            print("|cff8865ffForeverLoot|r No item link found. Usage: /fl roll [item link]");
        elseif (FL.UI.RollWindow and FL.UI.RollWindow.ShowStartPrompt) then
            FL.UI.RollWindow.ShowStartPrompt(itemLink);
        end
    elseif (msg == "softres" or msg == "sr") then
        if (FL.UI.SoftResImportWindow and FL.UI.SoftResImportWindow.Toggle) then
            FL.UI.SoftResImportWindow.Toggle();
        end
    elseif (msg == "tradequeue" or msg == "tq" or msg == "trade") then
        if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Toggle) then
            FL.UI.TradeQueueWindow.Toggle();
        end
    elseif (msg == "history" or msg == "h") then
        if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Toggle) then
            FL.UI.LootHistoryWindow.Toggle();
        end
    elseif (msg == "config" or msg == "c" or msg == "settings") then
        if (FL.UI.SettingsWindow and FL.UI.SettingsWindow.Show) then
            FL.UI.SettingsWindow.Show();
        end
    elseif (msg == "resetpositions" or msg == "resetpos") then
        resetAllWindowPositions();
        print("|cff8865ffForeverLoot|r window positions reset to default.");
    elseif (msg == "autoroll") then
        FL.AutoRoll.HandleSlashAutoroll();
    elseif (msg == "minimap") then
        local shown = FL.UI.MinimapButton.ToggleShown();
        print(("|cff8865ffForeverLoot|r minimap button: %s"):format(shown and "shown" or "hidden"));
    -- Border/pixel-grid diagnostics live in Core/PixelPerfect.lua.
    elseif (string.match(msg, "^pixel%s") or msg == "pixel") then
        FL.Pixel.HandleSlash(string.match(msg, "^pixel%s*(.-)$") or "");
    -- The debug log tools live in Sync/Debug.lua.
    elseif (string.match(msg, "^debug%s") or msg == "debug") then
        local rest = string.match(msg, "^debug%s*(.-)$") or "";
        if (FL.Sync.Debug and FL.Sync.Debug.HandleSlash) then
            FL.Sync.Debug.HandleSlash(rest);
        end
    else
        if (msg ~= "help") then
            print(("|cff8865ffForeverLoot|r Unknown command \"%s\"."):format(original));
        end
        print("|cff8865ffForeverLoot|r commands:");
        print("  /fl roll [item link] - start a roll-off for that item");
        print("  /fl softres (or /fl sr) - open the SoftRes import window");
        print("  /fl tradequeue (or /fl tq, /fl trade) - open the trade queue window");
        print("  /fl autoroll - open the Automatic Rolls popup for your current raid or dungeon");
        print("  /fl history (or /fl h) - open the loot history window");
        print("  /fl config (or /fl c, /fl settings) - open ForeverLoot's settings window");
        print("  /fl minimap - show/hide the minimap button");
        print("  /fl resetpositions (or /fl resetpos) - reset all window positions to their defaults");
        print("  /fl debug - open the Debug Log window (/fl debug help lists the debug commands)");
        print("  /fl help - show this list");
        printLootCouncilHelp();
    end
end;
