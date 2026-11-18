--[[--
A tiny, dependency-free EPUB 3 writer.

It streams a ZIP to disk one entry at a time (header + name + payload), so a book
is never held whole in memory: the caller adds the mimetype and container, then
each decoded page and each fetched image asset as it arrives, then the generated
nav/ncx/opf, and finally closes the archive. Every entry is *stored* (no
compression) — valid per the EPUB OCF spec (only the mimetype must be stored and
first), and the right call here anyway: page XHTML is small and image assets are
already-compressed JPEG/PNG. CRC-32 uses LuaJIT's bit ops (KOReader runs LuaJIT).

Assembly (container.xml / content.opf / nav.xhtml / toc.ncx and the page wrapper)
mirrors libby-archiver's src/epub.mjs so the output is the same shape.
--]]

local Epub = {}

--------------------------------------------------------------------------------
-- CRC-32 (IEEE, as ZIP requires). KOReader runs LuaJIT, so use its `bit` library
-- (fast, JITs well); fall back to pure arithmetic when `bit` is absent (e.g. a
-- plain-Lua test runtime), so this module loads and works on any Lua.
--------------------------------------------------------------------------------

local crc32
local ok_bit, bit = pcall(require, "bit")
if ok_bit and bit and bit.bxor then
    local bxor, band, rshift = bit.bxor, bit.band, bit.rshift
    local CRC_TABLE = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if band(c, 1) == 1 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
        end
        CRC_TABLE[i] = c
    end
    crc32 = function(s)
        local crc = -1 -- 0xFFFFFFFF as a signed 32-bit int (bit ops are 32-bit)
        for i = 1, #s do
            crc = bxor(rshift(crc, 8), CRC_TABLE[band(bxor(crc, s:byte(i)), 0xFF)])
        end
        crc = bxor(crc, -1)
        if crc < 0 then crc = crc + 4294967296 end -- back to unsigned 0..2^32-1
        return crc
    end
else
    -- Pure-arithmetic path: an 8-bit XOR table plus the byte-wise CRC table,
    -- both built lazily (only when an EPUB is actually assembled).
    local XOR8, CRC_TABLE
    local floor = math.floor
    local function xor32(a, b)
        local a0, a1, a2, a3 = a % 256, floor(a / 256) % 256, floor(a / 65536) % 256, floor(a / 16777216) % 256
        local b0, b1, b2, b3 = b % 256, floor(b / 256) % 256, floor(b / 65536) % 256, floor(b / 16777216) % 256
        return XOR8[a0][b0] + XOR8[a1][b1] * 256 + XOR8[a2][b2] * 65536 + XOR8[a3][b3] * 16777216
    end
    local function build()
        XOR8 = {}
        for a = 0, 255 do
            local row = {}
            for b = 0, 255 do
                local x, bitv, aa, bb = 0, 1, a, b
                for _ = 1, 8 do
                    local abit, bbit = aa % 2, bb % 2
                    if abit ~= bbit then x = x + bitv end
                    aa = (aa - abit) / 2; bb = (bb - bbit) / 2; bitv = bitv * 2
                end
                row[b] = x
            end
            XOR8[a] = row
        end
        CRC_TABLE = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if c % 2 == 1 then c = xor32(0xEDB88320, (c - 1) / 2) else c = c / 2 end
            end
            CRC_TABLE[i] = c
        end
    end
    crc32 = function(s)
        if not XOR8 then build() end
        local crc = 0xFFFFFFFF
        for i = 1, #s do
            local lo = crc % 256
            crc = xor32((crc - lo) / 256, CRC_TABLE[XOR8[lo][s:byte(i)]])
        end
        return xor32(crc, 0xFFFFFFFF)
    end
end
Epub.crc32 = crc32

--------------------------------------------------------------------------------
-- Little-endian integer encoders (arithmetic, so 32-bit values never go negative)
--------------------------------------------------------------------------------

local function u16(n)
    n = n % 65536
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
    n = n % 4294967296
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

-- An entry name must stay inside the archive.
local function safeName(name)
    name = tostring(name)
    if name == "" or name:sub(1, 1) == "/" or name:find("\0", 1, true) then
        error("unsafe EPUB entry name: " .. name)
    end
    for part in name:gmatch("[^/]+") do
        if part == ".." then error("unsafe EPUB entry name: " .. name) end
    end
    return name
