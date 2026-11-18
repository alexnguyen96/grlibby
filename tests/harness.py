"""
Run the plugin's Lua modules outside KOReader (via lupa) with KOReader's
LuaSocket / logger / JSON modules stubbed by Python, so the Goodreads and
OverDrive code paths can be exercised against the real services.

    pip install lupa
    python3 tests/harness.py            # unit + live tests
    python3 tests/harness.py --offline  # unit tests only
"""
import json
import os
import sys
import urllib.error
import urllib.request

import lupa
from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "goodreadslibby.koplugin")

lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect)


FAKE_HOST = {}  # url prefix -> list of (code, headers, body) to serve in order
SEEN = []


def py_http_request(req):
    url = req[b"url"].decode()
    for prefix, queue in FAKE_HOST.items():
        if url.startswith(prefix) and queue:
            hdrs = {}
            if req[b"headers"] is not None:
                for k, v in req[b"headers"].items():
                    hdrs[k.decode()] = v.decode()
            SEEN.append((req[b"method"].decode() if req[b"method"] else "GET", url, hdrs))
            code, rh, body = queue.pop(0)
            sink = req[b"sink"]
            if sink is not None:
                sink(body.encode() if isinstance(body, str) else body)
                sink(None)
            return 1, code, lua.table_from({k.encode(): v.encode() for k, v in rh.items()}), b"status"
    method = (req[b"method"] or b"GET").decode()
    headers = {}
    if req[b"headers"] is not None:
        for k, v in req[b"headers"].items():
            headers[k.decode()] = v.decode()
    body = None
    source = req[b"source"]
    if source is not None:
        parts = []
        while True:
            chunk = source()
            if chunk is None:
                break
            parts.append(chunk)
        body = b"".join(parts)
    r = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        resp = opener.open(r, timeout=30)
        code, hdrs, data = resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        code, hdrs, data = e.code, e.headers, e.read()
    except Exception as e:  # network failure -> LuaSocket style (nil, err)
        return None, str(e).encode()
    sink = req[b"sink"]
    if sink is not None:
        sink(data)
        sink(None)
    lua_headers = lua.table_from({k.lower().encode(): v.encode() for k, v in hdrs.items()})
    return 1, code, lua_headers, b"status"


def to_lua(v):
    if isinstance(v, dict):
        return lua.table_from({k.encode(): to_lua(x) for k, x in v.items() if x is not None})
    if isinstance(v, list):
        t = lua.table()
        for i, x in enumerate(v):
            t[i + 1] = to_lua(x)
        return t
    if isinstance(v, str):
        return v.encode()
    return v


def from_lua(v):
    if lupa.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys):
            return [from_lua(v[i]) for i in sorted(keys)]
        return {(k.decode() if isinstance(k, bytes) else k): from_lua(x) for k, x in v.items()}
    if isinstance(v, bytes):
        return v.decode("utf-8", "replace")
    return v


def json_decode(s):
    return to_lua(json.loads(s.decode("utf-8")))


def json_encode(t):
    return json.dumps(from_lua(t)).encode()


g = lua.globals()
g.py_http_request = py_http_request
g.py_json_decode = json_decode
g.py_json_encode = json_encode
g.PLUGIN = PLUGIN.encode()

lua.execute(b"""
package.path = PLUGIN .. "/?.lua;" .. package.path
unpack = unpack or table.unpack
package.preload["socket.http"] = function()
    return { request = function(req) return py_http_request(req) end }
end
package.preload["socket"] = function()
    return { skip = function(n, ...) return select(n + 1, ...) end }
end
package.preload["ltn12"] = function()
    return {
        source = { string = function(s) local done = false
            return function() if done then return nil end done = true return s end end },
        sink = { table = function(t) return function(c) if c then t[#t + 1] = c end return 1 end end },
    }
end
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end,
             LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30 }
end
package.preload["logger"] = function()
    local function nop() end
    return { info = nop, warn = function(...) print("WARN", ...) end, err = print, dbg = nop }
end
package.preload["rapidjson"] = function()
    return { decode = function(s) return py_json_decode(s) end,
             encode = function(t) return py_json_encode(t) end }
end
""")

# --- libs/libkoreader-lfs and ffi/archiver backed by Python -------------------
import shutil
import tempfile
import zipfile


def lfs_attributes(path, what=None):
    path = path.decode()
    if not os.path.exists(path):
        return None
    info = {"mode": "directory" if os.path.isdir(path) else "file", "size": os.path.getsize(path)}
    if what is not None:
        v = info[what.decode()]
        return v.encode() if isinstance(v, str) else v
    return to_lua(info)


def lfs_listdir(path):
    try:
        return to_lua([".", ".."] + os.listdir(path.decode()))
    except OSError:
        return to_lua([])


def lfs_mkdir(path):
    try:
        os.mkdir(path.decode())
        return True
    except OSError as e:
        return None, str(e).encode()


