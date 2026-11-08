--[[
onepage API client — ONE (wufazhuce.com) v3 JSON API.

The parsing and date-selection helpers are pure Lua 5.1 and are unit tested
offline. Network helpers are only called from the forked download subprocess
in main.lua, so a stalled request never blocks the KOReader UI.

Verified 2026-11-08:
  GET http://v3.wufazhuce.com:8000/api/hp/idlist/0?version=3.5.0&platform=android
  GET http://v3.wufazhuce.com:8000/api/hp/detail/5283?...
  GET https://image.wufazhuce.com/...?imageMogr2/thumbnail/1080x/format/jpg
]]

local Api = {}

Api.V3_BASE = "http://v3.wufazhuce.com:8000"
Api.V3_QS = "?version=3.5.0&platform=android"
Api.IMAGE_HOST = "^https?://image%.wufazhuce%.com/"
Api.USER_AGENT = "Mozilla/5.0 (compatible; onepage.koplugin/0.1)"
Api.MAX_IMAGE_BYTES = 4 * 1024 * 1024
Api.MIN_IMAGE_BYTES = 1024
Api.MAX_ID_PROBES = 10

local function round(v) return math.floor(v + 0.5) end

function Api.clean(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("[%z\1-\31\127]", " "):match("^%s*(.-)%s*$"))
end

-- Keep the protocol the API gave us. The v3 endpoint only speaks plain HTTP on
-- port 8000, so the device already has plain HTTP access; using it for the CDN
-- too avoids TLS/CA-bundle differences across KOReader builds. Verified 200 on
-- 2026-11-08 for both http and https variants of the same image.
function Api.normalize_image_url(url, width)
    if type(url) ~= "string" or url == "" then return nil end
    local base = url:gsub("^//", "http://")
    if not base:match("^https?://") then return nil end
    base = base:gsub("[?#].*$", "")
    if base:match(Api.IMAGE_HOST) and width and tonumber(width) and tonumber(width) > 0 then
        local w = math.floor(tonumber(width))
        return base .. string.format("?imageMogr2/thumbnail/%dx/format/jpg", w)
    end
    return base
end

local function iso_to_compact(makettime)
    if type(makettime) ~= "string" then return nil end
    local y, m, d = makettime:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    return y .. m .. d
end
Api.iso_to_compact = iso_to_compact

-- Normalise one hp/detail response into the fields the renderer needs.
-- Returns nil when the response is unusable (empty data, missing date/image).
function Api.parse_detail(data)
    if type(data) ~= "table" then return nil end
    local date = iso_to_compact(data.hp_makettime)
    local image_url = Api.normalize_image_url(data.hp_img_url or data.hp_img_original_url, 1080)
    if not date or not image_url then return nil end

    local text = Api.clean(data.hp_content)
    local quote, byline = text:match("^(.-)%s+by%s+(.+)$")
    if not quote then quote, byline = text, nil end
    quote = Api.clean(quote)
    if quote == "" then return nil end

    local author = Api.clean(data.text_author_name)
    if author == "" then author = Api.clean(byline) end
    if author == "" then author = nil end

    -- Lua patterns are byte-oriented. Never put a multi-byte character such as
    -- "＆" inside a [character class]: its UTF-8 bytes would be treated as
    -- individual separators and would cut Chinese text mid-codepoint.
    local credit = Api.clean(data.hp_author)
    local sep, sep_len = credit:find("＆", 1, true), #"＆"
    if not sep then sep, sep_len = credit:find("&", 1, true), 1 end
    local category, image_author
    if sep then
        category = Api.clean(credit:sub(1, sep - 1))
        image_author = Api.clean(credit:sub(sep + sep_len):gsub("作品%s*$", ""))
    end
    if not category or category == "" then category = "摄影" end
    if not image_author or image_author == "" then image_author = Api.clean(data.image_authors) end
    if image_author == "" then image_author = nil end

    local vol = tostring(data.hp_title or ""):match("VOL%.(%d+)")
    return {
        date = date,
        vol = vol or "",
        quote = quote,
        author = author,
        category = category or "摄影",
        image_author = image_author,
        image_url = image_url,
        hp_id = tostring(data.hpcontent_id or ""),
        makettime = Api.clean(data.hp_makettime),
    }
end

