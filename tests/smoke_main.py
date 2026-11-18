"""
Smoke-test main.lua against stubbed KOReader widgets (no device needed).

Covers: shelves (open without checking, load, sort, switch, manage, others'
shelves, auto-refresh), tap-to-check, precheck with an instant Stop (both with
a background process and the in-process fallback), the book dialog (pinned
controls, most copies first), borrow + ACSM hand-off, goodreads.txt, the ACSM
plugin installer, and that every dialog has a way out.

    python3 tests/smoke_main.py
"""
import json
import os
import shutil
import sys
import tempfile

import lupa
from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "goodreadslibby.koplugin")
TMP = tempfile.mkdtemp()
PLUGDIR = os.path.join(TMP, "plugins", "goodreadslibby.koplugin")
shutil.copytree(PLUGIN, PLUGDIR)
# Tests start from the shipped template, not whatever goodreads.txt holds now.
shutil.copy(os.path.join(ROOT, "tests", "fixtures", "goodreads.sample.txt"), os.path.join(PLUGDIR, "goodreads.txt"))

lua = LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
g.PLUGIN = PLUGIN
g.PLUGDIR = PLUGDIR
g.TMP = TMP


def to_lua(v):
    if isinstance(v, dict):
        return lua.table_from({k: to_lua(x) for k, x in v.items() if x is not None})
    if isinstance(v, list):
        t = lua.table()
        for i, x in enumerate(v):
            t[i + 1] = to_lua(x)
        return t
    return v


def from_lua(v):
    if lupa.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys):
            return [from_lua(v[i]) for i in sorted(keys)]
        return {k: from_lua(x) for k, x in v.items()}
    return v


def lfs_attributes(path, what=None):
    if not os.path.exists(path):
        return None
    info = {"mode": "directory" if os.path.isdir(path) else "file", "size": os.path.getsize(path)}
    if what is not None:
        return info[what]
    return lua.table_from(info)


g.py_json_encode = lambda t: json.dumps(from_lua(t))
g.py_json_decode = lambda s: to_lua(json.loads(s))
g.py_lfs_attributes = lfs_attributes
g.py_listdir = lambda p: lua.table_from([".", ".."] + (os.listdir(p) if os.path.isdir(p) else []))
g.py_mkdir = lambda p: os.makedirs(p, exist_ok=True) or True
g.py_rmdir = lambda p: os.rmdir(p) or True

