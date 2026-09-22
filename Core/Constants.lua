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
