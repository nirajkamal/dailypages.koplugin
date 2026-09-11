-- Daily Pages -- theme tokens.
--
-- Every visual constant the views use lives here, so adding a theme in v2
-- means adding a table below, not touching layout code. Per THEMES.md the
-- themes are "shared skins, not independent apps": the geometry is fixed
-- (20% header / 73% passage / 7% page footer) and only the tokens change.
--
-- Paper is the only fully implemented skin in v1, per THEMES.md's "Paper is
-- first implementation; others remain roadmap items." The remaining ten
-- (Reading Card, Color Field, Boarding Pass, Modern Geometric, Pixel,
-- Receipt, Postcard, Collage, Folder, Landscape Day Calendar) are declared
-- here with their THEMES.md colors so v2 is a matter of filling in the few
-- layout exceptions (Folder's page-tab rail, Landscape's sidebar, Stacked
-- Pages' card edges) rather than re-plumbing anything.

local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")

local Theme = {}

-- THEMES.md "Suggested initial colors". On a grayscale e-ink panel these
-- flatten to near-white/near-black, which is exactly why the spec insists
-- "Color never solely indicates state" -- every status in the calendar and
-- reading views is carried by a glyph (check / open circle / dash / rule),
-- with color only reinforcing it.
local INK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local RULE = Blitbuffer.COLOR_GRAY
local FAINT = Blitbuffer.COLOR_LIGHT_GRAY

Theme.themes = {
    paper = {
        name = _("Paper"),
        tagline = _("Classic. Clear. Timeless."),
        implemented = true,
        -- Surfaces
        bg = WHITE,
        header_bg = WHITE,
        passage_bg = WHITE,
        footer_bg = WHITE,
        -- Ink
        fg = INK,
        dim_fg = Blitbuffer.Color8(0x55),
        rule = RULE,
        faint_rule = FAINT,
        accent = INK, -- Paper has no chromatic accent; the date is just bold
        -- Type: "White, black serif passage, bold sans date, fine rules"
        face_passage = "NotoSerif-Regular.ttf",
        face_heading = "NotoSerif-Regular.ttf",
        face_ui = "cfont",
        face_mono = "infont",
        heading_bold = true,
        -- Frame treatment
        border = 2,
        card_inset = false, -- Reading Card sets this; Paper sits flat on the page
        rule_between_header_cells = true,
    },
}

-- [ChatGPT] Reading Card: native flat surfaces, no decorative raster art.
local card = {}
for key, value in pairs(Theme.themes.paper) do card[key] = value end
card.name = _("Reading Card")
card.tagline = _("Warm. Focused. Collectible.")
card.bg = Blitbuffer.ColorRGB32(0xE8, 0xE6, 0xE1, 0xFF)
card.passage_bg = Blitbuffer.ColorRGB32(0xFF, 0xF2, 0xC9, 0xFF)
card.accent = Blitbuffer.ColorRGB32(0xA7, 0x47, 0x32, 0xFF)
card.card_inset = true
card.calendar_bg = WHITE
card.calendar_cell_bg = card.passage_bg
Theme.themes.reading_card = card

local field = {}
for key,value in pairs(Theme.themes.paper) do field[key]=value end
field.name=_("Color Field")
field.tagline=_("Bold. Calm. Contemporary.")
field.color_field=true
field.bg=Blitbuffer.ColorRGB32(0xF8,0xD8,0xC5,0xFF)
field.passage_bg=field.bg
field.header_bg=Blitbuffer.ColorRGB32(0xE6,0xEE,0xF1,0xFF)
field.date_bg=Blitbuffer.ColorRGB32(0xD7,0x7B,0x50,0xFF)
field.calendar_bg=Blitbuffer.COLOR_WHITE
field.calendar_cell_bg=field.bg
Theme.themes.color_field=field

-- Roadmap skins. Declared (so Appearance can list them honestly as coming
-- in v2) but not selectable -- picking one would silently render Paper and
-- look like a bug.
local roadmap = {
    { id = "reading_card", name = _("Reading Card"), tagline = _("Warm. Focused. Collectible.") },
    { id = "color_field", name = _("Color Field"), tagline = _("Bold. Calm. Contemporary.") },
    { id = "boarding_pass", name = _("Boarding Pass"), tagline = _("Condensed. Monospace. Cobalt.") },
    { id = "modern", name = _("Modern Geometric"), tagline = _("Geometric. Aligned. Accented.") },
    { id = "pixel", name = _("Pixel"), tagline = _("Stepped borders. Bitmap headings.") },
    { id = "receipt", name = _("Receipt"), tagline = _("Monospace. Dotted rules.") },
    { id = "postcard", name = _("Postcard"), tagline = _("Cream and blue correspondence.") },
    { id = "collage", name = _("Collage"), tagline = _("Cut-paper perimeter.") },
    { id = "folder", name = _("Folder"), tagline = _("Manila surfaces, page tabs.") },
    { id = "landscape", name = _("Landscape Day Calendar"), tagline = _("Sidebar date, wide passage.") },
}
for _i, t in ipairs(roadmap) do
    Theme.themes[t.id] = Theme.themes[t.id] or {
        name = t.name,
        tagline = t.tagline,
        implemented = false,
    }
end

Theme.default_id = "paper"

function Theme:get(id)
    local t = self.themes[id or Theme.default_id]
    if not t or not t.implemented then
        return self.themes[Theme.default_id]
    end
    return t
end

-- Ordered list for Appearance menus: implemented first, then roadmap.
function Theme:list()
    local out = { { id = "paper", theme = self.themes.paper } }
    for _i, t in ipairs(roadmap) do
        out[#out + 1] = { id = t.id, theme = self.themes[t.id] }
    end
    return out
end

-- ===================== Status glyphs =====================
-- CALENDAR.md §"Independent date cues": read = small check, unread = small
-- open mark, partial = half mark, skipped = dash, no assignment = number
-- only. These are text glyphs rather than icons so they survive any font
-- size and stay legible in pure grayscale.
Theme.glyph = {
    read = "\226\156\147",       -- check
    unread = "\226\151\139",     -- open circle
    partial = "\226\151\145",    -- half-filled circle
    skipped = "\226\128\148",    -- em dash
    today = "\226\128\162",      -- bullet (paired with the underline cue)
    none = "",
}

function Theme.glyphFor(status)
    if status == "completed" then return Theme.glyph.read end
    if status == "partial" then return Theme.glyph.partial end
    if status == "skipped" then return Theme.glyph.skipped end
    if status == "pending" then return Theme.glyph.unread end
    return Theme.glyph.none
end

function Theme.labelFor(status)
    if status == "completed" then return _("Read") end
    if status == "partial" then return _("Partly read") end
    if status == "skipped" then return _("Skipped") end
    if status == "pending" then return _("Unread") end
    return _("No reading")
end

return Theme
