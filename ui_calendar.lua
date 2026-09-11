-- Daily Pages -- calendar.
--
-- Two layouts, per CALENDAR.md, both available in every theme:
--
--   Dots      number + status mark; tap a date to select, then "Open entry"
--             in a persistent detail panel below the grid.  (iteration 05)
--   Day boxes number + status + the entry's actual heading or excerpt inside
--             the cell; first tap selects, a second tap on the SAME date
--             opens. No detail panel, no chin.                (iteration 08)
--
-- The whole view is read-only with respect to the plan. Browsing months,
-- selecting dates and opening previews never allocate an assignment, move
-- the plan cursor, reschedule or mark anything read -- CALENDAR.md states
-- that three separate times, and it is the property most worth protecting
-- here, so all this file ever calls are query functions on the plugin.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("theme")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local CalendarView = InputContainer:extend{
    covers_fullscreen = true,
    plugin = nil,
    record = nil,
}

local MONTH_NAMES = { _("January"), _("February"), _("March"), _("April"),
    _("May"), _("June"), _("July"), _("August"), _("September"),
    _("October"), _("November"), _("December") }
-- Index 1 = Sunday, matching os.date's wday.
local WEEKDAY_INITIALS = { _("S"), _("M"), _("T"), _("W"), _("T"), _("F"), _("S") }
local WEEKDAY_SHORT = { _("Sun"), _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat") }

-- ===================== Calendar arithmetic =====================
-- Computed from real date arithmetic, never from the mockup rasters --
-- CALENDAR.md: "Compute dates, never copy raster numbers." Leap years come
-- free from os.time normalisation.

local function daysInMonth(year, month)
    local next_month = month == 12 and 1 or month + 1
    local next_year = month == 12 and year + 1 or year
    local first_next = os.time{ year = next_year, month = next_month, day = 1, hour = 12 }
    local last_this = os.date("*t", first_next - 86400)
    return last_this.day
end

local function weekdayOfFirst(year, month) -- 1 = Sunday
    return os.date("*t", os.time{ year = year, month = month, day = 1, hour = 12 }).wday
end

local function dateString(year, month, day)
    return string.format("%04d-%02d-%02d", year, month, day)
end

function CalendarView:init()
    self.theme = Theme:get(self.plugin:getSetting("theme"))
    self.layout = self.plugin:getSetting("calendar_layout") or "dots"
    self.cell_text_mode = self.plugin:getSetting("calendar_cell_text") or "heading"
    self.week_start = self.plugin:getSetting("week_start") or 2 -- 1=Sun, 2=Mon
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    self.today_str = self.plugin:today()
    local y, m = self.today_str:match("^(%d+)%-(%d+)")
    local now = {year=tonumber(y), month=tonumber(m)}
    self.view_year = self.view_year or now.year
    self.view_month = self.view_month or now.month

    -- CALENDAR.md: an initial or programmatic highlight is UNARMED -- so
    -- landing on the calendar and tapping today once selects it, and only a
    -- second tap opens. Arming is never inherited across view changes.
    self.selected_date = self.today_str
    self.armed_date = nil

    self.date_map = self.plugin:assignmentsByDate(self.record)

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    self:refresh()
end

function CalendarView:refresh()
    self:build()
    self[1] = FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        background = self.theme.calendar_bg or self.theme.bg,
        bordersize = 0,
        padding = 0,
        margin = 0,
        self.content,
    }
    UIManager:setDirty(self, "ui")
end

