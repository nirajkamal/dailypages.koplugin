-- Daily Pages -- the reading view.
--
-- Layout follows THEMES.md's shared geometry and iteration 03 (Paper):
--
--   +----------------------------------------------+
--   | cover | 09  [cal]   |    23/120              |  header row 1
--   |       | SEP 2026    |    [============--]    |
--   |       | WED         |                        |
--   +----------------------------------------------+
--   | ENTRY  |< ][ >|  |  [ Mark read ]   X        |  header row 2
--   +----------------------------------------------+
--   | ENTRY 24                                     |
--   | Begin with attention                         |  passage (~73%)
--   | Before the day gathers speed, notice ...     |
--   +----------------------------------------------+
--   | < Page      Page 1 of 2         Page >       |  footer (~7%)
--   +----------------------------------------------+
--
-- The two rows of controls are deliberately different things and DESIGN.md
-- §6 is emphatic about not conflating them: the header transport moves by
-- ENTRY, the footer moves by PAGE within the current entry. Page turns
-- never cross an entry boundary and never complete anything.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookIndex = require("bookindex")
local Theme = require("theme")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen
local ASSET_DIR = debug.getinfo(1, "S").source:sub(2):match("(.*/)" ) or "./"

local TodayView = InputContainer:extend{
    covers_fullscreen = true,
    -- injected by the caller
    plugin = nil,        -- the DailyPages plugin instance (for state + actions)
    record = nil,        -- { plan = <logic plan>, entries = <entry array>, ... }
    entry_index = nil,   -- which entry is displayed
    browsing = false,    -- true when showing something other than the assigned entry
}

local MONTHS = { _("JAN"), _("FEB"), _("MAR"), _("APR"), _("MAY"), _("JUN"),
                 _("JUL"), _("AUG"), _("SEP"), _("OCT"), _("NOV"), _("DEC") }
local WEEKDAYS = { _("SUN"), _("MON"), _("TUE"), _("WED"), _("THU"), _("FRI"), _("SAT") }

function TodayView:init()
    self.theme = Theme:get(self.plugin:getSetting("theme"))
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.page_num = 1

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
        self.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end
    self:refresh()
end

-- Rebuild the whole view from current state. Cheap enough on e-ink (one
-- full refresh) and much safer than trying to patch sub-widgets in place.
function TodayView:refresh()
    self:buildContent()
    self[1] = FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        background = self.theme.bg,
        bordersize = 0,
        padding = 0,
        margin = 0,
        self.content,
    }
    UIManager:setDirty(self, "ui")
end

function TodayView:buildContent()
    -- Rebuilds replace the old text widget; release its native text buffers.
    if self.body then self.body:free(); self.body = nil end
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(20)
    local inner_w = screen_w - 2 * margin

    local header = self:buildHeader(inner_w, margin)

    -- There is a genuine circularity here: the passage needs to know how
    -- much height the footer leaves, but the footer's "Page x of y" can
    -- only be known once the passage widget exists to be measured. So the
    -- footer is built twice -- once purely to measure (its height doesn't
    -- depend on the numbers, only on the font), and again afterwards with
    -- the real counts. Building it once, first, is what produced a footer
    -- permanently stuck on "Page 1 of 1" with the next-page button
    -- disabled, because self.body was still nil when it was measured.
    local footer_probe = self:buildFooter(inner_w)

    -- Passage takes whatever the header and footer leave. Measuring rather
    -- than assuming 73% keeps the text area correct at large font sizes,
    -- where the chrome legitimately grows (THEMES.md: "Large-font layout
    -- can grow chrome and paginate more").
    local header_h = header:getSize().h
    local footer_h = footer_probe:getSize().h
    local passage_h = screen_h - header_h - footer_h - Screen:scaleBySize(24)
    if passage_h < Screen:scaleBySize(120) then
        passage_h = Screen:scaleBySize(120)
    end

    if self.theme.card_inset then
        return self:buildCardContent(screen_w, screen_h, margin)
    end
    if self.theme.color_field then
        return self:buildColorField(screen_w,screen_h,margin,header)
    end
    self.passage_tap_zone = Geom:new{x=0,y=Screen:scaleBySize(18)+header_h+Size.line.thin,w=screen_w,h=passage_h}
    local passage = self:buildPassage(inner_w, passage_h)
    local footer = self:buildFooter(inner_w) -- now self.body exists

    self.content = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = header_h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, header } },
        LineWidget:new{
            background = self.theme.rule,
            dimen = Geom:new{ w = screen_w, h = Size.line.thin },
        },
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = passage_h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, passage } },
        LineWidget:new{
            background = self.theme.faint_rule,
            dimen = Geom:new{ w = screen_w, h = Size.line.thin },
        },
        LeftContainer:new{ dimen = Geom:new{ w = screen_w, h = footer_h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, footer } },
    }