lua.execute(r"""
package.path = PLUGIN .. "/?.lua;" .. package.path
shown, closed, problems, tasks = {}, {}, {}, {}
local function widget(kind)
    local W = {}
    W.__index = W
    function W:extend(t) t = t or {}; t.__index = t; return setmetatable(t, { __index = self }) end
    function W:new(o) o = o or {}; o._kind = kind; return setmetatable(o, { __index = self }) end
    function W:onShowKeyboard() end
    function W:getInputText() return self._answer or "" end
    function W:switchItemTable(title, items) if title then self.title = title end; self.item_table = items end
    function W:setTitle(t) self.title = t end
    function W:addWidget(w) self._added = self._added or {}; self._added[#self._added + 1] = w end
    function W:getAddedWidgetAvailableWidth() return 500 end
    return W
end

-- Fake fork: runs the child function in a coroutine we can advance step by step.
fork = { mode = "sync", killed = false, co = nil, started = 0, terminated = 0 }
function advance_child(n)
    for _ = 1, n do
        if fork.co and coroutine.status(fork.co) == "suspended" and not fork.killed then
            local ok, err = coroutine.resume(fork.co)
            if not ok then print("child error", err) end
        end
    end
end
local ffiutil = {
    template = function(s, ...)
        local a = { ... }
        return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
    end,
    runInSubProcess = function(func)
        if fork.mode == "fail" then return false, "fork failed" end
        fork.started = fork.started + 1
        fork.killed = false
        fork.co = coroutine.create(func)
        local ok, err = coroutine.resume(fork.co)
        if not ok then print("child error", err) end
        return 4242
    end,
    isSubProcessDone = function() return fork.killed or not fork.co or coroutine.status(fork.co) == "dead" end,
    terminateSubProcess = function() fork.killed = true; fork.terminated = fork.terminated + 1 end,
}
function run_tasks(n)
    for _ = 1, n do
        local t = table.remove(tasks, 1)
        if not t then return end
        t()
    end
end
online = true
local stubs = {
    ["ui/widget/buttondialog"] = widget("ButtonDialog"),
    ["ui/widget/buttontable"] = widget("ButtonTable"),
    ["ui/widget/confirmbox"] = widget("ConfirmBox"),
    ["ui/widget/infomessage"] = widget("InfoMessage"),
    ["ui/widget/inputdialog"] = widget("InputDialog"),
    ["ui/widget/menu"] = widget("Menu"),
    ["ui/widget/pathchooser"] = widget("PathChooser"),
    ["ui/widget/container/widgetcontainer"] = widget("WidgetContainer"),
    ["datastorage"] = { getSettingsDir = function() return TMP end, getDataDir = function() return TMP end },
    ["luasettings"] = { open = function(_, path)
        local data = {}
        return { readSetting = function(_, k) return data[k] end,
                 saveSetting = function(_, k, v) data[k] = v end,
                 delSetting = function(_, k) data[k] = nil end,
                 flush = function() end }
    end },
    ["ui/network/manager"] = { runWhenOnline = function(_, fn) fn() end, isOnline = function() return online end },
    ["ui/trapper"] = { wrap = function(_, fn) fn() end, info = function() return true end, clear = function() end },
    ["ui/uimanager"] = {
        show = function(_, w) shown[#shown + 1] = w end,
        close = function(_, w) closed[w] = true end,
        scheduleIn = function(_, s, fn) tasks[#tasks + 1] = fn end,
        unschedule = function(_, fn)
            for i = #tasks, 1, -1 do if tasks[i] == fn then table.remove(tasks, i) end end
        end,
    },
    ["libs/libkoreader-lfs"] = {
        attributes = function(p, m) return py_lfs_attributes(p, m) end,
        mkdir = function(p) return py_mkdir(p) end,
        rmdir = function(p) return py_rmdir(p) end,
        dir = function(p) local n, i = py_listdir(p), 0 return function() i = i + 1 return n[i] end end,
    },
    ["logger"] = { info = function() end, warn = function() end, err = print, dbg = function() end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = ffiutil,
    ["socket.http"] = { request = function() return nil, "offline" end },
    ["socket"] = { skip = function(n, ...) return select(n + 1, ...) end },
    ["ltn12"] = { source = { string = function() end }, sink = { table = function() end } },
    ["socketutil"] = { set_timeout = function() end, reset_timeout = function() end },
    ["rapidjson"] = { decode = function(s) return py_json_decode(s) end, encode = function(t) return py_json_encode(t) end },
}
for name, mod in pairs(stubs) do package.preload[name] = function() return mod end end
G_reader_settings = { readSetting = function() return TMP end }

function check_exit(w)
    local function has(rows, texts)
        for _, row in ipairs(rows or {}) do
            for _, b in ipairs(row) do
                for _, t in ipairs(texts) do if b.text == t then return true end end
            end
        end
        return false
    end
    local exits = { "Close", "Cancel", "Stop", "Back" }
    local ok = has(w.buttons, exits)
    for _, a in ipairs(w._added or {}) do ok = ok or has(a.buttons, exits) end
    if w._kind == "InputDialog" and not has(w.buttons, { "Cancel" }) then
        problems[#problems + 1] = "InputDialog without Cancel: " .. tostring(w.title)
    elseif w._kind == "ButtonDialog" and not ok then
        problems[#problems + 1] = "ButtonDialog without Close/Stop: " .. tostring(w.title)
    elseif w._kind == "Menu" and not w.close_callback then
        problems[#problems + 1] = "Menu without close: " .. tostring(w.title)
    end
end

function find_button(w, prefix)
    local function scan(rows)
        for _, row in ipairs(rows or {}) do
            for _, b in ipairs(row) do
                if b.text and b.text:sub(1, #prefix) == prefix then return b end
            end
        end
    end
    local b = scan(w.buttons)
    if b then return b end
    for _, a in ipairs(w._added or {}) do
        b = scan(a.buttons)
        if b then return b end
    end
end

function last(kind)
    for i = #shown, 1, -1 do if not kind or shown[i]._kind == kind then return shown[i] end end
end

function file_exists(p) local f = io.open(p) if f then f:close() return true end return false end

function texts(menu)
    local out = {}
    for _, it in ipairs(menu.item_table) do out[#out + 1] = it.book and it.book.id or it.text end
    return table.concat(out, ",")
end
""")

failures = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" -- " + str(detail)) if detail else ""))
    if not cond:
        failures.append(name)


