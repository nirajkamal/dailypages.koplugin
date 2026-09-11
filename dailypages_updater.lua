-- Self-update check for dailypages.koplugin. Same pipeline as
-- myclippings.koplugin's updater (GitHub-releases-driven download/unpack/
-- restart, same ffi/archiver extraction, same "check now" / "update now"
-- shape -- no background auto-check, no dev branches).
--
-- Difference from myclippings: this repo DOES upload a zip asset with each
-- release (dailypages.koplugin-vX.Y.Z-alpha.zip), built via `git archive`
-- at the release tag so it always matches the tagged commit exactly. That
-- asset is preferred; GitHub's auto-generated zipball_url is only a
-- fallback if a release is ever published without one. Both shapes have a
-- single top-level directory, so the same strip-root extraction handles
-- either.

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local REPO = "nirajkamal/dailypages.koplugin"

local Updater = {}

function Updater.getInstalledVersion()
    local DataStorage = require("datastorage")
    local meta_path = DataStorage:getDataDir() .. "/plugins/dailypages.koplugin/_meta.lua"
    local ok_meta, meta = pcall(dofile, meta_path)
    return (ok_meta and meta and meta.version) or "0.0.0"
end

local function parseVersion(v)
    local parts = {}
    for part in tostring(v):gsub("^v", ""):gmatch("([^.]+)") do
        table.insert(parts, tonumber(part) or 0)
    end
    return parts
end

local function isNewer(v1, v2)
    local a, b = parseVersion(v1), parseVersion(v2)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

-- ffi/archiver directly (the API KOReader itself uses), stripping the
-- archive's single top-level directory -- either "dailypages.koplugin/"
-- (our own release asset) or "<repo>-<sha>/" (GitHub's zipball fallback).
local function unpackStripRoot(zip_path, dest)
    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not (ok_req and Archiver and Archiver.Reader) then
        return false, "archive extractor unavailable"
    end
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        local e = arc.err
        arc:close()
        return false, e or "could not open archive"
    end
    local extract_err
    for entry in arc:iterate() do
        local rel = entry.path and entry.path:match("^[^/]+/(.+)$")
        if rel and rel ~= "" then
            if not arc:extractToPath(entry.path, dest .. "/" .. rel) then
                extract_err = arc.err or "extract failed"
                break
            end
        end
    end
    arc:close()
    if extract_err then return false, extract_err end
    return true
end

-- Tiny stand-in for a single "%1" substitution, so this file doesn't need
-- to pull in ffi/util just for one placeholder.
local function T_(fmt, v)
    return (fmt:gsub("%%1", tostring(v)))
end

local function httpGetJSON(url, user_agent)
    local JSON = require("json")
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if not ok_require then return nil end
    local response = {}
    local ok, code = pcall(function()
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local c = socket.skip(1, http.request({
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = user_agent,
                ["Accept"] = "application/vnd.github.v3+json",
            },
            sink = ltn12.sink.table(response),
            redirect = true,
        }))
        socketutil:reset_timeout()
        return c
    end)
    if not ok then pcall(function() socketutil:reset_timeout() end) end
    if not ok or code ~= 200 then return nil end
    local ok_decode, decoded = pcall(JSON.decode, table.concat(response))
    if not ok_decode then return nil end
    return decoded
end

function Updater.offerReleasesPage(message)
    local Device = require("device")
    local url = "https://github.com/" .. REPO .. "/releases"
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text = message .. "\n\n" .. _("Open the releases page in a browser?"),
            ok_text = _("Open"),
            ok_callback = function() Device:openLink(url) end,
        })
    else
        UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
    end
end

