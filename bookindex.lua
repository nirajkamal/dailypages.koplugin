-- Daily Pages -- book indexing and content extraction.
--
-- Everything that touches a KOReader Document lives here, behind pcall, so
-- the views never have to reason about a book that moved, failed to parse,
-- or has an unusable table of contents. Per DESIGN.md §1 this uses the
-- normal reader lifecycle only -- it never opens a second document
-- concurrently, and never touches a document during suspend.

local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local BookIndex = {}

-- ===================== File-level checks =====================

-- DESIGN.md §10 requires a "missing book" check. A stored plan outlives the
-- file it points at: a book can be deleted, moved, or sit on storage that is
-- no longer mounted. Everything downstream assumes a readable file, so this
-- is the single gate.
function BookIndex.fileExists(path)
    if not path or path == "" then return false end
    local ok, mode = pcall(lfs.attributes, path, "mode")
    return ok and mode == "file"
end

function BookIndex.missingFileMessage(path)
    return T(_("This book's file is missing:\n\n%1\n\nIt may have been moved, renamed, or deleted, or its storage may not be mounted. Your reading history is safe -- it will still be here when the file is."), path or "?")
end

-- ===================== TOC =====================

-- Returns the flat TOC array, or nil plus a reason. Each item has .title,
-- .depth, .page (an integer page number) and .xpointer (a location string
-- on reflowable documents). Those last two are NOT interchangeable, which
-- is worth stating loudly: passing .page where an xpointer is expected
-- fails silently and yields empty text.
function BookIndex.getToc(ui)
    if not (ui and ui.toc) then
        return nil, _("This document has no table of contents to read entries from.")
    end
    local ok = pcall(function() ui.toc:fillToc() end)
    if not ok then
        return nil, _("Could not read this book's table of contents. The file may be damaged or in a format Daily Pages can't index yet.")
    end
    local toc = ui.toc.toc
    if not toc or #toc == 0 then
        return nil, _("This book has no table of contents, so Daily Pages can't tell where one entry ends and the next begins.")
    end
    return toc
end

function BookIndex.maxDepth(ui)
    return (ui and ui.toc and ui.toc:getMaxDepth()) or 1
end

-- Is this a reflowable (crengine) document? Only those give us xpointers and
-- anchor-based text extraction; paged documents (PDF/DjVu) index by page and
-- can't have their entry text pulled out for the sleep screen.
function BookIndex.isReflowable(ui)
    return not not (ui and ui.document and ui.document.getPageXPointer)
end

-- The end anchor of the whole document, used to bound the final entry.
local function documentEndAnchor(ui)
    local ok, anchor = pcall(function()
        local doc = ui.document
        local xp = doc:getPageXPointer(doc:getPageCount())
        if not xp or xp == "" or not doc.getNextVisibleWordEnd then return nil end
        -- Last-page start is NOT document end. Walk only that page's words;
        -- this does not navigate the reader or alter its selection/history.
        for i=1,20000 do
            local next_xp = doc:getNextVisibleWordEnd(xp)
            if not next_xp or next_xp == "" or next_xp == xp then return xp end
            xp = next_xp
        end
        return nil -- never silently truncate an unusually large last page
    end)
    if ok then return anchor end
    return nil
end

-- Build the entry list for one TOC depth.
--
-- An "entry" is a TOC item at the chosen depth, running from its own anchor
-- to the next item AT THE SAME DEPTH (so choosing month headings gives you
-- whole months including their day sub-entries, and choosing day headings
-- gives you single days). The last entry runs to the end of the document.
--
-- Each returned entry carries both anchors because they serve different
-- jobs: `xp`/`end_xp` bound text extraction, while `page` is what we jump
-- the reader to.
function BookIndex.entriesAtDepth(ui, depth)
    local toc, err = BookIndex.getToc(ui)
    if not toc then return nil, err end

    local picked = {}
    for i, item in ipairs(toc) do
        if item.depth == depth then
            picked[#picked + 1] = {
                title = (item.title and item.title ~= "") and item.title or nil,
                page = item.page,
                xp = item.xpointer, -- nil on paged documents; that's expected
                toc_index = i,
            }
        end
    end
    if #picked == 0 then
        return nil, T(_("No chapters at level %1."), depth)
    end

    local end_anchor = documentEndAnchor(ui)
    for i, e in ipairs(picked) do
        local nxt = picked[i + 1]
        e.end_xp = nxt and nxt.xp or end_anchor
        e.end_page = nxt and nxt.page or nil
        e.index = i
        if not e.title then
            e.title = T(_("Entry %1"), i)
        end
    end
    return picked
end

