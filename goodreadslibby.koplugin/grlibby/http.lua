--[[--
Minimal HTTP(S) client on top of KOReader's LuaSocket, with manual redirect
following (LuaSocket refuses http<->https hops) and JSON helpers.
--]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")
local Log = require("grlibby/log")

local JSON
do
    local ok, rapidjson = pcall(require, "rapidjson")
    if ok and rapidjson then
        JSON = rapidjson
    else
        JSON = require("json")
    end
end

local Http = {}

Http.USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

-- The host part of a URL (no scheme, no path), used as the cookie-jar key.
local function hostOf(url)
    return (url:match("^%a[%w+.-]*://([^/]+)"))
end

-- Set-Cookie attribute names (everything that isn't an actual cookie pair).
local COOKIE_ATTR = {
    expires = true, ["max-age"] = true, domain = true, path = true,
    secure = true, httponly = true, samesite = true, version = true,
}

-- Fold the Set-Cookie header(s) of one response into jar[host]. LuaSocket joins
-- repeated headers with ", ", so we scan for every name=value pair and keep the
-- ones that aren't cookie attributes. Cookie values here are opaque tokens with
-- no commas, so a joined Expires=… date (whose comma starts no new pair) is
-- skipped cleanly.
local function storeCookies(jar, host, set_cookie)
    if not (jar and host and set_cookie) then return end
    local bag = jar[host] or {}
    jar[host] = bag
    for name, value in tostring(set_cookie):gmatch("([%w!#%$%%&'%*%+%-%.%^_`|~]+)=([^;,]*)") do
        if not COOKIE_ATTR[name:lower()] then bag[name] = value end
    end
end

-- The Cookie header value for a host, or nil when the jar holds none.
local function cookieHeader(jar, host)
    local bag = jar and host and jar[host]
    if not bag then return nil end
    local parts = {}
    for name, value in pairs(bag) do parts[#parts + 1] = name .. "=" .. value end
    if #parts == 0 then return nil end
    return table.concat(parts, "; ")
end
Http.hostOf = hostOf

-- Resolve a (possibly relative) Location header against the current URL.
function Http.absolute(base, location)
    if location:match("^%a[%w+.-]*://") then return location end
    local scheme, host = base:match("^(%a[%w+.-]*://)([^/]+)")
    if not scheme then return location end
    if location:sub(1, 2) == "//" then
        return scheme:match("^(%a[%w+.-]*:)") .. location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. host .. location
    end
    local dir = base:match("^(.*/)") or (scheme .. host .. "/")
    return dir .. location
end

--- Perform a request.
-- opts: url, method, headers, body, max_redirects, large (bool, longer timeouts),
-- trace (bool: log every hop to the plugin log; errors are always logged)
-- Returns { code = number, headers = table, body = string } or nil, error string.
function Http.request(opts)
    local url = opts.url
    local method = opts.method or "GET"
    local body = opts.body
    local max_redirects = opts.max_redirects or 6

    for _ = 0, max_redirects do
        local headers = {
            ["User-Agent"] = Http.USER_AGENT,
            ["Accept-Encoding"] = "identity",
        }
        for k, v in pairs(opts.headers or {}) do headers[k] = v end
        -- Attach any cookies this jar holds for the current host (a session
        -- cookie set earlier in the redirect chain, or by a prior request).
        if opts.cookies and not headers.Cookie and not headers.cookie then
            local ck = cookieHeader(opts.cookies, hostOf(url))
            if ck then headers.Cookie = ck end
        end
        local source
        if body then
            headers["Content-Length"] = tostring(#body)
            source = ltn12.source.string(body)
        end

        local chunks = {}
        local sink = socketutil.table_sink and socketutil.table_sink(chunks) or ltn12.sink.table(chunks)
        if opts.large then
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        else
            socketutil:set_timeout(socketutil.DEFAULT_BLOCK_TIMEOUT or 10, socketutil.DEFAULT_TOTAL_TIMEOUT or 30)
        end
        local ok, code, resp_headers = pcall(function()
            return socket.skip(1, http.request{
                url = url,
                method = method,
                headers = headers,
                source = source,
                sink = sink,
                redirect = false,
            })
        end)
        socketutil:reset_timeout()

        if not ok then
            logger.warn("grlibby http: request crashed", url, code)
            Log.write("HTTP", method, url, "CRASHED:", code)
            return nil, tostring(code)
        end
        if type(code) ~= "number" then
            logger.warn("grlibby http: request failed", url, code)
            Log.write("HTTP", method, url, "FAILED:", code)
            return nil, tostring(code or "network error")
        end
        resp_headers = resp_headers or {}

        if opts.cookies then
            storeCookies(opts.cookies, hostOf(url),
                resp_headers["set-cookie"] or resp_headers["Set-Cookie"])
        end

        local location = resp_headers.location or resp_headers.Location
        if opts.trace or code >= 400 then
            local resp_body = table.concat(chunks)
            Log.write("HTTP", method, url, "->", code,
                "auth=" .. (headers.Authorization and "yes" or "no"),
                location and ("location=" .. location) or "",
                "type=" .. tostring(resp_headers["content-type"] or "-"),
                "bytes=" .. #resp_body)
            if opts.trace and body and #body > 0 then
                Log.write("  sent:", Log.excerpt(body, 300))
            end
            if code >= 300 or opts.trace_body then
                Log.write("  reply:", Log.excerpt(resp_body))
            end
        end
        if REDIRECT[code] and location then
            url = Http.absolute(url, location)
            if code == 303 or ((code == 301 or code == 302) and method ~= "GET" and method ~= "HEAD") then
                method = "GET"
                body = nil
            end
        else
            return { code = code, headers = resp_headers, body = table.concat(chunks), url = url }
        end
    end
    return nil, "too many redirects"
end

-- JSON null sentinels (rapidjson.null, json.null, …) become plain nils.
local function stripNulls(v, depth)
    if type(v) ~= "table" or depth > 64 then return v end
    for k, x in pairs(v) do
        local t = type(x)
        if t == "userdata" or t == "function" then
            v[k] = nil
        elseif t == "table" then
            stripNulls(x, depth + 1)
        end
    end
    return v
end

function Http.decodeJSON(s)
    if type(s) ~= "string" or s == "" then return nil end
    local ok, data = pcall(JSON.decode, s)
    if not ok then return nil end
    return stripNulls(data, 0)
end

function Http.encodeJSON(t)
    return JSON.encode(t)
end

--- Request expecting a JSON reply. opts.json (table) is sent as the body.
-- Returns data (or nil), response (or nil), error string.
function Http.json(opts)
    local headers = { Accept = "application/json" }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    local body = opts.body
    if opts.json then
        body = Http.encodeJSON(opts.json)
        headers["Content-Type"] = "application/json; charset=utf-8"
    end
    local resp, err = Http.request{
        url = opts.url,
        method = opts.method or (body and "POST" or "GET"),
        headers = headers,
        body = body,
        large = opts.large,
        trace = opts.trace,
    }
    if not resp then return nil, nil, err end
    return Http.decodeJSON(resp.body), resp, nil
end

return Http
