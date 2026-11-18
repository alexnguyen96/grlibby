--[[--
Matching Goodreads books against OverDrive/Libby search results, and turning a
match into a per-library availability summary.
--]]

local Util = require("grlibby/util")

local Match = {}

-- Curly quotes, dashes and similar punctuation commonly found in titles.
local UTF8_PUNCT = {
    "\226\128\152", "\226\128\153", "\226\128\156", "\226\128\157", -- ‘ ’ “ ”
    "\226\128\147", "\226\128\148", "\226\128\166", "\194\183", -- – — … ·
}

local function normalize(s)
    s = tostring(s or ""):lower()
    for _, p in ipairs(UTF8_PUNCT) do s = s:gsub(p, " ") end
    s = s:gsub("&", " and ")
    s = s:gsub("'", "")
    s = s:gsub("%p", " ")
    s = s:gsub("%s+", " ")
    s = Util.trim(s)
    s = s:gsub("^the ", ""):gsub("^an ", ""):gsub("^a ", "")
    return s
end
Match.normalize = normalize

--- Goodreads titles carry series info, e.g. "Leviathan Wakes (The Expanse, #1)".
-- Returns the main title without series or subtitle.
function Match.mainTitle(title)
    local t = tostring(title or "")
    t = t:gsub("%b()", " "):gsub("%b[]", " ")
    t = t:gsub(":.*$", "")
    t = t:gsub("%s+", " ")
    return Util.trim(t)
end

--- The search string sent to OverDrive (same idea as the Libby userscript).
function Match.searchTitle(title)
    local t = Match.mainTitle(title)
    t = t:gsub("[&|,]", " "):gsub("%s+", " ")
    return Util.trim(t)
end

local function tokens(s)
    local set, n = {}, 0
    for w in s:gmatch("%S+") do
        if not set[w] then set[w] = true; n = n + 1 end
    end
    return set, n
end

function Match.titleScore(a, b)
    a, b = normalize(Match.mainTitle(a)), normalize(Match.mainTitle(b))
    if a == "" or b == "" then return 0 end
    if a == b then return 1 end
    local ta, na = tokens(a)
    local tb, nb = tokens(b)
    local inter = 0
    for w in pairs(ta) do if tb[w] then inter = inter + 1 end end
    local union = na + nb - inter
    local score = union > 0 and inter / union or 0
    -- One title fully contained in the other ("Dune" vs "Dune Messiah" is still
    -- handled by the author check and preference for exact matches).
    if inter == math.min(na, nb) and inter > 0 then
        score = math.max(score, 0.75)
    end
    return score
end

local function surname(name)
    local n = normalize(name)
    -- "Weir, Andy" -> "weir"
    local raw = tostring(name or "")
    if raw:find(",") then
        return normalize(raw:match("^([^,]+)"))
    end
    local last
    for w in n:gmatch("%S+") do
        if w ~= "jr" and w ~= "sr" and w ~= "ii" and w ~= "iii" then last = w end
    end
    return last
end
Match.surname = surname

