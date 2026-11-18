--[[--
Libby / OverDrive client.

* Catalog search and availability use OverDrive's public "thunder" API (the
  same one the Libby userscript uses); no sign-in required.
* Borrowing, holds and downloads use Libby's "sentry" API, authenticated by
  cloning your Libby app with an 8-digit setup code
  (Libby → Menu → Copy To Another Device).

The sentry calls mirror the ones used by odmpy and the Calibre Libby plugin.
--]]

local Http = require("grlibby/http")
local Log = require("grlibby/log")
local Util = require("grlibby/util")
local logger = require("logger")

local Libby = {}

-- The Libby app's account API. (The older sentry-read.svc.overdrive.com host
-- that odmpy and other tools use is being retired: its TLS certificate no
-- longer matches, and downloads through it failed with "missing_chip".)
Libby.SENTRY = "https://sentry.libbyapp.com"
Libby.THUNDER = "https://thunder.api.overdrive.com/v2"

Libby.FORMAT_ACSM = "ebook-epub-adobe"
Libby.FORMAT_PDF_ACSM = "ebook-pdf-adobe"
Libby.FORMAT_EPUB = "ebook-epub-open"

Libby.EXTENSION = {
    ["ebook-epub-adobe"] = "acsm",
    ["ebook-pdf-adobe"] = "acsm",
    ["ebook-epub-open"] = "epub",
    ["ebook-pdf-open"] = "pdf",
}

-- Pull a human readable error out of a sentry/thunder error body.
local function errorMessage(data, resp, fallback)
    if type(data) == "table" then
        local up = type(data.upstream) == "table" and data.upstream or {}
        local msg = Util.str(up.userExplanation) or Util.str(up.errorCode)
            or Util.str(data.message) or Util.str(data.result)
        if msg then return msg end
    end
    if resp then return string.format("%s (HTTP %d)", fallback or "Request failed", resp.code) end
    return fallback or "Request failed"
end
Libby.errorMessage = errorMessage

-- Error text plus which server answered, so a report from the device is
-- specific (e.g. "missing_chip (HTTP 401 from sentry.libbyapp.com)").
local function errorWithSource(data, resp, fallback)
    local msg = errorMessage(data, resp, fallback)
    local host = resp and resp.url and resp.url:match("^%a+://([^/]+)")
    if host and not msg:find("HTTP %d") then
        msg = string.format("%s (HTTP %d from %s)", msg, resp.code, host)
    end
    return msg
end

--------------------------------------------------------------------------------
-- Catalog (thunder): no authentication.
--------------------------------------------------------------------------------

--- Search one library for ebooks. Returns items or nil, error.
function Libby.search(library_key, title, author)
    local url = string.format("%s/libraries/%s/media?query=%s&mediaTypes=ebook&perPage=24",
        Libby.THUNDER, Util.urlencode(library_key), Util.urlencode(title))
    if author and author ~= "" then
        url = url .. "&creator=" .. Util.urlencode(author)
    end
    local data, resp, err = Http.json{ url = url }
    if not resp then return nil, err end
    if resp.code == 404 then return nil, "Unknown library “" .. library_key .. "”" end
    if resp.code ~= 200 or type(data) ~= "table" then
        return nil, errorMessage(data, resp, "Search failed")
    end
    return type(data.items) == "table" and data.items or {}
end

--- Look up a library by its key (e.g. "nypl"). Returns { key, name } or nil, error.
function Libby.libraryInfo(library_key)
    local data, resp, err = Http.json{
        url = string.format("%s/libraries/%s", Libby.THUNDER, Util.urlencode(library_key)),
    }
    if not resp then return nil, err end
    if resp.code ~= 200 or type(data) ~= "table" then
        return nil, errorMessage(data, resp, "Library not found")
    end
    return { key = library_key, name = Util.str(data.name) or library_key }
end

--------------------------------------------------------------------------------
-- Account (sentry): needs a Libby identity.
--------------------------------------------------------------------------------

