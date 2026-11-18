--[[--
Goodreads → Libby for KOReader.

Reads your Goodreads shelves, checks which of your Libby libraries carry each
ebook (and whether it's available now or on a wait list), and lets you borrow
or place a hold from the device. Borrowed books are downloaded straight into
your download folder as an ACSM (Adobe DRM) or a DRM-free EPUB.

@module koplugin.goodreadslibby
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local ffiutil = require("ffi/util")
local T = ffiutil.template

-- Plugin modules must be required at load time: KOReader only puts the plugin
-- directory on package.path while the plugin is being loaded.
local Goodreads = require("grlibby/goodreads")
local Http = require("grlibby/http")
local Libby = require("grlibby/libby")
local Log = require("grlibby/log")
local Match = require("grlibby/match")
local Openbook = require("grlibby/openbook")
local Update = require("grlibby/update")
local Util = require("grlibby/util")

local DEFAULT_AVAIL_TTL = 6 * 3600

local SHELF_NAMES = {
    ["to-read"] = _("Want to Read"),
    ["currently-reading"] = _("Currently Reading"),
    ["read"] = _("Read"),
    ["#ALL#"] = _("All books"),
}

local FORMAT_LABEL = {
    ["ebook-epub-adobe"] = _("EPUB (ACSM)"),
    ["ebook-pdf-adobe"] = _("PDF (ACSM)"),
    ["ebook-epub-open"] = _("EPUB (DRM-free)"),
    ["ebook-pdf-open"] = _("PDF (DRM-free)"),
    ["ebook-kindle"] = _("Kindle"),
    ["ebook-overdrive"] = _("reading in the Libby app"),
}

local ACSM_REPO = "kaikozlov/acsm.koplugin"
local ACSM_PLUGIN_URL = "https://github.com/" .. ACSM_REPO
local UPDATE_CHECK_INTERVAL = 24 * 3600
-- The automatic ACSM plugin update check runs at most once per KOReader session.
local acsm_update_checked = false
-- Set once the ACSM plugin was installed/updated; KOReader must restart.
local acsm_restart_needed = false

local GoodreadsLibby = WidgetContainer:extend{
    name = "goodreadslibby",
    is_doc_only = false,
}

--------------------------------------------------------------------------------
-- Setup and storage
--------------------------------------------------------------------------------

function GoodreadsLibby:init()
    -- Troubleshooting log, next to goodreads.txt in the plugin folder.
    Log.setPath(((self.path or DataStorage:getDataDir()):gsub("/+$", "")) .. "/goodreadslibby.log")
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/goodreadslibby.lua")
    self.cache = LuaSettings:open(DataStorage:getSettingsDir() .. "/goodreadslibby_cache.lua")
    self.libby = Libby.newClient{
        get = function() return self.settings:readSetting("libby_identity") end,
        set = function(identity)
            if identity then
                self.settings:saveSetting("libby_identity", identity)
            else
                self.settings:delSetting("libby_identity")
            end
            self.settings:flush()
        end,
    }
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    -- Leftovers of an interrupted ACSM plugin update (or a self-update) — never fatal.
    pcall(function() Update.cleanup(self:acsmDir()) end)
    pcall(function() Update.cleanup(self:pluginDir()) end)
    self:scheduleAcsmUpdateCheck()
    self:scheduleSelfUpdateCheck()
end

function GoodreadsLibby:get(key, default)
    local v = self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

function GoodreadsLibby:set(key, value)
    if value == nil then
        self.settings:delSetting(key)
    else
        self.settings:saveSetting(key, value)
    end
    self.settings:flush()
end

function GoodreadsLibby:onFlushSettings()
    if self.settings then self.settings:flush() end
    if self.cache then self.cache:flush() end
end

--- The Goodreads account. goodreads.txt in the plugin folder wins whenever it
-- holds a valid link, so editing that file is all it takes to set it.
function GoodreadsLibby:account()
    local saved = self:get("goodreads_account")
    local cfg = self:fileConfig()
    local from_file = cfg and cfg.account
    if from_file then
        if not saved or saved.id ~= from_file.id or saved.key ~= from_file.key then
            self:set("goodreads_account", from_file)
            self.cache:saveSetting("shelves", {})
            self.cache:flush()
        end
        return from_file
    end
    return saved
end

function GoodreadsLibby:cards()
    return self:get("libby_cards", {})
end

function GoodreadsLibby:isLinked()
    return self:get("libby_identity") ~= nil and #self:cards() > 0
end

--- Libraries to search: your Libby cards first, then extra library keys.
-- Each entry: { key, name, card = normalized card or nil }
function GoodreadsLibby:libraries()
    local libs, by_key = {}, {}
    for _i, card in ipairs(self:cards()) do
        if card.key and not by_key[card.key] then
            local lib = { key = card.key, name = card.library_name or card.key, card = card }
            by_key[card.key] = lib
            libs[#libs + 1] = lib
        end
    end
    local names = self:get("extra_library_names", {})
    for _i, key in ipairs(self:get("extra_libraries", {})) do
        if not by_key[key] then
            local lib = { key = key, name = names[key] or key }
            by_key[key] = lib
            libs[#libs + 1] = lib
        end
    end
    return libs, by_key
end

function GoodreadsLibby:downloadDir()
    local dir = self:get("download_dir")
    if dir and dir ~= "" then return dir end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if not home or lfs.attributes(home, "mode") ~= "directory" then
        local ok, Device = pcall(require, "device")
        home = ok and Device and Device.home_dir or DataStorage:getDataDir()
    end
    return (home or DataStorage:getDataDir()):gsub("/+$", "") .. "/Libby"
end

--- Where finished books (EPUB/PDF) go; defaults to the .acsm folder.
function GoodreadsLibby:bookDir()
    local dir = self:get("book_dir")
    if dir and dir ~= "" then return dir end
    return self:downloadDir()
end

local function shelfLabel(slug)
    if SHELF_NAMES[slug] then return SHELF_NAMES[slug] end
    local s = slug:gsub("[-_]", " ")
    return (s:gsub("^%l", string.upper))
end

--------------------------------------------------------------------------------
-- Small UI helpers
--------------------------------------------------------------------------------

local function notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

-- Run fn inside a Trapper coroutine so long network work can show progress and
-- be interrupted by a tap. Errors are reported instead of crashing the UI.
function GoodreadsLibby:task(fn)
    Trapper:wrap(function()
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            Trapper:clear()
            logger.err("grlibby: task failed", err)
            Log.write("ERROR:", err)
            notify(T(_("Something went wrong:\n%1"), tostring(err):match("^[^\n]*")))
        end
    end)
end

function GoodreadsLibby:whenOnline(fn)
    if NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(fn)
    else
        fn()
    end
end

local function mkdirp(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local parent = path:match("^(.+)/[^/]+/?$")
    if parent and parent ~= "" then mkdirp(parent) end
    return lfs.mkdir(path)
end

-- A path in `dir` for `name` that doesn't exist yet ("Book (1).epub", …).
local function uniquePath(dir, name)
    local base, ext = name:match("^(.*)(%.[^.]+)$")
    if not base then base, ext = name, "" end
    local path = dir .. "/" .. name
    local i = 1
    while lfs.attributes(path, "mode") do
        path = string.format("%s/%s (%d)%s", dir, base, i, ext)
        i = i + 1
    end
    return path
end

--- Move a file into `dir` (copying when it's on another storage).
-- Returns the new path, or nil and an error.
local function moveFile(src, dir)
    dir = dir:gsub("/+$", "")
    local src_dir, name = src:match("^(.*)/([^/]+)$")
    if not name or src_dir == dir then return src end
    mkdirp(dir)
    local dst = uniquePath(dir, name)
    if os.rename(src, dst) then return dst end
    local fi = io.open(src, "rb")
    if not fi then return nil, "can't read " .. src end
    local fo = io.open(dst, "wb")
    if not fo then
        fi:close()
        return nil, "can't write " .. dst
    end
    while true do
        local chunk = fi:read(1024 * 1024)
        if not chunk then break end
        fo:write(chunk)
    end
    fi:close()
    fo:close()
    os.remove(src)
    return dst
end

local function refreshFileManager()
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)
end

--------------------------------------------------------------------------------
-- Availability cache
--------------------------------------------------------------------------------

function GoodreadsLibby:availTTL()
    local ttl = tonumber(self:get("avail_ttl")) or DEFAULT_AVAIL_TTL
    if ttl < 0 then return math.huge end -- "Never": only when you tap Check again
    return ttl
end

function GoodreadsLibby:availFor(book_id)
    local avail = self.cache:readSetting("avail") or {}
    return avail[book_id]
end

function GoodreadsLibby:storeAvail(book_id, key, record)
    local avail = self.cache:readSetting("avail") or {}
    avail[book_id] = avail[book_id] or {}
    avail[book_id][key] = record
    self.cache:saveSetting("avail", avail)
end

function GoodreadsLibby:needsCheck(book, lib, force)
    if force then return true end
    local rec = (self:availFor(book.id) or {})[lib.key]
    if not rec or rec.status == "error" then return true end
    -- Keep what you did on this device until a recheck is asked for.
    if rec.status == "borrowed" or rec.status == "held" then return false end
    return os.time() - (rec.at or 0) > self:availTTL()
end

--- Search one library for one Goodreads book. Returns the result record
-- (no UI, no saving: this also runs in the background process).
function GoodreadsLibby:lookupBook(book, lib)
    local title = Match.searchTitle(book.title)
    local items, err = Libby.search(lib.key, title, Match.surname(book.author))
    local best = items and Match.best(book, items)
    -- Retry by ISBN when the title/author search found nothing usable.
    if items and not best then
        local isbn = Match.isbn13(book.isbn13) or Match.isbn13(book.isbn)
        if isbn then
            local by_isbn = Libby.search(lib.key, isbn)
            best = by_isbn and Match.best(book, by_isbn)
        end
    end
    local record
    if not items then
        record = { status = "error", error = err }
    elseif best then
        record = best
    else
        record = { status = "none" }
    end
    record.at = os.time()
    return record
end

--- The per-library results for a book, limited to the libraries in use.
function GoodreadsLibby:resultsFor(book, libs)
    local all = self:availFor(book.id) or {}
    local out = {}
    for _i, lib in ipairs(libs) do
        if all[lib.key] then out[lib.key] = all[lib.key] end
    end
    return out
end

local function statusLabel(best, checked)
    if not checked then return nil end
    if not best then return _("not found") end
    local s = best.status
    if s == "borrowed" then return _("borrowed") end
    if s == "available" then
        if not (best.acsm or best.epub_open or best.pdf_acsm) then return _("available (app)") end
        return _("available")
    end
    if s == "lucky" then return _("Lucky Day") end
    if s == "held" then return _("on hold") end
    if s == "hold" then
        if best.wait_days then return T(_("~%1 d wait"), best.wait_days) end
        return T(_("%1 holds"), best.holds or 0)
    end
    return _("not found")
end

--------------------------------------------------------------------------------
-- Background work with an always-visible Stop button
--------------------------------------------------------------------------------

local run_seq = 0

--- Run `opts.step` until it returns false, in a background process when the
-- platform allows it: the UI stays responsive and Stop ends the work at once.
-- step(emit) does one unit of work and reports plain-table messages with
-- emit(msg). opts.on_message(msg) handles each message on the UI thread and
-- may return new progress text. opts.on_done(stopped) runs at the end.
function GoodreadsLibby:runSteps(opts)
    local finished = false
    local dialog, poll, pid, outfile
    local offset = 0
    local progress_text = opts.text
    local shown_text = progress_text
    local finish

    local function makeDialog()
        return ButtonDialog:new{
            title = progress_text,
            title_align = "center",
            dismissable = false,
            -- The back key closes the dialog: treat it as Stop.
            tap_close_callback = function() finish(true) end,
            buttons = { { { text = _("Stop"), callback = function() finish(true) end } } },
        }
    end

    local function paint()
        if finished or not dialog or progress_text == shown_text then return end
        shown_text = progress_text
        if dialog.setTitle then
            dialog:setTitle(progress_text)
        else
            UIManager:close(dialog)
            dialog = makeDialog()
            UIManager:show(dialog)
        end
    end

    local function handle(msg)
        if type(msg) ~= "table" then return false end
        if msg.fin then return true end
        local text = opts.on_message and opts.on_message(msg)
        if text then progress_text = text end
        return false
    end

    -- Read the complete lines the background process has written so far.
    local function consume()
        if not outfile then return false end
        local f = io.open(outfile, "rb")
        if not f then return false end
        f:seek("set", offset)
        local data = f:read("*a") or ""
        f:close()
        local last_nl = data:match(".*()\n")
        if not last_nl then return false end
        offset = offset + last_nl
        local fin = false
        for line in data:sub(1, last_nl):gmatch("([^\n]*)\n") do
            if line ~= "" and handle(Http.decodeJSON(line)) then fin = true end
        end
        return fin
    end

    finish = function(stopped)
        if finished then return end
        if pid and stopped then ffiutil.terminateSubProcess(pid) end
        -- Keep whatever results already arrived.
        consume()
        finished = true
        if poll then UIManager:unschedule(poll) end
        if pid then
            local collect
            collect = function()
                if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(1, collect) end
            end
            collect()
        end
        if outfile then os.remove(outfile) end
        if dialog then UIManager:close(dialog) end
        dialog = nil
        if opts.on_done then opts.on_done(stopped) end
    end

    dialog = makeDialog()
    UIManager:show(dialog)

    if type(ffiutil.runInSubProcess) == "function" then
        run_seq = run_seq + 1
        local dir = DataStorage:getDataDir() .. "/cache"
        mkdirp(dir)
        outfile = string.format("%s/grlibby-%d-%d.jsonl", dir, os.time(), run_seq)
        local f = io.open(outfile, "wb")
        if f then f:close() else outfile = nil end
    end
    if outfile then
        local path = outfile
        local ok, child = pcall(ffiutil.runInSubProcess, function()
            local out = io.open(path, "ab")
            if not out then return end
            local function emit(msg)
                local enc_ok, line = pcall(Http.encodeJSON, msg)
                if enc_ok and line then
                    out:write(line, "\n")
                    out:flush()
                end
            end
            while true do
                local step_ok, more = pcall(opts.step, emit)
                if not step_ok then
                    emit({ err = tostring(more) })
                    break
                end
                if not more then break end
            end
            emit({ fin = true })
            out:close()
        end)
        if ok and child then
            pid = child
        else
            logger.warn("grlibby: no background process, running in the foreground", child)
            os.remove(outfile)
            outfile = nil
        end
    end

    if pid then
        local polls = 0
        poll = function()
            if finished then return end
            if consume() or ffiutil.isSubProcessDone(pid) then
                finish(false)
                return
            end
            polls = polls + 1
            if polls % 2 == 0 then paint() end
            UIManager:scheduleIn(0.5, poll)
        end
        UIManager:scheduleIn(0.3, poll)
    else
        -- No background process available: do one unit per UI tick, so a tap
        -- on Stop is handled between two network requests.
        local function emit(msg) handle(msg) end
        local step_fn
        step_fn = function()
            if finished then return end
            local step_ok, more = pcall(opts.step, emit)
            if not step_ok then
                handle({ err = tostring(more) })
                more = false
            end
            if not more then
                finish(false)
                return
            end
            paint()
            UIManager:scheduleIn(0.05, step_fn)
        end
        UIManager:scheduleIn(0.3, step_fn)
    end
end

--------------------------------------------------------------------------------
-- Shelves: your list of Goodreads shelves, each with a nickname
--------------------------------------------------------------------------------

local DEFAULT_SHELVES = {
    { name = _("Want to Read"), shelf = "to-read" },
    { name = _("Currently Reading"), shelf = "currently-reading" },
    { name = _("Read"), shelf = "read" },
}

--- The shelves shown in the menu. Each entry: { name, shelf, user = nil (you)
-- or { id, key } (someone else) }.
function GoodreadsLibby:shelfList()
    -- goodreads.txt wins when it lists shelves ("nickname = RSS link").
    local cfg = self:fileConfig()
    if cfg and #cfg.shelves > 0 then return cfg.shelves end
    local list = self:get("shelf_list")
    if type(list) == "table" then return list end
    list = {}
    local old = self:get("shelves") -- older versions stored shelf slugs only
    if type(old) == "table" and #old > 0 then
        for _i, slug in ipairs(old) do list[#list + 1] = { name = shelfLabel(slug), shelf = slug } end
    else
        for _i, e in ipairs(DEFAULT_SHELVES) do list[#list + 1] = { name = e.name, shelf = e.shelf } end
    end
    return list
end

--- Save shelf changes made on the device, into goodreads.txt as well.
function GoodreadsLibby:saveShelfList(list)
    self:set("shelf_list", list)
    self:writeConfig(function(cfg) cfg.shelves = list end)
end

function GoodreadsLibby:shelfAccount(entry)
    return entry.user or self:account()
end

--- Cache key for a shelf's books: whose shelf + which shelf.
function GoodreadsLibby:shelfKey(entry)
    local acc = self:shelfAccount(entry)
    return (acc and acc.id or "?") .. "/" .. tostring(entry.shelf)
end

function GoodreadsLibby:shelfSourceText(entry)
    if entry.user then
        return T(_("%1 · user %2"), entry.shelf, entry.user.id)
    end
    return entry.shelf
end

--------------------------------------------------------------------------------
-- Shelf browsing
--------------------------------------------------------------------------------

local SORTS = {
    { id = "shelf", text = _("Shelf order") },
    { id = "shelf_rev", text = _("Reverse shelf order") },
    { id = "title", text = _("Title A–Z") },
    { id = "title_rev", text = _("Title Z–A") },
    { id = "author_first", text = _("Author first name A–Z") },
    { id = "author_last", text = _("Author last name A–Z") },
    { id = "rating", text = _("Highest Goodreads rating") },
    { id = "availability", text = _("Availability (checked books first)") },
}

local function sortLabel(id)
    for _i, s in ipairs(SORTS) do
        if s.id == id then return s.text end
    end
    return SORTS[1].text
end

-- Lowercase, punctuation-free text for alphabetical sorting.
local function plain(s)
    s = tostring(s or ""):lower():gsub("%p", " "):gsub("%s+", " ")
    return Util.trim(s)
end

local LAST = "\255" -- sorts after any text: books without an author go last

local function sortItems(items, how)
    for _i, it in ipairs(items) do
        local b = it.book
        if how == "title" or how == "title_rev" then
            it._key = Match.normalize(b.title)
        elseif how == "author_first" then
            it._key = b.author and plain(b.author) or LAST
        elseif how == "author_last" then
            it._key = b.author and ((Match.surname(b.author) or "") .. " " .. plain(b.author)) or LAST
        end
    end
    table.sort(items, function(a, b)
        if how == "shelf_rev" then return a._idx > b._idx end
        if how == "rating" then
            local ra, rb = a.book.rating or -1, b.book.rating or -1
            if ra ~= rb then return ra > rb end
        elseif how == "availability" then
            if a._rank ~= b._rank then return a._rank < b._rank end
            if a._wait ~= b._wait then return a._wait < b._wait end
        elseif a._key and b._key and a._key ~= b._key then
            if how == "title_rev" then return a._key > b._key end
            return a._key < b._key
        end
        return a._idx < b._idx
    end)
end

--- Open a shelf: show the saved copy, or load it from Goodreads when there is
-- none, when you ask for a refresh, or when auto-refresh is on.
-- Availability is never checked here; only when you tap a book or precheck.
function GoodreadsLibby:openShelf(entry, opts)
    opts = opts or {}
    if not self:shelfAccount(entry) then
        self:editAccount(function() self:openShelf(entry, opts) end)
        return
    end
    local key = self:shelfKey(entry)
    local cached = (self.cache:readSetting("shelves") or {})[key]
    local auto = self:get("auto_refresh_shelf", false)
    if cached and not opts.refresh and not auto then
        self:showShelf(entry, cached.books or {}, true)
        return
    end
    if cached and not opts.refresh then
        -- Auto-refresh only when already online; never block on Wi-Fi.
        local ok, online = pcall(function() return NetworkMgr:isOnline() end)
        if ok and not online then
            self:showShelf(entry, cached.books or {}, true)
            return
        end
    end
    self:whenOnline(function()
        self:loadShelf(entry, function(books, err)
            if books then
                local all = self.cache:readSetting("shelves") or {}
                all[key] = { at = os.time(), books = books }
                self.cache:saveSetting("shelves", all)
                self.cache:flush()
                self:showShelf(entry, books, true)
            elseif cached then
                if err then
                    notify(T(_("Couldn't refresh “%1”; showing the saved copy.\n\n%2"), entry.name, err), 4)
                end
                self:showShelf(entry, cached.books or {}, true)
            elseif err then
                notify(err)
            end
        end)
    end)
end

--- Load every page of a shelf from Goodreads (Stop cancels at once).
-- on_loaded(books) on success, on_loaded(nil, err) on failure, on_loaded(nil)
-- when stopped.
function GoodreadsLibby:loadShelf(entry, on_loaded)
    local account = self:shelfAccount(entry)
    local page = 0
    local child_seen = {}
    local books, seen, err = {}, {}, nil
    self:runSteps{
        text = T(_("Loading “%1” from Goodreads…"), entry.name),
        step = function(emit)
            page = page + 1
            local res, perr = Goodreads.fetchPage(account, entry.shelf, page)
            if not res then
                emit({ err = perr })
                return false
            end
            local added = 0
            for _i, b in ipairs(res.books) do
                if not child_seen[b.id] then
                    child_seen[b.id] = true
                    added = added + 1
                end
            end
            emit({ p = page, books = res.books })
            return #res.books >= Goodreads.PAGE_SIZE and added > 0 and page < 50
        end,
        on_message = function(msg)
            if msg.err then
                err = msg.err
                return
            end
            if msg.p then
                for _i, b in ipairs(type(msg.books) == "table" and msg.books or {}) do
                    if b.id and not seen[b.id] then
                        seen[b.id] = true
                        books[#books + 1] = b
                    end
                end
                return T(_("Loading “%1” from Goodreads…\n%2 books so far"), entry.name, #books)
            end
        end,
        on_done = function(stopped)
            if stopped then
                on_loaded(nil)
            elseif err then
                on_loaded(nil, err)
            else
                on_loaded(books)
            end
        end,
    }
end

function GoodreadsLibby:shelfItems(entry, books)
    local libs = self:libraries()
    local items = {}
    for idx, book in ipairs(books) do
        local results = self:resultsFor(book, libs)
        local best = Match.overall(results)
        local checked = next(results) ~= nil
        items[#items + 1] = {
            text = book.author and T("%1 — %2", book.title, book.author) or book.title,
            mandatory = statusLabel(best, checked),
            book = book,
            _idx = idx,
            _rank = checked and (best and Match.STATUS_RANK[best.status] or 5) or 6,
            _wait = best and best.wait_days or 9999,
        }
    end
    sortItems(items, self:get("sort_order", "shelf"))
    if #items == 0 then
        items[1] = { text = _("This shelf is empty."), select_enabled = false }
    end
    return items, T(_("%1 · %2 books"), entry.name, #books)
end

function GoodreadsLibby:showShelf(entry, books, first_page)
    self.current_shelf = { entry = entry, books = books }
    local items, title = self:shelfItems(entry, books)
    if self.shelf_menu then
        self.shelf_menu:switchItemTable(title, items, first_page and 1 or -1)
        return
    end
    self.shelf_menu = Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() self:shelfOptions() end,
        onMenuSelect = function(_menu, item)
            if item.book then self:showBook(item.book) end
            return true
        end,
        close_callback = function()
            if self.shelf_menu then UIManager:close(self.shelf_menu) end
            self.shelf_menu = nil
            self.current_shelf = nil
        end,
    }
    UIManager:show(self.shelf_menu)
end

--- Close every screen this plugin has open.
function GoodreadsLibby:closeAll()
    for _i, name in ipairs({ "loans_menu", "shelves_menu", "shelf_menu" }) do
        if self[name] then
            UIManager:close(self[name])
            self[name] = nil
        end
    end
    self.current_shelf = nil
end

function GoodreadsLibby:refreshShelfMenu()
    if self.shelf_menu and self.current_shelf then
        local items, title = self:shelfItems(self.current_shelf.entry, self.current_shelf.books)
        self.shelf_menu:switchItemTable(title, items, -1)
    end
end

function GoodreadsLibby:shelfOptions()
    local cur = self.current_shelf
    if not cur then return end
    local dialog
    local function close_then(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local auto = self:get("auto_refresh_shelf", false)
    dialog = ButtonDialog:new{
        title = cur.entry.name,
        title_align = "center",
        buttons = {
            {
                { text = _("Refresh from Goodreads"), callback = close_then(function()
                    self:openShelf(cur.entry, { refresh = true })
                end) },
            },
            {
                { text = T(_("Shelf: %1"), cur.entry.name), callback = close_then(function() self:pickShelf() end) },
            },
            {
                { text = T(_("Sort: %1"), sortLabel(self:get("sort_order", "shelf"))),
                  callback = close_then(function() self:pickSort() end) },
            },
            {
                { text = T(_("Auto-refresh when opening: %1"), auto and _("on") or _("off")),
                  callback = close_then(function()
                      self:set("auto_refresh_shelf", not auto)
                      notify(not auto and _("Shelves now refresh from Goodreads each time you open them.")
                          or _("Shelves open from the saved copy. Use “Refresh from Goodreads” to update."), 3)
                  end) },
            },
            {
                { text = _("Precheck availability for all books…"), callback = close_then(function() self:precheck() end) },
            },
            {
                { text = _("Manage shelves"), callback = close_then(function() self:manageShelves() end) },
                { text = _("My Libby loans"), callback = close_then(function() self:showLoans() end) },
            },
            {
                { text = _("Settings"), callback = close_then(function() self:showSettings() end) },
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    UIManager:show(dialog)
end

function GoodreadsLibby:pickShelf()
    local cur = self.current_shelf
    local current_key = cur and self:shelfKey(cur.entry)
    local dialog
    local buttons = {}
    for _i, entry in ipairs(self:shelfList()) do
        local is_current = cur and entry.name == cur.entry.name and self:shelfKey(entry) == current_key
        buttons[#buttons + 1] = { {
            text = (is_current and "✓ " or "") .. entry.name,
            callback = function()
                UIManager:close(dialog)
                self:openShelf(entry)
            end,
        } }
    end
    buttons[#buttons + 1] = {
        { text = _("Manage shelves"), callback = function()
            UIManager:close(dialog)
            self:manageShelves()
        end },
        { text = _("Close"), callback = function() UIManager:close(dialog) end },
    }
    dialog = ButtonDialog:new{ title = _("View shelf"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function GoodreadsLibby:pickSort()
    local current = self:get("sort_order", "shelf")
    local dialog
    local buttons = {}
    for _i, s in ipairs(SORTS) do
        buttons[#buttons + 1] = { {
            text = (s.id == current and "✓ " or "") .. s.text,
            callback = function()
                UIManager:close(dialog)
                self:set("sort_order", s.id)
                if self.shelf_menu and self.current_shelf then
                    local items, title = self:shelfItems(self.current_shelf.entry, self.current_shelf.books)
                    self.shelf_menu:switchItemTable(title, items, 1)
                end
            end,
        } }
    end
    buttons[#buttons + 1] = { { text = _("Close"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = _("Sort books by"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

--------------------------------------------------------------------------------
-- Availability checks: one book on tap, or a whole shelf on request
--------------------------------------------------------------------------------

--- Check `jobs` ({ { book, libs } }) in the background, saving each result as
-- it arrives. opts.label names the shelf for a precheck; opts.on_done(stopped,
-- books_started) runs at the end.
function GoodreadsLibby:runChecks(jobs, opts)
    opts = opts or {}
    local total = #jobs
    local started, libs_done, saved = 0, 0, 0
    local function text(i)
        local job = jobs[i] or jobs[total]
        if total == 1 then
            return T(_("Checking your libraries for\n%1\n\n%2 of %3 done"),
                Util.shorten(job.book.title, 80), libs_done, #job.libs)
        end
        return T(_("Prechecking “%1”\nBook %2 of %3\n\n%4"),
            opts.label or "", i, total, Util.shorten(job.book.title, 80))
    end
    local i, j = 1, 0
    self:runSteps{
        text = text(1),
        step = function(emit)
            local job = jobs[i]
            if not job then return false end
            if j == 0 then emit({ s = i }) end
            j = j + 1
            local lib = job.libs[j]
            if lib then
                emit({ b = i, l = lib.key, r = self:lookupBook(job.book, lib) })
            end
            if j >= #job.libs then
                i = i + 1
                j = 0
            end
            return jobs[i] ~= nil
        end,
        on_message = function(msg)
            if msg.s then
                started = msg.s
                return text(msg.s)
            end
            if msg.b and msg.l and type(msg.r) == "table" and jobs[msg.b] then
                msg.r.at = msg.r.at or os.time()
                self:storeAvail(jobs[msg.b].book.id, msg.l, msg.r)
                libs_done = libs_done + 1
                saved = saved + 1
                if saved % 50 == 0 then self.cache:flush() end
                if total == 1 then return text(1) end
            end
        end,
        on_done = function(stopped)
            self.cache:flush()
            self:refreshShelfMenu()
            if opts.on_done then opts.on_done(stopped, started) end
        end,
    }
end

function GoodreadsLibby:precheck()
    local cur = self.current_shelf
    if not cur then return end
    local libs = self:libraries()
    if #libs == 0 then
        notify(_("Link your Libby account (or add a library) first."))
        return
    end
    local jobs, searches = {}, 0
    for _i, book in ipairs(cur.books) do
        local need = {}
        for _j, lib in ipairs(libs) do
            if self:needsCheck(book, lib) then need[#need + 1] = lib end
        end
        if #need > 0 then
            jobs[#jobs + 1] = { book = book, libs = need }
            searches = searches + #need
        end
    end
    if #jobs == 0 then
        notify(_("Every book on this shelf was checked recently."), 3)
        return
    end
    -- Roughly 1–2 seconds per library search on an e-reader.
    local minutes = math.ceil(searches * 1.5 / 60)
    local duration = minutes <= 1 and _("about a minute or more")
        or T(_("roughly %1 minutes or more"), minutes)
    UIManager:show(ConfirmBox:new{
        text = T(_("Precheck “%1”?\n\nThis looks up %2 books at your %3 libraries: about %4 library searches, one after another. It can take a long time (%5), keeps Wi-Fi busy and uses battery the whole time. Goodreads/Libby services may also slow down or refuse requests during a long run.\n\nResults are saved as they come in. The Stop button stays on screen and cancels immediately.\n\nRun it at your own risk."),
            cur.entry.name, #jobs, #libs, searches, duration),
        ok_text = _("Start precheck"),
        ok_callback = function()
            self:whenOnline(function()
                self:runChecks(jobs, {
                    label = cur.entry.name,
                    on_done = function(stopped, started)
                        if stopped then
                            notify(T(_("Precheck stopped at book %1 of %2. Results so far are saved."), started, #jobs), 4)
                        else
                            notify(T(_("Precheck finished: %1 books checked."), #jobs), 3)
                        end
                    end,
                })
            end)
        end,
    })
end

--- Tap on a book: check the libraries that have no fresh result, then show it.
function GoodreadsLibby:showBook(book, force)
    local libs = self:libraries()
    if #libs == 0 then
        UIManager:show(ConfirmBox:new{
            text = _("No libraries yet. Link your Libby account to check and borrow from your library cards."),
            ok_text = _("Link Libby"),
            ok_callback = function() self:linkLibby() end,
        })
        return
    end
    local need = {}
    for _i, lib in ipairs(libs) do
        if self:needsCheck(book, lib, force) then need[#need + 1] = lib end
    end
    if #need == 0 then
        self:showBookDialog(book)
        return
    end
    self:whenOnline(function()
        self:runChecks({ { book = book, libs = need } }, {
            on_done = function() self:showBookDialog(book) end,
        })
    end)
end

local ROW_RANK = { borrowed = 0, available = 1, lucky = 2, held = 3, hold = 4, error = 5, none = 6 }

function GoodreadsLibby:showBookDialog(book)
    local libs = self:libraries()
    local results = self:resultsFor(book, libs)
    local dialog
    local counts = { available = 0, hold = 0, none = 0, unchecked = 0 }
    local rows = {}
    for idx, lib in ipairs(libs) do
        local rec = results[lib.key]
        local s = rec and rec.status or "unchecked"
        local name = lib.name
        local can_act = rec and rec.id and lib.card
        local row = { enabled = false }
        if s == "available" or s == "borrowed" or s == "lucky" then
            counts.available = counts.available + 1
        elseif s == "hold" or s == "held" then
            counts.hold = counts.hold + 1
        elseif s == "unchecked" or s == "error" then
            counts.unchecked = counts.unchecked + 1
        else
            counts.none = counts.none + 1
        end
        local app_only = rec and not (rec.acsm or rec.epub_open or rec.pdf_acsm)
        if s == "borrowed" and can_act then
            row = { text = T(_("Download · %1"), name), callback = function()
                UIManager:close(dialog)
                self:whenOnline(function()
                    self:task(function() self:downloadLoan(lib.card.card_id, rec.id, rec.formats, book) end)
                end)
            end }
        elseif s == "available" then
            local copies = rec.always and _("always available")
                or T(_("%1 of %2 copies"), rec.available or 0, rec.owned or 0)
            if app_only then copies = copies .. " · " .. _("app only") end
            if can_act then
                row = { text = T(_("Borrow · %1 (%2)"), name, copies), callback = function()
                    UIManager:close(dialog)
                    self:borrow(book, lib, rec)
                end }
            else
                row.text = T(_("%1: available (%2) · no card"), name, copies)
            end
        elseif (s == "hold" or s == "lucky") then
            local wait = rec.wait_days and T(_("~%1 d"), rec.wait_days) or T(_("%1 holds"), rec.holds or 0)
            if s == "lucky" then wait = _("Lucky Day copy in the app") end
            if can_act and rec.holdable then
                row = { text = T(_("Place hold · %1 (%2)"), name, wait), callback = function()
                    UIManager:close(dialog)
                    self:placeHold(book, lib, rec)
                end }
            else
                row.text = T(_("%1: wait %2 · no card"), name, wait)
            end
        elseif s == "held" then
            row.text = T(_("%1: on hold"), name)
        elseif s == "borrowed" then
            row.text = T(_("%1: borrowed"), name)
        elseif s == "error" then
            row.text = T(_("%1: couldn't check"), name)
        elseif s == "none" then
            row.text = T(_("%1: not in catalog"), name)
        else
            row.text = T(_("%1: not checked"), name)
        end
        row._rank = ROW_RANK[s] or 7
        row._wait = rec and rec.wait_days or 9999
        -- Most copies on the shelf first ("always available" beats any count).
        row._copies = rec and (rec.always and math.huge or rec.available) or 0
        row._idx = idx
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b)
        if a._rank ~= b._rank then return a._rank < b._rank end
        if a._copies ~= b._copies then return a._copies > b._copies end
        if a._wait ~= b._wait then return a._wait < b._wait end
        return a._idx < b._idx
    end)
    local buttons = {}
    for _i, row in ipairs(rows) do
        row._rank, row._wait, row._copies, row._idx = nil, nil, nil, nil
        buttons[#buttons + 1] = { row }
    end

    local lines = { book.title }
    if book.author then lines[#lines + 1] = T(_("by %1"), book.author) end
    local summary = {}
    if counts.available > 0 then summary[#summary + 1] = T(_("available at %1"), counts.available) end
    if counts.hold > 0 then summary[#summary + 1] = T(_("wait list at %1"), counts.hold) end
    if counts.none > 0 then summary[#summary + 1] = T(_("not at %1"), counts.none) end
    if counts.unchecked > 0 then summary[#summary + 1] = T(_("unchecked %1"), counts.unchecked) end
    lines[#lines + 1] = table.concat(summary, " · ")
    if not self:isLinked() then
        lines[#lines + 1] = _("Link your Libby account (Settings) to borrow.")
    end

    -- Check again / Close stay put above the library list, however
    -- long it is (the list scrolls, this row doesn't).
    local controls = {
        { text = _("Check again"), callback = function()
            UIManager:close(dialog)
            self:showBook(book, true)
        end },
        { text = _("Close"), callback = function() UIManager:close(dialog) end },
    }
    local pinned = ButtonDialog.addWidget ~= nil and ButtonDialog.getAddedWidgetAvailableWidth ~= nil
    if not pinned then table.insert(buttons, 1, controls) end
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        title_align = "left",
        buttons = buttons,
        width_factor = 0.9,
    }
    if pinned then
        local ButtonTable = require("ui/widget/buttontable")
        dialog:addWidget(ButtonTable:new{
            width = dialog:getAddedWidgetAvailableWidth(),
            buttons = { controls },
            show_parent = dialog,
        })
    end
    UIManager:show(dialog)
end

--------------------------------------------------------------------------------
-- Managing shelves: add, rename, reorder, remove
--------------------------------------------------------------------------------

function GoodreadsLibby:manageShelves()
    local menu
    local function items()
        local out = { { text = _("+ Add a shelf…"), add = true } }
        for i, entry in ipairs(self:shelfList()) do
            out[#out + 1] = { text = entry.name, mandatory = self:shelfSourceText(entry), index = i }
        end
        return out
    end
    local function refresh()
        if menu then menu:switchItemTable(nil, items(), -1) end
    end
    if self.shelves_menu then UIManager:close(self.shelves_menu) end
    menu = Menu:new{
        title = _("Shelves"),
        item_table = items(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(_menu, item)
            if item.add then
                self:addShelf(refresh)
            elseif item.index then
                self:shelfActions(item.index, refresh)
            end
            return true
        end,
        close_callback = function()
            UIManager:close(menu)
            if self.shelves_menu == menu then self.shelves_menu = nil end
        end,
    }
    self.shelves_menu = menu
    UIManager:show(menu)
end

function GoodreadsLibby:promptText(opts)
    local dialog
    dialog = InputDialog:new{
        title = opts.title,
        description = opts.description,
        input = opts.input or "",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = opts.ok_text or _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = Util.trim(dialog:getInputText())
                    if value == "" then return end
                    UIManager:close(dialog)
                    opts.callback(value)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function slugify(s)
    if s == "#ALL#" then return s end
    return (Util.trim(s):lower():gsub("%s+", "-"))
end

function GoodreadsLibby:shelfActions(index, refresh)
    local list = self:shelfList()
    local entry = list[index]
    if not entry then return end
    local dialog
    local function done()
        self:saveShelfList(list)
        refresh()
    end
    local function close_then(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    dialog = ButtonDialog:new{
        title = T(_("%1\nGoodreads shelf: %2\nWhose: %3"), entry.name, entry.shelf,
            entry.user and T(_("user %1"), entry.user.id) or _("yours")),
        title_align = "left",
        buttons = {
            { { text = _("Open"), callback = close_then(function() self:openShelf(entry) end) } },
            {
                { text = _("Rename"), callback = close_then(function()
                    self:promptText{
                        title = _("Shelf nickname"),
                        description = _("Any name you like; it's only used on this device."),
                        input = entry.name,
                        callback = function(name)
                            entry.name = name
                            done()
                        end,
                    }
                end) },
                { text = _("Change shelf"), callback = close_then(function()
                    self:promptText{
                        title = _("Goodreads shelf"),
                        description = _("The shelf's name as in its web address, e.g. to-read, currently-reading, read, or a custom shelf. #ALL# means every book."),
                        input = entry.shelf,
                        callback = function(slug)
                            entry.shelf = slugify(slug)
                            done()
                        end,
                    }
                end) },
            },
            {
                { text = _("Move up"), enabled = index > 1, callback = close_then(function()
                    list[index], list[index - 1] = list[index - 1], list[index]
                    done()
                end) },
                { text = _("Move down"), enabled = index < #list, callback = close_then(function()
                    list[index], list[index + 1] = list[index + 1], list[index]
                    done()
                end) },
            },
            {
                { text = _("Remove"), callback = close_then(function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Remove “%1” from your shelves on this device? Nothing changes on Goodreads."), entry.name),
                        ok_text = _("Remove"),
                        ok_callback = function()
                            table.remove(list, index)
                            done()
                        end,
                    })
                end) },
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    UIManager:show(dialog)
end

function GoodreadsLibby:addShelfEntry(entry, refresh)
    local list = self:shelfList()
    list[#list + 1] = entry
    self:saveShelfList(list)
    if refresh then refresh() end
    notify(T(_("Added “%1”. Tap it to rename it."), entry.name), 3)
end

function GoodreadsLibby:addShelf(refresh)
    local dialog
    local function preset(slug, name)
        return { text = name, callback = function()
            UIManager:close(dialog)
            self:addShelfEntry({ name = name, shelf = slug }, refresh)
        end }
    end
    dialog = ButtonDialog:new{
        title = _("Add a shelf"),
        title_align = "center",
        buttons = {
            { preset("to-read", _("Want to Read")), preset("currently-reading", _("Currently Reading")) },
            { preset("read", _("Read")), preset("#ALL#", _("All my books")) },
            { { text = _("One of my custom shelves…"), callback = function()
                UIManager:close(dialog)
                self:promptText{
                    title = _("Your Goodreads shelf"),
                    description = _("The shelf's name as in its web address on Goodreads (e.g. book-club)."),
                    ok_text = _("Add"),
                    callback = function(slug)
                        slug = slugify(slug)
                        self:addShelfEntry({ name = shelfLabel(slug), shelf = slug }, refresh)
                    end,
                }
            end } },
            { { text = _("Someone else's shelf…"), callback = function()
                UIManager:close(dialog)
                self:addOthersShelf(refresh)
            end } },
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

function GoodreadsLibby:addOthersShelf(refresh)
    self:promptText{
        title = _("Whose shelf?"),
        description = _("Their Goodreads profile link (e.g. https://www.goodreads.com/user/show/12345-name), shelf RSS link, or user ID. Their profile must be public, or use an RSS link with key=…"),
        ok_text = _("Next"),
        callback = function(text)
            local user = Goodreads.parseAccountText(text) or Goodreads.parseAccount(text)
            if not user then
                notify(_("That doesn't look like a Goodreads profile link, RSS link or user ID."))
                return
            end
            self:promptText{
                title = _("Which of their shelves?"),
                description = _("e.g. to-read, currently-reading, read, or one of their custom shelves. #ALL# means every book."),
                input = "to-read",
                ok_text = _("Add"),
                callback = function(slug)
                    slug = slugify(slug)
                    -- Check it exists (and get their name) before adding it.
                    self:whenOnline(function()
                        local info, err
                        self:runSteps{
                            text = _("Looking up the shelf on Goodreads…"),
                            step = function(emit)
                                local res, perr = Goodreads.fetchPage(user, slug, 1)
                                if res then
                                    emit({ owner = res.owner or "", n = #res.books })
                                else
                                    emit({ err = perr })
                                end
                                return false
                            end,
                            on_message = function(msg)
                                if msg.err then err = msg.err else info = msg end
                            end,
                            on_done = function(stopped)
                                if stopped then return end
                                if not info then
                                    notify(T(_("Couldn't open that shelf:\n%1"), err or "?"))
                                    return
                                end
                                local owner = info.owner ~= "" and info.owner or T(_("user %1"), user.id)
                                self:addShelfEntry({
                                    name = T(_("%1 · %2"), owner, shelfLabel(slug)),
                                    shelf = slug,
                                    user = user,
                                }, refresh)
                            end,
                        }
                    end)
                end,
            }
        end,
    }
end

-- Which file to fetch for a loan, given the formats OverDrive offers.
function GoodreadsLibby:pickFormat(formats)
    local has = {}
    for _i, f in ipairs(formats or {}) do has[f] = true end
    if self:get("prefer_open_epub", true) and has[Libby.FORMAT_EPUB] then return Libby.FORMAT_EPUB end
    if has[Libby.FORMAT_ACSM] then return Libby.FORMAT_ACSM end
    if has[Libby.FORMAT_EPUB] then return Libby.FORMAT_EPUB end
    if has[Libby.FORMAT_PDF_ACSM] then return Libby.FORMAT_PDF_ACSM end
    return nil
end

function GoodreadsLibby:borrow(book, lib, rec)
    local card = lib.card
    local format = self:pickFormat(rec.formats)
    local period = card.periods and card.periods.ebook and card.periods.ebook.days
    local text = T(_("Borrow “%1” from %2?"), rec.title or book.title, lib.name)
    if period then text = text .. "\n" .. T(_("Loan period: %1 days."), period) end
    if format and Libby.EXTENSION[format] == "acsm" and self:acsmPlugin() and self:get("convert_acsm", true) then
        text = text .. "\n\n" .. T(_("The book will be saved to:\n%1"), self:bookDir())
    elseif format then
        text = text .. "\n\n" .. T(_("The %1 will be saved to:\n%2"), FORMAT_LABEL[format],
            Libby.EXTENSION[format] == "acsm" and self:downloadDir() or self:bookDir())
    else
        text = text .. "\n\n" .. _("This title has no downloadable EPUB/ACSM at this library; it can only be read in the Libby app (or on Kindle).")
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Borrow"),
        ok_callback = function()
            self:whenOnline(function()
                self:task(function() self:_borrow(book, lib, rec, format) end)
            end)
        end,
    })
end

function GoodreadsLibby:_borrow(book, lib, rec, format)
    Trapper:info(T(_("Borrowing from %1…"), lib.name))
    Log.write("borrow:", book.title, "| title", rec.id, "| library", lib.key, "| card", lib.card.card_id)
    local _loan, err, code = self.libby:borrow(lib.card, rec.id, "ebook")
    Log.write("borrow result:", _loan and "ok" or ("failed: " .. tostring(err)))
    if not _loan then
        Trapper:clear()
        if code == "PatronCardFailedAuthentication" then
            notify(T(_("%1 didn't accept your library card:\n%2\n\nOpen the Libby app, go to this library's card and sign in again (or renew the card). Then tap “Refresh library cards” in this plugin's settings and try again."),
                lib.name, err))
        else
            notify(T(_("Couldn't borrow:\n%1"), err))
        end
        return
    end
    rec.status = "borrowed"
    rec.at = os.time()
    self:storeAvail(book.id, lib.key, rec)
    self.cache:flush()
    self:refreshShelfMenu()
    if not format then
        Trapper:clear()
        notify(_("Borrowed! Open Libby to read it."))
        return
    end
    -- Libby refused the ACSM download before: skip that dead call (retrying it
    -- risks a rate-limit) and build the book on the device instead.
    if self:get("download_refused_at") and Libby.EXTENSION[format] == "acsm" then
        Trapper:clear()
        self:decodeToEpub(lib.card, rec.id, book)
        return
    end
    self:downloadLoan(lib.card.card_id, rec.id, rec.formats, book, format)
end

--- Remember what was downloaded for a loan (shown in My Libby loans).
function GoodreadsLibby:recordDownload(card_id, title_id, path, kind)
    local all = self:get("downloads", {})
    all[tostring(card_id) .. ":" .. tostring(title_id)] = { path = path, kind = kind, at = os.time() }
    self:set("downloads", all)
end

--- The download recorded for a loan, if its file is still on the device.
function GoodreadsLibby:downloadFor(card_id, title_id)
    local rec = self:get("downloads", {})[tostring(card_id) .. ":" .. tostring(title_id)]
    if rec and rec.path and lfs.attributes(rec.path, "mode") == "file" then return rec end
    return nil
end

function GoodreadsLibby:forgetDownload(card_id, title_id)
    local all = self:get("downloads", {})
    all[tostring(card_id) .. ":" .. tostring(title_id)] = nil
    self:set("downloads", all)
end

--- Fetch the loan file and save it. Runs inside a task.
-- ACSM files go to the .acsm folder; books (DRM-free downloads, and EPUBs the
-- ACSM plugin makes) end up in the book folder.
function GoodreadsLibby:downloadLoan(card_id, title_id, formats, book, format)
    format = format or self:pickFormat(formats)
    if not format then
        Trapper:clear()
        notify(_("This loan has no downloadable EPUB/ACSM. Read it in the Libby app."))
        return
    end
    Trapper:info(T(_("Downloading %1…"), FORMAT_LABEL[format] or format))
    local body, err, why = self.libby:fulfill(card_id, title_id, format)
    Log.write("download result:", body and ("ok, " .. #body .. " bytes") or ("failed: " .. tostring(err)))
    Trapper:clear()
    if not body and why == "blocked" then
        -- Libby refuses this client the ACSM download (missing_chip). Build the
        -- EPUB on the device instead, by decoding the loan the way the Libby web
        -- reader does. Remember the refusal so later borrows skip the dead call.
        self:set("download_refused_at", os.time())
        Log.write("download blocked; falling back to on-device decode")
        self:decodeToEpub(card_id, title_id, book)
        return
    end
    if body then self:set("download_refused_at", nil) end -- direct downloads work (again)
    if not body then
        notify(T(_("Borrowed, but the download failed:\n%1\n\nYou can retry from “My Libby loans”. Details are in the log:\n%2"), err, Log.path or "?"))
        return
    end
    local is_acsm = Libby.EXTENSION[format] == "acsm"
    local dir = is_acsm and self:downloadDir() or self:bookDir()
    mkdirp(dir)
    local name = Match.mainTitle(book.title or "")
    if name == "" then name = book.title or "book" end
    if book.author then name = name .. " - " .. book.author end
    local path = string.format("%s/%s.%s", dir, Util.safeFilename(name), Libby.EXTENSION[format] or "bin")
    local f, ferr = io.open(path, "wb")
    if not f then
        notify(T(_("Couldn't save the file:\n%1"), tostring(ferr)))
        return
    end
    f:write(body)
    f:close()
    Log.write("saved:", path)
    refreshFileManager()

    if not is_acsm then
        self:recordDownload(card_id, title_id, path, "book")
        self:refreshLoansMenu()
        self:offerOpen(path, T(_("Saved to:\n%1"), path))
        return
    end
    self:recordDownload(card_id, title_id, path, "acsm")
    self:refreshLoansMenu()

    if not self:acsmPlugin() then
        if acsm_restart_needed or self:findAcsm() then
            notify(T(_("Saved the ACSM to:\n%1\n\nThe ACSM plugin is installed but not running. Restart KOReader (and enable it in Plugin management if needed), then tap the file to get the book."), path))
        else
            UIManager:show(ConfirmBox:new{
                text = T(_("Saved the ACSM to:\n%1\n\nInstall the ACSM plugin from GitHub? It turns ACSM files into EPUBs, so after a restart you can tap this file to get the book, and future loans convert automatically."), path),
                ok_text = _("Install"),
                cancel_text = _("Not now"),
                ok_callback = function() self:checkAcsmUpdate(true, true) end,
            })
        end
        return
    end
    if not self:get("convert_acsm", true) then
        notify(T(_("Saved the ACSM to:\n%1\n\nTap it in the file browser to get the book."), path))
        return
    end
    local book_path, info = self:finishAcsm(path)
    Trapper:clear()
    if not book_path then
        notify(T(_("The ACSM was saved, but converting it failed:\n%1\n\nThe ACSM is kept at:\n%2\nTap it in the file browser to try again."), info, path))
        return
    end
    self:recordDownload(card_id, title_id, book_path, "book")
    self:refreshLoansMenu()
    refreshFileManager()
    self:offerOpen(book_path, T(_("Your book is ready:\n%1"), book_path) .. info)
end

--- Build the EPUB on the device by decoding the loan — the fallback for when
-- Libby refuses this client the ACSM download. Opens the loan for reading (the
-- Libby web reader's own endpoint, which isn't refused), then decodes the pages
-- and images and assembles an EPUB, with a Stop button throughout. The finished
-- book lands in the book folder, ready to open — no ACSM, no Adobe, no ACSM plugin.
function GoodreadsLibby:decodeToEpub(card_or_id, title_id, book)
    book = book or {}
    -- Accept a full normalized card, or a card id to resolve against saved cards.
    local card = type(card_or_id) == "table" and card_or_id or nil
    local card_id = tostring(card and card.card_id or card_or_id)
    if not (card and card.website_id) then
        for _i, c in ipairs(self:cards()) do
            if tostring(c.card_id) == card_id then card = c; break end
        end
    end
    if not (card and card.website_id) then
        notify(_("Couldn't find the library card for this loan. Refresh your library cards and try again."))
        return
    end
    local loan
    for _i, l in ipairs(self._loans or {}) do
        if tostring(l.id) == tostring(title_id) and tostring(l.card_id) == card_id then loan = l; break end
    end
    loan = loan or { id = tostring(title_id), card_id = card_id, type = "ebook", title = book.title }

    Trapper:info(_("Opening the loan for reading…"))
    local passport, oerr = self.libby:open(card, loan)
    Trapper:clear()
    if not passport then
        Log.write("decode: open failed:", tostring(oerr))
        notify(T(_("Couldn't open the loan for reading:\n%1\n\nYou can still get it the manual way. Details are in the log:\n%2"),
            tostring(oerr), Log.path or "?"))
        self:showManualAcsmHelp(book.title or loan.title)
        return
    end

    mkdirp(self:bookDir())
    local name = Match.mainTitle(book.title or loan.title or "")
    if name == "" then name = book.title or loan.title or "book" end
    if book.author then name = name .. " - " .. book.author end
    local epub_path = uniquePath(self:bookDir(), Util.safeFilename(name) .. ".epub")

    local builder = Openbook.newBuilder(passport, epub_path, {
        title = book.title or loan.title, author = book.author, title_id = title_id,
    })
    local result = {}
    self:runSteps{
        text = _("Building your book…"),
        step = function(emit) return builder:step(emit) end,
        on_message = function(msg)
            if msg.part then result.part = msg.part end
            if msg.done then result.done = msg.done end
            if msg.err then result.err = msg.err end
            if msg.stage == "pages" then
                return T(_("Building your book…\nDecoding page %1 of %2"), msg.i, msg.n)
            elseif msg.stage == "assets" then
                return T(_("Building your book…\nFetching image %1 of %2"), msg.i, msg.n)
            end
        end,
        on_done = function(stopped)
            if stopped then
                if result.part then os.remove(result.part) end
                notify(_("Stopped. The partly-built book was discarded."))
                return
            end
            if result.done then
                self:recordDownload(card_id, title_id, result.done, "book")
                self:refreshLoansMenu()
                refreshFileManager()
                self:offerOpen(result.done, T(_("Your book is ready:\n%1"), result.done))
            else
                self:showManualAcsmHelp(book.title or loan.title, result.err)
            end
        end,
    }
end

--- Turn one .acsm into a book with the ACSM plugin, move the book to the
-- book folder and (if set) delete the .acsm. Runs inside a task.
-- Returns book path and a note for the user, or nil and an error.
function GoodreadsLibby:finishAcsm(path)
    local book_path, cerr = self:convertAcsm(path)
    Log.write("ACSM plugin:", book_path and ("made " .. book_path) or ("failed: " .. tostring(cerr)))
    if not book_path then return nil, cerr end
    -- The ACSM plugin writes next to the .acsm; move the book to the book folder.
    local moved, merr = moveFile(book_path, self:bookDir())
    if moved then
        if moved ~= book_path then Log.write("moved book to", moved) end
        book_path = moved
    else
        Log.write("couldn't move book:", merr)
    end
    local note = ""
    if self:get("delete_acsm", true) and os.remove(path) then
        note = "\n\n" .. _("The .acsm file was deleted.")
    end
    return book_path, note
end

--- When Libby won't hand this plugin the ACSM: offer to build the book on the
-- device, or explain how to get the ACSM from the app. `note`, if given (e.g. the
-- reason the on-device build just failed), is shown at the top.
function GoodreadsLibby:showManualAcsmHelp(title, note)
    local header = note and (note .. "\n\n") or ""
    local dialog
    dialog = ButtonDialog:new{
        title = header .. T(_("Libby refused to let this plugin download the ACSM for “%1” (it accepts borrowing, but its download link only works in Libby's own app).\n\nThis plugin can build the EPUB on the device by decoding the loan the way the Libby web reader does — try “Build EPUB on device” in My Libby loans.\n\nOr get the ACSM from Libby instead:\n1. In the Libby app or libbyapp.com: Shelf → this loan → Manage Loan → Download EPUB (with DRM). That gives you the .acsm file.\n2. Copy the .acsm to this device, into:\n%2\n3. Here: Goodreads → Libby → Convert .acsm files. The EPUB goes to\n%3\nand the .acsm is deleted."),
            title or _("this book"), self:downloadDir(), self:bookDir()),
        title_align = "left",
        buttons = {
            { { text = _("Convert .acsm files now"), callback = function()
                UIManager:close(dialog)
                self:convertAcsmFolder()
            end } },
            { { text = _("Close"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

--- .acsm files waiting in the .acsm folder.
function GoodreadsLibby:pendingAcsmFiles()
    local dir = self:downloadDir()
    local files = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return files end
    for name in lfs.dir(dir) do
        if name:lower():match("%.acsm$") then files[#files + 1] = dir .. "/" .. name end
    end
    table.sort(files)
    return files
end

--- Match an .acsm to one of your loans by title, so My Libby loans can show
-- it as downloaded.
function GoodreadsLibby:loanForAcsm(path)
    local acsm = self:acsmPlugin()
    local meta = acsm and type(acsm.parseAcsmMetadata) == "function" and acsm:parseAcsmMetadata(path)
    local title = type(meta) == "table" and Util.str(meta.title)
    if not title then return nil end
    local want = Match.normalize(Match.mainTitle(title))
    for _i, loan in ipairs(self._loans or {}) do
        if Match.normalize(Match.mainTitle(loan.title)) == want then return loan end
    end
    return nil
end

--- Convert every .acsm in the .acsm folder (e.g. ones you downloaded in the
-- Libby app and copied over): book to the book folder, .acsm deleted.
function GoodreadsLibby:convertAcsmFolder()
    local files = self:pendingAcsmFiles()
    if #files == 0 then
        notify(T(_("No .acsm files in\n%1\n\nCopy the .acsm you downloaded in Libby there, then try again."), self:downloadDir()))
        return
    end
    if not self:acsmPlugin() then
        if acsm_restart_needed or self:findAcsm() then
            notify(_("The ACSM plugin is installed but not running. Restart KOReader (and enable it in Plugin management if needed), then try again."))
        else
            UIManager:show(ConfirmBox:new{
                text = _("Converting .acsm files needs the ACSM plugin. Install it from GitHub now?"),
                ok_text = _("Install"),
                ok_callback = function() self:checkAcsmUpdate(true, true) end,
            })
        end
        return
    end
    self:whenOnline(function()
        self:task(function()
            local done, lines = 0, {}
            for i, path in ipairs(files) do
                local name = path:match("([^/]+)$")
                Trapper:info(T(_("Converting %1 of %2…\n%3"), i, #files, name))
                local loan = self:loanForAcsm(path)
                local book_path, info = self:finishAcsm(path)
                if book_path then
                    done = done + 1
                    lines[#lines + 1] = "✓ " .. book_path:match("([^/]+)$")
                    if loan then self:recordDownload(loan.card_id, loan.id, book_path, "book") end
                else
                    lines[#lines + 1] = T("%1: %2", name, tostring(info))
                end
            end
            Trapper:clear()
            refreshFileManager()
            self:refreshLoansMenu()
            notify(T(_("Converted %1 of %2 .acsm file(s):\n%3\n\nBooks are in:\n%4"),
                done, #files, table.concat(lines, "\n"), self:bookDir()))
        end)
    end)
end

function GoodreadsLibby:openBook(path)
    self:closeAll()
    if self.ui and self.ui.document and self.ui.switchDocument then
        self.ui:switchDocument(path)
    else
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end
end

function GoodreadsLibby:offerOpen(path, text)
    UIManager:show(ConfirmBox:new{
        text = text .. "\n\n" .. _("Open it now?"),
        ok_text = _("Open"),
        cancel_text = _("Close"),
        ok_callback = function() self:openBook(path) end,
    })
end

--------------------------------------------------------------------------------
-- ACSM plugin integration (https://github.com/kaikozlov/acsm.koplugin)
--------------------------------------------------------------------------------

--- The running ACSM plugin instance, if it is installed and enabled.
function GoodreadsLibby:acsmPlugin()
    local p = self.ui and self.ui.acsm
    if type(p) == "table" and type(p.fulfillLoan) == "function" then return p end
    return nil
end

--- Turn an .acsm into the DRM-free EPUB/PDF with the ACSM plugin. Runs inside
-- a task. Returns the book's path, or nil and an error message.
function GoodreadsLibby:convertAcsm(acsm_path)
    local acsm = self:acsmPlugin()
    if not acsm then return nil, _("The ACSM plugin isn't installed.") end
    if type(acsm.loadSettings) == "function" then acsm:loadSettings() end
    local meta
    if type(acsm.parseAcsmMetadata) == "function" then meta = acsm:parseAcsmMetadata(acsm_path) end
    -- The ACSM plugin reserves the output name up front; remember whether it
    -- was there before so a failed run doesn't leave an empty file behind.
    local desired
    if type(acsm.deriveOutputPath) == "function" then desired = acsm:deriveOutputPath(acsm_path, meta) end
    local existed = desired and lfs.attributes(desired, "mode") ~= nil

    Trapper:info(_("Getting your book with the ACSM plugin…"))
    local ok, result, err = pcall(acsm.fulfillLoan, acsm, acsm_path, meta)
    if ok and type(result) == "table" and type(result.outputPath) == "string"
        and (lfs.attributes(result.outputPath, "size") or 0) > 0 then
        return result.outputPath
    end
    if desired and not existed and lfs.attributes(desired, "size") == 0 then
        os.remove(desired)
    end
    if not ok then return nil, tostring(result) end
    return nil, tostring(err or _("unknown error")):gsub("^.-: ", "")
end

--- Folders KOReader loads plugins from, this plugin's own folder first.
function GoodreadsLibby:pluginRoots()
    local roots, seen = {}, {}
    local function add(dir)
        if type(dir) ~= "string" or dir == "" then return end
        dir = dir:gsub("/+$", "")
        if not seen[dir] and lfs.attributes(dir, "mode") == "directory" then
            seen[dir] = true
            roots[#roots + 1] = dir
        end
    end
    if self.path then add(self.path:gsub("/+$", ""):match("^(.+)/[^/]+$")) end
    add(DataStorage:getDataDir() .. "/plugins")
    local extra = G_reader_settings and G_reader_settings:readSetting("extra_plugin_paths")
    if type(extra) == "table" then
        for _i, d in ipairs(extra) do add(d) end
    else
        add(extra)
    end
    -- KOReader's own (bundled) plugins folder.
    local ok, cwd = pcall(lfs.currentdir)
    if ok and cwd then add(cwd .. "/plugins") end
    return roots
end

--- The installed ACSM plugin, however it was installed (by hand, by a plugin
-- manager, from git, by us), enabled or not.
-- Returns { dir, version (may be nil), running, git } or nil.
function GoodreadsLibby:findAcsm()
    local function describe_install(dir, running)
        return {
            dir = dir,
            version = Update.installedVersion(dir),
            running = running,
            git = lfs.attributes(dir .. "/.git", "mode") ~= nil,
        }
    end
    local running = self:acsmPlugin()
    if running and type(running.path) == "string" then
        return describe_install((running.path:gsub("/+$", "")), true)
    end
    for _i, root in ipairs(self:pluginRoots()) do
        local names = {}
        for name in lfs.dir(root) do
            if name:match("%.koplugin$") then names[#names + 1] = name end
        end
        table.sort(names)
        for _j, name in ipairs(names) do
            local dir = root .. "/" .. name
            if Update.pluginName(dir) == "acsm" then
                return describe_install(dir, running ~= nil)
            end
        end
    end
    return nil
end

--- Where a fresh install goes: next to this plugin.
function GoodreadsLibby:acsmInstallDir()
    local plugins = self.path and self.path:gsub("/+$", ""):match("^(.+)/[^/]+$")
    return (plugins or (DataStorage:getDataDir() .. "/plugins")) .. "/acsm.koplugin"
end

function GoodreadsLibby:acsmDir()
    local inst = self:findAcsm()
    return inst and inst.dir or self:acsmInstallDir()
end

function GoodreadsLibby:acsmVersion()
    local inst = self:findAcsm()
    return inst and inst.version or nil
end

function GoodreadsLibby:acsmStatusText()
    local inst = self:findAcsm()
    if not inst then return _("not installed") end
    local version = inst.version or _("unknown version")
    if acsm_restart_needed then return T(_("%1, restart needed"), version) end
    if inst.git then return T(_("%1, git checkout"), version) end
    if not inst.running then return T(_("%1, not enabled"), version) end
    return version
end

function GoodreadsLibby:scheduleAcsmUpdateCheck()
    if acsm_update_checked or not self:get("acsm_auto_check", true) then return end
    -- Only keep a known-version, non-git install current; installing is
    -- always your call.
    local inst = self:findAcsm()
    if not inst or not inst.version or inst.git then return end
    local last = tonumber(self:get("acsm_last_check")) or 0
    if os.time() - last < UPDATE_CHECK_INTERVAL then return end
    acsm_update_checked = true
    UIManager:scheduleIn(20, function()
        -- Never turn Wi-Fi on just for this: only check if already online.
        local ok, online = pcall(function() return NetworkMgr:isOnline() end)
        if ok and online then self:checkAcsmUpdate(false) end
    end)
end

--- Look for a newer ACSM plugin release on GitHub (or install it if missing).
-- An existing install is always found first and updated in place; it is
-- never duplicated, and never replaced unless GitHub has a newer version.
-- manual: a tap from the menu (shows progress and "up to date");
-- confirmed: the user already agreed to install, don't ask again.
function GoodreadsLibby:checkAcsmUpdate(manual, confirmed)
    local inst = self:findAcsm()
    if inst and inst.git then
        if manual then
            notify(T(_("The ACSM plugin at\n%1\nis a git checkout, so it's left alone. Update it with git pull."), inst.dir))
        end
        return
    end
    if not inst and lfs.attributes(self:acsmInstallDir(), "mode") then
        if manual or confirmed then
            notify(T(_("%1 already exists but isn't the ACSM plugin, so it was left alone. Move or rename it to install the ACSM plugin from here."), self:acsmInstallDir()))
        end
        return
    end
    local function run()
        self:task(function()
            if manual then Trapper:info(_("Checking GitHub for the ACSM plugin…")) end
            local info, err = Update.latest(ACSM_REPO, "acsm")
            Trapper:clear()
            if not info then
                if manual then notify(T(_("Couldn't reach GitHub:\n%1"), err)) end
                return
            end
            self:set("acsm_last_check", os.time())
            if inst and inst.version and not Update.isNewer(info.version, inst.version) then
                if manual then notify(T(_("The ACSM plugin is up to date (%1)."), inst.version), 3) end
                return
            end
            if inst and not inst.version and not manual then return end
            if (confirmed and not inst)
                or (inst and inst.version and not manual and self:get("acsm_auto_install", false)) then
                self:installAcsm(info, inst)
                return
            end
            local text
            if inst and inst.version then
                local notes = info.notes and Util.trim((info.notes:gsub("\r", ""))) or ""
                if notes ~= "" then notes = "\n\n" .. Util.shorten(notes, 500) end
                text = T(_("ACSM plugin %1 is available (you have %2 in %3).%4\n\nUpdate it now?"),
                    info.version, inst.version, inst.dir, notes)
            elseif inst then
                text = T(_("An ACSM plugin is installed in\n%1\nbut its version can't be read.\n\nReplace it with %2 from GitHub?"),
                    inst.dir, info.version)
            else
                text = T(_("Install the ACSM plugin %1 from GitHub into\n%2?\n\nIt turns borrowed ACSM files into EPUBs right on this device.\n\n%3"),
                    info.version, self:acsmInstallDir(), ACSM_PLUGIN_URL)
            end
            UIManager:show(ConfirmBox:new{
                text = text,
                ok_text = inst and (inst.version and _("Update") or _("Replace")) or _("Install"),
                ok_callback = function()
                    self:whenOnline(function()
                        self:task(function() self:installAcsm(info, inst) end)
                    end)
                end,
            })
        end)
    end
    if manual then self:whenOnline(run) else run() end
end

--- Install `info` over the existing install `inst` (same folder), or fresh
-- next to this plugin. Runs inside a task.
function GoodreadsLibby:installAcsm(info, inst)
    local target = inst and inst.dir or self:acsmInstallDir()
    Trapper:info(T(inst and _("Updating the ACSM plugin to %1…") or _("Installing the ACSM plugin %1…"),
        info.version))
    local ok, err = Update.install(info, target, DataStorage:getDataDir() .. "/cache", { name = "acsm" })
    Trapper:clear()
    if not ok then
        notify(T(_("Couldn't install the ACSM plugin:\n%1\n\nNothing was changed."), err))
        return
    end
    acsm_restart_needed = true
    local text = T(_("ACSM plugin %1 is installed in\n%2\nRestart KOReader to start using it."), info.version, target)
    if UIManager.askForRestart then
        UIManager:askForRestart(text)
    else
        notify(text)
    end
end

--------------------------------------------------------------------------------
-- Updating this plugin itself, from its GitHub releases
--------------------------------------------------------------------------------

-- This plugin's own update source. A release's .zip asset is used when present,
-- otherwise GitHub's source zip. Override per-device with the "self_repo" setting.
local SELF_REPO = "alexnguyen96/grlibby"
-- The self-update check runs at most once per KOReader session.
local self_update_checked = false
-- Set once a newer version was installed; KOReader must restart to load it.
local self_restart_needed = false

function GoodreadsLibby:selfRepo()
    local r = self:get("self_repo")
    if type(r) == "string" and Update.validRepo(r) then return r end
    return SELF_REPO
end

--- This plugin's own folder.
function GoodreadsLibby:pluginDir()
    return self.path and self.path:gsub("/+$", "")
        or (DataStorage:getDataDir() .. "/plugins/goodreadslibby.koplugin")
end

--- The version in this plugin's own _meta.lua ("?" if it can't be read).
function GoodreadsLibby:selfVersion()
    return Update.installedVersion(self:pluginDir()) or "?"
end

function GoodreadsLibby:pluginStatusText()
    if self_restart_needed then return T(_("%1, restart needed"), self:selfVersion()) end
    return self:selfVersion()
end

--- Once a day, when already online, quietly look for a newer release.
function GoodreadsLibby:scheduleSelfUpdateCheck()
    if self_update_checked or not self:get("self_auto_check", true) then return end
    if self:selfVersion() == "?" then return end -- no version to compare against
    local last = tonumber(self:get("self_last_check")) or 0
    if os.time() - last < UPDATE_CHECK_INTERVAL then return end
    self_update_checked = true
    UIManager:scheduleIn(25, function()
        -- Never turn Wi-Fi on just for this: only check if already online.
        local ok, online = pcall(function() return NetworkMgr:isOnline() end)
        if ok and online then self:checkSelfUpdate(false) end
    end)
end

--- Look for a newer release of this plugin and offer (or auto-install) it.
-- manual: a tap from the menu (shows progress and an "up to date" note).
function GoodreadsLibby:checkSelfUpdate(manual)
    local function run()
        self:task(function()
            if manual then Trapper:info(_("Checking GitHub for a plugin update…")) end
            local info, err = Update.latest(self:selfRepo(), "goodreadslibby")
            Trapper:clear()
            if not info then
                if manual then notify(T(_("Couldn't reach GitHub:\n%1"), err)) end
                return
            end
            self:set("self_last_check", os.time())
            local current = self:selfVersion()
            if current ~= "?" and not Update.isNewer(info.version, current) then
                if manual then notify(T(_("The plugin is up to date (%1)."), current), 3) end
                return
            end
            if not manual and self:get("self_auto_install", false) then
                self:installSelf(info)
                return
            end
            local notes = info.notes and Util.trim((info.notes:gsub("\r", ""))) or ""
            if notes ~= "" then notes = "\n\n" .. Util.shorten(notes, 500) end
            UIManager:show(ConfirmBox:new{
                text = T(_("Goodreads → Libby %1 is available (you have %2).%3\n\nUpdate now? KOReader will ask to restart afterwards."),
                    info.version, current, notes),
                ok_text = _("Update"),
                ok_callback = function()
                    self:whenOnline(function()
                        self:task(function() self:installSelf(info) end)
                    end)
                end,
            })
        end)
    end
    if manual then self:whenOnline(run) else run() end
end

--- Download and install `info` over this plugin's own folder (keeping your
-- goodreads.txt and log). Runs inside a task.
function GoodreadsLibby:installSelf(info)
    Trapper:info(T(_("Updating Goodreads → Libby to %1…"), info.version))
    local ok, err = Update.install(info, self:pluginDir(), DataStorage:getDataDir() .. "/cache", {
        name = "goodreadslibby",
        preserve = { "goodreads.txt", "goodreadslibby.log", "goodreadslibby.log.1" },
    })
    Trapper:clear()
    if not ok then
        notify(T(_("Couldn't update the plugin:\n%1\n\nNothing was changed."), err))
        return
    end
    self_restart_needed = true
    Log.write("self-update: installed", info.version, "into", self:pluginDir())
    local text = T(_("Goodreads → Libby %1 is installed.\nRestart KOReader to start using it."), info.version)
    if UIManager.askForRestart then UIManager:askForRestart(text) else notify(text) end
end

function GoodreadsLibby:pluginUpdateMenu()
    return {
        {
            text = _("Check for plugin update now"),
            callback = function() self:checkSelfUpdate(true) end,
        },
        {
            text = _("Check for updates automatically"),
            help_text = _("Once a day, only when the device is already online."),
            checked_func = function() return self:get("self_auto_check", true) end,
            callback = function() self:set("self_auto_check", not self:get("self_auto_check", true)) end,
        },
        {
            text = _("Install updates automatically"),
            help_text = _("Install new releases without asking first. KOReader then asks to restart."),
            enabled_func = function() return self:get("self_auto_check", true) end,
            checked_func = function() return self:get("self_auto_install", false) end,
            callback = function() self:set("self_auto_install", not self:get("self_auto_install", false)) end,
            separator = true,
        },
        {
            text_func = function() return T(_("Update source: %1"), self:selfRepo()) end,
            help_text = _("The GitHub repository (owner/name) to fetch releases from. Change it only to use a fork."),
            keep_menu_open = true,
            callback = function(touchmenu) self:editSelfRepo(touchmenu) end,
        },
    }
end

function GoodreadsLibby:editSelfRepo(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title = _("Update source (GitHub owner/repo)"),
        input = self:selfRepo(),
        input_hint = SELF_REPO,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Use default"), callback = function()
                self:set("self_repo", nil)
                UIManager:close(dialog)
                if touchmenu then touchmenu:updateItems() end
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = Util.trim(dialog:getInputText())
                if v ~= "" and not Update.validRepo(v) then
                    notify(_("That isn't a valid GitHub owner/repo."))
                    return
                end
                self:set("self_repo", v == "" and nil or v)
                UIManager:close(dialog)
                if touchmenu then touchmenu:updateItems() end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoodreadsLibby:troubleshootingMenu()
    return {
        {
            text = _("Test Libby connection"),
            enabled_func = function() return self:get("libby_identity") ~= nil end,
            callback = function()
                self:whenOnline(function()
                    self:task(function()
                        Trapper:info(_("Testing the Libby connection…"))
                        local lines, data = self.libby:diagnose()
                        Trapper:clear()
                        if data then self:saveCards(data.cards) end
                        notify(table.concat(lines, "\n") .. "\n\n" .. T(_("Written to the log:\n%1"), Log.path or "?"))
                    end)
                end)
            end,
        },
        {
            text_func = function() return T(_("Log file: %1"), Log.path or "?") end,
            keep_menu_open = true,
            callback = function()
                notify(T(_("Requests to Libby, errors and failed downloads are written to:\n%1\n\nTokens, RSS keys and setup codes are hidden. Copy this file over USB to share it."), Log.path or "?"))
            end,
        },
        {
            text = _("Clear the log"),
            keep_menu_open = true,
            callback = function()
                if Log.path then
                    os.remove(Log.path)
                    os.remove(Log.path .. ".1")
                end
                notify(_("Log cleared."), 2)
            end,
        },
        {
            text = _("Check goodreads.txt"),
            keep_menu_open = true,
            callback = function() self:showConfigProblems() end,
        },
    }
end

function GoodreadsLibby:acsmMenu()
    return {
        {
            text_func = function()
                return self:findAcsm() and _("Check for ACSM plugin update")
                    or _("Install ACSM plugin from GitHub")
            end,
            callback = function() self:checkAcsmUpdate(true) end,
        },
        {
            text = _("Check for updates automatically"),
            help_text = _("Once a day, only when the device is already online."),
            checked_func = function() return self:get("acsm_auto_check", true) end,
            callback = function() self:set("acsm_auto_check", not self:get("acsm_auto_check", true)) end,
        },
        {
            text = _("Install updates automatically"),
            help_text = _("Install new ACSM plugin releases without asking first. KOReader then asks to restart."),
            enabled_func = function() return self:get("acsm_auto_check", true) end,
            checked_func = function() return self:get("acsm_auto_install", false) end,
            callback = function() self:set("acsm_auto_install", not self:get("acsm_auto_install", false)) end,
            separator = true,
        },
        {
            text = _("Turn ACSM into EPUB automatically"),
            help_text = _("After borrowing, hand the ACSM to the ACSM plugin so the book arrives as a readable EPUB/PDF."),
            checked_func = function() return self:get("convert_acsm", true) end,
            callback = function() self:set("convert_acsm", not self:get("convert_acsm", true)) end,
        },
        {
            text = _("Delete the .acsm after converting"),
            enabled_func = function() return self:get("convert_acsm", true) end,
            checked_func = function() return self:get("delete_acsm", true) end,
            callback = function() self:set("delete_acsm", not self:get("delete_acsm", true)) end,
        },
    }
end

--------------------------------------------------------------------------------
-- Loans
--------------------------------------------------------------------------------

local function shortDate(iso)
    local y, m, d = tostring(iso or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    return os.date("%b %d", os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

function GoodreadsLibby:loanItems()
    local cards_by_id = {}
    for _i, c in ipairs(self:cards()) do cards_by_id[c.card_id] = c end
    local items = {}
    for _i, loan in ipairs(self._loans or {}) do
        if loan.type == nil or loan.type == "ebook" then
            local card = cards_by_id[loan.card_id]
            local dl = self:downloadFor(loan.card_id, loan.id)
            local parts = {}
            if dl then
                parts[#parts + 1] = dl.kind == "book" and _("on device") or _("ACSM saved")
            end
            local due = shortDate(loan.expires)
            if due then parts[#parts + 1] = T(_("due %1"), due) end
            items[#items + 1] = {
                text = loan.author and T("%1 — %2", loan.title, loan.author) or loan.title,
                mandatory = #parts > 0 and table.concat(parts, " · ") or nil,
                loan = loan,
                library = card and card.library_name,
            }
        end
    end
    if #items == 0 then
        items[1] = { text = _("No ebook loans."), select_enabled = false }
    end
    return items, T(_("My Libby loans (%1)"), #(self._loans or {}))
end

function GoodreadsLibby:refreshLoansMenu()
    if self.loans_menu and self._loans then
        local items, title = self:loanItems()
        self.loans_menu:switchItemTable(title, items, -1)
    end
end

function GoodreadsLibby:showLoans()
    if not self:isLinked() then
        self:linkLibby()
        return
    end
    self:whenOnline(function()
        self:task(function()
            Trapper:info(_("Fetching your Libby loans…"))
            local data, err = self.libby:sync()
            Trapper:clear()
            if not data then
                notify(T(_("Couldn't reach Libby:\n%1"), err))
                return
            end
            self:saveCards(data.cards)
            self._loans = {}
            for _i, raw in ipairs(data.loans) do
                self._loans[#self._loans + 1] = Libby.normalizeLoan(raw)
            end
            local items, title = self:loanItems()
            if self.loans_menu then UIManager:close(self.loans_menu) end
            local menu
            menu = Menu:new{
                title = title,
                item_table = items,
                covers_fullscreen = true,
                is_borderless = true,
                is_popout = false,
                title_bar_left_icon = "appbar.settings",
                onLeftButtonTap = function() self:showSettings() end,
                onMenuSelect = function(_menu, item)
                    if item.loan then self:loanActions(item.loan, item.library) end
                    return true
                end,
                close_callback = function()
                    UIManager:close(menu)
                    if self.loans_menu == menu then self.loans_menu = nil end
                end,
            }
            self.loans_menu = menu
            UIManager:show(menu)
        end)
    end)
end

function GoodreadsLibby:returnLoan(loan, delete_file)
    self:whenOnline(function()
        self:task(function()
            Trapper:info(_("Returning…"))
            local ok, err = self.libby:returnLoan(loan.card_id, loan.id)
            Trapper:clear()
            Log.write("return:", loan.title, ok and "ok" or ("failed: " .. tostring(err)))
            if not ok then
                notify(T(_("Couldn't return it:\n%1"), err))
                return
            end
            local note = ""
            local dl = self:downloadFor(loan.card_id, loan.id)
            if delete_file and dl and os.remove(dl.path) then
                note = "\n" .. _("The downloaded file was deleted.")
                refreshFileManager()
            end
            self:forgetDownload(loan.card_id, loan.id)
            for i, l in ipairs(self._loans or {}) do
                if l.id == loan.id and l.card_id == loan.card_id then
                    table.remove(self._loans, i)
                    break
                end
            end
            self:refreshLoansMenu()
            notify(_("Returned.") .. note, 2)
        end)
    end)
end

function GoodreadsLibby:loanActions(loan, library)
    local dialog
    local buttons = {}
    local book = { title = loan.title, author = loan.author }
    local dl = self:downloadFor(loan.card_id, loan.id)
    local function close_then(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end

    local lines = { loan.title }
    if loan.author then lines[#lines + 1] = T(_("by %1"), loan.author) end
    if library then lines[#lines + 1] = library end
    local due = shortDate(loan.expires)
    if due then lines[#lines + 1] = T(_("Due %1"), due) end
    lines[#lines + 1] = ""
    if dl then
        lines[#lines + 1] = T(dl.kind == "book" and _("On this device:\n%1") or _("ACSM saved (not converted yet):\n%1"), dl.path)
    else
        lines[#lines + 1] = _("Not downloaded to this device yet.")
    end

    -- A loan locked to another format (e.g. after "Read with Kindle") can
    -- only be downloaded in that format.
    local formats = loan.formats
    if loan.locked then
        if Libby.EXTENSION[loan.locked] then
            formats = { loan.locked }
        else
            formats = {}
            lines[#lines + 1] = T(_("This loan is locked to %1, so it can't be downloaded as EPUB."),
                FORMAT_LABEL[loan.locked] or loan.locked)
        end
    end

    if dl and dl.kind == "book" then
        buttons[#buttons + 1] = { { text = _("Open book"), callback = close_then(function() self:openBook(dl.path) end) } }
    elseif self:get("download_refused_at") then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Libby won't let this plugin download the ACSM. This plugin can build the EPUB on the device instead, or you can get the ACSM in the Libby app (Manage Loan → Download EPUB), copy it to the .acsm folder, and use Convert .acsm files.")
        buttons[#buttons + 1] = { { text = _("Build EPUB on device"), callback = close_then(function()
            self:whenOnline(function()
                self:task(function() self:decodeToEpub(loan.card_id, loan.id, book) end)
            end)
        end) } }
        buttons[#buttons + 1] = { { text = _("Convert .acsm files"), callback = close_then(function() self:convertAcsmFolder() end) } }
        buttons[#buttons + 1] = { { text = _("How to get the ACSM"), callback = close_then(function() self:showManualAcsmHelp(loan.title) end) } }
    end
    local downloadable = false
    for _i, f in ipairs(formats) do
        if Libby.EXTENSION[f] then
            downloadable = true
            buttons[#buttons + 1] = { {
                text = T(dl and _("Download again: %1") or _("Download %1"), FORMAT_LABEL[f] or f),
                callback = close_then(function()
                    self:whenOnline(function()
                        self:task(function() self:downloadLoan(loan.card_id, loan.id, loan.formats, book, f) end)
                    end)
                end),
            } }
        end
    end
    if not downloadable and not loan.locked then
        lines[#lines + 1] = _("No downloadable format: read it in Libby.")
    end
    buttons[#buttons + 1] = { {
        text = _("Return early"),
        callback = close_then(function()
            UIManager:show(ConfirmBox:new{
                text = T(_("Return “%1” now?"), loan.title),
                ok_text = _("Return"),
                ok_callback = function() self:returnLoan(loan, false) end,
            })
        end),
    } }
    if dl then
        buttons[#buttons + 1] = { {
            text = _("Return and delete the file"),
            callback = close_then(function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Return “%1” now and delete\n%2?"), loan.title, dl.path),
                    ok_text = _("Return + delete"),
                    ok_callback = function() self:returnLoan(loan, true) end,
                })
            end),
        } }
    end
    buttons[#buttons + 1] = { { text = _("Close"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = table.concat(lines, "\n"), title_align = "left", buttons = buttons }
    UIManager:show(dialog)
end

--------------------------------------------------------------------------------
-- Settings: Goodreads, Libby, libraries, downloads
--------------------------------------------------------------------------------

local ACCOUNT_FILE = "goodreads.txt"

local function readSmallFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read(64 * 1024)
    f:close()
    return data
end

--- goodreads.txt lives in the plugin folder, next to main.lua.
function GoodreadsLibby:accountFilePath()
    local dir = self.path or (DataStorage:getDataDir() .. "/plugins/goodreadslibby.koplugin")
    return (dir:gsub("/+$", "")) .. "/" .. ACCOUNT_FILE
end

--- goodreads.txt, parsed: { account, shelves, errors, … } (nil if missing).
function GoodreadsLibby:fileConfig()
    local text = readSmallFile(self:accountFilePath())
    if not text then return nil end
    local cfg = Goodreads.parseConfig(text)
    if #cfg.errors > 0 and text ~= self._logged_config then
        self._logged_config = text
        for _i, e in ipairs(cfg.errors) do Log.write("goodreads.txt:", e) end
    end
    return cfg
end

--- Edit goodreads.txt: mutate(cfg) changes the parsed file, which is written
-- back with its comment lines kept.
function GoodreadsLibby:writeConfig(mutate)
    local path = self:accountFilePath()
    local text = readSmallFile(path) or ""
    local cfg = Goodreads.parseConfig(text)
    mutate(cfg)
    local f = io.open(path, "wb")
    if not f then
        Log.write("goodreads.txt: can't write", path)
        return false
    end
    f:write(Goodreads.formatConfig(cfg, text))
    f:close()
    return true
end

function GoodreadsLibby:saveAccount(acc, touchmenu, on_done)
    self:set("goodreads_account", acc)
    self:writeConfig(function(cfg)
        cfg.profile_raw = Goodreads.accountString(acc)
        cfg.has_profile_line = true
        cfg.account = acc
    end)
    self.cache:saveSetting("shelves", {})
    self.cache:flush()
    if touchmenu then touchmenu:updateItems() end
    notify(T(_("Goodreads account saved: %1%2"), acc.id, acc.key and _(" (private feed)") or ""), 3)
    if on_done then on_done() end
end

function GoodreadsLibby:showConfigProblems()
    local cfg = self:fileConfig()
    if not cfg or #cfg.errors == 0 then
        notify(_("goodreads.txt looks fine."), 2)
        return
    end
    notify(T(_("These lines in goodreads.txt were skipped:\n\n%1\n\nEach shelf line should look like:\nnickname = shelf RSS link\n\nFile: %2"),
        table.concat(cfg.errors, "\n"), self:accountFilePath()))
end

function GoodreadsLibby:importAccountFile(touchmenu, on_done)
    local PathChooser = require("ui/widget/pathchooser")
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if not home or lfs.attributes(home, "mode") ~= "directory" then home = DataStorage:getDataDir() end
    UIManager:show(PathChooser:new{
        select_directory = false,
        select_file = true,
        path = home,
        file_filter = function(filename)
            local ext = filename:match("%.([^.]+)$")
            return ext and (ext:lower() == "txt" or ext:lower() == "url" or ext:lower() == "html")
        end,
        onConfirm = function(path)
            local text = readSmallFile(path) or ""
            local cfg = Goodreads.parseConfig(text)
            local acc = cfg.account or Goodreads.parseAccount(text)
            if #cfg.shelves > 0 then
                -- A whole shelf list: it becomes goodreads.txt.
                local f = io.open(self:accountFilePath(), "wb")
                if f then
                    f:write(text)
                    f:close()
                end
                if touchmenu then touchmenu:updateItems() end
                notify(T(_("Imported %1 shelves from\n%2"), #cfg.shelves, path), 3)
                if on_done then on_done() end
            elseif acc then
                self:saveAccount(acc, touchmenu, on_done)
            else
                notify(T(_("No Goodreads link or user ID found in:\n%1"), path))
            end
        end,
    })
end

function GoodreadsLibby:editAccount(on_done, touchmenu)
    local current = self:account()
    local description = T(_("Easiest: on your computer, edit goodreads.txt in the plugin folder: one shelf per line as   nickname = shelf RSS link   (optional: profile = … and user id = …). It's read automatically:\n%1\n\nOr type your profile link / user ID here, or tap “From file” to pick another text file."), self:accountFilePath())
    local input = current and Goodreads.accountString(current) or ""
    local dialog
    dialog = InputDialog:new{
        title = _("Goodreads account"),
        description = description,
        input = input,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("From file…"),
                callback = function()
                    UIManager:close(dialog)
                    self:importAccountFile(touchmenu, on_done)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local acc = Goodreads.parseAccount(dialog:getInputText())
                    if not acc then
                        notify(_("That doesn't look like a Goodreads profile link, RSS link or user ID."))
                        return
                    end
                    UIManager:close(dialog)
                    self:saveAccount(acc, touchmenu, on_done)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoodreadsLibby:saveCards(raw_cards)
    if type(raw_cards) ~= "table" then return end
    local cards = {}
    for _i, c in ipairs(raw_cards) do
        local card = Libby.normalizeCard(c)
        if card.card_id and card.key then cards[#cards + 1] = card end
    end
    self:set("libby_cards", cards)
end

function GoodreadsLibby:linkLibby(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title = _("Link Libby"),
        description = _("On your phone, open Libby → Menu → Copy To Another Device → “Copy to …”. Libby shows an 8-digit setup code; type it here within a minute."),
        input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Link"),
                is_enter_default = true,
                callback = function()
                    local code = dialog:getInputText()
                    UIManager:close(dialog)
                    self:whenOnline(function()
                        self:task(function()
                            Trapper:info(_("Linking Libby…"))
                            local data, err = self.libby:cloneByCode(code)
                            Log.write("link Libby:", data and (#data.cards .. " card(s)") or ("failed: " .. tostring(err)))
                            Trapper:clear()
                            if not data then
                                notify(T(_("Couldn't link Libby:\n%1"), err))
                                return
                            end
                            self:saveCards(data.cards)
                            if touchmenu then touchmenu:updateItems() end
                            local names = {}
                            for _i, c in ipairs(self:cards()) do names[#names + 1] = "• " .. c.library_name end
                            if #names == 0 then
                                notify(_("Linked, but Libby has no library cards yet. Add a card in Libby, then use “Refresh library cards”."))
                            else
                                notify(T(_("Libby linked. Your libraries:\n%1"), table.concat(names, "\n")))
                            end
                        end)
                    end)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoodreadsLibby:refreshCards(touchmenu)
    self:whenOnline(function()
        self:task(function()
            Trapper:info(_("Refreshing library cards…"))
            local data, err = self.libby:sync()
            Trapper:clear()
            if not data then
                notify(T(_("Couldn't reach Libby:\n%1"), err))
                return
            end
            self:saveCards(data.cards)
            if touchmenu then touchmenu:updateItems() end
            notify(T(_("%1 library cards."), #self:cards()), 2)
        end)
    end)
end

function GoodreadsLibby:editExtraLibraries(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title = _("Extra libraries"),
        description = _("Libraries to check without a card (availability only). Use the library's Libby key, comma separated — it's the word after libbyapp.com/library/ (e.g. nypl, lapl)."),
        input = table.concat(self:get("extra_libraries", {}), ", "),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local keys = {}
                    for _i, k in ipairs(Util.splitList(dialog:getInputText())) do
                        keys[#keys + 1] = k:lower()
                    end
                    UIManager:close(dialog)
                    self:set("extra_libraries", keys)
                    if #keys == 0 then
                        if touchmenu then touchmenu:updateItems() end
                        return
                    end
                    -- Look the names up (and catch typos) while we're online.
                    self:whenOnline(function()
                        self:task(function()
                            local names, bad = self:get("extra_library_names", {}), {}
                            for _i, key in ipairs(keys) do
                                Trapper:info(T(_("Looking up %1…"), key))
                                local info = Libby.libraryInfo(key)
                                if info then names[key] = info.name else bad[#bad + 1] = key end
                            end
                            Trapper:clear()
                            self:set("extra_library_names", names)
                            if touchmenu then touchmenu:updateItems() end
                            if #bad > 0 then
                                notify(T(_("Unknown library key(s): %1"), table.concat(bad, ", ")))
                            end
                        end)
                    end)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoodreadsLibby:chooseDownloadDir(touchmenu, key)
    key = key or "download_dir"
    local PathChooser = require("ui/widget/pathchooser")
    local start = key == "book_dir" and self:bookDir() or self:downloadDir()
    if lfs.attributes(start, "mode") ~= "directory" then
        start = start:match("^(.+)/[^/]+$") or "/"
    end
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = start,
        onConfirm = function(path)
            self:set(key, path)
            if touchmenu then touchmenu:updateItems() end
        end,
    })
end

--------------------------------------------------------------------------------
-- Main menu
--------------------------------------------------------------------------------

function GoodreadsLibby:addToMainMenu(menu_items)
    menu_items.goodreads_libby = {
        text = _("Goodreads → Libby"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:menuTable() end,
    }
end

function GoodreadsLibby:menuTable()
    local items = {}
    local cfg = self:fileConfig()
    if cfg and #cfg.errors > 0 then
        items[#items + 1] = {
            text = T(_("goodreads.txt: %1 line(s) skipped (tap for details)"), #cfg.errors),
            callback = function() self:showConfigProblems() end,
            separator = true,
        }
    end
    for _i, entry in ipairs(self:shelfList()) do
        items[#items + 1] = {
            text = entry.name,
            callback = function() self:openShelf(entry) end,
        }
    end
    if #items > 0 then items[#items].separator = true end
    items[#items + 1] = {
        text = _("Manage shelves"),
        callback = function() self:manageShelves() end,
    }
    items[#items + 1] = {
        text = _("My Libby loans"),
        enabled_func = function() return self:isLinked() end,
        callback = function() self:showLoans() end,
    }
    items[#items + 1] = {
        text_func = function()
            local n = #self:pendingAcsmFiles()
            if n > 0 then return T(_("Convert .acsm files (%1 waiting)"), n) end
            return _("Convert .acsm files")
        end,
        callback = function() self:convertAcsmFolder() end,
        separator = true,
    }
    items[#items + 1] = {
        text = _("Settings"),
        sub_item_table = self:settingsTable(),
    }
    return items
end

--- Show menu items (the same tables as the KOReader menu: text/text_func,
-- checked_func, enabled_func, sub_item_table(_func), callback,
-- keep_menu_open) as a dialog, so settings are reachable from inside the
-- plugin's own lists. Close stays pinned above the items.
function GoodreadsLibby:showItemsDialog(items_src, title, back_text)
    local dialog
    local render
    -- Stands in for KOReader's menu: settings call updateItems() after a change.
    local fake_menu = { updateItems = function() render() end }
    local function rows()
        local items = type(items_src) == "function" and items_src() or items_src
        local out = {}
        for _i, item in ipairs(items) do
            local label = item.text_func and item.text_func() or item.text or ""
            local text = label
            if item.checked_func then text = (item.checked_func() and "✓ " or "    ") .. text end
            local sub = item.sub_item_table_func or item.sub_item_table
            if sub then text = text .. " ›" end
            local enabled = item.enabled ~= false
            if item.enabled_func then enabled = item.enabled_func() and true or false end
            out[#out + 1] = { {
                text = text,
                enabled = enabled,
                align = "left",
                callback = function()
                    if sub then
                        self:showItemsDialog(sub, label, _("Back"))
                    elseif item.callback then
                        if item.checked_func then
                            item.callback(fake_menu)
                            render()
                        elseif item.keep_menu_open then
                            item.callback(fake_menu)
                        else
                            UIManager:close(dialog)
                            item.callback(fake_menu)
                        end
                    end
                end,
            } }
        end
        return out
    end
    render = function()
        if dialog then UIManager:close(dialog) end
        local controls = { { text = back_text or _("Close"), callback = function() UIManager:close(dialog) end } }
        local buttons = rows()
        local pinned = ButtonDialog.addWidget ~= nil and ButtonDialog.getAddedWidgetAvailableWidth ~= nil
        if not pinned then table.insert(buttons, 1, controls) end
        dialog = ButtonDialog:new{ title = title, title_align = "center", buttons = buttons, width_factor = 0.95 }
        if pinned then
            local ButtonTable = require("ui/widget/buttontable")
            dialog:addWidget(ButtonTable:new{
                width = dialog:getAddedWidgetAvailableWidth(),
                buttons = { controls },
                show_parent = dialog,
            })
        end
        UIManager:show(dialog)
    end
    render()
end

function GoodreadsLibby:showSettings()
    self:showItemsDialog(function() return self:settingsTable() end, _("Goodreads → Libby settings"))
end

function GoodreadsLibby:settingsTable()
    local ttl_choices = {
        { _("1 hour"), 3600 }, { _("6 hours"), 6 * 3600 },
        { _("1 day"), 24 * 3600 }, { _("1 week"), 7 * 24 * 3600 },
        { _("Never (only when I tap “Check again”)"), -1 },
    }
    local ttl_items = {}
    for _i, c in ipairs(ttl_choices) do
        ttl_items[#ttl_items + 1] = {
            text = c[1],
            radio = true,
            checked_func = function() return (tonumber(self:get("avail_ttl")) or DEFAULT_AVAIL_TTL) == c[2] end,
            callback = function() self:set("avail_ttl", c[2]) end,
        }
    end

    return {
        {
            text_func = function()
                local acc = self:account()
                if not acc then return _("Goodreads account: not set") end
                return T(_("Goodreads account: %1%2"), acc.id, acc.key and _(" (private feed)") or "")
            end,
            keep_menu_open = true,
            callback = function(touchmenu) self:editAccount(nil, touchmenu) end,
        },
        {
            text = _("Manage shelves"),
            callback = function() self:manageShelves() end,
        },
        {
            text = _("Auto-refresh shelves when opening"),
            help_text = _("Reload a shelf from Goodreads each time you open it (when online). Otherwise the saved copy opens instantly; use “Refresh from Goodreads” in the shelf's menu to update it."),
            checked_func = function() return self:get("auto_refresh_shelf", false) end,
            callback = function() self:set("auto_refresh_shelf", not self:get("auto_refresh_shelf", false)) end,
            separator = true,
        },
        {
            text_func = function()
                if self:isLinked() then
                    return T(_("Libby: linked (%1 cards)"), #self:cards())
                end
                return _("Libby: link account…")
            end,
            sub_item_table_func = function()
                local sub = {
                    {
                        text = self:isLinked() and _("Re-link with a new setup code") or _("Link with setup code"),
                        keep_menu_open = true,
                        callback = function(touchmenu) self:linkLibby(touchmenu) end,
                    },
                }
                if self:get("libby_identity") then
                    sub[#sub + 1] = {
                        text = _("Refresh library cards"),
                        keep_menu_open = true,
                        callback = function(touchmenu) self:refreshCards(touchmenu) end,
                    }
                    sub[#sub + 1] = {
                        text = _("Unlink Libby from this device"),
                        keep_menu_open = true,
                        callback = function(touchmenu)
                            UIManager:show(ConfirmBox:new{
                                text = _("Forget the Libby login on this device? Your loans and holds are not affected."),
                                ok_text = _("Unlink"),
                                ok_callback = function()
                                    self:set("libby_identity", nil)
                                    self:set("libby_cards", nil)
                                    if touchmenu then touchmenu:updateItems() end
                                end,
                            })
                        end,
                    }
                end
                for _i, c in ipairs(self:cards()) do
                    sub[#sub + 1] = {
                        text = T("%1 (%2)", c.library_name, c.key),
                        enabled = false,
                    }
                end
                return sub
            end,
        },
        {
            text_func = function()
                local extra = self:get("extra_libraries", {})
                if #extra == 0 then return _("Extra libraries (no card): none") end
                return T(_("Extra libraries (no card): %1"), table.concat(extra, ", "))
            end,
            keep_menu_open = true,
            callback = function(touchmenu) self:editExtraLibraries(touchmenu) end,
            separator = true,
        },
        {
            text_func = function() return T(_("Folder for .acsm files: %1"), self:downloadDir()) end,
            keep_menu_open = true,
            callback = function(touchmenu) self:chooseDownloadDir(touchmenu, "download_dir") end,
        },
        {
            text_func = function()
                if (self:get("book_dir") or "") == "" then
                    return _("Folder for books (EPUB/PDF): same as .acsm")
                end
                return T(_("Folder for books (EPUB/PDF): %1"), self:bookDir())
            end,
            help_text = _("Where the EPUB/PDF made by the ACSM plugin (and DRM-free downloads) are put."),
            keep_menu_open = true,
            callback = function(touchmenu) self:chooseDownloadDir(touchmenu, "book_dir") end,
        },
        {
            text = _("Prefer DRM-free EPUB when offered"),
            help_text = _("Some titles (often public domain) come as a DRM-free EPUB as well as an ACSM. The EPUB opens directly in KOReader."),
            checked_func = function() return self:get("prefer_open_epub", true) end,
            callback = function() self:set("prefer_open_epub", not self:get("prefer_open_epub", true)) end,
            separator = true,
        },
        {
            text_func = function() return T(_("ACSM plugin: %1"), self:acsmStatusText()) end,
            sub_item_table_func = function() return self:acsmMenu() end,
            separator = true,
        },
        {
            text_func = function() return T(_("Plugin updates: %1"), self:pluginStatusText()) end,
            sub_item_table_func = function() return self:pluginUpdateMenu() end,
            separator = true,
        },
        {
            text = _("Recheck availability after"),
            sub_item_table = ttl_items,
        },
        {
            text = _("Troubleshooting"),
            sub_item_table_func = function() return self:troubleshootingMenu() end,
        },
        {
            text = _("Clear saved shelves and results"),
            keep_menu_open = true,
            callback = function()
                self.cache:saveSetting("shelves", {})
                self.cache:saveSetting("avail", {})
                self.cache:flush()
                notify(_("Cleared."), 2)
            end,
        },
    }
end

return GoodreadsLibby