end

function TodayView:buildColorField(w,h,margin,header)
    local top=Screen:scaleBySize(8)
    local gap=Screen:scaleBySize(16)
    local inner=w-2*margin
    local header_h=header:getSize().h+top
    local footer=self:buildFooter(inner)
    local footer_h=footer:getSize().h
    footer:free()
    local body_h=h-header_h-gap-footer_h-Screen:scaleBySize(3)
    local passage=self:buildPassage(inner,body_h)
    self.passage_tap_zone=Geom:new{x=0,y=header_h,w=w,h=gap+body_h}
    local function surface(child,height,bg)
        return FrameContainer:new{background=bg,bordersize=0,padding=0,margin=0,
            LeftContainer:new{dimen=Geom:new{w=w,h=height},child}}
    end
    self.content=VerticalGroup:new{align="left",
        surface(VerticalGroup:new{align="left",VerticalSpan:new{width=top},
            HorizontalGroup:new{HorizontalSpan:new{width=margin},header}},header_h,self.theme.header_bg),
        surface(VerticalGroup:new{align="left",VerticalSpan:new{width=gap},
            HorizontalGroup:new{HorizontalSpan:new{width=margin},
                LeftContainer:new{dimen=Geom:new{w=inner,h=body_h},passage}},
            self:buildFooter(w),VerticalSpan:new{width=Screen:scaleBySize(3)}},h-header_h,self.theme.passage_bg),
    }
end

-- Fixed card geometry is reserved before pagination; edge is decoration only.
function TodayView:buildCardContent(w, h, margin)
    local outer = Screen:scaleBySize(12)
    local gap = Screen:scaleBySize(10)
    local pad = Screen:scaleBySize(18)
    local edge = Screen:scaleBySize(6)
    local border = Size.border.thin
    local shell_w = w - 2 * outer
    local text_w = shell_w - edge - 2 * border - 2 * pad
    local header = self:buildHeader(w - 2 * margin, margin)
    local header_h = header:getSize().h
    local probe = self:buildFooter(shell_w)
    local footer_h = probe:getSize().h
    probe:free()
    local card_h = h - 2 * outer - gap - header_h
    local bottom_pad = Screen:scaleBySize(2)
    local number_gap = Screen:scaleBySize(2)
    local body_h = card_h - 2 * border - pad - bottom_pad - footer_h - number_gap
    self.passage_tap_zone = Geom:new{x=outer,y=outer+header_h+gap,w=shell_w,h=border+pad+body_h}
    local passage = self:buildPassage(text_w, body_h)
    local card = FrameContainer:new{
        background = self.theme.passage_bg, color = self.theme.fg,
        bordersize = border, radius = Screen:scaleBySize(5),
        padding = 0, margin = 0,
        HorizontalGroup:new{HorizontalSpan:new{width=pad},
        VerticalGroup:new{align="left",
            VerticalSpan:new{width=pad},
            LeftContainer:new{dimen = Geom:new{w=text_w, h=body_h}, passage},
            VerticalSpan:new{width=number_gap},
            self:buildFooter(text_w),
            VerticalSpan:new{width=bottom_pad},
        }, HorizontalSpan:new{width=pad}},
    }
    local card_row = HorizontalGroup:new{align="center", card,
        FrameContainer:new{background=self.theme.accent, bordersize=0, padding=0, margin=0,
            InputContainer:new{dimen=Geom:new{w=edge,h=card_h}}},
    }
    local function surface(child, width, height, inset)
        return FrameContainer:new{
            background=self.theme.header_bg, bordersize=0, padding=0, margin=0,
            LeftContainer:new{dimen=Geom:new{w=width,h=height},
                HorizontalGroup:new{HorizontalSpan:new{width=inset or 0}, child}},
        }
    end
    self.date_tap_zone.y = self.date_tap_zone.y + outer
    self.cover_tap_zone.y = self.cover_tap_zone.y + outer
    self.content = VerticalGroup:new{align="left",
        VerticalSpan:new{width=outer},
        HorizontalGroup:new{HorizontalSpan:new{width=outer},
            surface(header,shell_w,header_h,margin-outer)},
        VerticalSpan:new{width=gap},
        HorizontalGroup:new{HorizontalSpan:new{width=outer},card_row},
        VerticalSpan:new{width=outer},
    }
