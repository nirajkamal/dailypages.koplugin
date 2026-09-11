# Daily Pages — a KOReader plugin

> **Experimental alpha.** Works end to end in the KOReader emulator and is under active testing on real devices. Back up anything you care about before running it, and see [Limitations](#limitations) before installing.

For books meant to be read one entry at a time — *The Daily Stoic*, *The Pivot Year*, *A New Day*, *Saltwater, Seashells & Sunshine* — and for any book you'd rather take a chapter at a time than binge.

Pick a book, choose what counts as one entry using the book's **own chapter headings**, and set how often a new one unlocks. Daily Pages keeps track of what's due, what you've read, and how long your run is.

## What it does

- **Set a pace** — *N* entries every *M* days. One a day, two a week, a chapter every three days; whatever you like.
- **Choose what an entry is** using real chapter titles from the book, not an abstract outline level. The setup screen shows you actual headings ("January 1st: CONTROL AND CHOICE") so you can see what you're picking.
- **Read today's entry** in a dedicated view with the day's date, your progress, and page controls that stay inside the entry — a page turn never spills into tomorrow's reading.
- **Two calendars** — a dot grid, or day boxes showing each day's actual heading.
- **Music-player controls** — previous/next entry, pause and resume. Pausing is neutral: it doesn't break your run.
- **Sleep screen** — optionally show the day's entry (or just its title) on the sleeping device.
- **History and plan summary** — what was read, what was skipped, when, and an estimated finish date.

Marking an entry read is the only thing that counts as reading. Browsing ahead, previewing a future date on the calendar, or seeing an entry on the sleep screen never marks anything read or advances your schedule.

## Requirements

- KOReader (developed and tested against **v2026.07.1**)
- A reflowable book with a table of contents — **EPUB**, FB2, MOBI, AZW3, HTML, TXT, RTF, CHM

## Install

1. Download this repository as a ZIP (**Code → Download ZIP**), or clone it.
2. Rename the extracted folder to exactly **`dailypages.koplugin`** if it isn't already (GitHub appends `-main` to ZIP downloads).
3. Copy that folder into KOReader's `plugins/` directory:
   - **Kindle** — `/mnt/us/koreader/plugins/`
   - **Kobo** — `.adds/koreader/plugins/`
   - **Android** — `koreader/plugins/`
   - **Linux/desktop** — `~/.config/koreader/plugins/` or the `plugins/` folder beside `reader.lua`
4. **Restart KOReader.** Plugins are only loaded at startup.

You should then find it under **Tools → Daily Pages**.

### Upgrade

Once installed, **Tools → Daily Pages → Settings → Check for updates...** downloads and installs the latest release for you and offers to restart. No manual re-copy needed after the first install.

(This isn't yet listed in any KOReader plugin store/app-store index -- those typically gate listing on a star count this repo hasn't reached. The built-in updater works regardless.)

### Uninstall

Delete the `dailypages.koplugin` folder and restart KOReader. Your plans live in `settings/dailypages_db.lua` inside KOReader's data directory — delete that too if you want the history gone as well.

## Getting started

1. **Tools → Daily Pages → Select book** — pick a book from your library. It doesn't have to be open.
2. **Create plan** — choose what counts as one entry, how many unlock at a time, how often, and what happens if you miss a day.
3. **View today's entry** — reads the day's passage. Daily Pages opens the book for you if it isn't already open.

Tap the date in the reading view to open the calendar.

By default the plugin stays on the book you picked. If you'd rather it follow whatever you're currently reading, turn on **Settings → Follow currently open book**.

## Limitations

Please read these before reporting a bug — they're known and deliberate for this alpha.

- **Chapter headings only.** Entries come from the book's table of contents. Page-count boundaries and manual entry mapping aren't implemented.
- **No fixed-layout formats.** PDF and DjVu store pages rather than text anchors; setup refuses them with an explanation rather than half-working.
- **Plain text only.** Entry text is extracted as text — images and rich formatting aren't reproduced in the Daily Pages view. The book itself is untouched; "Open this entry in the book" jumps you there for the real thing.
- **Sleep/wake is not yet verified on hardware.** The emulator can't suspend. The plugin borrows KOReader's screensaver setting and restores it on wake, including on failure, but that path needs real-device testing. If you use a custom screensaver, treat this feature as unproven.
- **No background updates.** A sleeping device runs no timers, so the sleep screen is a snapshot from when the device was last awake — it's date-stamped so you can tell which day it belongs to. Everything catches up the next time you open the plugin.
- **Three themes so far** — Paper, Reading Card, Color Field. The rest are listed as "coming soon" rather than silently falling back.
- **Dated (calendar-mapped) plans** have scheduler support but no setup UI yet; plans are sequential.

## Reporting problems

Please open an issue with:

- Your device and KOReader version
- The book format, and whether the book has a table of contents
- What you expected versus what happened
- Anything from `crash.log` in KOReader's directory

## Development

The scheduling core (`dailypages_logic.lua`) is dependency-free and runs under plain Lua:

```bash
luajit test_dailypages_logic.lua
```

It has no KOReader dependencies on purpose — all scheduling, streak and reconciliation decisions live there and are testable without a device. The UI layer (`ui_*.lua`), document access (`bookindex.lua`) and KOReader glue (`main.lua`) sit on top of it.

Designed and built collaboratively with Claude and ChatGPT.

## License

MIT — see [LICENSE](LICENSE).