def lfs_rmdir(path):
    try:
        os.rmdir(path.decode())
        return True
    except OSError as e:
        return None, str(e).encode()


def zip_list(path):
    try:
        with zipfile.ZipFile(path.decode()) as z:
            return to_lua([{"path": i.filename, "mode": "directory" if i.is_dir() else "file"} for i in z.infolist()])
    except Exception:
        return None


def zip_read(path, name):
    with zipfile.ZipFile(path.decode()) as z:
        return z.read(name.decode())


g.py_lfs_attributes = lfs_attributes
g.py_lfs_listdir = lfs_listdir
g.py_lfs_mkdir = lfs_mkdir
g.py_lfs_rmdir = lfs_rmdir
g.py_zip_list = zip_list
g.py_zip_read = zip_read
lua.execute(b"""
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(p, what) return py_lfs_attributes(p, what) end,
        dir = function(p) local names, i = py_lfs_listdir(p), 0
            return function() i = i + 1 return names[i] end end,
        mkdir = function(p) return py_lfs_mkdir(p) end,
        rmdir = function(p) return py_lfs_rmdir(p) end,
    }
end
use_archiver = true
package.preload["ffi/archiver"] = function()
    if not use_archiver then error("module 'ffi/archiver' not found") end
    local Reader = {}
    Reader.__index = Reader
    function Reader:new() return setmetatable({}, Reader) end
    function Reader:open(p) self.path = p; self.entries = py_zip_list(p); return self.entries ~= nil end
    function Reader:iterate() local i = 0 return function() i = i + 1 return self.entries[i] end end
    function Reader:extractToMemory(name) return py_zip_read(self.path, name) end
    function Reader:close() end
    return { Reader = Reader }
end
""")

failures = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" -- " + str(detail)) if detail else ""))
    if not cond:
        failures.append(name)


Util = lua.eval(b'(require("grlibby/util"))')
Goodreads = lua.eval(b'(require("grlibby/goodreads"))')
Match = lua.eval(b'(require("grlibby/match"))')
Libby = lua.eval(b'(require("grlibby/libby"))')
Http = lua.eval(b'(require("grlibby/http"))')
Update = lua.eval(b'(require("grlibby/update"))')
Log = lua.eval(b'(require("grlibby/log"))')


two = lua.eval(b"function(f, ...) local r = table.pack(f(...)) return r[1], r[2] end")


def s(v):
    return v.decode() if isinstance(v, bytes) else v


# ---------------------------------------------------------------- unit tests
check("urlencode", s(Util.urlencode(b"a b&c")) == "a%20b%26c")
check("unescape", s(Util.unescape(b"O&apos;Brady &amp; &#8217;x&#x41;")) == "O'Brady & ’xA")
check("safeFilename", s(Util.safeFilename(b'Who: "Me"/You?')) == "Who_ _Me__You_", s(Util.safeFilename(b'Who: "Me"/You?')))
long_name = ("é" * 100).encode()
check("safeFilename utf8 cut", s(Util.safeFilename(long_name, 51)) == "é" * 25)
check("absolute url", s(Http.absolute(b"https://a.com/x/y?z", b"/p")) == "https://a.com/p")
check("absolute rel", s(Http.absolute(b"https://a.com/x/y", b"q")) == "https://a.com/x/q")

acc = Goodreads.parseAccount(b"https://www.goodreads.com/user/show/12345-john-doe")
check("account from profile", s(acc[b"id"]) == "12345")
acc = Goodreads.parseAccount(b"https://www.goodreads.com/review/list_rss/777?key=AbC-12_x&shelf=%23ALL%23")
check("account from rss", s(acc[b"id"]) == "777" and s(acc[b"key"]) == "AbC-12_x")
check("account from id", s(Goodreads.parseAccount(b" 42 ")[b"id"]) == "42")
check("account rejects junk", Goodreads.parseAccount(b"hello") is None)

check("mainTitle series", s(Match.mainTitle(b"Leviathan Wakes (The Expanse, #1)")) == "Leviathan Wakes")
check("mainTitle subtitle", s(Match.mainTitle(b"Educated: A Memoir")) == "Educated")
check("titleScore exact", Match.titleScore(b"The Martian", b"Martian") == 1)
check("titleScore diff", Match.titleScore(b"Dune", b"The Hobbit") < 0.6)
check("surname", s(Match.surname(b"J.R.R. Tolkien")) == "tolkien")
check("surname comma", s(Match.surname(b"Weir, Andy")) == "weir")
check("isbn13 from 10", s(Match.isbn13(b"1982133112")) == "9781982133115")