lua.execute(r"""
R = {}
local Plugin = (require("main"))
local GR = package.loaded["grlibby/goodreads"]
ui = { menu = { registerToMainMenu = function() end } }
p = Plugin:new{ ui = ui, path = PLUGDIR }
p:init()

-- Libby lookups are faked; count every one.
lookups = 0
yield_in_lookup = false
FAKE = {
    nypl = { status = "available", id = "t1", title = "X", available = 3, owned = 9, formats = { "ebook-epub-adobe" }, acsm = true },
    lapl = { status = "available", id = "t1", title = "X", available = 7, owned = 10, formats = { "ebook-epub-adobe" }, acsm = true },
    bpl = { status = "hold", id = "t1", title = "X", holds = 4, owned = 2, wait_days = 12, holdable = true, formats = { "ebook-epub-adobe" }, acsm = true },
}
p.lookupBook = function(self, book, lib)
    lookups = lookups + 1
    if yield_in_lookup then coroutine.yield() end
    local rec = {}
    for k, v in pairs(FAKE[lib.key] or { status = "none" }) do rec[k] = v end
    rec.at = os.time()
    return rec
end

-- Menus.
local mi = {}
p:addToMainMenu(mi)
local top = mi.goodreads_libby.sub_item_table_func()
local labels = {}
for _, it in ipairs(top) do labels[#labels + 1] = it.text or it.text_func() end
R.labels = table.concat(labels, "; ")
local settings_labels = {}
for _, it in ipairs(top[#top].sub_item_table) do
    settings_labels[#settings_labels + 1] = it.text or it.text_func()
end
R.settings = table.concat(settings_labels, "\n")
R.sample_no_account = p:account() == nil
p:editAccount(); p:linkLibby(); p:editExtraLibraries()

-- Account + Libby cards.
local f = io.open(PLUGDIR .. "/goodreads.txt", "w"); f:write("# my account\n1\n"); f:close()
p:set("libby_identity", "tok")
p:set("libby_cards", {
    { card_id = "11", key = "nypl", library_name = "NYPL", periods = { ebook = { days = 14 } } },
    { card_id = "22", key = "lapl", library_name = "LAPL", periods = {} },
    { card_id = "33", key = "bpl", library_name = "BPL", periods = {} },
})

-- Goodreads: 150 books over two pages.
fetches = 0
GR.fetchPage = function(acc, shelf, page)
    fetches = fetches + 1
    local books = {}
    local n = page == 1 and 100 or (page == 2 and 50 or 0)
    for i = 1, n do
        local id = (page - 1) * 100 + i
        books[#books + 1] = { id = "g" .. id, title = "Book " .. id, author = "Author " .. id }
    end
    return { books = books, owner = acc.id == "555" and "Otis" or nil }
end

-- 1) First open (nothing saved): loads from Goodreads, checks NOTHING.
local want = p:shelfList()[1]
p:openShelf(want)
R.load_dialog = last("ButtonDialog").title
run_tasks(10)
R.loaded_count = #p.current_shelf.books
R.lookups_after_open = lookups
R.fetches_first = fetches
R.shelf_title = p.shelf_menu.title
R.unchecked_label = tostring(p.shelf_menu.item_table[1].mandatory)

-- 2) Reopen: saved copy, no fetch, no checks.
p:closeAll()
p:openShelf(want)
run_tasks(10)
R.fetches_reopen = fetches
R.lookups_reopen = lookups

-- 3) Auto-refresh: refetch when online, use saved copy offline.
p:set("auto_refresh_shelf", true)
p:openShelf(want); run_tasks(10)
R.fetches_auto_online = fetches
online = false
p:openShelf(want); run_tasks(10)
R.fetches_auto_offline = fetches
online = true
p:set("auto_refresh_shelf", false)

-- 4) Sorting.
local books4 = {
    { id = "b1", title = "Educated: A Memoir", author = "Tara Westover", rating = 4.47 },
    { id = "b2", title = "Project Hail Mary", author = "Andy Weir", rating = 4.5 },
    { id = "b3", title = "The Unknown Book", author = "Nobody Zed", rating = 3.0 },
    { id = "b4", title = "Anonymous Diary", rating = 3.9 },
}
p:showShelf(want, books4, true)
R.sorts = {}
for _, id in ipairs({ "shelf", "shelf_rev", "title", "title_rev", "author_first", "author_last", "rating" }) do
    p:set("sort_order", id)
    p:refreshShelfMenu()
    R.sorts[id] = texts(p.shelf_menu)
end
p:set("sort_order", "shelf")
p:refreshShelfMenu()

-- Shelf options: no filters; refresh/shelf/sort/precheck present.
p:shelfOptions()
local opt = last("ButtonDialog")
local opt_texts = {}
for _, row in ipairs(opt.buttons) do for _, b in ipairs(row) do opt_texts[#opt_texts + 1] = b.text end end
R.options = table.concat(opt_texts, " | ")
find_button(opt, "Sort:").callback()
R.sort_picker = last("ButtonDialog").buttons[1][1].text
find_button(last("ButtonDialog"), "Close").callback()
find_button(opt, "Shelf:").callback()
local picker = last("ButtonDialog")
R.shelf_picker = picker.buttons[1][1].text .. " / " .. picker.buttons[2][1].text
picker.buttons[2][1].callback() -- view "Currently Reading"
run_tasks(10)
R.switched_title = p.shelf_menu.title
p:showShelf(want, books4, true)

-- 5) Tap a book: only that book is checked; dialog pins its controls.
lookups = 0
p:showBook(books4[2])
R.tap_progress = last("ButtonDialog").title
run_tasks(5)
R.tap_lookups = lookups
local bd = last("ButtonDialog")
R.book_rows = {}
for _, row in ipairs(bd.buttons) do R.book_rows[#R.book_rows + 1] = row[1].text end
R.book_rows = table.concat(R.book_rows, " | ")
R.pinned = bd._added and bd._added[1].buttons[1][1].text .. "," .. bd._added[1].buttons[1][2].text
    .. (bd._added[1].buttons[1][3] and ("," .. bd._added[1].buttons[1][3].text) or "")
R.list_label = p.shelf_menu.item_table[2].mandatory
-- Tapping again within the refresh window: no new lookups.
lookups = 0
p:showBook(books4[2])
R.tap_again_lookups = lookups

-- 6) Precheck with a background process: Stop kills it at once, keeps results.
p.cache:saveSetting("avail", {})
fork.mode = "partial"
yield_in_lookup = true
lookups = 0
p:shelfOptions()
find_button(last("ButtonDialog"), "Precheck").callback()
local warn = last("ConfirmBox")
R.warn_text = warn.text
warn.ok_callback()
local progress = last("ButtonDialog")
advance_child(4)        -- four library searches finish in the background
run_tasks(3)            -- UI polls the results
R.progress_title = progress.title
local saved = 0
for _, libs in pairs(p.cache:readSetting("avail") or {}) do for _ in pairs(libs) do saved = saved + 1 end end
R.saved_before_stop = saved
local started_lookups = lookups
find_button(progress, "Stop").callback()
R.stop_closed = closed[progress] == true
R.terminated = fork.terminated
advance_child(5)        -- a killed process does nothing more
run_tasks(10)
R.lookups_after_stop = lookups - started_lookups
R.stop_msg = last("InfoMessage").text
saved = 0
for _, libs in pairs(p.cache:readSetting("avail") or {}) do for _ in pairs(libs) do saved = saved + 1 end end
R.saved_after_stop = saved

-- 7) No background process available: one search per UI tick, Stop between.
p.cache:saveSetting("avail", {})
fork.mode = "fail"
yield_in_lookup = false
lookups = 0
p:shelfOptions()
find_button(last("ButtonDialog"), "Precheck").callback()
last("ConfirmBox").ok_callback()
local progress2 = last("ButtonDialog")
run_tasks(3)
R.fallback_lookups = lookups
find_button(progress2, "Stop").callback()
run_tasks(10)
R.fallback_after_stop = lookups
fork.mode = "sync"

-- 8) Full precheck runs to the end.
p.cache:saveSetting("avail", {})
lookups = 0
p:shelfOptions()
find_button(last("ButtonDialog"), "Precheck").callback()
last("ConfirmBox").ok_callback()
run_tasks(10)
R.full_lookups = lookups
R.full_msg = last("InfoMessage").text

-- 9) Borrow (most copies first) + ACSM without the ACSM plugin.
p.libby.borrow = function(_, card, title_id) R.borrowed = card.card_id .. "/" .. title_id; return {} end
p.libby.fulfill = function(_, card_id, title_id, fmt) R.fulfilled = fmt; return "<fulfillmentToken>x</fulfillmentToken>" end
p:showBook(books4[1])
local b1 = last("ButtonDialog")
R.first_row = b1.buttons[1][1].text
find_button(b1, "Borrow · NYPL").callback()
last("ConfirmBox").ok_callback()
R.acsm_path = TMP .. "/Libby/Educated - Tara Westover.acsm"
R.acsm_saved = file_exists(R.acsm_path)
R.install_offer = last("ConfirmBox").text:find("Install the ACSM plugin", 1, true) ~= nil

-- ACSM plugin present: EPUB made, .acsm deleted.
ui.acsm = {
    loadSettings = function() end,
    parseAcsmMetadata = function() return { title = "Educated" } end,
    deriveOutputPath = function() return TMP .. "/Libby/Educated.epub" end,
    fulfillLoan = function(self, path)
        local fo = io.open(TMP .. "/Libby/Educated.epub", "wb"); fo:write("PK\3\4epub"); fo:close()
        return { outputPath = TMP .. "/Libby/Educated.epub" }
    end,
}
p:showBook(books4[1])
find_button(last("ButtonDialog"), "Download · NYPL").callback()
R.epub_made = file_exists(TMP .. "/Libby/Educated.epub")
R.acsm_deleted = not file_exists(R.acsm_path)
ui.acsm = nil

-- 10) 15 libraries: controls stay pinned, library rows scroll beneath.
local many = {}
for i = 1, 15 do many[#many + 1] = { card_id = tostring(100 + i), key = "lib" .. i, library_name = "Library " .. i, periods = {} } end
local saved_cards = p:get("libby_cards")
p:set("libby_cards", many)
p:showBook(books4[3])
run_tasks(5)
local bm = last("ButtonDialog")
R.many_rows = #bm.buttons
R.many_pinned = bm._added ~= nil and find_button({ buttons = bm._added[1].buttons }, "Check again") ~= nil
p:set("libby_cards", saved_cards)

-- 11) Manage shelves: rename, reorder, remove, add presets and others' shelves.
p:manageShelves()
local sm = p.shelves_menu
R.manage_items = texts(sm)
sm.onMenuSelect(sm, sm.item_table[2])                 -- "Want to Read"
local acts = last("ButtonDialog")
find_button(acts, "Rename").callback()
local rn = last("InputDialog")
R.rename_has_cancel = find_button(rn, "Cancel") ~= nil
rn._answer = "My TBR pile"
find_button(rn, "Save").callback()
R.after_rename = texts(p.shelves_menu)
sm.onMenuSelect(sm, sm.item_table[2])
find_button(last("ButtonDialog"), "Move down").callback()
R.after_move = texts(p.shelves_menu)
sm.onMenuSelect(sm, sm.item_table[4])                 -- "Read"
find_button(last("ButtonDialog"), "Remove").callback()
last("ConfirmBox").ok_callback()
R.after_remove = texts(p.shelves_menu)
sm.onMenuSelect(sm, sm.item_table[1])                 -- "+ Add a shelf…"
find_button(last("ButtonDialog"), "All my books").callback()
sm.onMenuSelect(sm, sm.item_table[1])
find_button(last("ButtonDialog"), "Someone else").callback()
local who = last("InputDialog")
who._answer = "https://www.goodreads.com/user/show/555-otis"
find_button(who, "Next").callback()
local which = last("InputDialog")
which._answer = "read"
find_button(which, "Add").callback()
run_tasks(5)
R.after_add = texts(p.shelves_menu)
local list = p:shelfList()
R.other_user = list[#list].user and list[#list].user.id .. ":" .. list[#list].shelf
R.main_menu_after = {}
for _, it in ipairs(mi.goodreads_libby.sub_item_table_func()) do R.main_menu_after[#R.main_menu_after + 1] = it.text end
R.main_menu_after = table.concat(R.main_menu_after, "; ")
p:closeAll()
R.closed_all = p.shelf_menu == nil and p.shelves_menu == nil

-- On-device shelf edits were saved into goodreads.txt.
local fh = io.open(PLUGDIR .. "/goodreads.txt"); R.file_after_manage = fh:read("*a"); fh:close()

-- 12) goodreads.txt with several "nickname = RSS link" lines (+ one bad line).
local fw = io.open(PLUGDIR .. "/goodreads.txt", "w")
fw:write([[# shelves
profile = https://www.goodreads.com/user/show/777-me
user id =
TBR = https://www.goodreads.com/review/list_rss/777?key=K1&shelf=to-read
Now = https://www.goodreads.com/review/list_rss/777?key=K1&shelf=currently-reading
Club = book-club
Otis TBR = https://www.goodreads.com/review/list_rss/1?shelf=to-read
Oops = not a link
]])
fw:close()
local menu12 = {}
for _, it in ipairs(mi.goodreads_libby.sub_item_table_func()) do menu12[#menu12 + 1] = it.text end
R.menu_from_file = table.concat(menu12, "; ")
local l12 = p:shelfList()
R.file_shelves = #l12
R.file_account = p:account().id .. ":" .. tostring(p:account().key)
R.otis_user = l12[4].user and l12[4].user.id
R.club_key = p:shelfKey(l12[3])
p:showConfigProblems()
R.problems_msg = last("InfoMessage").text
-- Opening a file shelf uses its own link.
fetched_with = nil
GR.fetchPage = function(acc, shelf, page)
    fetched_with = acc.id .. ":" .. tostring(acc.key) .. ":" .. shelf
    return { books = {} }
end
p:openShelf(l12[4]); run_tasks(5)
R.otis_fetch = fetched_with
p:openShelf(l12[1]); run_tasks(5)
R.tbr_fetch = fetched_with
-- Rename on the device: written back, other lines untouched.
p:manageShelves()
local sm2 = p.shelves_menu
sm2.onMenuSelect(sm2, sm2.item_table[2])
find_button(last("ButtonDialog"), "Rename").callback()
local rn2 = last("InputDialog"); rn2._answer = "To read"; find_button(rn2, "Save").callback()
local fh2 = io.open(PLUGDIR .. "/goodreads.txt"); R.file_after_rename = fh2:read("*a"); fh2:close()
p:closeAll()

-- 13) Troubleshooting menu.
local ts = {}
for _, it in ipairs(p:troubleshootingMenu()) do ts[#ts + 1] = it.text or it.text_func() end
R.troubleshooting = table.concat(ts, " | ")

-- 14) Settings from inside the shelf list.
p:showShelf(want, books4, true)
p:shelfOptions()
find_button(last("ButtonDialog"), "Settings").callback()
local sd = last("ButtonDialog")
R.settings_title = sd.title
R.settings_close_pinned = sd._added ~= nil and sd._added[1].buttons[1][1].text == "Close"
local pref = find_button(sd, "✓ Prefer DRM-free EPUB")
pref.callback()
R.pref_toggled = find_button(last("ButtonDialog"), "    Prefer DRM-free EPUB") ~= nil and p:get("prefer_open_epub") == false
find_button(last("ButtonDialog"), "Recheck availability after").callback()
local ttl = last("ButtonDialog")
R.ttl_back = ttl._added and ttl._added[1].buttons[1][1].text
find_button(ttl, "    Never").callback()
R.never_checked = find_button(last("ButtonDialog"), "✓ Never") ~= nil
R.never_ttl = p:availTTL() == math.huge
p.cache:saveSetting("avail", { b1 = { nypl = { status = "none", at = 1 } } })
R.never_no_recheck = not p:needsCheck(books4[1], { key = "nypl" })
p:set("avail_ttl", nil)
p:closeAll()

-- 15) Book folder: the EPUB from the ACSM plugin is moved there; .acsm deleted.
p:set("book_dir", TMP .. "/Books")
ui.acsm = {
    loadSettings = function() end,
    parseAcsmMetadata = function() return { title = "Educated" } end,
    deriveOutputPath = function() return TMP .. "/Libby/Educated.epub" end,
    fulfillLoan = function(self, path)
        local fo = io.open(TMP .. "/Libby/Educated.epub", "wb"); fo:write("PK\3\4epub"); fo:close()
        return { outputPath = TMP .. "/Libby/Educated.epub" }
    end,
}
os.remove(TMP .. "/Books/Educated.epub")
p:downloadLoan("11", "t1", { "ebook-epub-adobe" }, { title = "Educated", author = "Tara Westover" })
R.moved = file_exists(TMP .. "/Books/Educated.epub") and not file_exists(TMP .. "/Libby/Educated.epub")
R.acsm_gone = not file_exists(TMP .. "/Libby/Educated - Tara Westover.acsm")
R.ready_text = last("ConfirmBox").text

-- 16) My Libby loans: download indicator, open / return / return + delete, locked loans.
p.libby.sync = function()
    return { cards = {}, holds = {}, loans = {
        { id = "t1", cardId = "11", title = "Educated", firstCreatorName = "Tara Westover", type = { id = "ebook" },
          formats = { { id = "ebook-epub-adobe" } }, expireDate = "2026-10-15T12:00:00Z" },
        { id = "t9", cardId = "11", title = "Kindle Book", type = { id = "ebook" },
          formats = { { id = "ebook-kindle", isLockedIn = true }, { id = "ebook-epub-adobe" } }, expireDate = "2026-10-20T12:00:00Z" },
    } }
end
p:showLoans()
local lm = p.loans_menu
R.loan_rows = lm.item_table[1].mandatory .. " | " .. lm.item_table[2].mandatory
R.loans_settings_icon = lm.title_bar_left_icon
lm.onMenuSelect(lm, lm.item_table[1])
local la = last("ButtonDialog")
local la_texts = {}
for _, row in ipairs(la.buttons) do la_texts[#la_texts + 1] = row[1].text end
R.loan_buttons = table.concat(la_texts, " | ")
R.loan_title = la.title
lm.onMenuSelect(lm, lm.item_table[2])
local lk = last("ButtonDialog")
R.locked_title = lk.title
R.locked_has_download = find_button(lk, "Download") ~= nil
p.libby.returnLoan = function(_, card_id, title_id) R.returned = card_id .. "/" .. title_id; return true end
lm.onMenuSelect(lm, lm.item_table[1])
find_button(last("ButtonDialog"), "Return and delete").callback()
last("ConfirmBox").ok_callback()
R.returned_file_gone = not file_exists(TMP .. "/Books/Educated.epub")
R.loans_after_return = #lm.item_table .. ":" .. lm.item_table[1].text
p:closeAll()
p:set("book_dir", nil)
ui.acsm = nil

-- 17) [optional] placeholders in goodreads.txt are fine.
local fp = io.open(PLUGDIR .. "/goodreads.txt", "w")
fp:write("profile = [optional]\nuser id = [optional]\nMine = https://www.goodreads.com/review/list_rss/150?key=K&shelf=to-read\n")
fp:close()
local cfg17 = package.loaded["grlibby/goodreads"].parseConfig(io.open(PLUGDIR .. "/goodreads.txt"):read("*a"))
R.placeholder_errors = #cfg17.errors
R.placeholder_account = cfg17.account and cfg17.account.id

-- 18) Libby refuses the ACSM download: fall back to building the EPUB on device.
-- Here open() is stubbed to fail, so the fallback itself falls back to the app
-- route; the next borrow must NOT call the refused download again.
p:set("download_refused_at", nil)
local saved_cards18 = p:get("libby_cards")
p:set("libby_cards", { { card_id = "11", key = "nypl", website_id = "1", library_name = "NYPL", periods = {} } })
fulfill_calls = 0
p.libby.fulfill = function() fulfill_calls = fulfill_calls + 1; return nil, "missing_chip (HTTP 403 from sentry.libbyapp.com)", "blocked" end
p.libby.borrow = function() return {} end
p.libby.open = function() return nil, "offline" end
p:showShelf(want, books4, true)
p:borrow(books4[1], { key = "nypl", name = "NYPL", card = { card_id = "11", periods = {} } },
    { id = "t1", title = "Educated", formats = { "ebook-epub-adobe" }, acsm = true })
last("ConfirmBox").ok_callback()
local help = last("ButtonDialog")
R.help_text = help.title
R.help_buttons = help.buttons[1][1].text .. " | " .. help.buttons[2][1].text
R.blocked_flag = p:get("download_refused_at") ~= nil
p:borrow(books4[2], { key = "nypl", name = "NYPL", card = { card_id = "11", periods = {} } },
    { id = "t2", title = "Project Hail Mary", formats = { "ebook-epub-adobe" }, acsm = true })
last("ConfirmBox").ok_callback()
R.fulfill_calls = fulfill_calls
R.second_help = last("ButtonDialog").title:find("Manage Loan", 1, true) ~= nil
p:set("libby_cards", saved_cards18)

-- Library refuses the card.
p.libby.borrow = function() return nil, "Invalid Library Card: .p3. Not a valid Auckland City Libraries card.", "PatronCardFailedAuthentication" end
p:borrow(books4[1], { key = "auckland", name = "Auckland", card = { card_id = "5", periods = {} } },
    { id = "t1", title = "Educated", formats = { "ebook-epub-adobe" }, acsm = true })
last("ConfirmBox").ok_callback()
R.card_msg = last("InfoMessage").text

-- 19) Convert .acsm files copied from the Libby app.
os.execute("mkdir -p '" .. TMP .. "/Libby'")
for _, n in ipairs({ "Educated.acsm", "Other.acsm" }) do
    local fa = io.open(TMP .. "/Libby/" .. n, "w"); fa:write("<fulfillmentToken/>"); fa:close()
end
p:set("book_dir", TMP .. "/Books2")
ui.acsm = {
    loadSettings = function() end,
    parseAcsmMetadata = function(_, path) return { title = path:find("Educated") and "Educated" or "Other Book" } end,
    deriveOutputPath = function(_, path) return (path:gsub("%.acsm$", ".epub")) end,
    fulfillLoan = function(self, path)
        local out = path:gsub("%.acsm$", ".epub")
        local fo = io.open(out, "wb"); fo:write("PK\3\4epub"); fo:close()
        return { outputPath = out }
    end,
}
local mi19 = mi.goodreads_libby.sub_item_table_func()
for _, it in ipairs(mi19) do if it.text_func then R.convert_label = it.text_func() end end
p._loans = { { id = "t1", card_id = "11", title = "Educated: A Memoir", type = "ebook", formats = { "ebook-epub-adobe" } } }
p:convertAcsmFolder()
R.convert_msg = last("InfoMessage").text
R.converted = file_exists(TMP .. "/Books2/Educated.epub") and file_exists(TMP .. "/Books2/Other.epub")
R.acsm_cleared = not file_exists(TMP .. "/Libby/Educated.acsm") and not file_exists(TMP .. "/Libby/Other.acsm")
R.loan_marked = p:downloadFor("11", "t1") ~= nil
ui.acsm = nil
p:set("book_dir", nil)

for _, w in ipairs(shown) do check_exit(w) end
""")

