-- dailypages.koplugin -- for books read one entry at a time.
--
-- This file is KOReader glue only: menu, persistence, book selection,
-- lifecycle events, and the small query/command surface the views call.
-- Every scheduling decision lives in dailypages_logic.lua, and every
-- document access lives in bookindex.lua.
--
-- Menu structure follows UI-UX Design/MENU.md exactly:
--
--   Tools -> Daily Pages
--     View today's entry
--     Select book                  [subtitle: current selection]
--       Current open book
--       Choose book from files...
--     Create plan... | Plan -> Plan summary / Edit plan... / History
--     Settings
--     Appearance
--
-- Book selection model, also per MENU.md: ONE pinned book, chosen
-- explicitly. "Follow currently open book" is a Settings toggle that is OFF
-- by default -- so the plugin does not require a book to be open, and does
-- not silently change which plan you are looking at when you open something
-- else.

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local BookIndex = require("bookindex")
local Logic = require("dailypages_logic")
local SleepScreen = require("sleepscreen")
local Theme = require("theme")
local _ = require("gettext")
local T = require("ffi/util").template

local DailyPages = WidgetContainer:extend{
    name = "dailypages",
    is_doc_only = false,
}

local DEFAULTS = {
    follow_current_book = false,
    theme = "paper",
    calendar_layout = "dots",
    calendar_cell_text = "heading",
    week_start = 2, -- Monday, per the mockups; locale override in Appearance
    body_font_size = 20,
    sleep_enabled = false,
    sleep_show_on_wake = "every", -- every | once | never
    sleep_open_on_wake = false,
    sleep_retain_completed = true, -- legacy key; sleep content no longer depends on completion
    sleep_content = "full", -- full | heading  (the original "cover page" ask)
    sleep_show_title = true,
    sleep_show_date = true,
    sleep_max_chars = 900,
    skip_unopened = false,
    rollover_minutes = 0,
}

-- ===================== Lifecycle =====================

function DailyPages:init()
    self.db_path = ("%s/%s"):format(DataStorage:getSettingsDir(), "dailypages_db.lua")
    self:loadDB()
    self.sleep = SleepScreen.new(self)
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- ===================== Persistence =====================
-- The DB holds every plan keyed by book path, plus plugin settings. Plans
-- are nested tables of assignments, so a generic serializer is used rather
-- than hand-written field formats.

function DailyPages:loadDB()
    local ok, data = pcall(dofile, self.db_path)
    self.db = (ok and type(data) == "table") and data or {}
    self.db.plans = self.db.plans or {}
    self.db.settings = self.db.settings or {}
end