end

-- ===================== Header =====================

function TodayView:buildHeader(inner_w, margin_left)
    local plan = self.record.plan

    -- Three cells of fixed width separated by full-height rules, as in
    -- iteration 03. Fixing the widths (rather than letting each cell size
    -- to its contents) is what keeps the rules vertically aligned and stops
    -- the row reflowing as the date, the progress numbers or the cover
    -- change from book to book and day to day.
    -- Three equal cells, each with its content centred, divided by rules --
    -- the same thirds the page footer uses, which is why the footer reads
    -- as evenly spaced and this row previously did not. Sizing the cells to
    -- their contents instead left the middle cell hugging the cover and the
    -- progress adrift in whatever space was left over.
    local cell_h = Screen:scaleBySize(86)
    local cover_h = cell_h - Screen:scaleBySize(6)
    local cover_w = Screen:scaleBySize(60)
    local rule_w = Size.line.thin
    local cell_w = math.floor((inner_w - 2 * rule_w) / 3)

    local function vrule()
        return LineWidget:new{
            background = self.theme.faint_rule,
            dimen = Geom:new{ w = rule_w, h = cell_h },
        }
    end

    -- --- cell 1: the real cover, natural ratio, thumbnail size ---
    local cover_widget
    local cover_image = self.plugin:getCoverImage()
    if cover_image then
        cover_widget = FrameContainer:new{
            bordersize = Size.border.thin,
            color = self.theme.rule,
            padding = 0,
            margin = 0,
            ImageWidget:new{
                image = cover_image,
                width = cover_w - 2 * Size.border.thin,
                height = cover_h - 2 * Size.border.thin,
                scale_factor = 0, -- fit inside, keep the book's own aspect ratio
            },
        }
    else
        -- No cover in the file: a labelled placeholder, never a stand-in image.
        cover_widget = FrameContainer:new{
            bordersize = Size.border.thin,
            color = self.theme.rule,
            padding = Size.padding.small,
            margin = 0,
            width = cover_w,
            height = cover_h,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w - Screen:scaleBySize(8),
                                  h = cover_h - Screen:scaleBySize(8) },
                TextBoxWidget:new{
                    text = self.plugin:getBookTitle(),
                    face = Font:getFace(self.theme.face_ui, 9),
                    width = cover_w - Screen:scaleBySize(10),
                    height = cover_h - Screen:scaleBySize(10),
                    height_overflow_show_ellipsis = true,
                    alignment = "center",
                },
            },
        }
    end

    -- --- cell 2: the date, tappable, opening the calendar ---
    -- Bundled vector icon; the entire date cell opens the calendar.
    local display_date = self.display_date or self.plugin:today()
    if not self.display_date then
        for _, id in ipairs(plan.assignment_order or {}) do
            local a = plan.assignments[id]
            for _, entry_id in ipairs(a.entry_ids or {}) do
                if tonumber(entry_id) == self.entry_index then
                    display_date = a.occurrence_date or a.due_date or display_date
                end
            end
        end
    end
    local y, m, d = display_date:match("^(%d+)%-(%d+)%-(%d+)$")
    local now = os.date("*t", os.time{year=tonumber(y), month=tonumber(m), day=tonumber(d), hour=12})
    local date_group = VerticalGroup:new{
        align = "center",
        HorizontalGroup:new{
            align = "center",
            TextWidget:new{
            padding = 0,
                text = string.format("%02d", now.day),
                face = Font:getFace(self.theme.face_ui, 28),
                bold = true,
                fgcolor = self.theme.fg,
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(10) },
            ImageWidget:new{
                file = ASSET_DIR .. "assets/icons/paper/calendar.svg",
                width = Screen:scaleBySize(24), height = Screen:scaleBySize(24),
                is_icon = true, alpha = true,
            },
        },
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        TextWidget:new{
            padding = 0,
            text = T("%1 %2", MONTHS[now.month], now.year),
            face = Font:getFace(self.theme.face_ui, 12),
            bold = true,
            fgcolor = self.theme.fg,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(3) },
        TextWidget:new{
            padding = 0,
            text = WEEKDAYS[now.wday],
            face = Font:getFace(self.theme.face_ui, 12),
            bold = true,
            fgcolor = self.theme.dim_fg,
        },
        VerticalSpan:new{width=Screen:scaleBySize(10)},
    }
    local date_cell = CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = cell_h },
        FrameContainer:new{
            background = self.theme.date_bg or self.theme.header_bg,
            color = self.theme.rule, bordersize = Size.border.thin,
            radius = Screen:scaleBySize(4), padding = 0, margin = 0,
            CenterContainer:new{
                dimen=Geom:new{w=cell_w-Screen:scaleBySize(24)-2*Size.border.thin,
                    h=cover_h-2*Size.border.thin},
                date_group,
            },
        },
    }
    -- The middle third, which is exactly where the date now sits.
    self.date_tap_zone = Geom:new{
        x = margin_left + cell_w + rule_w,
        y = Screen:scaleBySize(6),
        w = cell_w,
        h = cell_h,
    }
    self.cover_tap_zone = Geom:new{
        x = margin_left, y = Screen:scaleBySize(8), w = cell_w, h = cell_h,
    }

    -- --- cell 3: labelled progress ---
    -- DESIGN.md §6: "Progress distinguishes rendered page position,
    -- completed entries and document position." This one counts COMPLETED
    -- ENTRIES, and says so.
    local done, total = self.plugin:countProgress(self.record)
    local pct = total > 0 and (done / total) or 0
    local bar_w = math.min(cell_w - Screen:scaleBySize(20), Screen:scaleBySize(140))
    local progress_group = VerticalGroup:new{
        align = "center",
        HorizontalGroup:new{
            -- "bottom", not "baseline": HorizontalGroup accepts only
            -- center/top/bottom, and an unrecognised value makes it skip
            -- positioning entirely -- which silently dropped these numbers
            -- off the screen. Bottom is what visually aligns two different
            -- text sizes anyway.
            align = "bottom",
            TextWidget:new{
                text = tostring(done),
                face = Font:getFace(self.theme.face_ui, 20),
                bold = true,
                fgcolor = self.theme.fg,
            },
            TextWidget:new{
                text = "/" .. tostring(total),
                face = Font:getFace(self.theme.face_ui, 16),
                fgcolor = self.theme.dim_fg,
            },
        },
        VerticalSpan:new{ width = Screen:scaleBySize(5) },
        ProgressWidget:new{
            width = bar_w,
            height = Screen:scaleBySize(10),
            percentage = pct,
            bordersize = Size.border.thin,
            bordercolor = self.theme.rule,
            bgcolor = Blitbuffer.COLOR_WHITE,
            fillcolor = self.theme.fg,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        TextWidget:new{
            text = _("entries read"),
            face = Font:getFace(self.theme.face_ui, 12),
            fgcolor = self.theme.dim_fg,
        },
    }
    local progress_cell = CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = cell_h },
        progress_group,
    }

    local row1 = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            cover_widget,
        },
        vrule(),
        date_cell,
        vrule(),
        progress_cell,
    }

    -- --- row 2: entry transport ---
    local plan_active = plan.status == "active"
    local btn_w = Screen:scaleBySize(44)
    local function transportButton(name, cb, enabled)
        local button = Button:new{
            text = "", height = Screen:scaleBySize(26),
            bordersize = Size.border.thin, radius = 0,
            padding_h = 0, padding_v = Screen:scaleBySize(5), width = btn_w,
            enabled = enabled ~= false, show_parent = self, callback = cb,
        }
        button.label_widget:free()
        button.label_widget = ImageWidget:new{
            file = ASSET_DIR .. "assets/icons/" .. (self.theme.icon_set or "common") .. "/" .. name .. ".svg",
            width = Screen:scaleBySize(24), height = Screen:scaleBySize(24),
            is_icon = true, alpha = true, dim = enabled == false,
        }
        button.label_container[1] = button.label_widget
        return button
    end

    -- Grouped, then spaced -- ENTRY on the left, the transport centred,
    -- the actions on the right, with the leftover width split between the
    -- two gaps. Packing these left-to-right with fixed spans (as before)
    -- left a ragged empty margin on the right and made the row read as
    -- unrelated buttons rather than three groups.
    local entry_label = TextWidget:new{
        text = T(_("Entry %1"), self.entry_index),
        face = Font:getFace(self.theme.face_ui, 14),
        bold = true,
        fgcolor = self.theme.dim_fg,
    }

    local transport = HorizontalGroup:new{
        align = "center",
        transportButton("previous-entry", function() self:onPrevEntry() end,   -- |<
            self.entry_index > 1),
        HorizontalSpan:new{ width = Screen:scaleBySize(4) },
        transportButton(plan_active and "pause" or "play", -- pause / play
            function() self:onTogglePlay() end),
        HorizontalSpan:new{ width = Screen:scaleBySize(4) },
        transportButton("next-entry", function() self:onNextEntry() end,   -- >|
            self.entry_index < #self.record.entries),
    }

    local is_read = self.plugin.entryReadState and self.plugin:entryReadState(self.record,self.entry_index) or false
    local actions = HorizontalGroup:new{
        align = "center",
        Button:new{
            text = (is_read and "\226\152\145 " or "\226\152\144 ") .. _("Read"),
            text_font_face = self.theme.face_ui,
            text_font_size = 15,
            text_font_bold = true,
            bordersize = Size.border.thin,
            radius = 0,
            padding_h = Screen:scaleBySize(12),
            padding_v = Screen:scaleBySize(6),
            -- DESIGN.md §4: browsing a non-assigned entry cannot use the
            -- ordinary Mark read; credit belongs to the assigned entry only.
            enabled = self.record.entries[self.entry_index] ~= nil,
            show_parent = self,
            callback = function() self:onMarkRead() end,
        },
    }
    local close_button = Button:new{
        text = "\195\151 " .. _("Close"),
        text_font_face = self.theme.face_ui, text_font_size = 14,
        text_font_bold = true, background = Blitbuffer.ColorRGB32(0xE2,0x6A,0x5C,0xFF),
        bordersize = Size.border.thin, radius = 0,
        padding_h = Screen:scaleBySize(8), padding_v = Screen:scaleBySize(6),
        show_parent = self, callback = function() self:onClose() end,
    }
    local left_actions = HorizontalGroup:new{align="center",
        close_button, HorizontalSpan:new{width=Screen:scaleBySize(10)}, entry_label}

    local center_w = transport:getSize().w
    local side_w = math.floor((inner_w - center_w) / 2)
    local row_h = math.max(transport:getSize().h, actions:getSize().h, close_button:getSize().h)
    local row2 = HorizontalGroup:new{align="center",
        LeftContainer:new{dimen=Geom:new{w=side_w,h=row_h},left_actions},
        transport,
        RightContainer:new{dimen=Geom:new{w=inner_w-side_w-center_w,h=row_h},actions},
    }

    -- A "Browsing / Return to current" strip, shown only when the displayed
    -- entry isn't the assigned one (DESIGN.md §6).
    local browsing_strip
    if self.browsing then
        browsing_strip = VerticalGroup:new{
            align="left",
            TextWidget:new{text=_("Browsing — not today's reading"),
                face=Font:getFace(self.theme.face_ui,12), fgcolor=self.theme.dim_fg},
            VerticalSpan:new{width=Screen:scaleBySize(4)},
            HorizontalGroup:new{align="center",
                Button:new{text=_("Return to current"), text_font_size=13,
                    width=math.floor((inner_w-Screen:scaleBySize(8))/2),
                    bordersize=Size.border.thin, radius=0, padding_v=Screen:scaleBySize(5),
                    callback=function() self:onReturnToCurrent() end},
                HorizontalSpan:new{width=Screen:scaleBySize(8)},
                Button:new{text=_("Continue from here"), text_font_size=13,
                    width=math.floor((inner_w-Screen:scaleBySize(8))/2),
                    bordersize=Size.border.thin, radius=0, padding_v=Screen:scaleBySize(5),
                    enabled=plan.mode=="sequence",
                    callback=function()
                        UIManager:show(require("ui/widget/confirmbox"):new{
                            text=T(_("Continue from entry %1 today?\n\nPrevious history is kept in an earlier run. This entry becomes today's reading, using your existing pace. Nothing is marked read."), self.entry_index),
                            ok_text=_("Continue here"),
                            ok_callback=function()
                                if self.plugin:continueFromEntry(self.record,self.entry_index) then
                                    self.browsing=false; self.display_date=nil; self.page_num=1; self:refresh()
                                end
                            end})
                    end},
            },
        }
    end

    local group = VerticalGroup:new{
        align = "left",
        row1,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        LineWidget:new{
            background = self.theme.faint_rule,
            dimen = Geom:new{ w = inner_w, h = Size.line.thin },
        },
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        row2,
    }
    if browsing_strip then
        table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(6) })
        table.insert(group, browsing_strip)
    end
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    return group
end