R = lua.eval("R")
r = {k: R[k] for k in R}
sorts = {k: v for k, v in r["sorts"].items()}
print("menu:", r["labels"])
print("settings:\n  " + r["settings"].replace("\n", "\n  "))
print("shelf options:", r["options"])

check("default shelves in main menu", r["labels"].startswith("Want to Read; Currently Reading; Read; Manage shelves"), r["labels"])
check("settings has Manage shelves + auto-refresh", "Manage shelves" in r["settings"]
      and "Auto-refresh shelves when opening" in r["settings"], r["settings"])
check("sample goodreads.txt means no account yet", r["sample_no_account"] is True)
check("first open loads all pages", r["loaded_count"] == 150 and r["fetches_first"] == 2, (r["loaded_count"], r["fetches_first"]))
check("loading shows a Stop dialog", "Loading" in r["load_dialog"], r["load_dialog"])
check("opening a shelf checks NO availability", r["lookups_after_open"] == 0, r["lookups_after_open"])
check("unchecked books show no status", r["unchecked_label"] == "nil", r["unchecked_label"])
check("shelf title shows nickname + count", r["shelf_title"] == "Want to Read · 150 books", r["shelf_title"])
check("reopen uses saved copy (no fetch, no checks)", r["fetches_reopen"] == 2 and r["lookups_reopen"] == 0)
check("auto-refresh refetches when online", r["fetches_auto_online"] == 4, r["fetches_auto_online"])
check("auto-refresh offline uses saved copy", r["fetches_auto_offline"] == 4, r["fetches_auto_offline"])
check("sort: shelf order (default)", sorts["shelf"] == "b1,b2,b3,b4", sorts["shelf"])
check("sort: reverse shelf order", sorts["shelf_rev"] == "b4,b3,b2,b1", sorts["shelf_rev"])
check("sort: title A–Z (ignores The)", sorts["title"] == "b4,b1,b2,b3", sorts["title"])
check("sort: title Z–A", sorts["title_rev"] == "b3,b2,b1,b4", sorts["title_rev"])
check("sort: author first name", sorts["author_first"] == "b2,b3,b1,b4", sorts["author_first"])
check("sort: author last name", sorts["author_last"] == "b2,b1,b3,b4", sorts["author_last"])
check("sort: highest rating", sorts["rating"] == "b2,b1,b4,b3", sorts["rating"])
check("options: filters removed", "All" not in r["options"].split(" | ") and "Available now" not in r["options"]
      and "At my libraries" not in r["options"], r["options"])
