-- Daily Pages -- sleep screen.
--
-- Two honest constraints shape this whole file, both from DESIGN.md §8:
--
--   1. "Prepare content while active; no promised midnight refresh while
--      asleep."  A suspended e-reader runs no timers of ours. Whatever is
--      on the sleep screen was rendered the last time the device was awake
--      and stays there until it wakes again. So the passage is prepared at
--      suspend time and, crucially, is stamped with the date it was
--      prepared -- a reader who left the device alone for four days sees a
--      screen that says which day it belongs to, rather than one silently
--      pretending to be today.
--
--   2. "Do not leave global screensaver settings overwritten."  The sleep
--      screen is a shared, global KOReader setting. This plugin borrows it
--      for one suspend and puts back exactly what it found on the next
--      wake, including the case where the user had no custom message at
--      all. Losing someone's screensaver configuration would be a far
--      worse bug than never showing a passage.

local Screensaver = require("ui/screensaver")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local SleepScreen = {}
SleepScreen.__index = SleepScreen

function SleepScreen.new(plugin)
    return setmetatable({ plugin = plugin, saved = nil }, SleepScreen)
end

-- ===================== Borrow / restore =====================

function SleepScreen:saveGlobals()
    if self.saved then return end -- already borrowed; don't stack
    self.saved = {
        type = G_reader_settings:readSetting("screensaver_type"),
        had_type = G_reader_settings:has("screensaver_type"),
        message = G_reader_settings:readSetting("screensaver_message"),
        had_message = G_reader_settings:has("screensaver_message"),
    }
end

function SleepScreen:restoreGlobals()
    if not self.saved then return end
    if self.saved.had_type then
        G_reader_settings:saveSetting("screensaver_type", self.saved.type)
    else
        G_reader_settings:delSetting("screensaver_type")
    end
    if self.saved.had_message then
        G_reader_settings:saveSetting("screensaver_message", self.saved.message)
    else
        G_reader_settings:delSetting("screensaver_message")
    end
    self.saved = nil
end

-- ===================== Composition =====================

-- The tear-off calendar look from the storyboard: the passage sits in the
-- middle, the date sits under it. Text only -- the sleep screen is static
-- and untappable (DESIGN.md §8), so it must not imply controls.
function SleepScreen:composeMessage(record, entry_index, prepared_date)
    local entry = record.entries[entry_index]
    if not entry then return nil end

    local title = entry.title or T(_("Entry %1"), entry_index)

    -- "Just the title" is a deliberate choice, not a degraded fallback:
    -- the sleep screen is visible to anyone who picks the device up, and
    -- some readers want the day's entry kept private until they open it.
    -- The full-text path is the default (the original "cover page" idea:
    -- the whole of the day's reading, shown on the sleeping screen).
    local body
    if self.plugin:getSetting("sleep_content") ~= "heading" then
        body = self.plugin:getEntryText(record, entry_index)
    end

    local max_chars = tonumber(self.plugin:getSetting("sleep_max_chars")) or 900
    if body and #body > max_chars then
        -- Trim on a sentence boundary where possible: a passage cut
        -- mid-word looks like a rendering failure.
        local cut = body:sub(1, max_chars)
        local last_stop = cut:match(".*()[%.%!%?\226\128\157]")
        if last_stop and last_stop > max_chars * 0.5 then
            cut = cut:sub(1, last_stop)
        end
        body = cut .. "\226\128\166"
    end

    local parts = {}
    if self.plugin:getSetting("sleep_show_title") ~= false then
        parts[#parts + 1] = title
        parts[#parts + 1] = ""
    end
    if body and body ~= "" then
        parts[#parts + 1] = body
    elseif self.plugin:getSetting("sleep_content") == "heading" then
        -- Title-only mode: the title is already in parts above unless the
        -- reader also turned the title off, in which case say something
        -- rather than showing an empty screen.
        if self.plugin:getSetting("sleep_show_title") == false then
            parts[#parts + 1] = T(_("Today's reading: %1"), title)
        end
    else
        -- No extractable text: show the heading alone rather than nothing,
        -- and never invent a passage.
        parts[#parts + 1] = T(_("Today's reading: %1"), title)
    end

    -- The date stamp. This is what makes a stale screen readable rather
    -- than misleading after several days asleep.
    local stamp = self:dateStamp(prepared_date)
    if stamp then
        parts[#parts + 1] = ""
        parts[#parts + 1] = stamp
    end

    return table.concat(parts, "\n")
end

function SleepScreen:dateStamp(prepared_date)
    if self.plugin:getSetting("sleep_show_date") == false then return nil end
    local y, m, d = prepared_date:match("(%d+)-(%d+)-(%d+)")
    if not y then return nil end
    local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
    return os.date("%B %d, %Y \226\128\148 %A", t):upper()
end

-- ===================== Lifecycle =====================

-- Called on suspend. Everything here happens while the device is still
-- awake and the document is still open -- no document is touched during
-- suspend itself, per DESIGN.md §1.
function SleepScreen:prepare()
    if self.plugin:getSetting("sleep_enabled") ~= true then return end

    local ok, err = pcall(function()
        local record, why = self.plugin:resolveSleepRecord()
        if not record then
            logger.dbg("dailypages: no sleep record:", why)
            return
        end
        local plan = record.plan

        -- Read suppresses the awake prompt, not an enabled sleep passage.
        if plan.status == "paused" or plan.status == "stopped" then return end
        local hidden = self.plugin:getSetting("sleep_hidden_until")
        if hidden and hidden > self.plugin:today() then return end
        local entry_index, entry_date = self.plugin:entryForTodayView(record)
        if not entry_index then return end
        local today = entry_date or self.plugin:today()
        local message = self:composeMessage(record, entry_index, today)
        if not message then return end

        self:saveGlobals()
        G_reader_settings:saveSetting("screensaver_type", "message")
        G_reader_settings:saveSetting("screensaver_message", message)
        self.active = {
            record = record,
            entry_index = entry_index,
            prepared_date = today,
        }
    end)
    if not ok then
        -- DESIGN.md §8: "Fallback preserves user's normal sleep screen on
        -- rendering failure." A broken passage must never cost someone
        -- their screensaver.
        logger.warn("dailypages: sleep screen preparation failed:", err)
        self:restoreGlobals()
        self.active = nil
    end
end

-- Called on resume / leaving the screensaver. Restores the user's own
-- settings first, then decides whether to offer the interactive reading.
function SleepScreen:onWake()
    self:restoreGlobals()
    local active = self.active
    self.active = nil
    if not active then return end

    -- Deduplicate: OutOfScreenSaver and Resume can both arrive, in an order
    -- that depends on device settings (confirmed in screensaverwidget.lua).
    -- Without this guard the reading view opens twice on some devices.
    local now = os.time()
    if self._last_wake and (now - self._last_wake) < 3 then return end
    self._last_wake = now

    if self.plugin:getSetting("sleep_open_on_wake") ~= true then return end

    -- The device may have been asleep across a date boundary -- or across
    -- several. Reconcile against the real current date before showing
    -- anything, so what opens is today's reading and not the stale one the
    -- sleep screen was still displaying.
    UIManager:nextTick(function()
        self.plugin:showTodayAfterWake(active)
    end)
end

return SleepScreen