function CalendarView:build()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(16)
    local inner_w = screen_w - 2 * margin

    local header = self:buildHeader(inner_w)
    local monthnav = self:buildMonthNav(inner_w)
    local weekdays = self:buildWeekdayRow(inner_w)

    local used = header:getSize().h + monthnav:getSize().h + weekdays:getSize().h
    local footer, legend

    if self.layout == "dots" then
        legend = self:buildLegend(inner_w)
        footer = self:buildDetailPanel(inner_w)
        used = used + legend:getSize().h + footer:getSize().h
    else
        legend = self:buildModeStrip(inner_w)
        used = used + legend:getSize().h
    end

    local grid_h = screen_h - used - Screen:scaleBySize(48)
    local grid = self:buildGrid(inner_w, grid_h, margin)

    local rows = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = header:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, header } },
        LineWidget:new{ background = self.theme.rule,
            dimen = Geom:new{ w = screen_w, h = Size.line.thin } },
        LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = monthnav:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, monthnav } },
    }

    if self.layout == "boxes" then
        table.insert(rows, LineWidget:new{ background = self.theme.faint_rule,
            dimen = Geom:new{ w = screen_w, h = Size.line.thin } })
        table.insert(rows, LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = legend:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, legend } })
    end

    table.insert(rows, LineWidget:new{ background = self.theme.faint_rule,
        dimen = Geom:new{ w = screen_w, h = Size.line.thin } })
    table.insert(rows, LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = weekdays:getSize().h },
        HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, weekdays } })
    local grid_top = 0
    for _, child in ipairs(rows) do grid_top = grid_top + child:getSize().h end
    self.grid_origin_y = grid_top
    table.insert(rows, LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = grid_h },
        HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, grid } })

    if self.layout == "dots" then
        table.insert(rows, LineWidget:new{ background = self.theme.faint_rule,
            dimen = Geom:new{ w = screen_w, h = Size.line.thin } })
        table.insert(rows, LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = legend:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, legend } })
        table.insert(rows, LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = footer:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, footer } })
    end

    rows:resetLayout() -- measure the finished group, never a partial one
    self.content = rows
end

-- ===================== Header =====================

