package.path = package.path .. ";./?.lua"
local M = require("dailypages_logic")

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok   %s", name))
    end
end

-- ===== Date validation & arithmetic =====
check("parseDate rejects Feb 30", M.isValidDate("2026-02-30"), false)
check("parseDate rejects month 13", M.isValidDate("2026-13-01"), false)
check("parseDate rejects day 0", M.isValidDate("2026-01-00"), false)
check("parseDate rejects non-ISO shape", M.isValidDate("2026-2-1"), false)
check("parseDate rejects nil", M.isValidDate(nil), false)
check("parseDate rejects non-string", M.isValidDate(20260101), false)
check("parseDate accepts leap day", M.isValidDate("2028-02-29"), true)
check("parseDate rejects leap day in non-leap year", M.isValidDate("2026-02-29"), false)
check("parseDate rejects leap day in century non-leap year", M.isValidDate("1900-02-29"), false)
check("parseDate accepts leap day in 400-year exception", M.isValidDate("2000-02-29"), true)

check("daysBetween same day", M.daysBetween("2026-09-09", "2026-09-09"), 0)
check("daysBetween across year", M.daysBetween("2026-12-31", "2027-01-01"), 1)
check("daysBetween leap Feb", M.daysBetween("2028-02-28", "2028-03-01"), 2)
check("daysBetween invalid input returns nil", M.daysBetween("2026-02-30", "2026-09-09"), nil)
check("daysBetween calendar-year repeat", M.daysBetween("2026-09-09", "2027-09-09"), 365)
check("daysBetween calendar-year repeat across a leap year", M.daysBetween("2027-09-09", "2028-09-09"), 366)

check("addDays forward across month", M.addDays("2026-09-30", 1), "2026-10-01")
check("addDays backward across year", M.addDays("2027-01-01", -1), "2026-12-31")
check("addDays invalid input returns nil", M.addDays("not-a-date", 1), nil)

-- ===== effectiveDate (rollover) =====
check("effectiveDate: midnight rollover (default) keeps the calendar date", M.effectiveDate("2026-09-09T01:30:00", 0), "2026-09-09")
check("effectiveDate: bare date passes through unchanged", M.effectiveDate("2026-09-09", 180), "2026-09-09")
check("effectiveDate: before rollover counts as the previous day", M.effectiveDate("2026-09-09T01:30:00", 180), "2026-09-08")
check("effectiveDate: at/after rollover counts as today", M.effectiveDate("2026-09-09T03:00:00", 180), "2026-09-09")
check("effectiveDate: rollover across a month boundary", M.effectiveDate("2026-10-01T00:30:00", 180), "2026-09-30")
check("effectiveDate: invalid input returns nil", M.effectiveDate(nil, 0), nil)

-- ===== Test fixture: a 5-entry sequence book =====
local function entriesFn(slot)
    if slot >= 1 and slot <= 5 then return { "entry-" .. slot } end
    return nil -- past end of book
end

local function newSeqPlan(missed_policy)
    return M.newPlan{
        plan_id = "p1", book_id = "book1", mode = "sequence",
        quantity = 1, interval_days = 1, missed_policy = missed_policy or "hold",
        start_date = "2026-09-01",
    }
end

