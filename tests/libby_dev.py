"""
Run the plugin's real Libby code from this computer, against your own account,
without copying the plugin to the e-reader each time.

This computer is linked as a separate Libby device (with an 8-digit setup code),
so the e-reader's login is never copied. The token is stored, readable only by
you, in ~/.config/goodreadslibby-dev/ (outside the plugin folder, never zipped).
The log there hides tokens, keys and setup codes just like the plugin's log.

Read-only plus downloads: this script cannot borrow, return or place holds.

    python3 tests/libby_dev.py link        # type a Libby setup code when asked
    python3 tests/libby_dev.py status      # token, cards, loans (+ formats, locked)
    python3 tests/libby_dev.py download "Jumper"   # try the ACSM download for a loan
    python3 tests/libby_dev.py decode "Jumper"     # build an EPUB on-device (the fallback path)
    python3 tests/libby_dev.py forget      # delete the stored token
    python3 tests/libby_dev.py selftest    # anonymous login, no account involved

`decode` exercises the exact browser-free pipeline the plugin falls back to when
Libby refuses the ACSM download: open the loan for reading, decode the reader
page, fetch and decode each page + image, and assemble an EPUB. It's read-only
(no borrow/return) and writes the EPUB into the downloads folder below.
"""
import json
import os
import stat
import sys
import urllib.error
import urllib.request

import lupa
from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "goodreadslibby.koplugin")
HOME = os.path.join(os.path.expanduser("~"), ".config", "goodreadslibby-dev")
TOKEN_FILE = os.path.join(HOME, "identity.json")
LOG_FILE = os.path.join(HOME, "dev.log")
DOWNLOADS = os.path.join(HOME, "downloads")

lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def _to_lua(v):
    if isinstance(v, dict):
        return lua.table_from({k.encode(): _to_lua(x) for k, x in v.items() if x is not None})
    if isinstance(v, list):
        t = lua.table()
        for i, x in enumerate(v):
            t[i + 1] = _to_lua(x)
        return t
    if isinstance(v, str):
        return v.encode()
    return v


def _from_lua(v):
    if lupa.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys):
            return [_from_lua(v[i]) for i in sorted(keys)]
        return {(k.decode() if isinstance(k, bytes) else k): _from_lua(x) for k, x in v.items()}
    if isinstance(v, bytes):
        return v.decode("utf-8", "replace")
    return v


def _http(req):
    """socket.http.request stand-in (one hop; the plugin follows redirects)."""
    url = req[b"url"].decode()
    headers = {k.decode(): v.decode() for k, v in req[b"headers"].items()} if req[b"headers"] is not None else {}
    body = None
    if req[b"source"] is not None:
        parts = []
        while True:
            chunk = req[b"source"]()
            if chunk is None:
                break
            parts.append(chunk)
        body = b"".join(parts)
    r = urllib.request.Request(url, data=body, method=(req[b"method"] or b"GET").decode(), headers=headers)
    try:
        resp = _opener.open(r, timeout=60)
        code, hdrs, data = resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        code, hdrs, data = e.code, e.headers, e.read()
    except Exception as e:  # LuaSocket style: nil, error
        return None, str(e).encode()
    if req[b"sink"] is not None:
        req[b"sink"](data)
        req[b"sink"](None)
    return 1, code, lua.table_from({k.lower().encode(): v.encode() for k, v in hdrs.items()}), b"status"