function CalendarView:buildHeader(inner_w)
    local back = Button:new{
        text = "\226\128\185 " .. _("Back"),
        text_font_face = self.theme.face_ui,
        text_font_size = 16,
        bordersize = Size.border.thin,
        radius = 0,
        padding_h = Screen:scaleBySize(10),
        padding_v = Screen:scaleBySize(6),
        show_parent = self,
        callback = function() self:onClose() end,
    }
    local today_btn = Button:new{
        text = _("Today"),
        text_font_face = self.theme.face_ui,
        text_font_size = 15,
        bordersize = Size.border.thin,
        radius = 0,
        padding_h = Screen:scaleBySize(12),
        padding_v = Screen:scaleBySize(5),
        show_parent = self,
        callback = function() self:onGoToday() end,
    }

    local cover_w = Screen:scaleBySize(42)
    local cover_h = Screen:scaleBySize(58)
    local cover = self.plugin:getCoverImage()
    local cover_widget
    if cover then
        cover_widget = FrameContainer:new{
            bordersize = Size.border.thin, color = self.theme.rule,
            padding = 0, margin = 0,
            ImageWidget:new{ image = cover, width = cover_w, height = cover_h, scale_factor = 0 },
        }
    else
        cover_widget = HorizontalSpan:new{ width = 0 }
    end

    local title = self.plugin:getBookTitle()
    local authors = self.plugin:getBookAuthors()
    local box_w=math.floor(inner_w*0.38)
    local row_gap=Screen:scaleBySize(10)
    local text_w = inner_w - cover_widget:getSize().w - today_btn:getSize().w - box_w - 3*row_gap
    local title_group = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = title,
            face = Font:getFace(self.theme.face_heading, 15),
            height = Screen:scaleBySize(38),
            height_overflow_show_ellipsis = true,
            bold = true,
            width = text_w,
            alignment = "left",
        },
    }
    if authors and authors ~= "" then
        table.insert(title_group, TextBoxWidget:new{
            text = authors,
            face = Font:getFace(self.theme.face_ui, 12),
            height = Screen:scaleBySize(18),
            height_overflow_show_ellipsis = true,
            width = text_w,
            fgcolor = self.theme.dim_fg,
            alignment = "left",
        })
    end

    local Logic=require("dailypages_logic")
    local current=Logic.computeStreak(self.record.plan,self.today_str)
    local previous=Logic.lastStreak(self.record.plan,self.today_str)
    local pad=Screen:scaleBySize(5)
    local col_w=math.floor((box_w-2*pad-2*Size.border.thin)/2)
    local function stat(label,value)
        return CenterContainer:new{dimen=Geom:new{w=col_w,h=Screen:scaleBySize(46)},
            VerticalGroup:new{align="center",
                TextWidget:new{text=label,face=Font:getFace(self.theme.face_ui,12)},
                TextWidget:new{text=tostring(value),face=Font:getFace(self.theme.face_ui,20),bold=true},
            }}
    end
    local streak_box=FrameContainer:new{padding=pad,margin=0,bordersize=Size.border.thin,
        color=self.theme.rule,radius=Screen:scaleBySize(4),
        HorizontalGroup:new{stat(_("Current streak"),current),stat(_("Last streak"),previous)}}
    return VerticalGroup:new{
        align = "left",
        back,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        HorizontalGroup:new{
            align = "center",
            cover_widget,
            HorizontalSpan:new{ width = row_gap },
            title_group,
            HorizontalSpan:new{ width = row_gap },
            streak_box,
            HorizontalSpan:new{ width = row_gap },
            today_btn,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
    }
end

function CalendarView:buildMonthNav(inner_w)
    local prev_btn = Button:new{
        text = "\226\128\185 " .. _("Month"),
        text_font_face = self.theme.face_ui, text_font_size = 15,
        bordersize = 0, padding_v = Screen:scaleBySize(8),
        width = math.floor(inner_w * 0.25), show_parent = self,
        callback = function() self:onChangeMonth(-1) end,
    }
    local next_btn = Button:new{
        text = _("Month") .. " \226\128\186",
        text_font_face = self.theme.face_ui, text_font_size = 15,
        bordersize = 0, padding_v = Screen:scaleBySize(8),
        width = math.floor(inner_w * 0.25), show_parent = self,
        callback = function() self:onChangeMonth(1) end,
    }
    -- The month label is the long-jump picker (CALENDAR.md: "Month/year
    -- opens long-jump picker"), so a five-year-old plan doesn't need sixty
    -- taps to reach.
    local label_btn = Button:new{
        text = T("%1 %2", MONTH_NAMES[self.view_month], self.view_year),
        text_font_face = self.theme.face_heading, text_font_size = 19,
        text_font_bold = false,
        bordersize = 0, padding_v = Screen:scaleBySize(8),
        width = math.floor(inner_w * 0.5), show_parent = self,
        callback = function() self:onJumpPicker() end,
    }
    return HorizontalGroup:new{ align = "center", prev_btn, label_btn, next_btn }
end

function CalendarView:buildWeekdayRow(inner_w)
    local col_w = math.floor(inner_w / 7)
    local group = HorizontalGroup:new{ align = "center" }
    for i = 0, 6 do
        local wday = ((self.week_start - 1 + i) % 7) + 1
        table.insert(group, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = Screen:scaleBySize(24) },
            TextWidget:new{
                text = WEEKDAY_INITIALS[wday],
                face = Font:getFace(self.theme.face_ui, 13),
                fgcolor = self.theme.dim_fg,
            },
        })
    end
    return group
end

function CalendarView:buildLegend(inner_w)
    -- CALENDAR.md: status is carried by the glyph; the legend spells the
    -- glyphs out so nothing depends on recognising a shape.
    local function item(glyph, label)
        return HorizontalGroup:new{
            align = "center",
            TextWidget:new{ text = glyph, face = Font:getFace(self.theme.face_ui, 14) },
            HorizontalSpan:new{ width = Screen:scaleBySize(5) },
            TextWidget:new{ text = label, face = Font:getFace(self.theme.face_ui, 13),
                fgcolor = self.theme.dim_fg },
        }
    end
    local spacer = HorizontalSpan:new{ width = Screen:scaleBySize(18) }
    return CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(30) },
        HorizontalGroup:new{
            align = "center",
            item(Theme.glyph.read, _("Read")), spacer,
            item(Theme.glyph.unread, _("Unread")), spacer,
            item(Theme.glyph.skipped, _("Skipped")),
        },
    }
end