check("options: Settings + Close, no Quit", r["options"].endswith("Settings | Close") and "Quit" not in r["options"], r["options"])
check("options: refresh, shelf, sort, precheck", all(x in r["options"] for x in
      ("Refresh from Goodreads", "Shelf: Want to Read", "Sort: Shelf order", "Precheck", "Auto-refresh when opening: off")),
      r["options"])
check("sort picker marks current", r["sort_picker"] == "✓ Shelf order", r["sort_picker"])
check("shelf picker marks current", r["shelf_picker"] == "✓ Want to Read / Currently Reading", r["shelf_picker"])
check("shelf picker switches shelf", r["switched_title"].startswith("Currently Reading"), r["switched_title"])
check("tap shows progress with Stop", "Checking your libraries" in r["tap_progress"], r["tap_progress"])
check("tap checks only that book (3 libraries)", r["tap_lookups"] == 3, r["tap_lookups"])
check("book rows: most copies first", r["book_rows"].startswith("Borrow · LAPL (7 of 10 copies) | Borrow · NYPL (3 of 9 copies) | Place hold · BPL"),
      r["book_rows"])
check("Check again / Close pinned (no Quit)", r["pinned"] == "Check again,Close", r["pinned"])
check("list shows the tapped book's status", r["list_label"] == "available", r["list_label"])
check("tapping again uses saved results", r["tap_again_lookups"] == 0, r["tap_again_lookups"])
check("precheck warns: long time, own risk, Stop", all(x in r["warn_text"] for x in ("long time", "own risk", "Stop", "4 books")),
      r["warn_text"])