g = lua.globals()
g.py_http = _http
g.py_json_decode = lambda s: _to_lua(json.loads(s.decode("utf-8")))
g.py_json_encode = lambda t: json.dumps(_from_lua(t)).encode()
g.PLUGIN = PLUGIN.encode()
lua.execute(b"""
package.path = PLUGIN .. "/?.lua;" .. package.path
local function mod(t) return function() return t end end
package.preload["socket.http"] = mod({ request = function(r) return py_http(r) end })
package.preload["socket"] = mod({ skip = function(n, ...) return select(n + 1, ...) end })
package.preload["ltn12"] = mod({
    source = { string = function(s) local done = false
        return function() if done then return nil end done = true return s end end },
    sink = { table = function(t) return function(c) if c then t[#t + 1] = c end return 1 end end },
})
package.preload["socketutil"] = mod({ set_timeout = function() end, reset_timeout = function() end })
package.preload["logger"] = mod({ info = function() end, warn = function() end, err = print, dbg = function() end })
package.preload["rapidjson"] = mod({ decode = function(s) return py_json_decode(s) end,
                                     encode = function(t) return py_json_encode(t) end })
""")
Libby = lua.eval(b'(require("grlibby/libby"))')
Log = lua.eval(b'(require("grlibby/log"))')
_two = lua.eval(b"function(f, ...) local r = table.pack(f(...)) return r[1], r[2], r[3] end")

# Drive the real on-device decode pipeline (open -> read host -> decode pages ->
# fetch assets -> assemble EPUB) against the live account, exactly as the plugin's
# "Build EPUB on device" fallback does. Read-only: it never borrows or returns.
_decode = lua.eval(b"""
function(client, want, outpath, note)
    local Lib = require("grlibby/libby")
    local Openbook = require("grlibby/openbook")
    local data, err = client:sync()
    if not data then return false, "sync failed: " .. tostring(err) end
    want = tostring(want):lower()
    local rawloan
    for _, ln in ipairs(data.loans or {}) do
        local title = tostring(ln.title or ""):lower()
        if tostring(ln.id) == want or title:find(want, 1, true) then rawloan = ln; break end
    end
    if not rawloan then return false, "no loan matches " .. want end
    local rawcard
    for _, c in ipairs(data.cards or {}) do
        if tostring(c.cardId) == tostring(rawloan.cardId) then rawcard = c; break end
    end
    if not rawcard then return false, "no card found for that loan" end
    local card = Lib.normalizeCard(rawcard)
    local loan = Lib.normalizeLoan(rawloan)
    note("open", 0, 0)
    local passport, oerr = client:open(card, loan)
    if not passport then return false, "open failed: " .. tostring(oerr) end
    local builder = Openbook.newBuilder(passport, outpath,
        { title = loan.title, author = loan.author, title_id = loan.id })
    local result = {}
    local function emit(m)
        if m.err then result.err = m.err end
        if m.done then result.done = m.done end
        if m.stage then note(m.stage, m.i or 0, m.n or 0) end
    end
    while builder:step(emit) do end
    if result.done then return true, result.done end
    return false, result.err or "decode failed"
end
""")


def _s(v):
    return v.decode("utf-8", "replace") if isinstance(v, bytes) else v


def _ensure_home():
    os.makedirs(HOME, exist_ok=True)
    os.chmod(HOME, stat.S_IRWXU)  # 700: only you


def _load_token():
    try:
        with open(TOKEN_FILE) as f:
            return json.load(f).get("identity")
    except (OSError, ValueError):
        return None


def _save_token(identity):
    _ensure_home()
    if identity is None:
        if os.path.exists(TOKEN_FILE):
            os.remove(TOKEN_FILE)
        return
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"identity": _s(identity)}, f)


def _client(memory_only=False):
    """A plugin Libby client whose token lives in TOKEN_FILE (or only in memory)."""
    _ensure_home()
    Log.setPath(LOG_FILE.encode())
    state = {"identity": None if memory_only else _load_token()}

    def get():
        return state["identity"].encode() if state["identity"] else None

    def put(identity):
        state["identity"] = _s(identity) if identity else None
        if not memory_only:
            _save_token(identity)

    store = lua.table_from({b"get": get, b"set": put})
    return Libby.newClient(store), state


def _describe(state):
    return _s(Libby.describeToken(state["identity"].encode() if state["identity"] else None))


