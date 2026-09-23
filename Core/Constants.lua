local FL = ForeverLoot;
local Constants = FL.Constants;

-- Gargul's addon-comm prefix (Data/Constants.lua in Gargul). We register/send/listen
-- on this exact same prefix to interoperate with real Gargul clients.
Constants.COMM_CHANNEL = "GargulComm2";

-- Subset of Gargul's Comm.Actions we actually need (Data/Constants.lua:643-678).
Constants.Actions = {
    broadcastSoftRes = 3,
    response = 6,
    requestSoftResData = 8,
    startRollOff = 10,
    stopRollOff = 11,
};

-- Reverse lookup: action id -> name, used only for /zl commdebug printing.
Constants.ActionNames = {};
for name, id in pairs(Constants.Actions) do
    Constants.ActionNames[id] = name;
end

-- Gargul's Comm:listen drops any message whose declared `v` is older than this
-- (Data/Constants.lua:640, current Gargul release value). We declare a `v` that
-- satisfies Gargul's version check so our messages aren't silently rejected -
-- this is a protocol-compatibility handshake value, not an identity claim.
-- Bump this if a future Gargul release raises its own minimumAppVersion floor.
Constants.MIN_APP_VERSION = "7.7.36";
Constants.DECLARED_VERSION = "7.8.2";

-- Gargul's default roll-tracking brackets (Data/DefaultSettings.lua:155-158):
-- { label, min, max, priority, concernsOffspec, addPlusOne }
Constants.DEFAULT_BRACKETS = {
    { "MS", 1, 100, 2, false, false },
    { "OS", 1, 99, 3, true, false },
};

-- Loot council response options (Phase 3). This project's own dedicated
-- "ForeverLootLC" comm prefix uses plain string ids, not Gargul's numeric
-- action ids, so a simple ordered array is enough - order here is also the
-- button display order in LootCouncilResponseWindow.
--
-- `color` ({ r, g, b }, no alpha - each skin decides how strongly to apply
-- it) is a placeholder pick, one per response, purely so each response
-- button is visually distinct at a glance - not yet user-configurable. A
-- later options-panel phase is expected to let the user override these same
-- fields rather than replace this table's shape.
Constants.LOOT_COUNCIL_RESPONSES = {
    { id = "MAJOR",   label = "Major",   color = { 0.80, 0.20, 0.20 } }, -- red
    { id = "MINOR",   label = "Minor",   color = { 0.85, 0.55, 0.15 } }, -- orange
    { id = "OFFSPEC", label = "Offspec", color = { 0.20, 0.45, 0.80 } }, -- blue
    { id = "MOG",     label = "Mog",     color = { 0.65, 0.30, 0.80 } }, -- purple
    { id = "PASS",    label = "Pass",    color = { 0.25, 0.70, 0.30 } }, -- green
};

-- Reverse lookup: response id -> label, same convention as ActionNames above.
Constants.LOOT_COUNCIL_RESPONSE_LABELS = {};
for _, entry in ipairs(Constants.LOOT_COUNCIL_RESPONSES) do
    Constants.LOOT_COUNCIL_RESPONSE_LABELS[entry.id] = entry.label;
end

-- Shared "unselected" tint for a response button once its item has moved
-- into the "Responded" section - every button except the one actually
-- chosen switches to this grey, so the selection reads clearly at a glance.
Constants.LOOT_COUNCIL_RESPONSE_UNSELECTED_COLOR = { 0.35, 0.35, 0.35 };
