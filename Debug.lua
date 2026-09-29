local FL = ForeverLoot;

-- ---------------------------------------------------------------------------
-- Disabled-button art test harness (see /fl testdisabled)
-- ---------------------------------------------------------------------------

-- A few Theme-skinned buttons, all pre-disabled, just to eyeball the
-- DISABLED-state art (tinted and untinted) without having to find/force a
-- real disabled button somewhere in the addon's normal flows.
local testDisabledFrame;

local function ensureTestDisabledFrame()
    if (testDisabledFrame) then return testDisabledFrame; end

    local frame = CreateFrame("Frame", "ForeverLootTestDisabledFrame", UIParent, "BackdropTemplate");
    frame:SetSize(200, 190);
    frame:SetPoint("CENTER");
    frame:SetFrameStrata("DIALOG");
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    });
    frame:SetMovable(true);
    frame:EnableMouse(true);
    frame:RegisterForDrag("LeftButton");
    frame:SetScript("OnDragStart", frame.StartMoving);
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing);

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal");
    title:SetPoint("TOP", 0, -12);
    title:SetText("Disabled button test");

    local tintedButton = FL.Theme.CreateButton(frame);
    tintedButton:SetPoint("TOP", title, "BOTTOM", 0, -14);
    tintedButton:SetText("Tinted (Major)");
    FL.Theme.SkinButton(tintedButton, { 0.80, 0.20, 0.20 }); -- was Major's placeholder color (Core/Responses.lua now owns response colors)
    tintedButton:Disable();

    local accentButton = FL.Theme.CreateButton(frame);
    accentButton:SetPoint("TOP", tintedButton, "BOTTOM", 0, -10);
    accentButton:SetText("Accent");
    FL.Theme.SkinAccentButton(accentButton);
    accentButton:Disable();

    local normalButton = FL.Theme.CreateButton(frame);
    normalButton:SetPoint("TOP", accentButton, "BOTTOM", 0, -10);
    normalButton:SetText("Normal");
    FL.Theme.SkinButton(normalButton);
    normalButton:Disable();

    local closeButton = FL.Theme.CreateButton(frame);
    closeButton:SetPoint("TOP", normalButton, "BOTTOM", 0, -10);
    closeButton:SetText("Close");
    FL.Theme.SkinButton(closeButton);
    closeButton:SetScript("OnClick", function() frame:Hide(); end);

    frame:Hide();
    testDisabledFrame = frame;
    return frame;
end

local function toggleTestDisabledFrame()
    local frame = ensureTestDisabledFrame();
    if (frame:IsShown()) then frame:Hide(); else frame:Show(); end
end

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
                print(("|cff8865ffForeverLoot|r Added %s to the loot council roster."):format(name));
            else
                print(("|cff8865ffForeverLoot|r %s is already on the loot council roster."):format(name));
            end
        elseif (subCmd == "remove") then
            if (name == "") then
                print("|cff8865ffForeverLoot|r Usage: /flc council remove <name>");
            elseif (FL.LootCouncil.RosterRemove(name)) then
                print(("|cff8865ffForeverLoot|r Removed %s from the loot council roster."):format(name));
            else
                print(("|cff8865ffForeverLoot|r %s is not on the loot council roster."):format(name));
            end
        elseif (subCmd == "list") then
            local names = FL.LootCouncil.RosterNames();
            if (#names == 0) then
                print("|cff8865ffForeverLoot|r Loot council roster is empty.");
            else
                print(("|cff8865ffForeverLoot|r Loot council roster: %s"):format(table.concat(names, ", ")));
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
SlashCmdList["FOREVERLOOT"] = function(msg)
    msg = string.lower(strtrim(msg or ""));

    if (msg == "") then
        if (FL.UI.SettingsWindow and FL.UI.SettingsWindow.Show) then
            FL.UI.SettingsWindow.Show();
        end
    elseif (msg == "commdebug") then
        FL.Comm.debugEnabled = not FL.Comm.debugEnabled;
        FL.LootCouncil.debugEnabled = FL.Comm.debugEnabled;
        print(("|cff8865ffForeverLoot|r comm debug: %s"):format(FL.Comm.debugEnabled and "ON" or "OFF"));
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
    elseif (msg == "history") then
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
    elseif (msg == "testdisabled") then
        toggleTestDisabledFrame();
    elseif (msg == "autoroll") then
        FL.AutoRoll.HandleSlashAutoroll();
    else
        print("|cff8865ffForeverLoot|r commands:");
        print("  /fl commdebug - toggle printing of decoded comm traffic");
        print("  /fl roll - toggle the roll tracker window");
        print("  /fl softres - open the SoftRes import window");
        print("  /fl tradequeue - open the trade queue window");
        print("  /fl history - open the loot history window");
        print("  /fl autoroll - open the Automatic Rolls popup for your current raid");
        printLootCouncilHelp();
        print("  /fl config (or /fl c) - open ForeverLoot's settings window");
        print("  /fl options - open the Blizzard-side options panel (Escape menu)");
        print("  /fl resetpositions - reset all window positions to their defaults");
        print("  /fl testdisabled - show/hide a test window with disabled buttons (tinted, accent, normal)");
    end
end;