items = to_lua([
    {"id": "1", "title": "Project Hail Mary", "type": {"id": "audiobook"}, "creators": [{"name": "Andy Weir"}],
     "availableCopies": 3, "ownedCopies": 3, "formats": [{"id": "audiobook-mp3"}]},
    {"id": "2", "title": "Project Hail Mary", "type": {"id": "ebook"}, "creators": [{"name": "Andy Weir"}],
     "availableCopies": 0, "ownedCopies": 10, "holdsCount": 40, "estimatedWaitDays": 30, "isHoldable": True,
     "formats": [{"id": "ebook-epub-adobe"}, {"id": "ebook-kindle"}]},
    {"id": "3", "title": "Project Hail Mary", "type": {"id": "ebook"}, "creators": [{"name": "Andy Weir"}],
     "availableCopies": 1, "ownedCopies": 1, "isAvailable": True, "formats": [{"id": "ebook-epub-adobe"}]},
    {"id": "4", "title": "Project Hail Mary", "type": {"id": "ebook"}, "creators": [{"name": "Someone Else"}],
     "availableCopies": 5, "ownedCopies": 5, "isAvailable": True, "formats": [{"id": "ebook-epub-open"}]},
])
book = to_lua({"title": "Project Hail Mary", "author": "Andy Weir"})
best = Match.best(book, items)
check("best picks available ebook edition", s(best[b"id"]) == "3" and s(best[b"status"]) == "available", from_lua(best))
check("best marks acsm", best[b"acsm"] is True)

isbn_items = to_lua([{"id": "9", "title": "Totally Different Title", "type": {"id": "ebook"},
                      "creators": [{"name": "X"}], "ownedCopies": 2, "availableCopies": 0, "isHoldable": True,
                      "formats": [{"id": "ebook-epub-adobe", "identifiers": [{"type": "ISBN", "value": "9781982133115"}]}]}])
best = Match.best(to_lua({"title": "Impossible First", "author": "Colin O'Brady", "isbn": "1982133112"}), isbn_items)
check("isbn match beats title", best is not None and s(best[b"status"]) == "hold")
check("no match", Match.best(to_lua({"title": "Dune", "author": "Frank Herbert"}), items) is None)

overall = Match.overall(to_lua({"a": {"status": "hold", "wait_days": 20}, "b": {"status": "hold", "wait_days": 5},
                                "c": {"status": "none"}}))
check("overall shortest wait", overall[b"wait_days"] == 5)
overall = Match.overall(to_lua({"a": {"status": "hold"}, "b": {"status": "borrowed"}}))
check("overall borrowed first", s(overall[b"status"]) == "borrowed")

card = Libby.normalizeCard(to_lua({"cardId": "123", "advantageKey": "nypl", "cardName": "My card",
                                   "library": {"name": "New York Public Library", "websiteId": 57},
                                   "lendingPeriods": {"ebook": {"preference": [21, "days"],
                                                                "options": [[7, "days"], [14, "days"], [21, "days"]]}}}))
check("normalizeCard", s(card[b"key"]) == "nypl" and s(card[b"library_name"]) == "New York Public Library"
      and card[b"periods"][b"ebook"][b"days"] == 21 and s(card[b"website_id"]) == "57", from_lua(card))
loan = Libby.normalizeLoan(to_lua({"id": "5665700", "cardId": 123, "title": "PHM", "type": {"id": "ebook"},
                                   "formats": [{"id": "ebook-epub-adobe"}], "expireDate": "2026-10-15T10:00:00Z"}))
check("normalizeLoan", s(loan[b"card_id"]) == "123" and s(loan[b"formats"][1]) == "ebook-epub-adobe")

# Fake sentry exchange to exercise borrow/fulfill logic without an account.
lua.execute(b"""
local Http = require("grlibby/http")
local real = Http.request
fake_calls = {}
function install_fake(responses)
    Http.request = function(opts)
        fake_calls[#fake_calls + 1] = opts
        local r = table.remove(responses, 1)
        return r
    end
end
function restore_http() Http.request = real end
""")
client = Libby.newClient(lua.eval(b'{ get = function() return identity end, set = function(v) identity = v end }'))
lua.execute(b'identity = "tok"')
lua.eval(b"install_fake")(lua.eval(b"""{
    { code = 400, headers = {}, body = '{"result":"invalid_period","upstream":{"userExplanation":"Invalid lending period"}}' },
    { code = 200, headers = {}, body = '{"id":"5665700"}' },
}"""))
c = Libby.normalizeCard(to_lua({"cardId": "1", "advantageKey": "x", "lendingPeriods": {"ebook": {"preference": [7, "days"]}}}))
res, err = two(client.borrow, client, c, b"5665700", b"ebook")
calls = lua.eval(b"fake_calls")
first = json.loads(calls[1][b"body"])
second = json.loads(calls[2][b"body"])
check("borrow retries bad period", res is not None and first["period"] == 7 and second["period"] == 14
      and s(calls[1][b"url"]).endswith("/card/1/loan/5665700") and s(calls[1][b"headers"][b"Authorization"]) == "Bearer tok",
      (first, second, err))

