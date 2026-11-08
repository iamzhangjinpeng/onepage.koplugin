--[[
onepage layout — pure geometry and typography for both wallpaper styles.

No KOReader modules are required here, so the whole file can be unit tested in
a stock Lua 5.1 runtime. All measurements are physical pixels; every value is
derived from the device screen, never from the 1080x1080 reference image.
]]

local Layout = { VERSION = 1, DEFAULT_STYLE = "fullscreen", DEFAULT_CONTRAST = "high" }

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function round(v) return math.floor(v + 0.5) end
Layout.round = round

function Layout.style(value)
    return (value == "card" and "card") or "fullscreen"
end

function Layout.contrast(value)
    return (value == "classic" and "classic") or "high"
end

function Layout.month_name(month)
    return MONTHS[tonumber(month) or 0] or "Jan"
end

-- Greys are 0..255. The classic palette reproduces the ONE app card; the high
-- contrast palette is the default because a #D9D9D9 panel turns muddy on a
-- 16-level e-ink panel.
local PALETTES = {
    classic = { canvas = 0xEE, card = 0xFF, cat = 0x4A, cat_text = 0xFF,
        info = 0xD9, date = 0xFA, text = 0x1A, rule = 0xC0 },
    high    = { canvas = 0xE8, card = 0xFF, cat = 0x22, cat_text = 0xFF,
        info = 0xFF, date = 0xFF, text = 0x00, rule = 0xBB },
}

-- Content layout inside an arbitrary rectangle. The ONE card divides its
-- height into photo / category band / text-and-date footer.
local function content_boxes(x, y, w, h, compact)
    local photo_h = round(h * (compact and 0.680 or 0.722))
    local cat_h = round(h * (compact and 0.045 or 0.049))
    local info_h = h - photo_h - cat_h
    local date_w = round(w * 0.176)
    return {
        x = x, y = y, w = w, h = h,
        photo = { x = x, y = y, w = w, h = photo_h },
        cat = { x = x, y = y + photo_h, w = w, h = cat_h },
        info = { x = x, y = y + photo_h + cat_h, w = w - date_w, h = info_h },
        date = { x = x + w - date_w, y = y + photo_h + cat_h, w = date_w, h = info_h },
    }
end

function Layout.for_screen(width, height, style, contrast)
    width, height = math.floor(tonumber(width) or 0), math.floor(tonumber(height) or 0)
    assert(width > 0 and height > 0, "invalid screen size")
    style, contrast = Layout.style(style), Layout.contrast(contrast)
    local palette = PALETTES[contrast]
    local result = {
        version = Layout.VERSION, style = style, contrast = contrast,
        width = width, height = height, colors = palette,
    }

    if style == "fullscreen" then
        result.card = nil
        result.content = content_boxes(0, 0, width, height, false)
        result.header = nil
        result.footer = nil
    else
        local margin_x = round(width * 0.067)
        local card_y = round(height * 0.115)
        local card_h = round(height * 0.740)
        local radius = round(math.min(width, height) * 0.045)
        local pad = round(width * 0.032)
        result.card = {
            x = margin_x, y = card_y,
            w = width - 2 * margin_x, h = card_h,
            radius = radius, pad = pad,
        }
        local c = result.card
        result.content = content_boxes(c.x + pad, c.y + pad, c.w - 2 * pad, c.h - 2 * pad, true)
        result.header = { x = c.x, y = round(card_y * 0.42), w = c.w, h = round(card_y * 0.38) }
        local below = height - (c.y + c.h)
        result.footer = { x = c.x, y = c.y + c.h + round(below * 0.30), w = c.w, h = round(below * 0.42) }
    end

    local box = result.content
    local unit = style == "card" and box.w or width
    result.fonts = {
        quote = math.max(11, round(unit * (style == "card" and 0.039 or 0.033))),
        quote_min = math.max(10, round(unit * 0.024)),
        category = math.max(10, round(unit * 0.022)),
        vol = math.max(10, round(unit * 0.022)),
        month = math.max(10, round(unit * 0.022)),
        day = math.max(24, round(unit * 0.092)),
        header = math.max(10, round(width * 0.019)),
        footer = math.max(10, round(width * 0.017)),
    }
    result.padding = round(unit * 0.032)
    return result
end

-- Horizontal inset for one row of a rounded card. The same arc equation is
-- used by danxiangli.koplugin to round every corner of a rectangular bitmap,
-- including the photo and the text panel, before blitting it onto the canvas.
function Layout.row_inset(y_in_card, card_h, radius_x, radius_y)
    if radius_x <= 0 or radius_y <= 0 then return 0 end
    local edge = math.min(y_in_card + 0.5, card_h - y_in_card - 0.5)
    if edge >= radius_y then return 0 end
    local arc = math.max(0, 1 - edge / radius_y)
    return round(radius_x * (1 - math.sqrt(1 - arc * arc)))
end

-- Invariants used by the tests and by the renderer before allocating buffers.
function Layout.validate(L)
    if not L or not L.content then return false, "missing layout" end
    local b = L.content
    if b.photo.h + b.cat.h + b.info.h ~= b.h then return false, "vertical split" end
    if b.info.w + b.date.w ~= b.w then return false, "horizontal split" end
    if L.card then
        local c = L.card
        if c.x < 0 or c.y < 0 or c.x + c.w > L.width or c.y + c.h > L.height then
            return false, "card out of canvas"
        end
        if b.x < c.x or b.y < c.y or b.x + b.w > c.x + c.w or b.y + b.h > c.y + c.h then
            return false, "content out of card"
        end
    end
    for name, size in pairs(L.fonts) do
        if size < 10 then return false, "font too small: " .. name end
    end
    return true
end

return Layout
