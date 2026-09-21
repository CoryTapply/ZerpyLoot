--[[
Global addon namespace. Every other file attaches to this table.
]]

ZerpyLoot = ZerpyLoot or {};
local ZL = ZerpyLoot;

ZL.name = "ZerpyLoot";

-- Sub-namespaces populated by their respective files
ZL.Constants = ZL.Constants or {};
ZL.Util = ZL.Util or {};
ZL.Comm = ZL.Comm or {};
ZL.RollTracker = ZL.RollTracker or {};
ZL.GroupLootRoll = ZL.GroupLootRoll or {};
ZL.SoftRes = ZL.SoftRes or {};
ZL.Tooltip = ZL.Tooltip or {};
ZL.Trade = ZL.Trade or {};
ZL.Pixel = ZL.Pixel or {};
ZL.Theme = ZL.Theme or {};
ZL.Settings = ZL.Settings or {};
ZL.UI = ZL.UI or {};
ZL.UI.RollWindow = ZL.UI.RollWindow or {};
ZL.UI.GroupLootRollBars = ZL.UI.GroupLootRollBars or {};
ZL.UI.SoftResImport = ZL.UI.SoftResImport or {};
ZL.UI.TradeQueueWindow = ZL.UI.TradeQueueWindow or {};
ZL.UI.OptionsPanel = ZL.UI.OptionsPanel or {};
ZL.Vendor = ZL.Vendor or {};

local bootstrapFrame = CreateFrame("Frame");
bootstrapFrame:RegisterEvent("ADDON_LOADED");
bootstrapFrame:RegisterEvent("PLAYER_LOGIN");
bootstrapFrame:SetScript("OnEvent", function(_, event, addonName)
    if (event == "ADDON_LOADED" and addonName == ZL.name) then
        ZerpyLootDB = ZerpyLootDB or {};
        ZL.DB = ZerpyLootDB;
    elseif (event == "PLAYER_LOGIN") then
        -- Each module is initialised in its own pcall so one module failing
        -- (e.g. registering an event this client doesn't have) can't stop
        -- every module after it from loading.
        local modules = {
            { "Settings", ZL.Settings },
            { "Comm", ZL.Comm },
            { "RollTracker", ZL.RollTracker },
            { "GroupLootRoll", ZL.GroupLootRoll },
            { "SoftRes", ZL.SoftRes },
            { "Tooltip", ZL.Tooltip },
            { "Trade", ZL.Trade },
        };

        for _, module in ipairs(modules) do
            local moduleName, moduleTable = module[1], module[2];
            if (moduleTable.Init) then
                local ok, err = pcall(moduleTable.Init);
                if (not ok) then
                    print(("|cff8865ffZerpyLoot|r %s failed to initialise: %s"):format(moduleName, tostring(err)));
                end
            end
        end
    end
end);