-- A short, human summary of each available depth, used by setup to show
-- real book content instead of an abstract level number.
function BookIndex.describeDepths(ui)
    local max_depth = BookIndex.maxDepth(ui)
    local out = {}
    for d = 1, max_depth do
        local entries = BookIndex.entriesAtDepth(ui, d)
        if entries and #entries > 0 then
            local sample = {}
            for i = 1, math.min(3, #entries) do
                sample[#sample + 1] = entries[i].title
            end
            out[#out + 1] = {
                depth = d,
                count = #entries,
                samples = sample,
                entries = entries,
            }
        end
    end
    return out
end

-- Offer a numbered-day subset only when the actual headings form 1..N.
-- Keep original end anchors, so omitted front/back matter cannot leak in.
function BookIndex.addDayOptions(options)
    local extra = {}
    for _i, opt in ipairs(options) do
        local days = {}
        local valid = true
        for _j, e in ipairs(opt.entries) do
            local compact = (e.title or ""):lower():gsub("\194\160", ""):gsub("%s", "")
            local n = tonumber(compact:match("^day(%d+)$"))
            if n then
                if n ~= #days + 1 then valid = false; break end
                local copy = {}
                for k,v in pairs(e) do copy[k]=v end
                copy.title = T(_("Day %1"), n)
                copy.index = n
                days[#days+1] = copy
            end
        end
        if valid and #days >= 3 and #days < #opt.entries then
            for i,e in ipairs(days) do
                if days[i+1] then e.end_xp=days[i+1].xp; e.end_page=days[i+1].page end
            end
            extra[#extra+1] = {depth=-opt.depth, count=#days, entries=days,
                samples={days[1].title,days[2].title,days[#days].title},
                label=_("Numbered days only")}
        end
    end
    for _,opt in ipairs(extra) do options[#options+1]=opt end
    return options
end

function BookIndex.scanHeadings(ui)
    if not (ui.document and ui.document.buildAlternativeToc) then
        error("Heading scan is unavailable for this document")
    end
    ui.document:buildAlternativeToc()
    ui.doc_settings:makeTrue("alternative_toc")
    ui.toc:onUpdateToc()
    return BookIndex.addDayOptions(BookIndex.describeDepths(ui))
end

-- ===================== Text extraction =====================

-- Pull the source text of one entry. Reflowable documents only; paged
-- documents return nil with a reason, and callers fall back to the entry
-- heading (DESIGN.md §6 forbids fabricated excerpts, so a failure shows
-- less text, never invented text).
function BookIndex.extractText(ui, entry)
    if not (ui and ui.document) then
        return nil, _("The book isn't open.")
    end
    if not entry then
        return nil, _("No entry selected.")
    end
    if not entry.xp then
        return nil, _("This document type stores pages rather than text anchors, so its text can't be shown here yet. Open the entry in the book to read it.")
    end
    if not entry.end_xp then
        return nil, _("Couldn't work out where this entry ends.")
    end
    local ok, text = pcall(function()
        return ui.document:getTextFromXPointers(entry.xp, entry.end_xp, false)
    end)
    if not ok then
        return nil, _("Couldn't read this entry's text from the book file.")
    end
    if not text or text == "" then
        return nil, _("This entry appears to have no extractable text.")
    end
    return BookIndex.tidyText(text, entry.title)
end

-- crengine hands back text with the heading run together with the body and
-- assorted whitespace. Tidy without rewriting: collapse runs of blank lines,
-- trim trailing spaces, drop a leading copy of the heading (it is already
-- displayed above the passage). No summarising, no paraphrase.
function BookIndex.tidyText(text, heading)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[ \t]+\n", "\n")
    text = text:gsub("\n\n\n+", "\n\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- Drop a leading copy of the heading: crengine returns the chapter
    -- title as part of the section text, and it is already displayed above
    -- the passage. Compared with punctuation, case and whitespace removed,
    -- because the TOC title and the in-body heading routinely differ --
    -- "January 1st: CONTROL AND CHOICE" in the TOC against "January 1st"
    -- and "CONTROL AND CHOICE" on two lines in the body -- so a literal
    -- prefix match would almost never fire.
    if heading and heading ~= "" then
        local function norm(s) return (s:lower():gsub("[^%w]", "")) end
        local target = norm(heading)
        if #target > 0 then
            local acc, cut = "", nil
            for i = 1, math.min(#text, #target * 4 + 40) do
                acc = acc .. norm(text:sub(i, i))
                if #acc >= #target then
                    if acc == target then cut = i end
                    break
                end
            end
            if cut then
                local rest = text:sub(cut + 1):gsub("^%s+", "")
                if rest ~= "" then text = rest end
            end
        end
    end
    return text
end

-- ===================== Cover =====================

-- THEMES.md: "Use actual cover at natural ratio... Keep actual cover
-- unchanged across themes." Never generated, never substituted.
function BookIndex.getCover(ui)
    if not (ui and ui.document and ui.document.getCoverPageImage) then return nil end
    local ok, image = pcall(function() return ui.document:getCoverPageImage() end)
    if ok then return image end
    return nil
end

function BookIndex.getTitle(ui, fallback_path)
    if ui and ui.doc_props and ui.doc_props.display_title then
        return ui.doc_props.display_title
    end
    if ui and ui.document and ui.document.file then
        local base = ui.document.file:match("([^/\\]+)$") or ui.document.file
        return (base:gsub("%.%w+$", ""))
    end
    if fallback_path then
        local base = fallback_path:match("([^/\\]+)$") or fallback_path
        return (base:gsub("%.%w+$", ""))
    end
    return _("Untitled")
end

function BookIndex.getAuthors(ui)
    if ui and ui.doc_props then
        return ui.doc_props.authors or ui.doc_props.author
    end
    return nil
end

-- ===================== Navigation =====================

-- Jump the open reader to an entry's start. Used by "Open in book" and by
-- the reading view's fallback when text extraction is unavailable.
function BookIndex.goToEntry(ui, entry)
    if not (ui and entry) then return false end
    local ok = pcall(function()
        if entry.xp and ui.rolling then
            ui.link:addCurrentLocationToStack()
            ui.rolling:onGotoXPointer(entry.xp)
        elseif entry.page and ui.paging then
            ui.link:addCurrentLocationToStack()
            ui.paging:onGotoPage(entry.page)
        elseif entry.page then
            ui:handleEvent(require("ui/event"):new("GotoPage", entry.page))
        end
    end)
    return ok
end

return BookIndex