-- ===================== Passage =====================

function TodayView:buildPassage(inner_w, passage_h)
    local entry = self.record.entries[self.entry_index]
    local plan = self.record.plan

    if plan.status == "finished" and not entry then
        return self:noticeBox(inner_w, passage_h,
            _("Plan complete"),
            _("You've read every entry in this book's plan.\n\nYou can start it again from Daily Pages \226\134\146 Schedule if you'd like another pass through."))
    end
    if not entry then
        return self:noticeBox(inner_w, passage_h,
            _("Nothing scheduled"),
            _("There's no entry to show yet."))
    end

    -- Entry label + heading. THEMES.md: heading is 1.35-1.6x body on short
    -- entries, 1.1-1.25x on dense ones -- a long entry shouldn't have its
    -- text pushed onto an extra page by an oversized title.
    local body_size = self.plugin:getSetting("body_font_size") or 20
    local text, extract_err = self.plugin:getEntryText(self.record, self.entry_index)
    local dense = text and #text > 1200
    local heading_size = math.floor(body_size * (dense and 1.2 or 1.5))

    local heading = TextBoxWidget:new{
        text = entry.title or "",
        face = Font:getFace(self.theme.face_heading, heading_size),
        bgcolor = self.theme.passage_bg,
        bold = self.theme.heading_bold,
        width = inner_w,
        alignment = "left",
    }
    if heading:getSize().h > passage_h * 0.18 then
        heading:free()
        heading = TextBoxWidget:new{
            text = entry.title or "", face = Font:getFace(self.theme.face_heading, math.floor(body_size * 1.15)),
            bold = self.theme.heading_bold, width = inner_w, alignment = "left",
            bgcolor = self.theme.passage_bg,
        }
    end

    local head_h = heading:getSize().h + Screen:scaleBySize(8)
    local body_h = passage_h - head_h
    if body_h < Screen:scaleBySize(80) then
        body_h = Screen:scaleBySize(80)
    end

    local body_widget
    if text then
        -- One TextBoxWidget holds the whole entry and is scrolled a screenful
        -- at a time; "Page x of y" below is derived from its own line
        -- metrics, so the count is always the truth of what is rendered.
        self.body = TextBoxWidget:new{
            text = text,
            face = Font:getFace(self.theme.face_passage, body_size),
            bgcolor = self.theme.passage_bg,
            width = inner_w,
            height = body_h,
            alignment = "left",
            fgcolor = self.theme.fg,
        }
        -- Each refresh builds a brand-new TextBoxWidget, which starts at
        -- line 1 -- so the page the reader is on has to be reapplied here,
        -- or every page turn would redraw page 1 and appear to do nothing.
        -- self.page_num is the authority; the widget's scroll position is
        -- derived from it, never the other way round.
        if self.page_num and self.page_num > 1 then
            local vis = self.body:getVisLineCount()
            if vis and vis > 0 then
                self.body:scrollLines((self.page_num - 1) * vis)
            end
        end
        body_widget = self.body
    else
        self.body = nil
        -- Extraction unavailable. Show the reason and a way through, never
        -- invented text (DESIGN.md §6: "no fabricated excerpts").
        body_widget = VerticalGroup:new{
            align = "left",
            TextBoxWidget:new{
                text = extract_err or _("This entry's text isn't available here."),
                face = Font:getFace(self.theme.face_ui, 15),
                width = inner_w,
                fgcolor = self.theme.dim_fg,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(14) },
            Button:new{
                text = _("Open this entry in the book"),
                text_font_face = self.theme.face_ui,
                text_font_size = 15,
                bordersize = Size.border.thin,
                radius = 0,
                padding_v = Screen:scaleBySize(6),
                width = math.floor(inner_w * 0.7),
                show_parent = self,
                callback = function() self:onOpenInBook() end,
            },
        }
    end

    return VerticalGroup:new{
        align = "left",
        heading,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        body_widget,
    }
