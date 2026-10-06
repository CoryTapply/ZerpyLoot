--[[
Speaks Gargul's exact addon-comm wire protocol on the "GargulComm2" prefix:

    Lua table -> LibSerialize:Serialize() -> LibDeflate:CompressDeflate()
              -> LibDeflate:EncodeForWoWAddonChannel() -> SendAddonMessage

Payload uses Gargul's short keys: a=action, b=content, c=senderFqn,
m=minimumVersion, v=senderVersion, r=recipient (non-whisper only).

See Gargul's Classes/Comm.lua and Classes/CommMessage.lua for the reference
implementation this mirrors.
]]

local FL = ForeverLoot;
local Comm = FL.Comm;
local Constants = FL.Constants;
local Util = FL.Util;

local AceComm, LibDeflate, LibSerialize;

-- action id -> handler(Message) where Message = {action, content, senderFqn,
-- channel, recipient, version}
Comm.Actions = {};

--- Debug log line (Sync/Debug.lua, /fl debug) for this Gargul-compatible
--- channel's traffic - COMM level 2, like the sync layer's own send/receive.
local function commLog(fmt, ...)
    FL.Sync.Debug.Log("COMM", 2, fmt, ...);
end

--- Send an action to the group (or a specific recipient).
---@param action number One of Constants.Actions
---@param content any Arbitrary serializable content
---@param channel string "GROUP" or an explicit AceComm distribution ("WHISPER", "PARTY", "RAID")
---@param recipient string|nil Required for WHISPER
function Comm.Send(action, content, channel, recipient)
    local distribution, target = Util.GroupDistribution(channel or "GROUP", recipient);

    local payload = {
        a = action,
        b = content,
        c = Util.playerFqn(),
        m = Constants.MIN_APP_VERSION,
        v = Constants.DECLARED_VERSION,
    };

    if (distribution ~= "WHISPER" and recipient) then
        payload.r = recipient;
    end

    local serialized = LibSerialize:Serialize(payload);
    local compressed = LibDeflate:CompressDeflate(serialized, { level = 5 });
    local encoded = LibDeflate:EncodeForWoWAddonChannel(compressed);

    commLog("sent %s on the Gargul channel · to %s", Constants.ActionNames[action] or tostring(action),
        target or tostring(distribution):lower());

    AceComm:SendCommMessage(Constants.COMM_CHANNEL, encoded, distribution, target, "NORMAL");
end

local function onMessage(prefix, encoded, distribution, senderName)
    if (prefix ~= Constants.COMM_CHANNEL) then
        return;
    end

    local ok, decompressed = pcall(function()
        return LibDeflate:DecompressDeflate(LibDeflate:DecodeForWoWAddonChannel(encoded));
    end);

    if (not ok or not decompressed) then
        return;
    end

    local deserializeOk, payload = LibSerialize:Deserialize(decompressed);
    if (not deserializeOk or type(payload) ~= "table") then
        return;
    end

    -- Not meant for us (whisper forcefully routed through raid/party channel)
    local myName = Util.UnitName("player");
    local myFqn = Util.playerFqn();
    if (payload.r and not Util.iEquals(payload.r, myFqn) and not Util.iEquals(payload.r, myName)) then
        return;
    end

    -- Anti-spoofing: claimed sender must start with the real (server-supplied) sender name
    if (type(payload.c) == "string" and senderName) then
        local claimed = string.lower(strtrim(payload.c));
        local real = string.lower(strtrim(senderName));
        if (string.sub(claimed, 1, #real) ~= real) then
            return;
        end
    end

    if (not payload.a) then
        return;
    end

    local Message = {
        action = payload.a,
        content = payload.b,
        senderFqn = payload.c or senderName,
        senderName = Util.stripRealm(payload.c or senderName),
        channel = distribution,
        version = payload.v,
    };
    Message.isSelf = Util.iEquals(Message.senderFqn, myFqn) or Util.iEquals(Message.senderName, myName);

    commLog("got %s on the Gargul channel from %s · via %s", Constants.ActionNames[Message.action] or tostring(Message.action),
        Message.senderName or Message.senderFqn or "?", tostring(distribution):lower());

    local handler = Comm.Actions[Message.action];
    if (handler) then
        handler(Message);
    end
end

function Comm.Init()
    AceComm = LibStub("AceComm-3.0");
    LibDeflate = LibStub("LibDeflate");
    LibSerialize = LibStub("LibSerialize");

    AceComm:RegisterComm(Constants.COMM_CHANNEL, onMessage);
end