function CalendarView:buildModeStrip(inner_w)
    -- Day boxes has no detail panel, so the cell-content choice lives here
    -- as a tappable strip, matching iteration 08's "Day boxes - Headings".
    local label = self.cell_text_mode == "excerpt" and _("Excerpts") or _("Headings")
    return CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(30) },
        Button:new{
            text = T(_("Day boxes \226\128\162 %1"), label),
            text_font_face = self.theme.face_ui, text_font_size = 14,
            bordersize = 0, padding_v = Screen:scaleBySize(4),
            show_parent = self,
            callback = function()
                self.cell_text_mode = self.cell_text_mode == "excerpt" and "heading" or "excerpt"
                self.plugin:setSetting("calendar_cell_text", self.cell_text_mode)
                self.armed_date = nil -- a view change clears arming
                self:refresh()
            end,
        },
    }
end

-- ===================== Grid =====================

function CalendarView:gridGeometry(inner_w, grid_h)
    local first_wday = weekdayOfFirst(self.view_year, self.view_month)
    local lead = (first_wday - self.week_start) % 7
    local ndays = daysInMonth(self.view_year, self.view_month)
    local rows_needed = math.ceil((lead + ndays) / 7)
    -- Dots reserves six rows so the detail panel underneath doesn't jump
    -- between months; Day boxes uses the month's real row count to give
    -- each cell as much text area as possible (CALENDAR.md).
    local rows = self.layout == "dots" and 6 or rows_needed
    return {
        lead = lead,
        ndays = ndays,
        rows = rows,
        col_w = math.floor(inner_w / 7),
        row_h = math.floor(grid_h / rows),
    }
end

function CalendarView:buildGrid(inner_w, grid_h, margin)
    local g = self:gridGeometry(inner_w, grid_h)
    self.grid_geom = g
    self.grid_origin_x = margin
    -- Remembered so onTap can map a screen point back to a date without
    -- asking every cell widget where it ended up.
    self.grid_origin_y = nil -- filled in on first paint below

    local grid = VerticalGroup:new{ align = "left" }
    local day = 1
    for row = 1, g.rows do
        local row_group = HorizontalGroup:new{ align = "center" }
        for col = 1, 7 do
            local cell_index = (row - 1) * 7 + col
            local cell
            if cell_index <= g.lead or day > g.ndays then
                -- Adjacent-month positions are blank and non-interactive.
                cell = CenterContainer:new{
                    dimen = Geom:new{w=g.col_w,h=g.row_h},
                    HorizontalSpan:new{ width = g.col_w },
                }
            else
                cell = self:buildCell(day, g.col_w, g.row_h)
                day = day + 1
            end
            table.insert(row_group, cell)
        end
        table.insert(grid, row_group)
    end
    return grid
end

function CalendarView:buildCell(day, col_w, row_h)
    local date = dateString(self.view_year, self.view_month, day)
    local items = self.date_map[date]
    local status = items and items.status or nil
    local is_today = (date == self.today_str)
    local is_selected = (date == self.selected_date)

    if self.layout == "dots" then
        return self:buildDotCell(day, date, items, status, is_today, is_selected, col_w, row_h)
    end
    return self:buildBoxCell(day, date, items, status, is_today, is_selected, col_w, row_h)
end

-- Dots: a circle carrying the number, the status glyph beneath it, a strong
-- ring for selection and an underline for today. All three cues are
-- independent so a date can be today AND selected AND read at once.
function CalendarView:buildDotCell(day, date, items, status, is_today, is_selected, col_w, row_h)
    local diameter = math.min(col_w, row_h) - Screen:scaleBySize(14)
    if diameter < Screen:scaleBySize(28) then diameter = Screen:scaleBySize(28) end

    local num = TextWidget:new{
        text = tostring(day),
        face = Font:getFace(self.theme.face_ui, 15),
        bold = is_selected,
        fgcolor = self.theme.fg,
    }
    local circle = FrameContainer:new{
        bordersize = is_selected and Size.border.thick or Size.border.thin,
        color = items and self.theme.fg or self.theme.faint_rule,
        radius = math.floor(diameter / 2),
        padding = 0, margin = 0,
        width = diameter, height = diameter,
        CenterContainer:new{
            dimen = Geom:new{ w = diameter - 2, h = diameter - 2 },
            num,
        },
    }

    local cues = VerticalGroup:new{ align = "center", circle }
    if is_today then
        table.insert(cues, LineWidget:new{
            background = self.theme.fg,
            dimen = Geom:new{ w = math.floor(diameter * 0.5), h = Size.line.thick },
        })
    end
    if status then
        table.insert(cues, TextWidget:new{
            text = Theme.glyphFor(status),
            face = Font:getFace(self.theme.face_ui, 12),
            fgcolor = self.theme.fg,
        })
    end

    return CenterContainer:new{ dimen = Geom:new{ w = col_w, h = row_h }, cues }