check("precheck shows progress", "Book" in r["progress_title"] and "of 4" in r["progress_title"], r["progress_title"])
check("results saved while running", r["saved_before_stop"] == 4, r["saved_before_stop"])
check("Stop kills the background process", r["terminated"] == 1 and r["stop_closed"] is True)
check("nothing runs after Stop", r["lookups_after_stop"] == 0, r["lookups_after_stop"])
check("results kept after Stop", r["saved_after_stop"] == 4, r["saved_after_stop"])
check("stop message", "stopped" in r["stop_msg"] and "saved" in r["stop_msg"], r["stop_msg"])
check("fallback: one search per tick", r["fallback_lookups"] == 3, r["fallback_lookups"])
check("fallback: Stop halts between searches", r["fallback_after_stop"] == 3, r["fallback_after_stop"])
check("full precheck checks every book at every library", r["full_lookups"] == 12, r["full_lookups"])
check("precheck finished message", "finished" in r["full_msg"], r["full_msg"])
check("borrow rows: most copies first", r["first_row"].startswith("Borrow · LAPL"), r["first_row"])
check("borrow used right card + title", r["borrowed"] == "11/t1", r["borrowed"])
check("ACSM saved, install offered", r["acsm_saved"] and r["install_offer"])
check("ACSM plugin makes EPUB and deletes .acsm", r["epub_made"] and r["acsm_deleted"])
check("15 libraries: all rows listed", r["many_rows"] == 15, r["many_rows"])
check("15 libraries: controls pinned", r["many_pinned"] is True)
check("manage shelves lists Add + shelves", r["manage_items"] == "+ Add a shelf…,Want to Read,Currently Reading,Read", r["manage_items"])
check("rename has Cancel", r["rename_has_cancel"] is True)
check("rename shelf", r["after_rename"] == "+ Add a shelf…,My TBR pile,Currently Reading,Read", r["after_rename"])
check("move shelf down", r["after_move"] == "+ Add a shelf…,Currently Reading,My TBR pile,Read", r["after_move"])
check("remove shelf", r["after_remove"] == "+ Add a shelf…,Currently Reading,My TBR pile", r["after_remove"])
check("add preset + someone else's shelf", r["after_add"] == "+ Add a shelf…,Currently Reading,My TBR pile,All my books,Otis · Read",
      r["after_add"])