lua.execute(b"fake_calls = {}")
lua.eval(b"install_fake")(lua.eval(b"""{
    { code = 200, headers = {}, body = '<fulfillmentToken xmlns="http://ns.adobe.com/adept">...</fulfillmentToken>' },
}"""))
body, err = two(client.fulfill, client, b"1", b"5665700", b"ebook-epub-adobe")
check("fulfill acsm", body is not None and b"fulfillmentToken" in body, err)

lua.eval(b"install_fake")(lua.eval(b"""{
    { code = 200, headers = {}, body = '{"fulfill":{"href":"https://cdn.example/file.epub"}}' },
    { code = 200, headers = {}, body = 'PK\\3\\4rest-of-zip' },
}"""))
body, err = two(client.fulfill, client, b"1", b"5665700", b"ebook-epub-open")
check("fulfill follows json href", body is not None and body.startswith(b"PK"), err)

lua.eval(b"install_fake")(lua.eval(b"""{
    { code = 401, headers = {}, body = '' },
    { code = 200, headers = {}, body = '{"identity":"fresh","chip":"c"}' },
    { code = 200, headers = {}, body = '{"cards":[{"cardId":"9","advantageKey":"lapl"}],"loans":[],"holds":[]}' },
}"""))
data, err = two(client.sync, client)
check("sync renews expired identity", data is not None and s(lua.eval(b"identity")) == "fresh"
      and s(data[b"cards"][1][b"advantageKey"]) == "lapl", err)
lua.eval(b"restore_http")()

res, err = two(client.cloneByCode, client, b"1234")
check("clone rejects short code", res is None and b"8 digits" in err)

# ---------------------------------------------------------------- goodreads.txt
sample = open(os.path.join(ROOT, "tests", "fixtures", "goodreads.sample.txt"), "rb").read()
check("sample goodreads.txt is not an account", Goodreads.parseAccountText(sample) is None)
filled = sample.replace(b"PASTE_YOUR_RSS_LINK_HERE",
                        b"https://www.goodreads.com/review/list_rss/123456?key=k3Y-x_9&shelf=%23ALL%23")
acc = Goodreads.parseConfig(filled)[b"account"]
check("filled goodreads.txt parses (comments ignored)", acc is not None and s(acc[b"id"]) == "123456"
      and s(acc[b"key"]) == "k3Y-x_9")
check("accountString round-trips", from_lua(Goodreads.parseAccount(Goodreads.accountString(acc))) == {"id": "123456", "key": "k3Y-x_9"})

# ---------------------------------------------------------------- goodreads.txt (multi-shelf)
cfg = Goodreads.parseConfig(sample)
check("sample: [optional] / PASTE_ placeholders quietly skipped", len(from_lua(cfg[b"shelves"]) or []) == 0
      and not from_lua(cfg[b"errors"]) and cfg[b"account"] is None, from_lua(cfg[b"errors"]))
multi = b"""# my shelves
profile = https://www.goodreads.com/user/show/777-me
Want to Read = https://www.goodreads.com/review/list_rss/777?key=K1&shelf=to-read
Book club = book-club
Everything = https://www.goodreads.com/review/list_rss/777?key=K1
Otis = https://www.goodreads.com/review/list_rss/1?shelf=to-read
Otis read = https://www.goodreads.com/review/list/1-otis?shelf=read
Bad line = hello world
"""
cfg = Goodreads.parseConfig(multi)
shelves = [(e["name"], e["shelf"], (e.get("user") or {}).get("id")) for e in from_lua(cfg[b"shelves"])]
check("multi: nicknames, shelves, owners", shelves == [("Want to Read", "to-read", None), ("Book club", "book-club", None),
      ("Everything", "#ALL#", None), ("Otis", "to-read", "1"), ("Otis read", "read", "1")], shelves)
check("multi: account from profile + key from its RSS link", from_lua(cfg[b"account"]) == {"id": "777", "key": "K1"},
      from_lua(cfg[b"account"]))
check("multi: bad line reported", len(from_lua(cfg[b"errors"])) == 1 and "Bad line" in from_lua(cfg[b"errors"])[0])
cfg = Goodreads.parseConfig(b"user id = 42\nTBR = to-read\n")
check("user id only", from_lua(cfg[b"account"]) == {"id": "42"} and from_lua(cfg[b"shelves"])[0]["shelf"] == "to-read")
cfg = Goodreads.parseConfig(b"Mine = https://www.goodreads.com/review/list_rss/9?key=abc&shelf=read\n")
check("no profile: account from first RSS link", from_lua(cfg[b"account"]) == {"id": "9", "key": "abc"})
cfg = Goodreads.parseConfig(b"# old format\nhttps://www.goodreads.com/review/list_rss/9?key=abc&shelf=%23ALL%23\n")
check("old single-line file still works", from_lua(cfg[b"account"]) == {"id": "9", "key": "abc"}
      and not from_lua(cfg[b"errors"]) and not from_lua(cfg[b"shelves"]))
