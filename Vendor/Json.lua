--[[
Minimal recursive-descent JSON decoder. Decode-only - the SoftRes broadcast
protocol re-sends the original pasted string verbatim, so no encoder is needed.
]]

local ZL = ZerpyLoot;
ZL.Vendor.Json = ZL.Vendor.Json or {};
local Json = ZL.Vendor.Json;

local decodeValue;

local function skipWhitespace(str, pos)
    local _, stop = string.find(str, "^[ \t\n\r]*", pos);
    return stop + 1;
end

local escapeMap = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
};

local function decodeString(str, pos)
    -- pos points at the opening quote
    local out = {};
    local i = pos + 1;
    local len = #str;

    while (i <= len) do
        local c = string.sub(str, i, i);

        if (c == '"') then
            return table.concat(out), i + 1;
        elseif (c == "\\") then
            local nextChar = string.sub(str, i + 1, i + 1);
            if (nextChar == "u") then
                local hex = string.sub(str, i + 2, i + 5);
                local codepoint = tonumber(hex, 16) or 0;
                -- Basic Unicode escape handling: encode as UTF-8 (BMP only, sufficient for softres.it exports)
                if (codepoint < 0x80) then
                    table.insert(out, string.char(codepoint));
                elseif (codepoint < 0x800) then
                    table.insert(out, string.char(
                        0xC0 + math.floor(codepoint / 0x40),
                        0x80 + (codepoint % 0x40)
                    ));
                else
                    table.insert(out, string.char(
                        0xE0 + math.floor(codepoint / 0x1000),
                        0x80 + (math.floor(codepoint / 0x40) % 0x40),
                        0x80 + (codepoint % 0x40)
                    ));
                end
                i = i + 6;
            else
                table.insert(out, escapeMap[nextChar] or nextChar);
                i = i + 2;
            end
        else
            table.insert(out, c);
            i = i + 1;
        end
    end

    error("unterminated string in JSON at position " .. pos);
end

local function decodeNumber(str, pos)
    local numStr = string.match(str, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos);
    if (not numStr or numStr == "") then
        error("invalid number in JSON at position " .. pos);
    end
    return tonumber(numStr), pos + #numStr;
end

local function decodeArray(str, pos)
    local result = {};
    pos = skipWhitespace(str, pos + 1); -- skip '['

    if (string.sub(str, pos, pos) == "]") then
        return result, pos + 1;
    end

    while (true) do
        local value;
        value, pos = decodeValue(str, pos);
        table.insert(result, value);

        pos = skipWhitespace(str, pos);
        local c = string.sub(str, pos, pos);

        if (c == ",") then
            pos = skipWhitespace(str, pos + 1);
        elseif (c == "]") then
            return result, pos + 1;
        else
            error("expected ',' or ']' in JSON array at position " .. pos);
        end
    end
end

local function decodeObject(str, pos)
    local result = {};
    pos = skipWhitespace(str, pos + 1); -- skip '{'

    if (string.sub(str, pos, pos) == "}") then
        return result, pos + 1;
    end

    while (true) do
        pos = skipWhitespace(str, pos);
        if (string.sub(str, pos, pos) ~= '"') then
            error("expected string key in JSON object at position " .. pos);
        end

        local key;
        key, pos = decodeString(str, pos);

        pos = skipWhitespace(str, pos);
        if (string.sub(str, pos, pos) ~= ":") then
            error("expected ':' in JSON object at position " .. pos);
        end
        pos = skipWhitespace(str, pos + 1);

        local value;
        value, pos = decodeValue(str, pos);
        result[key] = value;

        pos = skipWhitespace(str, pos);
        local c = string.sub(str, pos, pos);

        if (c == ",") then
            pos = skipWhitespace(str, pos + 1);
        elseif (c == "}") then
            return result, pos + 1;
        else
            error("expected ',' or '}' in JSON object at position " .. pos);
        end
    end
end

decodeValue = function(str, pos)
    pos = skipWhitespace(str, pos);
    local c = string.sub(str, pos, pos);

    if (c == "{") then
        return decodeObject(str, pos);
    elseif (c == "[") then
        return decodeArray(str, pos);
    elseif (c == '"') then
        return decodeString(str, pos);
    elseif (c == "t" and string.sub(str, pos, pos + 3) == "true") then
        return true, pos + 4;
    elseif (c == "f" and string.sub(str, pos, pos + 4) == "false") then
        return false, pos + 5;
    elseif (c == "n" and string.sub(str, pos, pos + 3) == "null") then
        return nil, pos + 4;
    elseif (c == "-" or (c >= "0" and c <= "9")) then
        return decodeNumber(str, pos);
    end

    error("unexpected character in JSON at position " .. pos .. ": " .. tostring(c));
end

--- Decode a JSON string into a Lua table/value.
---@param str string
---@return boolean success
---@return any result Decoded value, or an error message on failure
function Json.decode(str)
    if (type(str) ~= "string") then
        return false, "input must be a string";
    end

    local ok, valueOrErr = pcall(function()
        local value = decodeValue(str, 1);
        return value;
    end);

    if (not ok) then
        return false, valueOrErr;
    end

    return true, valueOrErr;
end
