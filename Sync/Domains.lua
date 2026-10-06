--[[
Registry for sync domains (spec section 7.7): the generic HELLO/HELLO_ACK
handshake (Sync/Peers.lua) and planner (Sync/Coordinator.lua) know nothing
about loot history specifically - they only deal with whatever implements
this small interface. Loot history registers as domain 1
(Data/HistoryDomain.lua); a later council-session snapshot domain (plan
Phase 7) registers the same way without this file changing at all.

Registration happens from each domain's own Init() (PLAYER_LOGIN), not at
file-load time, even though spec 7.7's "Adding another domain" step 3 says
"at load": Domains.Register logs through Sync/Debug.lua, and FL.DB (which
Debug.Log reads) doesn't exist yet during the addon's raw file-load pass -
Core/Init.lua's bootstrapFrame only creates FL.DB on ADDON_LOADED, which
fires AFTER every one of this addon's files has finished loading. See
docs/sync-deviations.md.
]]

local FL = ForeverLoot;
local Domains = FL.Sync.Domains;

local registry = {};      -- [id] = domain
local registryOrder = {}; -- array of ids, in registration order

function Domains.Register(domain)
    registry[domain.id] = domain;
    table.insert(registryOrder, domain.id);
    FL.Sync.Debug.Log("DOMAIN", 1, "registered %s · %s strategy, %s scope, %s gate",
        FL.Sync.Debug.DomainName(domain.id), domain.strategy, domain.scope, domain.gate);
end

function Domains.Get(id)
    return registry[id];
end

--- Every registered domain whose scope matches `scope`, in registration
--- order (spec 7.7 pt1: "Peers sends one HELLO per scope... every registered
--- domain in that scope"). Callers filter by each domain's own gate
--- themselves - this only answers "what's registered for this scope".
function Domains.InScope(scope)
    local out = {};
    for _, id in ipairs(registryOrder) do
        if (registry[id].scope == scope) then
            table.insert(out, registry[id]);
        end
    end
    return out;
end

--- Every registered domain, in registration order - backs /fl sync domains.
function Domains.All()
    local out = {};
    for _, id in ipairs(registryOrder) do
        table.insert(out, registry[id]);
    end
    return out;
end

--- Lets a domain ask for an early HELLO on its own scope (spec 7.7: "right
--- after a leader starts a session"). Not used by HistoryDomain this phase -
--- wired for the Phase 7 council-session domain, which will call this from
--- its own Bump(). Routed through Coordinator (not Peers.Discover directly)
--- so a notify-triggered mismatch still gets planned exactly like every
--- other trigger, instead of silently discarding its responders.
function Domains.NotifyChanged(id)
    local domain = registry[id];
    if (not domain) then return; end
    FL.Sync.Coordinator.NotifyChanged(domain);
end
