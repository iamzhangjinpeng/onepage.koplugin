-- Manual updates for the published Kindle plugin package.
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Update = {}
local PLUGIN = "onepage.koplugin"
local REPOSITORY = "iamzhangjinpeng/" .. PLUGIN
local API = "https://api.github.com/repos/" .. REPOSITORY .. "/releases/latest"
local API_ASSETS = "https://api.github.com/repos/" .. REPOSITORY .. "/releases/assets/"
local DOWNLOAD = "https://github.com/" .. REPOSITORY .. "/releases/download/"
local MAX_RESPONSE = 256 * 1024
local MAX_ZIP = 1024 * 1024
local MAX_EXPANDED = 4 * 1024 * 1024
local MAX_ENTRIES = 96
local ASSET_HOSTS = {
    ["api.github.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
    ["objects.githubusercontent.com"] = true,
}
local REQUIRED = { "_meta.lua", "main.lua", "onepage_api.lua", "onepage_layout.lua",
    "onepage_wallpaper.lua", "onepage_update.lua" }

local function version_parts(version)
    if type(version) ~= "string" or #version > 24 then return end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if major and #major <= 9 and #minor <= 9 and #patch <= 9 then
        return { tonumber(major), tonumber(minor), tonumber(patch) }
    end
end

local function compare_versions(left, right)
    local a, b = version_parts(left), version_parts(right)
    if not a or not b then return end
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] > b[i] and 1 or -1 end
    end
    return 0
end

local function asset_name(version)
    return PLUGIN .. "-v" .. version .. ".zip"
end

local function browser_download_url(version)
    return DOWNLOAD .. "v" .. version .. "/" .. asset_name(version)
end

local function asset_url(id)
    return API_ASSETS .. id
end

local function asset_id_string(id)
    if type(id) ~= "number" or id < 1 or id >= 9007199254740992 or id % 1 ~= 0 then return end
    return string.format("%.0f", id)
end

local function valid_digest(digest)
    return type(digest) == "string" and #digest == 64 and digest:match("^%x+$") ~= nil
end

-- Kindle releases of KOReader ship a CA bundle. Older LuaSec builds in
-- KOReader verify the chain on request but leave DNS name checks to callers.
local function certificate_matches(connection, host)
    local certificate = connection.sock:getpeercertificate()
    local extensions = certificate and certificate:extensions()
    local extension = extensions and extensions["2.5.29.17"]
    for _, name in ipairs(extension and extension.dNSName or {}) do
        name = name:lower()
        if name == host or name == "*." .. (host:match("^[^.]+%.(.+)$") or "") then
            return true
        end
    end
    return false
end