end

function TodayView:noticeBox(inner_w, h, title, body)
    return VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = title,
            face = Font:getFace(self.theme.face_heading, 24),
            bold = true,
            fgcolor = self.theme.fg,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
        TextBoxWidget:new{
            text = body,
            face = Font:getFace(self.theme.face_passage, 16),
            width = inner_w,
            fgcolor = self.theme.dim_fg,
        },
    }
end

-- ===================== Footer =====================

function TodayView:pageCounts()
    if not self.body then return 1, 1 end
    local vis = self.body:getVisLineCount()
    local all = self.body:getAllLineCount()
    if not vis or vis < 1 then return 1, 1 end
    local total = math.max(1, math.ceil(all / vis))
    -- self.page_num is the authority, NOT the widget's scroll position.
    -- TextBoxWidget:scrollLines() deliberately clamps the final page so it
    -- shows the last `vis` lines rather than starting on a page boundary
    -- (avoiding a mostly-blank last page, at the cost of repeating a few
    -- lines). That means virtual_line_num does not sit on a multiple of
    -- `vis` at the end, so deriving the page number back out of it reported
    -- the last page as page 1 -- which also left "next" enabled and "prev"
    -- greyed out at the end of an entry.
    local current = math.min(math.max(1, self.page_num or 1), total)
    return current, total