local function serializeValue(v, indent)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local pad = string.rep("  ", indent)
        local inner = string.rep("  ", indent + 1)
        local parts = { "{\n" }
        local seen = {}
        for i, item in ipairs(v) do
            seen[i] = true
            parts[#parts + 1] = inner .. serializeValue(item, indent + 1) .. ",\n"
        end
        for k, val in pairs(v) do
            if not seen[k] then
                local key
                if type(k) == "string" then
                    key = "[" .. string.format("%q", k) .. "]"
                elseif type(k) == "number" then
                    key = "[" .. tostring(k) .. "]"
                end
                if key then
                    parts[#parts + 1] = inner .. key .. " = " .. serializeValue(val, indent + 1) .. ",\n"
                end
            end
        end
        parts[#parts + 1] = pad .. "}"
        return table.concat(parts)
    end
    return "nil"
end

function DailyPages:saveDB()
    -- Write to a temporary file and move it into place, so a crash or a
    -- flat battery mid-write can't leave a truncated DB that loses every
    -- plan. dofile() on a half-written file would silently reset everything.
    local tmp = self.db_path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        logger.warn("dailypages: could not open DB for writing:", tmp)
        return false
    end
    local ok, err = pcall(function()
        f:write("return " .. serializeValue(self.db, 0) .. "\n")
    end)
    f:close()
    if not ok then
        logger.warn("dailypages: DB serialization failed:", err)
        os.remove(tmp)
        return false
    end
    os.remove(self.db_path)
    os.rename(tmp, self.db_path)
    return true
end

function DailyPages:getSetting(key)
    local v = self.db.settings[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

function DailyPages:setSetting(key, value)
    self.db.settings[key] = value
    self:saveDB()
end

-- ===================== Book selection =====================

-- The path of the book Daily Pages is currently working with.
-- Returns nil plus a human explanation when there isn't one.
function DailyPages:selectedBookPath()
    if self:getSetting("follow_current_book") then
        if self.ui and self.ui.document and self.ui.document.file then
            return self.ui.document.file
        end
        -- MENU.md: "If following is on and no book is open, say Open a book
        -- first; do not silently fall back to another plan."
        return nil, _("Daily Pages is set to follow whichever book is open, but no book is open right now.\n\nOpen a book, or turn off Settings \226\134\146 Follow currently open book and pick one.")
    end
    local pinned = self.db.settings.selected_book
    if not pinned then
        return nil, _("No book selected yet.\n\nUse Select book to choose one.")
    end
    if not BookIndex.fileExists(pinned) then
        return nil, BookIndex.missingFileMessage(pinned)
    end
    return pinned
end

function DailyPages:selectedBookLabel()
    local path, _err = self:selectedBookPath()
    if not path then
        if self:getSetting("follow_current_book") then
            return _("Following the open book")
        end
        return _("None selected")
    end
    local record = self.db.plans[path]
    if record and record.title then return record.title end
    return (path:match("([^/\\]+)$") or path):gsub("%.%w+$", "")
end

-- True when the selected book is the one currently open in the reader --
-- which is what makes text extraction and cover art available.
function DailyPages:isSelectedBookOpen()
    local path = self:selectedBookPath()
    return path and self.ui and self.ui.document and self.ui.document.file == path
end

-- Paint before synchronous document/TOC work; nextTick alone can still run
-- before repaint. Always dismiss on failure, and prevent duplicate requests.
function DailyPages:withPreparationMessage(message, work)
    if self._preparing_book then return end
    self._preparing_book = true
    local notice = InfoMessage:new{
        text = message, show_icon = false, dismissable = false,
        honor_silent_mode = false,
    }
    UIManager:show(notice)
    UIManager:forceRePaint()
    local ok, result = xpcall(work, debug.traceback)
    UIManager:close(notice)
    self._preparing_book = nil
    if not ok then
        require("logger").warn("Daily Pages preparation failed", result)
        UIManager:show(InfoMessage:new{
            text = _("Couldn't prepare this book. Please try again."),
        })
    end
    return ok, result
end

function DailyPages:showReaderWithNotice(reader, path, provider, quickstart, seamless, callback)
    local title = (path:match("([^/\\]+)$") or path):gsub("%.%w+$", "")
    return self:withPreparationMessage(
        T(_("Opening book…\n\n%1\n\nPlease wait."), title),
        function() reader:showReader(path, provider, quickstart, seamless, callback) end)
end

function DailyPages:pinBook(path)
    return self:withPreparationMessage(_("Selecting book…"), function()
        self:pinBookNow(path)
    end)
end

function DailyPages:pinBookNow(path)
    self.db.settings.selected_book = path
    -- MENU.md: "Choosing a specific file pins it and turns following off,
    -- with a brief visible acknowledgement."
    local was_following = self:getSetting("follow_current_book")
    self.db.settings.follow_current_book = false
    self:saveDB()
    local title = (path:match("([^/\\]+)$") or path):gsub("%.%w+$", "")
    local msg = T(_("Daily Pages is now set to: %1"), title)
    if was_following then
        msg = msg .. "\n\n" .. _("(Following the open book has been turned off.)")
    end
    UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
end

-- PathChooser normally ignores file taps on touch devices (hold required).
-- This picker selects files with one tap; native folder navigation remains.
function DailyPages:onBookChooserSelect(chooser, item)
    local path = item.path and require("ffi/util").realpath(item.path)
    local mode = path and require("libs/libkoreader-lfs").attributes(path, "mode")
    if mode ~= "file" then
        return PathChooser.onMenuSelect(chooser, item)
    end
    if chooser._book_selected then return true end
    chooser._book_selected = true
    UIManager:close(chooser)
    chooser.onConfirm(path)
    return true
end

function DailyPages:chooseBookFromFiles()
    local start_dir = self.db.settings.last_browse_dir
        or (self.ui and self.ui.document and self.ui.document.file
            and self.ui.document.file:match("^(.*)[/\\][^/\\]*$"))
        or DataStorage:getDataDir()
    local chooser
    chooser = PathChooser:new{
        title = _("Choose a book"),
        onMenuSelect = function(widget, item)
            return self:onBookChooserSelect(widget, item)
        end,
        path = start_dir,
        select_directory = false,
        select_file = true,
        show_files = true,
        file_filter = function(filename)
            -- Reflowable formats only for now: entry text extraction and
            -- TOC-based boundaries need anchors that paged formats
            -- (PDF/DjVu) don't provide. Showing a PDF here and then
            -- failing at setup would be worse than not offering it.
            local ext = filename:lower():match("%.([^.]+)$")
            return ext == "epub" or ext == "fb2" or ext == "mobi"
                or ext == "azw3" or ext == "txt" or ext == "html"
                or ext == "htm" or ext == "rtf" or ext == "chm"
        end,
        onConfirm = function(path)
            self.db.settings.last_browse_dir = path:match("^(.*)[/\\][^/\\]*$")
            self:pinBook(path)
        end,
    }
    UIManager:show(chooser)
end

-- ===================== Book metadata =====================
-- These read through to the open document when it is the selected book, and
-- fall back to whatever was cached in the plan record otherwise -- so
-- Schedule, History and the calendar work with the book closed.

function DailyPages:getBookTitle()
    if self:isSelectedBookOpen() then
        return BookIndex.getTitle(self.ui)
    end
    local path = self:selectedBookPath()
    local record = path and self.db.plans[path]
    if record and record.title then return record.title end
    return path and ((path:match("([^/\\]+)$") or path):gsub("%.%w+$", "")) or _("No book")
end

function DailyPages:getBookAuthors()
    if self:isSelectedBookOpen() then
        return BookIndex.getAuthors(self.ui)
    end
    local path = self:selectedBookPath()
    local record = path and self.db.plans[path]
    return record and record.authors or nil
end

function DailyPages:getCoverImage()
    if self:isSelectedBookOpen() then
        return BookIndex.getCover(self.ui)
    end
    return nil -- a closed book shows the labelled placeholder, never a stand-in
end

-- ===================== Plan records =====================

function DailyPages:getRecord()
    local path, err = self:selectedBookPath()
    if not path then return nil, err end
    local record = self.db.plans[path]
    if not record then
        return nil, T(_("No reading plan for %1 yet.\n\nUse Create plan to set one up."), self:getBookTitle())
    end
    record.book_path = path
    return record
end

-- Maps a slot to the entry ids it covers. With a quantity of N, slot 1
-- covers entries 1..N, slot 2 covers N+1..2N, and so on -- returning nil
-- once the book runs out, which is what tells reconcile the plan is done.
local function makeEntriesFn(entries, quantity, start_index)
    return function(slot)
        local first = (slot - 1) * quantity + (start_index or 1)
        if first > #entries then return nil end
        local ids = {}
        for i = first, math.min(first + quantity - 1, #entries) do
            ids[#ids + 1] = tostring(i)
        end
        return ids
    end
end

function DailyPages:entriesFnFor(record)
    return makeEntriesFn(record.entries, record.plan.cadence.quantity, record.plan.start_entry_index)
end

function DailyPages:today()
    return os.date("%Y-%m-%d")
end

function DailyPages:nowTimestamp()
    return os.date("%Y-%m-%dT%H:%M:%S")
end

-- Bring a plan up to date with the calendar. Called on every entry point --
-- the plugin has no background timer, so "catching up" always happens here,
-- when the reader actually looks.
function DailyPages:reconcile(record)
    local ok, err = pcall(Logic.reconcile, record.plan, self:today(), self:entriesFnFor(record))
    if not ok then
        logger.warn("dailypages: reconcile failed:", err)
        return false, _("Something went wrong working out what's due. Your reading history is unchanged.")
    end
    local applied=false
    for _,id in ipairs(record.plan.assignment_order) do
        local a=record.plan.assignments[id]
        if a.due_date and a.due_date<=self:today() then
            for _,entry_id in ipairs(a.entry_ids) do
                local read_at=record.entry_reads and record.entry_reads[entry_id]
                if read_at and not a.entry_outcomes[entry_id] then
                    Logic.markEntryRead(record.plan,id,entry_id,read_at)
                    applied=true
                end
            end
        end
    end
    if applied then Logic.reconcile(record.plan,self:today(),self:entriesFnFor(record)) end
    self:saveDB()
    return true
end

-- ===================== Queries used by the views =====================

function DailyPages:activeAssignment(record)
    local plan = record.plan
    if not plan.active_assignment_id then return nil end
    return plan.assignments[plan.active_assignment_id]
end

-- The entry the reader is being asked to read: the first unresolved entry
-- of the active assignment.
function DailyPages:assignedEntryIndex(record)
    local a = self:activeAssignment(record)
    if not a then return nil end
    if a.due_date and a.due_date > self:today() then return nil end
    for _i, entry_id in ipairs(a.entry_ids) do
        local outcome = a.entry_outcomes[entry_id]
        if not outcome then
            return tonumber(entry_id)
        end
    end
    return nil
end

function DailyPages:lastCompletedEntryIndex(record)
    local plan = record.plan
    for i = #plan.assignment_order, 1, -1 do
        local a = plan.assignments[plan.assignment_order[i]]
        if a.status == "completed" then
            local last = a.entry_ids[#a.entry_ids]
            return tonumber(last)
        end
    end
    return nil
end

-- Completed entries out of the whole plan, for the header's labelled
-- progress. Counts ENTRIES READ -- deliberately not document position.
function DailyPages:countProgress(record)
    -- Count unique checked entries, not assignments. Read-ahead credit may
    -- exist before scheduling allocates an assignment for that entry.
    local read = {}
    for entry_id, timestamp in pairs(record.entry_reads or {}) do
        if timestamp and record.entries[tonumber(entry_id)] then read[entry_id]=true end
    end
    for _, id in ipairs(record.plan.assignment_order or {}) do
        local a=record.plan.assignments[id]
        for _,entry_id in ipairs(a.entry_ids or {}) do
            local o=a.entry_outcomes[entry_id]
            if o and o.status=="read" and record.entries[tonumber(entry_id)] then
                read[entry_id]=true
            end
        end
    end
    local done=0
    for _ in pairs(read) do done=done+1 end
    return done,#record.entries
end

function DailyPages:getEntryText(record, entry_index)
    local entry = record.entries[entry_index]
    if not entry then return nil, _("That entry isn't in this book's plan.") end
    if not self:isSelectedBookOpen() then
        return nil, T(_("Open %1 to read this entry's text here."), self:getBookTitle())
    end
    return BookIndex.extractText(self.ui, entry)
end

-- ===================== Calendar data =====================

-- A read-only map of date -> what is scheduled that day. Built fresh from
-- the plan on each calendar open; nothing here allocates or mutates.
function DailyPages:assignmentsByDate(record)
    local plan = record.plan
    local map = {}
    local today = self:today()

    for _i, id in ipairs(plan.assignment_order) do
        local a = plan.assignments[id]
        local date = a.occurrence_date or a.due_date
        if date then
            local entries = {}
            for _j, entry_id in ipairs(a.entry_ids) do
                local idx = tonumber(entry_id)
                local e = record.entries[idx]
                local outcome = a.entry_outcomes[entry_id]
                entries[#entries + 1] = {
                    entry_index = idx,
                    title = e and e.title or T(_("Entry %1"), idx),
                    status = outcome and outcome.status == "read" and "completed"
                        or outcome and outcome.status == "skipped" and "skipped"
                        or "pending",
                }
            end
            -- A held overdue assignment appears once, on its current due
            -- date -- never cloned onto every day it was missed.
            map[date] = {
                assignment_id = id,
                status = a.status,
                count = #entries,
                entries = entries,
                entry_index = entries[1] and entries[1].entry_index,
                title = entries[1] and entries[1].title,
                is_future = date > today,
                due_date = a.due_date,
                original_due_date = a.original_due_date,
            }
        end
    end
    return map
end

-- Text shown inside a Day boxes cell: the real heading, or a real excerpt.
-- Never a generated summary (CALENDAR.md is explicit), and it degrades
-- heading -> "Entry N" rather than inventing anything.
function DailyPages:cellTextFor(record, items, mode)
    if not items then return nil end
    if mode == "excerpt" and self:isSelectedBookOpen() then
        local text = self:getEntryText(record, items.entry_index)
        if text and text ~= "" then
            return (text:gsub("%s+", " "):sub(1, 120))
        end
    end
    return items.title
end

-- ===================== Commands =====================

function DailyPages:togglePlayPause(record)
    local plan = record.plan
    if plan.status == "active" then
        Logic.pause(plan, self:today())
    else
        Logic.play(plan, self:today())
        self:reconcile(record)
    end
    self:saveDB()
end

-- Marks the displayed entry read and returns true when that completed the
-- whole assignment (which is what tells the view to close and hand the
-- screen back).
function DailyPages:entryReadState(record, index)
    for i=#record.plan.assignment_order,1,-1 do
        local a=record.plan.assignments[record.plan.assignment_order[i]]
        if not a.due_date or a.due_date<=self:today() then
            for _,id in ipairs(a.entry_ids) do
                if id==tostring(index) then
                    local o=a.entry_outcomes[id]
                    return o and o.status=="read" or false, a
                end
            end
        end
    end
    local saved=record.entry_reads and record.entry_reads[tostring(index)]
    return saved ~= nil,nil
end

function DailyPages:toggleEntryRead(record,index)
    local read,a=self:entryReadState(record,index)
    if not record.entries[index] then return false end
    local id=tostring(index)
    record.entry_reads=record.entry_reads or {}
    if read then
        record.entry_reads[id]=nil
        if a then Logic.unmarkEntryRead(record.plan,a.assignment_id,id,self:nowTimestamp()) end
    else
        local now=self:nowTimestamp()
        record.entry_reads[id]=now
        if a then Logic.markEntryRead(record.plan,a.assignment_id,id,now) end
    end
    -- Keep the displayed entry stable; scheduling reconciles when closing.
    self:saveDB()
    return true
end

function DailyPages:markCurrentEntryRead(record)
    local a = self:activeAssignment(record)
    local idx = self:assignedEntryIndex(record)
    if not (a and idx) then return false end

    Logic.markEntryRead(record.plan, a.assignment_id, tostring(idx), self:nowTimestamp())
    local completed = (a.status == "completed")
    self:reconcile(record)
    self:saveDB()
    return completed
end

function DailyPages:completionMessage(record)
    local plan = record.plan
    local streak = Logic.computeStreak(plan, self:today())
    if plan.status == "finished" then
        return _("That's the last entry. Plan complete.")
    end
    local next_a = self:activeAssignment(record)
    local when = next_a and next_a.due_date
    local streak_line = streak > 0
        and T(_("%1 in a row."), streak)
        or nil
    local parts = { _("Marked read.") }
    if streak_line then parts[#parts + 1] = streak_line end
    if when then
        if when <= self:today() then
            parts[#parts + 1] = _("The next entry is ready now.")
        else
            parts[#parts + 1] = T(_("Next entry unlocks %1."), when)
        end
    end
    return table.concat(parts, " ")
end

-- Explicit skip. DESIGN.md §4 requires it to be a deliberate menu action
-- with Undo -- never something the transport buttons can do by accident.
function DailyPages:skipCurrentEntry(record)
    local a = self:activeAssignment(record)
    local idx = self:assignedEntryIndex(record)
    if not (a and idx) then
        UIManager:show(InfoMessage:new{ text = _("Nothing to skip right now.") })
        return
    end
    local entry = record.entries[idx]
    UIManager:show(ConfirmBox:new{
        text = T(_("Skip \226\128\156%1\226\128\157 without reading it?\n\nIt won't count towards your streak."),
            entry and entry.title or T(_("Entry %1"), idx)),
        ok_text = _("Skip it"),
        ok_callback = function()
            Logic.skipEntry(record.plan, a.assignment_id, tostring(idx), self:nowTimestamp())
            self:reconcile(record)
            self:saveDB()
            -- Undo is offered immediately: a skip is recoverable by marking
            -- the same entry read, which the logic audits as a correction.
            UIManager:show(InfoMessage:new{
                text = _("Skipped. You can still mark it read from the calendar if you change your mind."),
                timeout = 4,
            })
        end,
    })
end

function DailyPages:openEntryInBook(entry)
    if self:isSelectedBookOpen() then
        if not BookIndex.goToEntry(self.ui, entry) then
            UIManager:show(InfoMessage:new{ text = _("Couldn't jump to that entry in the book.") })
        end
        return
    end
    -- The book isn't open. Telling the reader to go and open it themselves
    -- is a dead end -- this button's whole job is to get them to the entry,
    -- so it opens the book (normal reader lifecycle, per DESIGN.md 1) and
    -- jumps once the document is ready.
    local path, err = self:selectedBookPath()
    if not path then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local ReaderUI = require("apps/reader/readerui")
    self:showReaderWithNotice(ReaderUI, path, nil, false, false, function()
        UIManager:nextTick(function()
            local inst = ReaderUI.instance
            if not inst then return end
            if not BookIndex.goToEntry(inst, entry) then
                UIManager:show(InfoMessage:new{
                    text = _("Opened the book, but couldn't jump to that entry."),
                    timeout = 3,
                })
            end
        end)
    end)
end

-- ===================== Views =====================

-- Runs after(plugin) with the selected book open.
--
-- The reading view reads entry text live out of the document, so with the
-- book shut it could only ever show a heading -- which is exactly the dead
-- end that made "Page >" pointless. Opening the book is therefore part of
-- showing today's entry, not something to ask the reader to go and do.
-- Uses the normal reader lifecycle (DESIGN.md 1), never a second
-- concurrently-open document.
function DailyPages:withBookOpen(after)
    if self:isSelectedBookOpen() then
        after(self)
        return
    end
    local path, err = self:selectedBookPath()
    if not path then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local ReaderUI = require("apps/reader/readerui")
    local function open()
        self:showReaderWithNotice(ReaderUI, path, nil, false, false, function()
            UIManager:nextTick(function()
                local inst = ReaderUI.instance
                local plugin = inst and inst.dailypages
                if plugin then
                    after(plugin)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Opened the book, but Daily Pages couldn't attach to it. Try again from Tools."),
                    })
                end
            end)
        end)
    end
    if self.ui and self.ui.document then
        -- Another book is already open. DESIGN.md 1 says to preserve the
        -- caller's book and position, so this asks rather than swapping it
        -- out from under the reader.
        UIManager:show(ConfirmBox:new{
            text = T(_("Open %1 to read today's entry?\n\nYour place in the book you're reading now is saved."),
                self:getBookTitle()),
            ok_text = _("Open it"),
            ok_callback = open,
        })
    else
        open() -- nothing open; no context to preserve
    end
end

-- Explicit menu view can revisit the latest due reading after completion.
function DailyPages:entryForTodayView(record)
    local current=self:assignedEntryIndex(record)
    if current then return current,nil end
    local today=self:today()
    for i=#record.plan.assignment_order,1,-1 do
        local a=record.plan.assignments[record.plan.assignment_order[i]]
        local date=a.occurrence_date or a.due_date
        if date and date<=today then
            local index=tonumber(a.entry_ids[#a.entry_ids])
            if index and record.entries[index] then return index,date end
        end
    end
    -- A future-start plan can still preview its starting entry without credit.
    return record.plan.start_entry_index or 1,nil
end

function DailyPages:showToday(explicit_view)
    local record, err = self:getRecord()
    if not record then
        self:explainAndOfferSetup(err)
        return
    end
    if not self:isSelectedBookOpen() then
        self:withBookOpen(function(plugin) plugin:showToday(explicit_view) end)
        return
    end
    if not self:reconcile(record) then
        UIManager:show(InfoMessage:new{ text = _("Couldn't work out today's reading. Your history is unchanged.") })
        return
    end

    local plan = record.plan
    local entry_index = self:assignedEntryIndex(record)
    local display_date
    if explicit_view and not entry_index then
        entry_index,display_date=self:entryForTodayView(record)
    end

    -- MENU.md: "If nothing is due, show the completed-today state or next
    -- due date rather than silently jumping ahead."
    if not explicit_view and not entry_index and plan.status ~= "finished" then
        local a = self:activeAssignment(record)
        local msg
        if a and a.due_date and a.due_date > self:today() then
            msg = T(_("You're up to date.\n\nThe next entry unlocks %1."), a.due_date)
        else
            msg = _("You're up to date. Nothing new is due yet.")
        end
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end

    -- Record that this assignment was actually opened, awake. Sleep-screen
    -- exposure and calendar previews deliberately do NOT set this -- it is
    -- the signal the "skip unopened days" option depends on (MENU.md).
    local a = self:activeAssignment(record)
    if a and self:assignedEntryIndex(record) == entry_index and not a.first_opened_at then
        a.first_opened_at = self:nowTimestamp()
        self:saveDB()
    end

    local TodayView = require("ui_today")
    self._today = TodayView:new{
        plugin = self,
        record = record,
        entry_index = entry_index or math.max(1, self:lastCompletedEntryIndex(record) or 1),
        browsing = explicit_view and self:assignedEntryIndex(record) == nil and not self:entryReadState(record,entry_index) or false,
        display_date = display_date,
    }
    UIManager:show(self._today)
end

function DailyPages:explainAndOfferSetup(message)
    local path = self:selectedBookPath()
    if not path then
        UIManager:show(InfoMessage:new{ text = message })
        return
    end
    -- A selected book with no plan: explain and link straight to setup,
    -- rather than dropping the reader into a blank wizard (MENU.md).
    UIManager:show(ConfirmBox:new{
        text = message,
        ok_text = _("Create plan"),
        cancel_text = _("Not now"),
        ok_callback = function() self:startSetup() end,
    })
end

function DailyPages:showCalendar()
    local record, err = self:getRecord()
    if not record then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    -- Calendar browsing is a read-only query, not a reconciliation trigger.
    local CalendarView = require("ui_calendar")
    self._calendar = CalendarView:new{ plugin = self, record = record }
    UIManager:show(self._calendar)
end

function DailyPages:onCalendarClosed()
    self._calendar = nil
    -- Returning from the calendar restores the reading view if that is
    -- where it was opened from.
    -- The reading widget remains underneath the modal calendar. Showing it
    -- again would register the same widget twice in UIManager's stack.
end

function DailyPages:onTodayClosed()
    self._today = nil
end

function DailyPages:onSetupClosed()
    self._setup = nil
end

function DailyPages:openEntryFromCalendar(entry_index, is_future, display_date)
    local record = self:getRecord()
    if not record then return end
    if is_future then
        -- A forecast is a preview: it opens read-only and cannot use the
        -- ordinary Mark read (DESIGN.md §4).
        UIManager:show(InfoMessage:new{
            text = _("This is a preview of a future reading. It isn't scheduled yet, so it can't be marked read."),
            timeout = 3,
        })
    end
    local TodayView = require("ui_today")
    self._today = TodayView:new{
        plugin = self,
        record = record,
        entry_index = entry_index,
        browsing = is_future or entry_index ~= self:assignedEntryIndex(record),
        display_date = display_date,
    }
    UIManager:show(self._today)
end

-- ===================== Setup =====================

function DailyPages:startSetup()
    local path, err = self:selectedBookPath()
    if not path then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    if self:isSelectedBookOpen() then
        self:launchSetupForOpenBook(path)
        return
    end
    -- The book needs to be open to read its table of contents. DESIGN.md §1
    -- requires the NORMAL reader lifecycle for indexing -- never a second
    -- document opened behind the scenes -- so this asks, then opens it.
    UIManager:show(ConfirmBox:new{
        text = T(_("Daily Pages needs to open %1 to see its chapters.\n\nOpen it now?"),
            self:getBookTitle()),
        ok_text = _("Open it"),
        ok_callback = function()
            local ReaderUI = require("apps/reader/readerui")
            self:showReaderWithNotice(ReaderUI, path, nil, false, false, function()
                -- after_open_callback: the document is ready, and the
                -- plugin instance in the new ReaderUI takes it from here.
                UIManager:nextTick(function()
                    local inst = ReaderUI.instance
                    local plugin = inst and inst.dailypages
                    if plugin then
                        plugin:launchSetupForOpenBook(path)
                    end
                end)
            end)
        end,
    })
end

function DailyPages:launchSetupForOpenBook(path)
    return self:withPreparationMessage(
        T(_("Reading chapters…\n\n%1\n\nPreparing your plan options."), self:getBookTitle()),
        function() self:launchSetupForOpenBookNow(path) end)
end

function DailyPages:launchSetupForOpenBookNow(path)
    if not BookIndex.isReflowable(self.ui) then
        UIManager:show(InfoMessage:new{
            text = _("This looks like a fixed-page document (PDF or similar). Daily Pages can't work out entry boundaries in those yet -- EPUB and similar formats work today."),
        })
        return
    end
    local options = BookIndex.addDayOptions(BookIndex.describeDepths(self.ui))
    if #options == 0 then
        -- Keep setup available so the user can explicitly scan headings.

    end
    local existing = self.db.plans[path] and self.db.plans[path].plan or nil
    local SetupView = require("ui_setup")
    self._setup = SetupView:new{
        plugin = self,
        book_path = path,
        depth_options = options,
        existing_plan = existing,
        -- A brand-new book starts from the default pace rather than from
        -- a hardcoded one-a-day.
        default_plan = not existing and self:getDefaultPlan() or nil,
    }
    UIManager:show(self._setup)
end

function DailyPages:commitPlan(opts)
    local existing = opts.existing_plan
    if existing then
        if opts.replace_entries then
            local record = self.db.plans[opts.book_path]
            local plan, archived = Logic.reset(existing, existing.run_id .. "+", self:today())
            archived.entries = record.entries
            archived.start_entry_index = plan.start_entry_index or 1
            archived.entry_reads = record.entry_reads
            record.entry_reads = nil
            archived.reason = "replace_entry_boundaries"
            record.archived_runs = record.archived_runs or {}
            record.archived_runs[#record.archived_runs+1] = archived
            plan.start_entry_index = 1
            record.plan = plan
        end
        -- Editing keeps the run and its history: only the pace and the
        -- future scheduling boundary move (DESIGN.md §3 -- a cadence change
        -- must not recompute dates already allocated).
        local ok, err = Logic.editCadence(existing, opts.quantity, opts.interval_days, self:today())
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("Couldn't save those changes: %1"), err or "?") })
            return
        end
        existing.missed_policy = opts.missed_policy
        existing.toc_depth = opts.toc_depth
        local record = self.db.plans[opts.book_path]
        record.entries = opts.entries
        self:reconcile(record)
        self:saveDB()
        UIManager:show(InfoMessage:new{ text = _("Plan updated."), timeout = 2 })
        return
    end

    local plan, err = Logic.newPlan{
        plan_id = opts.book_path,
        book_id = opts.book_path,
        mode = "sequence",
        quantity = opts.quantity,
        interval_days = opts.interval_days,
        missed_policy = opts.missed_policy,
        start_date = opts.start_date,
        rollover_minutes = self:getSetting("rollover_minutes"),
    }
    if not plan then
        UIManager:show(InfoMessage:new{ text = T(_("Couldn't create the plan: %1"), err or "?") })
        return
    end
    plan.toc_depth = opts.toc_depth

    self.db.plans[opts.book_path] = {
        plan = plan,
        entries = opts.entries,
        title = self:getBookTitle(),
        authors = self:getBookAuthors(),
        book_path = opts.book_path,
    }
    self:saveDB()
    UIManager:show(InfoMessage:new{ text = _("Plan created."), timeout = 2 })
end

-- ===================== Default plan =====================
--
-- A "default plan" is just the pace, not a plan object: quantity, interval
-- and missed-reading behaviour. New books start from it, so setting up the
-- second daily-reader is a couple of taps rather than the whole form again.
-- It deliberately does NOT include the entry unit, because that is a
-- property of the individual book's chapter structure -- carrying "level 3"
-- from a 366-day book to a 12-chapter one would be nonsense.

function DailyPages:getDefaultPlan()
    return self.db.settings.default_plan or {
        quantity = 1,
        interval_days = 1,
        missed_policy = "hold",
    }
end

function DailyPages:isDefaultPlan()
    local record = self:getRecord()
    if not record then return false end
    local d = self.db.settings.default_plan
    if not d then return false end
    local c = record.plan.cadence
    return d.quantity == c.quantity
        and d.interval_days == c.interval_days
        and d.missed_policy == record.plan.missed_policy
end

function DailyPages:setDefaultPlanFromCurrent()
    local record, err = self:getRecord()
    if not record then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local c = record.plan.cadence
    self.db.settings.default_plan = {
        quantity = c.quantity,
        interval_days = c.interval_days,
        missed_policy = record.plan.missed_policy,
    }
    self:saveDB()
    UIManager:show(InfoMessage:new{
        text = T(_("New books will start at this pace: %1."), self:describePace(
            c.quantity, c.interval_days)),
        timeout = 3,
    })
end

function DailyPages:describePace(quantity, interval_days)
    local unit = quantity == 1 and _("1 entry") or T(_("%1 entries"), quantity)
    local every
    if interval_days == 1 then every = _("every day")
    elseif interval_days == 7 then every = _("every week")
    elseif interval_days == 14 then every = _("every two weeks")
    else every = T(_("every %1 days"), interval_days) end
    return T("%1 %2", unit, every)
end

-- ===================== Plan summary / History =====================

function DailyPages:showPlanSummary()
    local record, err = self:getRecord()
    if not record then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    self:reconcile(record)
    local plan = record.plan
    local done, total = self:countProgress(record)
    local remaining = total - done
    local q, d = plan.cadence.quantity, plan.cadence.interval_days
    local k = remaining > 0 and math.ceil(remaining / q) or 0
    local last_due = k > 0 and Logic.addDays(self:today(), (k - 1) * d) or nil
    local a = self:activeAssignment(record)
    local streak = Logic.computeStreak(plan, self:today())

    local status_label = plan.status == "active" and _("Reading")
        or plan.status == "paused" and _("Paused")
        or plan.status == "finished" and _("Finished")
        or _("Stopped")

    local kv = {
        { _("Book"), record.title or self:getBookTitle() },
        { _("Author"), record.authors or _("Unknown") },
        { _("Status"), status_label },
        { _("Reading order"), _("In order (not by date)") },
        { _("One entry is"), T(_("1 of %1 chapters"), total) },
        { _("Pace"), q == 1 and T(_("1 entry every %1 day(s)"), d)
            or T(_("%1 entries every %2 day(s)"), q, d) },
        { _("Started"), plan.start_date },
        { _("Read so far"), T(_("%1 of %2"), done, total) },
        { _("Remaining"), tostring(remaining) },
        { _("On-time streak"), tostring(streak) },
        { _("If a day is missed"), plan.missed_policy == "hold"
            and _("Wait for me") or _("Keep to the calendar") },
    }
    if a then
        table.insert(kv, { _("Next due"), a.due_date or _("Now") })
    end
    if last_due then
        -- Labelled as an estimate, explicitly, per DESIGN.md §2.
        table.insert(kv, { _("Estimated last reading"), T(_("%1 (estimate)"), last_due) })
    end

    UIManager:show(KeyValuePage:new{
        title = _("Plan summary"),
        kv_pairs = kv,
    })
end

function DailyPages:showHistory()
    local record, err = self:getRecord()
    if not record then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local plan = record.plan
    local kv = {}
    -- Newest first: what happened recently is what people look for.
    for i = #plan.assignment_order, 1, -1 do
        local a = plan.assignments[plan.assignment_order[i]]
        local titles = {}
        for _j, entry_id in ipairs(a.entry_ids) do
            local e = record.entries[tonumber(entry_id)]
            titles[#titles + 1] = e and e.title or entry_id
        end
        local label = a.due_date or a.occurrence_date or "?"
        local value = T("%1  %2", Theme.glyphFor(a.status), table.concat(titles, ", "))
        -- A late completion is shown as such rather than as a plain tick,
        -- so the record matches what the streak actually counted.
        if a.status == "completed" and a.completed_at then
            local eff = Logic.effectiveDate(a.completed_at, plan.rollover_minutes or 0)
            if eff and a.due_date and eff > a.due_date then
                value = value .. T(_("  (read %1)"), eff)
            end
        end
        kv[#kv + 1] = { label, value }
    end
    for r=#(record.archived_runs or {}),1,-1 do
        local past=record.archived_runs[r]
        kv[#kv+1]={T(_("Earlier run %1"),r),past.reason or _("Restarted")}
        for i=#(past.assignment_order or {}),1,-1 do
            local a=past.assignments[past.assignment_order[i]]
            local titles={}
            for _j,id in ipairs(a.entry_ids or {}) do
                local entry=(past.entries or record.entries)[tonumber(id)]
                titles[#titles+1]=entry and entry.title or id
            end
            kv[#kv+1]={a.due_date or "?",Theme.labelFor(a.status).." · "..table.concat(titles,", ")}
        end
    end
    if #kv == 0 then
        kv = { { _("Nothing yet"), _("Readings appear here once they're due.") } }
    end
    UIManager:show(KeyValuePage:new{
        title = _("History"),
        kv_pairs = kv,
    })
end

-- ===================== Sleep screen =====================

function DailyPages:resolveSleepRecord()
    local record, err = self:getRecord()
    if not record then return nil, err end
    return record
end

function DailyPages:isSleepSuppressed(record)
    local mode = self:getSetting("sleep_show_on_wake")
    if mode == "never" then return true end
    local hide_until = self.db.settings.sleep_hidden_until
    if hide_until and hide_until > self:today() then return true end
    if mode == "once" then
        local a = self:activeAssignment(record)
        if a and self.db.settings.sleep_shown_for == a.assignment_id then
            return true
        end
        if a then
            self.db.settings.sleep_shown_for = a.assignment_id
            self:saveDB()
        end
    end
    return false
end

function DailyPages:showTodayAfterWake(_active)
    -- The device may have slept across several date boundaries. Reconciling
    -- first means what opens is genuinely today's reading, not the entry
    -- the (static) sleep screen was still showing.
    local record = self:getRecord()
    if not record then return end
    self:reconcile(record)
    -- Automatic opening is only for unread, due work. No up-to-date popup.
    if record.plan.status ~= "active" or not self:assignedEntryIndex(record) then return end
    if self:isSleepSuppressed(record) then return end
    if self._today or self._setup then return end
    self:showToday()
end

function DailyPages:onSuspend()
    if self.sleep then self.sleep:prepare() end
end

function DailyPages:onResume()
    if self.sleep then self.sleep:onWake() end
end

function DailyPages:onOutOfScreenSaver()
    -- Both events can fire, in an order that depends on device settings;
    -- SleepScreen:onWake() de-duplicates.
    if self.sleep then self.sleep:onWake() end
end

-- ===================== Menu =====================

function DailyPages:addToMainMenu(menu_items)
    menu_items.dailypages = {
        text = _("Daily Pages"),
        sorting_hint = "tools",
        sub_item_table = self:buildMenu(),
    }
end

function DailyPages:buildMenu()
    return {
        {
            -- First item, always present -- discoverable before setup, per
            -- MENU.md. Viewing never marks anything read.
            text = _("View today's entry"),
            callback = function() self:showToday(true) end,
        },
        {
            text_func = function()
                return T(_("Select book: %1"), self:selectedBookLabel())
            end,
            sub_item_table_func = function()
                local items = {}
                local open_file = self.ui and self.ui.document and self.ui.document.file
                items[#items + 1] = {
                    text_func = function()
                        if not open_file then
                            return _("Current open book (none open)")
                        end
                        return T(_("Current open book: %1"), BookIndex.getTitle(self.ui))
                    end,
                    enabled_func = function() return open_file ~= nil end,
                    callback = function()
                        if open_file then self:pinBook(open_file) end
                    end,
                }
                items[#items + 1] = {
                    text = _("Choose book from files\226\128\166"),
                    callback = function() self:chooseBookFromFiles() end,
                }
                return items
            end,
        },
        {
            -- "Create plan..." before a plan exists, "Plan for this book"
            -- once it does -- the qualifier matters now that a default plan
            -- exists, so it's clear which of the two you're editing.
            text_func = function()
                local path = self:selectedBookPath()
                if path and self.db.plans[path] then return _("Plan for this book") end
                return _("Create plan\226\128\166")
            end,
            sub_item_table_func = function()
                local path = self:selectedBookPath()
                if not (path and self.db.plans[path]) then
                    -- No plan: this item acts as the direct entry to setup
                    -- rather than opening an empty submenu.
                    return {
                        {
                            text = _("Set up a reading plan\226\128\166"),
                            callback = function() self:startSetup() end,
                        },
                    }
                end
                return {
                    { text = _("Plan summary"), callback = function() self:showPlanSummary() end },
                    { text = _("Edit plan\226\128\166"), callback = function() self:startSetup() end },
                    { text = _("Calendar"), callback = function() self:showCalendar() end },
                    { text = _("History"), callback = function() self:showHistory() end },
                    {
                        -- Most people read several of these books at the
                        -- same pace, so the pace they already settled on
                        -- becomes the starting point for the next book.
                        text_func = function()
                            if self:isDefaultPlan() then
                                return _("This is your default pace \226\156\147")
                            end
                            return _("Use this pace for new books")
                        end,
                        separator = true,
                        callback = function() self:setDefaultPlanFromCurrent() end,
                    },
                    {
                        text = _("Skip today's entry\226\128\166"),
                        separator = true,
                        callback = function()
                            local record = self:getRecord()
                            if record then self:skipCurrentEntry(record) end
                        end,
                    },
                    {
                        text_func = function()
                            local record = self:getRecord()
                            local paused = record and record.plan.status == "paused"
                            return paused and _("Resume plan") or _("Pause plan")
                        end,
                        callback = function()
                            local record = self:getRecord()
                            if record then
                                self:togglePlayPause(record)
                                UIManager:show(InfoMessage:new{
                                    text = record.plan.status == "paused"
                                        and _("Paused. Your streak is safe while paused.")
                                        or _("Resumed."),
                                    timeout = 2,
                                })
                            end
                        end,
                    },
                    {
                        text = _("Reset plan\226\128\166"),
                        callback = function() self:confirmReset() end,
                    },
                }
            end,
        },
        { text = _("Settings"), sub_item_table_func = function() return self:settingsMenu() end },
        { text = _("Appearance"), sub_item_table_func = function() return self:appearanceMenu() end },
    }
end

function DailyPages:continueFromEntry(record, index)
    if record.plan.mode ~= "sequence" or not record.entries[index] then return false end
    local plan, archived = Logic.reset(record.plan, record.plan.run_id .. "+", self:today())
    archived.start_entry_index = plan.start_entry_index or 1
    archived.entry_reads = record.entry_reads
    record.entry_reads = nil
    archived.reason = "continue_from_entry"
    archived.entries = record.entries
    record.archived_runs = record.archived_runs or {}
    record.archived_runs[#record.archived_runs+1] = archived
    plan.start_entry_index = index
    record.plan = plan
    self:reconcile(record)
    self:saveDB()
    return true
end

function DailyPages:confirmReset()
    local record = self:getRecord()
    if not record then return end
    UIManager:show(ConfirmBox:new{
        -- Reset is destructive and deliberately distinct from pausing or
        -- stopping (MENU.md); the old run is archived, not deleted.
        text = _("Start this book's plan again from the beginning?\n\nYour previous run is kept in History."),
        ok_text = _("Start again"),
        ok_callback = function()
            local new_run = record.plan.run_id .. "+"
            local plan, archived = Logic.reset(record.plan, new_run, self:today())
            archived.entry_reads = record.entry_reads
            record.entry_reads = nil
            archived.entries = record.entries
            archived.start_entry_index = plan.start_entry_index or 1
            plan.start_entry_index = 1
            record.plan = plan
            record.archived_runs = record.archived_runs or {}
            if archived then
                record.archived_runs[#record.archived_runs + 1] = archived
            end
            self:reconcile(record)
            self:saveDB()
            UIManager:show(InfoMessage:new{ text = _("Plan restarted."), timeout = 2 })
        end,
    })
end

function DailyPages:settingsMenu()
    local function toggle(key, text, help)
        return {
            text = text,
            help_text = help,
            checked_func = function() return self:getSetting(key) == true end,
            callback = function() self:setSetting(key, not (self:getSetting(key) == true)) end,
        }
    end
    return {
        toggle("follow_current_book", _("Follow currently open book"),
            _("Off: Daily Pages stays on the book you picked. On: it switches to whichever book you have open.")),
        {
            text_func = function()
                local d = self.db.settings.default_plan
                if not d then return _("Default pace for new books: not set") end
                return T(_("Default pace for new books: %1"),
                    self:describePace(d.quantity, d.interval_days))
            end,
            help_text = _("New books start at this pace. Set it from Plan for this book."),
            enabled_func = function() return self.db.settings.default_plan ~= nil end,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Forget the default pace?\n\nNew books will start at one entry a day again. Existing plans aren't affected."),
                    ok_text = _("Forget it"),
                    ok_callback = function()
                        self.db.settings.default_plan = nil
                        self:saveDB()
                    end,
                })
            end,
        },
        {
            text = _("Sleep screen"),
            separator = true,
            sub_item_table = {
                toggle("sleep_enabled", _("Show today's entry on the sleep screen"),
                    _("Your normal sleep screen is put back afterwards.")),
                toggle("sleep_open_on_wake", _("Open the entry when the device wakes")),
                {
                    text_func = function()
                        local m = self:getSetting("sleep_show_on_wake")
                        local label = m == "once" and _("Once per entry")
                            or m == "never" and _("Never")
                            or _("Every wake until read")
                        return T(_("Show: %1"), label)
                    end,
                    sub_item_table = {
                        {
                            text = _("Every wake until read"),
                            checked_func = function() return self:getSetting("sleep_show_on_wake") == "every" end,
                            callback = function() self:setSetting("sleep_show_on_wake", "every") end,
                        },
                        {
                            text = _("Once per entry"),
                            checked_func = function() return self:getSetting("sleep_show_on_wake") == "once" end,
                            callback = function() self:setSetting("sleep_show_on_wake", "once") end,
                        },
                        {
                            text = _("Never"),
                            checked_func = function() return self:getSetting("sleep_show_on_wake") == "never" end,
                            callback = function() self:setSetting("sleep_show_on_wake", "never") end,
                        },
                    },
                },
                {
                    text = _("Hide until the next reading is due"),
                    help_text = _("Quietens reminders without marking anything read."),
                    callback = function()
                        local record = self:getRecord()
                        local a = record and self:activeAssignment(record)
                        self.db.settings.sleep_hidden_until = a and a.due_date or self:today()
                        self:saveDB()
                        UIManager:show(InfoMessage:new{
                            text = _("Hidden until the next reading is due."), timeout = 2 })
                    end,
                },
            },
        },
        {
            text_func = function()
                local mins = self:getSetting("rollover_minutes") or 0
                if mins == 0 then return _("New day starts: midnight") end
                return T(_("New day starts: %1:%2"),
                    string.format("%02d", math.floor(mins / 60)),
                    string.format("%02d", mins % 60))
            end,
            help_text = _("If you read past midnight, set this later so a late-night reading still counts for the day before."),
            sub_item_table = {
                { text = _("Midnight"), callback = function() self:setSetting("rollover_minutes", 0) end },
                { text = _("2:00 am"), callback = function() self:setSetting("rollover_minutes", 120) end },
                { text = _("3:00 am"), callback = function() self:setSetting("rollover_minutes", 180) end },
                { text = _("4:00 am"), callback = function() self:setSetting("rollover_minutes", 240) end },
            },
        },
    }
end

function DailyPages:appearanceMenu()
    local theme_items = {}
    for _i, entry in ipairs(Theme:list()) do
        theme_items[#theme_items + 1] = {
            text_func = function()
                if entry.theme.implemented then return entry.theme.name end
                -- Listed honestly rather than hidden: picking one would
                -- otherwise silently render Paper and look broken.
                return T(_("%1 (coming soon)"), entry.theme.name)
            end,
            enabled_func = function() return entry.theme.implemented end,
            checked_func = function() return self:getSetting("theme") == entry.id end,
            callback = function() self:setSetting("theme", entry.id) end,
        }
    end

    return {
        { text = _("Theme"), sub_item_table = theme_items },
        {
            text = _("Calendar"),
            sub_item_table = {
                {
                    text = _("Dots"),
                    checked_func = function() return self:getSetting("calendar_layout") == "dots" end,
                    callback = function() self:setSetting("calendar_layout", "dots") end,
                },
                {
                    text = _("Day boxes"),
                    checked_func = function() return self:getSetting("calendar_layout") == "boxes" end,
                    callback = function() self:setSetting("calendar_layout", "boxes") end,
                },
                {
                    text = _("Day boxes show headings"),
                    separator = true,
                    checked_func = function() return self:getSetting("calendar_cell_text") == "heading" end,
                    callback = function() self:setSetting("calendar_cell_text", "heading") end,
                },
                {
                    text = _("Day boxes show excerpts"),
                    checked_func = function() return self:getSetting("calendar_cell_text") == "excerpt" end,
                    callback = function() self:setSetting("calendar_cell_text", "excerpt") end,
                },
                {
                    text = _("Week starts Monday"),
                    checked_func = function() return self:getSetting("week_start") == 2 end,
                    callback = function() self:setSetting("week_start", 2) end,
                },
                {
                    text = _("Week starts Sunday"),
                    checked_func = function() return self:getSetting("week_start") == 1 end,
                    callback = function() self:setSetting("week_start", 1) end,
                },
            },
        },
        {
            -- Kept alongside the calendar's Heading/Excerpt choice rather
            -- than over in Settings: both answer the same question -- how
            -- much of the entry a given surface shows -- so they belong
            -- together. Settings keeps the sleep screen's *behaviour*
            -- (whether it appears at all, and how often).
            text = _("Sleep screen"),
            sub_item_table = {
                {
                    text = _("Show the whole entry"),
                    checked_func = function() return self:getSetting("sleep_content") ~= "heading" end,
                    callback = function() self:setSetting("sleep_content", "full") end,
                },
                {
                    text = _("Show just the title"),
                    help_text = _("Keeps the day's reading private until you open it."),
                    checked_func = function() return self:getSetting("sleep_content") == "heading" end,
                    callback = function() self:setSetting("sleep_content", "heading") end,
                },
                {
                    text = _("Show the date"),
                    separator = true,
                    checked_func = function() return self:getSetting("sleep_show_date") ~= false end,
                    callback = function()
                        self:setSetting("sleep_show_date", self:getSetting("sleep_show_date") == false)
                    end,
                },
            },
        },
        {
            text_func = function()
                return T(_("Reading text size: %1"), self:getSetting("body_font_size"))
            end,
            -- THEMES.md: "Never auto-shrink reading body to fit" -- the size
            -- is the reader's choice and the layout paginates around it.
            sub_item_table = {
                { text = _("Smaller (16)"), callback = function() self:setSetting("body_font_size", 16) end },
                { text = _("Normal (20)"), callback = function() self:setSetting("body_font_size", 20) end },
                { text = _("Larger (24)"), callback = function() self:setSetting("body_font_size", 24) end },
                { text = _("Largest (28)"), callback = function() self:setSetting("body_font_size", 28) end },
            },
        },
    }
end

return DailyPages
