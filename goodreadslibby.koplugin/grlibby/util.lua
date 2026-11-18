--[[--
Small string helpers shared by the plugin modules (no KOReader dependencies).
--]]

local Util = {}

function Util.trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- Encode a Unicode code point as UTF-8.
local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return ""
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

-- Decode XML/HTML entities.
function Util.unescape(s)
    if type(s) ~= "string" then return s end
    s = s:gsub("&#[xX](%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&(%a+);", function(name) return ENTITIES[name] end)
    return s
end

-- Drop a trailing, truncated UTF-8 sequence after a byte-based cut.
local function fixUtf8Tail(s)
    local n = #s
    local i = n
    while i > 0 do
        local b = s:byte(i)
        if b < 0x80 then return s end
        if b >= 0xC0 then
            local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
            if n - i + 1 < need then return s:sub(1, i - 1) end
            return s
        end
        i = i - 1
    end
    return s
end

-- A name that is safe on FAT/exFAT e-reader storage.
function Util.safeFilename(s, max_bytes)
    s = tostring(s or "book")
    s = s:gsub('[%c\\/:%*%?"<>|]', "_"):gsub("%s+", " ")
    s = Util.trim(s):gsub("^%.+", "")
    if s == "" then s = "book" end
    max_bytes = max_bytes or 120
    if #s > max_bytes then s = Util.trim(fixUtf8Tail(s:sub(1, max_bytes))) end
    return s
end

function Util.urldecode(s)
    s = tostring(s or ""):gsub("%+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_VALUE = {}
for i = 1, #B64 do B64_VALUE[B64:sub(i, i)] = i - 1 end

--- Encode a byte string as standard base64 (with padding).
function Util.base64Encode(s)
    s = tostring(s or "")
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
            .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=")
            .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

--- Decode base64 / base64url (padding optional).
function Util.base64Decode(s)
    s = tostring(s or ""):gsub("%-", "+"):gsub("_", "/")
    local out, bits, nbits = {}, 0, 0
    for i = 1, #s do
        local v = B64_VALUE[s:sub(i, i)]
        if v then
            bits = bits * 64 + v
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                local p = 2 ^ nbits
                out[#out + 1] = string.char(math.floor(bits / p) % 256)
                bits = bits % p
            end
        end
    end
    return table.concat(out)
end

function Util.str(v)
    if type(v) == "string" then return v end
    return nil
end

function Util.num(v)
    if type(v) == "number" then return v end
    return nil
end

-- Split a comma/newline separated list, trimming and dropping empty entries.
function Util.splitList(s)
    local out = {}
    for part in tostring(s or ""):gmatch("[^,\n]+") do
        local p = Util.trim(part)
        if p ~= "" then out[#out + 1] = p end
    end
    return out
end

function Util.shorten(s, n)
    s = tostring(s or "")
    if #s <= n then return s end
    return fixUtf8Tail(s:sub(1, n - 1)) .. "…"
end

return Util