--[[
Pick today's hp entry. `ids` is the idlist/0 array. Its order is date-descending
and contiguous, but the numeric ids are scrambled (pre-allocated), so taking
max(id) is wrong: on 2026-11-08 max was 5310 = VOL.5139 (Nov 1), while ids[1]
was 5283 = VOL.5146 (Nov 8).

fetch_detail(id) must return a decoded hp/detail `data` table or nil.
]]
function Api.pick_today(ids, fetch_detail, date_str, max_probes)
    if type(ids) ~= "table" or type(fetch_detail) ~= "function" then return nil end
    local limit = math.min(max_probes or Api.MAX_ID_PROBES, #ids, Api.MAX_ID_PROBES)
    for i = 1, limit do
        local data = fetch_detail(ids[i])
        local meta = Api.parse_detail(data)
        if meta and meta.date == date_str then return meta end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Network helpers — only executed inside the download subprocess.
-- ---------------------------------------------------------------------------

local function transport(url, timeout, accept, sink, follow_redirect)
    local is_https = url:match("^https:") ~= nil
    local ok, mod = pcall(require, is_https and "ssl.https" or "socket.http")
    if not ok or not mod then return nil, "network_error" end
    local sock_ok, socketutil = pcall(require, "socketutil")
    if sock_ok and socketutil and socketutil.set_timeout then
        pcall(socketutil.set_timeout, timeout or 20, timeout or 20)
    end
    local called, result, code = pcall(mod.request, {
        url = url,
        headers = {
            ["User-Agent"] = Api.USER_AGENT,
            ["Accept"] = accept or "application/json",
            ["Accept-Encoding"] = "identity",
        },
        sink = sink,
        redirect = follow_redirect and true or false,
    })
    if not called then return nil, "network_error" end
    if not result then return nil, "network_error" end
    if code ~= 200 then return nil, "http_" .. tostring(code or "unknown") end
    return true
end

local function get_json(path, timeout)
    local chunks = {}
    local ok, err = transport(Api.V3_BASE .. path .. Api.V3_QS, timeout,
        "application/json", function(chunk)
            if chunk then chunks[#chunks + 1] = chunk end
            return 1
        end)
    if not ok then return nil, err end
    local decoded_ok, decoder = pcall(require, "dkjson")
    if not decoded_ok or not decoder then return nil, "nojson" end
    local parsed, value = pcall(decoder.decode, table.concat(chunks))
    if not parsed or type(value) ~= "table" or value.res ~= 0 then return nil, "decode" end
    return value.data
end

local function write_image(url, tmp, timeout)
    local file, err = io.open(tmp, "wb")
    if not file then return "open_error" end
    local received, too_large, write_error = 0, false, nil
    local function sink(chunk, chunk_err)
        if chunk_err then write_error = chunk_err; return nil, chunk_err end
        if chunk then
            received = received + #chunk
            if received > Api.MAX_IMAGE_BYTES then
                too_large = true
                return nil, "size limit"
            end
            local ok, wrote = pcall(file.write, file, chunk)
            if not ok or not wrote then
                write_error = tostring(wrote)
                return nil, write_error
            end
        end
        return 1
    end
    local ok, status = transport(url, timeout, "image/jpeg,*/*", sink, true)
    local closed = file:close()
    if too_large then os.remove(tmp); return "file_too_large" end
    if write_error or not closed or not ok then
        os.remove(tmp)
        return write_error and "open_error" or (status or "network_error")
    end
    if received < Api.MIN_IMAGE_BYTES then os.remove(tmp); return "invalid_file" end
    local check = io.open(tmp, "rb")
    if not check then os.remove(tmp); return "open_error" end
    local head = check:read(2)
    local size = check:seek("end")
    local tail
    if size and size >= 4 and check:seek("end", -2) then tail = check:read(2) end
    check:close()
    if head ~= "\255\216" or tail ~= "\255\217" then
        os.remove(tmp)
        return "invalid_file"
    end
    return "downloaded"
end

local function json_encode(value)
    local ok, dkjson = pcall(require, "dkjson")
    if ok and dkjson and dkjson.encode then return dkjson.encode(value) end
    -- Minimal fallback for the flat metadata table (no nested tables).
    local parts = {}
    for k, v in pairs(value) do
        if type(v) == "string" then
            parts[#parts + 1] = string.format("%q:%q", tostring(k), v)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--[[
Fetch everything needed for one day. opts:
  date_str    YYYYMMDD in Beijing time
  image_tmp   staging path for the JPEG (parent renames it)
  meta_tmp    staging path for the metadata JSON
  timeout     per-request timeout in seconds

Returns one of: "downloaded", "no_today", "network_error", "http_*",
"decode", "invalid_file", "file_too_large", "open_error", "write_error".
]]
function Api.fetch_today(opts)
    opts = opts or {}
    local ids, err = get_json("/api/hp/idlist/0", opts.timeout)
    if not ids then return err or "network_error" end
    if type(ids) ~= "table" or #ids == 0 then return "no_today" end

    local function fetch_detail(id)
        local data = get_json("/api/hp/detail/" .. tostring(id), opts.timeout)
        return data
    end
    local meta = Api.pick_today(ids, fetch_detail, opts.date_str)
    if not meta then return "no_today" end

    local status = write_image(meta.image_url, opts.image_tmp, opts.timeout)
    if status ~= "downloaded" then return status end

    local file = io.open(opts.meta_tmp, "wb")
    if not file then os.remove(opts.image_tmp); return "write_error" end
    local wrote = file:write(json_encode(meta))
    local closed = file:close()
    if not wrote or not closed then
        os.remove(opts.meta_tmp)
        os.remove(opts.image_tmp)
        return "write_error"
    end
    return "downloaded"
end

return Api