cfg = Goodreads.parseConfig(multi)
sh = cfg[b"shelves"]
sh[1][b"name"] = b"My TBR"
sh[2][b"shelf"] = b"favorites"
out = Goodreads.formatConfig(cfg, multi)
re = Goodreads.parseConfig(out)
again = [(e["name"], e["shelf"], (e.get("user") or {}).get("id")) for e in from_lua(re[b"shelves"])]
check("write-back keeps comments, profile, edits", out.startswith(b"# my shelves") and b"profile = https://www.goodreads.com/user/show/777-me" in out
      and again[0] == ("My TBR", "to-read", None) and again[1] == ("Book club", "favorites", None)
      and b"list_rss/777?shelf=favorites&key=K1" in out and again[3] == ("Otis", "to-read", "1"), out.decode())

# ---------------------------------------------------------------- log + Libby token handling
import base64, time
LOGFILE = os.path.join(tempfile.mkdtemp(), "goodreadslibby.log")
Log.setPath(LOGFILE.encode())


def jwt(chip, cards, exp):
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")
    return "%s.%s.sig" % (enc({"alg": "RS256"}), enc({"iss": "sentry", "exp": exp, "chip": {"pri": chip, "cards": cards}}))


old_sentry = Libby.SENTRY
Libby.SENTRY = b"https://fake-sentry.test"
tok = jwt("abcdef12-3456", ["c1", "c2"], int(time.time()) + 6 * 86400)
lua.globals().store_tok = tok.encode()
client = Libby.newClient(lua.eval(b'{ get = function() return store_tok end, set = function(v) store_tok = v end }'))
check("token described", b"device abcdef12" in Libby.describeToken(tok.encode()) and b"2 card(s)" in Libby.describeToken(tok.encode())
      and b"in 6.0 days" in Libby.describeToken(tok.encode()), s(Libby.describeToken(tok.encode())))
FAKE_HOST["https://fake-sentry.test"] = [
    (302, {"Location": "/card/11/loan/22/fulfill/ebook-epub-adobe?step=2"}, ""),
    (403, {"Content-Type": "application/json"}, '{"result":"missing_chip","notice":"private API"}'),
    (200, {}, json.dumps({"chip": "abcdef12-3456", "identity": tok})),           # app-style renewal
    (403, {"Content-Type": "application/json"}, '{"result":"missing_chip","notice":"private API"}'),
    (403, {"Content-Type": "application/json"}, '{"result":"missing_chip","notice":"private API"}'),
]
three = lua.eval(b"function(f, ...) local r = table.pack(f(...)) return r[1], r[2], r[3] end")
body, err, why = three(client.fulfill, client, b"11", b"22", b"ebook-epub-adobe")
check("download error names status + server", body is None and s(err) == "missing_chip (HTTP 403 from fake-sentry.test)", s(err))
check("refused download reported as blocked (after one JSON retry)", s(why) == "blocked"
      and SEEN[-1][2].get("Accept") == "application/json", (s(why), SEEN[-1][2].get("Accept")))
check("token sent on every hop", [h.get("Authorization", "").startswith("Bearer ") for _m, _u, h in SEEN[-5:]] == [True] * 5)
check("refused download renews the token app-style first", "/chip?c=d:18.5.2&s=0&v=abcdef12" in SEEN[-3][1], SEEN[-3][1])

# Refused download, then accepted after the app-style renewal.
FAKE_HOST["https://fake-sentry.test"] = [
    (403, {"Content-Type": "application/json"}, '{"result":"missing_chip"}'),
    (200, {}, json.dumps({"chip": "abcdef12-3456", "identity": tok})),
    (200, {"Content-Type": "application/vnd.adobe.adept+xml"}, '<fulfillmentToken xmlns="http://ns.adobe.com/adept">x</fulfillmentToken>'),
]
body, err, why = three(client.fulfill, client, b"11", b"22", b"ebook-epub-adobe")
check("download works after app-style renewal", body is not None and b"fulfillmentToken" in body, s(err))

# App-style renewal refused: falls back to ?client=dewey.
FAKE_HOST["https://fake-sentry.test"] = [
    (400, {}, '{"result":"bad_request"}'),
    (200, {}, json.dumps({"chip": "abcdef12-3456", "identity": tok})),
]
ok, err = two(client.refreshChip, client)
check("renewal falls back to ?client=dewey", ok is True and SEEN[-1][1].endswith("/chip?client=dewey")
      and "c=d:18.5.2" in SEEN[-2][1], (SEEN[-2][1], SEEN[-1][1]))