check("someone else's shelf stores their id", r["other_user"] == "555:read", r["other_user"])
check("main menu follows the shelf list", r["main_menu_after"].startswith("Currently Reading; My TBR pile; All my books; Otis · Read"),
      r["main_menu_after"])
check("quit closes everything", r["closed_all"] is True)
check("device shelf edits saved to goodreads.txt", "My TBR pile = to-read" in r["file_after_manage"]
      and "Otis · Read = https://www.goodreads.com/review/list_rss/555?shelf=read" in r["file_after_manage"]
      and "All my books = #ALL#" in r["file_after_manage"] and r["file_after_manage"].startswith("# my account"),
      r["file_after_manage"])
check("menu lists goodreads.txt shelves + skipped-line notice",
      r["menu_from_file"].startswith("goodreads.txt: 1 line(s) skipped (tap for details); TBR; Now; Club; Otis TBR; Manage shelves"),
      r["menu_from_file"])
check("goodreads.txt: 4 shelves, account from profile + RSS key", r["file_shelves"] == 4 and r["file_account"] == "777:K1",
      (r["file_shelves"], r["file_account"]))
check("someone else's line keeps their id", r["otis_user"] == "1" and r["club_key"] == "777/book-club", (r["otis_user"], r["club_key"]))
check("skipped lines explained", "Oops" in r["problems_msg"] and "nickname = shelf RSS link" in r["problems_msg"], r["problems_msg"])
check("shelves load with their own links", r["otis_fetch"] == "1:nil:to-read" and r["tbr_fetch"] == "777:K1:to-read",
      (r["otis_fetch"], r["tbr_fetch"]))
