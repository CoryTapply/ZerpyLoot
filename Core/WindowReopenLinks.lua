local FL = ForeverLoot;
local Util = FL.Util;

--[[
Whenever a player closes one of the addon's windows via its own close
button, a chat message is printed with a clickable link that reopens it
(see FL.NotifyWindowClosed, called from each window's close button).

Custom addon links all share Blizzard's "addon" hyperlink type
(LinkTypes.AddOn). Blizzard's own handler for that type (registered by
FrameXML - see Blizzard_UIPanels_Game/Shared/ItemRefHandlersShared.lua) does
nothing but rebroadcast the click as an EventRegistry "SetItemRef" event,
specifically so third-party addons can react without each registering their
own handler for "addon" (only one handler may own a given link type, so a
second LinkUtil.RegisterLinkHandler("addon", ...) call would just error).
]]

local REOPEN_COMMAND = "reopen";

local reopenTargets = {
    Roll = { label = "Roll", show = function() FL.UI.RollWindow.Show(); end },
    Award = { label = "Review and Award", show = function() FL.UI.AwardWindow.Show(); end },
    Respond = { label = "Respond", show = function() FL.UI.RespondWindow.Show(); end },
    TradeQueue = { label = "Trade Queue", show = function() FL.UI.TradeQueueWindow.Show(); end },
    SoftResImport = { label = "Import SoftRes", show = function() FL.UI.SoftResImportWindow.Show(); end },
    StartSession = { label = "Start Session", show = function() FL.UI.StartSessionWindow.Show(); end },
    LootHistory = { label = "Loot History", show = function() FL.UI.LootHistoryWindow.Show(); end },
    Settings = { label = "Settings", show = function() FL.UI.SettingsWindow.Show(); end },
    -- Routed through HandleSlashAutoroll (not AutoRollPopup.Show directly) so
    -- a click still gets the "only applies in raids that use group loot"
    -- guard if scope was lost between the message printing and the click.
    AutoRoll = { label = "Automatic Rolls", show = function() FL.AutoRoll.HandleSlashAutoroll(); end },
};

--- Builds a clickable chat link (Blizzard's "addon" hyperlink type, same
--- SetItemRef plumbing as FL.NotifyWindowClosed below) that reopens the
--- given reopenTargets entry when clicked, with `visibleText` as its label -
--- shared with any other message that wants a "click to reopen" affordance
--- (e.g. AutoRoll.lua's session-choice message).
function FL.FormatReopenLink(windowId, visibleText)
    local link = LinkUtil.FormatLink(LinkTypes.AddOn, visibleText, FL.name, REOPEN_COMMAND, windowId);
    return "|cff69ccf0[" .. link .. "]|r";
end

-- Call from a window's own close-button handler (not from a programmatic
-- Hide() made as part of normal workflow) with one of the keys above.
function FL.NotifyWindowClosed(windowId)
    local target = reopenTargets[windowId];
    if (not target) then return; end

    Util.Print(target.label .. " window was closed. " .. FL.FormatReopenLink(windowId, "Click here to re-open"));
end

EventRegistry:RegisterCallback("SetItemRef", function(_owner, link)
    local linkType, addonName, command, windowId = strsplit(":", link);
    if (linkType ~= LinkTypes.AddOn or addonName ~= FL.name or command ~= REOPEN_COMMAND) then
        return;
    end

    local target = reopenTargets[windowId];
    if (target) then target.show(); end
end, FL);