logtext = open(LOGFILE).read()
check("log has the whole chain", "token: device abcdef12" in logtext and "-> 302 auth=yes location=/card/11/loan/22" in logtext
      and "-> 403 auth=yes" in logtext and "missing_chip" in logtext, logtext)
check("log hides the token", tok not in logtext and tok.split(".")[1] not in logtext)
Log.write(b"https://www.goodreads.com/review/list_rss/1?key=SECRETKEY&shelf=x", b'{"code":"12345678"}')
logtext = open(LOGFILE).read()
check("log hides RSS keys + setup codes", "SECRETKEY" not in logtext and "12345678" not in logtext and "key=<hidden>" in logtext)

# A type-"l" token is upgraded (renewed app-style) once, before the first call.
l_tok = jwt("abcdef12-3456", ["c1"], int(time.time()) + 6 * 86400)
l_tok = l_tok.split(".")[0] + "." + base64.urlsafe_b64encode(json.dumps({"iss": "sentry", "exp": int(time.time()) + 6 * 86400,
    "chip": {"pri": "abcdef12-3456", "cards": ["c1"], "prbn": "l"}}).encode()).decode().rstrip("=") + ".sig"
v_tok = l_tok.replace(".sig", "") .rsplit(".", 1)[0] + "." + base64.urlsafe_b64encode(json.dumps({"iss": "sentry",
    "exp": int(time.time()) + 7 * 86400, "chip": {"pri": "abcdef12-3456", "cards": ["c1"], "prbn": "v"}}).encode()).decode().rstrip("=") + ".sig"
lua.globals().store_tok = l_tok.encode()
up_client = Libby.newClient(lua.eval(b'{ get = function() return store_tok end, set = function(v) store_tok = v end }'))
FAKE_HOST["https://fake-sentry.test"] = [
    (200, {}, json.dumps({"chip": "abcdef12-3456", "identity": v_tok})),
    (200, {}, '{"result":"synchronized","cards":[],"loans":[],"holds":[]}'),
    (200, {}, '{"result":"synchronized","cards":[],"loans":[],"holds":[]}'),
]
two(up_client.sync, up_client)
two(up_client.sync, up_client)
check("type-l token upgraded once, app-style", s(lua.globals().store_tok) == v_tok and "c=d:18.5.2" in SEEN[-3][1]
      and SEEN[-1][1].endswith("/chip/sync") and SEEN[-2][1].endswith("/chip/sync"), [u for _m, u, _h in SEEN[-3:]])
lua.globals().store_tok = tok.encode()

# A library refusing the card is not a token problem: no renewal, no retry.
n_before = len(SEEN)
FAKE_HOST["https://fake-sentry.test"] = [(401, {}, json.dumps({"result": "unauthorized", "upstream": {
    "errorCode": "PatronCardFailedAuthentication", "userExplanation": "Invalid Library Card: .p1. Not a valid card."}}))]
card = Libby.normalizeCard(to_lua({"cardId": "5", "advantageKey": "auckland", "lendingPeriods": {"ebook": {"preference": [14, "days"]}}}))
res, err, code = three(client.borrow, client, card, b"9", b"ebook")
check("card refusal: one request, library's message + code", res is None and len(SEEN) - n_before == 1
      and s(err).startswith("Invalid Library Card") and s(code) == "PatronCardFailedAuthentication", (s(err), s(code), len(SEEN) - n_before))

# Early renewal: a token close to expiry is renewed (same device) before a call.
soon = jwt("abcdef12-3456", ["c1"], int(time.time()) + 3600)
fresh = jwt("abcdef12-3456", ["c1"], int(time.time()) + 7 * 86400)
lua.globals().store_tok = soon.encode()
FAKE_HOST["https://fake-sentry.test"] = [
    (200, {}, json.dumps({"chip": "abcdef12-3456", "identity": fresh})),
    (200, {}, '{"result":"synchronized","cards":[],"loans":[],"holds":[]}'),
]
data, err = two(client.sync, client)
check("near-expiry token renewed before use (app-style)", data is not None and s(lua.globals().store_tok) == fresh
      and "/chip?c=d:18.5.2" in SEEN[-2][1]
      and SEEN[-1][2].get("Authorization") == "Bearer " + fresh, s(err))
# A renewal that returns a different device is refused.
lua.globals().store_tok = soon.encode()
other = jwt("99999999-0000", [], int(time.time()) + 7 * 86400)
FAKE_HOST["https://fake-sentry.test"] = [(200, {}, json.dumps({"chip": "9999", "identity": other}))]
ok, err = two(client.refreshChip, client)
check("renewal to a different device refused", ok is False and s(lua.globals().store_tok) == soon, s(err))
FAKE_HOST["https://fake-sentry.test"] = [(200, {}, '{"result":"synchronized","cards":[{"cardId":"1","advantageKey":"x"}],"loans":[],"holds":[]}')]
lua.globals().store_tok = tok.encode()
lines, data = two(client.diagnose, client)
lines = from_lua(lines)
check("connection test summary", lines[0].startswith("Token: device abcdef12") and lines[2] == "Sync OK: 1 card(s), 0 loan(s), 0 hold(s)", lines)
Libby.SENTRY = old_sentry
FAKE_HOST.clear()