end

-- Day boxes: number top-left, status glyph top-right, the entry's real
-- heading (or a real excerpt) filling the rest. No generated summaries --
-- extraction unavailable falls back to the heading, then to "Entry N".
function CalendarView:buildBoxCell(day, date, items, status, is_today, is_selected, col_w, row_h)
    -- Every cell must occupy EXACTLY col_w x row_h regardless of its border
    -- weight or how much text it holds. Letting either vary is what made the
    -- grid stagger: HorizontalGroup lays children out by their own reported
    -- size, so one taller cell shoves its whole row out of alignment, and a
    -- thick selection border made the selected cell bigger than its
    -- neighbours. So the frame is sized to a fixed box, the border is always
    -- the same thickness (selection is carried by its colour), and the text
    -- is given an explicit height budget with ellipsis.
    local border = Size.border.thin
    local pad = Screen:scaleBySize(3)
    local frame_w = col_w
    local frame_h = row_h
    local content_w = frame_w - 2 * (pad + border)
    local content_h = frame_h - 2 * (pad + border)

    local num_face = Font:getFace(self.theme.face_ui, 14)
    local num_widget = TextWidget:new{
        text = tostring(day),
        face = num_face,
        bold = is_selected,
        fgcolor = self.theme.fg,
    }
    local glyph_widget = TextWidget:new{
        text = status and Theme.glyphFor(status) or "",
        face = Font:getFace(self.theme.face_ui, 11),
        fgcolor = self.theme.fg,
    }
    local gap = content_w - num_widget:getSize().w - glyph_widget:getSize().w
    if gap < 0 then gap = 0 end
    local top_row = HorizontalGroup:new{
        align = "top",
        num_widget,
        HorizontalSpan:new{ width = gap },
        glyph_widget,
    }

    local group = VerticalGroup:new{ align = "left", top_row }
    local used_h = top_row:getSize().h

    if is_today then
        local rule_h = Size.line.thick
        table.insert(group, LineWidget:new{
            background = self.theme.fg,
            dimen = Geom:new{ w = math.floor(content_w * 0.35), h = rule_h },
        })
        used_h = used_h + rule_h
    end

    -- Whatever vertical space is left after the number row is the text's
    -- budget. If a single line will not fit, the cell shows the number only
    -- rather than spilling past its bounds.
    if items then
        local text_face = Font:getFace(self.theme.face_passage, 13)
        local line_h = TextBoxWidget:new{
            text = "X", face = text_face, width = content_w,
        }:getLineHeight()
        local avail = content_h - used_h - Screen:scaleBySize(2)
        if line_h and avail >= line_h then
            local label = self.plugin:cellTextFor(self.record, items, self.cell_text_mode)
            if label and label ~= "" then
                local lines = math.floor(avail / line_h)
                table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(2) })
                table.insert(group, TextBoxWidget:new{
                    text = label,
                    bgcolor = self.theme.calendar_cell_bg or self.theme.bg,
                    face = text_face,
                    width = content_w,
                    height = lines * line_h,
                    height_overflow_show_ellipsis = true,
                    alignment = "left",
                    fgcolor = self.theme.fg,
                })
            end
        end
    end

    local frame = FrameContainer:new{
        bordersize = border,
        -- Selection is a colour change, not a thickness change, so the box
        -- never resizes when it becomes selected.
        color = is_selected and self.theme.fg or self.theme.faint_rule,
        padding = pad,
        margin = 0,
        width = frame_w,
        height = frame_h,
        background = self.theme.calendar_cell_bg or self.theme.bg,
        inner_bordersize = is_selected and Size.border.thin or 0,
        InputContainer:new{
            dimen = Geom:new{w=content_w,h=content_h},
            group,
        },
    }

    -- Hard-clamp the footprint: even if something inside still misreports its
    -- height, the grid geometry stays uniform.
    return CenterContainer:new{
        dimen = Geom:new{ w = col_w, h = row_h },
        frame,
    }
