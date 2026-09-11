-- Pure logic for dailypages.koplugin: date arithmetic, plan/assignment
-- persistence shape, and reconciliation -- per the contract agreed in
-- DESIGN.md ("[ChatGPT] Assignment identity and state contract"). Rewrite
-- of the earlier index-based prototype per that doc's static review:
--   - stop() no longer resets position/history (only disables the plan)
--   - next()/prev() are pure VIEW navigation and never touch plan progress
--     or mark anything read (browsing a future entry cannot allocate or
--     complete it)
--   - nothing auto-advances "read" state; reconcile() only ensures due
--     assignments EXIST, mark/skip are the only ways to resolve one
--   - assignment identity is (plan_id, run_id, assignment_seq) /
--     slot_index / occurrence_date, never a bare date or index
--   - dates are validated against the real calendar (rejects 2026-02-30,
--     non-string/nil input, etc.), not just the "YYYY-MM-DD" shape
--
-- Dependency-free (no "require" of anything KOReader-specific) so it runs
-- under plain lua/luajit, independent of a device or the full app.

local M = {}

-- ===================== Date helpers (ISO "YYYY-MM-DD" strings) =====================

local function isLeapYear(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function daysInMonth(y, m)
    if m == 2 and isLeapYear(y) then return 29 end
    return DAYS_IN_MONTH[m]
end

-- Proleptic Gregorian day-number (Fliegel & Van Flandern), for simple
-- subtraction across month/year boundaries and leap years, century
-- exceptions included (1900 is not a leap year, 2000 is).
local function toDayNumber(y, m, d)
    if m <= 2 then
        y = y - 1
        m = m + 12
    end
    local a = math.floor(y / 100)
    local b = 2 - a + math.floor(a / 4)
    return math.floor(365.25 * (y + 4716)) + math.floor(30.6001 * (m + 1)) + d + b - 1524
end

-- Inverse of toDayNumber.
local function fromDayNumber(dn)
    local a = dn + 32044
    local b = math.floor((4 * a + 3) / 146097)
    local c = a - math.floor(146097 * b / 4)
    local dd = math.floor((4 * c + 3) / 1461)
    local e = c - math.floor(1461 * dd / 4)
    local mm = math.floor((5 * e + 2) / 153)
    local day = e - math.floor((153 * mm + 2) / 5) + 1
    local month = mm + 3 - 12 * math.floor(mm / 10)
    local year = 100 * b + dd - 4800 + math.floor(mm / 10)
    return year, month, day
end

-- Validates the string is well-formed AND names a real calendar date
-- (rejects e.g. "2026-02-30", "2026-13-01", "2026-2-1", non-strings, nil).
-- Returns y, m, d on success, or nil on any failure.
function M.parseDate(s)
    if type(s) ~= "string" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 then return nil end
    if d < 1 or d > daysInMonth(y, m) then return nil end
    return y, m, d
end

function M.isValidDate(s)
    return M.parseDate(s) ~= nil
end

function M.formatDate(y, m, d)
    return string.format("%04d-%02d-%02d", y, m, d)
end

-- b - a, in whole days. Both "YYYY-MM-DD", both validated. Returns nil if
-- either is malformed or not a real date.
function M.daysBetween(a, b)
    local ay, am, ad = M.parseDate(a)
    local by, bm, bd = M.parseDate(b)
    if not ay or not by then return nil end
    return toDayNumber(by, bm, bd) - toDayNumber(ay, am, ad)
end

-- today + n days, "YYYY-MM-DD" in, "YYYY-MM-DD" out. n may be negative.
-- Returns nil if `date` is invalid.
function M.addDays(date, n)
    local y, m, d = M.parseDate(date)
    if not y then return nil end
    return M.formatDate(fromDayNumber(toDayNumber(y, m, d) + n))
end

-- ===================== IDs =====================
-- Callers own uniqueness for plan_id/run_id (e.g. book path + timestamp);
-- this just centralizes the counter-based, never-reused assignment_seq
-- allocation the contract requires.

function M.nextAssignmentSeq(plan)
    local seq = plan.next_assignment_seq
    plan.next_assignment_seq = seq + 1
    return seq
end

-- ===================== Plan construction =====================

-- True for a positive integer (rejects 0, negatives, non-integers, non-numbers).
local function isPositiveInteger(v)
    return type(v) == "number" and v >= 1 and v == math.floor(v)
end
M.isPositiveInteger = isPositiveInteger

-- Escapes ":" (the assignment_id delimiter) in a caller-supplied
-- component so a plan_id/run_id containing one can't be split ambiguously
-- when assignment_id is later parsed apart (DESIGN.md §4: "Validate/encode
-- components when serializing with delimiters").
local function encodeIdComponent(s)
    return (tostring(s):gsub(":", "%%3A"))
end
M.encodeIdComponent = encodeIdComponent

-- opts: { plan_id, book_id, mode = "sequence"|"calendar",
--         quantity, interval_days, missed_policy = "hold"|"backlog",
--         start_date, rollover_minutes }
-- Returns nil, error_message if plan_id/book_id/start_date are missing or
-- quantity/interval_days aren't positive integers -- never constructs a
-- plan with invalid cadence.
function M.newPlan(opts)
    if not opts.plan_id or opts.plan_id == "" then return nil, "plan_id is required" end
    if not opts.book_id or opts.book_id == "" then return nil, "book_id is required" end
    if not M.isValidDate(opts.start_date) then return nil, "start_date must be a valid YYYY-MM-DD date" end
    local quantity = opts.quantity or 1
    local interval_days = opts.interval_days or 1
    if not isPositiveInteger(quantity) then return nil, "quantity must be a positive integer" end
    if not isPositiveInteger(interval_days) then return nil, "interval_days must be a positive integer" end

    return {
        schema_version = 1,
        plan_id = opts.plan_id,
        run_id = opts.run_id or (opts.plan_id .. "-run1"),
        book_id = opts.book_id,
        mode = opts.mode or "sequence",
        status = "active", -- active | paused | stopped | finished
        cadence = { quantity = quantity, interval_days = interval_days },
        missed_policy = opts.missed_policy or "hold", -- sequence only
        start_date = opts.start_date,
        rollover_minutes = opts.rollover_minutes or 0,
        schedule_revision = 1,
        -- Anchor for backlog's formula-based due-date computation (slot N's
        -- due date = boundary.date + (N - boundary.slot) * interval_days).
        -- Starts at slot 1 / start_date; editCadence() moves it forward so
        -- a cadence change only affects not-yet-materialized slots, per
        -- "Cadence changes affect unallocated future work... explicit
        -- effective scheduling boundary" (DESIGN.md §3).
        schedule_boundary = { slot = 1, date = opts.start_date },
        next_assignment_seq = 1,
        active_assignment_id = nil,
        paused_at = nil,
        assignments = {}, -- assignment_id -> assignment
        assignment_order = {}, -- assignment_id list, allocation order (for iteration/streak)
    }
end

local function newAssignment(plan, entry_ids, slot_index, due_date, occurrence_date)
    local seq = M.nextAssignmentSeq(plan)
    local id = encodeIdComponent(plan.plan_id) .. ":" .. encodeIdComponent(plan.run_id) .. ":" .. tostring(seq)
    local a = {
        assignment_id = id,
        slot_index = slot_index,
        schedule_revision = plan.schedule_revision,
        occurrence_date = occurrence_date,
        original_due_date = due_date,
        due_date = due_date,
        entry_ids = entry_ids,
        entry_outcomes = {},
        status = "pending", -- pending | partial | completed | skipped | superseded
        completed_at = nil, -- set only when status becomes "completed" (on-time/late check uses this)
        resolved_at = nil,  -- set when status becomes completed OR skipped; hold-reconcile's "next due" anchor
    }
    plan.assignments[id] = a
    table.insert(plan.assignment_order, id)
    return a
end

-- ===================== Outcome computation =====================
-- Per DESIGN.md: every assigned entry read -> completed; all resolved
-- with at least one skipped -> skipped; some resolved -> partial; none
-- resolved -> pending.
function M.computeOutcome(assignment)
    local total = #assignment.entry_ids
    if total == 0 then return "pending" end
    local resolved, read_count, skip_count = 0, 0, 0
    for _, entry_id in ipairs(assignment.entry_ids) do
        local o = assignment.entry_outcomes[entry_id]
        if o then
            resolved = resolved + 1
            if o.status == "read" then read_count = read_count + 1
            elseif o.status == "skipped" then skip_count = skip_count + 1 end
        end
    end
    if resolved == 0 then return "pending" end
    if read_count == total then return "completed" end
    if resolved == total and skip_count > 0 then return "skipped" end
    return "partial"
end

local function refreshAssignmentStatus(assignment, now)
    local was = assignment.status
    assignment.status = M.computeOutcome(assignment)
    if assignment.status == "completed" and was ~= "completed" then
        assignment.completed_at = now
    end
    -- resolved_at marks the moment this assignment left "pending"/"partial"
    -- for a terminal outcome (completed OR skipped) -- distinct from
    -- completed_at, which is specifically for the on-time/late streak
    -- check and must stay nil for a skip. Hold-mode's "next due date"
    -- anchor needs this regardless of which terminal outcome it was.
    if (assignment.status == "completed" or assignment.status == "skipped")
        and was ~= "completed" and was ~= "skipped" then
        assignment.resolved_at = now
    end
end

-- Marks one entry within an assignment read. Idempotent: marking an
-- already-read entry is a no-op that preserves its original timestamp.
-- A later correction from skipped to read IS recorded (contract: "a later
-- correction of skipped to read is a recorded history action, not
-- duplicate completion").
function M.markEntryRead(plan, assignment_id, entry_id, now)
    local a = plan.assignments[assignment_id]
    if not a then return false end
    local existing = a.entry_outcomes[entry_id]
    if existing and existing.status == "read" then
        return true -- no-op, preserves original timestamp
    end
    a.entry_outcomes[entry_id] = { status = "read", recorded_at = now }
    refreshAssignmentStatus(a, now)
    return true
end

-- Explicit completion correction; never creates an assignment.
function M.unmarkEntryRead(plan, assignment_id, entry_id, now)
    local a=plan.assignments[assignment_id]
    local outcome=a and a.entry_outcomes[entry_id]
    if not outcome or outcome.status~="read" then return false end
    a.corrections=a.corrections or {}
    a.corrections[#a.corrections+1]={entry_id=entry_id,action="unmark_read",recorded_at=now,previous=outcome}
    a.entry_outcomes[entry_id]=nil
    a.status=M.computeOutcome(a)
    a.completed_at=nil
    a.resolved_at=nil
    plan.active_assignment_id=assignment_id
    if plan.status=="finished" then plan.status="active" end
    return true
end

function M.skipEntry(plan, assignment_id, entry_id, now)
    local a = plan.assignments[assignment_id]
    if not a then return false end
    local existing = a.entry_outcomes[entry_id]
    if existing and existing.status == "skipped" then
        return true
    end
    a.entry_outcomes[entry_id] = { status = "skipped", recorded_at = now }
    refreshAssignmentStatus(a, now)
    return true
end

-- ===================== Reconciliation =====================
-- Ensures due assignments exist. NEVER marks anything read or skipped.
-- Safe/idempotent to call repeatedly (e.g. every check-in) -- calling it
-- twice on the same day with nothing resolved in between allocates
-- nothing new.

-- completed_at/recorded_at are full timestamps ("YYYY-MM-DDTHH:MM:SS",
-- caller-supplied -- e.g. os.date("%Y-%m-%dT%H:%M:%S")); scheduling dates
-- are pure "YYYY-MM-DD". Extracts the date portion so the two never get
-- silently mixed (addDays/parseDate reject anything with a time suffix).
-- Does NOT apply rollover -- use M.effectiveDate for that; this is the
-- plain fallback for values that are already bare dates.
local function dateOnly(s)
    if type(s) ~= "string" then return s end
    return s:match("^(%d%d%d%d%-%d%d%-%d%d)") or s
end

-- The "effective" calendar date for a timestamp, applying an optional
-- local rollover offset in minutes from midnight (DESIGN.md §3: "Effective
-- date uses local rollover (midnight default)... simply cutting a
-- timestamp at its first ten characters is insufficient for non-midnight
-- rollover"). rollover_minutes=180 means the day doesn't turn over until
-- 3am, so a 01:30 timestamp's effective date is the PREVIOUS calendar
-- date. A bare "YYYY-MM-DD" (no time component) passes through unchanged
-- -- there's nothing to roll over without a time of day.
-- Device timezone/DST conversion of the incoming timestamp itself is the
-- caller's responsibility; per DESIGN.md §9 this is unverified against
-- real device behavior, only the calendar-side rollover math is tested
-- here.
function M.effectiveDate(timestamp, rollover_minutes)
    rollover_minutes = rollover_minutes or 0
    if type(timestamp) ~= "string" then return nil end
    local date_part, h, mi = timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d):(%d%d)")
    if not date_part then return dateOnly(timestamp) end -- no time component
    if not M.isValidDate(date_part) then return nil end
    if rollover_minutes <= 0 then return date_part end
    local minutes_since_midnight = tonumber(h) * 60 + tonumber(mi)
    if minutes_since_midnight < rollover_minutes then
        return M.addDays(date_part, -1)
    end
    return date_part
end

local function activeAssignment(plan)
    if not plan.active_assignment_id then return nil end
    return plan.assignments[plan.active_assignment_id]
end

local function reconcileSequenceHold(plan, today, total_entries_fn)
    local a = activeAssignment(plan)
    if a and (a.status == "pending" or a.status == "partial") then
        return -- hold: exactly one unresolved assignment outstanding at a time
    end
    -- Either no assignment yet, or the active one is resolved (completed
    -- /skipped) -- allocate the next slot, due at the resolution date (or
    -- start_date for the very first one) + interval_days. First assignment
    -- is due ON start_date, per contract ("no initial wait from index 0").
    local next_due
    local next_slot
    if not a then
        next_due = plan.start_date
        next_slot = 1
    else
        next_due = M.addDays(M.effectiveDate(a.resolved_at, plan.rollover_minutes) or a.due_date, plan.cadence.interval_days)
        next_slot = a.slot_index + 1
    end
    if not next_due then return end -- malformed date input somewhere upstream; don't allocate a broken record
    local entry_ids = total_entries_fn(next_slot)
    if not entry_ids then
        -- Past the end of the book, and nothing left unresolved (checked
        -- above): the plan has genuinely run its course.
        plan.status = "finished"
        return
    end
    local new_a = newAssignment(plan, entry_ids, next_slot, next_due, nil)
    plan.active_assignment_id = new_a.assignment_id
end

local function dueDateForSlot(plan, slot)
    local boundary = plan.schedule_boundary or { slot = 1, date = plan.start_date }
    return M.addDays(boundary.date, (slot - boundary.slot) * plan.cadence.interval_days)
end

local function reconcileSequenceBacklog(plan, today, total_entries_fn)
    -- Materialize every elapsed slot in order, leaving missed ones
    -- pending (never auto-resolved). Idempotent: only allocates slots
    -- whose due date has arrived and that don't already have an
    -- assignment. Due dates come from dueDateForSlot's boundary anchor,
    -- not a raw start_date+interval formula, so a cadence edit only
    -- changes not-yet-materialized slots (already-allocated ones keep
    -- their own stored due_date, untouched here).
    local last_slot = 0
    for _, id in ipairs(plan.assignment_order) do
        local a = plan.assignments[id]
        if a.slot_index and a.slot_index > last_slot then
            last_slot = a.slot_index
        end
    end
    local slot = math.max(last_slot + 1, plan.schedule_boundary and plan.schedule_boundary.slot or 1)
    local book_exhausted = false
    while true do
        local due = dueDateForSlot(plan, slot)
        if not due or (M.daysBetween(due, today) or -1) < 0 then break end -- not due yet
        local entry_ids = total_entries_fn(slot)
        if not entry_ids then book_exhausted = true break end -- past the end of the book
        newAssignment(plan, entry_ids, slot, due, nil)
        slot = slot + 1
    end
    -- Unlike hold (one outstanding assignment), backlog can have several
    -- pending/partial at once -- only finish once the book has no more
    -- content AND every already-materialized assignment is resolved, not
    -- merely because materialization has caught up to "not due yet".
    if book_exhausted then
        local any_unresolved = false
        for _, id in ipairs(plan.assignment_order) do
            local a = plan.assignments[id]
            if a.status == "pending" or a.status == "partial" then
                any_unresolved = true
                break
            end
        end
        if not any_unresolved then
            plan.status = "finished"
        end
    end
end

-- Changes cadence going forward only. Not-yet-materialized slots (from
-- the next unallocated slot onward) use the new quantity/interval,
-- anchored to `today` -- already-allocated assignments' due_date fields
-- are untouched (DESIGN.md §3: "Do not recompute all historical dates
-- from a changed start/cadence").
function M.editCadence(plan, quantity, interval_days, today)
    if not isPositiveInteger(quantity) then return nil, "quantity must be a positive integer" end
    if not isPositiveInteger(interval_days) then return nil, "interval_days must be a positive integer" end
    plan.cadence.quantity = quantity
    plan.cadence.interval_days = interval_days
    plan.schedule_revision = plan.schedule_revision + 1
    local max_slot = 0
    for _, id in ipairs(plan.assignment_order) do
        local a = plan.assignments[id]
        if a.slot_index and a.slot_index > max_slot then max_slot = a.slot_index end
    end
    plan.schedule_boundary = { slot = max_slot + 1, date = today }
    return plan
end

local CALENDAR_MATERIALIZE_DAY_CAP = 3660 -- ~10 years; bounds the walk below for a very old start_date

local function reconcileCalendar(plan, today, entries_for_date_fn)
    -- One assignment per occurrence_date, for every dated entry from
    -- start_date through today -- not just today -- so a date the user
    -- never opened the calendar to "visit" still gets a pending/missed
    -- record and isn't invisible to history/streak (DESIGN.md §4/§7:
    -- "Calendar gaps must be accounted for independently of UI visits").
    -- Idempotent: skips any date that already has an assignment. Days
    -- with no mapped entry (e.g. no Feb 29 mapping) are skipped, not
    -- errored. Never marks anything read. Future dates are still looked
    -- up on demand when browsed, not pre-allocated here.
    local already = {}
    for _, id in ipairs(plan.assignment_order) do
        local a = plan.assignments[id]
        if a.occurrence_date then already[a.occurrence_date] = true end
    end

    local span = M.daysBetween(plan.start_date, today)
    if not span or span < 0 then span = 0 end
    if span > CALENDAR_MATERIALIZE_DAY_CAP then span = CALENDAR_MATERIALIZE_DAY_CAP end

    for offset = 0, span do
        local date = M.addDays(plan.start_date, offset)
        if date and not already[date] then
            local entry_ids = entries_for_date_fn(date)
            if entry_ids then
                newAssignment(plan, entry_ids, nil, date, date)
                already[date] = true
            end
        end
    end

    -- active_assignment_id tracks "today's" occurrence for quick-open,
    -- when one exists (whether just materialized above or already there
    -- from an earlier reconcile).
    for _, id in ipairs(plan.assignment_order) do
        if plan.assignments[id].occurrence_date == today then
            plan.active_assignment_id = id
            break
        end
    end
end

-- entries_fn: for sequence mode, function(slot_index) -> entry_ids or nil
-- past end of book. For calendar mode, function(date) -> entry_ids or nil
-- if no entry maps to that date.
function M.reconcile(plan, today, entries_fn)
    if plan.status ~= "active" then return end -- paused/stopped/finished: no new assignments
    if plan.mode == "calendar" then
        reconcileCalendar(plan, today, entries_fn)
    elseif plan.missed_policy == "backlog" then
        reconcileSequenceBacklog(plan, today, entries_fn)
    else
        reconcileSequenceHold(plan, today, entries_fn)
    end
end

-- ===================== Play / pause / stop / restart / reset =====================

-- Applies `fn(assignment)` to every currently unresolved (pending or
-- partial) assignment -- there can be more than one at once in backlog
-- mode, unlike hold's single outstanding assignment. Calendar occurrences
-- are never shifted/rebased this way (§1/§3: "Calendar occurrences must
-- not be shifted like sequence dates" -- calendar resume just returns to
-- today's occurrence, handled separately by whatever's due on the new
-- `today` at the next reconcile).
local function forEachUnresolved(plan, fn)
    if plan.mode == "calendar" then return end
    for _, id in ipairs(plan.assignment_order) do
        local a = plan.assignments[id]
        if a.status == "pending" or a.status == "partial" then
            fn(a)
        end
    end
end

function M.play(plan, today)
    if plan.status == "active" then
        return plan -- idempotent: already playing, nothing to shift/rebase
    end
    if plan.status == "stopped" then
        -- Restart: resume saved position, rebase unresolved due dates to
        -- today (contract: "restarting a stopped sequence plan resumes
        -- its saved position and rebases unresolved work to today
        -- without allocating duplicate IDs"). Applies to every unresolved
        -- assignment, not just one, so a backlog plan's pending queue
        -- doesn't leave some entries silently un-rebased.
        forEachUnresolved(plan, function(a) a.due_date = today end)
    elseif plan.status == "paused" then
        -- Resume: shift unresolved due date(s) forward by the paused
        -- duration (daily granularity, per contract) -- a fixed offset,
        -- so relative spacing between multiple pending backlog
        -- assignments is preserved rather than collapsed to one date.
        if plan.paused_at then
            local elapsed = M.daysBetween(plan.paused_at, today) or 0
            if elapsed > 0 then
                forEachUnresolved(plan, function(a)
                    a.due_date = M.addDays(a.due_date, elapsed) or a.due_date
                end)
            end
        end
    end
    plan.status = "active"
    plan.paused_at = nil
    if not plan.start_date then
        plan.start_date = today
    end
    return plan
end

-- Freezes scheduling: reconcile() becomes a no-op while paused. Position
-- and history are untouched. Idempotent: pausing an already-paused plan
-- preserves the ORIGINAL paused_at rather than overwriting it with a
-- later call's date (which would under-count the true paused duration on
-- eventual resume).
function M.pause(plan, today)
    if plan.status == "paused" then
        return plan
    end
    plan.status = "paused"
    plan.paused_at = today
    return plan
end

-- Disables the plan. Per contract, this must NOT reset position/history
-- -- only play()/restart brings it back, from where it left off.
function M.stop(plan)
    plan.status = "stopped"
    return plan
end

-- Starts a brand new run: fresh run_id/assignments/counters. Previous
-- run's history is left in place under its own run_id if the caller
-- retains it (this function only resets the live plan fields).
-- Returns plan, archived_run -- archived_run is a snapshot of everything
-- the previous run had (run_id, assignments, assignment_order,
-- schedule_boundary) for the caller to persist (e.g. under
-- plan.past_runs[old_run_id] = archived_run) before this function clears
-- the live plan fields. Previously this data was simply discarded, which
-- doesn't match "preserves the old run's history" (DESIGN.md §3).
function M.reset(plan, new_run_id, today)
    local archived_run = {
        run_id = plan.run_id,
        assignments = plan.assignments,
        assignment_order = plan.assignment_order,
        schedule_boundary = plan.schedule_boundary,
    }
    plan.run_id = new_run_id
    plan.status = "active"
    plan.schedule_revision = 1
    plan.next_assignment_seq = 1
    plan.active_assignment_id = nil
    plan.paused_at = nil
    plan.assignments = {}
    plan.assignment_order = {}
    plan.schedule_boundary = { slot = 1, date = today }
    plan.start_date = today
    return plan, archived_run
end

-- ===================== Streak =====================
-- "Completed periods in a row" (DESIGN.md §5). Counts from the most
-- recently allocated assignment backwards:
--   - superseded: ignored entirely (replaced, not lived) -- neutral,
--     keep looking backward, doesn't count or break.
--   - completed ON TIME (completed_at's date <= due_date): +1, continue.
--   - completed LATE (completed_at's date > due_date): breaks the run.
--     "A late completion records actual reading but does not
--     retroactively repair an on-time streak" -- it doesn't count, and it
--     doesn't get skipped over as neutral either, since the period WAS
--     missed on time.
--   - pending/partial, due_date not yet passed (due today counts as not
--     yet passed -- "assignments still due today are neutral"): neutral,
--     keep looking backward -- this is just the current outstanding
--     assignment, not a miss yet.
--   - pending/partial, due_date has passed unresolved: breaks the run.
--   - skipped: breaks the run (explicit skip, "does not count as
--     reading").
-- `today` is required to distinguish "due today, neutral" from "overdue,
-- breaks" and to evaluate on-time/late; without it, any non-completed or
-- unresolved-looking assignment conservatively breaks the streak.
function M.computeStreak(plan, today)
    local streak = 0
    for i = #plan.assignment_order, 1, -1 do
        local a = plan.assignments[plan.assignment_order[i]]
        if a.status == "superseded" then
            -- neutral: doesn't count, doesn't break
        elseif a.status == "completed" then
            local on_time = today == nil -- no `today` given: assume on-time (fallback)
            if today then
                local delta = M.daysBetween(a.due_date, M.effectiveDate(a.completed_at, plan.rollover_minutes) or a.due_date)
                on_time = delta ~= nil and delta <= 0
            end
            if on_time then
                streak = streak + 1
            else
                break -- late completion: doesn't repair, breaks the run
            end
        elseif (a.status == "pending" or a.status == "partial") and today
            and (M.daysBetween(a.due_date, today) or 1) <= 0 then
            -- due_date is today or still in the future: the current
            -- outstanding assignment, not a miss yet -- neutral.
        else
            break -- skipped, or overdue-and-still-unresolved: breaks the run
        end
    end
    return streak
end

-- Most recent non-empty on-time streak that ended, within this run.
function M.lastStreak(plan, today)
    local run,last=0,0
    for _,id in ipairs(plan.assignment_order or {}) do
        local a=plan.assignments[id]
        local neutral=a.status=="superseded" or
            ((a.status=="pending" or a.status=="partial") and today and a.due_date and a.due_date>=today)
        if not neutral then
            local date=M.effectiveDate(a.completed_at,plan.rollover_minutes)
            local on_time=a.status=="completed" and a.due_date and date and date<=a.due_date
            if on_time then run=run+1
            else
                if run>0 then last=run end
                run=0
            end
        end
    end
    return last
end

-- ===================== View (browsing) state =====================
-- Deliberately separate from plan progress: next()/prev() here only move
-- a cursor over already-known entries for display, and NEVER allocate,
-- complete, or skip anything. Call reconcile() (or read plan.assignments)
-- separately to know what's actually due.

function M.viewGoTo(view, entry_index, max_index)
    if entry_index < 1 then entry_index = 1 end
    if entry_index > max_index then entry_index = max_index end
    view.entry_index = entry_index
    return view
end

function M.viewNext(view, max_index)
    return M.viewGoTo(view, (view.entry_index or 0) + 1, max_index)
end

function M.viewPrev(view, max_index)
    return M.viewGoTo(view, (view.entry_index or 1) - 1, max_index)
end

return M
