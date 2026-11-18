--[[--
A plain-text log for troubleshooting, kept in the plugin folder
(goodreadslibby.log, rotated at 512 KB into goodreadslibby.log.1).

Secrets never reach the file: Libby tokens, Goodreads RSS keys and Libby setup
codes are replaced with <hidden> before writing.
--]]

local Log = {
    path = nil,
    max_bytes = 512 * 1024,
}

function Log.setPath(path)
    Log.path = path
end

--- Remove secrets from text bound for the log.
function Log.redact(s)
    s = tostring(s)
    s = s:gsub("([?&]key=)[^&%s\"']+", "%1<hidden>")
    s = s:gsub("(Bearer%s+)[%w%-_%.=]+", "%1<hidden>")
    s = s:gsub('("identity"%s*:%s*")[^"]*', "%1<hidden>")
    s = s:gsub('("code"%s*:%s*")[^"]*', "%1<hidden>")
    return s
end

--- Append one line: the arguments joined by spaces, with a timestamp.
function Log.write(...)
    if not Log.path then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    local f = io.open(Log.path, "ab")
    if not f then return end
    local size = f:seek("end")
    if size and size > Log.max_bytes then
        f:close()
        os.rename(Log.path, Log.path .. ".1")
        f = io.open(Log.path, "ab")
        if not f then return end
    end
    f:write(os.date("%Y-%m-%d %H:%M:%S "), Log.redact(table.concat(parts, " ")), "\n")
    f:close()
end

--- A short, single-line excerpt of a response body (binary bodies skipped).
function Log.excerpt(body, max)
    body = tostring(body or "")
    if body:sub(1, 2) == "PK" then return "<zip, " .. #body .. " bytes>" end
    if body:find("[%z\1-\8\14-\31]") then return "<binary, " .. #body .. " bytes>" end
    body = body:gsub("%s+", " ")
    max = max or 600
    if #body > max then body = body:sub(1, max) .. "…" end
    return body
end

return Log
