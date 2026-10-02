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
FL.UI.DebugLogWindow = FL.UI.DebugLogWindow or {};
FL.UI.SyncStatusWindow = FL.UI.SyncStatusWindow or {};
FL.Vendor = FL.Vendor or {};

-- History-sync system (docs/ForeverLoot History Sync — Spec.md). The spec
-- assumes a file-local `ns` namespace; this addon uses the global FL table
-- instead, so every `ns.X` becomes `FL.Sync.X` - see docs/sync-deviations.md.
FL.Sync = FL.Sync or {};
FL.Sync.Constants = FL.Sync.Constants or {};
FL.Sync.Debug = FL.Sync.Debug or {};
FL.Sync.Scheduler = FL.Sync.Scheduler or {};
FL.Sync.Gate = FL.Sync.Gate or {};
FL.Sync.Store = FL.Sync.Store or {};
FL.Sync.Digest = FL.Sync.Digest or {};
FL.Sync.Retention = FL.Sync.Retention or {};
FL.Sync.Permissions = FL.Sync.Permissions or {};
FL.Sync.Live = FL.Sync.Live or {};
FL.Sync.ItemLinks = FL.Sync.ItemLinks or {};
FL.Sync.Codec = FL.Sync.Codec or {};
FL.Sync.Transport = FL.Sync.Transport or {};
FL.Sync.Domains = FL.Sync.Domains or {};
FL.Sync.HistoryDomain = FL.Sync.HistoryDomain or {};
FL.Sync.Peers = FL.Sync.Peers or {};
FL.Sync.Session = FL.Sync.Session or {};
FL.Sync.Coordinator = FL.Sync.Coordinator or {};

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
            { "Debug", FL.Sync.Debug },
            { "Scheduler", FL.Sync.Scheduler },
            { "Gate", FL.Sync.Gate },
            { "Digest", FL.Sync.Digest }, -- self-test only here; no LootCouncil dependency (Rebuild() isn't called until Retention.Init())
            { "Permissions", FL.Sync.Permissions }, -- no dependency on LootCouncil; grouped with the other foundational Sync modules
            { "ItemLinks", FL.Sync.ItemLinks }, -- same: no LootCouncil dependency (just creates its own driver frame)
            { "Transport", FL.Sync.Transport }, -- same: registers AceComm prefixes, no LootCouncil dependency
            { "Settings", FL.Settings },
            { "Responses", FL.Responses },
            { "Comm", FL.Comm },
            { "RollTracker", FL.RollTracker },
            { "GroupLootRoll", FL.GroupLootRoll },
            { "SoftRes", FL.SoftRes },
            { "Tooltip", FL.Tooltip },
            { "Trade", FL.Trade },
            { "LootCouncil", FL.LootCouncil },
            -- Store/Live must init after LootCouncil (they read/write
            -- FL.LootCouncil.History/HistoryIndex). Live.Init() itself only
            -- registers into FL.Sync.Transport now (Phase 2) - it no longer
            -- needs LootCouncil.CommActions (that was Phase 1's
            -- historyDelete/historyPin, since removed) - but still needs
            -- Store's schema migration to have already run first.
            { "Store", FL.Sync.Store },
            -- Retention.Init() prunes/pins/rebuilds the digest off
            -- FL.LootCouncil.History and FL.DB.lootCouncil.pins/tombstones,
            -- so it must run after Store's schema migration too, same as Live.
            { "Retention", FL.Sync.Retention },
            { "Live", FL.Sync.Live },
            -- HistoryDomain.Init() registers itself with Domains (Sync/Domains.lua),
            -- and its Summary()/Compare() read Digest/Retention, both already
            -- initialised above. Peers/Coordinator only schedule timers and
            -- register Transport handlers at Init() time - the first real
            -- HELLO doesn't fire until LOGIN_DELAY (~20s) later, well after
            -- every module here has finished initialising.
            { "HistoryDomain", FL.Sync.HistoryDomain },
            { "Peers", FL.Sync.Peers },
            -- Session.Init() just registers Transport handlers and a
            -- Gate.OnChange callback - no dependency on Peers/Coordinator,
            -- but loaded in the spec's own file order (12.1): after Peers,
            -- before Coordinator (which is the only thing that calls
            -- Session.Open, and only ~LOGIN_DELAY seconds after every
            -- module here has already finished initialising).
            { "Session", FL.Sync.Session },
            { "Coordinator", FL.Sync.Coordinator },
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
