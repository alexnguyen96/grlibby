#!/usr/bin/env python3
"""Tests for the browser-free on-device decode/EPUB pipeline (grlibby/openbook.lua
and grlibby/epub.lua): the fallback that builds an EPUB when Libby refuses the
ACSM download.

The forward encoders here (scramble / cfc1Encode / eData page) are the exact
inverse of what the Lua decoders must do; they mirror libby-archiver's
test/helpers/overdrive-sim.mjs, which reproduces OverDrive's real wire formats.

Runs on LuaJIT 2.1 (as KOReader uses) when lupa bundles it, else any Lua. The
EPUB writer's CRC-32 is checked against Python's zlib on both code paths.

    pip install lupa
    python3 tests/decode_test.py
"""
import base64, io, json, os, re, sys, tempfile, zipfile, zlib, posixpath

try:  # match KOReader's LuaJIT 2.1 when available
    from lupa.luajit21 import LuaRuntime, lua_type
except ImportError:
    from lupa import LuaRuntime, lua_type

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "goodreadslibby.koplugin")
OUT = tempfile.mkdtemp(prefix="grlibby-decode-test-")

lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)


def L(s):
    return s.encode() if isinstance(s, str) else s


def U(v):
    return v.decode("utf-8", "replace") if isinstance(v, bytes) else v


def first(v):
    return v[0] if isinstance(v, tuple) else v


def to_lua(v):
    if isinstance(v, dict):
        t = lua.table()
        for k, x in v.items():
            if x is not None:
                t[L(k)] = to_lua(x)
        return t
    if isinstance(v, list):
        t = lua.table()
        for i, x in enumerate(v):
            t[i + 1] = to_lua(x)
        return t
    if isinstance(v, bool):
        return v
    if isinstance(v, str):
        return v.encode()
    return v


def from_lua(v):
    if lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys):
            return [from_lua(v[i]) for i in sorted(keys)]
        return {U(k): from_lua(x) for k, x in v.items()}
    return U(v)


# ---- forward encoders (mirror overdrive-sim.mjs) -----------------------------
def scramble(key, data):
    out = []
    klen = len(key)
    for a in range(len(data)):
        target = ord(data[a])
        kc = key[a % klen]
        d = int(kc) if kc.isdigit() else 0
        if d == 0:
            out.append(data[a])
            continue
        found = data[a]
        for c in range(32, 127):
            y = c + ((a + d) % 94)
            if y > 126:
                y = (y % 126) + 32
            if y == target:
                found = chr(c)
                break
        out.append(found)
    return "".join(out)


def key_for(web):
    host = web.split("://", 1)[1].split("/", 1)[0]
    return host.split(".")[0].split("-", 1)[1][::-1]


def edata_page(doc, web):
    j = base64.b64encode(json.dumps(doc).encode()).decode()
    literal = json.dumps(scramble(key_for(web), j).split('"'))
    return "<!doctype html><script>window.eData = %s;SPARK.bifocalPath='bifocal.js';</script>" % literal


def cfc1_encode(content):
    b = base64.b64encode(content.encode()).decode()
    return "".join(b[i + 3] + b[i + 1] + b[i + 2] + b[i] for i in range(0, len(b), 4))


def cfc1_page(content):
    return "<!doctype html><script>parent.__bif_cfc1(self, '%s');</script>" % cfc1_encode(content)


# ---- KOReader module stubs (logger, json, a scripted socket.http) ------------
g = lua.globals()
g.py_json_decode = lambda s: (lambda o: to_lua(o))(json.loads(bytes(s).decode("utf-8"))) if s else None
g.py_json_encode = lambda t: json.dumps(from_lua(t)).encode()

RESPONSES = {}


def add_response(url, code, body, setcookie=None):
    RESPONSES[url] = (code, body if isinstance(body, (bytes, bytearray)) else body.encode(), setcookie)


def _fetch(url):
    url = U(url)
    r = RESPONSES.get(url)
    t = lua.table()
    if not r:
        t[b"code"] = 404
        t[b"body"] = b""
        return t
    code, body, sc = r
    t[b"code"] = code
    t[b"body"] = body
    if sc:
        t[b"setcookie"] = sc.encode()
    return t


g.py_fetch = _fetch
g.PLUGIN = PLUGIN.encode()
lua.execute(rb"""
package.path = PLUGIN .. "/?.lua;" .. package.path
local function mod(t) return function() return t end end
package.preload["logger"] = mod({ info=function()end, warn=function()end, err=function()end, dbg=function()end })
package.preload["rapidjson"] = mod({ decode=function(s) return py_json_decode(s) end, encode=function(t) return py_json_encode(t) end })
package.preload["ltn12"] = mod({
  source = { string = function(s) local d=false; return function() if d then return nil end d=true return s end end },
  sink = { table = function(t) return function(c) if c then t[#t+1]=c end return 1 end end },
})
package.preload["socket"] = mod({ skip = function(n, ...) return select(n+1, ...) end })
package.preload["socketutil"] = mod({ set_timeout=function() end, reset_timeout=function() end })
package.preload["socket.http"] = mod({ request = function(req)
  local m = py_fetch(req.url)
  if req.sink then req.sink(m.body or "") req.sink(nil) end
  local h = { ["content-type"]="text/html" }
  if m.setcookie then h["set-cookie"] = m.setcookie end
  return 1, m.code, h, "status"
end })
""")