end

function TodayView:buildFooter(inner_w)
    local current, total = self:pageCounts()
    return CenterContainer:new{
        dimen=Geom:new{w=inner_w,h=Screen:scaleBySize(18)},
        TextWidget:new{text=T(_("Page %1 of %2"),current,total),
            face=Font:getFace(self.theme.face_ui,12),fgcolor=self.theme.dim_fg},
    }
end

-- ===================== Actions =====================

function TodayView:assignedEntryIndex()
    return self.plugin:assignedEntryIndex(self.record)
end

-- Page moves stay inside the entry. At the boundaries they stop rather than
-- rolling into the next entry, per DESIGN.md §6.
function TodayView:onNextPage()
    if not self.body then return true end
    local current, total = self:pageCounts()
    if current >= total then return true end -- stops at the entry's end
    self.page_num = current + 1
    self:refresh()
    return true
end

function TodayView:onPrevPage()
    if not self.body then return true end
    local current = self:pageCounts()
    if current <= 1 then return true end
    self.page_num = current - 1
    self:refresh()
    return true
end

function TodayView:onNextEntry()
    if self.entry_index >= #self.record.entries then return true end
    self:showEntry(self.entry_index + 1)
    return true
end

function TodayView:onPrevEntry()
    if self.entry_index <= 1 then return true end
    self:showEntry(self.entry_index - 1)
    return true