end

--------------------------------------------------------------------------------
-- Streaming ZIP writer
--------------------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

--- Open a writer that assembles the archive at `path` (via a `.part` temp file).
function Epub.newWriter(path)
    local f, err = io.open(path .. ".part", "wb")
    if not f then return nil, err end
    return setmetatable({ f = f, part = path .. ".part", final = path, pos = 0, dir = {} }, Writer)
end

--- Append one stored entry (name + payload). Payload may be any byte string.
function Writer:add(name, data)
    name = safeName(name)
    data = data or ""
    local crc = crc32(data)
    local nlen = #name
    local dlen = #data
    -- Local file header (30 bytes) + name + stored payload.
    self.f:write("PK\3\4", u16(20), u16(0), u16(0), u16(0), u16(0x21),
        u32(crc), u32(dlen), u32(dlen), u16(nlen), u16(0), name, data)
    self.dir[#self.dir + 1] = { name = name, crc = crc, size = dlen, offset = self.pos }
    self.pos = self.pos + 30 + nlen + dlen
end

--- Write the central directory + EOCD, close, and move into place. Returns the
-- final path, or nil and an error (leaving no partial file behind).
function Writer:finish()
    local dir_start = self.pos
    local dir_size = 0
    for _, e in ipairs(self.dir) do
        -- Central directory record (46 bytes) + name.
        self.f:write("PK\1\2", u16(20), u16(20), u16(0), u16(0), u16(0), u16(0x21),
            u32(e.crc), u32(e.size), u32(e.size), u16(#e.name),
            u16(0), u16(0), u16(0), u16(0), u32(0), u32(e.offset), e.name)
        dir_size = dir_size + 46 + #e.name
    end
    -- End of central directory (22 bytes).
    self.f:write("PK\5\6", u16(0), u16(0), u16(#self.dir), u16(#self.dir),
        u32(dir_size), u32(dir_start), u16(0))
    self.f:close()
    self.f = nil
    os.remove(self.final) -- os.rename won't overwrite on every platform
    if not os.rename(self.part, self.final) then
        os.remove(self.part)
        return nil, "couldn't move the finished EPUB into place"
    end
    return self.final
end

--- Give up: close and delete the partial file. Safe to call more than once.
function Writer:abort()
    if self.f then pcall(function() self.f:close() end) end
    self.f = nil
    if self.part then os.remove(self.part) end
end

--------------------------------------------------------------------------------
-- EPUB document assembly (mirrors libby-archiver/src/epub.mjs)
--------------------------------------------------------------------------------

local function xml(s)
    s = tostring(s == nil and "" or s)
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "") -- control chars invalid in XML 1.0
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    return s
end
Epub.xml = xml

local MIME = {
    jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png",
    gif = "image/gif", svg = "image/svg+xml", webp = "image/webp",
}
local function mimeOf(name)
    local ext = name:match("%.([%w]+)$")
    return (ext and MIME[ext:lower()]) or "application/octet-stream"
end
Epub.mimeOf = mimeOf

-- A manifest id that is unique and XML-safe, derived from a path.
local function idFor(path, used)
    local base = "i" .. path:gsub("[^%w]+", "_")
    local id, n = base, 1
    while used[id] do id = base .. "_" .. n; n = n + 1 end
    used[id] = true
    return id
end

--- Wrap a decoded page body in minimal XHTML (optionally fixed-layout viewport).
function Epub.wrapPage(body, viewport)
    local vp = ""
    if viewport and viewport.width and viewport.height then
        vp = string.format('\n  <meta name="viewport" content="width=%s, height=%s"/>',
            viewport.width, viewport.height)
    end
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. "<!DOCTYPE html>\n"
        .. '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\n'
        .. "<head>\n  <meta charset=\"utf-8\"/>\n  <title></title>" .. vp .. "\n"
        .. "  <style>html,body{margin:0;padding:0}svg,img{display:block;max-width:100%}</style>\n"
        .. "</head>\n" .. tostring(body or "") .. "\n</html>\n"
end

Epub.CONTAINER_XML =
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    .. '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    .. "  <rootfiles>\n    <rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/>\n  </rootfiles>\n"
    .. "</container>\n"

--- Build nav.xhtml, toc.ncx and content.opf for a book.
-- book = { meta = {identifier,title,subtitle,creator,language,description},
--          pages = { {id, href}, … },   -- in spine order
--          assets = { {id, href}, … },
--          nav = { {title, href}, … },  -- already resolved to real page hrefs
--          fixedLayout = bool }
-- Returns nav_xhtml, toc_ncx, content_opf (strings).
function Epub.documents(book)
    local meta = book.meta or {}
    local pages = book.pages or {}
    local assets = book.assets or {}
    local nav = book.nav or {}

    -- nav.xhtml
    local nav_items = {}
    local list = nav
    if #list == 0 then
        list = {}
        for _, p in ipairs(pages) do list[#list + 1] = { title = p.href, href = p.href } end
    end
    for _, n in ipairs(list) do
        nav_items[#nav_items + 1] = string.format('      <li><a href="%s">%s</a></li>',
            xml(n.href), xml(n.title))
    end
    local nav_xhtml = '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\n'
        .. "<head><meta charset=\"utf-8\"/><title>" .. xml(meta.title) .. "</title></head>\n<body>\n"
        .. '  <nav epub:type="toc" id="toc">\n    <h1>' .. xml(meta.title) .. "</h1>\n    <ol>\n"
        .. table.concat(nav_items, "\n") .. "\n    </ol>\n  </nav>\n</body>\n</html>\n"

    -- toc.ncx
    local ncx_points = {}
    for i, n in ipairs(list) do
        ncx_points[#ncx_points + 1] = string.format(
            '    <navPoint id="np%d" playOrder="%d">\n      <navLabel><text>%s</text></navLabel>\n      <content src="%s"/>\n    </navPoint>',
            i - 1, i, xml(n.title), xml(n.href))
    end
    local toc_ncx = '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
        .. '  <head><meta name="dtb:uid" content="' .. xml(meta.identifier) .. "\"/></head>\n"
        .. "  <docTitle><text>" .. xml(meta.title) .. "</text></docTitle>\n  <navMap>\n"
        .. table.concat(ncx_points, "\n") .. "\n  </navMap>\n</ncx>\n"

    -- content.opf
    local dc = {
        '    <dc:identifier id="pub-id">' .. xml(meta.identifier) .. "</dc:identifier>",
        "    <dc:title>" .. xml(meta.title) .. (meta.subtitle and (": " .. xml(meta.subtitle)) or "") .. "</dc:title>",
        "    <dc:language>" .. xml(meta.language or "en") .. "</dc:language>",
    }
    if meta.creator then dc[#dc + 1] = "    <dc:creator>" .. xml(meta.creator) .. "</dc:creator>" end
    if meta.description then dc[#dc + 1] = "    <dc:description>" .. xml(meta.description) .. "</dc:description>" end
    dc[#dc + 1] = '    <meta property="dcterms:modified">' .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. "</meta>"
    if book.fixedLayout then
        dc[#dc + 1] = '    <meta property="rendition:layout">pre-paginated</meta>'
        dc[#dc + 1] = '    <meta property="rendition:orientation">auto</meta>'
        dc[#dc + 1] = '    <meta property="rendition:spread">auto</meta>'
    end

    local manifest = {
        '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
        '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    }
    for _, p in ipairs(pages) do
        manifest[#manifest + 1] = string.format('    <item id="%s" href="%s" media-type="application/xhtml+xml"/>',
            p.id, xml(p.href))
    end
    for _, a in ipairs(assets) do
        manifest[#manifest + 1] = string.format('    <item id="%s" href="%s" media-type="%s"/>',
            a.id, xml(a.href), mimeOf(a.href))
    end

    local spine = {}
    for _, p in ipairs(pages) do spine[#spine + 1] = string.format('    <itemref idref="%s"/>', p.id) end

    local content_opf = '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id"'
        .. ' prefix="rendition: http://www.idpf.org/vocab/rendition/#">\n'
        .. '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n' .. table.concat(dc, "\n") .. "\n  </metadata>\n"
        .. "  <manifest>\n" .. table.concat(manifest, "\n") .. "\n  </manifest>\n"
        .. '  <spine toc="ncx">\n' .. table.concat(spine, "\n") .. "\n  </spine>\n"
        .. "</package>\n"

    return nav_xhtml, toc_ncx, content_opf
end

Epub.idFor = idFor

return Epub