function Updater.install(zip_url, old_version, new_version)
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")

    UIManager:show(InfoMessage:new{ text = _("Downloading update..."), timeout = 1 })

    UIManager:scheduleIn(0.1, function()
        local cache_dir = DataStorage:getSettingsDir() .. "/dailypages_cache"
        if lfs.attributes(cache_dir, "mode") ~= "directory" then
            lfs.mkdir(cache_dir)
        end
        local zip_path = cache_dir .. "/dailypages.koplugin.zip"

        local downloaded = false
        local ok_require, http, ltn12, socket, socketutil = pcall(function()
            return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
        end)
        if ok_require then
            local file = io.open(zip_path, "wb")
            if file then
                local ok_dl, code = pcall(function()
                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                    local c = socket.skip(1, http.request({
                        url = zip_url,
                        method = "GET",
                        headers = { ["User-Agent"] = "KOReader-DailyPages/" .. old_version },
                        sink = ltn12.sink.file(file),
                        redirect = true,
                    }))
                    socketutil:reset_timeout()
                    return c
                end)
                if not ok_dl then pcall(function() socketutil:reset_timeout() end) end
                downloaded = ok_dl and code == 200
            end
        end
        if not downloaded then
            pcall(os.remove, zip_path)
            local ret = os.execute(string.format(
                "curl -sfL --connect-timeout 10 --max-time 300 -o %q %q", zip_path, zip_url))
            downloaded = ret == 0 or ret == true
        end
        if not downloaded then
            pcall(os.remove, zip_path)
            Updater.offerReleasesPage(_("Download failed."))
            return
        end

        local plugin_path = DataStorage:getDataDir() .. "/plugins/dailypages.koplugin"
        local ok, err = unpackStripRoot(zip_path, plugin_path)
        pcall(os.remove, zip_path)

        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Installation failed: ") .. tostring(err),
                timeout = 5,
            })
            return
        end

        UIManager:show(ConfirmBox:new{
            text = T_(_("Daily Pages updated to v%1.\n\nRestart KOReader now?"), new_version),
            ok_text = _("Restart"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end)
end

function Updater.check()
    local installed_version = Updater.getInstalledVersion()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{ text = _("Checking for updates..."), timeout = 1 })

        UIManager:scheduleIn(0.1, function()
            local user_agent = "KOReader-DailyPages/" .. installed_version
            -- NOT /releases/latest: that endpoint excludes prereleases by
            -- definition, and this plugin is still alpha-tagged -- it
            -- returns a plain 404 as long as every release is marked
            -- prerelease, which silently broke update checks entirely.
            -- The releases list, newest first, works regardless.
            local releases = httpGetJSON(
                "https://api.github.com/repos/" .. REPO .. "/releases",
                user_agent)
            local release = releases and releases[1]

            if not release or not release.tag_name then
                Updater.offerReleasesPage(_("Could not check for updates."))
                return
            end

            local latest_version = release.tag_name:gsub("^v", ""):gsub("%-alpha$", "")
            if not isNewer(latest_version, installed_version) then
                UIManager:show(InfoMessage:new{
                    text = _("Daily Pages is up to date.") .. "\n\n" .. _("Version: ") .. "v" .. installed_version,
                    timeout = 3,
                })
                return
            end

            -- Prefer our own uploaded release asset (built via `git archive`
            -- at the tag, so it exactly matches what shipped) over GitHub's
            -- auto-generated zipball, which is only a fallback.
            local zip_url = nil
            if release.assets then
                for _, asset in ipairs(release.assets) do
                    if asset.name and asset.name:match("%.zip$") then
                        zip_url = asset.browser_download_url
                        break
                    end
                end
            end
            zip_url = zip_url or release.zipball_url
            if not zip_url then
                Updater.offerReleasesPage(_("Latest release has no downloadable archive."))
                return
            end

            local function stripMarkdown(text)
                text = text:gsub("#+%s*", "")
                text = text:gsub("%*%*(.-)%*%*", "%1")
                text = text:gsub("%*(.-)%*", "%1")
                text = text:gsub("`(.-)`", "%1")
                text = text:gsub("%[(.-)%]%(.-%)", "%1")
                return text
            end
            local notes = stripMarkdown(release.body or "")

            local TextViewer = require("ui/widget/textviewer")
            local viewer
            local buttons = {
                {
                    { text = _("Close"), callback = function() UIManager:close(viewer) end },
                    {
                        text = _("Update and restart"),
                        callback = function()
                            UIManager:close(viewer)
                            Updater.install(zip_url, installed_version, latest_version)
                        end,
                    },
                },
            }
            viewer = TextViewer:new{
                title = _("Update available!"),
                text = _("Installed: ") .. "v" .. installed_version .. "\n" ..
                    _("Latest: ") .. "v" .. latest_version .. "\n\n" .. notes,
                buttons_table = buttons,
                add_default_buttons = false,
            }
            UIManager:show(viewer)
        end)
    end)
end

return Updater
