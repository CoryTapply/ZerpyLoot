--[[
Global addon namespace. Every other file attaches to this table.
]]

ForeverLoot = ForeverLoot or {};
local FL = ForeverLoot;

FL.name = "ForeverLoot";

-- Sub-namespaces populated by their respective files
FL.Constants = FL.Constants or {};
FL.Util = FL.Util or {};
FL.Responses = FL.Responses or {};
FL.Comm = FL.Comm or {};
FL.RollTracker = FL.RollTracker or {};
FL.RollSession = FL.RollSession or {};
FL.GroupLootRoll = FL.GroupLootRoll or {};
FL.AutoRoll = FL.AutoRoll or {};
FL.LootChat = FL.LootChat or {};
FL.SoftRes = FL.SoftRes or {};
FL.Tooltip = FL.Tooltip or {};
FL.Trade = FL.Trade or {};
FL.LootCouncil = FL.LootCouncil or {};
FL.LootCouncilRoster = FL.LootCouncilRoster or {};
FL.SessionItems = FL.SessionItems or {};
FL.Awards = FL.Awards or {};
FL.Pixel = FL.Pixel or {};
FL.Theme = FL.Theme or {};
FL.Settings = FL.Settings or {};
FL.UI = FL.UI or {};
FL.UI.RollWindow = FL.UI.RollWindow or {};
FL.UI.GroupLootFrame = FL.UI.GroupLootFrame or {};
FL.UI.AutoRollPopup = FL.UI.AutoRollPopup or {};
FL.UI.SoftResImportWindow = FL.UI.SoftResImportWindow or {};
FL.UI.TradeQueueWindow = FL.UI.TradeQueueWindow or {};
FL.UI.StartSessionWindow = FL.UI.StartSessionWindow or {};
FL.UI.ResponseRow = FL.UI.ResponseRow or {};
FL.UI.RespondWindow = FL.UI.RespondWindow or {};
FL.UI.AwardWindow = FL.UI.AwardWindow or {};
FL.UI.LootHistoryWindow = FL.UI.LootHistoryWindow or {};
FL.UI.OptionsPanel = FL.UI.OptionsPanel or {};
FL.UI.SettingsWindow = FL.UI.SettingsWindow or {};
FL.Vendor = FL.Vendor or {};

local bootstrapFrame = CreateFrame("Frame");
bootstrapFrame:RegisterEvent("ADDON_LOADED");
bootstrapFrame:RegisterEvent("PLAYER_LOGIN");
bootstrapFrame:SetScript("OnEvent", function(_, event, addonName)
    if (event == "ADDON_LOADED" and addonName == FL.name) then
        ForeverLootDB = ForeverLootDB or {};
        FL.DB = ForeverLootDB;
    elseif (event == "PLAYER_LOGIN") then
        -- Each module is initialised in its own pcall so one module failing
        -- (e.g. registering an event this client doesn't have) can't stop
        -- every module after it from loading.
        local modules = {
            { "Settings", FL.Settings },
            { "Responses", FL.Responses },
            { "Comm", FL.Comm },
            { "RollTracker", FL.RollTracker },
            { "GroupLootRoll", FL.GroupLootRoll },
            { "SoftRes", FL.SoftRes },
            { "Tooltip", FL.Tooltip },
            { "Trade", FL.Trade },
            { "LootCouncil", FL.LootCouncil },
            { "SessionItems", FL.SessionItems },
            { "LootChat", FL.LootChat },
            { "AutoRoll", FL.AutoRoll },
        };

        for _, module in ipairs(modules) do
            local moduleName, moduleTable = module[1], module[2];
            if (moduleTable.Init) then
                local ok, err = pcall(moduleTable.Init);
                if (not ok) then
                    print(("|cff8865ffForeverLoot|r %s failed to initialise: %s"):format(moduleName, tostring(err)));
                end
            end
        end
    end
end);