check("rename written back, other lines kept", "To read = https://www.goodreads.com/review/list_rss/777?key=K1&shelf=to-read" in r["file_after_rename"]
      and "Club = book-club" in r["file_after_rename"] and "profile = https://www.goodreads.com/user/show/777-me" in r["file_after_rename"]
      and "user id = " in r["file_after_rename"] and "Oops" not in r["file_after_rename"], r["file_after_rename"])
check("troubleshooting menu", r["troubleshooting"].startswith("Test Libby connection | Log file: " + PLUGDIR + "/goodreadslibby.log | Clear the log"),
      r["troubleshooting"])
check("Settings opens from the shelf list", r["settings_title"] == "Goodreads → Libby settings" and r["settings_close_pinned"] is True)
check("settings toggle works in the dialog", r["pref_toggled"] is True)
check("settings submenu has Back", r["ttl_back"] == "Back", r["ttl_back"])
check("Never recheck option", r["never_checked"] and r["never_ttl"] and r["never_no_recheck"])
check("EPUB moved to the book folder", r["moved"] is True)
check(".acsm deleted after the EPUB is made", r["acsm_gone"] and "The .acsm file was deleted." in r["ready_text"]
      and "/Books/Educated.epub" in r["ready_text"], r["ready_text"])
check("loans show download state + due date", r["loan_rows"] == "on device · due Oct 15 | due Oct 20", r["loan_rows"])
check("loans list has a Settings button", r["loans_settings_icon"] == "appbar.settings")
check("loan popup: open / download again / return / return+delete / close (no Quit)",
      r["loan_buttons"] == "Open book | Download again: EPUB (ACSM) | Return early | Return and delete the file | Close", r["loan_buttons"])
check("loan popup says where the book is", "On this device:" in r["loan_title"] and "/Books/Educated.epub" in r["loan_title"], r["loan_title"])
check("locked loan explained, no download", "locked to Kindle" in r["locked_title"] and not r["locked_has_download"], r["locked_title"])
check("return + delete", r["returned"] == "11/t1" and r["returned_file_gone"] and r["loans_after_return"] == "1:Kindle Book",
      (r.get("returned"), r["returned_file_gone"], r["loans_after_return"]))
check("[optional] placeholders accepted", r["placeholder_errors"] == 0 and r["placeholder_account"] == "150",
      (r["placeholder_errors"], r["placeholder_account"]))
check("blocked download: app instructions shown", all(x in r["help_text"] for x in ("Manage Loan", "Download EPUB", "Convert .acsm files", "/Libby"))
      and r["help_buttons"] == "Convert .acsm files now | Close" and r["blocked_flag"] is True, r["help_text"])
check("next borrow skips the refused download", r["fulfill_calls"] == 1 and r["second_help"] is True, r["fulfill_calls"])
check("card refusal explained", "didn't accept your library card" in r["card_msg"] and "sign in again" in r["card_msg"], r["card_msg"])
check("main menu counts waiting .acsm files", r["convert_label"] == "Convert .acsm files (2 waiting)", r.get("convert_label"))
check("Convert .acsm files: books made + moved", r["converted"] is True, r["convert_msg"])
check("Convert .acsm files: .acsm deleted", r["acsm_cleared"] is True)
check("converted book shows in My Libby loans", r["loan_marked"] is True)
problems = list(lua.eval("problems").values())
check("every dialog has Cancel/Close/Stop", not problems, problems)

print()
print("FAILED: " + ", ".join(failures) if failures else "ALL PASSED")
sys.exit(1 if failures else 0)
