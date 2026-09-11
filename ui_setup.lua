-- Daily Pages -- plan setup.
--
-- One screen, every choice visible and editable in any order, with the
-- estimate recomputing live underneath. This deliberately replaces the
-- earlier dialog chain (entry type -> quantity -> interval -> estimate):
-- being marched through four modal steps made it impossible to see how the
-- choices related to each other, or to change an earlier answer without
-- starting over.
--
-- Wording rule applied throughout: describe the book, not the data model.
-- No "TOC depth", no "cadence", no "period", no "level N" -- the entry
-- picker shows real chapter titles out of the actual book and lets the
-- reader recognise what they are choosing.

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
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookIndex = require("bookindex")
local Logic = require("dailypages_logic")
local Theme = require("theme")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local SetupView = InputContainer:extend{
    covers_fullscreen = true,
    plugin = nil,
    book_path = nil,
    depth_options = nil, -- from BookIndex.describeDepths
    existing_plan = nil, -- when editing rather than creating
    default_plan = nil,  -- the reader's default pace, used for a new book
}

function SetupView:init()
    self.theme = Theme:get(self.plugin:getSetting("theme"))
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    -- Starting values, in priority order: what this book already has (so
    -- re-running setup never silently resets it), then the reader's default
    -- pace if they've set one, then a plain one-a-day.
    local plan = self.existing_plan
    local fallback = self.default_plan or {}
    self.depth = plan and plan.toc_depth or self:defaultDepth()
    self.quantity = plan and plan.cadence.quantity or fallback.quantity or 1
    self.interval_days = plan and plan.cadence.interval_days or fallback.interval_days or 1
    self.start_date = plan and plan.start_date or os.date("%Y-%m-%d")
    self.missed_policy = plan and plan.missed_policy or fallback.missed_policy or "hold"

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    end
    self:refresh()
end

-- Pick the depth whose entry count looks most like a day-at-a-time book.
-- A 366-entry level in a year book is a much better first guess than the
-- 14-entry front-matter level, and the reader can still change it.
function SetupView:defaultDepth()
    local best, best_score
    for _i, opt in ipairs(self.depth_options) do
        -- Prefer the largest count; that is nearly always the day/entry
        -- level rather than parts or front matter.
        local score = opt.count
        if not best_score or score > best_score then
            best, best_score = opt.depth, score
        end
    end
    return best or 1
end

function SetupView:currentOption()
    for _i, opt in ipairs(self.depth_options) do
        if opt.depth == self.depth then return opt end
    end
    return self.depth_options[1]
end

function SetupView:refresh()
    self:build()
    self[1] = FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        background = self.theme.bg,
        bordersize = 0, padding = 0, margin = 0,
        self.content,
    }
    UIManager:setDirty(self, "ui")
end

-- ===================== Rows =====================

