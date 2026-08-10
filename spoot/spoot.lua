#!/usr/bin/env lua

(function()

-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

local P = {
    home      = os.getenv("HOME"),
    -- Resolved rather than hardcoded so the tree can live anywhere. The pattern
    -- needs a directory separator to match: invoked as a bare `lua spoot.lua`
    -- from inside this directory, source is "@spoot.lua", dir came back nil, and
    -- the very first use of it (resolving the themes) died on "attempt to
    -- concatenate a nil value (field 'dir')". It must also end up absolute --
    -- we re-exec ourselves as a daemon and hand paths to rofi, both of which
    -- outlive our cwd. rofi always passes an absolute path, so only a hand-run
    -- hits the fallback.
    dir       = (function()
        local d = (arg[0] or debug.getinfo(1, "S").source:match("^@(.+)$") or ""):match("^(.*)/") or "."
        if d == "." then d = os.getenv("PWD") or "."
        elseif d:sub(1, 1) ~= "/" then d = (os.getenv("PWD") or ".") .. "/" .. d end
        -- Trailing separators stripped before we add our own, because this value
        -- feeds back into itself: every call site writes P.dir .. "/spoot.lua",
        -- Util.spawn_self hands that to the child as arg[0], and the greedy
        -- ^(.*)/ above keeps the doubled separator -- so each spawn generation
        -- grew one more slash (…/spoot/, …/spoot//, …/spoot///). Harmless to
        -- POSIX, but it showed up in ps, in the daemon log, and in the cmdlines
        -- the pkill fallbacks and Util.pidfile_owner_alive match against.
        -- "/" survives as "/".
        return (d:gsub("/+$", "")) .. "/"
    end)(),
    tmp       = os.getenv("TMPDIR") or "/tmp",
    -- Results per TYPE in the one search there is, fetched AND displayed. 50 is
    -- the hard ceiling: verified against the live API, where limit=51 answers
    -- 400. /search takes a single `limit` covering every type in `type=`, so
    -- this is one number by the endpoint's own design and the request limit and
    -- the display cap cannot drift -- an invariant the split search could never
    -- have, since it had two of these to keep in step. It costs bytes: 229 KB
    -- per uncached search when Util.SEARCH_TYPES held four types, against
    -- 23.5 KB when the combined list showed 5 of each. Shows and episodes have
    -- since joined it, and both carry long descriptions, so the real figure is
    -- now materially higher and has not been re-measured. Still exactly one
    -- round trip, and a round trip is ~530 ms TTFB here.
    max       = 50,
    -- Top tracks are paged past the 50-per-request ceiling to here. A multiple
    -- of 50 so the cap lands on a page boundary; the account reports 1578
    -- available, so this needs a stop, and past ~100 a "top" list stops meaning
    -- much. Two requests, and cached_fetch holds the result for an hour.
    top_max   = 100,
    -- How long Liked Tracks, Saved Albums and Followed Artists are trusted
    -- without asking. It was twelve hours, and twelve hours was never a claim
    -- about how often a library changes -- it was how rarely you could stand to
    -- be blocked, because expiry meant init_library re-paging the whole library
    -- before the menu could open. Expiry now costs three sub-kilobyte probes in
    -- a detached process (Util.REVALIDATORS.library), so the number can say what
    -- it means: check about every fifteen minutes.
    ttl       = 900,
    -- The backstop on those probes. total-plus-head cannot see an add that
    -- cancels a remove, and me/following is ordered by name so a new follow need
    -- not move its head, so past this the re-page happens regardless of what the
    -- fingerprint says. This is the number that used to be P.ttl.
    ttl_lib_max = 43200,
    ttl_lyrics = 7 * 24 * 3600,  -- 1 week
    spotify   = "d420a117a32841c2b3474932e49fb54b",
}
P.cache      = (os.getenv("XDG_CACHE_HOME") or P.home .. "/.cache") .. "/spoot"
P.mass       = P.cache .. "/mass"
P.lyrics     = P.cache .. "/lyrics"
P.token      = P.cache .. "/token.json"
P.liked      = P.cache .. "/liked_tracks.json"
P.albums     = P.cache .. "/saved_albums.json"
P.artists    = P.cache .. "/followed_artists.json"
-- Deliberately NOT part of the library fingerprint below: shows are fetched
-- lazily on first open, the way playlists are, so a cold start never blocks on
-- a section the user may never visit. See Util.REVALIDATORS.saved_shows.
P.shows      = P.cache .. "/saved_shows.json"
P.episodes   = P.cache .. "/saved_episodes.json"
-- Where you stopped in each podcast episode, recorded HERE because Spotify does
-- not record it for us: probing 50 episodes of a show that had been played and
-- paused found zero with a non-zero resume_position_ms and none marked
-- fully_played. Playback goes through spotifyd/librespot, which reports neither
-- listening history nor playback position -- the same reason the local
-- recently-played recorder had to stay.
P.eresume    = P.cache .. "/episode_resume.json"
-- Within this much of the end an episode counts as finished, so the next play
-- starts from the top instead of dropping you into the credits.
P.eresume_end_ms  = 30 * 1000
-- Below this, a poll tick is not worth a rewrite -- a paused episode reports the
-- same position every 25s and would otherwise rewrite the file forever.
P.eresume_min_ms  = 5 * 1000
P.eresume_max     = 200

-- Util.view_listen. songrec's own --request-interval defaults to 10s, so this
-- has to allow at least two attempts to be worth calling a timeout; 30 is two
-- with headroom. The poll is what makes the window dismissable -- it is how
-- often the loop asks whether a match landed or the user closed the window, so
-- it wants to be short enough to feel instant and long enough not to spin.
P.listen_timeout = 30
P.listen_poll    = 0.3

-- When each tile grid's artwork was last warmed, one timestamp per art kind.
-- Not a cache of anything -- a rate limit; see Util.spawn_shelf_warm.
P.warm       = P.cache .. "/shelf_warm.json"
-- What the three files above looked like from Spotify's side last time we asked:
-- one head fingerprint each, plus when the last full re-page ran. Kept apart
-- from the caches themselves so confirming freshness never rewrites megabytes.
P.lib_fp     = P.cache .. "/library_fp.json"
P.session    = P.cache .. "/session.json"
P.trails     = P.cache .. "/trails.json"
-- Menus you CLOSED, as opposed to the trail's record of where you still are.
-- See Util.menu_hist_add.
P.menu_hist  = P.cache .. "/menu_history.json"
P.view_pos   = P.cache .. "/view_pos.json"
P.queue      = P.cache .. "/playback_queue.json"
P.art        = P.cache .. "/art"
-- One response-header dump per PROCESS, so they are pid-named and there can be
-- one per live spoot. They used to sit loose in the cache root as `.api_hdr.<pid>`,
-- where a helper that os.exits without unwinding left its file behind and the
-- root accumulated them. Their own directory keeps the root readable and lets
-- the sweep name a whole directory instead of a dotfile glob.
P.api        = P.cache .. "/api"
P.liked_ids  = P.cache .. "/liked_ids.json"
P.volume     = P.cache .. "/volume.json"
P.recent     = P.cache .. "/recently_played.json"
P.bitrate    = P.cache .. "/bitrate"
P.state      = P.cache .. "/playback_state.json"
P.now        = P.cache .. "/now.json"
P.now_track  = P.cache .. "/now_track.json"
P.device     = P.cache .. "/device.json"
P.pl_index   = P.cache .. "/playlist_index.json"
P.search_hist = P.cache .. "/search_history.json"
-- One line per thumbnail grid draw. A tile cannot change while its rofi window
-- is open -- rofi is handed the entries once, at exec, and scrolls inside its own
-- process -- so a grid that came up with holes cannot be examined after the fact
-- by looking at it. This is how a bad draw gets explained without reproducing
-- it. See Util.thumb_log and --thumb-report.
P.thumb_log  = P.cache .. "/thumb.log"
-- Bytes, not lines, so the cap costs a seek on a handle already open rather than
-- a read of the whole file per draw. ~130 bytes a line, so roughly 3000 draws.
P.thumb_log_max = 400 * 1024
-- playlist_id -> the art hash currently cached at art/playlists/<id>.jpg. What
-- makes a cover self-evicting: a playlist whose art changed reports a different
-- hash, so the file is refetched over the top of the old one. No TTL, and no
-- orphans possible, because the path never varies with the art.
-- One entry per kind of object whose artwork is cached BY ID rather than by art
-- hash. `field` is where that kind keeps its image array -- categories say
-- `icons`, everyone else says `images`. Playlists additionally have a `highres`
-- subdirectory; categories are served at a single 274px size so they have none.
P.art_kinds = {
    playlist = {dir = P.art .. "/playlists",  index = P.cache .. "/playlist_art.json",
                field = "images", highres = P.art .. "/playlists/highres"},
    category = {dir = P.art .. "/categories", index = P.cache .. "/category_art.json",
                field = "icons"},
    -- Collections tiles are keyed by ROW, not by any Spotify object: each one
    -- borrows the artwork of the first thing on the shelf behind it, and the
    -- shelf's contents rotate constantly. Filing them under the row's own name
    -- means the tile is replaced when that first item changes, exactly as a
    -- playlist cover is replaced when its art changes.
    collection = {dir = P.art .. "/collections", index = P.cache .. "/collection_art.json",
                field = "images"},
    -- The root menu. Row-keyed like the grids below, and the one whose art moves
    -- most: the Playback tile wears whatever is playing.
    main     = {dir = P.art .. "/main", index = P.cache .. "/main_art.json",
                field = "images"},
    -- Your library, keyed by ROW like the two grids below: each tile borrows the
    -- cover of the first thing on the list behind it, and that changes as you
    -- like, save and follow things.
    library  = {dir = P.art .. "/library", index = P.cache .. "/library_art.json",
                field = "images"},
    -- The Podcasts grid, keyed by ROW for exactly the reason collections are: a
    -- topic tile wears the cover of the first show that topic currently returns,
    -- and what that show is changes as Spotify's index does.
    podcast  = {dir = P.art .. "/podcasts", index = P.cache .. "/podcast_art.json",
                field = "images"},
}
-- The two "is this in my library" endpoints that share a URL grammar: an ?ids=
-- collection you PUT to save and DELETE to remove, and a /contains sibling that
-- answers without paging the whole thing. Named per kind so Util.lib_write and
-- Util.lib_has can be one function each rather than one pair per kind.
--
-- Artists deliberately do NOT live here. me/following?type=artist and
-- me/following/contains take the kind as a QUERY PARAMETER rather than in the
-- path, so folding them in would need an escape hatch -- which is the point
-- where a table stops being simpler than the two functions it replaced.
P.lib_kinds = {
    album = {ids = "me/albums", contains = "me/albums/contains",
             mem = "saved_albums", file = P.albums, noun = "album"},
    show  = {ids = "me/shows",  contains = "me/shows/contains",
             mem = "saved_shows",  file = P.shows,  noun = "podcast"},
}
-- Images shipped with the themes. Named once here so the layout is not
-- repeated at each use, same as every other path in this table.
P.assets     = P.dir .. "/style/assets"
local EXIT = {
    back = 10, main = 11,
    open_url = 12, jump = 13, quit = 14, liked = 15, trail_jump = 16,
    track = 17, seek = 18, art = 19, repeat_toggle = 20, lyrics = 21,
    recent = 22, shuffle_toggle = 23, clear_trail = 24,
    seek_plus = 25, seek_minus = 26,
    alt_action = 27, refresh = 28,
}
local SEP = " \u{F01D8} "
local CACHE_TTL_SHORT = 300
local CACHE_TTL_MED = 3600
local CACHE_TTL_LONG = 86400
local PROGRESS_BAR_W = 20
-- How many album covers a thumbnail grid fetches before it is allowed to draw.
-- style/thumbs.rasi shows 5x3 = 15 at a time, so this is several screens of
-- scroll headroom. An artist discography can run to 1500 albums (Rachmaninoff
-- does), and fetching every cover up front is what made such a list look like a
-- hang -- the rest is handed to a detached prefetch, see Util.album_thumbs.
local THUMB_SYNC = 60
-- Budget for the first mesg line, excluding status icons (split off, never
-- truncated). Narrowest theme is 700px: borders and padding leave 638px at 10px
-- per char, minus the shuffle/repeat prefix (57px) and the widest icon run
-- (73px) = 508px. truncate_text adds an ellipsis on top, so 49, not 50.
local MESG_NAME_MAX_CHARS = 49
-- Trailing glyphs that carry a track's status. They live at the end of the line
-- and must survive truncation, so a long title costs title characters and never
-- the icons.
local STATUS_GLYPHS = {[0xf05d] = true, [0xf071] = true, [0xF0188] = true, [0xF0189] = true}
-- One glyph per type, keyed by the PLURAL name search stamps rows with
-- (`_stype`). Read only through Util.type_icon, so the glyphs live here and
-- nowhere else.
--
-- The first four are search-only: they say which kind each row is in a list that
-- mixes them, and a music note on every row of Liked Tracks would say nothing.
-- Shows and episodes are the exception -- Util.display_show and
-- Util.display_episode carry theirs, so a podcast is marked as one in every list
-- it appears in.
local ICON_PREFIX = {
    tracks    = "\u{F0387} ",
    albums    = "\u{F405} ",
    artists   = "\u{F415} ",
    playlists = "\u{F0411} ",
    shows     = "\u{F2CE} ",
    episodes  = "\u{F07C5} ",
}
local liked = {}  -- set of liked track IDs

local current_track, current_id, previous_id, last_playback = nil, nil, nil, 0
local is_playing, is_shuffle, repeat_state = false, false, "off"
local _local_toggle_time = 0

local json = require("cjson")

-- UTILITIES

local function shell(cmd)
    local h = io.popen(cmd, "r")
    if not h then return nil end
    local ok, r = pcall(h.read, h, "*a")
    h:close()
    if not ok then return nil end
    return r
end

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

-- The album.rasi layout sizes its message box for the number of literal "\n"s
-- in the mesg string, not the number of lines it actually wraps to. A long
-- title that auto-wraps to 2 visual lines eats the row reserved for the
-- breadcrumb below it, so the trail silently disappears. Keeping the title
-- on one visual line sidesteps that miscalculation.
local function truncate_text(s, max_chars)
    if not s then return s end
    local len = utf8.len(s)
    if not len or len <= max_chars then return s end
    local byte_end = utf8.offset(s, max_chars + 1) - 1
    return s:sub(1, byte_end) .. "\u{2026}"
end

-- Peels the trailing status-icon run off a mesg line so truncation can spend the
-- whole character budget on the title and put the icons back afterwards. Without
-- this, a long title pushed the liked/explicit/lyrics glyphs past the cut and
-- they simply vanished -- the icons are the part you cannot reconstruct by
-- reading, so they are the last thing that should go.
local function split_status_icons(s)
    if not s or s == "" then return s or "", "" end
    local n = utf8.len(s)
    if not n then return s, "" end     -- invalid UTF-8: leave it alone
    local cut = #s + 1
    for i = n, 1, -1 do
        local off = utf8.offset(s, i)
        if not off then break end
        local cp = utf8.codepoint(s, off)
        if not (STATUS_GLYPHS[cp] or cp == 0x20) then break end
        cut = off
    end
    local suffix = s:sub(cut)
    -- A title that merely ends in spaces must keep them; only a run that
    -- actually contains a glyph counts as icons.
    if not suffix:find("[^ ]") then return s, "" end
    return s:sub(1, cut - 1), suffix
end

-- printf '%s', not echo: echo appends a newline, so every URL copied from here
-- landed in the clipboard with a trailing \n. parse_spotify_url strips one on
-- the way back in, but a paste anywhere else carried it.
local function copy_to_clipboard(text)
    os.execute("printf '%s' " .. shell_quote(text) .. " | wl-copy 2>/dev/null")
end

local function copy_spotify_url(kind, id) copy_to_clipboard("https://open.spotify.com/" .. kind .. "/" .. (id or "")) end

local function parse_spotify_url(url)
    if not url or url == "" then return nil, nil end
    url = url:match("^(.-)\n") or url
    url = url:gsub("[?#].*$", "")
    url = url:gsub("/+$", "")
    url = url:gsub("open%.spotify%.com/intl%-[^/]+/", "open.spotify.com/")
    local kinds = {"track", "album", "artist", "playlist", "show", "episode"}
    for _, kind in ipairs(kinds) do
        local id = url:match("open%.spotify%.com/" .. kind .. "/([%w%-_]+)")
        if id then return kind, id end
        id = url:match("spotify:" .. kind .. ":([%w%-_]+)")
        if id then return kind, id end
    end
    return nil, nil
end

-- Parenthesised so this returns ONE value, for the same reason Util.strip_markup
-- is: gsub also hands back a match count, and every call site here happens to be
-- inside a concatenation -- but the day one of them is a function's last
-- argument, that count silently becomes an extra argument.
local function url_encode(s)
    return (s:gsub("([^%w%-%.%_%~])", function(c)
        if c == " " then return "+" end
        return string.format("%%%02X", string.byte(c))
    end))
end

local function read_file(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local d = f:read("*a"); f:close()
    return d
end

-- Grouped into one table (rather than separate top-level locals) since the
-- whole script body is a single function and Lua caps it at 200 locals.
local Util = {}

-- The one reader of ICON_PREFIX. Answers "" rather than nil so every caller can
-- concatenate unguarded.
function Util.type_icon(stype)
    return ICON_PREFIX[stype or ""] or ""
end

-- The shape of style/thumbs.rasi's grid. rofi_dmenu sizes the window from these,
-- and THUMB_SYNC above is several screens of their product -- so change the
-- theme's `columns`/`lines` and change these with it, or the window will be the
-- wrong height for what the theme lays out.
Util.THUMB_COLS = 5
Util.THUMB_ROWS = 3

-- Passed as rofi's -threads for thumbnail grids only, where the icons are.
--
-- A MITIGATION for a rofi bug, not a fix, and it is worth being exact about what
-- is known. rofi's icon fetcher pushes onto the one global GThreadPool that
-- -threads sizes (source/view.c: g_thread_pool_new_full(..., config.threads,
-- FALSE, ...), with 0 resolving to MIN(nproc, 128) -- six on this machine). In
-- source/rofi-icon-fetcher.c, `query_started = TRUE` is set BEFORE
-- g_thread_pool_push and the push error is discarded, and a failed load sets
-- query_done without ever clearing query_started -- so an icon that fails once
-- is blank for the life of that window and nothing ever asks again. That is the
-- black-tile bug, and the retry belongs upstream.
--
-- Measured while it was reproducing, same 50-cover grid opened at row 37: the
-- default six threads gave 6 blank tiles, two gave 10, one gave 11. A clean
-- dose-response DOWNWARD. Upward was never measured under failing conditions --
-- every clean run at 4, 8, 12, 16 and 64 came after the failure burst had
-- already stopped, as did fourteen clean runs of the plain default. So this is
-- an extrapolation of a real trend, and it earns its place only because the pool
-- is non-exclusive: idle threads are reclaimed, so asking for more costs nothing
-- when nothing needs them.
Util.THUMB_THREADS = 16

-- Every rofi argument a thumbnail GRID needs, in one named place rather than
-- inline in the middle of rofi_dmenu's argument builder. Two things that only
-- ever travel together: the row count the window is sized by, and the thread
-- pool the icon fetcher runs on. Rows come from the theme's own column count,
-- capped at its `lines`. Appends in place and returns nothing -- args is the
-- caller's list.
--
-- There used to be a `cols` override that emitted a -theme-str replacing the
-- theme's column count. Its only two callers were the Collections and Podcasts
-- grids, and they were the only grids whose tiles rendered blank; dropping the
-- override was the bisect that fixed them, which left nothing able to reach it.
function Util.grid_args(args, n)
    local rows = math.ceil((tonumber(n) or 0) / Util.THUMB_COLS)
    if rows > Util.THUMB_ROWS then rows = Util.THUMB_ROWS end
    if rows < 1 then rows = 1 end
    args[#args+1] = "-l"; args[#args+1] = tostring(rows)
    args[#args+1] = "-threads"; args[#args+1] = tostring(Util.THUMB_THREADS)
end

-- Refreshes that cached_fetch asked for while the menu they belong to was
-- already drawing from the expired copy. A fetcher cannot be handed to another
-- process, so the NAME of one is: this table is the whole vocabulary of the
-- `revalidate` option, and a second consumer costs a row here rather than a CLI
-- mode of its own. See Util.spawn_revalidate.
--
-- Declared here, not beside those functions: the entries are registered next to
-- the fetchers they name, thousands of lines earlier than the code that reads
-- them, and a later `= {}` would silently wipe every registration.
Util.REVALIDATORS = {}
Util._art_theme_tmpls = {}

-- One definition of "the request worked". Nineteen call sites spelled this
-- inline as `r and r:match("2..")`, two of them inverted, so a nil check was
-- easy to drop. Deliberately keeps the loose "2.." rather than an anchored
-- ^2%d%d$: curl's -w '%{http_code}' always emits three digits (or 000 on a
-- transport failure), so the two agree on every value curl can produce, and
-- loosening nothing means this cannot reject a response the old code accepted.
function Util.is2xx(r)
    return r ~= nil and r:match("2..") ~= nil
end

-- Every authenticated write to the Spotify API (18 call sites).
--   timeout  --max-time, default 5; player endpoints pass 3. Keep the split.
--   body     table is encoded, string sent as-is. Adds Content-Type.
--   len0     bodyless PUT/POST endpoints 411 without it. Ignored if body set.
--   raw      return the response body, not the status (create-playlist).
-- Returns the status string, or the body under raw, or nil. Test with
-- Util.is2xx -- "403" is truthy.
function Util.api_write(verb, url, token, opts)
    opts = opts or {}
    local c = {"curl -s --max-time ", tostring(opts.timeout or 5)}
    if not opts.raw then c[#c+1] = " -o /dev/null -w '%{http_code}'" end
    c[#c+1] = " -X " .. verb .. " " .. shell_quote(url)
    c[#c+1] = " -H " .. shell_quote("Authorization: Bearer " .. token)
    if opts.body ~= nil then
        local b = type(opts.body) == "string" and opts.body or json.encode(opts.body)
        c[#c+1] = " -H 'Content-Type: application/json' -d " .. shell_quote(b)
    elseif opts.len0 then
        c[#c+1] = " -H 'Content-Length: 0'"
    end
    return shell(table.concat(c))
end

-- Fire-and-forget variant: backgrounded by the shell, output discarded, no
-- wait. Used where the UI has already committed to the new state locally and
-- the round trip must not cost a frame (shuffle/repeat toggles).
function Util.api_write_bg(verb, url, token, opts)
    opts = opts or {}
    local c = {"curl -s --max-time ", tostring(opts.timeout or 5)}
    c[#c+1] = " -o /dev/null -w '%{http_code}'"
    c[#c+1] = " -X " .. verb .. " " .. shell_quote(url)
    c[#c+1] = " -H " .. shell_quote("Authorization: Bearer " .. token)
    if opts.len0 then c[#c+1] = " -H 'Content-Length: 0'" end
    os.execute(table.concat(c) .. " > /dev/null 2>&1 &")
end

-- Every background self-spawn (--daemon, --recent-watch, --bsmon, --prefetch-*,
-- --notify, --revalidate, --warm-shelf): 10 hand-built sites. args are
-- quoted individually so a title with a
-- quote cannot break out; the flags gain quotes the shell strips right back off.
-- pidf records the child's pid -- `echo $!` must run in the same shell as the
-- spawn, which is why this builds a command string rather than using os.execute.
function Util.spawn_self(args, log, pidf)
    local c = {"nohup lua ", shell_quote(P.dir .. "/spoot.lua")}
    for _, a in ipairs(args) do c[#c+1] = " " .. shell_quote(a) end
    c[#c+1] = " > " .. shell_quote(log or "/dev/null") .. " 2>&1 &"
    if pidf then c[#c+1] = " echo $! > " .. shell_quote(pidf) end
    os.execute(table.concat(c))
end

function Util.get_own_pid()
    local f = io.open("/proc/self/stat")
    local raw = f and f:read("*a")
    if f then f:close() end
    return raw and tonumber(raw:match("^(%d+)"))
end

-- Pid liveness and argv from /proc, replacing 11 `kill -0`/`cat` shell-outs --
-- 6 of them ran before the first menu could draw, 10.8ms of fork+exec.
-- /proc/<pid>/stat is world-readable where `kill -0` answers EPERM, but every
-- caller checks a helper we spawned and pairs it with a cmdline test, so the
-- answer matches. ^%d+$ guards a garbled pid file. Pid 0 is not special-cased:
-- `kill -0 0` called it alive because 0 means our process GROUP.
local function pid_str(pid)
    if type(pid) == "number" then pid = string.format("%d", pid) end
    if type(pid) ~= "string" or not pid:match("^%d+$") then return nil end
    return pid
end

function Util.proc_alive(pid)
    local p = pid_str(pid)
    if not p then return false end
    local f = io.open("/proc/" .. p .. "/stat", "r")
    if not f then return false end
    f:close()
    return true
end

-- NUL-separated, and returned as-is: every caller only ever :find()s "spoot"
-- or "--daemon" in it, which works unchanged on the raw bytes.
function Util.proc_cmdline(pid)
    local p = pid_str(pid)
    if not p then return "" end
    local f = io.open("/proc/" .. p .. "/cmdline", "r")
    if not f then return "" end
    local raw = f:read("*a")
    f:close()
    return raw or ""
end

-- "Is the process this pid file names still one of OURS?" -- the whole question
-- every pid-file guard here is actually asking. The cmdline test is what makes a
-- recycled pid answer no: without it a stale file whose pid has been reused by
-- some unrelated long-lived process disables the guarded spawn forever, since
-- nothing ever rewrites the file. `kill -0` used to paper over the root-owned
-- case by failing with EPERM; /proc does not, so the test is explicit now.
function Util.pidfile_owner_alive(path, marker)
    local pid = trim(read_file(path) or "")
    if not Util.proc_alive(pid) then return false end
    local cmd = Util.proc_cmdline(pid)
    return cmd:find("spoot", 1, true) ~= nil
        and (not marker or cmd:find(marker, 1, true) ~= nil)
end

function Util.get_clipboard()
    return trim(shell("wl-paste 2>/dev/null") or "")
end

function Util.markup(t)
    return "\1" .. tostring(t) .. "\2"
end

function Util.pango_escape(s)
    if not s then return s end
    s = tostring(s)
    -- Runs once per row on EVERY draw, including each menu_redo redraw, and the
    -- six chained gsubs below are all no-ops for a row with nothing to escape --
    -- which is nearly all of them (measured on a real library: 9 rows of 663).
    -- Skipping them took a 663-row draw from 3.4ms to 0.7ms, and the saving
    -- scales with the list. \1 is in the class so Util.markup blobs, which the
    -- protection pass below still has to unwrap, always take the slow path.
    if not s:find("[&<>\1]") then return s end
    local esc = {["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;"}
    local PROTECT = {}
    s = s:gsub("\1(.-)\2", function(m) PROTECT[#PROTECT + 1] = m; return "\3" .. #PROTECT .. "\4" end)
    s = s:gsub("&(#?%w+);", function(m)
        if m:sub(1, 1) == "#" then
            local n = m:sub(2)
            if n:sub(1, 1):lower() == "x" then
                if n:sub(2):match("^%x+$") then return "\3e" .. m .. "\4" end
            elseif n:match("^%d+$") then return "\3e" .. m .. "\4" end
            return "\3x" .. m .. "\4"
        end
        if m == "amp" or m == "lt" or m == "gt" or m == "quot" or m == "apos" or m == "nbsp" then
            return "\3e" .. m .. "\4"
        end
        return "\3x" .. m .. "\4"
    end)
    s = s:gsub("&", "&amp;")
    s = s:gsub("[<>]", esc)
    s = s:gsub("\3e(%#?%w+)\4", "&%1;")
    s = s:gsub("\3x(%#?%w+)\4", "&amp;%1;")
    s = s:gsub("\3(%d+)\4", function(n) return PROTECT[tonumber(n)] end)
    return s
end

-- Reduces a row to the plain text rofi actually displays, so a row built here
-- and the same row echoed back by rofi compare equal (see row_of).
--
-- The \1..\2 region is UNWRAPPED, not deleted. Deleting worked only when the
-- blob held nothing but a tag; it ate the text of rows wrapping tag AND content
-- ("Shuffle <b>ON</b>", every dimmed action row), which reduced to "" and so
-- matched no saved cursor and no echoed row. Unwrapping exposes the tags for
-- the gsub below, landing tag-only wrappers on the same result as before.
function Util.strip_markup(s)
    if not s then return s end
    s = tostring(s)
    -- Same early-out, and for the same reason, as Util.pango_escape above:
    -- row_of runs this twice per row on every selection, and neither gsub can
    -- match without one of these two bytes -- the first needs \1, the second
    -- needs '<'. Nearly every row has neither.
    if not s:find("[\1<]") then return s end
    s = s:gsub("\1(.-)\2", "%1")
    -- Parenthesised so this returns ONE value. gsub also hands back a match
    -- count, and every call site here happens to discard it -- but the day one
    -- of them is used as a function's last argument, that count silently
    -- becomes an extra argument.
    return (s:gsub("<[^>]+>", ""))
end

local THEME_MENU, THEME_LYR, THEME_MSG, THEME_SUB, THEME_BINDS, THEME_META, THEME_ART = (function()
    -- --listen is the one flag that DOES open rofi, so it resolves themes like
    -- an interactive run. Without this it would draw against the raw style/
    -- paths, whose `@import "ZENON"` is exactly what resolve() below exists to
    -- rewrite -- the window would come up unstyled.
    if arg and arg[1] and arg[1]:match("^%-%-") and arg[1] ~= "--listen" then
        -- Non-interactive modes (--daemon, --prefetch-lyrics) never open rofi.
        -- Skip the shared /tmp theme files so background processes can't wipe
        -- the resolved themes the interactive app is already using.
        Util.THEME_THUMBS = P.dir .. "/style/thumbs.rasi"
        Util.THEME_TRAIL  = P.dir .. "/style/trail.rasi"
        Util.THEME_PODS   = P.dir .. "/style/pods.rasi"
        Util.THEME_MAIN   = P.dir .. "/style/main.rasi"
        Util.THEME_LISTEN = P.dir .. "/style/listen.rasi"
        return P.dir .. "/style/menu.rasi", P.dir .. "/style/lyrics.rasi",
               P.dir .. "/style/message.rasi", P.dir .. "/style/sub.rasi", P.dir .. "/style/binds.rasi",
               P.dir .. "/style/meta.rasi", P.dir .. "/style/art.rasi"
    end
    -- Quoted through shell_quote like everywhere else; the glob stays OUTSIDE
    -- the quotes so the shell still expands it.
    os.execute("rm -f " .. shell_quote(P.tmp) .. "/spoot_theme_*.rasi 2>/dev/null")
    local function resolve(src, name)
        local content = read_file(src)
        if not content then return src end
        local resolved = content:gsub('@import "ZENON"', '@import "' .. P.dir .. '/style/ZENON"')
        if resolved == content then return src end
        local fixed = P.tmp .. "/spoot_theme_" .. name .. ".rasi"
        local f = io.open(fixed, "w")
        if f then f:write(resolved); f:close(); return fixed end
        return src
    end
    local d = P.dir .. "/style"
    P.THEME_SEARCH = resolve(d.."/search.rasi","search")
    -- The search's RESULTS list, as opposed to search.rasi which is its input
    -- box. Its rows are a mix of tracks, albums, artists and playlists, so it
    -- gets a two-column layout of its own rather than the generic menu.
    Util.THEME_RESULTS = resolve(d.."/searchall.rasi","searchall")
    Util.THEME_THUMBS = resolve(d.."/thumbs.rasi","thumbs")
    -- Trail Steps and Trail History share one file. It starts life as a copy of
    -- sub.rasi, so they look exactly as they did; having their own means they can
    -- be styled apart from every other sub-menu without touching those.
    Util.THEME_TRAIL = resolve(d.."/trail.rasi","trail")
    -- Podcast and episode details. Starts life as a copy of meta.rasi at a wider
    -- window, because a show description runs to sentences where an album's
    -- fields are all short values; having its own file means it can be restyled
    -- without touching Album and Track Details.
    Util.THEME_PODS = resolve(d.."/pods.rasi","pods")
    -- The root grid's own theme. A copy of thumbs.rasi, so the five top-level
    -- tiles can be restyled without dragging every other thumbnail grid along.
    Util.THEME_MAIN = resolve(d.."/main.rasi","main")
    -- The Listen window. art.rasi at asset size: art.rasi fills the screen with
    -- a 1000px cover, and style/assets is 300x300, so sharing it would upscale
    -- the icon 3.3x.
    Util.THEME_LISTEN = resolve(d.."/listen.rasi","listen")
    return resolve(d.."/menu.rasi","menu"), resolve(d.."/lyrics.rasi","lyrics"),
           resolve(d.."/message.rasi","message"), resolve(d.."/sub.rasi","sub"), resolve(d.."/binds.rasi","binds"),
           resolve(d.."/meta.rasi","meta"), resolve(d.."/art.rasi","art")
end)()

local _cache_ready = false
local function ensure_cache()
    if _cache_ready then return end
    -- Both mkdirs in ONE shell: os.execute spawns /bin/sh every time (measured at
    -- 1.0ms against 0.44ms for a bare fork), so two calls cost a whole extra
    -- shell for a command that runs in microseconds.
    --
    -- Scratch dir gets its own mkdir inside that shell because -m applies to
    -- every operand and the cache dirs must keep their normal mode. -p also
    -- creates P.tmp itself when $TMPDIR names something that does not exist yet.
    --
    -- The mode is the point. os.tmpname() was backed by mkstemp, which creates
    -- 0600; Util.tmpfile hands back a path that io.open("w") (or a shell >) then
    -- creates 0666 & ~umask -- 0644 here. Rather than pay a chmod fork PER FILE
    -- (two per menu draw) to claw that back, the directory carries the
    -- protection: files inside stay 0644, but 0700 means no other user can
    -- traverse in to reach them. One fork per process instead of per file.
    -- -m sets the mode at creation, so there is no window where it is 0755.
    os.execute("mkdir -p " .. shell_quote(P.cache) .. " " .. shell_quote(P.lyrics)
        .. " " .. shell_quote(P.mass) .. " " .. shell_quote(P.api)
        .. " " .. shell_quote(P.art) .. " " .. shell_quote(P.art .. "/highres") .. Util.art_kind_dirs()
        .. "; mkdir -p -m 700 " .. shell_quote(Util.scratch_dir()))

    -- Curations became Collections, and the art kind was renamed with it rather
    -- than left as a name on disk matching nothing in the code. The six covers
    -- re-download on the next warm; what would otherwise be left behind forever
    -- is a directory and an index no reader can reach.
    --
    -- Unguarded because rm -rf on a path that is not there is already a silent
    -- no-op, and it rides the same shell as the mkdir above -- so the steady
    -- state costs no fork and no stat. Not migrated: renaming the files would
    -- have to rewrite the index to match, for artwork one background fetch
    -- replaces.
    -- Header dumps moved into P.api, and the sweep only looks there now, so
    -- anything the old layout left loose in the cache root as `.api_hdr.<pid>`
    -- would never be collected -- 17 of them on this account at the time of the
    -- move. Shares this shell rather than forking a second one, and the glob
    -- stays OUTSIDE the quotes so the shell still expands it.
    os.execute("{ rm -rf " .. shell_quote(P.art .. "/curations") .. " "
        .. shell_quote(P.cache .. "/curation_art.json") .. ";"
        .. " rm -f " .. shell_quote(P.cache) .. "/.api_hdr.*; } 2>/dev/null")

    -- The housekeeping sweeps below are throttled to once an hour by the mtime of
    -- a stamp file. They used to run in EVERY process -- including the --notify
    -- helper the daemon spawns on every track change, which was paying three
    -- forks and a walk of the whole art tree (4,912 files) to tidy up files it
    -- never created. Nothing here is urgent: everything they remove is already
    -- age- or liveness-gated, so an hour late is indistinguishable from on time.
    local stamp = P.cache .. "/.sweep"
    local sf = io.open(stamp, "r")
    local last = 0
    if sf then
        last = tonumber(sf:read("*a")) or 0
        sf:close()
    end
    if os.time() - last >= 3600 then
        sf = io.open(stamp, "w")
        if sf then sf:write(tostring(os.time())); sf:close() end
        -- A fetch interrupted mid-flight (Escape out of a grid, or a kill) leaves
        -- its .tmp behind and nothing else ever removed them -- they had piled up
        -- into thousands. -mmin +10 so a prefetch still running from an earlier
        -- launch keeps the files it is actively writing.
        --
        -- Same treatment for the per-process api_get header files: the
        -- interactive process removes its own in clean_exit, but a detached
        -- helper os.exits without unwinding. -maxdepth 1 so this does not walk
        -- lyrics/ and mass/, which hold thousands of files.
        --
        -- And scratch dirs orphaned by a helper killed before clean_exit, keyed
        -- on pid LIVENESS rather than age: a long-lived process that happens not
        -- to have written a scratch file recently still owns its directory, and
        -- an -mmin sweep would delete it out from under a daemon that later calls
        -- tmpfile.
        --
        -- One backgrounded shell for all three, rather than three.
        os.execute("{ find " .. shell_quote(P.art) .. " -name '*.tmp*' -mmin +10 -delete;"
            .. " find " .. shell_quote(P.api) .. " -maxdepth 1 -name 'hdr.*' -mmin +10 -delete;"
            .. " for d in " .. shell_quote(P.tmp) .. "/spoot.[0-9]*; do"
            .. " p=${d##*/spoot.};"
            .. " [ -d \"$d\" ] && [ ! -e \"/proc/$p\" ] && rm -rf \"$d\";"
            .. " done; } >/dev/null 2>&1 &")
    end
    _cache_ready = true
end

-- This process's private scratch directory. Named by pid so two spoot processes
-- (interactive + --daemon, or a burst of --notify helpers) never share one, and
-- so the orphan sweep in ensure_cache can ask /proc whether the owner is still
-- alive. Created 0700 there; see the note on that mkdir for why the directory
-- rather than the files carries the protection.
function Util.scratch_dir()
    if not Util._scratch then
        Util._scratch = P.tmp .. "/spoot." .. tostring(Util.get_own_pid() or "x")
    end
    return Util._scratch
end

-- Scratch path, replacing os.tmpname(). os.tmpname is itself a hardcoded /tmp:
-- it ignores $TMPDIR entirely (verified -- it returns /tmp/lua_XXXXXX
-- regardless), so it was the one set of paths the move to P.tmp could not reach.
--
-- It has to keep the three properties mkstemp gave us, or this trades a
-- hardcoded path for a worse bug:
--   * cannot collide -- the dir is per-pid, and tag + counter separate the temps
--     a single process holds open at once (rofi_dmenu keeps two).
--   * cannot be READ by others -- mkstemp creates 0600. io.open("w") creates
--     0644, so the 0700 scratch directory provides this instead.
--   * cannot be GUESSED -- otherwise a predictable name can be pre-created as a
--     symlink and made to clobber whatever it points at, since io.open("w") has
--     no O_EXCL. Util._rand_suffix supplies 4 bytes of /dev/urandom, already
--     used for the same purpose on the art fetch path. Kept even though the
--     0700 dir already blocks other users: it costs nothing and it is the only
--     thing standing between us and a symlink if that dir is ever loosened.
--
-- Returns a path and does NOT create the file -- every caller either opens it
-- "w" straight away or has the shell create it with > / >>, and the io.open
-- failure paths were already handled.
Util._tmp_seq = 0
function Util.tmpfile(tag)
    ensure_cache()
    Util._tmp_seq = Util._tmp_seq + 1
    return Util.scratch_dir() .. "/" .. tag .. "." .. Util._tmp_seq .. "." .. Util._rand_suffix()
end

-- Resolved once per process; see the note at its use in api_get.
function Util.api_hdr_path()
    if not Util._api_hdr then
        ensure_cache()
        Util._api_hdr = P.api .. "/hdr." .. tostring(Util.get_own_pid() or "x")
    end
    return Util._api_hdr
end

local function write_file(p, d)
    ensure_cache()
    local t = p .. ".tmp"
    local f = io.open(t, "w")
    if not f then return false end
    if not f:write(d) then f:close(); os.remove(t); return false end
    if not f:close() then os.remove(t); return false end
    local ok = os.rename(t, p)
    if not ok then os.remove(t) end
    return ok
end

Util.secure_write = function(p, d)
    write_file(p, d)
    os.execute("chmod 600 " .. shell_quote(p) .. " 2>/dev/null")
end

-- The two halves of one conversion: an id out of any Spotify reference, and a
-- URI back out of any object. Both are KIND-AGNOSTIC on purpose -- an episode
-- arrives as spotify:episode:<id>, and the track-only patterns these used to
-- carry fell through to the passthrough below, so `now.json`'s id never matched
-- `now_track.json`'s and Util.fast_now_track answered false on every call,
-- costing every menu a me/player round trip it did not need.
-- Returns the id AND, as a second value, the kind it was carrying (nil for a
-- bare id). The daemon is the reason: MPRIS is the only place the kind survives
-- at all, so re-deriving it there would mean a second copy of these two
-- patterns. Every call site assigns or compares, never concatenates -- keep it
-- that way, for the reason spelled out above Util.strip_markup.
function Util.extract_track_id(raw)
    if not raw then return "" end
    local cleaned = trim(raw):gsub("^'", ""):gsub("'$", "")
    local kind, id = cleaned:match("^/spotify/([^/]+)/(.+)")
    if not id then kind, id = cleaned:match("^spotify:([^:]+):(.+)") end
    if id then return id, kind end
    return cleaned, nil
end

-- Defaults to "track" rather than reading item.uri, which is never there to
-- read: Util.mark_availability prunes `uri` as a DEAD_FIELD on the way in. The
-- default is load-bearing too -- api_get_playlist_tracks' field mask and the
-- daemon's now-playing write both used to omit `type` entirely.
function Util.item_uri(item)
    if not (item and item.id) then return nil end
    return "spotify:" .. (item.type or "track") .. ":" .. item.id
end

local function strip_nulls(t)
    if type(t) ~= "table" then return t end
    local rm = {}
    for k, v in pairs(t) do
        if v == json.null then rm[#rm+1] = k
        elseif type(v) == "table" then t[k] = strip_nulls(v) end
    end
    if #rm > 0 then
        for _, k in ipairs(rm) do t[k] = nil end
        local nums = {}
        for k in pairs(t) do if type(k) == "number" then nums[#nums+1] = k end end
        if #nums > 0 then
            table.sort(nums)
            for i, k in ipairs(nums) do
                if i ~= k then t[i] = t[k]; t[k] = nil end
            end
        end
    end
    return t
end

-- The trim() this used to open with cost 25ms on liked_tracks.json (1.4MB) --
-- nearly 3x the 9ms decode it was preparing for -- because `^%s*(.-)%s*$` walks
-- and then COPIES the whole blob. It was only ever an emptiness test: cjson
-- already skips leading and trailing whitespace itself. Scanning for the first
-- non-space instead is O(1) in practice and copies nothing.
local function safe_decode(s)
    if not s or not s:find("%S") then return nil end
    local ok, data = pcall(json.decode, s)
    if not ok or type(data) ~= "table" then return nil end
    -- strip_nulls walks the whole structure just to turn json.null into nil:
    -- 5.7ms on the 1.4MB liked cache, atop a 10ms decode. No `null` token means
    -- no null value, and our cache files never have one. The plain scan costs
    -- 0.3ms, so the common case skips the walk for free. "null" inside a string
    -- is a harmless false positive -- it just takes the walk it would have
    -- taken anyway. Same early-out idiom as pango_escape and strip_markup.
    if not s:find("null", 1, true) then return data end
    return strip_nulls(data)
end

local function get_saved_volume()
    local raw = read_file(P.volume)
    if not raw then return 100 end
    local d = safe_decode(raw)
    if d and d.volume and tonumber(d.volume) then
        return math.max(0, math.min(100, tonumber(d.volume)))
    end
    return 100
end

local function save_volume(pct)
    write_file(P.volume, json.encode({volume=pct}))
end

local function get_saved_bitrate()
    local raw = read_file(P.bitrate)
    local n = raw and tonumber(trim(raw))
    if n and (n == 96 or n == 160 or n == 320) then return n end
    return 160
end
local function save_bitrate(n)
    write_file(P.bitrate, tostring(n))
end

local _mem = {}
local function mem_get(key)
    local e = _mem[key]
    if e and (not e.expire or os.time() < e.expire) then return e.value end
    _mem[key] = nil
end
local function mem_set(key, value, ttl)
    _mem[key] = {value = value, expire = ttl and (os.time() + ttl)}
end
-- A key ending in ":" busts that whole FAMILY of memos rather than one entry --
-- every search run this process, say, whose keys carry a variable tail.
local function mem_bust(key)
    if key:sub(-1) ~= ":" then _mem[key] = nil; return end
    for k in pairs(_mem) do
        if k:sub(1, #key) == key then _mem[k] = nil end
    end
end
-- `tag` is a validity TOKEN, and it outranks the TTL: when the caller knows
-- something that changes exactly when the data does -- a playlist's snapshot_id
-- -- age stops being evidence of anything. A matching tag serves the file however
-- old it is, and a differing one refetches however fresh. The TTL stays as the
-- fallback for callers that have no such token.
local function disk_get(path, ttl, tag)
    local raw = read_file(path)
    if not raw then return nil end
    local d = safe_decode(raw)
    if not d or type(d) ~= "table" or type(d.fetched_at) ~= "number" then return nil end
    -- `items`/`tracks` are the envelope the three library loaders wrote before
    -- they moved onto this function. Same timestamp field, different payload key,
    -- so reading both means the switch costs no refetch of a 663-track cache.
    local payload = d.data
    if payload == nil then payload = d.items end
    if payload == nil then payload = d.tracks end
    if payload == nil then return nil end
    if tag ~= nil then
        if d.tag == tag then return payload end
        -- A tag was offered and the file carries a different one (or none, having
        -- been written before tags existed): it cannot be trusted past its TTL.
        if d.tag ~= nil then return nil end
    end
    if ttl and os.time() - d.fetched_at >= ttl then return nil end
    return payload
end
local function disk_set(path, data, tag)
    write_file(path, json.encode({data=data, fetched_at=os.time(), tag=tag}))
end
local function disk_bust(path) os.remove(path) end

-- EPISODE RESUME -- see P.eresume.

-- Returns the stored position (nil when there is none) AND whether the episode
-- was finished here. Two values because "no position" is true of both a
-- never-played episode and one played to the end, and only the second should be
-- dimmed as played.
--
-- Every caller assigns or compares -- never concatenates -- for the reason
-- spelled out above Util.strip_markup.
function Util.eresume_get(id)
    if not id then return nil, false end
    local m = disk_get(P.eresume)
    local e = type(m) == "table" and m[id]
    if type(e) ~= "table" then return nil, false end
    local ms = tonumber(e.ms)
    return (ms and ms > 0) and ms or nil, e.done == true
end

-- Records a position, or FORGETS one. `dur` is the episode length when known:
-- inside P.eresume_end_ms of it the episode is finished, and the entry is
-- dropped so the next play starts from zero rather than the credits.
--
-- Returns whether anything was written, which is what the tests assert on.
function Util.eresume_put(id, ms, dur)
    if not id then return false end
    ms = tonumber(ms) or 0
    local m = disk_get(P.eresume)
    if type(m) ~= "table" then m = {} end
    local prev = type(m[id]) == "table" and tonumber(m[id].ms) or nil
    local finished = dur and dur > 0 and ms >= dur - P.eresume_end_ms
    if ms <= 0 then
        -- Position zero says nothing -- it is where an unplayed episode sits.
        if m[id] == nil then return false end
        m[id] = nil
    elseif finished then
        -- Kept, not deleted: the next play must start from the top, which a nil
        -- ms already achieves, but the LIST still wants to show it as played.
        if type(m[id]) == "table" and m[id].done then return false end
        m[id] = {ms = 0, done = true, at = os.time()}
    else
        -- A paused episode reports an unchanged position on every tick; only a
        -- real move earns a write.
        if prev and math.abs(ms - prev) < P.eresume_min_ms then return false end
        m[id] = {ms = ms, at = os.time()}
        -- Bounded like the recently-played list. Oldest `at` goes first.
        local n = 0
        for _ in pairs(m) do n = n + 1 end
        while n > P.eresume_max do
            local oldest, oldest_at = nil, nil
            for k, v in pairs(m) do
                local at = type(v) == "table" and tonumber(v.at) or 0
                if not oldest_at or at < oldest_at then oldest, oldest_at = k, at end
            end
            if not oldest then break end
            m[oldest] = nil
            n = n - 1
        end
    end
    disk_set(P.eresume, m)
    return true
end

-- "This copy is still current" without rewriting the copy. Used by the library
-- revalidator, which asks Spotify whether anything changed for about a kilobyte
-- and, when the answer is no, has to make a several-megabyte cache read as fresh
-- again -- decoding and re-encoding it to move one integer would cost more than
-- the request that established it did not need moving.
--
-- The literal `"fetched_at":<digits>` occurs exactly once in an envelope: JSON
-- escaping means a track or playlist NAMED that appears as \"fetched_at\":, so
-- the pattern cannot match inside the payload. Anything other than exactly one
-- hit is treated as a failure rather than guessed at, and the caller falls back
-- to a real refresh.
function Util.cache_touch(path)
    local raw = read_file(path)
    if not raw then return false end
    local out, n = raw:gsub('"fetched_at":%s*%d+', '"fetched_at":' .. os.time(), 1)
    if n ~= 1 then return false end
    -- write_file answers os.rename's nil-on-failure, not false, so this is a
    -- truthiness test rather than a comparison.
    return not not write_file(path, out)
end

-- view_pos (cursor memory) is read on essentially every menu draw and rewritten
-- on every selection -- 11KB / 261 keys, decoded and re-encoded each time. One
-- in-process copy with write-through makes a draw cost no JSON work at all.
-- Nothing else writes this file while we run, so a single copy is safe.
P.pos_max = 800
function Util.pos_all()
    if not Util._pos then Util._pos = disk_get(P.view_pos) or {} end
    return Util._pos
end
function Util.pos_get(key)
    if not key then return nil end
    return Util.pos_all()[key]
end
function Util.pos_put(key, val)
    if not key then return end
    local t = Util.pos_all()
    if t[key] == val then return end
    t[key] = val
    -- The file grew one key per menu ever visited and was never pruned. Cursor
    -- positions are disposable (a dropped one just starts the menu at the top),
    -- so trimming arbitrarily above a generous cap is fine.
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n > P.pos_max then
        for k in pairs(t) do
            if k ~= key then t[k] = nil; n = n - 1 end
            if n <= P.pos_max then break end
        end
    end
    disk_set(P.view_pos, t)
end

-- Restores the cursor from a STABLE row key, not the visible label. Rows that
-- encode live state rewrite themselves on use ("Repeat OFF" -> "Repeat
-- CONTEXT", "Like" -> "Unlike"), and a stored label then matched nothing,
-- dropping the cursor to the top. `keys` names each row independently.
--
-- By name, not index: view_playback's Play/Pause row only exists while
-- something plays, so an index would slip one row whenever that changed.
function Util.pos_row(pos_key, keys)
    local saved = Util.pos_get(pos_key)
    if type(saved) ~= "string" then return 0 end
    for i, k in ipairs(keys) do if k == saved then return i - 1 end end
    return 0
end

-- SEARCH HISTORY
--
-- Past queries under P.hist_key, most recent first. Same
-- in-process-copy-plus-write-through shape as Util.pos_* above, and for the same
-- reason: it is read on every draw of the search box and rewritten on every
-- accepted query, and the file is small enough that a full re-encode per write
-- is free. Still keyed rather than a bare list because the file already held a
-- table of lists, and Util.hist_migrate has to be able to read the old keys.
P.hist_max = 50
P.hist_key = "search"
-- The keys the split search wrote, newest-intent first.
P.hist_legacy = {"search:all", "search:track", "search:album", "search:artist",
                 "search:playlist"}
function Util.hist_all()
    if not Util._hist then Util._hist = disk_get(P.search_hist) or {} end
    return Util._hist
end

function Util.hist_get(key)
    local l = Util.hist_all()[key]
    return type(l) == "table" and l or {}
end

-- Most-recent-first with de-duplication, so re-running an old query promotes it
-- rather than growing a second copy.
function Util.hist_add(key, q)
    if not key or type(q) ~= "string" then return end
    q = trim(q)
    if q == "" then return end
    local all = Util.hist_all()
    local l = type(all[key]) == "table" and all[key] or {}
    for i = #l, 1, -1 do if l[i] == q then table.remove(l, i) end end
    table.insert(l, 1, q)
    while #l > P.hist_max do table.remove(l) end
    all[key] = l
    disk_set(P.search_hist, all)
end

function Util.hist_remove(key, q)
    if not key or type(q) ~= "string" then return false end
    local all = Util.hist_all()
    local l = type(all[key]) == "table" and all[key] or nil
    if not l then return false end
    local hit = false
    for i = #l, 1, -1 do if l[i] == q then table.remove(l, i); hit = true end end
    if not hit then return false end
    -- Drop the key entirely once empty, so the file does not accumulate a
    -- growing set of categories mapping to nothing.
    if #l == 0 then all[key] = nil end
    disk_set(P.search_hist, all)
    return true
end

-- Folds the five per-category lists the split search left behind into the one
-- list there is now. Round-robin -- head of each in turn -- because the entries
-- carry no timestamps: taking one from each list keeps the most recent query of
-- every old category near the top, where concatenating would have buried four
-- categories under whichever list happened to be longest.
--
-- Self-erasing: it deletes the legacy keys as it consumes them, so every call
-- after the first is five table lookups that find nothing.
function Util.hist_migrate()
    local all = Util.hist_all()
    local lists, most = {}, 0
    for _, k in ipairs(P.hist_legacy) do
        local l = all[k]
        if type(l) == "table" and #l > 0 then
            lists[#lists+1] = l
            if #l > most then most = #l end
        end
        all[k] = nil
    end
    if most == 0 then return end
    local merged = type(all[P.hist_key]) == "table" and all[P.hist_key] or {}
    local seen = {}
    for _, q in ipairs(merged) do seen[q] = true end
    for i = 1, most do
        for _, l in ipairs(lists) do
            local q = l[i]
            if q and not seen[q] then seen[q] = true; merged[#merged+1] = q end
        end
    end
    while #merged > P.hist_max do table.remove(merged) end
    all[P.hist_key] = merged
    disk_set(P.search_hist, all)
end

local function bust_my_playlists()
    mem_bust("my_playlists")
    os.remove(P.cache .. "/my_playlists.json")
end
local function cache_exists(path)
    local f = io.open(path)
    if f then f:close(); return true end
    return false
end
-- disk_set writes fetched_at last, so it lands in the final few bytes. Reading
-- the whole file just to reach it costs ~7ms on liked_tracks.json (2.3MB) and
-- this runs for three caches on every startup; a tail read is ~500x cheaper.
-- Falls back to the full scan if the tail doesn't contain it, so a change in
-- key order can never turn a fresh cache into a permanently stale one.
local function cache_stale(path)
    local ts
    local f = io.open(path, "rb")
    if f then
        local size = f:seek("end")
        f:seek("set", math.max(0, size - 256))
        local tail = f:read("*a")
        f:close()
        ts = tail and tonumber(tail:match('"fetched_at"%s*:%s*(%d+)'))
    end
    if not ts then
        local raw = read_file(path)
        ts = raw and tonumber(raw:match('"fetched_at"%s*:%s*(%d+)'))
    end
    return not ts or os.time() - ts >= P.ttl
end
-- Our Spotify market, memoised. Resolved from the profile, which is itself
-- disk-cached for an hour, so the whole process pays at most one request for it.
-- The re-entrancy flag is kept because api_get_me goes through cached_fetch:
-- should anything on that path ever consult the market again, this bounds it.
Util._market_resolving = false
function Util.market()
    if Util._market ~= nil then return Util._market or nil end
    if Util._market_resolving then return nil end
    Util._market_resolving = true
    local me = Util.api_get_me and Util.api_get_me() or nil
    Util._market_resolving = false
    -- A failed profile fetch is transient, so it must NOT be memoised: the check
    -- above short-circuits on any non-nil value, so caching `false` here left the
    -- process marketless for the rest of its life. Harmless once, but
    -- --recent-watch runs for days, and one unlucky lookup at startup would cost
    -- it every availability flag it ever wrote. api_get_me is disk-cached for an
    -- hour, so retrying is nearly free.
    if not me then return nil end
    Util._market = me.country or false
    return Util._market or nil
end

-- Appends the market for endpoints returning track or album objects. Sending it
-- is what makes Spotify answer the availability question at all, and what stops
-- it padding every response with ~185 country codes. Returns `params` untouched
-- when the market is unknown (offline, no profile): the response then has no
-- is_playable, so nothing dims -- silence rather than a guess.
function Util.with_market(params)
    local m = Util.market()
    if not m then return params end
    return (params and (params .. "&") or "") .. "market=" .. m
end

-- available_markets is NOT an availability signal: of the 142 tracks it once
-- flagged in a 663-track library, 137 played fine -- 96.5% false positives,
-- greying out a fifth of Liked Tracks. Spotify only answers when the request
-- carries a market, and answers with is_playable. The array is dropped on sight.
-- Clearing `unavail` on a positive lets a re-fetch heal a stale flag.
--
-- Called from ONE place: api_get, before returning the body. Six hand-written
-- sites used to do it, missing every direct api_get caller (search,
-- recommendations, pasted URLs). save_library_cache's two remain -- that data
-- comes from raw curl.
-- Fields Spotify sends on every object that spoot never reads -- verified by
-- grep to have ZERO uses anywhere in this file. They are bulky (three of the
-- four are long URLs), so dropping them here shrinks liked_tracks.json by 34%
-- (1326 -> 881 KB) and takes its decode from 11.0ms to 8.4ms; saved_albums.json
-- loses 45%. Every write gets cheaper too -- do_like rewrites the whole liked
-- cache.
--
-- Only these four. A wider list (popularity, external_urls, external_ids,
-- disc_number, track_number, label, genres, album_type, release_date) measured
-- far better -- 63% smaller, 2.5x faster -- and is WRONG: Util.view_album_details
-- and Util.view_track_details read exactly those off api_get responses, so it
-- would empty both of those views.
local DEAD_FIELDS = {preview_url = true, href = true, uri = true, is_local = true}

function Util.mark_availability(o)
    local function walk(t)
        if type(t) ~= "table" then return end
        t.available_markets = nil
        if t.is_playable == false then t.unavail = true
        elseif t.is_playable == true then t.unavail = nil end
        t.is_playable = nil
        -- Episodes hosted outside Spotify's CDN are `is_playable = true` and
        -- still cannot be streamed: librespot answers "Unable to load audio
        -- item" and the play request 2xxs, so without this do_play reports
        -- success for something that will never make a sound. Collapsed here,
        -- with the region check, because this is the one place availability is
        -- decided -- the comment above says so, and a second site would be the
        -- hand-written kind this function replaced.
        if t.is_externally_hosted == true then t.unavail = true end
        t.is_externally_hosted = nil
        -- Riding the walk this function already performs, so the pruning costs
        -- no extra traversal.
        for k in pairs(DEAD_FIELDS) do t[k] = nil end
        for _, v in pairs(t) do
            if type(v) == "table" then walk(v) end
        end
    end
    walk(o)
    return o
end

-- `opts` (all optional):
--   tag         validity token, see disk_get -- a match serves the file at any age
--   stale_ok    a failed fetch answers with the EXPIRED disk copy rather than nil
--   revalidate  name of a Util.REVALIDATORS entry: an expired copy is served
--               IMMEDIATELY and refreshed in a detached process, so the menu
--               never waits on the network to draw
-- All three live here rather than at any one call site because every list in the
-- file already comes through this function, so each applies everywhere at once.
local function cached_fetch(key, disk_path, ttl, fetch_fn, opts)
    opts = opts or {}
    -- Util.revalidating is the detached refresh itself, and the exact mirror of
    -- Util.cache_only below: it must ignore every cache and go to the network,
    -- since re-reading the copy it was spawned to replace would make it a no-op.
    if Util.revalidating then
        local fresh = fetch_fn()
        -- Empty is written here for the same reason it is below: failure already
        -- signals itself as nil, so {} is a successful empty result and dropping
        -- it leaves the previous non-empty file in place forever. This path is
        -- the one that matters most for it -- saved_shows, saved_episodes,
        -- my_playlists and liked_tracks all revalidate, so a shelf emptied on
        -- ANOTHER device only ever arrives through here. Changes made inside
        -- spoot bust the file outright (Util.lib_write) and never reach this.
        if fresh ~= nil then
            mem_set(key, fresh, ttl)
            if disk_path then disk_set(disk_path, fresh, opts.tag) end
        end
        return fresh
    end
    local v = mem_get(key)
    if v ~= nil then return v end
    if disk_path then
        v = disk_get(disk_path, ttl, opts.tag)
        if v ~= nil then mem_set(key, v, ttl); return v end
        -- Expired, but present. Waiting ~450ms for a list that has barely changed
        -- is the whole complaint this answers: hand back what we have and let a
        -- detached process fetch the truth for the NEXT open. Anything changed
        -- inside spoot busts this cache outright and never reaches here, so the
        -- staleness window only covers edits made on another device.
        if opts.revalidate then
            v = disk_get(disk_path)
            if v ~= nil then
                mem_set(key, v, ttl)
                Util.spawn_revalidate(opts.revalidate, opts.revalidate_arg)
                return v
            end
        end
    end
    -- Util.cache_only asks for whatever is already cached and nothing more: the
    -- caller is decorating a menu, not opening one, and must not pay for a fetch.
    if not Util.cache_only then
        v = fetch_fn()
        -- An empty result used to be thrown away here, on the theory that it
        -- probably meant a failed request. It does not: FAILURE ALREADY SIGNALS
        -- ITSELF AS NIL. Util.paged_fetch returns nil the moment a request fails
        -- and {} only on a successful empty page, and every library loader
        -- propagates that. Discarding {} meant the previous non-empty file
        -- survived forever, so unfollowing every podcast left the Podcasts tile
        -- wearing a cover for a shelf that no longer had anything on it -- and
        -- made "this list is genuinely empty" impossible to know, which is what
        -- Util.shelf_head needs to dim a row.
        --
        -- Loaders that must not report {} already convert it to nil themselves,
        -- inside their own fetch_fn: api_get_top_tracks and Util.api_get_top_artists
        -- use nil to fall through medium_term -> long_term -> short_term. They
        -- never hand {} to this function, so nothing here changes for them.
        if v ~= nil then
            mem_set(key, v, ttl)
            if disk_path then disk_set(disk_path, v, opts.tag) end
        end
    end
    -- Nothing came back. A list the user is looking at is better served by what we
    -- knew an hour ago than by "no results", so re-read the file with no TTL. Also
    -- taken under cache_only, where there was no fetch to fail: stale is all there
    -- is, and it beats nothing for free.
    if v == nil and (opts.stale_ok or Util.cache_only) and disk_path then
        v = disk_get(disk_path)
        if v ~= nil then mem_set(key, v, ttl) end
    end
    return v
end

-- populate liked IDs for display helpers (lightweight, from cache)
local function populate_liked_ids()
    liked = {}
    local ids = safe_decode(read_file(P.liked_ids))
    if ids and type(ids) == "table" and #ids > 0 then
        for _, id in ipairs(ids) do liked[id] = true end
        return
    end
    local tracks = disk_get(P.liked)
    if type(tracks) == "table" then
        for _, t in ipairs(tracks) do
            if t.id then liked[t.id] = true end
        end
    end
end

-- SESSION STACK

-- THE view registry: one entry per view that can appear on the session stack,
-- holding its breadcrumb label and the function that opens it. Declared here
-- (empty) because Util.scope and the breadcrumb code below need to see it;
-- populated in one block next to replay_session, once every view function
-- exists. Both the live path and a warm-start replay go through `open`, which
-- is what keeps a restored menu identical to a freshly opened one.
local VIEWS = {}

local _session_stack = nil

function Util.trail_load()
    Util.trail_history = {}
    local d = safe_decode(read_file(P.trails))
    if d and type(d.trails) == "table" then
        for _, t in ipairs(d.trails) do
            if #Util.trail_history < 2 then
                if type(t) == "table" and type(t.stack) == "table" then
                    Util.trail_history[#Util.trail_history + 1] = t
                elseif type(t) == "string" then
                    Util.trail_history[#Util.trail_history + 1] = {label=t, stack={}}
                end
            end
        end
    end
end

function Util.trail_save()
    write_file(P.trails, json.encode({trails=Util.trail_history}))
end
Util.trail_history = Util.trail_history or {}

-- ── Closed-menu history ───────────────────────────────────────────────
-- The trail says where you still are; this says where you have BEEN and left.
-- Util.scope pops a menu on the way out and nothing used to remember it, so
-- getting back to something you closed meant walking the path again by hand.
--
-- Same in-process-copy-plus-write-through shape as Util.pos_* and Util.hist_*
-- above, and for the same reason: read on every trail draw, rewritten whenever a
-- menu closes, and small enough that a full re-encode per write is free.
--
-- Only the STACK is stored, never a rendered label -- exactly the rule the
-- breadcrumb follows, so a later change to how a step is named reaches old
-- entries too instead of leaving them frozen in an old style.
P.menu_hist_max = 100

function Util.menu_hist_all()
    if not Util._mhist then Util._mhist = disk_get(P.menu_hist) or {} end
    return Util._mhist
end

-- Removes one remembered menu. By IDENTITY, not by index: Util.menu_hist_rows
-- hides every entry still reachable from the live stack or a stored trail, so
-- its row numbers and this list's indexes are different things. It hands back
-- the entries alongside the rows precisely so a caller can pass one here.
function Util.menu_hist_remove(entry)
    if type(entry) ~= "table" then return false end
    local all = Util.menu_hist_all()
    for i = #all, 1, -1 do
        if all[i] == entry then
            table.remove(all, i)
            Util.menu_hist_save()
            return true
        end
    end
    return false
end

function Util.menu_hist_save()
    disk_set(P.menu_hist, Util.menu_hist_all())
end

-- True when `a` names the same path as `b`, or a shorter one leading to it. The
-- comparison is on view identity plus the ids that distinguish two menus of the
-- same kind, not on the whole entry: a stack entry also carries display names
-- that can change (a renamed playlist) without it being a different menu.
function Util.stack_prefix(a, b)
    if not (a and b) or #a > #b then return false end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if type(x) ~= "table" or type(y) ~= "table" then return false end
        if x.view ~= y.view then return false end
        for _, k in ipairs({"track_id", "album_id", "artist_id", "playlist_id",
                            "category_id", "query", "category", "genre"}) do
            if x[k] ~= y[k] then return false end
        end
    end
    return true
end

-- Records a menu that just closed. Called from Util.scope's normal unwind only.
--
-- Two things are deliberately NOT recorded:
--   * a track's action menu, which is a detail of the list underneath it and
--     would otherwise crowd out real destinations;
--   * a path that is a prefix of the entry we just wrote. Backing out of
--     Artist > Albums > Album > Track unwinds four scopes; without this the
--     history would hold four rows all describing the one excursion, when what
--     you left was the deepest of them.
function Util.menu_hist_add(path)
    if not path or #path == 0 then return end
    local leaf = path[#path]
    if type(leaf) ~= "table" or not leaf.view then return end
    if leaf.view == "action" then return end
    local all = Util.menu_hist_all()
    if all[1] and Util.stack_prefix(path, all[1].stack) then return end
    -- Somewhere we already know: move it up rather than keeping two rows for it.
    for i = #all, 1, -1 do
        local e = all[i]
        if type(e) == "table" and type(e.stack) == "table"
           and #e.stack == #path and Util.stack_prefix(path, e.stack) then
            table.remove(all, i)
        end
    end
    table.insert(all, 1, {stack = path, ts = os.time()})
    while #all > P.menu_hist_max do table.remove(all) end
    Util.menu_hist_save()
end

local function session_load()
    local d = safe_decode(read_file(P.session))
    if d and type(d.stack) == "table" then
        _session_stack = d.stack
    else
        _session_stack = {}
    end
    -- Installing a stack counts as a replacement (see Util.session_set).
    Util.session_gen = (Util.session_gen or 0) + 1
end

local function session_save()
    if not _session_stack then return end
    if #_session_stack == 0 then os.remove(P.session)
    else write_file(P.session, json.encode({stack=_session_stack})) end
end

local function session_peek()
    if not _session_stack or #_session_stack == 0 then return nil end
    return _session_stack[#_session_stack]
end

local function session_push(data)
    if not _session_stack then _session_stack = {} end
    _session_stack[#_session_stack+1] = data
    session_save()
end

local function session_pop()
    if not _session_stack or #_session_stack == 0 then return end
    table.remove(_session_stack)
    session_save()
end

-- Wholesale stack REPLACEMENT (warm start, trail jump, "go to main", …) as
-- opposed to an ordinary push/pop. Bumping a generation counter lets an
-- in-flight Util.scope tell "my menu closed normally" apart from "the stack
-- I belonged to was swapped out from under me", so it never truncates a
-- freshly-installed stack. Every assignment to _session_stack goes through
-- here; assigning it directly will silently reintroduce that class of bug.
Util.session_gen = 0
function Util.session_set(stack)
    _session_stack = stack or {}
    Util.session_gen = Util.session_gen + 1
    session_save()
end

-- THE session invariant: a menu owns exactly one stack entry, pushed on entry
-- and removed on exit, however it exits -- return, break, error, or a nested
-- view that leaked. The body is a closure, so no exit path can forget to pop,
-- making stack/trail sync structural rather than a convention.
--
-- NEW VIEWS MUST USE THIS, not a manual session_push/session_pop pair.
-- Captures a traceback AT THE FAULT SITE, for the crash handler at the bottom of
-- the file. pcall unwinds the stack before it returns, so a debug.traceback taken
-- where the error is finally caught describes the rethrow chain rather than the
-- line that actually broke -- and Util.scope rethrows, several levels deep, on
-- every nested view. Used as an xpcall message handler so it runs before the
-- unwind.
--
-- Idempotent on purpose: nested scopes each rethrow the same error through their
-- own xpcall, and without this test every level would staple another traceback
-- onto it. First (innermost, most useful) one wins.
function Util.traceback(e)
    e = tostring(e)
    if e:find("\nstack traceback:", 1, true) then return e end
    return debug.traceback(e, 2)
end

function Util.scope(entry, body)
    -- A view with no VIEWS entry can be pushed but never restored, so a warm
    -- start would silently drop it and land the user somewhere else. Loud on
    -- stderr (visible in the daemon log / terminal) rather than fatal: a missing
    -- registration is a bug in new code, not a reason to kill a running session.
    if type(entry) == "table" and entry.view and not VIEWS[entry.view] then
        io.stderr:write("spoot: view '" .. tostring(entry.view)
            .. "' is not in VIEWS -- it cannot be restored on a warm start\n")
    end
    -- session_push is what lazily creates the stack, so reading its length first
    -- has to tolerate it not existing yet. Nothing reaches a scoped view before
    -- session_load today; this keeps that from being load-bearing.
    local depth = _session_stack and #_session_stack or 0
    local gen   = Util.session_gen
    session_push(entry)
    -- xpcall, not pcall: the handler runs BEFORE the stack unwinds, which is the
    -- only moment a useful traceback can be taken (see Util.traceback). The
    -- rethrow below then carries it up to the crash handler at the bottom.
    local ok, a, b = xpcall(body, Util.traceback)
    if Util.session_gen == gen then
        -- This menu closed normally, so it is a place you have been and left:
        -- record the path to it before the stack forgets. Inside the generation
        -- test on purpose -- a trail jump or a warm start REPLACES the stack, and
        -- nothing was closed in that case. Copied, because what stays behind must
        -- not alias entries the live stack goes on mutating.
        if ok then
            local path = {}
            for i = 1, math.min(depth + 1, #_session_stack) do path[i] = _session_stack[i] end
            if #path == depth + 1 then
                Util.menu_hist_add(json.decode(json.encode(path)))
            end
        end
        while #_session_stack > depth do table.remove(_session_stack) end
        session_save()
    end
    if not ok then error(a, 0) end
    return a, b
end

local function session_clear()
    local parts = Util.breadcrumb_parts()
    if #parts > 1 then
        local copy = json.decode(json.encode(_session_stack)) or {}
        Util.trail_history[#Util.trail_history + 1] = {
            label = table.concat(parts, " > "),
            stack = copy,
        }
        if #Util.trail_history > 2 then table.remove(Util.trail_history, 1) end
        Util.trail_save()
    end
    -- session_save (reached through Util.session_set) removes the file itself
    -- once the stack is empty, so no os.remove is needed here or below.
    Util.session_set({})
end

function Util.clear_trail()
    Util.session_set({})
    Util.trail_history = {}
    os.remove(P.trails)
end

-- BREADCRUMB

-- A label may be a function, resolved at render time. Only one view needs it --
-- the library menu is named after the Spotify account, which is not known until
-- the profile has been read, and can change. Everything else passes a string and
-- is unaffected.
local function view_label(view)
    local v = VIEWS[view]
    local l = v and v.label
    if type(l) == "function" then
        local ok, name = pcall(l)
        l = ok and name or nil
    end
    return l or view or "?"
end

local function crumb_name(entry)
    if type(entry) ~= "table" then return nil end
    if entry.artist_name and entry.artist_name ~= "" then return entry.artist_name end
    if entry.track_name and entry.track_name ~= "" then return entry.track_name end
    if entry.episode_name and entry.episode_name ~= "" then return entry.episode_name end
    if entry.playlist_name and entry.playlist_name ~= "" then return entry.playlist_name end
    if entry.album_name and entry.album_name ~= "" then return entry.album_name end
    -- Below album_name and below episode_name on purpose: an episode-action
    -- entry carries BOTH show_name and episode_name, and the episode is the
    -- thing that step is about.
    if entry.show_name and entry.show_name ~= "" then return entry.show_name end
    if entry.category_name and entry.category_name ~= "" then return entry.category_name end
    if entry.query and entry.query ~= "" then return entry.query end
    return nil
end
-- lyrics_track_name / recs_track_name / strack_name are deliberately NOT read
-- here. Those views are label_only (see reg below), so this is never consulted
-- for them. The fields still matter -- replay_session restores each view from
-- its own, and they are named apart from an "action" entry's track_name so a
-- replay can tell the two kinds of entry apart -- they simply never named a
-- breadcrumb. The comment that used to sit here claimed they existed to avoid a
-- generic label, which was never true: the old name-collision rule discarded
-- them every time, since these views are only ever opened from a track action
-- menu that has already shown that same name one step up.

-- A step renders its own name when it has one, and its view's label otherwise.
--
-- This used to collapse a name that MATCHED THE STEP ABOVE IT down to the label,
-- which was the wrong test on both counts. It misfired on legitimate repeats --
-- a single, whose track shares the album's name, showed "Snail of Gold > Track",
-- and a self-titled album under its artist showed "Weezer > Album". And the case
-- it was really there for is about view identity, not string equality: "Lyrics"
-- reads better than a repeated track name because Lyrics is a DETAIL of the step
-- above it, which is now stated directly by label_only (see reg).
function Util.parts_from_stack(stack)
    local parts = {"Main"}
    if stack then
        for _, e in ipairs(stack) do
            -- crumb_name already tolerates a non-table entry, but view_label(e.view)
            -- below did not: a truncated or hand-edited session.json/trails.json
            -- holding a bare string raised "attempt to index a string value" on the
            -- startup replay path, which has no pcall around it, and the app would
            -- not launch until the cache file was deleted by hand. A junk entry is
            -- worth skipping, never worth refusing to start over.
            if type(e) == "table" then
                local v = VIEWS[e.view]
                local name = not (v and v.label_only) and crumb_name(e) or nil
                parts[#parts+1] = name or view_label(e.view)
            end
        end
    end
    return parts
end

function Util.breadcrumb_parts()
    return Util.parts_from_stack(_session_stack)
end

-- The arrow between trail steps. Darker and heavier than the step names it
-- separates, so the names read first and the arrows recede into punctuation --
-- the whole crumb is otherwise one flat Util.DIM, arrows included.
--
-- One definition shared by the two places a trail is drawn: the breadcrumb in
-- every menu's mesg, and the rows of the Trail Steps menu. The literal
-- ">" stays OUTSIDE the Util.markup blobs so pango_escape still turns it into
-- &gt;; only the tags are protected from escaping.
function Util.crumb_arrow(s)
    return Util.markup('<span foreground="#454a55"><b>') .. s .. Util.markup('</b></span>')
end

local function breadcrumb()
    local parts = {}
    -- Archived trails are rebuilt from their saved STACK, not from their saved
    -- label string. session_clear writes that label with a plain " > ", so
    -- rendering it verbatim left every previous trail with unstyled arrows while
    -- the live crumb beside it had styled ones.
    --
    -- Rebuilding rather than writing markup into trails.json keeps presentation
    -- out of persisted data: the arrow colour is applied at draw time, so a later
    -- change reaches old trails too, and trails saved before this get styled
    -- immediately instead of only new ones. It also picks up the label_only
    -- naming fix for free -- an old label may still read "Snail of Gold > Track".
    --
    -- Falls back to the stored label for entries with no usable stack: trail_load
    -- turns a legacy bare string into {label=t, stack={}}.
    for _, t in ipairs(Util.trail_history) do
        if type(t) == "table" and type(t.stack) == "table" and #t.stack > 0 then
            parts[#parts+1] = table.concat(Util.parts_from_stack(t.stack), Util.crumb_arrow(" > "))
        else
            parts[#parts+1] = type(t) == "table" and t.label or t
        end
    end
    parts[#parts+1] = table.concat(Util.breadcrumb_parts(), Util.crumb_arrow(" > "))
    return table.concat(parts, "  " .. Util.markup('<span foreground="#a3a9bd">\u{F17B7}</span>') .. "  ")
end

-- ROFI

local main_pending    = false
local liked_pending = false
local jump_to_track_pending = false
local recent_pending = false
local view_actions, view_artist, view_lyrics, view_add_pl, view_art, view_volume
local view_seek
local view_new_releases
local browse_album, view_browse
local get_playback
local get_token
local get_playerctl_position
local display_track, rofi_message
local toggle_repeat, toggle_shuffle
local open_url
local queue_tracks, queue_idx, queue_context
local recover_playback
local format_entries
local api_get_playlist_tracks

local function status_mesg()
    local DIM = Util.DIM
    local r
    if repeat_state == "track" then r = Util.markup('<span foreground="#fab387">\u{F0458}</span>')
    elseif repeat_state == "context" then r = "\u{F0456}"
    else r = Util.markup('<span foreground="' .. DIM .. '">\u{F0457}</span>') end
    local s = is_shuffle and "\u{F074}" or Util.markup('<span foreground="' .. DIM .. '">\u{F049D}</span>')
    return r .. " " .. s
end

toggle_repeat = function()
    local token = get_token()
    local new_state = repeat_state == "off" and "context"
        or (repeat_state == "context" and "track" or "off")
    repeat_state = new_state
    _local_toggle_time = os.time()
    write_file(P.state, json.encode({repeat_state=repeat_state, shuffle=is_shuffle}))
    if not token then return end
    Util.api_write_bg("PUT", "https://api.spotify.com/v1/me/player/repeat?state=" .. new_state,
        token, {timeout=3, len0=true})
end

toggle_shuffle = function()
    local token = get_token()
    is_shuffle = not is_shuffle
    _local_toggle_time = os.time()
    write_file(P.state, json.encode({repeat_state=repeat_state, shuffle=is_shuffle}))
    if not token then return end
    Util.api_write_bg("PUT", "https://api.spotify.com/v1/me/player/shuffle?state="
        .. (is_shuffle and "true" or "false"), token, {timeout=3, len0=true})
end

local function rofi_dmenu(entries, opts)
    Util.back_pressed = false
    Util.alt_pressed = false
    Util.tab_pressed = false
    Util.del_pressed = false
    if main_pending or liked_pending or recent_pending or Util.trail_jump_pending then return nil end
    opts = opts or {}
    local prompt   = opts.prompt or ""
    local mesg_fn  = opts.mesg
    local markup   = opts.markup
    local by_index = opts.by_index
    -- Two themes, one choice: a thumbnail grid or a plain list. main.rasi was a
    -- third -- the root menu's own -- and the root is a grid now, so nothing
    -- reached it. The `use_menu` flag went with it: it existed only to pick
    -- between main.rasi and menu.rasi, and with one of them gone it selected
    -- between a thing and itself at 21 call sites.
    local theme    = opts.theme or (opts.thumbs and Util.THEME_THUMBS or THEME_MENU)
    local sel      = opts.sel
    -- Blanket cursor memory: any menu given a pos_key restores the row it was
    -- last left on and records the row chosen, on disk, so it survives both
    -- back-navigation and a cold reopen. Doing it here rather than at each
    -- call site is what makes it apply to every menu including future ones.
    -- Transient prompts (confirmations) simply omit pos_key.
    local pos_key  = opts.pos_key
    if pos_key and not sel then
        local saved = Util.pos_get(pos_key)
        if type(saved) == "number" and #(entries or {}) > 0 then
            sel = math.max(0, math.min(saved, #entries - 1))
        end
    end
    local function remember_pos(row)
        if not pos_key or type(row) ~= "number" or row < 0 then return end
        Util.pos_put(pos_key, row)
    end
    -- Resolve whatever rofi reported (a row index under by_index, otherwise the
    -- entry text) back to a row number. Shared by the ordinary selection path,
    -- the Escape handler and the redraw path, so quitting or bouncing through a
    -- nested view remembers the row you were sitting on exactly as selecting
    -- one would.
    local function row_of(res)
        if by_index then
            local n = tonumber(res)
            if n and n >= 0 then return n end
            return nil
        end
        -- Compared through the SAME transformation the row was written with:
        -- a markup menu writes Util.pango_escape(e), so rofi echoes back the
        -- escaped text. Comparing that against the raw entry meant any row
        -- containing & < > never resolved to an index -- which is how a lyric
        -- line like "Me & You" silently lost its cursor memory. Track lists
        -- escaped this only by using by_index.
        local want = Util.strip_markup(res or "")
        for i, e in ipairs(entries or {}) do
            if Util.strip_markup(markup and Util.pango_escape(e) or e) == want then return i - 1 end
        end
        return nil
    end
    local function capture_pos(res)
        if not pos_key then return end
        remember_pos(row_of(res))
    end

    -- THE menu invariant: rofi_dmenu returns nil ONLY when the user left this
    -- menu. Anything happening inside it -- a toggle, a seek, a nested view, an
    -- error -- must redraw instead, because every caller reads nil as "my menu
    -- exited" and unwinds, and the surrounding Util.scope then pops its stack
    -- entry. That is how Alt+Return from an album list used to lose the list.
    --
    -- Call as `if reenter(res) then goto menu_redo end return nil`: false means
    -- a deliberate global jump is in flight and the nil must propagate.
    local function reenter(res)
        Util.back_pressed = false
        Util.alt_pressed = false
        Util.del_pressed = false
        if main_pending or liked_pending or recent_pending or Util.trail_jump_pending
           or jump_to_track_pending then return false end
        local row = row_of(res)
        if row then sel = row; remember_pos(row) end
        return true
    end

    if jump_to_track_pending then return nil end
    ::menu_redo::
    -- Rows are rebuilt here, not by the caller, because a redraw can happen
    -- without the caller's loop ever running: reenter() comes back through this
    -- label after a nested view that may have played or liked something. A menu
    -- whose rows show live state passes `refresh`; mesg gets the same treatment
    -- by being a function. Cheap to call every draw -- format_entries memoises
    -- on (tracks, current_id, is_playing) and like/unlike busts that cache.
    if opts.refresh then entries = opts.refresh() or entries end
    -- Spelled out rather than `type(x) == "function" and x() or x`: that idiom
    -- hands back the FUNCTION when the call returns nil, and a mesg function is
    -- allowed to return nil (main and view_playback do, when nothing is playing).
    local mesg = mesg_fn
    if type(mesg) == "function" then mesg = mesg() end
    -- Album/action themes size the message box by counting literal "\n"s, not
    -- wrapped visual lines, so a long auto-wrapping name eats the breadcrumb row
    -- and the trail vanishes. Capping only the first line at a width that never
    -- wraps fixes it everywhere without touching deliberate multi-line content.
    -- Status icons are peeled off first and re-attached after the cut, so the
    -- budget buys title and the glyphs always show in full.
    if mesg then
        local nl = mesg:find("\n", 1, true)
        local first = nl and mesg:sub(1, nl - 1) or mesg
        local rest  = nl and mesg:sub(nl) or ""
        local body, icons = split_status_icons(first)
        -- Measure what will actually be DRAWN. The budget is a width estimate at
        -- ~10px per character, and markup occupies no width -- but it was being
        -- counted, so the shuffle/repeat spans alone spent 38 of the 49 and a
        -- 16-character track title came out as "Xtal…". A blind cut was unsafe
        -- besides: it could slice a <span …> in half and hand rofi broken pango.
        -- Fits: left exactly as built, markup and all. Too long: the cut is made
        -- on the plain text, because slicing a <span …> in half would hand rofi
        -- broken pango.
        local plain = Util.strip_markup(body)
        if (utf8.len(plain) or 0) > MESG_NAME_MAX_CHARS then
            body = truncate_text(plain, MESG_NAME_MAX_CHARS)
        end
        mesg = body .. icons .. rest
    end
    local args = {"rofi","-dmenu","-config",P.dir.."/style/config.rasi","-theme",theme,"-p",prompt,"-i",
                   "-kb-custom-1","Control+Shift+Delete"}
    -- Release rofi's own claims on keys we want for ourselves. Tab belongs to
    -- kb-element-next and Shift+Return to kb-accept-alt; while rofi holds them
    -- it handles the press internally and exits with the ordinary accept code,
    -- so the script can never tell Return from Shift+Return. Unbinding first
    -- also avoids a binding-conflict error regardless of argv parse order.
    args[#args+1] = "-kb-element-next"; args[#args+1] = ""
    args[#args+1] = "-kb-accept-alt"; args[#args+1] = ""
    -- Escape is taken off kb-cancel for the same reason as the keys above: as
    -- long as rofi owns it, it exits code 1 and reports nothing, so we never
    -- learn which row was highlighted and the cursor is lost on reopen. Routed
    -- through a custom slot we get both a distinct code and the hovered row.
    -- Control+bracketleft stays on kb-cancel as a native escape hatch.
    args[#args+1] = "-kb-cancel"; args[#args+1] = "Control+bracketleft"
    args[#args+1] = "-kb-custom-5"; args[#args+1] = "Escape"
    -- Last custom slot (exit code 9 + N). Redraws the menu in place, which is
    -- how a thumbnail grid picks up covers the background prefetch has written
    -- since it opened -- rofi never re-reads an icon path it already missed.
    args[#args+1] = "-kb-custom-19"; args[#args+1] = "F5"
    if not opts.no_alt_space then args[#args+1] = "-kb-custom-2"; args[#args+1] = "Alt+space" end
    args[#args+1] = "-kb-custom-3"; args[#args+1] = "Alt+g"
    args[#args+1] = "-kb-custom-4"; args[#args+1] = "Alt+Return"
    args[#args+1] = "-kb-custom-6"; args[#args+1] = "Alt+l"
    args[#args+1] = "-kb-custom-7"; args[#args+1] = "Tab"
    args[#args+1] = "-kb-custom-8"; args[#args+1] = "Alt+c"
    args[#args+1] = "-kb-custom-9"; args[#args+1] = "Alt+e"
    args[#args+1] = "-kb-custom-10"; args[#args+1] = "Alt+a"
    args[#args+1] = "-kb-custom-11"; args[#args+1] = "Alt+r"
    args[#args+1] = "-kb-custom-12"; args[#args+1] = "Alt+y"
    args[#args+1] = "-kb-custom-13"; args[#args+1] = "Alt+p"
    args[#args+1] = "-kb-custom-14"; args[#args+1] = "Alt+s"
    -- One slot, two meanings, because rofi has exactly 19 kb-custom slots
    -- (verified: a 20th is silently ignored) and all 19 are already spoken for.
    -- A history menu binds plain Delete here and reads exit 24 as "drop the
    -- highlighted entry"; every other menu binds Alt+Delete and reads it as
    -- "clear the session trail". The two are never both wanted in one menu, so
    -- sharing the slot costs nothing except that Alt+Delete does not clear the
    -- trail while you are sitting in a search box -- where you are typing, not
    -- navigating.
    -- Delete deletes a ROW in the menus that own rows worth deleting -- the
    -- search box's history and Trail History. Everywhere else the slot is
    -- Alt+Delete, which clears the trail. One binding, two meanings, decided by
    -- whether the caller opted in.
    args[#args+1] = "-kb-custom-15"
    args[#args+1] = (opts.hist_key or opts.del_select) and "Delete" or "Alt+Delete"
    args[#args+1] = "-kb-custom-16"; args[#args+1] = "Alt+equal"
    args[#args+1] = "-kb-custom-17"; args[#args+1] = "Alt+minus"
    args[#args+1] = "-kb-custom-18"; args[#args+1] = "Shift+Return"
    args[#args+1] = "-kb-remove-char-forward"; args[#args+1] = "Control+d"
    if opts.custom == false then args[#args+1] = "-no-custom" end
    if markup then args[#args+1] = "-markup-rows"; args[#args+1] = "-markup" end
    if by_index then args[#args+1] = "-format"; args[#args+1] = "i" end
    -- Grids only: \0icon rows come from Util.album_thumbs and nowhere else, so
    -- a text list has no icons to lose and no reason to carry -threads.
    if opts.thumbs then
        Util.grid_args(args, #(entries or {}))
    end
    if sel and sel > 0 then args[#args+1] = "-selected-row"; args[#args+1] = tostring(sel) end
    if not opts.no_status and not opts.thumbs then
        local status = status_mesg()
        if status then mesg = mesg and (status .. "  " .. mesg) or status end
    end
    -- The trail menus are the one place this is suppressed: they ARE the trail,
    -- so printing it above them says nothing, and the line is better spent on
    -- what Tab does from where you are standing.
    if not opts.no_crumb then
        local crumb = breadcrumb()
        if crumb then
            if markup then crumb = Util.dim(crumb) end
            mesg = (mesg and (mesg .. "\n") or "") .. crumb
        end
    end
    if mesg then args[#args+1] = "-mesg"; args[#args+1] = Util.pango_escape(mesg) end

    local entry_tf = Util.tmpfile("menu.in")
    local f = io.open(entry_tf, "w")
    if not f then os.remove(entry_tf); return nil end
    for _, e in ipairs(entries or {}) do f:write(markup and Util.pango_escape(e) or e, "\n") end
    f:close()

    -- Return value deliberately dropped: the monitor lives for the app's
    -- lifetime and is torn down in Util.clean_exit, not here.
    Util.bs_launch(theme)

    local qa = {}
    for _, a in ipairs(args) do qa[#qa+1] = shell_quote(a) end
    local out_tf = Util.tmpfile("menu.out")
    local cmd = table.concat(qa, " ") .. " < " .. shell_quote(entry_tf)
              .. " > " .. shell_quote(out_tf)
              .. " 2>/dev/null; printf '\\n__EXIT__%d__' $? >> " .. shell_quote(out_tf)
    os.execute(cmd)
    -- bs is intentionally NOT torn down here; it lives for the app's lifetime
    -- and is cleaned up in Util.clean_exit.
    local raw = read_file(out_tf)
    os.remove(entry_tf)
    os.remove(out_tf)

    local exit_code = tonumber((raw or ""):match("__EXIT__(%d+)__")) or 0
    local result    = trim((raw or ""):match("^(.-)\n__EXIT__%d+__") or "")

    -- Escape. session.json is already current (saved on every push/pop) and
    -- clean_exit's os.exit means no scope unwinds to truncate it, so the only
    -- thing still missing is which row was highlighted -- record that, then go.
    if exit_code == EXIT.quit then capture_pos(result); Util.clean_exit() end
    if exit_code == EXIT.back then Util.back_pressed = true; return nil end
    if exit_code == EXIT.main then session_clear(); main_pending = true; return nil end
    if exit_code == EXIT.clear_trail then
        -- Shared slot; see the -kb-custom-15 binding above.
        if opts.hist_key then
            -- entries holds the RAW queries, while rofi echoes back the
            -- pango-escaped row, so resolve through row_of rather than
            -- comparing strings -- otherwise a query containing & or < could
            -- never be deleted.
            local row = row_of(result)
            local victim = row and (entries or {})[row + 1]
            if victim and Util.hist_remove(opts.hist_key, victim) then
                -- Keep the cursor where it was; opts.refresh rebuilds the list
                -- from storage on the way back through menu_redo.
                sel = math.max(0, math.min(row, #(entries or {}) - 2))
            end
            goto menu_redo
        end
        -- Opt-in, like alt_select: the caller owns the list and has to do the
        -- removal AND rebuild its rows, so this comes back as an ordinary accept
        -- with a flag rather than closing the menu. Read Util.del_pressed
        -- immediately -- the next rofi_dmenu clears it.
        if opts.del_select then
            Util.del_pressed = true
            local row = row_of(result)
            return by_index and (row and row + 1 or nil) or (row and (entries or {})[row + 1] or nil)
        end
        Util.clear_trail(); main_pending = true; return nil
    end
    if exit_code == EXIT.liked then
        -- Guarded like the EXIT.trail_jump handler below, and for the reason
        -- Util.scope spells out: nothing reaches a menu before session_load
        -- today, and this keeps that from being load-bearing.
        if not Util.jump_preserve_stack and _session_stack and #_session_stack > 0 then
            Util.jump_preserve_stack = json.decode(json.encode(_session_stack))
        end
        liked_pending = true; return nil end
    if exit_code == EXIT.trail_jump then
        -- Opt-in, like alt_select above: the trail menu handles Tab itself to
        -- switch modes, so it must not bubble up and close the very menu that
        -- wants to react to it. A flag rather than a callback, matching
        -- Util.alt_pressed; the caller reads it immediately.
        if opts.tab_select then Util.tab_pressed = true; return nil end
        Util.trail_jump_stack = _session_stack and json.decode(json.encode(_session_stack)) or {}
        Util.trail_jump_pending = true
        return nil
    end
    if exit_code == EXIT.track then jump_to_track_pending = true; return nil end
    if exit_code == EXIT.alt_action then
        -- Opt-in menus handle Shift+Return themselves: return the row as an
        -- ordinary accept and flag the key, like Util.back_pressed does for
        -- Backspace. A flag not a callback, because the caller may need `goto`
        -- or an early return inside its own loop (Saved Albums drops the row
        -- after removal). Read Util.alt_pressed immediately -- the next
        -- rofi_dmenu, nested or not, clears it.
        if opts.alt_select then
            local row = row_of(result)
            if row then
                capture_pos(result)
                Util.alt_pressed = true
                return by_index and (row + 1) or result
            end
            if reenter(result) then goto menu_redo end
            return nil
        end
        -- The sibling hotkey branches below all refresh before opening a view
        -- that renders track state; this one did not, so an action menu reached
        -- by Shift+Return could open on stale Play/Pause/Like labels.
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        -- Forward the list's context. view_actions has always accepted it, but
        -- every call site passed the item alone, so ctx_id was permanently nil
        -- -- which is why its Remove from Playlist branch was unreachable, and
        -- why Play from here lost the queue context do_play wants.
        if opts.current then
            view_actions(opts.current, opts.ctx_type, opts.ctx_id, opts.items, opts.cidx, opts.entries)
        else
            local items = opts.items or {}
            local idx = tonumber(result or "")
            if idx and idx >= 0 and idx < #items then
                view_actions(items[idx + 1], opts.ctx_type, opts.ctx_id, items, idx + 1, opts.entries)
            end
        end
        if reenter(result) then goto menu_redo end
        return nil
    end
    if exit_code == EXIT.seek then
        -- Run the seek view nested rather than unwinding to main with a flag:
        -- every Util.scope between here and main would truncate the stack on the
        -- way up, so Alt+e from a deep list used to drop you back at Main.
        if current_track then view_seek(current_track)
        else rofi_message("No track playing") end
        if reenter(result) then goto menu_redo end
        return nil
    end
    -- Alt+a and Alt+y do NOT re-enter view_actions after the nested view
    -- returns. `reenter -> goto menu_redo` already puts the same action menu
    -- back up with rebuild_actions re-run, so calling it again stacked a second
    -- {view="action"} entry for the same track -- and parts_from_stack renders a
    -- repeated crumb as the generic label, appending "Track" on every press.
    if exit_code == EXIT.art then
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        local target = opts.current or current_track
        if target then
            view_art(target)
        else rofi_message("No track playing") end
        if reenter(result) then goto menu_redo end
        return nil
    elseif exit_code == EXIT.recent then
        -- Guarded like the EXIT.trail_jump handler below, and for the reason
        -- Util.scope spells out: nothing reaches a menu before session_load
        -- today, and this keeps that from being load-bearing.
        if not Util.jump_preserve_stack and _session_stack and #_session_stack > 0 then
            Util.jump_preserve_stack = json.decode(json.encode(_session_stack))
        end
        recent_pending = true; return nil
    elseif exit_code == EXIT.lyrics then
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        local target = opts.current or current_track
        if target then
            view_lyrics(target)
        else rofi_message("No track playing") end
        if reenter(result) then goto menu_redo end
        return nil
    elseif exit_code == EXIT.jump then
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        if current_track then view_actions(current_track)
        else rofi_message("No track playing") end
        if reenter(result) then goto menu_redo end
        return nil
    elseif exit_code == EXIT.refresh then
        -- Pure redraw: menu_redo re-runs opts.refresh, so whatever that rebuilds
        -- (thumbnail icons, live track state) is picked up.
        if reenter(result) then goto menu_redo end
        return nil
    elseif exit_code == EXIT.repeat_toggle then
        toggle_repeat()
        if reenter(result) then goto menu_redo end
        return nil
    elseif exit_code == EXIT.shuffle_toggle then
        toggle_shuffle()
        if reenter(result) then goto menu_redo end
        return nil
    elseif exit_code == EXIT.open_url then
        local ok, err = pcall(function()
            local url = Util.get_clipboard()
            if url and url ~= "" then open_url(url)
            else rofi_message("Clipboard is empty") end
        end)
        if not ok then rofi_message("open_url error: " .. tostring(err)) end
        if reenter(result) then goto menu_redo end
        return nil
    elseif exit_code == EXIT.seek_plus or exit_code == EXIT.seek_minus then
        if not current_track then
            rofi_message("No track playing")
            if reenter(result) then goto menu_redo end
            return nil
        end
        local delta = exit_code == EXIT.seek_plus and 10 or -10
        local pos = get_playerctl_position()
        local dur = (current_track.duration_ms or 0) / 1000
        local target = math.max(0, math.min(dur > 0 and dur or math.huge, math.floor(pos + delta + 0.5)))
        os.execute("playerctl position " .. target .. " 2>/dev/null")
        mem_bust("_playerctl_pos")
        if reenter(result) then goto menu_redo end
        return nil
    else
        if result == "" then
            if exit_code == 0 then return nil end
            Util.clean_exit()
        end
        if by_index then
            local n = tonumber(result)
            if not n or n < 0 then return nil end
            capture_pos(result)
            return n + 1
        end
        capture_pos(result)
        return result
    end
end

-- Backspace must close THIS window only. spbsd turns Backspace-on-empty into
-- Control+Shift+Delete, and a window not binding that combo lets it fall
-- through to whatever takes focus next -- the menu underneath, which reads it
-- as "back". Hence Track Details used to skip the action menu entirely. Binding
-- it here (and bumping bsmon's generation to reset its shadow and latch) keeps
-- the press local, like every rofi_dmenu menu.
rofi_message = function(msg, theme)
    local tf = Util.tmpfile("msg")
    theme = theme or THEME_MSG
    Util.bs_launch(theme)
    os.execute("rofi -e " .. shell_quote(Util.pango_escape(msg)) .. " -config " .. shell_quote(P.dir.."/style/config.rasi") .. " -theme " .. shell_quote(theme) .. " -kb-custom-1 'Control+Shift+Delete' -markup 2>/dev/null; printf '\\n__EXIT__%d__' $? >> " .. shell_quote(tf))
    local raw = read_file(tf)
    os.remove(tf)
    local ec = tonumber((raw or ""):match("__EXIT__(%d+)__")) or 1
    return ec == 0
end

local function rofi_input(prompt, preset, theme)
    local in_tf  = Util.tmpfile("input.in")
    local out_tf = Util.tmpfile("input.out")
    local f = io.open(in_tf, "w")
    if f then f:write(preset or ""); f:close() end
    os.execute("rofi -dmenu -config " .. shell_quote(P.dir.."/style/config.rasi") .. " -p " .. shell_quote(prompt)
        .. " -theme " .. shell_quote(theme or THEME_MENU)
        .. " < " .. shell_quote(in_tf)
        .. " > " .. shell_quote(out_tf) .. " 2>/dev/null")
    local r = trim(read_file(out_tf) or "")
    os.remove(in_tf)
    os.remove(out_tf)
    return r
end

-- TOKEN

-- Hoisted out of oauth_get_token so the granted set can be RECORDED into
-- token.json. Adding a scope does not invalidate a stored refresh token -- the
-- new scope is simply never granted -- so a feature added after the last
-- authorisation would fail with nothing to point at. Writing down what was
-- actually granted is the same "know rather than guess" move as P.lib_fp and a
-- playlist's snapshot_id; Util.reauth is how you widen it.
local OAUTH_SCOPES = "app-remote-control playlist-modify playlist-modify-private playlist-modify-public"
    .. " playlist-read playlist-read-collaborative playlist-read-private streaming"
    .. " user-follow-modify user-follow-read user-library-modify user-library-read"
    .. " user-top-read"
    .. " user-modify-playback-state user-read-currently-playing user-read-playback-state"
    .. " user-read-private"
    .. " user-read-playback-position"

get_token = function()
    local cached = mem_get("token")
    if cached then return cached end
    local raw = read_file(P.token)
    if not raw then return nil end
    local data = safe_decode(raw)
    if not data then return nil end
    if not data.access_token then return nil end
    if data.expires_at and type(data.expires_at) == "number" then
        if os.time() > data.expires_at - 120 then
            if data.refresh_token and type(data.refresh_token) == "string" then
                local r = shell("curl -s --max-time 10 -X POST https://accounts.spotify.com/api/token "
                    .. "-d grant_type=refresh_token -d refresh_token=" .. shell_quote(data.refresh_token)
                    .. " -d client_id=" .. P.spotify)
                local rd = safe_decode(r)
                if rd and rd.access_token then
                    data.access_token = rd.access_token
                    if rd.refresh_token then data.refresh_token = rd.refresh_token end
                    data.expires_at = os.time() + (rd.expires_in or 3600) - 60
                    write_file(P.token, json.encode(data))
                    os.execute("chmod 600 " .. shell_quote(P.token) .. " 2>/dev/null")
                    local ttl = math.max(data.expires_at - os.time() - 120, 60)
                    mem_set("token", data.access_token, ttl)
                    return data.access_token
                end
            end
            -- Refresh failed (offline or revoked); don't hand back a dead token.
            os.remove(P.token)
            mem_bust("token")
            return nil
        end
    end
    if not data.expires_at or type(data.expires_at) ~= "number" then return data.access_token end
    local ttl = math.max(data.expires_at - os.time() - 120, 60)
    mem_set("token", data.access_token, ttl)
    return data.access_token
end

local function oauth_get_token()
    local verifier = trim(shell("openssl rand -base64 96 | tr -d '=+\\n/' | head -c 128"))
    local challenge = trim(shell("echo -n " .. shell_quote(verifier)
        .. " | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='"))
    local scopes = OAUTH_SCOPES
    local auth_url = "https://accounts.spotify.com/authorize"
        .. "?client_id=" .. P.spotify
        .. "&response_type=code"
        .. "&redirect_uri=http://127.0.0.1:8989/login"
        .. "&code_challenge_method=S256"
        .. "&code_challenge=" .. challenge
        .. "&scope=" .. scopes:gsub("%s+", "+")

    -- The output path is passed as an ARGUMENT and read back as $ARGV[0], rather
    -- than interpolated into the program text. Interpolating put it inside a Perl
    -- double-quoted string nested inside a shell single-quoted program, where a
    -- $ or @ in the path would be expanded by Perl and a ' would end the shell's
    -- quoting. As an argument it needs no escaping rules beyond shell_quote.
    local srv = "perl -MIO::Socket::INET -e '"
        .. "alarm 120;"
        .. "$s=IO::Socket::INET->new(LocalPort=>8989,Listen=>1,ReuseAddr=>1);"
        .. "$c=$s->accept();$r=<$c>;($x)=$r=~/code=([^&\\s]+)/;"
        .. "if($x){open(F,\">\",$ARGV[0]);print F $x;close(F)}"
        .. "print $c \"HTTP/1.1 200 OK\\r\\n\\r\\nok\";close $c;close $s' "
        .. shell_quote(P.tmp .. "/spoot_code")
    os.execute(srv .. " & echo $! > " .. shell_quote(P.tmp .. "/spoot_oauth_pid"))
    os.execute("xdg-open " .. shell_quote(auth_url) .. " 2>/dev/null &")

    local function kill_oauth_server()
        local pid = trim(read_file(P.tmp .. "/spoot_oauth_pid") or "")
        if pid ~= "" and pid:match("^%d+$") then os.execute("kill " .. pid .. " 2>/dev/null") end
        os.remove(P.tmp .. "/spoot_oauth_pid")
    end

    local attempts = 0
    while true do
        local code = trim(read_file(P.tmp .. "/spoot_code") or "")
        if #code > 0 then
            os.remove(P.tmp .. "/spoot_code")
            kill_oauth_server()
            local r = shell("curl -s --max-time 10 -X POST https://accounts.spotify.com/api/token "
                .. "-d grant_type=authorization_code -d code=" .. shell_quote(code)
                .. " -d redirect_uri=http://127.0.0.1:8989/login"
                .. " -d client_id=" .. P.spotify
                .. " -d code_verifier=" .. shell_quote(verifier))
            local d = safe_decode(r)
            if d and d.access_token then
                write_file(P.token, json.encode({
                    access_token = d.access_token,
                    refresh_token = d.refresh_token,
                    expires_at = os.time() + (d.expires_in or 3600) - 60,
                    -- What this token can actually do. d.scope is what Spotify
                    -- says it GRANTED, which is the authority; OAUTH_SCOPES is
                    -- only what was asked for.
                    scopes = d.scope or OAUTH_SCOPES,
                }))
                os.execute("chmod 600 " .. shell_quote(P.token) .. " 2>/dev/null")
                return d.access_token
            end
            return nil
        end
        attempts = attempts + 1
        if attempts >= 120 then
            kill_oauth_server()
            os.remove(P.tmp .. "/spoot_code")
            rofi_message("OAuth timed out — no response after 120 seconds")
            return nil
        end
        os.execute("sleep 1")
    end
end

local function ensure_auth()
    if get_token() then return end
    oauth_get_token()
end

-- Discards the stored token so the next ensure_auth runs the full flow. The only
-- way to widen the granted scope set: a refresh grant returns whatever was
-- authorised originally, no matter what OAUTH_SCOPES has grown to since.
function Util.reauth()
    os.remove(P.token)
    mem_bust("token")
    ensure_auth()
    return get_token() ~= nil
end

-- NOTIFY

local function artist_names(item)
    local a = {}
    for _, v in ipairs(item.artists or {}) do if v.name then a[#a+1] = v.name end end
    return table.concat(a, ", ")
end

-- "Who is this by", for anything with a name. Artists for tracks and albums,
-- the show for an episode, the publisher for a show itself. One function
-- because the alternative is `or item.publisher` sprinkled across the five
-- sites that caption a row -- track_mesg, display_episode, display_show,
-- view_art and album_suffix -- which is exactly the drift artist_names already
-- exists to prevent. Returns "" rather than nil so every caller can concatenate.
function Util.subtitle(item)
    if not item then return "" end
    local an = artist_names(item)
    if an ~= "" then return an end
    if item.show and item.show.name then return item.show.name end
    return item.publisher or ""
end

local function album_suffix(item)
    local an = Util.subtitle(item)
    if an == "" then return "" end
    return SEP .. an
end

Util.art_url = function(art_url, seed)
    if not art_url or #art_url == 0 then return art_url end
    local s = seed or "82c1"
    return (art_url:gsub("(i%.scdn%.co/image/ab67616d0000)[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]", "%1" .. s))
end

-- The high-resolution rendition of a PLAYLIST cover. The last byte of the prefix
-- is a size code: ab67706f00000002 is 300x300 and …03 is 640x640, verified
-- against six playlists including editorial and featured ones.
--
-- Anchored to that exact prefix on purpose. Every playlist reachable from this
-- account has an uploaded cover sharing it, so an auto-generated mosaic using a
-- different prefix is untested -- and rewriting a prefix we do not recognise
-- would turn a working 300px cover into a 404. Anything unmatched is returned
-- untouched and simply stays at the size Spotify gave.
Util.art_url_hi = function(art_url)
    if not art_url or #art_url == 0 then return art_url end
    return (art_url:gsub("(i%.scdn%.co/image/ab67706f000000)0[0-9a-fA-F]", "%103"))
end

Util._rand_suffix = function()
    local u = io.open("/dev/urandom", "rb")
    if u then
        local b = u:read(4)
        u:close()
        if b and #b == 4 then
            return string.format("%02x%02x%02x%02x", b:byte(1), b:byte(2), b:byte(3), b:byte(4))
        end
    end
    return tostring(os.time())
end

Util._art_content_length = function(hdr_path)
    if not hdr_path then return nil end
    local h = read_file(hdr_path)
    if not h then return nil end
    return tonumber(h:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
end

-- Is this file something rofi can actually draw, and did all of it arrive?
--
-- This used to accept JPEG and nothing else, which was wrong about what Spotify
-- serves: 2 of the 50 category icons are PNG, and roughly a tenth of playlist
-- search results are WebP (user-uploaded covers on image-cdn-*.spotifycdn.com).
-- Every one of those was downloaded, rejected, and queued again on the NEXT
-- draw, so Categories and playlist search each paid ~3 s per open, reopen and
-- back -- forever, since the file could never be accepted. rofi renders all
-- three formats (gdk-pixbuf identifies images by content, not by extension),
-- so the files are stored exactly as they arrive under their existing .jpg
-- path and the suffix is cosmetic.
--
-- Still a real check, not a rubber stamp: each format is verified end-to-end so
-- a truncated download is caught, which is the reason this function exists.
Util._art_valid_file = function(path, content_length)
    local fh = io.open(path, "rb")
    if not fh then return false end
    local head = fh:read(12) or ""
    local st = fh:seek("end")
    local function tail_bytes(n)
        if not st or st < n then return nil end
        fh:seek("end", -n)
        return fh:read(n)
    end
    local ok = false
    if not st or st <= 0 or (content_length and st ~= content_length) then
        ok = false
    elseif head:byte(1) == 0xFF and head:byte(2) == 0xD8 and head:byte(3) == 0xFF then
        local t = tail_bytes(2)
        ok = t ~= nil and t:byte(1) == 0xFF and t:byte(2) == 0xD9
    elseif head:sub(1, 8) == "\137PNG\r\n\26\n" then
        -- IEND, with its CRC -- the last 8 bytes of every well-formed PNG.
        ok = tail_bytes(8) == "IEND\174\66\96\130"
    elseif head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
        -- The RIFF size field counts everything after itself, so it is a
        -- length check on the whole file -- stricter than any trailer sniff.
        local b1, b2, b3, b4 = head:byte(5, 8)
        ok = b1 and (b1 + b2 * 256 + b3 * 65536 + b4 * 16777216) == st - 8
    end
    fh:close()
    return ok
end

-- The part of an art URL that identifies the IMAGE, so a replaced cover is
-- detectable. Album art is i.scdn.co/image/<hex> with no extension; category
-- icons are t.scdn.co/images/<hex>.jpeg, and the extension is what used to
-- defeat this -- an anchored [%w_%-]+$ cannot cross the dot, so every category
-- resolved to no hash at all and none of them ever cached. Query strings are
-- dropped too: they are cache-busting noise, not identity.
Util.art_hash = function(url)
    if not url or #url == 0 then return nil end
    local last = url:match("([^/?#]+)[?#]") or url:match("([^/?#]+)$")
    if not last then return nil end
    return (last:gsub("%.%w+$", ""):gsub("[^%w_%-]", ""))
end

-- Is another attempt at this fetch worth anything? A body that arrived intact
-- but is not a renderable image will not become one on the second try, and a
-- 404 will not either -- retrying those only bought the sleep between passes,
-- which is what made a single dead cover cost ~2 s on EVERY draw of a list.
-- Only genuinely transient conditions come back.
--
-- code == nil means curl reported nothing for this url at all: connection
-- refused, DNS, or timeout. `truncated` is a size mismatch against the
-- Content-Length, i.e. the transfer was cut short.
Util.art_retry_worthwhile = function(code, truncated)
    if code == nil then return true end          -- never reached the server
    if truncated then return true end            -- arrived short
    local n = tonumber(code)
    if not n then return false end
    return n == 408 or n == 429 or n >= 500      -- server said "later"
end

Util.fetch_art = function(url, art_path, opts)
    opts = opts or {}
    local attempts = opts.attempts or 3
    local connect_timeout = opts.connect_timeout or 5
    local timeout = opts.timeout or 10
    for attempt = 1, attempts do
        local tmp = art_path .. ".tmp" .. Util._rand_suffix()
        local hdr = tmp .. ".hdr"
        -- -w carries the status back so a hopeless fetch can be told apart from
        -- an unlucky one; -f still suppresses the error body.
        local cmd = string.format("curl -sf --connect-timeout %d --max-time %d -D %s -o %s %s -w '%%{http_code}' 2>/dev/null",
            connect_timeout, timeout, shell_quote(hdr), shell_quote(tmp), shell_quote(url))
        local code = (shell(cmd) or ""):match("%d%d%d")
        local cl = Util._art_content_length(hdr)
        os.remove(hdr)
        if Util._art_valid_file(tmp, cl) then
            if os.rename(tmp, art_path) then return art_path end
        end
        -- Truncation is the one failure the size tells us about; anything else
        -- that arrived is a body we simply cannot draw.
        local truncated = false
        if cl then
            local fh = io.open(tmp, "rb")
            if fh then truncated = fh:seek("end") ~= cl; fh:close() end
        end
        os.remove(tmp)
        if not Util.art_retry_worthwhile(code, truncated) then return nil end
        if attempt < attempts then os.execute("sleep 1") end
    end
    return nil
end

-- Values go into a curl -K config, which honours backslash escapes inside the
-- quotes. Art URLs and cache paths never contain either character today, but a
-- $HOME that did would silently corrupt every transfer in the config.
-- On Util, not a local: the chunk body is one function and Lua caps it at 200
-- locals (see the note above Util's declaration).
Util._curl_cfg_quote = function(s)
    return (tostring(s):gsub("[\\\"]", "\\%0"))
end

-- One curl process per pass, not one per image. -Z multiplexes over a few HTTP/2
-- connections: 40 covers in 0.54s / 0.08s CPU versus 1.45s / 1.14s for the
-- 8-at-a-time fork loop. The old cost was process spawn and cold TCP+TLS, not
-- concurrency -- hence --parallel-max 16 matching 32 or 64.
--
-- Validation uses --write-out, not headers: `dump-header` in a -K config is
-- global and last-one-wins, so all responses concatenate into one file with
-- nothing tying them to a transfer. --write-out is per transfer and carries the
-- status plus the bytes written, keyed by output path. No .hdr files now.
Util._art_batch = function(items)
    local todo = items
    for pass = 1, 3 do
        if #todo == 0 then break end
        local cfg = Util.tmpfile("curlcfg")
        local f = io.open(cfg, "w")
        if not f then os.remove(cfg); return end
        for j, pd in ipairs(todo) do
            pd.tmp = pd.path .. ".tmp" .. Util._rand_suffix() .. "." .. j
            f:write('url = "', Util._curl_cfg_quote(pd.url), '"\n',
                    'output = "', Util._curl_cfg_quote(pd.tmp), '"\n')
        end
        f:close()
        -- filename_effective goes LAST so a path containing spaces still parses.
        local report = shell("curl -sf -Z --parallel-max 16 --connect-timeout 5 --max-time 10 -K "
            .. shell_quote(cfg) .. " -w '%{http_code} %{size_download} %{filename_effective}\\n' 2>/dev/null") or ""
        os.remove(cfg)
        local got = {}
        for code, size, path in report:gmatch("(%d+) (%d+) ([^\n]+)") do
            got[path] = {code = code, size = tonumber(size)}
        end
        -- Split, rather than retrying everything that did not land: a cover
        -- that came down whole but is not a drawable image is hopeless, and
        -- carrying it into the next pass bought nothing but the sleep below.
        local retry = {}
        for _, pd in ipairs(todo) do
            local r = got[pd.tmp]
            local ok = r ~= nil and Util.is2xx(r.code)
            if ok then ok = Util._art_valid_file(pd.tmp, r.size) end
            if ok then ok = os.rename(pd.tmp, pd.path) end
            pd.ok = ok or nil
            -- Only on failure: a successful rename already moved the file, so
            -- the unconditional remove was a wasted syscall per cover -- 60 of
            -- them on a full sync batch.
            if not ok then
                -- r.size is what curl actually wrote. It can only disagree with
                -- the transfer curl reported as complete if the transfer was
                -- cut short, which is the one retryable kind of bad body.
                local truncated = false
                if r and Util.is2xx(r.code) then
                    local fh = io.open(pd.tmp, "rb")
                    if fh then truncated = fh:seek("end") ~= r.size; fh:close() end
                end
                if Util.art_retry_worthwhile(r and r.code, truncated) then
                    retry[#retry+1] = pd
                else
                    pd.dead = true   -- so the caller can stop asking for it
                end
                os.remove(pd.tmp)
            end
            pd.tmp = nil
        end
        todo = retry
        if #todo > 0 and pass < 3 then os.execute("sleep 1") end
    end
end

-- Hands the tail of a thumbnail grid to a detached copy of ourselves so the menu
-- can draw now and the rest of the covers are warm by the next visit. Routed
-- through spoot.lua rather than a backgrounded bare curl so the tail gets the
-- same status + byte-count + JPEG validation and atomic rename as the sync path;
-- a prefetch killed mid-flight can then never leave a truncated file sitting at
-- a final art path, where every later run would trust it.
-- Covers per spool file. A CHUNK SIZE, not a limit on how much of a grid gets
-- fetched: the worker drains every file in the spool, so a 1496-album
-- discography becomes seven of these and all of it lands. Chunked rather than
-- handed over whole so the index is committed seven times instead of once, and a
-- worker killed part-way through leaves its finished chunks recorded.
Util.PREFETCH_MAX = 240
Util.art_spool_dir = function() return P.tmp .. "/spoot_art_spool" end

-- Hands the tail of a thumbnail grid to a detached copy of ourselves so the menu
-- can draw now and the rest of the covers are warm by the next visit. Routed
-- through spoot.lua rather than a backgrounded bare curl so the tail gets the
-- same status + byte-count + JPEG validation and atomic rename as the sync path;
-- a prefetch killed mid-flight can then never leave a truncated file sitting at
-- a final art path, where every later run would trust it.
--
-- SPOOLED, not handed to one process. This used to return outright when a worker
-- was already alive, which threw the whole tail away -- and a grid you are
-- sitting in produces no next draw to re-queue from, so those tiles stayed
-- placeholders until you pressed F5. A worker lives ~3s per chunk, so any grid
-- opened just after another one lost its covers, which is precisely the "it
-- works sometimes" this is meant to end. Now the work is always written down;
-- the pidfile only decides whether a NEW worker is needed to drain it.
--
-- Answers the tail_action recorded in the thumbnail log.
function Util.spawn_art_prefetch(list, kind)
    if not list or #list == 0 then return "empty" end
    local dir = Util.art_spool_dir()
    os.execute("mkdir -p " .. shell_quote(dir))
    local n = 0
    for i = 1, #list, Util.PREFETCH_MAX do
        -- Zero-padded so a plain lexicographic sort is oldest-first, and written
        -- under a dot-prefixed name that is renamed into place, so a worker
        -- scanning the directory can never pick up a half-written chunk.
        local name = string.format("%012d_%s_%06d", os.time(), Util._rand_suffix(), i)
        local tmp, final = dir .. "/." .. name, dir .. "/" .. name
        local f = io.open(tmp, "w")
        if not f then break end
        -- kind/key/hash ride along for id-keyed artwork. Without them this
        -- process wrote the files but nothing recorded them in the index, and
        -- the staleness check for those kinds is the INDEX, not the file -- so
        -- every cover past THUMB_SYNC was re-fetched on every draw, forever.
        for j = i, math.min(i + Util.PREFETCH_MAX - 1, #list) do
            local pd = list[j]
            f:write(pd.url, "\t", pd.path, "\t", kind or "", "\t",
                    pd.art_key or "", "\t", pd.hash or "", "\n")
        end
        f:close()
        if os.rename(tmp, final) then n = n + 1 else os.remove(tmp) end
    end
    if n == 0 then return "spoolfail" end
    local pidf = P.tmp .. "/spoot_art_prefetch.pid"
    if Util.pidfile_owner_alive(pidf, "--prefetch-art-batch") then return "spooled" end
    Util.spawn_self({"--prefetch-art-batch"}, nil, pidf)
    return "spawned"
end

-- `opts` is forwarded to Util.fetch_art, whose defaults (3 attempts, 5s connect,
-- 10s max, 1s between) are right for art the user ASKED to see and wrong for art
-- that is merely a menu backdrop. Dropping the passthrough is what let the two
-- decorative callers inherit the full retry budget: a cover that is not cached
-- yet froze the action menu for 17s with the network down, and up to ~32s if
-- connections opened but stalled -- silently, for a background image. Those two
-- pass Util.ART_DECOR below; view_art and --notify keep the defaults.
local function ensure_art(art_url, subdir, opts)
    if not art_url or #art_url == 0 then return nil end
    local hash = art_url:match("/image/([%w]+)") or art_url:match("/([%w_%-]+)$")
    if not hash then return nil end
    ensure_cache()
    local art_path
    if subdir then
        os.execute("mkdir -p " .. shell_quote(P.art .. "/" .. subdir))
        art_path = P.art .. "/" .. subdir .. "/" .. hash .. ".jpg"
    else
        art_path = P.art .. "/" .. hash .. ".jpg"
    end
    if Util._art_valid_file(art_path) then return art_path end
    os.remove(art_path)
    return Util.fetch_art(art_url, art_path, opts)
end

-- ASSETS shipped with the themes, for rows that will never have real artwork.
-- 300x300 like Spotify's covers, so they scale identically in the 150px grid.
Util.ART_NONE     = P.assets .. "/noart.png"     -- album with no cover
Util.ART_PLAYLIST = P.assets .. "/playlist.png"  -- playlist with no cover
Util.ART_NEW      = P.assets .. "/new.png"       -- the Create New Playlist tile
-- Tiles that open a PICKER rather than a shelf, so no object's cover can stand
-- for them and they would otherwise wear the "no cover" mark. ART_GENRE serves
-- Collections' Discover by Genre AND the Podcasts grid's Search tile -- both are
-- "type a name and see what comes back" -- while ART_CATEGORIES serves
-- Collections' Categories. A dedicated search asset would suit the third better
-- than the genre picture it borrows.
Util.ART_GENRE      = P.assets .. "/genre.png"
Util.ART_CATEGORIES = P.assets .. "/categories.png"

-- Playlist covers are cached ONE FILE PER PLAYLIST, keyed by playlist id rather
-- than by art hash. Spotify regenerates these constantly -- weekly editorial
-- refreshes, mosaics rebuilding as tracks change -- and a hash-named file would
-- leave the superseded cover behind every time. Here the path never varies, so
-- refetching overwrites: the eviction and the replacement are the same
-- operation, and an orphan cannot exist. No TTL is involved; the index below is
-- what detects a change.
--
-- Returns the path to use as the row's icon, always non-nil: the shipped
-- placeholder when the playlist has no cover.
-- Directory list for ensure_cache's single mkdir, so every kind's cache exists
-- without a fork per draw.
function Util.art_kind_dirs()
    local out = ""
    for _, k in pairs(P.art_kinds) do
        out = out .. " " .. shell_quote(k.dir)
        if k.highres then out = out .. " " .. shell_quote(k.highres) end
    end
    return out
end

function Util.art_index(kind)
    Util._art_idx = Util._art_idx or {}
    if not Util._art_idx[kind] then
        Util._art_idx[kind] = disk_get(P.art_kinds[kind].index) or {}
    end
    return Util._art_idx[kind]
end

-- Forces the next Util.art_index to re-read from disk. The detached prefetcher
-- records ITS covers in another process, so a copy loaded at startup goes stale
-- the moment one is spawned -- and a stale copy reports cached artwork as
-- missing, which spends a draw's whole synchronous budget re-downloading files
-- that are already on disk and leaves everything past it wearing a placeholder.
function Util.art_index_drop(kind)
    if Util._art_idx then Util._art_idx[kind] = nil end
end

-- The ONE writer. Every write used to be `disk_set(cfg.index, idx)` from a copy
-- this process read at some earlier point, which is a whole-file overwrite: a
-- prefetcher's entries, written in between, were silently erased and its covers
-- re-fetched forever after. Re-reading and merging here means the last writer
-- adds to the file instead of replacing it.
--
-- `updates` maps key -> hash string, or key -> false to delete.
function Util.art_index_put(kind, updates)
    local cfg = P.art_kinds[kind]
    if not cfg then return end
    local idx = disk_get(cfg.index) or {}
    for k, v in pairs(updates) do
        if v == false then idx[k] = nil else idx[k] = v end
    end
    disk_set(cfg.index, idx)
    Util._art_idx = Util._art_idx or {}
    Util._art_idx[kind] = idx
end

-- Artwork cached BY ID rather than by art hash, for objects whose image Spotify
-- replaces in place: playlists (weekly editorial refreshes, mosaics rebuilding
-- as tracks change) and categories. A hash-named file would strand the old cover
-- every time. Here the path never varies, so refetching overwrites -- eviction
-- and replacement are one operation and an orphan cannot exist. No TTL; the
-- index of id -> art hash is what detects a change.
--
-- `hi` asks for the high-resolution rendition, cached in the kind's own
-- subdirectory. Returns a path to use, always non-nil; the caller supplies the
-- placeholder for "this object has no artwork".
-- How long a piece of artwork we could not fetch stays written off. Long enough
-- that a dead cover costs nothing across a session; short enough that a CDN
-- having a bad afternoon heals by itself.
-- On Util, not a local: the chunk body is one function at Lua's 200-local cap.
Util.ART_FAIL_TTL = 6 * 3600

-- An index entry is either the art hash we successfully cached (a string, as it
-- always was) or a record of a fetch that failed (a table). Old index files hold
-- only strings, so they load unchanged.
function Util.art_failed(entry, hash)
    return type(entry) == "table" and entry.f == hash
        and (os.time() - (entry.t or 0)) < Util.ART_FAIL_TTL
end

function Util.keyed_art(kind, item, fetch, hi, fallback)
    local cfg = P.art_kinds[kind]
    if not (cfg and item and item.id) then return fallback end
    local dir  = (hi and cfg.highres) or cfg.dir
    local idx  = Util.art_index(kind)
    local key  = hi and (item.id .. ":hi") or item.id
    local path = dir .. "/" .. item.id .. ".jpg"
    local imgs = item[cfg.field] or {}
    local url  = imgs[1] and imgs[1].url
    local hash = Util.art_hash(url)

    if not hash then
        -- "No url" means two completely different things, and conflating them
        -- was destructive. `art_unknown` says the CALLER could not resolve this
        -- row's source right now -- a tile grid reading its shelves under
        -- Util.cache_only, where a shelf simply is not on disk yet. That is not
        -- evidence the artwork went away, and treating it as such unlinked every
        -- cover in the grid on each cold draw, so the warmer re-downloaded all
        -- of them and the next cold draw deleted them again.
        --
        -- For a row-keyed kind the file at <dir>/<key>.jpg IS that row's
        -- artwork; the url only ever decides whether it has gone stale. With no
        -- url to judge by, serving what we have beats drawing a placeholder over
        -- a perfectly good cover.
        if item.art_unknown then
            if idx[key] and Util._art_valid_file(path) then return path end
            return fallback
        end
        -- Artwork removed upstream: drop ours rather than serving a stale one.
        if idx[key] then
            os.remove(path)
            Util.art_index_put(kind, {[key] = false})
        end
        return fallback
    end
    if hi then url = Util.art_url_hi(url) end
    if idx[key] == hash and Util._art_valid_file(path) then return path end
    -- Already tried this exact artwork and it would not come down. Answering
    -- with the placeholder is the whole point: the alternative is re-requesting
    -- it on every redraw of the list, which is what made a single dead cover
    -- cost seconds per menu.
    if Util.art_failed(idx[key], hash) then return fallback end
    if not fetch then return path, url, hash, key end  -- caller batches the fetch
    ensure_cache()   -- also creates every kind's dir
    local got = Util.fetch_art(url, path, not hi and Util.ART_DECOR or nil)
    Util.art_index_put(kind, {[key] = got and hash or {f = hash, t = os.time()}})
    return got and path or fallback
end

-- Records artwork the batch fetcher just wrote, so the index agrees with disk.
function Util.art_commit(kind, list)
    if not list or #list == 0 then return end
    local up, dirty = {}, false
    for _, e in ipairs(list) do
        if e.art_key and e.hash then
            if Util._art_valid_file(e.path) then
                up[e.art_key] = e.hash; dirty = true
            elseif e.dead then
                -- _art_batch gave up on this one for good. Recording that is
                -- what keeps the next draw from asking again.
                up[e.art_key] = {f = e.hash, t = os.time()}; dirty = true
            end
        end
    end
    if dirty then Util.art_index_put(kind, up) end
end

-- Budget for art that is only a menu backdrop: try once, give up quickly. A miss
-- costs nothing visible -- the callers already `or ""`, and Util.write_art_theme
-- strips the background-image line for an empty path -- so the menu opens
-- promptly with no backdrop instead of making the user wait for one.
Util.ART_DECOR = {attempts = 1, connect_timeout = 2, timeout = 4}

-- Unique path per call. A fixed /tmp/spoot_theme_<name>.rasi broke whenever a
-- view nested inside itself, and both callers can: a nested view_actions
-- overwrote the file and deleted it on exit, leaving the outer menu redrawing
-- against a missing -theme; a nested view_browse left the outer list wearing
-- the inner album's cover. A per-call sequence number isolates each one; the
-- startup sweep and clean_exit still glob these names.
Util._theme_seq = 0
Util.write_art_theme = function(name, art_path)
    local tmpl = Util._art_theme_tmpls[name]
    if not tmpl then
        local raw = read_file(P.dir .. "/style/" .. name .. ".rasi") or ""
        tmpl = raw:gsub('@import "ZENON"', '@import "' .. P.dir .. '/style/ZENON"')
        Util._art_theme_tmpls[name] = tmpl
    end
    Util._theme_seq = Util._theme_seq + 1
    local tmp = P.tmp .. "/spoot_theme_" .. name .. "_" .. Util._theme_seq .. ".rasi"
    -- Function replacement, not a string: gsub treats % specially in a
    -- replacement STRING, so a path containing one raised "invalid use of '%' in
    -- replacement string" and took the menu down with it. Latent before, more
    -- reachable now that art_path derives from $XDG_CACHE_HOME (via P.art) and,
    -- for the noart.png fallback, from $PWD (via P.dir). A function replacement
    -- is taken literally.
    local rasi = tmpl:gsub("%%s", function() return art_path or "" end)
    if not art_path or art_path == "" then
        rasi = rasi:gsub("background%-image:%s*url%(\"\",%s*both%);", "")
    end
    local f = io.open(tmp, "w")
    if f then f:write(rasi); f:close() end
    return tmp
end

-- Wall clock, at 10ms resolution, without a fork. os.clock measures CPU, which
-- is exactly the wrong thing here -- a draw that spent 900ms waiting on the CDN
-- burns almost none of it, and that is the number worth recording. os.time only
-- has whole seconds. /proc/uptime has neither problem and costs one read.
function Util.mono()
    local f = io.open("/proc/uptime", "r")
    if not f then return nil end
    local s = f:read(32) or ""
    f:close()
    return tonumber(s:match("^([%d%.]+)"))
end

-- THUMBNAIL DRAW LOG
--
-- One line per grid draw, because a grid cannot be examined after the fact: rofi
-- is handed its entries once, at exec, and scrolls inside its own process, so a
-- tile that came up as a placeholder stays one for the life of that window no
-- matter what lands on disk a moment later. What a draw DECIDED is therefore the
-- only evidence there is, and it has to be recorded as the draw happens.
--
-- Fields, in order (see Util.thumb_report, which is the reader):
--   ts kind view items cursor cached missing sync_try sync_ok sync_fail
--   tail tail_action placeholders invalid ms
Util.THUMB_FIELDS = {"ts", "kind", "view", "items", "cursor", "cached", "missing",
                     "sync_try", "sync_ok", "sync_fail", "tail", "tail_action",
                     "placeholders", "invalid", "ms"}

function Util.thumb_log(rec)
    local out = {}
    for i, k in ipairs(Util.THUMB_FIELDS) do
        local v = rec[k]
        if v == nil then v = "-" end
        -- Tabs are the separator and a view key is arbitrary text.
        out[i] = tostring(v):gsub("[\t\n]", " ")
    end
    local f = io.open(P.thumb_log, "a")
    if not f then return end
    f:write(table.concat(out, "\t"), "\n")
    local size = f:seek("end")
    f:close()
    if not size or size <= P.thumb_log_max then return end
    -- Halve it rather than trimming one line per draw: the rewrite then happens
    -- once every few thousand draws instead of on every one past the cap.
    local raw = read_file(P.thumb_log)
    if not raw then return end
    local lines = {}
    for line in raw:gmatch("[^\n]+") do lines[#lines+1] = line end
    local keep = {}
    for i = math.floor(#lines / 2) + 1, #lines do keep[#keep+1] = lines[i] end
    write_file(P.thumb_log, table.concat(keep, "\n") .. "\n")
end

-- Album-list thumbnails, reusing the shared 300px art cache (seed "1e02").
-- Fetches the first THUMB_SYNC missing covers, detaches the rest, then appends
-- "\0icon\x1f<path>" to every row with a path.
--
-- Three tile states, once one indistinguishable black square:
--   * not fetched yet -- path emitted anyway so rofi loads it on scroll.
--   * fetch failed    -- stays in `missing` until a stat finds it, and that set
--     is re-statted every call, so the next redraw retries.
--   * no artwork      -- pointed at style/assets/noart.png rather than left iconless.
--
-- url -> path is memoised per list: this reruns on every redraw, and re-deriving
-- it cost 1500 gsubs + 1500 stats per keypress on a large discography. Only
-- covers still MISSING are re-statted, which preserves the retry above.
Util._thumb_memo = nil
-- Resolves ONE item to the icon path it should show, plus the url/hash needed if
-- that file still has to be fetched. This is the ONLY thing that differs between
-- an album grid and a playlist grid -- the memo, the re-stat of missing covers,
-- the sync/prefetch split and the \0icon decoration below are all shared, which
-- is why this is a parameter rather than a second copy of the whole function.
local function thumb_resolve(it, kind)
    -- Kinds whose artwork Spotify replaces in place are cached by id; the rest
    -- are cached by art hash, below.
    if P.art_kinds[kind] then
        -- A row that is not a playlist at all: view_playlists puts "Create New
        -- Playlist" above the real ones, so without a sentinel entries and items
        -- sit one apart and every tile shows its neighbour's cover.
        if it.__new then return Util.ART_NEW end
        -- A row may name its own stand-in: the Collections genre tile has no
        -- object behind it and would otherwise wear the "no cover" mark, which
        -- reads as a failure rather than as what it is.
        local fb = it.art_fallback
                or (kind == "playlist" and Util.ART_PLAYLIST or Util.ART_NONE)
        local path, url, hash, key = Util.keyed_art(kind, it, false, false, fb)
        if not url then return path end       -- already cached, or has no artwork
        return path, url, hash, key
    end
    local imgs = it.images or (it.album and it.album.images) or {}
    local url = imgs[1] and imgs[1].url
    if url and #url > 0 then
        url = Util.art_url(url, "1e02")
        local hash = Util.art_hash(url)
        if hash and #hash > 0 then return P.art .. "/" .. hash .. ".jpg", url end
    end
    -- No usable art URL. Deliberately returns no url, so the caller does not mark
    -- it missing: there is nothing to fetch, and the placeholder ships with the
    -- themes so it is always present and costs no network.
    return Util.ART_NONE
end

-- `focus` is the row the menu is about to open on (0-based, same convention as
-- rofi_dmenu's `sel`). Covers are fetched outwards from there rather than from
-- the top of the list, because those are the ones rofi is about to render -- see
-- the ordering below. `view` only names the draw in the log.
Util.album_thumbs = function(entries, items, kind, focus, view)
    items = items or {}
    kind = kind or "album"
    local n = #items
    local t_start = Util.mono()
    -- The prefetcher records ITS covers from another process, so a copy of the
    -- index read earlier in this one is stale the moment a worker has run --
    -- and a stale index reports cached artwork as missing, which is how a draw
    -- spends its whole synchronous budget re-downloading files that are already
    -- on disk. Re-read per draw: 51 KB / 676 entries decodes in well under the
    -- millisecond a draw of this size already costs.
    if P.art_kinds[kind] then Util.art_index_drop(kind) end
    -- Keyed on identity AND shape: Saved Albums' "Remove from Library" mutates
    -- this very table in place, and a memo keyed on identity alone would then
    -- hand every row below the removal the previous row's cover. `kind` is in the
    -- key too, so an album grid and a playlist grid cannot share a memo.
    local memo = Util._thumb_memo
    if not (memo and memo.items == items and memo.n == n and memo.kind == kind
            and memo.first == items[1] and memo.last == items[n]) then
        memo = {items = items, n = n, kind = kind, first = items[1], last = items[n],
                paths = {}, urls = {}, hashes = {}, ids = {}, missing = {}}
        for i, it in ipairs(items) do
            local path, url, hash, pid = thumb_resolve(it, kind)
            memo.paths[i] = path
            if url then
                memo.urls[i]   = url
                memo.hashes[i] = hash
                memo.ids[i]    = pid
                -- Kept as an ASCENDING array, not a set: the stat pass below
                -- walks it in order and the reordering that follows needs a
                -- stable sequence to work from. A pairs() walk would hand it
                -- 60 covers at random.
                memo.missing[#memo.missing + 1] = i
            end
        end
        Util._thumb_memo = memo
    end
    local paths = memo.paths
    local pending, still = {}, {}
    local invalid = 0
    for _, i in ipairs(memo.missing) do
        local p = paths[i]
        local ok
        if P.art_kinds[kind] then
            -- Existence proves NOTHING here. These files are named by object id,
            -- so artwork Spotify has since replaced still sits at exactly the
            -- path we would write to -- statting it would report "present" and
            -- the new art would never be fetched, defeating the whole point. The
            -- index is the authority: current only if it agrees with the hash the
            -- API just reported. This also lets a row drop out of `missing` once
            -- Util.art_commit records it.
            ok = Util._art_valid_file(p) and Util.art_index(kind)[memo.ids[i]] == memo.hashes[i]
        else
            -- Album paths are named by art hash, so a changed cover is a
            -- different path and existence really does mean up to date -- but
            -- only for a file that is actually an image. This used to accept any
            -- non-empty file, which is the one failure F5 could never repair: a
            -- truncated or half-written cover read as cached, its real path went
            -- to rofi, the decode failed, and because spoot believed that cover
            -- was fine it was never re-fetched. Validating it here puts it back
            -- in `pending` instead, where the next draw replaces it.
            ok = Util._art_valid_file(p)
            if not ok then
                local fh = io.open(p, "r")
                if fh then
                    local sz = fh:seek("end")
                    fh:close()
                    -- Present, non-empty, and not a drawable image: the exact
                    -- case above, counted so the log can name it.
                    if sz and sz > 0 then invalid = invalid + 1 end
                end
            end
        end
        if not ok then
            still[#still+1] = i
            -- art_key/hash ride along only for id-keyed grids; _art_batch
            -- ignores them, and they are what lets the index be updated once the
            -- file actually lands (see Util.art_commit below).
            pending[#pending+1] = { url = memo.urls[i], path = p, row = i,
                                    art_key = memo.ids[i], hash = memo.hashes[i] }
        end
    end
    memo.missing = still
    -- Every row that has no file right now. rofi must not be pointed at any of
    -- these (see the decoration loop). Rows fetched successfully just below drop
    -- out of it.
    local blank = {}
    for _, pd in ipairs(pending) do blank[pd.row] = true end
    local sync_try, sync_ok, tail_n, tail_action = 0, 0, 0, "none"
    if #pending > 0 then
        ensure_cache()
        -- Fetch OUTWARDS FROM THE CURSOR, not from row 1. `pending` is in row
        -- order, so the synchronous head used to be rows 1-60 no matter where the
        -- menu was about to open -- and a grid reopened at row 300, which pos_key
        -- restores routinely, therefore left every visible tile to the background
        -- prefetch. Forward first because that is the direction people scroll,
        -- then upwards, nearest row first in both directions. Same number of
        -- covers, the ones actually about to be drawn.
        local at = math.max(0, math.min(tonumber(focus) or 0, n - 1)) + 1
        local ordered, above = {}, {}
        for _, pd in ipairs(pending) do
            if pd.row >= at then ordered[#ordered+1] = pd else above[#above+1] = pd end
        end
        for j = #above, 1, -1 do ordered[#ordered+1] = above[j] end
        local head, tail = {}, {}
        for i, pd in ipairs(ordered) do
            if i <= THUMB_SYNC then head[#head+1] = pd else tail[#tail+1] = pd end
        end
        Util._art_batch(head)
        -- Only the synchronous half can be committed here; the detached prefetch
        -- writes its files in another process, so those covers are recorded the
        -- next time this list is drawn and the stat above finds them present.
        if P.art_kinds[kind] then Util.art_commit(kind, head) end
        sync_try, tail_n = #head, #tail
        for _, pd in ipairs(head) do
            if pd.ok then blank[pd.row] = nil; sync_ok = sync_ok + 1 end
        end
        if #tail > 0 then tail_action = Util.spawn_art_prefetch(tail, kind) end
    end
    -- NEVER name a file that is not on disk yet. rofi's icon fetcher caches by
    -- path with no eviction, no invalidation and no retry anywhere in it: one
    -- failed load stores a null surface against that path and every later render
    -- of the row returns it, so the tile stays blank for the life of the window.
    -- Proven directly -- a tile whose file appeared one second after the menu
    -- opened was still empty two seconds later. That is the whole bug, including
    -- the case where the artwork IS cached: skimming fast reaches rows the
    -- prefetch has not written, rofi writes those paths off, and the covers that
    -- land a moment later are never looked at again. Only a NEW rofi has a clean
    -- icon cache, which is why refreshing was the only thing that worked.
    --
    -- So a row without a file yet gets the placeholder, which always exists and
    -- always loads. The tile is then a deliberate render rather than a hole, and
    -- nothing is poisoned: the next draw upgrades it to the real cover.
    local ph = kind == "playlist" and Util.ART_PLAYLIST or Util.ART_NONE
    local placeholders = 0
    for i, e in ipairs(entries or {}) do
        local p = paths[i]
        if p then
            if blank[i] then p = ph; placeholders = placeholders + 1 end
            -- Replace rather than skip. The old guard froze the FIRST path onto
            -- the entry forever, which with placeholders in play would strand a
            -- row on one permanently -- the redraw could never promote it.
            -- \0icon is the only field appended to a row, and always last.
            local cut = e:find("\0", 1, true)
            entries[i] = (cut and e:sub(1, cut - 1) or e) .. "\0icon\x1f" .. p
        end
    end
    -- What this draw decided, while it is still knowable. See Util.thumb_log.
    local t_end = Util.mono()
    Util.thumb_log({
        ts = os.time(), kind = kind, view = view or "-", items = n,
        cursor = tonumber(focus) or 0,
        cached = n - #pending, missing = #pending,
        sync_try = sync_try, sync_ok = sync_ok, sync_fail = sync_try - sync_ok,
        tail = tail_n, tail_action = tail_action,
        placeholders = placeholders, invalid = invalid,
        ms = (t_start and t_end) and math.floor((t_end - t_start) * 1000 + 0.5) or "-",
    })
end

-- SPOTIFYD MANAGEMENT

P.device_ttl = 600

-- Forget the cached device so the next play re-resolves it. Called when the
-- daemons are restarted or when Spotify rejects the device we had.
function Util.bust_device()
    mem_bust("spotifyd_device")
    disk_bust(P.device)
end

-- Disk-backed with a TTL: mem_* dies with the process, so the first play of
-- every launch paid a ~300ms /me/player/devices round trip. bust_device covers
-- staleness. The old supports_volume flag is gone -- nothing read it back, and
-- volume goes through playerctl, not the device API. Reading only saved.id
-- means an older device.json carrying `vol` still loads.
local function get_spotifyd_device()
    local cached = mem_get("spotifyd_device")
    if cached then return cached end
    local saved = disk_get(P.device, P.device_ttl)
    if type(saved) == "table" and saved.id then
        mem_set("spotifyd_device", saved.id, P.device_ttl)
        return saved.id
    end
    local token = get_token()
    if not token then return nil end
    local d = safe_decode(shell("curl -s --max-time 3 -H " .. shell_quote("Authorization: Bearer " .. token) .. " 'https://api.spotify.com/v1/me/player/devices'"))
    if not d or not d.devices then return nil end
    local dev_id = nil
    for _, dev in ipairs(d.devices) do
        if dev.name and dev.name:lower():find("spoot") then dev_id = dev.id; break end
    end
    if not dev_id then
        for _, dev in ipairs(d.devices) do
            if dev.is_active then dev_id = dev.id; break end
        end
    end
    if not dev_id and #d.devices > 0 then dev_id = d.devices[1].id end
    if dev_id then
        mem_set("spotifyd_device", dev_id, P.device_ttl)
        disk_set(P.device, {id = dev_id})
    end
    return dev_id
end

-- Starts spotifyd if needed and returns immediately. It used to poll for up to
-- 4.5s here, which froze the menu before it could even draw; the device is
-- resolved lazily at play time anyway, so waiting bought nothing.
local function ensure_spotifyd()
    local pid = trim(shell("pgrep -x spotifyd 2>/dev/null") or "")
    if pid == "" then
        os.execute("spotifyd --no-daemon --device-name spoot --backend pulseaudio --use-mpris --volume-normalisation --initial-volume " .. get_saved_volume() .. " --bitrate " .. get_saved_bitrate() .. " > /dev/null 2>&1 &")
    end
end

-- DATA CACHE

local function api_get(path, params, _retry)
    local token = get_token()
    if not token then return nil end
    local url = "https://api.spotify.com/v1/" .. path
    if params then url = url .. "?" .. params end
    -- One header file per PROCESS, not per request: the contents are read only on
    -- a 429, so a paginated browse (a 1500-album discography is ~30 pages) used to
    -- mint 30 scratch files to throw away. curl truncates the file on each write,
    -- so no request can read a previous one's headers. The pid is in the name
    -- because the detached helpers (--notify, --recent-watch) run api_get
    -- concurrently with this process.
    local hdr = Util.api_hdr_path()
    local r = shell("curl -s --max-time 10 -D " .. shell_quote(hdr) .. " -w '\\n%{http_code}' -H " .. shell_quote("Authorization: Bearer " .. token) .. " " .. shell_quote(url))
    local status = tonumber(string.match(r or "", "\n(%d+)\n?$")) or 0
    local body = string.match(r or "", "^(.-)\n%d+\n?$") or r or ""
    if status == 429 then
        local hf = io.open(hdr, "r")
        local headers = hf and hf:read("*a") or ""
        if hf then hf:close() end
        local secs = string.match(headers, "[Rr]etry%-[Aa]fter:%s*(%d+)") or "30"
        local cool = tonumber((read_file(P.tmp .. "/spoot_rate_cooldown") or ""):match("%d+"))
        if not Util.detached then
            Util.secure_write(P.tmp .. "/spoot_rate_cooldown", os.time() + math.min(tonumber(secs), 5) + 5)
        end
        if not (cool and os.time() < cool) and not Util.detached then
            rofi_message("Spotify API rate limit reached (429). Retry after " .. secs .. "s.")
        end
        return nil
    end
    if status == 401 then
        if not Util.detached then
            rofi_message("Spotify token expired (401). Restart rofi to refresh.")
        end
        return nil
    end
    if status >= 500 and not _retry then
        os.execute("sleep 1")
        return api_get(path, params, true)
    end
    if status >= 400 then return nil end
    -- THE availability collapse, for everything that comes off the API. See the
    -- note above Util.mark_availability for why it lives here rather than at the
    -- call sites. Also the single place that drops available_markets, so no
    -- endpoint can smuggle its ~185-entry arrays into a disk cache.
    local d = safe_decode(body)
    if d then Util.mark_availability(d) end
    return d
end

-- Offset-paginated fetch helper; any failed page returns nil so it is never
-- cached as a partial/empty list from a transient error.
Util.paged_fetch = function(path, mk_params, done, each)
    local all, offset = {}, 0
    while true do
        local d = api_get(path, mk_params(offset))
        if not d then return nil end
        local items = d.items or {}
        for _, it in ipairs(items) do
            local v = it
            if each then v = each(it) end
            if v ~= nil then all[#all+1] = v end
        end
        if done(d, items) then break end
        offset = offset + #items
    end
    return all
end

local liked_by_artist_id = nil

local function get_liked_by_artist(artist_id)
    if not liked_by_artist_id then return {} end
    return liked_by_artist_id[artist_id] or {}
end

local function load_liked_tracks_full()
    local tracks = {}
    local token = get_token()
    if not token then return nil end
    local offset = 0
    while true do
        local d = api_get("me/tracks", Util.with_market("limit=50&offset=" .. offset))
        if not d or not d.items then return nil end
        if #d.items == 0 then break end
        for _, entry in ipairs(d.items) do
            local t = entry.track
            if t then
                t.added_at = entry.added_at
                tracks[#tracks+1] = t
            end
        end
        if #d.items < 50 then break end
        offset = offset + 50
    end
    table.sort(tracks, function(a,b) return (a.added_at or "") > (b.added_at or "") end)
    return tracks
end

local function parallel_fetch_library()
    local token = get_token()
    if not token then return nil, nil, nil end
    local auth = "Authorization: Bearer " .. token
    local base = "https://api.spotify.com/v1/"
    local tmpdir = P.cache .. "/fetch_tmp"
    os.execute("rm -rf " .. shell_quote(tmpdir) .. " && mkdir -p " .. shell_quote(tmpdir))

    local ok, r1, r2, r3 = pcall(function()
    local BATCH = 5
    -- These URLs are assembled by hand rather than going through api_get, so the
    -- market has to be appended here too -- this is the path that actually
    -- rebuilds the liked cache, and without it every track comes back with no
    -- is_playable and a ~185-entry available_markets. Resolved once, up front.
    local mkt = Util.market()
    mkt = mkt and ("&market=" .. mkt) or ""

    local function fire_batch(cmds)
        if #cmds == 0 then return end
        os.execute(table.concat(cmds, " & ") .. " & wait")
    end

        local function curl_cmd(url, out)
        return string.format("curl -s --max-time 10 -H %s %s -o %s 2>/dev/null",
            shell_quote(auth), shell_quote(url), shell_quote(out))
    end

    local function page_valid(file)
        local d = safe_decode(read_file(file))
        return d and d.items and #d.items > 0
    end

    -- PHASE 1: PROBE — fetch page 0 for all three endpoints simultaneously
    fire_batch({
        curl_cmd(base .. "me/tracks?limit=50&offset=0" .. mkt, tmpdir .. "/lk_0.json"),
        curl_cmd(base .. "me/albums?limit=50&offset=0" .. mkt, tmpdir .. "/al_0.json"),
        curl_cmd(base .. "me/following?type=artist&limit=50", tmpdir .. "/ar_0.json"),
    })
    -- PHASE 2: PARSE PROBES — extract totals and page 0 data
    local lk0 = safe_decode(read_file(tmpdir .. "/lk_0.json"))
    local al0 = safe_decode(read_file(tmpdir .. "/al_0.json"))
    local ar0 = safe_decode(read_file(tmpdir .. "/ar_0.json"))

    local tracks_total = (lk0 and lk0.total) or 0
    local albums_total = (al0 and al0.total) or 0
    local tracks_pages = math.ceil(tracks_total / 50)
    local albums_pages = math.ceil(albums_total / 50)

    -- PHASE 3: BUILD COMMANDS — page 0 already fetched, queue pages 1..N-1
    local lk_cmds = {}
    local al_cmds = {}
    for i = 1, tracks_pages - 1 do
        lk_cmds[#lk_cmds+1] = curl_cmd(base .. "me/tracks?limit=50&offset=" .. (i * 50) .. mkt, tmpdir .. "/lk_" .. i .. ".json")
    end
    for i = 1, albums_pages - 1 do
        al_cmds[#al_cmds+1] = curl_cmd(base .. "me/albums?limit=50&offset=" .. (i * 50) .. mkt, tmpdir .. "/al_" .. i .. ".json")
    end

    local cmds = {}
    for _, c in ipairs(lk_cmds) do cmds[#cmds+1] = c end
    for _, c in ipairs(al_cmds) do cmds[#cmds+1] = c end

    -- PHASE 4: FIRE in batches, then retry failures sequentially
    for b = 1, #cmds, BATCH do
        local batch = {}
        for j = b, math.min(b + BATCH - 1, #cmds) do batch[#batch+1] = cmds[j] end
        fire_batch(batch)
    end

    -- RETRY: check each page file, retry failures one at a time with delay
    for i = 1, tracks_pages - 1 do
        local f = tmpdir .. "/lk_" .. i .. ".json"
        if not page_valid(f) then
            os.execute("sleep 1")
            os.execute(curl_cmd(base .. "me/tracks?limit=50&offset=" .. (i * 50) .. mkt, f))
        end
    end
    for i = 1, albums_pages - 1 do
        local f = tmpdir .. "/al_" .. i .. ".json"
        if not page_valid(f) then
            os.execute("sleep 1")
            os.execute(curl_cmd(base .. "me/albums?limit=50&offset=" .. (i * 50) .. mkt, f))
        end
    end

    -- ARTISTS: cursor-based, must be sequential via curl
    local artists = {}
    local artist_after = nil
    if ar0 and ar0.artists and ar0.artists.items and #ar0.artists.items > 0 then
        for _, a in ipairs(ar0.artists.items) do artists[#artists+1] = a end
        artist_after = ar0.artists.cursors and ar0.artists.cursors.after
    end
    while artist_after and artist_after ~= "" do
        local ar_file = tmpdir .. "/ar_" .. #artists .. ".json"
        os.execute("curl -s --max-time 10 -H " .. shell_quote(auth) .. " " ..
            shell_quote(base .. "me/following?type=artist&limit=50&after=" .. artist_after) .. " -o " ..
            shell_quote(ar_file) .. " 2>/dev/null")
        local ar_page = safe_decode(read_file(ar_file))
        if not ar_page or not ar_page.artists or not ar_page.artists.items or #ar_page.artists.items == 0 then break end
        for _, a in ipairs(ar_page.artists.items) do artists[#artists+1] = a end
        if not ar_page.artists.next then break end
        artist_after = ar_page.artists.cursors and ar_page.artists.cursors.after
    end
    table.sort(artists, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)

    -- PHASE 5: READ AND DEDUP
    local tracks = {}
    local seen_tracks = {}
    for i = 0, tracks_pages - 1 do
        local raw = read_file(tmpdir .. "/lk_" .. i .. ".json")
        local d = raw and safe_decode(raw)
        if d and d.items and #d.items > 0 then
            for _, entry in ipairs(d.items) do
                local t = entry.track
                if t and t.id and not seen_tracks[t.id] then
                    seen_tracks[t.id] = true
                    t.added_at = entry.added_at
                    tracks[#tracks+1] = t
                end
            end
        end
    end
    table.sort(tracks, function(a,b) return (a.added_at or "") > (b.added_at or "") end)

    local albums = {}
    local seen_albums = {}
    for i = 0, albums_pages - 1 do
        local raw = read_file(tmpdir .. "/al_" .. i .. ".json")
        local d = raw and safe_decode(raw)
        if d and d.items and #d.items > 0 then
            for _, e in ipairs(d.items) do
                if e.album and e.album.id and not seen_albums[e.album.id] then
                    seen_albums[e.album.id] = true
                    albums[#albums+1] = e.album
                end
            end
        end
    end
    table.sort(albums, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)

    -- A count of 0 is only a real failure if the probe itself didn't come back;
    -- a user with a genuinely empty library/collection should not be treated
    -- as a failed fetch (that used to force the slow sequential fallback on
    -- every single cache refresh for such accounts).
    local ok_tracks  = lk0 ~= nil and (#tracks >= tracks_total)
    local ok_albums  = al0 ~= nil and (#albums >= albums_total)
    local ok_artists = ar0 ~= nil and ar0.artists ~= nil
        and (#artists >= (ar0.artists.total or 0))

    os.execute("rm -rf " .. shell_quote(tmpdir))
    return
        ok_tracks and tracks or nil,
        ok_albums and albums or nil,
        ok_artists and artists or nil
    end)
    os.execute("rm -rf " .. shell_quote(tmpdir))
    if ok then return r1, r2, r3 else return nil, nil, nil end
end

-- The three library loaders below used to carry a copy each of the same memo,
-- disk envelope, TTL test and serve-the-old-list-if-the-network-failed fallback.
-- That last behaviour is now cached_fetch's `stale_ok`, so it applies to every
-- list in the file rather than to these three, and they are left holding only
-- what actually differs: how their endpoint pages.
--
-- The second return value means "this is CURRENT", which is what
-- fetch_library_with_fallback needs before it rewrites the cache: true from the
-- memo, from a fresh file, or from a fetch that worked -- false only when a
-- failed fetch fell back to an expired copy. Util.lib_sorted names the one
-- ordering both the album and the artist list use.
--
-- On Util, not a local: the chunk body is one function at Lua's 200-local cap.
function Util.lib_sorted(t)
    table.sort(t, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    return t
end

local function load_saved_albums()
    local tried, fresh = false, false
    local items = cached_fetch("saved_albums", P.albums, P.ttl, function()
        tried = true
        local out, offset = {}, 0
        while true do
            local d = api_get("me/albums", Util.with_market("limit=50&offset=" .. offset))
            if not d or not d.items then return nil end
            if #d.items == 0 then break end
            for _, e in ipairs(d.items) do
                if e.album then out[#out+1] = e.album end
            end
            if #d.items < 50 then break end
            offset = offset + 50
        end
        fresh = true
        return Util.lib_sorted(out)
    end, {stale_ok = true, revalidate = "library"})
    return items or {}, items ~= nil and (fresh or not tried)
end

local function load_followed_artists()
    local tried, fresh = false, false
    local items = cached_fetch("followed_artists", P.artists, P.ttl, function()
        tried = true
        local out, after = {}, nil
        while true do
            local p = "type=artist&limit=50"
            if after then p = p .. "&after=" .. after end
            local d = api_get("me/following", p)
            if not d or not d.artists or not d.artists.items then return nil end
            if #d.artists.items == 0 then break end
            for _, a in ipairs(d.artists.items) do out[#out+1] = a end
            if not d.artists.next then break end
            after = d.artists.cursors and d.artists.cursors.after
        end
        fresh = true
        return Util.lib_sorted(out)
    end, {stale_ok = true, revalidate = "library"})
    return items or {}, items ~= nil and (fresh or not tried)
end

-- Followed podcasts. Deliberately NOT part of the library triple above: those
-- three are fetched together by fetch_library_with_fallback and share one
-- fingerprint, so joining them would make every cold start page a section that
-- may never be opened. This follows api_get_my_playlists instead -- its own
-- cache, its own revalidator, fetched lazily the first time Podcasts is opened.
--
-- Util.paged_fetch's `each` does the me/shows envelope unwrap; it drops nil
-- returns, so a malformed row needs no guard, and any failed page answers nil
-- so a partial list is never cached.
function Util.load_saved_shows()
    return cached_fetch("saved_shows", P.shows, P.ttl, function()
        local out = Util.paged_fetch("me/shows",
            function(o) return Util.with_market("limit=50&offset=" .. o) end,
            function(d, items) return #items == 0 or not d.next end,
            function(e) return e.show end)
        if not out then return nil end
        return Util.lib_sorted(out)
    end, {stale_ok = true, revalidate = "saved_shows"})
end
Util.REVALIDATORS.saved_shows = function() return Util.load_saved_shows() end

-- Episodes you saved individually, which Spotify surfaces as "Your Episodes".
-- Same shape as the shows loader above, and equally lazy -- a podcast section
-- nobody opens should cost a cold start nothing.
--
-- NOT sorted by name: this is a save list, and the order Spotify returns it in
-- is most-recently-saved first, which is the order that means something here.
function Util.load_saved_episodes()
    return cached_fetch("saved_episodes", P.episodes, P.ttl, function()
        return Util.paged_fetch("me/episodes",
            function(o) return Util.with_market("limit=50&offset=" .. o) end,
            function(d, items) return #items == 0 or not d.next end,
            function(e) return e.episode end)
    end, {stale_ok = true, revalidate = "saved_episodes"})
end
Util.REVALIDATORS.saved_episodes = function() return Util.load_saved_episodes() end

local function fetch_library_with_fallback()
    local tracks, albums, artists = parallel_fetch_library()
    if not tracks then tracks = load_liked_tracks_full() end
    if not albums then
        local a, ok = load_saved_albums()
        albums = ok and a or nil
    end
    if not artists then
        local a, ok = load_followed_artists()
        artists = ok and a or nil
    end
    return tracks, albums, artists
end

local function build_liked_artist_index(tracks)
    liked_by_artist_id = {}
    for _, t in ipairs(tracks) do
        for _, a in ipairs(t.artists or {}) do
            if a.id then
                local arr = liked_by_artist_id[a.id]
                if not arr then arr = {}; liked_by_artist_id[a.id] = arr end
                arr[#arr+1] = t
            end
        end
    end
end

-- The LAST callers of mark_availability outside api_get, and deliberately so:
-- parallel_fetch_library assembles these from raw curl output, so they are the
-- one library path the collapse in api_get never sees. Without it
-- liked_tracks.json goes back to being 44% available_markets.
local function save_library_cache(tracks, albums, artists)
    if tracks then
        Util.mark_availability(tracks)
        mem_set("liked_tracks", tracks, P.ttl)
        build_liked_artist_index(tracks)
        Util.persist_liked(tracks)
    end
    if albums then
        Util.mark_availability(albums)
        mem_set("saved_albums", albums, P.ttl)
        disk_set(P.albums, albums)
    end
    if artists then
        mem_set("followed_artists", artists, P.ttl)
        disk_set(P.artists, artists)
    end
end

local function load_liked_tracks()
    local fresh = false
    local tracks = cached_fetch("liked_tracks", P.liked, P.ttl, function()
        local t = load_liked_tracks_full()
        if not t then return nil end
        -- cached_fetch writes the track file itself; only the derived id list is
        -- this function's to keep in step.
        Util.write_liked_ids(t)
        fresh = true
        return t
    end, {stale_ok = true, revalidate = "library"})
    -- The `or {}` this used to end on is gone on purpose: it turned "not cached"
    -- into "empty", and Util.shelf_head has to tell those apart to know whether
    -- the Liked Tracks row is genuinely empty or merely unread. The two callers
    -- that need a table now say so themselves.
    -- The artist index is per-process, so it has to exist before the first return
    -- of a run -- and be rebuilt when the list underneath it just changed.
    if fresh or not liked_by_artist_id then build_liked_artist_index(tracks or {}) end
    return tracks
end

-- LIBRARY FRESHNESS
--
-- The library is the one cache where "has this changed?" is enormously cheaper
-- than "give it to me again": three ~1 KB requests against the ~35 pages
-- parallel_fetch_library walks for a 1578-track library. Each list's head -- its
-- total, plus the newest entry's id and date -- is the fingerprint. Asking is so
-- cheap that P.ttl can be minutes instead of half a day, which is the whole
-- point: staleness is now bounded by how often you open spoot, not by a number
-- picked to keep you from being blocked.
--
-- Answers nil when the probe itself failed, which is NOT the same as "unchanged"
-- and must never be stored: an offline probe would otherwise write a fingerprint
-- that matches nothing and force a re-page on the next run.
function Util.lib_probe(kind)
    if kind == "artists" then
        local d = api_get("me/following", "type=artist&limit=1")
        local a = d and d.artists
        if not a then return nil end
        local first = a.items and a.items[1]
        return (a.total or -1) .. ":" .. ((first and first.id) or "")
    end
    local d = api_get(kind == "liked" and "me/tracks" or "me/albums", "limit=1")
    if not d or not d.items then return nil end
    local e = d.items[1]
    local obj = e and (e.track or e.album)
    return (d.total or -1) .. ":" .. ((obj and obj.id) or "") .. ":" .. ((e and e.added_at) or "")
end

-- Records what the library looked like at the moment it was fully re-paged, so
-- the next probe has something to compare against. Every path that rebuilds all
-- three caches calls this -- the revalidator below, the cold build in
-- init_library, System > Refresh Library -- because a full refresh that left no
-- fingerprint would be re-paged again by the very next background check.
--
-- `fp` is the probe result the caller already has, if any; the revalidator does,
-- the other two do not and pay three small requests here. An incomplete probe
-- writes nothing: no record means one wasted re-page later, a wrong record means
-- edits that never show up.
function Util.lib_fp_write(fp)
    fp = fp or {}
    for _, kind in ipairs({"liked", "albums", "artists"}) do
        if not fp[kind] then fp[kind] = Util.lib_probe(kind) end
        if not fp[kind] then return end
    end
    fp.full_at = os.time()
    disk_set(P.lib_fp, fp)
end

-- The one definition of "re-page the library and write down what it looked
-- like". The background revalidator below and System > Refresh Library both ran
-- byte-identical copies of this. `fp` is the fingerprint the caller already
-- holds, if any -- the revalidator has one from its probes, a manual refresh
-- does not and lets Util.lib_fp_write take its own.
function Util.rebuild_library(fp)
    local tracks, albums, artists = fetch_library_with_fallback()
    -- Reporting success unconditionally announced it even when all three
    -- fetches had failed and save_library_cache had written nothing.
    if not tracks then return false end
    save_library_cache(tracks, albums, artists)
    Util.lib_fp_write(fp)
    return true
end

Util.REVALIDATORS.library = function()
    local fp = disk_get(P.lib_fp) or {}
    local now = {}
    for _, kind in ipairs({"liked", "albums", "artists"}) do
        local v = Util.lib_probe(kind)
        -- One failed probe and the whole run stands down. Refreshing on partial
        -- information would either re-page a library that never moved or, worse,
        -- record a fingerprint for a list we did not actually check.
        if not v then return end
        now[kind] = v
    end
    local changed = now.liked ~= fp.liked or now.albums ~= fp.albums
                 or now.artists ~= fp.artists
                 or os.time() - (tonumber(fp.full_at) or 0) >= P.ttl_lib_max
    if not changed then
        -- Nothing moved: make the three caches read as current without rewriting
        -- them. A touch that cannot be made (an envelope this cannot parse) is
        -- treated as a reason to do the real work rather than to guess.
        if Util.cache_touch(P.liked) and Util.cache_touch(P.albums)
           and Util.cache_touch(P.artists) then
            return
        end
    end
    Util.rebuild_library(now)
end

-- PLAYBACK STATE

local inv_playback  -- forward declaration

get_playback = function()
    if os.time() - last_playback < 5 then return end
    -- me/player takes a market too, so the now-playing item arrives carrying
    -- is_playable; api_get collapses it on the way out, so now_track.json never
    -- persists the field and anything downstream that reads current_track --
    -- record_recent_play included -- sees the same shape every other track
    -- source produces.
    -- additional_types is NOT optional. Without it Spotify answers with
    -- item: null whenever an episode is playing, which the nil branch below
    -- reads as spotifyd having dropped out -- and recover_playback then starts
    -- a TRACK over the podcast you are listening to. Every me/player read in
    -- this file carries it for that reason.
    local d = api_get("me/player", Util.with_market("additional_types=episode"))
    last_playback = os.time()
    if not d or not d.item then
        local cool = tonumber((read_file(P.tmp .. "/spoot_rate_cooldown") or ""):match("%d+"))
        if cool and os.time() < cool then return end
        local recent = P.recent_cmd_at and (os.time() - P.recent_cmd_at < 15)
        if not recent and not Util.recovering and queue_tracks and #queue_tracks > 0 then
            Util.recovering = true
            local ok = recover_playback(0, true)
            Util.recovering = false
            if ok then return end
        end
        if not recent then inv_playback() end
        return
    end
    current_track = d.item
    current_id    = d.item.id
    is_playing    = d.is_playing == true
    write_file(P.now_track, json.encode({ item = d.item, playing = is_playing }))
    if os.time() - _local_toggle_time > 5 then
        is_shuffle    = d.shuffle_state == true
        repeat_state  = d.repeat_state or "off"
        write_file(P.state, json.encode({repeat_state=repeat_state, shuffle=is_shuffle}))
    end
end

inv_playback = function()
    current_track = nil; current_id = nil; previous_id = nil; is_playing = false
end

function Util.fast_now_track()
    local now  = safe_decode(read_file(P.now))
    local rich = safe_decode(read_file(P.now_track))
    if not (now and now.id and rich and rich.item and rich.item.id == now.id) then return false end
    current_track = rich.item
    current_id    = rich.item.id
    -- Ask the player, not the cache. now.json's `playing` is sampled once per
    -- track (process_snap early-returns on pause/resume, whose MPRIS events
    -- carry unchanged metadata), so it goes stale the moment you pause.
    -- playerctl status is a local D-Bus call, no network, and always right.
    -- The cached fields remain as fallback when playerctl is unavailable.
    local st = Util.playerctl_status()
    if st == "Playing" then
        is_playing = true
    elseif st == "Paused" or st == "Stopped" then
        is_playing = false
    elseif rich.playing ~= nil then
        -- Was `rich.playing ~= nil and rich.playing == true or now.playing`, which
        -- parses as `(rich.playing ~= nil and rich.playing == true) or now.playing`
        -- -- so an explicit `playing = false` fell through to the stale snapshot.
        is_playing = rich.playing == true
    else
        is_playing = now.playing == true
    end
    return true
end

-- Cheap refresh for any menu that renders now-playing state. fast_now_track is
-- two file reads plus a local playerctl call; get_playback is a ~300ms me/player
-- round trip that self-throttles to once per 5s, so this is safe to call on
-- every menu entry.
function Util.sync_now()
    -- Right after do_play the locally patched globals are the ONLY correct
    -- source: spotifyd needs a moment to pick the track up, so now.json still
    -- names the previous one and me/player can still answer with it too.
    -- Syncing inside that window would drag the ▶ marker back to the old track.
    if P.recent_cmd_at and os.time() - P.recent_cmd_at < 5 then return end
    if not Util.fast_now_track() then get_playback() end
end

open_url = function(url)
    local kind, id = parse_spotify_url(url)
    if not kind then rofi_message("No valid Spotify web link detected"); return end
    if kind == "track" then
        local d = api_get("tracks/" .. id, Util.with_market())
        if d then view_actions(d)
        else rofi_message("Track not found") end
    elseif kind == "album" then
        local d = api_get("albums/" .. id, Util.with_market())
        if d then browse_album(id, (d.name or "Album") .. album_suffix(d))
        else rofi_message("Album not found") end
    elseif kind == "artist" then
        local d = api_get("artists/" .. id)
        if d then view_artist({id=d.id, name=d.name or "Artist"})
        else rofi_message("Artist not found") end
    elseif kind == "playlist" then
        local d = api_get("playlists/" .. id)
        if d then
            Util.open_playlist(d)
            if jump_to_track_pending then return end
        else rofi_message("Playlist not found") end
    elseif kind == "show" then
        -- Util.open_show does its own fetch and reports its own failures, so
        -- unlike the branches above there is nothing to look up first.
        Util.open_show(id)
        if jump_to_track_pending then return end
    elseif kind == "episode" then
        local d = api_get("episodes/" .. id, Util.with_market())
        -- Straight to view_actions, whose type dispatch sends it to the episode
        -- menu -- the same route a pasted track URL takes.
        if d then view_actions(d)
        else rofi_message("Episode not found") end
    end
end

-- RECENTLY PLAYED
--
-- Write-through on every record so the always-on --recent-watch process and
-- interactive sessions can each read-modify-write the file safely.
--
-- Local on purpose, and briefly replaced by Spotify's own
-- me/player/recently-played before being put back. That endpoint answers with an
-- EMPTY list for this account: playback goes through spotifyd/librespot, and
-- librespot does not report plays to Spotify's listening history. The remote
-- list is authoritative for every other client and useless for this one, which
-- is the whole reason this recorder exists.

-- Empty, NOT disk_get: this runs at chunk load, so every process paid for it --
-- including --notify, which the daemon spawns on every single track change, and
-- which never touches this list. Both real readers (record_recent_play,
-- view_recently_played) call Util.recent_reload() first, so the loaded value was
-- always overwritten before anything could see it. Kept as {} rather than nil so
-- the non-nil invariant holds for any future reader that forgets to reload.
local recent_tracks = {}

function Util.recent_reload()
    recent_tracks = disk_get(P.recent) or {}
end

local function record_recent_play(track)
    if not track or not track.id then return end
    Util.recent_reload()
    for i = #recent_tracks, 1, -1 do
        if recent_tracks[i].id == track.id then
            table.remove(recent_tracks, i)
        end
    end
    -- Every caller feeds this a track that came off me/player through api_get,
    -- which already applied the availability collapse, so there is nothing to do
    -- here -- and nothing that would re-walk all 100 entries on every play.
    table.insert(recent_tracks, 1, track)
    while #recent_tracks > 100 do
        table.remove(recent_tracks)
    end
    disk_set(P.recent, recent_tracks)
end

-- DISPLAY HELPERS

-- The two marks every list puts on the row that is PLAYING: the transport glyph
-- in front of it, and green around the whole thing. Four row builders and the
-- root grid's Playback tile draw them, and they had a copy each -- so a change
-- to either had to be made in five places or the lists would disagree about
-- what "playing" looks like.
--
-- Kept as two functions rather than one because the glyph does not always lead:
-- display_album puts its single-track glyph first, on purpose, so that a fixed
-- leading column reads the same whether or not something is playing.
function Util.transport_glyph()
    return is_playing and "\u{f04b} " or "\u{f04c} "
end

function Util.now_playing(txt)
    return Util.markup('<span foreground="#b6e0a4">') .. txt .. Util.markup('</span>')
end

-- Its counterpart: the grey every menu uses to say "here, but not available" --
-- Seek with nothing playing, an unavailable track, the breadcrumb's arrows, a
-- container whose shelf is empty. The colour was spelled out at ten sites and
-- had to be kept in step by hand; one of them said `color` and the rest
-- `foreground`, which pango treats alike but a reader does not.
-- The colour itself is published too: a few callers build a span incrementally
-- (the trail hint, the queue separator) and open it without closing it on the
-- same line, so they cannot wrap a finished string.
Util.DIM = "#6a707f"
function Util.dim(txt)
    return Util.markup('<span foreground="' .. Util.DIM .. '">') .. txt .. Util.markup('</span>')
end

-- Coarse duration for list rows. Deliberately not the %d:%02d the details sheet
-- and the seek bar use: those describe a position inside a track, where seconds
-- are the unit that matters, and a 97-minute podcast rendered that way reads as
-- "97:31". Here the question is only "how long is this", so minutes, with hours
-- once there are any.
function Util.dur_short(ms)
    local secs = math.floor((ms or 0) / 1000)
    if secs <= 0 then return "" end
    if secs < 60 then return secs .. "s" end
    local mins = math.floor(secs / 60)
    if mins < 60 then return mins .. "m" end
    local h, m = math.floor(mins / 60), mins % 60
    -- "1h", not "1h 0m": the trailing zero is noise, and these sit inside a row
    -- that already carries the episode name and the podcast.
    return h .. "h" .. (m > 0 and (" " .. m .. "m") or "")
end

-- Episodes are track-like enough to share every list, formatter and playback
-- path with tracks, and different enough to need their own row: no artists, no
-- like state, no explicit glyph, and a listened-position that is the whole
-- reason anyone opens a podcast list. display_track dispatches here rather than
-- format_entries doing it, so Util.format_mixed_item's `tracks` arm gets it too
-- without a second branch.
--
-- resume_point is a snapshot from FETCH time, so it is not rendered on the row
-- that is currently playing -- the ▶ marker already says what that row is doing,
-- and a frozen "12m/58m" beside it would read as a live position that has stuck.
function Util.display_episode(item, hide_artist, hide_liked, hide_single_artist)
    local hide = hide_artist or hide_single_artist
    local playing = item.id == current_id
    local p = playing and Util.transport_glyph() or ""
    local pos, done = Util.episode_progress(item)
    local dur = Util.dur_short(item.duration_ms)
    local meta = dur
    if not playing and dur ~= "" then
        if done then meta = dur .. SEP .. "played"
        elseif pos > 0 then meta = Util.dur_short(pos) .. "/" .. dur end
    end
    local by = hide and "" or Util.subtitle(item)
    -- Icon after the transport marker, not before it: the marker says what this
    -- row is DOING and belongs in the leading column, the icon says what it IS.
    local txt = p .. Util.type_icon("episodes") .. (item.name or "Unknown")
        .. (by ~= "" and (SEP .. by) or "")
        .. (meta ~= "" and (SEP .. meta) or "")
    if playing then
        txt = Util.now_playing(txt)
    elseif item.unavail or done then
        -- Same dim as an unplayable track: one for "cannot play", one for
        -- "already heard". Both mean "skip past this one", which is what the
        -- colour is telling you.
        txt = Util.dim(txt)
    end
    return txt
end

display_track = function(item, hide_artist, hide_liked, hide_single_artist)
    if item.type == "episode" then
        return Util.display_episode(item, hide_artist, hide_liked, hide_single_artist)
    end
    local hide = hide_artist or (hide_single_artist and #(item.artists or {}) <= 1)
    local an = hide and "" or artist_names(item)
    local p  = item.id == current_id and Util.transport_glyph() or ""
    local l  = (not hide_liked) and item.id and liked[item.id] and "\u{f05d} " or ""
    local e  = item.explicit and "\u{f071} " or ""
    local txt = p .. l .. e .. (item.name or "Unknown") .. (hide and "" or SEP .. an)
    if item.id == current_id then txt = Util.now_playing(txt)
    elseif item.unavail then
        -- Not licensed in our market, so it will not play. Same dim as the
        -- disabled action rows. Never applied to the current track: if it IS
        -- playing, whatever the cache says, green wins.
        txt = Util.dim(txt)
    end
    return txt
end

-- A one-track album is a single, and selecting it plays that track rather than
-- opening a list of one (see Util.open_album). The row says so two ways:
--
--   * \u{F069F} in #fab387, ALWAYS -- a fixed colour independent of playback, so
--     "this plays straight away" is legible at a glance in any list.
--   * the ▶/⏸ marker and the green row of display_track while its track is the
--     one playing. `total_tracks` comes with every album object and the album id
--     is on the playing track, so neither costs a fetch.
local function display_album(item, show_artist)
    local body = (not show_artist and #(item.artists or {}) <= 1)
        and (item.name or "Unknown")
        or ((item.name or "Unknown") .. album_suffix(item))
    if item.total_tracks ~= 1 then return body end
    local playing = current_track and current_track.album
                    and current_track.album.id == item.id and item.id ~= nil
    -- Single glyph FIRST, transport marker after it: the glyph is what the row
    -- is, the marker is what it is doing, and a fixed leading column reads
    -- better than one that shifts right whenever playback starts.
    local mark = playing and Util.transport_glyph() or ""
    body = Util.markup('<span foreground="#fab387">') .. "\u{F069F}"
           .. Util.markup("</span>") .. " " .. mark .. body
    if playing then
        body = Util.now_playing(body)
    end
    return body
end

-- The album row builder, in one place. Four call sites had a copy of this loop,
-- and with singles now carrying live playback state the rows have to be
-- REBUILDABLE -- a marker that only appears on the next open is no marker.
-- `numbered` matches format_entries' "%2d. " prefix, which the search result
-- lists use and the standalone album lists do not. Rebuilding a search list
-- without it would silently strip the numbering off every row.
function Util.album_entries(items, show_artist, numbered)
    local out = {}
    for i, a in ipairs(items or {}) do
        local row = display_album(a, show_artist ~= false)
        out[i] = numbered and string.format("%2d. %s", i, row) or row
    end
    return out
end

local function display_artist(item)
    return item.name or "Unknown"
end

local function display_playlist(item)
    local prefix = (item.owner and item.owner.id == "spotify") and "\u{f1bc}  " or ""
    return prefix .. (item.name or "Unknown")
end

-- album_suffix resolves through Util.subtitle, which answers a show's publisher,
-- so a podcast captions itself the way an album captions itself with its artist.
--
-- The icon is carried HERE rather than by the caller, so it appears in every
-- list a show can reach: Followed Podcasts, each topic grid, a search result and
-- the show action menu's own header.
function Util.display_show(item)
    return Util.type_icon("shows") .. (item.name or "Unknown") .. album_suffix(item)
end

-- Every _stype needs an arm of its own: the fallback is display_playlist, so a
-- kind that forgets one does not misrender loudly, it renders as a playlist.
function Util.format_mixed_item(t, i)
    -- Plural, like every arm below and like the keys format_search_results
    -- stamps. The singular default this replaces matched nothing, so an
    -- unstamped row fell through to display_playlist -- a bare name with no
    -- artist, no marker and no heart.
    local st = t._stype or "tracks"
    -- Shows and episodes carry their icon inside their own display function, so
    -- that they keep it outside search too. Adding it again here would render it
    -- twice on exactly the rows that already have it.
    local pfx = (st == "shows" or st == "episodes") and "" or Util.type_icon(st)
    local body
    if st == "tracks" then body = display_track(t)
    elseif st == "albums" then body = display_album(t, true)
    elseif st == "artists" then body = display_artist(t)
    elseif st == "shows" then body = Util.display_show(t)
    elseif st == "episodes" then body = Util.display_episode(t)
    else body = display_playlist(t) end
    return string.format("%2d. %s", i, pfx .. body)
end

local _fmt_cache_entries = nil
local _fmt_cache_tracks  = nil
local _fmt_cache_key     = nil

format_entries = function(tracks, hide_artist, hide_liked, hide_single_artist)
    local key = (current_id or "") .. tostring(is_playing) .. tostring(hide_artist) .. tostring(hide_liked) .. tostring(hide_single_artist)
    if _fmt_cache_tracks == tracks and _fmt_cache_key == key then
        return _fmt_cache_entries
    end
    local entries = {}
    for i, t in ipairs(tracks) do entries[i] = string.format("%2d. %s", i, display_track(t, hide_artist, hide_liked, hide_single_artist)) end
    _fmt_cache_entries = entries
    _fmt_cache_tracks  = tracks
    _fmt_cache_key     = key
    return entries
end

local function view_recently_played()
    Util.recent_reload()
    local tracks = recent_tracks
    if #tracks == 0 then rofi_message("No recently played tracks"); return end
    Util.scope({view="recently-played"}, function()
    local entries = format_entries(tracks)
    view_browse(entries, tracks, "Recently Played" .. SEP .. #tracks .. " tracks", "recently-played", nil, nil)
    if jump_to_track_pending then return end
end)
end

local function bust_format_cache()
    _fmt_cache_entries = nil
    _fmt_cache_tracks  = nil
    _fmt_cache_key     = nil
end

get_playerctl_position = function()
    local cached = mem_get("_playerctl_pos")
    if cached ~= nil then return cached end
    local raw = shell("playerctl position 2>/dev/null")
    local v = tonumber(trim(raw or "")) or 0
    mem_set("_playerctl_pos", v, 1)
    return v
end

-- The same 1-second memo its two siblings here already had. Status was the only
-- one of the three called raw, and it is by far the most frequent:
-- Util.fast_now_track asks on every Util.sync_now -- each main-loop iteration,
-- each view_actions and view_playback entry -- and Util.wait_playback_change
-- polls it four times per skip. Measured at 4.6ms a call.
--
-- MUST be busted by anything that changes transport state, or a stale "Playing"
-- lets fast_now_track flip is_playing back the instant after you pause. Same
-- discipline as the mem_bust("_playerctl_pos") that already follows every seek.
--
-- On Util so Util.fast_now_track, which is defined above this point, can reach it
-- (table field, resolved at call time).
function Util.playerctl_status()
    local cached = mem_get("_playerctl_status")
    if cached ~= nil then return cached end
    local v = trim(shell("playerctl status 2>/dev/null") or "")
    mem_set("_playerctl_status", v, 1)
    return v
end

function Util.playerctl_bust()
    mem_bust("_playerctl_status")
end

local function get_playerctl_volume()
    local cached = mem_get("_playerctl_vol")
    if cached ~= nil then return cached end
    local raw = shell("playerctl volume 2>/dev/null")
    local v = tonumber(trim(raw or ""))
    if v and v >= 0 then v = math.min(math.floor(v * 100 + 0.5), 100) else v = get_saved_volume() end
    mem_set("_playerctl_vol", v, 1)
    return v
end

-- One decode of lyrics_<id>.json per draw instead of two or three: status_icons
-- asks twice, rebuild_actions adds a third, and track_mesg is the `mesg`
-- function for three menus, so all of it reran on every redraw.
--
-- A positive is memoised for the cache TTL; a negative for seconds only, since
-- a detached --prefetch-lyrics may be writing the file right now -- long enough
-- to collapse one draw's calls, short enough that the glyph appears on the next
-- redraw. On Util, not a local: the chunk is at Lua's 200-local ceiling.
function Util.lyr_state(id)
    if not id then return nil end
    local key = "lyrstate:" .. id
    local st = mem_get(key)
    if st ~= nil then return st end
    local d = disk_get(P.lyrics .. "/lyrics_" .. id .. ".json")
    st = {
        has    = type(d) == "table" and type(d.lines) == "table" and #d.lines > 0,
        synced = type(d) == "table" and type(d.times) == "table" and #d.times > 0,
    }
    mem_set(key, st, st.has and P.ttl_lyrics or 3)
    return st
end

-- Called wherever THIS process learns the file changed, so the memo above never
-- outlives what it describes.
function Util.lyr_bust(id)
    if id then mem_bust("lyrstate:" .. id) end
end

function Util.has_synced_lyrics(id)
    local st = Util.lyr_state(id)
    return st ~= nil and st.synced
end

function Util.has_lyrics(id)
    local st = Util.lyr_state(id)
    return st ~= nil and st.has
end

function Util.track_has_lyrics(id)
    if Util.has_lyrics(id) then return true end
    if id and disk_get(P.lyrics .. "/nolyr_" .. id .. ".json", P.ttl_lyrics) ~= nil then return false end
    return nil
end

-- The liked set is only populated in the interactive process; the detached
-- notify helper has to fall back to the on-disk id list.
function Util.is_liked(id)
    if not id then return false end
    if liked[id] then return true end
    if next(liked) ~= nil then return false end
    local ids = safe_decode(read_file(P.liked_ids))
    if type(ids) ~= "table" then return false end
    for _, v in ipairs(ids) do if v == id then return true end end
    return false
end

-- Single composer for the liked / explicit / lyrics glyph run. The notification
-- path used to carry its own copy of this logic and the two had already drifted
-- apart; anything that shows a track's status now reads from here.
function Util.status_icons(item)
    if not item then return "" end
    local out = ""
    if Util.is_liked(item.id) then out = out .. " \u{f05d}" end
    if item.explicit then out = out .. " \u{f071}" end
    if Util.has_lyrics(item.id) then
        out = out .. (Util.has_synced_lyrics(item.id) and " \u{F0188}" or " \u{F0189}")
    end
    return out
end

-- Util.subtitle, not artist_names: an episode has no artists, so this rendered
-- "Episode Title <SEP> " with a dangling separator -- in view_actions, in
-- view_playback, in view_seek and in the main menu's own header.
local function track_mesg(item)
    local p = item.id == current_id and Util.transport_glyph() or ""
    local by = Util.subtitle(item)
    return (p ~= "" and (p .. " ") or "") .. (item.name or "") .. (by ~= "" and (SEP .. by) or "")
        .. " " .. Util.status_icons(item)
end

local function progress_bar(pct)
    local filled = math.floor(math.max(0, math.min(pct, 1)) * PROGRESS_BAR_W + 0.5)
    return string.rep("\u{2588}", filled) .. string.rep("\u{2591}", PROGRESS_BAR_W - filled)
end

local function seek_mesg(item, pos)
    local row1 = track_mesg(item)
    local p = pos or math.max(get_playerctl_position(), 0)
    local dur = (item.duration_ms or 0) / 1000
    if dur <= 0 then return row1 end
    local elapsed = string.format("%d:%02d", math.floor(p / 60), math.floor(p % 60))
    local total = string.format("%d:%02d", math.floor(dur / 60), math.floor(dur % 60))
    return row1 .. "\n" .. elapsed .. "  " .. progress_bar(p / dur) .. "  " .. total
end

local function vol_mesg(vol)
    local v = vol or get_playerctl_volume()
    local bar = v .. "%  " .. progress_bar(v / 100) .. "  100%"
    if current_track then
        return track_mesg(current_track) .. "\n" .. bar
    end
    return bar
end

-- QUEUE

queue_tracks  = nil
queue_idx     = 0
queue_context = nil

local function load_queue()
    local raw = read_file(P.queue)
    if not raw then return end
    local d = safe_decode(raw)
    if d then
        if type(d.tracks) == "table" then
            -- Full spotify: URIs, matching every writer (save_queue and
            -- do_add_queue both go through Util.item_uri, flush_queue
            -- round-trips them). They used to be BARE IDS, which silently meant
            -- "track" everywhere they were read back -- so an episode in the
            -- queue was resumed as spotify:track:<episode id>, which resolves to
            -- nothing. A string with no ":" is one of those older files; it can
            -- only have held tracks, so prefixing it is exact rather than a
            -- guess. Tables with an .id are still accepted too.
            local clean = {}
            for _, t in ipairs(d.tracks) do
                if type(t) == "string" then
                    clean[#clean+1] = t:find(":", 1, true) and t or ("spotify:track:" .. t)
                elseif type(t) == "table" and t.id then
                    clean[#clean+1] = Util.item_uri(t)
                end
            end
            queue_tracks = clean
        else
            queue_tracks = {}
        end
        queue_idx = type(d.idx) == "number" and d.idx or 0
        if queue_idx < 0 or queue_idx > #queue_tracks then queue_idx = 0 end
        queue_context = type(d.context) == "string" and d.context or nil
    end
end

-- `idx` indexes the caller's list; `uris` drops every entry without an .id, so
-- the two only line up while nothing is dropped. One id-less row (a local file,
-- an unavailable episode) shifted every position after it, leaving queue_idx
-- pointing at the wrong track -- which is what recover_playback's
-- Next/Previous fallback then resumes from. Mapping the index inside the same
-- filtering pass keeps it on the track the caller actually meant.
--
-- Stores URIs rather than ids for the same reason: a URI says what it is, so
-- nothing downstream has to assume. A parallel array of kinds would have been
-- the alternative, and it is precisely the two-arrays-that-must-stay-aligned
-- shape the paragraph above exists to describe going wrong.
local function save_queue(items, idx, context_uri)
    local tids, new_idx = {}, nil
    for i, t in ipairs(items or {}) do
        if type(t) == "table" and t.id then
            tids[#tids+1] = Util.item_uri(t)
            if i == idx then new_idx = #tids end
        end
    end
    -- Falls back to the raw idx when the target row was itself filtered out --
    -- there is no right answer then, and this matches the old behaviour.
    idx = new_idx or idx
    queue_tracks  = tids
    queue_idx     = idx
    queue_context = context_uri
    write_file(P.queue, json.encode({tracks=tids, idx=idx, context=context_uri}))
    -- RETURNED so do_play can send the same index it stored. The two used to
    -- differ: this one indexes the filtered array, do_play sent the caller's
    -- unfiltered one as offset.position, and recover_playback later reused
    -- queue_idx as a context position -- so one id-less row ahead of the played
    -- one made a resume land on the wrong track.
    return idx
end

local function flush_queue()
    if not queue_tracks then return end
    write_file(P.queue, json.encode({tracks=queue_tracks, idx=queue_idx, context=queue_context}))
end

-- ACTIONS

-- Returns whether a play request actually went out, so callers stop patching the
-- now-playing globals for a play that never happened.
local function do_play(item, ctx_type, ctx_id, all_items, idx)
    -- Spotify ACCEPTS a play request for a track it will not serve here, then
    -- quietly moves to the next one -- which reads as the app ignoring the row you
    -- picked. Refused before save_queue so a play we never started cannot leave a
    -- queue behind. `unavail` comes only from is_playable (see
    -- Util.mark_availability), so this can never fire on a guess.
    if item and item.unavail then
        rofi_message("Selection is unavailable to your account's region")
        return false
    end
    local context_uri
    if ctx_type and ctx_id then context_uri = "spotify:" .. ctx_type .. ":" .. ctx_id
    end

    -- save_queue drops id-less rows, so the position it stored is the one that
    -- indexes what Spotify will actually be given.
    if all_items and idx then idx = save_queue(all_items, idx, context_uri) end
    local token = get_token()
    if not token then return false end
    local device_id = get_spotifyd_device()
    local dparam = device_id and "?device_id=" .. device_id or ""

    -- Assembled as a TABLE and encoded once below. Each branch used to encode
    -- its own string, which meant position_ms -- orthogonal to every one of them
    -- -- could only be added four times over.
    local b
    if context_uri and idx then
        b = {context_uri=context_uri, offset={position=idx-1}}
    elseif context_uri and item and item.id then
        -- Context known, position NOT known. This used to fall into the branch
        -- above as `(idx or 1)-1`, i.e. position 0, so it silently played the
        -- album or playlist from its FIRST track instead of the one asked for.
        -- Reached whenever a warm start replays a track's action menu: the stack
        -- entry carries ctx_type/ctx_id but all_items/cidx cannot be restored,
        -- so Play started the wrong track.
        --
        -- offset accepts a uri as well as a position, which keeps the context --
        -- playback still continues through the album afterwards -- while landing
        -- on the right track. Better than dropping to a bare uris play, which
        -- would start the correct track but strand it with no context.
        b = {context_uri=context_uri, offset={uri=Util.item_uri(item)}}
    elseif all_items and idx then
        local uris = {}
        for i = idx, math.min(#all_items, idx + 49) do
            local u = all_items[i] and Util.item_uri(all_items[i])
            if u then uris[#uris+1] = u end
        end
        if #uris > 0 then b = {uris=uris, offset={position=0}} end
    elseif item and item.id then
        -- Guarded: an item with no id used to raise a concat error here rather
        -- than failing gracefully. `b` stays nil and the caller returns false.
        b = {uris={Util.item_uri(item)}}
    end
    -- Podcasts resume where you stopped. Resolved here rather than passed in, so
    -- every path that plays an episode -- a list, an action menu, a search
    -- result, a replayed session -- resumes without a caller having to know to
    -- ask. Util.episode_resume_ms answers nil for anything that is not an
    -- episode, so a track costs nothing.
    if b then b.position_ms = Util.episode_resume_ms(item) end
    local body = b and json.encode(b) or nil
    if body then
        local code = Util.api_write("PUT", "https://api.spotify.com/v1/me/player/play" .. dparam,
            token, {timeout=3, body=body})
        -- Spotify answers 204 on success. This used to return true for ANY
        -- response -- 403, a curl timeout ("000"), "no active device" -- so a
        -- play that never happened still moved the caller's ▶ marker onto the
        -- row and still stamped P.recent_cmd_at, which then muted Util.sync_now
        -- for 5s and delayed the correction. Costs nothing to check: the request
        -- is already awaited and `code` was already being read for the 404 test.
        local ok = Util.is2xx(code)
        -- 404 = "Device not found": the persisted id went stale, so drop it and
        -- retry once against a freshly resolved device. The retry's status is
        -- what decides the outcome now; it used to be discarded entirely.
        if not ok and code and code:match("404") and device_id then
            Util.bust_device()
            local fresh = get_spotifyd_device()
            if fresh and fresh ~= device_id then
                local retry = Util.api_write("PUT",
                    "https://api.spotify.com/v1/me/player/play?device_id=" .. fresh,
                    token, {timeout=3, body=body})
                ok = Util.is2xx(retry)
            end
        end
        -- Only on a play that actually started: this suppresses Util.sync_now,
        -- and after a FAILED play we want that sync to run and show the truth.
        -- The status memo goes with it -- transport just changed underneath it.
        if ok then P.recent_cmd_at = os.time(); Util.playerctl_bust() end
        return ok
    end
    return false
end

-- Resume or pause what is already loaded, and keep our idea of the transport in
-- step with it. Six copies of these three lines existed; the memo bust is the
-- one that was easy to forget, and forgetting it leaves every ▶ marker drawn for
-- the next second showing the state we just left.
-- Returns whether playerctl accepted it, so a caller that wants to report the
-- failure can (view_playback does) without repeating the call. The flag moves
-- only on success: claiming paused after a pause that never happened leaves the
-- marker lying until the next sync corrects it.
function Util.transport(playing)
    local r = os.execute("playerctl " .. (playing and "play" or "pause") .. " 2>/dev/null")
    Util.playerctl_bust()
    local ok = r == true or r == 0
    if ok then is_playing = playing end
    return ok
end

-- What pressing Return on a playable row means, in one place: the row that is
-- already playing toggles, any other row starts. Four lists spelled this out
-- identically, and a one-track album -- which IS a track row, just drawn as an
-- album -- needs the same rule rather than a fifth copy of it.
--
-- current_track is adopted only when the request actually went out: do_play
-- refuses an unavailable track and answers false with no token, and claiming it
-- playing anyway moved the marker to a row that never started.
function Util.play_or_toggle(item, ctx_type, ctx_id, all_items, idx)
    if not item then return false end
    if item.id and item.id == current_id then
        Util.transport(not is_playing)
        return true
    end
    if do_play(item, ctx_type, ctx_id, all_items, idx) then
        current_track = item
        current_id = item.id
        is_playing = true
        return true
    end
    return false
end

local _liked_dirty = false

local function flush_liked_cache()
    if not _liked_dirty then return end
    local tracks = mem_get("liked_tracks")
    if type(tracks) ~= "table" then tracks = disk_get(P.liked) end
    if type(tracks) ~= "table" then tracks = {} end
    local id_set = {}
    for _, t in ipairs(tracks) do if t.id then id_set[t.id] = true end end
    local new_ids = {}
    -- Whether this reconciliation actually found work. do_like already ran
    -- Util.optimistic_like (which mutates this very list and rebuilds the artist
    -- index) and Util.persist_liked (which wrote both cache files), so in the
    -- normal case the loop below finds NOTHING out of sync -- and the writes at
    -- the bottom then re-encoded and rewrote the 1.4MB liked cache a second
    -- time, ~6ms, for a byte-identical result on every single like/unlike.
    local changed = false
    for id, v in pairs(liked) do
        if v and not id_set[id] then
            new_ids[#new_ids + 1] = id
        elseif not v and id_set[id] then
            for i = #tracks, 1, -1 do
                if tracks[i].id == id then table.remove(tracks, i); changed = true; break end
            end
        end
    end
    if #new_ids > 0 then
        local ok = true
        for s = 1, #new_ids, 50 do
            local chunk = {}
            for j = s, math.min(s + 49, #new_ids) do chunk[#chunk+1] = new_ids[j] end
            -- "tracks", not "me/tracks": a GET to me/tracks ignores `ids` entirely
            -- and answers with a page of saved tracks under `items`, so the
            -- `d.tracks` test below could never pass and this whole reconciliation
            -- silently gave up every time it had work to do. Verified against the
            -- live API -- me/tracks?ids=<one id> returns 20 items and no `tracks`.
            local d = api_get("tracks", Util.with_market("ids=" .. table.concat(chunk, ",")))
            if not d or not d.tracks then ok = false; break end
            local fresh = {}
            for _, t in pairs(d.tracks) do
                if t and t.id then fresh[#fresh+1] = t end
            end
            for i = #fresh, 1, -1 do table.insert(tracks, 1, fresh[i]) end
            if #fresh > 0 then changed = true end
        end
        if not ok then
            _liked_dirty = true
            return
        end
    end
    _liked_dirty = false
    -- Nothing was out of sync, so the caches on disk already say exactly this.
    -- build_liked_artist_index and bust_format_cache are skipped for the same
    -- reason: Util.optimistic_like and do_like respectively already ran them
    -- against this same unchanged list.
    if not changed then return end
    Util.persist_liked(tracks)
    build_liked_artist_index(tracks)
    bust_format_cache()
end

-- The flat id list every display helper reads for its heart glyph. Derived from
-- the track cache rather than maintained alongside it, so the two cannot drift.
function Util.write_liked_ids(tracks)
    local ids = {}
    for _, t in ipairs(tracks or {}) do if t.id then ids[#ids+1] = t.id end end
    write_file(P.liked_ids, json.encode(ids))
end

function Util.persist_liked(tracks)
    tracks = tracks or {}
    disk_set(P.liked, tracks)
    Util.write_liked_ids(tracks)
end

function Util.optimistic_like(item, unlike)
    if not (item and item.id) then return nil end
    local tracks = mem_get("liked_tracks")
    if type(tracks) ~= "table" then tracks = disk_get(P.liked) end
    if type(tracks) ~= "table" then tracks = {} end
    if unlike then
        for i = #tracks, 1, -1 do
            if tracks[i].id == item.id then table.remove(tracks, i) end
        end
    else
        local present = false
        for _, t in ipairs(tracks) do if t.id == item.id then present = true; break end end
        if not present then
            local copy = {}
            for k, v in pairs(item) do
                if not (type(k) == "string" and k:sub(1, 1) == "_") then copy[k] = v end
            end
            if not copy.added_at then copy.added_at = os.date("!%Y-%m-%dT%H:%M:%SZ") end
            table.insert(tracks, 1, copy)
        end
    end
    mem_set("liked_tracks", tracks, P.ttl)
    build_liked_artist_index(tracks)
    return tracks
end

-- `code` defaults to 0, so every ordinary caller is unchanged; the crash handler
-- at the bottom passes 1 so a shell that launched us sees the failure.
function Util.clean_exit(code)
    Util.bs_stop()
    flush_liked_cache()
    if Util._api_hdr then os.remove(Util._api_hdr) end
    os.remove(P.tmp .. "/spoot_instance.lock")
    -- The glob covers every theme this process resolved or generated, including
    -- the per-call art themes from Util.write_art_theme.
    -- Quoted through shell_quote like everywhere else; the glob stays OUTSIDE
    -- the quotes so the shell still expands it.
    os.execute("rm -f " .. shell_quote(P.tmp) .. "/spoot_theme_*.rasi 2>/dev/null")
    -- Whole scratch directory in one go. The per-call os.remove()s stay where
    -- they are -- they keep the directory small mid-session, and the detached
    -- helpers never reach this function at all (they os.exit), which is what the
    -- orphan sweep in ensure_cache is for.
    if Util._scratch then
        os.execute("rm -rf " .. shell_quote(Util._scratch) .. " 2>/dev/null")
    end
    os.exit(code or 0)
end

local function do_like(item, unlike)
    local token = get_token()
    if not token then rofi_message("Cannot like: no token"); return false end
    local verb = unlike and "DELETE" or "PUT"
    local url = "https://api.spotify.com/v1/me/tracks?ids=" .. item.id
    local r = Util.api_write(verb, url, token)
    if not Util.is2xx(r) then
        rofi_message(unlike and "Failed to unlike" or "Failed to like")
        return false
    end
    if unlike then liked[item.id] = false else liked[item.id] = true end
    Util.persist_liked(Util.optimistic_like(item, unlike))
    _liked_dirty = true
    bust_format_cache()
    return true
end

-- No token fetch here: api_get resolves (and refreshes) its own, and answers nil
-- when there isn't one, which this already reads as "not following".
local function api_check_following(artist_id)
    local r = api_get("me/following/contains?type=artist&ids=" .. artist_id)
    return r and r[1] == true
end

local function do_follow_artist(artist_id, follow)
    local token = get_token()
    if not token then return false end
    local verb = follow and "PUT" or "DELETE"
    local url = "https://api.spotify.com/v1/me/following?type=artist&ids=" .. artist_id
    local r = Util.api_write(verb, url, token, {len0=true})
    if Util.is2xx(r) then
        mem_bust("followed_artists")
        os.remove(P.artists)
        return true
    end
    return false
end

-- Takes the ITEM, not an id: the endpoint wants a URI and the local mirror now
-- stores one, and neither can be built from an id alone once episodes exist.
local function do_add_queue(item)
    local uri = Util.item_uri(item)
    if not uri then return end
    local token = get_token()
    if not token then rofi_message("Cannot add to queue: no token"); return end
    local url = "https://api.spotify.com/v1/me/player/queue?uri=" .. uri
    local r = Util.api_write("POST", url, token)
    if not Util.is2xx(r) then rofi_message("Failed to add to queue"); return end
    mem_bust("queue")
    -- also add to local queue tracking
    if not queue_tracks then queue_tracks = {}; queue_idx = 0 end
    queue_tracks[#queue_tracks+1] = uri
    flush_queue()
end

-- Save or unsave one library item. `kind` keys P.lib_kinds, which is where the
-- endpoint and the two caches to bust live, so albums and podcasts share this
-- rather than each carrying a save/remove pair of their own -- the shape the
-- album version grew into when removing was made reachable from an album's own
-- action menu instead of only from the Saved Albums list.
function Util.lib_write(kind, id, save)
    local k = P.lib_kinds[kind]
    if not (k and id) then return false end
    local token = get_token()
    if not token then
        rofi_message("Cannot " .. (save and "save " or "remove ") .. k.noun .. ": no token")
        return false
    end
    local url = "https://api.spotify.com/v1/" .. k.ids .. "?ids=" .. id
    local r = Util.api_write(save and "PUT" or "DELETE", url, token)
    if Util.is2xx(r) then
        mem_bust(k.mem)
        disk_bust(k.file)
        return true
    end
    return false
end

-- "Is this in the library?", answered without stalling the menu.
--
-- Reads the cache DIRECTLY rather than calling the loader: that refetches every
-- page when the cache is cold, which would turn opening an action menu into a
-- multi-second paginated crawl. When there is no cache to consult it asks
-- Spotify instead -- one small request, the same shape api_check_following
-- already uses for artists.
--
-- A cache written before the item was saved elsewhere can be stale, exactly as
-- Util.is_liked can be for tracks; acting on the row corrects it either way,
-- since Util.lib_write busts both caches.
function Util.lib_has(kind, id)
    local k = P.lib_kinds[kind]
    if not (k and id) then return false end
    local items = mem_get(k.mem)
    if not items then items = disk_get(k.file) end
    if type(items) == "table" then
        for _, a in ipairs(items) do if a.id == id then return true end end
        return false
    end
    local r = api_get(k.contains, "ids=" .. id)
    return type(r) == "table" and r[1] == true
end

local function do_save_playlist(playlist_id)
    local token = get_token()
    if not token then rofi_message("Cannot save playlist: no token"); return false end
    local url = "https://api.spotify.com/v1/playlists/" .. playlist_id .. "/followers"
    local r = Util.api_write("PUT", url, token, {len0=true})
    if Util.is2xx(r) then
        bust_my_playlists()
        return true
    end
    return false
end

-- Shared "Open / Save / Copy Web Link" action menu for albums and playlists.
-- Handles Save/Copy internally; returns true if the caller should open the
-- item (via browse_album / api_get_playlist_tracks) themselves, since the
-- follow-up navigation (session push/pop depth, pending-seek handling) differs
-- by call site.
local function album_action_menu(album)
    -- Row 2 flips between Save and Remove with the album's library state, so the
    -- cursor is remembered by a STABLE key per row rather than by the visible
    -- label -- the same problem Util.pos_row exists for in view_actions and
    -- view_playback. Remembering the label meant that saving an album (and so
    -- relabelling the row) dropped the cursor back to the top next time.
    local is_saved = Util.lib_has("album", album.id)
    local acts  = {"Open Album", is_saved and "Remove from Saved Albums" or "Save Album",
                   "Albumart", "Copy Web Link", "Album Details"}
    local akeys = {"open", "save", "art", "url", "details"}
    if (album.artists or {})[1] then
        table.insert(acts, 2, "Go to Artist")
        table.insert(akeys, 2, "artist")
    end
    local al_ac_key = "album-ac:" .. (album.id or "")
    local pre_sel = Util.pos_row(al_ac_key, akeys)
    local mesg = (album.name or "Album") .. album_suffix(album)
    -- Claimed only for the Go to Artist row, which offers the artist's hub on
    -- Shift+Return and their discography on Return. Every other row treats the
    -- two alike -- the default handler was a silent no-op here anyway, since
    -- this menu passes neither `current` nor `items`.
    local action = rofi_dmenu(acts,
        {prompt=album.name or "Album", mesg=mesg, custom=false, theme=THEME_SUB, no_status=true, sel=pre_sel, markup=true,
         alt_select=true})
    local alt = Util.alt_pressed
    Util.alt_pressed = false
    if action then
        for i, a in ipairs(acts) do
            if a == action then Util.pos_put(al_ac_key, akeys[i]); break end
        end
    end
    if action == "Save Album" then
        rofi_message(Util.lib_write("album", album.id, true) and "Album saved" or "Failed to save album")
    elseif action == "Remove from Saved Albums" then
        rofi_message(Util.lib_write("album", album.id, false) and "Removed from Saved Albums"
            or "Failed to remove album")
    elseif action == "Copy Web Link" then
        copy_spotify_url("album", album.id)
        rofi_message("Copied web link")
    elseif action == "Go to Artist" then
        local ar = (album.artists or {})[1]
        if ar then Util.open_artist({id=ar.id, name=ar.name or ""}, alt) end
    elseif action == "Albumart" then
        view_art({album=album, name=album.name, artists=album.artists})
    elseif action == "Album Details" then
        Util.view_album_details(album)
    end
    return action == "Open Album"
end

-- album_action_menu's shape for podcasts, down to the stable-key cursor: row 2
-- flips between Follow and Unfollow with the library state, so remembering the
-- cursor by the visible label would drop it back to the top the moment the row
-- was relabelled. Returns whether the caller should open the show, which is the
-- contract album_action_menu and playlist_action_menu already answer with.
function Util.show_action_menu(show)
    local followed = Util.lib_has("show", show.id)
    local acts  = {"Open Podcast", followed and "Unfollow Podcast" or "Follow Podcast",
                   "Podcast Art", "Copy Web Link", "Podcast Details"}
    local akeys = {"open", "follow", "art", "url", "details"}
    local sh_ac_key = "show-ac:" .. (show.id or "")
    local pre_sel = Util.pos_row(sh_ac_key, akeys)
    local action = rofi_dmenu(acts,
        {prompt=show.name or "Podcast", mesg=Util.display_show(show), custom=false,
         theme=THEME_SUB, no_status=true, sel=pre_sel, markup=true})
    if action then
        for i, a in ipairs(acts) do
            if a == action then Util.pos_put(sh_ac_key, akeys[i]); break end
        end
    end
    if action == "Follow Podcast" then
        rofi_message(Util.lib_write("show", show.id, true) and "Podcast followed"
            or "Failed to follow podcast")
    elseif action == "Unfollow Podcast" then
        rofi_message(Util.lib_write("show", show.id, false) and "Podcast unfollowed"
            or "Failed to unfollow podcast")
    elseif action == "Copy Web Link" then
        copy_spotify_url("show", show.id)
        rofi_message("Copied web link")
    elseif action == "Podcast Art" then
        view_art(show)
    elseif action == "Podcast Details" then
        Util.view_show_details(show)
    end
    return action == "Open Podcast"
end

local function playlist_action_menu(pl)
    local acts = {"Open Playlist", "Save Playlist", "Playlist Art", "Copy Web Link"}
    local pl_ac_key = "pl-ac:" .. (pl.id or "")
    local pre_sel = 0
    local saved = Util.pos_get(pl_ac_key)
    if type(saved) == "string" then
        for i, a in ipairs(acts) do if a == saved then pre_sel = i - 1; break end end
    end
    local action = rofi_dmenu(acts,
            {prompt=display_playlist(pl), mesg=display_playlist(pl) .. SEP .. (pl.owner and pl.owner.display_name or "Unknown owner"), custom=false, theme=THEME_SUB, no_status=true, sel=pre_sel, markup=true})
    if action then
        Util.pos_put(pl_ac_key, action)
    end
    if action == "Playlist Art" then
        view_art(pl)
    elseif action == "Save Playlist" then
        rofi_message(do_save_playlist(pl.id) and "Playlist saved" or "Failed to save playlist")
    elseif action == "Copy Web Link" then
        copy_spotify_url("playlist", pl.id)
        rofi_message("Copied web link")
    end
    return action == "Open Playlist"
end

local function do_playback_cmd(cmd)
    local token = get_token()
    if not token then return nil end
    local device_id = get_spotifyd_device()
    local url = "https://api.spotify.com/v1/me/player/" .. cmd
        .. (device_id and ("?device_id=" .. device_id) or "")
    local r = Util.api_write("POST", url, token, {timeout=3, len0=true})
    -- Bust the status memo too: next/previous changes transport, and
    -- Util.wait_playback_change polls Util.fast_now_track straight afterwards.
    if Util.is2xx(r) then mem_bust("queue"); P.recent_cmd_at = os.time(); Util.playerctl_bust() end
    return r
end

recover_playback = function(direction, force)
    if not queue_tracks or #queue_tracks == 0 then return false end
    local new_idx = queue_idx + direction
    if new_idx < 1 then new_idx = 1 end
    if new_idx > #queue_tracks then new_idx = #queue_tracks end
    if not force and new_idx == queue_idx then return false end
    local token = get_token()
    if not token then return false end
    Util.bust_device()
    local device_id = get_spotifyd_device()
    if not device_id then return false end
    local dparam = "?device_id=" .. device_id
    local body
    if queue_context and not is_shuffle then
        -- Spotify ignores offset.position on context_uri playback while
        -- shuffle is active, so this path is only reliable when shuffle is off.
        body = json.encode({context_uri=queue_context, offset={position=new_idx-1}})
    else
        local uris = {}
        for i = new_idx, math.min(#queue_tracks, new_idx + 49) do
            uris[#uris+1] = queue_tracks[i]
        end
        if #uris > 0 then body = json.encode({uris=uris, offset={position=0}}) end
    end
    if not body then return false end
    local r = Util.api_write("PUT", "https://api.spotify.com/v1/me/player/play" .. dparam,
        token, {timeout=3, body=body})
    if Util.is2xx(r) then
        queue_idx = new_idx
        flush_queue()
        P.recent_cmd_at = os.time()
        -- Explicit rather than relying on P.recent_cmd_at suppressing sync_now
        -- for 5s while the status memo lives 1s. That coincidence does protect
        -- this today, but it couples two unrelated constants: shorten the
        -- suppression or lengthen the TTL and the stale-state bug returns with
        -- nothing pointing back here.
        Util.playerctl_bust()
        last_playback = 0; get_playback()
        return true
    end
    return false
end

-- API HELPERS

local function api_get_album(album_id)
    return cached_fetch("album_" .. album_id, P.mass .. "/album_" .. album_id .. ".json", CACHE_TTL_LONG, function()
        local d = api_get("albums/" .. album_id, Util.with_market())
        if not d then return nil end
        if d.tracks then
            local tracks = {}
            if d.tracks.items then
                for _, t in ipairs(d.tracks.items) do tracks[#tracks+1] = t end
            end
            local next_url = d.tracks.next
            while next_url and #tracks < (d.total_tracks or 999) do
                local params = next_url:match("%?(.+)")
                local page = api_get("albums/" .. album_id .. "/tracks", params)
                if not page then return nil end
                if not page.items or #page.items == 0 then break end
                for _, t in ipairs(page.items) do tracks[#tracks+1] = t end
                next_url = page.next
            end
            d.tracks = tracks
            -- albums/{id} hands back SIMPLIFIED track objects, which carry no
            -- `album` field at all, so one is synthesised here. It used to hold
            -- nothing but the cover images, which left every track browsed from
            -- an album with an album that could not name itself -- `Go to Album`
            -- guards on `album.id` and so did nothing, and the stunted object
            -- escapes this view (do_play assigns it to current_track, which the
            -- main loop can hand to record_recent_play, and Util.optimistic_like
            -- copies it into the liked cache).
            --
            -- Outside the images test on purpose: an album with no artwork used
            -- to skip the whole loop and get no album patched onto its tracks.
            for _, t in ipairs(tracks) do
                if not t.album then t.album = {} end
                t.album.id      = t.album.id      or d.id
                t.album.name    = t.album.name    or d.name
                t.album.artists = t.album.artists or d.artists
                if d.images and #d.images > 0
                   and (not t.album.images or #t.album.images == 0) then
                    t.album.images = d.images
                end
            end
        end
        return d
    end, {revalidate = "album", revalidate_arg = album_id})
end

-- A podcast and its episodes, in the shape api_get_album answers with: the show
-- object itself, plus `episodes` as a flat array rather than the paging envelope
-- Spotify wraps it in.
--
-- The synthetic `show` patched onto each episode matters for exactly the reason
-- the album version's does: shows/{id}/episodes answers with SimplifiedEpisode,
-- which carries NO parent, and that stunted object escapes this view -- do_play
-- assigns it to current_track, view_art captions from it, Go to Podcast and
-- Copy URL read it, and the episode list's backdrop resolves its cover through
-- it. `publisher` is in the patch because Util.subtitle falls back to it.
--
-- No snapshot_id exists for a show, so unlike a playlist there is nothing to
-- hand cached_fetch as a validity tag; the long TTL plus the revalidator is the
-- honest version of "we cannot know, so serve fast and refresh behind you".
function Util.api_get_show(show_id)
    return cached_fetch("show_" .. show_id, P.mass .. "/show_" .. show_id .. ".json", CACHE_TTL_LONG, function()
        local d = api_get("shows/" .. show_id, Util.with_market())
        if not d then return nil end
        local eps = {}
        if d.episodes and d.episodes.items then
            for _, e in ipairs(d.episodes.items) do eps[#eps+1] = e end
            local next_url = d.episodes.next
            while next_url do
                local params = next_url:match("%?(.+)")
                local page = api_get("shows/" .. show_id .. "/episodes", params)
                if not page then return nil end
                if not page.items or #page.items == 0 then break end
                for _, e in ipairs(page.items) do eps[#eps+1] = e end
                next_url = page.next
            end
        end
        for _, e in ipairs(eps) do
            if not e.show then e.show = {} end
            e.show.id        = e.show.id        or d.id
            e.show.name      = e.show.name      or d.name
            e.show.publisher = e.show.publisher or d.publisher
            if d.images and #d.images > 0
               and (not e.show.images or #e.show.images == 0) then
                e.show.images = d.images
            end
        end
        d.episodes = eps
        return d
    end, {revalidate = "show", revalidate_arg = show_id})
end
-- Where an episode should actually start, asked at the moment of playing.
--
-- resume_point cannot be read off the episode we already hold: it arrives inside
-- the show payload, and Util.api_get_show caches that for CACHE_TTL_LONG, so
-- after the first fetch of a show the position is frozen for a day. Resume
-- therefore never survived a restart -- or even a second play in the same
-- session -- and always restarted from zero.
--
-- One small request, and only when starting an EPISODE that is not already the
-- current item (Util.play_or_toggle turns that case into a transport toggle
-- before do_play is reached), so tracks pay nothing and a double press does not
-- refetch. fully_played is honoured for the reason it always was: a finished
-- episode's position sits at the very end, and resuming there drops you into
-- the last seconds of the credits.
-- What an episode's progress looks like, resolved WITHOUT touching the network
-- -- this runs per row, on every draw. Local first for the same reason
-- Util.episode_resume_ms prefers it: the recorder is the only thing that sees
-- this player's progress, and Spotify answers zero for everything spotifyd
-- played. Returns milliseconds (0 when unknown) and whether it is finished.
function Util.episode_progress(item)
    if not item then return 0, false end
    local ms, done = Util.eresume_get(item.id)
    if ms then return ms, false end
    if done then return 0, true end
    local rp = item.resume_point or {}
    if rp.fully_played then return 0, true end
    return rp.resume_position_ms or 0, false
end

function Util.episode_resume_ms(item)
    if not (item and item.id and item.type == "episode") then return nil end
    -- Local first, and it ends the lookup: the recorder below is the only thing
    -- that sees this player's progress, so its answer is the true one -- and
    -- returning here means starting an episode costs no request at all. Spotify
    -- would answer 0 for everything played through spotifyd and overwrite a
    -- perfectly good position with it.
    local local_ms, local_done = Util.eresume_get(item.id)
    if local_ms then return local_ms end
    -- Finished HERE. Start from the top, and do not spend a request asking
    -- Spotify about an episode we already know the answer for.
    if local_done then return nil end
    -- Nothing recorded here. Now the API is worth asking, because this is
    -- exactly the case it can answer: an episode you were listening to on a
    -- phone or the web player, where Spotify's own client did record a position.
    local d = api_get("episodes/" .. item.id, Util.with_market())
    local rp = (d and d.resume_point) or item.resume_point
    if not rp or rp.fully_played then return nil end
    local ms = rp.resume_position_ms or 0
    return ms > 0 and ms or nil
end

-- Lifts CURRENT resume points onto a cached episode list, so the progress figure
-- and the played-dimming in a show's list are not a day old.
--
-- Bounded on purpose: one request for the newest 50 however large the catalogue
-- (Darknet Diaries is 227 episodes over five pages, and re-paging that on every
-- open to refresh a progress number would be absurd). Episodes past the newest
-- 50 keep whatever the show cache holds -- they are the back catalogue, and the
-- play path reads the live value anyway.
function Util.merge_resume_points(show_id, eps)
    if not (show_id and eps and #eps > 0) then return eps end
    local fresh = cached_fetch("show_resume_" .. show_id,
        P.mass .. "/show_resume_" .. show_id .. ".json", CACHE_TTL_SHORT, function()
            local d = api_get("shows/" .. show_id .. "/episodes",
                Util.with_market("limit=50"))
            if not (d and d.items) then return nil end
            local map = {}
            for _, e in ipairs(d.items) do
                if e and e.id and e.resume_point then map[e.id] = e.resume_point end
            end
            if not next(map) then return nil end
            return map
        end)
    if type(fresh) ~= "table" then return eps end
    for _, e in ipairs(eps) do
        if e.id and fresh[e.id] then e.resume_point = fresh[e.id] end
    end
    return eps
end

Util.REVALIDATORS.show = function(show_id)
    if show_id and #show_id > 0 then return Util.api_get_show(show_id) end
end

-- The aligned label/value sheet behind Album and Track Details, which carried
-- byte-identical copies of the row builder, skip-empties wrapper and artist
-- collapse. add() drops nil and empty values, making most callers' `if d.x`
-- guards redundant -- kept only where a guard maps a value (explicit -> "yes")
-- or reaches through an absent table. Popularity 0 still shows: "0" isn't "".
-- `theme` overrides the sheet's window only -- every caller shares the same row
-- builder, so an album sheet and a podcast sheet cannot drift in how they render
-- a field. Defaults to THEME_META.
function Util.detail_sheet(theme)
    local lines = {}
    local s = {}
    function s.add(label, val)
        if val == nil then return end
        val = tostring(val)
        if val == "" then return end
        lines[#lines+1] = string.rep(" ", 15 - #label)
            .. Util.markup('<span foreground="#9bbfbf">') .. label .. Util.markup("</span>")
            .. "  " .. val
    end
    function s.artists(list)
        local names = {}
        for _, ar in ipairs(list or {}) do
            if ar.name and ar.name ~= "" then names[#names+1] = ar.name end
        end
        if #names > 0 then s.add("Artists", table.concat(names, ", ")) end
    end
    function s.show()
        rofi_message(#lines > 0 and table.concat(lines, "\n") or "No details available", theme or THEME_META)
    end
    return s
end

-- On Util rather than a file local: these two were the only views in the file
-- with no forward declaration, so they were leaking into _G. They cannot become
-- locals either -- the chunk is at Lua's 200-local ceiling (see the note above
-- Util's declaration).
Util.view_album_details = function(album)
    local d = api_get_album(album.id)
    if not d then
        rofi_message("Could not load album details")
        return
    end
    local s = Util.detail_sheet()
    s.add("Name", d.name)
    s.artists(d.artists)
    s.add("Type", d.album_type)
    s.add("Release date", d.release_date)
    s.add("Total tracks", d.total_tracks)
    s.add("Label", d.label)
    if d.genres and #d.genres > 0 then s.add("Genres", table.concat(d.genres, ", ")) end
    s.add("Popularity", d.popularity)
    s.add("URL", d.external_urls and d.external_urls.spotify)
    s.add("UPC", d.external_ids and d.external_ids.upc)
    s.add("ID", d.id)
    s.show()
end

Util.view_track_details = function(item)
    local d = api_get("tracks/" .. (item.id or ""), Util.with_market())
    if not d then
        rofi_message("Could not load track details")
        return
    end
    local s = Util.detail_sheet()
    s.add("Name", d.name)
    s.artists(d.artists)
    s.add("Album", d.album and d.album.name)
    s.add("Type", d.album and d.album.album_type)
    s.add("Disc", d.disc_number)
    s.add("Track", d.track_number)
    if d.duration_ms then
        s.add("Duration", string.format("%d:%02d", math.floor(d.duration_ms / 60000),
            math.floor((d.duration_ms % 60000) / 1000)))
    end
    if d.explicit then s.add("Explicit", "yes") end
    s.add("Popularity", d.popularity)
    s.add("URL", d.external_urls and d.external_urls.spotify)
    s.add("ISRC", d.external_ids and d.external_ids.isrc)
    s.add("ID", d.id)
    s.show()
end

-- Both sheets below reuse Util.detail_sheet unchanged; s.artists simply goes
-- unused, since neither a show nor an episode has any.
Util.view_show_details = function(show)
    local d = Util.api_get_show(show.id)
    if not d then
        rofi_message("Could not load podcast details")
        return
    end
    local s = Util.detail_sheet(Util.THEME_PODS)
    s.add("Name", d.name)
    s.add("Publisher", d.publisher)
    s.add("Episodes", d.total_episodes or (d.episodes and #d.episodes))
    s.add("Type", d.media_type)
    s.add("Languages", d.languages and #d.languages > 0 and table.concat(d.languages, ", ") or nil)
    if d.explicit then s.add("Explicit", "yes") end
    s.add("Description", d.description)
    s.add("URL", d.external_urls and d.external_urls.spotify)
    s.add("ID", d.id)
    s.show()
end

Util.view_episode_details = function(item)
    local d = api_get("episodes/" .. (item.id or ""), Util.with_market())
    if not d then
        rofi_message("Could not load episode details")
        return
    end
    local s = Util.detail_sheet(Util.THEME_PODS)
    s.add("Name", d.name)
    s.add("Podcast", d.show and d.show.name)
    s.add("Release date", d.release_date)
    s.add("Duration", Util.dur_short(d.duration_ms))
    -- Reads the same resolver the list rows do, so the sheet and the row can
    -- never disagree about how far in you are.
    local pos, done = Util.episode_progress(d)
    if done then s.add("Progress", "played")
    elseif pos > 0 then s.add("Progress", Util.dur_short(pos) .. " in") end
    if d.explicit then s.add("Explicit", "yes") end
    s.add("Description", d.description)
    s.add("URL", d.external_urls and d.external_urls.spotify)
    s.add("ID", d.id)
    s.show()
end

-- `snapshot` is the playlist's snapshot_id, which Spotify changes exactly when
-- its contents change. Handed to cached_fetch as the validity tag, it replaces
-- guessing with knowing: a playlist you have opened before is a disk read for as
-- long as it genuinely has not moved, and refetches the moment it has -- including
-- edits made on your phone, which no TTL could catch any sooner than its expiry.
--
-- The old 1800s TTL survives as the fallback for callers with no token, and is
-- why this was slow: every one of these files expires mid-session, so reopening a
-- 739-track playlist meant eight sequential pages before the menu could draw.
api_get_playlist_tracks = function(playlist_id, snapshot)
    return cached_fetch("playlist_tracks_" .. playlist_id, P.mass .. "/playlist_tracks_" .. playlist_id .. ".json", 1800, function()
        return Util.paged_fetch("playlists/" .. playlist_id .. "/tracks",
            -- `explicit` has to be in the mask: this is the only track source in
            -- the file that narrows the response, so without it every track read
            -- out of a playlist lost its explicit glyph in list rows, in the
            -- message bar and in Track Details. `is_playable` is in for the same
            -- reason -- the mask would otherwise drop the one field that says
            -- whether the track can actually play here. `type` joined them for
            -- the same reason: a playlist may legally hold episodes, and
            -- without it one arrives shaped like an artist-less track and plays
            -- as spotify:track:<episode id>, which resolves to nothing.
            function(o) return Util.with_market("limit=100&offset=" .. o .. "&fields=items(track(id,name,type,duration_ms,explicit,is_playable,artists,album(id,name,images,artists)),added_at),next") end,
            function(d, items) return #items == 0 or not d.next end,
            function(entry)
                if entry.track and entry.track.id then
                    entry.track.added_at = entry.added_at
                    return entry.track
                end
                return nil
            end)
    end, {tag = snapshot})
end

-- Everything that changes a playlist's tracks has to drop both copies of them,
-- and the pair was written out at three call sites. One name so a fourth
-- mutation cannot forget half of it.
function Util.bust_playlist_tracks(playlist_id)
    if not playlist_id then return end
    disk_bust(P.mass .. "/playlist_tracks_" .. playlist_id .. ".json")
    mem_bust("playlist_tracks_" .. playlist_id)
    disk_bust(Util.playlist_meta_path(playlist_id))
    mem_bust("playlist_meta_" .. playlist_id)
end

function Util.playlist_meta_path(id) return P.mass .. "/playlist_meta_" .. id .. ".json" end

-- ONE owner of "what does playlist X look like right now" -- its name, cover,
-- owner, size, and above all its snapshot_id, which is what decides whether the
-- cached tracks are still current.
--
-- This exists as a CACHE rather than as fields on the session stack, and the
-- difference matters: a stack entry is a record of where you were and never
-- changes, so a snapshot kept there would go on validating the same tracks
-- forever. An editorial playlist -- Discover Weekly, daylist, Release Radar --
-- would then be frozen at whatever it held the day the session was written.
-- A cache has a TTL and a background refresh, so the snapshot self-corrects.
function Util.playlist_meta(id)
    if not id or #id == 0 then return nil end
    return cached_fetch("playlist_meta_" .. id, Util.playlist_meta_path(id), CACHE_TTL_MED,
        function()
            return api_get("playlists/" .. id,
                "fields=id,name,images,owner,snapshot_id,tracks(total)")
        end, {revalidate = "playlist_meta", revalidate_arg = id})
end

-- Records what a list already told us, so replaying into this playlist never has
-- to ask. The list it came from is itself refreshed on its own schedule, so this
-- is as current as that list was.
function Util.playlist_meta_seed(pl)
    if not (pl and pl.id and pl.snapshot_id) then return end
    disk_set(Util.playlist_meta_path(pl.id), {
        id = pl.id, name = pl.name, images = pl.images, owner = pl.owner,
        snapshot_id = pl.snapshot_id,
        tracks = pl.tracks and {total = tonumber(pl.tracks.total)} or nil,
    })
    mem_set("playlist_meta_" .. pl.id, nil, 0)
end

-- Refreshes the snapshot FIRST, then lets it decide whether the tracks need
-- re-paging: with Util.revalidating cleared, api_get_playlist_tracks goes back to
-- its ordinary tag check, so an unchanged playlist costs one small request and a
-- changed one is fully rebuilt. Blanket-refetching instead would re-page 739
-- tracks every hour to learn nothing.
Util.REVALIDATORS.playlist_meta = function(id)
    if not id or #id == 0 then return end
    local m = Util.playlist_meta(id)
    Util.revalidating = false
    if m and m.snapshot_id then api_get_playlist_tracks(id, m.snapshot_id) end
end

-- Searches are cached to DISK, not just memory. A warm start is a new process
-- with an empty memo, so replaying onto a search result refetched every time --
-- measured at 695 ms single-category and 511 ms combined, which is the whole of
-- that delay. It is network, so memory alone cannot fix it: the memo does not
-- survive the restart that IS the warm start.
--
-- Lifetime is the daemons' -- both kill paths call Util.drop_search_cache -- with
-- CACHE_TTL_LONG as a backstop, because daemons can run for weeks and the
-- catalogue does move. The trade is deliberate: repeating a search inside that
-- window answers from disk instead of requerying.
function Util.search_cache_path(key)
    -- Queries are arbitrary user text, so the filename is a sanitised prefix for
    -- legibility plus a djb2 hash of the WHOLE key. A collision then needs both
    -- to match, rather than just 32 bits.
    local h = 5381
    for i = 1, #key do h = (h * 33 + key:byte(i)) % 0x100000000 end
    local tag = key:gsub("[^%w]", "_"):sub(1, 32)
    return P.mass .. "/search_" .. tag .. "_" .. string.format("%08x", h) .. ".json"
end

function Util.drop_search_cache()
    mem_bust("search:")
    os.execute("rm -f " .. shell_quote(P.mass) .. "/search_*.json 2>/dev/null")
end

-- One search, one shape: all four types in one request, P.max of each. Neither
-- the type list nor the limit is a parameter any more -- there is no second
-- caller to vary them, and both belonged to the type picker that is gone.
-- The one list of what a search covers. It used to be three hand-maintained
-- copies -- the type= parameter, the plural keys the response is unwrapped by,
-- and format_search_results' display order -- which is exactly the drift the
-- comments around here keep warning about. `key` is the plural Spotify answers
-- with and the _stype every row is stamped with; `t` is the singular the
-- endpoint asks for. Order is display order.
Util.SEARCH_TYPES = {
    {key = "tracks",    t = "track"},
    {key = "albums",    t = "album"},
    {key = "artists",   t = "artist"},
    {key = "playlists", t = "playlist"},
    {key = "shows",     t = "show"},
    {key = "episodes",  t = "episode"},
}

-- The pages the one results list is split into, and the only thing that knows
-- the split is not 1:1 with Util.SEARCH_TYPES: "All" spans every type, and
-- Podcasts holds shows AND episodes, because "podcast" as a thing you look for
-- means both the show and a particular episode of it.
--
-- `keys = nil` means "every type, in SEARCH_TYPES order" rather than a copy of
-- that list, so the All page cannot drift when a type is added or removed.
-- `icon` names the _stype whose glyph stands for the page, and defaults to the
-- page key. Only the two pages whose key is not itself a type need it: All spans
-- every type and so gets none, and Podcasts spans two and takes the show's.
Util.SEARCH_PAGES = {
    {key = "all",       label = "All",                             icon = false},
    {key = "tracks",    label = "Tracks",    keys = {"tracks"}},
    {key = "albums",    label = "Albums",    keys = {"albums"}},
    {key = "artists",   label = "Artists",   keys = {"artists"}},
    {key = "playlists", label = "Playlists", keys = {"playlists"}},
    {key = "podcasts",  label = "Podcasts",  keys = {"shows", "episodes"}, icon = "shows"},
}

-- Which _stype keys a page shows, resolved once so callers never special-case
-- the nil that means "all of them".
function Util.search_page_keys(page)
    local pg = Util.SEARCH_PAGES[page]
    if pg and pg.keys then return pg.keys end
    local all = {}
    for _, e in ipairs(Util.SEARCH_TYPES) do all[#all+1] = e.key end
    return all
end

-- One search, described once. api_search issues it through api_get; the
-- parallel prefetcher below builds a curl for the same thing, and they must
-- agree on the query, the cache key and the shape stored under it or the
-- prefetch would fill a cache api_search never reads.
function Util.search_query(query)
    local ts = {}
    for _, e in ipairs(Util.SEARCH_TYPES) do ts[#ts+1] = e.t end
    local stype, limit = table.concat(ts, ","), P.max
    return Util.with_market("q=" .. url_encode(query) .. "&type=" .. stype .. "&limit=" .. limit),
           "search:" .. query .. ":" .. stype .. ":" .. limit
end

-- Collapses each type's paging envelope to a bare array. api_get already ran on
-- the api_search path; the prefetcher decodes raw, so this is the one place that
-- knows what a cached search looks like.
function Util.search_unwrap(d)
    if not d then return nil end
    for _, e in ipairs(Util.SEARCH_TYPES) do
        if d[e.key] and d[e.key].items then d[e.key] = d[e.key].items end
    end
    return d
end

local function api_search(query)
    local params, key = Util.search_query(query)
    return cached_fetch(key, Util.search_cache_path(key), CACHE_TTL_LONG, function()
        return Util.search_unwrap(api_get("search", params))
    end)
end

-- Fills the search cache for many queries AT ONCE. The shelf warm behind the
-- Podcasts grid is 21 topic searches, and issued one at a time -- each ~500ms of
-- latency and almost no transfer -- that alone was 11 of the 27 seconds a
-- brand-new warm took, during which every tile draws a placeholder.
--
-- Same fire-a-batch-and-wait idiom parallel_fetch_library uses, and the same
-- reason: these are latency-bound, so the wall time is one round trip rather
-- than the sum of them. Already-cached queries are skipped, so a warm start
-- issues nothing.
function Util.search_prefetch(queries)
    local token = get_token()
    if not token then return end
    local auth = "Authorization: Bearer " .. token
    local want = {}
    for _, q in ipairs(queries or {}) do
        local params, key = Util.search_query(q)
        local path = Util.search_cache_path(key)
        if disk_get(path, CACHE_TTL_LONG) == nil then
            want[#want+1] = {q = q, params = params, path = path, tmp = path .. ".tmp"}
        end
    end
    if #want == 0 then return end
    ensure_cache()
    local BATCH = 8
    for i = 1, #want, BATCH do
        local cmds = {}
        for j = i, math.min(i + BATCH - 1, #want) do
            local w = want[j]
            cmds[#cmds+1] = string.format("curl -s --max-time 15 -H %s %s -o %s 2>/dev/null",
                shell_quote(auth),
                shell_quote("https://api.spotify.com/v1/search?" .. w.params),
                shell_quote(w.tmp))
        end
        os.execute(table.concat(cmds, " & ") .. " & wait")
        for j = i, math.min(i + BATCH - 1, #want) do
            local w = want[j]
            local d = safe_decode(read_file(w.tmp) or "")
            os.remove(w.tmp)
            -- Through the same collapse and the same availability pass api_get
            -- would have applied, so a prefetched entry is byte-comparable with
            -- one api_search wrote.
            if d and not d.error then
                disk_set(w.path, Util.search_unwrap(Util.mark_availability(d)))
            end
        end
    end
end

local function api_get_me()
    return cached_fetch("me_profile", P.cache .. "/me_profile.json", CACHE_TTL_MED, function()
        return api_get("me")
    end, {revalidate = "me_profile"})
end
-- Util.market() needs this, and it is declared far above where this local
-- exists. Published rather than duplicated so there stays one profile fetch.
Util.api_get_me = api_get_me

-- What to call the menu holding your library. api_get_me is disk-cached for an
-- hour and cached_fetch serves a stale copy rather than nothing, so this is a
-- file read in the normal case and survives being offline.
--
-- Falls back through the account id to a plain word: display_name is optional on
-- a Spotify profile and comes back null for some accounts, and a menu row is not
-- the place to discover that.
function Util.account_name()
    local me = api_get_me()
    local n = me and me.display_name
    if type(n) == "string" and trim(n) ~= "" then return trim(n) end
    n = me and me.id
    if type(n) == "string" and trim(n) ~= "" then return trim(n) end
    return "Library"
end

-- Five minutes is shorter than the gap between two ordinary uses of spoot, so
-- this expired before nearly every open and the Playlists menu paid a ~340ms
-- round trip before it could draw. `revalidate` keeps the TTL honest while
-- refusing to make the menu wait for it: the expired list draws now and the
-- refresh lands behind it. Every change made INSIDE spoot calls
-- bust_my_playlists, which removes the file outright, so those are never stale.
local function api_get_my_playlists()
    return cached_fetch("my_playlists", P.cache .. "/my_playlists.json", CACHE_TTL_SHORT, function()
        return Util.paged_fetch("me/playlists",
            function(o) return "limit=50&offset=" .. o end,
            function(d, items) return #items == 0 or not d.next end)
    end, {revalidate = "my_playlists"})
end
Util.REVALIDATORS.my_playlists = function() return api_get_my_playlists() end

-- PLAYLIST MEMBERSHIP INDEX
--
-- Answers "which of my playlists holds this track?" without a round trip, so
-- the action menu can offer Remove from Playlist from any view. Only owned or
-- collaborative playlists are indexed -- Spotify rejects writes to editorial
-- ones, so offering removal there would only produce a failed request.
--
-- Shape: { owned = {[pl_id] = name}, tracks = {[track_id] = {pl_id, ...}} }

-- On Util rather than as file locals: this chunk is already at Lua's 200-local
-- ceiling.
function Util.pl_is_mine(p, my_id)
    return p and p.owner and my_id and (p.owner.id == my_id or p.collaborative)
end

function Util.build_pl_index()
    local me = api_get_me()
    local my_id = me and me.id
    if not my_id then return nil end
    local pls = api_get_my_playlists()
    if not pls then return nil end

    local idx = {owned = {}, tracks = {}}
    for _, p in ipairs(pls) do
        if p.id and Util.pl_is_mine(p, my_id) then
            idx.owned[p.id] = p.name or "Playlist"
            -- api_get_playlist_tracks is disk+mem cached at 1800s, so a rebuild
            -- behind a warm library costs no network at all.
            for _, t in ipairs(api_get_playlist_tracks(p.id) or {}) do
                if t.id then
                    local l = idx.tracks[t.id]
                    if not l then l = {}; idx.tracks[t.id] = l end
                    l[#l+1] = p.id
                end
            end
        end
    end
    disk_set(P.pl_index, idx)
    mem_set("pl_index", idx, CACHE_TTL_SHORT)
    return idx
end

-- Build_pl_index walks every owned playlist, so it is the most expensive
-- background job here and exactly one may be in flight. Same pid-file liveness
-- idiom as Util.spawn_art_prefetch; without it, view_actions (which
-- calls Util.pl_index once per open) fired a fresh full-library walk on EVERY
-- action menu opened while the index was cold, and init_library's sibling spawn
-- could race the first of them.
function Util.spawn_plindex()
    if Util.detached then return end
    local pidf = P.tmp .. "/spoot_plindex.pid"
    if Util.pidfile_owner_alive(pidf, "--prefetch-plindex") then return end
    Util.spawn_self({"--prefetch-plindex"}, nil, pidf)
end

function Util.spawn_revalidate(name, arg2)
    if Util.detached or Util.revalidating then return end
    if not name or not Util.REVALIDATORS[name] then return end
    -- One per name, not one per open: a menu redraws freely, and without this
    -- guard every draw during a slow refresh would start another refresh. Same
    -- pid-file liveness idiom as spawn_art_prefetch and spawn_plindex.
    -- The ARGUMENT is in the name too. Four revalidators are parameterised by an
    -- id -- show, show_latest, category_playlists, playlist_meta -- and a pid
    -- file keyed on the revalidator alone made them contend for one slot: with
    -- twenty followed podcasts, one open of Latest Episodes refreshed exactly
    -- one show and silently dropped the other nineteen, the same one every time
    -- since Util.load_saved_shows is name-sorted.
    local pidf = P.tmp .. "/spoot_reval_" .. name:gsub("[^%w_]", "")
        .. (arg2 and ("_" .. tostring(arg2):gsub("[^%w_]", "")) or "") .. ".pid"
    if Util.pidfile_owner_alive(pidf, "--revalidate") then return end
    local args = {"--revalidate", name}
    if arg2 then args[#args+1] = tostring(arg2) end
    Util.spawn_self(args, nil, pidf)
end

function Util.run_revalidate()
    Util.detached = true
    local fn = Util.REVALIDATORS[arg[2] or ""]
    if not fn then os.exit(0) end
    ensure_cache()
    -- Set for the whole call: everything it reaches goes through cached_fetch,
    -- and every one of those reads has to be skipped, not just the outermost.
    Util.revalidating = true
    pcall(fn, arg[3])
    Util.revalidating = false
    os.exit(0)
end

-- Read-only and non-blocking: view_actions already stalls up to 1.5s on
-- resolve_lyrics_state, so it must never also wait on a walk of every playlist.
-- A stale index is served while a rebuild runs in the background.
function Util.pl_index()
    local v = mem_get("pl_index")
    if v ~= nil then return v end
    local fresh = disk_get(P.pl_index, CACHE_TTL_SHORT)
    if fresh then mem_set("pl_index", fresh, CACHE_TTL_SHORT); return fresh end
    Util.spawn_plindex()
    return disk_get(P.pl_index)  -- no TTL: whatever we last knew beats nothing
end

-- Keep the index truthful the instant a track is added or removed, rather than
-- leaving the menu wrong until the next rebuild.
-- pl_name registers the playlist as one of yours, which matters for a playlist
-- created seconds ago: it is not in any index built before it existed, and
-- rm_targets only offers playlists listed in `owned`.
function Util.pl_index_patch(pl_id, track_id, present, pl_name)
    if not (pl_id and track_id) then return end
    local idx = mem_get("pl_index") or disk_get(P.pl_index)
    if type(idx) ~= "table" then idx = {owned = {}, tracks = {}} end
    if type(idx.owned) ~= "table" then idx.owned = {} end
    if type(idx.tracks) ~= "table" then idx.tracks = {} end
    if present and pl_name then idx.owned[pl_id] = pl_name end
    local l = idx.tracks[track_id]
    if present then
        if not l then l = {}; idx.tracks[track_id] = l end
        -- Already listed: fall through to the write anyway, because registering
        -- the playlist in `owned` above may still be new information.
        local dup = false
        for _, id in ipairs(l) do if id == pl_id then dup = true; break end end
        if not dup then l[#l+1] = pl_id end
    elseif l then
        for i = #l, 1, -1 do if l[i] == pl_id then table.remove(l, i) end end
        if #l == 0 then idx.tracks[track_id] = nil end
    end
    disk_set(P.pl_index, idx)
    mem_set("pl_index", idx, CACHE_TTL_SHORT)
end

-- Removes every occurrence of the URI, matching the rest of the file: no call
-- site here sends a snapshot_id.
function Util.do_remove_from_playlist(playlist_id, track_id)
    if not (playlist_id and track_id) then return false end
    local token = get_token()
    if not token then return false end
    local body = json.encode({tracks = {{uri = "spotify:track:" .. track_id}}})
    local url = "https://api.spotify.com/v1/playlists/" .. playlist_id .. "/tracks"
    local r = Util.api_write("DELETE", url, token, {body=body})
    if not Util.is2xx(r) then return false end
    Util.bust_playlist_tracks(playlist_id)
    Util.pl_index_patch(playlist_id, track_id, false)
    return true
end

local function api_get_artist_albums(artist_id)
    return cached_fetch("artist_albums_" .. artist_id, P.mass .. "/artist_albums_" .. artist_id .. ".json", CACHE_TTL_LONG, function()
        return Util.paged_fetch("artists/" .. artist_id .. "/albums",
            function(o) return "limit=50&offset=" .. o .. "&include_groups=album,single,compilation" end,
            function(d, items) return #items == 0 or not d.next end)
    end, {revalidate = "artist_albums", revalidate_arg = artist_id})
end

local function api_get_artist_top_tracks(artist_id)
    return cached_fetch("artist_top_" .. artist_id, P.mass .. "/artist_top_" .. artist_id .. ".json", CACHE_TTL_MED, function()
        return api_get("artists/" .. artist_id .. "/top-tracks", Util.with_market())
    end, {revalidate = "artist_top", revalidate_arg = artist_id})
end

local function api_get_artist_related(artist_id)
    return cached_fetch("artist_related_" .. artist_id, P.mass .. "/artist_related_" .. artist_id .. ".json", CACHE_TTL_LONG, function()
        return api_get("artists/" .. artist_id .. "/related-artists")
    end, {revalidate = "artist_related", revalidate_arg = artist_id})
end

local function api_get_tracks(ids)
    if not ids or #ids == 0 then return {} end
    local joined = table.concat(ids, ",")
    local d = api_get("tracks", Util.with_market("ids=" .. joined))
    if not d or not d.tracks then return {} end
    local map = {}
    for _, t in pairs(d.tracks) do if t and t.id then map[t.id] = t end end
    return map
end

-- Same shape as api_get_top_tracks above, deliberately: the per-range
-- cached_fetch, the paged walk, and the medium -> long -> short fall-through
-- with the same "return nil, never {}" rule that makes the fall-through work.
-- That last part is load-bearing here too -- short_term really is empty on a
-- listening history this app has only recently started seeing.
function Util.api_get_top_artists()
    for _, rng in ipairs({"medium_term","long_term","short_term"}) do
        local artists = cached_fetch("top_artists_" .. rng, P.cache .. "/top_artists_" .. rng .. ".json", CACHE_TTL_MED, function()
            local got = 0
            local all = Util.paged_fetch("me/top/artists",
                function(o) return "limit=50&offset=" .. o .. "&time_range=" .. rng end,
                function(d, items)
                    got = got + #items
                    return #items == 0 or not d.next or got >= P.top_max
                end)
            if not all or #all == 0 then return nil end
            return all
        end, {revalidate = "top_artists"})
        if artists then return artists end
    end
end

-- The exact call view_followed_artists makes, so artist rows, Shift+Return
-- actions and the artist hub all behave identically here.
function Util.view_top_artists()
    local ar = Util.api_get_top_artists()
    if not ar or #ar == 0 then rofi_message("No top artists"); return end
    Util.scope({view="top-artists"}, function()
        local entries = {}
        for i, a in ipairs(ar) do entries[i] = display_artist(a) end
        view_browse(entries, ar, "Top Artists" .. SEP .. #ar .. " artists", "artist-list", nil, nil, true)
    end)
end

-- `seed` is the whole seed_* parameter, so a genre shelf and a "More Like" both
-- come through here rather than growing a second copy of the stub repair below.
--
-- Note for later: /recommendations is deprecated for new applications and works
-- only because this client ID predates that. Two features now depend on it, so
-- if Spotify withdraws it for old clients as well, both go at once.
local function api_get_recommendations(seed)
    if not seed or #seed == 0 then return nil end
    local d = api_get("recommendations", Util.with_market(seed .. "&limit=50"))
    if not d or not d.tracks or #d.tracks == 0 then return nil end
    local stubs = {}
    for i, t in pairs(d.tracks) do
        if t and (not t.name or #t.name == 0 or not t.artists or #t.artists == 0) then
            stubs[#stubs+1] = i
        end
    end
    if #stubs > 0 then
        local ids, sidx = {}, {}
        for _, i in ipairs(stubs) do
            local id = d.tracks[i].id
            if id then sidx[id] = i; ids[#ids+1] = id end
        end
        if #ids > 0 then
            local map = api_get_tracks(ids)
            for id, i in pairs(sidx) do if map[id] then d.tracks[i] = map[id] end end
        end
    end
    return d.tracks
end

local function api_get_categories()
    return cached_fetch("categories", P.cache .. "/categories.json", CACHE_TTL_LONG, function()
        local d = api_get("browse/categories", "limit=50")
        if d and d.categories and d.categories.items then return d.categories.items end
    end, {revalidate = "categories"})
end

-- At most this many name-less rows are resolved per shelf. One request each --
-- there is no batch endpoint for playlists -- so it is bounded rather than
-- unlimited, and it happens inside the cached_fetch below so the finished list
-- is what lands on disk. A shelf therefore pays it once per TTL, not per draw.
-- On Util, not a local: the chunk body is one function at Lua's 200-local cap.
Util.CATEGORY_BACKFILL_MAX = 20

local function api_get_category_playlists(cat_id)
    return cached_fetch("category_playlists_" .. cat_id, P.mass .. "/category_playlists_" .. cat_id .. ".json", CACHE_TTL_MED, function()
        -- locale, or names arrive in the account's market language: the Charts
        -- shelf comes back as "أنجح الأغاني - مصر" rather than "Top Songs -
        -- Egypt". Every other string spoot draws is English and the themes use a
        -- Latin mono face, so the menu should match.
        local d = api_get("browse/categories/" .. cat_id .. "/playlists", "limit=50&locale=en_US")
        if not (d and d.playlists and d.playlists.items) then return nil end
        local out, thin = {}, {}
        for _, pl in ipairs(d.playlists.items) do
            -- No id is nothing we can open. A missing NAME is different: the
            -- Made For You shelf returns 15 such rows and they are real
            -- playlists -- one of them is Classical Mix, 50 tracks with artwork
            -- -- the listing just omits the name. They used to draw as
            -- "Unknown", so resolve them rather than dropping them.
            if pl and pl.id then
                out[#out+1] = pl
                if (not pl.name or #pl.name == 0) and #thin < Util.CATEGORY_BACKFILL_MAX then
                    thin[#thin+1] = pl
                end
            end
        end
        for _, pl in ipairs(thin) do
            local full = api_get("playlists/" .. pl.id, "fields=name,owner,images,tracks(total)")
            if full and full.name and #full.name > 0 then
                pl.name   = full.name
                pl.owner  = pl.owner  or full.owner
                pl.images = (pl.images and #pl.images > 0) and pl.images or full.images
                pl.tracks = pl.tracks or full.tracks
            end
        end
        -- A handful are nameless UPSTREAM -- a direct fetch answers "" too -- so
        -- after trying, drop what still cannot be labelled rather than drawing an
        -- "Unknown" row nobody can act on.
        local keep = {}
        for _, pl in ipairs(out) do
            if pl.name and #pl.name > 0 then keep[#keep+1] = pl end
        end
        if #keep == 0 then return nil end
        return keep
    end, {revalidate = "category_playlists", revalidate_arg = cat_id})
end
-- A category shelf costs up to 21 requests to rebuild (the name backfill), which
-- is exactly why its expiry must not land on a menu that is trying to draw.
Util.REVALIDATORS.category_playlists = function(cat_id)
    if cat_id and #cat_id > 0 then return api_get_category_playlists(cat_id) end
end

local function api_get_top_tracks()
    for _, rng in ipairs({"medium_term","long_term","short_term"}) do
        local tracks = cached_fetch("top_tracks_" .. rng, P.cache .. "/top_tracks_" .. rng .. ".json", CACHE_TTL_MED, function()
            -- 50 is the per-request ceiling, so more means paging. Reuses
            -- Util.paged_fetch rather than hand-rolling another offset loop;
            -- `got` is what stops it, since the account reports 1578 available.
            local got = 0
            local all = Util.paged_fetch("me/top/tracks",
                function(o) return Util.with_market("limit=50&offset=" .. o .. "&time_range=" .. rng) end,
                function(d, items)
                    got = got + #items
                    return #items == 0 or not d.next or got >= P.top_max
                end)
            -- MUST return nil, not an empty table: this function walks
            -- medium_term -> long_term -> short_term and uses nil to fall
            -- through to the next range. Util.paged_fetch answers {} for an
            -- empty result, which would look like success and stop the walk.
            if not all or #all == 0 then return nil end
            return all
        end, {revalidate = "top_tracks"})
        if tracks then return tracks end
    end
end

-- Spotify's editorial shelf. Answers a `message` headline ("Popular Playlists")
-- alongside the list, which is worth showing since it is the only label the
-- shelf has.
--
-- On the Nov 2024 deprecation list: it works for this client only because the
-- id predates the cutoff, the same grandfathering that keeps More Like This and
-- Related Artists alive. Every caller must tolerate nil.
local function api_get_featured_playlists()
    return cached_fetch("featured_playlists", P.cache .. "/featured_playlists.json", CACHE_TTL_MED, function()
        local d = api_get("browse/featured-playlists", "limit=50")
        local it = d and d.playlists and d.playlists.items
        if not (it and #it > 0) then return nil end
        -- Carried alongside the items so the view can title itself.
        return {message = d.message, items = it}
    end, {revalidate = "featured_playlists"})
end

local function api_get_new_releases()
    return cached_fetch("new_releases", P.cache .. "/new_releases.json", CACHE_TTL_LONG, function()
        local d = api_get("browse/new-releases", "limit=50")
        if d and d.albums and d.albums.items and #d.albums.items > 0 then return d.albums.items end
    end, {revalidate = "new_releases"})
end

-- The plain revalidators: every one of them is "call the fetcher again", so they
-- are one table rather than eleven hand-written assignments that could only ever
-- differ by typo. Placed here because this is the first point at which all of
-- them exist; genre_seeds lives several thousand lines further down and is
-- reached through Util at call time, which is why it alone needs a wrapper.
--
-- Not here, and each for its own reason stated at its definition:
--   playlist_meta / my_playlists / category_playlists -- registered at their
--     sites because they do more than re-call one function.
--   library -- probes before it re-pages.
--   playlist_tracks -- snapshot_id makes a stale copy WRONG, not merely old, so
--     blocking on it is correct.
--   search / lyrics -- keyed on arbitrary text, with nothing to refresh into.
for name, fn in pairs({
    album             = api_get_album,
    artist_albums     = api_get_artist_albums,
    artist_top        = api_get_artist_top_tracks,
    artist_related    = api_get_artist_related,
    top_artists       = Util.api_get_top_artists,
    top_tracks        = api_get_top_tracks,
    categories        = api_get_categories,
    featured_playlists = api_get_featured_playlists,
    new_releases      = api_get_new_releases,
    me_profile        = api_get_me,
    genre_seeds       = function() return Util.api_get_genre_seeds() end,
}) do
    Util.REVALIDATORS[name] = fn
end

local function lyrics_to_lines(plain)
    if not plain then return nil end
    local lines = {}
    for line in plain:gmatch("[^\n]+") do
        if #line > 0 then lines[#lines+1] = line end
    end
    return #lines > 0 and lines or nil
end

local function parse_lrc(synced)
    if not synced then return nil end
    local times, lines = {}, {}
    for line in synced:gmatch("[^\n]+") do
        local ts, text = line:match("%[(%d+:%d+%.%d+)%](.*)")
        if ts and text then
            text = text:gsub("^%[[^%]]*%]", ""):match("^%s*(.-)%s*$")
            if #text > 0 then
                local min, sec = ts:match("(%d+):(%d+%.%d+)")
                if min and sec then
                    times[#times+1] = tonumber(min) * 60 + tonumber(sec)
                    lines[#lines+1] = text
                end
            end
        end
    end
    return #times > 0 and {lines=lines, times=times} or nil
end

local function normalize_str(s)
    return (s or ""):lower():gsub("[^%w%s]", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

Util.http_get = function(url)
    local r = shell("curl -s --max-time 5 -w '\n%{http_code}' " .. shell_quote(url))
    local status = tonumber(string.match(r or "", "\n(%d+)\n?$")) or 0
    local body = string.match(r or "", "^(.-)\n%d+\n?$") or r or ""
    return body, status
end

-- Returns (result, definitive). definitive is false when the request itself
-- failed (offline / timeout / non-200), so callers must NOT treat that as
-- "this track has no lyrics". Only a successful lrclib response counts.
local function api_get_lyrics(track_name, artist_name, album_name, duration)
    if not track_name or #track_name == 0 then return nil, false end
    local get_url = "https://lrclib.net/api/get?track_name=" .. url_encode(track_name)
    if artist_name and #artist_name > 0 then get_url = get_url .. "&artist_name=" .. url_encode(artist_name) end
    if album_name and #album_name > 0 then get_url = get_url .. "&album_name=" .. url_encode(album_name) end
    if duration and duration > 0 then get_url = get_url .. "&duration=" .. tostring(math.floor(duration)) end
    local body = Util.http_get(get_url)
    local d = safe_decode(body)
    if d then
        local synced = parse_lrc(d.syncedLyrics)
        if synced then return synced, true end
        if d.plainLyrics then
            local lines = lyrics_to_lines(d.plainLyrics)
            if lines then return {lines=lines}, true end
        end
    end

    local search_url = "https://lrclib.net/api/search?track_name=" .. url_encode(track_name)
    if artist_name and #artist_name > 0 then search_url = search_url .. "&artist_name=" .. url_encode(artist_name) end
    -- Only the SEARCH status is consulted (a failed request must not be reported
    -- as "definitively no lyrics"); the get status was never read.
    local gst
    body, gst = Util.http_get(search_url)
    d = safe_decode(body)
    if not d or #d == 0 then return nil, gst == 200 end

    local norm_track  = normalize_str(track_name)
    local norm_artist = normalize_str(artist_name)
    local norm_album  = normalize_str(album_name)
    local best, best_score = nil, -1
    for _, entry in ipairs(d) do
        local score = 0
        if normalize_str(entry.trackName)  == norm_track  then score = score + 10 end
        if normalize_str(entry.artistName) == norm_artist then score = score + 10 end
        if norm_album ~= "" and normalize_str(entry.albumName) == norm_album then score = score + 3 end
        if duration and entry.duration then
            local diff = math.abs(duration - entry.duration)
            if diff <= 2 then score = score + 5
            elseif diff <= 10 then score = score + 2 end
        end
        if score > best_score then
            local synced = parse_lrc(entry.syncedLyrics)
            if synced then best = synced; best_score = score
            elseif entry.plainLyrics then
                local lines = lyrics_to_lines(entry.plainLyrics)
                if lines then best = {lines=lines}; best_score = score end
            end
        end
    end
    return best, true
end

local function resolve_lyrics_state(item)
    local id = item and item.id
    if not id or #id == 0 then return nil end
    local known = Util.track_has_lyrics(id)
    if known ~= nil then return known end
    local disk   = P.lyrics .. "/lyrics_" .. id .. ".json"
    local marker = P.lyrics .. "/nolyr_" .. id .. ".json"
    local dur = item.duration_ms and tostring(math.floor(item.duration_ms / 1000)) or ""
    Util.spawn_self({"--prefetch-lyrics", id, item.name or "", artist_names(item),
        (item.album and item.album.name) or "", dur})
    -- Backs off instead of five flat 0.3s waits: same 1.5s worst case, but the
    -- common case (the detached prefetch answers quickly) unblocks the action
    -- menu in 0.1s rather than 0.3s.
    for _, wait in ipairs({0.1, 0.2, 0.3, 0.4, 0.5}) do
        if disk_get(disk, P.ttl_lyrics) ~= nil then Util.lyr_bust(id); return true end
        if disk_get(marker, P.ttl_lyrics) ~= nil then return false end
        os.execute("sleep " .. wait)
    end
    return nil
end

-- VIEW: BROWSE

view_browse = function(entries, items, mesg, ctx, ctx_type, ctx_id, no_status, art_path)
    local is_track = ctx == "liked" or ctx == "top-tracks"
                  or ctx == "your-queue"
                  or ctx == "liked-by-artist" or ctx == "top-by-artist"
                  or ctx == "recommendations"
                  or ctx == "recently-played" or ctx == "genre"
                  -- A show's EPISODE list. It carries no ctx_type/ctx_id pair
                  -- because there is no context_uri to build from them: Spotify
                  -- documents context_uri for albums, artists and playlists
                  -- only, and a spotify:show: context fails inside librespot's
                  -- connect-state resolver with nothing surfacing back here. So
                  -- episodes take do_play's `uris` branch, exactly as Liked
                  -- Tracks and Top Tracks already do.
                  or ctx == "show"
                  -- Episode lists that are not one podcast's own: Saved
                  -- Episodes and Latest Episodes. Same reasoning as "show" --
                  -- no context_uri exists for either, so they play through
                  -- do_play's uris branch.
                  or ctx == "episode-list"
                  or (ctx_type and ctx_id)
    local is_album_list   = ctx == "album-list" or (ctx_type == "album" and not ctx_id) or ctx == "album"
    local is_album_grid   = ctx == "album-list" or (ctx_type == "album" and not ctx_id)
    local is_artist_list  = ctx == "artist-list"
    local is_playlist_list = (ctx_type == "playlist" and not ctx_id)
    local is_show_grid    = ctx == "show-list"
    -- The search's one results list, mixing all four types. "track", "artist",
    -- "search-album" and "search-playlist" used to arrive here too, one per
    -- single-category search; every one of them died with the type picker, and
    -- no caller passes them now.
    local is_search       = ctx == "search"
    -- `or nil` to match what the CALLERS passed. format_entries keys its memo on
    -- tostring() of each flag, and callers wanting the default pass nil -- so a
    -- literal `false` here made "nil" ~= "false", and the first refresh of every
    -- such list rebuilt the whole entry array for nothing.
    -- ctx == "show" is here for the reason the comment above rebuild() gives:
    -- Util.open_show builds its rows with this flag set, so leaving it out made
    -- the first refresh re-render every episode WITH the podcast name it had
    -- just been asked to leave off.
    local hide_single_artist = (ctx == "album" or ctx == "liked-by-artist"
                                or ctx == "top-by-artist" or ctx == "show") or nil

    local v_key = ctx .. "|" .. (ctx_type or "") .. "|" .. (ctx_id or "")
    -- Left nil so rofi_dmenu's pos_key restores the remembered row. It is only
    -- assigned to force a specific row (jump-to-playing-track, or holding the
    -- cursor after a selection); an explicit sel always wins over pos_key.
    local pre_sel = nil
    local album_theme = nil
    -- write_art_theme's path is unique per call, so this view owns the file and
    -- must remove it. It never did, so a long session leaked one /tmp theme per
    -- album opened. Tied to the BLOCK, not an exit path -- this function returns
    -- from eight places -- the same guarantee Util.scope gets from its pcall.
    -- A nested view has its own path and guard, so it cannot delete the outer's.
    local _theme_guard <close> = setmetatable({}, {__close = function()
        if album_theme then os.remove(album_theme) end
    end})
    if art_path then
        -- A cover the CALLER resolved -- a playlist's own artwork. Same
        -- album.rasi backdrop, but the image must not come from items[1], which
        -- for a playlist is merely its first track and has nothing to do with
        -- the playlist. Passing "" is meaningful: write_art_theme strips the
        -- background-image line, so an artless list still gets the layout.
        album_theme = Util.write_art_theme("album", art_path)
    elseif ctx == "album" then
        local a = items[1] and items[1].album
        local art_url = a and a.images and a.images[1] and a.images[1].url or nil
        -- Backdrop only: never make opening an album wait on the CDN. Named
        -- `cover` rather than art_path so it cannot shadow the parameter above.
        local cover = art_url and ensure_art(Util.art_url(art_url, "1e02"), nil, Util.ART_DECOR) or ""
        album_theme = Util.write_art_theme("album", cover)
    end
    -- The theme this list actually draws with. Deliberately NOT folded into
    -- album_theme: that is a per-call file this view owns and the <close> guard
    -- above deletes it, whereas THEME_RESULTS is resolved once at startup and
    -- shared for the app's lifetime -- assigning it there would delete it out
    -- from under every later search.
    --
    -- nil for everything else, which lets rofi_dmenu fall back to its usual
    -- thumbs/plain-list selection.
    local view_theme = album_theme or (is_search and Util.THEME_RESULTS) or nil
    -- Regenerates rows carrying live state (▶ marker, liked heart). Handed to
    -- rofi_dmenu as `refresh` so a redraw from inside -- a track played or liked
    -- in a hotkey-opened action menu -- shows the new state. Album, artist and
    -- playlist rows have no such state and are left alone, which also preserves
    -- album_thumbs' \0icon suffixes. Must match the flags the caller built
    -- `entries` with, or the first refresh re-renders differently.
    local hide_liked = (ctx == "liked") or nil
    local function rebuild()
        if is_track then
            entries = format_entries(items, nil, hide_liked, hide_single_artist)
        elseif is_search then
            entries = {}
            for i, it in ipairs(items) do entries[i] = Util.format_mixed_item(it, i) end
        elseif is_album_list and not is_track then
            -- Album rows carry live state now too: a single played from this
            -- list has to take the ▶ marker without the list being reopened.
            -- Guarded on `not is_track` because an album's TRACK list is
            -- is_album_list as well, and its rows are handled above.
            entries = Util.album_entries(items, true)
        end
        -- The row the menu is about to open on, resolved the same way
        -- rofi_dmenu resolves it, so the covers fetched before the draw are the
        -- ones about to be rendered.
        local at = pre_sel or Util.pos_get(v_key)
        if is_album_grid then Util.album_thumbs(entries, items, nil, at, v_key)
        elseif is_playlist_list then Util.album_thumbs(entries, items, "playlist", at, v_key)
        -- "show" rather than the default "album": shows are hash-keyed like
        -- albums (they are absent from P.art_kinds on purpose), but the kind is
        -- part of Util._thumb_memo's key, so naming it keeps a show grid's memo
        -- from colliding with an album grid's.
        elseif is_show_grid then Util.album_thumbs(entries, items, "show", at, v_key) end
        return entries
    end
    while true do
        -- ctx_type/ctx_id/entries ride along so Shift+Return hands the action
        -- menu the list it came from -- that is what offers Remove from Playlist
        -- for the playlist being browsed, and drops the row after removal.
        -- Album/artist/playlist rows open content on Return and actions on
        -- Shift+Return, so those lists claim the key. An album's TRACK list is
        -- is_album_list too, but is_track wins the dispatch and keeps the default.
        local idx = rofi_dmenu(entries, {prompt=ctx or "Browse", mesg=mesg, custom=false, by_index=true, markup=(is_track or is_search or is_playlist_list or is_artist_list or is_album_list or is_show_grid), theme=view_theme, sel=pre_sel, pos_key=v_key, no_status=no_status or is_search, thumbs=is_album_grid or is_playlist_list or is_show_grid, items=items, entries=entries, ctx_type=ctx_type, ctx_id=ctx_id, refresh=rebuild,
            -- is_show_grid claims Shift+Return for the show action menu. The
            -- EPISODE list deliberately does not: it is is_track, and a track
            -- list must leave Shift+Return to rofi_dmenu's default handler,
            -- which is what routes an episode to its own action menu.
            -- The search list claims Tab for its type picker, so it must not
            -- bubble up as the trail jump. Same opt-in the trail menu itself
            -- uses; every other list here leaves Tab alone.
            tab_select=is_search or nil,
            alt_select=((is_album_list and not is_track) or is_artist_list or is_playlist_list or is_search or is_show_grid) or nil})
        -- Read before anything else: the next rofi_dmenu call clears the flag.
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        -- Handed back to Util.open_search_results rather than paged here: this
        -- function never had the results object, only one page's worth of rows,
        -- and giving it that just to switch pages would widen its signature for
        -- one caller. A flag read immediately, like Util.alt_pressed above.
        if Util.tab_pressed then
            Util.tab_pressed = false
            if is_search then Util.search_tab = true; return end
        end
        if jump_to_track_pending then
            jump_to_track_pending = false
            if current_id then
                pre_sel = 0
                for i = 1, #items do
                    if items[i].id == current_id then pre_sel = i - 1; break end
                end
            end
            goto br_next
        elseif not idx then return
        elseif idx < 1 or idx > #items then goto br_next
        else
            local item = items[idx]

        if is_track then
            Util.play_or_toggle(item, ctx_type, ctx_id, items, idx)
            rebuild()
            pre_sel = idx - 1
        elseif is_search then
            local st = item._stype
            -- Tracks and episodes are the two PLAYABLE result kinds, and they
            -- behave identically here: Shift+Return opens an action menu (which
            -- view_actions routes by type), Return plays with the other rows of
            -- its own kind as continuation. Sharing the branch rather than
            -- copying it is what keeps the sub-list filter below correct for
            -- both -- it is the reason the filter exists at all.
            local playable = (st == "tracks" or st == "episodes")
            if playable and alt then
                -- This list claims Shift+Return for its album and playlist rows,
                -- so a track row has to reproduce what rofi_dmenu's default
                -- handler would have done for it.
                if not Util.fast_now_track() then last_playback = 0; get_playback() end
                view_actions(item, ctx_type, ctx_id, items, idx, entries)
                if jump_to_track_pending then return end
                rebuild()
                pre_sel = idx - 1
            elseif playable then
                -- Only rows of the SAME kind, so playback continues through the
                -- results without stepping onto an album or artist row.
                local tctx, tcidx = nil, nil
                for _, it in ipairs(items) do
                    if it._stype == st then
                        if not tctx then tctx = {} end
                        tctx[#tctx+1] = it
                        if it == item then tcidx = #tctx end
                    end
                end
                Util.play_or_toggle(item, ctx_type, ctx_id, tctx, tcidx)
                -- Deliberately no get_playback() here, matching the is_track
                -- branch above. Within 5s it self-throttles to a no-op; past
                -- that it is a ~300ms round trip that can still answer with the
                -- PREVIOUS track, dragging the marker off the row just picked --
                -- the race Util.sync_now's P.recent_cmd_at guard exists to stop.
                rebuild()
                pre_sel = idx - 1
            elseif st == "albums" then
                if not alt or album_action_menu(item) then
                    -- browse_album reports its own failure now. `alt` is true only
                    -- when the action menu ran, i.e. "Open Album" was asked for
                    -- by name -- which must open even a single.
                    Util.open_album(item, alt)
                    if jump_to_track_pending then return end
                    -- A single played rather than opened; this list mixes types,
                    -- so its rebuild is what puts the marker on the album row.
                    rebuild()
                end
            elseif st == "artists" then
                Util.open_artist(item, alt)
                if jump_to_track_pending then return end
            elseif st == "playlists" then
                if not alt or playlist_action_menu(item) then
                    Util.open_playlist(item)
                    if jump_to_track_pending then return end
                end
            elseif st == "shows" then
                if not alt or Util.show_action_menu(item) then
                    Util.open_show(item)
                    if jump_to_track_pending then return end
                end
            end
            -- The playable kinds went through rebuild() above, which re-renders
            -- the whole list; everything else repaints only the row it touched.
            if not playable then
                entries[idx] = Util.format_mixed_item(item, idx)
                pre_sel = idx - 1
            end
        elseif is_album_list then
            -- Return opens the album; only Shift+Return detours through an
            -- action menu. Saved Albums keeps its own list (it has Remove from
            -- Library, whose success path prunes the row and restarts the loop
            -- below -- which is why it stays inline here rather than moving into
            -- the shared album_action_menu).
            local do_open = not alt
            -- Set by either action list's "Open Album" row. Kept apart from
            -- do_open because the two mean different things: plain Return on a
            -- single plays it, asking for the album by name opens it.
            local from_menu = false
            if alt and ctx == "album-list" then
                local acts = {"Open Album", "Remove from Library", "Albumart", "Copy Web Link", "Album Details"}
                if (item.artists or {})[1] then table.insert(acts, 2, "Go to Artist") end
                -- act_alt, not alt: this list's own Shift+Return is already bound
                -- to the `alt` above, which is what opened this menu.
                local action = rofi_dmenu(acts, {prompt=item.name or "Album", mesg=(item.name or "Album") .. album_suffix(item), custom=false, theme=THEME_SUB, no_status=true, markup=true, pos_key="album-list-ac:" .. (item.id or ""), alt_select=true})
                local act_alt = Util.alt_pressed
                Util.alt_pressed = false
                if action == "Open Album" then
                    do_open = true; from_menu = true
                elseif action == "Remove from Library" then
                    -- Shares Util.lib_write with the album action menu; only
                    -- the row-pruning below is specific to this list.
                    if Util.lib_write("album", item.id, false) then
                        rofi_message("Removed from library")
                        table.remove(items, idx)
                        entries = Util.album_entries(items)
                        mesg = "Saved Albums" .. SEP .. #items .. " albums"
                        if #items == 0 then return end
                        goto br_next
                    else rofi_message("Failed to remove") end
                elseif action == "Copy Web Link" then
                    copy_spotify_url("album", item.id)
                    rofi_message("Copied web link")
                elseif action == "Go to Artist" then
                    local ar = (item.artists or {})[1]
                    if ar then
                        Util.open_artist({id=ar.id, name=ar.name or ""}, act_alt)
                        if jump_to_track_pending then return end
                    end
                elseif action == "Albumart" then
                    view_art({album=item, name=item.name, artists=item.artists})
                elseif action == "Album Details" then
                    Util.view_album_details(item)
                end
            elseif alt then
                do_open = album_action_menu(item)
                from_menu = do_open
            end
            if do_open then
                -- browse_album reports its own failure now.
                Util.open_album(item, from_menu)
                if jump_to_track_pending then return end
                -- Util.open_album may have PLAYED this row rather than opened it
                -- (a single), so the marker has to be re-derived before the redraw.
                rebuild()
            end
            pre_sel = idx - 1
        elseif is_artist_list then
            Util.open_artist(item, alt)
            entries[idx] = ctx == "artist" and string.format("%2d. %s", idx, display_artist(item)) or display_artist(item)
            pre_sel = idx - 1
        elseif is_playlist_list then
            if not alt or playlist_action_menu(item) then Util.open_playlist(item) end
            pre_sel = idx - 1
        -- No row rewrite, unlike the artist arm: this grid carries \0icon
        -- suffixes from Util.album_thumbs, and a show has no live playback state
        -- worth re-rendering at the cost of losing its thumbnail.
        elseif is_show_grid then
            if not alt or Util.show_action_menu(item) then Util.open_show(item) end
            pre_sel = idx - 1
        end end
        ::br_next::
    end
end

browse_album = function(album_id, mesg)
    local ad = api_get_album(album_id)
    -- Reported HERE rather than at the call sites: 6 of the 8 ignored the false
    -- return, so pasting a URL for a dead or restricted album used to do nothing
    -- at all -- no view, no message. The two causes are worth telling apart.
    if not ad then rofi_message("Failed to load album"); return false end
    if not ad.tracks or #ad.tracks == 0 then
        local mk = Util.market()
        rofi_message("Album has no available tracks" .. (mk and (" in " .. mk) or ""))
        return false
    end
    -- Derived here when the caller has no album object to build it from, which
    -- is the case on a warm start.
    mesg = mesg or ((ad.name or "Album") .. album_suffix(ad))
    -- Context on the view you asked for, rather than a blocking message.
    if ad.unavail then
        local mk = Util.market()
        mesg = mesg .. SEP .. "unavailable" .. (mk and (" in " .. mk) or "")
    end
    -- Util.scope hands back whatever the body returns, and this MUST stay
    -- returned: browse_album otherwise answers nil on success, which reads as
    -- failure to anything testing it (it once fired a "Failed to load album"
    -- message every time you backed out of an album you had opened fine).
    return Util.scope({view="album", album_id=album_id, album_name=ad.name or "Album"}, function()
    local te = format_entries(ad.tracks, nil, nil, true)
    view_browse(te, ad.tracks, mesg, "album", "album", album_id)
    return true
end)
end

-- What a SELECTED album row does, as opposed to what browse_album does. A single
-- -- one track -- plays that track instead of opening a list of one, which is the
-- whole point of marking singles in display_album.
--
-- Deliberately NOT folded into browse_album: that function is what
-- reg("album", …) replays on a warm start and what a pasted album URL opens, and
-- neither may start music on its own. Only a deliberate selection comes here.
--
-- The mesg every caller used to build by hand lives here now too, which is what
-- kept six copies of the same concatenation in step.
-- `want_browse` is set by the callers that came through an action menu's "Open
-- Album" row. Asking for the album by name means the album, even when it holds
-- one track -- otherwise that row played the single and the one way to actually
-- SEE a single's album did not exist.
function Util.open_album(al, want_browse)
    if not (al and al.id) then return false end
    if al.total_tracks == 1 and not want_browse then
        local ad = api_get_album(al.id)
        -- api_get_album filters to what our market will actually serve, so an
        -- album that says one track can still arrive with none, or (a
        -- mislabelled compilation) with several. Anything but exactly one falls
        -- through to the ordinary view rather than guessing which track you meant.
        if ad and ad.tracks and #ad.tracks == 1 then
            -- The same call a track row makes, so a single behaves exactly like
            -- one: play it if it is not the current track, otherwise pause or
            -- resume. Pressing Return twice used to restart it from the top.
            Util.play_or_toggle(ad.tracks[1], "album", al.id, ad.tracks, 1)
            return true
        end
    end
    return browse_album(al.id, (al.name or "Unknown") .. album_suffix(al))
end

-- A podcast's episode list. The one function both the live menu and
-- reg("show", …) call, per the rule the trail depends on: opening a view is ONE
-- function, so a replayed step behaves exactly like a freshly opened one.
--
-- Takes an id, not a show object, because that is all a replayed stack entry
-- can carry -- `name` is only a label to save the fetch showing a blank header.
function Util.open_show(show_id, show_name)
    if type(show_id) == "table" then show_id, show_name = show_id.id, show_id.name end
    if not show_id then return false end
    local sd = Util.api_get_show(show_id)
    if not sd then rofi_message("Failed to load podcast"); return false end
    local eps = sd.episodes or {}
    if #eps == 0 then
        local mk = Util.market()
        rofi_message("Podcast has no available episodes" .. (mk and (" in " .. mk) or ""))
        return false
    end
    -- Before the rows are built: display_episode reads resume_point for its
    -- progress figure and its played-dimming, and the copy inside the show cache
    -- can be a day old.
    Util.merge_resume_points(show_id, eps)
    local name = sd.name or show_name or "Podcast"
    -- Resolved here and handed to view_browse as art_path, the way
    -- Util.open_playlist does it: items[1] is an EPISODE, so the ctx == "album"
    -- backdrop branch would have nothing of the show's to look at. Shows are
    -- hash-keyed art, so this is ensure_art rather than Util.keyed_art.
    local url = sd.images and sd.images[1] and sd.images[1].url
    local cover = url and ensure_art(Util.art_url(url, "1e02"), nil, Util.ART_DECOR) or nil
    Util.scope({view="show", show_id=show_id, show_name=name}, function()
        -- hide_single_artist so the show's own name is not repeated down every
        -- row of its own episode list -- the same argument browse_album makes
        -- for an album's artist.
        local te = format_entries(eps, nil, nil, true)
        -- ctx_id without a ctx_type, deliberately. The pair is what do_play
        -- turns into a context_uri, and a spotify:show: context is the one thing
        -- this must not produce -- but ctx_id alone still reaches view_browse's
        -- v_key, which is what gives each podcast its OWN remembered cursor
        -- instead of all of them sharing "show||".
        view_browse(te, eps, name .. SEP .. #eps .. " episodes", "show", nil, show_id, nil, cover)
    end)
    return true
end

-- VIEW: ALBUM ART

-- Tracks and albums carry their art on `item.album.images`; a playlist carries
-- its own on `item.images`, and it is the PLAYLIST's cover that must show, not
-- the first track's. `item.owner` marks that case: a playlist has no artists, so
-- it captions itself with who made it.
view_art = function(item)
    local imgs = item and ((item.album and item.album.images) or item.images)
    if not (imgs and imgs[1] and imgs[1].url) then
        rofi_message("No album art available"); return
    end
    local art_path
    if item.owner then
        -- Cached by id under the playlist kind, not by art hash: an editorial
        -- cover is replaced in place, and a hash-named file would strand the old
        -- one on every weekly refresh.
        art_path = Util.keyed_art("playlist", item, true, true, nil)
    else
        art_path = ensure_art(Util.art_url(imgs[1].url), "highres")
    end
    if not art_path then rofi_message("No album art available"); return end
    -- Util.subtitle, not artist_names: it answers the show for an episode and
    -- the publisher for a podcast, both of which have no artists at all and
    -- captioned themselves with a dangling separator before.
    local by = item.owner and (item.owner.display_name or item.owner.id or "Spotify")
        or Util.subtitle(item)
    local mesg = Util.pango_escape((item.name or "Unknown") .. (by ~= "" and (SEP .. by) or ""))
    local entry_tf = Util.tmpfile("art.in")
    local ef = io.open(entry_tf, "w")
    if ef then
        ef:write("\0icon\x1f" .. art_path .. "\n")
        ef:close()
    end
    -- Same reason as rofi_message: bind the back combo so a Backspace here is
    -- consumed by this window instead of reaching the menu underneath.
    Util.bs_launch(THEME_ART)
    os.execute("rofi -dmenu -config " .. shell_quote(P.dir.."/style/config.rasi") .. " -theme " .. shell_quote(THEME_ART)
        .. " -mesg " .. shell_quote(mesg)
         .. " -markup-rows -no-custom"
        .. " -kb-custom-1 'Control+Shift+Delete'"
        .. " < " .. shell_quote(entry_tf)
        .. " > /dev/null 2>/dev/null")
    os.remove(entry_tf)
end

-- VIEW: TRACK ACTIONS

-- An episode's action menu. A sibling of view_actions rather than a branch
-- inside it: an episode has no like state, no album, no artists, no playlist
-- membership and no lyrics, so it shares exactly one row with a track's menu and
-- would otherwise mean five dimmed-forever rows and a second meaning for half of
-- view_actions' locals. Albums, artists and playlists each have their own menu
-- for the same reason.
--
-- A real scoped view, unlike album_action_menu: it is reached from a track-like
-- list where the trail already names the podcast, and its own reg entry is what
-- makes a warm start replay it as an EPISODE menu -- reg("action") rebuilds a
-- stub with no `type`, so a replayed episode would otherwise come back as a
-- track.
function Util.view_episode_actions(item, ctx_type, ctx_id, all_items, cidx)
    return Util.scope({view="episode-action", episode_id=item.id,
                  episode_name=item.name or "",
                  show_id=(item.show and item.show.id) or nil,
                  show_name=(item.show and item.show.name) or nil,
                  track_duration_ms=item.duration_ms or 0,
                  episode_unavail=item.unavail or nil,
                  from_current=(item.id ~= nil and item.id == current_id) or nil}, function()
    Util.sync_now()
    local actions, akeys = {"Play"}, {"play"}
    local seek_idx = #actions + 1
    actions[seek_idx] = "Seek"; akeys[seek_idx] = "seek"
    actions[#actions+1] = "Add to Queue"; akeys[#akeys+1] = "queue"
    actions[#actions+1] = "Go to Podcast"; akeys[#akeys+1] = "show"
    actions[#actions+1] = "Copy Web Link"; akeys[#akeys+1] = "url"
    actions[#actions+1] = "Podcast Art"; akeys[#akeys+1] = "art"
    actions[#actions+1] = "Episode Details"; akeys[#akeys+1] = "details"

    -- Same contract as view_actions' rebuild_actions: volatile labels derived
    -- from live state on every draw, and rows dimmed rather than removed so a
    -- fixed index never shifts under the cursor.
    local DIM = '<span foreground="' .. Util.DIM .. '">'
    local function rebuild_actions()
        local playing_this = item.id ~= nil and item.id == current_id
        actions[1]        = playing_this and (is_playing and "Pause" or "Resume")
                            or (item.unavail and Util.markup(DIM .. 'Play</span>') or "Play")
        actions[seek_idx] = playing_this and "Seek" or Util.markup(DIM .. 'Seek</span>')
        return actions
    end
    rebuild_actions()

    local ac_key = "ep-ac:" .. (item.id or "")
    while true do
        local pre_sel = Util.pos_row(ac_key, akeys)
        -- `current` is carried for Alt+a, which opens this episode's art rather
        -- than the playing track's. It also means Shift+Return nests a second
        -- copy of this menu, exactly as it does in view_actions -- pointless
        -- here, since no row of this one does anything different on alt, but
        -- harmless (Backspace pops the one level) and consistent with the track
        -- menu, which is worth more than special-casing the key away.
        local sel = rofi_dmenu(actions, {prompt="Episode", mesg=function() return track_mesg(item) end,
            custom=false, theme=THEME_SUB, no_status=true, markup=true, sel=pre_sel,
            current=item, ctx_type=ctx_type, ctx_id=ctx_id, refresh=rebuild_actions})
        if not sel then return end
        local clean = Util.strip_markup(sel)
        local key
        for i, a in ipairs(actions) do
            if Util.strip_markup(a) == clean then key = akeys[i]; Util.pos_put(ac_key, key); break end
        end
        if key == "play" then
            -- The same call an episode ROW makes, so the menu and the list agree:
            -- play it if it is not current, otherwise pause or resume. do_play
            -- derives the resume position from item.resume_point itself.
            Util.play_or_toggle(item, ctx_type, ctx_id, all_items, cidx)
        elseif key == "seek" then
            if item.id == current_id then view_seek(item)
            else rofi_message("Seek only works on the playing episode") end
        elseif key == "queue" then do_add_queue(item)
        elseif key == "show" then
            local sid = item.show and item.show.id
            if sid then
                Util.open_show(sid, item.show.name)
                if jump_to_track_pending then return end
            else rofi_message("Episode carries no podcast") end
        elseif key == "url" then
            copy_spotify_url("episode", item.id)
            rofi_message("Copied web link")
        elseif key == "art" then
            -- view_art resolves item.images, and the synthetic show patched on by
            -- Util.api_get_show is what gives an episode without its own artwork
            -- the podcast's cover to fall back to.
            view_art({images=(item.images and #item.images > 0) and item.images
                             or (item.show and item.show.images),
                      name=item.name, show=item.show})
        elseif key == "details" then Util.view_episode_details(item) end
        if jump_to_track_pending then return end
        rebuild_actions()
    end
    end)
end

view_actions = function(item, ctx_type, ctx_id, all_items, cidx, entries)
    -- Episodes get their own menu. Dispatching HERE rather than at each call
    -- site covers every entry point at once: rofi_dmenu's Shift+Return handler,
    -- Alt+Return on the current track, the search list, an action-on-action, a
    -- pasted URL, and reg("action")'s replay.
    if item and item.type == "episode" then
        return Util.view_episode_actions(item, ctx_type, ctx_id, all_items, cidx)
    end
    -- Action-on-action is a real extra level now that rofi_dmenu redraws the
    -- menu underneath instead of closing it; popping the parent would leave a
    -- visible menu with no stack entry.
    -- from_current: was this opened on the then-playing track? A warm start uses
    -- it to decide whether to restore the named track or whatever plays now --
    -- without it every restored action menu jumped to the current track. `or
    -- nil` keeps it out of session.json so older files restore their own track.
    -- ctx_type/ctx_id restore the list context; all_items/cidx cannot be, so a
    -- replayed menu can remove the track but not prune the row.
    return Util.scope({view="action", track_id=item.id, track_name=item.name or "",
                  track_artists=item.artists or {}, track_album=item.album or {},
                  track_duration_ms=item.duration_ms or 0,
                  -- Carried so a menu restored on a warm start still knows the
                  -- track cannot play here. `or nil` keeps it out of session.json
                  -- when false, like from_current below, so older session files
                  -- load unchanged.
                  track_unavail=item.unavail or nil,
                  ctx_type=ctx_type, ctx_id=ctx_id,
                  from_current=(item.id ~= nil and item.id == current_id) or nil}, function()
    -- Both the mesg and the volatile Play/Pause/Seek/Like labels are derived
    -- from the now-playing globals, and nothing on the way in refreshed them --
    -- so reopening this menu after the track changed (or was paused) elsewhere
    -- showed whatever state the process last happened to observe.
    Util.sync_now()
    local is_liked = item.id and liked[item.id]
    resolve_lyrics_state(item)

    -- Every playlist of yours this track sits in, so removal is offered wherever
    -- you found the track -- Liked Tracks, a search, Recently Played -- not only
    -- while browsing the playlist itself. The playlist you navigated from goes
    -- first so it stays the obvious default. Editorial playlists are excluded:
    -- Spotify refuses writes to them, so listing them would only ever fail.
    local rm_targets = {}
    local seen_pl = {}
    local pidx = item.id and Util.pl_index() or nil
    local owned = (type(pidx) == "table" and pidx.owned) or {}
    if ctx_type == "playlist" and ctx_id and owned[ctx_id] then
        rm_targets[1] = {id = ctx_id, name = owned[ctx_id], from_ctx = true}
        seen_pl[ctx_id] = true
    end
    if type(pidx) == "table" and type(pidx.tracks) == "table" and item.id then
        for _, pid in ipairs(pidx.tracks[item.id] or {}) do
            if owned[pid] and not seen_pl[pid] then
                seen_pl[pid] = true
                rm_targets[#rm_targets+1] = {id = pid, name = owned[pid]}
            end
        end
    end

    -- akeys[i] names row i independently of what it currently reads. rebuild_actions
    -- below relabels Play/Pause/Resume, Like/Unlike and three dim states in place,
    -- so remembering the cursor by label meant reopening this menu after liking or
    -- playing the track always landed back on row 1 -- see Util.pos_row.
    local actions, akeys = {"Play"}, {"play"}
    local seek_idx = #actions + 1
    actions[seek_idx] = "Seek"; akeys[seek_idx] = "seek"
    actions[#actions+1] = "Add to Queue"; akeys[#akeys+1] = "queue"
    local like_idx = #actions + 1
    actions[#actions+1] = "Like"; akeys[#akeys+1] = "like"
    actions[#actions+1] = "Go to Album"; akeys[#akeys+1] = "album"
    actions[#actions+1] = "Go to Artist"; akeys[#akeys+1] = "artist"
    actions[#actions+1] = "Add to Playlist"; akeys[#akeys+1] = "addpl"
    -- Always present, dimmed by rebuild_actions when the track is in none of
    -- your playlists -- same treatment as Seek on a track that is not playing.
    -- A row that appears and disappears also shifts every index below it.
    local rm_idx = #actions + 1
    actions[rm_idx] = "Remove from Playlist"; akeys[rm_idx] = "rmpl"
    local lyrics_idx = #actions + 1
    actions[lyrics_idx] = "Lyrics"; akeys[lyrics_idx] = "lyrics"
    actions[#actions+1] = "Copy Web Link"; akeys[#akeys+1] = "url"
    actions[#actions+1] = "More Like This"; akeys[#akeys+1] = "more"
    actions[#actions+1] = "Albumart"; akeys[#akeys+1] = "art"
    actions[#actions+1] = "Track Details"; akeys[#akeys+1] = "details"

    -- The four volatile labels are derived from live state on every draw rather
    -- than patched by hand in the selection branches, so they stay right when a
    -- nested action menu (Alt+Return from here) plays or likes this same track
    -- and rofi_dmenu redraws without this loop running.
    local DIM = '<span foreground="' .. Util.DIM .. '">'
    local function rebuild_actions()
        local playing_this = item.id ~= nil and item.id == current_id
        is_liked = item.id and liked[item.id]
        -- playing_this is tested first for the same reason display_track puts the
        -- green marker ahead of the dim one: if it IS playing, whatever the cache
        -- says about availability, that wins.
        actions[1]          = playing_this and (is_playing and "Pause" or "Resume")
                              or (item.unavail and Util.markup(DIM .. 'Play</span>') or "Play")
        actions[seek_idx]   = playing_this and "Seek" or Util.markup(DIM .. 'Seek</span>')
        actions[like_idx]   = is_liked and "Unlike" or "Like"
        actions[rm_idx]     = #rm_targets > 0 and "Remove from Playlist"
                              or Util.markup(DIM .. 'Remove from Playlist</span>')
        actions[lyrics_idx] = Util.track_has_lyrics(item.id) ~= false and "Lyrics"
                              or Util.markup(DIM .. 'Lyrics</span>')
        return actions
    end
    rebuild_actions()

    -- Shared by the Return and the Shift+Return path so the multi-artist picker
    -- is written once. Returns true when the caller must unwind (a jump-to-track
    -- is in flight); the caller owns tmp_theme, so cleanup stays out here.
    local function go_to_artist(want_hub)
        local arts = item.artists or {}
        if #arts <= 1 then
            if #arts == 1 then Util.open_artist(arts[1], want_hub) end
            return jump_to_track_pending
        end
        local ae = {}
        for i, a in ipairs(arts) do ae[i] = display_artist(a) end
        local pick_key = "artist-pick:" .. (item.id or "")
        while true do
            local aidx = rofi_dmenu(ae, {prompt="Artists", mesg=(item.name or "") .. SEP .. #arts .. " artists",
                custom=false, by_index=true, theme=THEME_SUB, pos_key=pick_key,
                markup=true, alt_select=true})
            -- Shift+Return on the picker reaches the hub even when plain Return
            -- (want_hub false) is what opened it.
            local pick_alt = Util.alt_pressed
            Util.alt_pressed = false
            if not aidx then return false end
            if aidx >= 1 and aidx <= #arts then
                Util.open_artist(arts[aidx], want_hub or pick_alt)
                if jump_to_track_pending then return true end
            end
        end
    end

    local act_key = "action:" .. (item.id or "")
    local pre_sel = Util.pos_row(act_key, akeys)

    -- Hoisted out of the loop: `item` is fixed for the life of this menu, so the
    -- cover and the theme built from it are the same on every pass. Rebuilding
    -- them per iteration re-statted the art cache for nothing, and now that
    -- Util.write_art_theme hands back a unique path it would also leave one
    -- stray /tmp theme per pass. One file, removed on the way out.
    local art_url = item.album and item.album.images and #item.album.images > 0
        and item.album.images[1].url or nil
    -- Backdrop only. This is the hot one: a track opened from Liked Tracks or
    -- Recently Played (plain lists, no thumbnail grid to warm the cache) pays a
    -- live fetch for its cover, and the action menu cannot draw until it lands.
    local art_path = ensure_art(Util.art_url(art_url, "1e02"), nil, Util.ART_DECOR) or ""
    local tmp_theme = Util.write_art_theme("action", art_path)
    local action_theme = tmp_theme

    while true do
        -- Claimed so Shift+Return on "Go to Album" can offer the album's own
        -- action menu (Return there opens the album outright). Every other row
        -- reproduces the default below: a nested action menu for this track.
        local sel = rofi_dmenu(actions,
            {prompt="Action", mesg=function() return track_mesg(item) end, sel=pre_sel,
             custom=false, theme=action_theme, markup=true, current=item, refresh=rebuild_actions,
             ctx_type=ctx_type, ctx_id=ctx_id, items=all_items, cidx=cidx, entries=entries,
             alt_select=true})
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        if not sel then
            -- Both arms of the jump_to_track_pending test that used to be here
            -- were byte-identical; the flag is read by the caller, not cleared
            -- here, so it made no difference either way.
            Util.back_pressed = false
            if tmp_theme then os.remove(tmp_theme) end
            return
        end

        -- rebuild_actions hands rofi pango-wrapped labels for the dimmed Seek and
        -- Lyrics rows, and rofi echoes back exactly what it was given -- so the
        -- raw string is "<span color=...>Lyrics</span>", which matched no branch
        -- below and made a dimmed row silently redraw the menu. Normalise once
        -- and dispatch on that, the way the cursor-memory lookup above already
        -- does. A dimmed Lyrics now reaches view_lyrics, which says "No lyrics
        -- found" instead of doing nothing at all.
        local key = Util.strip_markup(sel)

        -- Resolved against `actions` as drawn; rebuild_actions has not run again
        -- yet, so the label rofi echoed still matches the row it came from. The
        -- stable key, not the label, is what gets remembered.
        for i, a in ipairs(actions) do
            if Util.strip_markup(a) == key then
                pre_sel = i - 1; Util.pos_put(act_key, akeys[i]); break
            end
        end

        if alt then
            if key == "Go to Album" then
                local album = item.album
                -- Fall back to the list's own album when the track cannot name
                -- one (see the Return branch). api_get_album is memo- and
                -- disk-cached and we are inside that very album, so this is a
                -- cache hit rather than a request.
                if not (album and album.id) and ctx_type == "album" and ctx_id then
                    album = api_get_album(ctx_id)
                end
                if album and album.id and album_action_menu(album) then
                    -- "Open Album" on the album we are already in: unwind
                    -- instead of duplicating it, same as the Return branch.
                    if album.id == ctx_id then
                        if tmp_theme then os.remove(tmp_theme) end
                        return
                    end
                    -- browse_album, NOT Util.open_album: "Go to Album" is a
                    -- request to SEE the album, so a one-track one must still
                    -- open rather than start playing.
                    browse_album(album.id, (album.name or "Unknown") .. album_suffix(album))
                end
            elseif key == "Go to Artist" then
                go_to_artist(true)
            else
                if not Util.fast_now_track() then last_playback = 0; get_playback() end
                view_actions(item, ctx_type, ctx_id, all_items, cidx, entries)
            end
            if jump_to_track_pending then
                if tmp_theme then os.remove(tmp_theme) end
                return
            end
        elseif key == "Resume" then
            Util.transport(true)
        elseif key == "Play" then
            if do_play(item, ctx_type, ctx_id, all_items, cidx) then
                current_track = item
                current_id = item.id
                is_playing = true
            end
        elseif key == "Pause" then
            Util.transport(false)
        elseif key == "Add to Queue" then do_add_queue(item)
        elseif key == "Like" or key == "Unlike" then
            if do_like(item, key == "Unlike") then
                is_liked = not is_liked
                if not is_liked then if tmp_theme then os.remove(tmp_theme) end; return true end
            end
        elseif key == "Go to Album" then
            local album = item.album
            -- Already inside this album's track list, so the destination IS the
            -- menu directly beneath us: unwind to it rather than stacking a
            -- second copy of the same view. browse_album passes ctx_type/ctx_id
            -- through view_browse, so the context is already here.
            --
            -- The `not album.id` half catches tracks cached before api_get_album
            -- learned to name the album it patches on -- for those this row did
            -- nothing at all, which is how the dead end was found.
            if ctx_type == "album" and ctx_id
               and (not (album and album.id) or album.id == ctx_id) then
                if tmp_theme then os.remove(tmp_theme) end
                return
            end
            if album and album.id then
                -- Same as the Shift+Return branch above: this row means "show me
                -- the album", never "play it".
                browse_album(album.id, (album.name or "Unknown") .. album_suffix(album))
            end
        elseif key == "Go to Artist" then
            if go_to_artist(false) then
                if tmp_theme then os.remove(tmp_theme) end
                return
            end
        elseif key == "Add to Playlist" then view_add_pl(item.id, item.name)
        elseif key == "Remove from Playlist" then
            local target = rm_targets[1]
            if #rm_targets == 0 then
                rofi_message("Not in any of your playlists")
            elseif #rm_targets > 1 then
                local names = {}
                for i, t in ipairs(rm_targets) do names[i] = t.name end
                local pick = rofi_dmenu(names, {prompt="Remove from", mesg=(item.name or "") .. SEP .. #rm_targets .. " playlists",
                    custom=false, by_index=true, theme=THEME_SUB, markup=true, pos_key="remove-from-playlist"})
                target = pick and rm_targets[pick] or nil
            end
            if target then
                if Util.do_remove_from_playlist(target.id, item.id) then
                    -- Drop the row only when the list underneath IS this playlist;
                    -- removing from some other playlist leaves this view correct.
                    if target.from_ctx and entries and all_items and cidx then
                        table.remove(entries, cidx)
                        table.remove(all_items, cidx)
                        bust_format_cache()
                    end
                    -- Keep the menu's own candidate list honest, so a second
                    -- removal offers only the playlists still holding the track.
                    for i = #rm_targets, 1, -1 do
                        if rm_targets[i].id == target.id then table.remove(rm_targets, i) end
                    end
                    rofi_message("Removed from " .. (target.name or "playlist"))
                    if target.from_ctx then
                        if tmp_theme then os.remove(tmp_theme) end
                        return
                    end
                    -- rebuild_actions dims the row once rm_targets empties. The
                    -- entry is never spliced out: seek_idx/like_idx/lyrics_idx
                    -- are fixed positions into this array, and removing an
                    -- element would slide the labels into the wrong slots.
                else
                    rofi_message("Failed to remove from " .. (target.name or "playlist"))
                end
            end
        elseif key == "Lyrics" then view_lyrics(item)
        elseif key == "Copy Web Link" then
            copy_spotify_url("track", item.id)
            rofi_message("Copied web link")
        elseif key == "More Like This" then
            Util.open_recommendations(item.id, item.name)
        elseif key == "Albumart" then view_art(item)
        elseif key == "Track Details" then Util.view_track_details(item)
        elseif key == "Seek" then
            if item.id == current_id then view_seek(item)
            else rofi_message("Not the current track") end
        end
    end
    end)
end

-- SHARED HELPERS (used by both view functions and replay_session)

local function fetch_artist_albums(artist_id, artist_name)
    local items = api_get_artist_albums(artist_id)
    if not items or #items == 0 then return nil end
    local ae = Util.album_entries(items, false)
    return items, ae, (artist_name or "") .. SEP .. #items .. " albums"
end

local function fetch_liked_by_artist(artist_id, artist_name)
    load_liked_tracks()
    local tracks = get_liked_by_artist(artist_id)
    if #tracks == 0 then return nil end
    table.sort(tracks, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    local te = format_entries(tracks, nil, nil, true)
    return tracks, te, (artist_name or "") .. SEP .. #tracks .. " liked tracks"
end

local function fetch_artist_top_tracks(artist_id, artist_name)
    local d = api_get_artist_top_tracks(artist_id)
    if not d or not d.tracks or #d.tracks == 0 then return nil end
    local te = format_entries(d.tracks, nil, nil, true)
    return d.tracks, te, (artist_name or "") .. SEP .. #d.tracks .. " top tracks"
end

local function fetch_related_artists(artist_id, artist_name)
    local d = api_get_artist_related(artist_id)
    if not d or not d.artists or #d.artists == 0 then return nil end
    local ae = {}
    for i, a in ipairs(d.artists) do ae[i] = display_artist(a) end
    return d.artists, ae, (artist_name or "") .. SEP .. #d.artists .. " related"
end

local function fetch_category_playlists(category_id, category_name)
    local pls = api_get_category_playlists(category_id)
    if not pls then return nil end
    local pe = {}
    for _, pl in ipairs(pls) do pe[#pe+1] = display_playlist(pl) end
    return pls, pe, (category_name or "") .. SEP .. #pls .. " playlists"
end

-- Everything the one request returned, in type order, each row stamped with the
-- `_stype` view_browse dispatches on. No cap of its own: api_search asks for
-- P.max per type and this shows P.max per type, so a number here could only ever
-- hide results that were already paid for. The flat "no more than P.max rows in
-- total" cap this used to carry was exactly that mistake -- harmless while a
-- combined search fetched 20 items, but it would now throw away three types.
-- `page` indexes Util.SEARCH_PAGES. Rows keep their _stype stamp whatever the
-- page, so view_browse's per-type dispatch is untouched by the split -- a
-- filtered page is the same list with fewer kinds on it, not a different thing.
local function format_search_results(results, query, page)
    local want = {}
    for _, k in ipairs(Util.search_page_keys(page or 1)) do want[k] = true end
    local items = {}
    for _, e in ipairs(Util.SEARCH_TYPES) do
        local ci = want[e.key] and results[e.key]
        if ci and type(ci) == "table" then
            for i = 1, #ci do ci[i]._stype = e.key; items[#items+1] = ci[i] end
        end
    end
    if #items == 0 then return nil end
    local entries = {}
    for i = 1, #items do
        entries[i] = Util.format_mixed_item(items[i], i)
    end
    local pg = Util.SEARCH_PAGES[page or 1]
    local mesg = #items .. " results for " .. query
    if pg and pg.key ~= "all" then mesg = pg.label .. SEP .. mesg end
    return items, entries, mesg
end

-- How many rows a page would draw, for the picker's counts. Cheap -- the
-- response is already in hand and this only sums lengths.
function Util.search_page_count(results, page)
    local n = 0
    for _, k in ipairs(Util.search_page_keys(page)) do
        local ci = results[k]
        if type(ci) == "table" then n = n + #ci end
    end
    return n
end

-- Tab's menu. A picker rather than a blind cycle, so an empty page is something
-- you can SEE and step over rather than land on -- which also means no
-- skip-the-empties walk and no risk of one looping.
function Util.search_page_pick(results, page)
    local rows = {}
    for i, pg in ipairs(Util.SEARCH_PAGES) do
        local n = Util.search_page_count(results, i)
        local row = (pg.icon ~= false and Util.type_icon(pg.icon or pg.key) or "")
            .. pg.label .. SEP .. n
        if n == 0 then
            row = Util.dim(row)
        elseif i == page then
            row = Util.markup('<span foreground="#b6e0a4">') .. "\u{f00c} " .. row .. Util.markup('</span>')
        end
        rows[i] = row
    end
    -- Opens on the page you are already on, which is more useful here than a
    -- remembered cursor: the menu exists to move you off it.
    local idx = rofi_dmenu(rows, {prompt="Type", mesg="Filter results by type",
        custom=false, by_index=true, theme=THEME_SUB, no_status=true, markup=true,
        sel=(page or 1) - 1})
    if not idx or idx < 1 or idx > #Util.SEARCH_PAGES then return nil end
    if Util.search_page_count(results, idx) == 0 then
        rofi_message("No " .. Util.SEARCH_PAGES[idx].label:lower() .. " results")
        return nil
    end
    return idx
end

-- Opening a view is ONE function, shared by the live menu and replay_session.
-- Where they drifted -- replay calling view_browse directly instead of through
-- Util.scope -- the restored menu sat on a stack missing its own entry, so
-- anything opened from it pushed onto the grandparent, and that shortened stack
-- is what session_save wrote. Hence the next warm start landed elsewhere.
-- New views follow this shape rather than being reimplemented in replay_session.

function Util.open_playlist(pl)
    if not pl or not pl.id then return false end
    -- snapshot_id rides on every playlist object every list here hands us -- your
    -- own, category shelves, Featured, search results -- so the common path never
    -- has to guess whether its cached tracks are current.
    local tracks = api_get_playlist_tracks(pl.id, pl.snapshot_id)
    if not tracks then rofi_message("Failed to load playlist"); return false end
    if #tracks == 0 then rofi_message("Playlist is empty"); return false end
    -- A playlist WITH a cover gets the album.rasi backdrop showing its own art;
    -- one without falls through to menu.rasi, which needs no code -- view_browse
    -- leaves the theme nil and rofi_dmenu falls back to menu.rasi.
    --
    -- fetch=true because this is a single cover for the view we are opening, not
    -- a grid: there is no batch to defer to. Util.ART_DECOR bounds the wait.
    -- The shipped placeholder is for GRID rows; as a full-bleed backdrop it
    -- would just be a giant glyph, so an artless playlist passes nothing -- which
    -- is what the nil fallback here means.
    local cover = (pl.images and pl.images[1] and pl.images[1].url)
        and Util.keyed_art("playlist", pl, true, false, nil) or nil
    -- Hand what this list knew to the metadata cache, so reopening this playlist
    -- after a restart is a disk read rather than the ~450ms request that used to
    -- be ~95% of a warm start.
    Util.playlist_meta_seed(pl)
    Util.scope({view="playlist", playlist_id=pl.id, playlist_name=pl.name or "Playlist"}, function()
        local te = format_entries(tracks)
        view_browse(te, tracks, display_playlist(pl) .. SEP .. #tracks .. " tracks", "playlist", "playlist", pl.id,
                    nil, cover)
    end)
    return true
end

-- on_change("rename"|"delete", pl) lets the playlist LIST that opened this menu
-- resync its rows. Replay passes nil: there is no list behind it to update.
function Util.open_playlist_actions(pl, on_change)
    if not pl or not pl.id then return end
    Util.playlist_meta_seed(pl)
    Util.scope({view="playlist-actions", playlist_id=pl.id, playlist_name=pl.name or "Playlist"}, function()
        -- Opening an empty playlist only ever yields "Playlist is empty", so say
        -- it on the row instead. Dimmed in place, not dropped: a vanishing row
        -- shifts every index below it, and pos_key remembers the cursor by index.
        -- Only user playlists can be empty; editorial ones always carry tracks.
        -- A replay that could not restore the count falls back to the cached
        -- playlist list for it.
        local total = pl.tracks and tonumber(pl.tracks.total)
        if not total then
            for _, p in ipairs(api_get_my_playlists() or {}) do
                if p.id == pl.id then
                    total = p.tracks and tonumber(p.tracks.total)
                    pl.owner  = pl.owner  or p.owner
                    pl.images = pl.images or p.images   -- Playlist Art needs these on replay
                    break
                end
            end
        end
        local is_empty = total == 0 and not (pl.owner and pl.owner.id == "spotify")
        local acts = {is_empty and Util.dim("Playlist is empty")
                      or "Open Playlist", "Rename Playlist", "Delete Playlist", "Playlist Art", "Copy Web Link"}
        while true do
            local asel = rofi_dmenu(acts, {prompt=display_playlist(pl), mesg=display_playlist(pl), custom=false,
                theme=THEME_SUB, no_status=true, markup=true, pos_key="playlist-ac:" .. (pl.id or "")})
            if not asel then return end
            local token = get_token()
            if asel == "Open Playlist" then
                Util.open_playlist(pl)
                if jump_to_track_pending then return end
            elseif asel == "Playlist Art" then
                view_art(pl)
            elseif asel == "Rename Playlist" then
                if not token then rofi_message("No auth")
                else
                    local nn = rofi_input("New Name", pl.name or "", P.THEME_SEARCH)
                    if nn ~= "" and nn ~= (pl.name or "") then
                        local url = "https://api.spotify.com/v1/playlists/" .. pl.id
                        local r = Util.api_write("PUT", url, token, {body={name=nn}})
                        if Util.is2xx(r) then
                            pl.name = nn; bust_my_playlists()
                            if on_change then on_change("rename", pl) end
                            rofi_message("Renamed")
                        else rofi_message("Failed") end
                    end
                end
            elseif asel == "Delete Playlist" then
                if not token then rofi_message("No auth")
                else
                    local c = rofi_dmenu({"DELETE","Cancel"}, {prompt="Delete", mesg="Delete " .. (pl.name or "") .. "?", custom=false, by_index=true, theme=THEME_SUB, no_status=true, markup=true})
                    if c == 1 then
                        local url = "https://api.spotify.com/v1/playlists/" .. pl.id .. "/followers"
                        local r = Util.api_write("DELETE", url, token)
                        if Util.is2xx(r) then
                            bust_my_playlists()
                            Util.bust_playlist_tracks(pl.id)
                            rofi_message("Deleted Playlist: " .. (pl.name or ""))
                            if on_change then on_change("delete", pl) end
                            return
                        else rofi_message("Failed to delete") end
                    end
                end
            elseif asel == "Copy Web Link" then
                copy_spotify_url("playlist", pl.id)
                rofi_message("Copied web link")
            end
        end
    end)
end

function Util.api_get_genre_seeds()
    return cached_fetch("genre_seeds", P.cache .. "/genre_seeds.json", CACHE_TTL_LONG, function()
        local d = api_get("recommendations/available-genre-seeds")
        if d and d.genres and #d.genres > 0 then return d.genres end
    end, {revalidate = "genre_seeds"})
end

-- Split out so the picker and a warm start replaying straight into a genre both
-- land in the same place.
function Util.open_genre_tracks(genre)
    if not genre then return false end
    local tracks = api_get_recommendations("seed_genres=" .. url_encode(genre))
    if not tracks then rofi_message("No tracks for " .. genre); return false end
    Util.scope({view="genre-tracks", genre=genre}, function()
        local te = format_entries(tracks)
        view_browse(te, tracks, "Genre" .. SEP .. genre .. SEP .. #tracks .. " tracks", "genre", nil, nil)
    end)
    return true
end

function Util.view_discover_genre()
    local genres = Util.api_get_genre_seeds()
    if not genres or #genres == 0 then rofi_message("No genres available"); return end
    Util.scope({view="discover-genre"}, function()
        local gk = "discover-genre||"
        while true do
            local idx = rofi_dmenu(genres, {prompt="Genre", mesg="Discover by Genre" .. SEP .. #genres .. " genres",
                custom=false, by_index=true, no_status=true, markup=true, pos_key=gk})
            if not idx then return end
            if idx >= 1 and idx <= #genres then Util.open_genre_tracks(genres[idx]) end
            if jump_to_track_pending then return end
        end
    end)
end

function Util.open_recommendations(track_id, track_name)
    if not track_id then rofi_message("No recommendations found"); return false end
    local tracks = api_get_recommendations("seed_tracks=" .. track_id)
    if not tracks then rofi_message("No recommendations found"); return false end
    Util.scope({view="recommendations", track_id=track_id, recs_track_name=track_name or ""}, function()
        local te = format_entries(tracks)
        view_browse(te, tracks, "More Like " .. (track_name or ""), "recommendations", nil, nil)
    end)
    return true
end

-- The page is remembered the way every cursor here is, so the type you last
-- filtered to survives the next search and the next launch. Not carried in the
-- session entry: a replayed search restores the QUERY, and which slice of it you
-- were looking at is a preference, not a place.
Util.SEARCH_PAGE_KEY = "search-page:"

function Util.open_search_results(query)
    local results = api_search(query)
    if not results then rofi_message("No results"); return false end
    Util.scope({view="search-results", query=query}, function()
        local page = 1
        local saved = Util.pos_get(Util.SEARCH_PAGE_KEY)
        for i, pg in ipairs(Util.SEARCH_PAGES) do if pg.key == saved then page = i end end
        -- A remembered page can be empty for THIS query even though it had rows
        -- for the last one, and an empty page draws nothing at all -- so fall
        -- back to All rather than opening on a blank list.
        if Util.search_page_count(results, page) == 0 then page = 1 end
        while true do
            local items, entries, mesg = format_search_results(results, query, page)
            if not items then return end
            -- ctx_id is the page key, which is what view_browse builds its v_key
            -- from -- so each page remembers its own cursor instead of all six
            -- sharing one. ctx_type stays nil, so no context_uri is ever built
            -- from it.
            view_browse(entries, items, mesg, "search", nil, Util.SEARCH_PAGES[page].key)
            if not Util.search_tab then break end
            Util.search_tab = false
            local pick = Util.search_page_pick(results, page)
            if pick then
                page = pick
                Util.pos_put(Util.SEARCH_PAGE_KEY, Util.SEARCH_PAGES[page].key)
            end
            if jump_to_track_pending then break end
        end
    end)
    return true
end

function Util.open_featured_playlists()
    local d = api_get_featured_playlists()
    local pls = d and d.items
    -- A deprecated endpoint answering nil is an ordinary outcome here, not an
    -- error worth crashing over.
    if not (pls and #pls > 0) then rofi_message("No featured playlists"); return false end
    local pe = {}
    for i, pl in ipairs(pls) do pe[i] = display_playlist(pl) end
    Util.scope({view="featured"}, function()
        -- ctx="playlist" so it inherits the thumbnail grid and the
        -- art-aware open behaviour every other playlist list has.
        view_browse(pe, pls, (d.message or "Featured") .. SEP .. #pls .. " playlists",
                    "playlist", "playlist", nil, true)
    end)
    return true
end

function Util.open_category_playlists(category_id, category_name)
    local pls, pe, mesg = fetch_category_playlists(category_id, category_name)
    if not pls then rofi_message("No playlists"); return false end
    Util.scope({view="category-playlists", category_id=category_id, category_name=category_name}, function()
        view_browse(pe, pls, mesg, "playlist", "playlist", nil, true)
    end)
    return true
end

-- VIEW: ARTIST ACTIONS

-- Both of these are shared by the live artist menu AND by replay_session, so a
-- trail step restored on a warm start behaves identically to a freshly opened
-- one: same stack entry, same remembered cursor. Replay used to re-implement
-- these loops inline without either, which is why restored menus lost their
-- place and vanished from the trail.
function Util.browse_artist_albums(artist_id, artist_name)
    Util.scope({view="artist-albums", artist_id=artist_id, artist_name=artist_name or ""}, function()
        local items, ae, mesg = fetch_artist_albums(artist_id, artist_name)
        if not items then rofi_message("No albums found"); return end
        local pk = "artist-albums:" .. (artist_id or "")
        while true do
            -- Same reason as view_new_releases: a discography is mostly singles,
            -- and playing one from here has to move the marker without a reopen.
            ae = Util.album_entries(items, false)
            Util.album_thumbs(ae, items, nil, Util.pos_get(pk), pk)
            local aidx = rofi_dmenu(ae, {prompt=artist_name or "", mesg=mesg, custom=false, by_index=true,
                                         no_status=true, markup=true, thumbs=true, pos_key=pk,
                                         alt_select=true,
                                         -- So F5 re-runs album_thumbs; view_browse gets this
                                         -- via its own `rebuild`.
                                         refresh=function() Util.album_thumbs(ae, items, nil, Util.pos_get(pk), pk); return ae end})
            local alt = Util.alt_pressed
            Util.alt_pressed = false
            if not aidx then return end
            if aidx >= 1 and aidx <= #items then
                local al = items[aidx]
                if not alt or album_action_menu(al) then
                    -- `alt` marks the "Open Album" row: never play, always open.
                    Util.open_album(al, alt)
                    if jump_to_track_pending then return end
                end
            end
        end
    end)
end

-- One artist destination for every call site: Return lands on the discography,
-- Shift+Return on the hub. Split out because eight call sites need the same
-- choice, and the artist "action menu" (view_artist) is itself a scoped view --
-- so the Return path has to bypass it rather than pass through it, which is why
-- backing out of an artist's albums lands on the artist list, not the hub.
function Util.open_artist(artist, want_hub)
    if not artist or not artist.id then return end
    if want_hub then view_artist(artist)
    else Util.browse_artist_albums(artist.id, artist.name or "") end
end

function Util.browse_related_artists(artist_id, artist_name)
    Util.scope({view="related", artist_id=artist_id, artist_name=artist_name or ""}, function()
        local artists, ae, mesg = fetch_related_artists(artist_id, artist_name)
        if not artists then rofi_message("No related artists found"); return end
        local pk = "related:" .. (artist_id or "")
        while true do
            local ridx = rofi_dmenu(ae, {prompt="Related to " .. (artist_name or ""), mesg=mesg, custom=false,
                                         by_index=true, no_status=true, markup=true, pos_key=pk,
                                         alt_select=true})
            local alt = Util.alt_pressed
            Util.alt_pressed = false
            if not ridx then return end
            if ridx >= 1 and ridx <= #artists then
                Util.open_artist(artists[ridx], alt)
                if jump_to_track_pending then return end
            end
        end
    end)
end

function Util.browse_liked_by_artist(artist_id, artist_name)
    Util.scope({view="liked-by-artist", artist_id=artist_id, artist_name=artist_name or ""}, function()
        local tracks, te, mesg = fetch_liked_by_artist(artist_id, artist_name)
        if not tracks then rofi_message("No liked tracks by this artist"); return end
        view_browse(te, tracks, mesg, "liked-by-artist", nil, nil)
    end)
end

function Util.browse_top_by_artist(artist_id, artist_name)
    Util.scope({view="top-by-artist", artist_id=artist_id, artist_name=artist_name or ""}, function()
        local tracks, te, mesg = fetch_artist_top_tracks(artist_id, artist_name)
        if not tracks then rofi_message("No top tracks found"); return end
        view_browse(te, tracks, mesg, "top-by-artist", nil, nil)
    end)
end

view_artist = function(artist)
    Util.scope({view="artist-actions", artist_id=artist.id, artist_name=artist.name or ""}, function()
    local is_followed = api_check_following(artist.id)
    local actions = {"View All Albums", "View Liked Tracks", "View Top Tracks",
                     "Related Artists",
                     is_followed and "Unfollow Artist" or "Follow Artist",
                     "Copy Web Link"}
    local art_ac_key = "artist-ac:" .. (artist.id or "")

    while true do
        local sel = rofi_dmenu(actions, {prompt=artist.name or "Artist", mesg=artist.name or "Artist",
                                         custom=false, theme=THEME_SUB, no_status=true,
                                         markup=true, pos_key=art_ac_key})
        if not sel then
            Util.back_pressed = false
            return
        end

        if sel == "View All Albums" then
            Util.browse_artist_albums(artist.id, artist.name)
            if jump_to_track_pending then return end
        elseif sel == "View Liked Tracks" then
            Util.browse_liked_by_artist(artist.id, artist.name)
            if jump_to_track_pending then return end
        elseif sel == "View Top Tracks" then
            Util.browse_top_by_artist(artist.id, artist.name)
            if jump_to_track_pending then return end
        elseif sel == "Related Artists" then
            Util.browse_related_artists(artist.id, artist.name)
            if jump_to_track_pending then return end
        elseif sel == "Follow Artist" or sel == "Unfollow Artist" then
            local success = do_follow_artist(artist.id, sel == "Follow Artist")
            if success then
                is_followed = not is_followed
                actions[5] = is_followed and "Unfollow Artist" or "Follow Artist"
            else
                rofi_message("Failed to " .. (sel == "Follow Artist" and "follow" or "unfollow") .. " artist")
            end
        elseif sel == "Copy Web Link" then
            copy_spotify_url("artist", artist.id)
            rofi_message("Copied web link")
        end
    end
    end)
end

-- VIEW: LYRICS (via lrclib.net)

view_lyrics = function(item)
    Util.scope({view="lyrics", track_id=item.id, lyrics_track_name=item.name or "",
                lyrics_track_artists=item.artists or {},
                lyrics_unavail=item.unavail or nil,
                from_current=(item.id ~= nil and item.id == current_id) or nil}, function()
    local was_current = current_id == item.id
    local id = item.id or ""
    local dur = item.duration_ms and item.duration_ms / 1000 or nil
    local alb = item.album and item.album.name or nil
    local disk = P.lyrics .. "/lyrics_" .. id .. ".json"
    local marker = P.lyrics .. "/nolyr_" .. id .. ".json"
    if id ~= "" and disk_get(marker, P.ttl_lyrics) ~= nil then
        rofi_message("No lyrics found"); return
    end
    local data = cached_fetch("lyrics_" .. id, disk, P.ttl_lyrics, function()
        local result, definitive = api_get_lyrics(item.name, artist_names(item), alb, dur)
        if result then return result end
        if definitive then disk_set(marker, true) end
        return nil
    end)
    -- cached_fetch may have just written the file this process memoised as
    -- "no lyrics"; drop that so the glyph shows on the very next draw.
    Util.lyr_bust(id)

    local display_lines, timestamps
    if type(data) == "table" and data.lines then
        display_lines = data.lines
        timestamps = data.times
    elseif type(data) == "table" then
        display_lines = data
    end

    if not display_lines or #display_lines == 0 then
        rofi_message("No lyrics found"); return
    end

    local mesg_base = track_mesg(item)
    if timestamps then
        local pre_sel = 0
        if current_id == item.id then
            local pos = get_playerctl_position()
            for i, ts in ipairs(timestamps) do
                if ts <= pos then pre_sel = i - 1 end
            end
        end
        -- The synced viewer runs for ANY track that has timestamps. It used to
        -- sit inside the `current_id == item.id` test above, because the `end`
        -- closing this for-loop was missing -- which silently reparented the
        -- whole block and left `if timestamps` with no else at all. A track with
        -- plain (unsynced) lyrics therefore fell through both branches and
        -- view_lyrics returned without opening a window, which is what made
        -- "Lyrics" in the action menu look like it did nothing.
        while true do
            ::lr_next::
            local sel_line = rofi_dmenu(display_lines,
                {prompt="Lyrics", mesg=mesg_base .. "\n> Search or select a line to jump to <", custom=false,
                 theme=THEME_LYR, sel=pre_sel, markup=true})
            if jump_to_track_pending then
                jump_to_track_pending = false
                if current_track and current_track.id == item.id then
                    local pos = get_playerctl_position()
                    local best = 1
                    for i, ts in ipairs(timestamps) do
                        if ts <= pos then best = i end
                    end
                    pre_sel = best - 1
                end
                goto lr_next
            end
            if not sel_line then
                Util.back_pressed = false
                if jump_to_track_pending then return end
                break
            end
            local found_idx
            for i, l in ipairs(display_lines) do
                if Util.pango_escape(l) == sel_line then found_idx = i; break end
            end
            if found_idx and timestamps[found_idx] then
                local ts = timestamps[found_idx]
                local is_current = current_track and current_track.id == item.id
                if is_current then
                    os.execute("playerctl position " .. string.format("%.2f", ts) .. " 2>/dev/null")
                    mem_bust("_playerctl_pos")
                    if trim(shell("playerctl status 2>/dev/null")) ~= "Playing" then
                        os.execute("playerctl play &")
                        Util.playerctl_bust()
                    end
                    is_playing = true
                elseif item.unavail then
                    -- This branch builds its own play request rather than going
                    -- through do_play, so it needs the same refusal.
                    rofi_message("Selection is unavailable to your account's region")
                elseif not was_current then
                    local token = get_token()
                    if token then
                        local device_id = get_spotifyd_device()
                        local dparam = device_id and "?device_id=" .. device_id or ""
                        local ms = math.floor(ts * 1000)
                        local body = json.encode({uris={"spotify:track:" .. item.id}, position_ms=ms})
                        -- Asked for no status at all before (no -w), so a failed
                        -- play still set current_track/is_playing here -- the
                        -- same defect do_play had. Sharing its request builder
                        -- means sharing its answer: only claim the track is
                        -- playing when Spotify says it started.
                        local r = Util.api_write("PUT",
                            "https://api.spotify.com/v1/me/player/play" .. dparam,
                            token, {timeout=3, body=body})
                        if Util.is2xx(r) then
                            P.recent_cmd_at = os.time()
                            -- Explicit, for the reason spelled out in
                            -- recover_playback: not left to the 5s-vs-1s
                            -- coincidence between sync_now's suppression window
                            -- and the status memo's TTL.
                            Util.playerctl_bust()
                            current_track = item
                            current_id = item.id
                            is_playing = true
                        else
                            rofi_message("Failed to play from timestamp")
                        end
                    end
                else
                    rofi_message("Track changed while viewing lyrics")
                end
                pre_sel = found_idx - 1
            end
        end
    else
        while true do
            ::lr_next_plain::
            local sel_line = rofi_dmenu(display_lines,
                {prompt="Lyrics", mesg=mesg_base, custom=false, theme=THEME_LYR, markup=true, pos_key="lyrics:" .. (item.id or "")})
            if jump_to_track_pending then
                jump_to_track_pending = false
                rofi_message("No synced lyrics — cannot jump to a line")
                goto lr_next_plain
            end
            if sel_line then
                rofi_message("No synced lyrics — cannot jump to a line")
                goto lr_next_plain
            end
            if jump_to_track_pending then return end
            break
        end
    end
end)
end

-- VIEW: ADD TO PLAYLIST

view_add_pl = function(track_id, track_name)
    Util.scope({view="add-to-playlist", track_id=track_id, track_name=track_name or ""}, function()
    local token = get_token()
    if not token then return end
    local items = api_get_my_playlists()
    if not items then return end
    local me = api_get_me()
    local my_id = me and me.id
    if not my_id then rofi_message("Cannot determine user ID"); return end

    local names = {"Create New Playlist"}
    local ids   = {"__create__"}
    for _, p in ipairs(items) do
        if Util.pl_is_mine(p, my_id) then
            -- `or "Playlist"` matters: names and ids are parallel arrays read by
            -- one rofi index, and a nil name appended nothing while the id still
            -- appended, skewing every later row onto the wrong playlist.
            names[#names+1] = p.name or "Playlist"; ids[#ids+1] = p.id
        end
    end

    local idx = rofi_dmenu(names, {prompt="Add to Playlist", mesg="Select a playlist", custom=false, by_index=true, markup=true, pos_key="add-to-playlist"})
    if not idx then return end

    local target_id, target_name
    if ids[idx] == "__create__" then
        local pl_name = rofi_input("New Playlist", "", P.THEME_SEARCH)
        if pl_name == "" then return end
        local url = "https://api.spotify.com/v1/users/" .. my_id .. "/playlists"
        local r = Util.api_write("POST", url, token, {body={name=pl_name}, raw=true})
        local cr = safe_decode(r)
        if not cr or not cr.id then rofi_message("Failed to create playlist"); return end
        target_id = cr.id
        target_name = cr.name or pl_name
        bust_my_playlists()
    else
        target_id = ids[idx]
        target_name = names[idx]
    end

    local body = json.encode({uris={"spotify:track:" .. track_id}})
    local add_url = "https://api.spotify.com/v1/playlists/" .. target_id .. "/tracks"
    local r = Util.api_write("POST", add_url, token, {body=body})
    if Util.is2xx(r) then
        Util.bust_playlist_tracks(target_id)
        -- Patch the membership index now rather than waiting for a rebuild, so
        -- Remove from Playlist offers this playlist immediately.
        Util.pl_index_patch(target_id, track_id, true, target_name)
    end
    rofi_message(Util.is2xx(r) and "Added to playlist" or "Failed to add track")
end)
end

-- VIEW: PLAYLISTS

local function view_playlists()
    Util.scope({view="playlists"}, function()
    local token = get_token()
    if not token then rofi_message("No auth"); return end
    local pls = api_get_my_playlists() or {}
    local entries, thumb_items
    -- Rebuilt together, always, by this one function. `thumb_items` is parallel
    -- to `entries` INCLUDING its first row: Util.album_thumbs pairs entries[i]
    -- with items[i], so a placeholder has to stand in for "Create New Playlist"
    -- or every tile shows the previous row's cover. The sentinel resolves to the
    -- create glyph, which is what blends that row into the grid.
    --
    -- One builder rather than three inline rebuilds because create, rename and
    -- delete each mutate this list, and any of them forgetting the second array
    -- silently shifts every icon by one.
    local function rebuild_rows()
        entries = {"Create New Playlist"}
        thumb_items = {{__new = true}}
        for _, p in ipairs(pls) do
            entries[#entries+1] = display_playlist(p)
            thumb_items[#thumb_items+1] = p
        end
    end
    rebuild_rows()

    while true do
        Util.album_thumbs(entries, thumb_items, "playlist", Util.pos_get("playlists||"), "playlists||")
        local idx = rofi_dmenu(entries, {prompt="Playlists", mesg="Playlists" .. SEP .. #pls, custom=false, by_index=true, no_status=true, markup=true, pos_key="playlists||", alt_select=true,
            thumbs=true,
            refresh=function() Util.album_thumbs(entries, thumb_items, "playlist", Util.pos_get("playlists||"), "playlists||"); return entries end})
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        if not idx then return end
        if idx == 1 then
            local pl_name = rofi_input("New Playlist", "", P.THEME_SEARCH)
            if pl_name == "" then goto pl_loop end
            local me = api_get_me()
            if me and me.id then
                local url = "https://api.spotify.com/v1/users/" .. me.id .. "/playlists"
                local r = Util.api_write("POST", url, token, {body={name=pl_name}, raw=true})
                local cr = safe_decode(r)
                if cr then pls[#pls+1] = cr; rebuild_rows(); bust_my_playlists()
                else rofi_message("Failed to create") end
            end
        elseif idx >= 2 and idx - 1 <= #pls then
            local pl = pls[idx - 1]
            if alt then
                Util.open_playlist_actions(pl, function(what)
                    if what == "rename" then
                        table.sort(pls, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
                        rebuild_rows()
                    elseif what == "delete" then
                        local del_idx = nil
                        for i, p in ipairs(pls) do if p.id == pl.id then del_idx = i; break end end
                        if del_idx then table.remove(pls, del_idx); rebuild_rows() end
                    end
                end)
            else
                Util.open_playlist(pl)
            end
            if jump_to_track_pending then return end
        end
        ::pl_loop::
    end
    end)
end

-- VIEW: SEARCH

local function view_search()
    Util.scope({view="search"}, function()
    local hkey = P.hist_key
    Util.hist_migrate()
    while true do
        -- Past queries are offered as rows. `custom` stays enabled (the default),
        -- so typing a new query still works exactly as before -- the history is
        -- a suggestion list, not a menu you are confined to.
        local hist = Util.hist_get(hkey)
        local query = rofi_dmenu(hist, {prompt="Search",
            mesg="Search", theme=P.THEME_SEARCH, no_status=true, markup=true,
            hist_key=hkey, refresh=function() return Util.hist_get(hkey) end})
        if not query then break end
        -- rofi echoes a SELECTED row back pango-escaped (markup is on), so a
        -- remembered query containing & or < would otherwise be searched for in
        -- its escaped form. Free-typed text is never escaped, so it falls
        -- through this loop untouched.
        for _, h in ipairs(hist) do
            if Util.pango_escape(h) == query then query = h; break end
        end
        Util.hist_add(hkey, query)
        if not Util.open_search_results(query) then break end
        if jump_to_track_pending then break end
    end
    end)
end

-- VIEW: CATEGORIES

local function view_categories()
    local cats = api_get_categories()
    if not cats or #cats == 0 then rofi_message("No categories available"); return end
    Util.scope({view="categories"}, function()
    local ce = {}
    for _, c in ipairs(cats) do ce[#ce+1] = c.name end

    while true do
        -- Icons are cached by category id, like playlist covers: Spotify replaces
        -- a category's icon in place rather than serving a new URL.
        Util.album_thumbs(ce, cats, "category", Util.pos_get("categories||"), "categories||")
        local idx = rofi_dmenu(ce, {prompt="Categories", mesg="Categories" .. SEP .. #cats, custom=false, by_index=true, no_status=true, markup=true, pos_key="categories||",
            thumbs=true,
            refresh=function() Util.album_thumbs(ce, cats, "category", Util.pos_get("categories||"), "categories||"); return ce end})
        if not idx then return end
        if idx < 1 or idx > #cats then goto cat_loop end
        local cat = cats[idx]
        Util.open_category_playlists(cat.id, cat.name)
        ::cat_loop::
    end
    end)
end

-- VIEW: TOP TRACKS / LIKED / SAVED / FOLLOWED / CURATED / QUEUE

local function view_top_tracks()
    local tracks = api_get_top_tracks()
    if not tracks then rofi_message("No top tracks"); return end
    Util.scope({view="top-tracks"}, function()
    local entries = format_entries(tracks)
    view_browse(entries, tracks, "Top Tracks" .. SEP .. #tracks .. " tracks", "top-tracks", nil, nil)
    if jump_to_track_pending then return end
end)
end

local function view_liked_tracks()
    local tracks = load_liked_tracks() or {}
    if #tracks == 0 then rofi_message("No liked tracks"); return end
    Util.scope({view="liked"}, function()
    local entries = format_entries(tracks, nil, true)
    view_browse(entries, tracks, "Liked Tracks" .. SEP .. #tracks .. " tracks", "liked", nil, nil)
    if jump_to_track_pending then return end
end)
end

local function view_saved_albums()
    local al = load_saved_albums()
    if #al == 0 then rofi_message("No saved albums"); return end
    Util.scope({view="saved-albums"}, function()
    local entries = Util.album_entries(al)
    view_browse(entries, al, "Saved Albums" .. SEP .. #al .. " albums", "album-list", "album", nil, true)
    if jump_to_track_pending then return end
end)
end

-- Rows built inline rather than through a Util.album_entries-shaped helper:
-- that one exists because album rows carry live playback state and have to be
-- REBUILDABLE, and a show row carries none -- the same reason
-- view_followed_artists below builds its own.
Util.view_saved_shows = function()
    local sh = Util.load_saved_shows() or {}
    if #sh == 0 then rofi_message("No followed podcasts"); return end
    Util.scope({view="show-list"}, function()
    local entries = {}
    for i, s in ipairs(sh) do entries[i] = Util.display_show(s) end
    view_browse(entries, sh, "Podcasts" .. SEP .. #sh .. " podcasts", "show-list", nil, nil, true)
    if jump_to_track_pending then return end
end)
end

-- Browsing podcasts by name. Reuses api_search rather than issuing a show-only
-- request: that function's cache is keyed by query and already fetches every
-- type in ONE round trip, so searching "darknet" here and searching it from
-- Search share a cache entry instead of costing two. Only the shows bucket is
-- shown, as a grid -- which is what makes this a browse rather than a lookup.
--
-- ctx_id carries the query for the same reason Util.open_show passes the show
-- id: it is what view_browse's v_key is built from, so each query remembers its
-- own cursor instead of every search sharing "show-list||".
function Util.open_podcast_search(query)
    local results = api_search(query)
    local shows = results and results.shows
    if not (shows and #shows > 0) then
        rofi_message("No podcasts found for " .. query)
        return false
    end
    Util.scope({view="podcast-search", query=query}, function()
        local entries = {}
        for i, s in ipairs(shows) do entries[i] = Util.display_show(s) end
        view_browse(entries, shows, "Podcasts" .. SEP .. query .. SEP .. #shows .. " podcasts",
                    "show-list", nil, query, true)
    end)
    return true
end

-- PODCASTS
--
-- A dedicated grid, not a menu of two rows. What it deliberately is NOT is a
-- mirror of open.spotify.com/genre/podcasts-web: that page is served by
-- Spotify's internal GraphQL backend, and the public Web API exposes none of
-- it. Verified rather than assumed -- browse/categories answers with 56
-- categories and not one podcast among them, and the "Podcasts" category that
-- does exist (0JQ5DArNBzkmxXHCqFLx2J) answers with total: 0 playlists. There is
-- no browse-shows endpoint and no podcast chart.
--
-- So the shelves are built from what the API does serve: your library, and
-- search. A topic tile is a saved search -- which is what makes it browsable
-- rather than something you have to already know the name of.
--
-- These are Spotify's OWN podcast category names, not invented ones, so the
-- grid reads like the genre page even though it cannot be fed by it. Each was
-- checked against search?type=show in this account's market and every one
-- returns shows. Bare names, deliberately: appending "podcast" to the query was
-- measured and made results LESS topical, not more (Comedy got worse; Arts got
-- more rows but fewer of them about the arts).
Util.PODCAST_TOPICS = {
    "True Crime", "Comedy", "News", "Politics", "Society & Culture",
    "Technology", "Science", "Education", "History", "Documentary",
    "Business", "Health & Fitness", "Lifestyle", "Leisure", "Sports",
    "Music", "TV & Film", "Arts", "Fiction", "Kids & Family",
    "Religion & Spirituality",
}

-- Library shelves first, then the topics. Each `art` returns the object whose
-- cover stands for the tile, reusing the very fetcher the tile opens with, so a
-- warm shelf costs nothing extra -- and every one of them runs under
-- Util.cache_only, so none may assume it will reach the network.
Util.PODCAST_TILES = (function()
    local t = {
        {key = "followed", label = "Followed", open = function() Util.view_saved_shows() end,
         art = function() return Util.shelf_head(Util.load_saved_shows) end},
        -- The SHOW's cover, not the newest episode's. Util.latest_episodes
        -- asks shows/{id}/episodes once PER FOLLOWED SHOW -- twenty requests to
        -- decorate one tile, paid again by every warm. An episode's artwork
        -- falls through to its parent show anyway (Util.src_images), so the
        -- image drawn is usually the identical file for none of the cost. The
        -- menu itself still builds the real feed.
        {key = "latest",   label = "Latest Episodes", open = function() Util.view_latest_episodes() end,
         art = function() return Util.shelf_head(Util.load_saved_shows) end},
        {key = "saved",    label = "Saved Episodes", open = function() Util.view_saved_episodes() end,
         art = function() return Util.shelf_head(Util.load_saved_episodes) end},
        {key = "search",   label = "Search", fallback = Util.ART_GENRE,
         open = function() Util.podcast_search_prompt() end},
    }
    for _, topic in ipairs(Util.PODCAST_TOPICS) do
        t[#t+1] = {
            -- Sanitised to word characters: this key becomes a FILENAME
            -- under P.art/podcasts, and category names carry "&" and spaces.
            key = "topic:" .. topic:lower():gsub("[^%w]+", "-"):gsub("%-+$", ""),
            label = topic,
            open = function() Util.open_podcast_search(topic) end,
            art = function()
                return Util.shelf_head(function()
                    local r = api_search(topic)
                    return r and r.shows
                end)
            end,
        }
    end
    return t
end)()

-- One show's newest episode, and ONLY that. Deliberately not Util.api_get_show,
-- which pages a podcast's entire back catalogue -- 227 episodes over five
-- requests for Darknet Diaries alone. Building a feed from twenty followed shows
-- that way is a hundred requests to render twenty rows; limit=1 makes it twenty
-- small ones, cached for an hour.
--
-- shows/{id}/episodes answers newest-first, which is the whole reason limit=1 is
-- enough.
function Util.show_latest_episode(show_id)
    return cached_fetch("show_latest_" .. show_id, P.mass .. "/show_latest_" .. show_id .. ".json", CACHE_TTL_MED, function()
        local d = api_get("shows/" .. show_id .. "/episodes", Util.with_market("limit=1"))
        return d and d.items and d.items[1] or nil
    end, {revalidate = "show_latest", revalidate_arg = show_id})
end
Util.REVALIDATORS.show_latest = function(show_id)
    if show_id and #show_id > 0 then return Util.show_latest_episode(show_id) end
end

-- The newest episode of every podcast you follow, newest first. The closest the
-- public API gets to a podcast home feed, and it is derived rather than fetched:
-- there is no endpoint for it.
--
-- The parent show is patched on from the list we are already walking, so this
-- gets it for free where Util.api_get_show has to synthesise one -- and every
-- caller downstream (Go to Podcast, Copy URL, the art fallback, Util.subtitle)
-- depends on it being there. Under Util.cache_only nothing is fetched at all,
-- which is what keeps the tile grid from firing one request per followed
-- podcast just to draw a thumbnail.
function Util.latest_episodes()
    local out = {}
    for _, sh in ipairs(Util.load_saved_shows() or {}) do
        local ok, ep = pcall(Util.show_latest_episode, sh.id)
        if ok and ep then
            if not ep.show then
                ep.show = {id = sh.id, name = sh.name,
                           publisher = sh.publisher, images = sh.images}
            end
            out[#out+1] = ep
        end
    end
    -- release_date is ISO, so lexicographic IS chronological.
    table.sort(out, function(a, b)
        return (a.release_date or "") > (b.release_date or "")
    end)
    return out
end

function Util.view_latest_episodes()
    local eps = Util.latest_episodes()
    if #eps == 0 then rofi_message("No episodes -- follow a podcast first"); return end
    Util.scope({view="latest-episodes"}, function()
    -- Show names are NOT hidden here: every row is a different podcast, which is
    -- the opposite of a single show's episode list.
    local entries = format_entries(eps)
    view_browse(entries, eps, "Latest Episodes" .. SEP .. #eps .. " episodes", "episode-list", nil, nil)
    if jump_to_track_pending then return end
end)
end

function Util.view_saved_episodes()
    local eps = Util.load_saved_episodes() or {}
    if #eps == 0 then rofi_message("No saved episodes"); return end
    Util.scope({view="saved-episodes"}, function()
    local entries = format_entries(eps)
    view_browse(entries, eps, "Saved Episodes" .. SEP .. #eps .. " episodes", "episode-list", nil, nil)
    if jump_to_track_pending then return end
end)
end

-- Split out so the Search tile and a warm start replaying into a query both
-- reach the same prompt.
function Util.podcast_search_prompt()
    -- The same history the general Search uses, deliberately: a podcast name
    -- typed in one place is worth offering in the other, and a second history
    -- key would split the list for no gain.
    local hkey = P.hist_key
    Util.hist_migrate()
    local hist = Util.hist_get(hkey)
    local query = rofi_dmenu(hist, {prompt="Podcasts", mesg="Search Podcasts",
        theme=P.THEME_SEARCH, no_status=true, markup=true,
        hist_key=hkey, refresh=function() return Util.hist_get(hkey) end})
    if not query then return false end
    -- rofi echoes a selected row back pango-escaped, so a remembered query
    -- containing & or < has to be mapped back to its raw form.
    for _, h in ipairs(hist) do
        if Util.pango_escape(h) == query then query = h; break end
    end
    Util.hist_add(hkey, query)
    return Util.open_podcast_search(query)
end

Util.view_podcasts = function()
    Util.view_tile_grid({tiles = Util.PODCAST_TILES, view = "podcasts",
                         kind = "podcast", prompt = "Podcasts"})
end

local function view_followed_artists()
    local ar = load_followed_artists()
    if #ar == 0 then rofi_message("No followed artists"); return end
    Util.scope({view="followed-artists"}, function()
    local entries = {}
    for i, a in ipairs(ar) do entries[i] = display_artist(a) end
    view_browse(entries, ar, "Followed Artists" .. SEP .. #ar .. " artists", "artist-list", nil, nil, true)
    if jump_to_track_pending then return end
end)
end

-- YOUR LIBRARY -- the four lists that are yours rather than Spotify's, gathered
-- under one row named after the account instead of taking four top-level slots.
--
-- The view id is "library", not the account name: it is a PERSISTED identifier
-- naming this view in session.json and its cursor in view_pos.json, and a
-- display name can change (or be missing entirely) without it becoming a
-- different menu. Same separation reg("spotify-picks", "Collections") relies on.
-- `art` returns the object whose cover stands for the row -- the first thing on
-- it -- reusing the very loader the row opens with, so a warm library costs
-- nothing extra. All five run under Util.cache_only inside Util.shelf_tiles, so
-- none may assume it will reach the network; every one of them reads a library
-- cache that is already on disk, which is why this grid draws with art on the
-- first open where the shelf-backed ones cannot.
Util.LIBRARY_ROWS = {
    {key = "liked",     label = "Liked Tracks",     open = function() view_liked_tracks() end,
     art = function() return Util.shelf_head(load_liked_tracks) end},
    {key = "top",       label = "Top Tracks",       open = function() view_top_tracks() end,
     art = function() return Util.shelf_head(api_get_top_tracks) end},
    {key = "albums",    label = "Saved Albums",     open = function() view_saved_albums() end,
     art = function() return Util.shelf_head(load_saved_albums) end},
    {key = "artists",   label = "Followed Artists", open = function() view_followed_artists() end,
     art = function() return Util.shelf_head(load_followed_artists) end},
    {key = "playlists", label = "Playlists",        open = function() view_playlists() end,
     art = function() return Util.shelf_head(api_get_my_playlists) end},
}

-- The account name is resolved per call rather than baked into the spec: it
-- comes from a profile cache that can refresh under us, and this menu is the one
-- place it is displayed.
Util.view_library = function()
    Util.view_tile_grid({tiles = Util.LIBRARY_ROWS, view = "library",
                         kind = "library", prompt = Util.account_name()})
end

-- Spotify's own shelves plus the personalised ones, gathered under a single Main
-- row so none has to take a top-level slot of its own. Same stable-key cursor
-- treatment as the other sub.rasi menus (see Util.pos_row).
-- Browse category ids. These are global Spotify constants -- the same id serves
-- every account and market -- so naming them here is safer than resolving by
-- label, which arrives localised.
Util.PICK_CATEGORIES = {
    made_for_you = "0JQ5DAt0tbjZptfcdMSKl3",
    discover     = "0JQ5DAtOnAEpjOgUKwXyxj",
    charts       = "0JQ5DAudkNjCgYMM0TZXDw",
}

-- The Discover shelf holds exactly one playlist, the personalised Discover
-- Weekly, so the row opens straight into its tracks instead of into a list of
-- one. If it ever holds more, fall through to the ordinary category view rather
-- than picking an arbitrary first row.
function Util.open_discover_weekly()
    local pls = api_get_category_playlists(Util.PICK_CATEGORIES.discover)
    if pls and #pls == 1 and pls[1] and pls[1].id then
        return Util.open_playlist(pls[1])
    end
    return Util.open_category_playlists(Util.PICK_CATEGORIES.discover, "Discover Weekly")
end

-- One row per shelf: its label, the key its cursor position is remembered by,
-- and where its TILE ARTWORK comes from. `art` returns the object whose cover
-- stands for the shelf -- almost always the first thing on it -- reusing the
-- fetcher the row itself opens with, so a warm shelf costs nothing extra.
--
-- Every `art` call happens under Util.cache_only (see below), so none of these
-- may assume its fetcher will actually go out to the network.
-- `open` is what the row DOES, carried beside its label rather than matched
-- against it. The label chain this replaces compared the visible string, which
-- made every display name load-bearing -- rename a row and its action silently
-- stopped firing. Same reason the cursor is remembered by `key`.
Util.COLLECTION_TILES = {
    -- Its own tile grid, opened from this one. First because it is the only row
    -- here backed by your library rather than by Spotify's editorial shelves,
    -- and the art follows suit: the podcasts you follow, or the placeholder
    -- until you follow one.
    {key = "podcasts",       label = "Podcasts",
     open = function() Util.view_podcasts() end,
     -- Cover only. This opens Util.PODCAST_TILES -- four library rows plus the
     -- 21 topics -- which is 25 rows whether or not a single show is followed,
     -- so it falls back to podcasts.png with nothing followed but is never
     -- dimmed. The rows INSIDE it dim for themselves.
     art_only = true,
     art = function() return Util.shelf_head(Util.load_saved_shows) end},
    {key = "madeforyou",     label = "Made For You",
     open = function() Util.open_category_playlists(Util.PICK_CATEGORIES.made_for_you, "Made For You") end,
     art = function() return Util.shelf_head(api_get_category_playlists, Util.PICK_CATEGORIES.made_for_you) end},
    {key = "discoverweekly", label = "Discover Weekly",
     open = function() Util.open_discover_weekly() end,
     art = function() return Util.shelf_head(api_get_category_playlists, Util.PICK_CATEGORIES.discover) end},
    {key = "topartists",     label = "Top Artists",
     open = function() Util.view_top_artists() end,
     art = function() return Util.shelf_head(Util.api_get_top_artists) end},
    {key = "featured",       label = "Featured Playlists",
     open = function() Util.open_featured_playlists() end,
     art = function() return Util.shelf_head(function() local d = api_get_featured_playlists(); return d and d.items end) end},
    {key = "newreleases",    label = "New Releases",
     open = function() view_new_releases() end,
     art = function() return Util.shelf_head(api_get_new_releases) end},
    {key = "charts",         label = "Charts",
     open = function() Util.open_category_playlists(Util.PICK_CATEGORIES.charts, "Charts") end,
     art = function() return Util.shelf_head(api_get_category_playlists, Util.PICK_CATEGORIES.charts) end},
    -- The two picker rows. Discover by Genre is a picker over 126 genre names
    -- and Categories one over Spotify's browse categories, not shelves of
    -- objects, so there is nothing whose cover could stand for either -- the
    -- permanently artless rows, and the only users of the ART_ assets above.
    {key = "genre",          label = "Discover by Genre", fallback = Util.ART_GENRE,
     open = function() Util.view_discover_genre() end},
    {key = "categories",     label = "Categories",        fallback = Util.ART_CATEGORIES,
     open = function() view_categories() end},
}

-- Resolves a tile list to pseudo-items Util.keyed_art can file by ROW key.
-- One builder for every tile grid: Collections and Podcasts differed only in an
-- episode's images living on its parent show, which is a no-op for a shelf whose
-- sources are playlists and albums.
--
-- Runs entirely under Util.cache_only: reading every shelf for real would cost a
-- dozen requests before the grid could draw, which is the exact cost this shape
-- exists to remove. A shelf never opened yields "unknown", which is reported as
-- `art_unknown` rather than as "no artwork", because Util.keyed_art treats the
-- second as proof the cover was withdrawn and deletes it. A shelf that WAS read
-- and turned out to be empty is the opposite, and wants exactly that deletion --
-- see Util.shelf_head, which is what tells the two apart. The second return
-- value tells the caller to warm the cold shelves in the background.
-- Where a tile's source actually keeps its cover, by kind: an album, artist,
-- playlist or show carries its own, an episode's is on its parent show, and a
-- TRACK's is on its album. Same fall-through thumb_resolve makes for ordinary
-- rows.
--
-- Shared by the two halves that must agree about it -- Util.shelf_tiles, which
-- decides what the grid DRAWS, and Util.run_shelf_warm, which decides what gets
-- FETCHED. They had a copy each, and the copies drifted the moment a tile backed
-- by a track appeared: the grid knew to look at the album and the warmer did
-- not, so those covers were never downloaded.
-- How wide a tile's caption may be. The grid is five columns of a 1000px window,
-- so a row is ~190px of text -- a long track title would otherwise wrap into the
-- tile below it or be cut mid-word by the theme.
Util.TILE_LABEL_MAX = 22

-- What a tile is CALLED. `label` is the static name; `name` is an optional
-- function for a row whose caption comes from live state -- the account tile is
-- named after the Spotify profile, and the Playback tile after whatever is
-- playing right now. `label` is what it falls back to, so a row is never
-- nameless: the Playback tile reads "Playback" until something starts.
--
-- `name` may return a SECOND value meaning "this row is the thing playing", and
-- the caption then wears exactly what a playing row wears in any other list --
-- same glyph, same green, from Util.transport_glyph and Util.now_playing. A tile
-- and a track row cannot disagree about what playing looks like.
--
-- Truncation happens BEFORE the markup and never after: cutting a string that
-- already carries pango tags would eventually cut one in half and take the whole
-- row's rendering with it.
--
-- Guarded, like the art resolvers: these run against caches that may be
-- half-populated, and one row's bad day must not take the grid down.
-- `res` is the row's resolved entry from Util.shelf_tiles, when the caller has
-- one. It carries art_empty: the shelf behind this row was read and holds
-- nothing, so the caption is dimmed the same way Seek dims with nothing playing.
-- A row that is merely UNREAD is never dimmed -- claiming a list is empty
-- because we have not looked yet would be a guess.
--
-- `art_only` is the other half of that. Dim has to mean "what this row OPENS is
-- empty", and for most rows the shelf supplying the cover IS what they open --
-- Liked Tracks shows liked tracks. For a row that opens a MENU of its own, it is
-- not: Podcasts wears the cover of a followed show but opens a 25-tile grid that
-- exists whether or not you follow anything. Those rows still fall back to their
-- asset when the shelf empties, which is what the asset is for, but they are
-- never dimmed -- there is always something behind them.
function Util.tile_label(t, res)
    if type(t) ~= "table" then return "?" end
    local empty = res and res.art_empty and not t.art_only
    if t.name then
        local ok, n, live = pcall(t.name)
        if ok and type(n) == "string" and trim(n) ~= "" then
            n = truncate_text(trim(n), Util.TILE_LABEL_MAX)
            -- Green wins over grey, exactly as it does for a track row: if this
            -- row is what is playing, that is the more useful thing to say.
            if live then return Util.now_playing(Util.transport_glyph() .. n) end
            return empty and Util.dim(n) or n
        end
    end
    local lbl = t.label or "?"
    return empty and Util.dim(lbl) or lbl
end

function Util.src_images(src)
    if type(src) ~= "table" then return nil end
    local imgs = src.images
    if (not imgs or #imgs == 0) and src.show  then imgs = src.show.images end
    if (not imgs or #imgs == 0) and src.album then imgs = src.album.images end
    if imgs and #imgs > 0 then return imgs end
    return nil
end

-- What a container row actually learned about the shelf behind it.
--
-- `list[1]`, which every tile used to take, collapses three different answers
-- into one nil: the shelf is not cached, the shelf is cached and EMPTY, and the
-- shelf's first entry simply carries no artwork. They want opposite treatment --
-- one must leave the existing cover alone, one must replace it with the row's
-- asset and dim the row, one must replace it and NOT dim -- so the state comes
-- back alongside the item.
--
--   item, "ok"       first entry that actually carries artwork
--   nil,  "noart"    entries, but not one with artwork: fallback, do NOT dim
--   nil,  "empty"    read, and genuinely nothing in it: fallback, and dim
--   nil,  "unknown"  nothing was learned: leave the existing art alone
--
-- Scanning for the first ARTED entry rather than the first entry costs nothing
-- (the list is already decoded) and is what stops a coverless row at the head of
-- a shelf from blanking the whole tile. It is also the entire fetch budget for a
-- container: one cover, never a walk into what the container holds.
--
-- Extra arguments are forwarded to the loader, so a shelf that takes one
-- (a category id) needs no closure at the call site.
function Util.shelf_head(load, ...)
    if type(load) ~= "function" then return nil, "unknown" end
    -- Guarded like every other shelf read: these run against half-populated
    -- caches by design, and one shelf's bad day must not take the grid down.
    local ok, list = pcall(load, ...)
    if not ok or type(list) ~= "table" then return nil, "unknown" end
    for _, it in ipairs(list) do
        if Util.src_images(it) then return it, "ok" end
    end
    return nil, (#list == 0) and "empty" or "noart"
end

function Util.shelf_tiles(list)
    local was = Util.cache_only
    Util.cache_only = true
    local tiles, cold = {}, false
    for i, t in ipairs(list or {}) do
        local src, state = nil, nil
        if t.art then
            -- Guarded: these run against half-populated caches by design, and
            -- one shelf's bad day must not take the whole grid down.
            local ok, v, st = pcall(t.art)
            if ok then src, state = v, st else src, state = nil, "unknown" end
            -- A row that answers with a bare value and no state gets the
            -- CONSERVATIVE reading: a value is "ok", and a nil is "unknown", not
            -- "empty". Defaulting a bare nil to empty would have dimmed the
            -- account row and deleted its avatar whenever the profile simply was
            -- not cached yet, because api_get_me answers nil for that too. A row
            -- that genuinely means "there is nothing here" says so itself -- see
            -- the Playback tile -- and Util.shelf_head always states its case.
            if not state then state = src and "ok" or "unknown" end
        end
        -- Only an unread shelf leaves the existing cover alone and asks for a
        -- warm. "empty" and "noart" are ANSWERS: they fall through to
        -- Util.keyed_art's artwork-withdrawn path, which drops the stale file
        -- and returns the fallback -- which is exactly what a container whose
        -- contents went away should show. Warming them is pointless besides;
        -- nothing it fetches could fill a shelf that is genuinely empty, and it
        -- was being spawned on every draw for precisely that case.
        local unknown = (state == "unknown") or nil
        if unknown then cold = true end
        -- An episode's cover lives on the show patched onto it by
        -- Util.api_get_show, so fall through to that when it has none of its own.
        -- A tile with no cover of its own can be given one by DROPPING A FILE:
        -- style/assets/<key>.png, named after the row. It wins over the
        -- fallback the row declares, so the artless rows -- Search, System --
        -- can be themed without touching this file, and a row that grows a real
        -- cover later simply stops consulting either.
        local asset = P.assets .. "/" .. t.key .. ".png"
        if not cache_exists(asset) then asset = nil end
        tiles[i] = {id = t.key, images = Util.src_images(src),
                    art_fallback = asset or t.fallback,
                    art_unknown = unknown,
                    -- Read by the caption builders, which dim a row whose shelf
                    -- was read and found to hold nothing.
                    art_empty = (state == "empty") or nil}
    end
    Util.cache_only = was
    return tiles, cold
end

-- One grid for every tile list. `spec` carries what actually differs: the tiles,
-- the Util.scope view name (a persisted identifier, NOT a label -- it names the
-- view in session.json and its cursor in view_pos.json, and stays put while the
-- display name changes), the art kind, and the prompt.
function Util.view_tile_grid(spec)
    local list = spec.tiles
    -- keys, not row indexes, are what the cursor is remembered by -- so a list
    -- can be reordered without moving anyone\'s cursor.
    local keys = {}
    for i, t in ipairs(list) do keys[i] = t.key end
    Util.scope({view = spec.view}, function()
    local pk = spec.view .. ":"
    local pre_sel = Util.pos_row(pk, keys)
    local tiles, cold = Util.shelf_tiles(list)
    -- One warmer per open, and only when something was actually missing. It
    -- fetches the cold shelves and their covers, so the NEXT open is complete --
    -- this one stays as fast as it was when the menu was plain text.
    if cold then Util.spawn_shelf_warm(spec.kind) end
    local entries = {}
    -- Re-resolved per draw, not per open: a tile named from live state (the
    -- account, the playing track) has to follow it, and a row asks its resolved
    -- tile whether the shelf behind it turned out to be empty.
    local function labels()
        for i, t in ipairs(list) do entries[i] = Util.tile_label(t, tiles[i]) end
    end
    -- Re-resolves the tiles rather than re-decorating the ones this draw started
    -- with. Those carry no images for a shelf that was cold, so redecorating them
    -- could only ever reproduce the same placeholders -- which made F5 a no-op
    -- and left backing out and reopening as the only way to see art the warmer
    -- had already written.
    --
    -- Captions are rebuilt here too. Re-resolving `tiles` without them meant a
    -- refresh picked up new artwork but not a row that had just emptied or
    -- filled, so a shelf could change under an open grid and only the picture
    -- would say so.
    local function redraw()
        tiles = Util.shelf_tiles(list)
        labels()
        Util.album_thumbs(entries, tiles, spec.kind, pre_sel, spec.view .. "||")
        return entries
    end
    while true do
        labels()
        Util.album_thumbs(entries, tiles, spec.kind, pre_sel, spec.view .. "||")
        -- by_index, like every other thumbnail grid here: album_thumbs appends a
        -- \0icon field to each row, so matching rofi\'s echo back against the row
        -- TEXT is exactly the comparison that suffix would break.
        local idx = rofi_dmenu(entries, {prompt=spec.prompt, mesg=spec.prompt,
            custom=false, by_index=true, no_status=true, markup=true, sel=pre_sel,
            thumbs=true, refresh=redraw})
        if not idx then return end
        if idx >= 1 and idx <= #list then
            pre_sel = idx - 1
            Util.pos_put(pk, keys[idx])
            if list[idx].open then list[idx].open() end
            if jump_to_track_pending then return end
            -- Whatever was just visited may have filled a shelf that was cold
            -- when this grid opened, so re-resolve before drawing again.
            tiles = Util.shelf_tiles(list)
        end
    end
    end)
end

-- "spotify-picks" is a PERSISTED identifier, not a label: it names this view in
-- session.json and its cursor in view_pos.json, and it stays put while the
-- display name changes -- which is exactly what happened when Curations became
-- Collections. Renaming it would invalidate every saved session, cursor and
-- trail that points at it.
Util.view_collections = function()
    Util.view_tile_grid({tiles = Util.COLLECTION_TILES, view = "spotify-picks",
                         kind = "collection", prompt = "Collections"})
end

view_new_releases = function()
    local albums = api_get_new_releases() or {}
    if #albums == 0 then rofi_message("No new releases"); return end
    Util.scope({view="new-releases"}, function()
    local entries
    local v_key = "new-releases||"
    local pre_sel = nil
    while true do
        -- Rebuilt per pass, not once: a single played from this grid takes the ▶
        -- marker, and this loop is what redraws after it. album_thumbs re-applies
        -- its \0icon suffixes from the memo, so the tiles cost nothing.
        entries = Util.album_entries(albums)
        Util.album_thumbs(entries, albums, nil, pre_sel or Util.pos_get(v_key), v_key)
        local idx = rofi_dmenu(entries, {prompt="New Releases", mesg="New Releases" .. SEP .. #albums .. " albums", custom=false, by_index=true, no_status=true, sel=pre_sel, pos_key=v_key, markup=true, thumbs=true, alt_select=true,
            refresh=function() Util.album_thumbs(entries, albums, nil, pre_sel or Util.pos_get(v_key), v_key); return entries end})
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        if not idx then return end
        if idx >= 1 and idx <= #albums then
            pre_sel = idx - 1
            local al = albums[idx]
            if not alt or album_action_menu(al) then
                -- `alt` marks the "Open Album" row: never play, always open.
                Util.open_album(al, alt)
                if jump_to_track_pending then return end
            end
        end
    end
end)
end

local function view_your_queue()
    local d = mem_get("queue")
    if not d then
        -- Undocumented, but me/player/queue honours market and answers with
        -- is_playable on currently_playing and on every queue entry -- which
        -- matters here because Spotify will happily queue a track it then skips.
        -- api_get collapses that into `unavail` before we ever see it.
        d = api_get("me/player/queue", Util.with_market("additional_types=episode"))
        if d then mem_set("queue", d, 10) end
    end
    if not d then rofi_message("Queue is empty"); return end
    local tracks = {}
    if d.currently_playing and type(d.currently_playing) == "table" and d.currently_playing.id then tracks[#tracks+1] = d.currently_playing end
    if d.queue then for _, t in ipairs(d.queue) do if type(t) == "table" and t.id then tracks[#tracks+1] = t end end end
    if #tracks == 0 then rofi_message("Queue is empty"); return end
    Util.scope({view="your-queue"}, function()
    local entries = format_entries(tracks)
    local user_q = d.queue and #d.queue or 0
    local mesg = "Your Queue" .. SEP .. user_q .. " tracks"
    if user_q > 0 then mesg = mesg .. " (may include Spotify suggestions)" end
    view_browse(entries, tracks, mesg, "your-queue", nil, nil)
    if jump_to_track_pending then return end
end)
end

view_volume = function()
    -- No supports_volume gate here. It only ever answered when a device lookup
    -- happened to run earlier in THIS process, so a fresh launch going straight
    -- to System > Volume skipped it entirely -- and when it did fire it blocked
    -- a menu that drives volume through playerctl, not the Spotify device API,
    -- so the device's supports_volume flag was not the capability being tested.
    -- get_spotifyd_device no longer carries the flag at all.
    local disp_vol = get_playerctl_volume()
    Util.scope({view="volume"}, function()
    while true do
        local vol_acts = {"Volume +5", "Volume -5", Util.markup('<span foreground="#20242a">────────────────────</span>'),
                               "Mute", "25%", "50%", "75%", "100%"}
        local vol_key = "volume:"
        local pre_sel = 0
        local saved = Util.pos_get(vol_key)
        if type(saved) == "string" then
            for i, a in ipairs(vol_acts) do if Util.strip_markup(a) == Util.strip_markup(saved) then pre_sel = i - 1; break end end
        end
        local vi = rofi_dmenu(vol_acts,
            {prompt="Volume", mesg=vol_mesg(disp_vol), custom=false, theme=THEME_SUB, markup=true, no_status=not current_track, sel=pre_sel})
        if not vi then break end
        Util.pos_put(vol_key, vi)
        local vol = disp_vol
        if vi == "Volume +5" then
            local nv = math.min(vol + 5, 100)
            os.execute("playerctl volume " .. string.format("%.2f", nv / 100) .. " 2>/dev/null")
            mem_bust("_playerctl_vol")
            save_volume(nv)
            disp_vol = nv
        elseif vi == "Volume -5" then
            local nv = math.max(vol - 5, 0)
            os.execute("playerctl volume " .. string.format("%.2f", nv / 100) .. " 2>/dev/null")
            mem_bust("_playerctl_vol")
            save_volume(nv)
            disp_vol = nv
        else
            local vol_presets = {Mute=0, ["25%"]=25, ["50%"]=50, ["75%"]=75, ["100%"]=100}
            local v = vol_presets[vi]
            if v then
                os.execute("playerctl volume " .. string.format("%.2f", v / 100) .. " 2>/dev/null")
                mem_bust("_playerctl_vol")
                save_volume(v)
                disp_vol = v
            end
        end
    end
end)
end

-- VIEW: PLAYBACK CONTROLS

view_seek = function(item)
    Util.scope({view="seek", track_id=item.id, strack_name=item.name or "", track_duration_ms=item.duration_ms or 0}, function()
    local seeks = {"+10s", "-10s", "+30s", "-30s", Util.markup('<span foreground="#20242a">────────────────────</span>'), "+1:00", "-1:00", "0:00"}
    local seek_key = "seek:" .. (item.id or "")
    while true do
        local pre_sel = 0
        local saved = Util.pos_get(seek_key)
        if type(saved) == "string" then
            for i, a in ipairs(seeks) do if Util.strip_markup(a) == Util.strip_markup(saved) then pre_sel = i - 1; break end end
        end
        local si = rofi_dmenu(seeks, {prompt="Seek", mesg=function() return seek_mesg(item) end, sel=pre_sel, custom=false, theme=THEME_SUB, markup=true})
        if not si then
            if jump_to_track_pending then return end
            break
        end
        Util.pos_put(seek_key, si)
        local delta
        local sign, secs = si:match("^([%+%-])(%d+)s$")
        if sign then delta = sign == "+" and tonumber(secs) or -tonumber(secs) end
        if not delta then
            local rsign, rm, rs = si:match("^([%+%-])(%d+):(%d+)$")
            if rsign then delta = (rsign == "+" and 1 or -1) * (tonumber(rm) * 60 + tonumber(rs)) end
        end
        if delta then
            local pos = get_playerctl_position()
            local dur = (item.duration_ms or 0) / 1000
            local target = math.max(0, math.min(dur > 0 and dur or math.huge, math.floor(pos + delta + 0.5)))
            os.execute("playerctl position " .. target .. " 2>/dev/null")
            mem_bust("_playerctl_pos")
        else
            local m, s = si:match("^(%d+):(%d+)$")
            if m and s then
                local target = tonumber(m) * 60 + tonumber(s)
                local dur = (item.duration_ms or 0) / 1000
                target = math.max(0, math.min(dur > 0 and dur or math.huge, target))
                os.execute("playerctl position " .. target .. " 2>/dev/null")
                mem_bust("_playerctl_pos")
            end
        end
    end
end)
end

Util.wait_playback_change = function(prev_id)
    if not prev_id then
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        return
    end
    os.execute("sleep 0.15")
    for _ = 1, 4 do
        -- Daemon file first: it reflects the change within ~a tick and costs a
        -- file read, versus ~300ms for a me/player round trip.
        if Util.fast_now_track() and current_id and current_id ~= prev_id then return true end
        last_playback = 0
        get_playback()
        if current_id and current_id ~= prev_id then return true end
        os.execute("sleep 0.15")
    end
    return current_id ~= prev_id
end

-- VIEW: LISTEN
--
-- Identify whatever the SPEAKERS are playing and hand the match to the ordinary
-- track action menu. The point is the audio spoot has nothing to do with -- a
-- video, a browser tab, someone else's playlist -- so it captures the default
-- sink's monitor rather than a microphone.
--
-- All three pieces live on Util rather than as file locals: the chunk is at
-- Lua's 200-local ceiling (see the note above Util's declaration), and splitting
-- the parse and the lookup out is also what makes them testable without audio.

-- songrec --json is Shazam's own response. Confirmed against a real one: the
-- artist is `subtitle`, not any field named artist (`artists` holds opaque
-- adamids), and `isrc` names the exact recording.
function Util.listen_parse(raw)
    local d = safe_decode(raw)
    local tr = d and d.track
    if type(tr) ~= "table" then return nil end
    local function field(k)
        local v = tr[k]
        if type(v) ~= "string" then return nil end
        v = trim(v)
        if v == "" then return nil end
        return v
    end
    local title = field("title")
    if not title then return nil end
    return {title = title, artist = field("subtitle"), isrc = field("isrc")}
end

-- Shazam's own SPOTIFY hub provider is no help here: it hands back
-- `spotify:search:<title>%20<artist>`, a search URI rather than a track id, so
-- the search is ours to do either way.
function Util.listen_lookup(m)
    if not m then return nil end
    -- ISRC names the exact RECORDING, so it lands on the master Shazam actually
    -- heard rather than a remaster, live cut or karaoke version sharing the
    -- title. Its own request because the filter is meaningless for the other
    -- five types api_search asks for, and this response keeps the .items
    -- envelope that Util.search_unwrap would have flattened.
    if m.isrc then
        local d = api_get("search",
            Util.with_market("q=isrc:" .. url_encode(m.isrc) .. "&type=track&limit=1"))
        local it = d and d.tracks and d.tracks.items and d.tracks.items[1]
        if it then return it end
    end
    -- Cached and shared with the search menu, so recognising the same song twice
    -- costs no request. Already unwrapped, hence .tracks[1] and not .items[1].
    local d = api_search(m.artist and (m.title .. " " .. m.artist) or m.title)
    return d and d.tracks and d.tracks[1] or nil
end

function Util.view_listen()
    if trim(shell("command -v songrec 2>/dev/null") or "") == "" then
        rofi_message("songrec is not installed"); return
    end
    -- The first sink, so this follows whatever the machine's default output is
    -- rather than naming a card. `.monitor` is the loopback of that sink: what
    -- is being PLAYED, not what a microphone hears.
    local sink = trim(shell("pactl list short sinks 2>/dev/null | awk 'NR==1{print $2}'") or "")
    if sink == "" then rofi_message("No audio output device found"); return end
    local device = sink .. ".monitor"

    local row_tf, out_tf = Util.tmpfile("listen.in"), Util.tmpfile("listen.out")
    local sr_pidf, ro_pidf = Util.tmpfile("listen.sr.pid"), Util.tmpfile("listen.ro.pid")
    local rf = io.open(row_tf, "w")
    if rf then rf:write("\0icon\x1f" .. P.assets .. "/listen.png\n"); rf:close() end

    -- songrec first, so recognition is already running while rofi maps its
    -- window. Backgrounded bare rather than inside a { } group: `$!` has to be
    -- songrec's own pid, because killing a wrapping subshell would leave the
    -- recorder holding the monitor. Its exit is also what marks the output file
    -- complete, so the loop below never reads a half-written response.
    os.execute("songrec recognize -d " .. shell_quote(device) .. " -j > " .. shell_quote(out_tf)
        .. " 2>/dev/null & echo $! > " .. shell_quote(sr_pidf))
    -- Same reason as view_art: bind the back combo so a Backspace here is
    -- consumed by this window instead of reaching the menu underneath.
    Util.bs_launch(Util.THEME_LISTEN)
    os.execute("rofi -dmenu -config " .. shell_quote(P.dir .. "/style/config.rasi")
        .. " -theme " .. shell_quote(Util.THEME_LISTEN)
        .. " -mesg " .. shell_quote("spoot is listening\u{2026}")
        .. " -no-custom -kb-custom-1 'Control+Shift+Delete'"
        .. " < " .. shell_quote(row_tf) .. " > /dev/null 2>&1 & echo $! > " .. shell_quote(ro_pidf))

    local function pid_of(f)
        local p = trim(read_file(f) or "")
        return p:match("^%d+$")
    end
    local raw, cancelled = nil, false
    local deadline = os.time() + P.listen_timeout
    while true do
        -- songrec gone means it answered: `recognize` exits on its first match.
        local sp = pid_of(sr_pidf)
        if sp and not Util.proc_alive(sp) then raw = read_file(out_tf); break end
        -- Window gone means the user gave up. Checking it is the whole reason
        -- this polls instead of blocking on songrec: with the recogniser in the
        -- foreground nothing could notice, and Escape would appear dead until
        -- the timeout ran out.
        local rp = pid_of(ro_pidf)
        if rp and not Util.proc_alive(rp) then cancelled = true; break end
        if os.time() >= deadline then break end
        os.execute("sleep " .. tostring(P.listen_poll))
    end

    for _, f in ipairs({ro_pidf, sr_pidf}) do
        local p = pid_of(f)
        if p then os.execute("kill " .. p .. " 2>/dev/null") end
    end
    -- Scoped to our own invocation, device and all: a bare `pkill songrec` would
    -- take down an unrelated one the user started themselves.
    os.execute("pkill -f " .. shell_quote("songrec recognize -d " .. device) .. " 2>/dev/null")
    for _, f in ipairs({row_tf, out_tf, sr_pidf, ro_pidf}) do os.remove(f) end
    if cancelled then return end

    local m = Util.listen_parse(raw)
    if not m then rofi_message("No match"); return end
    local track = Util.listen_lookup(m)
    if not track then
        rofi_message("Not on Spotify" .. SEP .. (m.artist and (m.artist .. SEP) or "") .. m.title)
        return
    end
    view_actions(track)
end

local function view_playback()
    -- Resync queue_idx to wherever playback actually is. A blind +1/-1 assumes
    -- queue_tracks is played in linear order, which breaks as soon as shuffle
    -- is on (Spotify's real next/previous track has no relation to our local
    -- index). Looking up current_id in queue_tracks keeps us correct in both.
    local function sync_queue_idx()
        if not queue_tracks or not current_id then return end
        -- The queue holds URIs and current_id is a bare id, so this compares
        -- through the same extractor the daemon uses rather than re-deriving
        -- the URI shape a second time.
        for i, uri in ipairs(queue_tracks) do
            if Util.extract_track_id(uri) == current_id then
                queue_idx = i; flush_queue(); return
            end
        end
    end
    Util.scope({view="playback"}, function()
    -- Rebuilding rows from live state only helps if that state was refreshed on
    -- the way in; without this, reopening Playback showed the transport as it
    -- stood when this process last looked.
    Util.sync_now()
    -- Every row here reflects live transport state, so it is rebuilt on each
    -- draw -- including a redraw from inside rofi_dmenu, where this loop does
    -- not run (Alt+r/Alt+s toggle shuffle and repeat from this very menu).
    -- keys[i] names row i for the life of this menu, whatever that row currently
    -- reads. Every label here is volatile (Pause/Resume, Shuffle ON/OFF, Repeat
    -- OFF/TRACK/CONTEXT, and Seek dims when nothing is playing), so remembering
    -- the cursor by label lost it the instant you used the row -- see Util.pos_row.
    local items, keys = {}, {}
    local function build_items()
        items, keys = {}, {}
        local function add(label, key) items[#items+1] = label; keys[#keys+1] = key end
        local play_label = current_track and (is_playing and "Pause" or "Resume") or nil
        if play_label then add(play_label, "play") end
        add(current_track and "Seek" or Util.dim("Seek"), "seek")
        add("Next Track", "next")
        add("Previous Track", "prev")
        add("Shuffle " .. (is_shuffle and Util.markup("<b>ON</b>") or Util.markup("<b>OFF</b>")), "shuffle")
        add("Repeat " .. (repeat_state=="off" and Util.markup("<b>OFF</b>") or (repeat_state=="track" and Util.markup("<b>TRACK</b>") or Util.markup("<b>CONTEXT</b>"))), "repeat")
        add("Your Queue", "queue")
        -- Dimmed when there is genuinely nothing in it. A local file read, not
        -- a request -- unlike Your Queue, which is me/player/queue and would
        -- cost one on every draw to learn the same thing.
        Util.recent_reload()
        add(#recent_tracks > 0 and "Recently Played" or Util.dim("Recently Played"), "recent")
        add("Open Web Link", "openurl")
        add("Listen\u{2026}", "listen")
        return items
    end
    -- Hoisted out of the loop: re-deriving it each pass read the stored value
    -- back AFTER build_items had already relabelled the row, so it never matched.
    local pb_key = "playback:"
    build_items()
    local pre_sel = Util.pos_row(pb_key, keys)
    while true do
        build_items()
        local si = rofi_dmenu(items, {prompt="Playback",
            mesg=function() return current_track and track_mesg(current_track) or nil end,
            custom=false, theme=THEME_SUB, markup=true, no_status=not current_track,
            sel=pre_sel, current=current_track, refresh=build_items})
        if not si then break end
        -- Resolved against `items` AS DRAWN -- the next pass's build_items has not
        -- run yet, so the label rofi echoed still matches the row it came from.
        for i, it in ipairs(items) do
            if Util.strip_markup(it) == Util.strip_markup(si) then
                pre_sel = i - 1; Util.pos_put(pb_key, keys[i]); break
            end
        end
        -- Compared plain from here down. A dimmed row echoes back carrying its
        -- markup, so `si == "Recently Played"` would silently stop matching the
        -- moment the row went grey -- the branch would vanish exactly when the
        -- user most needs to be told why. Stripping once keeps every branch
        -- below written in the label it displays. Rows that must stay inert when
        -- dimmed already guard themselves (Seek checks current_track).
        si = Util.strip_markup(si)
        if si == "Pause" then
            if not Util.transport(false) then rofi_message("Failed to pause") end
        elseif si == "Resume" then
            if not Util.transport(true) then rofi_message("Failed to resume") end
        elseif si == "Next Track" then
            local prev_id = current_id
            local r = do_playback_cmd("next")
            if Util.is2xx(r) then
                Util.wait_playback_change(prev_id)
                sync_queue_idx()
            elseif not recover_playback(1) then rofi_message("Failed to skip")
            else
                Util.wait_playback_change(prev_id)
                sync_queue_idx()
            end
        elseif si == "Previous Track" then
            local prev_id = current_id
            local r = do_playback_cmd("previous")
            if Util.is2xx(r) then
                Util.wait_playback_change(prev_id)
                sync_queue_idx()
            elseif not recover_playback(-1) then rofi_message("Failed to go back")
            else
                Util.wait_playback_change(prev_id)
                sync_queue_idx()
            end
        elseif si:find("^Shuffle") then toggle_shuffle()
        elseif si:find("^Repeat") then toggle_repeat()
        elseif si == "Seek" then
            if current_track then view_seek(current_track) end
        elseif si == "Your Queue" then
            view_your_queue()
            if jump_to_track_pending then break end
        elseif si == "Recently Played" then
            view_recently_played()
            if jump_to_track_pending then break end
        elseif si == "Listen\u{2026}" then
            Util.view_listen()
        elseif si == "Open Web Link" then
            local url = Util.get_clipboard()
            if url and url ~= "" then open_url(url)
            else rofi_message("Clipboard is empty") end
        end
    end
end)
end

-- VIEW: SYSTEM

-- Lifted out of view_system's "Restart Daemons" row so the bitrate view can
-- reuse it -- bitrate only takes effect when spotifyd is respawned, since
-- ensure_spotifyd reads get_saved_bitrate() at launch. Body is unchanged.
-- On Util rather than a file local: the chunk is at Lua's 200-local ceiling
-- (see the note above Util's declaration).
function Util.restart_daemons()
    os.execute("pkill -x spotifyd 2>/dev/null"); os.execute("pkill -f 'spoot.*--daemon' 2>/dev/null")
    Util.kill_recent_watch()
    Util.kill_playerctl_follow()
    Util.bust_device()
    -- Search results are cached until the daemons go, so this is where they go.
    Util.drop_search_cache()
    -- Deliberately keeps P.trails: restarting audio plumbing has
    -- nothing to do with navigation history.
    os.execute("sleep 1")
    -- Not inv_playback(): that clears current_track but LEAVES the saved
    -- queue, and get_playback reads "me/player empty" + "we still hold a
    -- queue" as a spotifyd dropout and forces a PUT /me/player/play. So
    -- restarting the daemons silently resumed the previous session --
    -- the same mechanism as the cold-start bug, in a second place.
    -- Killing the daemons must never leave the last track playing.
    -- Navigation state is untouched, exactly as the comment above says.
    Util.clear_last_playback()
    ensure_spotifyd()
    os.execute("sleep 3")
    Util.spawn_self({"--daemon"}, P.tmp .. "/spoot_daemon.log")
    Util.ensure_recent_watch()
end

-- A real scoped view rather than the one-shot menu this used to be inline in
-- view_system, so it behaves like every other submenu: the picker loops, an
-- action redraws it, and you leave with Escape/Backspace. Being a stack entry is
-- also what gives it a breadcrumb, replacing a hand-passed `crumb` opt.
--
-- Nothing is written until the restart is confirmed. That is the whole of
-- "Abort reverts": save_bitrate never ran, so there is nothing to undo, and
-- re-reading the saved value at the top of each pass makes the checkmark show
-- the truth for free.
Util.view_bitrate = function()
    Util.scope({view="bitrate"}, function()
    while true do
        local cur = get_saved_bitrate()
        local br_opts = {}
        for _, v in ipairs({96, 160, 320}) do
            if v == cur then
                table.insert(br_opts, Util.markup('<span foreground="#b6e0a4">')
                    .. "\u{f00c} " .. v .. " kbps" .. (v == 160 and " (default)" or "") .. Util.markup("</span>"))
            else
                local label = v .. " kbps"
                if v == 160 then label = label .. " (default)" end
                table.insert(br_opts, label)
            end
        end
        local chosen = rofi_dmenu(br_opts,
            {prompt="Bitrate", mesg="Current: " .. cur .. " kbps", custom=false, markup=true,
             theme=THEME_SUB, no_status=true, pos_key="bitrate"})
        if not chosen then return end
        local n = tonumber(Util.strip_markup(chosen):match("(%d+)"))
        if n and n ~= cur then
            -- Transient confirmation, so no pos_key -- same shape and theme as
            -- the Delete-playlist confirm in Util.open_playlist_actions.
            local c = rofi_dmenu({"Restart Daemons", "Abort"},
                {prompt="Bitrate", mesg=n .. " kbps" .. SEP .. "restart daemons to apply?",
                 custom=false, by_index=true, theme=THEME_SUB,
                 no_status=true, markup=true})
            if c == 1 then
                -- Before the restart: ensure_spotifyd reads the saved value.
                save_bitrate(n)
                Util.restart_daemons()
            end
            -- Abort and Backspace both land here having written nothing, and
            -- the loop redraws the picker with the original rate still checked.
            -- (Escape is bound app-wide to quit, so it leaves nothing written
            -- either -- the revert holds however this prompt is dismissed.)
        end
    end
    end)
end

local function view_system()
    local cur_br = get_saved_bitrate()
    local cur_vol = get_playerctl_volume()
    local vol_label = cur_vol == 0 and "Muted" or (cur_vol .. "%")
    local items = {"Keybinds", "Volume " .. Util.markup("<b>") .. vol_label .. Util.markup("</b>"), "Bitrate " .. Util.markup("<b>") .. cur_br .. " kbps" .. Util.markup("</b>"),
                   "Jump to Trail Step",
                   "Clear Session",
                   "Refresh Library",
                   "Re-authenticate",
                   "Restart Daemons",
                   "Kill Daemons"}
    -- Rows 2 and 3 are patched in place below as the volume and bitrate change,
    -- so the cursor is remembered by these stable keys rather than by the label
    -- (which no longer matched once it had been rewritten). See Util.pos_row.
    local keys = {"keybinds", "volume", "bitrate", "trailjump",
                  "clearsession", "refresh", "reauth", "restart", "kill"}
    Util.scope({view="system"}, function()
    local sys_key = "system:"
    local pre_sel = Util.pos_row(sys_key, keys)
    while true do
        local sel = rofi_dmenu(items, {prompt="System", custom=false, theme=THEME_SUB, markup=true, no_status=true, sel=pre_sel})
        if not sel then break end
        local clean = Util.strip_markup(sel)
        for i, it in ipairs(items) do
            if Util.strip_markup(it) == clean then
                pre_sel = i - 1; Util.pos_put(sys_key, keys[i]); break
            end
        end
        if clean == "Keybinds" then
            local function row(desc, key)
                local k = 15
                if not key then return string.rep(" ", k + 2) .. desc end
                return string.rep(" ", k - #key) .. Util.markup('<span foreground="#eebebe">') .. key .. Util.markup("</span>")
                    .. "  " .. desc
            end
            rofi_message(table.concat({
                row("grid redraw failsafe", "f5"),
                row("trail menu / history \u{2014} search type filter", "tab"),
                row("select -- play/pause/resume selected item", "return"),
                row("delete entry in search or trail history", "delete"),
                row("collapse current menu", "escape"),
                row("clear input / back one level", "backspace"),
                row("quick seek + / - 10s", "alt = / -"),
                row("hovered item's action menu", "shift return"),
                row("jump to current track's action menu", "alt return"),
                row("clear session", "alt delete"),
                row("jump to main menu", "alt space"),
                row("jump to seek menu", "alt e"),
                row("jump to liked tracks", "alt l"),
                row("jump to recently played", "alt p"),
                row("jump to lyrics of current track", "alt y"),
                row("jump to albumart of current track", "alt a"),
                row("cycle repeat modes", "alt r"),
                row("toggle shuffle", "alt s"),
                row("open spotify web link", "alt g"),
                row("jump to playing track in list", "alt c"),
                row("jump to current lyric line in lyrics view"),
            }, "\n"), THEME_BINDS)
        elseif clean:match("^Volume") then
            view_volume()
            cur_vol = get_playerctl_volume()
            vol_label = cur_vol == 0 and "Muted" or (cur_vol .. "%")
            items[2] = "Volume " .. Util.markup("<b>") .. vol_label .. Util.markup("</b>")
        elseif clean:match("^Bitrate") then
            -- Same shape as the Volume row above: open the view, then resync
            -- this menu's own label from whatever it left saved.
            Util.view_bitrate()
            cur_br = get_saved_bitrate()
            items[3] = "Bitrate " .. Util.markup("<b>") .. cur_br .. " kbps" .. Util.markup("</b>")
        elseif clean == "Refresh Library" then
            -- Synchronous, unlike the background revalidator: this row exists to
            -- be waited on. rofi_message rather than a desktop notification,
            -- matching every other System row -- caching has no business
            -- interrupting the desktop, but a row that blocks for half a minute
            -- and then says nothing reads as broken.
            local ok = Util.rebuild_library()
            if ok then populate_liked_ids() end
            rofi_message(ok and "Library refreshed" or "Library refresh failed")
        elseif clean == "Re-authenticate" then
            -- The only way to widen the granted scope set, and the only way to
            -- recover a revoked one without deleting token.json by hand. A
            -- refresh grant returns whatever was authorised the FIRST time,
            -- however much OAUTH_SCOPES has grown since.
            rofi_message(Util.reauth() and "Re-authenticated"
                or "Re-authentication failed")
        elseif clean == "Jump to Trail Step" then
            Util.view_trail_jump(_session_stack)
            main_pending = true
            break
        elseif clean == "Clear Session" then
            Util.clear_trail()
            main_pending = true
            break
        elseif clean == "Restart Daemons" then
            Util.restart_daemons()
        elseif clean == "Kill Daemons" then
            os.execute("pkill -x spotifyd 2>/dev/null")
            os.execute("pkill -f 'spoot.*--daemon' 2>/dev/null")
            Util.kill_recent_watch()
            Util.kill_playerctl_follow()
            Util.drop_search_cache()
            -- Session AND trail: this row is a shutdown, and clean_exit's
            -- os.exit means no scope unwinds to rewrite session.json -- so the
            -- stack was left naming THIS menu, and the next launch replayed
            -- straight back into it instead of opening on Main.
            Util.clear_trail()
            os.execute("pkill -x rofi 2>/dev/null")
            Util.clean_exit()
        end
    end
    end)
end

-- SESSION REPLAY

-- Registry population. `label` is the breadcrumb fallback used when the stack
-- entry carries no name of its own (see crumb_name); `open(s, prefer_current)`
-- restores the view from that entry and must be the SAME function the live menu
-- calls, so a restored step behaves identically to a freshly opened one.
-- label_only marks a view that is a DETAIL of the step above it in the stack --
-- always reached from a track's action menu, which has already shown that
-- track's name. Those render their label ("Lyrics", "Seek") rather than
-- repeating the name. Every other view shows its own name when it has one; see
-- Util.parts_from_stack for why this is declared per view rather than inferred
-- from two steps happening to share a string.
local function reg(view, label, open, label_only)
    VIEWS[view] = {label = label, open = open, label_only = label_only}
end

-- prefer_current (warm start only) follows the music across a restart, but only
-- for a menu that was opened on the then-playing track -- see from_current in
-- view_actions. Any other entry restores the exact track it names.
reg("action", "Track", function(s, prefer_current)
    if not s.track_id then return end
    -- The list this menu sat on top of is gone after a restart, so all_items and
    -- cidx stay nil; ctx_type/ctx_id survive in the stack entry and are enough
    -- for Remove from Playlist to still know which playlist you came from.
    if current_track and (current_track.id == s.track_id or (prefer_current and s.from_current)) then
        view_actions(current_track, s.ctx_type, s.ctx_id)
    else
        view_actions({id=s.track_id, name=s.track_name or "", artists=s.track_artists or {},
            album=s.track_album or {}, duration_ms=s.track_duration_ms or 0,
            unavail=s.track_unavail},
            s.ctx_type, s.ctx_id)
    end
end)
reg("lyrics", "Lyrics", function(s, prefer_current)
    if not s.track_id then return end
    if current_track and (current_track.id == s.track_id or (prefer_current and s.from_current)) then
        view_lyrics(current_track)
    else
        view_lyrics({id=s.track_id, name=s.lyrics_track_name or "", artists=s.lyrics_track_artists or {},
            unavail=s.lyrics_unavail})
    end
end, true)
reg("seek", "Seek", function(s)
    if not s.track_id then return end
    if current_track and current_track.id == s.track_id then view_seek(current_track)
    else view_seek({id=s.track_id, name=s.strack_name or "", duration_ms=s.track_duration_ms or 0}) end
end, true)
reg("album", "Album", function(s)
    if s.album_id then browse_album(s.album_id) end
end)
reg("show", "Podcast", function(s)
    if s.show_id then Util.open_show(s.show_id, s.show_name) end
end)
-- NOT label_only, matching reg("action", "Track"): the step above this one is a
-- LIST, so it shows the list's name, not the episode's -- and label_only would
-- make crumb_name's episode_name branch unreachable and the crumb read a bare
-- "Episode". The rebuilt stub carries type="episode" so view_actions' dispatch
-- sends it straight back here.
reg("episode-action", "Episode", function(s)
    if not s.episode_id then return end
    view_actions({id=s.episode_id, name=s.episode_name or "", type="episode",
        duration_ms=s.track_duration_ms or 0, unavail=s.episode_unavail,
        show=(s.show_id and {id=s.show_id, name=s.show_name}) or nil})
end)
reg("playlist", "Playlist", function(s)
    if not s.playlist_id then return end
    -- Util.playlist_meta answers from disk, so the whole replay is a disk read --
    -- and unlike a snapshot frozen into the stack entry, it carries a TTL and
    -- refreshes itself behind the menu, so an editorial playlist that Spotify
    -- has rebuilt since is noticed rather than served forever.
    Util.open_playlist(Util.playlist_meta(s.playlist_id)
        or {id=s.playlist_id, name=s.playlist_name or "Playlist"})
end)
reg("playlist-actions", "Playlist", function(s)
    if not s.playlist_id then return end
    -- Same cache: the {id, name} stub is what makes open_playlist_actions walk
    -- the whole playlist list to recover owner/images/total.
    Util.open_playlist_actions(Util.playlist_meta(s.playlist_id)
        or {id=s.playlist_id, name=s.playlist_name or "Playlist"})
end)
reg("recommendations", "More Like", function(s)
    if s.track_id then Util.open_recommendations(s.track_id, s.recs_track_name) end
end, true)
-- s.category is read by neither of these any more. Entries written by the split
-- search still carry it and still replay: the query is all that was ever needed
-- to rebuild the results, and the search box has nothing left to parameterise.
reg("search-results", "Search", function(s)
    if s.query then Util.open_search_results(s.query) end
end)
reg("category-playlists", "Category", function(s)
    if s.category_id then Util.open_category_playlists(s.category_id, s.category_name) end
end)
reg("add-to-playlist", "Add to Playlist", function(s)
    if s.track_id then view_add_pl(s.track_id, s.track_name) end
end, true)
reg("artist-actions", "Artist", function(s)
    if s.artist_id then view_artist({id=s.artist_id, name=s.artist_name or ""}) end
end)
reg("artist-albums", "Albums", function(s)
    if s.artist_id then Util.browse_artist_albums(s.artist_id, s.artist_name) end
end)
reg("liked-by-artist", "Liked Tracks", function(s)
    if s.artist_id then Util.browse_liked_by_artist(s.artist_id, s.artist_name) end
end)
reg("top-by-artist", "Top Tracks", function(s)
    if s.artist_id then Util.browse_top_by_artist(s.artist_id, s.artist_name) end
end)
reg("related", "Related", function(s)
    if s.artist_id then Util.browse_related_artists(s.artist_id, s.artist_name) end
end)
reg("search", "Search", function() view_search() end)
reg("liked",            "Liked Tracks",     function() view_liked_tracks() end)
reg("top-tracks",       "Top Tracks",       function() view_top_tracks() end)
reg("your-queue",       "Your Queue",       function() view_your_queue() end)
reg("recently-played",  "Recently Played",  function() view_recently_played() end)
reg("saved-albums",     "Saved Albums",     function() view_saved_albums() end)
-- Label as a FUNCTION: this view is named after the Spotify account, which is
-- not known at load time and can change. See view_label.
reg("library",          Util.account_name,  function() Util.view_library() end)
reg("podcasts",         "Podcasts",         function() Util.view_podcasts() end)
reg("show-list",        "Followed",         function() Util.view_saved_shows() end)
reg("saved-episodes",   "Saved Episodes",   function() Util.view_saved_episodes() end)
reg("latest-episodes",  "Latest Episodes",  function() Util.view_latest_episodes() end)
reg("podcast-search", "Podcasts", function(s)
    if s.query then Util.open_podcast_search(s.query) end
end)
reg("followed-artists", "Followed Artists", function() view_followed_artists() end)
reg("new-releases",     "New Releases",     function() view_new_releases() end)
reg("spotify-picks",    "Collections",      function() Util.view_collections() end)
reg("top-artists",      "Top Artists",      function() Util.view_top_artists() end)
reg("discover-genre",   "Genre",            function() Util.view_discover_genre() end)
reg("genre-tracks", "Genre", function(s)
    if s.genre then Util.open_genre_tracks(s.genre) end
end)
reg("featured",         "Featured",         function() Util.open_featured_playlists() end)
reg("categories",       "Categories",       function() view_categories() end)
reg("playlists",        "Playlists",        function() view_playlists() end)
reg("volume",           "Volume",           function() view_volume() end)
reg("bitrate",          "Bitrate",          function() Util.view_bitrate() end)
reg("playback",         "Playback",         function() view_playback() end)
reg("system",           "System",           function() view_system() end)

local function replay_session(prefer_current)
    -- Hoisted out of the loop: this used to run per stack entry, so restoring a
    -- deep trail could fan out into several ~300ms me/player round trips when
    -- one refresh covers the whole replay. It also has to sit ABOVE the
    -- session_peek guard -- an empty stack returned early and left the caller
    -- with no playback state at all, which is what main() then drew.
    Util.sync_now()

    local s = session_peek()
    if not s then return end

    while s do
        session_pop()
        local entry = VIEWS[s.view]
        if entry and entry.open then
            entry.open(s, prefer_current)
        end
        -- Alt+c asks the ENCLOSING list to move its cursor; there is no list
        -- behind a replay, so stop rebuilding ancestors and let main clear it.
        if jump_to_track_pending then return end
        s = session_peek()
    end
end

function Util.restore_trail()
    for i = #Util.trail_history, 1, -1 do
        local t = Util.trail_history[i]
        if type(t) == "table" and type(t.stack) == "table" and #t.stack > 0 then
            table.remove(Util.trail_history, i)
            Util.session_set(t.stack)
            Util.trail_save()
            replay_session()
            return true
        end
    end
    return false
end

-- Mode 2, Trail History: menus you closed that the trail no longer offers.
--
-- Rows are rendered from Util.parts_from_stack, the same function the breadcrumb
-- and mode 1 use, so a step can never be named one way here and another there.
-- The destination reads first and its context recedes behind it; rofi filters on
-- the whole line, so typing either one finds the row.
function Util.menu_hist_rows(live)
    local rows, entries = {}, {}
    local function reachable(path)
        if Util.stack_prefix(path, live) then return true end
        for _, t in ipairs(Util.trail_history) do
            if type(t) == "table" and type(t.stack) == "table"
               and Util.stack_prefix(path, t.stack) then return true end
        end
        return false
    end
    for _, e in ipairs(Util.menu_hist_all()) do
        if type(e) == "table" and type(e.stack) == "table" and #e.stack > 0
           and not reachable(e.stack) then
            local parts = Util.parts_from_stack(e.stack)
            local leaf = table.remove(parts)
            -- parts is now {"Main", …}; "Main" alone is not context worth
            -- printing, so a top-level menu is simply its own name.
            table.remove(parts, 1)
            local row = leaf
            if #parts > 0 then
                row = row .. Util.markup('<span foreground="' .. Util.DIM .. '">') .. "  \u{F01D8}  "
                    .. table.concat(parts, " > ") .. Util.markup("</span>")
            end
            rows[#rows+1] = row
            entries[#entries+1] = e
        end
    end
    return rows, entries
end

function Util.view_trail_jump(stack)
    local SEP = "  \u{F17B7}  "
    local opts = {}
    local function push(prefix, name, ostack, depth)
        opts[#opts+1] = {label=prefix .. name, stack=ostack, depth=depth}
    end
    local first = true
    -- Same guard as Util.parts_from_stack: a junk stack entry must not be able
    -- to take the whole menu down.
    -- Same rule as Util.parts_from_stack, and it has to stay that way: this menu
    -- lists the very steps that function renders, so the two disagreeing would
    -- mean jumping to a step whose label you never saw.
    local function step_name(e)
        if type(e) ~= "table" then return view_label(nil) end
        local v = VIEWS[e.view]
        local name = not (v and v.label_only) and crumb_name(e) or nil
        return name or view_label(e.view)
    end
    local function add_trail(stk, with_main)
        if with_main then
            push(first and "" or SEP, "Main", stk, 0)
            first = false
            if stk then
                for i = 1, #stk do
                    push(Util.crumb_arrow("> "), step_name(stk[i]), stk, i)
                end
            end
            return
        end
        if not stk or #stk == 0 then return end
        for i = 1, #stk do
            push(i == 1 and (first and "" or SEP) or Util.crumb_arrow("> "),
                 step_name(stk[i]), stk, i)
        end
        first = false
    end
    for _, t in ipairs(Util.trail_history) do
        if type(t) == "table" and type(t.stack) == "table" then add_trail(t.stack) end
    end
    add_trail(stack, true)
    -- Two modes, Tab cycling between them: the trail you are on, and the menus
    -- you closed and left behind. tab_select is what keeps Tab here instead of
    -- letting it bubble up and close this menu, the same opt-in shape
    -- alt_select uses for Shift+Return.
    --
    -- The two are INDEPENDENT, and that matters most right after you clear the
    -- session: alt delete (and the System entry) empty the trail but not the
    -- record of what you closed -- which is exactly what you want to reach at
    -- that moment. So "You left no trail" is only the right answer when there is
    -- nothing in EITHER, and an empty trail with a history opens straight into
    -- the history rather than dead-ending on a message.
    local have_trail = #opts > 1
    local mode = have_trail and "trail" or "history"
    if not have_trail and #(Util.menu_hist_rows(stack)) == 0 then
        rofi_message("You left no trail")
        replay_session()
        return
    end
    while true do
        local labels, chosen
        if mode == "trail" then
            labels = {}
            for i, o in ipairs(opts) do labels[i] = o.label end
        else
            labels, chosen = Util.menu_hist_rows(stack)
        end
        do
            -- These two menus are the only ones that suppress the breadcrumb:
            -- they already show the trail as their rows, so repeating it above
            -- them is noise. The line says what Tab does from here instead --
            -- which is the one binding you cannot discover by looking.
            -- Named before the draw so the hint can promise only what Tab will
            -- actually do: with one side empty there is nowhere to switch to,
            -- and the line says so rather than advertising a dead key.
            -- An if, not an and/or chain: "trail" with an empty history makes the
            -- middle term nil, and `a and nil or b` then falls through to b --
            -- which would advertise a switch back to the mode you are already in.
            local other
            if mode == "trail" then
                if #(Util.menu_hist_rows(stack)) > 0 then other = "history" end
            elseif have_trail then
                other = "trail"
            end
            -- All one dimmed grey, the same Util.DIM the breadcrumb uses for a
            -- trail step. This line is a footnote about a key, not content: it
            -- should sit behind the rows, not compete with them.
            -- Names the menu Tab goes TO, so the line reads as the pair of
            -- titles rather than as prose describing them. With one side empty
            -- there is nowhere to switch to, and it says that instead of
            -- advertising a dead key.
            local hint = Util.markup('<span foreground="' .. Util.DIM .. '">') .. "tab  "
                .. (other == "history" and "trail history"
                 or other == "trail" and "trail steps"
                 or (mode == "trail" and "nothing closed yet" or "no trail to go back to"))
                .. Util.markup("</span>")
            -- One string for the prompt and the heading so the two cannot drift.
            -- These menus hide the inputbar, so the prompt is never drawn and the
            -- message bar is the only place the mode can name itself -- which it
            -- has to, since Tab silently swaps the rows underneath you. Left
            -- unstyled so it takes the theme's message colour and reads as a
            -- heading over the dimmed keybind line below it. Only the FIRST mesg
            -- line is ever truncated (see rofi_dmenu), and this one is short, so
            -- the hint underneath always survives intact.
            local title = mode == "trail" and "Trail Steps" or "Trail History"
            local idx = rofi_dmenu(labels, {prompt = title,
                mesg = title .. "\n" .. hint,
                custom=false, by_index=true, markup=true, no_status=true,
                theme=Util.THEME_TRAIL,
                no_alt_space=true, tab_select=true, no_crumb=true,
                -- Only Trail History. A trail STEP is a place you can still go
                -- back to, not a record you would want to erase, and the rows in
                -- that mode are shared with the live stack.
                del_select = (mode == "history") or nil,
                sel = mode == "trail" and (#labels - 1) or 0})
            if Util.tab_pressed then
                Util.tab_pressed = false
                if other then mode = other end
                goto tj_next
            end
            if not idx then break end
            if Util.del_pressed then
                Util.del_pressed = false
                -- Redraw either way: the loop rebuilds `labels` from storage, so
                -- a removed row is gone and a failed removal simply reappears.
                if mode == "history" then Util.menu_hist_remove(chosen[idx]) end
                -- Deleting the last row would otherwise redraw an empty menu.
                -- Fall back to the trail if there is one, and give up only when
                -- both sides are empty -- the same rule the opening guard uses.
                if #(Util.menu_hist_rows(stack)) == 0 then
                    if not have_trail then break end
                    mode = "trail"
                end
                goto tj_next
            end
            if mode == "history" then
                local e = chosen[idx]
                if e then Util.session_set(json.decode(json.encode(e.stack))) end
                break
            end
            if idx >= 1 and idx <= #opts then
                local o = opts[idx]
                local target = {}
                for i = 1, o.depth do target[i] = o.stack[i] end
                if o.stack ~= stack then
                    for i = #Util.trail_history, 1, -1 do
                        if Util.trail_history[i] and Util.trail_history[i].stack == o.stack then
                            table.remove(Util.trail_history, i)
                            break
                        end
                    end
                    Util.trail_save()
                end
                Util.session_set(target)
            end
            break
        end
        ::tj_next::
    end
    -- Whether the user jumped or backed out, the view functions that unwound
    -- while Tab propagated up already popped _session_stack out from under
    -- whatever entries were in flight. Always replay so the displayed menu
    -- and the stack agree again — otherwise re-opening the same item pushes
    -- a second copy onto the stale stack, and the trail gains a duplicate.
    replay_session()
end

-- MAIN

local function init_instance_lock()
    local lock = P.tmp .. "/spoot_instance.lock"
    local existing = trim(read_file(lock) or "")
    -- Our OWN pid is not another instance. --listen takes the lock, then hands
    -- over to main() when a jump key was pressed, and main() locks again on the
    -- way in; without this the second call would find a live spoot named in the
    -- file, conclude one was already running, and exit(0) -- so the handover
    -- would look exactly like the key having closed spoot.
    if existing == tostring(Util.get_own_pid() or "") then existing = "" end
    if existing ~= "" and existing:match("^%d+$") then
        local alive = Util.proc_alive(existing)
        local cmdline = alive and Util.proc_cmdline(existing) or ""
        if alive and cmdline:find("spoot") then os.exit(0) end
    end
    -- AFTER the liveness check, never before: these two files belong to an
    -- in-flight OAuth flow, and oauth_get_token polls /tmp/spoot_code for up to
    -- 120s. Wiping them first meant launching spoot while the first instance was
    -- still logging in deleted the code file that instance was waiting for, and
    -- its login hung until the timeout.
    os.execute("rm -f " .. shell_quote(P.tmp .. "/spoot_code")
        .. " " .. shell_quote(P.tmp .. "/spoot_oauth_pid") .. " 2>/dev/null")
    local pid = Util.get_own_pid()
    if pid then Util.secure_write(lock, tostring(pid)) end
end

local function ensure_daemon()
    local daemon_alive = Util.pidfile_owner_alive(P.tmp .. "/spoot_daemon.pid", "--daemon")
    if not daemon_alive then
        Util.spawn_self({"--daemon"}, P.tmp .. "/spoot_daemon.log")
    end
    return daemon_alive
end

function Util.ensure_recent_watch()
    local alive = Util.pidfile_owner_alive(P.tmp .. "/spoot_recent.pid", "--recent-watch")
    if not alive then
        Util.spawn_self({"--recent-watch"}, P.tmp .. "/spoot_recent_watch.log")
    end
end

function Util.kill_recent_watch()
    local wp = trim(read_file(P.tmp .. "/spoot_recent.pid") or "")
    -- Validated before interpolation, like every sibling that reads a pid file
    -- (init_instance_lock, ensure_daemon, Util.spawn_art_prefetch). The pkill
    -- below is the fallback, so a garbled file costs nothing.
    if wp:match("^%d+$") then os.execute("kill " .. wp .. " 2>/dev/null") end
    os.execute("pkill -f 'spoot.*--recent-watch' 2>/dev/null")
    os.remove(P.tmp .. "/spoot_recent.pid")
end

function Util.kill_playerctl_follow()
    os.execute("pkill -f 'playerctl[ -]--follow metadata' 2>/dev/null")
end

local function check_rate_cooldown()
    local rate_cool = read_file(P.tmp .. "/spoot_rate_cooldown")
    if rate_cool then
        local until_t = tonumber(trim(rate_cool))
        if until_t and os.time() < until_t then
            local secs = until_t - os.time()
            rofi_message("Spotify API rate limit active.\nRetry after " .. secs .. "s.")
            return true
        end
        os.remove(P.tmp .. "/spoot_rate_cooldown")
    end
    return false
end

-- PLAYBACK state only. Runs on a cold start (MPRIS daemon not alive, so the
-- now-playing caches are stale) and from System > Restart Daemons. It must NOT
-- touch P.session: where you were in the menus is unrelated to whether the
-- daemon survived, and clearing it here is what made menu retention look random
-- -- fine while the daemon was up, silently reset after a reboot or a crash.
--
-- On Util rather than a file local so view_system can reach it: that function
-- is defined ~400 lines EARLIER, and a local declared here is simply not in
-- scope there. Same reason as Util.view_album_details and friends -- the chunk
-- is one function and Lua caps it at 200 locals, so a forward declaration is
-- not free. Util is a table looked up at call time, so order stops mattering.
function Util.clear_last_playback()
    Util.transport(false)
    os.remove(P.now); os.remove(P.now_track)
    current_track = nil; current_id = nil
    is_playing = false; last_playback = 0
    -- The saved queue is what resurrected the previous session: get_playback
    -- reads "me/player empty" + "queue held" as a spotifyd dropout and forces a
    -- PUT /me/player/play. Right for a dropout, wrong for a cold start, where
    -- the daemons were killed on purpose.
    --
    -- Cleared in memory too -- init_library calls load_queue() before this.
    -- Navigation state is deliberately untouched: session.json and trails.json
    -- survive a cold start.
    queue_tracks = nil; queue_idx = 0; queue_context = nil
    os.remove(P.queue)
end

local function init_library(cold_start)
    ensure_auth()
    ensure_spotifyd()
    load_queue()
    if cold_start then Util.clear_last_playback() end
    (function()
        local raw = read_file(P.state)
        if raw then local d = safe_decode(raw)
            if d then
                if d.repeat_state then repeat_state = d.repeat_state end
                if d.shuffle ~= nil then is_shuffle = d.shuffle end
            end
        end
    end)()
    -- Absent and expired are the same question, and cache_stale already answers
    -- both: a file with no fetched_at to read is stale by definition. The cold
    -- case used to be a second branch that built the library INLINE -- ~35
    -- requests before the menu could draw, on the one launch with nothing
    -- cached to draw anyway. Util.REVALIDATORS.library performs exactly that
    -- build in a detached process, and correctly: with no fingerprint on disk
    -- every probe differs from nil, so it re-pages the lot.
    --
    -- The trade is deliberate -- a first launch opens instantly onto a library
    -- that is still filling in, rather than waiting for one that is complete --
    -- and the main loop picks the liked set up as soon as it lands.
    if cache_stale(P.liked) or cache_stale(P.albums) or cache_stale(P.artists) then
        Util.spawn_revalidate("library")
    end
    populate_liked_ids()
    -- Warm the playlist membership index out of band. Nothing waits on it: the
    -- action menu serves the last known index and picks up the new one next run.
    if not disk_get(P.pl_index, CACHE_TTL_SHORT) then Util.spawn_plindex() end
    -- The tile grids' artwork, warmed at LAUNCH rather than on first open.
    -- Their tiles are the only ones whose art sits behind a shelf fetch, so
    -- unlike every other grid there is nothing for Util.album_thumbs to fetch
    -- synchronously before the first draw -- it can only show placeholders and
    -- wait. Starting here buys the warm the seconds it takes to walk from the
    -- main menu to Collections, which is usually all it needs. Both are
    -- rate-limited and no-ops once warm, so a normal launch spawns nothing.
    for kind in pairs(Util.SHELF_KINDS) do Util.spawn_shelf_warm(kind) end
    Util.trail_load()
    session_load()
    replay_session(true)
    last_playback = os.time()
end

-- THE ROOT GRID
--
-- Five tiles, drawn by main() rather than by Util.view_tile_grid: the root is
-- not a stack entry, and it owns the pending-flag handling (Alt+L, Alt+P, the
-- trail jump, back) that every other menu unwinds THROUGH. So it borrows the
-- pieces -- Util.shelf_tiles for resolution, Util.album_thumbs for decoration --
-- rather than the whole view.
--
-- Where a row declares `art` it follows the same rule as every other tile list:
-- the cover of the thing behind the row, read under Util.cache_only. The rows
-- that declare none wear their drop-in asset instead, which is the whole reason
-- style/assets/<key>.png is consulted by name.
Util.MAIN_TILES = {
    -- Whatever is playing, so the root screen shows it without being opened.
    -- Util.src_images resolves a track through its album.
    {key = "playback",    label = "Playback",    open = function() view_playback() end,
     -- Whatever is playing, falling back to the menu's own name when nothing is.
     -- The second value marks it as the playing row, so the caption gets the
     -- same glyph and green a track row gets in every other list.
     name = function()
        if not current_track then return nil end
        return current_track.name, true
     end,
     -- States its case rather than returning a bare nil: nothing playing is an
     -- ANSWER, not an unread shelf, so this falls through to
     -- style/assets/playback.png instead of the last track's cover. It is not
     -- dimmed for it -- Playback is always openable -- which is why the state is
     -- "noart" and not "empty".
     -- Cover only: this opens the transport menu, which has its own fixed rows
     -- whether or not anything is playing.
     art_only = true,
     art  = function()
        if current_track then return current_track, "ok" end
        return nil, "noart"
     end},
    -- No `art`: this one wears style/assets/collections.png rather than borrowing
    -- the cover of whatever happens to sit first on a Collections shelf. A row
    -- with no art source at all resolves straight to its drop-in asset, and
    -- because that is a definite "no artwork" it also clears any cover an earlier
    -- build left in art/main/collections.jpg.
    {key = "collections", label = "Collections", open = function() Util.view_collections() end},
    -- Your own profile picture. The one tile whose art is genuinely yours, and
    -- the row a fresh launch opens on -- see main().
    {key = "library",     label = "Library",     open = function() Util.view_library() end,
     name = function() return Util.account_name() end,
     -- Cover only, like Podcasts: your profile picture stands for a menu of five
     -- fixed rows, so an unreadable profile must not read as an empty library.
     art_only = true,
     art  = function() return api_get_me() end},
    -- Both are pickers over names rather than shelves of objects, so neither has
    -- an object whose cover could stand for it. Each now has a drop-in asset of
    -- its own, which Util.shelf_tiles prefers; the declared fallbacks stay as
    -- what they resolve to if that file is ever removed.
    {key = "search",      label = "Search",      open = function() view_search() end,
     fallback = Util.ART_GENRE},
    {key = "system",      label = "System",      open = function() view_system() end,
     fallback = Util.ART_NONE},
}

local function main()
    init_instance_lock()
    local cold_start = not ensure_daemon()
    Util.ensure_recent_watch()
    if check_rate_cooldown() then Util.clean_exit() end
    init_library(cold_start)

    local first_loop = true
    local main_key = "main||"

    while true do
        flush_liked_cache()
        -- The cold library build runs detached now, so on the launch that
        -- triggers it populate_liked_ids() ran against a file that did not exist
        -- yet and left the ♥ set empty for the whole session. Pick it up the
        -- moment it lands instead. Guarded on the set being empty AND the file
        -- having appeared, so it can fire at most once, and only on that launch.
        if not next(liked) and cache_exists(P.liked_ids) then populate_liked_ids() end
        -- Refresh on the first loop too. Skipping it meant a fresh launch drew
        -- the main menu with current_track still nil, so the mesg had no track
        -- and `no_status = not current_track` suppressed the shuffle/repeat
        -- icons as well -- they only appeared once you backed out of a submenu.
        -- sync_now prefers the daemon's cache, so the cold path costs two file
        -- reads rather than the me/player call the skip was avoiding.
        Util.sync_now()
        local is_first = first_loop
        first_loop = false
        if is_first then
            if current_id and current_track then record_recent_play(current_track) end
            previous_id = current_id
        elseif current_id and current_id ~= previous_id then
            record_recent_play(current_track)
            previous_id = current_id
        end
        -- A function so a hotkey that plays/likes from here redraws with the
        -- new state instead of the header this iteration built.
        --
        -- status_mesg is folded in BY HAND because rofi_dmenu only prepends it
        -- for non-thumbnail menus -- the grid themes have no status line. Losing
        -- the shuffle and repeat markers off the root screen was not worth the
        -- grid, so they are carried here instead.
        -- Dropped entirely when nothing is loaded. With no track the row carried
        -- only the shuffle/repeat pair, which says nothing on its own and left a
        -- band of empty header above the grid. Returning nil omits -mesg, and
        -- rofi draws no message widget at all rather than reserving space for an
        -- empty one.
        local mesg = function()
            if not current_track then return nil end
            local status = status_mesg()
            local track  = track_mesg(current_track)
            return status and (status .. "  " .. track) or track
        end

        -- A fresh launch opens on the account tile instead of wherever the last
        -- session happened to leave the cursor. Located BY KEY so reordering
        -- MAIN_TILES cannot silently move it, and only on the first draw --
        -- every reentry after that (backing out of a submenu, a pending jump)
        -- restores the remembered row exactly as before.
        local first_sel
        if is_first then
            for i, t in ipairs(Util.MAIN_TILES) do
                if t.key == "library" then first_sel = i - 1 end
            end
        end
        local focus = first_sel or Util.pos_get(main_key)

        -- Rebuilt per draw: the Playback tile wears the current track's cover,
        -- so this list is only correct for as long as that has not changed.
        -- Captions resolved per draw: two of these rows name themselves from
        -- live state -- the account, and the track currently playing.
        -- Tiles first, captions second: a caption asks its resolved tile whether
        -- the shelf behind it turned out to be empty, so it has to exist by then.
        local entries = {}
        local tiles, cold = Util.shelf_tiles(Util.MAIN_TILES)
        local function labels()
            for i, t in ipairs(Util.MAIN_TILES) do entries[i] = Util.tile_label(t, tiles[i]) end
        end
        labels()
        if cold then Util.spawn_shelf_warm("main") end
        Util.album_thumbs(entries, tiles, "main", focus, main_key)
        -- by_index, like every other thumbnail grid: album_thumbs appends a
        -- \0icon field to each row, so matching rofi's echo back against the row
        -- TEXT is exactly the comparison that suffix would break. It also
        -- retires comparing the account tile against its own escaped label.
        --
        -- `sel` is set only on the first draw; passing nil leaves rofi_dmenu's
        -- own pos_key restore in charge, which is what every later draw wants.
        -- `theme` overrides only the theme choice; `thumbs` still selects the
        -- grid's row count, icon thread pool and status-line suppression.
        local sel = rofi_dmenu(entries, {prompt="Spotify", mesg=mesg, pos_key=main_key,
            custom=false, by_index=true, markup=true, thumbs=true,
            theme=Util.THEME_MAIN,
            no_status=not current_track, sel=first_sel, alt_select=true,
            refresh=function()
                tiles = Util.shelf_tiles(Util.MAIN_TILES)
                -- Captions too, not just art: a redraw is how the grid picks up
                -- a shelf that emptied (or filled) since this draw began.
                labels()
                Util.album_thumbs(entries, tiles, "main", Util.pos_get(main_key), main_key)
                return entries
            end})
        -- Read immediately, per the contract on Util.alt_pressed: the next
        -- rofi_dmenu, nested or not, clears it -- and the pending-flag branches
        -- below open views that call one.
        local alt = Util.alt_pressed
        Util.alt_pressed = false

        if main_pending   then main_pending   = false; goto m1 end
        if liked_pending then
            liked_pending = false
            local base = Util.jump_preserve_stack
            Util.jump_preserve_stack = nil
            if base and #base > 0 then Util.session_set(base) end
            view_liked_tracks()
            if base and #base > 0 then replay_session() end
            goto m1
        end
        if recent_pending then
            recent_pending = false
            local base = Util.jump_preserve_stack
            Util.jump_preserve_stack = nil
            if base and #base > 0 then Util.session_set(base) end
            view_recently_played()
            if base and #base > 0 then replay_session() end
            goto m1
        end
        if Util.trail_jump_pending then
            Util.trail_jump_pending = false
            local snap = Util.trail_jump_stack
            Util.session_set(snap)
            Util.view_trail_jump(snap)
            goto m1
        end
        if jump_to_track_pending then jump_to_track_pending = false; goto m1 end
        if Util.back_pressed then
            Util.back_pressed = false
            if _session_stack and #_session_stack > 1 then
                session_pop()
                replay_session()
                goto m1
            elseif Util.restore_trail() then
                goto m1
            end
        end
        if not sel then goto m1 end

        if sel >= 1 and sel <= #Util.MAIN_TILES then
            local tile = Util.MAIN_TILES[sel]
            -- Shift+Return on Playback goes straight to the playing track's own
            -- action menu -- the same destination the key reaches from any track
            -- row, so the tile behaves like the row it is standing in for. With
            -- nothing playing there is no track to act on, so it opens the
            -- Playback menu as an ordinary accept would.
            if alt and tile.key == "playback" and current_track then
                view_actions(current_track)
            else
                tile.open()
            end
        end
        ::m1::
    end
end

-- DAEMON MODE — MPRIS listener for zero-API-call notifications

local function daemon_mode()
    local lock = P.tmp .. "/spoot_daemon.pid"
    local claim = P.tmp .. "/spoot_daemon.lock"
    local mypid = Util.get_own_pid()
    -- Both takeover paths below SIGTERM the pid they find, so ownership has to
    -- be answered strictly. Matching "spoot" alone matched any process merely
    -- MENTIONING spoot -- a shell, an editor, a test harness with the path in
    -- argv -- so a recycled pid killed something unrelated. (Hit for real while
    -- testing this file.) A daemon is always `lua <dir>/spoot.lua --daemon`, so
    -- requiring the flag costs nothing. Plain find, not a pattern.
    local function is_our_daemon(pid)
        local c = Util.proc_cmdline(pid)
        return c:find("spoot", 1, true) ~= nil and c:find("--daemon", 1, true) ~= nil
    end
    local claimed = trim(shell("mkdir " .. claim .. " 2>/dev/null && echo ok") or "") == "ok"
    if not claimed then
        local holder = tonumber((read_file(claim .. "/pid") or ""):match("(%d+)"))
        local holder_alive = holder and holder ~= mypid
            and Util.proc_alive(holder)
            and is_our_daemon(holder)
        if holder_alive then
            os.execute("kill " .. holder .. " 2>/dev/null; sleep 0.1")
        end
        os.execute("rm -rf " .. shell_quote(claim) .. " 2>/dev/null")
        claimed = trim(shell("mkdir " .. claim .. " 2>/dev/null && echo ok") or "") == "ok"
    end
    if not claimed then return nil end
    if mypid then Util.secure_write(claim .. "/pid", tostring(mypid)) end
    local prev = read_file(lock)
    local prev_pid = prev and tonumber(prev:match("(%d+)"))
    if prev_pid and prev_pid > 0 and prev_pid ~= mypid and is_our_daemon(prev_pid) then
        os.execute("kill " .. prev_pid .. " 2>/dev/null; sleep 0.1")
    end
    if mypid then Util.secure_write(lock, tostring(mypid)) end
    Util.kill_playerctl_follow()

    local NOTIFY_FILE = P.tmp .. "/spoot_last_notify"
    local last_title = nil
    local last_track_id = nil

    -- Dedupe lives here, ahead of the spawn, so a burst of MPRIS snaps for one
    -- track starts exactly one notify helper.
    local function notify_seen(track_id)
        if not (track_id and #track_id > 0) then return false end
        local prev_id = read_file(NOTIFY_FILE)
        if prev_id and trim(prev_id) == track_id then return true end
        Util.secure_write(NOTIFY_FILE, track_id)
        return false
    end

    local FIELD_SEP = "\x1f"

    local function process_snap(snap)
        if not snap then return end
        snap = trim(snap)
        local title, artist, art_url, track_id, album, duration_raw =
            snap:match("^([^\x1f]*)\x1f([^\x1f]*)\x1f([^\x1f]*)\x1f([^\x1f]*)\x1f([^\x1f]*)\x1f([^\x1f]*)$")
        local track_kind
        track_id, track_kind = Util.extract_track_id(track_id)
        local duration = tonumber(duration_raw) and tonumber(duration_raw) / 1000000 or nil
        local track_changed = track_id and #track_id > 0 and track_id ~= last_track_id
        local title_changed = title and title ~= "" and title ~= last_title
        if not track_changed and not title_changed then return end
        if track_id and #track_id > 0 then
            -- `type` is carried through because this object reaches
            -- view_actions via Util.fast_now_track, and that is what routes an
            -- episode to its own action menu rather than the track one. For an
            -- episode MPRIS reports the show in {{artist}}, so it lands in
            -- `artists` here and Util.subtitle reads it back out unchanged.
            write_file(P.now, json.encode({ id=track_id, name=title, type=track_kind,
                artists={{name=artist or ""}}, album={name=album or ""},
                duration_ms=math.floor((duration or 0) * 1000),
                playing=trim(shell("playerctl status 2>/dev/null")) == "Playing" }))
            last_track_id = track_id
        end
        if title and title ~= "" then last_title = title end
        -- One helper instead of three spawns plus an inline notify. The old
        -- order was self-defeating: the notification was composed two statements
        -- after launching --prefetch-track/--prefetch-lyrics, reading caches
        -- those processes had not written yet, so a track's first play always
        -- lost its explicit and lyrics glyphs -- and the dedupe above meant they
        -- were never filled in later. The helper fetches first, notifies last,
        -- off this loop so nothing blocks the playerctl --follow stream.
        if title and #trim(title) > 0 and not notify_seen(track_id) then
            -- The KIND rides along too. Without it the helper resolved every id
            -- as a track, so an episode 404'd, now_track.json kept the previous
            -- TRACK, and Util.fast_now_track then answered false on every menu
            -- entry for as long as the podcast played -- a me/player round trip
            -- per menu, which is the exact cost carrying the kind removes.
            Util.spawn_self({"--notify", track_id or "", title, artist or "", album or "",
                duration and tostring(math.floor(duration)) or "", art_url or "",
                track_kind or ""})
        end
    end

    local function daemon_loop()
        local FMT = "{{title}}" .. FIELD_SEP .. "{{artist}}" .. FIELD_SEP .. "{{mpris:artUrl}}" .. FIELD_SEP
            .. "{{mpris:trackid}}" .. FIELD_SEP .. "{{album}}" .. FIELD_SEP .. "{{mpris:length}}"
        process_snap(shell("playerctl metadata -f " .. shell_quote(FMT) .. " 2>/dev/null"))
        local p = io.popen("playerctl --follow metadata -f " .. shell_quote(FMT) .. " 2>/dev/null", "r")
        if not p then return nil end
        for line in p:lines() do
            process_snap(line)
        end
        p:close()
    end

    while true do
        local ok, err = pcall(daemon_loop)
        if not ok then
            io.stderr:write("spoot daemon error: " .. tostring(err) .. "\n")
        end
        os.execute("sleep 2")
    end
end

-- RECENT-WATCH — always-on recorder. Polls the live playback endpoint so any
-- play on the account (regardless of source or local MPRIS) lands in Recently
-- Played even while the interactive UI is closed.

function Util.recent_watch_mode()
    Util.detached = true
    local mypid = Util.get_own_pid()
    if mypid then Util.secure_write(P.tmp .. "/spoot_recent.pid", tostring(mypid)) end
    local last_id = nil
    local nil_strikes = 0
    local function poll()
        -- additional_types for the same reason get_playback carries it: without
        -- it me/player answers item: null while an episode plays, so a podcast
        -- would record nothing and count as a dropout strike. With it, episodes
        -- land in Recently Played too -- which is more than Spotify's own
        -- recently-played endpoint offers, since that one is tracks-only.
        local d = api_get("me/player", Util.with_market("additional_types=episode"))
        if not d or type(d) ~= "table" or not d.item or not d.item.id then
            nil_strikes = nil_strikes + 1
            return
        end
        nil_strikes = 0
        local id = d.item.id
        -- Free: progress_ms rides on the response this poll already makes, so
        -- recording where you are in an episode costs no request and no second
        -- process. 25s granularity is the poll interval, which is the most this
        -- can lose -- and it is 25s against "always from the beginning".
        if d.item.type == "episode" then
            Util.eresume_put(id, d.progress_ms, d.item.duration_ms)
        end
        if id ~= last_id then
            record_recent_play(d.item)
            last_id = id
        end
    end
    while true do
        local cooldown = tonumber((read_file(P.tmp .. "/spoot_rate_cooldown") or ""):match("%d+"))
        if cooldown and os.time() < cooldown then
            os.execute("sleep " .. math.max(cooldown - os.time(), 1))
        else
            local ok, err = pcall(poll)
            if not ok then
                io.stderr:write("spoot recent-watch error: " .. tostring(err) .. "\n")
                nil_strikes = nil_strikes + 1
            end
            os.execute("sleep " .. (nil_strikes >= 3 and 60 or 25))
        end
    end
end

-- Shared by --prefetch-lyrics and --notify so there is one definition of "look
-- these lyrics up and cache the answer", including the negative one.
function Util.fetch_and_cache_lyrics(id, title, artist, album, duration)
    if not (id and title and artist) then return end
    if not id:match("^[A-Za-z0-9]+$") then return end
    local disk = P.lyrics .. "/lyrics_" .. id .. ".json"
    if disk_get(disk, P.ttl_lyrics) then return end
    if disk_get(P.lyrics .. "/nolyr_" .. id .. ".json", P.ttl_lyrics) ~= nil then return end
    local result, definitive = api_get_lyrics(title, artist, album, duration)
    if result then
        disk_set(disk, result)
        Util.lyr_bust(id)
    elseif definitive then
        disk_set(P.lyrics .. "/nolyr_" .. id .. ".json", true)
    end
end

local function run_prefetch_lyrics()
    Util.detached = true
    local id = arg[2]
    if not (id and arg[3] and arg[4]) then os.exit(2) end
    Util.fetch_and_cache_lyrics(id, arg[3], arg[4],
        arg[5] ~= "" and arg[5] or nil,
        arg[6] and tonumber(arg[6]) or nil)
    os.exit(0)
end

-- Fetch everything the notification needs, THEN send it. Ordering is the whole
-- point: the track object supplies `explicit` and the lyrics lookup decides
-- which lyrics glyph applies, and neither is knowable at the moment the daemon
-- sees the MPRIS event.
function Util.run_notify()
    Util.detached = true
    local id       = arg[2] ~= "" and arg[2] or nil
    local title    = arg[3]
    local artist   = arg[4] ~= "" and arg[4] or nil
    local album    = arg[5] ~= "" and arg[5] or nil
    local duration = arg[6] and tonumber(arg[6]) or nil
    local art_url  = arg[7] ~= "" and arg[7] or nil
    local kind     = arg[8] ~= "" and arg[8] or nil
    if not title or #trim(title) == 0 then os.exit(0) end

    -- Off the follow loop now, so the full retry budget is affordable.
    local art_path = ""
    if art_url then art_path = ensure_art(Util.art_url(art_url, "1e02")) or "" end

    local track
    if id and id:match("^[A-Za-z0-9]+$") then
        -- Market + collapse, like every other track source: without it this
        -- writer left 183 available_markets entries in now_track.json -- ~a third
        -- of a file fast_now_track reads and decodes on nearly every menu entry.
        --
        -- An episode is fetched from its OWN endpoint. tracks/<episode id> is a
        -- 404, and the object that comes back here is what now_track.json holds
        -- and what view_actions is later handed -- so it has to carry `type`, or
        -- the episode arrives at the track action menu.
        local is_ep = kind == "episode"
        track = api_get((is_ep and "episodes/" or "tracks/") .. id, Util.with_market())
        if track then
            -- `playing` is written here as well; run_prefetch_track omitted it
            -- while get_playback includes it, which left fast_now_track reading
            -- transport state from the daemon's one-shot snapshot instead.
            write_file(P.now_track, json.encode({
                item = track,
                playing = trim(shell("playerctl status 2>/dev/null")) == "Playing",
            }))
        end
        -- Episodes have no lyrics to look up, and asking spends a request plus a
        -- negative-cache entry on every one that plays.
        if not is_ep then
            Util.fetch_and_cache_lyrics(id, title, artist or "", album, duration)
        end
    end

    local icons = Util.status_icons({id = id, explicit = track and track.explicit})
    local body = Util.pango_escape(artist or "")
    icons = icons:gsub("^%s+", "")
    if icons ~= "" then body = body .. (body ~= "" and "\n" or "") .. icons end

    os.execute("notify-send --app-name=spoot "
        .. (#art_path > 0 and ("--icon=" .. shell_quote(art_path)) or "")
        .. " " .. shell_quote(title)
        .. " " .. shell_quote(body))
    os.exit(0)
end

-- The daemon no longer spawns this (--notify covers that path), but it stays as
-- a standalone way to refresh now_track.json. It has to write `playing` like
-- every other writer of this file, or fast_now_track falls back to the daemon's
-- one-shot snapshot for transport state.
local function run_prefetch_track()
    Util.detached = true
    local id = arg[2]
    if not id or not id:match("^[A-Za-z0-9]+$") then os.exit(0) end
    local track = api_get("tracks/" .. id, Util.with_market())
    if track then
        write_file(P.now_track, json.encode({
            item = track,
            playing = trim(shell("playerctl status 2>/dev/null")) == "Playing",
        }))
    end
    os.exit(0)
end

function Util.run_prefetch_plindex()
    Util.detached = true
    Util.build_pl_index()
    os.exit(0)
end

-- Grid tails, spooled by Util.spawn_art_prefetch as url<TAB>path<TAB>kind<TAB>
-- key<TAB>hash chunks. DRAINS the spool rather than handling one hand-off: while
-- this runs, every other grid opened keeps writing chunks into the same
-- directory, and the whole point of the spool is that none of them are lost.
-- Each chunk is consumed and removed before it is fetched, so a crash cannot
-- leave one to be retried forever, and the index is committed per chunk so a
-- worker killed mid-drain still recorded everything it finished.
function Util.run_prefetch_art_batch()
    Util.detached = true
    local dir = Util.art_spool_dir()
    -- arg[2] is the pre-spool calling convention -- a single batch file passed by
    -- path. Still honoured so a worker spawned by the previous build, or one
    -- already in flight across an upgrade, finishes its work instead of dropping
    -- it on the floor.
    local first = arg[2]
    if first and #first == 0 then first = nil end
    -- Bounded so a spool that somehow refills forever cannot make this immortal;
    -- whatever is left is picked up by the next draw's worker.
    for _ = 1, 200 do
        local lf = first
        first = nil
        if not lf then
            local names = {}
            local p = io.popen("ls -1 " .. shell_quote(dir) .. " 2>/dev/null")
            if p then
                for line in p:lines() do
                    -- Dot-prefixed names are chunks still being written.
                    if line:sub(1, 1) ~= "." then names[#names+1] = line end
                end
                p:close()
            end
            if #names == 0 then break end
            table.sort(names)
            lf = dir .. "/" .. names[1]
        end
        local raw = read_file(lf)
        os.remove(lf)
        local list, kind = {}, nil
        for line in (raw or ""):gmatch("[^\n]+") do
            -- Trailing fields are empty for hash-named artwork, which needs no index.
            local url, path, k, art_key, hash = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
            if url and #url > 0 and #path > 0 then
                list[#list+1] = {url = url, path = path,
                                 art_key = #art_key > 0 and art_key or nil,
                                 hash = #hash > 0 and hash or nil}
                if #k > 0 then kind = k end
            end
        end
        if #list > 0 then
            ensure_cache()
            Util._art_batch(list)
            -- Same bookkeeping the synchronous half does, so these covers count
            -- as cached on the next draw instead of being fetched again.
            if kind and P.art_kinds[kind] then Util.art_commit(kind, list) end
        end
    end
    os.exit(0)
end

-- Reads P.thumb_log back. A grid cannot be inspected after it is closed, so this
-- is the only account of why a draw came up with holes: it names the reason
-- rather than printing the numbers and leaving them to be interpreted.
--
-- `spoot.lua --thumb-report [n]` -- the last n draws that had placeholders
-- (default 20), worst first, then a per-view tally.
function Util.thumb_report()
    Util.detached = true
    local raw = read_file(P.thumb_log)
    if not raw then print("no thumbnail log yet: " .. P.thumb_log); os.exit(0) end
    local rows = {}
    for line in raw:gmatch("[^\n]+") do
        -- Split on tabs by hand. gmatch("[^\t]*") is the obvious spelling and is
        -- wrong: a pattern that can match the empty string yields one between
        -- every pair of fields, which slides every column one place along.
        local r, i, pos = {}, 1, 1
        while true do
            local s, e = line:find("\t", pos, true)
            local fld = line:sub(pos, (s or 0) - 1)
            if not s then fld = line:sub(pos) end
            local k = Util.THUMB_FIELDS[i]
            if k then r[k] = fld end
            i = i + 1
            if not s then break end
            pos = e + 1
        end
        if r.kind then
            for _, k in ipairs({"items","cursor","cached","missing","sync_try","sync_ok",
                                "sync_fail","tail","placeholders","invalid","ms"}) do
                r[k] = tonumber(r[k]) or 0
            end
            rows[#rows+1] = r
        end
    end
    -- Ranked by how much of the grid was wrong, not by how many tiles: 12 holes
    -- in 20 is the report worth reading, 12 in 1400 is a scroll away from normal.
    local bad = {}
    for _, r in ipairs(rows) do
        if r.placeholders > 0 then
            r.share = r.placeholders / math.max(r.items, 1)
            bad[#bad+1] = r
        end
    end
    table.sort(bad, function(a, b) return a.share > b.share end)
    local want = tonumber(arg[2]) or 20
    print(string.format("%d draws logged, %d with placeholders", #rows, #bad))
    print("")
    for i = 1, math.min(#bad, want) do
        local r = bad[i]
        -- In the order they'd have to be ruled out. Only the first that applies
        -- is printed: a draw whose tail was dropped has not got a second problem,
        -- it has that one.
        local why
        if r.invalid > 0 then
            why = r.invalid .. " cached file(s) not a decodable image -- refetched now, "
                .. "used to be a permanently dead tile"
        elseif r.tail_action == "spoolfail" then
            why = "tail of " .. r.tail .. " could not be spooled (is " .. P.tmp .. " writable?)"
        elseif r.sync_fail > 0 then
            why = r.sync_fail .. " of " .. r.sync_try .. " synchronous fetches failed"
        elseif r.tail > 0 then
            why = "grid larger than the " .. r.sync_try .. "-cover synchronous budget; "
                .. r.tail .. " left to the background (" .. r.tail_action .. ")"
        else
            why = "covers were simply not cached yet"
        end
        print(string.format("%s  %s  %s", os.date("%Y-%m-%d %H:%M:%S", tonumber(r.ts) or 0),
            r.kind, r.view))
        print(string.format("    %d/%d tiles placeholder  (cached %d, missing %d, sync %d/%d, tail %d %s, %dms)",
            r.placeholders, r.items, r.cached, r.missing, r.sync_ok, r.sync_try,
            r.tail, r.tail_action, r.ms))
        print("    " .. why)
    end
    print("")
    print("per view:")
    local per, order = {}, {}
    for _, r in ipairs(rows) do
        local k = r.kind .. "  " .. r.view
        if not per[k] then per[k] = {draws = 0, clean = 0, ph = 0, inval = 0, tail = 0}; order[#order+1] = k end
        local a = per[k]
        a.draws = a.draws + 1
        if r.placeholders == 0 then a.clean = a.clean + 1 end
        a.ph = a.ph + r.placeholders
        a.inval = a.inval + r.invalid
        a.tail = a.tail + r.tail
    end
    table.sort(order)
    for _, k in ipairs(order) do
        local a = per[k]
        print(string.format("  %-46s %3d draws, %3d clean, %5d placeholders, %d invalid, %d backgrounded",
            k:sub(1, 46), a.draws, a.clean, a.ph, a.inval, a.tail))
    end
    os.exit(0)
end

-- Fills in whatever a tile grid could not draw. Util.shelf_tiles reads the
-- shelves cache-only so a grid never waits on them; this is the other half --
-- it reads them FOR real, which populates each shelf's ordinary cache, and then
-- fetches the covers those shelves point at. Nothing here is specific to either
-- grid beyond the tile list: the shelf caches it warms are the same ones the
-- rows open with, so the first visit to any of them is faster too.
--
-- Keyed by ART KIND, which is also the P.art_kinds key the covers are filed
-- under and the argument the CLI arm carries -- one name for one thing.
Util.SHELF_KINDS = {
    main       = function() return Util.MAIN_TILES end,
    library    = function() return Util.LIBRARY_ROWS end,
    collection = function() return Util.COLLECTION_TILES end,
    podcast  = function() return Util.PODCAST_TILES end,
}

-- The pid file below stops two warmers running AT ONCE; this stops one running
-- on every single open, for the plain reason that a warm which just ran cannot
-- have anything new to fetch.
--
-- It used to be load-bearing for a second reason: Util.shelf_tiles could not
-- tell "shelf not cached yet" from "shelf is genuinely empty", so a Podcasts
-- grid with nothing followed reported `cold` forever and spawned a process on
-- every draw. Util.shelf_head tells those apart now and `cold` is set only for
-- an unread shelf, so this is back to being an ordinary rate limit.
function Util.spawn_shelf_warm(kind)
    if not Util.SHELF_KINDS[kind] then return end
    local stamps = disk_get(P.warm) or {}
    if type(stamps) ~= "table" then stamps = {} end
    local last = tonumber(stamps[kind]) or 0
    if os.time() - last < CACHE_TTL_SHORT then return end
    -- Sanitised into the pid file name the same way Util.spawn_revalidate does
    -- with a revalidator name, and matched against the same way on the way back.
    local pidf = P.tmp .. "/spoot_warm_" .. kind:gsub("[^%w_]", "") .. ".pid"
    if Util.pidfile_owner_alive(pidf, "--warm-shelf") then return end
    -- Stamped at SPAWN, not on completion: the point is to bound how often this
    -- is attempted, and a warm that fails is exactly one that must not be
    -- retried on the very next draw.
    stamps[kind] = os.time()
    disk_set(P.warm, stamps)
    Util.spawn_self({"--warm-shelf", kind}, nil, pidf)
end

function Util.run_shelf_warm()
    Util.detached = true
    local kind = arg[2] or ""
    local get = Util.SHELF_KINDS[kind]
    if not get then os.exit(0) end
    ensure_cache()
    -- Every shelf this grid needs, fetched at once rather than one per tile as
    -- the walk below reaches it. Only the topic tiles are searches; the rest are
    -- single endpoints the walk still fetches individually, which is fine
    -- because there are few of them.
    if kind == "podcast" then Util.search_prefetch(Util.PODCAST_TOPICS) end
    local list = {}
    for _, t in ipairs(get() or {}) do
        if t.art then
            local ok, src = pcall(t.art)
            local imgs = ok and Util.src_images(src) or nil
            if imgs and imgs[1] and imgs[1].url then
                -- fetch=false so this goes through _art_batch with everything
                -- else, rather than one blocking download per shelf.
                local path, url, hash, key = Util.keyed_art(kind,
                    {id = t.key, images = imgs}, false, false, nil)
                if url then
                    list[#list+1] = {url = url, path = path, art_key = key, hash = hash}
                end
            end
        end
    end
    if #list > 0 then
        Util._art_batch(list)
        Util.art_commit(kind, list)
    end
    os.exit(0)
end

-- ── Backspace monitor ─────────────────────────────────────────────────
-- Backspace is ambiguous: rofi edits the filter natively, but on an empty
-- filter the press is swallowed by its keyboard grab. This watches the
-- keyboard at the evdev layer (Wayland) and, while the filter is known
-- empty, injects the "back one level" combo (Control+Shift+Delete =
-- kb-custom-1) via uinput. The combo excludes Backspace on purpose: it is
-- injected while that key is still held, and compositors dedupe a repeat
-- of a held keycode, so a fresh key is needed.
--
--   * BS_C_SOURCE / bs_compile  C helper "spbsd": forwards EV_KEY events as
--     "K <code> <val>" on ev.fifo, injects on demand via cmd.fifo.
--   * bsmon_mode (--bsmon)      holds a shadow of rofi's filter (per-key word
--     class) so Ctrl+Backspace word-deletes match textbox_cursor_dec_word;
--     injects when a Backspace arrives with the shadow empty.
--   * bs_start/bs_launch/bs_stop  lifecycle: started on the first menu, reused
--     after, torn down in clean_exit. Spawn is async, so a Backspace in the
--     first instant of a new menu (before spbsd is READY) may be missed.

Util.BS_C_SOURCE = [=[
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <linux/input.h>
#include <linux/uinput.h>

#define MAXDEV 32
#define NBITS(x) ((((x) - 1) / (8 * sizeof(unsigned long))) + 1)
#define INJ_NAME "spbsd-inject"

static int devfds[MAXDEV];
static int ndev = 0;
static int evfd = -1;
static int cmdfd = -1;
static int uifd = -1;

static void on_term(int sig) {
    (void)sig;
    _exit(0);
}

static int has_backspace(int fd) {
    unsigned long evbits[NBITS(EV_MAX)] = {0};
    if (ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits) < 0) return 0;
    if (!(evbits[EV_KEY / (8 * sizeof(unsigned long))]
          & (1UL << (EV_KEY % (8 * sizeof(unsigned long)))))) return 0;
    unsigned long keys[NBITS(KEY_MAX)] = {0};
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys) < 0) return 0;
    return (keys[KEY_BACKSPACE / (8 * sizeof(unsigned long))]
            & (1UL << (KEY_BACKSPACE % (8 * sizeof(unsigned long))))) ? 1 : 0;
}

/* Skip our own injector device so injected keys never loop back. */
static int is_own_device(int fd) {
    char name[256];
    if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0) return 0;
    name[sizeof(name) - 1] = 0;
    return strcmp(name, INJ_NAME) == 0;
}

static void setup_uinput(void) {
    uifd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (uifd < 0) {
        fprintf(stderr, "HELPER no uinput\n");
        return;
    }
    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    strncpy(setup.name, INJ_NAME, sizeof(setup.name) - 1);
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x1234;
    setup.id.product = 0x5678;
    setup.id.version = 1;
    ioctl(uifd, UI_SET_EVBIT, EV_KEY);
    ioctl(uifd, UI_SET_KEYBIT, KEY_DELETE);
    ioctl(uifd, UI_SET_KEYBIT, KEY_LEFTCTRL);
    ioctl(uifd, UI_SET_KEYBIT, KEY_RIGHTCTRL);
    ioctl(uifd, UI_SET_KEYBIT, KEY_LEFTSHIFT);
    ioctl(uifd, UI_SET_KEYBIT, KEY_RIGHTSHIFT);
    if (ioctl(uifd, UI_DEV_SETUP, &setup) < 0
        || ioctl(uifd, UI_DEV_CREATE) < 0) {
        close(uifd);
        uifd = -1;
        return;
    }
    usleep(10000); /* let the kernel register /dev/input/eventX */
    fprintf(stderr, "HELPER uinput ready\n");
}

static void inject_back(void) {
    if (uifd < 0) return;
    struct input_event e[7];
    int n = 0;
    memset(&e[n], 0, sizeof(e[0])); e[n].type = EV_KEY; e[n].code = KEY_LEFTCTRL;  e[n].value = 1; n++;
    memset(&e[n], 0, sizeof(e[0])); e[n].type = EV_KEY; e[n].code = KEY_LEFTSHIFT; e[n].value = 1; n++;
    memset(&e[n], 0, sizeof(e[0])); e[n].type = EV_KEY; e[n].code = KEY_DELETE;     e[n].value = 1; n++;
    memset(&e[n], 0, sizeof(e[0])); e[n].type = EV_KEY; e[n].code = KEY_DELETE;     e[n].value = 0; n++;
    memset(&e[n], 0, sizeof(e[0])); e[n].type = EV_KEY; e[n].code = KEY_LEFTSHIFT; e[n].value = 0; n++;
    memset(&e[n], 0, sizeof(e[0])); e[n].type = EV_KEY; e[n].code = KEY_LEFTCTRL;  e[n].value = 0; n++;
    memset(&e[n], 0, sizeof(e[0])); e[n].type = EV_SYN; e[n].code = SYN_REPORT;    e[n].value = 0; n++;
    if (write(uifd, e, n * sizeof(struct input_event)) < 0)
        fprintf(stderr, "HELPER inject write failed\n");
}

static void open_devices(void) {
    DIR *d = opendir("/dev/input");
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "event", 5) != 0) continue;
        char path[160];
        snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        if (!has_backspace(fd) || is_own_device(fd)) { close(fd); continue; }
        if (ndev < MAXDEV) {
            devfds[ndev++] = fd;
            fprintf(stderr, "HELPER open %s\n", path);
        }
        else close(fd);
    }
    closedir(d);
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    const char *evfifo = argv[1];
    const char *cmdfifo = argv[2];
    setup_uinput();
    open_devices();
    fprintf(stderr, "HELPER devices=%d\n", ndev);
    evfd = open(evfifo, O_WRONLY);
    if (evfd < 0) return 3;
    if (ndev == 0) {
        dprintf(evfd, "NODEV\n");
        close(evfd);
        return 4;
    }
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    dprintf(evfd, "READY\n");
    if (uifd < 0) dprintf(evfd, "NOUINPUT\n");
    cmdfd = open(cmdfifo, O_RDONLY | O_NONBLOCK);
    int running = 1;
    while (running) {
        fd_set rfds;
        FD_ZERO(&rfds);
        int maxfd = -1;
        for (int i = 0; i < ndev; i++) {
            FD_SET(devfds[i], &rfds);
            if (devfds[i] > maxfd) maxfd = devfds[i];
        }
        if (cmdfd >= 0) {
            FD_SET(cmdfd, &rfds);
            if (cmdfd > maxfd) maxfd = cmdfd;
        }
        if (maxfd < 0) break;
        int r = select(maxfd + 1, &rfds, NULL, NULL, NULL);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (cmdfd >= 0 && FD_ISSET(cmdfd, &rfds)) {
            char buf[64];
            int n = read(cmdfd, buf, sizeof(buf));
            for (int i = 0; i < n; i++) {
                if (buf[i] == '1') inject_back();
            }
        }
        for (int i = 0; i < ndev && running; i++) {
            if (!FD_ISSET(devfds[i], &rfds)) continue;
            struct input_event ev;
            int n = read(devfds[i], &ev, sizeof(ev));
            if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
                close(devfds[i]);
                devfds[i] = devfds[--ndev];
                i--;
                continue;
            }
            if (n < 0) continue;
            if (n < (int)sizeof(ev)) continue;
            if (ev.type != EV_KEY) continue;
            if (dprintf(evfd, "K %d %d\n", ev.code, ev.value) < 0) {
                running = 0;
                break;
            }
        }
    }
    if (uifd >= 0) {
        ioctl(uifd, UI_DEV_DESTROY);
        close(uifd);
    }
    if (evfd >= 0) close(evfd);
    if (cmdfd >= 0) close(cmdfd);
    for (int i = 0; i < ndev; i++) close(devfds[i]);
    return 0;
}
]=]

function Util.bs_compile()
    os.execute("mkdir -p " .. shell_quote(P.cache))
    local bin = P.cache .. "/spbsd"
    local stamp = P.cache .. "/spbsd.stamp"
    local function exists(p)
        local f = io.open(p, "r")
        if f then f:close(); return true end
        return false
    end
    if (read_file(stamp) or "") ~= tostring(#Util.BS_C_SOURCE) or not exists(bin) then
        local src = P.cache .. "/spbsd.c"
        write_file(src, Util.BS_C_SOURCE)
        os.execute("gcc -O2 -w -o " .. shell_quote(bin) .. " " .. shell_quote(src) .. " 2>/dev/null")
        os.remove(src)
        write_file(stamp, tostring(#Util.BS_C_SOURCE))
    end
    if exists(bin) then
        os.execute("chmod +x " .. shell_quote(bin))
        return bin
    end
    return nil
end

function Util.bs_clear_on_bs(theme)
    if not theme then return false end
    local content = read_file(theme) or ""
    local val = content:match("kb%-remove%-to%-sol%s*:%s*\"([^\"]+)\"")
    return val ~= nil and val:find("BackSpace") ~= nil
end

function Util.bs_start(clear_bs)
    local bin = Util.bs_bin or Util.bs_compile()
    if not bin then return nil end
    Util.bs_bin = bin
    local pid = tostring(Util.get_own_pid() or math.random(100000, 999999))
    local run = P.tmp .. "/spoot_bs_" .. pid .. "_" .. tostring(math.random(10000, 99999))
    os.execute("mkdir -p " .. shell_quote(run))
    local evf = run .. "/ev.fifo"
    local cmdf = run .. "/cmd.fifo"
    os.execute("mkfifo " .. shell_quote(evf) .. " " .. shell_quote(cmdf) .. " 2>/dev/null")
    -- Written before the monitor starts so it can never see a missing control
    -- file and mistake that for "the app exited".
    Util._bs_gen = 1
    write_file(run .. "/gen", "1 " .. (clear_bs and "1" or "0"))
    Util.spawn_self({"--bsmon", run, clear_bs and "1" or "0"}, run .. "/bsmon.log")
    return { run = run, ev = evf, cmd = cmdf }
end

-- Spawned once per app run, not per menu draw: the old way re-parsed this 214KB
-- file (~18ms) plus mkdir/mkfifo/pkill/rm -rf (~8ms) on all 29 render sites.
-- Each draw now just bumps a generation counter.
--
-- The generation is correctness, not theming: bsmon's filter shadow and its
-- one-shot `injected` latch used to reset only because the process was thrown
-- away. A persistent monitor ignoring it would send "back" once, then look dead.
function Util.bs_launch(theme)
    if os.getenv("SPOOT_NO_BS") then return nil end
    local clear_bs = Util.bs_clear_on_bs(theme)
    if not Util._bs then
        Util._bs = Util.bs_start(clear_bs)
        if not Util._bs then return nil end
        return Util._bs
    end
    Util._bs_gen = (Util._bs_gen or 1) + 1
    write_file(Util._bs.run .. "/gen", Util._bs_gen .. " " .. (clear_bs and "1" or "0"))
    return Util._bs
end

-- Real teardown, once, at exit. Per-draw teardown is gone.
function Util.bs_stop()
    local bs = Util._bs
    if not bs then return end
    Util._bs = nil
    os.execute("pkill -f " .. shell_quote(bs.run) .. " 2>/dev/null")
    os.execute("rm -rf " .. shell_quote(bs.run))
end

function Util.bsmon_mode()
    local run = arg[2]
    if not run then os.exit(2) end
    local clear_bs = (arg[3] == "1")
    io.write(string.format("BSMON started run=%s clear_bs=%s\n", run, clear_bs and "1" or "0"))
    io.flush()
    local evf = run .. "/ev.fifo"
    local cmdf = run .. "/cmd.fifo"
    os.execute("mkfifo " .. shell_quote(evf) .. " " .. shell_quote(cmdf) .. " 2>/dev/null")
    local bin = Util.bs_bin or Util.bs_compile()
    if not bin then os.exit(3) end
    Util.bs_bin = bin
    os.execute(shell_quote(bin) .. " " .. shell_quote(evf) .. " " .. shell_quote(cmdf)
        .. " >> " .. shell_quote(run .. "/helper.log") .. " 2>&1 &")
    local ev = io.open(evf, "r")
    if not ev then os.exit(4) end
    local cmd = io.open(cmdf, "w")
    if not cmd then ev:close(); os.exit(5) end
    local use_wtype = false
    local injected = false
    local function inject_back()
        if injected then return end
        injected = true
        io.write("BSMON inject\n"); io.flush()
        if cmd then
            cmd:write("1")
            cmd:flush()
        end
        if use_wtype then
            os.execute("wtype -M ctrl -M shift -k Delete -m ctrl -m shift 2>/dev/null")
        end
    end
    local KEY_LEFTCTRL, KEY_RIGHTCTRL = 29, 97
    local KEY_LEFTSHIFT, KEY_RIGHTSHIFT = 42, 54
    local KEY_LEFTALT, KEY_RIGHTALT = 56, 100
    local printable = {}
    for i = 2, 13 do printable[i] = true end
    for i = 16, 27 do printable[i] = true end
    for i = 30, 41 do printable[i] = true end
    printable[43] = true
    printable[86] = true
    for i = 44, 53 do printable[i] = true end
    printable[55] = true
    printable[57] = true
    for i = 71, 83 do printable[i] = true end
    printable[98] = true
    printable[117] = true
    printable[121] = true
    local shadow = ""
    local is_word = {}
    for i = 2, 11 do is_word[i] = true end
    for i = 16, 25 do is_word[i] = true end
    for i = 30, 38 do is_word[i] = true end
    is_word[40] = true
    for i = 44, 50 do is_word[i] = true end
    for i = 71, 73 do is_word[i] = true end
    for i = 75, 77 do is_word[i] = true end
    for i = 79, 82 do is_word[i] = true end
    local function shadow_del_one()
        shadow = shadow:sub(1, #shadow - 1)
    end
    local function shadow_word_back()
        local n = #shadow
        while n > 0 and shadow:sub(n, n) ~= "w" do n = n - 1 end
        while n > 0 and shadow:sub(n, n) == "w" do n = n - 1 end
        shadow = shadow:sub(1, n)
    end
    local lctrl, rctrl, lshift, rshift, lalt, ralt = 0, 0, 0, 0, 0, 0

    -- The monitor now outlives individual menus, so per-menu state has to be
    -- reset explicitly. The app bumps <run>/gen before each draw; on a change we
    -- clear the shadow filter (every rofi starts with an empty one) and, just as
    -- importantly, the `injected` one-shot latch -- without that reset a single
    -- back-press would disable Backspace-as-back for the rest of the session.
    local gen_path = run .. "/gen"
    local app_pid = tostring(run:match("spoot_bs_(%d+)_") or "")
    local cur_gen = nil
    local function sync_gen()
        local raw = read_file(gen_path)
        if not raw then os.exit(0) end          -- run dir removed: app exited
        -- app died without cleaning up
        if app_pid ~= "" and not Util.proc_alive(app_pid) then os.exit(0) end
        local g, cb = raw:match("^(%d+)%s+(%d)")
        if g and g ~= cur_gen then
            cur_gen  = g
            clear_bs = (cb == "1")
            shadow   = ""
            injected = false
        end
    end
    sync_gen()

    for line in ev:lines() do
        if line == "NODEV" then
            io.write("BSMON helper NODEV\n"); io.flush()
            break
        elseif line == "READY" then
            io.write("BSMON helper ready\n"); io.flush()
        elseif line == "NOUINPUT" then
            use_wtype = true
            io.write("BSMON helper no uinput, using wtype\n"); io.flush()
        elseif line:sub(1, 2) == "K " then
            sync_gen()
            local code_s, val_s = line:match("^K (%d+) (%d+)$")
            if code_s then
                local code, val = tonumber(code_s), tonumber(val_s)
                local is_mod = code == KEY_LEFTCTRL or code == KEY_RIGHTCTRL
                    or code == KEY_LEFTSHIFT or code == KEY_RIGHTSHIFT
                    or code == KEY_LEFTALT or code == KEY_RIGHTALT
                if is_mod then
                    if val == 0 then
                        if code == KEY_LEFTCTRL then lctrl = 0
                        elseif code == KEY_RIGHTCTRL then rctrl = 0
                        elseif code == KEY_LEFTSHIFT then lshift = 0
                        elseif code == KEY_RIGHTSHIFT then rshift = 0
                        elseif code == KEY_LEFTALT then lalt = 0
                        elseif code == KEY_RIGHTALT then ralt = 0 end
                    elseif val == 1 or val == 2 then
                        if code == KEY_LEFTCTRL then lctrl = 1
                        elseif code == KEY_RIGHTCTRL then rctrl = 1
                        elseif code == KEY_LEFTSHIFT then lshift = 1
                        elseif code == KEY_RIGHTSHIFT then rshift = 1
                        elseif code == KEY_LEFTALT then lalt = 1
                        elseif code == KEY_RIGHTALT then ralt = 1 end
                    end
                elseif val == 1 or val == 2 then
                    local ctrl = (lctrl + rctrl) > 0
                    local alt = (lalt + ralt) > 0
                    if ctrl and alt then
                        if code == 35 then
                            shadow_word_back()
                        end
                    elseif ctrl and not alt then
                        if code == 17 then
                            shadow = ""
                        elseif code == 22 then
                            if not clear_bs then shadow = "" end
                        elseif code == 14 then
                            shadow_word_back()
                        elseif code == 35 or code == 32 then
                            if not clear_bs then shadow_del_one() end
                        elseif code == 47 then
                            local cb = shell("wl-paste 2>/dev/null")
                            if cb and cb ~= "" then
                                shadow = shadow .. string.rep("?", utf8.len(cb) or #cb)
                            end
                        end
                    elseif not alt then
                        if code == 14 then
                            local empty = (#shadow == 0)
                            if clear_bs then shadow = ""
                            else shadow_del_one() end
                            if empty then inject_back() end
                        elseif printable[code] then
                            shadow = shadow .. (is_word[code] and "w" or "s")
                        end
                    end
                end
            end
        end
    end
    ev:close()
    os.exit(0)
end

-- Interactive spoot is the one path with no error handling at all. An error
-- anywhere in it used to print a traceback to stderr -- which nobody sees,
-- because rofi has closed and a keybind launch has no terminal -- and then die
-- WITHOUT reaching Util.clean_exit, so a pending like/unlike reconciliation was
-- dropped by the missing flush_liked_cache() and the bsmon and scratch
-- directories leaked. The window simply vanished.
--
-- The detached modes already have this covered: daemon_mode wraps
-- pcall(daemon_loop) and recent_watch_mode wraps pcall(poll). The one-shot
-- helpers write to /dev/null, so there is nobody to tell.
--
-- A function rather than an inline block because the chunk body is at Lua's
-- 200-local ceiling (see the note above Util's declaration) -- these locals have
-- to be function-scoped to fit.
function Util.run_interactive(fn)
    local ok, err = xpcall(fn, Util.traceback)
    if ok then return end
    err = tostring(err)
    local log = P.tmp .. "/spoot_crash.log"
    -- Every step below is individually guarded: a failure while REPORTING the
    -- crash must not stop us reaching the cleanup at the end.
    pcall(function()
        -- Appended, not write_file: that does an atomic replace and would throw
        -- away the previous crash, which is usually the one you want once a
        -- second turns up.
        local f = io.open(log, "a")
        if f then
            f:write("\n=== ", os.date("%Y-%m-%d %H:%M:%S"), " ===\n", err, "\n")
            f:close()
        end
    end)
    local first = err:match("^[^\n]*") or "unknown error"
    pcall(io.stderr.write, io.stderr, err .. "\n")
    -- notify-send as well as rofi: if the crash was in theme resolution then
    -- rofi_message cannot draw at all, so the fallback must not need a theme.
    pcall(os.execute, "notify-send -u critical --app-name=spoot 'spoot crashed' "
        .. shell_quote(first) .. " 2>/dev/null &")
    pcall(rofi_message, "spoot crashed\n" .. Util.pango_escape(first)
        .. "\n\nfull trace: " .. log)
    pcall(Util.clean_exit, 1)
    os.exit(1)   -- only reached if clean_exit itself failed before its os.exit
end

if arg and arg[1] == "--daemon" then
    daemon_mode()
elseif arg and arg[1] == "--recent-watch" then
    Util.recent_watch_mode()
elseif arg and arg[1] == "--prefetch-lyrics" then
    run_prefetch_lyrics()
elseif arg and arg[1] == "--prefetch-track" then
    run_prefetch_track()
elseif arg and arg[1] == "--prefetch-art-batch" then
    Util.run_prefetch_art_batch()
elseif arg and arg[1] == "--thumb-report" then
    Util.thumb_report()
elseif arg and arg[1] == "--prefetch-plindex" then
    Util.run_prefetch_plindex()
elseif arg and arg[1] == "--warm-shelf" then
    Util.run_shelf_warm()
elseif arg and arg[1] == "--revalidate" then
    Util.run_revalidate()
elseif arg and arg[1] == "--notify" then
    Util.run_notify()
elseif arg and arg[1] == "--bsmon" then
    Util.bsmon_mode()
elseif arg and arg[1] == "--listen" then
    -- The one flag that opens rofi, so it gets the same wrapper main() does: a
    -- keybind launch has no terminal, and without run_interactive a crash here
    -- would vanish without reaching Util.clean_exit. Only the preamble the flow
    -- actually needs -- the instance lock (so pressing the key while spoot is
    -- open does nothing rather than racing a second window), the daemon for the
    -- Play row the action menu offers, and one sync so that menu opens on live
    -- transport state. No init_library: nothing here reads the library.
    Util.run_interactive(function()
        init_instance_lock()
        ensure_daemon()
        Util.sync_now()
        Util.view_listen()
        -- Alt+Space, Alt+L, Alt+P and the trail jump do not navigate themselves:
        -- they raise a flag and unwind, and main()'s loop is what acts on it.
        -- Reached from the keybind there is no main loop above this, so the flag
        -- was simply dropped and the process ended -- which read as the key
        -- closing spoot rather than going to the root menu. Hand over instead.
        if main_pending or liked_pending or recent_pending or Util.trail_jump_pending then
            main()
        end
    end)
elseif arg and arg[1] then
    os.exit(2)
else
    -- Interactive spoot is the one path with no error handling at all. An error
    -- anywhere in it used to print a traceback to stderr -- which nobody sees,
    -- because rofi has closed and a keybind launch has no terminal -- and then
    -- die WITHOUT reaching Util.clean_exit, so a pending like/unlike
    -- reconciliation was dropped by the missing flush_liked_cache() and the
    -- bsmon and scratch directories leaked. The window simply vanished.
    --
    -- The detached modes already have this covered: daemon_mode wraps
    -- pcall(daemon_loop) and recent_watch_mode wraps pcall(poll). The one-shot
    -- helpers write to /dev/null, so there is nobody to tell.
    Util.run_interactive(main)
end
end)()