end

-- ===================== Detail panel (Dots only) =====================

function CalendarView:buildDetailPanel(inner_w)
    local date = self.selected_date
    local items = self.date_map[date]
    local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    local wday = os.date("*t", os.time{ year = y, month = m, day = d, hour = 12 }).wday
    local date_label = T(_("%1, %2 %3"), WEEKDAY_SHORT[wday]:upper(), d, MONTH_NAMES[m])

    local group = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        TextWidget:new{
            text = date_label,
            face = Font:getFace(self.theme.face_ui, 12),
            fgcolor = self.theme.dim_fg,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
    }

    if not items then
        table.insert(group, TextWidget:new{
            text = _("No reading scheduled"),
            face = Font:getFace(self.theme.face_heading, 17),
            fgcolor = self.theme.dim_fg,
        })
    else
        table.insert(group, TextBoxWidget:new{
            text = items.title or _("Entry"),
            face = Font:getFace(self.theme.face_heading, 18),
            bold = true,
            width = inner_w - Screen:scaleBySize(20),
            alignment = "left",
        })
        local status_line = Theme.labelFor(items.status)
        if items.is_future then
            -- A future date is a forecast, never an allocated assignment.
            status_line = _("Planned")
        end
        table.insert(group, TextWidget:new{
            text = T("%1 \226\128\162 %2", status_line,
                T(_("Entry %1"), items.entry_index or "?")),
            face = Font:getFace(self.theme.face_ui, 13),
            fgcolor = self.theme.dim_fg,
        })
        table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(8) })
        table.insert(group, Button:new{
            text = items.is_future and _("Preview entry") or _("Open entry"),
            text_font_face = self.theme.face_ui,
            text_font_size = 15,
            bordersize = Size.border.thin,
            radius = 0,
            padding_v = Screen:scaleBySize(7),
            width = math.floor(inner_w * 0.55),
            show_parent = self,
            callback = function() self:openDate(date) end,
        })
    end

    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    table.insert(group, TextWidget:new{
        -- The single most important sentence on this screen.
        text = _("Selecting a date does not mark it read."),
        face = Font:getFace(self.theme.face_ui, 11),
        fgcolor = self.theme.dim_fg,
    })
    return group
end

-- ===================== Interaction =====================

function CalendarView:onTap(_arg, ges)
    if not (self.grid_geom and ges.pos) then return false end
    local g = self.grid_geom
    -- The grid's y origin isn't known until the layout is painted, so it is
    -- recovered from the cell rows themselves via the content group.
    local origin_y = self:gridTopY()
    if not origin_y then return false end

    local x, y = ges.pos.x, ges.pos.y
    if y < origin_y or y >= origin_y + g.rows * g.row_h then return false end
    if x < self.grid_origin_x or x >= self.grid_origin_x + 7 * g.col_w then return false end

    local col = math.floor((x - self.grid_origin_x) / g.col_w)
    local row = math.floor((y - origin_y) / g.row_h)
    local cell_index = row * 7 + col + 1
    local day = cell_index - g.lead
    if day < 1 or day > g.ndays then return true end -- blank position: inert

    self:onSelectDay(dateString(self.view_year, self.view_month, day))
    return true
end

-- Locate the grid's top edge by summing the heights of everything above it
-- in the content group. Cheaper and less fragile than storing coordinates
-- during paint.
function CalendarView:gridTopY()
    if self.grid_origin_y then return self.grid_origin_y end
    if not self.content then return nil end
    local y = 0
    for _i, w in ipairs(self.content) do
        local size = w:getSize()
        -- The grid is the tall LeftContainer whose height matches rows*row_h.
        if self.grid_geom and math.abs(size.h - self.grid_geom.rows * self.grid_geom.row_h) < 2 then
            return y
        end
        y = y + size.h
    end
    return nil