-- ===== Due on start =====
local p = newSeqPlan()
M.reconcile(p, "2026-09-01", entriesFn)
check("due-on-start: assignment allocated on start_date, no initial wait", #p.assignment_order, 1)
check("due-on-start: due_date equals start_date", p.assignments[p.assignment_order[1]].due_date, "2026-09-01")

-- ===== Repeated reconcile is idempotent =====
M.reconcile(p, "2026-09-01", entriesFn)
M.reconcile(p, "2026-09-01", entriesFn)
check("repeated reconcile allocates nothing new (hold, unresolved)", #p.assignment_order, 1)

-- ===== Browsing never mutates plan state =====
local view = { entry_index = 1 }
M.viewNext(view, 5)
M.viewNext(view, 5)
M.viewPrev(view, 5)
check("browse-without-mutation: view moved", view.entry_index, 2)
check("browse-without-mutation: plan assignment count unchanged", #p.assignment_order, 1)
check("browse-without-mutation: assignment still pending", p.assignments[p.assignment_order[1]].status, "pending")

-- ===== Mark read -> completed; duplicate mark is a no-op =====
local a1_id = p.assignment_order[1]
M.markEntryRead(p, a1_id, "entry-1", "2026-09-01T10:00:00")
check("mark read: status becomes completed", p.assignments[a1_id].status, "completed")
check("mark read: completed_at set", p.assignments[a1_id].completed_at, "2026-09-01T10:00:00")

M.markEntryRead(p, a1_id, "entry-1", "2026-09-05T10:00:00") -- duplicate completion attempt
check("duplicate completion: timestamp NOT overwritten", p.assignments[a1_id].entry_outcomes["entry-1"].recorded_at, "2026-09-01T10:00:00")
check("duplicate completion: completed_at NOT overwritten", p.assignments[a1_id].completed_at, "2026-09-01T10:00:00")

-- ===== Hold mode: completing schedules the next one, due date + interval =====
M.reconcile(p, "2026-09-01", entriesFn)
check("hold: next assignment allocated after completion", #p.assignment_order, 2)
local a2_id = p.assignment_order[2]
check("hold: next due date is completion date + interval_days", p.assignments[a2_id].due_date, "2026-09-02")

-- Reconciling again before it's resolved allocates nothing further.
M.reconcile(p, "2026-09-10", entriesFn)
check("hold: still only one outstanding unresolved assignment", #p.assignment_order, 2)

-- ===== Partial batch (multi-entry assignment, one entry read, one pending) =====
local pm = newSeqPlan()
local multi_entries = function(slot) if slot == 1 then return { "e1", "e2" } end return nil end
M.reconcile(pm, "2026-09-01", multi_entries)
local pm_a1 = pm.assignment_order[1]
M.markEntryRead(pm, pm_a1, "e1", "2026-09-01T00:00:00")
check("partial batch: one of two entries read -> partial", pm.assignments[pm_a1].status, "partial")
M.reconcile(pm, "2026-09-01", multi_entries)
check("partial batch: hold does not allocate next while partial", #pm.assignment_order, 1)
M.markEntryRead(pm, pm_a1, "e2", "2026-09-01T01:00:00")
check("partial batch: both read -> completed", pm.assignments[pm_a1].status, "completed")

-- ===== Skip -> skipped status, breaks streak; correcting to read later is recorded =====
local ps = newSeqPlan()
M.reconcile(ps, "2026-09-01", entriesFn)
local ps_a1 = ps.assignment_order[1]
M.skipEntry(ps, ps_a1, "entry-1", "2026-09-01T00:00:00")
check("skip: status becomes skipped", ps.assignments[ps_a1].status, "skipped")
check("streak: a skip breaks the streak (0)", M.computeStreak(ps, "2026-09-01"), 0)
-- Correcting it the NEXT day (after due_date has passed) is a late
-- completion -- DESIGN.md §5: "does not retroactively repair an on-time
-- streak". Recorded, but still doesn't count.
M.markEntryRead(ps, ps_a1, "entry-1", "2026-09-02T00:00:00")
check("skip->read correction is recorded, not a duplicate", ps.assignments[ps_a1].status, "completed")
check("late correction does not repair the streak", M.computeStreak(ps, "2026-09-02"), 0)

-- A same-day correction (before due_date has passed) IS on-time and
-- counts normally -- this is the complementary case.
local ps2 = newSeqPlan()
M.reconcile(ps2, "2026-09-01", entriesFn)
local ps2_a1 = ps2.assignment_order[1]
M.skipEntry(ps2, ps2_a1, "entry-1", "2026-09-01T08:00:00")
M.markEntryRead(ps2, ps2_a1, "entry-1", "2026-09-01T20:00:00") -- same-day correction
check("same-day skip->read correction counts as on-time", M.computeStreak(ps2, "2026-09-01"), 1)

-- ===== Streak across several completed assignments =====
local pst = newSeqPlan()
M.reconcile(pst, "2026-09-01", entriesFn)
for i = 1, 3 do
    local aid = pst.assignment_order[#pst.assignment_order]
    M.markEntryRead(pst, aid, "entry-" .. i, "2026-09-0" .. i .. "T00:00:00")
    M.reconcile(pst, "2026-09-0" .. i, entriesFn)
end
check("streak: three completions in a row", M.computeStreak(pst, "2026-09-03"), 3)
check("streak: the trailing not-yet-due assignment doesn't count as a miss", pst.assignments[pst.assignment_order[4]].status, "pending")
-- But once that same trailing assignment's due date has actually passed
-- without being resolved, it IS a miss and breaks the streak.
check("streak: an overdue unresolved assignment breaks the streak", M.computeStreak(pst, "2026-09-05"), 0)

-- ===== Pause / resume shifts unresolved due date by paused duration =====
local pp = newSeqPlan()
M.reconcile(pp, "2026-09-01", entriesFn)
M.pause(pp, "2026-09-01")
check("pause: status paused", pp.status, "paused")
M.reconcile(pp, "2026-09-10", entriesFn) -- must be a no-op while paused
check("pause: reconcile is a no-op while paused", #pp.assignment_order, 1)
M.play(pp, "2026-09-10") -- resumed 9 days later
check("resume: status active again", pp.status, "active")
local pp_a1 = pp.assignments[pp.assignment_order[1]]
check("resume: unresolved due date shifted by the paused duration", pp_a1.due_date, "2026-09-10")

-- ===== Pause/play idempotency =====
local pi = newSeqPlan()
M.reconcile(pi, "2026-09-01", entriesFn)
M.pause(pi, "2026-09-01")
M.pause(pi, "2026-09-05") -- second pause call, days later -- must NOT overwrite the original paused_at
check("pause is idempotent: original paused_at preserved", pi.paused_at, "2026-09-01")
M.play(pi, "2026-09-01") -- resume immediately, no elapsed time
M.play(pi, "2026-09-01") -- second play call while already active -- must be a no-op
check("play is idempotent: no double-shift when called while already active", pi.assignments[pi.assignment_order[1]].due_date, "2026-09-01")

-- ===== Backlog pause/resume shifts ALL unresolved assignments, not just one =====
local pbp = newSeqPlan("backlog")
M.reconcile(pbp, "2026-09-05", entriesFn) -- materializes 5 pending slots
check("backlog pause setup: 5 pending assignments", #pbp.assignment_order, 5)
M.pause(pbp, "2026-09-05")
M.play(pbp, "2026-09-10") -- resumed 5 days later
for i = 1, 5 do
    local a = pbp.assignments[pbp.assignment_order[i]]
    check("backlog resume: slot " .. i .. " due date shifted by the paused duration",
        a.due_date, M.addDays(a.original_due_date, 5))
end

-- ===== Calendar occurrences are never shifted by pause/resume =====
local function calEntries(date)
    if date == "2026-01-01" then return { "jan1" } end
    return nil
end
local pcp = M.newPlan{ plan_id = "pcp1", book_id = "book3", mode = "calendar", start_date = "2026-01-01" }
M.reconcile(pcp, "2026-01-01", calEntries)
local pcp_a1 = pcp.assignments[pcp.assignment_order[1]]
local original_occurrence = pcp_a1.occurrence_date
M.pause(pcp, "2026-01-01")
M.play(pcp, "2026-01-10") -- resumed 9 days later
check("calendar: occurrence_date is never shifted by pause/resume", pcp_a1.occurrence_date, original_occurrence)
check("calendar: due_date is never shifted by pause/resume either", pcp_a1.due_date, "2026-01-01")

-- ===== Stop / restart preserves position (does NOT reset like the old module) =====
local pr = newSeqPlan()
M.reconcile(pr, "2026-09-01", entriesFn)
local pr_a1 = pr.assignment_order[1]
M.stop(pr)
check("stop: status stopped", pr.status, "stopped")
check("stop: assignment history preserved (not reset)", #pr.assignment_order, 1)
check("stop: assignment itself untouched", pr.assignments[pr_a1].status, "pending")
M.play(pr, "2026-09-20") -- restart, 19 days later
check("restart: status active again", pr.status, "active")
check("restart: rebases unresolved due date to today", pr.assignments[pr_a1].due_date, "2026-09-20")
check("restart: no duplicate assignment allocated", #pr.assignment_order, 1)

-- ===== Reset starts a genuinely fresh run, and returns the archived one =====
local run1 = pr.run_id
local run1_assignment_count = #pr.assignment_order
local _, archived = M.reset(pr, "p1-run2", "2026-10-01")
check("reset: new run_id", pr.run_id, "p1-run2")
check("reset: run_id actually changed", pr.run_id ~= run1, true)
check("reset: assignments cleared for the new run", #pr.assignment_order, 0)
check("reset: fresh start_date", pr.start_date, "2026-10-01")
check("reset: archived run_id matches the old run", archived.run_id, run1)
check("reset: archived run's assignments are NOT silently discarded", #archived.assignment_order, run1_assignment_count)

-- ===== newPlan validates required fields and cadence =====
check("newPlan: rejects missing plan_id", ({M.newPlan{ book_id = "b", start_date = "2026-09-01" }})[1], nil)
check("newPlan: rejects missing book_id", ({M.newPlan{ plan_id = "p", start_date = "2026-09-01" }})[1], nil)
check("newPlan: rejects invalid start_date", ({M.newPlan{ plan_id = "p", book_id = "b", start_date = "2026-02-30" }})[1], nil)
check("newPlan: rejects zero quantity", ({M.newPlan{ plan_id = "p", book_id = "b", start_date = "2026-09-01", quantity = 0 }})[1], nil)
check("newPlan: rejects non-integer interval_days", ({M.newPlan{ plan_id = "p", book_id = "b", start_date = "2026-09-01", interval_days = 1.5 }})[1], nil)
check("newPlan: accepts valid input", ({M.newPlan{ plan_id = "p", book_id = "b", start_date = "2026-09-01" }})[1] ~= nil, true)

-- ===== Assignment IDs are safely delimiter-encoded =====
local pid = M.newPlan{ plan_id = "book:with:colons", book_id = "b", start_date = "2026-09-01" }
M.reconcile(pid, "2026-09-01", entriesFn)
local encoded_id = pid.assignment_order[1]
check("assignment ID: colon in plan_id is escaped, not left raw", encoded_id:find("book:with:colons", 1, true), nil)
check("assignment ID: still resolves to the same assignment", pid.assignments[encoded_id] ~= nil, true)

-- ===== End of book marks the plan finished (hold mode) =====
local pf = newSeqPlan() -- hold, 5-entry book
for i = 1, 5 do
    local aid = pf.assignment_order[#pf.assignment_order]
    if not aid then M.reconcile(pf, "2026-09-0" .. i, entriesFn); aid = pf.assignment_order[#pf.assignment_order] end
    M.markEntryRead(pf, aid, "entry-" .. i, "2026-09-0" .. i .. "T00:00:00")
    M.reconcile(pf, "2026-09-0" .. i, entriesFn)
end
check("hold: plan status becomes finished once the book runs out", pf.status, "finished")
check("hold: no assignment allocated past the last entry", #pf.assignment_order, 5)

-- ===== End of book marks the plan finished (backlog mode), only once fully resolved =====
local pfb = newSeqPlan("backlog")
M.reconcile(pfb, "2026-09-30", entriesFn) -- far enough to exhaust the 5-entry book
check("backlog: not finished yet -- materialized assignments still pending", pfb.status, "active")
for _, id in ipairs(pfb.assignment_order) do
    M.markEntryRead(pfb, id, pfb.assignments[id].entry_ids[1], "2026-09-30T00:00:00")
end
M.reconcile(pfb, "2026-09-30", entriesFn)
check("backlog: finished once the book is exhausted AND everything is resolved", pfb.status, "finished")

-- ===== Backlog mode: materializes every elapsed slot, missed ones stay pending =====
local pb = newSeqPlan("backlog")
M.reconcile(pb, "2026-09-05", entriesFn) -- 5 days elapsed since start_date -> slots 1..5 due
check("backlog: materializes all elapsed slots", #pb.assignment_order, 5)
for i = 1, 5 do
    check("backlog: slot " .. i .. " left pending (never auto-resolved)", pb.assignments[pb.assignment_order[i]].status, "pending")
end
M.reconcile(pb, "2026-09-05", entriesFn)
check("backlog: repeated reconcile allocates nothing new", #pb.assignment_order, 5)

-- ===== Backlog stops materializing past the end of the book =====
local pb2 = newSeqPlan("backlog")
M.reconcile(pb2, "2026-09-30", entriesFn) -- far more elapsed days than the 5-entry book has
check("backlog: stops at end of book, not beyond available entries", #pb2.assignment_order, 5)

-- ===== Cadence edit: applies only to unallocated future assignments =====
local pc = newSeqPlan()
M.reconcile(pc, "2026-09-01", entriesFn)
local pc_a1 = pc.assignment_order[1]
M.markEntryRead(pc, pc_a1, "entry-1", "2026-09-01T00:00:00")
M.editCadence(pc, 1, 3, "2026-09-01") -- edit cadence after the first assignment already exists
M.reconcile(pc, "2026-09-01", entriesFn)
check("cadence edit: existing assignment's due_date untouched", pc.assignments[pc_a1].due_date, "2026-09-01")
local pc_a2 = pc.assignment_order[2]
check("cadence edit: new assignment uses the new interval", pc.assignments[pc_a2].due_date, "2026-09-04")
check("editCadence: rejects non-positive quantity", ({M.editCadence(pc, 0, 3, "2026-09-01")})[1], nil)
check("editCadence: rejects non-integer interval", ({M.editCadence(pc, 1, 2.5, "2026-09-01")})[1], nil)

-- ===== Calendar mode =====
local function dateEntries(date)
    local map = { ["2026-01-01"] = { "jan1" }, ["2026-01-03"] = { "jan3" }, ["2026-06-15"] = { "jun15" } }
    return map[date]
end
local pcal = M.newPlan{ plan_id = "pc1", book_id = "book2", mode = "calendar", start_date = "2026-01-01" }
M.reconcile(pcal, "2026-01-01", dateEntries)
check("calendar: today's dated entry materialized", #pcal.assignment_order, 1)
check("calendar: occurrence_date set", pcal.assignments[pcal.assignment_order[1]].occurrence_date, "2026-01-01")
M.reconcile(pcal, "2026-01-01", dateEntries)
check("calendar: repeated reconcile same day allocates nothing new", #pcal.assignment_order, 1)

-- Gap materialization: jan-1 was never "visited" again, and jan-2 has no
-- mapped entry at all -- reconciling straight to jan-3 (skipping days in
-- between) must still backfill jan-3's entry (and jan-1's stays put) so a
-- missed date can't vanish from history/streak just because the UI never
-- opened the calendar on it.
M.reconcile(pcal, "2026-01-03", dateEntries)
check("calendar: gap-materializes a later mapped date without re-visiting it", #pcal.assignment_order, 2)
local jan3 = pcal.assignments[pcal.assignment_order[2]]
check("calendar: backfilled assignment has the right occurrence_date", jan3.occurrence_date, "2026-01-03")
check("calendar: active_assignment_id follows to the new today", pcal.active_assignment_id, jan3.assignment_id)

-- No entry exists for a date without one (e.g. no Feb 29 mapping) -- reconcile must not error or fabricate one.
local pcal2 = M.newPlan{ plan_id = "pc2", book_id = "book2", mode = "calendar", start_date = "2026-02-01" }
local ok_noerr = pcall(M.reconcile, pcal2, "2026-02-01", dateEntries)
check("calendar: no mapped entry for a date does not error", ok_noerr, true)
check("calendar: no mapped entry for a date allocates nothing", #pcal2.assignment_order, 0)

print(string.format("\n%s", failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