local function get(url, limit, asset)
    local http = require("socket.http")
    -- HTTPS requests use a custom LuaSec connector, which cannot tunnel
    -- through LuaSocket's HTTP proxy. This runs in an isolated child process,
    -- so clearing PROXY here does not change KOReader's network settings.
    http.PROXY = nil
    local https = require("ssl.https")
    local socketutil = require("socketutil")
    socketutil:set_timeout(10, 20)

    for hop = 0, 3 do
        local host = type(url) == "string" and url:match("^https://([a-z0-9.-]+)/[^%c%s]*$")
        if not host or (asset and not ASSET_HOSTS[host]) or (not asset and host ~= "api.github.com") then
            return nil, "redirect_error"
        end

        local tcp = https.tcp{ verify = "peer", cafile = "data/ca-bundle.crt" }
        local function create()
            local connection = tcp()
            local connect = connection.connect
            -- LuaSocket can close the connection before LuaSec has installed
            -- its TLS methods, for example after a failed handshake.
            function connection:close()
                return self.sock:close()
            end
            function connection:connect(peer, port)
                if peer ~= host or tonumber(port) ~= 443 then return nil, "unexpected HTTPS peer" end
                local ok, err = connect(self, peer, port)
                if not ok then return nil, err end
                if not certificate_matches(self, host) then return nil, "TLS certificate hostname mismatch" end
                return ok
            end
            return connection
        end

        local chunks, size, too_large = {}, 0, false
        local ok, code, headers = http.request{
            url = url,
            create = create,
            redirect = false,
            headers = {
                ["user-agent"] = "KOReader-OnePage",
                ["accept"] = asset and "application/octet-stream" or "application/vnd.github+json",
                ["accept-encoding"] = "identity",
            },
            sink = function(chunk)
                if chunk then
                    size = size + #chunk
                    if size > limit then
                        too_large = true
                        return nil, "response exceeds size limit"
                    end
                    chunks[#chunks + 1] = chunk
                end
                return 1
            end,
        }
        if too_large then return nil, "too_large" end
        if not ok then
            logger.warn("一页壁纸: 更新请求失败", host, tostring(code))
            return nil, "network_error"
        end
        if code == 200 then return table.concat(chunks) end
        if not asset or hop == 3 or (code ~= 301 and code ~= 302 and code ~= 303
                and code ~= 307 and code ~= 308) then
            return nil, "http_" .. tostring(code)
        end
        url = headers and headers.location
    end
end

local function short_notes(body)
    if type(body) ~= "string" then return "" end
    body = body:gsub("[%z\1-\8\11\12\14-\31\127]", "")
    local limit = 480
    if #body <= limit then return body end
    while limit > 0 and body:byte(limit + 1) >= 128 and body:byte(limit + 1) <= 191 do
        limit = limit - 1
    end
    return body:sub(1, limit) .. "…"
end

-- The parent waits for child exit before reading the pipe, so keep the
-- message well below PIPE_BUF. Large responses stay in the child.
function Update.check(current_version)
    local body, err = get(API, MAX_RESPONSE)
    if not body then return err end
    local release = require("dkjson").decode(body)
    if type(release) ~= "table" or release.draft ~= false or release.prerelease ~= false
        or type(release.tag_name) ~= "string" then
        return "bad_release"
    end
    local version = release.tag_name:match("^v(%d+%.%d+%.%d+)$")
    local comparison = compare_versions(version, current_version)
    if not comparison then return "bad_release" end
    if comparison <= 0 then return "current" end
    if type(release.assets) ~= "table" then return "missing_asset" end
    for _, asset in ipairs(release.assets) do
        if type(asset) == "table" and asset.name == asset_name(version) and asset.state == "uploaded"
            and asset.browser_download_url == browser_download_url(version) then
            local asset_id = asset_id_string(asset.id)
            if not asset_id or asset.url ~= asset_url(asset_id) then return "bad_release" end
            local digest = type(asset.digest) == "string" and asset.digest:match("^sha256:(%x+)$")
            if not valid_digest(digest) then return "bad_release" end
            if type(asset.size) ~= "number" or asset.size < 1 or asset.size > MAX_ZIP
                or asset.size % 1 ~= 0 then
                return "too_large"
            end
            return table.concat({ "available", version, tostring(asset.size), digest:lower(), asset_id,
                short_notes(release.body) }, "\n")
        end
    end
    return "missing_asset"
end

function Update.parse_result(status)
    local version, size, digest, asset_id, notes =
        status:match("^available\n([%d.]+)\n(%d+)\n(%x+)\n(%d+)\n(.*)$")
    size = tonumber(size)
    local asset_id_number = tonumber(asset_id)
    if version_parts(version) and size and size > 0 and size <= MAX_ZIP and valid_digest(digest)
        and asset_id_number and asset_id == asset_id_string(asset_id_number) then
        return { version = version, size = size, digest = digest, asset_id = asset_id, notes = notes }
    end
end

function Update.paths(path)
    if type(path) ~= "string" or not path:match("/onepage%.koplugin$") then return end
    return {
        live = path,
        parent = path:match("^(.*)/[^/]+$"),
        backup = path .. ".previous",
        work = path .. ".update",
    }
end

local function mode(path)
    return lfs.symlinkattributes(path, "mode")
end

function Update.has_backup(paths)
    return mode(paths.backup) ~= nil
end

local function remove_tree(path)
    local kind = mode(path)
    if not kind then return true end
    if kind == "directory" then
        local opened, iterator, directory = pcall(lfs.dir, path)
        if not opened then return nil, iterator end
        for entry in iterator, directory do
            if entry ~= "." and entry ~= ".." then
                local ok, err = remove_tree(path .. "/" .. entry)
                if not ok then return nil, err end
            end
        end
        return lfs.rmdir(path)
    end
    return os.remove(path)
end

local function sync_install_directory(paths)
    local called, synced, err = pcall(ffiutil.fsyncDirectory, paths.parent)
    if not called or not synced then
        logger.warn("一页壁纸: 刷新插件目录失败", tostring(called and err or synced))
        return false
    end
    return true
end

function Update.clean_after_start(paths, healthy)
    local ok, err = remove_tree(paths.work)
    if not ok then logger.warn("一页壁纸: 清理更新临时目录失败", tostring(err)) end
    -- Keep the rollback copy until the new code has initialized its wallpaper
    -- and the live directory entry has been confirmed on storage.
    if healthy and Update.has_backup(paths) and mode(paths.live) == "directory"
        and sync_install_directory(paths) then
        ok, err = remove_tree(paths.backup)
        if not ok then logger.warn("一页壁纸: 清理更新备份失败", tostring(err)) end
    end
end

local stage_counter = 0

function Update.make_stage(paths)
    if mode(paths.live) ~= "directory" then return nil, "install_error" end
    if Update.has_backup(paths) then return nil, "backup_pending" end
    if not mode(paths.work) and not lfs.mkdir(paths.work) then return nil, "write_error" end
    if mode(paths.work) ~= "directory" then return nil, "write_error" end
    -- An orphaned worker from the previous KOReader process cannot write to a
    -- new job's directory, even if the old stage has already been cleaned up.
    local ffi = require("ffi")
    stage_counter = stage_counter + 1
    local stage = string.format("%s/%d-%d-%d", paths.work, tonumber(ffi.C.getpid()), os.time(), stage_counter)
    if not lfs.mkdir(stage) then return nil, "write_error" end
    return stage
end

function Update.remove_stage(paths, stage)
    local ok, err = remove_tree(stage)
    if not ok then logger.warn("一页壁纸: 清理更新临时目录失败", tostring(err)) end
    lfs.rmdir(paths.work)
end

local function write_file(path, contents, sync)
    local file = io.open(path, "wb")
    if not file then return false end
    local ok = file:write(contents)
    if ok and sync then ok = ffiutil.fsyncOpenedFile(file, true) end
    local closed = file:close()
    return ok and closed
end

local function safe_path(path)
    if #path > 180 or path:sub(1, 1) == "/" or path:sub(-1) == "/" or path:find("//", 1, true) then
        return false
    end
    for part in path:gmatch("[^/]+") do
        if not part:match("^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$") or part:sub(-1) == "." then
            return false
        end
    end
    return path ~= ""
end

local function extract(reader, destination, version)
    local seen, written, directories = {}, {}, {}
    local expanded, count = 0, 0
    local function ensure_directory(path)
        if not path then return true end
        local key = path:lower()
        if seen[key] then return seen[key] == path .. "/" end
        if not ensure_directory(path:match("^(.*)/[^/]+$")) then return false end
        if not lfs.mkdir(destination .. "/" .. path) then return false end
        seen[key] = path .. "/"
        directories[#directories + 1] = path
        return true
    end

    for entry in reader:iterate() do
        count = count + 1
        if count > MAX_ENTRIES then return "bad_zip" end
        local path = entry.path:match("^onepage%.koplugin/(.*)$")
        local size = tonumber(entry.size)
        if path == nil or not size or size < 0 then return "bad_zip" end
        if entry.mode == "directory" and path ~= "" then
            path = path:gsub("/$", "")
            if path == "" then return "bad_zip" end
        end
        if path ~= "" or entry.mode ~= "directory" then
            if not safe_path(path) then return "bad_zip" end
            if entry.mode == "directory" then
                if not ensure_directory(path) then return "bad_zip" end
            elseif entry.mode == "file" then
                local key = path:lower()
                expanded = expanded + size
                if seen[key] or size == 0 or expanded > MAX_EXPANDED
                    or not ensure_directory(path:match("^(.*)/[^/]+$")) then
                    return "bad_zip"
                end
                local contents = reader:extractToMemory(entry.path)
                if type(contents) ~= "string" or #contents ~= size then return "bad_zip" end
                if path:match("%.lua$") and (contents:byte(1) == 27 or not loadstring(contents, "@" .. path)) then
                    return "bad_zip"
                end
                if path == "_meta.lua" and contents:match('\n%s*version%s*=%s*"([%d.]+)"') ~= version then
                    return "bad_zip"
                end
                if not write_file(destination .. "/" .. path, contents, true) then return "write_error" end
                seen[key], written[path] = path, true
            else
                return "bad_zip"
            end
        end
    end
    if reader.err then return "bad_zip" end
    for _, path in ipairs(REQUIRED) do
        if not written[path] then return "bad_zip" end
    end
    for i = #directories, 1, -1 do
        if not ffiutil.fsyncDirectory(destination .. "/" .. directories[i]) then return "write_error" end
    end
    if not ffiutil.fsyncDirectory(destination) then return "write_error" end
    return "prepared"
end

function Update.prepare(stage, release)
    local data, err = get(asset_url(release.asset_id), release.size, true)
    if not data then return err end
    if #data ~= release.size or require("ffi/sha2").sha256(data) ~= release.digest then
        return "bad_digest"
    end
    if data:sub(1, 4) ~= "PK\3\4" then return "bad_zip" end
    local zip, destination = stage .. "/package.zip", stage .. "/new"
    if not write_file(zip, data) or not lfs.mkdir(destination) then return "write_error" end
    local reader = require("ffi/archiver").Reader:new()
    if not reader:open(zip) then return "bad_zip" end
    local status = extract(reader, destination, release.version)
    reader:close()
    return status
end

function Update.install(paths, stage)
    if mode(paths.live) ~= "directory" or Update.has_backup(paths) or mode(stage .. "/new") ~= "directory" then
        return "install_error"
    end
    local ok, err = os.rename(paths.live, paths.backup)
    if not ok then
        logger.warn("一页壁纸: 无法备份旧版", tostring(err))
        return "install_error"
    end
    ok, err = os.rename(stage .. "/new", paths.live)
    if not ok then
        logger.warn("一页壁纸: 无法替换插件", tostring(err))
        local restored, restore_err = os.rename(paths.backup, paths.live)
        if not restored then
            logger.err("一页壁纸: 无法恢复旧版", paths.backup, tostring(restore_err))
            return "restore_error"
        end
        return "install_error"
    end
    return sync_install_directory(paths) and "installed" or "sync_error"
end

return Update
