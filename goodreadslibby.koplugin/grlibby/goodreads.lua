--[[--
Reads Goodreads shelves through the per-shelf RSS feeds
(https://www.goodreads.com/review/list_rss/<user id>?shelf=<shelf>).

No sign-in is needed for public profiles. For private profiles, paste the RSS
link from the bottom of your "My Books" page: it carries a `key=` parameter
that grants read access to the feed.
--]]

local Http = require("grlibby/http")
local Util = require("grlibby/util")

local Goodreads = {}

Goodreads.BASE = "https://www.goodreads.com"
Goodreads.PAGE_SIZE = 100

--- Parse whatever the user typed: a numeric id, a profile/shelf URL, or a
-- list_rss URL (possibly with key=…). Returns { id = "123", key = "abc" } or nil.
function Goodreads.parseAccount(input)
    input = Util.trim(input)
    if input == "" then return nil end
    local id = input:match("^(%d+)$")
        or input:match("list_rss/(%d+)")
        or input:match("/user/show/(%d+)")
        or input:match("/review/list/(%d+)")
        or input:match("/user/(%d+)")
    if not id then return nil end
    local key = input:match("[?&]key=([%w%-_]+)")
    return { id = id, key = key }
end

--- Parse the contents of goodreads.txt: lines starting with # are comments;
-- the first line that holds a link or user ID wins.
function Goodreads.parseAccountText(text)
    for raw in tostring(text or ""):gmatch("[^\r\n]+") do
        local line = Util.trim(raw)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local acc = Goodreads.parseAccount(line)
            if acc then return acc end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- goodreads.txt: one shelf per line, "nickname = shelf RSS link"
--------------------------------------------------------------------------------

-- Setting names accepted in goodreads.txt (spaces/underscores/case ignored).
local SETTING_KEYS = {
    ["profile"] = "profile", ["public profile"] = "profile",
    ["user id"] = "user_id", ["userid"] = "user_id", ["user"] = "user_id",
}

--- The RSS link of a shelf (without paging), for writing goodreads.txt.
function Goodreads.shelfRssUrl(account, shelf)
    local url = string.format("%s/review/list_rss/%s?shelf=%s", Goodreads.BASE, account.id, Util.urlencode(shelf))
    if account.key and account.key ~= "" then url = url .. "&key=" .. account.key end
    return url
end

--- Parse the right-hand side of a shelf line. Accepts a shelf RSS link, a
-- shelf page link (…/review/list/123?shelf=x), a profile link (all books), or
-- just a shelf name like to-read (uses your profile/user id).
-- Returns { shelf, user = { id, key } or nil } or nil, reason.
function Goodreads.parseShelfValue(value)
    value = Util.trim(value)
    if value == "" then return nil, "no link given" end
    if value:find("://", 1, true) or value:find("goodreads%.com") then
        local id = value:match("list_rss/(%d+)") or value:match("/review/list/(%d+)")
            or value:match("/user/show/(%d+)")
        if not id then return nil, "no Goodreads user id in this link" end
        local shelf = value:match("[?&]shelf=([^&#%s]+)")
        return {
            shelf = shelf and Util.urldecode(shelf) or "#ALL#",
            user = { id = id, key = value:match("[?&]key=([%w%-_]+)") },
        }
    end
    if value == "#ALL#" or value:match("^[%l%d][%l%d%-_]*$") then
        return { shelf = value }
    end
    return nil, "not a shelf RSS link or shelf name"
end

-- "[optional]", "<your id>" or "PASTE_…": template text, not a value.
local function isPlaceholder(v)
    return v == "" or v:match("^%[.*%]$") ~= nil or v:match("^<.*>$") ~= nil or v:match("^PASTE_") ~= nil
end

local function settingKey(k)
    local norm = Util.trim(k):lower():gsub("[_%s]+", " ")
    return SETTING_KEYS[norm]
end

--- Parse goodreads.txt.
-- Returns { account, shelves = { { name, shelf, user, value } }, errors,
-- profile_raw, user_id_raw, has_profile_line, has_user_id_line }.
function Goodreads.parseConfig(text)
    local cfg = { shelves = {}, errors = {} }
    local legacy
    local lineno = 0
    for raw in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        local line = Util.trim((raw:gsub("\r$", "")))
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v
            -- A line that starts with a link is the older single-line format
            -- (its "=" signs belong to the URL).
            if not (line:match("^https?://") or line:match("^www%.")) then
                k, v = line:match("^([^=]+)=(.*)$")
            end
            if not k then
                -- Older single-line format: just a link or user id.
                -- Kept as the profile, so rewriting the file preserves it.
                local acc = Goodreads.parseAccount(line)
                if acc then
                    legacy = legacy or acc
                    cfg.profile_raw = cfg.profile_raw or line
                else
                    cfg.errors[#cfg.errors + 1] = string.format("line %d: not “nickname = link”: %s", lineno, line)
                end
            else
                v = Util.trim(v)
                local which = settingKey(k)
                if which == "profile" then
                    cfg.has_profile_line = true
                    if isPlaceholder(v) then
                        cfg.profile_placeholder = v
                    else
                        cfg.profile_raw = v
                        cfg.profile = Goodreads.parseAccount(v)
                        if not cfg.profile then
                            cfg.errors[#cfg.errors + 1] = string.format("line %d: profile isn't a Goodreads link or id", lineno)
                        end
                    end
                elseif which == "user_id" then
                    cfg.has_user_id_line = true
                    if isPlaceholder(v) then
                        cfg.user_id_placeholder = v
                    else
                        cfg.user_id_raw = v
                        local acc = Goodreads.parseAccount(v)
                        cfg.user_id = acc and acc.id
                        if not cfg.user_id then
                            cfg.errors[#cfg.errors + 1] = string.format("line %d: user id should be a number", lineno)
                        end
                    end
                elseif isPlaceholder(v) then
                    -- The sample file's placeholder: not filled in yet.
                    cfg.placeholders = (cfg.placeholders or 0) + 1
                else
                    local name = Util.trim(k)
                    local parsed, why = Goodreads.parseShelfValue(v)
                    if parsed then
                        cfg.shelves[#cfg.shelves + 1] = {
                            name = name, shelf = parsed.shelf, user = parsed.user,
                            value = v, _shelf = parsed.shelf,
                        }
                    else
                        cfg.errors[#cfg.errors + 1] = string.format("line %d (%s): %s", lineno, name, why)
                    end
                end
            end
        end
    end

    -- Whose shelves plain shelf names refer to: profile, else user id, else
    -- the older single-line format, else the first RSS link's owner.
    local acc = cfg.profile or (cfg.user_id and { id = cfg.user_id }) or legacy
    if not acc then
        for _, e in ipairs(cfg.shelves) do
            if e.user then
                acc = { id = e.user.id, key = e.user.key }
                break
            end
        end
    end
    if acc and not acc.key then
        for _, e in ipairs(cfg.shelves) do
            if e.user and e.user.id == acc.id and e.user.key then
                acc = { id = acc.id, key = e.user.key }
                break
            end
        end
    end
    cfg.account = acc
    -- Your own shelves are simply "yours".
    for _, e in ipairs(cfg.shelves) do
        if e.user and acc and e.user.id == acc.id then
            if e.user.key and not acc.key then acc.key = e.user.key end
            e.user = nil
        end
    end
    return cfg
end

--- Write goodreads.txt from `cfg`, keeping the comment lines of `old_text`.
function Goodreads.formatConfig(cfg, old_text)
    local out = {}
    for raw in (tostring(old_text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw:gsub("\r$", "")
        if line:match("^%s*#") then out[#out + 1] = line end
    end
    if #out == 0 then
        out[1] = "# Goodreads → Libby: one shelf per line, as   nickname = shelf RSS link"
        out[2] = "# Lines starting with # are ignored."
    end
    out[#out + 1] = ""
    if cfg.has_profile_line or cfg.profile_raw then
        out[#out + 1] = "profile = " .. (cfg.profile_raw or cfg.profile_placeholder or "")
    end
    if cfg.has_user_id_line or cfg.user_id_raw then
        out[#out + 1] = "user id = " .. (cfg.user_id_raw or cfg.user_id_placeholder or "")
    end
    local acc = cfg.account
    for _, e in ipairs(cfg.shelves or {}) do
        local value
        if e.value and e._shelf == e.shelf then
            value = e.value
        elseif e.user then
            value = Goodreads.shelfRssUrl(e.user, e.shelf)
        elseif acc and acc.key then
            value = Goodreads.shelfRssUrl(acc, e.shelf)
        else
            value = e.shelf
        end
        local name = Util.trim(tostring(e.name or e.shelf):gsub("=", "-"))
        out[#out + 1] = name .. " = " .. value
    end
    return table.concat(out, "\n") .. "\n"
end

--- The shortest text that fully describes an account (for goodreads.txt).
function Goodreads.accountString(account)
    if account.key and account.key ~= "" then
        return string.format("%s/review/list_rss/%s?key=%s&shelf=%%23ALL%%23",
            Goodreads.BASE, account.id, account.key)
    end
    return account.id
end

function Goodreads.feedUrl(account, shelf, page)
    local url = string.format("%s/review/list_rss/%s?shelf=%s&page=%d",
        Goodreads.BASE, account.id, Util.urlencode(shelf), page or 1)
    if account.key and account.key ~= "" then
        url = url .. "&key=" .. Util.urlencode(account.key)
    end
    return url
end

local function field(item, name)
    local v = item:match("<" .. name .. ">(.-)</" .. name .. ">")
    if not v then return nil end
    local cdata = v:match("^%s*<!%[CDATA%[(.-)%]%]>%s*$")
    if cdata then
        v = cdata
    else
        v = Util.unescape(v)
    end
    v = Util.trim(v)
    if v == "" then return nil end
    return v
end

--- Parse an RSS document into a list of books.
function Goodreads.parseFeed(xml)
    local books = {}
    if type(xml) ~= "string" then return books end
    for item in xml:gmatch("<item>(.-)</item>") do
        local title = field(item, "title")
        local book_id = field(item, "book_id")
        if title and book_id then
            local author = field(item, "author_name")
            books[#books + 1] = {
                id = book_id,
                title = title,
                author = author and author:gsub("%s+", " ") or nil,
                isbn = field(item, "isbn"),
                isbn13 = field(item, "isbn13"),
                pages = tonumber(item:match("<num_pages>(%d+)</num_pages>") or ""),
                cover = field(item, "book_medium_image_url") or field(item, "book_image_url"),
                shelves = field(item, "user_shelves"),
                added = field(item, "user_date_added"),
                rating = tonumber(field(item, "average_rating") or ""),
            }
        end
    end
    return books
end

function Goodreads.feedTitle(xml)
    local channel = type(xml) == "string" and xml:match("<channel>(.-)<item>") or xml
    return channel and field(channel, "title")
end

--- Fetch one page (up to 100 books) of a shelf feed.
-- Returns { books, title, owner } or nil, error message.
function Goodreads.fetchPage(account, shelf, page)
    local resp, err = Http.request{
        url = Goodreads.feedUrl(account, shelf, page),
        headers = { Accept = "application/rss+xml, application/xml;q=0.9, */*;q=0.5" },
        large = true,
    }
    if not resp then
        return nil, "Couldn't reach Goodreads: " .. tostring(err)
    end
    if resp.code == 403 or resp.code == 401 then
        return nil, "This Goodreads profile is private. Use the RSS link from the bottom of the “My Books” page (it includes key=…)."
    end
    if resp.code == 404 then
        return nil, "Goodreads couldn't find that user or shelf."
    end
    if resp.code ~= 200 then
        return nil, string.format("Goodreads replied with HTTP %d.", resp.code)
    end
    if not resp.body:find("<rss", 1, true) then
        return nil, "Goodreads didn't return a shelf feed. If the profile is private, use the RSS link that includes key=…"
    end
    local title = Goodreads.feedTitle(resp.body)
    -- "Otis 's bookshelf: to-read" -> "Otis"
    local owner = title and Util.trim(title:match("^(.-)%s*'s bookshelf") or "")
    return {
        books = Goodreads.parseFeed(resp.body),
        title = title,
        owner = owner ~= "" and owner or nil,
    }
end

--- Fetch every book on a shelf (up to max_pages × 100).
-- Returns books, nil or nil, error message.
function Goodreads.fetchShelf(account, shelf, max_pages)
    max_pages = max_pages or 50
    local books, seen = {}, {}
    for page = 1, max_pages do
        local res, err = Goodreads.fetchPage(account, shelf, page)
        if not res then return nil, err end
        local added = 0
        for _, b in ipairs(res.books) do
            if not seen[b.id] then
                seen[b.id] = true
                books[#books + 1] = b
                added = added + 1
            end
        end
        if #res.books < Goodreads.PAGE_SIZE or added == 0 then break end
    end
    return books
end

return Goodreads