end

function CalendarView:onSelectDay(date)
    if self.layout == "dots" then
        -- Dots: tapping only ever selects; opening is the explicit button.
        self.selected_date = date
        self:refresh()
        return
    end
    -- Day boxes: first tap selects and arms; a second tap on the SAME date
    -- opens. No timing window -- a slow second tap works exactly like a
    -- fast one (CALENDAR.md: "No double-tap timing window").
    if self.selected_date == date and self.armed_date == date then
        self:openDate(date)
        return
    end
    self.selected_date = date
    self.armed_date = date
    self:refresh()
end

function CalendarView:openDate(date)
    local items = self.date_map[date]
    if not items then return end -- empty days select but cannot open
    if items.count and items.count > 1 then
        -- Multiple entries on one date: pick explicitly, never silently
        -- open the first.
        local buttons = {}
        for _i, entry in ipairs(items.entries) do
            buttons[#buttons + 1] = {{
                text = T("%1  %2", Theme.glyphFor(entry.status), entry.title),
                callback = function()
                    UIManager:close(self._picker)
                    self:openEntryIndex(entry.entry_index, items.is_future)
                end,
            }}
        end
        self._picker = ButtonDialog:new{
            title = _("Which entry?"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(self._picker)
        return
    end
    self:openEntryIndex(items.entry_index, items.is_future)
end

function CalendarView:openEntryIndex(entry_index, is_future)
    self.armed_date = nil
    self.plugin:openEntryFromCalendar(entry_index, is_future, self.selected_date)
end

function CalendarView:onChangeMonth(delta)
    local m = self.view_month + delta
    local y = self.view_year
    if m < 1 then m, y = 12, y - 1 elseif m > 12 then m, y = 1, y + 1 end
    self.view_month, self.view_year = m, y
    -- A month change is a view change: the selection is programmatic and
    -- therefore unarmed.
    self.selected_date = dateString(y, m, 1)
    self.armed_date = nil
    self:refresh()
    return true
end

function CalendarView:onGoToday()
    local y, m = self.today_str:match("^(%d+)%-(%d+)")
    self.view_year, self.view_month = tonumber(y), tonumber(m)
    self.selected_date = self.today_str
    self.armed_date = nil -- Today selects only; it never opens
    self:refresh()
    return true
end

function CalendarView:onJumpPicker()
    local buttons = {}
    local now = os.date("*t")
    -- A modest window either side of the plan's own span is enough for a
    -- long-jump without becoming a second calendar.
    for y = now.year - 1, now.year + 2 do
        local row = {}
        row[#row + 1] = {
            text = tostring(y),
            callback = function()
                UIManager:close(self._jump)
                self.view_year = y
                self.selected_date = dateString(y, self.view_month, 1)
                self.armed_date = nil
                self:refresh()
            end,
        }
        buttons[#buttons + 1] = row
    end
    local month_row = {}
    for m = 1, 12 do
        month_row[#month_row + 1] = {
            text = MONTH_NAMES[m]:sub(1, 3),
            callback = function()
                UIManager:close(self._jump)
                self.view_month = m
                self.selected_date = dateString(self.view_year, m, 1)
                self.armed_date = nil
                self:refresh()
            end,
        }
        if #month_row == 4 then
            buttons[#buttons + 1] = month_row
            month_row = {}
        end
    end
    self._jump = ButtonDialog:new{
        title = _("Jump to"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self._jump)
    return true
end

function CalendarView:onSwipe(_arg, ges)
    -- Optional grid swipe changes MONTH -- never an entry or a page.
    if ges.direction == "west" then return self:onChangeMonth(1) end
    if ges.direction == "east" then return self:onChangeMonth(-1) end
    if ges.direction == "south" then return self:onClose() end
    return true
end

function CalendarView:onClose()
    UIManager:close(self)
    self.plugin:onCalendarClosed()
    return true
end

function CalendarView:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

return CalendarView
