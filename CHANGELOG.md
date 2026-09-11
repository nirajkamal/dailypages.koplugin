# Changelog

## v0.3.0-alpha — 2026-09-11

First public release. Experimental.

### Added

- **Plans** — read *N* entries every *M* days, from a chosen start date, with a "wait for me" or "keep to the calendar" policy for missed days.
- **Entry selection from real chapter titles.** The setup screen previews actual headings from the book so you pick what you recognise, not an outline depth number. Optional native heading scan for books whose table of contents is too coarse.
- **Single-screen setup** — every choice editable in any order, with a live estimated finish date.
- **Reading view** — date, cover, labelled progress, entry transport, and page controls bounded to the current entry.
- **Calendars** — dot grid and day boxes (showing each day's real heading or an excerpt), with month navigation and a long-jump picker.
- **Sleep screen** — optional day's entry or title only, date-stamped, restoring KOReader's own screensaver settings afterwards.
- **Plan summary, history and archived runs**; streaks counted as completed periods in a row.
- **Default pace** — save a book's pace as the starting point for new books.
- **Themes** — Paper, Reading Card, Color Field.

### Behaviour worth knowing

- Marking read is the only action that counts as reading. Browsing entries, previewing future calendar dates and sleep-screen exposure never allocate assignments, advance the schedule or award streak credit.
- Pausing is neutral for streaks; an explicit skip is not.
- A late completion records the reading but does not retroactively repair an on-time streak.
- Editing a plan's pace only affects work not yet scheduled; already-allocated dates keep theirs.

### Known gaps

See [Limitations](README.md#limitations). In short: chapter headings only (no page-count boundaries), no PDF/DjVu, plain-text extraction, sleep/wake unverified on hardware, and dated calendar-mapped plans have scheduler support but no setup UI.