end

-- Browsing is view state only: it never allocates an assignment, never
-- moves the plan cursor and never awards credit (DESIGN.md §4).
function TodayView:showEntry(index)
    self.display_date = nil
    self.entry_index = index
    self.page_num = 1
    self.browsing = (index ~= self:assignedEntryIndex())
    self:refresh()
end

function TodayView:onReturnToCurrent()
    local idx,date = self.plugin:entryForTodayView(self.record)
    if idx and self.record.entries[idx] then
        self.entry_index=idx
        self.display_date=date
        self.page_num=1
        self.browsing=false
        self:refresh()
    end
    return true
end

function TodayView:onTogglePlay()
    self.plugin:togglePlayPause(self.record)
    self:refresh()
    return true
end

function TodayView:onMarkRead()
    if self.plugin:toggleEntryRead(self.record,self.entry_index) then
        self:refresh()
    end
    return true
end

function TodayView:onOpenInBook()
    if self.plugin.reconcile then self.plugin:reconcile(self.record) end
    local entry = self.record.entries[self.entry_index]
    UIManager:close(self)
    self.plugin:onTodayClosed()
    self.plugin:openEntryInBook(entry)
    return true
end

-- Only the date rectangle is claimed here; returning false everywhere else
-- lets the taps fall through to the Buttons, which handle themselves.
function TodayView:onTap(_arg, ges)
    if self.cover_tap_zone and ges.pos and self.cover_tap_zone:contains(ges.pos) then
        return self:onOpenInBook()
    end
    if self.date_tap_zone and ges.pos and self.date_tap_zone:contains(ges.pos) then
        self.plugin:showCalendar()
        return true
    end
    local area = self.passage_tap_zone
    if area and ges.pos and area:contains(ges.pos) then
        local reader = self.plugin.ui and self.plugin.ui.view
        local forward, backward
        if reader and reader.getTapZones then
            forward, backward = reader:getTapZones()
        else
            local function zone(key)
                local z=G_defaults:readSetting(key)
                return {ratio_x=z.x,ratio_y=z.y,ratio_w=z.w,ratio_h=z.h}
            end
            forward,backward=zone("DTAP_ZONE_FORWARD"),zone("DTAP_ZONE_BACKWARD")
        end
        local x,y=(ges.pos.x-area.x)/area.w,(ges.pos.y-area.y)/area.h
        local function inside(z)
            return x>=z.ratio_x and x<z.ratio_x+z.ratio_w
                and y>=z.ratio_y and y<z.ratio_y+z.ratio_h
        end
        if inside(forward) then return self:onNextPage() end
        if inside(backward) then return self:onPrevPage() end
        return true
    end
    return false
end

function TodayView:onSwipe(_arg, ges)
    -- Swipes are page moves within the entry, matching the footer -- never
    -- entry moves, so a stray swipe can't silently skip a day's reading.
    if ges.direction == "west" then
        return self:onNextPage()
    elseif ges.direction == "east" then
        return self:onPrevPage()
    elseif ges.direction == "south" then
        return self:onClose()
    end
    return true
end

-- Close means "Later": nothing is marked, nothing is lost, and the reader
-- goes back exactly where it was (DESIGN.md §6).
function TodayView:onClose()
    self.plugin:reconcile(self.record)
    UIManager:close(self)
    self.plugin:onTodayClosed()
    return true
end

function TodayView:onCloseWidget()
    if self.body then
        self.body:free()
    end
    UIManager:setDirty(nil, "full")
end

return TodayView