--- What a Libby identity token says about itself (it's a JWT): which device
-- ("chip"), when it expires, how many cards it carries. Nothing secret.
function Libby.tokenInfo(identity)
    local payload = type(identity) == "string" and identity:match("^[^.]+%.([^.]+)%.")
    if not payload then return nil end
    local data = Http.decodeJSON(Util.base64Decode(payload))
    if type(data) ~= "table" then return nil end
    local chip = type(data.chip) == "table" and data.chip or {}
    return {
        exp = Util.num(data.exp),
        chip = Util.str(chip.pri),
        cards = type(chip.cards) == "table" and #chip.cards or 0,
        -- How the token was issued: "i" new, "l" renewed with ?client=dewey,
        -- "v" renewed with the app's version (see Libby.CLIENT_VERSION).
        kind = Util.str(chip.prbn),
    }
end

function Libby.describeToken(identity)
    if not identity then return "none" end
    local info = Libby.tokenInfo(identity)
    if not info then return "unreadable (length " .. #identity .. ")" end
    local left = info.exp and (info.exp - os.time()) or nil
    return string.format("device %s…, %d card(s), type %s, expires %s (%s)",
        (info.chip or "?"):sub(1, 8), info.cards, info.kind or "?",
        info.exp and os.date("%Y-%m-%d %H:%M", info.exp) or "?",
        left and (left > 0 and string.format("in %.1f days", left / 86400) or "EXPIRED") or "?")
end

-- Renew the token when it's this close to expiring (they last about a week).
Libby.RENEW_BEFORE = 3 * 24 * 3600

-- Token renewal as done by jordkh/odmpy (renew_chip): it names the Libby app
-- version and the device. Tokens renewed this way are type "v"; the older
-- "?client=dewey" renewal gives type "l", which Libby's download link may refuse.
Libby.CLIENT_VERSION = "18.5.2"

local Client = {}
Client.__index = Client

--- store: { get = function() -> identity|nil, set = function(identity) }
function Libby.newClient(store)
    return setmetatable({ store = store }, Client)
end

function Client:identity()
    return self.store.get()
end

function Client:_raw(method, path, opts)
    opts = opts or {}
    -- The same request headers the Libby web app sends.
    local headers = {
        Accept = opts.accept or "application/json",
        Referer = "https://libbyapp.com/",
        ["Cache-Control"] = "no-cache",
        Pragma = "no-cache",
    }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    local identity = self:identity()
    if identity and opts.auth ~= false then
        headers.Authorization = "Bearer " .. identity
    end
    local body
    if opts.json then
        body = Http.encodeJSON(opts.json)
        headers["Content-Type"] = "application/json; charset=utf-8"
    end
    local url = path:match("^https?://") and path or (Libby.SENTRY .. "/" .. path)
    if headers.Authorization then
        Log.write("libby:", method, path:gsub("%?.*$", ""), "token:", Libby.describeToken(identity))
    end
    return Http.request{
        url = url, method = method, headers = headers, body = body, large = opts.large,
        trace = true,
    }
end

--- Renew a token that is about to expire (the Libby app does the same).
function Client:freshen()
    local info = Libby.tokenInfo(self:identity())
    if not info then return end
    if info.exp and info.exp - os.time() < Libby.RENEW_BEFORE then
        Log.write("libby: token expires soon, renewing")
        self:refreshChip()
    elseif info.kind and info.kind ~= "v" and not self._upgrade_tried then
        -- Older tokens (type "l") may be refused by the download link:
        -- renew once, app-style, to get a type "v" token.
        self._upgrade_tried = true
        Log.write("libby: token type", info.kind, "- renewing app-style")
        self:refreshChip()
    end
end

-- Sentry request returning decoded JSON; transparently renews an expired
-- identity once.
function Client:_call(method, path, opts)
    if not (opts and opts.no_retry) then self:freshen() end
    local resp, err = self:_raw(method, path, opts)
    if not resp then return nil, nil, err end
    local data = Http.decodeJSON(resp.body)
    -- Renew only when Libby rejected the token itself. An "upstream" error
    -- (e.g. the library refusing your card) has nothing to do with the token.
    local upstream = type(data) == "table" and type(data.upstream) == "table"
    if resp.code == 401 and not upstream and not (opts and opts.no_retry) and self:identity() then
        logger.info("grlibby: identity rejected, renewing chip")
        if self:refreshChip() then
            resp, err = self:_raw(method, path, opts)
            if not resp then return nil, nil, err end
        end
    end
    return Http.decodeJSON(resp.body), resp
end

--- The library's own error code from a Libby reply, e.g.
-- "PatronCardFailedAuthentication" when the library refuses your card.
local function upstreamCode(data)
    return type(data) == "table" and type(data.upstream) == "table" and Util.str(data.upstream.errorCode) or nil
end
Libby.upstreamCode = upstreamCode

--- Get a fresh device identity. With an existing identity the server renews it
-- for the same (linked) chip.
function Client:refreshChip(allow_new_device)
    local current = Libby.tokenInfo(self:identity())
    local old = not allow_new_device and current or nil
    local data, resp
    if current and current.chip then
        -- Renew an existing token the way jordkh/odmpy does.
        data, resp = self:_call("POST", string.format("chip?c=d:%s&s=0&v=%s",
            Libby.CLIENT_VERSION, current.chip:match("^([^-]+)") or current.chip), { no_retry = true })
        if not (resp and resp.code >= 200 and resp.code < 300 and type(data) == "table"
            and Util.str(data.identity)) then
            Log.write("libby: app-style renewal failed, using ?client=dewey")
            data, resp = nil, nil
        end
    end
    if not data then
        data, resp = self:_call("POST", "chip?client=dewey", { no_retry = true })
    end
    if resp and resp.code >= 200 and resp.code < 300 and type(data) == "table"
        and Util.str(data.identity) then
        local new = Libby.tokenInfo(data.identity)
        -- Never swap a linked device for a different (empty) one.
        if old and old.chip and new and new.chip ~= old.chip then
            Log.write("libby: renewal returned a different device; keeping the current token")
            return false, "Libby returned a different device"
        end
        Log.write("libby: token renewed:", Libby.describeToken(data.identity))
        self.store.set(data.identity)
        return true
    end
    return false, errorMessage(data, resp, "Couldn't get a Libby identity")
end

function Client:ensureChip()
    if self:identity() then return true end
    return self:refreshChip()
end

--- Link this device to a Libby app using an 8-digit setup code.
function Client:cloneByCode(code)
    code = tostring(code or ""):gsub("%D", "")
    if #code ~= 8 then return nil, "The setup code must be 8 digits." end
    -- Always start from a fresh chip so a stale identity can't get in the way.
    self.store.set(nil)
    local ok, err = self:refreshChip()
    if not ok then return nil, err end
    local data, resp, rerr = self:_call("POST", "chip/clone/code", { json = { code = code }, no_retry = true })
    if not resp then return nil, rerr end
    if resp.code < 200 or resp.code >= 300 then
        return nil, errorMessage(data, resp, "Libby didn't accept that code (it expires after a minute)")
    end
    -- Re-issue the identity so it carries the cloned account.
    self:refreshChip(true)
    return self:sync()
end

--- Cards, loans and holds. Returns table or nil, error.
function Client:sync()
    if not self:identity() then return nil, "Libby isn't linked yet." end
    local data, resp, err = self:_call("GET", "chip/sync")
    if not resp then return nil, err end
    if resp.code ~= 200 or type(data) ~= "table" then
        return nil, errorMessage(data, resp, "Couldn't sync with Libby")
    end
    data.cards = type(data.cards) == "table" and data.cards or {}
    data.loans = type(data.loans) == "table" and data.loans or {}
    data.holds = type(data.holds) == "table" and data.holds or {}
    return data
end

--- Check the link to Libby: token state plus a sync. Returns a list of
-- human-readable lines (also written to the log).
function Client:diagnose()
    local lines = { "Token: " .. Libby.describeToken(self:identity()), "Server: " .. Libby.SENTRY }
    Log.write("libby: connection test;", lines[1])
    local data, err = self:sync()
    if data then
        lines[#lines + 1] = string.format("Sync OK: %d card(s), %d loan(s), %d hold(s)",
            #data.cards, #data.loans, #data.holds)
    else
        lines[#lines + 1] = "Sync failed: " .. tostring(err)
    end
    Log.write("libby: connection test result:", lines[#lines])
    return lines, data
end

--- Normalize a Libby card for storage.
function Libby.normalizeCard(card)
    local lib = type(card.library) == "table" and card.library or {}
    local periods = {}
    if type(card.lendingPeriods) == "table" then
        for media, info in pairs(card.lendingPeriods) do
            if type(info) == "table" then
                local pref = type(info.preference) == "table" and info.preference or nil
                local options = {}
                for _, o in ipairs(type(info.options) == "table" and info.options or {}) do
                    if type(o) == "table" and Util.num(o[1]) then options[#options + 1] = o[1] end
                end
                periods[media] = {
                    days = pref and Util.num(pref[1]) or nil,
                    unit = pref and Util.str(pref[2]) or "days",
                    options = options,
                }
            end
        end
    end
    local card_id = Util.str(card.cardId) or (Util.num(card.cardId) and string.format("%d", card.cardId))
    return {
        card_id = card_id,
        card_name = Util.str(card.cardName),
        key = Util.str(card.advantageKey),
        library_name = Util.str(lib.name) or Util.str(card.cardName) or Util.str(card.advantageKey),
        website_id = Util.str(lib.websiteId) or (Util.num(lib.websiteId) and tostring(lib.websiteId)),
        periods = periods,
    }
end

--- Normalize a loan for display.
function Libby.normalizeLoan(loan)
    local formats, locked = {}, nil
    for _, f in ipairs(type(loan.formats) == "table" and loan.formats or {}) do
        local id = Util.str(f.id)
        if id then formats[#formats + 1] = id end
        -- e.g. after "Read with Kindle" the loan can only be used that way.
        if id and f.isLockedIn == true then locked = id end
    end
    local card_id = Util.str(loan.cardId) or (Util.num(loan.cardId) and string.format("%d", loan.cardId))
    return {
        id = Util.str(loan.id) or (Util.num(loan.id) and tostring(loan.id)),
        card_id = card_id,
        title = Util.str(loan.title) or "?",
        author = Util.str(loan.firstCreatorName),
        type = type(loan.type) == "table" and Util.str(loan.type.id) or nil,
        expires = Util.str(loan.expireDate),
        formats = formats,
        locked = locked,
    }
end

--- Borrow a title. card is a normalized card.
function Client:borrow(card, title_id, media_type)
    media_type = media_type or "ebook"
    local p = card.periods and card.periods[media_type] or {}
    local tries = {}
    local seen = {}
    local function add(d) if d and not seen[d] then seen[d] = true; tries[#tries + 1] = d end end
    add(p.days)
    add(14)
    add(21)
    for _, d in ipairs(p.options or {}) do add(d) end

    local last_err, last_code
    for i, days in ipairs(tries) do
        local data, resp, err = self:_call("POST",
            string.format("card/%s/loan/%s", card.card_id, title_id),
            { json = { period = days, units = p.unit or "days", title_format = media_type } })
        if not resp then return nil, err end
        if resp.code >= 200 and resp.code < 300 then
            return data or {}
        end
        last_err = errorMessage(data, resp, "Borrow failed")
        last_code = upstreamCode(data)
        -- Only an unacceptable lending period is worth retrying.
        local text = (last_err or ""):lower()
        if not (text:find("period", 1, true) or text:find("lending", 1, true)) or i >= 4 then
            break
        end
    end
    -- The third value is the library's error code, if it gave one.
    return nil, last_err, last_code
end

function Client:placeHold(card, title_id)
    local data, resp, err = self:_call("POST",
        string.format("card/%s/hold/%s", card.card_id, title_id),
        { json = { days_to_suspend = 0, email_address = "" } })
    if not resp then return nil, err end
    if resp.code >= 200 and resp.code < 300 then return data or {} end
    return nil, errorMessage(data, resp, "Couldn't place the hold")
end

function Client:returnLoan(card_id, title_id)
    local data, resp, err = self:_call("DELETE", string.format("card/%s/loan/%s", card_id, title_id))
    if not resp then return nil, err end
    if resp.code >= 200 and resp.code < 300 then return true end
    return nil, errorMessage(data, resp, "Couldn't return the loan")
end

--- The /open/<kind>/ segment the gateway expects for a loan's media type.
-- Ebooks (and anything else the read host serves) open as "book"; magazines as
-- "magazine". Audiobooks aren't handled by the on-device decoder.
function Libby.openKind(loan)
    local t = (type(loan) == "table" and Util.str(loan.type) or ""):lower()
    if t == "magazine" then return "magazine" end
    return "book"
end

--- Open a loan on the gateway for reading and return its fulfillment passport
-- ({ urls = { web = "https://dewey-<buid>.read.libbyapp.com/" }, message = … }).
-- This is the endpoint the Libby web app uses to read in the browser; unlike the
-- ACSM download link, it is not refused for this client. Returns passport or nil, error.
-- card is a normalized card; loan is a normalized loan (needs id, type).
function Client:open(card, loan)
    local card_id = card.card_id
    local title_id = loan.id
    if not (card_id and title_id and card.website_id) then
        return nil, "Missing card, title or website id for open"
    end
    local psn = string.format("%s-%s", card_id, title_id)
    local codex = {
        codex = {
            title = { titleId = tostring(title_id), slug = tostring(title_id) },
            loan = { psnKey = psn, slug = psn },
            library = { key = card.key, name = card.library_name or card.key },
        },
        ["dewey-url"] = "https://libbyapp.com",
        spec = "V31",
    }
    local t = Util.urlencode(Util.base64Encode(Http.encodeJSON(codex)))
    local path = string.format("open/%s/card/%s/title/%s?t=%s&website_id=%s",
        Libby.openKind(loan), card_id, title_id, t, card.website_id)
    Log.write("libby: open", Libby.openKind(loan), "loan", title_id, "on card", card_id)
    local data, resp, err = self:_call("GET", path,
        { headers = { ["Sec-Fetch-Site"] = "same-site", ["Sec-Fetch-Mode"] = "cors" } })
    if not resp then return nil, err end
    if resp.code < 200 or resp.code >= 300 or type(data) ~= "table" then
        return nil, errorWithSource(data, resp, "Couldn't open the loan for reading")
    end
    return data
end

local function looksRight(format_id, body)
    if format_id == Libby.FORMAT_ACSM or format_id == Libby.FORMAT_PDF_ACSM then
        return body:find("fulfillmentToken", 1, true) ~= nil
    end
    if format_id == Libby.FORMAT_EPUB then
        return body:sub(1, 2) == "PK"
    end
    return #body > 0
end

--- Download the file for a loan (ACSM token or DRM-free EPUB).
-- Returns body string or nil, error.
--- Download the file for a loan (ACSM token or DRM-free EPUB).
-- Returns body, or nil, error, and "blocked" when Libby refuses downloads from
-- this client ("missing_chip" while the same token works for everything else).
function Client:fulfill(card_id, title_id, format_id)
    self:freshen()
    local path = string.format("card/%s/loan/%s/fulfill/%s", card_id, title_id, format_id)
    Log.write("libby: download", format_id, "for loan", title_id, "on card", card_id)
    local resp, err = self:_raw("GET", path, { accept = "*/*", large = true })
    if not resp then return nil, err end
    local data = Http.decodeJSON(resp.body)
    if resp.code == 403 and type(data) == "table" and data.result == "missing_chip" then
        -- Renew the token app-style (type "v") and try again.
        Log.write("libby: download refused (missing_chip) with token:", Libby.describeToken(self:identity()))
        if self:refreshChip() then
            resp, err = self:_raw("GET", path, { accept = "*/*", large = true })
            if not resp then return nil, err end
            data = Http.decodeJSON(resp.body)
        end
    end
    if resp.code == 403 and type(data) == "table" and data.result == "missing_chip" then
        -- odmpy also asks this endpoint for JSON fulfillment details; try that once.
        Log.write("libby: download refused (missing_chip); asking for fulfillment details instead")
        resp, err = self:_raw("GET", path, { accept = "application/json", large = true })
        if not resp then return nil, err end
        data = Http.decodeJSON(resp.body)
        if resp.code == 403 and type(data) == "table" and data.result == "missing_chip" then
            Log.write("libby: downloads are refused for this client")
            return nil, errorWithSource(data, resp, "Download refused"), "blocked"
        end
    end
    if resp.code < 200 or resp.code >= 300 then
        return nil, errorWithSource(data, resp, "Download failed")
    end
    local body = resp.body or ""
    -- Some formats answer with a JSON pointer to the real file.
    if not looksRight(format_id, body) and body:match("^%s*{") then
        data = Http.decodeJSON(body)
        local href = type(data) == "table" and type(data.fulfill) == "table" and Util.str(data.fulfill.href)
        if href then
            resp, err = self:_raw("GET", href, { accept = "*/*", large = true, auth = false })
            if not resp then return nil, err end
            if resp.code < 200 or resp.code >= 300 then
                return nil, errorWithSource(Http.decodeJSON(resp.body), resp, "Download failed")
            end
            body = resp.body or ""
        end
    end
    if not looksRight(format_id, body) then
        logger.warn("grlibby: unexpected fulfillment body", format_id, body:sub(1, 200))
        Log.write("libby: unexpected download reply:", Log.excerpt(body))
        return nil, "Libby returned something that isn't a " ..
            (Libby.EXTENSION[format_id] or "book") .. " file."
    end
    return body
end

return Libby
