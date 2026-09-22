--[[
Minimal standard base64 decoder (RFC 4648). Decode-only - we never need to
re-encode SoftRes data since broadcasts simply re-send the original pasted
string verbatim.
]]

local FL = ForeverLoot;
FL.Vendor.Base64 = FL.Vendor.Base64 or {};
local Base64 = FL.Vendor.Base64;

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

local decodeTable;
local function buildDecodeTable()
    decodeTable = {};
    for i = 1, #ALPHABET do
        decodeTable[string.byte(ALPHABET, i)] = i - 1;
    end
end

--- Decode a base64-encoded string.
---@param input string
---@return string|nil decoded, string|nil error
function Base64.decode(input)
    if (type(input) ~= "string") then
        return nil, "input must be a string";
    end

    if (not decodeTable) then
        buildDecodeTable();
    end

    -- Strip whitespace and padding - padding is implicit once '=' characters
    -- are removed, since leftover bits (< 8) at the end are simply not
    -- emitted as a byte below.
    input = string.gsub(input, "[^A-Za-z0-9%+/]", "");

    local bytes = {};
    local buffer, bits = 0, 0;

    for i = 1, #input do
        local value = decodeTable[string.byte(input, i)];
        if (not value) then
            return nil, "invalid base64 character at position " .. i;
        end

        buffer = (buffer * 64) + value;
        bits = bits + 6;

        if (bits >= 8) then
            bits = bits - 8;
            local byte = math.floor(buffer / (2 ^ bits)) % 256;
            table.insert(bytes, string.char(byte));
            -- Discard the bits we just consumed so `buffer` only ever holds
            -- the still-unconsumed low-order bits, not the entire history.
            buffer = buffer % (2 ^ bits);
        end
    end

    return table.concat(bytes);
end