Util = lua.eval(b'(require("grlibby/util"))')
Epub = lua.eval(b'(require("grlibby/epub"))')
Http = lua.eval(b'(require("grlibby/http"))')
Openbook = lua.eval(b'(require("grlibby/openbook"))')

fails = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (("  " + str(extra)) if (extra and not cond) else ""))
    if not cond:
        fails.append(name)


# 1) CRC-32 matches zlib (whichever path epub.lua took: bit or arithmetic)
for s in [b"", b"a", b"application/epub+zip", b"hello & <world>" * 64, bytes(range(256))]:
    got = int(Epub.crc32(s))
    check("crc32 %d bytes" % len(s), got == zlib.crc32(s) & 0xffffffff, "%x vs %x" % (got, zlib.crc32(s) & 0xffffffff))

# 2) base64Encode
for s in [b"", b"f", b"fo", b"foo", b"foob", b"\x00\xff\x10a", os.urandom(257)]:
    check("base64Encode %d" % len(s), base64.b64decode(U(Util.base64Encode(s))) == s)

WEB = "https://dewey-ABC123.read.libbyapp.com/"
BUID = "ABC123"

# 3) descramble inverts scramble
import random
random.seed(1)
sample = base64.b64encode(bytes(random.randrange(256) for _ in range(777))).decode()
check("descramble round-trip", U(Openbook.descramble(L(key_for(WEB)), L(scramble(key_for(WEB), sample)))) == sample)

# 4) cfc1 inverts cfc1Encode (incl. non-ASCII content)
content = '<svg xmlns="x"><image href="../assets/h-1.jpg"/>café — & <b>x</b></svg>'
check("cfc1 round-trip", U(first(Openbook.cfc1(L(cfc1_encode(content))))) == content)

# 5) decodeOpenbook (with a backslash-bearing payload -> JSON-escaped eData array)
random.seed(7)
pad = base64.b64encode(bytes(random.randrange(256) for _ in range(3000))).decode()
doc = {"b": {"title": {"main": "A Novel", "subtitle": "Sub"}, "language": "en",
             "creator": [{"name": "A. Writer", "role": "author"}], "-odread-buid": BUID,
             "spine": [{"path": "pages/1.xhtml", "-odread-spine-position": 0, "-odread-original-path": "pages/1.xhtml"},
                       {"path": "pages/2.xhtml", "-odread-spine-position": 1, "-odread-original-path": "pages/2.xhtml"}],
             "-odread-cmpt-params": ["cmpt=0", "cmpt=1"],
             "nav": {"toc": [{"title": "Start", "path": "pages/1.xhtml"}]}, "pad": pad}}
ob = from_lua(first(Openbook.decodeOpenbook(L(edata_page(doc, WEB)), L(BUID))))
check("decodeOpenbook title", isinstance(ob, dict) and ob.get("title", {}).get("main") == "A Novel", ob)
check("decodeOpenbook survives backslashes", isinstance(ob, dict) and ob.get("pad") == pad)

# 6) decodePage + namespaceSvg
body = '<svg viewBox="0 0 1 1"><image href="../assets/h-9.jpg"/></svg>'
dec = U(first(Openbook.decodePage(L(cfc1_page(body)))))
check("decodePage namespaced", dec.startswith('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink'))

# 7) extractSpine + assetRefs
ob_lua = first(Openbook.decodeOpenbook(L(edata_page(doc, WEB)), L(BUID)))
spine = from_lua(Openbook.extractSpine(ob_lua, L(WEB)))
check("extractSpine url+cmpt", spine[0]["url"] == WEB.rstrip("/") + "/pages/1.xhtml?cmpt=0", spine[0]["url"])
check("assetRefs strips ../ + dedups", from_lua(Openbook.assetRefs(L(dec))) == ["assets/h-9.jpg"])