# ---------------------------------------------------------------- updater
check("version compare", Update.isNewer(b"v1.2.0", b"v1.1.9") and not Update.isNewer(b"v1.1.0", b"v1.1.0")
      and Update.isNewer(b"1.10.0", b"v1.9.3") and not Update.isNewer(b"v1.0", b"v1.0.1"))
check("findRoot zipball", s(Update.findRoot(to_lua(["o-r-abc/README.md", "o-r-abc/goodreadslibby.koplugin/_meta.lua",
                                                    "o-r-abc/goodreadslibby.koplugin/main.lua"]))) == "o-r-abc/goodreadslibby.koplugin/")

WORK = tempfile.mkdtemp()
ACSM_SRC = os.path.join(WORK, "acsm-src")
os.makedirs(os.path.join(ACSM_SRC, "adobe"))
open(os.path.join(ACSM_SRC, "_meta.lua"), "w").write('return { name = "acsm", version = "v0.0.13" }\n')
open(os.path.join(ACSM_SRC, "main.lua"), "w").write("return {}\n")
open(os.path.join(ACSM_SRC, "adobe", "adobe.lua"), "w").write("return {}\n")


def make_zip(path, version, prefix="acsm.koplugin/", name="acsm", src=ACSM_SRC):
    with zipfile.ZipFile(path, "w") as z:
        for root, _dirs, files in os.walk(src):
            for f in files:
                full = os.path.join(root, f)
                rel = os.path.relpath(full, src)
                data = open(full, "rb").read()
                if rel == "_meta.lua":
                    data = ('return { name = "%s", version = "%s" }\n' % (name, version)).encode()
                z.writestr(prefix + rel, data)
        z.writestr(prefix + "NEWFILE.txt", "new in this version")
    return open(path, "rb").read()


def plugins_dir(with_acsm):
    base = os.path.join(WORK, "plugins")
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base)
    target = os.path.join(base, "acsm.koplugin")
    if with_acsm:
        shutil.copytree(ACSM_SRC, target)
        open(os.path.join(target, "keep.me"), "w").write("user data")
    return target


def run_install(zip_bytes, target, opts):
    lua.eval(b"install_fake")(lua.eval(b"function(b) return { { code = 200, headers = {}, body = b } } end")(zip_bytes))
    info = to_lua({"version": "v9.9.9", "zip_url": "https://example.invalid/x.zip"})
    ok, err = two(Update.install, info, target.encode(), os.path.join(WORK, "cache").encode(), to_lua(opts))
    lua.eval(b"restore_http")()
    return ok, err


def installed_ok(target, ok):
    return (ok is True and s(Update.installedVersion(target.encode())) == "v9.9.9"
            and os.path.exists(os.path.join(target, "NEWFILE.txt"))
            and os.path.exists(os.path.join(target, "adobe", "adobe.lua"))
            and not os.path.exists(target + ".new") and not os.path.exists(target + ".old"))


target = plugins_dir(False)
ok, err = run_install(make_zip(os.path.join(WORK, "a.zip"), "v9.9.9"), target, {"name": "acsm"})
check("fresh install of acsm.koplugin", installed_ok(target, ok), s(err))

target = plugins_dir(True)
check("installedVersion reads _meta.lua", s(Update.installedVersion(target.encode())) == "v0.0.13")
ok, err = run_install(make_zip(os.path.join(WORK, "b.zip"), "v9.9.9"), target, {"name": "acsm", "preserve": ["keep.me"]})
check("update replaces folder, keeps preserved files", installed_ok(target, ok)
      and open(os.path.join(target, "keep.me")).read() == "user data", s(err))

target = plugins_dir(True)
ok, err = run_install(make_zip(os.path.join(WORK, "c.zip"), "v9.9.9", "kaikozlov-acsm.koplugin-1a2b3c/"), target, {"name": "acsm"})
check("update from source zipball", installed_ok(target, ok), s(err))

target = plugins_dir(True)
ok, err = run_install(make_zip(os.path.join(WORK, "d.zip"), "v9.9.9", name="other"), target, {"name": "acsm"})
check("refuses a different plugin, keeps current", ok is None and b"isn't" in err
      and s(Update.installedVersion(target.encode())) == "v0.0.13" and not os.path.exists(target + ".new"), s(err))

lua.execute(b'use_archiver = false; package.loaded["ffi/archiver"] = nil')
target = plugins_dir(True)
ok, err = run_install(make_zip(os.path.join(WORK, "e.zip"), "v9.9.9"), target, {"name": "acsm"})
check("update works with unzip fallback", installed_ok(target, ok), s(err))
lua.execute(b'use_archiver = true; package.loaded["ffi/archiver"] = nil')

