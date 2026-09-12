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
        if (ZL.Settings.Init) then ZL.Settings.Init(); end
        if (ZL.Comm.Init) then ZL.Comm.Init(); end
        if (ZL.RollTracker.Init) then ZL.RollTracker.Init(); end
        if (ZL.GroupLootRoll.Init) then ZL.GroupLootRoll.Init(); end
        if (ZL.SoftRes.Init) then ZL.SoftRes.Init(); end
        if (ZL.Tooltip.Init) then ZL.Tooltip.Init(); end
        if (ZL.Trade.Init) then ZL.Trade.Init(); end
    end
end);