def _status(client, state):
    data, err, _ = _two(client.sync, client)
    print("Token:", _describe(state))
    if data is None:
        print("Sync failed:", _s(err))
        return None
    data = _from_lua(data)
    cards = data.get("cards") or []
    loans = data.get("loans") or []
    print("Cards (%d):" % len(cards))
    for c in cards:
        lib = c.get("library") or {}
        print("  - %s (%s) card %s" % (lib.get("name") or c.get("cardName"), c.get("advantageKey"), c.get("cardId")))
    print("Loans (%d):" % len(loans))
    for ln in loans:
        fm = ln.get("formats") or []
        ids = [f.get("id") + (" [locked]" if f.get("isLockedIn") else "") for f in fm if isinstance(f, dict)]
        print("  - %s | loan %s on card %s | due %s | %s" % (ln.get("title"), ln.get("id"), ln.get("cardId"),
                                                         (ln.get("expireDate") or "?")[:10], ", ".join(ids)))
    return data


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    if cmd == "link":
        code = input("Libby setup code (Libby → Menu → Copy To Another Device), 8 digits: ").strip()
        client, state = _client()
        _save_token(None)
        state["identity"] = None
        data, err, _ = _two(client.cloneByCode, client, code.encode())
        if data is None:
            print("Couldn't link:", _s(err))
            return 1
        print("Linked. Token:", _describe(state))
        print("Cards:", len(_from_lua(data).get("cards") or []))
        return 0
    if cmd == "forget":
        _save_token(None)
        print("Deleted", TOKEN_FILE)
        return 0
    if cmd == "selftest":
        client, state = _client(memory_only=True)
        ok, err, _ = _two(client.refreshChip, client)
        print("anonymous chip:", "ok" if ok else _s(err))
        ok, err, _ = _two(client.refreshChip, client)
        print("app-style renewal:", "ok" if ok else _s(err))
        _status(client, state)
        return 0
    client, state = _client()
    if not state["identity"]:
        print("Not linked yet: run  python3 tests/libby_dev.py link")
        return 1
    if cmd == "status":
        return 0 if _status(client, state) is not None else 1
    if cmd == "download":
        want = (argv[2] if len(argv) > 2 else "").lower()
        data = _status(client, state)
        if data is None:
            return 1
        loans = [ln for ln in data.get("loans") or [] if want in (ln.get("title") or "").lower() or want == str(ln.get("id"))]
        if not loans:
            print("No loan matches", repr(want))
            return 1
        ln = loans[0]
        fmt = argv[3] if len(argv) > 3 else "ebook-epub-adobe"
        print("\nDownloading %s for “%s”…" % (fmt, ln.get("title")))
        body, err, why = _two(client.fulfill, client, str(ln.get("cardId")).encode(), str(ln.get("id")).encode(), fmt.encode())
        print("Token now:", _describe(state))
        if body is None:
            print("FAILED:", _s(err), "(%s)" % _s(why) if why else "")
            print("Details:", LOG_FILE)
            return 1
        os.makedirs(DOWNLOADS, exist_ok=True)
        out = os.path.join(DOWNLOADS, "%s.%s" % (ln.get("id"), "acsm" if "adobe" in fmt else "epub"))
        with open(out, "wb") as f:
            f.write(body)
        print("OK: %d bytes saved to %s" % (len(body), out))
        return 0
    if cmd == "decode":
        want = (argv[2] if len(argv) > 2 else "")
        if not want:
            print('Usage: decode "<title or loan id>"')
            return 1
        os.makedirs(DOWNLOADS, exist_ok=True)
        out = os.path.join(DOWNLOADS, "decoded-%s.epub" % want.replace("/", "_")[:40])
        last = [None]

        def note(stage, i, n):
            s = _s(stage)
            msg = s if not n else "%s %d/%d" % (s, int(i), int(n))
            if msg != last[0]:
                last[0] = msg
                print("  " + msg)

        print('Decoding “%s” into an EPUB (open -> read host -> pages -> assets)…' % want)
        ok, res = _decode(client, want.encode(), out.encode(), note)
        print("Token now:", _describe(state))
        if ok:
            size = os.path.getsize(res) if os.path.exists(res) else 0
            print("OK: %d bytes -> %s" % (size, _s(res)))
            return 0
        print("FAILED:", _s(res))
        print("Details:", LOG_FILE)
        return 1
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
