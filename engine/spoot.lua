#!/usr/bin/env lua

(function()

-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- spoot Spotify Client ~ Part of the ZENWORKS Suite
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
    -- HOW LONG A KNOWINGLY STALE ANSWER IS HELD IN MEMORY. Seconds, not minutes:
    -- it only has to outlive the redraws immediately in front of it while the
    -- refresh it just triggered finishes. See cached_fetch's revalidate branch,
    -- which used to re-arm the FULL ttl on the copy it had that instant decided
    -- was out of date.
    ttl_stale = 20,
    ttl_lyrics = 7 * 24 * 3600,  -- 1 week
    spotify   = "d420a117a32841c2b3474932e49fb54b"
}
-- Named rather than folded into P.cache below because spotifyd's own default
-- cache path is a sibling of ours under the same base, and ensure_cache migrates
-- it from there exactly once -- deriving both from this is what keeps that move
-- from being a spelled-out path.
P.xdg_cache  = os.getenv("XDG_CACHE_HOME") or P.home .. "/.cache"
P.cache      = P.xdg_cache .. "/spoot"

-- RUNTIME STATE -- locks, pidfiles, logs, spools. Under a directory of this
-- build's own rather than loose in $TMPDIR under `spoot_` names, for two
-- reasons.
--
-- The first is ownership. These are the files that answer "which process is in
-- charge of this", and answering it is done by reading a pidfile and SIGTERMing
-- whatever is in it. The rofi build reads and writes the same names, so the two
-- killed each other's daemon in turn: whichever started second took the lock and
-- shot the other's, and the loser's MPRIS listener -- the thing that makes track
-- notifications free -- was simply gone. The CACHES stay shared on purpose (same
-- account, same artwork, and starting warm is the entire point); nothing that
-- means "mine" can be.
--
-- The second is that each of these names used to be spelled out at every site
-- that touched it, up to six times each, which is how two of them could have
-- drifted apart without anything noticing.
P.run           = P.tmp .. "/spoot"
P.daemon_pid    = P.run .. "/daemon.pid"
-- The device login helper: `spotifyd authenticate` runs in the background while
-- we watch its output for the URL to open. Both live in the run directory
-- because they belong to one login, not to the machine.
P.device_pid    = P.run .. "/device_auth.pid"
P.device_log    = P.run .. "/device_auth.log"
P.daemon_lock   = P.run .. "/daemon.lock"
P.daemon_log    = P.run .. "/daemon.log"
P.instance_lock = P.run .. "/instance.lock"
P.recent_pid    = P.run .. "/recent.pid"
P.recent_log    = P.run .. "/recent-watch.log"
P.prefetch_pid  = P.run .. "/art-prefetch.pid"
P.plindex_pid   = P.run .. "/plindex.pid"
P.art_spool     = P.run .. "/art-spool"
P.rate_cooldown = P.run .. "/rate-cooldown"
P.last_notify   = P.run .. "/last-notify"
P.oauth_code    = P.run .. "/oauth-code"
P.oauth_pid     = P.run .. "/oauth.pid"
P.crash_log     = P.run .. "/crash.log"
-- Prefixes: the caller appends the name of the revalidator or the warm job, so
-- one pidfile exists per kind rather than one for all of them.
P.reval_pid     = P.run .. "/reval-"
P.warm_pid      = P.run .. "/warm-"
P.mass       = P.cache .. "/mass"
P.lyrics     = P.cache .. "/lyrics"
P.token      = P.cache .. "/token.json"
P.liked      = P.cache .. "/liked_tracks.json"
P.albums     = P.cache .. "/saved_albums.json"
P.artists    = P.cache .. "/followed_artists.json"
-- Your own playlists. Named here rather than spelled out at each of its two uses
-- (the loader and the bust), which is how the two could have drifted.
P.my_playlists = P.cache .. "/my_playlists.json"
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
-- EVERYTHING THE LISTENER HAS EVER IDENTIFIED. A recognition is a small piece of
-- work with a real cost -- thirty seconds of held microphone -- and until now its
-- result lived exactly as long as the card that showed it. Kept newest-first and
-- capped, the way the search history is.
P.listen_hist    = P.cache .. "/listen_history.json"
P.listen_hist_max = 60
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
-- WHERE THE UI IS, as a hop list (see Util.serve_nav). session.json records the
-- engine's own stack; this records the trail you can still walk, which is a
-- different thing and outlives a restart.
P.nav        = P.cache .. "/nav.json"
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
-- Everything the interface lets you change about itself, in one table. Not a
-- file per setting the way volume and bitrate are: those two predate the idea
-- and are read by spotifyd's launch line rather than by the UI, where these are
-- eight answers to one question and are always read together.
P.ui         = P.cache .. "/ui.json"
-- spotifyd's cache, holding BOTH its credentials (oauth/, zeroconf/) and the
-- cached audio -- 256 two-hex-char directories of whole tracks, 15 GB of them on
-- this account. It used to sit at librespot's default, P.spotifyd_old, which is
-- why ensure_cache moves it here once: one cache tree, so `du -sh` on P.cache
-- answers for all of spoot's disk rather than most of it.
-- NOTE: deliberately absent from the mkdir in ensure_cache -- creating it would
-- make the migration guard read "already moved". spotifyd creates it itself.
P.spotifyd     = P.cache .. "/spotifyd"
P.spotifyd_old = P.xdg_cache .. "/spotifyd"
-- Whether spotifyd caches audio at all. One line, same shape as P.bitrate, and
-- read at spawn time for the same reason: it is a launch flag, not something
-- that can be changed under a running daemon.
P.trackcache = P.cache .. "/track_cache"
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
-- `icons`, everyone else says `images`.
--
-- `code` is the rendition the DEFAULT tier fetches, and `tiers` the ones a
-- caller can ask for by name, each with its own directory. Naming the directory
-- and the size code together is the point: the tier decides both, so a file can
-- never end up somewhere that disagrees with what is in it. `full` marks a tier
-- the user ASKED to see, which is what buys it the full retry budget -- every
-- other tier is a decoration and gets Util.ART_DECOR.
--
-- Categories are served at a single 274px size, so they declare neither.
--
-- The `reseed` that turns a code into a url is NOT written here -- see the
-- assignments below Util.art_url_artist for why this table cannot hold one.
P.art_kinds = {
    -- Playlists. 300 for the grid at 150px a tile, 640 for the track list's
    -- 364px backdrop, and 1280 -- the largest there is -- for the full-screen
    -- viewer. See Util.art_url_pl for the codes.
    playlist = {dir = P.art .. "/playlists",  index = P.cache .. "/playlist_art.json",
                field = "images", code = "02",
                tiers = {
                    med = {dir = P.art .. "/playlists/med-res",  code = "03"},
                    hi  = {dir = P.art .. "/playlists/high-res", code = "04", full = true}
                }},
    -- Artists. Id-keyed like playlists because Spotify replaces an artist
    -- picture in place, so a hash-named file would strand the old one on every
    -- change. 320x320 for the grid, which thumbs.rasi draws at 150px, and
    -- 640x640 -- the largest an artist has -- for the Artist Impression viewer.
    -- See Util.art_url_artist for why those two codes and no others.
    artist   = {dir = P.art .. "/artists", index = P.cache .. "/artist_art.json",
                field = "images", code = "5174",
                tiers = {
                    hi = {dir = P.art .. "/artists/high-res", code = "e5eb", full = true}
                }},
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
                field = "images"}
}
-- Art cached in a SUBDIRECTORY of P.art rather than the flat hash pool, keyed by
-- exactly what a caller hands ensure_art as `subdir`. Listed here so
-- ensure_cache creates them in its one mkdir and ensure_art never forks per
-- call -- the same bargain P.art_kinds makes for the id-keyed grids. The bare
-- string used to be written at the call site while the directory it needed was
-- spelled out again inside that mkdir, so the two could drift.
-- All three are album renditions, so they sit together under albums/ -- one
-- parent per KIND, matching playlists/ and artists/, with the sizes below it.
-- The 300px pool used to sit loose in P.art itself, which left the art root
-- holding thousands of hash-named files as well as every kind's directory, and
-- put the small and large copies of the same cover in unrelated places.
P.art_subdirs = {
    -- 300x300, hash-named: the shared pool every album thumbnail grid warms and
    -- every backdrop that is not one of the two below reads. Also holds show and
    -- episode covers, which are hash-keyed for the same reason albums are -- the
    -- directory is named for the kind that fills it, not the only one in it.
    albums = P.art .. "/albums",
    -- 640x640: the size the album view and the track action menu draw into a
    -- 364px box. Apart from the pool above because that one is warmed by the
    -- grids at 150px a tile, and a directory per rendition stays countable and
    -- removable on its own.
    ["albums/med-res"] = P.art .. "/albums/med-res",
    -- The largest rendition, for the full-screen art viewer only (view_art).
    ["albums/high-res"] = P.art .. "/albums/high-res"
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
             mem = "saved_shows",  file = P.shows,  noun = "podcast"}
}
-- Images shipped with spoot: the Main tile icons and the three placeholders a
-- row falls back to when it has no cover of its own. Named once here so the
-- layout is not repeated at each use, same as every other path in this table.
--
-- They lived under style/ until now, which was rofi's directory: it held the
-- .rasi files and these sat in a subdirectory of it. The .rasi files are gone,
-- so style/ held one thing and named nothing.
P.assets     = P.dir .. "/assets"
local SEP = " \u{F01D8} "
-- A ROW THAT DOES SOMETHING ELSE ON SHIFT+RETURN, marked. One glyph, defined
-- here beside SEP because it is punctuation rather than content: a row wearing
-- it is making a promise about a key, and every row that makes that promise has
-- to make it the same way. A local, not a Util field -- Util is not declared
-- until further down, and smoke.sh checks exactly that.
local ALT_MARK = "\u{F0BAB}"
local CACHE_TTL_SHORT = 300
local CACHE_TTL_MED = 3600
local CACHE_TTL_LONG = 86400
local PROGRESS_BAR_W = 20
-- How many album covers a thumbnail grid fetches before it is allowed to draw.
-- The thumbs grid shows 5x3 = 15 at a time, so this is several screens of
-- scroll headroom. An artist discography can run to 1500 albums (Rachmaninoff
-- does), and fetching every cover up front is what made such a list look like a
-- hang -- the rest is handed to a detached prefetch, see Util.album_thumbs.
local THUMB_SYNC = 60
-- A CHARACTER BUDGET FOR THE MESSAGE BAR stood here, with the glyph table that
-- let truncation spend it on the title and put the status icons back after. Both
-- were measured against "the narrowest theme is 700px at 10px per char", which
-- is a fixed-width terminal's arithmetic and rofi's problem: the bar is a Text
-- item with `elide` now, so the front end truncates to the pixels it actually
-- has, on whatever width the user set. Nothing had read either since.
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
    -- The one entry that is not an _stype: no row is ever stamped "video", and
    -- this is here for the search PAGE of that name, which Util.search_page_icon
    -- resolves through the same table by key. Same glyph the badge in
    -- Util.display_show wears, so the filter and the rows it selects are marked
    -- with the same mark.
    video     = "\u{F447} "
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

-- P.run, made real. Here rather than in the P block above because that block is
-- declaration only and this is the first line that can quote a path, and here
-- rather than in ensure_cache because most of the entry points at the bottom of
-- this file never call it: --notify, --daemon and the --prefetch-* helpers are
-- detached one-shots that write a pidfile into this directory and nothing else.
-- daemon_mode claims its lock with a bare `mkdir`, which just fails against a
-- missing parent -- so the daemon would never start, and nothing would say why.
--
-- One fork per process, at the 0.44ms a bare fork costs, against a guarantee
-- that a thirteenth entry point cannot miss. 700 because this holds pidfiles
-- and, for the length of a login, the OAuth code.
os.execute("mkdir -p -m 700 " .. shell_quote(P.run) .. " 2>/dev/null")

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

-- printf '%s', not echo: echo appends a newline, so every URL copied from here
-- landed in the clipboard with a trailing \n. parse_spotify_url strips one on
-- the way back in, but a paste anywhere else carried it. The native branch has
-- no such problem -- it is handed the string.
--
-- ONE THING TO KNOW about the native branch: a Wayland selection belongs to the
-- client that set it, so what spoot copies lives as long as spoot does. wl-copy
-- forks a small process to hold it instead, which outlives us. spoot is resident
-- now, so this only differs if you quit it between copying a link and pasting.
local function copy_to_clipboard(text)
    -- THE GLOBAL, not Util.host. This function is defined above `local Util`,
    -- so the name `Util` here compiles to a global lookup and is nil at call
    -- time -- which turned Copy Web Link into a crash the moment this branch was
    -- added. `spoot` is the table Util.host is itself assigned from, so this is
    -- the same object read the only way that works this far up the file.
    local host = rawget(_G, "spoot")
    if host and host.clip then
        host.clip("set", text)
        return
    end
    os.execute("printf '%s' " .. shell_quote(text) .. " | wl-copy 2>/dev/null")
end

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

-- An item's page on the web. One spelling of that URL, shared by the row that
-- COPIES it and the row that OPENS it -- they were one function until the second
-- reader existed, and they must not become two strings now.
--
-- Down here rather than beside copy_to_clipboard, where copy_spotify_url used to
-- live: `Util` is not declared until this line, so naming it any earlier
-- compiles as a global read and answers nil at call time. The 200-local ceiling
-- is why the helper cannot simply be a file local instead.
function Util.web_url(kind, id)
    return "https://open.spotify.com/" .. kind .. "/" .. (id or "")
end

-- Backgrounded, like the OAuth open it mirrors: a cold browser start takes
-- seconds and the menu must not sit there waiting for it.
function Util.open_in_spotify(kind, id)
    os.execute("xdg-open " .. shell_quote(Util.web_url(kind, id)) .. " 2>/dev/null &")
end

-- "Spotify says this show carries video", asked in one place. media_type is
-- "audio" or "mixed" and there is no per-EPISODE flag anywhere in the API, so
-- every video decision in the app is this one comparison: the badge on a row,
-- the wording of the Watch action, and the search page that selects for it.
--
-- Nil-tolerant because two of those callers ask about an episode's `show`, which
-- an episode from search results does not carry.
function Util.is_video_show(show)
    return show ~= nil and show.media_type == "mixed"
end

-- What that row can honestly promise. Only a show's media_type says anything
-- about video, so anything not KNOWN to be "mixed" -- including every episode
-- that reached its menu without its show attached -- gets the neutral word.
function Util.watch_label(is_video)
    return is_video and "Watch in Spotify" or "Open in Spotify"
end

local function copy_spotify_url(kind, id) copy_to_clipboard(Util.web_url(kind, id)) end

-- The one reader of ICON_PREFIX. Answers "" rather than nil so every caller can
-- concatenate unguarded.
function Util.type_icon(stype)
    return ICON_PREFIX[stype or ""] or ""
end

-- Util.grid_args and the THUMB_COLS/ROWS/THREADS it read lived here: 47 lines
-- that built rofi's `-l` and `-threads` arguments, the second of them a careful
-- mitigation for a bug in rofi's icon fetcher (a failed icon load set query_done
-- without clearing query_started, so a tile that failed once stayed blank for
-- the life of the window). It was measured, it was real, and it has nothing to
-- mitigate now -- QML's Image reloads when its source changes and retries on its
-- own, which is why the blank-tile bug is not a thing this build has. Nothing
-- had called grid_args since rofi stopped being spawned.

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
-- ONE REQUEST, DESCRIBED RATHER THAN SPELLED OUT.
--
-- Six sites used to hand-build a curl command line. A request now says what it
-- wants and this decides how it travels: natively through the host when the
-- engine is embedded in the binary, and through curl when the script is run
-- standalone -- which both engine guards and the `printf | lua ... --serve`
-- probe do, so that path is not legacy, it is the debugging route.
--
-- The curl branch is not a second implementation of anything. It is the ONLY
-- copy of "how to build a curl", where there used to be six.
--
--   req  {method=, url=, headers={...}, body=, timeout=, compressed=}
--   ->   {code=<number>, body=<string>, headers=<string>}
--
-- Headers come back as the raw dump because the one caller that reads them wants
-- Retry-After off a 429 and nothing else; parsing them into a table here would
-- be work done on every request for the benefit of one in a thousand.
-- THE NETWORK IS DOWN, AND FINDING THAT OUT COSTS A TIMEOUT.
--
-- This is the whole of "spoot becomes unresponsive when internet access drops".
-- Every request in the app blocks the engine's worker until it answers or the
-- timeout expires -- 10s for a menu fetch, 15s for a page batch -- and with the
-- link down NONE of them answer. The UI polls playback once a second and each
-- poll that misses its local fast path queues behind whichever request is
-- currently waiting out its ten seconds, so the queue only grows: the panel goes
-- on drawing, and nothing it asks for ever comes back.
--
-- A HALF-OPEN BREAKER. A transport failure -- code 0, which is "no answer at
-- all" and never something a server said -- shuts the gate for NET_DOWN_SECS.
-- While it is shut every request returns that same code AT ONCE, so a view falls
-- back to its cache in microseconds instead of minutes, and the poll stays
-- current because it is never behind anything. When the window expires the next
-- request goes out for real: it either succeeds, which opens the gate, or fails
-- and re-arms it. So an outage costs one timeout every NET_DOWN_SECS rather than
-- one per request, and the moment the link is back the very next request notices.
--
-- Deliberately short. This is not a backoff -- Spotify saying "slow down" is a
-- 429 and has its own cooldown -- it is only a way of not asking the same dead
-- socket a hundred times in a row while the answer cannot change.
local NET_DOWN_SECS = 3
Util.net_down_until = 0

-- The gate and NOTHING ELSE. Saying so is api_get's job, beside the 429 and the
-- 401: ui_say is a local declared several thousand lines below this, so a call
-- from here would be a global lookup and a nil call -- and this runs on every
-- request in the app, including from background jobs that have nobody to tell.
function Util.net_note(code)
    if code and code > 0 then
        Util.net_down_until = 0
        Util.net_said = false
        return
    end
    Util.net_down_until = os.time() + NET_DOWN_SECS
end

-- Is the gate shut right now? Read by Util.http and Util.curl_batch, which are
-- the only two ways out of this process.
function Util.net_down()
    return os.time() < (Util.net_down_until or 0)
end

-- IS SPOTIFY STILL SAYING "LATER"? Seconds remaining, or 0.
--
-- A 429 wrote this file and NOTHING READ IT before sending. So a rate limit ran
-- like this: a request comes back 429, a cooldown is written, and the very next
-- request goes out anyway -- into the same closed window, earning the same 429,
-- writing the same cooldown. Every poll, every revalidation, every shelf warm,
-- for as long as the limit lasted. That is the notification arriving over and
-- over: not one rate limit being reported repeatedly, but spoot walking into the
-- same wall a few times a second and being told each time.
--
-- The gate is the fix, and it is the same shape as Util.net_down above: while it
-- is shut a read costs nothing and answers from cache, and the first request
-- after it opens either succeeds or re-arms it. Self-expiring, so a stale file
-- from a previous run cannot lock the app out.
function Util.rate_cool()
    local n = tonumber((read_file(P.rate_cooldown) or ""):match("%d+"))
    if not n then return 0 end
    local left = n - os.time()
    if left <= 0 then os.remove(P.rate_cooldown); return 0 end
    return left
end

function Util.http(req)
    -- Nothing goes out while the gate is shut; see NET_DOWN_SECS. `bg` included:
    -- a fire-and-forget write is exactly the kind of thing there is no point
    -- queueing against a dead link, and its caller has already committed to the
    -- new state locally.
    if Util.net_down() then return {code = 0, body = "", headers = ""} end
    -- SPOOT_FORCE_CURL forces the shell path even when embedded. It exists
    -- because it is exactly what was wanted the first time the native transport
    -- misbehaved: Qt decompresses a reply only while it owns Accept-Encoding, and
    -- setting that header by hand quietly handed the caller raw gzip, so every
    -- search came back empty. One env var to fall back and compare is worth more
    -- than the two lines it costs.
    if Util.host and Util.host.http and not os.getenv("SPOOT_FORCE_CURL") then
        local r = Util.host.http(req)
        -- `bg` answers 0 by design -- it waits for nothing -- so it must not be
        -- read as the link being down.
        if not req.bg then Util.net_note(r and r.code) end
        return r
    end
    local hdr = Util.api_hdr_path()
    -- Backgrounded, output discarded, nothing awaited -- the shell's answer to
    -- what `bg` asks for.
    local bg_tail = req.bg and " > /dev/null 2>&1 &" or ""
    local c = {"curl -s --max-time ", tostring(req.timeout or 10)}
    if req.compressed then c[#c+1] = " --compressed" end
    c[#c+1] = " -D " .. shell_quote(hdr) .. " -w '\\n%{http_code}'"
    if req.method and req.method ~= "GET" then c[#c+1] = " -X " .. req.method end
    for _, h in ipairs(req.headers or {}) do c[#c+1] = " -H " .. shell_quote(h) end
    if req.body ~= nil then c[#c+1] = " -d " .. shell_quote(req.body) end
    c[#c+1] = " " .. shell_quote(req.url)
    if req.bg then
        os.execute(table.concat(c) .. bg_tail)
        return {code = 0, body = "", headers = ""}
    end
    local r = shell(table.concat(c)) or ""
    local out = {code = tonumber(r:match("\n(%d+)\n?$")) or 0,
                 body = r:match("^(.-)\n%d+\n?$") or "",
                 headers = read_file(hdr) or ""}
    Util.net_note(out.code)
    return out
end

-- ONE PLACE THAT KNOWS HOW TO TALK TO A PLAYER, the way Util.http is the one
-- place that knows how to make a request. Embedded, this is a D-Bus call on the
-- host's own session-bus connection; outside it -- `lua spoot.lua --serve`, the
-- daemon, any of the CLI entry points -- it is the playerctl fork it always was.
--
-- Every op answers the same shape, {ok = boolean, value = ...}, so no caller has
-- to know which branch it took. `value` is seconds for position, 0..1 for volume,
-- a status string, or the six metadata fields; commands answer with ok alone.
--
-- SPOOT_FORCE_PLAYERCTL=1 pins the fork even when embedded, which is how the
-- two branches get compared when one of them starts lying.
-- On Util rather than a file local: this chunk sits at Lua's 200-local ceiling.
Util.mpris_fmt = "{{title}}\x1f{{artist}}\x1f{{album}}\x1f{{mpris:artUrl}}"
    .. "\x1f{{mpris:trackid}}\x1f{{mpris:length}}"

-- The one reader of Util.mpris_fmt. The daemon's --follow stream emits a line
-- in this format per track change, so it splits them with this too rather than
-- carrying a second copy of the field order.
-- ONE NOTIFICATION, wherever it is raised from. Embedded this is the D-Bus call
-- that notify-send makes after paying for a process to make it; outside, it is
-- notify-send. Three sites raised notifications with three hand-built command
-- lines, which is how one of them ended up as the only one that could carry an
-- icon.
--
-- `urgency` is the spec's: 0 low, 1 normal, 2 critical.
-- WHAT THE DAEMON ON THIS MACHINE CAN DO, asked once.
--
-- Every toast was shaped for a daemon that parses markup, draws action buttons
-- and shows a body. Two of those three are knowable and neither was asked.
function Util.notify_caps()
    if Util._ncaps then return Util._ncaps end
    local c = nil
    if Util.host and Util.host.notify_caps then
        local ok, got = pcall(Util.host.notify_caps)
        if ok and type(got) == "table" then c = got end
    end
    local has = {}
    for _, k in ipairs((c and c.caps) or {}) do has[k] = true end
    -- NO ANSWER IS NOT "NO CAPABILITIES". With no host there is no bus to ask on
    -- and notify-send is the transport; assume what that path has always assumed
    -- rather than degrading a working setup on the strength of silence.
    if not next(has) then
        has.body = true; has["body-markup"] = true; has.actions = true
    end
    Util._ncaps = {has = has, server = (c and c.server) or ""}
    return Util._ncaps
end

-- HOW THIS DAEMON WANTS A LINE BREAK.
--
-- A newline is what the spec says a body carries, and dunst, mako and swaync all
-- honour it. A daemon that renders the body as Qt or HTML rich text collapses it
-- into a space instead -- HTML does that to a literal newline -- so anything the
-- sender put on its own row runs into the end of the line above it.
--
-- NO TABLE OF GUESSES. There is no capability that tells Pango from HTML, and no
-- honest way to derive it: naming daemons here would be asserting things about
-- programs this has never seen, and guessing wrong sends five literal characters
-- to a daemon that was already right. So the spec's answer is the default and
-- there is a way out for the one who finds otherwise. SPOOT_NOTIFY_BR=1.
function Util.notify_break()
    if trim(os.getenv("SPOOT_NOTIFY_BR") or "") == "1" then return "<br/>" end
    return "\n"
end

function Util.notify(o)
    if Util.host and Util.host.notify then
        if Util.host.notify(o) then return true end
    end
    if not Util.have("notify-send") then return false end
    local c = {"notify-send --app-name=spoot"}
    if o.urgency == 2 then c[#c+1] = " -u critical" end
    if o.icon and #o.icon > 0 then c[#c+1] = " --icon=" .. shell_quote(o.icon) end
    -- NO ACTIONS ON THIS PATH, and it was a mistake to try. `notify-send -A` does
    -- not merely declare an action: it BLOCKS until one is pressed or the toast
    -- closes, then prints the key on stdout. Backgrounded to keep from hanging the
    -- caller, that is a process per notification sitting there for the life of the
    -- toast with nobody reading the pipe -- so the press could never be dispatched
    -- either. Buttons that do nothing, bought with a leak.
    --
    -- The host path is the one that can answer a press (see ToastActions in
    -- src/main.cpp, which listens for ActionInvoked on the bus), and it is the
    -- path spoot actually runs on. This is the fallback for having no host at all.
    c[#c+1] = " " .. shell_quote(o.title or "")
    c[#c+1] = " " .. shell_quote(o.body or "")
    os.execute(table.concat(c) .. " 2>/dev/null")
    return true
end

-- A WAIT. `sleep N` is two forks -- a shell and the sleep it runs -- and the
-- always-on loops below do it twice a minute between them. Natively it is a
-- timer, and one that keeps the bus dispatching underneath, which matters
-- because the daemon is listening while it waits.
function Util.wait(secs)
    if Util.host and Util.host.sleep then
        Util.host.sleep(secs)
        return
    end
    os.execute("sleep " .. tostring(secs))
end

function Util.mpris_split(line)
    if not line then return nil end
    local title, artist, album, art, tid, len = trim(line):match(
        "^([^\x1f]*)\x1f([^\x1f]*)\x1f([^\x1f]*)\x1f([^\x1f]*)\x1f([^\x1f]*)\x1f([^\x1f]*)$")
    if not title then return nil end
    return {title = title, artist = artist, album = album,
            art = art, trackid = tid, length = tonumber(len) or 0}
end

function Util.mpris(req)
    if Util.host and Util.host.mpris and not os.getenv("SPOOT_FORCE_PLAYERCTL") then
        return Util.host.mpris(req)
    end
    local pc = "playerctl" .. (req.player and (" -p " .. req.player) or "")
    local op, v = req.op, req.value
    local function run(args)
        return trim(shell(pc .. " " .. args .. " 2>/dev/null") or "")
    end
    local function did(args)
        local r = os.execute(pc .. " " .. args .. " 2>/dev/null")
        return {ok = r == true or r == 0}
    end
    if op == "status" then
        return {ok = true, value = run("status")}
    elseif op == "position" then
        return {ok = true, value = tonumber(run("position")) or 0}
    elseif op == "volume" then
        return {ok = true, value = tonumber(run("volume"))}
    elseif op == "metadata" then
        local m = Util.mpris_split(run("metadata -f " .. shell_quote(Util.mpris_fmt)))
        if not m then return {ok = false} end
        return {ok = true, value = m}
    elseif op == "setvol" then
        return did("volume " .. string.format("%.2f", v))
    elseif op == "setpos" then
        return did("position " .. string.format("%.2f", v))
    elseif op == "seek" then
        -- playerctl spells a relative seek "10+" / "10-" rather than with a sign.
        return did("position " .. string.format("%.2f", math.abs(v)) .. (v < 0 and "-" or "+"))
    end
    return did(op)
end

function Util.api_write(verb, url, token, opts)
    opts = opts or {}
    local headers = {"Authorization: Bearer " .. token}
    local body
    if opts.body ~= nil then
        body = type(opts.body) == "string" and opts.body or json.encode(opts.body)
        headers[#headers+1] = "Content-Type: application/json"
    elseif opts.len0 then
        headers[#headers+1] = "Content-Length: 0"
    end
    local r = Util.http{method = verb, url = url, headers = headers, body = body,
                        timeout = opts.timeout or 5}
    -- The contract callers have always had: the status as a STRING for
    -- Util.is2xx, or the body itself when the caller asked for it raw.
    return opts.raw and r.body or tostring(r.code)
end

-- Fire-and-forget variant: backgrounded by the shell, output discarded, no
-- wait. Used where the UI has already committed to the new state locally and
-- the round trip must not cost a frame (shuffle/repeat toggles).
function Util.api_write_bg(verb, url, token, opts)
    opts = opts or {}
    local headers = {"Authorization: Bearer " .. token}
    if opts.len0 then headers[#headers+1] = "Content-Length: 0" end
    -- `bg` is honoured natively (issue it, wait for nothing) and by the curl
    -- branch, which backgrounds the process the way this always did.
    Util.http{method = verb, url = url, headers = headers,
              timeout = opts.timeout or 5, bg = true}
end

-- Every background self-spawn (--daemon, --recent-watch, --prefetch-*,
-- --notify, --revalidate, --warm-shelf): 10 hand-built sites. args are
-- quoted individually so a title with a
-- quote cannot break out; the flags gain quotes the shell strips right back off.
-- pidf records the child's pid -- `echo $!` must run in the same shell as the
-- spawn, which is why this builds a command string rather than using os.execute.
-- A BACKGROUND JOB. Embedded this is a disposable Lua state on a pool thread --
-- the same script, the same entry point, the same isolation as the fork, minus
-- the fork -- and the pid file's job is done by an in-flight key instead. The
-- `log` is dropped on that path: a job's output already goes to spoot's own.
--
-- Outside the host it is the nohup it always was, which is what --daemon and
-- --recent-watch still take when spoot itself is not running.
function Util.spawn_self(args, log, pidf)
    if Util.host and Util.host.job then
        Util.host.job(args, pidf or "")
        return
    end
    -- THE BINARY IF WE ARE IN ONE. `spoot --revalidate liked` is the same entry
    -- point `lua spoot.lua --revalidate liked` is, so a fork of ourselves can be
    -- a fork of ourselves rather than of an interpreter that has to find and
    -- parse the script again.
    local exe = Util.host and Util.host.exe
    local c = exe and {"nohup ", shell_quote(exe)}
                  or  {"nohup lua ", shell_quote(P.dir .. "/spoot.lua")}
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
-- IS THIS JOB ALREADY RUNNING. Both answers matter: the host's in-flight set
-- covers the jobs it is running itself, and the pid file still covers one left
-- over from a standalone spoot -- an art prefetch from a `spoot --revalidate`
-- in a terminal, say -- which would otherwise be duplicated.
function Util.job_running(pidf, marker)
    if Util.host and Util.host.job_busy and Util.host.job_busy(pidf) then return true end
    return Util.pidfile_owner_alive(pidf, marker)
end

function Util.pidfile_owner_alive(path, marker)
    local pid = trim(read_file(path) or "")
    if not Util.proc_alive(pid) then return false end
    local cmd = Util.proc_cmdline(pid)
    return cmd:find("spoot", 1, true) ~= nil
        and (not marker or cmd:find(marker, 1, true) ~= nil)
end

function Util.get_clipboard()
    if Util.host and Util.host.clip then return trim(Util.host.clip("get") or "") end
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

-- THEMES ARE NAMES NOW, not files.
--
-- This was 60 lines that read each style/*.rasi, rewrote its `@import "ZENON"`
-- to an absolute path, and wrote the result to /tmp so rofi could find it. No
-- rofi runs here: the Qt front end asks the engine which theme a view uses and
-- looks the geometry up in ui/Theme.qml, where ZENON has been transcribed. So a
-- theme only has to be NAMED, and naming it is the whole job.
--
-- The names are unchanged and still authoritative -- they are what every view
-- already passes to ui_menu, and what the UI keys its geometry table on -- so
-- nothing above this line had to change. What goes with the files is the /tmp
-- copying, the sweep that cleaned it up, and the last reason to keep 19 .rasi
-- files in a project that no longer reads them.
-- THEME_MSG, THEME_BINDS and THEME_LISTEN stood here and were read by nothing:
-- the keybind sheet names "binds" on its event directly and the listener names
-- no theme at all. THEME_ALBUM and THEME_ACTION are the other half of the same
-- tidy -- both were being produced as the first argument to write_art_theme,
-- which handed the string straight back, so the one menu in the app that was
-- about a track wore a theme name that came out of a function about artwork.
local THEME_MENU, THEME_LYR, THEME_SUB, THEME_META, THEME_ART, THEME_ALBUM,
      THEME_ACTION, THEME_IMP =
      "menu", "lyrics", "sub", "meta", "art", "album", "action", "imp"
P.THEME_SEARCH     = "search"
Util.THEME_RESULTS = "searchall"   -- the results LIST; search.rasi is its input box
Util.THEME_THUMBS  = "thumbs"
Util.THEME_TRAIL   = "trail"       -- Trail Steps and Trail History share one
Util.THEME_PODS    = "pods"        -- wider than meta: descriptions run to sentences
Util.THEME_MAIN    = "main"        -- the root grid, so it can be styled apart

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
        .. " " .. shell_quote(P.art) .. Util.art_dirs()
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
    -- And spotifyd's cache, moved under ours ONCE. Both paths are under the same
    -- base (P.xdg_cache), so this is a rename and not a copy however many
    -- gigabytes of cached audio are in there -- 15 GB at the time of the move.
    -- Moved rather than started fresh so oauth/ and zeroconf/ come with it and
    -- the device needs no re-pairing.
    --
    -- Two tests and no fork of its own, riding the shell above. The guard is the
    -- whole migration: once the destination exists this is a no-op forever, and
    -- it must stay that way -- see the NOTE on P.spotifyd about why that path is
    -- absent from the mkdir.
    --
    -- A spotifyd that was already running when this fires still holds the old
    -- path as a string and will recreate a stub there for whatever it writes
    -- next; the first restart after this launches with -c and nothing writes to
    -- it again.
    os.execute("{ rm -rf " .. shell_quote(P.art .. "/curations") .. " "
        .. shell_quote(P.cache .. "/curation_art.json") .. ";"
        .. " rm -f " .. shell_quote(P.cache) .. "/.api_hdr.*;"
        .. " [ -d " .. shell_quote(P.spotifyd_old) .. " ] && [ ! -d " .. shell_quote(P.spotifyd) .. " ]"
        .. " && mv " .. shell_quote(P.spotifyd_old) .. " " .. shell_quote(P.spotifyd) .. "; } 2>/dev/null")

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
--     a single process holds open at once (ui_menu keeps two).
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

-- ============================================================================
-- UI SETTINGS
-- ============================================================================
--
-- ONE DESCRIPTION OF EACH SETTING: what it is called, what it defaults to, and
-- what it is allowed to be. The menu builds its rows from this and ui_set
-- validates against this, so the values on offer and the values accepted are the
-- same list by construction -- the failure this shape exists to prevent is a
-- picker that offers 16 rows while the clamp still stops at 14.
--
-- The UI holds none of these numbers: they are sent to it (see the `settings`
-- event) and Theme.geom applies them. Deleting ui.json restores every default,
-- which is the test that the defaults here match the constants they replaced.
Util.UI_SETTINGS = {
    {key = "replay", default = true, kind = "bool", label = "Session Replay",
     why = "reopen the menu you were in when spoot last closed"},
    -- SOLID BY DEFAULT. It shipped at 80, from the rofi build where the panel
     -- was the whole of what spoot drew; with a backdrop, covers and a floating
     -- card all layered inside it, a translucent ground is the desktop showing
     -- through three things at once. Still adjustable down to 50 for anyone who
     -- wants it.
    {key = "opacity", default = 100, kind = "range", min = 50, max = 100, step = 5,
     label = "Opacity", unit = "%", why = "how solid the panel's ground is"},
    -- THE EDGE, and whether it is there at all. On by default: it is the only
    -- part of spoot you can use without opening spoot, and someone who has never
    -- noticed the hot spot has lost nothing. Off, no dock surface is ever mapped
    -- -- see main.qml's Instantiator, which stops arming them -- so it costs
    -- exactly nothing to have turned off rather than being drawn and hidden.
    {key = "dock", default = true, kind = "bool", label = "Control Panel",
     why = "hover the screen edge spoot opens from for playback controls"},
    {key = "shadows", default = true, kind = "bool", label = "Shadows",
     why = "the drop shadow under the cards that float over a menu"},
    {key = "maxWidth", default = 1000, kind = "range", min = 700, max = 1600,
     step = 100, label = "Maximum Width", unit = "px",
     why = "the widest a menu or a details sheet may get"},
    {key = "listLines", default = 14, kind = "range", min = 8, max = 16, step = 1,
     label = "List Rows", why = "rows visible per page in a list"},
    {key = "gridCols", default = 5, kind = "range", min = 2, max = 10, step = 1,
     label = "Grid Columns", why = "covers across a grid page"},
    {key = "gridRows", default = 3, kind = "range", min = 1, max = 6, step = 1,
     label = "Grid Rows", why = "rows of covers per grid page"},
    {key = "position", default = "bottom-center", kind = "anchor",
     label = "Window Position", why = "which edge or corner spoot opens against"}
}

-- Reading order, so the picker is a 3x3 that looks like where the window will
-- go. The stored value is the key; the label is only ever displayed.
Util.UI_POSITIONS = {
    {key = "top-left",      label = "Top Left"},
    {key = "top-center",    label = "Top"},
    {key = "top-right",     label = "Top Right"},
    {key = "middle-left",   label = "Left"},
    {key = "middle-center", label = "Center"},
    {key = "middle-right",  label = "Right"},
    {key = "bottom-left",   label = "Bottom Left"},
    {key = "bottom-center", label = "Bottom"},
    {key = "bottom-right",  label = "Bottom Right"}
}

function Util.ui_setting(key)
    for _, d in ipairs(Util.UI_SETTINGS) do if d.key == key then return d end end
    return nil
end

-- Defaults with the file merged over them, so a ui.json written by an older
-- spoot -- one that had never heard of a setting added since -- still answers
-- for every key rather than nil where a number should be.
function Util.ui_get()
    if Util._ui then return Util._ui end
    local out = {}
    for _, d in ipairs(Util.UI_SETTINGS) do out[d.key] = d.default end
    local raw = read_file(P.ui)
    if raw then
        local d = safe_decode(raw)
        if type(d) == "table" then
            for _, spec in ipairs(Util.UI_SETTINGS) do
                local v = d[spec.key]
                if v ~= nil then out[spec.key] = Util.ui_clamp(spec, v) end
            end
        end
    end
    Util._ui = out
    return out
end

-- A value is only ever stored after it has been put back inside its own range.
-- Hand-edit ui.json to listLines = 400 and you get 16, not a panel taller than
-- the screen.
function Util.ui_clamp(spec, v)
    if spec.kind == "bool" then return v == true or v == "true" end
    if spec.kind == "anchor" then
        for _, p in ipairs(Util.UI_POSITIONS) do if p.key == v then return v end end
        return spec.default
    end
    local n = tonumber(v)
    if not n then return spec.default end
    n = math.max(spec.min, math.min(spec.max, n))
    -- Onto the step, so a value from anywhere lands on one the picker offers.
    return spec.min + math.floor((n - spec.min) / spec.step + 0.5) * spec.step
end

function Util.ui_set(key, value)
    local spec = Util.ui_setting(key)
    if not spec then return end
    local cur = Util.ui_get()
    cur[key] = Util.ui_clamp(spec, value)
    write_file(P.ui, json.encode(cur))
    Util._ui = cur
    -- SAID IMMEDIATELY, not on the next launch. The UI holds no copy of any of
    -- this and reads no file; it is told, and it rebinds.
    Util.ui_announce()
end

function Util.ui_announce()
    if not Util.serving then return end
    local ev = {ev = "settings"}
    for k, v in pairs(Util.ui_get()) do ev[k] = v end
    Util.serve_write(ev)
end

-- A SETTING'S ROW, and there is one shape for all of them: the name, a space,
-- and the value in bold. Volume, Bitrate and Track Cache each spelled this out
-- in System's own items list; UI Settings did something else entirely, joining
-- with SEP -- the glyph that separates a track from its artist -- so the one
-- menu that is nothing but settings was the one that did not read like the rest.
function Util.setting_row(label, value)
    return label .. " " .. Util.markup("<b>") .. tostring(value) .. Util.markup("</b>")
end

-- What a setting reads as on its row in the menu, and in its picker's caption.
function Util.ui_show(spec, v)
    if spec.kind == "bool" then return v and "On" or "Off" end
    if spec.kind == "anchor" then
        for _, p in ipairs(Util.UI_POSITIONS) do
            if p.key == v then return p.label end
        end
        return tostring(v)
    end
    return tostring(v) .. (spec.unit or "")
end

-- Whether spotifyd caches the audio it streams. Defaults to ON when the file is
-- absent, which is librespot's own default -- so a spoot that has never been
-- told otherwise behaves exactly as it did before this setting existed.
--
-- On Util rather than beside save_bitrate as a file local: the chunk body is at
-- Lua's 200-local ceiling (see the note above Util's declaration).
function Util.track_cache_on()
    local raw = read_file(P.trackcache)
    return trim(raw or "") ~= "0"
end
function Util.save_track_cache(on)
    write_file(P.trackcache, on and "1" or "0")
end
-- The state's NAME, in one place. Five things say it -- the System row, the two
-- picker rows, that picker's mesg and the restart confirm -- and they have to
-- agree, or the row you flipped and the row reporting it read as two settings.
function Util.track_cache_label(on)
    return on and "Enabled" or "Disabled"
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
    -- Forgetting a query forgets which slice of it you were looking at. Without
    -- this the map would outlive every entry that could reach it.
    local pm = all[P.hist_page_key]
    if type(pm) == "table" then
        pm[q] = nil
        if next(pm) == nil then all[P.hist_page_key] = nil end
    end
    disk_set(P.search_hist, all)
    return true
end

-- Which results page each query was last left on, keyed by the query itself.
--
-- A SIBLING of the history list rather than something stored inside it:
-- Util.hist_get's return value IS the row array rofi draws, so its entries have
-- to stay bare strings. It rides in the same file because it is the same fact --
-- what you did with a query last time -- and because removing a query from the
-- history is then the one place that has to forget its page too.
--
-- This used to be a single view_pos entry shared by every search, so the page
-- you left one query on was the page the NEXT one opened on. Per query, a query
-- with no record is a query never filtered, which is what makes All the default
-- for anything new without a special case for it.
P.hist_page_key = "search-page"

function Util.hist_page_get(q)
    if type(q) ~= "string" then return nil end
    local m = Util.hist_all()[P.hist_page_key]
    return type(m) == "table" and m[q] or nil
end

function Util.hist_page_put(q, page)
    if type(q) ~= "string" or q == "" then return end
    local all = Util.hist_all()
    local m = type(all[P.hist_page_key]) == "table" and all[P.hist_page_key] or {}
    -- "all" is the default a missing entry already means, so recording it would
    -- only grow the file with rows that say nothing.
    if page == nil or page == "all" then m[q] = nil else m[q] = page end
    if next(m) == nil then all[P.hist_page_key] = nil else all[P.hist_page_key] = m end
    disk_set(P.search_hist, all)
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

-- `item` is the playlist that changed and `add` whether it is now in the list,
-- when the caller has the object: the shelf is then AMENDED rather than deleted,
-- so the Playlists tile can still read a head and repaint. See Util.shelf_splice
-- for why deleting it was what left that tile wearing stale artwork.
--
-- Called bare from do_save_playlist, which holds only an id -- there is no object
-- to splice there, so it takes the bust below exactly as every caller used to.
local function bust_my_playlists(item, add)
    -- Spotify's own ordering, so no sort: a spliced playlist lands at the end
    -- until the next fetch puts it where the API says.
    if item and Util.shelf_splice("my_playlists", P.my_playlists, item, add,
                                  {ttl = CACHE_TTL_SHORT}) then return end
    mem_bust("my_playlists")
    os.remove(P.my_playlists)
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
-- A BACKGROUND REFRESH THAT LANDS ON THE OPEN THAT PAID FOR IT.
--
-- The revalidate branch below hands back a copy it knows is old and spawns a
-- detached process to fetch the truth. That process writes the fresh list to
-- disk a second or two later -- and the engine that asked for it went on serving
-- what it had, so the answer showed up the NEXT time you opened the shelf. The
-- twenty-second lease made "next time" sooner than it had been (it used to be
-- the next cold start) without making it THIS time.
--
-- Two halves, and neither of them waits on anything. This is the ledger: every
-- key served stale is remembered with what it would take to read a fresh copy.
Util.reval_watch = {}
local function reval_watch(key, disk_path, ttl, tag)
    if not disk_path then return end
    Util.reval_watch[key] = {path = disk_path, ttl = ttl, tag = tag}
end
-- ...and this is the pickup, swept once per request -- the only moment anything
-- could act on the result anyway. disk_get with the REAL ttl is the whole test:
-- it fails while the file is still the copy we judged out of date, and succeeds
-- the moment the revalidator has replaced it. No pid file to poll, no process to
-- wait on, and nothing to do when the refresh failed or has not finished --
-- the entry simply stays on the ledger until the next request tries again.
function Util.reval_sweep()
    for key, w in pairs(Util.reval_watch) do
        local fresh = disk_get(w.path, w.ttl, w.tag)
        if fresh ~= nil then
            mem_set(key, fresh, w.ttl)
            Util.reval_watch[key] = nil
        end
    end
end

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
    if v ~= nil then
        -- STILL WAITING, and the draw has to be told. The lease taken below
        -- hands this copy back without touching the disk -- which is what keeps
        -- the redraws in front of a refresh cheap, and also what hides the fact
        -- that a refresh is in flight. Said here as well as at the branch that
        -- starts one, or the SECOND draw of a stale shelf would look settled and
        -- nothing would ask again.
        if Util.reval_watch[key] then Util.draw_stale = true end
        return v
    end
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
                -- A SHORT LEASE ON AN ANSWER WE KNOW IS OLD. This used to re-arm
                -- the full fifteen minutes on the very copy it had just judged
                -- out of date -- so the refresh spawned on the next line could
                -- not reach the process that asked for it. The child wrote the
                -- fresh list to disk in a second or two and the running engine
                -- went on serving the stale one from memory until its lease ran
                -- out, which is why a like made on your phone showed up on the
                -- next COLD START rather than the next time you opened the shelf.
                --
                -- Twenty seconds is enough to keep the redraws in front of it off
                -- the disk, and short enough that the refresh lands in the
                -- session that paid for it.
                mem_set(key, v, P.ttl_stale)
                Util.spawn_revalidate(opts.revalidate, opts.revalidate_arg)
                -- ...and the draw says so, so the UI asks once more in a moment
                -- rather than the shelf being right only the next time you open
                -- it. See Util.reval_sweep, which is what makes the second ask
                -- read the file the first one spawned.
                reval_watch(key, disk_path, ttl, opts.tag)
                Util.draw_stale = true
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

-- WHAT THE USER IS TOLD, as opposed to what the log is given. Util.traceback
-- staples a full stack onto every error so a crash can be read afterwards, and
-- the UI puts whatever comes back straight into the message bar -- so a nil
-- concatenation three views deep arrived as twenty lines of Lua file paths
-- across the middle of the screen. The first line IS the error; the file that
-- raised it and the chain that got there are for the log.
function Util.err_brief(e)
    e = tostring(e)
    local first = e:match("^[^\n]*") or e
    -- "/path/to/spoot.lua:8569: attempt to concatenate ..." -- the location is
    -- noise in a bar over the music, and the log copy still carries it.
    return (first:gsub("^.-%.lua:%d+:%s*", ""))
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
    -- The seed string exactly as the picker listed it and as open_genre_tracks
    -- captions the results ("tango", "black-metal"). Named `genre` and not
    -- `genre_name` because that is the field Util.stack_prefix already compares
    -- to tell two genre shelves apart -- it was in the entry the whole time,
    -- just never read here, so every genre shelf rendered as a bare "Genre".
    if entry.genre and entry.genre ~= "" then return entry.genre end
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
--
-- THE naming rule, and the only copy of it: the breadcrumb, the Trail Steps menu
-- and the closed-menus list all name a step through here, so none of them can
-- drift into showing a step the others do not. It returns the qualifier rather
-- than joining it because each of those draws its arrow differently -- parts
-- become separate crumb steps, a Trail Steps row is one string.
--
-- A `qualify` view's own name is the PARENT it belongs to, not itself: all four
-- artist sub-views carry the same artist_name, so "Bad Bunny" named the albums,
-- the top tracks, the liked tracks and the related artists alike. Those render
-- "<name> > <label>" and are told apart again.
function Util.step_name(entry)
    local v = VIEWS[entry.view]
    local name = not (v and v.label_only) and crumb_name(entry) or nil
    if name and v and v.qualify then return name, view_label(entry.view) end
    return name or view_label(entry.view), nil
end

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
                local name, qual = Util.step_name(e)
                parts[#parts+1] = name
                -- A separate part, not "name > qual": the breadcrumb then styles
                -- the arrow between them like every other one, and nothing ever
                -- writes a markup sentinel into trails.json.
                if qual then parts[#parts+1] = qual end
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
    -- Archived trails are rebuilt from their saved STACK, not from any saved
    -- label string. Trails written by older versions carry one, joined with a
    -- plain " > ", and rendering that verbatim left every previous trail with
    -- unstyled arrows while the live crumb beside it had styled ones.
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
    local live = Util.breadcrumb_parts()
    -- Util.parts_from_stack always seeds "Main", so #live == 1 IS the empty
    -- stack: you are at the root with nothing pushed. With nothing archived
    -- beside it the whole line would be that one word, naming the menu already
    -- filling the screen -- the app's own name says more. One live step or one
    -- archived trail and "Main" is the head of a path again, which is why this
    -- lives here and not in parts_from_stack: the Trail Steps rows, the
    -- closed-menus list and an archived trail's own head all still want the root
    -- called Main.
    if #parts == 0 and #live == 1 then return "spoot" end
    parts[#parts+1] = table.concat(live, Util.crumb_arrow(" > "))
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
local display_track, ui_say
local toggle_repeat, toggle_shuffle
local open_url
local queue_tracks, queue_idx, queue_context
local recover_playback
local format_entries
local api_get_playlist_tracks

-- status_mesg lived here: the coloured shuffle and repeat glyphs, folded into
-- Main's caption by hand. Its only caller was that caption, and the pair is now
-- drawn in the now-playing strip instead -- where it is true on every view
-- rather than only on the one screen rofi could fit it on. The glyphs and all
-- three of their colours are transcribed verbatim into Theme.qml.

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

-- ROFI IS GONE. This was 405 lines of driving a rofi process: writing entries to
-- a temp file, exec'ing it with a theme, decoding its exit code into keybinds,
-- and the menu_redo loop that re-entered a menu after a hotkey. Util.serve_mode
-- replaces this function at startup with a recorder, so none of it can run.
--
-- The signature survives because the replacement ASSIGNS to this local -- every
-- view closed over it long before serve mode starts. Reaching this body means
-- something called a menu before the engine was ready, which is a bug worth
-- hearing about rather than a window worth opening.
local function ui_menu(entries, opts)
    error("ui_menu called before serve mode replaced it", 2)
end

ui_say = function(msg, theme)
    -- Replaced by Util.serve_mode with an event. What stood here spawned
    -- `rofi -e` to draw a message box.
    error("ui_say called before serve mode replaced it", 2)
end

-- A LINK WAS COPIED. Eight action menus do this and all eight used to spell out
-- the same sentence for rofi to draw, because a sentence was the only thing rofi
-- could be handed. The UI marks the row you picked instead, and it can only do
-- that if this arrives as a THING -- one event with a name -- rather than as
-- prose it would have to recognise by matching on the wording.
--
-- The message stays as the fallback for anything not being served, so the
-- meaning never depends on which front end is listening.
function Util.copied_link()
    if Util.serving then Util.serve_write({ev = "copied"}) return end
    ui_say("Copied web link")
end

-- ASKING FOR TEXT, and the answer may not exist yet.
--
-- nil means NOT ANSWERED: the field has only just been put on screen and this
-- pass of the view is over -- exactly what a nil from ui_menu means, and every
-- caller must stop on it. "" means answered with nothing, which is also a stop.
-- So the test is `if not x or x == "" then`, and it has to be that way round.
--
-- Worth spelling out because all three callers had it wrong, and wrong in the
-- way that WRITES: rofi's input box could only ever answer with a string, so ""
-- was cancel and `x ~= ""` was a complete test. Under Qt the first pass answers
-- nil, `nil ~= ""` is true, and each of them went on to send its request --
-- creating a nameless playlist the moment the field appeared, and renaming one
-- to nothing. See view_playlists, view_add_pl and Util.open_playlist_actions.
local function ui_ask(prompt, preset, theme)
    -- Replaced by Util.serve_mode with a prompt event answered from the path.
    -- What stood here spawned a rofi input box and read its stdout.
    error("ui_ask called before serve mode replaced it", 2)
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
            -- Declared out here so the failure branch below can read it: whether
            -- Spotify ANSWERED, and what it said, is the whole difference between
            -- a revoked credential and an unreachable one.
            local rd = nil
            if data.refresh_token and type(data.refresh_token) == "string" then
                -- Form-encoded, which is what curl's repeated -d built for us.
                rd = safe_decode(Util.http{
                    method = "POST",
                    url = "https://accounts.spotify.com/api/token",
                    headers = {"Content-Type: application/x-www-form-urlencoded"},
                    body = "grant_type=refresh_token&refresh_token=" .. data.refresh_token
                           .. "&client_id=" .. P.spotify,
                    compressed = true, timeout = 10}.body)
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
            -- REFUSED IS NOT THE SAME AS UNREACHABLE, and treating them alike is
            -- how killing spoot turned into signing in again.
            --
            -- A killed spoot leaves a token behind that later expires. The next
            -- start finds it expired and refreshes -- and ANY hiccup on that one
            -- request used to delete the credential outright: no network up yet,
            -- DNS still coming, the ten-second curl timeout, Spotify having a
            -- moment. The refresh token is the only credential there is, and it
            -- was being thrown away because a request did not come back.
            --
            -- Spotify says invalid_grant, and nothing else, when a refresh token
            -- is genuinely revoked. That is the one answer worth erasing for.
            -- Everything else is temporary by definition: hand back nothing for
            -- now, leave the credential alone, and let the next attempt have it.
            --
            -- `rd` is the decoded reply; nil means the request never produced
            -- one. A token file with no refresh_token in it at all is dead by
            -- construction and there is nothing temporary about that, so it goes
            -- too -- that is the case the old unconditional remove was written
            -- for, and the only one it was ever right about.
            if (rd and rd.error == "invalid_grant")
               or not (data.refresh_token and type(data.refresh_token) == "string") then
                os.remove(P.token)
            end
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

    -- CATCHING THE REDIRECT. The host does it in process when there is one --
    -- see l_oauth_listen -- and the port is bound HERE, before the browser is
    -- opened, so a fast redirect cannot arrive at a socket that does not exist
    -- yet.
    local native = Util.host and Util.host.oauth_listen
                   and Util.host.oauth_listen(8989) and true or false

    -- ...AND THE PERL ONE-LINER, for a spoot running under a bare interpreter.
    -- It is the original mechanism and it still works: fork an HTTP server into
    -- the background, have it write the code to a file, and poll for that file.
    -- Kept only for the no-host case, which is `lua engine/spoot.lua` -- the
    -- binary reaches the branch above and needs neither perl nor the file.
    --
    -- The output path is passed as an ARGUMENT and read back as $ARGV[0], rather
    -- than interpolated into the program text. Interpolating put it inside a Perl
    -- double-quoted string nested inside a shell single-quoted program, where a
    -- $ or @ in the path would be expanded by Perl and a ' would end the shell's
    -- quoting. As an argument it needs no escaping rules beyond shell_quote.
    if not native then
        local srv = "perl -MIO::Socket::INET -e '"
            .. "alarm 120;"
            .. "$s=IO::Socket::INET->new(LocalPort=>8989,Listen=>1,ReuseAddr=>1);"
            .. "$c=$s->accept();$r=<$c>;($x)=$r=~/code=([^&\\s]+)/;"
            .. "if($x){open(F,\">\",$ARGV[0]);print F $x;close(F)}"
            .. "print $c \"HTTP/1.1 200 OK\\r\\n\\r\\nok\";close $c;close $s' "
            .. shell_quote(P.oauth_code)
        os.execute(srv .. " & echo $! > " .. shell_quote(P.oauth_pid))
    end
    os.execute("xdg-open " .. shell_quote(auth_url) .. " 2>/dev/null &")

    local function kill_oauth_server()
        local pid = trim(read_file(P.oauth_pid) or "")
        if pid ~= "" and pid:match("^%d+$") then os.execute("kill " .. pid .. " 2>/dev/null") end
        os.remove(P.oauth_pid)
    end

    -- WAITING FOR THE CODE, one way or the other. Both answer the same thing --
    -- the code, or nil after two minutes -- so everything below this is shared.
    local function await_code()
        if native then return Util.host.oauth_wait(120) end
        local attempts = 0
        while attempts < 120 do
            local code = trim(read_file(P.oauth_code) or "")
            if #code > 0 then os.remove(P.oauth_code); return code end
            attempts = attempts + 1
            Util.wait(1)
        end
        return nil
    end

    local code = await_code()
    if not native then kill_oauth_server(); os.remove(P.oauth_code) end
    if not code or code == "" then
        ui_say("OAuth timed out — no response after 120 seconds")
        return nil
    end

    local d = safe_decode(Util.http{
        method = "POST",
        url = "https://accounts.spotify.com/api/token",
        headers = {"Content-Type: application/x-www-form-urlencoded"},
        body = "grant_type=authorization_code&code=" .. code
               .. "&redirect_uri=http://127.0.0.1:8989/login"
               .. "&client_id=" .. P.spotify
               .. "&code_verifier=" .. verifier,
        compressed = true, timeout = 10}.body)
    if not (d and d.access_token) then return nil end
    write_file(P.token, json.encode({
        access_token = d.access_token,
        refresh_token = d.refresh_token,
        expires_at = os.time() + (d.expires_in or 3600) - 60,
        -- What this token can actually do. d.scope is what Spotify
        -- says it GRANTED, which is the authority; OAUTH_SCOPES is
        -- only what was asked for.
        scopes = d.scope or OAUTH_SCOPES
    }))
    os.execute("chmod 600 " .. shell_quote(P.token) .. " 2>/dev/null")
    return d.access_token
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

-- The rendition of a PLAYLIST cover. The last byte of the prefix is a size code,
-- and there are FOUR, not the two this said before it was swept properly: 01 is
-- 64x64, 02 is 300x300 -- what the API hands back as images[1] -- 03 is 640x640
-- and 04 is 1280x1280. 05 and 06 do not exist, so 04 is as large as a playlist
-- gets. Confirmed against every playlist on this account.
--
-- The old comment claimed 03 was the top, which is why the full-screen viewer
-- spent its life upscaling 640 into a 1000px window.
--
-- Anchored to that exact prefix on purpose, and it matches barely half of what
-- is cached: ab67706c personalised covers (one size only), album-art URLs, and
-- Spotify's `default`/`region_*` placeholders all wear something else. Rewriting
-- a prefix we do not recognise would turn a working cover into a 404, so
-- anything unmatched is returned untouched and stays at the size Spotify gave --
-- which means its tiers hold the same bytes, and that is the correct outcome.
Util.art_url_pl = function(art_url, code)
    if not art_url or #art_url == 0 then return art_url end
    return (art_url:gsub("(i%.scdn%.co/image/ab67706f000000)0[0-9a-fA-F]", "%1" .. code))
end

-- The rendition of an ARTIST picture. Spotify serves exactly three and no more:
-- 0000f178 is 160x160, 00005174 is 320x320 and 0000e5eb is 640x640 -- the last
-- being what the API hands back as images[1]. Confirmed against every followed
-- and top artist on this account, and by probing the CDN with the codes albums
-- use: there is no 2000px artist rendition the way ab67616d000082c1 is one, so
-- 640 is as large as an artist gets.
--
-- Anchored to the artist prefix for the same reason Util.art_url_pl is anchored
-- to the playlist one. About one artist in seven still wears a legacy bare-hash
-- upload at some odd size, or (for a couple) an album cover, and rewriting a
-- prefix we do not recognise would turn a working picture into a 404. Anything
-- unmatched comes back untouched and stays at whatever size Spotify gave.
Util.art_url_artist = function(art_url, code)
    if not art_url or #art_url == 0 then return art_url end
    return (art_url:gsub("(i%.scdn%.co/image/ab6761610000)[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]",
                         "%1" .. code))
end

-- How a kind turns one of its size codes into a url. The codes themselves are
-- data on the kind (see P.art_kinds); this is the one thing about a rendition
-- that has to be a function, because each prefix has its own shape.
--
-- Attached HERE and not in the P.art_kinds literal, which is where they belong.
-- That table is built with the other cache paths at the top of the file, ~230
-- lines before `local Util` exists, so anything written there that names `Util`
-- compiles as a GLOBAL read -- nil at call time. It took the artist grid down on
-- its first draw with "attempt to index a nil value (global 'Util')". Down here
-- `Util` is the local, captured as an upvalue.
P.art_kinds.playlist.reseed = Util.art_url_pl
P.art_kinds.artist.reseed   = Util.art_url_artist

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

-- The one string hash in the file. Used for art identity below and for the
-- P.mass filenames of caches keyed by arbitrary text; see Util.mass_path.
function Util.djb2(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 0x100000000 end
    return h
end

-- The part of an art URL that identifies the IMAGE, so a replaced cover is
-- detectable. Album art is i.scdn.co/image/<hex> with no extension; category
-- icons are t.scdn.co/images/<hex>.jpeg, and the extension is what used to
-- defeat this -- an anchored [%w_%-]+$ cannot cross the dot, so every category
-- resolved to no hash at all and none of them ever cached. Query strings are
-- dropped too: they are cache-busting noise, not identity.
--
-- The last path segment is only an identity on the CONTENT-ADDRESSED CDNs.
-- Spotify's generated covers live elsewhere behind descriptive paths -- a mix
-- ends .../img/repeat/or/en, a seed mix .../Relaxing%20Classical/en/default, a
-- chart .../region_eg_default.jpg -- so 61 playlists on this account hashed to
-- "default" and 32 to "en". Since this value is what Util.keyed_art compares to
-- decide a cover went stale, those covers could never be SEEN to change: they
-- froze at whatever landed first, and mixes and charts are exactly the ones
-- Spotify regenerates most.
Util.art_hash = function(url)
    if not url or #url == 0 then return nil end
    local last = url:match("([^/?#]+)[?#]") or url:match("([^/?#]+)$")
    if not last then return nil end
    local tok = (last:gsub("%.%w+$", ""):gsub("[^%w_%-]", ""))
    -- A long hex tail IS the identity, and returning it untouched is
    -- load-bearing twice over: it leaves 94% of already-cached tokens
    -- byte-identical, and this value also NAMES the file in the flat album pool
    -- (see thumb_resolve), so changing it there would orphan every cover in it.
    if #tok >= 32 and tok:match("^%x+$") then return tok end
    -- Everything else: the whole url is the identity. Prefixed so a hashed token
    -- is never mistaken for a real asset id when reading an index by eye.
    return "u" .. string.format("%08x", Util.djb2(url))
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
        -- Through Util.http like every other request, so this follows whichever
        -- transport is in play rather than owning a seventh curl command line.
        -- The header dump the old form needed for Content-Length is gone with it:
        -- the headers come back as a string either way.
        local r = Util.http{url = url, timeout = timeout}
        local code = tostring(r.code):match("%d%d%d")
        local cl = tonumber((r.headers or ""):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
        -- NOTHING IS WRITTEN FOR A FAILED FETCH -- what `curl -sf` bought. A file
        -- holding an error body looks like a cover and decodes as an apology.
        if r.code >= 200 and r.code < 300 then write_file(tmp, r.body) end
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

-- MANY URLS, ONE CURL. -Z multiplexes over a few HTTP/2 connections: 40 covers
-- in 0.54s / 0.08s CPU versus 1.45s / 1.14s for the 8-at-a-time fork loop. The
-- old cost was process spawn and cold TCP+TLS, not concurrency -- hence
-- --parallel-max 16 matching 32 or 64. The same measurement holds for the API:
-- five requests take 2.50s as five curls and 0.66s through this.
--
-- Answers {[output path] = {code = "200", size = 12345}}. Reporting through
-- --write-out and not headers is the load-bearing part: `dump-header` in a -K
-- config is global and last-one-wins, so all responses concatenate into one file
-- with nothing tying them to a transfer, while --write-out is per transfer and
-- carries the status plus the bytes written, keyed by output path.
--
-- opts.fail passes -sf, which makes curl treat an HTTP error as a failed
-- transfer. Art wants that (a 404 cover is just a miss); the API pager does NOT,
-- because it has to tell a 429 from a 500 to know whether to back off.
-- Answers nil, not an empty table, when the config could not be written: that is
-- "nothing was attempted", which a caller must be able to tell from "everything
-- was attempted and every one failed" -- otherwise a broken scratch directory
-- reads as a batch of dead URLs and gets retried on a sleep.
function Util.curl_batch(jobs, opts)
    opts = opts or {}
    local got = {}
    if #jobs == 0 then return got end
    -- The other way out of this process, and it takes the same gate: a batch of
    -- six pages against a dead link is six timeouts, and its callers all treat
    -- nil as "keep what you have". See NET_DOWN_SECS.
    if Util.net_down() then return nil end
    -- NATIVELY WHEN EMBEDDED. One QNetworkAccessManager issues all of them over
    -- one connection, which is what `curl -Z --parallel-max` was already doing --
    -- so this is process hygiene rather than speed, plus HTTP/2 multiplexing.
    --
    -- The shim answers with a NUMBER for the status, because that is the sane
    -- thing for it to answer. Callers here have always been handed curl's `-w`
    -- output, which is a string, and they compare it as one (Util.is2xx does
    -- r:match, and one site tests r.code == "429"). Converted here, once, rather
    -- than teaching the shim a shape that suits only this caller.
    if Util.host and Util.host.http and not os.getenv("SPOOT_FORCE_CURL") then
        local res = Util.host.http{jobs = jobs, timeout = opts.timeout or 10,
                                   headers = opts.header and {opts.header} or nil}
        if not res then return nil end
        -- One answer is enough to know the link is alive; one failure is not
        -- enough to know it is dead, because a batch can lose a page on its own.
        -- So only an ALL-ZERO batch arms the gate.
        local best = 0
        for out, r in pairs(res) do
            got[out] = {code = tostring(r.code), size = r.size}
            if (tonumber(r.code) or 0) > best then best = tonumber(r.code) or 0 end
        end
        Util.net_note(best)
        return got
    end
    local cfg = Util.tmpfile("curlcfg")
    local f = io.open(cfg, "w")
    if not f then os.remove(cfg); return nil end
    -- Header first: curl carries options forward across the urls that follow in
    -- the same config, so one written at the end would apply to nothing.
    if opts.header then
        f:write('header = "', Util._curl_cfg_quote(opts.header), '"\n')
    end
    for _, j in ipairs(jobs) do
        f:write('url = "', Util._curl_cfg_quote(j.url), '"\n',
                'output = "', Util._curl_cfg_quote(j.out), '"\n')
    end
    f:close()
    -- filename_effective goes LAST so a path containing spaces still parses.
    local report = shell("curl -s" .. (opts.fail and "f" or "")
        .. (opts.compressed and " --compressed" or "")
        .. " -Z --parallel-max " .. tostring(opts.parallel or 8)
        .. " --connect-timeout " .. tostring(opts.connect_timeout or 5)
        .. " --max-time " .. tostring(opts.timeout or 10)
        .. " -K " .. shell_quote(cfg)
        .. " -w '%{http_code} %{size_download} %{filename_effective}\\n' 2>/dev/null") or ""
    os.remove(cfg)
    for code, size, path in report:gmatch("(%d+) (%d+) ([^\n]+)") do
        got[path] = {code = code, size = tonumber(size)}
    end
    return got
end

-- The art pass on top of that transport: name a temp file per cover, fetch the
-- batch, then validate and rename. Three passes, because a cover that came down
-- truncated is worth one more try and a 404 is not.
Util._art_batch = function(items)
    local todo = items
    for pass = 1, 3 do
        if #todo == 0 then break end
        local jobs = {}
        for j, pd in ipairs(todo) do
            pd.tmp = pd.path .. ".tmp" .. Util._rand_suffix() .. "." .. j
            jobs[#jobs+1] = {url = pd.url, out = pd.tmp}
        end
        -- nil means the batch never ran, which is not the same as every cover
        -- failing: give up rather than sleep between three passes that cannot
        -- work either.
        local got = Util.curl_batch(jobs, {fail = true, parallel = 16})
        if not got then return end
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
-- How long Util.serve_art_after may keep filling a grid before it has to stop
-- and let the engine read its next command. NOT a limit on how many covers a
-- grid gets -- see the loop there, which keeps going until the grid is full.
Util.ART_FILL_SECONDS = 10
Util.art_spool_dir = function() return P.art_spool end

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
    local pidf = P.prefetch_pid
    if Util.job_running(pidf, "--prefetch-art-batch") then return "spooled" end
    Util.spawn_self({"--prefetch-art-batch"}, nil, pidf)
    return "spawned"
end

-- `opts` is forwarded to Util.fetch_art, whose defaults (3 attempts, 5s connect,
-- 10s max, 1s between) are right for art the user ASKED to see and wrong for art
-- that is merely a menu backdrop. Dropping the passthrough is what let the two
-- decorative callers inherit the full retry budget: a cover that is not cached
-- yet froze the action menu for 17s with the network down, and up to ~32s if
-- connections opened but stalled -- silently, for a background image. Every
-- backdrop passes Util.ART_DECOR below -- the show list directly, the album view
-- and the action menu through Util.ensure_art_med; view_art and --notify keep
-- the defaults.
local function ensure_art(art_url, subdir, opts)
    if not art_url or #art_url == 0 then return nil end
    -- Its OWN extractor, not Util.art_hash, and the two can disagree: for a
    -- generated cover on pickasso.spotifycdn.com this answers the id after
    -- /image/ while art_hash answers the whole url hashed. Latent rather than
    -- live -- every url that reaches BOTH is i.scdn.co/image/<hex>, checked
    -- against all 825 show and episode covers on disk with 0 disagreements.
    -- Left alone deliberately: this value names the file in the flat album pool,
    -- so unifying them would orphan every cover in it to fix nothing.
    local hash = art_url:match("/image/([%w]+)") or art_url:match("/([%w_%-]+)$")
    if not hash then return nil end
    ensure_cache()
    -- ensure_cache() above created every P.art_subdirs entry in its one mkdir,
    -- so there is no fork here -- there used to be one PER CALL, on the action
    -- menu's hot path. A subdir absent from that table has no directory to write
    -- into: a bug in the caller, not a fetch to attempt.
    --
    -- No subdir means the shared 300px pool, which has a name of its own now
    -- rather than being "P.art itself" -- so the two arms this used to have
    -- collapse into one lookup.
    local base = P.art_subdirs[subdir or "albums"]
    if not base then return nil end
    local art_path = base .. "/" .. hash .. ".jpg"
    if Util._art_valid_file(art_path) then return art_path end
    -- ASKED FOR IT ONLY IF IT IS ALREADY HERE. The action menu resolves its
    -- backdrop twice: once on the way in, where a miss must answer immediately
    -- so the rows can go out, and once in the continuation after they have,
    -- where the fetch is free to take as long as it takes. Returning nil here is
    -- the first of those. No os.remove either -- a partial file is the later
    -- call's to clean up, and removing it now would only make that call fetch
    -- something this one already knows is coming.
    if opts and opts.cached_only then return nil end
    os.remove(art_path)
    return Util.fetch_art(art_url, art_path, opts)
end

-- The 640x640 rendition, for the two screens that draw a cover as a 364px
-- backdrop: the album view and the track action menu. Nothing else wants it --
-- the thumbnail grids share the 300px pool at 150px a tile, and the full-screen
-- viewer wants the largest one there is.
--
-- On Util rather than a local: the chunk body is one function at Lua's 200-local
-- cap, the same reason Util.ART_FAIL_TTL lives there.
--
-- Util.ART_DECOR on purpose. This is still only a backdrop, and it is no longer
-- warmed by anything: the grids cache the 300px file under a different name, so
-- the first open of an album pays one short fetch. A miss returns "", and
-- Util.serve_cover takes an empty path as "none", so
-- the menu opens promptly with no cover instead of waiting for one.
-- `cached_only` answers with the cover only if it is already on disk, and ""
-- otherwise. The fetch budget is irrelevant on that path because no fetch is
-- reached, which is why it passes a bare flag rather than a second copy of
-- Util.ART_DECOR's numbers.
Util.ensure_art_med = function(art_url, cached_only)
    return ensure_art(Util.art_url(art_url, "b273"), "albums/med-res",
                      cached_only and {cached_only = true} or Util.ART_DECOR) or ""
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
-- Directory list for ensure_cache's single mkdir, so every art directory exists
-- without a fork per draw: each kind's own cache and every rendition it keeps
-- beside it, plus every rendition subdirectory of the flat pool.
function Util.art_dirs()
    local out = ""
    for _, k in pairs(P.art_kinds) do
        out = out .. " " .. shell_quote(k.dir)
        if k.tiers then
            for _, t in pairs(k.tiers) do out = out .. " " .. shell_quote(t.dir) end
        end
    end
    for _, d in pairs(P.art_subdirs) do
        out = out .. " " .. shell_quote(d)
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

-- `tier` names one of the kind's extra renditions -- nil for its default, "med",
-- "hi". It was a boolean while two sizes were all any kind had; playlists have
-- three, and a boolean cannot say which. An undeclared tier reads as the default
-- rather than erroring, the way a kind with no renditions at all already did.
function Util.keyed_art(kind, item, fetch, tier, fallback)
    local cfg = P.art_kinds[kind]
    if not (cfg and item and item.id) then return fallback end
    local t    = tier and cfg.tiers and cfg.tiers[tier] or nil
    local dir  = (t and t.dir) or cfg.dir
    local idx  = Util.art_index(kind)
    -- Unchanged for "hi", so the <id>:hi entries already in playlist_art.json and
    -- artist_art.json still resolve to the files they were written for.
    local key  = t and (item.id .. ":" .. tier) or item.id
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
    -- The tier picks the rendition, the kind knows how to ask for it. Note the
    -- hash above is taken from the RAW url, so it identifies the artwork rather
    -- than the size -- which is what lets every tier of one cover share a single
    -- staleness token.
    local code = (t and t.code) or cfg.code
    if code and cfg.reseed then url = cfg.reseed(url, code) end
    if idx[key] == hash and Util._art_valid_file(path) then return path end
    -- Already tried this exact artwork and it would not come down. Answering
    -- with the placeholder is the whole point: the alternative is re-requesting
    -- it on every redraw of the list, which is what made a single dead cover
    -- cost seconds per menu.
    if Util.art_failed(idx[key], hash) then return fallback end
    if not fetch then return path, url, hash, key end  -- caller batches the fetch
    ensure_cache()   -- also creates every kind's dir
    -- Only a tier marked `full` is one the user asked to look at; everything
    -- else here is a grid tile or a backdrop, and a miss on those costs nothing
    -- visible. The old test was `not hi`, which read "is this the default tier"
    -- -- so the moment a decorative tier that was not the default existed, it
    -- would have inherited the full retry budget and frozen the view.
    local got = Util.fetch_art(url, path, (t and t.full) and nil or Util.ART_DECOR)
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
-- costs nothing visible -- the callers already `or ""`, and Util.serve_cover
-- strips the background-image line for an empty path -- so the menu opens
-- promptly with no backdrop instead of making the user wait for one.
Util.ART_DECOR = {attempts = 1, connect_timeout = 2, timeout = 4}

-- Unique path per call. A fixed /tmp/spoot_theme_<name>.rasi broke whenever a
-- view nested inside itself, and both callers can: a nested view_actions
-- overwrote the file and deleted it on exit, leaving the outer menu redrawing
-- against a missing -theme; a nested view_browse left the outer list wearing
-- the inner album's cover. A per-call sequence number isolates each one; the
-- startup sweep and clean_exit still glob these names.
-- The album and action views wear their subject's cover as the window's
-- BACKGROUND, and this used to bake that into a per-call .rasi in /tmp. Qt draws
-- the cover directly, so no file is needed -- but the art path this was given is
-- still the right one, chosen by the view itself. Recording it here means the
-- context cover beside an action menu is the view's OWN choice rather than a
-- second guess made by re-resolving the item, which is what Util.serve_ctx_art
-- had to do for everything else.
-- `art_url` is where to GO AND GET IT if the path came back empty, which is what
-- a caller asking cache-only gets on a first visit. Recorded rather than fetched
-- here, so the menu goes out now and its backdrop follows -- see
-- Util.serve_ctx_art, which runs after the rows.
--
-- IT USED TO BE CALLED write_art_theme, and it used to earn the name: it wrote a
-- .rasi baking the cover in as the window's background-image and handed back the
-- path to it. With rofi gone it wrote no file, took a theme NAME it did nothing
-- with, and returned that name unchanged -- so four callers were holding a local
-- called `album_theme` whose value was the string "album", passing it as
-- `theme=`, and reading as though a theme were being built. What it does is
-- record the cover; that is now what it is called and all it takes.
Util.serve_cover = function(art_path, art_url)
    Util.serve_ctx_path = (art_path ~= "" and art_path) or nil
    Util.serve_ctx_url = (not Util.serve_ctx_path) and art_url or nil
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
--   * no artwork      -- pointed at assets/noart.png rather than left iconless.
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
        local path, url, hash, key = Util.keyed_art(kind, it, false, nil, fb)
        if not url then return path end       -- already cached, or has no artwork
        return path, url, hash, key
    end
    local imgs = it.images or (it.album and it.album.images) or {}
    local url = imgs[1] and imgs[1].url
    if url and #url > 0 then
        url = Util.art_url(url, "1e02")
        local hash = Util.art_hash(url)
        -- The same path ensure_art would compute for this url, which is what
        -- makes a cover fetched for a backdrop already warm when the grid draws.
        -- Both read the directory out of P.art_subdirs so they cannot drift.
        if hash and #hash > 0 then return P.art_subdirs.albums .. "/" .. hash .. ".jpg", url end
    end
    -- No usable art URL. Deliberately returns no url, so the caller does not mark
    -- it missing: there is nothing to fetch, and the placeholder ships with the
    -- themes so it is always present and costs no network.
    return Util.ART_NONE
end

-- `focus` is the row the menu is about to open on (0-based, same convention as
-- ui_menu's `sel`). Covers are fetched outwards from there rather than from
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
    -- Keyed on identity AND shape: unsaving an album from Saved Albums mutates
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
    -- NO ICON AT ALL for a cover that is not on disk yet -- not the shipped
    -- "no cover" graphic, which is what stood here.
    --
    -- The rule above it survives: never name a file that does not exist. It was
    -- written for rofi's icon fetcher, which stored a null surface against the
    -- path and returned it forever after, but QML has the same failure by a
    -- different route -- an Image reloads when its `source` CHANGES, so naming a
    -- path before the file lands leaves it in Error and the art event that
    -- follows names the identical string and changes nothing.
    --
    -- Standing in a real picture was rofi's half of it, because a dmenu row
    -- needed some icon or the grid reflowed. Here an absent icon is an empty
    -- source, the grid draws its own placeholder behind it, and when the cover
    -- lands the art event names a path that IS a change -- so it loads, and the
    -- tile was never briefly wearing a graphic that says the album has no cover
    -- when the truth is that it has one and it is on its way.
    local placeholders = 0
    for i, e in ipairs(entries or {}) do
        local p = paths[i]
        -- \0icon is the only field appended to a row, and always last. Stripped
        -- unconditionally so a redraw can promote a row that had none.
        local cut = e:find("\0", 1, true)
        local bare = cut and e:sub(1, cut - 1) or e
        if p and blank[i] then
            placeholders = placeholders + 1
            entries[i] = bare
        elseif p then
            entries[i] = bare .. "\0icon\x1f" .. p
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
        ms = (t_start and t_end) and math.floor((t_end - t_start) * 1000 + 0.5) or "-"
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
    local d = safe_decode(Util.http{
        url = "https://api.spotify.com/v1/me/player/devices", compressed = true,
        timeout = 3, headers = {"Authorization: Bearer " .. token}}.body)
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
--
-- Every setting here is read AT SPAWN. spotifyd takes them as argv and nothing
-- can change them under a running daemon, which is why both the bitrate and the
-- track-cache views end in a restart rather than pretending to apply.
--
-- --no-audio-cache takes an explicit value (spotifyd 0.4.2: `[=<BOOL>]`), so the
-- flag is always present and only the value moves -- no conditional string
-- building, and the running process names the setting either way, which is what
-- makes `pgrep -a spotifyd` a straight answer to "is caching on?".
local function ensure_spotifyd()
    local pid = trim(shell("pgrep -x spotifyd 2>/dev/null") or "")
    if pid == "" then
        os.execute("spotifyd --no-daemon --device-name spoot --backend pulseaudio --use-mpris --volume-normalisation --initial-volume " .. get_saved_volume() .. " --bitrate " .. get_saved_bitrate()
            .. " --no-audio-cache=" .. (Util.track_cache_on() and "false" or "true")
            .. " -c " .. shell_quote(P.spotifyd) .. " > /dev/null 2>&1 &")
    end
end

-- DATA CACHE

-- The one place a v1 endpoint becomes a URL. Util.paged_fetch's batch builds the
-- same string for the pages it fetches without api_get, and a second copy of
-- this is exactly how the two would drift.
function Util.api_url(path, params)
    local url = "https://api.spotify.com/v1/" .. path
    if params then url = url .. "?" .. params end
    return url
end

local function api_get(path, params, _retry)
    -- SHUT MEANS SHUT. Reads fall back to whatever is cached, exactly as they do
    -- when the link is down -- which is the behaviour every caller here is
    -- already written for. WRITES ARE NOT GATED: a write is something you just
    -- asked for, it is rare, and silently dropping it is worse than one more 429.
    if Util.rate_cool() > 0 then return nil end
    local token = get_token()
    if not token then return nil end
    local url = Util.api_url(path, params)
    -- --compressed on every JSON fetch in the file. Spotify gzips only when
    -- asked, and it is asked nowhere before this: a 50-album page is 451,481
    -- bytes uncompressed and 28,566 compressed, measured. curl decompresses
    -- transparently, so nothing downstream can tell the difference except by
    -- how long it waited. Not on the art fetches -- a JPEG is already
    -- compressed and the header would buy nothing.
    local r = Util.http{url = url, compressed = true, timeout = 10,
                        headers = {"Authorization: Bearer " .. token}}
    local status, body = r.code, r.body
    if status == 429 then
        -- WHAT SPOTIFY ACTUALLY ASKED FOR. This used to be
        -- `math.min(tonumber(secs), 5) + 5` -- a ten-second ceiling on a window
        -- the server might have said was five minutes long -- so spoot went back
        -- early, every time, and Spotify's limits are ROLLING: asking again inside
        -- the window is what extends it. The cap made the outage longer than
        -- obeying the header would have.
        --
        -- Clamped at both ends and not capped at one: a floor so a header of "1"
        -- cannot turn into a busy loop, a ceiling so a pathological value cannot
        -- take the app off the network for an hour. Between them, the number the
        -- server sent.
        local secs = tonumber(string.match(r.headers or "", "[Rr]etry%-[Aa]fter:%s*(%d+)")) or 30
        secs = math.max(5, math.min(secs, 60))
        -- Read BEFORE the write below, so this asks whether a window was already
        -- open -- which is the difference between the first 429 of an outage and
        -- the twentieth. The gate above means there should not BE a twentieth any
        -- more; this stays because a burst already in flight can still produce one.
        local was = Util.rate_cool()
        -- ...and a background job arms the gate too. It used to write nothing at
        -- all (`if not Util.detached`), so a prefetch that got itself rate limited
        -- left no record of it and every foreground request walked straight into
        -- the same window. The gate is about the ACCOUNT, not about who noticed.
        Util.secure_write(P.rate_cooldown, os.time() + secs)
        if was == 0 and not Util.detached then
            ui_say("Spotify API rate limit reached (429)" .. SEP
                   .. "using cache for " .. secs .. "s")
        end
        return nil
    end
    if status == 401 then
        if not Util.detached then
            ui_say("Spotify token expired (401)" .. SEP .. "System > Re-authenticate")
        end
        return nil
    end
    -- NO ANSWER AT ALL, which is not something a server can say -- the link is
    -- down, or the request timed out against it. Told once per outage, beside
    -- the 429 and the 401 above; Util.net_note has already shut the gate, so the
    -- requests behind this one cost nothing. Util.net_said is cleared the moment
    -- anything answers, so a link that drops twice says so twice.
    if status == 0 then
        if not Util.net_said and not Util.detached then
            Util.net_said = true
            ui_say("No connection" .. SEP .. "showing what is cached")
        end
        return nil
    end
    if status >= 500 and not _retry then
        -- Util.wait, not os.execute("sleep 1"): embedded this is a timer that
        -- keeps the bus dispatching, and outside it is the same sleep. It was
        -- the last hand-rolled fork left in the request path.
        Util.wait(1)
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
--
-- Page 1 is fetched alone, and its `total` is what makes the rest cheap: every
-- remaining offset is known from it, so they go out as ONE curl instead of a
-- sequential walk. Measured on a 6-page browse: 3.57s sequential, 1.04s this
-- way. That is the whole point -- the old loop paid a fresh TCP+TLS handshake
-- and a cold-connection first byte per page (~0.63s each, versus ~0.11s on a
-- warm one), which is why reopening a 739-track playlist took eight round trips
-- to draw.
--
-- Page 1 still goes through api_get, and so does any page the batch failed to
-- bring back: that function owns the 429 cooldown, the 401 notice, the 5xx
-- retry and Util.mark_availability, and none of that is worth reimplementing on
-- the fast path.
--
-- opts.max caps the items wanted, for the callers that want a head of the list
-- rather than all of it. Without it, a total of 4,000 would mean 80 pages in
-- flight for a caller that only ever reads 100.
--
-- THE TRADE: paging by `total` cannot see an item added DURING the fetch, where
-- following `next` one page at a time can. Util.parallel_fetch_library already
-- accepts exactly this for the library shelves; the exposure is one refresh.
Util.paged_fetch = function(path, mk_params, done, each, opts)
    opts = opts or {}
    local all = {}
    local function take(items)
        for _, it in ipairs(items or {}) do
            local v = it
            if each then v = each(it) end
            if v ~= nil then all[#all+1] = v end
        end
    end

    local d = api_get(path, mk_params(0))
    if not d then return nil end
    local items = d.items or {}
    take(items)
    if done(d, items) then return all end

    local per, total, token = #items, tonumber(d.total), get_token()
    if per > 0 and total and token then
        local want = opts.max and math.min(total, opts.max) or total
        local pages = math.ceil(want / per)
        if pages <= 1 then return all end
        -- One temp file per page, named through Util.tmpfile so they land in
        -- this process's 0700 scratch directory and the orphan sweep can reclaim
        -- them if we die mid-flight.
        local jobs = {}
        for i = 1, pages - 1 do
            jobs[i] = {url = Util.api_url(path, mk_params(i * per)), out = Util.tmpfile("page")}
        end
        -- The token goes in the -K config rather than on argv, which is where
        -- every other request in the file puts it: the config is written 0700
        -- and deleted immediately, so this is the one fetch whose credentials
        -- never appear in the process list.
        local got = Util.curl_batch(jobs, {compressed = true, parallel = 6, timeout = 15,
                                           header = "Authorization: Bearer " .. token})
        -- 429 IS REACHABLE HERE in a way it was not when pages went one at a
        -- time, and it arrives for the whole burst at once: measured against a
        -- 54-page podcast, an over-eager batch came back 54/54 rate limited in
        -- 0.66s. Back off once and re-ask for just the pages that missed, at a
        -- crawl -- without this the retry below hands each of them to api_get,
        -- which answers nil on a 429, and one burst would fail the whole fetch
        -- and cache nothing.
        if got then
            local again, limited = {}, false
            for i = 1, pages - 1 do
                local r = got[jobs[i].out]
                if not (r and Util.is2xx(r.code)) then
                    again[#again+1] = jobs[i]
                    if r and r.code == "429" then limited = true end
                end
            end
            if limited and #again > 0 then
                os.execute("sleep 2")
                for out, r in pairs(Util.curl_batch(again, {compressed = true, parallel = 2,
                        timeout = 15, header = "Authorization: Bearer " .. token}) or {}) do
                    got[out] = r
                end
            end
        end
        for i = 1, pages - 1 do
            local r = got and got[jobs[i].out]
            local dn = (r and Util.is2xx(r.code)) and safe_decode(read_file(jobs[i].out)) or nil
            os.remove(jobs[i].out)
            if dn then
                -- api_get does this for every response it returns; a page that
                -- came in through the batch has to be collapsed the same way or
                -- its ~185-entry available_markets arrays reach the disk cache.
                Util.mark_availability(dn)
            else
                -- Anything the batch could not bring back gets one honest retry
                -- through api_get -- which is also what turns a 429 into a real
                -- cooldown rather than a silently short list.
                dn = api_get(path, mk_params(i * per))
                if not dn then return nil end
            end
            take(dn.items)
        end
        return all
    end

    -- No `total` to page by: cursor-paginated endpoints (me/following walks an
    -- `after` token) and anything that answered an empty first page. Same loop
    -- as before, picking up where page 1 left off.
    local offset = per
    while true do
        local dn = api_get(path, mk_params(offset))
        if not dn then return nil end
        local it2 = dn.items or {}
        take(it2)
        if done(dn, it2) then break end
        offset = offset + #it2
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
    -- These URLs are assembled by hand rather than going through api_get, so the
    -- market has to be appended here too -- this is the path that actually
    -- rebuilds the liked cache, and without it every track comes back with no
    -- is_playable and a ~185-entry available_markets. Resolved once, up front.
    local mkt = Util.market()
    mkt = mkt and ("&market=" .. mkt) or ""

    -- One curl for the whole batch, the same transport the covers and
    -- Util.paged_fetch use. This was `cmd1 & cmd2 & … & wait` -- N processes,
    -- each paying its own TCP+TLS -- which measured 0.81s against 0.63s for six
    -- pages, and the concurrency bound is now --parallel-max rather than a hand
    -- rolled BATCH loop.
    local function fire_batch(jobs)
        if #jobs == 0 then return end
        Util.curl_batch(jobs, {compressed = true, parallel = 6, timeout = 10, header = auth})
    end

    local function page_valid(file)
        local d = safe_decode(read_file(file))
        return d and d.items and #d.items > 0
    end

    -- PHASE 1: PROBE — fetch page 0 for all three endpoints simultaneously
    fire_batch({
        {url = base .. "me/tracks?limit=50&offset=0" .. mkt, out = tmpdir .. "/lk_0.json"},
        {url = base .. "me/albums?limit=50&offset=0" .. mkt, out = tmpdir .. "/al_0.json"},
        {url = base .. "me/following?type=artist&limit=50", out = tmpdir .. "/ar_0.json"}
    })
    -- PHASE 2: PARSE PROBES — extract totals and page 0 data
    local lk0 = safe_decode(read_file(tmpdir .. "/lk_0.json"))
    local al0 = safe_decode(read_file(tmpdir .. "/al_0.json"))
    local ar0 = safe_decode(read_file(tmpdir .. "/ar_0.json"))

    local tracks_total = (lk0 and lk0.total) or 0
    local albums_total = (al0 and al0.total) or 0
    local tracks_pages = math.ceil(tracks_total / 50)
    local albums_pages = math.ceil(albums_total / 50)

    -- PHASE 3: BUILD JOBS — page 0 already fetched, queue pages 1..N-1
    local jobs = {}
    for i = 1, tracks_pages - 1 do
        jobs[#jobs+1] = {url = base .. "me/tracks?limit=50&offset=" .. (i * 50) .. mkt,
                         out = tmpdir .. "/lk_" .. i .. ".json"}
    end
    for i = 1, albums_pages - 1 do
        jobs[#jobs+1] = {url = base .. "me/albums?limit=50&offset=" .. (i * 50) .. mkt,
                         out = tmpdir .. "/al_" .. i .. ".json"}
    end

    -- PHASE 4: FIRE, then retry failures sequentially. No chunking loop: one
    -- curl takes the lot and --parallel-max decides how many are in flight.
    fire_batch(jobs)

    -- RETRY: check each page file, retry failures one at a time with delay.
    -- Through fire_batch with a single job rather than a second command builder
    -- -- one URL is just the smallest batch.
    for i = 1, tracks_pages - 1 do
        local f = tmpdir .. "/lk_" .. i .. ".json"
        if not page_valid(f) then
            os.execute("sleep 1")
            fire_batch({{url = base .. "me/tracks?limit=50&offset=" .. (i * 50) .. mkt, out = f}})
        end
    end
    for i = 1, albums_pages - 1 do
        local f = tmpdir .. "/al_" .. i .. ".json"
        if not page_valid(f) then
            os.execute("sleep 1")
            fire_batch({{url = base .. "me/albums?limit=50&offset=" .. (i * 50) .. mkt, out = f}})
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
        -- Cursor-paginated, so these cannot be batched the way the offset pages
        -- above are -- each `after` is only known once the page before it lands.
        -- Straight to memory now; the scratch file it round-tripped through was
        -- only ever there because curl needed somewhere to put the body.
        local ar_page = safe_decode(Util.http{
            url = base .. "me/following?type=artist&limit=50&after=" .. artist_after,
            headers = {auth}, compressed = true, timeout = 10}.body)
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
        -- A WHOLE PAGE, not one row. Liked tracks and saved albums carry
        -- `added_at`, so their newest item moves the moment anything changes;
        -- me/following has no such field and no snapshot id, so the only signals
        -- are the count and the ids themselves. `total .. first_id` -- which is
        -- what this asked for -- is blind to every change that keeps both: one
        -- follow paired with one unfollow, or re-following someone who does not
        -- sort to the top. The shelf then stays as it was until ttl_lib_max
        -- forces a full rebuild hours later, which is exactly "followed artists
        -- don't update".
        --
        -- Fifty ids in one request instead of one, summed into a fingerprint.
        -- The same single call, a response measured in kilobytes, and it now
        -- catches any change inside the first page rather than only the two that
        -- happen to move the count or the head.
        local d = api_get("me/following", "type=artist&limit=50")
        local a = d and d.artists
        if not a then return nil end
        -- Order-sensitive on purpose: a swap that preserves the set is still a
        -- change to the list this fingerprint stands for. Positional weights, so
        -- two ids trading places do not cancel out.
        local sum = 0
        for i, it in ipairs(a.items or {}) do
            for c in tostring(it.id or ""):gmatch(".") do
                sum = (sum * 31 + c:byte() + i) % 0x7FFFFFFF
            end
        end
        return (a.total or -1) .. ":" .. sum
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
        -- Rate limited is not "the player went away", and recover_playback below
        -- would start a track over the podcast you are listening to on the
        -- strength of it.
        if Util.rate_cool() > 0 then return end
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
    -- THE PLAYER IS THE ONLY WITNESS. Playing is the one answer that needs one:
    -- Paused, Stopped and "nobody there" are all not-playing, so this is a single
    -- comparison rather than a chain.
    --
    -- IT USED TO FALL BACK TO THE CACHE when the status came back empty, and the
    -- cache is written while a track IS playing and then simply left there --
    -- now.json says `playing: true` for a track that has been paused for an hour,
    -- which is what the note above says about it. So the moment spotifyd was not
    -- on the bus -- it crashed, it had not started yet, it was restarting after a
    -- bitrate change -- spoot read that file, announced the last track as
    -- playing, and drew the transport marker on it.
    --
    -- Which broke the row itself, not just the glyph: Util.play_or_toggle sends a
    -- PAUSE to whatever it believes is playing, so Return on that track asked a
    -- player that was not there to pause, and did nothing at all. Pressed again,
    -- nothing again -- see the note above Util.played_here, which is this same
    -- fault caught once before from the other end.
    is_playing = Util.playerctl_status() == "Playing"
    return true
end

-- Cheap refresh for any menu that renders now-playing state. fast_now_track is
-- two file reads plus a local playerctl call; get_playback is a ~300ms me/player
-- round trip that self-throttles to once per 5s, so this is safe to call on
-- every menu entry.
function Util.sync_now()
    -- WAIT FOR THE PLAYER TO CATCH UP, NOT FOR A CLOCK.
    --
    -- Right after a play, spotifyd needs a moment to pick the track up: now.json
    -- still names the previous one and me/player can answer with it too, so
    -- reading either drags the marker back to the track you just left. That was
    -- answered with a flat five-second blackout -- five seconds during which
    -- spoot deliberately did not look, whatever had actually happened in them.
    --
    -- But the question was never "how long ago was the command". It is "has the
    -- player caught up", and that is answerable directly: read, and keep the
    -- reading unless it is still naming the track we left. It converges the
    -- moment the player does -- usually well inside a second -- and it cannot go
    -- on being wrong for five. The five seconds survive only as a ceiling, so a
    -- play that never starts cannot wedge the marker forever.
    local guard = P.recent_cmd_at and (os.time() - P.recent_cmd_at < 5)
    if not guard then
        if not Util.fast_now_track() then get_playback() end
        return
    end
    local was_track, was_id, was_playing = current_track, current_id, is_playing
    if not Util.fast_now_track() then get_playback() end
    -- Still the track we left, and we had already moved off it: the player is
    -- behind. Put our own reading back and ask again next time.
    if P.pending_from and current_id == P.pending_from and was_id ~= P.pending_from then
        current_track, current_id, is_playing = was_track, was_id, was_playing
        return
    end
    P.recent_cmd_at, P.pending_from = nil, nil
end

-- Where Alt+c should put the cursor: the 0-based row holding `id`, matching
-- ui_menu's `sel` convention, or nil when this list does not hold it.
--
-- nil means LEAVE THE CURSOR ALONE. view_browse used to fall back to row 0
-- instead, so a jump it could not honour also threw away your place -- which in
-- an album grid was EVERY jump, since it was matching a track id against rows
-- that are albums.
--
-- On Util rather than a local: the chunk body is one function at Lua's 200-local
-- cap, the same reason Util.ART_FAIL_TTL lives there.
function Util.row_of_id(items, id)
    if not id then return nil end
    for i = 1, #(items or {}) do
        if items[i].id == id then return i - 1 end
    end
    return nil
end

-- The album the playing track belongs to. The same field display_album already
-- tests to put the ▶ marker on a single, and what Alt+c has to match in a grid
-- whose rows ARE albums.
function Util.current_album_id()
    return current_track and current_track.album and current_track.album.id or nil
end

open_url = function(url)
    local kind, id = parse_spotify_url(url)
    if not kind then ui_say("No valid Spotify web link detected"); return end
    if kind == "track" then
        local d = api_get("tracks/" .. id, Util.with_market())
        if d then view_actions(d)
        else ui_say("Track not found") end
    elseif kind == "album" then
        local d = api_get("albums/" .. id, Util.with_market())
        if d then browse_album(id, (d.name or "Album") .. album_suffix(d))
        else ui_say("Album not found") end
    elseif kind == "artist" then
        local d = api_get("artists/" .. id)
        if d then view_artist({id=d.id, name=d.name or "Artist"})
        else ui_say("Artist not found") end
    elseif kind == "playlist" then
        local d = api_get("playlists/" .. id)
        if d then
            Util.open_playlist(d)
            if jump_to_track_pending then return end
        else ui_say("Playlist not found") end
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
        else ui_say("Episode not found") end
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
    -- No marker here either; the UI draws it. `playing` still decides whether a
    -- frozen resume position is worth showing, which is about the DATA.
    local p = ""
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
    -- NO TRANSPORT MARKER AND NO GREEN. Which row is playing changes while you
    -- are looking at the list, and baking it into the row's TEXT meant the only
    -- way to move it was to build the whole menu again -- which is what rofi
    -- forced, because a dmenu process could be handed strings and nothing else.
    -- The row now carries its id (see Util.serve_rows) and the UI marks whichever
    -- one matches what is playing, live, without asking for anything.
    local l  = (not hide_liked) and item.id and liked[item.id] and "\u{f05d} " or ""
    local e  = item.explicit and "\u{f071} " or ""
    local txt = l .. e .. (item.name or "Unknown") .. (hide and "" or SEP .. an)
    if item.unavail and item.id ~= current_id then
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
    -- A `playing` local stood here, worked out from current_track's album, and
    -- was read by nothing: the transport marker moved to the UI, which draws it
    -- from live state so that it can move without the menu being rebuilt. What
    -- the UI needed was the FACT rather than the string -- see serve_playback's
    -- albumId, which is where that knowledge went.
    --
    -- Single glyph FIRST, transport marker after it: the glyph is what the row
    -- is, the marker is what it is doing, and a fixed leading column reads
    -- better than one that shifts right whenever playback starts.
    body = Util.markup('<span foreground="#fab387">') .. "\u{F069F}"
           .. Util.markup("</span>") .. " " .. body
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
-- The video badge sits between the two, the way display_playlist prefixes a
-- Spotify-owned playlist: type glyph first (it is what tells a show row from an
-- episode row on the All search page), then what is true ABOUT this show, then
-- the name.
--
-- media_type is "audio" or "mixed" and nothing else, and "mixed" means the show
-- publishes SOME video episodes -- Spotify will not say which. So the badge
-- belongs to the show and never to a row under it, and its absence has to mean
-- "not known to have video", never "no data": an object cached before this
-- carries no media_type at all and must render exactly as it did.
function Util.display_show(item)
    local vid = Util.is_video_show(item) and Util.type_icon("video") or ""
    return Util.type_icon("shows") .. vid .. (item.name or "Unknown") .. album_suffix(item)
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
    if #tracks == 0 then ui_say("No recently played tracks"); return end
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
    local v = Util.mpris{op = "position"}.value or 0
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
    local v = Util.mpris{op = "status"}.value or ""
    mem_set("_playerctl_status", v, 1)
    return v
end

-- IS THERE A PLAYER ON THE BUS AT ALL. Both transports answer "" when there is
-- not -- the host's D-Bus property call fails, and playerctl prints nothing --
-- so an empty status is the ABSENCE of a player rather than a player with
-- nothing to say. There is no third state to confuse it with: MPRIS answers
-- Playing, Paused or Stopped.
--
-- It matters because every transport spoot has goes through MPRIS to the local
-- player (see Util.transport). With nobody there, "playing" is not a state spoot
-- can be in, whatever any cache or any API says about it.
function Util.player_live()
    return Util.playerctl_status() ~= ""
end

function Util.playerctl_bust()
    mem_bust("_playerctl_status")
end

local function get_playerctl_volume()
    local cached = mem_get("_playerctl_vol")
    if cached ~= nil then return cached end
    local v = Util.mpris{op = "volume"}.value
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
        synced = type(d) == "table" and type(d.times) == "table" and #d.times > 0
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

-- NO NOW-PLAYING LINE. Every one of these captions used to open with
-- track_mesg(current_track) -- the playing track, its artists and its status
-- icons -- because rofi had one message bar and nowhere else to put it. The
-- now-playing strip is that place now, permanently and on every view, so
-- repeating it above the rows said the same thing twice and cost a line of the
-- panel to do it. What is left in each is the part the strip does NOT carry.
-- seek_mesg lived here: an ASCII progress bar of twenty block characters and two
-- clocks, drawn as the seek menu's caption because rofi had no other way to show
-- a position. The now-playing strip shows the real one, continuously and on every
-- view, so this was a worse copy of something already on screen.

local function vol_mesg(vol)
    local v = vol or get_playerctl_volume()
    -- The bar and nothing else: volume is the one thing here the now-playing
    -- strip does not show.
    return v .. "%  " .. progress_bar(v / 100) .. "  100%"
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

-- How many track URIs one play request carries. Spotify documents no maximum for
-- the `uris` array, so this is the size that has always worked here rather than a
-- limit anyone published -- which is exactly why it belongs in one named place
-- instead of being spelled `+ 49` at two call sites that never referenced each
-- other.
--
-- On Util rather than a local: the chunk body is one function at Lua's 200-local
-- cap, the same reason Util.ART_FAIL_TTL lives there.
Util.PLAY_URIS_MAX = 50

-- The slice of a CONTEXTLESS list to hand Spotify, and where the played row sits
-- inside it. Returns (uris, position).
--
-- Only three of the places you can start playback from have a context to play
-- through -- an album, a playlist, the single-album shortcut. Everything else,
-- from Liked Tracks to a genre shelf, has to send a bare `uris` array, and the
-- moment that array runs out Spotify autoplays whatever it likes. That is
-- playback wandering off the list you were looking at.
--
-- Both callers used to build the array as `idx .. idx+49`: everything BEFORE the
-- row was thrown away, so a 50-track genre shelf played from row 30 sent 21 URIs
-- and strayed 21 tracks later. A list that fits in one request is now sent
-- WHOLE, with the offset pointing at the row -- which covers every genre shelf,
-- More Like This and search page outright.
--
-- A longer list still starts at the row. Forward coverage is what decides how
-- long playback stays put, so spending it on tracks behind the cursor would buy
-- nothing: recover_playback re-issues its own window on every skip, which is
-- what makes Previous work without them.
function Util.play_window(uris_all, idx)
    local n = #uris_all
    local first = (n <= Util.PLAY_URIS_MAX) and 1 or idx
    local uris, pos = {}, 0
    for i = first, math.min(n, first + Util.PLAY_URIS_MAX - 1) do
        uris[#uris+1] = uris_all[i]
        if i == idx then pos = #uris - 1 end
    end
    return uris, pos
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
        ui_say("Selection is unavailable in your account's region")
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
        -- queue_tracks, not all_items: save_queue above has just built it, and
        -- the idx it handed back indexes THAT array -- the filtered one, with
        -- id-less rows dropped. Reading all_items with a filtered index was off
        -- by one row for every id-less row above the one played. It also spares
        -- a second Util.item_uri pass over the whole list, since save_queue
        -- already did exactly that.
        local uris, pos = Util.play_window(queue_tracks, idx)
        if #uris > 0 then b = {uris=uris, offset={position=pos}} end
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
        if ok then
            P.recent_cmd_at = os.time(); Util.playerctl_bust()
            -- The track we are LEAVING. Util.sync_now waits for the player to
            -- stop naming it rather than for a clock -- see there.
            P.pending_from = current_id
            -- WHERE IT WAS PLAYED FROM is the UI's to remember, and this is the
            -- only moment anything can know it: the menu on screen when a play
            -- succeeds IS the origin, whatever it happens to be -- Liked, a
            -- search result, an album, a queue. The engine cannot answer that
            -- later from the track alone, because a track belongs to an album
            -- and was played from a list, and those are rarely the same place.
            if Util.serving then
                Util.serve_write({ev = "played", id = item and item.id or nil})
            end
            -- ...and its LAST STEP, which is the only part worth reopening. The UI
            -- remembers the whole trail as well, and that is right while the list
            -- is still ON it -- going there is then a walk. When it is not, re-
            -- entering the journey that led there (an artist, then their albums,
            -- then the album) rebuilds a path nobody asked to walk a second time.
            -- One entry reopens the list itself and nothing else.
            Util.play_origin_save()
        end
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
-- HAS ANYTHING PLAYED IN THIS PROCESS. Not "is something playing" -- that is
-- is_playing -- but whether there is a player behind the state at all.
--
-- The two are the same after the first note and quite different before it. On a
-- cold start Spotify still remembers the last track you heard, hours ago, and
-- reports it with is_playing false: indistinguishable, from inside, from a track
-- you paused a moment ago. That mattered in exactly two places and was wrong in
-- both -- Return on the row asked a player that is not running to resume, and the
-- UI drew the transport marker on a track that was over.
Util.played_here = false

function Util.transport(playing)
    local ok = Util.mpris{op = playing and "play" or "pause"}.ok
    Util.playerctl_bust()
    -- READ IT BACK rather than assuming it. playerctl exiting 0 says the method
    -- call was DELIVERED, not that the player did anything with it -- so this
    -- used to write down what it had asked for and call that the state.
    --
    -- It can afford the truth: playerctl is a synchronous D-Bus call, so by the
    -- time it returns the player has processed it, and fast_now_track reads MPRIS
    -- locally with no network anywhere near it. The guess only ever covered the
    -- gap until the next poll, and it covered it by being right most of the time.
    if ok then
        Util.played_here = true
        if not Util.fast_now_track() then is_playing = playing end
    end
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
    -- TOGGLING NEEDS SOMETHING TO TOGGLE. Straight after a cold start current_id
    -- names the track Spotify last remembers rather than one that is loaded
    -- anywhere, so this branch sent a resume to a player that was not there and
    -- the row you pressed Return on did nothing at all -- you had to play some
    -- OTHER track first to get out of it. Nothing has played here yet, so nothing
    -- is paused: fall through and start it, like any other row.
    -- ...AND A PLAYER TO TOGGLE IT ON. `is_playing` has more than one source --
    -- the local player, the Web API's view of a Connect session, a cached
    -- snapshot -- and only the first of them is something Util.transport can
    -- actually talk to. When it came from either of the others this branch sent a
    -- pause into the void and answered true, so the row you pressed Return on did
    -- nothing, every time, until you played some OTHER track to get out of it.
    --
    -- Asked here rather than trusted from `is_playing`, because the point is not
    -- what spoot believes: it is whether there is anything on the bus to be told.
    if item.id and item.id == current_id and Util.player_live()
       and (is_playing or Util.played_here) then
        Util.transport(not is_playing)
        return true
    end
    if do_play(item, ctx_type, ctx_id, all_items, idx) then
        Util.played_here = true
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

-- Applies a library change to the CACHED shelf rather than deleting it -- the
-- same bargain Util.optimistic_like makes above for liked tracks, extended to
-- the shelves that were still being thrown away on every write.
--
-- Deleting the file is what left the tile grids wearing stale artwork.
-- Util.shelf_tiles reads every shelf under Util.cache_only, where a missing file
-- is not "this shelf changed", it is "no answer": Util.shelf_head reports
-- "unknown", and Util.keyed_art then deliberately keeps the cover it already
-- has. The row wore the old one until you opened its list -- the one path that
-- calls the loader outside cache_only and repopulates the cache -- or until the
-- 300s-throttled shelf warmer got to it. A spliced shelf stays readable, so the
-- next grid draw sees the real head and repaints from it.
--
-- Falls back to the old bust when there is nothing cached to amend or no object
-- to amend it with: an unreadable shelf is still better than a wrong one, and it
-- keeps every caller that holds only an id behaving exactly as it did.
--
-- opts.sort is the shelf's own ordering -- Util.lib_sorted for the name-ordered
-- library shelves -- so a spliced list comes out ordered like a freshly paged
-- one. opts.ttl defaults to P.ttl, which is the TTL of every shelf but
-- my_playlists.
function Util.shelf_splice(mem_key, file, item, add, opts)
    opts = opts or {}
    local list = mem_get(mem_key)
    -- No TTL: an expired shelf still holds the content being amended, and the
    -- write below re-stamps it.
    if type(list) ~= "table" then list = disk_get(file) end
    if type(list) ~= "table" or not (item and item.id) then
        mem_bust(mem_key); disk_bust(file); return false
    end
    -- Removal and replacement are the same pass: a save of something already on
    -- the shelf must not leave two rows for it.
    local out = {}
    for _, e in ipairs(list) do
        if e.id ~= item.id then out[#out+1] = e end
    end
    if add then out[#out+1] = item end
    if opts.sort then opts.sort(out) end
    mem_set(mem_key, out, opts.ttl or P.ttl)
    disk_set(file, out)
    return true
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
    flush_liked_cache()
    if Util._api_hdr then os.remove(Util._api_hdr) end
    os.remove(P.instance_lock)
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
    if not token then ui_say("Cannot like: no token"); return false end
    local verb = unlike and "DELETE" or "PUT"
    local url = "https://api.spotify.com/v1/me/tracks?ids=" .. item.id
    local r = Util.api_write(verb, url, token)
    if not Util.is2xx(r) then
        ui_say(unlike and "Failed to unlike" or "Failed to like")
        return false
    end
    if unlike then liked[item.id] = false else liked[item.id] = true end
    Util.persist_liked(Util.optimistic_like(item, unlike))
    _liked_dirty = true
    bust_format_cache()
    return true
end

-- Answers from the cached shelf before the network, exactly as Util.lib_has does
-- for albums and shows. view_artist calls this on the way in, so every open of
-- every artist hub used to pay a me/following/contains round trip for something
-- load_followed_artists already knew.
--
-- Read under Util.cache_only, the way Util.shelf_tiles reads its shelves: this
-- must never turn one small request into a paginated crawl of the whole followed
-- list, so a shelf that is not on disk falls through to the ask below instead.
--
-- Same trade Util.lib_has states: a follow made on another device reads stale
-- until the shelf refreshes, and acting on the row corrects it either way --
-- do_follow_artist splices the shelf as it writes.
--
-- No token fetch here: api_get resolves (and refreshes) its own, and answers nil
-- when there isn't one, which this already reads as "not following".
local function api_check_following(artist_id)
    if not artist_id then return false end
    local was = Util.cache_only
    Util.cache_only = true
    local items = load_followed_artists()
    Util.cache_only = was
    if type(items) == "table" and #items > 0 then
        for _, a in ipairs(items) do if a.id == artist_id then return true end end
        return false
    end
    local r = api_get("me/following/contains?type=artist&ids=" .. artist_id)
    return r and r[1] == true
end

-- `artist` is the object artist_id names, when the caller has it: supplying it
-- amends the cached shelf instead of deleting it, which is what keeps the
-- Followed Artists tile from going stale. See Util.shelf_splice.
local function do_follow_artist(artist_id, follow, artist)
    local token = get_token()
    if not token then return false end
    local verb = follow and "PUT" or "DELETE"
    local url = "https://api.spotify.com/v1/me/following?type=artist&ids=" .. artist_id
    local r = Util.api_write(verb, url, token, {len0=true})
    if Util.is2xx(r) then
        -- Name-ordered, like the album shelf: load_followed_artists ends on
        -- Util.lib_sorted.
        Util.shelf_splice("followed_artists", P.artists, artist, follow,
                          {sort = Util.lib_sorted})
        return true
    end
    return false
end

-- Takes the ITEM, not an id: the endpoint wants a URI and the local mirror now
-- stores one, and neither can be built from an id alone once episodes exist.
local function do_add_queue(item)
    local uri = Util.item_uri(item)
    if not uri then ui_say("Nothing to queue"); return end
    local token = get_token()
    if not token then ui_say("Cannot add to queue: no token"); return end
    -- A BODYLESS POST, and it must SAY that its body is empty. `len0` is the
    -- flag Util.api_write carries for exactly this (see its header) and
    -- do_playback_cmd -- the only other bodyless POST in the file -- has always
    -- passed it; this one never did.
    --
    -- That was not the whole of "can't add to queue", and the measurement is
    -- worth keeping: with it, curl added the track and the NATIVE transport
    -- still came back 400, on the same URL, with and without the flag. `len0`
    -- only reaches curl -- it is a header, and Qt was sending the request with
    -- no body device at all, so no Content-Length went out however it was asked
    -- for. See l_http in src/main.cpp, which is where that was fixed.
    -- SPOOT_FORCE_CURL=1 is what tells the two apart, and it earned itself here.
    --
    -- ...and the DEVICE, for the reason do_playback_cmd names it: the endpoint
    -- acts on whatever Spotify currently calls active, which after a pause is
    -- nothing at all. Naming spotifyd puts the track in the queue of the player
    -- the rest of the app is driving.
    local device_id = get_spotifyd_device()
    local url = "https://api.spotify.com/v1/me/player/queue?uri=" .. uri
        .. (device_id and ("&device_id=" .. device_id) or "")
    local r = Util.api_write("POST", url, token, {len0=true})
    if not Util.is2xx(r) then ui_say("Failed to add to queue"); return end
    mem_bust("queue")
    -- also add to local queue tracking
    if not queue_tracks then queue_tracks = {}; queue_idx = 0 end
    queue_tracks[#queue_tracks+1] = uri
    flush_queue()
    -- SAID SO. Every other verb in an action menu answers -- Added to playlist,
    -- Deleted, Renamed -- and this one did its work in silence, which from the
    -- outside is indistinguishable from the failure it actually was.
    ui_say("Added to queue")
end

-- Save or unsave one library item. `kind` keys P.lib_kinds, which is where the
-- endpoint and the two caches to bust live, so albums and podcasts share this
-- rather than each carrying a save/remove pair of their own -- the shape the
-- album version grew into when removing was made reachable from an album's own
-- action menu instead of only from the Saved Albums list.
-- `item` is the object the id names, when the caller has it. Supplying it is
-- what lets the cached shelf be amended instead of deleted; see Util.shelf_splice
-- for why deleting it left the Saved Albums and Podcasts tiles stale.
function Util.lib_write(kind, id, save, item)
    local k = P.lib_kinds[kind]
    if not (k and id) then return false end
    local token = get_token()
    if not token then
        ui_say("Cannot " .. (save and "save " or "remove ") .. k.noun .. ": no token")
        return false
    end
    local url = "https://api.spotify.com/v1/" .. k.ids .. "?ids=" .. id
    local r = Util.api_write(save and "PUT" or "DELETE", url, token)
    if Util.is2xx(r) then
        -- Both shelves are name-ordered (Util.lib_sorted, in their loaders), so
        -- the spliced list comes out in the order a fresh page would.
        Util.shelf_splice(k.mem, k.file, item, save, {sort = Util.lib_sorted})
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
    if not token then ui_say("Cannot save playlist: no token"); return false end
    local url = "https://api.spotify.com/v1/playlists/" .. playlist_id .. "/followers"
    local r = Util.api_write("PUT", url, token, {len0=true})
    if Util.is2xx(r) then
        -- Bare on purpose: this path has a playlist ID and nothing else, so
        -- there is no object to splice into the shelf and the bust is the
        -- honest answer. Every other caller passes one.
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
    -- ...and it is dispatched on by a STABLE key per row rather than by the
    -- visible label. Row 2 flips between Save and Remove with the library state,
    -- so a branch that matched the words had to carry both of them.
    local is_saved = Util.lib_has("album", album.id)
    local acts  = {"Open Album", is_saved and "Remove from Saved Albums" or "Save Album",
                   "Albumart", "Copy Web Link", "Album Details"}
    local akeys = {"open", "save", "art", "url", "details"}
    if (album.artists or {})[1] then
        table.insert(acts, 2, "Go to Artist")
        table.insert(akeys, 2, "artist")
    end
    -- A CURSOR MEMORY STOOD HERE: pos_row on the way in, pos_put on the way out,
    -- around a `pre_sel` that was handed to nothing. It is rofi's, and it had to
    -- exist there -- a menu was a process that had just started, so the engine
    -- was the only thing that could say which row to land on. The card is a live
    -- list that never goes away between picks and keeps its own cursor. Every
    -- pick was paying a JSON encode and a disk write for a value nobody read --
    -- and `akeys`, which existed only to feed it, is now what the dispatch runs
    -- on instead.
    local mesg = (album.name or "Album") .. album_suffix(album)
    -- Claimed only for the Go to Artist row, which offers the artist's hub on
    -- Shift+Return and their discography on Return. Every other row treats the
    -- two alike -- the default handler was a silent no-op here anyway, since
    -- this menu passes neither `current` nor `items`.
    local action = ui_menu(acts,
        {prompt=album.name or "Album", mesg=mesg, theme=THEME_SUB,
         context=true, art=false, alt_select=true})
    local alt = Util.alt_pressed
    Util.alt_pressed = false
    local key
    for i, a in ipairs(acts) do if a == action then key = akeys[i]; break end end
    -- WHAT IT DID, for a caller that has to act on it. Saved Albums had its own
    -- inline copy of this whole menu -- six rows and six branches -- for the sake
    -- of one thing the shared one could not tell it: that the album had just been
    -- unsaved, so the row has to come off the list. Answering that here is the
    -- whole of what the copy was for. (See view_browse, which had also quietly
    -- drifted: its Go to Artist took artists[1] outright, so a collaboration in
    -- Saved Albums could only ever reach one of its artists.)
    local removed = false
    if key == "save" then
        if is_saved then
            local ok = Util.lib_write("album", album.id, false, album)
            ui_say(ok and "Removed from Saved Albums" or "Failed to remove album")
            removed = ok and true or false
        else
            ui_say(Util.lib_write("album", album.id, true, album)
                and "Album saved" or "Failed to save album")
        end
    elseif key == "url" then
        copy_spotify_url("album", album.id)
        Util.copied_link()
    elseif key == "artist" then
        -- artists[1] used to be taken outright, which on a collaboration meant
        -- one name won and the rest were unreachable. Same picker the track menu
        -- has always had -- see Util.go_to_artist.
        Util.go_to_artist(album.artists, album.name, alt)
    elseif key == "art" then
        view_art({album=album, name=album.name, artists=album.artists})
    elseif key == "details" then
        Util.view_album_details(album)
    end
    return key == "open", removed
end

-- album_action_menu's shape for podcasts, down to the stable-key cursor: row 2
-- flips between Follow and Unfollow with the library state, so remembering the
-- cursor by the visible label would drop it back to the top the moment the row
-- was relabelled. Returns whether the caller should open the show, which is the
-- contract album_action_menu and playlist_action_menu already answer with.
function Util.show_action_menu(show)
    local followed = Util.lib_has("show", show.id)
    -- The LABEL is state: it says Watch only for a show Spotify marks as
    -- carrying video. It used to have to be held in a local so the dispatch
    -- could compare against the same value; the dispatch runs on the row's key
    -- now, so this is simply the label.
    local watch = Util.watch_label(Util.is_video_show(show))
    local acts  = {"Open Podcast", followed and "Unfollow Podcast" or "Follow Podcast",
                   "Podcast Art", "Copy Web Link", watch, "Podcast Details"}
    local akeys = {"open", "follow", "art", "url", "watch", "details"}
    -- A CURSOR MEMORY STOOD HERE: pos_row on the way in, pos_put on the way
    -- out, around a `pre_sel` that was handed to nothing. It is rofi's, and it
    -- had to exist there -- a menu was a process that had just started, so the
    -- engine was the only thing that could say which row to land on. The card
    -- is a live list that never goes away between picks and keeps its own
    -- cursor. Every pick was paying a JSON encode and a disk write for a value
    -- no one would ever read.
    local action = ui_menu(acts,
        {prompt=show.name or "Podcast", mesg=Util.display_show(show),
         theme=THEME_SUB, context=true, art=false})
    -- ON THE KEY, not the label. Two of the six rows are state -- Follow flips to
    -- Unfollow, and the Watch row is named by Util.watch_label -- so a branch
    -- matching words needed a case for each spelling and a local to hold the
    -- third. `akeys` already named every row and was read by nothing but the
    -- cursor memory above.
    local key
    for i, a in ipairs(acts) do if a == action then key = akeys[i]; break end end
    if key == "follow" then
        if followed then
            ui_say(Util.lib_write("show", show.id, false, show)
                and "Podcast unfollowed" or "Failed to unfollow podcast")
        else
            ui_say(Util.lib_write("show", show.id, true, show)
                and "Podcast followed" or "Failed to follow podcast")
        end
    elseif key == "url" then
        copy_spotify_url("show", show.id)
        Util.copied_link()
    elseif key == "watch" then
        -- The only route to a video episode there is: Spotify's own player.
        -- spoot cannot play one -- the video stream is DRM'd and separate from
        -- the audio librespot implements.
        Util.open_in_spotify("show", show.id)
    elseif key == "art" then
        view_art(show)
    elseif key == "details" then
        Util.view_show_details(show)
    end
    return key == "open"
end

local function playlist_action_menu(pl)
    local acts = {"Open Playlist", "Save Playlist", "Playlist Art", "Copy Web Link"}
    -- A CURSOR MEMORY STOOD HERE: pos_row on the way in, pos_put on the way
    -- out, around a `pre_sel` that was handed to nothing. It is rofi's, and it
    -- had to exist there -- a menu was a process that had just started, so the
    -- engine was the only thing that could say which row to land on. The card
    -- is a live list that never goes away between picks and keeps its own
    -- cursor. Every pick was paying a JSON encode and a disk write for a value
    -- no one would ever read.
    local action = ui_menu(acts,
            {prompt=display_playlist(pl), mesg=display_playlist(pl) .. SEP .. (pl.owner and pl.owner.display_name or "Unknown owner"), theme=THEME_SUB, context=true, art=false})
    if action == "Playlist Art" then
        view_art(pl)
    elseif action == "Save Playlist" then
        ui_say(do_save_playlist(pl.id) and "Playlist saved" or "Failed to save playlist")
    elseif action == "Copy Web Link" then
        copy_spotify_url("playlist", pl.id)
        Util.copied_link()
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
        local uris, pos = Util.play_window(queue_tracks, new_idx)
        if #uris > 0 then body = json.encode({uris=uris, offset={position=pos}}) end
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
        end, {revalidate = "show_resume", revalidate_arg = show_id})
    if type(fresh) ~= "table" then return eps end
    for _, e in ipairs(eps) do
        if e.id and fresh[e.id] then e.resume_point = fresh[e.id] end
    end
    return eps
end

Util.REVALIDATORS.show = function(show_id)
    if show_id and #show_id > 0 then return Util.api_get_show(show_id) end
end

-- A 300s TTL with no revalidate meant nearly every RE-open of a podcast blocked
-- on a fresh page of 50 episodes, for a progress number. Serving the last one
-- and refreshing behind the menu is the whole point of the short TTL.
Util.REVALIDATORS.show_resume = function(show_id)
    if not (show_id and #show_id > 0) then return end
    -- Reached through merge_resume_points because the fetch lives inside it;
    -- the episode list it is handed is a throwaway, only there to satisfy the
    -- signature -- what matters is the cached_fetch it performs on the way.
    Util.merge_resume_points(show_id, {{id = ""}})
end

-- The aligned label/value sheet behind Album and Track Details, which carried
-- byte-identical copies of the row builder, skip-empties wrapper and artist
-- collapse. add() drops nil and empty values, making most callers' `if d.x`
-- guards redundant -- kept only where a guard maps a value (explicit -> "yes")
-- or reaches through an absent table. Popularity 0 still shows: "0" isn't "".
-- `theme` overrides the sheet's window only -- every caller shares the same row
-- builder, so an album sheet and a podcast sheet cannot drift in how they render
-- a field. Defaults to THEME_META.
--
-- `title` is what the sheet CALLS itself, on the bar across its top -- the same
-- bar the art viewer and every card wear. A sheet is a floating card now, and a
-- card with no title is a slab of text with no idea what it is about.
function Util.detail_sheet(theme, title)
    -- PAIRS, not padded strings. This built its label column by repeating spaces
    -- to width 15 because rofi is handed one blob of text and lays out nothing;
    -- a long label simply collided with its value. The pairs were always here --
    -- every caller writes s.add("Label", value) -- they were just flattened away
    -- at the end. Keeping them lets the front end lay out two real columns with
    -- the same renderer the keybind sheet uses.
    local pairs_ = {}
    local s = {}
    function s.add(label, val)
        if val == nil then return end
        val = tostring(val)
        if val == "" then return end
        pairs_[#pairs_+1] = {key = label, desc = val}
    end
    function s.artists(list)
        local names = {}
        for _, ar in ipairs(list or {}) do
            if ar.name and ar.name ~= "" then names[#names+1] = ar.name end
        end
        if #names > 0 then s.add("Artists", table.concat(names, ", ")) end
    end
    -- WHERE IT LIVES AND WHAT THE API CALLS IT. The last two rows of every one of
    -- the four sheets, written out four times -- so a change to how a link is
    -- read, or a decision to stop printing raw ids, had four places to reach and
    -- would have been found in three of them.
    --
    -- Any code the item carries goes with them, because a UPC, an ISRC and an id
    -- are the same kind of row: the thing's names in other people's systems.
    function s.link(d, codeLabel, code)
        s.add(codeLabel, code)
        s.add("URL", d.external_urls and d.external_urls.spotify)
        s.add("ID", d.id)
    end
    function s.show()
        if #pairs_ == 0 then
            ui_say("No details available", theme or THEME_META)
            return
        end
        -- Same shape the keybind sheet sends, so one renderer draws both.
        Util.serve_write({ev = "sheet", kind = "details",
                          theme = (theme or THEME_META),
                          title = title or "Details", rows = pairs_})
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
        ui_say("Could not load album details")
        return
    end
    local s = Util.detail_sheet(nil, "Album Details")
    s.add("Name", d.name)
    s.artists(d.artists)
    s.add("Type", d.album_type)
    s.add("Release date", d.release_date)
    s.add("Total tracks", d.total_tracks)
    s.add("Label", d.label)
    if d.genres and #d.genres > 0 then s.add("Genres", table.concat(d.genres, ", ")) end
    s.add("Popularity", d.popularity)
    s.link(d, "UPC", d.external_ids and d.external_ids.upc)
    s.show()
end

-- Cached like every other per-id lookup here (see api_get_album). A track's
-- metadata does not change, so a day is generous rather than risky, and opening
-- the same sheet twice stopped costing two round trips.
-- On Util, not a local: the chunk body is at Lua's 200-local cap, so a
-- file-scope `local function` here does not compile.
Util.api_get_track_detail = function(id)
    if not id or #id == 0 then return nil end
    return cached_fetch("track_detail_" .. id, P.mass .. "/track_detail_" .. id .. ".json",
        CACHE_TTL_LONG, function()
            return api_get("tracks/" .. id, Util.with_market())
        end, {revalidate = "track_detail", revalidate_arg = id})
end
Util.REVALIDATORS.track_detail = function(id)
    if id and #id > 0 then return Util.api_get_track_detail(id) end
end

Util.view_track_details = function(item)
    local d = Util.api_get_track_detail(item.id)
    if not d then
        ui_say("Could not load track details")
        return
    end
    local s = Util.detail_sheet(nil, "Track Details")
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
    s.link(d, "ISRC", d.external_ids and d.external_ids.isrc)
    s.show()
end

-- Both sheets below reuse Util.detail_sheet unchanged; s.artists simply goes
-- unused, since neither a show nor an episode has any.
Util.view_show_details = function(show)
    local d = Util.api_get_show(show.id)
    if not d then
        ui_say("Could not load podcast details")
        return
    end
    local s = Util.detail_sheet(Util.THEME_PODS, "Podcast Details")
    s.add("Name", d.name)
    s.add("Publisher", d.publisher)
    s.add("Episodes", d.total_episodes or (d.episodes and #d.episodes))
    -- Was `s.add("Type", d.media_type)`, which spent a line printing the raw
    -- field name -- "Type audio" says nothing, and "Type mixed" only says
    -- something if you already know Spotify's word for it. Named for what it
    -- tells you, and absent entirely on an audio-only show (s.add drops a nil).
    s.add("Video", d.media_type == "mixed" and "some episodes" or nil)
    s.add("Languages", d.languages and #d.languages > 0 and table.concat(d.languages, ", ") or nil)
    -- s.add drops a nil, which is what every other line here relies on -- so the
    -- `if` this used to be was the one row testing for itself.
    s.add("Explicit", d.explicit and "yes" or nil)
    s.add("Description", d.description)
    s.link(d)
    s.show()
end

-- Same treatment as api_get_track_detail above, and for the same reason: the
-- sheet is a read of fixed metadata, so it belongs on disk rather than on the
-- wire every time it is opened.
Util.api_get_episode_detail = function(id)
    if not id or #id == 0 then return nil end
    return cached_fetch("episode_detail_" .. id, P.mass .. "/episode_detail_" .. id .. ".json",
        CACHE_TTL_LONG, function()
            return api_get("episodes/" .. id, Util.with_market())
        end, {revalidate = "episode_detail", revalidate_arg = id})
end
Util.REVALIDATORS.episode_detail = function(id)
    if id and #id > 0 then return Util.api_get_episode_detail(id) end
end

Util.view_episode_details = function(item)
    local d = Util.api_get_episode_detail(item.id)
    if not d then
        ui_say("Could not load episode details")
        return
    end
    local s = Util.detail_sheet(Util.THEME_PODS, "Episode Details")
    s.add("Name", d.name)
    s.add("Podcast", d.show and d.show.name)
    -- Free: the full episode fetch already carries its show, and that object
    -- carries media_type. Worded about the PODCAST on purpose -- no field
    -- anywhere says whether THIS episode is one of the video ones.
    s.add("Video", d.show and d.show.media_type == "mixed"
                   and "podcast has video episodes" or nil)
    s.add("Release date", d.release_date)
    s.add("Duration", Util.dur_short(d.duration_ms))
    -- Reads the same resolver the list rows do, so the sheet and the row can
    -- never disagree about how far in you are.
    local pos, done = Util.episode_progress(d)
    if done then s.add("Progress", "played")
    elseif pos > 0 then s.add("Progress", Util.dur_short(pos) .. " in") end
    -- s.add drops a nil, which is what every other line here relies on -- so the
    -- `if` this used to be was the one row testing for itself.
    s.add("Explicit", d.explicit and "yes" or nil)
    s.add("Description", d.description)
    s.link(d)
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
        tracks = pl.tracks and {total = tonumber(pl.tracks.total)} or nil
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
-- A P.mass filename for a cache keyed by ARBITRARY TEXT rather than by an id --
-- a query, a recommendation seed. A sanitised prefix for legibility plus a djb2
-- hash of the WHOLE key, so a collision needs both to match rather than just 32
-- bits.
--
-- `prefix` is what keeps two such caches apart on disk, and it is load-bearing:
-- Util.drop_search_cache globs search_*.json on the way out, so anything meant
-- to survive an exit has to be filed under a name of its own.
function Util.mass_path(prefix, key)
    local tag = key:gsub("[^%w]", "_"):sub(1, 32)
    return P.mass .. "/" .. prefix .. "_" .. tag .. "_"
        .. string.format("%08x", Util.djb2(key)) .. ".json"
end

function Util.search_cache_path(key) return Util.mass_path("search", key) end

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
    {key = "episodes",  t = "episode"}
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
--
-- `thumbs` draws the page as a thumbnail grid instead of a list, and
-- `thumb_kind` is the Util.album_thumbs kind for it -- nil meaning the
-- hash-keyed album pool, exactly as an album grid passes. Only the pages whose
-- rows are all CONTAINERS get one: All and Tracks stay lists because a track has
-- no cover of its own worth a 150px tile, and All mixes six kinds whose rows
-- would have nothing in common but their size.
--
-- This is also what keeps a search from fetching artwork it was never asked for.
-- A new query opens on All, which is not a grid, so submitting one costs no
-- image requests at all; the covers for a type are fetched the moment you filter
-- to it and not before.
Util.SEARCH_PAGES = {
    {key = "all",       label = "All",                             icon = false},
    -- `backdrop`: the only results page that wears one. See
    -- Util.search_page_art -- and the pages either side of it for why it is the
    -- only one that can.
    {key = "tracks",    label = "Tracks",    keys = {"tracks"}, backdrop = true},
    {key = "albums",    label = "Albums",    keys = {"albums"},    thumbs = true},
    {key = "artists",   label = "Artists",   keys = {"artists"},   thumbs = true,
     thumb_kind = "artist"},
    {key = "playlists", label = "Playlists", keys = {"playlists"}, thumbs = true,
     thumb_kind = "playlist"},
    {key = "podcasts",  label = "Podcasts",  keys = {"shows", "episodes"}, icon = "shows",
     thumbs = true, thumb_kind = "show"},
    -- `filter` is the only thing here that selects by something other than TYPE:
    -- a predicate every row of the page has to pass. Sits after Podcasts because
    -- it is a slice of it -- the same shows, minus the ones Spotify does not mark
    -- as carrying video.
    --
    -- SHOWS ONLY, and it cannot be otherwise: an episode in a search response
    -- carries no `show`, and the API has no per-episode video field to consult,
    -- so no episode row can ever be known to belong here.
    {key = "video",     label = "Video",     keys = {"shows"},
     thumbs = true, thumb_kind = "show", filter = Util.is_video_show}
}

-- The glyph standing for a page, or "" for one that has none (All spans every
-- type). Shared so the type picker's rows and the results header cannot end up
-- marking the same page differently.
function Util.search_page_icon(page)
    local pg = Util.SEARCH_PAGES[page]
    if not pg or pg.icon == false then return "" end
    return Util.type_icon(pg.icon or pg.key)
end

-- Is this page a grid, and of what kind? Looked up BY KEY rather than by index
-- because view_browse receives the key as its ctx_id and has no index to hand.
function Util.search_page_grid(key)
    for _, pg in ipairs(Util.SEARCH_PAGES) do
        if pg.key == key then return pg.thumbs == true, pg.thumb_kind end
    end
    return false, nil
end

-- WHETHER THIS PAGE OF RESULTS IS ABOUT SOMETHING YOU CAN PICTURE. Search as a
-- whole is not -- All mixes six kinds of row, and a cover beside it would be a
-- picture of whichever one happened to sort first -- which is why the results
-- list has worn no backdrop at all.
--
-- Tracks is the exception and the only one: every row is a track, they all have
-- album art, and a list of tracks is exactly the thing the backdrop was built
-- for everywhere else in spoot. The grids need no such thing -- every row there
-- is already a picture.
--
-- Read off the page table rather than compared against "tracks" here, so the
-- fact lives beside the page it is about.
function Util.search_page_art(key)
    for _, pg in ipairs(Util.SEARCH_PAGES) do
        if pg.key == key then return pg.backdrop == true end
    end
    return false
end

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
    -- One curl for all of them, the same transport the covers, the library sync
    -- and Util.paged_fetch use. The chunking loop this replaces existed to bound
    -- how many curl PROCESSES ran at once; --parallel-max bounds requests
    -- instead, without the fork-per-query.
    local jobs = {}
    for _, w in ipairs(want) do
        jobs[#jobs+1] = {url = Util.api_url("search", w.params), out = w.tmp}
    end
    Util.curl_batch(jobs, {compressed = true, parallel = 8, timeout = 15, header = auth})
    for _, w in ipairs(want) do
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
    return cached_fetch("my_playlists", P.my_playlists, CACHE_TTL_SHORT, function()
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
    local pidf = P.plindex_pid
    if Util.job_running(pidf, "--prefetch-plindex") then return end
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
    local pidf = P.reval_pid .. name:gsub("[^%w_]", "")
        .. (arg2 and ("_" .. tostring(arg2):gsub("[^%w_]", "")) or "") .. ".pid"
    if Util.job_running(pidf, "--revalidate") then return end
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
            -- The cap is opts.max rather than a counter inside `done`, so the
            -- pager knows it BEFORE it decides how many pages to ask for -- an
            -- account with thousands of top artists would otherwise put every
            -- page in flight to read the first hundred.
            local all = Util.paged_fetch("me/top/artists",
                function(o) return "limit=50&offset=" .. o .. "&time_range=" .. rng end,
                function(d, items) return #items == 0 or not d.next end,
                nil, {max = P.top_max})
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
    if not ar or #ar == 0 then ui_say("No top artists"); return end
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
-- Cached like every other menu loader, which it was not: this was the ONE
-- menu-opening loader in the file that went straight to api_get, so More Like
-- This and every genre shelf paid ~0.75s on every open -- first visit, reopen in
-- the same session, and again on each warm-start replay through
-- reg("genre-tracks") / reg("recommendations"). Two round trips whenever the
-- response comes back with stubs, since the repair below is serial.
--
-- The TTL is an hour rather than a day because /recommendations is the one
-- endpoint here that does not answer the same thing twice: two calls a second
-- apart with the same seed shared 4 tracks out of 50. So the cache decides how
-- often the list turns over, not just how fast it opens. An hour of the same
-- picks is the trade -- and `revalidate` means the wait is never paid again
-- anyway, since an expired copy draws immediately while a detached process
-- fetches the next one.
--
-- Keeping the list still also fixes something that was never a "slowness" bug:
-- reopening used to hand back 50 different tracks, so the remembered cursor
-- landed on an unrelated row every time.
--
-- The stub repair stays INSIDE the fetch, so it only costs a request on a real
-- miss.
local function api_get_recommendations(seed)
    if not seed or #seed == 0 then return nil end
    return cached_fetch("recs_" .. seed, Util.mass_path("recs", seed), CACHE_TTL_MED, function()
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
    end, {stale_ok = true, revalidate = "recommendations", revalidate_arg = seed})
end

-- Parameterised like category_playlists and show_latest: the seed is the whole
-- seed_* parameter, and Util.spawn_self shell-quotes it, so the `=` and any %xx
-- from url_encode survive the trip to the detached process intact.
Util.REVALIDATORS.recommendations = function(seed)
    if seed and #seed > 0 then return api_get_recommendations(seed) end
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
            -- Util.paged_fetch rather than hand-rolling another offset loop.
            -- opts.max is what stops it, since the account reports 1578
            -- available and only P.top_max of them are ever read -- see the note
            -- at the top-artists caller for why that is a cap the pager is told
            -- rather than one hidden in `done`.
            local all = Util.paged_fetch("me/top/tracks",
                function(o) return Util.with_market("limit=50&offset=" .. o .. "&time_range=" .. rng) end,
                function(d, items) return #items == 0 or not d.next end,
                nil, {max = P.top_max})
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
--   recommendations / show_resume -- registered at their sites, like the three
--     above, because they take a parameter.
--
-- And the loaders that are deliberately not cached AT ALL, named here so the
-- next reader can see they were weighed rather than missed: the queue and
-- me/player are live transport state, and a cached one is simply a wrong one;
-- Util.lib_probe exists to ask whether a cache is stale; open_url and
-- listen_lookup are one-shot resolvers rather than menus; api_get_tracks only
-- ever runs inside another loader's fetch.
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
    genre_seeds       = function() return Util.api_get_genre_seeds() end
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
    local r = Util.http{url = url, compressed = true, timeout = 5}
    return r.body, r.code
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
    -- Which slice of a search this is, and whether that slice draws as a grid.
    -- ctx_id IS the page key (see Util.open_search_results), so the page's own
    -- table answers both without view_browse learning anything about search
    -- beyond the lookup. false/nil for every list that is not a search.
    local is_search_grid, search_thumb_kind = false, nil
    if is_search then is_search_grid, search_thumb_kind = Util.search_page_grid(ctx_id) end
    -- ...and whether it is the one page that wears a cover. See
    -- Util.search_page_art.
    local is_search_art = is_search and Util.search_page_art(ctx_id)
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
    -- Left nil so ui_menu's pos_key restores the remembered row. It is only
    -- assigned to force a specific row (jump-to-playing-track, or holding the
    -- cursor after a selection); an explicit sel always wins over pos_key.
    local pre_sel = nil
    -- A <close> GUARD STOOD HERE unlinking `album_theme` on the way out, from
    -- the days when that held the path to a per-call .rasi. It has held the
    -- string "album" since rofi went -- so what ran at the end of every album,
    -- playlist and show list was os.remove("album"), against whatever directory
    -- spoot happened to be started in. It never found anything; it was also
    -- never going to, and it is the last of the seven the action menu's note
    -- below describes.
    local album_theme = nil
    if art_path then
        -- A cover the CALLER resolved -- a playlist's own artwork. Same album
        -- backdrop, but the image must not come from items[1], which for a
        -- playlist is merely its first track and has nothing to do with the
        -- playlist. An empty path is meaningful: it says "no cover", so an
        -- artless list still gets the layout.
        Util.serve_cover(art_path)
        album_theme = THEME_ALBUM
    end
    -- THE FIRST RESULT IS WHAT A TRACKS SEARCH IS ABOUT, until you pick
    -- something. It is the row under the cursor when the page opens and the one
    -- Return takes, so it is the honest subject of a list that has no container
    -- to borrow a picture from -- and items[1] being merely the first track is
    -- the objection to doing this for a PLAYLIST, where the list is about the
    -- playlist. Here there is nothing else it could be about.
    --
    -- No theme with it: the results list keeps THEME_RESULTS, which is the
    -- two-column layout these rows are written for. art_path above is a
    -- container handing over its sleeve and changes the layout to match; this
    -- only names a picture.
    --
    -- Recorded as a URL rather than fetched, so the rows go out now and the
    -- cover follows -- see Util.serve_cover. Once a step picks a row, ui_menu
    -- clears this and the picked track becomes the subject; once something from
    -- this list is playing, Util.serve_shelf hands the backdrop to the playback
    -- poll and it follows the music with no draw at all.
    if is_search_art and not art_path then
        local first = items and items[1]
        local alb = first and (first.type == nil or first.type == "track")
                    and first.album or nil
        local u = alb and alb.images and alb.images[1] and alb.images[1].url or nil
        if u then Util.serve_cover(Util.ensure_art_med(u, true), u) end
    end
    -- The theme this list actually draws with; nil for everything else, which
    -- lets ui_menu fall back to its usual thumbs/plain-list selection.
    -- `searchall` is the MIXED results layout: two columns of text, sized for
    -- rows that name their own kind. A page filtered to one kind of container is
    -- a grid instead, so it names no theme here and falls through to
    -- ui_menu's thumbs/plain selection like every other grid.
    local view_theme = album_theme
        or (is_search and not is_search_grid and Util.THEME_RESULTS) or nil
    -- Regenerates rows carrying live state (▶ marker, liked heart). Handed to
    -- ui_menu as `refresh` so a redraw from inside -- a track played or liked
    -- in a hotkey-opened action menu -- shows the new state. Album, artist and
    -- playlist rows have no such state and are left alone, which also preserves
    -- album_thumbs' \0icon suffixes. Must match the flags the caller built
    -- `entries` with, or the first refresh re-renders differently.
    -- ...and the same for an artist's slice of it. Both are lists OF likes, so
    -- the heart is a column of one repeated glyph. Must match the flags the
    -- caller built `entries` with -- see fetch_liked_by_artist, which now passes
    -- the same -- or the first refresh re-renders differently.
    local hide_liked = (ctx == "liked" or ctx == "liked-by-artist") or nil
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
        -- ui_menu resolves it, so the covers fetched before the draw are the
        -- ones about to be rendered.
        local at = pre_sel or Util.pos_get(v_key)
        if is_album_grid then Util.album_thumbs(entries, items, nil, at, v_key)
        elseif is_artist_list then Util.album_thumbs(entries, items, "artist", at, v_key)
        elseif is_playlist_list then Util.album_thumbs(entries, items, "playlist", at, v_key)
        -- "show" rather than the default "album": shows are hash-keyed like
        -- albums (they are absent from P.art_kinds on purpose), but the kind is
        -- part of Util._thumb_memo's key, so naming it keeps a show grid's memo
        -- from colliding with an album grid's.
        elseif is_show_grid then Util.album_thumbs(entries, items, "show", at, v_key)
        -- The kind comes from the page, not from the ctx: a filtered search is
        -- six different grids sharing one ctx, and the kind is what keys both the
        -- art cache and Util._thumb_memo.
        elseif is_search_grid then Util.album_thumbs(entries, items, search_thumb_kind, at, v_key) end
        return entries
    end
    while true do
        -- ctx_type/ctx_id/entries ride along so Shift+Return hands the action
        -- menu the list it came from -- that is what offers Remove from Playlist
        -- for the playlist being browsed, and drops the row after removal.
        -- Album/artist/playlist rows open content on Return and actions on
        -- Shift+Return, so those lists claim the key. An album's TRACK list is
        -- is_album_list too, but is_track wins the dispatch and keeps the default.
        -- THIS MENU NAMED A COVER OF ITS OWN. art_path is how a container hands
        -- one over -- an album's sleeve, a playlist's tile, a podcast's art -- and
        -- it is the whole of what separates a container from a shelf. See
        -- Util.serve_shelf, which used to ask instead whether ctx_type was
        -- "album" and then "album or playlist", a list that could only ever grow
        -- and had already missed shows: a show's episode list passes no ctx_type
        -- at all, deliberately, so it was never going to match.
        local idx = ui_menu(entries, {prompt=ctx or "Browse", mesg=mesg, by_index=true, theme=view_theme, thumbs=is_album_grid or is_playlist_list or is_show_grid or is_artist_list or is_search_grid, items=items, entries=entries, ctx_type=ctx_type, ctx_id=ctx_id, refresh=rebuild, own_art=(art_path ~= nil or is_search_art) or nil,
            -- is_show_grid claims Shift+Return for the show action menu. The
            -- EPISODE list deliberately does not: it is is_track, and a track
            -- list must leave Shift+Return to ui_menu's default handler,
            -- which is what routes an episode to its own action menu.
            -- The search list claims Tab for its type picker, so it must not
            -- bubble up as the trail jump. Same opt-in the trail menu itself
            -- uses; every other list here leaves Tab alone.
            tab_select=is_search or nil,
            -- NO BACKDROP ON SEARCH RESULTS. A results list is not about any one
            -- thing -- All mixes six kinds of row, and Tracks is a list you are
            -- scanning rather than a place you are in -- so a cover beside it is
            -- either whatever happens to be playing or a picture that changes
            -- under the cursor while you read. `not`, rather than `and false or
            -- nil`: false is the value that idiom cannot carry, and Util.serve_draw
            -- forwards only false.
            -- ...EXCEPT the Tracks page, which does have a subject and says so
            -- through Util.search_page_art. Everything the paragraph above says
            -- about a results list is about the pages that mix kinds or draw as
            -- grids; a column of tracks is not one of those.
            art=(not is_search) or is_search_art,
            alt_select=((is_album_list and not is_track) or is_artist_list or is_playlist_list or is_search or is_show_grid) or nil})
        -- Read before anything else: the next ui_menu call clears the flag.
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
            -- An album grid's rows are ALBUMS, so the track id this matched
            -- against could never be one of them: every Alt+c in Saved Albums
            -- fell through to the old `pre_sel = 0` and threw the cursor to the
            -- top of the grid. Ask for the playing track's album there instead.
            --
            -- pre_sel is left untouched when there is no answer -- nothing
            -- playing, or its album is not on this list -- so the cursor stays
            -- where it was rather than moving somewhere arbitrary.
            local row = Util.row_of_id(items,
                is_album_grid and Util.current_album_id() or current_id)
            if row then pre_sel = row end
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
                -- so a track row has to reproduce what ui_menu's default
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
            --
            -- Except on a grid page, where that repaint would drop the
            -- \0icon suffix Util.album_thumbs appended and blank the tile for the
            -- rest of the window's life. rebuild() re-renders AND re-decorates,
            -- which is what the show grid's arm relies on too.
            if not playable then
                if is_search_grid then rebuild()
                else entries[idx] = Util.format_mixed_item(item, idx) end
                pre_sel = idx - 1
            end
        elseif is_album_list then
            -- Return opens the album; only Shift+Return detours through an
            -- action menu.
            local do_open = not alt
            -- Set by the action menu's "Open Album" row. Kept apart from do_open
            -- because the two mean different things: plain Return on a single
            -- plays it, asking for the album by name opens it.
            local from_menu = false
            if alt then
                -- ONE ALBUM ACTION MENU. A second copy of it lived here, for
                -- Saved Albums alone, because that list has to drop a row when
                -- the album is unsaved -- and the shared menu had no way to say
                -- that it had been. It says so now (see album_action_menu's
                -- second return), so the copy is gone and with it the drift it
                -- had accumulated: a different label for the same verb, and a
                -- Go to Artist that could not offer a collaborator.
                local removed
                do_open, removed = album_action_menu(item)
                from_menu = do_open
                if jump_to_track_pending then return end
                if removed and ctx == "album-list" then
                    table.remove(items, idx)
                    entries = Util.album_entries(items)
                    mesg = "Saved Albums" .. SEP .. #items .. " albums"
                    if #items == 0 then return end
                    goto br_next
                end
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
        -- No row rewrite, for the reason the show grid states below: these rows
        -- now carry \0icon suffixes from Util.album_thumbs. The line that used to
        -- sit here rebuilt the row from display_artist -- which is the same
        -- string the caller already built, since an artist row has no live state
        -- to re-render -- and its `ctx == "artist"` arm was unreachable, this
        -- branch only running when ctx is "artist-list". Dead then, and it would
        -- have eaten the thumbnail now.
        elseif is_artist_list then
            Util.open_artist(item, alt)
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
    if not ad then ui_say("Failed to load album"); return false end
    if not ad.tracks or #ad.tracks == 0 then
        local mk = Util.market()
        ui_say("Album has no available tracks" .. (mk and (" in " .. mk) or ""))
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
    -- The album's OWN cover, from the album object this function already
    -- fetched. view_browse used to derive it from items[1].album instead, but
    -- /albums/{id}/tracks answers with simplified tracks that carry no album at
    -- all -- so the backdrop was nil for every album ever opened. The art_path
    -- parameter is how a playlist has always passed its own artwork; this is the
    -- same road, not a second one.
    local cover = ad.images and ad.images[1] and Util.ensure_art_med(ad.images[1].url) or nil
    view_browse(te, ad.tracks, mesg, "album", "album", album_id, nil, cover)
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
    if not sd then ui_say("Failed to load podcast"); return false end
    local eps = sd.episodes or {}
    if #eps == 0 then
        local mk = Util.market()
        ui_say("Podcast has no available episodes" .. (mk and (" in " .. mk) or ""))
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

-- Tracks and albums carry their art on `item.album.images`; a playlist and an
-- artist carry their own on `item.images`, and it is the PLAYLIST's cover that
-- must show, not the first track's. `item.owner` marks that case: a playlist has
-- no artists, so it captions itself with who made it. An artist says so on
-- `item.type`, and gets its own card -- "Artist Impression" on THEME_IMP.
view_art = function(item)
    local is_artist = item and item.type == "artist" or false
    -- Names what is actually missing. Both guards below said "album art" for
    -- everything, which reads wrong on a menu whose row is called Artist
    -- Impression.
    local noun = is_artist and "artist image" or "album art"
    local imgs = item and ((item.album and item.album.images) or item.images)
    if not (imgs and imgs[1] and imgs[1].url) then
        ui_say("No " .. noun .. " available"); return
    end
    local art_path
    if item.owner then
        -- Cached by id under the playlist kind, not by art hash: an editorial
        -- cover is replaced in place, and a hash-named file would strand the old
        -- one on every weekly refresh.
        art_path = Util.keyed_art("playlist", item, true, "hi", nil)
    elseif is_artist then
        -- Id-keyed for the same reason, and `hi` for the 640x640 rendition --
        -- the largest an artist has. Not the branch below: Util.art_url reseeds
        -- the ALBUM prefix, which an artist URL does not match, so this would
        -- land in the albums high-res pool at whatever size it happened to arrive.
        art_path = Util.keyed_art("artist", item, true, "hi", nil)
    else
        art_path = ensure_art(Util.art_url(imgs[1].url), "albums/high-res")
    end
    if not art_path then ui_say("No " .. noun .. " available"); return end
    -- Util.subtitle, not artist_names: it answers the show for an episode and
    -- the publisher for a podcast, both of which have no artists at all and
    -- captioned themselves with a dangling separator before.
    local by = item.owner and (item.owner.display_name or item.owner.id or "Spotify")
        or Util.subtitle(item)
    local mesg = (item.name or "Unknown") .. (by ~= "" and (SEP .. by) or "")
    -- THE PICTURE IS THE PAYLOAD. Everything above -- the resolution choice, the
    -- high-res fetch, the artist/playlist/album split -- has already run, so the
    -- UI is handed exactly the image rofi would have shown.
    --
    -- What stood below this was the rofi half: a temp file holding one row with
    -- a `\0icon` marker so that dmenu would draw a picture as a row's ICON, fed
    -- to a `rofi -dmenu` spawned against style/config.rasi with a -kb-custom
    -- binding to keep Backspace from reaching the menu underneath. Every part of
    -- that was a way to make a list widget display an image. It named a config
    -- file this build no longer ships, so it could not have run; it is gone
    -- rather than left as the last thing in here that mentions rofi.
    Util.serve_write({ev = "art-view", path = art_path,
                      mesg = Util.strip_markup(mesg or ""),
                      -- `imp` for an artist impression (640px), `art` for a
                      -- cover (1000px) -- the same split view_art always made.
                      -- Named through the constants, which is what they are for:
                      -- this line spelled both out and was the only place in the
                      -- app that did, so THEME_IMP was declared, documented and
                      -- read by nothing.
                      theme = is_artist and THEME_IMP or THEME_ART,
                      kind = is_artist and "artist" or "cover"})
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
    -- Same contract as view_actions' rebuild_actions, and now the same shape:
    -- the whole list is built on every draw, so a row that cannot act is left out
    -- rather than drawn dead. Nothing here holds a position any more.
    local actions, akeys = {}, {}
    local DIM = '<span foreground="' .. Util.DIM .. '">'
    local function add(label, key)
        actions[#actions+1] = label; akeys[#akeys+1] = key
    end
    local function rebuild_actions()
        local playing_this = item.id ~= nil and item.id == current_id
        for i = #actions, 1, -1 do actions[i] = nil; akeys[i] = nil end
        add(playing_this and (is_playing and "Pause" or "Resume")
            or (item.unavail and Util.markup(DIM .. 'Play</span>') or "Play"), "play")
        -- See view_actions: one playhead, in the loaded episode and nowhere else.
        if playing_this then add("Seek", "seek") end
        add("Add to Queue", "queue")
        add("Go to Podcast", "show")
        add("Copy Web Link", "url")
        -- Reads Watch only when the episode arrived carrying its show -- a search
        -- result does not, and Spotify has no per-episode video field to consult
        -- either way, so the neutral label is the honest default.
        add(Util.watch_label(Util.is_video_show(item.show)), "watch")
        add("Podcast Art", "art")
        add("Episode Details", "details")
        return actions
    end
    rebuild_actions()

    -- A CURSOR MEMORY STOOD HERE: pos_row on the way in, pos_put on the way
    -- out, around a `pre_sel` that was handed to nothing. It is rofi's, and it
    -- had to exist there -- a menu was a process that had just started, so the
    -- engine was the only thing that could say which row to land on. The card
    -- is a live list that never goes away between picks and keeps its own
    -- cursor. Every pick was paying a JSON encode and a disk write for a value
    -- no one would ever read.
    while true do
        -- `current` is carried for Alt+a, which opens this episode's art rather
        -- than the playing track's. It also means Shift+Return nests a second
        -- copy of this menu, exactly as it does in view_actions -- pointless
        -- here, since no row of this one does anything different on alt, but
        -- harmless (Backspace pops the one level) and consistent with the track
        -- menu, which is worth more than special-casing the key away.
        local sel = ui_menu(actions, {prompt="Episode", mesg=function() return track_mesg(item) end, theme=THEME_SUB, context=true, art=false, ctx_type=ctx_type, ctx_id=ctx_id, refresh=rebuild_actions})
        if not sel then return end
        local clean = Util.strip_markup(sel)
        local key
        for i, a in ipairs(actions) do
            if Util.strip_markup(a) == clean then key = akeys[i]; break end
        end
        if key == "play" then
            -- The same call an episode ROW makes, so the menu and the list agree:
            -- play it if it is not current, otherwise pause or resume. do_play
            -- derives the resume position from item.resume_point itself.
            Util.play_or_toggle(item, ctx_type, ctx_id, all_items, cidx)
        elseif key == "seek" then
            if item.id == current_id then view_seek(item)
            else ui_say("Seek only works on the playing episode") end
        elseif key == "queue" then do_add_queue(item)
        elseif key == "show" then
            local sid = item.show and item.show.id
            if sid then
                Util.open_show(sid, item.show.name)
                if jump_to_track_pending then return end
            else ui_say("Episode carries no podcast") end
        elseif key == "url" then
            copy_spotify_url("episode", item.id)
            Util.copied_link()
        elseif key == "watch" then
            -- Spotify's own player is the only thing that can show the video:
            -- the stream is DRM'd and separate from the audio librespot speaks.
            Util.open_in_spotify("episode", item.id)
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

-- ONE ARTIST OPENS; SEVERAL ASK WHICH. Hoisted out of view_actions because an
-- ALBUM's action menu needs exactly the same question and was answering it by
-- taking artists[1] -- so a collaboration went to whichever name Spotify happened
-- to list first and the others were unreachable from there at all.
--
-- `subject` is the thing the artists belong to (a track, an album) and is only
-- the picker's caption. `want_hub` opens the artist's hub rather than their
-- discography; Shift+Return on a row of the picker asks for it too, so a caller
-- that did not want it can still be overruled per artist.
--
-- Returns true when the caller must unwind: a jump-to-track is in flight.
function Util.go_to_artist(arts, subject, want_hub)
    arts = arts or {}
    if #arts <= 1 then
        if #arts == 1 then Util.open_artist(arts[1], want_hub) end
        return jump_to_track_pending
    end
    local ae = {}
    for i, a in ipairs(arts) do ae[i] = display_artist(a) end
    while true do
        -- A CARD. This is the same kind of thing every action menu is -- a short
        -- question about the row you are already standing on, raised by a verb
        -- and gone as soon as it is answered -- and it was the last one still
        -- replacing the whole menu to ask it. `art=false` for the reason they all
        -- set it: the list behind is still wearing its own backdrop, and a list
        -- of NAMES is not about a picture anyway.
        local aidx = ui_menu(ae, {prompt="Artists",
            mesg=(subject or "") .. SEP .. #arts .. " artists",
            by_index=true, theme=THEME_SUB, alt_select=true,
            context=true, art=false})
        local pick_alt = Util.alt_pressed
        Util.alt_pressed = false
        if not aidx then return false end
        if aidx >= 1 and aidx <= #arts then
            Util.open_artist(arts[aidx], want_hub or pick_alt)
            if jump_to_track_pending then return true end
        end
    end
end

view_actions = function(item, ctx_type, ctx_id, all_items, cidx, entries)
    -- Episodes get their own menu. Dispatching HERE rather than at each call
    -- site covers every entry point at once: ui_menu's Shift+Return handler,
    -- Alt+Return on the current track, the search list, an action-on-action, a
    -- pasted URL, and reg("action")'s replay.
    if item and item.type == "episode" then
        return Util.view_episode_actions(item, ctx_type, ctx_id, all_items, cidx)
    end
    -- Action-on-action is a real extra level now that ui_menu redraws the
    -- menu underneath instead of closing it; popping the parent would leave a
    -- visible menu with no stack entry.
    -- from_current: was this opened on the then-playing track? A warm start uses
    -- it to decide whether to restore the named track or whatever plays now --
    -- without it every restored action menu jumped to the current track. `or
    -- nil` keeps it out of session.json so older files restore their own track.
    -- ctx_type/ctx_id restore the list context; all_items/cidx cannot be, so a
    -- replayed menu can remove the track but not prune the row.
    --
    -- NO Util.scope, AND THEREFORE NO STACK ENTRY -- the last of the eight action
    -- menus to give one up. album_action_menu, Util.open_playlist_actions,
    -- Util.show_action_menu and view_artist all shed theirs long ago, each for
    -- the same reason and each with the same note: "A CONTEXT MENU, so no
    -- Util.scope and no trail step". This one kept its scope, which is why every
    -- trail through a track's verbs read "Liked Tracks > A Formal Arrangement",
    -- why the crumb grew a step you could jump back into, and why a cold start
    -- days later reopened a list of verbs about a track as though it were a place.
    --
    -- What the entry used to buy was session replay -- reg("action", "Track")
    -- rebuilt this menu from track_id and friends on a warm start. That is the
    -- behaviour being removed, not a casualty of removing it: an overlay that
    -- outlives the session it was opened in is not an overlay. reg("action")
    -- stays registered so a session.json written by an older build still replays
    -- instead of failing to parse; nothing writes one any more.
    --
    -- ctx_type/ctx_id are still parameters and still reach Remove from Playlist.
    -- They travelled through the stack entry only because there was one.
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
    -- THE WHOLE MENU, BUILT ON EVERY DRAW, rather than a fixed array with a few
    -- volatile labels patched into remembered slots. Two rows are now HIDDEN when
    -- they cannot do anything -- Lyrics for a track known to have none, Remove
    -- from Playlist for a track that is in none of yours -- and a row that comes
    -- and goes cannot live at a fixed index. So nothing holds one any more: the
    -- keys are rebuilt beside the labels, and the two places that used to need
    -- positions (Util.pos_row's cursor memory and the dispatch below) already
    -- work off the key and the stripped label instead.
    --
    -- PLAY STAYS DIMMED, because an unavailable track is still a track you asked
    -- about and the row explains why nothing happens. Everything else that cannot
    -- act is simply not drawn: Seek on a track that is not loaded, Lyrics on one
    -- known to have none, Remove from Playlist on one that is in none of yours.
    local actions, akeys = {}, {}
    local DIM = '<span foreground="' .. Util.DIM .. '">'
    local function add(label, key)
        actions[#actions+1] = label; akeys[#akeys+1] = key
    end
    -- The volatile labels are derived from live state on every draw rather than
    -- patched by hand in the selection branches, so they stay right when a nested
    -- action menu (Alt+Return from here) plays or likes this same track and
    -- ui_menu redraws without this loop running.
    local function rebuild_actions()
        local playing_this = item.id ~= nil and item.id == current_id
        is_liked = item.id and liked[item.id]
        -- Emptied in place, never replaced: the loop below holds a reference to
        -- this very table and hands it to ui_menu on every pass.
        for i = #actions, 1, -1 do actions[i] = nil; akeys[i] = nil end
        -- playing_this is tested first for the same reason display_track puts the
        -- green marker ahead of the dim one: if it IS playing, whatever the cache
        -- says about availability, that wins.
        -- ONE ROW, THREE VERBS, and now three KEYS. All three were added under
        -- "play" because nothing read the key; the branches below told them apart
        -- by comparing the drawn label, which is the part that changes.
        add(playing_this and (is_playing and "Pause" or "Resume")
            or (item.unavail and Util.markup(DIM .. 'Play</span>') or "Play"),
            playing_this and (is_playing and "pause" or "resume") or "play")
        -- SEEK BELONGS TO THE ACTIVE TRACK and to no other. There is one
        -- playhead, and it is in whatever is loaded -- so on any other row the
        -- verb has nothing to move. Hidden rather than dimmed, like Lyrics and
        -- Remove from Playlist: paused counts as active, so this follows
        -- playing_this (is this the loaded track) and not is_playing.
        if playing_this then add("Seek", "seek") end
        add("Add to Queue", "queue")
        add(is_liked and "Unlike" or "Like", "like")
        add("Go to Album", "album")
        add("Go to Artist", "artist")
        add("Add to Playlist", "addpl")
        if #rm_targets > 0 then add("Remove from Playlist", "rmpl") end
        -- `~= false`, not `== true`: nil means "never looked up", and treating
        -- that as "no lyrics" would hide the row on every track the first time
        -- its menu was opened -- which is the one time it is most wanted.
        if Util.track_has_lyrics(item.id) ~= false then add("Lyrics", "lyrics") end
        add("Copy Web Link", "url")
        add("More Like This", "more")
        add("Albumart", "art")
        add("Track Details", "details")
        return actions
    end
    rebuild_actions()

    -- Shared by the Return and the Shift+Return path so the multi-artist picker
    -- is written once. Returns true when the caller must unwind -- a
    -- jump-to-track is in flight.
    local function go_to_artist(want_hub)
        return Util.go_to_artist(item.artists, item.name, want_hub)
    end

    -- A CURSOR MEMORY STOOD HERE: pos_row on the way in, pos_put on the way
    -- out, around a `pre_sel` that was handed to nothing. It is rofi's, and it
    -- had to exist there -- a menu was a process that had just started, so the
    -- engine was the only thing that could say which row to land on. The card
    -- is a live list that never goes away between picks and keeps its own
    -- cursor. Every pick was paying a JSON encode and a disk write for a value
    -- no one would ever read.

    -- Hoisted out of the loop: `item` is fixed for the life of this menu, so the
    -- cover is the same on every pass, and rebuilding it per iteration re-statted
    -- the art cache for nothing.
    local art_url = item.album and item.album.images and #item.album.images > 0
        and item.album.images[1].url or nil
    -- Backdrop only, at 640x640 because the action layout draws it at 364px; see
    -- Util.ensure_art_med.
    --
    -- CACHE ONLY. This was the hot one: nothing warms the med-res pool ahead of
    -- an action menu, so the first one opened on any album paid a live fetch
    -- before it could draw a single row -- the last place in the app where a
    -- menu visibly waited on something. rofi had no choice, because the cover
    -- was the window's background-image and had to exist before the window did.
    -- Qt draws it beside the rows instead, so a miss now costs nothing: the URL
    -- goes to Util.serve_ctx_art and the picture arrives after the menu.
    local art_path = Util.ensure_art_med(art_url, true)
    -- The cover, recorded for the draw. The theme is a NAME and always was;
    -- what used to conflate the two was write_art_theme, which took the name,
    -- wrote a .rasi baking the art in as the window's background-image, and
    -- returned the path -- so every early return here had to unlink it. Seven
    -- os.remove calls were left behind unlinking the string "action" from
    -- whatever directory the engine happened to be started in; those are gone,
    -- and so is the last of them (see the album list).
    Util.serve_cover(art_path, art_url)
    local action_theme = THEME_ACTION

    while true do
        -- Claimed so Shift+Return on "Go to Album" can offer the album's own
        -- action menu (Return there opens the album outright). Every other row
        -- reproduces the default below: a nested action menu for this track.
        -- An explicit local, never `Util.action_art and nil or false`: the and/or
        -- idiom cannot carry `false`, which is the one value this has to send.
        local no_art = false
        if Util.action_art then no_art = nil end
        local sel = ui_menu(actions,
            {prompt="Action", mesg=function() return track_mesg(item) end, theme=action_theme, refresh=rebuild_actions,
             context=true, art=no_art,
             ctx_type=ctx_type, ctx_id=ctx_id, items=all_items, entries=entries,
             alt_select=true})
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        if not sel then
            -- Both arms of the jump_to_track_pending test that used to be here
            -- were byte-identical; the flag is read by the caller, not cleared
            -- here, so it made no difference either way.
            Util.back_pressed = false
            return
        end

        -- THE ROW'S KEY, not the words printed on it. `akeys` has named every
        -- row since this menu was written and NOTHING read it: the branches below
        -- compared the LABEL, which is the one part of a row that changes --
        -- "Pause" becomes "Resume", "Like" becomes "Unlike", and an unavailable
        -- Play arrives wrapped in a colour span. Each of those needed a rule here
        -- to undo it, and a label that ever gains a word would silently match
        -- nothing and redraw the menu. That is rofi's shape: it echoed back the
        -- string it was handed, so the string was the only handle there was.
        --
        -- Resolved against `actions` AS DRAWN -- rebuild_actions has not run
        -- again yet, so the label that came back still names the row it came
        -- from. strip_markup on both sides, because a dimmed row echoes with its
        -- span.
        local label = Util.strip_markup(sel)
        local key
        for i, a in ipairs(actions) do
            if Util.strip_markup(a) == label then key = akeys[i]; break end
        end
        -- The row is not in the menu any more, which a redraw between the draw
        -- and the pick can do. Nothing to act on: fall through and draw again.
        if not key then goto next_action end


        if alt then
            if key == "album" then
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
                        return
                    end
                    -- browse_album, NOT Util.open_album: "Go to Album" is a
                    -- request to SEE the album, so a one-track one must still
                    -- open rather than start playing.
                    browse_album(album.id, (album.name or "Unknown") .. album_suffix(album))
                end
            elseif key == "artist" then
                go_to_artist(true)
            else
                if not Util.fast_now_track() then last_playback = 0; get_playback() end
                view_actions(item, ctx_type, ctx_id, all_items, cidx, entries)
            end
            if jump_to_track_pending then
                return
            end
        elseif key == "resume" then
            Util.transport(true)
        elseif key == "play" then
            if do_play(item, ctx_type, ctx_id, all_items, cidx) then
                current_track = item
                current_id = item.id
                is_playing = true
            end
        elseif key == "pause" then
            Util.transport(false)
        elseif key == "queue" then do_add_queue(item)
        elseif key == "like" then
            -- WHICH WAY the toggle goes comes from the state the row was drawn
            -- from, not from reading the word on it back off the screen.
            local was_liked = is_liked
            if do_like(item, was_liked) then
                is_liked = not was_liked
                if not is_liked then return true end
            end
        elseif key == "album" then
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
                return
            end
            if album and album.id then
                -- Same as the Shift+Return branch above: this row means "show me
                -- the album", never "play it".
                browse_album(album.id, (album.name or "Unknown") .. album_suffix(album))
            end
        elseif key == "artist" then
            if go_to_artist(false) then
                return
            end
        elseif key == "addpl" then view_add_pl(item.id, item.name)
        elseif key == "rmpl" then
            local target = rm_targets[1]
            if #rm_targets == 0 then
                ui_say("Not in any of your playlists")
            elseif #rm_targets > 1 then
                local names = {}
                for i, t in ipairs(rm_targets) do names[i] = t.name end
                local pick = ui_menu(names, {prompt="Remove from", mesg=(item.name or "") .. SEP .. #rm_targets .. " playlists", by_index=true, theme=THEME_SUB})
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
                    ui_say("Removed from " .. (target.name or "playlist"))
                    if target.from_ctx then
                        return
                    end
                    -- rebuild_actions drops the row once rm_targets empties.
                    -- Nothing has to be spliced here, and nothing may be: the
                    -- whole list is rebuilt from scratch on the next draw.
                else
                    ui_say("Failed to remove from " .. (target.name or "playlist"))
                end
            end
        elseif key == "lyrics" then view_lyrics(item)
        elseif key == "url" then
            copy_spotify_url("track", item.id)
            Util.copied_link()
        elseif key == "more" then
            Util.open_recommendations(item.id, item.name)
        elseif key == "art" then view_art(item)
        elseif key == "details" then Util.view_track_details(item)
        elseif key == "seek" then
            if item.id == current_id then view_seek(item)
            else ui_say("Not the current track") end
        end
        ::next_action::
    end
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
    -- NO HEART ON A LIST OF LIKES. Every row here is liked by definition -- that
    -- is the whole selection -- so the glyph marks nothing and only takes the
    -- column. Liked Tracks has always said this about itself (see view_browse's
    -- hide_liked); an artist's liked tracks is the same list, narrowed.
    local te = format_entries(tracks, nil, true, true)
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
    local items = Util.search_page_items(results, page or 1)
    if #items == 0 then return nil end
    local entries = {}
    for i = 1, #items do
        entries[i] = Util.format_mixed_item(items[i], i)
    end
    -- The page marks itself with its GLYPH rather than its name -- the same
    -- glyph the type picker puts on that row and the one every mixed result row
    -- of that kind already carries, so the header reads as the thing being
    -- filtered to instead of restating it in words.
    --
    -- No SEP after it. The separator earns its place between two pieces of TEXT
    -- ("Saved Albums <sep> 13 albums"); here the glyph is already set off by the
    -- trailing space every ICON_PREFIX entry carries, and a second divider next
    -- to a one-character mark just reads as clutter.
    local icon = Util.search_page_icon(page or 1)
    local mesg = icon .. #items .. " results for " .. query
    return items, entries, mesg
end

-- The rows a page draws, filter and all, stamped with the `_stype` view_browse
-- dispatches on. Both the formatter and the counter below go through this, so
-- the number Tab puts on a page is BY CONSTRUCTION the number of rows you get
-- when you land on it -- they used to be two walks of the same data, which a
-- page with a `filter` would have made disagree.
--
-- Util.search_page_keys answers in SEARCH_TYPES order for every page, All
-- included, so display order comes for free rather than from a second loop.
function Util.search_page_items(results, page)
    local pg   = Util.SEARCH_PAGES[page or 1]
    local keep = pg and pg.filter
    local out = {}
    for _, k in ipairs(Util.search_page_keys(page or 1)) do
        local ci = results[k]
        if type(ci) == "table" then
            for i = 1, #ci do
                if not keep or keep(ci[i]) then
                    ci[i]._stype = k
                    out[#out+1] = ci[i]
                end
            end
        end
    end
    return out
end

-- How many rows a page would draw, for the picker's counts. Builds the list
-- rather than summing lengths -- a filtered page has no length to sum -- which
-- at a hundred-odd items is nothing, and is what keeps the count honest.
function Util.search_page_count(results, page)
    return #Util.search_page_items(results, page)
end

-- Tab's menu. A picker rather than a blind cycle, so an empty page is something
-- you can SEE and step over rather than land on -- which also means no
-- skip-the-empties walk and no risk of one looping.
function Util.search_page_pick(results, page)
    local rows = {}
    for i, pg in ipairs(Util.SEARCH_PAGES) do
        local n = Util.search_page_count(results, i)
        local row = Util.search_page_icon(i) .. pg.label .. SEP .. n
        if n == 0 then
            row = Util.dim(row)
        elseif i == page then
            row = Util.markup('<span foreground="#b6e0a4">') .. "\u{f00c} " .. row .. Util.markup('</span>')
        end
        rows[i] = row
    end
    -- Opens on the page you are already on, which is more useful here than a
    -- remembered cursor: the menu exists to move you off it.
    -- NO BACKDROP. This menu is a list of counts, not a thing you can picture,
    -- so the cover of whatever happens to be playing beside it is decoration in
    -- the way of the choice. Said by the menu rather than tested for by name in
    -- Util.serve_art_after, so the next one that wants this costs a key.
    -- A CARD, not a menu you go to. Picking a type does not take you anywhere --
    -- it changes which slice of the results you were already looking at is shown
    -- -- so the results stay on screen behind it and the picker floats over them.
    local idx = ui_menu(rows, {prompt="Type", mesg="Filter results by type", by_index=true,
                                  theme=THEME_SUB, art=false, context=true})
    if not idx or idx < 1 or idx > #Util.SEARCH_PAGES then return nil end
    if Util.search_page_count(results, idx) == 0 then
        ui_say("No " .. Util.SEARCH_PAGES[idx].label:lower() .. " results")
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
    if not tracks then ui_say("Failed to load playlist"); return false end
    if #tracks == 0 then ui_say("Playlist is empty"); return false end
    -- A playlist WITH a cover gets the album.rasi backdrop showing its own art;
    -- one without falls through to menu.rasi, which needs no code -- view_browse
    -- leaves the theme nil and ui_menu falls back to menu.rasi.
    --
    -- fetch=true because this is a single cover for the view we are opening, not
    -- a grid: there is no batch to defer to. Util.ART_DECOR bounds the wait.
    -- The shipped placeholder is for GRID rows; as a full-bleed backdrop it
    -- would just be a giant glyph, so an artless playlist passes nothing -- which
    -- is what the nil fallback here means.
    local cover = (pl.images and pl.images[1] and pl.images[1].url)
        and Util.keyed_art("playlist", pl, true, "med", nil) or nil
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
--
-- A CONTEXT MENU, so no Util.scope and no trail step -- same as view_artist and
-- the unscoped playlist_action_menu the grids use. It was scoped, and since the
-- playlist it opens is named after the playlist too, every trail through here
-- read "Playlists > Chill Mix > Chill Mix".
function Util.open_playlist_actions(pl, on_change)
    if not pl or not pl.id then return end
    Util.playlist_meta_seed(pl)
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
        local asel = ui_menu(acts, {prompt=display_playlist(pl), mesg=display_playlist(pl),
            theme=THEME_SUB, context=true, art=false})
        if not asel then return end
        local token = get_token()
        if asel == "Open Playlist" then
            Util.open_playlist(pl)
            if jump_to_track_pending then return end
        elseif asel == "Playlist Art" then
            view_art(pl)
        elseif asel == "Rename Playlist" then
            if not token then ui_say("No auth")
            else
                local nn = ui_ask("New Name", pl.name or "", P.THEME_SEARCH)
                -- `not nn` FIRST: see ui_ask. Without it the field going up was
                -- itself a rename, to nothing.
                if nn and nn ~= "" and nn ~= (pl.name or "") then
                    local url = "https://api.spotify.com/v1/playlists/" .. pl.id
                    local r = Util.api_write("PUT", url, token, {body={name=nn}})
                    if Util.is2xx(r) then
                        pl.name = nn; bust_my_playlists(pl, true)
                        if on_change then on_change("rename", pl) end
                        ui_say("Renamed")
                    else ui_say("Failed") end
                end
            end
        elseif asel == "Delete Playlist" then
            if not token then ui_say("No auth")
            else
                -- A CARD, like the action menu that raised it. A yes/no about
                -- the playlist you are standing on is the same kind of thing an
                -- action menu is -- a question about that row, not a place you
                -- have gone -- and it was the one step in the sequence that
                -- replaced the whole menu to ask. `art=false` for the reason
                -- every other card sets it: the list behind is still wearing its
                -- own backdrop and this has no business changing it.
                local c = ui_menu({"DELETE","Cancel"}, {prompt="Delete", mesg="Delete " .. (pl.name or "") .. "?", by_index=true, theme=THEME_SUB, confirm=true, context=true, art=false})
                if c == 1 then
                    local url = "https://api.spotify.com/v1/playlists/" .. pl.id .. "/followers"
                    local r = Util.api_write("DELETE", url, token)
                    if Util.is2xx(r) then
                        bust_my_playlists(pl, false)
                        Util.bust_playlist_tracks(pl.id)
                        ui_say("Deleted Playlist: " .. (pl.name or ""))
                        if on_change then on_change("delete", pl) end
                        return
                    else ui_say("Failed to delete") end
                end
            end
        elseif asel == "Copy Web Link" then
            copy_spotify_url("playlist", pl.id)
            Util.copied_link()
        end
    end
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
    if not tracks then ui_say("No tracks for " .. genre); return false end
    Util.scope({view="genre-tracks", genre=genre}, function()
        local te = format_entries(tracks)
        view_browse(te, tracks, "Genre" .. SEP .. genre .. SEP .. #tracks .. " tracks", "genre", nil, nil)
    end)
    return true
end

function Util.view_discover_genre()
    local genres = Util.api_get_genre_seeds()
    if not genres or #genres == 0 then ui_say("No genres available"); return end
    Util.scope({view="discover-genre"}, function()
        local gk = "discover-genre||"
        while true do
            -- NO BACKDROP. A list of genre NAMES is not about a track, and the
            -- cover of whatever happens to be playing beside it is decoration --
            -- the same case the search results' type filter makes about itself.
            local idx = ui_menu(genres, {prompt="Genre", mesg="Discover by Genre" .. SEP .. #genres .. " genres", by_index=true, art=false})
            if not idx then return end
            if idx >= 1 and idx <= #genres then Util.open_genre_tracks(genres[idx]) end
            if jump_to_track_pending then return end
        end
    end)
end

function Util.open_recommendations(track_id, track_name)
    if not track_id then ui_say("No recommendations found"); return false end
    local tracks = api_get_recommendations("seed_tracks=" .. track_id)
    if not tracks then ui_say("No recommendations found"); return false end
    Util.scope({view="recommendations", track_id=track_id, recs_track_name=track_name or ""}, function()
        local te = format_entries(tracks)
        view_browse(te, tracks, "More Like " .. (track_name or ""), "recommendations", nil, nil)
    end)
    return true
end

-- The page is remembered PER QUERY, alongside the query itself in the search
-- history -- see Util.hist_page_get. It used to be one shared view_pos entry, so
-- filtering "aphex twin" to Artists opened the next search on Artists too;
-- searching for something new now always starts on All, because a query nobody
-- has filtered has nothing recorded for it.
--
-- Not carried in the session entry either: a replayed search restores the QUERY,
-- and which slice of it you were looking at belongs to the query, not to that
-- one visit.
function Util.open_search_results(query)
    local results = api_search(query)
    if not results then ui_say("No results"); return false end
    Util.scope({view="search-results", query=query}, function()
        local page = 1
        local saved = Util.hist_page_get(query)
        for i, pg in ipairs(Util.SEARCH_PAGES) do if pg.key == saved then page = i end end
        -- A remembered page can be empty THIS time -- an artist who has since
        -- released nothing under that name, a podcast search that now answers
        -- with none -- and an empty page draws nothing at all, so fall back to
        -- All rather than opening on a blank list.
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
                Util.hist_page_put(query, Util.SEARCH_PAGES[page].key)
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
    if not (pls and #pls > 0) then ui_say("No featured playlists"); return false end
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
    if not pls then ui_say("No playlists"); return false end
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
        if not items then ui_say("No albums found"); return end
        local pk = "artist-albums:" .. (artist_id or "")
        -- Only ever assigned to FORCE a row (Alt+c). Left nil the rest of the
        -- time so pos_key restores the remembered cursor exactly as before --
        -- ui_menu lets an explicit sel win over pos_key, so this has to stay
        -- nil to keep out of the way.
        local pre_sel = nil
        while true do
            -- Same reason as view_new_releases: a discography is mostly singles,
            -- and playing one from here has to move the marker without a reopen.
            ae = Util.album_entries(items, false)
            Util.album_thumbs(ae, items, nil, pre_sel or Util.pos_get(pk), pk)
            local aidx = ui_menu(ae, {prompt=artist_name or "", mesg=mesg, by_index=true, thumbs=true, alt_select=true,
                                         -- WHAT EACH ROW IS, so the step that picks
                                         -- one names the album to the menu that
                                         -- follows. view_browse has always passed
                                         -- this; the grids that decorate their own
                                         -- rows never did, so an album's action
                                         -- menu had nothing to be about and wore
                                         -- whatever the last step had named -- the
                                         -- ARTIST, opened one level up. `alt_select`
                                         -- is set, so this does not also hand
                                         -- Shift+Return to the default handler.
                                         items=items,
                                         -- So F5 re-runs album_thumbs; view_browse gets this
                                         -- via its own `rebuild`.
                                         refresh=function() Util.album_thumbs(ae, items, nil, Util.pos_get(pk), pk); return ae end})
            local alt = Util.alt_pressed
            Util.alt_pressed = false
            -- Alt+c: move to the album holding the playing track and redraw,
            -- rather than letting the flag unwind this scope and dump the user
            -- back at the root grid, which is what it did before.
            if jump_to_track_pending then
                jump_to_track_pending = false
                local row = Util.row_of_id(items, Util.current_album_id())
                if row then pre_sel = row end
                goto aa_next
            end
            if not aidx then return end
            if aidx >= 1 and aidx <= #items then
                local al = items[aidx]
                if not alt or album_action_menu(al) then
                    -- `alt` marks the "Open Album" row: never play, always open.
                    Util.open_album(al, alt)
                    if jump_to_track_pending then return end
                end
            end
            ::aa_next::
        end
    end)
end

-- One artist destination for every call site: Return lands on the discography,
-- Shift+Return on the hub. Split out because eight call sites need the same
-- choice, and the Return path reaches the albums DIRECTLY rather than through
-- view_artist -- routing it through the hub would leave a menu you never asked
-- for between the list and the albums, one you would have to dismiss on the way
-- back out. Backing out of an artist's albums therefore lands on the artist
-- list, which is also where it lands coming back out of the hub.
function Util.open_artist(artist, want_hub)
    if not artist or not artist.id then return end
    if want_hub then view_artist(artist)
    else Util.browse_artist_albums(artist.id, artist.name or "") end
end

function Util.browse_related_artists(artist_id, artist_name)
    Util.scope({view="related", artist_id=artist_id, artist_name=artist_name or ""}, function()
        local artists, ae, mesg = fetch_related_artists(artist_id, artist_name)
        if not artists then ui_say("No related artists found"); return end
        local pk = "related:" .. (artist_id or "")
        while true do
            -- A grid like every other artist list. This one owns its dmenu loop
            -- rather than going through view_browse, so it decorates its rows
            -- here and again in `refresh` -- the same shape Util.browse_artist_albums
            -- uses, and for the same reason: F5 has to re-run album_thumbs.
            Util.album_thumbs(ae, artists, "artist", Util.pos_get(pk), pk)
            local ridx = ui_menu(ae, {prompt="Related to " .. (artist_name or ""), mesg=mesg,
                                         by_index=true,
                                         thumbs=true, alt_select=true,
                                         -- The picked artist names the cover; see
                                         -- Util.browse_artist_albums.
                                         items=artists,
                                         refresh=function() Util.album_thumbs(ae, artists, "artist", Util.pos_get(pk), pk); return ae end})
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
        if not tracks then ui_say("No liked tracks by this artist"); return end
        view_browse(te, tracks, mesg, "liked-by-artist", nil, nil)
    end)
end

function Util.browse_top_by_artist(artist_id, artist_name)
    Util.scope({view="top-by-artist", artist_id=artist_id, artist_name=artist_name or ""}, function()
        local tracks, te, mesg = fetch_artist_top_tracks(artist_id, artist_name)
        if not tracks then ui_say("No top tracks found"); return end
        view_browse(te, tracks, mesg, "top-by-artist", nil, nil)
    end)
end

-- The artist hub is a CONTEXT MENU, not a place: like album_action_menu and
-- Util.show_action_menu it takes no Util.scope entry, so it costs no trail step
-- and a warm start restores the list it was opened from. It used to be scoped,
-- which cost a step named after the artist directly in front of four sub-views
-- that were also named after the artist -- "Bad Bunny > Bad Bunny".
view_artist = function(artist)
    local is_followed = api_check_following(artist.id)
    -- Artist Impression goes LAST, where the track menu keeps Albumart, and
    -- appending is also what keeps the literal actions[5] below -- the
    -- follow/unfollow toggle -- pointing at the row it names.
    local actions = {"View All Albums", "View Liked Tracks", "View Top Tracks",
                     "Related Artists",
                     is_followed and "Unfollow Artist" or "Follow Artist",
                     "Copy Web Link", "Artist Impression"}
    local art_ac_key = "artist-ac:" .. (artist.id or "")

    while true do
        local sel = ui_menu(actions, {prompt=artist.name or "Artist", mesg=artist.name or "Artist", theme=THEME_SUB, context=true, art=false})
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
            local success = do_follow_artist(artist.id, sel == "Follow Artist", artist)
            if success then
                is_followed = not is_followed
                actions[5] = is_followed and "Unfollow Artist" or "Follow Artist"
            else
                ui_say("Failed to " .. (sel == "Follow Artist" and "follow" or "unfollow") .. " artist")
            end
        elseif sel == "Copy Web Link" then
            copy_spotify_url("artist", artist.id)
            Util.copied_link()
        elseif sel == "Artist Impression" then
            -- view_art routes on item.type, so the artist object goes straight
            -- in: it picks the artist art kind and THEME_IMP for itself.
            view_art(artist)
        end
    end
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
        ui_say("No lyrics found"); return
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
        ui_say("No lyrics found"); return
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
            local sel_line = ui_menu(display_lines,
                -- No "> Search or select a line to jump to <" second line. It was
                -- instructions, and instructions in a caption are what a UI says
                -- when it cannot show you: typing filters here as it does in
                -- every list, and the sung line marks itself.
                {prompt="Lyrics", mesg=mesg_base,
                 theme=THEME_LYR})
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
                    Util.mpris{op = "setpos", value = ts}
                    mem_bust("_playerctl_pos")
                    if (Util.mpris{op = "status"}.value or "") ~= "Playing" then
                        Util.mpris{op = "play"}
                        Util.playerctl_bust()
                    end
                    is_playing = true
                elseif item.unavail then
                    -- This branch builds its own play request rather than going
                    -- through do_play, so it needs the same refusal.
                    ui_say("Selection is unavailable to your account's region")
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
                            ui_say("Failed to play from timestamp")
                        end
                    end
                else
                    ui_say("Track changed while viewing lyrics")
                end
                pre_sel = found_idx - 1
            end
        end
    else
        while true do
            ::lr_next_plain::
            local sel_line = ui_menu(display_lines,
                {prompt="Lyrics", mesg=mesg_base, theme=THEME_LYR})
            if jump_to_track_pending then
                jump_to_track_pending = false
                ui_say("No synced lyrics — cannot jump to a line")
                goto lr_next_plain
            end
            if sel_line then
                ui_say("No synced lyrics — cannot jump to a line")
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
    if not my_id then ui_say("Cannot determine user ID"); return end

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

    local idx = ui_menu(names, {prompt="Add to Playlist", mesg="Select a playlist", by_index=true})
    if not idx then return end
    -- THE ROW HAS TO STILL BE THERE. `idx` is a position in the list as it was
    -- DRAWN, and a replayed step -- a warm start walking back into this menu --
    -- can land after the playlist list has been rebuilt shorter. Nothing checked
    -- it, so a stale step ran off the end of `ids` and the nil reached the URL
    -- two screens down as a concatenation: the engine raised, and the traceback
    -- was what the message bar showed on every launch.
    if not ids[idx] then ui_say("That playlist is no longer there"); return end

    local target_id, target_name
    if ids[idx] == "__create__" then
        local pl_name = ui_ask("New Playlist", "", P.THEME_SEARCH)
        -- Nothing yet, or nothing at all: either way there is no playlist to
        -- make. See ui_ask -- this tested `== ""` alone, so the pass that merely
        -- RAISED the field fell straight through and posted a playlist with no
        -- name, before the user had typed a character.
        if not pl_name or pl_name == "" then return end
        local url = "https://api.spotify.com/v1/users/" .. my_id .. "/playlists"
        local r = Util.api_write("POST", url, token, {body={name=pl_name}, raw=true})
        local cr = safe_decode(r)
        if not cr or not cr.id then ui_say("Failed to create playlist"); return end
        target_id = cr.id
        target_name = cr.name or pl_name
        bust_my_playlists(cr, true)
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
    ui_say(Util.is2xx(r) and "Added to playlist" or "Failed to add track")
end)
end

-- VIEW: PLAYLISTS

local function view_playlists()
    Util.scope({view="playlists"}, function()
    local token = get_token()
    if not token then ui_say("No auth"); return end
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
        local idx = ui_menu(entries, {prompt="Playlists", mesg="Playlists" .. SEP .. #pls, by_index=true, alt_select=true,
            thumbs=true,
            refresh=function() Util.album_thumbs(entries, thumb_items, "playlist", Util.pos_get("playlists||"), "playlists||"); return entries end})
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        if not idx then return end
        if idx == 1 then
            local pl_name = ui_ask("New Playlist", "", P.THEME_SEARCH)
            -- See ui_ask. `not pl_name` is the pass that only put the field up.
            if not pl_name or pl_name == "" then goto pl_loop end
            local me = api_get_me()
            if me and me.id then
                local url = "https://api.spotify.com/v1/users/" .. me.id .. "/playlists"
                local r = Util.api_write("POST", url, token, {body={name=pl_name}, raw=true})
                local cr = safe_decode(r)
                if cr then pls[#pls+1] = cr; rebuild_rows(); bust_my_playlists(cr, true)
                else ui_say("Failed to create") end
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
        local query = ui_menu(hist, {prompt="Search",
            mesg="Search", theme=P.THEME_SEARCH,
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
    if not cats or #cats == 0 then ui_say("No categories available"); return end
    Util.scope({view="categories"}, function()
    local ce = {}
    for _, c in ipairs(cats) do ce[#ce+1] = c.name end

    while true do
        -- Icons are cached by category id, like playlist covers: Spotify replaces
        -- a category's icon in place rather than serving a new URL.
        Util.album_thumbs(ce, cats, "category", Util.pos_get("categories||"), "categories||")
        local idx = ui_menu(ce, {prompt="Categories", mesg="Categories" .. SEP .. #cats, by_index=true,
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
    if not tracks then ui_say("No top tracks"); return end
    Util.scope({view="top-tracks"}, function()
    local entries = format_entries(tracks)
    -- THE NAME IS THE WINDOW IT DESCRIBES. Spotify's me/top/tracks is
    -- medium_term -- roughly the last four weeks -- and "Top Tracks" said
    -- nothing about that, which made a shelf that visibly changes week to week
    -- look like it was simply wrong. The view key, the cache file and the trail
    -- id are all still `top-tracks`: this is a label, and renaming any of the
    -- others would strand every saved trail that names it.
    view_browse(entries, tracks, "This Month's Top" .. SEP .. #tracks .. " tracks", "top-tracks", nil, nil)
    if jump_to_track_pending then return end
end)
end

local function view_liked_tracks()
    local tracks = load_liked_tracks() or {}
    if #tracks == 0 then ui_say("No liked tracks"); return end
    Util.scope({view="liked"}, function()
    local entries = format_entries(tracks, nil, true)
    view_browse(entries, tracks, "Liked Tracks" .. SEP .. #tracks .. " tracks", "liked", nil, nil)
    if jump_to_track_pending then return end
end)
end

local function view_saved_albums()
    local al = load_saved_albums()
    if #al == 0 then ui_say("No saved albums"); return end
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
    if #sh == 0 then ui_say("No followed podcasts"); return end
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
        ui_say("No podcasts found for " .. query)
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
    "Religion & Spirituality"
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
         open = function() Util.podcast_search_prompt() end}
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
            end
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
    if #eps == 0 then ui_say("No episodes -- follow a podcast first"); return end
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
    if #eps == 0 then ui_say("No saved episodes"); return end
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
    local query = ui_menu(hist, {prompt="Podcasts", mesg="Search Podcasts",
        theme=P.THEME_SEARCH,
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
    if #ar == 0 then ui_say("No followed artists"); return end
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
    {key = "top",       label = "This Month's Top",  open = function() view_top_tracks() end,
     art = function() return Util.shelf_head(api_get_top_tracks) end},
    {key = "albums",    label = "Saved Albums",     open = function() view_saved_albums() end,
     art = function() return Util.shelf_head(load_saved_albums) end},
    {key = "artists",   label = "Followed Artists", open = function() view_followed_artists() end,
     art = function() return Util.shelf_head(load_followed_artists) end},
    {key = "playlists", label = "Playlists",        open = function() view_playlists() end,
     art = function() return Util.shelf_head(api_get_my_playlists) end}
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
    charts       = "0JQ5DAudkNjCgYMM0TZXDw"
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
     open = function() view_categories() end}
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
        -- assets/<key>.png, named after the row. It wins over the
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
        local idx = ui_menu(entries, {prompt=spec.prompt, mesg=spec.prompt, by_index=true,
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
    if #albums == 0 then ui_say("No new releases"); return end
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
        local idx = ui_menu(entries, {prompt="New Releases", mesg="New Releases" .. SEP .. #albums .. " albums", by_index=true, thumbs=true, alt_select=true,
            -- The picked album names the cover; see Util.browse_artist_albums.
            items=albums,
            refresh=function() Util.album_thumbs(entries, albums, nil, pre_sel or Util.pos_get(v_key), v_key); return entries end})
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        -- Alt+c: move to the album holding the playing track and redraw, rather
        -- than letting the flag unwind this scope and dump the user back at the
        -- root grid, which is what it did before.
        if jump_to_track_pending then
            jump_to_track_pending = false
            local row = Util.row_of_id(albums, Util.current_album_id())
            if row then pre_sel = row end
            goto nr_next
        end
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
        ::nr_next::
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
    if not d then ui_say("Queue is empty"); return end
    local tracks = {}
    if d.currently_playing and type(d.currently_playing) == "table" and d.currently_playing.id then tracks[#tracks+1] = d.currently_playing end
    if d.queue then for _, t in ipairs(d.queue) do if type(t) == "table" and t.id then tracks[#tracks+1] = t end end end
    if #tracks == 0 then ui_say("Queue is empty"); return end
    Util.scope({view="your-queue"}, function()
    local entries = format_entries(tracks)
    local user_q = d.queue and #d.queue or 0
    local mesg = "Your Queue" .. SEP .. user_q .. " tracks"
    if user_q > 0 then mesg = mesg .. " (may include Spotify suggestions)" end
    view_browse(entries, tracks, mesg, "your-queue", nil, nil)
    if jump_to_track_pending then return end
end)
end

-- SET THE VOLUME, ONCE. The same three lines stood in five places -- three
-- branches of view_volume and now the wheel -- and they have to stay together:
-- the player is told, the one-second cache is dropped so the next read is not the
-- old number, and the level is persisted so a restarted spotifyd comes back where
-- it was. Clamped here so no caller has to remember the range.
function Util.set_volume(v)
    local nv = math.max(0, math.min(100, math.floor(tonumber(v) or 0)))
    Util.mpris{op = "setvol", value = nv / 100}
    mem_bust("_playerctl_vol")
    save_volume(nv)
    return nv
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
        -- NO BACKDROP, here or in any other System submenu. System itself is
        -- refused one by the UI from its scope, and every menu under it pushes a
        -- scope of its own and so escaped that -- but a volume slider is no more
        -- about a picture than the menu it was opened from. See Util.serve_draw's
        -- `art`.
        -- A CARD, and one that SURVIVES BEING USED. Volume is nudged -- +5, +5
        -- again -- so a card that closed on the first press would have to be
        -- reopened for the second, which is the whole reason Seek is sticky too.
        local vi = ui_menu(vol_acts,
            {prompt="Volume", mesg=vol_mesg(disp_vol), theme=THEME_SUB, art=false,
             context=true, sticky=true})
        if not vi then break end
        local vol = disp_vol
        if vi == "Volume +5" then
            disp_vol = Util.set_volume(vol + 5)
        elseif vi == "Volume -5" then
            disp_vol = Util.set_volume(vol - 5)
        else
            local vol_presets = {Mute=0, ["25%"]=25, ["50%"]=50, ["75%"]=75, ["100%"]=100}
            local v = vol_presets[vi]
            if v then disp_vol = Util.set_volume(v) end
        end
    end
end)
end

-- VIEW: PLAYBACK CONTROLS

view_seek = function(item)
    -- THE TRACK IT IS SEEKING IN, named for the card's own backdrop -- the same
    -- line view_actions carries, for the same reason.
    --
    -- It named nothing before, which was harmless while a tail segment started
    -- with no subject at all: the card simply had no picture. Tails inherit what
    -- the trail was standing on now (see Util.serve_run's keepCtx, which is what
    -- lets a double-clicked backdrop know it is in an album) -- so a Seek card
    -- opened by keybind inside an album would have inherited the ALBUM and shown
    -- its sleeve, which is a picture of the wrong thing: seeking is about the
    -- track that is playing, and that track need not be from this album at all.
    --
    -- Cache-only. This is a card about what is already playing, so its cover has
    -- been on disk since the row that started it was drawn; a miss just means no
    -- picture, which is what the card had before.
    do
        local u = item and item.album and item.album.images
                  and item.album.images[1] and item.album.images[1].url or nil
        if u then Util.serve_cover(Util.ensure_art_med(u, true), u) end
    end
    Util.scope({view="seek", track_id=item.id, strack_name=item.name or "", track_duration_ms=item.duration_ms or 0}, function()
    local seeks = {"+10s", "-10s", "+30s", "-30s", Util.markup('<span foreground="#20242a">────────────────────</span>'), "+1:00", "-1:00", "0:00"}
    while true do
        -- A CARD, like the action menus. Seek is the same kind of thing they are:
        -- a short list of verbs about the row you are already looking at, not a
        -- place you have gone to. `art=false` for the same reason they set it --
        -- a floating menu draws over the backdrop rather than replacing it.
        --
        -- ...and a card that SURVIVES BEING USED, which is the one thing every
        -- other one must not do. Nudging the playhead is something you do twice
        -- and three times -- ten seconds, ten more, back a minute -- and every
        -- other verb here is a one-shot: Play, Like, Copy Web Link act once and
        -- the card has finished with the row. So the UI closes a card on the
        -- pick and asks the list behind it again, and Seek came back as a NEW
        -- card each time with its cursor on the first row. That is rofi's
        -- behaviour, reproduced by accident. See applyContext's `sticky`.
        --
        -- A cursor memory stood here -- pos_get/pos_put around a `pre_sel` that
        -- was computed on every pass and handed to nothing. It answered this
        -- exact complaint in the rofi build, where the engine had to name the
        -- selected row because a menu was a process that had just started. The
        -- card is a live list now and keeps its own cursor, so the memory was
        -- writing a file to feed a variable nobody read.
        local si = ui_menu(seeks, {prompt="Seek", theme=THEME_SUB,
                                      context=true, art=false, sticky=true})
        if not si then
            if jump_to_track_pending then return end
            break
        end
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
            Util.mpris{op = "setpos", value = target}
            mem_bust("_playerctl_pos")
        else
            local m, s = si:match("^(%d+):(%d+)$")
            if m and s then
                local target = tonumber(m) * 60 + tonumber(s)
                local dur = (item.duration_ms or 0) / 1000
                target = math.max(0, math.min(dur > 0 and dur or math.huge, target))
                Util.mpris{op = "setpos", value = target}
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

-- LISTENING, WITHOUT HOLDING THE ENGINE HOSTAGE.
--
-- This used to be one function that started songrec and then sat in a polling
-- loop for up to P.listen_timeout seconds. The engine is a single stdio loop, so
-- for those thirty seconds it read no request and answered none: every poll the
-- UI sent queued up behind it, the loading glow breathed forever because the
-- draw it was waiting on could never arrive, and spoot was locked in whatever
-- menu it happened to be on. Killing the process did not help, because the
-- backgrounded songrec outlived it still holding the monitor.
--
-- Split into three, none of which waits: start it, ask how it is doing, stop it.
-- The UI drives the asking while its card is up, which is also what finally gives
-- the card a working cancel.
Util.listen = nil          -- {out, pidf, device, deadline} while one is running
Util.listen_track = nil    -- what the last completed listen identified

function Util.listen_pid()
    if not Util.listen then return nil end
    local p = trim(read_file(Util.listen.pidf) or "")
    return p:match("^%d+$")
end

-- Kills the recorder and clears the files. Safe to call when nothing is running,
-- because every route out of a listen comes through here.
function Util.listen_stop()
    local st = Util.listen
    Util.listen = nil
    if not st then return {state = "idle"} end
    local pid = trim(read_file(st.pidf) or ""):match("^%d+$")
    if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
    -- Scoped to our own invocation, device and all: a bare `pkill songrec` would
    -- take down an unrelated one the user started themselves.
    os.execute("pkill -f " .. shell_quote("songrec recognize -d " .. st.device) .. " 2>/dev/null")
    for _, f in ipairs({st.out, st.pidf}) do os.remove(f) end
    return {state = "idle"}
end

function Util.listen_start()
    -- Whatever was running is over: a second Alt+l while one is up restarts it
    -- rather than stacking two recorders on the same monitor.
    Util.listen_stop()
    Util.listen_track = nil
    if trim(shell("command -v songrec 2>/dev/null") or "") == "" then
        ui_say("songrec is not installed"); return
    end
    -- The first sink, so this follows whatever the machine's default output is
    -- rather than naming a card. `.monitor` is the loopback of that sink: what
    -- is being PLAYED, not what a microphone hears.
    local sink = trim(shell("pactl list short sinks 2>/dev/null | awk 'NR==1{print $2}'") or "")
    if sink == "" then ui_say("No audio output device found"); return end
    local device = sink .. ".monitor"

    local out_tf = Util.tmpfile("listen.out")
    local sr_pidf = Util.tmpfile("listen.sr.pid")
    -- Backgrounded bare rather than inside a { } group: `$!` has to be songrec's
    -- own pid, because killing a wrapping subshell would leave the recorder
    -- holding the monitor. Its exit is also what marks the output file complete,
    -- so nothing ever reads a half-written response.
    os.execute("songrec recognize -d " .. shell_quote(device) .. " -j > " .. shell_quote(out_tf)
        .. " 2>/dev/null & echo $! > " .. shell_quote(sr_pidf))
    Util.listen = {out = out_tf, pidf = sr_pidf, device = device,
                   deadline = os.time() + P.listen_timeout}
    -- NO ASSET. This used to name a 300px speaker glyph for the card to draw,
    -- from the rofi build where a message with a picture was the only way to
    -- make a window that looked like it was doing something. The listener is a
    -- pill now -- a line of text and a light running round its edge -- so there
    -- is no picture, and listen.png has gone from assets with it.
    Util.serve_write({ev = "listening", timeout = P.listen_timeout})
end

-- HOW IS IT GOING. Answers immediately, every time -- that is the whole point.
-- The UI asks while its card is up and acts on the state it gets back.
-- NEWEST FIRST, and one entry per track: recognising the same song twice moves
-- it back to the top rather than filling the list with it. `at` is what the rows
-- are labelled with, so it is stored rather than derived -- a recognition is a
-- moment, and the list is a record of moments.
function Util.listen_hist_add(track)
    if not (track and track.id) then return end
    local hist = disk_get(P.listen_hist) or {}
    if type(hist) ~= "table" then hist = {} end
    for i = #hist, 1, -1 do
        local e = hist[i]
        if type(e) ~= "table" or not e.track or e.track.id == track.id then
            table.remove(hist, i)
        end
    end
    table.insert(hist, 1, {at = os.time(), track = track})
    while #hist > P.listen_hist_max do table.remove(hist) end
    disk_set(P.listen_hist, hist)
end

function Util.listen_hist()
    local hist = disk_get(P.listen_hist)
    return type(hist) == "table" and hist or {}
end

-- HOW LONG AGO, in the coarsest unit that still says something. A recognition is
-- remembered as the moment it happened, and "3d" answers the question the list
-- is actually asking better than a timestamp does. Falls back to a date once the
-- relative form stops being useful.
function Util.ago(t)
    t = tonumber(t)
    if not t or t <= 0 then return "" end
    local d = os.time() - t
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    if d < 86400 * 7 then return math.floor(d / 86400) .. "d ago" end
    return os.date("%d %b", t)
end

function Util.listen_poll()
    local st = Util.listen
    if not st then return {state = "idle"} end
    local pid = Util.listen_pid()
    -- songrec gone means it answered: `recognize` exits on its first match.
    local done = pid and not Util.proc_alive(pid)
    if not done and os.time() < st.deadline then return {state = "listening"} end
    local raw = done and read_file(st.out) or nil
    Util.listen_stop()
    local m = raw and Util.listen_parse(raw)
    if not m then return {state = "none"} end
    local track = Util.listen_lookup(m)
    if not track then
        return {state = "notfound",
                label = (m.artist and (m.artist .. SEP) or "") .. (m.title or "")}
    end
    Util.listen_track = track
    Util.listen_hist_add(track)
    return {state = "match", name = track.name or "",
            artist = (track.artists and track.artists[1] and track.artists[1].name) or ""}
end

-- THE BLOCKING ONE, for the two entry points that have no event loop to poll
-- from: the System menu's "Listen..." row and `lua spoot.lua --listen`. Both are
-- rofi-era paths, and rofi is what a wait like this was ever acceptable in.
--
-- Built on the three pieces above rather than being a second copy of the
-- recorder, so there is one description of how a listen works and the front end
-- with an event loop simply declines to sit in this loop.
function Util.view_listen()
    Util.listen_start()
    if not Util.listen then return end
    local r
    repeat
        os.execute("sleep " .. tostring(P.listen_poll))
        r = Util.listen_poll()
    until r.state ~= "listening"
    if r.state == "none" then ui_say("No match"); return end
    if r.state == "notfound" then
        ui_say("Not on Spotify" .. SEP .. (r.label or "")); return
    end
    if not Util.listen_track then return end
    view_actions(Util.listen_track)
    -- Says a result MENU was opened, as opposed to the ways this returns without
    -- one. The --listen keybind reads it to decide whether to hand over to main()
    -- on the way out: backing out of a menu should land somewhere, giving up on
    -- the listener should not.
    return true
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
    -- draw -- including a redraw from inside ui_menu, where this loop does
    -- not run (Alt+r/Alt+s toggle shuffle and repeat from this very menu).
    -- keys[i] names row i for the life of this menu, whatever that row currently
    -- reads. Every label here is volatile (Pause/Resume, Shuffle ON/OFF, Repeat
    -- OFF/TRACK/CONTEXT), so remembering the cursor by label lost it the instant
    -- you used the row -- see Util.pos_row. Seek is not merely volatile: it is
    -- absent whenever there is nothing loaded to seek through.
    local items, keys = {}, {}
    local function build_items()
        items, keys = {}, {}
        local function add(label, key) items[#items+1] = label; keys[#keys+1] = key end
        local play_label = current_track and (is_playing and "Pause" or "Resume") or nil
        if play_label then add(play_label, "play") end
        -- Not drawn at all with nothing loaded. There is one playhead and it is
        -- in the current track; with no current track the row has nothing to
        -- move, and a dead row is worse than a shorter menu.
        if current_track then add("Seek", "seek") end
        -- The playing track's own action menu, from the one menu that is about
        -- the playing track. Everything the row offers -- like it, queue it, go
        -- to its album, its lyrics -- was reachable only by first FINDING the
        -- track in some list. Dimmed rather than absent, unlike Seek above it:
        -- Seek needs a playhead and there is none, while this row is about a
        -- TRACK, and naming the gap reads better than closing it.
        add(current_track and "Track Actions" or Util.dim("Track Actions"), "actions")
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
        -- THE MARK FOR A ROW WITH A SECOND GESTURE, and it goes FIRST. Shift+Return
        -- here opens what the listener has already found rather than starting
        -- another thirty seconds of listening, and there is no other way to know
        -- that from looking at the menu. Leading, because it is a property of the
        -- row rather than part of its name -- the same column every marked row
        -- would use, read before the words instead of found after them. ALT_MARK
        -- is the glyph, defined once.
        add(ALT_MARK .. " Listen\u{2026}", "listen")
        return items
    end
    build_items()
    -- THE PLAYING TRACK'S COVER, beside the verbs. This menu is about one track
    -- in the same way an action menu is, so it wears the same backdrop -- rofi
    -- could not, because a cover there was the window's background-image and
    -- this menu shares THEME_SUB with a dozen others that are about nothing.
    --
    -- Cache-only, and the url handed on for the continuation: the rows go out
    -- first and the picture follows. See Util.serve_cover.
    local pb_art = current_track and current_track.album and current_track.album.images
        and current_track.album.images[1] and current_track.album.images[1].url or nil
    Util.serve_cover(Util.ensure_art_med(pb_art, true), pb_art)
    while true do
        build_items()
        local si = ui_menu(items, {prompt="Playback", theme=THEME_SUB,
            refresh=build_items, alt_select=true})
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        if not si then break end
        -- ON THE KEY, not the words. `keys` has named every row here since the
        -- menu was written and was read by nothing: the branches below compared
        -- the LABEL, and every label in this menu is state -- Pause becomes
        -- Resume, Shuffle carries its own ON/OFF, and two rows are dimmed into
        -- markup when they have nothing to act on. Each of those needed a rule
        -- here to undo it (a strip_markup pass, two `find("^Shuffle")` prefix
        -- matches), and adding so much as a glyph to a row -- see the Listen
        -- row's alternate mark -- silently unmatched its branch.
        --
        -- Resolved against `items` AS DRAWN: the next pass's build_items has not
        -- run yet, so the label that came back still names the row it came from.
        local label = Util.strip_markup(si)
        local key
        for i, it in ipairs(items) do
            if Util.strip_markup(it) == label then key = keys[i]; break end
        end
        if not key then goto pb_next end
        -- SHIFT+RETURN, where a row offers something else. Only Listen does, and
        -- it says so on its face; anything else falls through to its plain verb,
        -- which is what makes the key harmless everywhere it means nothing.
        if alt then
            if key == "listen" then Util.view_listen_history() end
            goto pb_next
        end
        if key == "play" then
            -- ONE ROW, ONE KEY, and which way it goes comes from the state the
            -- row was DRAWN from rather than from reading its word back.
            if is_playing then
                if not Util.transport(false) then ui_say("Failed to pause") end
            else
                if not Util.transport(true) then ui_say("Failed to resume") end
            end
        elseif key == "next" then
            local prev_id = current_id
            local r = do_playback_cmd("next")
            if Util.is2xx(r) then
                Util.wait_playback_change(prev_id)
                sync_queue_idx()
            elseif not recover_playback(1) then ui_say("Failed to skip")
            else
                Util.wait_playback_change(prev_id)
                sync_queue_idx()
            end
        elseif key == "prev" then
            local prev_id = current_id
            local r = do_playback_cmd("previous")
            if Util.is2xx(r) then
                Util.wait_playback_change(prev_id)
                sync_queue_idx()
            elseif not recover_playback(-1) then ui_say("Failed to go back")
            else
                Util.wait_playback_change(prev_id)
                sync_queue_idx()
            end
        elseif key == "shuffle" then toggle_shuffle()
        elseif key == "repeat" then toggle_repeat()
        elseif key == "seek" then
            if current_track then view_seek(current_track) end
        elseif key == "actions" then
            if current_track then view_actions(current_track) end
        elseif key == "queue" then
            view_your_queue()
            if jump_to_track_pending then break end
        elseif key == "recent" then
            view_recently_played()
            if jump_to_track_pending then break end
        elseif key == "listen" then
            -- NON-BLOCKING UNDER THE QT FRONT END, which is the whole point of
            -- the split: listen_start hands the card over and returns, and the UI
            -- polls it. Calling the blocking wrapper here would have re-locked the
            -- engine for thirty seconds from the one route still using it -- the
            -- System menu -- and undone the fix for anyone who reaches the
            -- listener that way rather than by the keybind.
            if Util.serving then Util.listen_start() else Util.view_listen() end
        elseif key == "openurl" then
            local url = Util.get_clipboard()
            if url and url ~= "" then open_url(url)
            else ui_say("Clipboard is empty") end
        end
        ::pb_next::
    end
end)
end

-- WHAT THE LISTENER HAS FOUND, as a place you can go back to. Reached by
-- Shift+Return on the Listen row, which wears ALT_MARK to say so.
--
-- A real scoped view rather than a card: it is a list of tracks you can browse,
-- scroll and act on, which is a place -- and the same shape every other track
-- list in the app has, so Return plays and Shift+Return opens the action menu
-- without any of that being written again here.
function Util.view_listen_history()
    local hist = Util.listen_hist()
    if #hist == 0 then
        ui_say("Nothing identified yet" .. SEP .. "Listen finds tracks by ear")
        return
    end
    local tracks, entries = {}, {}
    for _, e in ipairs(hist) do
        if type(e) == "table" and type(e.track) == "table" then
            tracks[#tracks+1] = e.track
            -- The track as every other list draws it, then WHEN -- which is the
            -- one fact this list has that no other one does.
            entries[#entries+1] = display_track(e.track) .. SEP .. Util.ago(e.at)
        end
    end
    if #tracks == 0 then ui_say("Nothing identified yet"); return end
    Util.scope({view = "listen-history"}, function()
        view_browse(entries, tracks,
                    "Heard" .. SEP .. #tracks .. (#tracks == 1 and " track" or " tracks"),
                    "listen-history", nil, nil)
    end)
end

-- VIEW: SYSTEM

-- Lifted out of view_system's "Restart" row so the bitrate view can
-- reuse it -- bitrate only takes effect when spotifyd is respawned, since
-- ensure_spotifyd reads get_saved_bitrate() at launch. Body is unchanged.
-- On Util rather than a file local: the chunk is at Lua's 200-local ceiling
-- (see the note above Util's declaration).
function Util.restart_daemons()
    os.execute("pkill -x spotifyd 2>/dev/null"); os.execute(Util.own_procs("--daemon"))
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
    Util.spawn_self({"--daemon"}, P.daemon_log)
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
-- ONE PICKER FOR EVERY SETTING, because they differ only in what they offer:
-- two rows for a toggle, a stepped span for a number, a 3x3 for the anchor. A
-- function each would have been eight copies of "draw the values, tick the
-- current one, store the choice" -- which is the shape the bitrate picker below
-- already is, and the one place that idiom should exist twice is not here.
--
-- The checkmark is drawn the same green the bitrate picker uses, so a setting
-- reads the same wherever you meet one.
-- WHAT PICKING A SETTING'S ROW DOES.
--
-- A SETTING WITH TWO STATES HAS NOWHERE TO GO. Every setting opened a picker,
-- which for a range or the window position is the whole point -- there are values
-- to look at and choose between. For an on/off it was a card with two rows, one
-- of them already ticked, to answer a question the row you just pressed had
-- already asked: two keystrokes and a card to say the opposite of what it says.
--
-- So a bool flips where it stands and the menu redraws with the new value. The
-- step spends itself on the toggle and describes no place, so Util.serve_keep
-- takes it back off the trail -- the same shape Delete and Queue have.
--
-- Here rather than in the menu, so the rule is one function rather than a test at
-- each caller. It also means a bool never pushes a `ui-setting` scope, so no
-- warm start can restore a picker that no longer exists.
function Util.ui_activate(spec)
    if not spec then return end
    if spec.kind == "bool" then
        Util.ui_set(spec.key, not Util.ui_get()[spec.key])
        return
    end
    Util.ui_pick(spec)
end

function Util.ui_pick(spec)
    Util.scope({view = "ui-setting", setting = spec.key}, function()
    while true do
        local cur = Util.ui_get()[spec.key]
        local values = {}
        -- A `bool` BRANCH STOOD HERE offering {true, false}. Nothing can reach it
        -- any more: an on/off toggles in place (see Util.ui_activate) and never
        -- gets this far, and it was the one picker whose two rows told you
        -- strictly less than the row that opened it.
        if spec.kind == "anchor" then
            for _, p in ipairs(Util.UI_POSITIONS) do values[#values + 1] = p.key end
        else
            for v = spec.min, spec.max, spec.step do values[#values + 1] = v end
        end
        local rows = {}
        for i, v in ipairs(values) do
            local label = Util.ui_show(spec, v)
            if v == spec.default then label = label .. " (default)" end
            if v == cur then
                label = Util.markup('<span foreground="#b6e0a4">') .. "\u{f00c} "
                        .. label .. Util.markup("</span>")
            end
            rows[i] = label
        end
        -- A 3x3 FOR THE ANCHOR, at last. This was a flat list of nine rows in
        -- reading order, with a note here explaining that a real grid was not
        -- available: the only grid spoot had was a grid of COVER tiles, and nine
        -- of those with no artwork would have been nine empty frames with words
        -- under them.
        --
        -- `cols` is the third thing: a card whose rows flow across into columns
        -- rather than down. Nine places in three columns of three, laid out the
        -- way they sit on the screen, so the picker is a picture of the choice.
        -- See main.qml's ctxCols and RowList's rowMajor.
        --
        -- STICKY, because changing a setting is not going anywhere: the loop
        -- redraws this same picker with the check moved, and a card that closed
        -- on every change would have to be reopened to try the next value.
        local sel = ui_menu(rows, {prompt = spec.label,
            mesg = spec.why and (spec.why .. SEP .. "Current: "
                                 .. Util.ui_show(spec, cur)) or nil,
            theme = THEME_SUB, by_index = true, art = false,
            context = true, sticky = true,
            cols = (spec.kind == "anchor") and 3 or nil})
        if not sel then return end
        local chosen = values[sel]
        if chosen ~= nil and chosen ~= cur then Util.ui_set(spec.key, chosen) end
    end
    end)
end

-- VIEW: UI SETTINGS -- one row per setting, each showing what it is set to.
Util.view_ui_settings = function()
    Util.scope({view = "ui-settings"}, function()
    while true do
        local cur = Util.ui_get()
        local rows = {}
        for i, spec in ipairs(Util.UI_SETTINGS) do
            rows[i] = Util.setting_row(spec.label, Util.ui_show(spec, cur[spec.key]))
        end
        local sel = ui_menu(rows, {prompt = "UI Settings",
            mesg = "How spoot looks and where it opens",
            theme = THEME_SUB, art = false, by_index = true})
        if not sel then return end
        Util.ui_activate(Util.UI_SETTINGS[sel])
    end
    end)
end

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
        -- A CARD over System, like every other System submenu: none of them is a
        -- place you have gone to, they are all a choice about the menu you are
        -- standing in.
        local chosen = ui_menu(br_opts,
            {prompt="Bitrate", mesg="Current: " .. cur .. " kbps",
             theme=THEME_SUB, art=false, context=true, sticky=true})
        if not chosen then return end
        local n = tonumber(Util.strip_markup(chosen):match("(%d+)"))
        if n and n ~= cur then
            -- PICKING IT APPLIES IT. A "Restart / Abort" confirmation stood here,
            -- and it was asking the wrong question in two ways: it read as though
            -- SPOOT were about to restart -- it is not, and there is no way to
            -- restart spoot from inside it -- and it made a two-step ritual out of
            -- the only thing this menu can do. Util.restart_daemons replaces
            -- spotifyd and spoot's own background helper; the engine you are
            -- talking to and the window you are looking at are untouched.
            --
            -- Said BEFORE the work, because the work blocks: killing the player,
            -- waiting for it to go and bringing it back is about four seconds, and
            -- a menu that simply stops for four seconds reads as a hang.
            ui_say("Switching to " .. n .. " kbps\u{2026}")
            -- Before the restart: ensure_spotifyd reads the saved value.
            save_bitrate(n)
            Util.restart_daemons()
            ui_say("Bitrate " .. n .. " kbps")
        end
    end
    end)
end

-- Whether spotifyd caches the TRACKS it streams -- spoot's own artwork and data
-- caches are not this setting and are not touched by anything here.
--
-- Same shape as Util.view_bitrate above, for the same reason: the flag is read
-- when spotifyd is spawned, so a change means a restart, and nothing is written
-- until that restart is confirmed.
--
-- The one thing this owns that bitrate does not is the purge. librespot keeps
-- whole tracks in 256 two-hex-char directories next to its credentials (oauth/,
-- zeroconf/) and its saved volume; matching that glob is what lets the row empty
-- the audio without costing a re-auth. The glob stays OUTSIDE shell_quote so the
-- shell still expands it -- the same shape as the .api_hdr.* sweep in
-- ensure_cache -- and the SAME glob measures and removes, so the number on the
-- row cannot describe a different set of files than the one that goes.
Util.view_track_cache = function()
    Util.scope({view="track-cache"}, function()
    local audio = shell_quote(P.spotifyd) .. "/[0-9a-f][0-9a-f]"
    -- -c for the total line, since the glob expands to up to 256 arguments.
    -- Measured at 3ms warm on a 15 GB / 1,685-file cache: one fork on a menu
    -- that was opened deliberately, not on any draw path.
    local function cached_size()
        local out = shell("du -shc " .. audio .. " 2>/dev/null | tail -1")
        local sz = out and out:match("^(%S+)")
        -- A glob that matches nothing is passed through LITERALLY by the shell,
        -- so du errors into /dev/null and -c still prints a "0 total" line. That
        -- is the empty cache, and it has to read as nothing here or the row would
        -- offer to delete "0" of tracks.
        if not sz or sz == "0" then return nil end
        return sz
    end
    while true do
        local on = Util.track_cache_on()
        local function row(label, checked)
            if not checked then return label end
            return Util.markup('<span foreground="#b6e0a4">') .. "\u{f00c} " .. label
                .. Util.markup("</span>")
        end
        local sz = cached_size()
        -- "(default)" marks the shipped state the way the bitrate picker marks
        -- 160 kbps; the name beside it comes from Util.track_cache_label so it
        -- cannot drift from the System row that opened this.
        local opts = {row(Util.track_cache_label(true) .. " (default)", on),
                      row(Util.track_cache_label(false), not on),
                      "Clear Cached Tracks" .. (sz and (SEP .. sz) or "")}
        local sel = ui_menu(opts,
            {prompt="Track Cache", mesg="Current: " .. Util.track_cache_label(on), by_index=true,
             theme=THEME_SUB, art=false, context=true, sticky=true})
        if not sel then return end
        if sel == 3 then
            if not sz then
                ui_say("No cached tracks")
            else
                local c = ui_menu({"Clear Cache", "Abort"},
                    {prompt="Track Cache", mesg="delete " .. sz .. " of cached tracks?", by_index=true, theme=THEME_SUB, confirm=true, art=false, context=true})
                if c == 1 then
                    -- No restart: a file the daemon has open stays readable until
                    -- it closes it, and anything else simply streams again on the
                    -- next play. Credentials are untouched, so playback continues
                    -- without re-pairing the device.
                    os.execute("rm -rf " .. audio .. " 2>/dev/null")
                    ui_say("Cleared " .. sz .. " of cached tracks")
                end
            end
        else
            local want = (sel == 1)
            if want ~= on then
                -- Applied on the pick, exactly as the bitrate is and for the same
                -- reasons -- see Util.view_bitrate. The two carried identical
                -- confirmations; leaving one of them behind would have been the
                -- same prompt asking the same wrong question in one place only.
                --
                -- The DESTRUCTIVE row above still confirms. Clearing the cache
                -- deletes gigabytes of audio and cannot be undone; changing a flag
                -- and restarting a daemon can be changed back by pressing the
                -- other row.
                ui_say(Util.track_cache_label(want) .. "\u{2026}")
                -- Before the restart: ensure_spotifyd reads the saved value.
                Util.save_track_cache(want)
                Util.restart_daemons()
                ui_say("Track Cache " .. Util.track_cache_label(want))
            end
        end
    end
    end)
end

-- THE KEYMAP, as data. It was a list of pre-padded STRINGS built for rofi,
-- which takes one blob of text and lays out nothing -- hence the hand-counted
-- 15-column indent. As a table it can be rendered properly by a front end
-- that has a layout engine, and it stays the single source for both the
-- sheet and anything else that wants to know what a key does.
--
-- A binding with no key is a note about the one above it.
Util.KEYBINDS = {
    {key = "tab", desc = "trail menu / history"},
    {key = "return", desc = "select -- play/pause/resume selected item"},
    {key = "delete", desc = "delete entry in search or trail history"},
    {key = "escape", desc = "clear filter, then hide spoot"},
    {key = "backspace", desc = "clear filter, then back one level"},
    {key = "alt = / -", desc = "quick seek + / - 10s"},
    {key = "shift return", desc = "hovered item's action menu"},
    {key = "alt delete", desc = "clear session"},
    {key = "alt return", desc = "jump to main menu"},
    {key = "alt e", desc = "jump to seek menu"},
    {key = "alt l", desc = "jump to liked tracks"},
    {key = "alt p", desc = "jump to recently played"},
    -- Bound since the keymap was written and never listed here, which made the
    -- sheet a partial answer to the one question it exists to answer.
    {key = "alt t", desc = "jump to top tracks"},
    {key = "alt q", desc = "jump to your queue"},
    {key = "space", desc = "play / pause -- unless you are typing"},
    {key = "alt y", desc = "jump to lyrics of current track"},
    {key = "alt a", desc = "jump to albumart of current track"},
    {key = "alt r", desc = "cycle repeat modes"},
    {key = "alt s", desc = "toggle shuffle"},
    {key = "alt g", desc = "open spotify web link"},
    {key = "alt c", desc = "jump to the playing track -- from any view"},
    {key = nil, desc = "walks back to the list it was played from"},
    {key = nil, desc = "or opens playback if that list is gone"},
    {key = "alt left / right", desc = "walk back and forth along the trail"},
    {key = nil, desc = "non-destructive -- the trail stays whole"},
    {key = "ctrl left / right", desc = "previous / next track"},
    {key = "tab", desc = "the trail menu -- every step of the whole path"},
    {key = nil, desc = "or click a step in the breadcrumb itself"},
    -- Last, and about this sheet: the one binding you cannot find by reading the
    -- sheet unless the sheet says it.
    {key = "f1", desc = "this list, from anywhere"}
}

-- THE KEYMAP AS A SHEET. Structured, so the front end can lay out two real
-- columns and size itself to the content; rofi got a padded string because it
-- could do neither.
--
-- ONE FUNCTION, TWO CALLERS. It was written inline in the System menu, which is
-- the only place it could be reached from -- so F1 had nothing to call. See
-- SERVE_VIEWS.keybinds.
function Util.show_keybinds()
    Util.serve_write({ev = "sheet", kind = "keybinds", theme = "binds",
                      title = "Keybinds", rows = Util.KEYBINDS})
end

local function view_system()
    local cur_br = get_saved_bitrate()
    local cur_tc = Util.track_cache_on()
    local cur_vol = get_playerctl_volume()
    local vol_label = cur_vol == 0 and "Muted" or (cur_vol .. "%")
    local function tc_row(on) return Util.setting_row("Track Cache", Util.track_cache_label(on)) end
    local items = {"Keybinds",
                   Util.setting_row("Volume", vol_label),
                   Util.setting_row("Bitrate", cur_br .. " kbps"),
                   tc_row(cur_tc),
                   "UI Settings",
                   "Jump to Trail Step",
                   "Clear Session",
                   "Refresh Library",
                   "Re-authenticate",
                   -- The DEVICE's login, which is not the account's -- see
                   -- Util.device_auth. Its own row because it fails on its own:
                   -- an account can be signed in perfectly while spotifyd has no
                   -- credentials, and the symptom of that is menus that work and
                   -- a Play key that does nothing.
                   "Authorise Playback",
                   -- NO "Restart" ROW. It respawned spotifyd and the two helper
                   -- processes, which was worth a row when those were three
                   -- separate things that could each be wedged. The watchers are
                   -- inside spoot now, and the one remaining daemon is respawned
                   -- by the two places that actually need it -- a bitrate change
                   -- and a device authorisation -- both of which do it
                   -- themselves. Restarting it by hand fixed nothing that was
                   -- still broken.
                   "Quit"}
    -- Rows 2 to 4 are patched in place below as the volume, bitrate and track
    -- cache change, so the cursor is remembered by these stable keys rather than
    -- by the label (which no longer matched once it had been rewritten). See
    -- Util.pos_row. Index-parallel with `items`: a row added to one is a row
    -- added to the other, at the same position.
    local keys = {"keybinds", "volume", "bitrate", "trackcache", "uisettings",
                  "trailjump", "clearsession", "refresh", "reauth", "deviceauth",
                  "kill"}
    Util.scope({view="system"}, function()
    while true do
        local sel = ui_menu(items, {prompt="System", theme=THEME_SUB})
        if not sel then break end
        local clean = Util.strip_markup(sel)
        if clean == "Keybinds" then
            Util.show_keybinds()
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
        elseif clean:match("^Track Cache") then
            Util.view_track_cache()
            cur_tc = Util.track_cache_on()
            items[4] = tc_row(cur_tc)
        elseif clean == "UI Settings" then
            Util.view_ui_settings()
        elseif clean == "Refresh Library" then
            -- Synchronous, unlike the background revalidator: this row exists to
            -- be waited on. ui_say rather than a desktop notification,
            -- matching every other System row -- caching has no business
            -- interrupting the desktop, but a row that blocks for half a minute
            -- and then says nothing reads as broken.
            local ok = Util.rebuild_library()
            if ok then populate_liked_ids() end
            ui_say(ok and "Library refreshed" or "Library refresh failed")
        elseif clean == "Re-authenticate" then
            -- The only way to widen the granted scope set, and the only way to
            -- recover a revoked one without deleting token.json by hand. A
            -- refresh grant returns whatever was authorised the FIRST time,
            -- however much OAUTH_SCOPES has grown since.
            ui_say(Util.reauth() and "Re-authenticated"
                or "Re-authentication failed")
        elseif clean == "Authorise Playback" then
            -- Reads the credentials back rather than trusting the helper's exit
            -- status, and replaces the daemon on success: spotifyd reads its
            -- credentials at launch, so the one already running would still be
            -- unauthenticated.
            if Util.device_auth() then
                Util.restart_daemons()
                ui_say("Playback device authorised")
            else
                ui_say("Could not authorise the playback device")
            end
        elseif clean == "Jump to Trail Step" then
            Util.view_trail_jump(_session_stack)
            main_pending = true
            break
        elseif clean == "Clear Session" then
            Util.clear_trail()
            main_pending = true
            break
        elseif clean == "Quit" then
            os.execute("pkill -x spotifyd 2>/dev/null")
            os.execute(Util.own_procs("--daemon"))
            Util.kill_recent_watch()
            Util.kill_playerctl_follow()
            Util.drop_search_cache()
            -- Session AND trail: this row is a shutdown, and clean_exit's
            -- os.exit means no scope unwinds to rewrite session.json -- so the
            -- stack was left naming THIS menu, and the next launch replayed
            -- straight back into it instead of opening on Main.
            Util.clear_trail()
            -- THE WINDOW GOES TOO. This row used to be "Kill Daemons": it swept
            -- the background processes, ran `pkill -x rofi` to take the menu
            -- with them, and exited. There is no rofi to kill, and the window is
            -- no longer a process that dies when this one does -- it is a host
            -- that OWNS this one, so exiting here left it holding a dead pipe
            -- with nothing to draw and no way to say so.
            --
            -- So the host is told first, and given a moment to go, before the
            -- engine follows it out.
            Util.serve_write({ev = "quit"})
            os.execute("sleep 0.2")
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
-- qualify is the opposite case: the view's name is not its own but its PARENT's,
-- shared with sibling views, so the label is appended rather than replaced --
-- "Bad Bunny > Top Tracks". See Util.step_name.
local function reg(view, label, open, label_only, qualify)
    VIEWS[view] = {label = label, open = open, label_only = label_only, qualify = qualify}
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
-- LEGACY, like artist-actions below: nothing pushes this any more, because a
-- context menu is not a place you went. It stays registered so a session.json /
-- trails.json / menu history written before that change still names its step and
-- still replays.
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
-- LEGACY, for the reason given at playlist-actions above: view_artist is a
-- context menu and no longer takes a stack entry, the way album_action_menu
-- never had one.
reg("artist-actions", "Artist", function(s)
    if s.artist_id then view_artist({id=s.artist_id, name=s.artist_name or ""}) end
end)
-- All four carry the SAME artist_name, so each is qualified by its label (see
-- reg): without that the trail read "Bad Bunny" whichever of them you opened.
reg("artist-albums", "Albums", function(s)
    if s.artist_id then Util.browse_artist_albums(s.artist_id, s.artist_name) end
end, nil, true)
reg("liked-by-artist", "Liked Tracks", function(s)
    if s.artist_id then Util.browse_liked_by_artist(s.artist_id, s.artist_name) end
end, nil, true)
reg("top-by-artist", "Top Tracks", function(s)
    if s.artist_id then Util.browse_top_by_artist(s.artist_id, s.artist_name) end
end, nil, true)
reg("related", "Related", function(s)
    if s.artist_id then Util.browse_related_artists(s.artist_id, s.artist_name) end
end, nil, true)
reg("search", "Search", function() view_search() end)
reg("liked",            "Liked Tracks",     function() view_liked_tracks() end)
reg("top-tracks",       "This Month's Top", function() view_top_tracks() end)
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
reg("track-cache",      "Track Cache",      function() Util.view_track_cache() end)
reg("ui-settings",      "UI Settings",      function() Util.view_ui_settings() end)
-- A picker for ONE setting, restored by which one it was. Registered for the
-- same reason its siblings are: a warm start that lands mid-menu should land
-- where it was, and a view missing from here warns on every launch.
reg("ui-setting", "UI Settings", function(sc)
    local spec = sc.setting and Util.ui_setting(sc.setting)
    if spec then Util.ui_pick(spec) end
end)
reg("playback",         "Playback",         function() view_playback() end)
reg("listen-history",   "Heard",            function() Util.view_listen_history() end)
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

-- tip/tip_roots are the UI's own breadcrumb: the WHOLE path, across every root,
-- including the part ahead of the cursor. `stack` is one segment of it -- the
-- last one -- which is all this menu ever listed, so a trail reading
--
--     Main > Liked Tracks  ⟐  Top Tracks  ⟐  Top Tracks
--
-- offered two rows out of four and no way to reach the first half of the walk at
-- all. Only the UI holds the hop list that spans roots, so only the UI can say
-- what the whole path is -- and, below, only the UI can walk back into it.
-- `mode` is "trail" or "history", or nil to let this choose. WHICH FACE IS
-- SHOWING IS AN ARGUMENT, not a step: Tab used to be answered as a path step, and
-- a path step is a thing the engine replays -- so crossing between the two faces
-- wrote itself into the very trail the menu exists to show you, and `sticky` then
-- reverted it, leaving the card drawing one face while the path described the
-- other. Everything after that was picked out of the wrong list.
--
-- As an argument it is carried by the card's own hop, which lives beside the
-- trail and never on it (see main.qml's tabHere), so crossing costs no step, no
-- crumb and no replay.
function Util.view_trail_jump(stack, tip, tip_roots, mode_arg)
    local SEP = "  \u{F17B7}  "
    local opts = {}
    local function push(prefix, name, ostack, depth)
        opts[#opts+1] = {label=prefix .. name, stack=ostack, depth=depth}
    end
    local first = true
    -- Same guard as Util.parts_from_stack: a junk stack entry must not be able
    -- to take the whole menu down.
    -- Naming goes through Util.step_name, the same function the breadcrumb uses,
    -- because this menu lists the very steps that one renders -- the two
    -- disagreeing would mean jumping to a step whose label you never saw. Only
    -- the join differs: a row is ONE entry, so a qualified step wears its label
    -- inline ("Bad Bunny > Top Tracks") where the crumb spends two steps on it.
    local function step_label(e)
        if type(e) ~= "table" then return view_label(nil) end
        local name, qual = Util.step_name(e)
        if qual then return name .. Util.crumb_arrow(" > ") .. qual end
        return name
    end
    local function add_trail(stk, with_main)
        if with_main then
            push(first and "" or SEP, "Main", stk, 0)
            first = false
            if stk then
                for i = 1, #stk do
                    push(Util.crumb_arrow("> "), step_label(stk[i]), stk, i)
                end
            end
            return
        end
        if not stk or #stk == 0 then return end
        for i = 1, #stk do
            push(i == 1 and (first and "" or SEP) or Util.crumb_arrow("> "),
                 step_label(stk[i]), stk, i)
        end
        first = false
    end
    for _, t in ipairs(Util.trail_history) do
        if type(t) == "table" and type(t.stack) == "table" then add_trail(t.stack) end
    end
    -- THE WHOLE PATH when the UI has told us what it is, and the single segment
    -- the engine can see when it has not (an older UI, or a call from somewhere
    -- that has no breadcrumb to offer). Rows carry a crumb INDEX rather than a
    -- stack: a jump across roots is a move along the hop list, which lives in the
    -- UI, so picking one of these answers with an event instead of a menu.
    if type(tip) == "table" and #tip > 0 then
        local seams = {}
        for _, r in ipairs(tip_roots or {}) do seams[r] = true end
        for i = 1, #tip do
            local pre = (i == 1) and (first and "" or SEP)
                     or (seams[i - 1] and SEP or Util.crumb_arrow("> "))
            opts[#opts+1] = {label = pre .. tostring(tip[i]), crumb = i - 1}
        end
        first = false
    else
        add_trail(stack, true)
    end
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
    -- THE FACE THE CALLER ASKED FOR, when it asked and that face has anything to
    -- show. Falling back rather than obeying blindly is what keeps Tab from
    -- landing you on an empty list: with no trail there is nothing to cross TO,
    -- and the menu says so on its own hint line instead.
    local mode = have_trail and "trail" or "history"
    if mode_arg == "history" then mode = "history"
    elseif mode_arg == "trail" and have_trail then mode = "trail" end
    if not have_trail and #(Util.menu_hist_rows(stack)) == 0 then
        ui_say("You left no trail")
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
            -- line is ever truncated (see ui_menu), and this one is short, so
            -- the hint underneath always survives intact.
            local title = mode == "trail" and "Trail Steps" or "Trail History"
            -- A CARD, over wherever you already are. This is the one menu that
            -- is entirely ABOUT where you have been, so replacing the view you are
            -- standing in with it hid the very thing the list is offering to take
            -- you back to.
            --
            -- IT OWNS TAB, which is how you cross between the steps you are on and
            -- the menus you closed -- and that key is what broke the first time
            -- this floated: main.qml's tabHere read the list BEHIND the card for
            -- the row to send, so Tab answered with whatever happened to be
            -- highlighted underneath. Fixed there, in the binding, rather than
            -- here by refusing to float.
            --
            -- STICKY, so Tab can swap between the two modes without the card
            -- closing between them: they are one card being redrawn, which is
            -- exactly the case sticky exists for.
            local idx = ui_menu(labels, {prompt = title,
                mesg = title .. "\n" .. hint, by_index=true,
                theme=Util.THEME_TRAIL, tab_select=true,
                context=true, sticky=true, art=false,
                -- AND NO PICTURE, EVER. A card's cover is resolved from whatever
                -- named one on the way in (Util.serve_card_art), and a replayed
                -- parent step counts: press the trail key inside an album and the
                -- album's own sleeve was still recorded, so the card came up
                -- wearing it. This menu is about PLACES -- there is no one thing
                -- it is a picture of -- and `art=false` cannot say that, because
                -- every action menu sets it too and those now want their subject.
                no_cover=true,
                -- WHICH FACE THIS IS. The only menu that sends one, and the UI
                -- uses its presence to know that Tab here means "show me the
                -- other one" rather than "send a tab step". See serve_draw.
                mode=mode,
                -- Only Trail History. A trail STEP is a place you can still go
                -- back to, not a record you would want to erase, and the rows in
                -- that mode are shared with the live stack.
                del_select = (mode == "history") or nil})
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
            if idx >= 1 and idx <= #opts and opts[idx].crumb then
                -- ACROSS ROOTS, so the UI walks it. The hop list is the only
                -- description of a path that spans segments, and the engine does
                -- not have one -- it is handed a trail per request and answers a
                -- menu. So this says WHICH step was picked and draws nothing; the
                -- UI moves its cursor there and asks again, which replays the
                -- right stack on the way.
                Util.serve_write({ev = "jump", crumb = opts[idx].crumb})
                return
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

-- ============================================================================
-- WHAT THIS MACHINE HAS
-- ============================================================================
--
-- A dependency SYSTEM used to live here: a table of every program spoot shells
-- out to, a package manager per distribution, a way to become root, and an
-- installer that ran on first launch and raised an authentication dialog over
-- spoot's own surface to finish. All of it is gone, and the reason is that it
-- was in the wrong program. `setup` installs everything before spoot ever runs,
-- so by the time this file is loaded the question has already been answered.
--
-- What survives is the one-line question itself, because three places that have
-- nothing to do with installing anything still need to ask it: the notification
-- fallback, the device check, and the login preconditions below.
function Util.have(bin)
    return trim(shell("command -v " .. shell_quote(bin) .. " 2>/dev/null") or "") ~= ""
end

-- The other half of "is this machine ready" -- programs are not enough, the two
-- logins have to have happened. Same text for --doctor and for anything else
-- that needs to say what is outstanding.
function Util.setup_report()
    local st = Util.setup_state()
    local L = {}
    L[#L+1] = "account:  " .. (st.token and "signed in" or "NOT signed in")
    L[#L+1] = "device:   " .. (st.device and "authorised"
                               or "NOT authorised (spotifyd has no credentials, so nothing plays)")
    if #st.lack > 0 then
        L[#L+1] = "blocked:  cannot sign in without " .. table.concat(st.lack, ", ")
    end
    return table.concat(L, "\n")
end

-- ============================================================================
-- THE PLAYBACK DEVICE'S OWN LOGIN
-- ============================================================================
--
-- spoot has two logins and they are not the same login. The token in token.json
-- is spoot's -- it authorises the Web API calls that draw every menu. spotifyd
-- has its own, stored as credentials.json in its cache, and without it the
-- daemon runs as an unauthenticated Connect target: it appears on the network,
-- it never appears in the account's device list, and every play lands nowhere.
--
-- That is the whole of "nothing plays after a fresh install". It worked before
-- only because the cache already held credentials from a login nobody remembered
-- making, and clearing the cache took them with it.
--
-- spotifyd 0.4 does this itself through `spotifyd authenticate`, which is the
-- only supported route left -- password login is gone. It prints the URL rather
-- than opening it, so this drives the browser on its behalf.
-- SAYING WHAT IS HAPPENING WHILE THE PANEL IS HIDDEN. Both logins put a page in
-- your browser, and the UI takes itself off screen for the duration -- so its own
-- notice bar is exactly what you cannot see. Two unexplained browser tabs in a
-- row is a worse first run than two explained ones. Silent if notify-send is not
-- installed, which is why it is optional rather than required.
function Util.setup_notify(title, body)
    Util.notify{title = title, body = body or ""}
end

function Util.device_ready()
    -- NON-EMPTY, not merely present. read_file answers "" for a zero-byte file
    -- and "" is TRUE in Lua, so a credentials.json that exists but has not been
    -- written yet reads as authorised. That was harmless while this only looked
    -- at a path spotifyd 0.4 never writes; it is not harmless now, because the
    -- poll in Util.device_auth below stops the moment this says yes and then
    -- KILLS the `spotifyd authenticate` that was still filling the file --
    -- leaving an empty one that says "ready" for good, with no route back.
    local function filled(p)
        local s = read_file(p)
        return s ~= nil and #s > 0
    end
    -- spotifyd 0.4.2 keeps its OAuth credentials in <cache>/oauth/credentials.json
    -- (written by `spotifyd authenticate`) and its session credentials in
    -- <cache>/zeroconf/credentials.json. Either means playback is authorised.
    for _, dir in ipairs({"oauth", "zeroconf"}) do
        if filled(P.spotifyd .. "/" .. dir .. "/credentials.json") then return true end
    end
    -- Older spotifyd (pre-0.4) used <cache>/credentials.json directly.
    return filled(P.spotifyd .. "/credentials.json")
end

function Util.device_auth()
    if Util.device_ready() then return true end
    if not (Util.have("spotifyd") and Util.have("xdg-open")) then return false end
    os.execute("mkdir -p -m 700 " .. shell_quote(P.spotifyd) .. " 2>/dev/null")
    os.remove(P.device_log)
    -- Backgrounded, because it holds its OAuth port until the login completes,
    -- and stdin closed for the reason every other child here has it closed: this
    -- process reads the UI's requests from it.
    os.execute("spotifyd authenticate -c " .. shell_quote(P.spotifyd)
        .. " </dev/null >" .. shell_quote(P.device_log) .. " 2>&1 & echo $! > "
        .. shell_quote(P.device_pid))
    -- It announces itself as "Browse to: <url>". Waited for rather than assumed:
    -- the port may be taken, in which case it dies instead and there is no URL to
    -- open -- which is worth reporting rather than sitting through.
    local url
    for _ = 1, 100 do
        url = (read_file(P.device_log) or ""):match("Browse to:%s*(%S+)")
        if url then break end
        os.execute("sleep 0.1")
    end
    if url then os.execute("xdg-open " .. shell_quote(url) .. " >/dev/null 2>&1 &") end
    -- The credentials file appearing IS the success signal -- the same "believe
    -- the system, not the exit code" rule the dependency install follows.
    for _ = 1, 180 do
        if Util.device_ready() then break end
        os.execute("sleep 1")
    end
    local pid = trim(read_file(P.device_pid) or "")
    if pid:match("^%d+$") then os.execute("kill " .. pid .. " 2>/dev/null") end
    os.remove(P.device_pid)
    return Util.device_ready()
end

-- WHAT A FIRST RUN STILL OWES, in the order it has to happen. Dependencies come
-- first and are not negotiable: the account login needs openssl to build the
-- challenge and xdg-open to show you the page. Authorising before those exist
-- fails two ways.
--
-- Reported as state rather than as a verdict, so the caller can say what it is
-- waiting for instead of just failing.
function Util.setup_state()
    -- NOT curl, and no longer perl. Both were part of the login and neither is
    -- any more: the requests go through the host's own network stack, and the
    -- redirect is caught by a socket the host opens (see oauth_get_token). perl
    -- survives only as the fallback for a spoot running under a bare
    -- interpreter, which is not the thing being set up here -- listing either
    -- would block a sign-in over a program the sign-in does not use.
    local names = {"openssl", "xdg-open"}
    local lack = {}
    for _, b in ipairs(names) do
        if not Util.have(b) then lack[#lack + 1] = b end
    end
    return {token = read_file(P.token) ~= nil,
            device = Util.device_ready(),
            lack = lack}
end

-- MAIN

local function init_instance_lock()
    local lock = P.instance_lock
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
    os.execute("rm -f " .. shell_quote(P.oauth_code)
        .. " " .. shell_quote(P.oauth_pid) .. " 2>/dev/null")
    local pid = Util.get_own_pid()
    if pid then Util.secure_write(lock, tostring(pid)) end
end

-- WHO WATCHES, and whether it needs a process to do it. Embedded, the host runs
-- both watchers itself -- an MPRIS subscription and a 25s timer, posting
-- `daemon-snap` and `recent-tick` in -- so spawning these would give the same
-- work two owners: two notifications per track, two recorders racing over
-- Recently Played. Any left over from a previous build is reaped instead, which
-- is what makes the first embedded start clean without asking anything of the
-- user.
--
-- The return value is whether the daemon was ALREADY running, which main() reads
-- as "not a cold start". Embedded there is no daemon to have been running, and
-- the host has just started, so it is a cold start by definition.
local function ensure_daemon()
    if Util.hosted then
        -- REAPED FIRST, CLAIMED SECOND. Whatever was watching before this
        -- process started has to stop before its pid file is overwritten with
        -- ours, or the only handle on it is gone and it runs forever alongside
        -- the embedded watcher -- two of everything, and every track change
        -- notified twice.
        Util.kill_pidfile(P.daemon_pid)
        os.execute(Util.own_procs("--daemon"))
        -- ...and now the file says us. Anything that later asks whether a daemon
        -- is running -- a `spoot --doctor`, a guard run -- reads it, and the
        -- answer has to be yes or it starts a second watcher.
        local mypid = Util.get_own_pid()
        if mypid then Util.secure_write(P.daemon_pid, tostring(mypid)) end
        -- AND THE PIPE IT HELD OPEN. The follow stream is a grandchild -- a
        -- shell holding a playerctl -- so killing the daemon reparents it to
        -- init rather than ending it, and it would sit there for the rest of
        -- the session doing nothing. daemon_mode clears it on its own way in
        -- for the same reason.
        Util.kill_playerctl_follow()
        return false
    end
    -- No marker. The owner of this file is either `spoot.lua --daemon` or the
    -- spoot binary watching MPRIS itself, and both are "a daemon is running";
    -- the cmdline check inside still keeps a recycled pid from answering yes.
    local daemon_alive = Util.pidfile_owner_alive(P.daemon_pid)
    if not daemon_alive then
        Util.spawn_self({"--daemon"}, P.daemon_log)
    end
    return daemon_alive
end

function Util.ensure_recent_watch()
    if Util.hosted then
        Util.kill_pidfile(P.recent_pid)
        os.execute(Util.own_procs("--recent-watch"))
        local mypid = Util.get_own_pid()
        if mypid then Util.secure_write(P.recent_pid, tostring(mypid)) end
        return
    end
    local alive = Util.pidfile_owner_alive(P.recent_pid)
    if not alive then
        Util.spawn_self({"--recent-watch"}, P.recent_log)
    end
end

-- Our own helpers, named exactly. `pkill -f 'spoot.*--daemon'` matched any
-- process with "spoot" and "--daemon" anywhere in its command line -- including
-- the rofi build's, which is a different program that happens to share a name.
-- Killing it from here was a cross-build reach that only made sense while the
-- two were one thing.
-- EITHER FORM OF OURSELVES. A helper used to be reachable only one way --
-- `lua <dir>/spoot.lua --daemon` -- and matching that exact string is what kept
-- this from killing some other program that happens to have "spoot" and
-- "--daemon" on its command line. Since the flags became subcommands of the
-- binary there is a second spelling, `<...>/bin/spoot --daemon`, and matching
-- only the first meant spoot silently failed to reap a daemon started that way:
-- two watchers, and every track change notified twice.
--
-- Both patterns are still anchored to a path inside THIS installation, which is
-- what keeps the reach narrow.
-- KILL WHOEVER OWNS THIS PIDFILE, if it is one of ours. The pattern reapers
-- below match a command line, which cannot work for a helper started as
-- `./bin/spoot --daemon`: pkill sees the relative path it was invoked with, and
-- an absolute pattern never matches it. The pid file does not care how the
-- process was spelled, and every helper writes one on its way in.
--
-- Still checked before killing -- a stale file whose pid has been recycled must
-- not take an unrelated process with it. Util.pidfile_owner_alive is that check.
-- NEVER OURSELVES. A helper used to be a PROCESS, so a pid file named something
-- that could be killed; with a host it is a JOB -- a thread in this very
-- process -- and Util.get_own_pid, which reads /proc/self/stat, answers the
-- HOST's pid from inside one. So every helper's pid file now names spoot, and
-- every reaper below was pointed straight at it.
--
-- That is "changing the bitrate closes spoot": Util.restart_daemons reaps the
-- daemon and the recent-watch on its way through, and reaping them sent spoot a
-- SIGTERM. It was reachable from the device authorisation too, and from the
-- track-cache toggle -- everything that restarts the player.
--
-- A thread cannot be signalled and does not need to be: the job pool refuses a
-- second job under the same key (see JobPool::submit), so the respawn that
-- follows a reap is already a no-op while one is running. What had to stop was
-- the killing.
function Util.self_pid()
    if not Util._self_pid then Util._self_pid = Util.get_own_pid() end
    return Util._self_pid
end
function Util.kill_pid(pid)
    local p = trim(tostring(pid or ""))
    if not p:match("^%d+$") then return false end
    if tonumber(p) == Util.self_pid() then return false end
    os.execute("kill " .. p .. " 2>/dev/null")
    return true
end

function Util.kill_pidfile(path, marker)
    if not Util.pidfile_owner_alive(path, marker) then
        os.remove(path)
        return false
    end
    local killed = Util.kill_pid(trim(read_file(path) or ""))
    os.remove(path)
    return killed
end

function Util.own_procs(flag)
    local root = P.dir:gsub("/engine/?$", "")
    return "pkill -f " .. shell_quote(P.dir .. "/spoot.lua " .. flag) .. " 2>/dev/null; "
        .. "pkill -f " .. shell_quote(root .. "/bin/spoot " .. flag) .. " 2>/dev/null"
end

function Util.kill_recent_watch()
    -- Through Util.kill_pid, which refuses our own pid -- see the note there.
    -- This was the site that actually fired: it read the pid file and killed
    -- whatever it named with no cmdline test at all, and under a host that file
    -- names spoot.
    Util.kill_pid(trim(read_file(P.recent_pid) or ""))
    os.execute(Util.own_procs("--recent-watch"))
    os.remove(P.recent_pid)
end

function Util.kill_playerctl_follow()
    os.execute("pkill -f 'playerctl[ -]--follow metadata' 2>/dev/null")
end

-- One reader for the cooldown file, in Util.rate_cool -- three copies of the
-- same "is it still shut" arithmetic stood in this file and the ceiling bug lived
-- in a fourth.
local function check_rate_cooldown()
    local left = Util.rate_cool()
    if left <= 0 then return false end
    ui_say("Spotify API rate limit active.\nRetry after " .. left .. "s.")
    return true
end

-- PLAYBACK state only. Runs on a cold start (MPRIS daemon not alive, so the
-- now-playing caches are stale) and from System > Restart. It must NOT
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
-- assets/<key>.png is consulted by name.
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
     -- assets/playback.png instead of the last track's cover. It is not
     -- dimmed for it -- Playback is always openable -- which is why the state is
     -- "noart" and not "empty".
     -- Cover only: this opens the transport menu, which has its own fixed rows
     -- whether or not anything is playing.
     art_only = true,
     art  = function()
        if current_track then return current_track, "ok" end
        return nil, "noart"
     end},
    -- No `art`: this one wears assets/collections.png rather than borrowing
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
     fallback = Util.ART_NONE}
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
        -- MAIN HAS NO CAPTION. It carried the shuffle/repeat pair and the
        -- playing track, folded in by hand because ui_menu only prepends a
        -- status line for non-thumbnail menus and the grid themes have none.
        -- Both halves have a better home now: the pair is drawn in the
        -- now-playing strip (Theme.glyphShuffleOn), where it is true on every
        -- view rather than only on this one, and the track is the strip's whole
        -- subject. What is left for Main to say about itself is its name, and
        -- the crumb already says that.
        local mesg = nil

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
        -- `sel` is set only on the first draw; passing nil leaves ui_menu's
        -- own pos_key restore in charge, which is what every later draw wants.
        -- `theme` overrides only the theme choice; `thumbs` still selects the
        -- grid's row count, icon thread pool and status-line suppression.
        local sel = ui_menu(entries, {prompt="Spotify", mesg=mesg, by_index=true, thumbs=true,
            theme=Util.THEME_MAIN, alt_select=true,
            refresh=function()
                tiles = Util.shelf_tiles(Util.MAIN_TILES)
                -- Captions too, not just art: a redraw is how the grid picks up
                -- a shelf that emptied (or filled) since this draw began.
                labels()
                Util.album_thumbs(entries, tiles, "main", Util.pos_get(main_key), main_key)
                return entries
            end})
        -- Read immediately, per the contract on Util.alt_pressed: the next
        -- ui_menu, nested or not, clears it -- and the pending-flag branches
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

-- THE DAEMON'S EYE, hoisted out of daemon_mode so both callers reach the same
-- code: the standalone `--daemon` process, which still exists for a spoot that
-- is not running, and the embedded host, which watches MPRIS itself and posts
-- each change in as a `daemon-snap` request. Per-track state lives on Util
-- rather than in upvalues because the embedded caller arrives once per snap
-- instead of looping.

-- Dedupe lives here, ahead of the spawn, so a burst of MPRIS snaps for one
-- track starts exactly one notify helper.
-- On Util, not a file local: this chunk is at Lua's 200-local ceiling.
function Util.notify_seen(track_id)
    if not (track_id and #track_id > 0) then return false end
    local prev_id = read_file(P.last_notify)
    if prev_id and trim(prev_id) == track_id then return true end
    Util.secure_write(P.last_notify, track_id)
    return false
end

-- A SNAP IS A TABLE, from either source: Util.mpris for the one-shot read
-- and Util.mpris_split for each line of the follow stream. Both are the same
-- six fields in the same order, which is the point of them sharing a parser.
function Util.daemon_snap(snap)
    if not snap then return end
    local title, artist, art_url, track_id, album, duration_raw =
        snap.title, snap.artist, snap.art, snap.trackid, snap.album, snap.length
    local track_kind
    track_id, track_kind = Util.extract_track_id(track_id)
    local duration = tonumber(duration_raw) and tonumber(duration_raw) / 1000000 or nil
    local track_changed = track_id and #track_id > 0 and track_id ~= Util.snap_id
    local title_changed = title and title ~= "" and title ~= Util.snap_title
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
            playing=(Util.mpris{op = "status"}.value or "") == "Playing" }))
        Util.snap_id = track_id
    end
    if title and title ~= "" then Util.snap_title = title end
    -- One helper instead of three spawns plus an inline notify. The old
    -- order was self-defeating: the notification was composed two statements
    -- after launching --prefetch-track/--prefetch-lyrics, reading caches
    -- those processes had not written yet, so a track's first play always
    -- lost its explicit and lyrics glyphs -- and the dedupe above meant they
    -- were never filled in later. The helper fetches first, notifies last,
    -- off this loop so nothing blocks the playerctl --follow stream.
    if title and #trim(title) > 0 and not Util.notify_seen(track_id) then
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



local function daemon_mode()
    local lock = P.daemon_pid
    local claim = P.daemon_lock
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

    local function daemon_loop()
        Util.daemon_snap(Util.mpris{op = "metadata"}.value)
        -- THE SUBSCRIPTION. `spoot --daemon` has a bus connection of its own, so
        -- being told when the player changes costs a wait rather than a
        -- `playerctl --follow` pipe held open for the life of the process. The
        -- timeout is a heartbeat, not a poll: it returns false, nothing is read,
        -- and the loop goes back to waiting -- it exists so a daemon whose bus
        -- has gone quiet for an hour still comes back through pcall now and then.
        if Util.host and Util.host.mpris then
            while true do
                if Util.mpris{op = "watch", timeout = 60}.value then
                    Util.daemon_snap(Util.mpris{op = "metadata"}.value)
                end
            end
        end
        -- And the pipe when there is no host: `lua engine/spoot.lua --daemon`
        -- still works, and still works the way it always did.
        local p = io.popen("playerctl --follow metadata -f "
            .. shell_quote(Util.mpris_fmt) .. " 2>/dev/null", "r")
        if not p then return nil end
        for line in p:lines() do
            Util.daemon_snap(Util.mpris_split(line))
        end
        p:close()
    end

    while true do
        local ok, err = pcall(daemon_loop)
        if not ok then
            io.stderr:write("spoot daemon error: " .. tostring(err) .. "\n")
        end
        Util.wait(2)
    end
end

-- RECENT-WATCH — always-on recorder. Polls the live playback endpoint so any
-- play on the account (regardless of source or local MPRIS) lands in Recently
-- Played even while the interactive UI is closed.

-- ONE POLL of the live playback endpoint, hoisted for the same reason
-- Util.daemon_snap was: the standalone `--recent-watch` loop below calls it on
-- its own timer, and the embedded host calls it as a `recent-tick` request from
-- a QTimer, so the recorder itself exists once.
function Util.recent_tick()
    -- additional_types for the same reason get_playback carries it: without
    -- it me/player answers item: null while an episode plays, so a podcast
    -- would record nothing and count as a dropout strike. With it, episodes
    -- land in Recently Played too -- which is more than Spotify's own
    -- recently-played endpoint offers, since that one is tracks-only.
    local d = api_get("me/player", Util.with_market("additional_types=episode"))
    if not d or type(d) ~= "table" or not d.item or not d.item.id then return false end
    local id = d.item.id
    -- Free: progress_ms rides on the response this poll already makes, so
    -- recording where you are in an episode costs no request and no second
    -- process. 25s granularity is the poll interval, which is the most this
    -- can lose -- and it is 25s against "always from the beginning".
    if d.item.type == "episode" then
        Util.eresume_put(id, d.progress_ms, d.item.duration_ms)
    end
    if id ~= Util.recent_id then
        record_recent_play(d.item)
        Util.recent_id = id
    end
    return true
end

function Util.recent_watch_mode()
    Util.detached = true
    local mypid = Util.get_own_pid()
    if mypid then Util.secure_write(P.recent_pid, tostring(mypid)) end
    local nil_strikes = 0
    while true do
        local left = Util.rate_cool()
        if left > 0 then
            Util.wait(math.max(left, 1))
        else
            local ok, got = pcall(Util.recent_tick)
            if not ok then
                io.stderr:write("spoot recent-watch error: " .. tostring(got) .. "\n")
            end
            nil_strikes = (ok and got) and 0 or (nil_strikes + 1)
            Util.wait(nil_strikes >= 3 and 60 or 25)
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
                playing = (Util.mpris{op = "status"}.value or "") == "Playing"
            }))
        end
        -- Episodes have no lyrics to look up, and asking spends a request plus a
        -- negative-cache entry on every one that plays.
        if not is_ep then
            Util.fetch_and_cache_lyrics(id, title, artist or "", album, duration)
        end
    end

    -- ITS OWN ROW, ALWAYS. The marks used to ride whatever line was there --
    -- appended to the artist when there was one, standing alone when there was
    -- not -- so a track with no artist put its glyphs on line one and a track
    -- with one put them at the end of line two, and neither read as a status.
    -- Two lines every time: who it is by, then what it is. The artist line is
    -- kept even when empty, which is what makes the second line the SAME line in
    -- both cases.
    --
    -- Separator per Util.notify_break, which is a newline unless this machine's
    -- daemon is one of the ones that eats them.
    local icons = trim(Util.status_icons({id = id, explicit = track and track.explicit}))
    local caps = Util.notify_caps()
    -- ESCAPED ONLY WHERE IT IS PARSED. This was unconditional, so on a daemon
    -- that advertises no `body-markup` an ampersand in an artist's name arrived
    -- as `&amp;` -- escaping is only ever correct against something that is going
    -- to unescape it.
    local body = caps.has["body-markup"] and Util.pango_escape(artist or "")
                 or (artist or "")
    if icons ~= "" then body = body .. Util.notify_break() .. icons end
    -- ...AND NOWHERE TO PUT IT AT ALL. A daemon with no `body` shows the summary
    -- and nothing else, so the marks ride the title rather than being dropped --
    -- the one place left that is certain to be seen.
    if not caps.has.body then
        if icons ~= "" then title = title .. "  " .. icons end
        body = ""
    end

    -- ...AND THE TRANSPORT, as actions on the toast. Namespaced `spoot:` so the
    -- host can tell a press of ours from any other notification's without keeping
    -- a table of live ids -- see ToastActions in src/main.cpp. Flat key/label
    -- pairs, which is the order the D-Bus call wants them in.
    --
    -- Whether they are drawn as buttons, revealed on hover, or hidden behind a
    -- context menu is the daemon's decision and the protocol gives the sender no
    -- say in it. What is ours is that they are there.
    -- ONLY WHERE THEY CAN BE DRAWN. Attached to a daemon that does not advertise
    -- `actions` they are three keys nobody will ever see or press, and some
    -- daemons log a complaint about each one.
    Util.notify{title = title, body = body, icon = art_path,
                actions = caps.has.actions
                          and {"spoot:prev", "Previous",
                               "spoot:playpause", "Play/Pause",
                               "spoot:next", "Next"} or nil}
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
            playing = (Util.mpris{op = "status"}.value or "") == "Playing"
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
    podcast  = function() return Util.PODCAST_TILES end
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
    local pidf = P.warm_pid .. kind:gsub("[^%w_]", "") .. ".pid"
    if Util.job_running(pidf, "--warm-shelf") then return end
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
                    {id = t.key, images = imgs}, false, nil, nil)
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

-- The backspace monitor lived here: an embedded C helper compiled at runtime,
-- a uinput injector, and a --bsmon subprocess holding a shadow copy of rofi's
-- filter. All of it existed for one reason, stated in its own comment --
-- "rofi edits the filter natively, but on an empty filter the press is swallowed
-- by its keyboard grab" -- so spoot had to watch the keyboard at the evdev layer
-- to notice a Backspace it never received.
--
-- Qt delivers key events to the window that has focus. Backspace is a key now,
-- handled in ui/Keymap.qml, where it clears the filter, then steps back, then
-- exits. 447 lines, a C compiler dependency and a second process, deleted.

-- Interactive spoot is the one path with no error handling at all. An error
-- anywhere in it used to print a traceback to stderr -- which nobody sees,
-- because rofi has closed and a keybind launch has no terminal -- and then die
-- WITHOUT reaching Util.clean_exit, so a pending like/unlike reconciliation was
-- dropped by the missing flush_liked_cache() and the scratch directory
-- leaked. The window simply vanished.
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
    local log = P.crash_log
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
    -- ui_say cannot draw at all, so the fallback must not need a theme.
    pcall(Util.notify, {title = "spoot crashed", body = first, urgency = 2})
    pcall(ui_say, "spoot crashed\n" .. Util.pango_escape(first)
        .. "\n\nfull trace: " .. log)
    pcall(Util.clean_exit, 1)
    os.exit(1)   -- only reached if clean_exit itself failed before its os.exit
end

-- SERVE MODE -- the headless engine behind spoot's Qt Quick front end.
--
-- Newline-delimited JSON on stdio, three message kinds:
--   in    {"id":7,"cmd":"main","args":{}}
--   out   {"id":7,"ok":true,"data":{...}}
--   out   {"ev":"playback","pos_ms":48210}          unsolicited
--
-- Ids exist so responses may complete out of order, and events so the engine can
-- speak without being asked. Both are unnecessary today and both are why live
-- progress and lyric sync will not need the protocol rebuilt underneath them.
--
-- This is an ADAPTER over the draw path the rofi views already use, not a
-- reimplementation: the same Util.shelf_tiles, Util.tile_label and
-- Util.album_thumbs run, and the \0icon suffix album_thumbs appends is parsed
-- back off into a plain file path. Everything the art pool knows -- tiers,
-- placeholders, the detached prefetch of the tail -- therefore still happens.
-- THE TRANSPORT, decided once and named here.
--
-- Embedded in the binary there is a native queue on the other side of a thread
-- boundary; run as `lua spoot.lua --serve` there is stdio. The LINES ARE THE SAME
-- either way -- ndjson, one per line -- and that is deliberate rather than
-- incidental: keeping the wire format across the thread boundary is what stops
-- the host and the engine sharing any mutable state at all. They exchange copies
-- of bytes, exactly as two processes do, so there is nothing to race over.
--
-- rawget, not a plain lookup: this file runs under a strict-global guard in some
-- paths, and asking for an absent global must be a question rather than an error.
-- On Util, not a file local: this chunk sits at Lua's 200-local ceiling.
Util.host = rawget(_G, "spoot")
-- TWO KINDS OF HOST. Both hand this script the transports; only one of them is
-- serving a UI. A job state has no `emit` and no `next` -- it is a background
-- helper that happens to be running in spoot's process rather than beside it --
-- so everything that means "I am the engine" has to ask which one this is, or a
-- job would try to answer requests nobody sent it and claim pid files it does
-- not own.
Util.hosted = Util.host ~= nil and Util.host.role == "serve"

-- One iterator whichever side we are on. `host.next` blocks the worker thread
-- until a request arrives and answers nil when the host is shutting down, which
-- is precisely the contract io.lines() has at end of input -- so the loop reading
-- it does not know or care which one it got.
function Util.serve_lines()
    if Util.hosted then return Util.host.next end
    return io.lines()
end

function Util.serve_write(t)
    -- EVENTS SAY WHICH REQUEST THEY BELONG TO. Artwork is resolved after its
    -- reply is already on the wire, so a slow batch can land while the UI has
    -- moved on -- and covers patched by row index onto whatever list is showing
    -- now is precisely how the wrong album art ends up beside the cursor. The
    -- UI drops anything stamped with a request it is no longer looking at.
    -- Responses carry their own id and are left alone.
    if t.ev and Util.serve_req_id ~= nil and t.req == nil then t.req = Util.serve_req_id end
    local line = json.encode(t)
    if Util.hosted then Util.host.emit(line)
    else io.stdout:write(line, "\n"); io.stdout:flush() end
end

-- album_thumbs decorates a row as "<text>\0icon\x1f<path>". Qt has no use for
-- the packing, so rows leave here as {label=, icon=}.
-- album_thumbs packs a row as "<text>\0icon\x1f<path>". THE one place that
-- knows the packing: four copies of this pattern had grown across the serve
-- layer, and a change to how rows are decorated would have had to find them all.
function Util.serve_unpack(entry)
    if type(entry) ~= "string" then return nil, nil end
    local text, icon = entry:match("^(.-)\0icon\x1f(.*)$")
    if icon then return text, icon end
    return entry, nil
end

-- THE ROW AS MARKUP, for a front end that can draw it. Answers nil for a row
-- that has none, which is nearly all of them.
--
-- The markup was never decoration. It is how a menu says an action is not
-- available to you -- Play and Seek on an unavailable track, Lyrics on one with
-- none, dimmed rather than absent where the row still explains itself -- and how a
-- settings list marks the value you are on, in green with a check. rofi drew all
-- of it and Util.strip_markup was throwing every bit of it away, so a greyed-out
-- action was indistinguishable from a live one.
--
-- Pango's <span foreground> becomes Qt's <font color>. Those two and <b> are the
-- entire vocabulary spoot emits, so the conversion is a rename rather than a
-- translation.
function Util.rich_markup(s)
    if not s then return nil end
    s = tostring(s)
    -- No sentinel, no markup. Same early-out as strip_markup, and for the same
    -- reason: this runs once per row on every draw.
    if not s:find("\1", 1, true) then return nil end
    local function esc(t)
        return (t:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
    end
    local out, i = {}, 1
    while true do
        local a, b, tag = s:find("\1(.-)\2", i)
        if not a then out[#out + 1] = esc(s:sub(i)); break end
        -- The literal text between markup regions is ESCAPED; the regions
        -- themselves are the markup and pass through as tags.
        out[#out + 1] = esc(s:sub(i, a - 1))
        out[#out + 1] = tag
        i = b + 1
    end
    local m = table.concat(out)
    m = m:gsub('<span%s+foreground="([^"]*)"%s*>', '<font color="%1">')
    return (m:gsub("</span>", "</font>"))
end

-- `items` are the objects the rows were built from, when the caller has them.
-- Their ids travel with the rows so the UI can mark the playing one itself --
-- see display_track, which no longer writes that into the text.
function Util.serve_rows(entries, items)
    local out = {}
    local paired = type(items) == "table" and #items == #(entries or {})
    for i, e in ipairs(entries or {}) do
        local text, icon = Util.serve_unpack(e)
        local it = paired and items[i] or nil
        local id = (type(it) == "table") and it.id or nil
        -- `label` stays plain: it is what the filter matches against, and
        -- matching "Play" against "<font color=...>Play</font>" would find
        -- nothing. `rich` is the same row with its markup kept.
        out[i] = {label = Util.strip_markup(text or e), icon = icon,
                  rich = Util.rich_markup(text or e), id = id}
    end
    return out
end

-- Every decorated row in a list, as {i, icon} pairs for the UI to patch in.
function Util.serve_icons(entries)
    local items = {}
    for i, e in ipairs(entries or {}) do
        local _, icon = Util.serve_unpack(e)
        if icon then items[#items+1] = {i = i, icon = icon} end
    end
    return items
end

function Util.serve_main()
    -- Main IS the empty stack. Saying so keeps the crumb honest when you jump
    -- home from three levels down.
    Util.session_set({})
    local tiles, cold = Util.shelf_tiles(Util.MAIN_TILES)
    local entries = {}
    for i, t in ipairs(Util.MAIN_TILES) do entries[i] = Util.tile_label(t, tiles[i]) end
    -- The root grid streams its covers like every other one.
    Util.serve_after = function()
        Util.album_thumbs(entries, tiles, "main", nil, "main||")
        local items = Util.serve_icons(entries)
        if #items > 0 then Util.serve_write({ev = "art", view = "main", items = items}) end
    end
    local rows = Util.serve_rows(entries)
    for i, t in ipairs(Util.MAIN_TILES) do rows[i].key = t.key end
    local crumb = Util.breadcrumb_parts()
    -- `cold` is the grid saying a shelf has never been read. The rofi path
    -- spawns a warm and redraws; here it is reported so the UI can decide.
    -- Says "grid" explicitly. Every other view reports its layout, and the UI
    -- only drew the root correctly because grid happened to be its fallback --
    -- a default doing the work of a statement.
    return {rows = rows, cold = cold or false, crumb = crumb,
            view = "main", layout = "grid", scope = "main"}
end

-- Every top-level view, by the name the UI asks for. These are the SAME
-- functions the rofi build calls -- not reimplementations -- which is what makes
-- the port 1:1 by construction rather than by inspection: a view cannot drift
-- from its original because it IS its original.
Util.SERVE_VIEWS = {
    liked            = function() view_liked_tracks() end,
    ["top-tracks"]   = function() view_top_tracks() end,
    ["saved-albums"] = function() view_saved_albums() end,
    playlists        = function() view_playlists() end,
    categories       = function() view_categories() end,
    podcasts         = function() Util.view_podcasts() end,
    library          = function() Util.view_library() end,
    collections      = function() Util.view_collections() end,
    ["followed-artists"] = function() view_followed_artists() end,
    ["new-releases"] = function() view_new_releases() end,
    ["top-artists"]  = function() Util.view_top_artists() end,
    ["recently-played"] = function() view_recently_played() end,
    ["your-queue"]   = function() view_your_queue() end,
    ["show-list"]    = function() Util.view_saved_shows() end,
    ["latest-episodes"] = function() Util.view_latest_episodes() end,
    ["saved-episodes"]  = function() Util.view_saved_episodes() end,
    ["discover-genre"]  = function() Util.view_discover_genre() end,
    ["ui-settings"]     = function() Util.view_ui_settings() end,
    -- Takes its query as the first path step: view("search", {path = {"aurora"}}).
    -- With no step it draws the history list, which is what the rofi build shows
    -- before you type.
    search           = function() view_search() end,
    -- Tab's menu, over the stack the engine is currently standing on. Selecting
    -- a row jumps there, which the path mechanism drives like any other view.
    -- OVER THE MENU YOU PRESSED TAB IN. Every segment starts on a cleared stack
    -- (see serve_run), which is right for a view that draws itself and wrong for
    -- the one view whose whole content IS the stack: it found nothing to list,
    -- decided there was no trail, and opened straight into Trail History -- so
    -- the two modes read as one. The stack of the segment before this one is
    -- where Tab was pressed, and running on it is exactly the situation the rofi
    -- build had when it called this from inside a live menu.
    ["trail-jump"]   = function(a)
        if a and type(a.stack) == "table" then Util.session_set(a.stack) end
        Util.view_trail_jump(Util.session_stack(), a and a.tip, a and a.tipRoots,
                             a and a.mode)
    end,
    -- What is playing in the ROOM, via songrec. Blocks while it listens, which
    -- is why the view announces itself with a `listening` event first.
    -- WHERE THE MUSIC CAME FROM, and nothing else. One scope entry, opened the
    -- way replay_session opens any restored stack -- so what you get is that list
    -- as a root of its own, not the walk that first led to it. Alt+c falls here
    -- when the list is no longer anywhere on the trail.
    origin           = function()
        local o = Util.play_origin()
        if not o then
            ui_say("Nothing has played from a list yet")
            return
        end
        Util.session_set({json.decode(json.encode(o))})
        replay_session()
    end,
    listen           = function() Util.listen_start() end,
    -- What it has already found. Its own entry point, so a warm start can land
    -- back on it and views.sh can probe it like any other list.
    ["listen-history"] = function() Util.view_listen_history() end,
    -- THE PLAYING TRACK'S OWN ACTION MENU, as an entry point.
    --
    -- Shift+Return on Main's Playback tile has always meant this, and the branch
    -- that does it lives in main() -- the interactive loop, which serve mode
    -- never runs: Util.serve_main builds the grid and answers, and reads no path
    -- at all. So the key reached the engine, walked into a function that ignores
    -- steps, and came back with Main. The tile behaves like the track row it is
    -- standing in for again, and by the same route every other card takes.
    ["track-actions"] = function()
        if not current_track then ui_say("Nothing playing"); return end
        view_actions(current_track)
    end,
    -- The track the last listen identified, as its own action menu. Opened by
    -- the UI as a context hop, so it is a card over whatever you were on and
    -- costs no trail step -- which is what "jump to the identified track" has to
    -- mean now that an action menu is an overlay.
    ["listen-result"] = function()
        if not Util.listen_track then ui_say("Nothing identified"); return end
        -- THE ONE ACTION MENU THAT KEEPS ITS BACKDROP. Every other one is a card
        -- over the list it came from, and that list is already showing what the
        -- menu is about -- so a cover behind it would be a second answer to a
        -- question nobody asked. This one arrives out of nowhere: the cover of the
        -- track spoot just identified is the only thing on screen saying WHAT it
        -- identified. Cleared however the menu exits.
        Util.action_art = true
        local ok, err = pcall(view_actions, Util.listen_track)
        Util.action_art = nil
        if not ok then error(err, 0) end
    end,
    -- WHATEVER SPOTIFY LINK IS ON THE CLIPBOARD. This is what Alt+g has always
    -- been for -- Util.KEYBINDS says "open spotify web link" -- and the UI had it
    -- wired to the opposite thing, copying the playing track's URL, which is
    -- already a row in every action menu.
    --
    -- A VIEW, not a one-shot command, and that is the whole of the second half of
    -- the bug. The only other way in was the Playback menu's "Open Web Link" row,
    -- which draws the destination INSIDE Playback -- an artist hub is unscoped
    -- (a context menu, not a place) and wears THEME_SUB, so at Playback's depth
    -- and theme the addressing rule reads it as a redraw of Playback and refuses
    -- to feed it the next step. Every row in it did nothing. Opened as a view it
    -- draws on an empty stack, with no menu above it to be confused with.
    --
    -- The clipboard is read on every replay, exactly as the current-track keys
    -- below re-read what is playing: a trail step names the ACT, not the answer
    -- it gave an hour ago.
    ["open-link"]    = function()
        local url = Util.get_clipboard()
        if url == "" then ui_say("Clipboard is empty"); return end
        open_url(url)
    end,

    -- THE CURRENT-TRACK KEYS. In the rofi build these are rofi exit codes
    -- handled inside ui_menu, which decoded them from an exit code; replacing
    -- that function took them with it. Each refreshes playback first for the
    -- same reason the originals do -- the keybind may be pressed a while after
    -- the track changed, and acting on a stale current_track opens the wrong
    -- song's lyrics.
    ["lyrics-current"] = function()
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        if current_track then view_lyrics(current_track)
        else ui_say("No track playing") end
    end,
    -- THE KEYMAP, FROM ANYWHERE. F1 is the one key whose whole job is to work
    -- wherever you are, so it cannot be a row in a menu you have to reach first
    -- -- it is a view like any other, and the sheet it writes is the same one the
    -- System row writes. See Util.show_keybinds.
    ["keybinds"] = function() Util.show_keybinds() end,
    -- WHAT THE BACKDROP IS A PICTURE OF, full size. Double clicking the cover
    -- beside a list means "show me this properly", and what "this" is depends on
    -- where you are: inside an album or on an artist's page the backdrop is that
    -- container's own picture, and everywhere else it is whatever is playing.
    --
    -- Util.serve_ctx_item is exactly that distinction already -- the row the step
    -- into this place picked, which is the album, the playlist or the artist, and
    -- nil when you simply opened a shelf. view_art sorts the three kinds out for
    -- itself, which is why an artist gets an impression and an album a sleeve
    -- without this having to know the difference.
    ["art-here"] = function()
        local it = Util.serve_ctx_item
        if type(it) ~= "table" then
            if not Util.fast_now_track() then last_playback = 0; get_playback() end
            it = current_track
        end
        if it then view_art(it) else ui_say("Nothing to show") end
    end,
    ["art-current"] = function()
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        if current_track then view_art(current_track)
        else ui_say("No track playing") end
    end,
    ["seek-current"] = function()
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        if current_track then view_seek(current_track)
        else ui_say("No track playing") end
    end,
    -- An "album-current" view lived here: the album the playing track belongs
    -- to, opened when Alt+c could not find the track on screen. It answered the
    -- wrong question -- a track played out of Liked or out of a search result
    -- belongs to an album you may never have opened -- and the UI now records
    -- where a track was actually played from (see the `played` event) and falls
    -- back to Playback rather than to an album nobody visited.

    -- AN "actions-current" VIEW LIVED HERE: Alt+Return, the playing track's own
    -- action menu, summoned from wherever you happened to be. It made sense while
    -- an action menu was a full menu that replaced whatever was on screen. It does
    -- not now: an action menu is a card drawn over the list it belongs to, and
    -- this one had no list to belong to -- it was the single case that had to fall
    -- back to the full-panel path. Alt+Return is Main now, which is the key Alt+
    -- Space used to be.
}

-- Runs a view for its DRAW and nothing else.
--
-- The interception is the whole trick: with ui_menu replaced by a recorder
-- that answers nil, a view function runs its real body -- scope push, cache
-- reads, format_entries, album_thumbs -- reaches the menu call, is told the user
-- dismissed it, and unwinds cleanly. What it would have handed rofi is what the
-- UI gets. No view logic is duplicated here, so none of it can rot.
-- Shapes a captured draw for the wire. One place, so `view`, `open` and `nav`
-- cannot describe the same menu three different ways.
-- The number of path steps that still describe WHERE YOU ARE, given the menu
-- finally drawn. Steps beyond that ran actions and left no place behind them.
function Util.serve_keep(menu)
    local answered = Util.serve_answered_menus or {}
    if menu == nil then return #answered end
    for i = 1, #answered do
        if answered[i] == menu then return i - 1 end
    end
    return #answered
end

function Util.serve_draw(name, d, raw)
    if not d then return {view = name, rows = {}, empty = true} end
    local o = d.opts or {}
    return {
        view   = name,
        -- opts.thumbs is precisely how the rofi build decides grid vs list, so
        -- the UI inherits that decision rather than keeping its own table.
        layout = o.thumbs and "grid" or "list",
        prompt = o.prompt and Util.strip_markup(o.prompt) or nil,
        -- A FUNCTION IS A MESG TOO. Views whose caption depends on live state
        -- pass a closure rather than a string -- Playback's names whatever is
        -- playing right now, Main's the transport state -- and rofi called it.
        -- Taking only strings dropped those on the floor without a word, which
        -- is how the Playback menu came to have no caption at all and nothing
        -- anywhere said so.
        mesg   = (function()
            local m = o.mesg
            if type(m) == "function" then
                local ok, v = pcall(m)
                m = ok and v or nil
            end
            return type(m) == "string" and Util.strip_markup(m) or nil
        end)(),
        rows   = Util.serve_rows(d.entries, o.items),
        raw    = raw and d.entries or nil,
        -- Util.parts_from_stack's own output: "Main", then one part per step,
        -- with a qualified sub-view spending two. The UI draws the arrows; the
        -- naming rule stays in one place, where the rofi build already has it.
        crumb  = d.crumb,
        -- WHICH ZENON THEME this view would have been drawn with. Every view
        -- already names one when it calls ui_menu, and those files carry the
        -- per-view geometry -- widths from 304 to 1000, row counts from 1 to 14.
        -- Reporting the name rather than re-deriving "which view is this" in the
        -- UI keeps one mapping instead of two, and it is the ORIGINAL mapping.
        theme  = d.theme,
        -- TRUE when the last step acted rather than moved: playing a track,
        -- liking it, copying a link. The menu you were on is the menu you are
        -- still on, so the UI drops that step from the path -- otherwise the
        -- same list counts as a different one and the cursor snaps to the top,
        -- which then puts Return over "Play" instead of the row you were on.
        -- HOW MANY PATH STEPS SURVIVE. If the captured draw is a menu some
        -- earlier step was answered on, everything after that step merely acted
        -- and is dropped -- which is what stops a one-shot action replaying
        -- itself on the next refresh, and what keeps a list's identity (and so
        -- its remembered cursor) stable when you play a track from it.
        keep = Util.serve_keep(d.menu),
        -- The view the DEEPEST scope names -- "lyrics", "album", "artist-albums".
        -- The entry point above says how you got here; this says what you are
        -- looking at, which is what decides whether a view syncs to the clock or
        -- wears a cover. Taken from the stack so it cannot disagree with the
        -- crumb drawn from that same stack.
        scope  = (d.stack and #d.stack > 0) and d.stack[#d.stack].view or nil,
        -- The track a lyrics view is FOR, so the UI can ask for its cues without
        -- guessing that it is whatever happens to be playing.
        track  = (d.stack and #d.stack > 0) and d.stack[#d.stack].track_id or nil,
        -- WHETHER DELETE MEANS ANYTHING HERE. opts.del_select is the rofi build's
        -- own claim on the key -- only the menus that erase a record set it -- so
        -- reporting it lets the UI offer Delete exactly where it does something.
        -- Without this the key had to either do nothing everywhere or be sent
        -- blind, and a menu that does not claim it would have read the step as an
        -- ordinary Return and navigated instead.
        -- hist_key alongside it because the search history claims Delete the
        -- other way round: it names the store to erase from and lets the menu
        -- machinery do the erasing, rather than handling the key itself.
        del = (o.del_select or o.hist_key) and true or nil,
        -- WHETHER TAB BELONGS TO THIS MENU. Only two claim it -- the trail menu
        -- and the search results -- and everywhere else Tab opens the trail. The
        -- UI has to be told which it is rather than guessing from a view name.
        tab = o.tab_select and true or nil,
        -- WHETHER THIS MENU HAS A SUBJECT. The UI already refuses a backdrop to
        -- whole KINDS of view -- the trail, the search box, System, lyrics --
        -- from what they are. This is the other question: a single menu, inside
        -- a view that does wear one, that is about nothing you can picture. The
        -- search results' type filter is the case; it says so itself rather than
        -- being named in a list somewhere else.
        --
        -- An `if`, not `and/or`: `x and false or nil` is always nil, because
        -- `false or nil` is nil -- the one value the idiom cannot carry is the
        -- one this field exists to send. Same immediately-called shape `mesg`
        -- above uses, so the key stays absent for every menu that does want one.
        art = (function() if o.art == false then return false end end)(),
        -- ...and whether the cover beside it is WHATEVER IS PLAYING rather than
        -- a fixed picture of this menu's subject. On a shelf it is, so the UI
        -- can keep it current from the playback poll it already runs -- autoplay
        -- moving to the next track fades the next cover in without the menu
        -- being built again. See Util.serve_shelf.
        -- WHETHER THIS MENU IS ABOUT THE ROW BEHIND IT. An action menu is a list
        -- of verbs concerning the thing you were standing on, not a place -- the
        -- engine has said so in comments for as long as they have existed (see
        -- Util.open_playlist_actions and view_artist: "A CONTEXT MENU, so no
        -- Util.scope and no trail step"). Saying it in the DRAW lets the UI draw
        -- it over the list it came from instead of replacing it.
        --
        -- Declared per menu rather than inferred: theme=THEME_SUB is nearly this
        -- signal, and is wrong -- twenty-five menus use that theme and only these
        -- eight are action menus. Same `and true or nil` shape as `del` and `tab`
        -- above, so the key stays absent everywhere else.
        --
        -- Every one of them pairs it with `art=false`: a card floating over the
        -- list it came from is not a thing with a picture, and the list behind
        -- it is still wearing whatever backdrop it had. See `art` below -- this
        -- adds no second mechanism for saying "no cover here".
        context = o.context and true or nil,
        -- ...AND WHETHER IT OUTLIVES A PICK. A card closes on the verb it was
        -- opened for, because that verb is over: `keep` tells the UI the step
        -- acted rather than moved, and the card goes with it. Seek is the one
        -- menu that is used repeatedly -- nudge, nudge again -- so it says so
        -- here and the UI leaves it standing. Declared per menu for the same
        -- reason `context` is: there is no property of a menu that could be read
        -- to guess this.
        sticky = o.sticky and true or nil,
        artLive = Util.serve_shelf(d) or nil,
        -- THE COVER, WITH THE ROWS, WHEN IT COSTS NOTHING.
        --
        -- Artwork is resolved after the reply on purpose: the rows go out first
        -- and the picture follows, so a menu never waits on the CDN. That leaves
        -- a window, and on a shelf the window shows the WRONG cover -- the
        -- backdrop follows the playback poll, the poll is up to a second behind
        -- the pick, so playing a track out of a different list drew the previous
        -- track's art beside the new list's rows until the context-art event
        -- landed. Telling the UI which track the late answer belongs to fixed the
        -- second half of that; this closes the first.
        --
        -- CACHE-ONLY, so it is a stat and a read or nothing at all. Almost always
        -- something: the list that drew this track's row already fetched its
        -- thumbnail. On a miss this stays absent and the event answers as before.
        cover = Util.serve_draw_cover(d),
        coverFor = (Util.serve_shelf(d) and current_track and current_track.id) or nil,
        -- HOW MANY COLUMNS THE ROWS FLOW INTO, for a card that is a shape rather
        -- than a list. Absent everywhere else, which the UI reads as one.
        cols = (type(o.cols) == "number" and o.cols > 1) and o.cols or nil,
        -- WHICH OF A MENU'S FACES IS SHOWING, for a menu that has more than one.
        -- The trail menu is the only one, and it is how Tab there crosses between
        -- them without the crossing becoming a step. See Util.view_trail_jump.
        mode = (type(o.mode) == "string" and #o.mode > 0) and o.mode or nil,
        -- SOMETHING HERE IS A COPY WE KNOW IS OUT OF DATE, with the real answer
        -- already on its way. The UI asks again shortly rather than leaving the
        -- shelf wrong until the next time it is opened. See Util.reval_sweep.
        stale = Util.draw_stale or nil
    }
end

-- The capture protocol, once. serve_view and serve_open differed only in how
-- they find the function to run, and had grown identical bodies around it --
-- answers, art deferral, the pcall, the teardown, the art continuation. Anything
-- that becomes true of one is now automatically true of the other.
function Util.serve_run(name, fn, args)
    args = args or {}
    Util.serve_capture = {}
    -- WHETHER ANYTHING THIS REQUEST SERVES IS KNOWN TO BE OLD. Cleared here and
    -- set by cached_fetch; the draw carries it out and the UI asks again. Swept
    -- first, so a refresh that landed since the last request is already in memory
    -- by the time the view reads it -- which is the request that then answers
    -- with fresh rows and no `stale`, and that is where the asking stops.
    Util.draw_stale = false
    Util.reval_sweep()
    -- args.path walks INTO the view: each index is the row that gets selected at
    -- that depth, dispatched by the view's own handler. An empty path just draws.
    Util.serve_answers = type(args.path) == "table" and args.path or nil
    Util.serve_depth = 0
    Util.serve_last_menu = nil
    Util.serve_answered_menus = {}
    Util.serve_ctx_item = nil
    -- Reset with it. serve_ctx_path never was, so a menu naming no cover of its
    -- own wore whichever one the last menu that did had named.
    Util.serve_ctx_path = nil
    Util.serve_ctx_url = nil
    -- ...UNLESS THIS IS A TAIL, which is about where the trail already stands and
    -- so inherits what that place was about. See the segment loop, which is the
    -- only caller that ever passes this.
    if args and args.keepCtx ~= nil then Util.serve_ctx_item = args.keepCtx end
    Util.serve_answered_depth = nil
    -- FROM EMPTY, every time. The replay pushes a scope per step as it walks the
    -- path, so a stack left over from the previous request would be pushed on top
    -- of rather than replaced -- the crumb grew across unrelated requests
    -- ("Saved Albums > ... > Buck > Liked Tracks") because of exactly that.
    -- The exception is a restore, which installs the saved stack deliberately.
    if not Util.serve_restoring then Util.session_set({}) end
    Util._art_defer = true
    -- The args reach the VIEW, not just this wrapper. Only trail-jump reads them
    -- today (it needs the stack it was opened over), but a view being told what
    -- it was asked for is the general shape -- the alternative is a global set
    -- beside the call, which is the same thing with nowhere to look it up.
    local ok, err = pcall(fn, args)
    Util._art_defer = false
    local cap = Util.serve_capture
    Util.serve_capture, Util.serve_answers, Util.serve_depth = nil, nil, 0
    if not ok then error(err, 0) end
    -- The first UNANSWERED draw is the one the UI asked for: every draw before
    -- it was handed a selection and dispatched. Deeper first, so a path that
    -- opened an album returns the album, not the list behind it.
    local d = cap[1]
    -- Leave the session stack where the UI actually is. Every scope unwound on
    -- the way out of the replay, so without this session.json would describe an
    -- empty app: no crumb to restore, no trail to archive, and a warm start that
    -- opens on Main however deep you were. Util.session_set is the only sanctioned
    -- way to replace it -- it bumps the generation counter the scopes check.
    if d and d.stack then Util.session_set(d.stack) end
    -- The art pass runs AFTER the response is on the wire (see the dispatcher).
    -- Intermediate segments of a trail are walked THROUGH, never drawn, so
    -- resolving their covers would spend real fetches on rows nobody sees --
    -- and would stream art events the UI would patch onto the wrong model.
    if not Util.serve_art_skip then Util.serve_art_after(name, d) end
    return Util.serve_draw(name, d, args.raw)
end

-- THE TRAIL, replayed. A trail is a flat list of HOPS: a root hop names an
-- entry point ({cmd="view", key="liked"}), a step hop names a selection made
-- inside it ({step=3}). Walking them in order is what lets a new root APPEND to
-- the trail you were already on -- the segment starts on the stack the previous
-- one ended on, so the crumb keeps reading "Main > Buck > Liked Tracks > Search"
-- instead of collapsing to "Main > Search" the moment you press Alt+s.
--
-- One entry point for every draw the UI asks for, warm start included: a restore
-- is just this list, loaded from disk instead of held in memory. That is what
-- makes a restored trail walkable rather than a line of dead text.
function Util.serve_nav(args)
    -- An ABSENT hops means "resume"; an EMPTY one means Main. They are different
    -- requests and the difference is the key's presence, never its length --
    -- reading #hops == 0 as resume made every trip home reopen the saved trail.
    local given = args and args.hops
    local hops = given or {}
    local pos = args and args.pos
    -- The deepest crumb this trail reached, carried verbatim. The engine stores
    -- it and hands it back; naming steps is the UI's business, not its own.
    local tip, tip_roots = args and args.tip, args and args.tipRoots
    -- No hops means "resume": the saved trail is replayed exactly as a live one
    -- would be, which is the whole reason it is stored as hops rather than as a
    -- restored leaf. A warm start is therefore not a special path.
    if given == nil then
        local saved = Util.serve_nav_load()
        if saved then hops, pos, tip, tip_roots = saved.hops, saved.pos, saved.tip, saved.tipRoots end
    end
    -- The WHOLE trail is stored; only the part up to the cursor is walked. That
    -- split is what lets Alt+left survive a restart with somewhere to walk back
    -- INTO -- truncating here instead would save the trail already trimmed.
    -- pos 0 is legal and means Main: an empty trail is not a missing one.
    if type(pos) ~= "number" or pos < 0 or pos > #hops then pos = #hops end
    -- Fold a hop list back into segments. A step hop before any root hop is
    -- meaningless and dropped rather than guessed at. Written once because it is
    -- now run twice -- see `tail` below, which folds in exactly the same way and
    -- differs only in what happens to the result.
    local function fold(segs, list, upto)
        for i = 1, upto do
            local h = list[i]
            if type(h) == "table" and h.cmd then
                -- `mode` rides along with the hop. Only the trail menu uses it:
                -- that menu has two faces -- the steps you are on and the menus
                -- you closed -- and Tab crosses between them. It used to cross by
                -- sending a STEP, which is a thing the engine replays, so the
                -- crossing joined the path it was showing you. See
                -- Util.view_trail_jump.
                segs[#segs + 1] = {cmd = h.cmd, key = h.key, mode = h.mode, path = {}}
            elseif #segs > 0 then
                local pth = segs[#segs].path
                pth[#pth + 1] = (type(h) == "table" and h.step ~= nil) and h.step or h
            end
        end
    end
    local segs = {}
    fold(segs, hops, pos)
    -- HOPS THAT ARE NOT PLACES. An action menu is produced by ANSWERING a row,
    -- and that answer has to reach the view or there is no menu -- but a list of
    -- verbs about a track is not somewhere you have been. The engine has said so
    -- in comments since before the Qt port; this is where it stops being only a
    -- comment.
    --
    -- So the UI sends those hops BESIDE the trail rather than in it. They are
    -- walked exactly like the rest, and then: not saved to nav.json, not echoed
    -- back as the trail, and not allowed to name a crumb. Closing the menu is
    -- the UI dropping them, which costs no request at all -- the list underneath
    -- never went anywhere.
    local tail = (args and type(args.tail) == "table") and args.tail or nil
    -- Where the tail's own segments begin, so the chain below can skip them. A
    -- tail of plain steps creates none and this is simply never reached; a tail
    -- that starts with a root hop -- Alt+Return, the playing track's menu from
    -- wherever you are -- creates one, and it must not draw a seam for a place
    -- that does not exist.
    local tail_from = #segs + 1
    if tail then fold(segs, tail, #tail) end
    local draw
    -- WHAT THE TRAIL WAS ABOUT when the tail begins, carried into every tail
    -- segment -- see the read below and Util.serve_run's keepCtx. Declared out
    -- here rather than in the loop: written as a fresh `local` per iteration its
    -- own initialiser could only read an OUTER variable that does not exist, so
    -- it evaluated to nil on every pass but the first tail one, and a card opened
    -- over a card lost the album it was about.
    local keep_ctx = nil
    -- THE DAISY CHAIN. Each segment runs on its OWN stack and reports its own
    -- crumb; the chain is assembled here. That is what makes a root visible as a
    -- root: joined by the trail glyph rather than the step arrow, exactly as the
    -- rofi build joined archived trails (Util.trail_label). Building segments on
    -- one shared stack instead would have hidden the seam -- and a Main root,
    -- whose whole crumb is the word "Main", would have vanished entirely.
    local chain, roots = {}, {}
    -- The session stack the tail was opened OVER, put back once it has drawn.
    -- Util.serve_run ends by writing the stack its segment finished on, so a tail
    -- with a segment of its own -- Alt+Return, the playing track's menu from
    -- wherever you happen to be -- would leave session.json describing the
    -- overlay. Nothing a cold start resumes into may be an overlay.
    local pre_tail = nil
    -- No segments at all IS Main -- the trail before you have taken a step.
    if #segs == 0 then
        draw = Util.serve_main({})
        chain = (type(draw.crumb) == "table") and draw.crumb or {"Main"}
    end
    for i = 1, #segs do
        local sg = segs[i]
        local last = (i == #segs)
        -- A MAIN ROOT YOU HAVE ALREADY LEFT IS NOT A PLACE. Alt+Space puts a
        -- `main` hop on the trail so that going home from three levels down is a
        -- jump you can walk back out of; picking a tile from that grid appends the
        -- tile's own root, because the grid is where the tile LIVES rather than
        -- somewhere you have been. The chain then carried BOTH, and the crumb read
        --
        --     Main > Liked > whatever  ⟐  Main  ⟐  Search > whatever
        --
        -- -- two seams for one jump, from a glyph whose whole job is to say "a
        -- different trail starts here". It said it twice about the same one.
        --
        -- So a walked-through `main` segment with nothing of its own contributes
        -- nothing: the root after it already draws the seam. Standing ON it (it is
        -- the last segment) still draws it, because then it IS where you are --
        -- which is what keeps Alt+left able to walk back to the grid.
        --
        -- Here rather than in the UI's openTile so that trails already saved to
        -- nav.json read right on the next warm start, and so that any other route
        -- to the same shape reads right too.
        if sg.cmd == "main" and #sg.path == 0 and not last then goto next_seg end
        -- Where the PREVIOUS segment ended -- read before serve_run clears it.
        -- A root normally starts somewhere new and wants nothing from it; the
        -- trail menu is the exception, since what it lists is the trail it was
        -- opened over.
        local from = Util.session_stack()
        if i == tail_from then pre_tail = from end
        -- ...AND WHAT THE PREVIOUS SEGMENT WAS ABOUT, for the same reason and read
        -- at the same moment.
        --
        -- Util.serve_run clears the capture per SEGMENT, not per request -- which
        -- is right for a root hop, since a new root is somewhere new and owes
        -- nothing to what came before it. A TAIL is the exception: it is beside
        -- the trail rather than after it, so it is about exactly where you already
        -- are. Cleared, `art-here` could never see the album or the artist it was
        -- opened over and fell through to whatever was playing -- which is the
        -- whole of "clicking a backdrop only shows the current track".
        --
        -- Carried rather than re-derived: only the step that picked the container
        -- knows which row it was, and the tail runs long after that step has been
        -- replayed. Same precedent as `stack = from` above.
        if i == tail_from then keep_ctx = Util.serve_ctx_item end
        -- Everything but the last segment is walked through: no art, no cost.
        Util.serve_art_skip = not last
        local ok, res = pcall(function()
            if sg.cmd == "open" then
                return Util.serve_open({tile = sg.key, path = sg.path, raw = args.raw,
                                        keepCtx = (i >= tail_from) and keep_ctx or nil})
            elseif sg.cmd == "view" then
                return Util.serve_view({name = sg.key, path = sg.path, raw = args.raw,
                                        mode = sg.mode,
                                        keepCtx = (i >= tail_from) and keep_ctx or nil,
                                        stack = from, tip = tip, tipRoots = tip_roots})
            end
            return Util.serve_main({})
        end)
        Util.serve_art_skip = false
        if not ok then error(res, 0) end
        draw = res
        -- A tail segment RUNS -- it is what produced the menu -- but contributes
        -- nothing to the crumb, because it is not a step you took.
        if i >= tail_from then goto next_seg end
        local c = (type(res) == "table" and type(res.crumb) == "table") and res.crumb or {"Main"}
        local part1 = 1
        -- WHETHER ANYTHING IS ALREADY ON THE CHAIN, not whether this is the first
        -- segment. Those were the same thing until a segment could contribute
        -- nothing (see the skip above): with `i > 1` a root following a
        -- walked-through Main would have drawn a seam onto an empty chain, and
        -- there is nothing there for a seam to join.
        if #chain > 0 then
            -- Where this root starts, as an index into the chain. The UI draws
            -- the trail glyph before exactly these.
            roots[#roots + 1] = #chain
            -- Every segment's crumb is seeded with "Main" by parts_from_stack.
            -- On a continuation that head says nothing the glyph has not already
            -- said -- unless the segment IS Main, where it is the whole name.
            if sg.cmd ~= "main" and c[1] == "Main" and #c > 1 then part1 = 2 end
        end
        for k = part1, #c do chain[#chain + 1] = c[k] end
        ::next_seg::
    end
    if type(draw) == "table" then draw.crumb, draw.roots = chain, roots end
    if pre_tail then Util.session_set(pre_tail) end
    -- Only a trail that actually drew is worth resuming from -- and `hops` here
    -- is the trail alone. The tail was never in it, so nothing has to remember to
    -- strip it out.
    Util.serve_nav_save(hops, pos, tip, tip_roots)
    -- Echoed so a resuming UI adopts the trail it just replayed rather than
    -- holding a crumb it cannot walk.
    if type(draw) == "table" then
        draw.hops, draw.pos, draw.tip, draw.tipRoots = hops, pos, tip, tip_roots
    end
    return draw
end

-- The hop list on disk, so a cold start resumes a walkable trail rather than a
-- crumb you cannot move through. Written next to session.json in the cache,
-- which is the one location spoot already owns.
function Util.serve_nav_save(hops, pos, tip, tip_roots)
    -- LISTENING IS AN ACT, NOT A PLACE, and it is the one act that must not be
    -- resumed into. Util.view_listen blocks on songrec for P.listen_timeout
    -- seconds, during which the engine reads no request and answers nothing --
    -- so a saved trail ending in it means the NEXT cold start records the room
    -- for thirty seconds before it will draw anything at all, having been asked
    -- to open a music menu.
    --
    -- It became reachable in exactly that way when `spoot --listen` started
    -- working at a resident shell (see Shell::askListen): the hop it appends is
    -- a root like any other and was persisted like any other.
    --
    -- Trimmed rather than refused, so the trail you were ON is still resumed --
    -- you come back where you were, not into a recording. Only `listen`: every
    -- other keybind view is cheap to replay, and a rule listing them all would
    -- be guessing at which ones someone might mind.
    hops = hops or {}
    local n = #hops
    while n > 0 and type(hops[n]) == "table"
          and hops[n].cmd == "view" and hops[n].key == "listen" do
        n = n - 1
    end
    -- ...AND THE SYSTEM MENU, for the opposite reason. Listening is too expensive
    -- to resume into; System is simply not somewhere you were going. Quit is a ROW
    -- in it, so the last thing the trail records before every deliberate shutdown
    -- is "System" -- and the next cold start dutifully reopened the settings menu,
    -- because session replay is faithful and this is the one step where being
    -- faithful is wrong.
    --
    -- The whole SEGMENT, not just the root hop: System's submenus are steps inside
    -- it, and leaving those behind would resume a path standing on no root. Found
    -- by walking back to the last root rather than by counting, because how many
    -- steps deep you were is not knowable from here.
    --
    -- On disk only. The live trail is untouched, so within a session System walks
    -- and Alt+left leaves it exactly as before; this is what a COLD start reads.
    local r = n
    while r > 0 and not (type(hops[r]) == "table" and hops[r].cmd) do r = r - 1 end
    if r > 0 and hops[r].cmd == "open" and hops[r].key == "system" then n = r - 1 end
    if n < #hops then
        local cut = {}
        for i = 1, n do cut[i] = hops[i] end
        hops = cut
        if type(pos) ~= "number" or pos > n then pos = n end
    end
    -- The play origin is not ours to write -- Util.play_origin_save owns it --
    -- and every trail write after it has to carry it through rather than drop it.
    -- Recovered from disk when this is the first write of the process, which is
    -- the cold start Alt+c most needs it for.
    local origin = Util.play_origin()
    Util.serve_nav_state = {
        hops = hops or {}, pos = pos,
        tip = (type(tip) == "table" and #tip > 0) and tip or nil,
        tipRoots = (type(tip_roots) == "table" and #tip_roots > 0) and tip_roots or nil,
        origin = (type(origin) == "table" and origin.view) and origin or nil
    }
    local f = io.open(P.nav, "w")
    if not f then return end
    f:write(json.encode(Util.serve_nav_state))
    f:close()
end

-- THE LIST A TRACK WAS PLAYED FROM, as a single scope entry.
--
-- The deepest entry on the stack IS the menu that was on screen, and every
-- registered view knows how to reopen itself from one (see reg and
-- replay_session) -- so one entry is a complete way back with no journey
-- attached to it. Kept beside the trail, because "where you were" already lives
-- there and a second file for one object would be a second thing to keep in step.
--
-- An action menu takes no scope entry of its own, so playing from one records the
-- list underneath it, which is exactly right.
-- ...and reading it back, from memory or from disk. Both callers need the same
-- recovery: a process that has not navigated yet still has an origin on disk from
-- the last one, and a cold start is exactly when Alt+c has nothing else to go on.
function Util.play_origin()
    local o = type(Util.serve_nav_state) == "table" and Util.serve_nav_state.origin or nil
    if o == nil then
        local disk = Util.serve_nav_load()
        o = disk and disk.origin or nil
    end
    return (type(o) == "table" and o.view) and o or nil
end

function Util.play_origin_save()
    local st = Util.session_stack()
    local leaf = (type(st) == "table" and #st > 0) and st[#st] or nil
    if type(leaf) ~= "table" or not leaf.view then return end
    if type(Util.serve_nav_state) ~= "table" then return end
    Util.serve_nav_state.origin = json.decode(json.encode(leaf))
    local f = io.open(P.nav, "w")
    if not f then return end
    f:write(json.encode(Util.serve_nav_state))
    f:close()
end

function Util.serve_nav_load()
    local f = io.open(P.nav, "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    local ok, d = pcall(json.decode, raw)
    if not ok or type(d) ~= "table" or type(d.hops) ~= "table" or #d.hops == 0 then
        return nil
    end
    return d
end

function Util.serve_view(args)
    local name = args and args.name
    local fn = Util.SERVE_VIEWS[name]
    if not fn then error("unknown view: " .. tostring(name), 0) end
    return Util.serve_run(name, fn, args)
end

-- Resolves a draw's artwork once the rows are already drawn, and reports it as
-- it goes. The UI patches its model per item, so a grid fills in rather than
-- appearing all at once -- and stays scrollable the whole time.
-- One cover for the item an action menu is about. Runs Util.album_thumbs over a
-- single-item list rather than reaching into the art pool directly, so tiers,
-- id-keying and the withdrawn-artwork path all behave exactly as they do for a
-- grid -- and a kind that gains a tier later gains it here for free.
-- A SHELF: a menu whose rows ARE its items, and whose items are tracks. That is
-- a PLACE you are standing in rather than a thing you are looking at, and it is
-- the whole distinction the backdrop turns on -- see Util.serve_ctx_art.
--
-- An action menu carries `items` too (the list it was opened from, so
-- Shift+Return can reach it) and is not a shelf, because its ROWS are verbs:
-- #items ~= #entries. That is the same test the step dispatcher uses to decide
-- whether a pick names anything, and it is here for the same reason.
-- The cover a shelf would wear, if it is already on disk. Cache-only and
-- current_track only: this exists to close a one-poll gap, not to become a second
-- way of resolving artwork. Util.serve_ctx_art is still the one that answers
-- properly, in the continuation, for every case including a miss here.
function Util.serve_draw_cover(d)
    local o = (d and d.opts) or {}
    -- A CARD'S PICTURE IS THE CARD'S. This field is the LIST's backdrop, and a
    -- card floats over a list that is still wearing one -- see Util.serve_card_art
    -- and the `own` branch of Util.serve_art_after.
    if o.context then return nil end
    if not Util.serve_shelf(d) then
        -- A CONTAINER THAT NAMED ITS OWN PICTURE, and the other half of the gap
        -- this function exists to close. A shelf's cover was shipped with the
        -- rows and an album's was not, so stepping from a list you had played
        -- something out of into an album carried the PREVIOUS TRACK's cover
        -- across: the rows were the album's, the backdrop was still the last
        -- draw's, until the context-art event landed and replaced it.
        --
        -- Free: the view called Util.serve_cover before it drew, which is where
        -- the continuation would read it from anyway.
        if Util.serve_ctx_path then return Util.serve_ctx_path end
        if Util.serve_ctx_url then
            local p = Util.ensure_art_med(Util.serve_ctx_url, true)
            if p ~= "" then return p end
        end
        return nil
    end
    local it = current_track
    local alb = it and (it.type == nil or it.type == "track") and it.album or nil
    local url = alb and alb.images and alb.images[1] and alb.images[1].url or nil
    if not url then return nil end
    local p = Util.ensure_art_med(url, true)
    return (p ~= "" and p) or nil
end

function Util.serve_shelf(d)
    local o = (d and d.opts) or {}
    local it = o.items
    if type(it) ~= "table" or #it == 0 then return false end
    if #it ~= #((d and d.entries) or {}) then return false end
    local t = it[1]
    if type(t) ~= "table" then return false end
    if not (t.type == "track" or t.type == "episode" or t.album ~= nil) then return false end
    -- A CONTAINER WITH A PICTURE OF ITS OWN IS THE EXCEPTION, and `own_art` is
    -- that question asked directly. An album's sleeve, a playlist's tile and a
    -- podcast's art are all pictures OF THE LIST YOU ARE IN, which is the thing
    -- worth showing beside it -- being shown whatever happens to be playing tells
    -- you nothing about where you are, and opening an album to find an unrelated
    -- track's artwork reads as a bug.
    --
    -- This used to test ctx_type == "album", then "album or playlist": a list of
    -- kinds that could only grow, and that had already missed podcasts -- a show's
    -- episode list passes no ctx_type at all, deliberately (see Util.open_show),
    -- so it could never have matched however long the list got.
    -- ...UNTIL SOMETHING IN THE LIST IS PLAYING. The exception above is about
    -- not showing you an unrelated track's artwork beside a container you merely
    -- opened -- and once the music is coming OUT of that container the artwork is
    -- not unrelated any more, it is the one thing the backdrop is for. Without
    -- this a playlist wore its own tile for as long as you stayed in it: skipping
    -- track after track changed nothing, and skipping while spoot was hidden
    -- changed nothing on the way back either, because a container is not a shelf
    -- and only a shelf follows the poll.
    --
    -- Decided per draw and then left to the UI. artLive is not a live binding
    -- over there -- it is what this draw said -- so the answer has to be true at
    -- the moment the list is drawn, and from then on the playback poll moves the
    -- cover with no draw at all. That is what makes it work while the menu is
    -- closed, which is the case the report was about.
    if o.own_art and not Util.playing_here(it) then return false end
    return true
end

-- IS THE PLAYING TRACK ONE OF THESE ROWS? By id, against the items the menu was
-- built from -- the same objects the rows were rendered from, so this asks about
-- what is on screen rather than about what the trail says we are inside of.
--
-- current_track rather than a fresh poll: this runs on the draw path, where a
-- request would be paid for by every list that has its own picture. It is at
-- most one poll interval stale, and the consequence of being wrong is one draw's
-- worth of the container's own cover before the next one settles it.
function Util.playing_here(items)
    local id = current_track and current_track.id
    if not id or type(items) ~= "table" then return false end
    for i = 1, #items do
        local it = items[i]
        if type(it) == "table" and it.id == id then return true end
    end
    return false
end

function Util.serve_ctx_art(d)
    -- The view already told us, if it is one of the two that names a cover.
    -- ...or it told us where to get it. This is the fetch the menu used to wait
    -- on -- see Util.serve_named_cover, which both this and the card's resolver
    -- read, and which explains why the URL branch is allowed to fetch.
    local named = Util.serve_named_cover
    -- A SHELF WEARS WHAT IS PLAYING, never what contains it. Both of the answers
    -- above are about the CONTAINER -- the playlist you opened, the album you
    -- stepped into -- and beside a list of its tracks that says only "you are in
    -- this playlist", which the breadcrumb already says. Worse, it stuck: you
    -- played track after track out of an editorial playlist and went on looking
    -- at the playlist's own cover, and the only way to shift it was to open a
    -- track's action menu and come back.
    --
    -- Every list of tracks is the same case -- Liked, Recently Played, More Like
    -- This, an album -- so this is one rule rather than a list of views.
    local shelf = Util.serve_shelf(d)
    if not shelf then
        local p = named()
        if p then return p end
    end
    -- NOBODY PICKED ANYTHING, so the cover belongs to whatever is playing.
    --
    -- Resolved through the same album_thumbs path as any other cover, in the
    -- continuation, so it costs the draw nothing.
    local item = (not shelf) and Util.serve_ctx_item or nil
    if type(item) ~= "table" then
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        item = current_track
    end
    -- A shelf with nothing playing falls back to what contains it. That is the
    -- best answer left, and it is the one every shelf gave before this.
    if type(item) ~= "table" and shelf then
        local p = named()
        if p then return p end
        item = Util.serve_ctx_item
    end
    if type(item) ~= "table" then return nil end
    -- A TRACK'S COVER COMES FROM THE MED-RES POOL, not the grid's. The context
    -- cover is drawn at the full height of the body -- 364px and up -- and
    -- album_thumbs answers with the 300px file every grid tile uses, so it was
    -- being enlarged past its own size and every list wore a soft cover. The
    -- action menu never had the problem because it asks for med-res directly.
    return Util.item_cover(item)
end

-- THE COVER THIS DRAW NAMED FOR ITSELF, if it named one.
--
-- A view that has a picture of its own records it on the way in through
-- Util.serve_cover -- as a path when it is already on disk, as a URL when it is
-- not. Two callers ask the same two questions in the same order: the list's
-- resolver and the card's. They had a copy each.
--
-- The URL branch FETCHES, and that is on purpose: nothing warms the med-res pool
-- ahead of an action menu, so the first one opened on any album used to pay a
-- live download before it could draw a single row. Here it costs nothing anyone
-- is looking at -- the rows are already on screen and the cover fades in beside
-- them when it lands.
function Util.serve_named_cover()
    if Util.serve_ctx_path then return Util.serve_ctx_path end
    if Util.serve_ctx_url then
        local p = Util.ensure_art_med(Util.serve_ctx_url)
        if p ~= "" then return p end
    end
    return nil
end

-- ONE ITEM, ONE COVER. Lifted out of Util.serve_ctx_art so the card's own
-- resolver can share it rather than carrying a second copy of the same four
-- cases -- see Util.serve_card_art.
function Util.item_cover(item)
    if type(item) ~= "table" then return nil end
    -- A TRACK'S COVER COMES FROM THE MED-RES POOL, not the grid's. It is drawn at
    -- the full height of the body -- 364px and up -- and album_thumbs answers
    -- with the 300px file every grid tile uses, so it was being enlarged past its
    -- own size and every list wore a soft cover.
    local alb = (item.type == nil or item.type == "track") and item.album or nil
    local aurl = alb and alb.images and alb.images[1] and alb.images[1].url or nil
    -- An ALBUM carries its own images, and the argument above is the same one.
    if not aurl and item.type == "album" then
        aurl = item.images and item.images[1] and item.images[1].url or nil
    end
    if aurl then
        local p = Util.ensure_art_med(aurl)
        if p ~= "" then return p end
    end
    local kind = nil
    local t = item.type
    if t == "artist" then kind = "artist"
    elseif t == "playlist" then kind = "playlist"
    elseif t == "show" then kind = "show" end
    local e = {""}
    local ok = pcall(Util.album_thumbs, e, {item}, kind, nil, "serve-ctx||")
    if not ok then return nil end
    local _, icon = Util.serve_unpack(e[1])
    return icon
end

-- THE COVER A CARD IS ABOUT, and nothing else.
--
-- Util.serve_ctx_art falls back to whatever is PLAYING when no row was picked,
-- which is right for a list -- the backdrop beside a shelf is the music -- and
-- wrong for a card. A card is about one row: with no row there is nothing it
-- could be a picture of, so it shows none. That is also the whole of "if the
-- item doesn't have its own albumart, it shouldn't display a backdrop" -- every
-- branch here answers nil rather than reaching for a substitute.
function Util.serve_card_art(d)
    -- The view named one itself. The listener's result does exactly this, which
    -- is how its card comes to wear the track it just recognised.
    local named = Util.serve_named_cover()
    if named then return named end
    -- ...or the step that opened the card picked one. An action menu is opened
    -- BY picking a row, and ui_menu records that row as the subject of whatever
    -- menu comes next -- so this is the selected item, by construction.
    return Util.item_cover(Util.serve_ctx_item)
end

function Util.serve_art_after(name, d)
    local refresh = d and type(d.refresh) == "function" and d.refresh or nil
    -- An action menu has no refresh -- it is a fixed list of verbs -- but it is
    -- exactly the view that wants a cover beside it. Gating the whole
    -- continuation on refresh meant the one case this was written for never ran.
    -- No early return any more. It skipped the continuation for a view with no
    -- refresh and no picked item -- which is every plain list -- and the cover
    -- beside one is now the PLAYING track's, which such a view can still have.
    Util.serve_after = function()
        if refresh then
            -- UNTIL THE GRID IS FULL, not until the first batch is.
            --
            -- Each pass of the view's own refresh resolves the next THUMB_SYNC
            -- covers -- the ones it fetched last time are on disk now, so they
            -- are no longer pending -- and reports everything resolved so far.
            -- Looping it fills the whole grid instead of its first sixty.
            --
            -- That cap was rofi's. rofi could not draw a menu until its icons
            -- existed, so fetching a 1500-album discography up front WAS the
            -- menu hanging, and everything past sixty had to be handed to a
            -- detached prefetch and picked up on some later draw -- which is why
            -- a grid of 69 artists came up with nine blank tiles. Nothing here
            -- waits on art: the rows go out first and covers arrive as events,
            -- so there is no reason to stop at any particular number.
            --
            -- The clock is not a cap on covers, it is a cap on how long the
            -- engine may go without answering. It reads one line at a time and
            -- cannot be interrupted mid-fill, so a pathological list would
            -- otherwise leave the next keypress waiting minutes. Whatever is
            -- unresolved when it runs out is already spooled to the detached
            -- prefetch, exactly as the whole tail used to be.
            local deadline = os.time() + Util.ART_FILL_SECONDS
            local reported = -1
            while true do
                local ok, rebuilt = pcall(refresh)
                if not ok or type(rebuilt) ~= "table" then break end
                local items = Util.serve_icons(rebuilt)
                if #items > 0 then
                    Util.serve_write({ev = "art", view = name, items = items})
                end
                -- No new cover came back: everything reachable is reported, and
                -- the rest is either absent or in another process's hands.
                if #items <= reported then break end
                reported = #items
                if os.time() >= deadline then break end
            end
        end
        -- A BLOCK STOOD HERE resolving every row's own cover, for a list, so
        -- that the backdrop could follow the cursor as you moved it. The
        -- backdrop does not follow the cursor any more -- it follows PLAYBACK,
        -- which is the thing a cover beside a list of tracks is actually about
        -- -- so nothing read those paths, and resolving them was a hash and a
        -- stat per row (three hundred of them on a search result) spent on
        -- nothing. A grid's tiles are unaffected: those come from the view's own
        -- refresh, above.
        local wants = not (d and d.opts and d.opts.art == false)
        -- ALWAYS SENT, even as an empty path. The UI used to clear the cover
        -- itself on every draw and wait for this to put one back, so a redraw
        -- collapsed the cover to nothing and grew it again -- shoving the rows
        -- sideways and back for a menu that had not changed. Saying "none"
        -- explicitly is what lets it stop guessing.
        -- ...and "none" is an answer a menu may give for itself: opts.art=false
        -- means this one is about nothing you can picture. Still sent, for the
        -- reason above -- the UI is told there is no cover, not left to guess.
        -- ...but a CONTEXT MENU SAYS NOTHING AT ALL, which is different from
        -- saying "none". It is a card drawn OVER a list that is still on screen
        -- wearing its own backdrop, so a cover -- or the absence of one -- is an
        -- answer about a menu that is not the one the backdrop belongs to. The UI
        -- has no way to tell those apart from an event, so it applied this to the
        -- list underneath: opening a track's action menu inside an album wiped the
        -- album's sleeve and fell back to whatever happened to be playing.
        --
        -- ...unless it HAS one, which is the listener's result menu and nothing
        -- else (see SERVE_VIEWS["listen-result"]). That one arrives out of nowhere
        -- with no list behind it to be about, so its cover is the only thing on
        -- screen saying what spoot identified -- and staying silent left the
        -- backdrop showing whatever was playing, which is precisely the track it
        -- is NOT. So: silent when a context menu declares it has no subject, and
        -- otherwise it speaks like any other menu.
        -- A CARD CARRIES ITS OWN PICTURE, and never the list's. It used to say
        -- nothing at all when it declared `art=false` -- which every action menu
        -- does -- because the alternative then was overwriting the backdrop of
        -- the list still showing behind it. `own` is what separates those two
        -- now: the UI draws this inside the card and leaves the list alone.
        --
        -- Resolved from the picked row only (see Util.serve_card_art), so a card
        -- about something with no artwork simply has none.
        if d and d.opts and d.opts.context then
            -- ...unless the card says it is about nothing. See the trail menu.
            local own = (not d.opts.no_cover) and Util.serve_card_art(d) or nil
            Util.serve_write({ev = "context-art", view = name, own = true,
                              path = own or ""})
            return
        end
        -- ...and NEITHER DOES A VIEW THAT DREW NO MENU. The listener is the case:
        -- it answers empty -- its whole output is a card the UI draws itself --
        -- and then this fired anyway and pushed the PLAYING track's cover into the
        -- backdrop of the menu still sitting underneath. Spawning a picture behind
        -- the listening card, and leaving it there after the listen was cancelled,
        -- replacing whatever the list had been wearing.
        if not (d.entries and #d.entries > 0) then return end
        Util.serve_write({ev = "context-art", view = name,
                          -- WHOSE COVER THIS IS. A shelf's backdrop follows the
                          -- playback poll, which is up to a second behind the pick:
                          -- play a track out of a different list and the poll still
                          -- names the one before it, so the old cover held while the
                          -- rows were already the new list's. That is the flash.
                          --
                          -- The engine is not behind -- Util.play_or_toggle adopts
                          -- the track the moment the request goes out, so the cover
                          -- resolved here is already the right one. Naming the track
                          -- it belongs to lets the UI tell "the poll has not caught
                          -- up yet" from "the music moved on by itself", and prefer
                          -- this answer only in the first case. See coverArt.
                          id = current_track and current_track.id or nil,
                          path = (wants and Util.serve_ctx_art(d) or nil) or ""})
    end
end

-- Opening a Main tile runs the tile's OWN open() -- the same closure the rofi
-- grid invokes on Return -- so the mapping from tile to view is not duplicated
-- anywhere. A tile that changes where it goes changes here for free.
function Util.serve_open(args)
    local key = args and args.tile
    for _, t in ipairs(Util.MAIN_TILES) do
        if t.key == key then
            if not t.open then return {view = key, rows = {}, empty = true} end
            -- Same runner as a named view: a tile is just another entry point.
            return Util.serve_run(key, t.open, args)
        end
    end
    error("unknown tile: " .. tostring(key), 0)
end

-- What is playing, right now. The UI polls this about once a second and
-- INTERPOLATES between answers, which is how a progress bar runs at 60fps over a
-- 1Hz truth -- asking sixty times a second would be neither cheaper nor more
-- accurate. Position comes from playerctl, which reads the local spotifyd rather
-- than a Spotify round trip, so this costs no API call.
function Util.serve_playback()
    -- THE FAST PATH FIRST. get_playback is a me/player request and throttles
    -- itself to once every five seconds, so a poll running once a second was
    -- mostly reading a cached answer -- and the transport marker sat on the
    -- track you had just left for up to five seconds after autoplay moved on.
    --
    -- fast_now_track reads the daemon's own snapshot and asks playerctl over
    -- D-Bus: no network, and current the moment MPRIS says a track changed. The
    -- request is kept as the fallback for when that snapshot is missing, which
    -- is the same order every other caller in this file uses.
    if not Util.fast_now_track() then get_playback() end
    local t = current_track
    return {
        playing  = is_playing or false,
        -- WHETHER THERE IS A PLAYER BEHIND ANY OF THIS. `id` below names the last
        -- track Spotify remembers, which on a cold start is one from hours ago
        -- with nothing loaded anywhere -- the difference between "paused" and
        -- "over", and nothing in this payload could tell them apart. The UI drew
        -- the transport marker on it either way. See Util.played_here.
        live     = (is_playing or Util.played_here) or nil,
        shuffle  = is_shuffle or false,
        repeat_  = repeat_state or "off",
        -- WHAT IT IS SET TO. Cached for a second inside get_playerctl_volume, so
        -- a poll running once a second costs one read of that cache and no bus
        -- traffic. The UI needs it to show what a nudge did.
        volume   = get_playerctl_volume(),
        -- ...AND WHETHER IT IS SAVED. `icons` below carries this too, as a glyph
        -- among others -- but that string is the engine's finished answer about
        -- how a status LOOKS, and a front end picking the heart back out of it
        -- would be a second copy of that knowledge. A boolean is the fact.
        liked    = (t and t.id and Util.is_liked(t.id)) or false,
        id       = t and t.id or nil,
        name     = t and t.name or nil,
        artists  = t and artist_names(t) or nil,
        album    = t and t.album and t.album.name or nil,
        -- ...and its ID, which is what an album GRID needs: a tile is an album,
        -- so the tile that is playing is the one holding the playing track, and
        -- matching on the track id could only ever light up a single. The engine
        -- used to work this out itself in display_album and bake the answer into
        -- the row's text; the UI marks rows from live state now, so it needs the
        -- same fact rather than the same string.
        albumId  = t and t.album and t.album.id or nil,
        duration = t and t.duration_ms or 0,
        -- Milliseconds, from the player itself. nil when nothing is playing,
        -- which the UI reads as "no bar to draw" rather than "position zero".
        position = t and math.floor((get_playerctl_position() or 0) * 1000) or nil,
        -- Liked, explicit, lyrics -- built by Util.status_icons, the same
        -- function every row and message bar in the app uses. Sent as the
        -- finished string rather than as flags: the glyphs and their order are
        -- the engine's to decide, and a second copy of that knowledge in QML is
        -- exactly how the now-playing bar would start disagreeing with the rows
        -- above it.
        icons = t and trim(Util.status_icons(t)) or nil,
        -- ITS COVER, if it is already on disk. Cache-only: this answers a poll
        -- that runs once a second and must never wait on a download. With it the
        -- UI can follow a track change -- autoplay, the next button, anything --
        -- without asking for the menu to be built again.
        art = (function()
            local u = t and t.album and t.album.images and t.album.images[1]
                        and t.album.images[1].url or nil
            if not u then return nil end
            local p = Util.ensure_art_med(u, true)
            if p ~= "" then return p end
            -- NOT ON DISK, AND NOTHING ELSE WAS EVER GOING TO PUT IT THERE.
            -- Cache-only is right for this poll and wrong as the whole story: a
            -- track played from a menu that never drew its cover -- the queue,
            -- a shelf, autoplay moving on -- had no warm entry and no one to
            -- make one, so the backdrop stayed empty until some other view
            -- happened to fetch the same picture. Reopening a menu or pausing
            -- and playing "fixed" it because those go through a path that does.
            --
            -- Fetched AFTER the reply has gone out (see the serve loop's
            -- Util.serve_after), so the poll still never waits on a download,
            -- and picked up by the next poll a second later -- which is a fade,
            -- not a stall. Once per track: a cover Spotify does not have must
            -- not be re-requested every second forever.
            if Util.serving and Util.art_warm_for ~= (t and t.id) then
                Util.art_warm_for = t and t.id
                local url = u
                Util.serve_after = function() Util.ensure_art_med(url) end
            end
            return nil
        end)()
    }
end

-- Transport. Everything here is local -- playerctl talks to the spotifyd on this
-- machine -- so a key press moves the music without waiting on a Spotify round
-- trip. Each action answers with the FRESH playback state, so the UI updates from
-- the reply instead of waiting for the next poll to notice.
function Util.serve_control(args)
    local a = args and args.action
    if a == "like" then
        -- THE PLAYING TRACK, and the same two functions the action menu's own
        -- Like row uses -- see the `like` branch of view_actions, including its
        -- note about taking the toggle's direction from state rather than from a
        -- label. Resolved the way art-current resolves it: the fast path first,
        -- the request only if there is no snapshot to read.
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        if current_track and current_track.id then
            do_like(current_track, Util.is_liked(current_track.id))
        else
            ui_say("Nothing playing")
        end
    elseif a == "shuffle" then toggle_shuffle()
    elseif a == "repeat" then toggle_repeat()
    elseif a == "playpause" then Util.mpris{op = "play-pause", player = "spotifyd"}
    elseif a == "next" then Util.mpris{op = "next", player = "spotifyd"}
    elseif a == "prev" then Util.mpris{op = "previous", player = "spotifyd"}
    elseif a == "seek" then
        -- Seconds, signed. playerctl takes "10+" / "10-" rather than a sign.
        local by = tonumber(args.by) or 10
        Util.mpris{op = "seek", value = by, player = "spotifyd"}
    elseif a == "volume" then
        -- RELATIVE OR ABSOLUTE. The wheel nudges (`by`), a slider would set
        -- (`to`), and the arithmetic is here rather than in the UI because only
        -- this side knows what the level currently IS -- the UI would have to
        -- read it back, add to it and race its own next notch.
        if args.to ~= nil then Util.set_volume(args.to)
        else Util.set_volume(get_playerctl_volume() + (tonumber(args.by) or 5)) end
    else error("unknown control: " .. tostring(a), 0) end
    return Util.serve_playback()
end

-- The live stack. A reader rather than exposing the local, so nothing outside
-- Util.session_set can rebind it.
function Util.session_stack() return _session_stack end

-- A `trail` COMMAND AND Util.serve_trail STOOD HERE. It answered with the live
-- crumb plus the archived ones, for a front end that wanted the whole history in
-- one payload -- and nothing ever asked: not the UI, not the host's watchers, not
-- smoke.sh or views.sh. The trail the UI draws comes with every draw (see
-- serve_draw's `crumb`), and the archived ones are a MENU (Util.view_trail_jump),
-- not a payload.

-- LYRICS, with their timing. spoot already caches lrclib's synced form as
-- parallel `times` and `lines` arrays, so live sync needs no new fetching and no
-- new format -- the UI picks the current line from the position it is already
-- interpolating for the progress bar.
--
-- Same cache_fetch key and disk path the lyrics view uses, so a track fetched by
-- one is already warm for the other.
function Util.serve_lyrics(args)
    local id = (args and args.id) or (current_track and current_track.id)
    if not id or id == "" then return {id = nil, lines = {}, synced = false} end
    local disk = P.lyrics .. "/lyrics_" .. id .. ".json"
    local d = disk_get(disk, P.ttl_lyrics)
    if type(d) ~= "table" then
        -- Not on disk: say so rather than blocking the UI on a network fetch it
        -- did not ask for. The view path fetches; this reports.
        return {id = id, lines = {}, synced = false, cached = false}
    end
    return {
        id     = id,
        lines  = d.lines or {},
        -- Seconds, as lrclib gives them and as parse_lrc stored them. The UI
        -- compares against the position it already has in milliseconds.
        times  = d.times or nil,
        synced = (d.times ~= nil and #(d.times) > 0) or false,
        cached = true
    }
end

-- WARM START. The saved stack's last entry names a view and carries the ids it
-- needs; reg() registered an opener for exactly this. So restoring is not a
-- special path -- it is the same opener a live menu calls, run under the same
-- recorder, which is what makes a restored view behave identically to one you
-- navigated to.
function Util.serve_restore()
    local saved = Util.serve_saved
    if type(saved) ~= "table" or #saved == 0 then return {empty = true} end
    local leaf = saved[#saved]
    local v = leaf and leaf.view and VIEWS[leaf.view]
    if not (v and v.open) then return {empty = true} end
    -- The stack MINUS its leaf. The opener pushes the leaf's own scope back on,
    -- so installing the whole thing left it there twice -- the crumb read
    -- "... > And Thou Shalt Trust the Seer > And Thou Shalt Trust the Seer".
    local below = {}
    for i = 1, #saved - 1 do below[i] = saved[i] end
    Util.session_set(below)
    Util.serve_restoring = true
    local ok, restored = pcall(Util.serve_run, leaf.view, function() v.open(leaf) end, {})
    Util.serve_restoring = false
    if not ok then error(restored, 0) end
    -- One shot. A second restore would re-open it on top of itself.
    Util.serve_saved = nil
    return restored
end

-- THE FIRST RUN, IN ORDER: account, then device, then the daemon. Blocking on
-- purpose -- each step is a browser page a person has to act on, and there is no
-- meaningful "meanwhile" for an app that cannot reach the API yet. The UI gets
-- out of the way for the duration and says what it is waiting for.
--
-- Every step is skipped if already done, so this is safe to call at any time and
-- is what System > Re-authenticate should end up calling too.
Util.serve_setup = function(args)
    local st = Util.setup_state()
    if #st.lack > 0 then
        -- Cannot log in yet, and saying which programs are missing is more use
        -- than a page that would fail to load.
        return {ok = false, token = st.token, device = st.device, lack = st.lack}
    end
    local did = {}
    if not st.token then
        Util.setup_notify("Sign in to Spotify",
            "spoot has opened the authorisation page in your browser.")
        ensure_auth()
        did[#did + 1] = "account"
    end
    -- Only once the account is in: the device login is pointless without one, and
    -- opening two browser pages when the first was abandoned is worse than
    -- stopping.
    local have_token = get_token() ~= nil
    local did_device = false
    if have_token and not st.device then
        Util.setup_notify("Authorise playback",
            "One more page: this signs in the spoot device itself, which is what "
            .. "actually plays audio.")
        did_device = Util.device_auth()
        did[#did + 1] = "device"
    end
    if have_token then
        -- REPLACED, not merely ensured. spotifyd is already running by now --
        -- serve mode starts it at launch -- and it read its credentials at that
        -- launch, when there were none. Leaving it up would mean a device that
        -- has just been authorised and still cannot be played to.
        if did_device then Util.restart_daemons() else ensure_spotifyd() end
    end
    return {ok = have_token and Util.device_ready(), token = have_token,
            device = Util.device_ready(), did = did, lack = {}}
end

Util.SERVE = {
    setup = Util.serve_setup,
    nav = Util.serve_nav,
    restore = Util.serve_restore,
    lyrics = Util.serve_lyrics,
    ping = function() return {pong = true, pid = Util.get_own_pid()} end,
    control = Util.serve_control,
    -- A `weblink` command stood here, copying the playing track's web link
    -- because that is what Alt+g used to do. Alt+g opens a PASTED link now (see
    -- SERVE_VIEWS' open-link, and Util.KEYBINDS, which always said so), and
    -- copying the current track's is a row in its own action menu -- Alt+Return,
    -- Copy Web Link -- which also marks the row it copied. Nothing called this.
    main = Util.serve_main,
    view = Util.serve_view,
    open = Util.serve_open,
    playback = Util.serve_playback,
    -- Asked repeatedly while the listening card is up, and always answered on
    -- the spot. See Util.listen_poll.
    -- THE TWO WATCHERS, as requests. Embedded, spoot subscribes to MPRIS and
    -- runs a 25s timer itself and posts each one in here, so the pair of
    -- always-on `lua` processes that used to do this are gone. The standalone
    -- --daemon and --recent-watch entry points still exist and still call the
    -- same two functions; they are simply not started when a host is present.
    -- No arguments: the host says only THAT the player changed, and the read
    -- happens here on the worker's own bus connection. Passing the metadata
    -- across would marshal the same map twice and could still be stale by the
    -- time it arrived, and a snap is deduped by track id either way.
    ["daemon-snap"] = function()
        Util.daemon_snap(Util.mpris{op = "metadata"}.value)
        return {ok = true}
    end,
    ["recent-tick"] = function()
        -- A rate-limit cooldown is the one thing that must still be honoured:
        -- polling through it is what earns the next one.
        if Util.rate_cool() > 0 then return {skipped = true} end
        return {recorded = Util.recent_tick()}
    end,
    ["listen-poll"] = function() return Util.listen_poll() end,
    ["listen-stop"] = function() return Util.listen_stop() end,
    views = function()
        local ks = {}
        for k in pairs(Util.SERVE_VIEWS) do ks[#ks+1] = k end
        table.sort(ks)
        return {views = ks}
    end
}

function Util.serve_mode()
    -- THE ENGINE IS ANSWERING A UI. Views that can say something twice -- once
    -- as a menu and once as an event -- read this to choose the event.
    Util.serving = true
    -- `Util.detached` IS NOT SET HERE, and used to be. It means "I am a
    -- background job with nobody to talk to and no business starting more jobs"
    -- -- run_revalidate, the recent watcher, every --prefetch-* entry point sets
    -- it about themselves. Serve mode is the exact opposite of that and had been
    -- claiming it since the day rofi went, on the reasoning that ui_say could not
    -- reach "a UI that is not rofi". It reaches this one: ui_say is an event now.
    --
    -- What that one line switched off, in the only mode spoot ever runs in:
    --
    --   * the 429 and 401 notices (see api_get) -- rate-limited and expired-token
    --     both failed in complete silence, which is most of "spoot just stops
    --     working";
    --   * the rate-limit cooldown file that goes with them, so nothing backed
    --     off either;
    --   * Util.spawn_plindex, so the playlist-membership index was never built
    --     in the running app -- that is what Remove from Playlist reads;
    --   * Util.spawn_revalidate, so nothing behind a menu ever refreshed itself.
    --     Every REVALIDATOR in this file was unreachable.
    ensure_cache()
    -- The background halves main() also starts. Without the daemon there is
    -- nothing watching for a track change, so desktop notifications never fired;
    -- without the recent watch, Recently Played never fills. Deliberately NOT
    -- init_instance_lock: the host owns single-instance through its socket, and
    -- taking the rofi build's lock here would have the two fighting over it.
    ensure_daemon()
    Util.ensure_recent_watch()
    -- The player, exactly as main() starts it. Without this there is no Connect
    -- device to play to: every transport command reached a playerctl with no
    -- players, and Return on a track quietly did nothing. Returns immediately --
    -- the device is resolved lazily at play time.
    ensure_spotifyd()
    -- THE SESSION AS FOUND. Read from disk first -- nothing else in serve mode
    -- does it, so the stack was empty and every warm start looked like a cold
    -- one. Then snapshotted, because every request resets the stack to build its
    -- own and the first one the UI sends would erase exactly what a warm start
    -- needs. The trail is loaded for the same reason: it is what the crumb draws
    -- previous journeys from.
    session_load()
    Util.trail_load()
    -- THE LIKED SET. Nothing in serve mode read it: init_library is main()'s and
    -- main() never runs here, so `liked` stayed empty for the life of the
    -- process. Everything that asks "is this track liked" was therefore answered
    -- no -- the ♥ never appeared on a row in any list, and the action menu's row
    -- said Like for a track you had already liked, so Unlike was unreachable.
    -- One read of a file that is already on disk.
    populate_liked_ids()
    -- REPLAY IS A SETTING. Off, spoot opens on Main however deep you were when
    -- it last closed -- the stack is still LOADED and still written, so the
    -- setting is a switch rather than a demolition and turning it back on
    -- resumes from wherever you have since been. The `ready` event below reports
    -- restore = false on the strength of this being empty, so the UI asks for
    -- Main without needing to know a setting exists.
    Util.serve_saved = Util.ui_get().replay
        and json.decode(json.encode(_session_stack or {})) or {}
    -- THE INTERCEPTION. ui_menu is a file local, so assigning it here rebinds
    -- the upvalue every view function already closed over -- they call this from
    -- now on without knowing anything changed.
    --
    -- Answering nil is what makes a view render exactly once: nil is "dismissed"
    -- to every caller, so each `while true` loop breaks and each Util.scope
    -- unwinds properly, leaving the session stack as tidy as a real visit would.
    -- NO ART BEFORE THE ROWS, whoever asks for it. Some views decorate their own
    -- entries before handing them to view_browse, so deferring only the
    -- recorder's refresh still left that work on the critical path. Gating the
    -- function itself is the only place that covers every caller.
    Util._real_album_thumbs = Util.album_thumbs
    Util.album_thumbs = function(...)
        if Util._art_defer then return end
        return Util._real_album_thumbs(...)
    end

    ui_menu = function(entries, opts)
        opts = opts or {}
        if Util.serve_capture then
            -- SCRIPTED SELECTION. Answering nil unwinds a view; answering an
            -- index makes it dispatch that row for real -- play the track, open
            -- the album, follow the artist -- and draw whatever comes next.
            -- Feeding a path of indices therefore walks the app exactly as a
            -- person would, through the app's own dispatch, with no second copy
            -- of "what does Return do here" living in the UI.
            --
            -- This is the same idea replay_session already uses to restore a
            -- warm start: drive the real views rather than describe them.
            -- Resolved before the addressing rule below, which reads it: the
            -- theme is part of a menu's identity.
            -- A PLAIN NAME. A `([^/]+)%.rasi$` strip stood here and on the
            -- message event below, from when a theme was a path to a file --
            -- kept "in case a path ever arrives again", which is a pattern match
            -- per menu against a suffix nothing in the app can produce. Every
            -- theme is a name and is declared as one; see THEME_MENU.
            local th = opts.theme or (opts.thumbs and Util.THEME_THUMBS or THEME_MENU)

            -- THE ADDRESSING RULE, and the only one. A path step answers a
            -- MENU, not a call. Menus redraw themselves constantly -- after an
            -- action runs, after a rebuild, after a nested view unwinds -- and
            -- counting raw ui_menu calls handed those redraws the answer
            -- meant for the next menu. Everything below it then shifted by one,
            -- which is why picking a row in a track's action menu acted on the
            -- album grid two levels up.
            --
            -- A menu is identified by WHERE it is: its depth in the session
            -- stack plus the view that owns that depth. A redraw has the same
            -- identity as the draw before it and therefore consumes nothing; a
            -- genuinely new menu has a new one and takes the next step.
            local stack = _session_stack or {}
            -- Depth, owning view, AND theme. Depth alone was not enough: an
            -- album's, artist's and playlist's action menus are deliberately
            -- UNSCOPED -- they are context menus, not places -- so they draw at
            -- the same stack depth as the grid behind them and looked like a
            -- redraw of it. Their theme differs (sub/action versus thumbs),
            -- which is exactly the distinction rofi itself makes.
            -- ...AND WHETHER IT IS A CONFIRMATION. A yes/no prompt is raised from
            -- inside the view it belongs to, at that view's depth and in that
            -- view's theme, so by every measure above it looks exactly like a
            -- redraw of the menu that just answered -- and the rule then quite
            -- correctly declines to feed the same menu twice. The prompt was
            -- therefore never answerable: `Restart` after a bitrate change, the
            -- track-cache clear, the playlist delete. Each one drew, took no
            -- answer, and returned nil, which every call site reads as "the user
            -- backed out".
            --
            -- Marked at the call site rather than guessed at from the rows,
            -- because the rows of a redraw legitimately change -- liking a track
            -- relabels one -- and a rule that read a relabel as a new menu would
            -- misfeed every list in the app.
            -- ...AND THE PROMPT, which is the last thing that tells two menus at
            -- one depth apart. Depth and theme are not enough for a menu raised
            -- from inside another that shares both: the artist hub is unscoped
            -- (a context menu, not a place) and wears THEME_SUB, so opened from
            -- the Playback menu -- also THEME_SUB, same depth -- it read as a
            -- REDRAW of Playback, and the rule quite correctly declined to feed
            -- the same menu twice. Every row in a pasted artist link did nothing.
            --
            -- Safe as an identity component precisely because a redraw is the
            -- same ui_menu call with the same opts: its prompt cannot differ.
            -- What differs is the menu ("Playback" against the artist's name),
            -- which is the distinction being asked for. It does not retire
            -- `confirm` below -- a yes/no prompt is raised with its parent's
            -- prompt on purpose, so that stays the thing that marks it.
            local here = #stack .. ":" .. tostring(stack[#stack] and stack[#stack].view or "-")
                .. ":" .. tostring(th or "-")
                .. ":" .. tostring(opts.prompt or "-")
                .. (opts.confirm and ":confirm" or "")
            local ans = nil
            if Util.serve_answers and here ~= Util.serve_last_menu then
                Util.serve_depth = Util.serve_depth + 1
                ans = Util.serve_answers[Util.serve_depth]
                if ans ~= nil then
                    Util.serve_last_menu = here
                    Util.serve_answered_menus[#Util.serve_answered_menus + 1] = here
                end
            end
            -- A step may be {i = 3, alt = true} instead of a bare 3. That is
            -- Shift+Return: rofi reports it through an exit code, and every
            -- caller reads Util.alt_pressed immediately after the menu returns,
            -- so setting it here is exactly what the real key does. Reset first,
            -- because the flag is sticky and a stale true would send the NEXT
            -- plain Return into an action menu.
            Util.alt_pressed = false
            -- Delete travels the same way. rofi reported it as its own exit code
            -- and Util.view_trail_jump reads the flag immediately after the menu
            -- returns, so setting it here is exactly what the key did. Cleared on
            -- every draw for the same reason alt is: the flag is sticky, and a
            -- stale true would erase a row the next Return only meant to pick.
            Util.del_pressed = false
            -- And Tab, which two menus claim for themselves: the trail menu
            -- cycles Trail Steps against Trail History with it, and the search
            -- results cycle their type picker. Both branches were still here and
            -- both were unreachable, because nothing set the flag once rofi
            -- stopped reporting the key -- so the menus kept the code for a
            -- feature they no longer had. Same shape as alt and del: a flag on
            -- the path step, read immediately after the menu returns.
            Util.tab_pressed = false
            -- ...and Queue, which is a middle click on a row. Same shape again: a
            -- flag on the step, read once, cleared on every draw. It is not a key
            -- in the rofi build at all -- there was no third mouse button to bind
            -- -- so this is the one of the four with no keyboard ancestor.
            Util.queue_pressed = false
            if type(ans) == "table" then
                Util.alt_pressed = ans.alt and true or false
                Util.del_pressed = ans.del and true or false
                Util.tab_pressed = ans.tab and true or false
                Util.queue_pressed = ans.queue and true or false
                ans = ans.i
                -- TAB AND DELETE REDRAW THE MENU YOU ARE STANDING IN, and that
                -- redraw has to be addressable or the step after it goes
                -- unanswered. The addressing rule identifies a menu by where it
                -- is -- depth, view, theme -- so a mode swap looks exactly like a
                -- redraw of the menu that was just answered, and the rule quite
                -- correctly refuses to feed the same menu twice. That is why one
                -- Tab reached Trail History and a second one could never get
                -- back: the answer meant for it was never taken.
                --
                -- Forgetting the menu here says the opposite: THIS one changed
                -- underneath you, so what comes next is a new menu. Narrow on
                -- purpose -- it fires only for a step that carried one of these
                -- two keys, both of which mean exactly that.
                if Util.tab_pressed or Util.del_pressed then
                    Util.serve_last_menu = nil
                end
            end
            -- The SEARCH HISTORY list is the one menu whose Delete ui_menu
            -- handled itself: view_search only ever passes hist_key and never
            -- sees the key, so the replacement does the removal here rather than
            -- growing a branch into the view that the original never had. Every
            -- other claimant -- the trail history -- reads Util.del_pressed for
            -- itself and must still find it set, which is why this clears the
            -- flag only when it has actually spent it.
            if Util.del_pressed and opts.hist_key and type(ans) == "number" then
                local q = entries and entries[ans]
                if type(q) == "string" and Util.hist_remove(opts.hist_key, q) then
                    Util.del_pressed = false
                    -- The answer was spent ON the deletion, so this is not a
                    -- selection: re-read the list and fall through to the
                    -- capture, redrawing the same menu without the row. That is
                    -- what the view's own `while true` loop would have done.
                    if type(opts.refresh) == "function" then
                        local fresh = opts.refresh()
                        if type(fresh) == "table" then entries = fresh end
                    end
                    ans = nil
                end
            end
            -- QUEUE THE ROW AND STAY PUT. Handled here for the same reason the
            -- Shift+Return default below is: a track row has no queue branch in
            -- any view, because until there was a middle button nothing could ask
            -- for one. The row is queued and the answer is SPENT -- ans goes nil,
            -- so the capture below redraws the very menu you are standing in and
            -- the step never describes a place (see Util.serve_keep, which is what
            -- takes it back off the trail).
            if Util.queue_pressed and ans ~= nil and type(opts.items) == "table"
               and type(entries) == "table" and #opts.items == #entries
               and type(ans) == "number" then
                Util.queue_pressed = false
                local item = opts.items[ans]
                if item then
                    do_add_queue(item)
                    ans = nil
                end
            end
            -- ui_menu used to handle Shift+Return ITSELF for lists that do
            -- not claim it: a track row has no alt branch in
            -- view_browse because rofi opened the action menu on the list's
            -- behalf. Replacing ui_menu took that with it, so the default
            -- handler is reproduced here, from the same opts it read.
            if Util.alt_pressed and ans ~= nil and not opts.alt_select
               and type(opts.items) == "table" and type(ans) == "number" then
                local item = opts.items[ans]
                if item then
                    Util.alt_pressed = false
                    view_actions(item, opts.ctx_type, opts.ctx_id, opts.items, ans, opts.entries)
                    return nil      -- the action menu was the destination
                end
            end
            -- The item this step picked is the subject of whatever menu comes
            -- next, and it is the only place that association exists: an action
            -- menu is a list of verbs with no idea what it is acting on.
            -- Only when the menu's items ARE its rows. An action menu carries
            -- opts.items too -- the list it was opened from, so Shift+Return can
            -- reach it -- and indexing that by the row you picked names a
            -- completely unrelated track. That is why an album's action menu
            -- wore the cover of whatever sat at the same index in the list
            -- behind it.
            if type(ans) == "number" and type(opts.items) == "table"
               and type(entries) == "table" and #opts.items == #entries then
                Util.serve_ctx_item = opts.items[ans]
                -- AND THE COVER THE MENU BEHIND US NAMED IS NOW STALE. A view
                -- that has one records it on the way in (Util.serve_cover),
                -- and Util.serve_ctx_art reads that first because a view naming
                -- its own cover is more reliable than re-resolving an item. But
                -- once a step has picked something, the picked thing is what the
                -- next menu is about -- so an album's action menu opened from
                -- inside an artist wore the ARTIST's picture, which is the one
                -- cover it could not possibly be. Whatever comes next names its
                -- own if it has one; view_actions does exactly that, after this.
                Util.serve_ctx_path = nil
                Util.serve_ctx_url = nil
            end
            if ans ~= nil then
                -- How deep we were when this step was answered. If the draw we
                -- finally capture is no deeper, nothing was navigated to: the
                -- step ran an ACTION and left us on the same menu.
                -- The menu this step was answered ON. The transient test below
                -- compares the captured draw against it: same menu means the
                -- step ACTED and left you where you were; a different menu means
                -- it took you somewhere. Depth alone was wrong here for exactly
                -- the reason it was wrong for addressing -- an unscoped action
                -- menu sits at its parent's depth, so picking a row in one got
                -- classified as an action and popped off the path, and the next
                -- Return indexed the grid behind it.
                -- A STRING step is free-typed input: a search query, a new
                -- playlist name, a rename. Menus that allow custom text take
                -- whatever the user wrote, so handing it straight back is
                -- exactly what rofi does.
                if type(ans) == "string" then return ans end
                -- by_index decides the ANSWER TYPE: menus that match on the row
                -- text (the action menus) must be handed the string, or the
                -- dispatch compares an integer against a label and silently does
                -- nothing.
                if opts.by_index then return ans end
                return entries and entries[ans] or nil
            end
            -- NOT resolved here. opts.refresh is the view's own rebuild, and it
            -- runs Util.album_thumbs, which downloads whatever the visible window
            -- is missing -- seconds, for a fifty-cover grid. Doing that before
            -- answering is rofi's bargain: nothing on screen until everything is
            -- ready. It is kept as a continuation instead, so the rows go out
            -- immediately and the covers follow as events.
            -- THE STACK, as it stands at this draw. Util.scope has pushed every
            -- step that led here and has not popped any of them yet, so this is
            -- the same stack the rofi build would be sitting on -- the crumb, the
            -- trail and a warm start all read from it. Taken here because the
            -- replay unwinds every scope on the way out, leaving it empty by the
            -- time the command returns.
            -- The theme rofi WOULD have been given, resolved by the same
            -- expression ui_menu uses -- the default is computed there, not
            -- passed in, so reading opts.theme alone reported nothing for every
            -- ordinary list and grid. Themes are copied to P.tmp as
            -- spoot_theme_<name>_<n>.rasi, so the copy's name is normalised back
            -- to the source it came from.
            -- THE ROWS AS THEY ARE NOW, not as they were when the view built
            -- them. A menu whose rows describe state it can change -- Like
            -- becoming Unlike, Save Album becoming Remove, Track Cache flipping
            -- -- hands ui_menu a `refresh` and lets it rebuild them; rofi
            -- called that itself every time it redrew, so the row you had just
            -- acted on was correct by the time you saw it again.
            --
            -- Capturing `entries` untouched skipped that entirely: the action
            -- ran, the menu came back, and every label still read as it had
            -- before. Liking a track did like it and then showed you "Like".
            --
            -- Costs nothing to do here: album_thumbs is gated by _art_defer,
            -- which is still set, so a refresh rebuilds labels and fetches no
            -- artwork. The continuation resolves that afterwards as before.
            local shown = entries
            if type(opts.refresh) == "function" then
                local rok, fresh = pcall(opts.refresh)
                if rok and type(fresh) == "table" then shown = fresh end
            end
            Util.serve_capture[#Util.serve_capture + 1] =
                {entries = shown, opts = opts, refresh = opts.refresh, theme = th,
                 menu = here,
                 stack = json.decode(json.encode(_session_stack or {})),
                 crumb = Util.breadcrumb_parts()}
        end
        return nil
    end
    -- Rename Playlist and New Playlist ask for TEXT, and ui_ask spawns rofi
    -- on its own rather than going through ui_menu -- so without this the one
    -- remaining path that could still open a rofi window was creating a
    -- playlist. It answers from the path like any other menu; a step meant for
    -- it is simply a string.
    --
    -- Answering nil is "cancelled", which every caller already handles, so a
    -- path that stops short of the prompt leaves the playlist untouched.
    ui_ask = function(prompt, preset, _theme)
        local ans = Util.serve_answers and Util.serve_answers[Util.serve_depth + 1]
        if type(ans) == "string" then
            Util.serve_depth = Util.serve_depth + 1
            return ans
        end
        -- Report what is being asked for, so the UI can put up its own field.
        Util.serve_write({ev = "prompt", prompt = tostring(prompt or ""),
                          preset = tostring(preset or "")})
        return nil
    end

    -- Same reason: a view that wants to say "No results" must not try to spawn
    -- rofi to say it. It becomes an event the UI can render however it likes.
    ui_say = function(msg, theme)
        -- The theme is the sheet's GEOMETRY: meta is 900px, binds 680, pods
        -- 1100, and the default message 700. One table in the UI looks any of
        -- them up, keyed by this name.
        local th = theme and tostring(theme) or nil
        Util.serve_write({ev = "message", theme = th,
                          text = Util.strip_markup(tostring(msg or ""))})
    end
    Util.serve_write({ev = "ready", restore = (#(Util.serve_saved or {}) > 0),
                      nav = Util.serve_nav_load(), commands = (function()
        local ks = {}
        for k in pairs(Util.SERVE) do ks[#ks+1] = k end
        table.sort(ks)
        return ks
    end)()})
    -- HOW THE UI SHOULD LOOK, before it draws anything. The UI ships no copy of
    -- these numbers and reads no file -- it is told, here and on every change,
    -- and Theme.geom applies them. Ahead of the first draw so the opening menu is
    -- already the right width rather than snapping to it a frame later.
    Util.ui_announce()
    -- WHAT IS MISSING, SAID AT THE DOOR. After `ready` deliberately: the UI has
    -- its first request in flight by then, so nine `command -v` calls cost the
    -- launch nothing. Silent on a healthy machine, which is nearly every launch.
    -- SPOOT_NO_AUTOSETUP holds all of this back: the dependency install and the
    -- two logins. For the automated UI check above all, which drives the real app
    -- and cannot answer a browser page -- without it, a machine with no token
    -- hides the window and waits five minutes for a login nobody is there to do.
    -- It is also the switch for anyone who would rather run --doctor themselves.
    if not os.getenv("SPOOT_NO_AUTOSETUP") then
        -- AND WHAT IS STILL OWED AFTER THEM. Sent second, always, because the
        -- order is the point: the UI installs first and logs in afterwards, and
        -- an event arriving in that order is the simplest way to say so.
        --
        -- The token is checked by looking for the FILE, not by calling
        -- get_token() -- that refreshes over the network, and a launch is not the
        -- place to spend ten seconds finding out something a stat can answer.
        local sok, st = pcall(Util.setup_state)
        if sok and st and (not st.token or not st.device) then
            Util.serve_write({ev = "setup", token = st.token, device = st.device,
                              lack = st.lack})
        end
    end
    for line in Util.serve_lines() do
        if line ~= "" then
            local req = safe_decode(line)
            if not req or not req.cmd then
                Util.serve_write({id = req and req.id, ok = false, err = "bad request"})
            else
                local fn = Util.SERVE[req.cmd]
                if not fn then
                    Util.serve_write({id = req.id, ok = false, err = "unknown command: " .. tostring(req.cmd)})
                else
                    -- The cold library build runs detached, so on the launch
                    -- that triggers it the read above ran against a file that
                    -- did not exist yet. Pick it up the moment it lands, the
                    -- same guard and for the same reason as main()'s loop: the
                    -- set being empty AND the file having appeared, so it can
                    -- fire at most once and only on that launch.
                    if not next(liked) and cache_exists(P.liked_ids) then
                        populate_liked_ids()
                    end
                    -- pcall, always: one bad command must not take the engine
                    -- down and leave the UI staring at a dead pipe.
                    Util.serve_after = nil
                    -- Stamped on every event this request goes on to write,
                    -- including the artwork pass below, which runs after the
                    -- reply has already gone out.
                    Util.serve_req_id = req.id
                    local ok, data = pcall(fn, req.args or {})
                    if ok then Util.serve_write({id = req.id, ok = true, data = data})
                    else
                        -- THE WHOLE THING TO THE LOG, one line to the bar. The
                        -- traceback is what makes a crash fixable and is kept
                        -- in full here; see Util.err_brief for why the UI is
                        -- not handed it.
                        io.stderr:write("spoot: " .. tostring(data) .. "\n")
                        Util.serve_write({id = req.id, ok = false,
                                          err = Util.err_brief(data)})
                    end
                    -- AFTER the reply is flushed, never before: this is the work
                    -- the UI must not wait on. A failure here costs artwork, not
                    -- the view, so it is guarded and dropped.
                    if Util.serve_after then
                        local after = Util.serve_after
                        Util.serve_after = nil
                        pcall(after)
                    end
                    Util.serve_req_id = nil
                end
            end
        end
    end
    -- THE WATCHERS GO WITH IT. The host held both pidfiles while it was up, so
    -- leaving them behind would have the next standalone spoot decline to start
    -- a daemon on the grounds that one it cannot see is already running.
    if Util.hosted then
        os.remove(P.daemon_pid)
        os.remove(P.recent_pid)
    end
end

-- WHAT SPOOT NEEDS, ON A TERMINAL. The same scan the UI runs at startup, printed
-- rather than drawn -- and this is where a privileged install belongs when there
-- is no non-interactive route to root, because here sudo has a terminal to ask
-- on. `--doctor install` does it; a bare `--doctor` only looks.
-- WHAT IS STILL OWED, which is now only ever the two logins. The dependency half
-- of this report -- and the `install` argument that acted on it -- went with the
-- installer: `setup` puts everything in place before spoot starts, so a spoot
-- that is running has already had that question answered.
if arg and arg[1] == "--doctor" then
    print(Util.setup_report())
    local st = Util.setup_state()
    os.exit((st.token and st.device) and 0 or 1)
elseif arg and arg[1] == "--serve" then
    Util.serve_mode()
elseif arg and arg[1] == "--daemon" then
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
elseif arg and arg[1] == "--listen" then
    -- The one flag that opens rofi, so it gets the same wrapper main() does: a
    -- keybind launch has no terminal, and without run_interactive a crash here
    -- would vanish without reaching Util.clean_exit. Only the preamble the flow
    -- actually needs -- the instance lock (so pressing the key while spoot is
    -- open does nothing rather than racing a second window), the daemon for the
    -- Play row the action menu offers, and one sync so that menu opens on live
    -- transport state. No init_library on the way IN -- nothing here reads the
    -- library, and paying for a build the listener never touches would only
    -- delay the window. The handover at the bottom runs it, but by then the user
    -- is going back into the app and wants it.
    Util.run_interactive(function()
        init_instance_lock()
        ensure_daemon()
        Util.sync_now()
        -- The trail and the stack this keybind lands ON. Skipping them made the
        -- result menu a lone entry with nothing under it: its breadcrumb read
        -- "Main > Track" however deep you already were, Backspace out of it
        -- ended the process instead of returning to the menu beneath, and an
        -- Alt+Space from it archived onto an empty Util.trail_history -- which
        -- Util.trail_save then wrote over the real trails.json with.
        --
        -- Loading is all that is needed; NOT replay_session. The menus below are
        -- not reopened on the way in -- the point of the keybind is to get to
        -- the listener -- they are reopened on the way OUT, by main() below,
        -- from the stack Util.scope leaves behind when the result menu closes.
        Util.trail_load()
        session_load()
        local shown = Util.view_listen()
        -- Alt+Space, Alt+L, Alt+P and the trail jump do not navigate themselves:
        -- they raise a flag and unwind, and main()'s loop is what acts on it.
        -- Reached from the keybind there is no main loop above this, so the flag
        -- was simply dropped and the process ended -- which read as the key
        -- closing spoot rather than going to the root menu. Hand over instead.
        --
        -- `shown` covers backing out: a result menu that was drawn and dismissed
        -- hands over too, so init_library's replay walks back into the trail --
        -- or opens the root grid when there was no trail to walk. Giving up on
        -- the listener (Escape, no match, not on Spotify) drew no menu and still
        -- just ends, which is what asking to identify a track and getting
        -- nothing should do.
        if shown or main_pending or liked_pending or recent_pending or Util.trail_jump_pending then
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
    -- the scratch directory leaked. The window simply vanished.
    --
    -- The detached modes already have this covered: daemon_mode wraps
    -- pcall(daemon_loop) and recent_watch_mode wraps pcall(poll). The one-shot
    -- helpers write to /dev/null, so there is nobody to tell.
    Util.run_interactive(main)
end
end)()
