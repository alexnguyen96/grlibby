--[[--
On-device EPUB builder — the fallback for when Libby refuses to hand this client
the ACSM download (missing_chip).

It reproduces, in pure Lua, the browser-free read path that libby-archiver works
out on the desktop (see its src/openbook.mjs + src/read.mjs + src/archive-read.mjs):

  1. open the loan on the gateway -> a fulfillment "passport" (done by the caller,
     grlibby/libby.lua Client:open — it needs the Libby token).
  2. follow the passport's signed handshake on the per-loan read host to set a
     session cookie, then fetch the reader page. Its window.eData array is an
     obfuscated openbook (spine + signed component params); de-obfuscate it.
  3. for each spine page, fetch the component and reverse OverDrive's __bif_cfc1
     per-page cipher to get the page's XHTML/SVG; collect its image refs.
  4. fetch the referenced image assets (served in the clear).
  5. assemble it all into an EPUB with grlibby/epub.lua.

Nothing here bypasses a lending limit: it saves, for offline reading, a copy of a
book already borrowed on the user's own card. The reader page is de-obfuscated
structurally and never executed as code.

The eData scramble and the __bif_cfc1 cipher are OverDrive's; if either changes,
decoding fails with a message naming the broken step rather than writing garbage.
--]]

local Http = require("grlibby/http")
local Util = require("grlibby/util")
local Epub = require("grlibby/epub")
local Log = require("grlibby/log")

local Openbook = {}

--------------------------------------------------------------------------------
-- De-obfuscation (pure, no network) — mirrors libby-archiver byte for byte
--------------------------------------------------------------------------------

-- Undo bifocal's per-position scramble on the reader page's eData. `key` is the
-- read host's buid reversed. For each 0-based position a, a nonzero digit in the
-- key shifts the byte by (a + digit) % 94, wrapping values above 126 back into
-- printable range — exactly the inverse the browser applies.
local function descramble(key, data)
    local klen = #key
    if klen == 0 then return data end
    local shifts = {}
    for i = 1, klen do
        local d = tonumber(key:sub(i, i))
        shifts[i] = (d and d >= 1 and d <= 9) and d or 0
    end
    local out = {}
    for a = 0, #data - 1 do
        local ch = data:byte(a + 1)
        local d = shifts[(a % klen) + 1]
        if d ~= 0 then
            ch = ch + ((a + d) % 94)
            if ch > 126 then ch = (ch % 126) + 32 end
        end
        out[a + 1] = string.char(ch)
    end
    return table.concat(out)
end
Openbook.descramble = descramble

