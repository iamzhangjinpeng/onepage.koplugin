--[[
onepage wallpaper renderer.

Two styles, one content painter:
  fullscreen — the ONE app card fills the screen (photo / category / quote / date)
  card       — the same card sits inside a white rounded card on a light canvas,
               with ONE branding above and VOL/date/credit below

Text layout follows yiyan.koplugin: TextBoxWidget with progressive font shrink,
painted into an off-screen BlitBuffer. Rounded corners follow
danxiangli.koplugin: blit the card row by row with an arc-derived inset, which
rounds the photo and the text panels together instead of just the background.

The rendered PNG is dithered to 16 greys, verified, and only then published to
display/wallpaper.png. A failed render never evicts the last usable wallpaper.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
-- Load by absolute path: this module is also dofile'd from the forked download
-- subprocess, where KOReader's package.path may not include the plugin dir.
local Layout = dofile((debug.getinfo(1, "S").source:match("^@(.*/)") or "./")
    .. "onepage_layout.lua")

local Wallpaper = { MAX_JPEG_BYTES = 4 * 1024 * 1024, CACHE_VERSION = 1 }
local MAX_JPEG_PIXELS = 4 * 1024 * 1024
local MAX_PNG_BYTES = 32 * 1024 * 1024
local MAX_PNG_PIXELS = 8 * 1024 * 1024
local MAX_IMAGE_EDGE = 4096
local PNG_SIGNATURE = "\137PNG\r\n\26\n"
local PNG_END = "\0\0\0\0IEND\174\66\96\130"
local verified_png
local published_png

local function round(value) return math.floor(value + 0.5) end

local function big_endian(data, offset, length)
    local value = 0
    for i = offset, offset + length - 1 do
        value = value * 256 + data:byte(i)
    end
    return value
end

local function dimensions_fit(width, height, max_pixels)
    return width > 0 and height > 0 and width <= MAX_IMAGE_EDGE and height <= MAX_IMAGE_EDGE
        and width * height <= max_pixels
end

local function valid_png(path, attrs)
    if not attrs or attrs.mode ~= "file" or attrs.size < 45 or attrs.size > MAX_PNG_BYTES then return false end
    local file = io.open(path, "rb")
    if not file then return nil end
    local head = file:read(24)
    local tail
    if file:seek("end", -12) then tail = file:read(12) end
    if not file:close() or not head or #head ~= 24 or not tail or #tail ~= 12 then return nil end
    if head:sub(1, 16) ~= PNG_SIGNATURE .. "\0\0\0\13IHDR"
        or tail ~= PNG_END then return false end
    if not dimensions_fit(big_endian(head, 17, 4), big_endian(head, 21, 4), MAX_PNG_PIXELS) then return false end
    local ffi = require("ffi")
    local Png = require("ffi/png")
    local called, ok, image = pcall(Png.decodeFromFile, path, 1)
    if not called then return nil end
    if not ok then
        if image == "couldn't open PNG file" or image == "memory allocation failed" then return nil end
        return false
    end
    ffi.C.free(image.data)
    return true
end

function Wallpaper.isValidPNG(path)
    return valid_png(path, lfs.attributes(path)) == true
end

local function same_file(attrs, saved)
    return attrs and saved and attrs.mode == saved.mode and attrs.size == saved.size
        and attrs.modification == saved.modification and attrs.change == saved.change
        and attrs.ino == saved.ino and attrs.dev == saved.dev
end

local function cached_png_is_valid(path)
    local attrs = lfs.attributes(path)
    if not attrs then return nil end
    local saved = verified_png and verified_png.path == path and verified_png.attrs
    if same_file(attrs, saved) then return true end
    local valid = valid_png(path, attrs)
    if not valid then return valid end
    verified_png = { path = path, attrs = attrs }
    return true
end

-- Scan JPEG segments up to the first frame header before allocating pixels.
local function jpeg_dimensions(data)
    local pos = 3
    while pos <= #data and data:byte(pos) == 255 do
        repeat pos = pos + 1 until data:byte(pos) ~= 255
        local marker = data:byte(pos)
        pos = pos + 1
        if not marker or marker == 0 or marker == 218 or marker == 222
            or (marker >= 208 and marker <= 217) or pos + 1 > #data then return end
        local length = big_endian(data, pos, 2)
        if length < 2 or pos + length > #data then return end
        if marker == 192 or marker == 193 or marker == 194 then
            if length < 11 or length ~= 8 + 3 * data:byte(pos + 7) then return end
            return big_endian(data, pos + 5, 2), big_endian(data, pos + 3, 2)
        end
        if marker >= 192 and marker <= 207 and marker ~= 196 and marker ~= 204 then return end
        pos = pos + length
    end
end

local function decode_source(RenderImage, path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local size = file:seek("end")
    if size and size > Wallpaper.MAX_JPEG_BYTES then
        file:close()
        return nil, "JPEG exceeds the download size limit"
    end
    local data
    if size and size >= 4 and file:seek("set", 0) then data = file:read(size) end
    file:close()
    if not data or #data ~= size or data:sub(1, 2) ~= "\255\216" or data:sub(-2) ~= "\255\217" then
        return nil, "Invalid JPEG"
    end
    local width, height = jpeg_dimensions(data)
    if not width then return nil, "Invalid or unsupported JPEG frame" end
    if not dimensions_fit(width, height, MAX_JPEG_PIXELS) then return nil, "JPEG dimensions exceed the limit" end
    local ok, image = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok then return nil, tostring(image) end
    if not image then return nil, "Cannot decode the daily image" end
    return image
end

function Wallpaper.validate_source(path)
    local image, err = decode_source(require("ui/renderimage"), path)
    if not image then return false, err end
    image:free()
    return true
end

local function load_meta(source)
    local date = source:match("(%d%d%d%d%d%d%d%d)%.jpg$")
    if not date then return nil end
    local dir = source:match("^(.*/)") or ""
    local file = io.open(dir .. date .. ".json", "rb")
    if not file then return nil end
    local body = file:read("*a")
    file:close()
    if not body or body == "" then return nil end
    local ok, dkjson = pcall(require, "dkjson")
    if not ok or not dkjson then return nil end
    local decoded, meta = pcall(dkjson.decode, body)
    if not decoded or type(meta) ~= "table" then return nil end
    return meta
end

-- TextBoxWidget allocates a pixel buffer on construction, so bound its height
-- on every size trial. Font:getFace scales its argument by the screen DPI, so
-- convert the intended pixel size back first (yiyan.koplugin).
local function text_in_box(text, box, size, min_size, fgcolor, bgcolor, alignment)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local Screen = require("device").screen
    local screen_scale = Screen:scaleBySize(1024) / 1024
    if screen_scale <= 0 then screen_scale = 1 end
    local current = size
    while true do
        local widget = TextBoxWidget:new{
            text = text,
            face = Font:getFace("cfont", math.max(1, round(current / screen_scale))),
            width = math.max(1, box.w),
            height = math.max(1, box.h),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = alignment or "left",
            alignment_strict = true,
            auto_para_direction = true,
            fgcolor = fgcolor,
            bgcolor = bgcolor,
        }
        if current <= min_size or (not widget.line_with_ellipsis and widget:getSize().h <= box.h) then
            return widget
        end
        widget:free()
        current = math.max(min_size, current - 1)
    end
end

-- Paint and release immediately: a 1072x1448 wallpaper holds seven of these,
-- and keeping every widget's pixel buffer alive until the end of render() was
-- several megabytes of avoidable peak memory.
local function paint_text(text, box, size, min_size, fgcolor, bgcolor, alignment, bb)
    if not text or text == "" then return end
    local widget = text_in_box(text, box, size, min_size, fgcolor, bgcolor, alignment)
    local painted = pcall(widget.paintTo, widget, bb, box.x, box.y)
    widget:free()
    if not painted then error("Cannot paint text") end
end

-- Paint the ONE card into `panel`. ox/oy is the panel origin in the layout's
-- coordinate space (the card's top-left for the card style, 0/0 for fullscreen).
local function paint_content(panel, L, meta, original, Blitbuffer, RenderImage)
    local colors = L.colors
    local ox, oy = L.card and L.card.x or 0, L.card and L.card.y or 0
    local C = L.content
    local function color(v) return Blitbuffer.Color8(v) end
    local function local_box(b, dx, dy, dw, dh)
        return { x = b.x - ox + (dx or 0), y = b.y - oy + (dy or 0),
            w = b.w + (dw or 0), h = b.h + (dh or 0) }
    end

    -- Photo: scale to cover and centre-crop. This matches the ONE app's card.
    local photo = C.photo
    local pw, ph = photo.w, photo.h
    local iw, ih = original:getWidth(), original:getHeight()
    local scale = math.max(pw / iw, ph / ih)
    local sw, sh = math.max(1, round(iw * scale)), math.max(1, round(ih * scale))
    local scaled = RenderImage:scaleBlitBuffer(original, sw, sh, false)
    if not scaled then error("Cannot scale the daily image") end
    local sx, sy = math.floor((sw - pw) / 2), math.floor((sh - ph) / 2)
    local blitted = pcall(panel.blitFrom, panel, scaled, photo.x - ox, photo.y - oy, sx, sy, pw, ph)
    scaled:free()
    if not blitted then error("Cannot place the daily image") end

    -- Category band.
    local cat = C.cat
    panel:paintRect(cat.x - ox, cat.y - oy, cat.w, cat.h, color(colors.cat))
    paint_text((meta and meta.category) or "摄影", local_box(cat),
        L.fonts.category, L.fonts.category, color(colors.cat_text), color(colors.cat),
        "center", panel)

    -- Quote panel and date column.
    local info, date = C.info, C.date
    panel:paintRect(info.x - ox, info.y - oy, info.w, info.h, color(colors.info))
    panel:paintRect(date.x - ox, date.y - oy, date.w, date.h, color(colors.date))
    if L.contrast == "high" then
        panel:paintRect(date.x - ox, date.y - oy, 1, date.h, color(colors.rule))
    end

    local pad = L.padding
    if meta and type(meta.quote) == "string" then
        paint_text(meta.quote, local_box(info, pad, pad, -2 * pad, -2 * pad),
            L.fonts.quote, L.fonts.quote_min, color(colors.text), color(colors.info),
            "left", panel)
    end

    local date_str = tostring((meta and meta.date) or "")
    local vol_text = (meta and meta.vol and meta.vol ~= "") and ("VOL." .. tostring(meta.vol)) or ""
    local day_text = date_str:sub(7, 8)
    local month_text = Layout.month_name(tonumber(date_str:sub(5, 6)) or 1) .. " " .. date_str:sub(1, 4)
    local date_color, date_bg = color(colors.text), color(colors.date)
    local dpad = round(date.w * 0.08)
    local vol_box = local_box(date, dpad, round(date.h * 0.10), -2 * dpad, 0)
    vol_box.h = round(date.h * 0.20)
    local day_box = local_box(date, 0, round(date.h * 0.30), 0, 0)
    day_box.h = round(date.h * 0.45)
    local month_box = local_box(date, dpad, round(date.h * 0.78), -2 * dpad, 0)
    month_box.h = round(date.h * 0.18)
    paint_text(vol_text, vol_box, L.fonts.vol, L.fonts.vol, date_color, date_bg, "center", panel)
    paint_text(day_text, day_box, L.fonts.day, round(L.fonts.day * 0.7), date_color, date_bg, "center", panel)
    paint_text(month_text, month_box, L.fonts.month, L.fonts.month, date_color, date_bg, "center", panel)
end

local function render(source, target, width, height, style, contrast)
    local original, panel, canvas, eink
    local invalid_source
    local ok, err = pcall(function()
        local ffi_ok, Blitbuffer = pcall(require, "ffi/blitbuffer")
        if not ffi_ok then error("Blitbuffer unavailable") end
        local RenderImage = require("ui/renderimage")
        local decode_error
        original, decode_error = decode_source(RenderImage, source)
        if not original then
            -- Tells main.lua to re-download instead of trusting today's JPEG.
            invalid_source = true
            error(decode_error or "Cannot decode the daily image", 0)
        end

        local L = Layout.for_screen(width, height, style, contrast)
        local valid, why = Layout.validate(L)
        if not valid then error(why) end
        local meta = load_meta(source) or { date = source:match("(%d%d%d%d%d%d%d%d)%.jpg$") or "" }
        local colors = L.colors
        local function color(v) return Blitbuffer.Color8(v) end

        local panel_w = L.card and L.card.w or width
        local panel_h = L.card and L.card.h or height
        panel = Blitbuffer.new(panel_w, panel_h, Blitbuffer.TYPE_BB8)
        if L.card then panel:paintRect(0, 0, panel_w, panel_h, color(colors.card)) end
        paint_content(panel, L, meta, original, Blitbuffer, RenderImage)

        if L.card then
            canvas = Blitbuffer.new(width, height, Blitbuffer.TYPE_BB8)
            canvas:paintRect(0, 0, width, height, color(colors.canvas))
            local c = L.card
            for row = 0, panel_h - 1 do
                local inset = Layout.row_inset(row, panel_h, c.radius, c.radius)
                local left = math.max(0, inset)
                local right = math.min(panel_w, panel_w - inset)
                if right > left then
                    canvas:blitFrom(panel, c.x + left, c.y + row, left, row, right - left, 1)
                end
            end
            paint_text("ONE · 一个", L.header, L.fonts.header, L.fonts.header,
                color(colors.text), color(colors.canvas), "center", canvas)
            paint_text(Layout.footer_text(meta), L.footer, L.fonts.footer, L.fonts.footer,
                color(colors.text), color(colors.canvas), "center", canvas)
        else
            canvas = panel
            panel = nil
        end

        eink = Blitbuffer.new(width, height, Blitbuffer.TYPE_BB8)
        eink:ditherblitFrom(canvas, 0, 0, 0, 0, width, height)
        local called, written, detail = eink:writeToFile(target, "png")
        assert(called and written ~= false, detail or written or "Cannot write the wallpaper PNG")
        assert(valid_png(target, lfs.attributes(target)), "Incomplete wallpaper PNG")
        return true
    end)

    if panel then panel:free() end
    if canvas then canvas:free() end
    if eink then eink:free() end
    if original then original:free() end
    if not ok then
        logger.warn("一页壁纸: 渲染失败", tostring(err))
        return false, tostring(err), invalid_source
    end
    return true, nil, invalid_source
end

-- ---------------------------------------------------------------------------
-- Cache and publish (from danxiangli.koplugin)
-- ---------------------------------------------------------------------------

local function cache_key(path)
    return path:match("^(.*%.png)%.pending%d*$") or path
end

local function cache_date(path)
    return path:match("(%d%d%d%d%d%d%d%d)%-[^/]+$")
end

local function generated_images(dir)
    local paths = {}
    if lfs.attributes(dir, "mode") ~= "directory" then return paths end
    for name in lfs.dir(dir) do
        if cache_key(name):match("^%d%d%d%d%d%d%d%d%-.+%.png$")
            and lfs.attributes(dir .. name, "mode") == "file" then
            paths[#paths + 1] = dir .. name
        end
    end
    return paths
end

local function remove_wallpaper(path)
    local removed, err = os.remove(path)
    if not removed then logger.warn("一页壁纸: 无法清理壁纸", path, tostring(err)) end
end

local function prune_replaced_cache(paths, keep, date)
    for _, path in ipairs(paths) do
        if path ~= keep and cache_date(path) <= date then remove_wallpaper(path) end
    end
end

local function find_cached_wallpaper(paths, newer_than, cache_style)
    table.sort(paths, function(a, b)
        local left, right = cache_key(a), cache_key(b)
        if left ~= right then return left > right end
        return a < b
    end)
    local failure
    for _, path in ipairs(paths) do
        local d, rest = cache_key(path):match("(%d%d%d%d%d%d%d%d)%-(.+)%.png$")
        local matches = rest and cache_style and rest:sub(1, #cache_style) == cache_style
        if not newer_than or (d and d > newer_than and matches) then
            local valid = cached_png_is_valid(path)
            if valid then return path end
            if valid == false then
                remove_wallpaper(path)
            else
                failure = "Cannot verify the cached wallpaper"
            end
        end
    end
    return nil, failure
end

local function copy_png(source, target, size)
    local input, err = io.open(source, "rb")
    if not input then return nil, err end
    local output
    output, err = io.open(target, "wb")
    if not output then
        input:close()
        return nil, err
    end
    local remaining = size
    while remaining > 0 do
        local length = math.min(remaining, 64 * 1024)
        local data, read_error = input:read(length)
        if not data or #data ~= length then
            err = read_error or "Incomplete wallpaper read"
            break
        end
        local wrote
        wrote, err = output:write(data)
        if not wrote then break end
        remaining = remaining - length
    end
    input:close()
    local closed, close_error = output:close()
    if remaining ~= 0 or not closed then return nil, err or close_error or "Cannot copy the wallpaper" end
    return true
end

local function publish_wallpaper(source, dir, refreshed)
    local target = dir .. "wallpaper.png"
    local attrs = lfs.attributes(target)
    local previous = published_png and published_png.target == target and published_png
    local display_verified = previous and same_file(attrs, previous.target_attrs)
    local source_attrs = source and lfs.attributes(source)
    if not refreshed and display_verified and source == previous.source and same_file(source_attrs, previous.source_attrs) then
        return true, nil, true
    end

    local failure
    if source then
        if not source_attrs or source_attrs.mode ~= "file" or source_attrs.size > MAX_PNG_BYTES then
            failure = "Cannot read the wallpaper for display"
        else
            local ready
            ready, failure = util.makePath(dir)
            if ready then
                local tmp = target .. ".tmp"
                ready, failure = copy_png(source, tmp, source_attrs.size)
                if ready then
                    if valid_png(tmp, lfs.attributes(tmp)) then
                        ready, failure = os.rename(tmp, target)
                    else
                        ready, failure = false, "Invalid wallpaper display copy"
                    end
                end
                if ready then
                    published_png = { source = source, source_attrs = source_attrs, target = target,
                        target_attrs = lfs.attributes(target) }
                    return true, nil, true
                end
                os.remove(tmp)
            end
            failure = failure or "Cannot publish the wallpaper"
        end
        logger.warn("一页壁纸: 无法发布屏保图片", tostring(failure))
    end
    if display_verified then return true, failure end
    if not attrs then return false, failure end
    local valid = valid_png(target, attrs)
    if valid then
        published_png = { target = target, target_attrs = attrs }
        return true, failure
    end
    if valid == false then remove_wallpaper(target) end
    return false, failure or "Cannot verify the displayed wallpaper"
end

function Wallpaper.prepare(dir, source, style, refresh, verify_cache, display_dir)
    if verify_cache then verified_png, published_png = nil, nil end
    style = Layout.style(style)
    local settings = G_reader_settings
    local contrast = Layout.contrast(settings and settings.readSetting
        and settings:readSetting("onepage_contrast") or nil)
    local cache_style = style .. "-" .. contrast
    local previous = generated_images(dir)
    local tmp = dir .. "wallpaper.png.tmp"
    os.remove(tmp)
    local failure, invalid_source
    if source then
        local attrs = lfs.attributes(source)
        local date = source:match("(%d%d%d%d%d%d%d%d)%.jpg$")
        if attrs and date then
            local screen = require("device").screen
            local sw, sh = screen:getWidth(), screen:getHeight()
            local width, height = math.min(sw, sh), math.max(sw, sh)
            local key = string.format("%s-%s-v%d-%dx%d-%d-%d.png", date, cache_style,
                Wallpaper.CACHE_VERSION, width, height, attrs.modification, attrs.size)
            local target = dir .. key
            local ready = not refresh and cached_png_is_valid(target)
            local rendered
            if not ready then
                local made, mkdir_err = util.makePath(dir)
                if made then
                    ready, failure, invalid_source = render(source, tmp, width, height, style, contrast)
                    if ready then
                        ready, failure = os.rename(tmp, target)
                        if ready then
                            rendered = true
                            verified_png = { path = target, attrs = lfs.attributes(target) }
                        end
                    end
                    os.remove(tmp)
                else
                    failure = mkdir_err
                end
            end
            if ready then
                local candidate = find_cached_wallpaper(previous, date, cache_style) or target
                local available, publish_error, published = publish_wallpaper(candidate, display_dir,
                    rendered and candidate == target)
                if rendered and published then prune_replaced_cache(previous, target, date) end
                return available, publish_error, invalid_source
            end
        end
        failure = failure or "Cannot prepare the wallpaper"
        logger.warn("一页壁纸: 壁纸生成失败", tostring(failure))
    end
    local candidate, cache_error = find_cached_wallpaper(previous)
    local available, publish_error = publish_wallpaper(candidate, display_dir)
    return available, failure or publish_error or cache_error, invalid_source
end

return Wallpaper