function Match.authorMatches(book_author, item)
    if not book_author or book_author == "" then return true end
    local last = surname(book_author)
    if not last then return true end
    local names = {}
    for _, c in ipairs(type(item.creators) == "table" and item.creators or {}) do
        names[#names + 1] = Util.str(c.name)
    end
    names[#names + 1] = Util.str(item.firstCreatorName)
    for _, n in ipairs(names) do
        if n then
            local nn = " " .. normalize(n) .. " "
            if nn:find(" " .. last .. " ", 1, true) then return true end
        end
    end
    return false
end

local function digits(s)
    return s and (tostring(s):gsub("[^%dXx]", ""):upper()) or nil
end

-- ISBN-10 -> ISBN-13 so the two forms compare equal.
local function isbn13(s)
    s = digits(s)
    if not s then return nil end
    if #s == 13 then return s end
    if #s ~= 10 then return nil end
    local core = "978" .. s:sub(1, 9)
    local sum = 0
    for i = 1, 12 do
        sum = sum + tonumber(core:sub(i, i)) * ((i % 2 == 1) and 1 or 3)
    end
    return core .. tostring((10 - sum % 10) % 10)
end
Match.isbn13 = isbn13

function Match.isbnMatches(book, item)
    local want = {}
    for _, v in ipairs({ book.isbn, book.isbn13 }) do
        local n = isbn13(v)
        if n then want[n] = true end
    end
    if not next(want) then return false end
    for _, f in ipairs(type(item.formats) == "table" and item.formats or {}) do
        for _, ident in ipairs(type(f.identifiers) == "table" and f.identifiers or {}) do
            if Util.str(ident.type) == "ISBN" and want[isbn13(ident.value) or ""] then
                return true
            end
        end
    end
    return false
end

local function formatIds(item)
    local ids = {}
    for _, f in ipairs(type(item.formats) == "table" and item.formats or {}) do
        local id = Util.str(f.id)
        if id then ids[#ids + 1] = id end
    end
    return ids
end

--- Summarize one OverDrive media item into the availability record we cache.
function Match.summarize(item, score)
    local formats = formatIds(item)
    local has = {}
    for _, f in ipairs(formats) do has[f] = true end
    local available = Util.num(item.availableCopies) or 0
    local owned = Util.num(item.ownedCopies) or 0
    local always = Util.str(item.availabilityType) == "always"
    local is_available = item.isAvailable == true or available > 0 or always
    local lucky = Util.num(item.luckyDayAvailableCopies) or 0
    local status
    if is_available then
        status = "available"
    elseif lucky > 0 then
        status = "lucky"
    elseif item.isHoldable == true or owned > 0 then
        status = "hold"
    else
        status = "none"
    end
    local subtitle = Util.str(item.subtitle)
    return {
        id = Util.str(item.id) or (Util.num(item.id) and tostring(item.id)),
        title = Util.str(item.title),
        subtitle = subtitle,
        author = Util.str(item.firstCreatorName),
        status = status,
        available = available,
        owned = owned,
        always = always or nil,
        lucky = lucky,
        holds = Util.num(item.holdsCount) or 0,
        wait_days = Util.num(item.estimatedWaitDays),
        holdable = item.isHoldable == true,
        formats = formats,
        acsm = has["ebook-epub-adobe"] or nil,
        pdf_acsm = has["ebook-pdf-adobe"] or nil,
        epub_open = has["ebook-epub-open"] or nil,
        kindle = has["ebook-kindle"] or nil,
        score = score,
    }
end

-- "borrowed"/"held" are set locally after you borrow or place a hold.
local STATUS_RANK = { borrowed = 0, available = 1, lucky = 2, held = 3, hold = 4, none = 5 }

local function better(a, b)
    local ra, rb = STATUS_RANK[a.status] or 9, STATUS_RANK[b.status] or 9
    if ra ~= rb then return ra < rb end
    if a.status == "hold" then
        local wa, wb = a.wait_days or 9999, b.wait_days or 9999
        if wa ~= wb then return wa < wb end
    end
    -- Prefer a format we can download.
    local da = (a.epub_open or a.acsm) and 1 or 0
    local db = (b.epub_open or b.acsm) and 1 or 0
    return da > db
end

--- Pick the best matching ebook among search results for a Goodreads book.
-- Returns a summary table or nil when nothing matches.
function Match.best(book, items)
    local candidates = {}
    local top = 0
    for _, item in ipairs(items or {}) do
        local type_id = type(item.type) == "table" and Util.str(item.type.id)
        if type_id == nil or type_id == "ebook" then
            local score
            if Match.isbnMatches(book, item) then
                score = 1.5
            else
                local ts = Match.titleScore(book.title, Util.str(item.title) or "")
                if ts >= 0.6 and Match.authorMatches(book.author, item) then
                    score = ts
                end
            end
            if score then
                candidates[#candidates + 1] = { item = item, score = score }
                if score > top then top = score end
            end
        end
    end
    if #candidates == 0 then return nil end
    -- Among near-equal matches (e.g. two editions), choose the most borrowable.
    local best
    for _, c in ipairs(candidates) do
        if c.score >= math.min(top, 1) - 0.15 then
            local s = Match.summarize(c.item, c.score)
            if not best or better(s, best) then best = s end
        end
    end
    return best
end

--- Overall status for a book across libraries: the best per-library result.
-- results: { [library_key] = summary | { status = "none" } | { status = "error" } }
function Match.overall(results)
    local best
    for _, r in pairs(results or {}) do
        if r.status ~= "error" and (not best or better(r, best)) then best = r end
    end
    return best
end

Match.STATUS_RANK = STATUS_RANK
Match.better = better

return Match