function SetupView:build()
    local screen_w = Screen:getWidth()
    local margin = Screen:scaleBySize(20)
    local inner_w = screen_w - 2 * margin

    local rows = VerticalGroup:new{ align = "left" }

    local function addTappableRow(label, value, detail, callback)
        local content = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = Screen:scaleBySize(9) },
            TextWidget:new{
                text = label,
                face = Font:getFace(self.theme.face_ui, 12),
                fgcolor = self.theme.dim_fg,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(3) },
            TextBoxWidget:new{
                text = value,
                face = Font:getFace(self.theme.face_ui, 16),
                bold = true,
                width = inner_w - Screen:scaleBySize(24),
                alignment = "left",
                fgcolor = self.theme.fg,
            },
        }
        if detail and detail ~= "" then
            table.insert(content, TextBoxWidget:new{
                text = detail,
                face = Font:getFace(self.theme.face_ui, 13),
                width = inner_w - Screen:scaleBySize(24),
                alignment = "left",
                fgcolor = self.theme.dim_fg,
            })
        end
        table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(9) })

        table.insert(rows, LeftContainer:new{
            dimen = Geom:new{ w = screen_w, h = content:getSize().h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, content },
        })
        -- A transparent full-width button laid under the text would swallow
        -- the label, so the tap is registered as a zone instead.
        self.row_zones[#self.row_zones + 1] = {
            height = content:getSize().h,
            callback = callback,
        }
        table.insert(rows, LineWidget:new{
            background = self.theme.faint_rule,
            dimen = Geom:new{ w = screen_w, h = Size.line.thin },
        })
    end

    self.row_zones = {}

    -- --- title ---
    -- Built as its own finished group before being added to `rows`.
    -- VerticalGroup:getSize() CACHES into self._size, so measuring a group
    -- and then inserting more children into it leaves it reporting a height
    -- smaller than it actually paints -- which makes the enclosing frame
    -- draw past the end of its buffer and takes KOReader down with it.
    -- Measure only finished groups; never a group still being filled.
    local head = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = Screen:scaleBySize(14) },
        LeftContainer:new{
            dimen = Geom:new{ w = screen_w, h = Screen:scaleBySize(30) },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin },
                TextWidget:new{
                    text = self.existing_plan and _("Change reading plan") or _("Set up a reading plan"),
                    face = Font:getFace(self.theme.face_heading, 22),
                    bold = true,
                    fgcolor = self.theme.fg,
                } },
        },
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        LeftContainer:new{
            dimen = Geom:new{ w = screen_w, h = Screen:scaleBySize(22) },
            HorizontalGroup:new{ HorizontalSpan:new{ width = margin },
                TextBoxWidget:new{
                    text = self.plugin:getBookTitle(),
                    face = Font:getFace(self.theme.face_ui, 14),
                    width = inner_w,
                    fgcolor = self.theme.dim_fg,
                } },
        },
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        LineWidget:new{
            background = self.theme.rule,
            dimen = Geom:new{ w = screen_w, h = Size.line.thin },
        },
    }
    local zones_start_y = head:getSize().h
    table.insert(rows, head)

    -- --- the choices ---
    local opt = self:currentOption()
    local sample = opt and table.concat(opt.samples, "  \226\128\162  ") or ""
    addTappableRow(
        _("One entry is"),
        opt and T(_("%1 entries in this book"), opt.count) or _("(none found)"),
        sample ~= "" and T(_("like: %1"), sample) or nil,
        function() self:pickEntryUnit() end)

    addTappableRow(
        _("Each time, unlock"),
        self.quantity == 1 and _("1 entry") or T(_("%1 entries"), self.quantity),
        nil,
        function() self:pickQuantity() end)

    addTappableRow(
        _("A new one unlocks"),
        self:intervalLabel(),
        nil,
        function() self:pickInterval() end)

    addTappableRow(
        _("Starting"),
        self.start_date == os.date("%Y-%m-%d") and _("Today") or self.start_date,
        nil,
        function() self:pickStartDate() end)

    addTappableRow(
        _("If I miss a day"),
        self.missed_policy == "hold" and _("Wait for me") or _("Keep to the calendar"),
        self.missed_policy == "hold"
            and _("Nothing unlocks until I've read the one I'm on. Nothing piles up.")
            or _("Entries keep unlocking on schedule, and unread ones wait in a backlog."),
        function() self:pickMissedPolicy() end)

    -- --- live estimate ---
    local est = self:estimateText()
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(12) })
    table.insert(rows, LeftContainer:new{
        dimen = Geom:new{ w = screen_w, h = Screen:scaleBySize(20) },
        HorizontalGroup:new{ HorizontalSpan:new{ width = margin },
            TextWidget:new{
                text = _("AT THIS PACE"),
                face = Font:getFace(self.theme.face_ui, 11),
                fgcolor = self.theme.dim_fg,
            } },
    })
    table.insert(rows, LeftContainer:new{
        dimen = Geom:new{ w = screen_w, h = Screen:scaleBySize(60) },
        HorizontalGroup:new{ HorizontalSpan:new{ width = margin },
            TextBoxWidget:new{
                text = est,
                face = Font:getFace(self.theme.face_ui, 15),
                width = inner_w,
                alignment = "left",
                fgcolor = self.theme.fg,
            } },
    })

    -- --- actions ---
    table.insert(rows, VerticalSpan:new{ width = Screen:scaleBySize(14) })
    local btn_w = math.floor(inner_w * 0.48)
    table.insert(rows, LeftContainer:new{
        dimen = Geom:new{ w = screen_w, h = Screen:scaleBySize(52) },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = margin },
            Button:new{
                text = _("Cancel"),
                text_font_face = self.theme.face_ui, text_font_size = 16,
                bordersize = Size.border.thin, radius = 0,
                width = btn_w, padding_v = Screen:scaleBySize(9),
                show_parent = self,
                callback = function() self:onClose() end,
            },
            HorizontalSpan:new{ width = Screen:scaleBySize(10) },
            Button:new{
                text = self.existing_plan and _("Save changes") or _("Start plan"),
                text_font_face = self.theme.face_ui, text_font_size = 16,
                text_font_bold = true,
                -- NOT a filled button: Button hardcodes its label to
                -- COLOR_BLACK when enabled and paints the border in the
                -- fill colour, so a dark background renders black on black
                -- and the label vanishes. A heavier border marks the
                -- primary action instead, which also reads correctly on
                -- grayscale e-ink and suits Paper's fine-rules treatment.
                bordersize = Size.border.thick, radius = 0,
                width = btn_w, padding_v = Screen:scaleBySize(9),
                show_parent = self,
                callback = function() self:onSave() end,
            },
        },
    })

    -- Drop any measurement taken while rows was still being filled, so the
    -- frame measures the finished group (see the note on _size caching).
    rows:resetLayout()
    self.zones_start_y = zones_start_y
    self.content = rows