-- Decode the reader page's window.eData into the openbook table (its `.b`).
-- Returns the openbook, or nil and a message naming the step that failed.
-- Extract the array of strings from `window.eData = [...]`. The scrambled
-- segments can contain '[' and ']', so (like libby-archiver) we anchor the end
-- on the `;SPARK.bifocalPath` that always follows, rather than bracket-balancing.
-- The array is JSON (backslashes etc. escaped), so decode it as JSON; only if that
-- fails do we fall back to slicing quoted runs (bifocal's single-quoted variant).
local function extractEData(html)
    local literal = html:match("window%.eData%s*=%s*(%[.-%])%s*;%s*SPARK%.bifocalPath")
        or html:match("window%.eData%s*=%s*(%b[])")
    if not literal then return nil end
    local decoded = Http.decodeJSON(literal)
    if type(decoded) == "table" and #decoded > 0 then
        local parts, ok = {}, true
        for i = 1, #decoded do
            if type(decoded[i]) ~= "string" then ok = false break end
            parts[i] = decoded[i]
        end
        if ok then return parts end
    end
    local parts = {}
    for s in literal:gmatch('"([^"]*)"') do parts[#parts + 1] = s end
    if #parts == 0 then
        for s in literal:gmatch("'([^']*)'") do parts[#parts + 1] = s end
    end
    return #parts > 0 and parts or nil
end

local function decodeOpenbook(html, buid)
    local parts = extractEData(html)
    if not parts then return nil, "the reader page had no window.eData (OverDrive page format may have changed)" end
    local b64 = descramble(buid:reverse(), table.concat(parts, '"'))
    local json = Util.base64Decode(b64)
    if not json:match("^%s*[%[{]") then
        return nil, "reader-page decode produced non-JSON (the eData scramble may have changed)"
    end
    local doc = Http.decodeJSON(json)
    if type(doc) ~= "table" or type(doc.b) ~= "table" then
        return nil, "the decoded reader data carried no openbook"
    end
    return doc.b
end
Openbook.decodeOpenbook = decodeOpenbook

-- Reverse one __bif_cfc1 blob: swap chars 1 and 4 of every 4-char group, then
-- base64-decode. Blobs are newline-free base64, so a plain quad-swap gsub is the
-- exact inverse (Lua '.' matches every byte, and there are no line terminators).
local function cfc1(blob)
    local swapped = blob:gsub("(.)(.)(.)(.)", "%4%2%3%1")
    return Util.base64Decode(swapped)
end
Openbook.cfc1 = cfc1

-- SVG from the decoder omits namespace declarations (the browser infers them);
-- add them so each page is valid standalone XHTML.
local function namespaceSvg(body)
    return (body:gsub("<svg[^>]*>", function(tag)
        if tag:find("xmlns=", 1, true) then return tag end
        return '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"' .. tag:sub(5)
    end))
end

-- Decode a fetched reader-page component into its XHTML/SVG body, or nil, error.
local function decodePage(html)
    local blob = html:match("parent%.__bif_cfc1%(%s*self%s*,%s*'([^']*)'%s*%)")
    if not blob then return nil, "a page component was missing (nothing to decode)" end
    local body = cfc1(blob)
    if not body:match("^%s*<") then
        return nil, "a decoded page was not markup (the __bif_cfc1 cipher may have changed)"
    end
    return namespaceSvg(body)
end
Openbook.decodePage = decodePage

-- Distinct image asset refs in a decoded page body, leading "../" stripped.
local function assetRefs(body)
    local refs, seen = {}, {}
    local function consider(u)
        u = u or ""
        while u:sub(1, 3) == "../" do u = u:sub(4) end
        if u:find("assets/", 1, true) and not seen[u] then
            seen[u] = true
            refs[#refs + 1] = u
        end
    end
    for u in body:gmatch('href="([^"]*)"') do consider(u) end
    for u in body:gmatch('src="([^"]*)"') do consider(u) end
    return refs
end
Openbook.assetRefs = assetRefs

-- Ordered spine of fetchable page components. Each: { index, path, url, viewport }.
local function extractSpine(ob, web)
    local base = web:gsub("/+$", "")
    local cmpts = type(ob["-odread-cmpt-params"]) == "table" and ob["-odread-cmpt-params"] or {}
    local spine = type(ob.spine) == "table" and ob.spine or {}
    local out = {}
    for i, part in ipairs(spine) do
        local path = Util.str(part["-odread-original-path"]) or Util.str(part.path)
        if path then
            local pos = Util.num(part["-odread-spine-position"]) or (i - 1)
            local cmpt = cmpts[pos + 1] or ""
            local vp = type(part["rendition-viewport"]) == "table" and part["rendition-viewport"] or nil
            out[#out + 1] = {
                index = i,
                path = path,
                url = base .. "/" .. path .. (cmpt ~= "" and ("?" .. cmpt) or ""),
                viewport = vp and vp.width and vp.height and { width = vp.width, height = vp.height } or nil,
            }
        end
    end
    return out
end
Openbook.extractSpine = extractSpine

local function isFixedLayout(ob)
    for _, p in ipairs(type(ob.spine) == "table" and ob.spine or {}) do
        if type(p) == "table" and p["rendition-layout"] == "pre-paginated" then return true end
    end
    return false
end

-- TOC entries resolved to real spine pages (drops ones that don't resolve).
local function buildNav(ob, pathset)
    local out = {}
    local toc = type(ob.nav) == "table" and type(ob.nav.toc) == "table" and ob.nav.toc or {}
    for _, e in ipairs(toc) do
        if type(e) == "table" then
            local href = (Util.str(e.path) or ""):gsub("#.*$", "")
            if href ~= "" and pathset[href] then
                out[#out + 1] = { title = Util.str(e.title) or Util.str(e.sectionName) or href, href = href }
            end
        end
    end
    return out
end

local function metaFrom(ob, buid, hint)
    local t = type(ob.title) == "table" and ob.title or {}
    local creators = type(ob.creator) == "table" and ob.creator or {}
    local author
    for _, c in ipairs(creators) do
        if type(c) == "table" and (Util.str(c.role) or ""):lower():find("aut") then
            author = Util.str(c.name)
            break
        end
    end
    if not author and type(creators[1]) == "table" then author = Util.str(creators[1].name) end
    local lang = ob.language
    if type(lang) == "table" then lang = lang[1] end
    return {
        identifier = Util.str(ob["-odread-buid"]) or ("libby-" .. tostring(hint.title_id or buid)),
        title = Util.str(t.main) or hint.title or "Book",
        subtitle = Util.str(t.subtitle) or hint.subtitle,
        creator = author or hint.author,
        language = Util.str(lang),
    }
end

--------------------------------------------------------------------------------
-- Read-host session + fetches (network)
--------------------------------------------------------------------------------

--- Establish the read-host session from an open passport and decode the openbook.
-- Returns { web, buid, jar, openbook } or nil, error.
function Openbook.readSession(passport)
    local web = type(passport) == "table" and type(passport.urls) == "table" and Util.str(passport.urls.web)
    if not web then return nil, "the open response carried no reader URL" end
    local host = Http.hostOf(web)
    local label = host and host:match("^([^.]+)")
    local buid = label and label:match("^[^-]+%-(.+)$")
    if not buid then return nil, "couldn't read the reader host id from " .. tostring(host) end

    local jar = {}
    local message = Util.str(passport.message) or ""
    -- 1. follow the signed handshake (sets the session cookie; no token needed).
    local resp, err = Http.request{
        url = web .. (web:find("?", 1, true) and "&" or "?") .. message,
        headers = { Accept = "text/html" }, cookies = jar, large = true, trace = true,
    }
    if not resp then return nil, err end
    -- 2. fetch the reader page carrying window.eData.
    resp, err = Http.request{ url = web, headers = { Accept = "text/html" }, cookies = jar, large = true, trace = true }
    if not resp then return nil, err end
    if resp.code ~= 200 then return nil, string.format("the reader page returned HTTP %d", resp.code) end
    local ob, derr = decodeOpenbook(resp.body, buid)
    if not ob then return nil, derr end
    return { web = web, buid = buid, jar = jar, openbook = ob }
end

--- Fetch + decode one spine page. Returns body (markup) or nil, error.
function Openbook.fetchPage(session, part)
    local resp, err = Http.request{ url = part.url, headers = { Accept = "*/*" }, cookies = session.jar, large = true }
    if not resp then return nil, err end
    if resp.code ~= 200 then return nil, string.format("page %s returned HTTP %d", part.path, resp.code) end
    return decodePage(resp.body)
end

--- Fetch one image asset (plaintext). Returns bytes or nil, HTTP code / error.
function Openbook.fetchAsset(session, ref)
    local resp, err = Http.request{
        url = session.web:gsub("/+$", "") .. "/" .. ref,
        headers = { Accept = "*/*" }, cookies = session.jar, large = true,
    }
    if not resp then return nil, err end
    if resp.code ~= 200 then return nil, resp.code end
    return resp.body
end

--------------------------------------------------------------------------------
-- Builder: a resumable state machine driven one unit at a time (so the plugin's
-- runSteps harness can show progress and a Stop button, in a subprocess when the
-- platform allows). step(emit) does one unit and returns true until finished.
--------------------------------------------------------------------------------

local Builder = {}
Builder.__index = Builder

--- passport: from Client:open. epub_path: final .epub path. hint: { title, author,
--- subtitle, title_id } used when the openbook omits a field.
function Openbook.newBuilder(passport, epub_path, hint)
    return setmetatable({ passport = passport, epub_path = epub_path, hint = hint or {}, phase = "init" }, Builder)
end

function Builder:fail(emit, err)
    if self.w then self.w:abort(); self.w = nil end
    self.phase = "done"
    Log.write("decode: failed:", tostring(err))
    emit({ err = tostring(err or "building the book failed") })
    return false
end

function Builder:step(emit)
    local phase = self.phase

    if phase == "init" then
        local session, err = Openbook.readSession(self.passport)
        if not session then return self:fail(emit, err) end
        self.session = session
        self.spine = extractSpine(session.openbook, session.web)
        if #self.spine == 0 then return self:fail(emit, "the loan had no pages to decode") end
        self.fixedLayout = isFixedLayout(session.openbook)
        local pathset = {}
        for _, p in ipairs(self.spine) do pathset[p.path] = true end
        self.nav = buildNav(session.openbook, pathset)
        self.meta = metaFrom(session.openbook, session.buid, self.hint)

        local w, werr = Epub.newWriter(self.epub_path)
        if not w then return self:fail(emit, werr or "couldn't create the EPUB file") end
        self.w = w
        emit({ part = self.epub_path .. ".part" }) -- so a Stop can clean up the partial
        w:add("mimetype", "application/epub+zip")
        w:add("META-INF/container.xml", Epub.CONTAINER_XML)

        self.used, self.pages, self.assets = {}, {}, {}
        self.wanted, self.seen, self.asset_names = {}, {}, {}
        self.i = 0
        Log.write("decode: building", self.meta.title, "-", #self.spine, "page(s)")
        self.phase = "pages"
        return true
    end

    if phase == "pages" then
        self.i = self.i + 1
        local part = self.spine[self.i]
        local body, perr = Openbook.fetchPage(self.session, part)
        if not body then return self:fail(emit, perr) end
        local id = Epub.idFor(part.path, self.used)
        self.w:add("OEBPS/" .. part.path, Epub.wrapPage(body, part.viewport))
        self.pages[#self.pages + 1] = { id = id, href = part.path }
        for _, ref in ipairs(assetRefs(body)) do
            if not self.seen[ref] then
                self.seen[ref] = true
                self.wanted[#self.wanted + 1] = ref
            end
        end
        emit({ stage = "pages", i = self.i, n = #self.spine })
        if self.i >= #self.spine then
            self.j = 0
            self.phase = (#self.wanted > 0) and "assets" or "finalize"
        end
        return true
    end

    if phase == "assets" then
        self.j = self.j + 1
        local ref = self.wanted[self.j]
        local name = "assets/" .. (ref:match("([^/]+)$") or ref)
        local bytes, acode = Openbook.fetchAsset(self.session, ref)
        if bytes and not self.asset_names[name] then
            self.asset_names[name] = true
            self.w:add("OEBPS/" .. name, bytes)
            self.assets[#self.assets + 1] = { id = Epub.idFor(name, self.used), href = name }
        elseif not bytes then
            Log.write("decode: asset", ref, "skipped:", tostring(acode))
        end
        emit({ stage = "assets", i = self.j, n = #self.wanted })
        if self.j >= #self.wanted then self.phase = "finalize" end
        return true
    end

    if phase == "finalize" then
        local nav_xhtml, toc_ncx, content_opf = Epub.documents({
            meta = self.meta, pages = self.pages, assets = self.assets,
            nav = self.nav, fixedLayout = self.fixedLayout,
        })
        self.w:add("OEBPS/nav.xhtml", nav_xhtml)
        self.w:add("OEBPS/toc.ncx", toc_ncx)
        self.w:add("OEBPS/content.opf", content_opf)
        local final, ferr = self.w:finish()
        self.w = nil
        if not final then return self:fail(emit, ferr or "couldn't finish the EPUB") end
        Log.write("decode: wrote", final, "(" .. #self.pages .. " pages, " .. #self.assets .. " assets)")
        emit({ done = final })
        self.phase = "done"
        return false
    end

    return false
end

return Openbook
