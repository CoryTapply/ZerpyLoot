--[[
Automatic Rolls engine: decides whether/how to auto-respond to a native
Group Loot roll (Need/Greed/Pass) in a raid or dungeon, tracks the popup's
session-only choices, and is the entry point for /fl autoroll.

Scope (AutoRoll.ScopeOK) gates everything here: outside a raid/dungeon, or
on a non-roll loot method (master looter/free-for-all/round-robin/personal
loot), nothing is auto-rolled, the popup never shows, and item overrides
never apply - matching a plain Group Loot roll exactly as if this addon's
automation didn't exist.

Raids and dungeons differ only in the raid-wide mode: raids follow the
saved db.autoRoll.mode (and its "ask" popup on entry), while dungeons
ignore it and always roll manually unless the player opts in for that
dungeon via /fl autoroll. Item overrides apply identically in both.

UI/AutoRollPopup.lua is presentation-only (Show/Hide/IsShown); every policy
decision (when to show it, what to store) lives here. GroupLootRoll.lua owns
the actual roll-submission plumbing (RollOnAuto/pendingAuto) this calls into.
]]

local FL = ForeverLoot;
local AutoRoll = FL.AutoRoll;
local Util = FL.Util;
local RULE_TITLE = FL.Constants.AUTO_ROLL_RULE_TITLE;
local RULE_VERB = FL.Constants.AUTO_ROLL_RULE_VERB;

--------------------------------------------------------------------------
-- Scope / effective mode
--------------------------------------------------------------------------

--- True only on a loot method that actually produces Group Loot rolls -
--- master looter/free-for-all/round-robin/personal loot never fire
--- START_LOOT_ROLL at all, so automatic rolls (and the raid popup) have
--- nothing to do under them.
function AutoRoll.IsRollLootMethod()
    if (C_PartyInfo and C_PartyInfo.GetLootMethod) then
        local method = C_PartyInfo.GetLootMethod();
        return method == Enum.LootMethod.Group or method == Enum.LootMethod.Needbeforegreed;
    end
    local method = GetLootMethod();
    return method == "group" or method == "needbeforegreed";
end

function AutoRoll.ScopeOK()
    local inInstance, instanceType = IsInInstance();
    return inInstance and (instanceType == "raid" or instanceType == "party") and AutoRoll.IsRollLootMethod();
end

function AutoRoll.IsDungeon()
    local _, instanceType = IsInInstance();
    return instanceType == "party";
end

--- The mode that actually governs this instance right now: the current
--- instance's session choice (from the popup or /fl autoroll) if one was
--- made, else the saved default - except in "ask" mode, which stays
--- "manual" (i.e. normal rolling) until answered rather than falling back to
--- itself. Dungeons never use the saved default: "manual" until /fl autoroll.
function AutoRoll.GetEffectiveMode()
    local instanceID = select(8, GetInstanceInfo());
    local mode = FL.Settings.GetAutoRollMode();
    local session = instanceID and FL.Settings.GetAutoRollSessionChoice(instanceID);
    if (AutoRoll.IsDungeon() or mode == "ask") then return session or "manual"; end
    return session or mode;
end

--------------------------------------------------------------------------
-- Precedence chain
--------------------------------------------------------------------------

--- Returns rule ("need"|"greed"|"pass"|"manual"), source (a short label) or
--- nil (no decision made at all - a normal roll row shows, nothing printed).
--- "manual" only comes from an explicit item override; the raid-mode branches
--- below return nil instead when the effective mode is "manual"/"ask", since
--- that's the absence of automation, not a decision worth announcing.
function AutoRoll.Decide(itemID, canNeed, canGreed)
    local override = itemID and FL.Settings.GetAutoRollOverride(itemID);
    if (override) then
        -- An explicit item rule is never silently swapped for a different
        -- roll - every branch here returns outright, never falls through to
        -- the raid mode below. "manual" returns a real rule (not nil)
        -- so HandleStartLootRoll still prints the "Manually rolling on
        -- [item]" notice for this deliberate per-item exception, even though
        -- it leaves the roll row up for a manual click same as nil would.
        if (override == "manual") then return "manual", "item override"; end
        if (override == "pass") then return "pass", "item override"; end
        if (override == "need") then return (canNeed and "need" or nil), "item override"; end
        if (override == "greed") then return (canGreed and "greed" or nil), "item override"; end
        return nil;
    end

    local mode = AutoRoll.GetEffectiveMode();
    if (mode == "need") then
        if (canNeed) then return "need", "raid setting"; end
        if (canGreed) then return "greed", "raid setting"; end
        return "pass", "raid setting";
    elseif (mode == "greed") then
        return (canGreed and "greed" or "pass"), "raid setting";
    elseif (mode == "pass") then
        return "pass", "raid setting";
    end
    return nil; -- "manual"
end

--------------------------------------------------------------------------
-- Chat prints
--------------------------------------------------------------------------

local function colorHex(rgb)
    return ("%02x%02x%02x"):format(rgb[1] * 255, rgb[2] * 255, rgb[3] * 255);
end

function AutoRoll.PrintRollMessage(itemLink, rule)
    -- FL.UI.Colors isn't set until UI/SettingsWindow/Colors.lua loads, which
    -- is after this file in the .toc - read it live rather than capturing a
    -- module-level local that would freeze on the nil it has at load time.
    local hex = colorHex(FL.UI.Colors.systemMessage);
    Util.Print(("|cff%s%s on %s|r"):format(hex, RULE_VERB[rule] or rule, itemLink));
end