end

function SetupView:intervalLabel()
    local d = self.interval_days
    if d == 1 then return _("every day") end
    if d == 7 then return _("every week") end
    if d == 14 then return _("every two weeks") end
    if d % 7 == 0 then return T(_("every %1 weeks"), math.floor(d / 7)) end
    return T(_("every %1 days"), d)
end

-- DESIGN.md §2's corrected arithmetic: K = ceil(R / Q) assignments, first
-- due on the start date, so the last one falls on start + (K-1) * D. Not
-- R/Q*D, which overshoots by a whole interval.
function SetupView:estimateText()
    local opt = self:currentOption()
    if not opt or opt.count == 0 then
        return _("Pick what counts as an entry to see how long this will take.")
    end
    local remaining = opt.count
    local k = math.ceil(remaining / self.quantity)
    if k <= 0 then
        return _("This book is already finished at that setting.")
    end
    local last = Logic.addDays(self.start_date, (k - 1) * self.interval_days)
    if not last then
        return _("That start date doesn't look like a real date.")
    end
    local span_days = (k - 1) * self.interval_days
    local human_span
    if span_days < 14 then
        human_span = T(_("about %1 days"), span_days + 1)
    elseif span_days < 70 then
        human_span = T(_("about %1 weeks"), math.floor(span_days / 7) + 1)
    else
        human_span = T(_("about %1 months"), math.floor(span_days / 30) + 1)
    end
    return T(_("%1 readings, %2 \226\128\148 the last one lands on %3.\n\nThat's an estimate, not a deadline: it moves if you read late or pause."),
        k, human_span, last)
end

-- ===================== Pickers =====================

function SetupView:previewEntries(save_after_review)
    local opt = self:currentOption()
    if not opt then return end
    local Menu = require("ui/widget/menu")
    local items = {}
    for i, entry in ipairs(opt.entries) do
        items[#items+1] = {
            text = tostring(i) .. ". " .. (entry.title or ""),
            mandatory = entry.page and tostring(entry.page) or "",
            callback = function()
                self.plugin:withPreparationMessage(_("Loading entry preview…"), function()
                    local text, err = BookIndex.extractText(self.plugin.ui, entry)
                    UIManager:show(InfoMessage:new{
                        text=(entry.title or "") .. "\n\n" .. (text or err or ""),
                        height=math.floor(Screen:getHeight()*0.7), show_icon=false,
                    })
                end)
            end,
        }
    end
    local menu
    table.insert(items, 1, {text=save_after_review and _("Accept entries and save plan") or _("Use these entries"), callback=function()
        self._reviewed_entries = opt.entries
        UIManager:close(menu)
        if save_after_review then self:onSave() end
    end})
    menu = Menu:new{title=T(_("Preview %1 entries"),opt.count), item_table=items,
        width=Screen:getWidth(), height=Screen:getHeight(), is_popout=false,
        close_callback=function() UIManager:close(menu) end}
    UIManager:show(menu)
end