# 8) EPUB writer -> structurally valid zip
out = os.path.join(OUT, "unit.epub")
w = Epub.newWriter(L(out))
w.add(w, b"mimetype", b"application/epub+zip")
w.add(w, b"META-INF/container.xml", Epub.CONTAINER_XML)
w.add(w, b"OEBPS/pages/1.xhtml", Epub.wrapPage(L("<p>hi &amp; <b>x</b></p>")))
jpg = b"\xff\xd8\xff\xe0\x00\x10JFIF" + os.urandom(1500) + b"\xff\xd9"
w.add(w, b"OEBPS/assets/h-9.jpg", jpg)
nav, ncx, opf = Epub.documents(to_lua({
    "meta": {"identifier": BUID, "title": "A <Novel>", "creator": "A. Writer", "language": "en"},
    "pages": [{"id": "ip1", "href": "pages/1.xhtml"}],
    "assets": [{"id": "ia1", "href": "assets/h-9.jpg"}],
    "nav": [{"title": "Start", "href": "pages/1.xhtml"}], "fixedLayout": False}))
w.add(w, b"OEBPS/nav.xhtml", nav)
w.add(w, b"OEBPS/toc.ncx", ncx)
w.add(w, b"OEBPS/content.opf", opf)
check("writer finish", U(first(w.finish(w))) == out)
zf = zipfile.ZipFile(out)
check("zip CRCs valid", zf.testzip() is None)
check("mimetype first & stored", zf.namelist()[0] == "mimetype" and zf.infolist()[0].compress_type == zipfile.ZIP_STORED)
check("asset bytes intact", zf.read("OEBPS/assets/h-9.jpg") == jpg)
check("opf escapes title", "A &lt;Novel&gt;" in zf.read("OEBPS/content.opf").decode())

# 9) End-to-end builder through the scripted HTTP layer
def page_body(n):
    return ('<svg viewBox="0 0 800 1200"><image href="../assets/h-1.jpg"/>'
            '<text>page %d café &amp; co</text></svg>' % n)


e2e = {"b": {"title": {"main": "E2E Novel", "subtitle": "Sim"}, "language": "en",
             "creator": [{"name": "E. Author", "role": "author"}], "-odread-buid": BUID,
             "spine": [{"path": "pages/1.xhtml", "-odread-spine-position": 0, "-odread-original-path": "pages/1.xhtml"},
                       {"path": "pages/2.xhtml", "-odread-spine-position": 1, "-odread-original-path": "pages/2.xhtml"}],
             "-odread-cmpt-params": ["cmpt=0", "cmpt=1"],
             "nav": {"toc": [{"title": "Front", "path": "pages/1.xhtml"}]}}}
jpg2 = b"\xff\xd8\xff\xe0\x00\x10JFIF" + bytes(range(256)) * 6 + b"\xff\xd9"
base = WEB.rstrip("/")
add_response(WEB + "?sig=abc", 200, "<ok/>", setcookie="odread=TOKEN; Path=/; HttpOnly")
add_response(WEB, 200, edata_page(e2e, WEB))
add_response(base + "/pages/1.xhtml?cmpt=0", 200, cfc1_page(page_body(1)))
add_response(base + "/pages/2.xhtml?cmpt=1", 200, cfc1_page(page_body(2)))
add_response(base + "/assets/h-1.jpg", 200, jpg2)

out2 = os.path.join(OUT, "e2e.epub")
builder = Openbook.newBuilder(to_lua({"urls": {"web": WEB}, "message": "sig=abc"}),
                              out2.encode(), to_lua({"title": "E2E Novel", "author": "E. Author", "title_id": "99"}))
msgs = []
emit = lua.eval(b"function(cb) return function(m) cb(m) end end")(lambda m: msgs.append(from_lua(m)))
guard = 0
while builder.step(builder, emit) and guard < 1000:
    guard += 1
done = next((m.get("done") for m in msgs if isinstance(m, dict) and m.get("done")), None)
err = next((m.get("err") for m in msgs if isinstance(m, dict) and m.get("err")), None)
check("e2e no error", err is None, err)
check("e2e produced epub", done == out2, done)
if done and os.path.exists(done):
    z = zipfile.ZipFile(done)
    names = z.namelist()
    check("e2e zip valid", z.testzip() is None)
    check("e2e both pages", "OEBPS/pages/1.xhtml" in names and "OEBPS/pages/2.xhtml" in names)
    check("e2e asset deduped", names.count("OEBPS/assets/h-1.jpg") == 1 and z.read("OEBPS/assets/h-1.jpg") == jpg2)
    check("e2e opf has 2 itemrefs", z.read("OEBPS/content.opf").decode().count("<itemref") == 2)
    # every asset reference in every page resolves to a file in the EPUB
    for pg in ("OEBPS/pages/1.xhtml", "OEBPS/pages/2.xhtml"):
        text = z.read(pg).decode()
        for ref in re.findall(r'href="([^"]*assets/[^"]+)"', text):
            tgt = posixpath.normpath(posixpath.join(posixpath.dirname(pg), ref))
            check("link resolves %s" % ref, tgt in names, tgt)

print("\n%d failure(s)" % len(fails))
sys.exit(1 if fails else 0)
