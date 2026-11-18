--[[--
Install and update KOReader plugins from GitHub releases (used for
acsm.koplugin).

Looks up the latest release of a GitHub repository, downloads its .zip (a
release asset if there is one, otherwise the source zip), and swaps the plugin
folder for the new version. The old folder is kept until the new one is in
place, so a failed update leaves the installed version untouched.
--]]

local Http = require("grlibby/http")
local Util = require("grlibby/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Update = {}

Update.API = "https://api.github.com/repos/"

--- "v1.2.10-beta" -> { 1, 2, 10 }
function Update.parseVersion(v)
    local parts = {}
    for n in tostring(v or ""):gsub("^[vV]", ""):gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(n)
    end
    return parts
end

function Update.isNewer(remote, current)
    local a, b = Update.parseVersion(remote), Update.parseVersion(current)
    if #a == 0 then return false end
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

function Update.validRepo(repo)
    return type(repo) == "string" and repo:match("^[%w%-_.]+/[%w%-_.]+$") ~= nil
end

--- Latest published release of `repo` ("owner/name"). A .zip asset whose name
-- contains `asset_hint` is preferred.
-- Returns { version, notes, zip_url, page } or nil, error.
function Update.latest(repo, asset_hint)
    if not Update.validRepo(repo) then
        return nil, "Set the GitHub repository (owner/name) first."
    end
    local data, resp, err = Http.json{
        url = Update.API .. repo .. "/releases/latest",
        headers = { Accept = "application/vnd.github+json" },
    }
    if not resp then return nil, err end
    if resp.code == 404 then
        return nil, "No releases found for " .. repo .. "."
    end
    if resp.code == 403 or resp.code == 429 then
        return nil, "GitHub is rate-limiting requests; try again later."
    end
    if resp.code ~= 200 or type(data) ~= "table" then
        return nil, string.format("GitHub replied with HTTP %d.", resp.code)
    end
    local zip_url
    for _, asset in ipairs(type(data.assets) == "table" and data.assets or {}) do
        local name = Util.str(asset.name) or ""
        local url = Util.str(asset.browser_download_url)
        if url and name:lower():match("%.zip$") then
            if asset_hint and name:find(asset_hint, 1, true) then
                zip_url = url
                break
            end
            zip_url = zip_url or url
        end
    end
    zip_url = zip_url or Util.str(data.zipball_url)
    if not zip_url then return nil, "The latest release has no .zip to download." end
    return {
        version = Util.str(data.tag_name) or Util.str(data.name) or "?",
        notes = Util.str(data.body),
        zip_url = zip_url,
        page = Util.str(data.html_url),
    }
end

--------------------------------------------------------------------------------
-- File helpers
--------------------------------------------------------------------------------

local function exists(path) return lfs.attributes(path, "mode") ~= nil end
local function isDir(path) return lfs.attributes(path, "mode") == "directory" end

local function mkdirp(path)
    if isDir(path) then return true end
    local parent = path:match("^(.+)/[^/]+/?$")
    if parent and parent ~= "" then mkdirp(parent) end
    return lfs.mkdir(path)
end

local function rmrf(path)
    if not exists(path) then return true end
    if isDir(path) then
        local names = {}
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
        for _, name in ipairs(names) do rmrf(path .. "/" .. name) end
        return lfs.rmdir(path)
    end
    return os.remove(path)
end
Update.rmrf = rmrf

local function writeFile(path, data)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(data)
    f:close()
    return true
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Which folder inside the archive is the plugin: the one holding both
-- _meta.lua and main.lua, closest to the root.
local function findRoot(paths)
    local set = {}
    for _, p in ipairs(paths) do set[p] = true end
    local best
    for _, p in ipairs(paths) do
        local prefix = p:match("^(.-)_meta%.lua$")
        if prefix and (prefix == "" or prefix:sub(-1) == "/") and set[prefix .. "main.lua"] then
            if not best or #prefix < #best then best = prefix end
        end
    end
    return best
end
Update.findRoot = findRoot

local function safeRelative(rel)
    return rel ~= "" and not rel:find("%.%.") and rel:sub(1, 1) ~= "/"
end

--- Extract the plugin folder of a release zip into `dest` (created).
function Update.extract(zip_path, dest)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if ok and type(Archiver) == "table" and Archiver.Reader then
        local reader = Archiver.Reader:new()
        if not reader:open(zip_path) then
            return nil, "Couldn't open the update: " .. tostring(reader.err)
        end
        local files = {}
        for entry in reader:iterate() do
            if entry.mode == "file" then files[#files + 1] = entry.path end
        end
        local root = findRoot(files)
        if not root then
            reader:close()
            return nil, "The download doesn't contain this plugin."
        end
        mkdirp(dest)
        for entry in reader:iterate() do
            if entry.mode == "file" and entry.path:sub(1, #root) == root then
                local rel = entry.path:sub(#root + 1)
                if safeRelative(rel) then
                    local data = reader:extractToMemory(entry.path)
                    if not data then
                        reader:close()
                        return nil, "Couldn't unpack " .. rel
                    end
                    local dir = rel:match("^(.*)/[^/]+$")
                    if dir then mkdirp(dest .. "/" .. dir) end
                    local wok, werr = writeFile(dest .. "/" .. rel, data)
                    if not wok then
                        reader:close()
                        return nil, werr
                    end
                end
            end
        end
        reader:close()
        return true
    end

    -- Older KOReader without ffi/archiver: use the system unzip.
    local tmp = dest .. ".unzip"
    rmrf(tmp)
    mkdirp(tmp)
    local function quote(p) return "'" .. p:gsub("'", "'\\''") .. "'" end
    local cmd = string.format("unzip -qo %s -d %s", quote(zip_path), quote(tmp))
    local rc = os.execute(cmd)
    if not (rc == 0 or rc == true) then
        rmrf(tmp)
        return nil, "Couldn't unpack the update (no unzip available)."
    end
    local files = {}
    local function walk(dir, rel)
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local path, r = dir .. "/" .. name, rel .. name
                if isDir(path) then walk(path, r .. "/") else files[#files + 1] = r end
            end
        end
    end
    walk(tmp, "")
    local root = findRoot(files)
    if not root then
        rmrf(tmp)
        return nil, "The download doesn't contain this plugin."
    end
    rmrf(dest)
    local src = tmp
    if root ~= "" then src = tmp .. "/" .. root:gsub("/$", "") end
    local moved = os.rename(src, dest)
    rmrf(tmp)
    if not moved then return nil, "Couldn't move the update into place." end
    return true
end

--- Download `info` (from Update.latest) and install it as `plugin_dir`,
-- replacing the folder if it exists.
-- opts.name: the plugin's _meta.lua name (guards against the wrong download);
-- opts.preserve: files in the old folder to carry over.
-- Returns true or nil, error.
function Update.install(info, plugin_dir, tmp_dir, opts)
    opts = opts or {}
    plugin_dir = plugin_dir:gsub("/+$", "")
    local parent = plugin_dir:match("^(.+)/[^/]+$")
    if not parent then return nil, "Unknown plugin folder." end
    -- The plugins folder must be writable (it isn't for some bundled installs).
    local probe = parent .. "/.grlibby_write_test"
    if not writeFile(probe, "") then
        return nil, "The plugins folder is read-only; update manually."
    end
    os.remove(probe)

    local resp, err = Http.request{
        url = info.zip_url,
        headers = { Accept = "application/octet-stream" },
        large = true,
    }
    if not resp then return nil, "Download failed: " .. tostring(err) end
    if resp.code ~= 200 or resp.body:sub(1, 2) ~= "PK" then
        return nil, string.format("Download failed (HTTP %d).", resp.code)
    end
    mkdirp(tmp_dir)
    local zip_path = tmp_dir .. "/" .. (opts.name or "plugin") .. "-update.zip"
    local wok, werr = writeFile(zip_path, resp.body)
    if not wok then return nil, werr end

    local staging = plugin_dir .. ".new"
    local backup = plugin_dir .. ".old"
    rmrf(staging)
    local ok, xerr = Update.extract(zip_path, staging)
    os.remove(zip_path)
    if not ok then
        rmrf(staging)
        return nil, xerr
    end
    if not exists(staging .. "/main.lua")
        or (opts.name and Update.pluginName(staging) ~= opts.name) then
        rmrf(staging)
        return nil, "The download isn't the " .. (opts.name or "expected") .. " plugin."
    end

    for _, name in ipairs(opts.preserve or {}) do
        local data = readFile(plugin_dir .. "/" .. name)
        if data then writeFile(staging .. "/" .. name, data) end
    end

    rmrf(backup)
    local fresh = not exists(plugin_dir)
    if not fresh then
        local renamed, rerr = os.rename(plugin_dir, backup)
        if not renamed then
            rmrf(staging)
            return nil, "Couldn't replace the plugin: " .. tostring(rerr)
        end
    end
    local placed, perr = os.rename(staging, plugin_dir)
    if not placed then
        if not fresh then os.rename(backup, plugin_dir) end
        rmrf(staging)
        return nil, "Couldn't replace the plugin: " .. tostring(perr)
    end
    rmrf(backup)
    logger.info("grlibby: installed", opts.name, info.version, "into", plugin_dir)
    return true
end

-- A `key = "value"` field of a _meta.lua (not matching e.g. fullname for name).
local function metaField(meta, key)
    if not meta then return nil end
    return ("\n" .. meta):match("[^%w_]" .. key .. '%s*=%s*"([^"]+)"')
end

--- The version in a plugin folder's _meta.lua (nil when absent).
function Update.installedVersion(plugin_dir)
    return metaField(readFile(plugin_dir .. "/_meta.lua"), "version")
end

--- The plugin name in a plugin folder's _meta.lua (nil when absent).
function Update.pluginName(plugin_dir)
    return metaField(readFile(plugin_dir .. "/_meta.lua"), "name")
end

--- Remove leftovers of an interrupted update.
function Update.cleanup(plugin_dir)
    if not plugin_dir then return end
    plugin_dir = plugin_dir:gsub("/+$", "")
    rmrf(plugin_dir .. ".new")
    rmrf(plugin_dir .. ".old")
end

return Update
