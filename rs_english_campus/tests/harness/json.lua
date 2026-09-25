--[[
    JSON minimal compatible avec le comportement de json.encode/json.decode de FiveM (dérivé de rxi/json.lua) :
      • table vide → []        • tableau à trous → erreur        • clés mixtes → erreur
    Utilisé uniquement par le banc de test (tests/), jamais chargé en jeu.
]]
local json = {}

local escapes = { ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function escapeChar(c) return escapes[c] or string.format('\\u%04x', c:byte()) end

local encode

local function encodeTable(value, stack)
    if stack[value] then error('circular reference') end
    stack[value] = true
    local out = {}
    if rawget(value, 1) ~= nil or next(value) == nil then
        local n = 0
        for k in pairs(value) do
            if type(k) ~= 'number' then error('invalid table: mixed or invalid key types') end
            n = n + 1
        end
        if n ~= #value then error('invalid table: sparse array') end
        for _, v in ipairs(value) do out[#out + 1] = encode(v, stack) end
        stack[value] = nil
        return '[' .. table.concat(out, ',') .. ']'
    end
    for k, v in pairs(value) do
        if type(k) ~= 'string' then error('invalid table: mixed or invalid key types (' .. tostring(k) .. ')') end
        out[#out + 1] = encode(k, stack) .. ':' .. encode(v, stack)
    end
    stack[value] = nil
    return '{' .. table.concat(out, ',') .. '}'
end

encode = function(value, stack)
    local t = type(value)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return tostring(value) end
    if t == 'number' then
        if value ~= value or value <= -math.huge or value >= math.huge then error('unexpected number value') end
        return string.format('%.14g', value)
    end
    if t == 'string' then return '"' .. value:gsub('[%c"\\]', escapeChar) .. '"' end
    if t == 'table' then return encodeTable(value, stack or {}) end
    error('unexpected type ' .. t)
end

function json.encode(value) return (encode(value, {})) end

local function decodeError(str, idx, msg) error(('%s at char %d'):format(msg, idx)) end

local function skipWhitespace(str, i)
    local _, e = str:find('^[ \n\r\t]*', i)
    return e + 1
end

local decodeValue

local function codepointToUtf8(n)
    return utf8.char(n)
end

local function parseString(str, i)
    local out = {}
    local j = i + 1
    while true do
        local c = str:sub(j, j)
        if c == '' then decodeError(str, j, 'unterminated string') end
        if c == '"' then break end
        if c == '\\' then
            local n = str:sub(j + 1, j + 1)
            local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
            if map[n] then
                out[#out + 1] = map[n]
                j = j + 2
            elseif n == 'u' then
                local hex = str:sub(j + 2, j + 5)
                local cp = tonumber(hex, 16)
                if not cp then decodeError(str, j, 'invalid unicode escape') end
                j = j + 6
                if cp >= 0xD800 and cp <= 0xDBFF and str:sub(j, j + 1) == '\\u' then
                    local low = tonumber(str:sub(j + 2, j + 5), 16)
                    if low and low >= 0xDC00 and low <= 0xDFFF then
                        cp = (cp - 0xD800) * 0x400 + (low - 0xDC00) + 0x10000
                        j = j + 6
                    end
                end
                out[#out + 1] = codepointToUtf8(cp)
            else
                decodeError(str, j, 'invalid escape')
            end
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
    return table.concat(out), j + 1
end

local function parseNumber(str, i)
    local s, e = str:find('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
    if not s then decodeError(str, i, 'invalid number') end
    local text = str:sub(s, e)
    local n = math.tointeger(tonumber(text)) or tonumber(text)
    if text:find('[%.eE]') then n = tonumber(text) end
    if n == nil then decodeError(str, i, 'invalid number') end
    return n, e + 1
end

decodeValue = function(str, i)
    i = skipWhitespace(str, i)
    local c = str:sub(i, i)
    if c == '{' then
        local out = {}
        i = skipWhitespace(str, i + 1)
        if str:sub(i, i) == '}' then return out, i + 1 end
        while true do
            if str:sub(i, i) ~= '"' then decodeError(str, i, 'expected key') end
            local key
            key, i = parseString(str, i)
            i = skipWhitespace(str, i)
            if str:sub(i, i) ~= ':' then decodeError(str, i, 'expected :') end
            local value
            value, i = decodeValue(str, i + 1)
            out[key] = value
            i = skipWhitespace(str, i)
            local d = str:sub(i, i)
            if d == '}' then return out, i + 1 end
            if d ~= ',' then decodeError(str, i, 'expected , or }') end
            i = skipWhitespace(str, i + 1)
        end
    elseif c == '[' then
        local out, n = {}, 0
        i = skipWhitespace(str, i + 1)
        if str:sub(i, i) == ']' then return out, i + 1 end
        while true do
            local value
            value, i = decodeValue(str, i)
            n = n + 1
            out[n] = value
            i = skipWhitespace(str, i)
            local d = str:sub(i, i)
            if d == ']' then return out, i + 1 end
            if d ~= ',' then decodeError(str, i, 'expected , or ]') end
            i = i + 1
        end
    elseif c == '"' then
        return parseString(str, i)
    elseif str:sub(i, i + 3) == 'true' then
        return true, i + 4
    elseif str:sub(i, i + 4) == 'false' then
        return false, i + 5
    elseif str:sub(i, i + 3) == 'null' then
        return nil, i + 4
    end
    return parseNumber(str, i)
end

function json.decode(str)
    if type(str) ~= 'string' then error('expected string') end
    local value, i = decodeValue(str, 1)
    i = skipWhitespace(str, i)
    if i <= #str then decodeError(str, i, 'trailing garbage') end
    return value
end

return json