--- Announced once per raid entry (see scopeWasActive below) - the ambient
--- mode that will govern this raid unless/until a session choice changes it.
--- Skipped for "ask" mode with no session choice yet: the popup is about to
--- ask, and PrintSessionChoiceMessage announces whatever the player picks.
--- Dungeons announce an automatic session choice here too; with none (or
--- "manual") they print PrintDungeonOffMessage instead.
function AutoRoll.PrintModeMessage(mode)
    local changeLink = FL.FormatReopenLink("AutoRoll", "Click here to change");
    if (mode == "manual") then
        Util.Print(("Automatic rolls: Rolling manually. %s"):format(changeLink));
    else
        Util.Print(("Automatic rolls: %s on everything. %s"):format(RULE_TITLE[mode] or mode, changeLink));
    end
end

--- Printed on dungeon entry when this dungeon has no automatic session
--- choice - the clickable link is the in-chat equivalent of /fl autoroll.
function AutoRoll.PrintDungeonOffMessage()
    Util.Print(("Automatic rolls are off in this dungeon. %s"):format(
        FL.FormatReopenLink("AutoRoll", "Click here to turn them on")));
end

function AutoRoll.PrintSessionChoiceMessage(choice, instanceName)
    local reopenLink = FL.FormatReopenLink("AutoRoll", "Click here to re-open");
    if (choice == "manual") then
        Util.Print(("Rolling manually in %s until you log out. %s"):format(instanceName, reopenLink));
    else
        Util.Print(("%s on everything in %s until you log out. %s"):format(RULE_TITLE[choice] or choice, instanceName, reopenLink));
    end
end

--------------------------------------------------------------------------
-- START_LOOT_ROLL entry point (called from GroupLootRoll.lua)
--------------------------------------------------------------------------

local ROLL_TYPE = { need = 1, greed = 2, pass = 0 };

--- Returns true if this roll was auto-rolled (the caller must not show a
--- row for it), false otherwise. "manual" is a rule like any other (an
--- explicit item-override decision) but never auto-rolls - it only prints
--- the notice and leaves the row up for the player to click themselves.
function AutoRoll.HandleStartLootRoll(rollID)
    local roll = FL.GroupLootRoll.ActiveRolls[rollID];
    if (not roll or not AutoRoll.ScopeOK()) then return false; end

    local itemID = Util.itemIDFromLink(roll.itemLink);
    local rule = AutoRoll.Decide(itemID, roll.canNeed, roll.canGreed);
    if (not rule) then return false; end

    if (rule ~= "manual") then
        FL.GroupLootRoll.RollOnAuto(rollID, ROLL_TYPE[rule]);
    end
    AutoRoll.PrintRollMessage(roll.itemLink, rule);
    return rule ~= "manual";
end

--------------------------------------------------------------------------
-- Popup trigger + session choices + /fl autoroll
--------------------------------------------------------------------------

-- Tracks whether scope was already active as of the last check, so the mode
-- announcement below fires once per raid entry (or per loot-method flip into
-- a roll method), not on every subzone change within the same raid.
local scopeWasActive = false;

local function checkShowPopup()
    if (not AutoRoll.ScopeOK()) then
        scopeWasActive = false;
        if (FL.UI.AutoRollPopup.IsShown and FL.UI.AutoRollPopup.IsShown()) then
            FL.UI.AutoRollPopup.Hide();
        end
        return;
    end

    local mode = FL.Settings.GetAutoRollMode();
    local instanceID = select(8, GetInstanceInfo());
    local session = instanceID and FL.Settings.GetAutoRollSessionChoice(instanceID);

    if (AutoRoll.IsDungeon()) then
        -- No automatic popup in dungeons - only /fl autoroll opens it.
        if (not scopeWasActive) then
            scopeWasActive = true;
            if (session and session ~= "manual") then
                AutoRoll.PrintModeMessage(session);
            else
                AutoRoll.PrintDungeonOffMessage();
            end
        end
        return;
    end

    if (not scopeWasActive) then
        scopeWasActive = true;
        if (session or mode ~= "ask") then
            AutoRoll.PrintModeMessage(session or mode);
        end
    end

    if (mode ~= "ask") then return; end
    if (session ~= nil) then return; end

    FL.UI.AutoRollPopup.Show();
end

--- /fl autoroll: opens the popup regardless of mode or whether this
--- instance already has a session answer (picking a choice only replaces
--- the session choice for the current instance, never db.autoRoll.mode).
--- The only way to turn on automatic rolls in a dungeon.
function AutoRoll.HandleSlashAutoroll()
    if (not AutoRoll.ScopeOK()) then
        Util.Print("Automatic rolls only apply in raids and dungeons that use group loot.");
        return;
    end
    FL.UI.AutoRollPopup.Show();
end

local eventFrame = CreateFrame("Frame");
eventFrame:SetScript("OnEvent", function(_, event, isInitialLogin)
    if (event == "PLAYER_ENTERING_WORLD") then
        -- A real login/relog wipes session choices (asks again); a /reload
        -- or a death run-back (isInitialLogin false either way) does not.
        if (isInitialLogin) then wipe(FL.DB.settings.autoRoll.sessionChoices); end
        C_Timer.After(1, checkShowPopup); -- let the loading screen clear first
    elseif (event == "ZONE_CHANGED_NEW_AREA") then
        C_Timer.After(1, checkShowPopup);
    elseif (event == "PARTY_LOOT_METHOD_CHANGED") then
        checkShowPopup(); -- no loading screen involved, no delay needed
    end
end);

function AutoRoll.Init()
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD");
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA");
    eventFrame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED");
end
