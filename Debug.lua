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

-- Loot Council entry point. With no arguments: council members (and a
-- session initiator who forgot to add themselves to the roster - see
-- LootCouncil.CanAccessReviewWindow) get the Review and Award window;
-- everyone else still gets the leader's Start Session window. Later
-- phases extend this further - a raider-facing "no active session" panel
-- with a request button (Phase 9) - depending on role and local session
-- state.
-- Shared between "/flc help" and "/fl"'s full command dump below, so the
-- two lists can't drift out of sync with each other.
local function printLootCouncilHelp()
    print("|cff8865ffForeverLoot|r loot council commands:");
    print("  /flc - open the loot council window");
    print("  /flc add [item link] [item link] ... - add item(s) to the loot council list");
    print("  /flc start - open the start session window");
    print("  /flc council add [name] - add a player (or yourself, if no name) to the council roster");
    print("  /flc council remove <name> - remove a player from the council roster");
    print("  /flc council list - list current council roster members");
    print("  /flc help - show this list");
end

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

    -- Roster management stopgap ahead of Phase 7's dedicated UI window.
    if (firstWord and string.lower(firstWord) == "council") then
        local subCmd, name = string.match(rest, "^(%S*)%s*(.-)$");
        subCmd = string.lower(subCmd or "");
        name = strtrim(name or "");

        if (subCmd == "add") then
            if (name == "") then name = UnitName("player"); end
            if (FL.LootCouncil.RosterAdd(name)) then
                print(("|cff8865ffForeverLoot|r Added %s to the saved loot council roster."):format(name));
            else
                print(("|cff8865ffForeverLoot|r %s is already on the saved loot council roster."):format(name));
            end
        elseif (subCmd == "remove") then
            if (name == "") then
                print("|cff8865ffForeverLoot|r Usage: /flc council remove <name>");
            elseif (FL.LootCouncil.RosterRemove(name)) then
                print(("|cff8865ffForeverLoot|r Removed %s from the saved loot council roster."):format(name));
            else
                print(("|cff8865ffForeverLoot|r %s is not on the saved loot council roster."):format(name));
            end
        elseif (subCmd == "list") then
            local names = FL.LootCouncil.RosterNames();
            if (#names == 0) then
                print("|cff8865ffForeverLoot|r Saved loot council roster is empty.");
            else
                print(("|cff8865ffForeverLoot|r Saved loot council roster: %s"):format(table.concat(names, ", ")));
            end
            if (FL.LootCouncil.CurrentSession) then
                local council = FL.LootCouncil.SessionCouncilNames();
                print(("|cff8865ffForeverLoot|r Session #%s council: %s"):format(tostring(FL.LootCouncil.CurrentSession.id),
                    (#council > 0) and table.concat(council, ", ") or "(none)"));
            end
        else
            print("|cff8865ffForeverLoot|r Usage: /flc council add|remove|list [name]");
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
    -- `original` keeps its case for "/fl sync dump <id>" below, since ids are
    -- case-sensitive - every other branch still matches on the lowercased
    -- `msg`, unchanged from before.
    local original = strtrim(rawMsg or "");
    local msg = string.lower(original);

    if (msg == "") then
        if (FL.UI.SettingsWindow and FL.UI.SettingsWindow.Show) then
            FL.UI.SettingsWindow.Show();
        end
    elseif (msg == "commdebug") then
        -- Retired: these lines now go to the main debug log.
        print("|cff8865ffForeverLoot|r Council, roll and softres debug lines are now part of /fl debug (categories COUNCIL, ROLL, SOFTRES; Gargul-channel traffic is COMM at level 2).");
    elseif (msg == "roll" or msg == "rollwindow") then
        if (FL.UI.RollWindow and FL.UI.RollWindow.Toggle) then
            FL.UI.RollWindow.Toggle();
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
    elseif (msg == "options") then
        if (FL.UI.OptionsPanel and FL.UI.OptionsPanel.Open) then
            FL.UI.OptionsPanel.Open();
        end
    elseif (msg == "resetpositions" or msg == "resetpos") then
        resetAllWindowPositions();
        print("|cff8865ffForeverLoot|r window positions reset to default.");
    elseif (msg == "autoroll") then
        FL.AutoRoll.HandleSlashAutoroll();
    elseif (msg == "minimap") then
        local shown = FL.UI.MinimapButton.ToggleShown();
        print(("|cff8865ffForeverLoot|r minimap button: %s"):format(shown and "shown" or "hidden"));
    -- Unrelated to "commdebug" above (which toggles raw comm-traffic
    -- printing): this is the history-sync system's own logging/status tools
    -- (Sync/Debug.lua), gated separately via ForeverLootDB.debug.
    elseif (string.match(msg, "^debug%s") or msg == "debug") then
        local rest = string.match(msg, "^debug%s*(.-)$") or "";
        if (FL.Sync.Debug and FL.Sync.Debug.HandleSlash) then
            FL.Sync.Debug.HandleSlash(rest);
        end
    elseif (string.match(msg, "^sync%s") or msg == "sync") then
        local prefix = string.match(msg, "^sync%s*") or "sync";
        local rest = original:sub(#prefix + 1); -- case-preserved, for "dump <id>"
        if (FL.Sync.Debug and FL.Sync.Debug.HandleSyncSlash) then
            FL.Sync.Debug.HandleSyncSlash(rest);
        end
    else
        print("|cff8865ffForeverLoot|r commands:");
        print("  /fl roll - toggle the roll tracker window");
        print("  /fl softres - open the SoftRes import window");
        print("  /fl tradequeue - open the trade queue window");
        print("  /fl history (or /fl h) - open the loot history window");
        print("  /fl autoroll - open the Automatic Rolls popup for your current raid or dungeon");
        printLootCouncilHelp();
        print("  /fl config (or /fl c) - open ForeverLoot's settings window");
        print("  /fl options - open the Blizzard-side options panel (Escape menu)");
        print("  /fl minimap - show/hide the minimap button");
        print("  /fl resetpositions - reset all window positions to their defaults");
        print("  /fl debug - open the Debug Log window (/fl debug help lists the debug commands)");
        print("  /fl sync status|dump <id>|digest [months|days <monthKey>]|domains|peers - history-sync status, dump, digest, domains, or peers");
    end
end;