lua.eval(b"install_fake")(lua.eval(b"""{ { code = 200, headers = {}, body = [[{"tag_name":"v0.0.14","body":"Notes",
  "html_url":"https://github.com/kaikozlov/acsm.koplugin/releases/v0.0.14","zipball_url":"https://api.github.com/zip",
  "assets":[{"name":"other.tar.gz","browser_download_url":"https://x/a.tgz"},
            {"name":"acsm-koplugin-v0.0.14.zip","browser_download_url":"https://x/acsm.zip"}]}]] } }"""))
info, err = two(Update.latest, b"kaikozlov/acsm.koplugin", b"acsm")
lua.eval(b"restore_http")()
check("latest picks the plugin zip asset", info is not None and s(info[b"zip_url"]) == "https://x/acsm.zip"
      and s(info[b"version"]) == "v0.0.14", s(err))

# ---------------------------------------------------------------- live tests
if "--offline" not in sys.argv:
    acc = Goodreads.parseAccount(b"1")
    books, err = two(Goodreads.fetchShelf, acc, b"to-read", 2)
    n = len(books) if books is not None else 0
    check("live: goodreads shelf fetched", books is not None and n > 100, err or n)
    if books is not None:
        b1 = books[1]
        print("   first book:", from_lua(b1)["title"], "/", from_lua(b1).get("author"), "/ isbn", from_lua(b1).get("isbn"))
    bad, err = two(Goodreads.fetchShelf, Goodreads.parseAccount(b"99999999999"), b"to-read", 1)
    check("live: unknown user gives an error", bad is None, s(err))

    tests = [("Project Hail Mary", "Andy Weir"), ("Educated: A Memoir", "Tara Westover"),
             ("The Fellowship of the Ring (The Lord of the Rings, #1)", "J.R.R. Tolkien"),
             ("A Book That Does Not Exist Anywhere Zzyzx", "Nobody")]
    for title, author in tests:
        bk = to_lua({"title": title, "author": author})
        items, err = two(Libby.search, b"nypl", Match.searchTitle(bk[b"title"]), Match.surname(bk[b"author"]))
        best = items and Match.best(bk, items)
        print("   nypl:", title, "->", from_lua(best) and {k: from_lua(best).get(k) for k in
              ("id", "title", "status", "available", "holds", "wait_days", "acsm")})
        if "Zzyzx" in title:
            check("live: nonsense not matched", best is None)
        else:
            check("live: matched " + title, best is not None, err)

    # Real GitHub release: install the actual acsm.koplugin, then update over it.
    info, err = two(Update.latest, b"kaikozlov/acsm.koplugin", b"acsm")
    check("live: acsm.koplugin latest release", info is not None and s(info[b"zip_url"]).endswith(".zip"),
          {k: from_lua(info)[k] for k in ("version", "zip_url")} if info is not None else s(err))
    if info is not None:
        target = plugins_dir(False)
        ok, err = two(Update.install, info, target.encode(), os.path.join(WORK, "cache").encode(), to_lua({"name": "acsm"}))
        check("live: real acsm.koplugin installed", ok is True
              and s(Update.installedVersion(target.encode())) == s(info[b"version"])
              and os.path.exists(os.path.join(target, "adobe", "fulfillment.lua"))
              and os.path.exists(os.path.join(target, "dependencies", "xml2lua.lua")), s(err))
        ok, err = two(Update.install, info, target.encode(), os.path.join(WORK, "cache").encode(), to_lua({"name": "acsm"}))
        check("live: reinstall over existing acsm.koplugin", ok is True and not os.path.exists(target + ".old"), s(err))

    # Libby account API host: an anonymous identity (no account) can sync.
    anon = Libby.newClient(lua.eval(b'{ get = function() return anon_id end, set = function(v) anon_id = v end }'))
    ok, err = two(anon.refreshChip, anon)
    data, err2 = two(anon.sync, anon) if ok else (None, err)
    check("live: Libby API host gives identity + sync", ok is True and data is not None
          and s(Libby.SENTRY) == "https://sentry.libbyapp.com", s(err2 or err))
    ok, err = two(anon.refreshChip, anon)
    info = Libby.tokenInfo(lua.globals().anon_id)
    check("live: app-style renewal gives a type-v token", ok is True and s(info[b"kind"]) == "v",
          s(Libby.describeToken(lua.globals().anon_id)))

    info, err = two(Libby.libraryInfo, b"nypl")
    check("live: library info", info is not None and b"New York" in info[b"name"], err)
    info, err = two(Libby.libraryInfo, b"notalibrary-zzz")
    check("live: bad library key", info is None, s(err))

print()
print("FAILED: " + ", ".join(failures) if failures else "ALL PASSED")
sys.exit(1 if failures else 0)