function SetupView:scanHeadings()
    self.plugin:withPreparationMessage(_("Scanning book headings…"), function()
        local options = BookIndex.scanHeadings(self.plugin.ui)
        if #options == 0 then
            UIManager:show(InfoMessage:new{text=_("No usable headings found. This book needs explicit entry boundaries; Daily Pages won't guess from its text.")})
            return
        end
        self.depth_options = options
        self.depth = self:defaultDepth()
        -- A verified day sequence is a useful suggestion, still previewable.
        for _i,opt in ipairs(options) do if opt.depth < 0 then self.depth=opt.depth end end
        self:refresh()
        self:previewEntries()
    end)
end

function SetupView:pickEntryUnit()
    local buttons = {}
    for _i, opt in ipairs(self.depth_options) do
        -- Real titles from this book, generously spaced, one per line --
        -- the reader recognises "January 1st: CONTROL AND CHOICE" instantly
        -- and never has to work out what a level is.
        local sample_size = opt.count > 100 and 2 or 3
        local lines = {}
        for i = 1, math.min(sample_size, #opt.samples) do
            lines[#lines + 1] = "\226\128\162 " .. opt.samples[i]
        end
        if opt.count > sample_size then
            lines[#lines + 1] = "\226\128\162 \226\128\166"
        end
        buttons[#buttons + 1] = {{
            text = (opt.label and opt.label .. " · " or "") .. T(_("%1 entries\n%2"), opt.count, table.concat(lines, "\n")),
            text_font_size = 15,
            padding_v = Screen:scaleBySize(12),
            callback = function()
                UIManager:close(self._picker)
                self.depth = opt.depth
                self:refresh()
            end,
        }}
    end
    buttons[#buttons+1] = {{text=_("Preview all headings"), callback=function()
        UIManager:close(self._picker); self:previewEntries()
    end}}
    buttons[#buttons+1] = {{text=_("Scan book headings…"), callback=function()
        UIManager:close(self._picker)
        UIManager:show(require("ui/widget/confirmbox"):new{
            text=_("Build entries from the book's structural headings? This also switches KOReader's table of contents to detected headings. You can restore the original from KOReader's TOC menu. Review the results before starting a plan."),
            ok_text=_("Scan headings"), ok_callback=function() self:scanHeadings() end})
    end}}
    self._picker = ButtonDialog:new{
        title = _("Which of these is one day's reading?"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self._picker)
end

function SetupView:pickQuantity()
    self:numberPrompt(_("How many entries unlock at once?"), self.quantity, function(v)
        self.quantity = v
        self:refresh()
    end)
end

function SetupView:pickInterval()
    -- Common paces as one tap, with a free-form option behind them -- most
    -- readers want "every day" or "every week", not to type a number.
    local presets = {
        { 1, _("Every day") },
        { 2, _("Every other day") },
        { 7, _("Every week") },
        { 14, _("Every two weeks") },
    }
    local buttons = {}
    for _i, p in ipairs(presets) do
        buttons[#buttons + 1] = {{
            text = p[2],
            callback = function()
                UIManager:close(self._picker)
                self.interval_days = p[1]
                self:refresh()
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("Some other number of days\226\128\166"),
        callback = function()
            UIManager:close(self._picker)
            self:numberPrompt(_("A new entry every how many days?"), self.interval_days, function(v)
                self.interval_days = v
                self:refresh()
            end)
        end,
    }}
    self._picker = ButtonDialog:new{
        title = _("How often?"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self._picker)
end

function SetupView:pickStartDate()
    local buttons = {
        {{
            text = _("Today"),
            callback = function()
                UIManager:close(self._picker)
                self.start_date = os.date("%Y-%m-%d")
                self:refresh()
            end,
        }},
        {{
            text = _("Tomorrow"),
            callback = function()
                UIManager:close(self._picker)
                self.start_date = Logic.addDays(os.date("%Y-%m-%d"), 1)
                self:refresh()
            end,
        }},
        {{
            text = _("A specific date\226\128\166"),
            callback = function()
                UIManager:close(self._picker)
                self:datePrompt()
            end,
        }},
    }
    self._picker = ButtonDialog:new{
        title = _("When does the first entry unlock?"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self._picker)
end

function SetupView:pickMissedPolicy()
    local buttons = {
        {{
            text = _("Wait for me\nNothing new unlocks until I've read\nthe entry I'm on."),
            text_font_size = 15,
            padding_v = Screen:scaleBySize(10),
            callback = function()
                UIManager:close(self._picker)
                self.missed_policy = "hold"
                self:refresh()
            end,
        }},
        {{
            text = _("Keep to the calendar\nEntries keep unlocking on time.\nUnread ones wait for me."),
            text_font_size = 15,
            padding_v = Screen:scaleBySize(10),
            callback = function()
                UIManager:close(self._picker)
                self.missed_policy = "backlog"
                self:refresh()
            end,
        }},
    }
    self._picker = ButtonDialog:new{
        title = _("If a day goes by without reading"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self._picker)
end

function SetupView:numberPrompt(title, current, on_ok)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(current),
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    local v = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    if not v or v < 1 or v ~= math.floor(v) then
                        UIManager:show(InfoMessage:new{
                            text = _("That needs to be a whole number, 1 or more."),
                        })
                        return
                    end
                    on_ok(v)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SetupView:datePrompt()
    local dialog
    dialog = InputDialog:new{
        title = _("Start date"),
        description = _("As year-month-day, for example 2026-09-15."),
        input = self.start_date,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("OK"),
                is_enter_default = true,
                callback = function()
                    local v = dialog:getInputText()
                    UIManager:close(dialog)
                    -- Validated against the real calendar, so 2026-02-30
                    -- is rejected here rather than becoming a broken plan.
                    if not Logic.isValidDate(v) then
                        UIManager:show(InfoMessage:new{
                            text = _("That isn't a date on the calendar. Use year-month-day, like 2026-09-15."),
                        })
                        return
                    end
                    self.start_date = v
                    self:refresh()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ===================== Row hit-testing =====================

function SetupView:onTap(_arg, ges)
    if not (self.row_zones and ges.pos and self.zones_start_y) then return false end
    local y = ges.pos.y
    local top = self.zones_start_y
    for _i, zone in ipairs(self.row_zones) do
        local bottom = top + zone.height
        if y >= top and y < bottom then
            zone.callback()
            return true
        end
        top = bottom + Size.line.thin
    end
    return false
end

-- ===================== Save =====================

function SetupView:onSave()
    local opt = self:currentOption()
    if not opt or opt.count == 0 then
        UIManager:show(InfoMessage:new{ text = _("Pick what counts as an entry first.") })
        return
    end
    -- Pace-only edits do not need another review of unchanged boundaries.
    if self.existing_plan and self._reviewed_entries ~= opt.entries then
        local record = self.plugin.db.plans[self.book_path]
        local old = record and record.entries or {}
        local same = #old == #opt.entries
        for i,e in ipairs(old) do
            local new = opt.entries[i]
            if not new or e.xp ~= new.xp or e.end_xp ~= new.end_xp then same=false; break end
        end
        if same then self._reviewed_entries = opt.entries end
    end
    if self._reviewed_entries ~= opt.entries then
        self:previewEntries(true)
        return
    end
    if self.existing_plan then
        local record = self.plugin.db.plans[self.book_path]
        local old = record and record.entries or {}
        local changed = #old ~= #opt.entries
        for i,e in ipairs(old) do
            if not opt.entries[i] or (e.xp ~= opt.entries[i].xp or e.end_xp ~= opt.entries[i].end_xp) then changed=true; break end
        end
        if changed and self._replace_confirmed ~= opt.entries then
            UIManager:show(require("ui/widget/confirmbox"):new{
                text=_("Replace the old entry list and restart with these headings? Previous reading history will be archived with its original entries. No reading credit transfers to the new list."),
                ok_text=_("Replace and restart"),
                ok_callback=function() self._replace_confirmed=opt.entries; self:onSave() end})
            return
        end
    end
    UIManager:close(self)
    self.plugin:commitPlan{
        book_path = self.book_path,
        toc_depth = self.depth,
        entries = opt.entries,
        quantity = self.quantity,
        interval_days = self.interval_days,
        start_date = self.start_date,
        missed_policy = self.missed_policy,
        existing_plan = self.existing_plan,
        replace_entries = self._replace_confirmed == opt.entries,
    }
end

function SetupView:onSwipe(_arg, ges)
    if ges.direction == "south" then return self:onClose() end
    return true
end

function SetupView:onClose()
    UIManager:close(self)
    self.plugin:onSetupClosed()
    return true
end

function SetupView:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

return SetupView
