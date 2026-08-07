#!/usr/bin/lua

(function()

-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

local P = {
    home      = os.getenv("HOME"),
    dir       = debug.getinfo(1, "S").source:match("^@(.*/)"),
    max       = 20,
    ttl       = 43200,
    ttl_lyrics = 7 * 24 * 3600,  -- 1 week
    spotify   = "d420a117a32841c2b3474932e49fb54b",
}
P.cache      = P.home .. "/.cache/spoot"
P.mass       = P.cache .. "/mass"
P.lyrics     = P.cache .. "/lyrics"
P.token      = P.cache .. "/token.json"
P.liked      = P.cache .. "/liked_tracks.json"
P.albums     = P.cache .. "/saved_albums.json"
P.artists    = P.cache .. "/followed_artists.json"
P.session    = P.cache .. "/session.json"
P.trails     = P.cache .. "/trails.json"
P.view_pos   = P.cache .. "/view_pos.json"
P.queue      = P.cache .. "/playback_queue.json"
P.art        = P.cache .. "/art"
P.liked_ids  = P.cache .. "/liked_ids.json"
P.volume     = P.cache .. "/volume.json"
P.recent     = P.cache .. "/recently_played.json"
P.bitrate    = P.cache .. "/bitrate"
P.state      = P.cache .. "/playback_state.json"
P.now        = P.cache .. "/now.json"
P.now_track  = P.cache .. "/now_track.json"
P.device     = P.cache .. "/device.json"
P.pl_index   = P.cache .. "/playlist_index.json"
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
-- Budget for the FIRST mesg line, excluding the status icons (which are split
-- off and never truncated) -- see the truncation call in rofi_dmenu.
-- Measured against the narrowest theme, main/sub.rasi at 700px: 1px border and
-- 30px message padding each side leave 638px, and JetBrainsMono Nerd Font Propo
-- Bold 12 is 10px per character. Subtract the shuffle/repeat prefix that
-- status_mesg prepends after truncation (57px) and the widest status icon run,
-- liked + explicit + lyrics (73px), and 508px remain. truncate_text appends an
-- ellipsis on top of the limit, so the cap is 49, not 50: 49 + "…" = 500px,
-- 630px in total.
local MESG_NAME_MAX_CHARS = 49
-- Trailing glyphs that carry a track's status. They live at the end of the line
-- and must survive truncation, so a long title costs title characters and never
-- the icons.
local STATUS_GLYPHS = {[0xf05d] = true, [0xf071] = true, [0xF0188] = true, [0xF0189] = true}
local ICON_PREFIX = {
    tracks    = "\u{F0387} ",
    albums    = "\u{F405} ",
    artists   = "\u{F415} ",
    playlists = "\u{F0411} ",
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

local function copy_to_clipboard(text)
    os.execute("echo " .. shell_quote(text) .. " | wl-copy 2>/dev/null")
end

local function copy_spotify_url(kind, id) copy_to_clipboard("https://open.spotify.com/" .. kind .. "/" .. (id or "")) end

local function parse_spotify_url(url)
    if not url or url == "" then return nil, nil end
    url = url:match("^(.-)\n") or url
    url = url:gsub("[?#].*$", "")
    url = url:gsub("/+$", "")
    url = url:gsub("open%.spotify%.com/intl%-[^/]+/", "open.spotify.com/")
    local kinds = {"track", "album", "artist", "playlist"}
    for _, kind in ipairs(kinds) do
        local id = url:match("open%.spotify%.com/" .. kind .. "/([%w%-_]+)")
        if id then return kind, id end
        id = url:match("spotify:" .. kind .. ":([%w%-_]+)")
        if id then return kind, id end
    end
    return nil, nil
end

local function url_encode(s)
    return s:gsub("([^%w%-%.%_%~])", function(c)
        if c == " " then return "+" end
        return string.format("%%%02X", string.byte(c))
    end)
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
Util._art_theme_tmpls = {}

function Util.get_own_pid()
    local f = io.open("/proc/self/stat")
    local raw = f and f:read("*a")
    if f then f:close() end
    return raw and tonumber(raw:match("^(%d+)"))
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
-- The \1..\2 region is UNWRAPPED, not deleted. Deleting it was right only for
-- the common `Util.markup('<span …>') .. text .. Util.markup('</span>')` shape,
-- where the blob holds nothing but a tag; it silently ate the text of the rows
-- that wrap tag AND content -- "Shuffle <b>ON</b>" in view_playback, and every
-- dimmed action row, which reduced to "" and so matched no saved cursor and no
-- echoed row. Unwrapping leaves the tags exposed for the gsub below to strip,
-- which lands tag-only wrappers on exactly the same result as before.
function Util.strip_markup(s)
    if not s then return s end
    s = tostring(s):gsub("\1(.-)\2", "%1")
    return s:gsub("<[^>]+>", "")
end

local THEME, THEME_MENU, THEME_LYR, THEME_MSG, THEME_SUB, THEME_BINDS, THEME_META, THEME_ART = (function()
    if arg and arg[1] and arg[1]:match("^%-%-") then
        -- Non-interactive modes (--daemon, --prefetch-lyrics) never open rofi.
        -- Skip the shared /tmp theme files so background processes can't wipe
        -- the resolved themes the interactive app is already using.
        Util.THEME_THUMBS = P.dir .. "/style/thumbs.rasi"
        return P.dir .. "/style/main.rasi", P.dir .. "/style/menu.rasi", P.dir .. "/style/lyrics.rasi",
               P.dir .. "/style/message.rasi", P.dir .. "/style/sub.rasi", P.dir .. "/style/binds.rasi",
               P.dir .. "/style/meta.rasi", P.dir .. "/style/art.rasi"
    end
    os.execute("rm -f /tmp/spoot_theme_*.rasi 2>/dev/null")
    local function resolve(src, name)
        local content = read_file(src)
        if not content then return src end
        local resolved = content:gsub('@import "ZENON"', '@import "' .. P.dir .. '/style/ZENON"')
        if resolved == content then return src end
        local fixed = "/tmp/spoot_theme_" .. name .. ".rasi"
        local f = io.open(fixed, "w")
        if f then f:write(resolved); f:close(); return fixed end
        return src
    end
    local d = P.dir .. "/style"
    P.THEME_SEARCH = resolve(d.."/search.rasi","search")
    Util.THEME_TRAIL = resolve(d.."/trail.rasi","trail")
    Util.THEME_THUMBS = resolve(d.."/thumbs.rasi","thumbs")
    return resolve(d.."/main.rasi","main"), resolve(d.."/menu.rasi","menu"), resolve(d.."/lyrics.rasi","lyrics"),
           resolve(d.."/message.rasi","message"), resolve(d.."/sub.rasi","sub"), resolve(d.."/binds.rasi","binds"),
           resolve(d.."/meta.rasi","meta"), resolve(d.."/art.rasi","art")
end)()

local _cache_ready = false
local function ensure_cache()
    if _cache_ready then return end
    os.execute("mkdir -p " .. shell_quote(P.cache) .. " " .. shell_quote(P.lyrics) .. " " .. shell_quote(P.mass) .. " " .. shell_quote(P.art) .. " " .. shell_quote(P.art .. "/highres"))
    -- A fetch interrupted mid-flight (Escape out of a grid, or a kill) leaves its
    -- .tmp behind and nothing else ever removed them -- they had piled up into
    -- thousands. -mmin +10 so a prefetch still running from an earlier launch
    -- keeps the files it is actively writing.
    os.execute("find " .. shell_quote(P.art) .. " -name '*.tmp*' -mmin +10 -delete 2>/dev/null &")
    -- Same treatment for the per-process api_get header files: the interactive
    -- process removes its own in clean_exit, but a detached helper (--notify runs
    -- once per track change) os.exits without unwinding. -maxdepth 1 so this does
    -- not walk lyrics/ and mass/, which hold thousands of files.
    os.execute("find " .. shell_quote(P.cache) .. " -maxdepth 1 -name '.api_hdr.*' -mmin +10 -delete 2>/dev/null &")
    _cache_ready = true
end

-- Resolved once per process; see the note at its use in api_get.
function Util.api_hdr_path()
    if not Util._api_hdr then
        ensure_cache()
        Util._api_hdr = P.cache .. "/.api_hdr." .. tostring(Util.get_own_pid() or "x")
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

-- Normalize an MPRIS mpris:trackid (which comes as a DBus object path or a
-- spotify: URI, sometimes quoted) down to the bare Spotify track ID.
function Util.extract_track_id(raw)
    if not raw then return "" end
    local cleaned = trim(raw):gsub("^'", ""):gsub("'$", "")
    return cleaned:match("^/spotify/track/(.+)") or cleaned:match("^spotify:track:(.+)") or cleaned
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

local function safe_decode(s)
    s = trim(s or "")
    if s == "" then return nil end
    local ok, data = pcall(json.decode, s)
    if not ok or type(data) ~= "table" then return nil end
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
local function mem_bust(key) _mem[key] = nil end
local function disk_get(path, ttl)
    local raw = read_file(path)
    if not raw then return nil end
    local d = safe_decode(raw)
    if not d or type(d) ~= "table" or type(d.fetched_at) ~= "number" then return nil end
    if ttl and os.time() - d.fetched_at >= ttl then return nil end
    return d.data
end
local function disk_set(path, data)
    write_file(path, json.encode({data=data, fetched_at=os.time()}))
end
local function disk_bust(path) os.remove(path) end

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

-- Restores a menu's cursor from a STABLE row key rather than the row's visible
-- label. Rows whose label encodes live state rewrite themselves the moment you
-- use them -- "Repeat OFF" becomes "Repeat CONTEXT", "Like" becomes "Unlike",
-- "Volume 75%" becomes "Volume 80%" -- and a stored LABEL then matched no row at
-- all, dropping the cursor to the top of the menu. `keys` is a parallel array
-- naming each row independently of what that row currently displays.
--
-- Keyed by name rather than by index on purpose: view_playback's Play/Pause row
-- exists only while something is playing, so an index would point one row off
-- whenever that changed, where "shuffle" resolves to the shuffle row either way.
function Util.pos_row(pos_key, keys)
    local saved = Util.pos_get(pos_key)
    if type(saved) ~= "string" then return 0 end
    for i, k in ipairs(keys) do if k == saved then return i - 1 end end
    return 0
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

-- Appends the market to a query string, for the endpoints that hand back track
-- or album objects. Sending it is what makes Spotify answer the availability
-- question at all (see Util.mark_availability) AND what stops it padding every
-- response with ~185 country codes.
--
-- Returns `params` untouched when the market is unknown -- offline, or no profile
-- yet. The response then carries no is_playable, so nothing is flagged and
-- nothing dims: silence rather than a guess.
function Util.with_market(params)
    local m = Util.market()
    if not m then return params end
    return (params and (params .. "&") or "") .. "market=" .. m
end

-- available_markets is NOT an availability signal, however much it looks like
-- one. Measured against the live API across all 142 tracks this once flagged in a
-- 663-track library: the array was EMPTY for 130 of them, and for the 12 where it
-- was populated it still disagreed with reality 11 times. 137 of the 142 played
-- fine -- a 96.5% false-positive rate, which is what greyed out a fifth of Liked
-- Tracks.
--
-- Spotify only answers the question when the request carries a market, and then
-- it answers with is_playable. That is the single field read here; the old array
-- is discarded on sight, purely to keep it out of the cache on any response that
-- still arrives with one (see Util.with_market for why most no longer do).
--
-- Clearing `unavail` on a positive is what lets a re-fetch heal a stale flag,
-- since the flag outlives the data it was derived from.
function Util.mark_availability(o)
    local function walk(t)
        if type(t) ~= "table" then return end
        t.available_markets = nil
        if t.is_playable == false then t.unavail = true
        elseif t.is_playable == true then t.unavail = nil end
        t.is_playable = nil
        for _, v in pairs(t) do
            if type(v) == "table" then walk(v) end
        end
    end
    walk(o)
    return o
end

local function cached_fetch(key, disk_path, ttl, fetch_fn)
    local v = mem_get(key)
    if v ~= nil then return v end
    if disk_path then
        v = disk_get(disk_path, ttl)
        if v ~= nil then mem_set(key, v, ttl); return v end
    end
    v = fetch_fn()
    if v ~= nil then
        local empty = type(v) == "table" and next(v) == nil
        if not empty then
            Util.mark_availability(v)
            mem_set(key, v, ttl)
            if disk_path then disk_set(disk_path, v) end
        end
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
    local c = safe_decode(read_file(P.liked))
    if c and c.tracks then
        for _, t in ipairs(c.tracks) do
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

-- THE session invariant, in one place: a menu owns exactly one stack entry,
-- pushed on entry and removed on exit, no matter HOW it exits — normal
-- return, early return, break, error, or a nested view that leaked entries.
-- Because the body is a closure there is no exit path that can "forget" to
-- pop, which is what makes stack/trail sync structural instead of a
-- convention every future view has to remember to honour.
--
-- NEW VIEWS MUST USE THIS rather than a manual session_push/session_pop pair.
function Util.scope(entry, body)
    -- A view with no VIEWS entry can be pushed but never restored, so a warm
    -- start would silently drop it and land the user somewhere else. Loud on
    -- stderr (visible in the daemon log / terminal) rather than fatal: a missing
    -- registration is a bug in new code, not a reason to kill a running session.
    if type(entry) == "table" and entry.view and not VIEWS[entry.view] then
        io.stderr:write("spoot: view '" .. tostring(entry.view)
            .. "' is not in VIEWS -- it cannot be restored on a warm start\n")
    end
    local depth = #_session_stack
    local gen   = Util.session_gen
    session_push(entry)
    local ok, a, b = pcall(body)
    if Util.session_gen == gen then
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

local function view_label(view)
    local v = VIEWS[view]
    return (v and v.label) or view or "?"
end

local function crumb_name(entry)
    if type(entry) ~= "table" then return nil end
    if entry.artist_name and entry.artist_name ~= "" then return entry.artist_name end
    if entry.track_name and entry.track_name ~= "" then return entry.track_name end
    if entry.playlist_name and entry.playlist_name ~= "" then return entry.playlist_name end
    if entry.album_name and entry.album_name ~= "" then return entry.album_name end
    if entry.category_name and entry.category_name ~= "" then return entry.category_name end
    -- Views that stash the track name under a view-specific field (so
    -- replay_session can tell it apart from an "action" entry's track_name)
    -- rather than falling back to a generic label like "Lyrics" or "Seek".
    if entry.lyrics_track_name and entry.lyrics_track_name ~= "" then return entry.lyrics_track_name end
    if entry.recs_track_name and entry.recs_track_name ~= "" then return entry.recs_track_name end
    if entry.strack_name and entry.strack_name ~= "" then return entry.strack_name end
    if entry.query and entry.query ~= "" then return entry.query end
    return nil
end

function Util.parts_from_stack(stack, extra)
    local parts = {"Main"}
    local last_name = nil
    if stack then
        for _, e in ipairs(stack) do
            -- crumb_name already tolerates a non-table entry, but view_label(e.view)
            -- below did not: a truncated or hand-edited session.json/trails.json
            -- holding a bare string raised "attempt to index a string value" on the
            -- startup replay path, which has no pcall around it, and the app would
            -- not launch until the cache file was deleted by hand. A junk entry is
            -- worth skipping, never worth refusing to start over.
            if type(e) == "table" then
                local name = crumb_name(e)
                if name and name ~= last_name then
                    parts[#parts+1] = name
                    last_name = name
                else
                    parts[#parts+1] = view_label(e.view)
                end
            end
        end
    end
    if extra and extra ~= "" then parts[#parts+1] = extra end
    return parts
end

function Util.breadcrumb_parts(extra)
    return Util.parts_from_stack(_session_stack, extra)
end

local function breadcrumb(extra)
    local parts = {}
    for _, t in ipairs(Util.trail_history) do parts[#parts+1] = type(t) == "table" and t.label or t end
    parts[#parts+1] = table.concat(Util.breadcrumb_parts(extra), " > ")
    return table.concat(parts, "  " .. Util.markup('<span foreground="#a3a9bd">\u{F17B7}</span>') .. "  ")
end

-- ROFI

local main_pending    = false
local liked_pending = false
local jump_to_track_pending = false
local recent_pending = false
local view_actions, view_artist, view_lyrics, view_add_pl, view_art, view_volume
local view_seek
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
    local DIM = "#6a707f"
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
    os.execute("curl -s --max-time 3 -o /dev/null -w '%{http_code}' -X PUT "
        .. "'https://api.spotify.com/v1/me/player/repeat?state=" .. new_state .. "' -H "
        .. shell_quote("Authorization: Bearer " .. token) .. " -H 'Content-Length: 0'"
        .. " > /dev/null 2>&1 &")
end

toggle_shuffle = function()
    local token = get_token()
    is_shuffle = not is_shuffle
    _local_toggle_time = os.time()
    write_file(P.state, json.encode({repeat_state=repeat_state, shuffle=is_shuffle}))
    if not token then return end
    os.execute("curl -s --max-time 3 -o /dev/null -w '%{http_code}' -X PUT "
        .. "'https://api.spotify.com/v1/me/player/shuffle?state=" .. (is_shuffle and "true" or "false") .. "' -H "
        .. shell_quote("Authorization: Bearer " .. token) .. " -H 'Content-Length: 0'"
        .. " > /dev/null 2>&1 &")
end

local function rofi_dmenu(entries, opts)
    Util.back_pressed = false
    Util.alt_pressed = false
    if main_pending or liked_pending or recent_pending or Util.trail_jump_pending then return nil end
    opts = opts or {}
    local prompt   = opts.prompt or ""
    local mesg_fn  = opts.mesg
    local markup   = opts.markup
    local by_index = opts.by_index
    local theme    = opts.theme or (opts.thumbs and Util.THEME_THUMBS or (opts.use_menu and THEME_MENU or THEME))
    local eh       = opts.eh
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
    -- menu. Everything that happens *inside* it -- a shuffle/repeat toggle, a
    -- seek nudge, a nested view opened from a hotkey, an error message -- has to
    -- redraw this same menu instead, because every caller reads nil as "my menu
    -- exited" and unwinds (see view_browse's `elseif not idx then return`).
    -- Returning nil there closes the menu the user is still looking at, and the
    -- Util.scope around it then pops that menu's stack entry --
    -- which is how Alt+Return from an album list used to lose the album list.
    --
    -- Call as `if reenter(result) then goto menu_redo end return nil`: false
    -- means a deliberate global jump is in flight and the nil really does have
    -- to propagate all the way up.
    local function reenter(res)
        Util.back_pressed = false
        Util.alt_pressed = false
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
    -- Some themes (album/action) size their message box by counting literal
    -- "\n"s rather than actual wrapped visual lines, so a long name that
    -- auto-wraps eats the row reserved for the breadcrumb below it and the
    -- trail silently vanishes. Capping just the first line (the name) at a
    -- width that never wraps in the narrowest such theme sidesteps that for
    -- every caller, everywhere, without touching intentional multi-line
    -- content (progress bars, etc.) that comes after it.
    -- The trailing status icons are peeled off first and re-attached after the
    -- cut, so they are never what gets dropped: the budget buys title, and the
    -- liked/explicit/lyrics glyphs are always shown in full.
    if mesg then
        local nl = mesg:find("\n", 1, true)
        local first = nl and mesg:sub(1, nl - 1) or mesg
        local rest  = nl and mesg:sub(nl) or ""
        local body, icons = split_status_icons(first)
        mesg = truncate_text(body, MESG_NAME_MAX_CHARS) .. icons .. rest
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
    args[#args+1] = "-kb-custom-15"; args[#args+1] = "Delete"
    args[#args+1] = "-kb-custom-16"; args[#args+1] = "Alt+equal"
    args[#args+1] = "-kb-custom-17"; args[#args+1] = "Alt+minus"
    args[#args+1] = "-kb-custom-18"; args[#args+1] = "Shift+Return"
    args[#args+1] = "-kb-remove-char-forward"; args[#args+1] = "Control+d"
    if opts.custom == false then args[#args+1] = "-no-custom" end
    if markup then args[#args+1] = "-markup-rows"; args[#args+1] = "-markup" end
    if by_index then args[#args+1] = "-format"; args[#args+1] = "i" end
    if eh then args[#args+1] = "-eh"; args[#args+1] = tostring(eh) end
    if opts.thumbs then
        local n = #(entries or {})
        local rows = math.ceil(n / 5)
        if rows > 3 then rows = 3 end
        if rows < 1 then rows = 1 end
        args[#args+1] = "-l"; args[#args+1] = tostring(rows)
    end
    if sel and sel > 0 then args[#args+1] = "-selected-row"; args[#args+1] = tostring(sel) end
    if not opts.no_status and not opts.thumbs then
        local status = status_mesg()
        if status then mesg = mesg and (status .. "  " .. mesg) or status end
    end
    local crumb = breadcrumb(opts.crumb)
    if crumb then
        if markup then crumb = Util.markup('<span foreground="#6a707f">') .. crumb .. Util.markup('</span>') end
        mesg = (mesg and (mesg .. "\n") or "") .. crumb
    end
    if mesg then args[#args+1] = "-mesg"; args[#args+1] = Util.pango_escape(mesg) end

    local entry_tf = os.tmpname()
    local f = io.open(entry_tf, "w")
    if not f then os.remove(entry_tf); return nil end
    for _, e in ipairs(entries or {}) do f:write(markup and Util.pango_escape(e) or e, "\n") end
    f:close()

    local bs = Util.bs_launch(theme)

    local qa = {}
    for _, a in ipairs(args) do qa[#qa+1] = shell_quote(a) end
    local out_tf = os.tmpname()
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
    if exit_code == EXIT.clear_trail then Util.clear_trail(); main_pending = true; return nil end
    if exit_code == EXIT.liked then
        if not Util.jump_preserve_stack and #_session_stack > 0 then
            Util.jump_preserve_stack = json.decode(json.encode(_session_stack))
        end
        liked_pending = true; return nil end
    if exit_code == EXIT.trail_jump then
        Util.trail_jump_stack = _session_stack and json.decode(json.encode(_session_stack)) or {}
        Util.trail_jump_pending = true
        return nil
    end
    if exit_code == EXIT.track then jump_to_track_pending = true; return nil end
    if exit_code == EXIT.alt_action then
        -- Menus that opt in handle Shift+Return themselves: hand the highlighted
        -- row back exactly as an ordinary accept would and flag which key ended
        -- the menu, the way Util.back_pressed already reports Backspace. A flag
        -- rather than a callback because the caller's handling can need `goto`
        -- or an early `return` inside its own loop (Saved Albums drops the row
        -- after Remove from Library), which a callback running here cannot do.
        -- The caller MUST read Util.alt_pressed immediately: the next rofi_dmenu,
        -- nested or not, clears it.
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
    -- Alt+a and Alt+y below deliberately do NOT re-enter view_actions after the
    -- nested view returns. They used to, back when rofi_dmenu closed the menu
    -- underneath instead of redrawing it. Now `reenter -> goto menu_redo` puts
    -- the very same action menu back up with rebuild_actions re-run, so calling
    -- view_actions again just stacked a SECOND {view="action"} scope entry for
    -- the same track -- and parts_from_stack renders a repeated crumb name as
    -- the generic view label, so every press appended another "Track" to the
    -- breadcrumb and the trail.
    if exit_code == EXIT.art then
        if not Util.fast_now_track() then last_playback = 0; get_playback() end
        local target = opts.current or current_track
        if target then
            view_art(target)
        else rofi_message("No track playing") end
        if reenter(result) then goto menu_redo end
        return nil
    elseif exit_code == EXIT.recent then
        if not Util.jump_preserve_stack and #_session_stack > 0 then
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

-- Backspace here has to close THIS window and nothing else. spbsd turns a
-- Backspace-on-empty-filter into Control+Shift+Delete, and a window that does
-- not bind that combo does not swallow it -- it lands on whatever takes focus
-- next, which is the menu this message was opened from, and that menu reads it
-- as "back". That is why backing out of Track Details used to skip the action
-- menu and drop you on the list behind it. Binding the combo here (and bumping
-- bsmon's generation so its shadow filter and one-shot latch reset for this
-- window) keeps the press local, exactly like every rofi_dmenu menu.
rofi_message = function(msg, theme)
    local tf = os.tmpname()
    theme = theme or THEME_MSG
    Util.bs_launch(theme)
    os.execute("rofi -e " .. shell_quote(Util.pango_escape(msg)) .. " -config " .. shell_quote(P.dir.."/style/config.rasi") .. " -theme " .. shell_quote(theme) .. " -kb-custom-1 'Control+Shift+Delete' -markup 2>/dev/null; printf '\\n__EXIT__%d__' $? >> " .. shell_quote(tf))
    local raw = read_file(tf)
    os.remove(tf)
    local ec = tonumber((raw or ""):match("__EXIT__(%d+)__")) or 1
    return ec == 0
end

local function rofi_input(prompt, preset, theme)
    local in_tf  = os.tmpname()
    local out_tf = os.tmpname()
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
    local scopes = "app-remote-control playlist-modify playlist-modify-private playlist-modify-public"
        .. " playlist-read playlist-read-collaborative playlist-read-private streaming"
        .. " user-follow-modify user-follow-read user-library-modify user-library-read"
        .. " user-top-read"
        .. " user-modify-playback-state user-read-currently-playing user-read-playback-state"
        .. " user-read-private"
        .. " user-read-playback-position"
    local auth_url = "https://accounts.spotify.com/authorize"
        .. "?client_id=" .. P.spotify
        .. "&response_type=code"
        .. "&redirect_uri=http://127.0.0.1:8989/login"
        .. "&code_challenge_method=S256"
        .. "&code_challenge=" .. challenge
        .. "&scope=" .. scopes:gsub("%s+", "+")

    local srv = "perl -MIO::Socket::INET -e '"
        .. "alarm 120;"
        .. "$s=IO::Socket::INET->new(LocalPort=>8989,Listen=>1,ReuseAddr=>1);"
        .. "$c=$s->accept();$r=<$c>;($x)=$r=~/code=([^&\\s]+)/;"
        .. "if($x){open(F,\">\",\"/tmp/spoot_code\");print F $x;close(F)}"
        .. "print $c \"HTTP/1.1 200 OK\\r\\n\\r\\nok\";close $c;close $s'"
    os.execute(srv .. " & echo $! > /tmp/spoot_oauth_pid")
    os.execute("xdg-open " .. shell_quote(auth_url) .. " 2>/dev/null &")

    local function kill_oauth_server()
        local pid = trim(read_file("/tmp/spoot_oauth_pid") or "")
        if pid ~= "" and pid:match("^%d+$") then os.execute("kill " .. pid .. " 2>/dev/null") end
        os.remove("/tmp/spoot_oauth_pid")
    end

    local attempts = 0
    while true do
        local code = trim(read_file("/tmp/spoot_code") or "")
        if #code > 0 then
            os.remove("/tmp/spoot_code")
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
                }))
                os.execute("chmod 600 " .. shell_quote(P.token) .. " 2>/dev/null")
                return d.access_token
            end
            return nil
        end
        attempts = attempts + 1
        if attempts >= 120 then
            kill_oauth_server()
            os.remove("/tmp/spoot_code")
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

-- NOTIFY

local function artist_names(item)
    local a = {}
    for _, v in ipairs(item.artists or {}) do if v.name then a[#a+1] = v.name end end
    return table.concat(a, ", ")
end

local function album_suffix(item)
    local an = artist_names(item)
    if an == "" then return "" end
    return SEP .. an
end

Util.art_url = function(art_url, seed)
    if not art_url or #art_url == 0 then return art_url end
    local s = seed or "82c1"
    return (art_url:gsub("(i%.scdn%.co/image/ab67616d0000)[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]", "%1" .. s))
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

Util._art_valid_file = function(path, content_length)
    local fh = io.open(path, "rb")
    if not fh then return false end
    local head = fh:read(3)
    local st = fh:seek("end")
    local tail = nil
    if st and st >= 2 then
        fh:seek("end", -2)
        tail = fh:read(2)
    end
    fh:close()
    if not st or st <= 0 then return false end
    if content_length and st ~= content_length then return false end
    if not head or #head < 3 then return false end
    if head:byte(1) ~= 0xFF or head:byte(2) ~= 0xD8 or head:byte(3) ~= 0xFF then return false end
    if not tail or #tail < 2 then return false end
    return tail:byte(1) == 0xFF and tail:byte(2) == 0xD9
end

Util.fetch_art = function(url, art_path, opts)
    opts = opts or {}
    local attempts = opts.attempts or 3
    local connect_timeout = opts.connect_timeout or 5
    local timeout = opts.timeout or 10
    for attempt = 1, attempts do
        local tmp = art_path .. ".tmp" .. Util._rand_suffix()
        local hdr = tmp .. ".hdr"
        local cmd = string.format("curl -sf --connect-timeout %d --max-time %d -D %s -o %s %s 2>/dev/null",
            connect_timeout, timeout, shell_quote(hdr), shell_quote(tmp), shell_quote(url))
        shell(cmd)
        local cl = Util._art_content_length(hdr)
        os.remove(hdr)
        if Util._art_valid_file(tmp, cl) then
            if os.rename(tmp, art_path) then return art_path end
        end
        os.remove(tmp)
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

-- ONE curl process per pass rather than one per image. -Z multiplexes every
-- transfer over a handful of HTTP/2 connections to i.scdn.co: measured on 40
-- covers, 0.54s / 0.08s CPU versus 1.45s / 1.14s for the 8-at-a-time fork loop
-- this replaces. The old cost was process spawn and cold TCP+TLS, not a lack of
-- concurrency -- which is why --parallel-max 16 is no slower than 32 or 64.
--
-- Validation moved off response headers: `dump-header` in a -K config is a
-- GLOBAL, last-one-wins option, so every response's headers land concatenated in
-- one file with nothing tying them to a transfer. --write-out is per transfer
-- and carries more: status plus the byte count curl actually wrote, keyed by
-- output path. No .hdr files are created at all now.
Util._art_batch = function(items)
    local todo = items
    for pass = 1, 3 do
        if #todo == 0 then break end
        local cfg = os.tmpname()
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
        local failures = {}
        for _, pd in ipairs(todo) do
            local r = got[pd.tmp]
            local ok = r ~= nil and r.code:match("2..") ~= nil
            if ok then ok = Util._art_valid_file(pd.tmp, r.size) end
            if ok then ok = os.rename(pd.tmp, pd.path) end
            if not ok then failures[#failures+1] = pd end
            os.remove(pd.tmp)
            pd.tmp = nil
        end
        todo = failures
        if #todo > 0 and pass < 3 then os.execute("sleep 1") end
    end
end

-- Hands the tail of a thumbnail grid to a detached copy of ourselves so the menu
-- can draw now and the rest of the covers are warm by the next visit. Routed
-- through spoot.lua rather than a backgrounded bare curl so the tail gets the
-- same status + byte-count + JPEG validation and atomic rename as the sync path;
-- a prefetch killed mid-flight can then never leave a truncated file sitting at
-- a final art path, where every later run would trust it.
function Util.spawn_art_prefetch(list)
    if not list or #list == 0 then return end
    -- album_thumbs re-derives its pending list from disk on every call, so each
    -- redraw during a download would otherwise spawn a second prefetcher for
    -- whatever is still missing. Same kill -0 liveness idiom as ensure_daemon.
    local pidf = "/tmp/spoot_art_prefetch.pid"
    local prev = trim(read_file(pidf) or "")
    if prev:match("^%d+$")
       and trim(shell("kill -0 " .. prev .. " 2>/dev/null && echo alive") or "") == "alive" then
        return
    end
    local lf = os.tmpname()
    local f = io.open(lf, "w")
    if not f then os.remove(lf); return end
    for _, pd in ipairs(list) do f:write(pd.url, "\t", pd.path, "\n") end
    f:close()
    os.execute("nohup lua " .. shell_quote(P.dir .. "/spoot.lua")
        .. " --prefetch-art-batch " .. shell_quote(lf) .. " > /dev/null 2>&1 &"
        .. " echo $! > " .. shell_quote(pidf))
end

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

Util.write_art_theme = function(name, art_path)
    local tmpl = Util._art_theme_tmpls[name]
    if not tmpl then
        local raw = read_file(P.dir .. "/style/" .. name .. ".rasi") or ""
        tmpl = raw:gsub('@import "ZENON"', '@import "' .. P.dir .. '/style/ZENON"')
        Util._art_theme_tmpls[name] = tmpl
    end
    local tmp = "/tmp/spoot_theme_" .. name .. ".rasi"
    local rasi = tmpl:gsub("%%s", art_path or "")
    if not art_path or art_path == "" then
        rasi = rasi:gsub("background%-image:%s*url%(\"\",%s*both%);", "")
    end
    local f = io.open(tmp, "w")
    if f then f:write(rasi); f:close() end
    return tmp
end

-- Album-list thumbnails: reuse the shared 300px art cache (seed "1e02") so the
-- grid needs no extra network source. Fetches the first THUMB_SYNC missing
-- covers before returning, hands the rest to a detached prefetch, then appends
-- "\0icon\x1f<path>" to EVERY row that has a path -- see the note on the
-- decoration loop for why a path that does not exist yet is still emitted.
--
-- Three states a tile can be in, which used to be one indistinguishable black
-- square:
--   * cover not fetched YET -- no file, but the path is emitted anyway so rofi
--     loads it when you scroll the row into view, and F5 catches the rest.
--   * fetch FAILED -- Util._art_batch retried it 3 passes; a cover stays in the
--     pending set until a stat actually finds it on disk, and that set is
--     re-statted on every call (view_browse's `rebuild` included), so the next
--     redraw or visit tries again.
--   * album has NO artwork at all -- nothing will ever be fetched, so the row is
--     pointed at style/noart.png instead of being left iconless forever.
--
-- The url -> path resolution never changes for a given list, but this runs again
-- on every redraw (view_browse's `rebuild`, the F5 handler, browse_artist_albums'
-- loop), and it used to re-derive and re-stat all of it every time: on a ~1500
-- album discography that is 1500 gsubs plus 1500 open/seek/close triples per
-- keypress. The resolution is memoised per list and only the covers still MISSING
-- are re-statted, which is what preserves the retry-on-next-redraw behaviour
-- described above -- an entry leaves `missing` only when a stat actually finds it.
Util._thumb_memo = nil
Util.album_thumbs = function(entries, items)
    items = items or {}
    local n = #items
    -- Keyed on identity AND shape: Saved Albums' "Remove from Library" mutates
    -- this very table in place, and a memo keyed on identity alone would then
    -- hand every row below the removal the previous row's cover.
    local memo = Util._thumb_memo
    if not (memo and memo.items == items and memo.n == n
            and memo.first == items[1] and memo.last == items[n]) then
        memo = {items = items, n = n, first = items[1], last = items[n],
                paths = {}, urls = {}, missing = {}}
        for i, it in ipairs(items) do
            local imgs = it.images or (it.album and it.album.images) or {}
            local url = imgs[1] and imgs[1].url
            local hash
            if url and #url > 0 then
                url = Util.art_url(url, "1e02")
                hash = url:match("/image/([%w]+)") or url:match("/([%w_%-]+)$")
            end
            if hash then
                memo.paths[i] = P.art .. "/" .. hash .. ".jpg"
                memo.urls[i]  = url
                -- Kept as an ASCENDING array, not a set: the stat pass below
                -- feeds THUMB_SYNC in this order, and the covers that must be
                -- fetched before the menu draws are the ones at the top of the
                -- list. A pairs() walk would hand it 60 covers at random.
                memo.missing[#memo.missing + 1] = i
            else
                -- No usable art URL: deliberately NOT marked missing, there is
                -- nothing to fetch. The placeholder ships with the themes, so it
                -- is always present and costs no network.
                memo.paths[i] = P.dir .. "/style/noart.png"
            end
        end
        Util._thumb_memo = memo
    end
    local paths = memo.paths
    local pending, still = {}, {}
    for _, i in ipairs(memo.missing) do
        local p = paths[i]
        local fh = io.open(p, "r")
        local ok = false
        if fh then
            local sz = fh:seek("end")
            fh:close()
            ok = sz and sz > 0
        end
        if not ok then
            still[#still+1] = i
            pending[#pending+1] = { url = memo.urls[i], path = p }
        end
    end
    memo.missing = still
    if #pending > 0 then
        ensure_cache()
        local head, tail = {}, {}
        for i, pd in ipairs(pending) do
            if i <= THUMB_SYNC then head[#head+1] = pd else tail[#tail+1] = pd end
        end
        Util._art_batch(head)
        if #tail > 0 then Util.spawn_art_prefetch(tail) end
    end
    -- Emitted even when the file is not there YET, which looks wrong but is
    -- deliberate: rofi queries an icon only when it first RENDERS that row
    -- (measured -- of 200 rows whose icons all existed, rofi opened 3), so a row
    -- below the fold is looked up when you scroll to it, by which time the
    -- prefetch has usually written it. A row that IS on screen while its file is
    -- still missing is the case this cannot help: rofi caches that miss for the
    -- life of the menu and never re-reads the path, even once the file appears.
    -- F5 redraws to pick those up.
    for i, e in ipairs(entries or {}) do
        local p = paths[i]
        if p and not e:find("\0icon", 1, true) then
            entries[i] = e .. "\0icon\x1f" .. p
        end
    end
end

-- SPOTIFYD MANAGEMENT

P.device_ttl = 600

-- Forget the cached device so the next play re-resolves it. Called when the
-- daemons are restarted or when Spotify rejects the device we had.
function Util.bust_device()
    mem_bust("spotifyd_device"); mem_bust("spotifyd_device_vol")
    disk_bust(P.device)
end

-- The device id used to live in mem_* only, which dies with the process, so the
-- first play of EVERY launch paid a ~300ms /me/player/devices round trip. Backed
-- by disk with a TTL it survives launches; bust_device covers the cases where it
-- could go stale.
local function get_spotifyd_device()
    local cached = mem_get("spotifyd_device")
    if cached then return cached end
    local saved = disk_get(P.device, P.device_ttl)
    if type(saved) == "table" and saved.id then
        mem_set("spotifyd_device", saved.id, P.device_ttl)
        mem_set("spotifyd_device_vol", saved.vol, P.device_ttl)
        return saved.id
    end
    local token = get_token()
    if not token then return nil end
    local d = safe_decode(shell("curl -s --max-time 3 -H " .. shell_quote("Authorization: Bearer " .. token) .. " 'https://api.spotify.com/v1/me/player/devices'"))
    if not d or not d.devices then return nil end
    local dev_id, dev_supports_vol = nil, false
    for _, dev in ipairs(d.devices) do
        if dev.name and dev.name:lower():find("spoot") then dev_id = dev.id; dev_supports_vol = dev.supports_volume; break end
    end
    if not dev_id then
        for _, dev in ipairs(d.devices) do
            if dev.is_active then dev_id = dev.id; dev_supports_vol = dev.supports_volume; break end
        end
    end
    if not dev_id and #d.devices > 0 then dev_id = d.devices[1].id; dev_supports_vol = d.devices[1].supports_volume end
    if dev_id then
        mem_set("spotifyd_device", dev_id, P.device_ttl)
        mem_set("spotifyd_device_vol", dev_supports_vol, P.device_ttl)
        disk_set(P.device, {id = dev_id, vol = dev_supports_vol})
    end
    return dev_id
end

local SPOTIFYD_CREDS = P.home .. "/.cache/spotifyd/oauth/credentials.json"

local function ensure_spotifyd_auth()
    local f = io.open(SPOTIFYD_CREDS); if f then f:close(); return end
    os.execute("notify-send --app-name=spoot -t 8000 'Spotifyd OAuth needed' 'Run: spotifyd authenticate' &")
    os.execute("spotifyd authenticate >/dev/null 2>&1 &")
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
    -- One header file per PROCESS, not per request. os.tmpname() mkstemps and
    -- unlinks a real file on every single call, and the contents are read only on
    -- a 429 -- a paginated browse (a 1500-album discography is ~30 pages) paid for
    -- 30 of them. curl truncates the file on each write, so no request can read a
    -- previous one's headers. The pid is in the name because the detached helpers
    -- (--notify, --recent-watch) run api_get concurrently with this process.
    local hdr = Util.api_hdr_path()
    local r = shell("curl -s --max-time 10 -D " .. shell_quote(hdr) .. " -w '\\n%{http_code}' -H " .. shell_quote("Authorization: Bearer " .. token) .. " " .. shell_quote(url))
    local status = tonumber(string.match(r or "", "\n(%d+)\n?$")) or 0
    local body = string.match(r or "", "^(.-)\n%d+\n?$") or r or ""
    if status == 429 then
        local hf = io.open(hdr, "r")
        local headers = hf and hf:read("*a") or ""
        if hf then hf:close() end
        local secs = string.match(headers, "[Rr]etry%-[Aa]fter:%s*(%d+)") or "30"
        local cool = tonumber((read_file("/tmp/spoot_rate_cooldown") or ""):match("%d+"))
        if not Util.detached then
            Util.secure_write("/tmp/spoot_rate_cooldown", os.time() + math.min(tonumber(secs), 5) + 5)
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
    return safe_decode(body)
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

local function load_saved_albums()
    local cached = mem_get("saved_albums")
    if cached then return cached, true end
    local c = safe_decode(read_file(P.albums))
    if c and c.items and type(c.items) == "table" then
        if type(c.fetched_at) ~= "number" or os.time() - c.fetched_at < P.ttl then
            mem_set("saved_albums", c.items, P.ttl)
            return c.items, true
        end
    end
    local items = {}
    local offset = 0
    while true do
        local d = api_get("me/albums", Util.with_market("limit=50&offset=" .. offset))
        if not d or not d.items then return (c and c.items) or {}, false end
        if #d.items == 0 then break end
        for _, e in ipairs(d.items) do
            if e.album then items[#items+1] = e.album end
        end
        if #d.items < 50 then break end
        offset = offset + 50
    end
    table.sort(items, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    Util.mark_availability(items)
    write_file(P.albums, json.encode({fetched_at=os.time(), items=items}))
    mem_set("saved_albums", items, P.ttl)
    return items, true
end

local function load_followed_artists()
    local cached = mem_get("followed_artists")
    if cached then return cached, true end
    local c = safe_decode(read_file(P.artists))
    if c and c.items and type(c.items) == "table" then
        if type(c.fetched_at) ~= "number" or os.time() - c.fetched_at < P.ttl then
            mem_set("followed_artists", c.items, P.ttl)
            return c.items, true
        end
    end
    local items = {}
    local after = nil
    while true do
        local p = "type=artist&limit=50"
        if after then p = p .. "&after=" .. after end
        local d = api_get("me/following", p)
        if not d or not d.artists or not d.artists.items then return (c and c.items) or {}, false end
        if #d.artists.items == 0 then break end
        for _, a in ipairs(d.artists.items) do items[#items+1] = a end
        if not d.artists.next then break end
        after = d.artists.cursors and d.artists.cursors.after
    end
    table.sort(items, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    write_file(P.artists, json.encode({fetched_at=os.time(), items=items}))
    mem_set("followed_artists", items, P.ttl)
    return items, true
end

local function fetch_library_with_fallback()
    local tracks, albums, artists = parallel_fetch_library()
    local from_cache = {}
    local failed = {}
    if not tracks then
        tracks = load_liked_tracks_full()
        if tracks then from_cache[#from_cache+1] = "tracks" else failed[#failed+1] = "tracks" end
    end
    if not albums then
        local a, ok = load_saved_albums()
        albums = ok and a or nil
        if albums then from_cache[#from_cache+1] = "albums" else failed[#failed+1] = "albums" end
    end
    if not artists then
        local a, ok = load_followed_artists()
        artists = ok and a or nil
        if artists then from_cache[#from_cache+1] = "artists" else failed[#failed+1] = "artists" end
    end
    return tracks, albums, artists, from_cache, failed
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

-- These write straight to disk instead of going through cached_fetch, so they
-- need the availability collapse applied here too -- liked_tracks.json alone is
-- 44% available_markets.
local function save_library_cache(tracks, albums, artists)
    if tracks then
        Util.mark_availability(tracks)
        mem_set("liked_tracks", tracks, P.ttl)
        build_liked_artist_index(tracks)
        write_file(P.liked, json.encode({fetched_at=os.time(), tracks=tracks}))
        local ids = {}
        for _, t in ipairs(tracks) do if t.id then ids[#ids+1] = t.id end end
        write_file(P.liked_ids, json.encode(ids))
    end
    if albums then
        Util.mark_availability(albums)
        mem_set("saved_albums", albums, P.ttl)
        write_file(P.albums, json.encode({fetched_at=os.time(), items=albums}))
    end
    if artists then
        mem_set("followed_artists", artists, P.ttl)
        write_file(P.artists, json.encode({fetched_at=os.time(), items=artists}))
    end
end

local function load_liked_tracks()
    local cached = mem_get("liked_tracks")
    if cached then
        if not liked_by_artist_id then build_liked_artist_index(cached) end
        return cached
    end
    local c = safe_decode(read_file(P.liked))
    if c and c.tracks and type(c.tracks) == "table" then
        if type(c.fetched_at) ~= "number" or os.time() - c.fetched_at < P.ttl then
            mem_set("liked_tracks", c.tracks, P.ttl)
            build_liked_artist_index(c.tracks)
            return c.tracks
        end
    end
    local tracks = load_liked_tracks_full()
    if not tracks then
        tracks = (c and c.tracks and type(c.tracks) == "table") and c.tracks or {}
        mem_set("liked_tracks", tracks, P.ttl)
        build_liked_artist_index(tracks)
        return tracks
    end
    Util.mark_availability(tracks)
    write_file(P.liked, json.encode({fetched_at=os.time(), tracks=tracks}))
    local ids = {}
    for _, t in ipairs(tracks) do if t.id then ids[#ids+1] = t.id end end
    write_file(P.liked_ids, json.encode(ids))
    mem_set("liked_tracks", tracks, P.ttl)
    build_liked_artist_index(tracks)
    return tracks
end

-- PLAYBACK STATE

local inv_playback  -- forward declaration

get_playback = function()
    if os.time() - last_playback < 5 then return end
    -- me/player takes a market too, so the now-playing item arrives carrying
    -- is_playable. Converted (and stripped) here rather than left raw, so
    -- now_track.json never persists the field and anything downstream that reads
    -- current_track -- record_recent_play included -- sees the same shape every
    -- other track source produces.
    local d = api_get("me/player", Util.with_market())
    last_playback = os.time()
    if d and d.item then Util.mark_availability(d.item) end
    if not d or not d.item then
        local cool = tonumber((read_file("/tmp/spoot_rate_cooldown") or ""):match("%d+"))
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
    current_track = nil; current_id = nil; is_playing = false
end

function Util.fast_now_track()
    local now  = safe_decode(read_file(P.now))
    local rich = safe_decode(read_file(P.now_track))
    if not (now and now.id and rich and rich.item and rich.item.id == now.id) then return false end
    current_track = rich.item
    current_id    = rich.item.id
    -- Ask the player, not the cache. now.json's `playing` is sampled once per
    -- track (the daemon's process_snap early-returns on pause/resume, because
    -- those MPRIS events carry unchanged metadata) so it goes stale the moment
    -- you pause, and now_track.json may not carry the field at all. playerctl
    -- status is a local D-Bus round trip with no network in it, and it is the
    -- only source that is right every time. The cached fields stay as fallback
    -- for when playerctl is unavailable.
    local st = trim(shell("playerctl status 2>/dev/null") or "")
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
    end
end

-- RECENTLY PLAYED
--
-- Write-through on every record so the always-on --recent-watch process and
-- interactive sessions can each read-modify-write the file safely.

local recent_tracks = disk_get(P.recent) or {}

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
    -- Tracks arrive here straight off me/player, not through cached_fetch, so the
    -- availability collapse has to be applied by hand. Only the NEW track can
    -- still be carrying available_markets -- every other entry was collapsed when
    -- it was inserted -- so this no longer re-walks all 100 on every play.
    Util.mark_availability(track)
    table.insert(recent_tracks, 1, track)
    while #recent_tracks > 100 do
        table.remove(recent_tracks)
    end
    disk_set(P.recent, recent_tracks)
end

-- DISPLAY HELPERS

display_track = function(item, hide_artist, hide_liked, hide_single_artist)
    local hide = hide_artist or (hide_single_artist and #(item.artists or {}) <= 1)
    local an = hide and "" or artist_names(item)
    local p  = item.id == current_id and (is_playing and "\u{f04b} " or "\u{f04c} ") or ""
    local l  = (not hide_liked) and item.id and liked[item.id] and "\u{f05d} " or ""
    local e  = item.explicit and "\u{f071} " or ""
    local txt = p .. l .. e .. (item.name or "Unknown") .. (hide and "" or SEP .. an)
    if item.id == current_id then txt = Util.markup('<span foreground="#b6e0a4">') .. txt .. Util.markup('</span>')
    elseif item.unavail then
        -- Not licensed in our market, so it will not play. Same dim as the
        -- disabled action rows. Never applied to the current track: if it IS
        -- playing, whatever the cache says, green wins.
        txt = Util.markup('<span color="#6a707f">') .. txt .. Util.markup('</span>')
    end
    return txt
end

local function display_album(item, show_artist)
    if not show_artist and #(item.artists or {}) <= 1 then return item.name or "Unknown" end
    return (item.name or "Unknown") .. album_suffix(item)
end

local function display_artist(item)
    return item.name or "Unknown"
end

local function display_playlist(item)
    local prefix = (item.owner and item.owner.id == "spotify") and "\u{f1bc}  " or ""
    return prefix .. (item.name or "Unknown")
end

function Util.format_mixed_item(t, i)
    local st = t._stype or "track"
    local pfx = ICON_PREFIX[st] or ""
    local body
    if st == "tracks" then body = display_track(t)
    elseif st == "albums" then body = display_album(t, true)
    elseif st == "artists" then body = display_artist(t)
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

local function get_playerctl_volume()
    local cached = mem_get("_playerctl_vol")
    if cached ~= nil then return cached end
    local raw = shell("playerctl volume 2>/dev/null")
    local v = tonumber(trim(raw or ""))
    if v and v >= 0 then v = math.min(math.floor(v * 100 + 0.5), 100) else v = get_saved_volume() end
    mem_set("_playerctl_vol", v, 1)
    return v
end

function Util.has_synced_lyrics(id)
    if not id then return false end
    local d = disk_get(P.lyrics .. "/lyrics_" .. id .. ".json")
    return type(d) == "table" and type(d.times) == "table" and #d.times > 0
end

function Util.has_lyrics(id)
    if not id then return false end
    local d = disk_get(P.lyrics .. "/lyrics_" .. id .. ".json")
    return type(d) == "table" and type(d.lines) == "table" and #d.lines > 0
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

local function track_mesg(item)
    local p = item.id == current_id and (is_playing and "\u{f04b} " or "\u{f04c} ") or ""
    return (p ~= "" and (p .. " ") or "") .. (item.name or "") .. SEP .. artist_names(item)
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
            local clean = {}
            for _, t in ipairs(d.tracks) do if type(t) == "table" then clean[#clean+1] = t end end
            queue_tracks = clean
        else
            queue_tracks = {}
        end
        queue_idx = type(d.idx) == "number" and d.idx or 0
        if queue_idx < 0 or queue_idx > #queue_tracks then queue_idx = 0 end
        queue_context = type(d.context) == "string" and d.context or nil
    end
end

local function save_queue(items, idx, context_uri)
    local tids = {}
    for _, t in ipairs(items or {}) do
        if type(t) == "table" and t.id then tids[#tids+1] = t.id end
    end
    queue_tracks  = tids
    queue_idx     = idx
    queue_context = context_uri
    write_file(P.queue, json.encode({tracks=tids, idx=idx, context=context_uri}))
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

    if all_items and idx then save_queue(all_items, idx, context_uri) end
    local token = get_token()
    if not token then return false end
    local device_id = get_spotifyd_device()
    local dparam = device_id and "?device_id=" .. device_id or ""

    local body
    if context_uri then
        body = json.encode({context_uri=context_uri, offset={position=(idx or 1)-1}})
    elseif all_items and idx then
        local uris = {}
        for i = idx, math.min(#all_items, idx + 49) do
            if all_items[i] and all_items[i].id then uris[#uris+1] = "spotify:track:" .. all_items[i].id end
        end
        if #uris > 0 then body = json.encode({uris=uris, offset={position=0}}) end
    else
        body = json.encode({uris={"spotify:track:" .. item.id}})
    end
    if body then
        local code = shell(string.format("curl -s --max-time 3 -o /dev/null -w '%%{http_code}' -X PUT %s -H %s -H 'Content-Type: application/json' -d %s", shell_quote("https://api.spotify.com/v1/me/player/play" .. dparam), shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
        -- 404 = "Device not found": the persisted id went stale, so drop it and
        -- retry once against a freshly resolved device.
        if code and code:match("404") and device_id then
            Util.bust_device()
            local fresh = get_spotifyd_device()
            if fresh and fresh ~= device_id then
                shell(string.format("curl -s --max-time 3 -o /dev/null -w '%%{http_code}' -X PUT %s -H %s -H 'Content-Type: application/json' -d %s", shell_quote("https://api.spotify.com/v1/me/player/play?device_id=" .. fresh), shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
            end
        end
        P.recent_cmd_at = os.time()
        return true
    end
    return false
end

local _liked_dirty = false

local function flush_liked_cache()
    if not _liked_dirty then return end
    local tracks = mem_get("liked_tracks")
    if not tracks then
        local c = safe_decode(read_file(P.liked))
        tracks = (c and c.tracks and type(c.tracks) == "table") and c.tracks or {}
    end
    local id_set = {}
    for _, t in ipairs(tracks) do if t.id then id_set[t.id] = true end end
    local new_ids = {}
    for id, v in pairs(liked) do
        if v and not id_set[id] then
            new_ids[#new_ids + 1] = id
        elseif not v and id_set[id] then
            for i = #tracks, 1, -1 do
                if tracks[i].id == id then table.remove(tracks, i); break end
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
        end
        if not ok then
            _liked_dirty = true
            return
        end
    end
    _liked_dirty = false
    write_file(P.liked, json.encode({fetched_at=os.time(), tracks=tracks}))
    local ids = {}
    for _, t in ipairs(tracks) do if t.id then ids[#ids+1] = t.id end end
    write_file(P.liked_ids, json.encode(ids))
    build_liked_artist_index(tracks)
    bust_format_cache()
end

function Util.persist_liked(tracks)
    tracks = tracks or {}
    write_file(P.liked, json.encode({fetched_at=os.time(), tracks=tracks}))
    local ids = {}
    for _, t in ipairs(tracks) do if t.id then ids[#ids+1] = t.id end end
    write_file(P.liked_ids, json.encode(ids))
end

function Util.optimistic_like(item, unlike)
    if not (item and item.id) then return nil end
    local tracks = mem_get("liked_tracks")
    if not tracks then
        local c = safe_decode(read_file(P.liked))
        tracks = (c and c.tracks and type(c.tracks) == "table") and c.tracks or {}
    end
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

function Util.clean_exit()
    Util.bs_stop()
    flush_liked_cache()
    if Util._api_hdr then os.remove(Util._api_hdr) end
    os.remove("/tmp/spoot_instance.lock")
    os.remove(P.cache .. "/action_theme.rasi")
    os.execute("rm -f /tmp/spoot_theme_*.rasi 2>/dev/null")
    os.exit(0)
end

local function do_like(item, unlike)
    local token = get_token()
    if not token then rofi_message("Cannot like: no token"); return false end
    local verb = unlike and "DELETE" or "PUT"
    local url = "https://api.spotify.com/v1/me/tracks?ids=" .. item.id
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -o /dev/null -X %s %s -H %s", verb, shell_quote(url), shell_quote("Authorization: Bearer " .. token)))
    if not r or not r:match("2..") then
        rofi_message(unlike and "Failed to unlike" or "Failed to like")
        return false
    end
    if unlike then liked[item.id] = false else liked[item.id] = true end
    Util.persist_liked(Util.optimistic_like(item, unlike))
    _liked_dirty = true
    bust_format_cache()
    return true
end

local function api_check_following(artist_id)
    local token = get_token()
    if not token then return false end
    local r = api_get("me/following/contains?type=artist&ids=" .. artist_id)
    return r and r[1] == true
end

local function do_follow_artist(artist_id, follow)
    local token = get_token()
    if not token then return false end
    local verb = follow and "PUT" or "DELETE"
    local url = "https://api.spotify.com/v1/me/following?type=artist&ids=" .. artist_id
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -o /dev/null -X %s %s -H %s -H 'Content-Length: 0'", verb, shell_quote(url), shell_quote("Authorization: Bearer " .. token)))
    if r and r:match("2..") then
        mem_bust("followed_artists")
        os.remove(P.artists)
        return true
    end
    return false
end

local function do_add_queue(track_id)
    local token = get_token()
    if not token then rofi_message("Cannot add to queue: no token"); return end
    local url = "https://api.spotify.com/v1/me/player/queue?uri=spotify:track:" .. track_id
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X POST %s -H %s -o /dev/null", shell_quote(url), shell_quote("Authorization: Bearer " .. token)))
    if not r or not r:match("2..") then rofi_message("Failed to add to queue"); return end
    mem_bust("queue")
    -- also add to local queue tracking
    if not queue_tracks then queue_tracks = {}; queue_idx = 0 end
    queue_tracks[#queue_tracks+1] = track_id
    flush_queue()
end

local function do_save_album(album_id)
    local token = get_token()
    if not token then rofi_message("Cannot save album: no token"); return false end
    local url = "https://api.spotify.com/v1/me/albums?ids=" .. album_id
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X PUT %s -H %s -o /dev/null", shell_quote(url), shell_quote("Authorization: Bearer " .. token)))
    if r and r:match("2..") then
        mem_bust("saved_albums")
        disk_bust(P.albums)
        return true
    end
    return false
end

local function do_save_playlist(playlist_id)
    local token = get_token()
    if not token then rofi_message("Cannot save playlist: no token"); return false end
    local url = "https://api.spotify.com/v1/playlists/" .. playlist_id .. "/followers"
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X PUT %s -H %s -H 'Content-Length: 0' -o /dev/null", shell_quote(url), shell_quote("Authorization: Bearer " .. token)))
    if r and r:match("2..") then
        bust_my_playlists()
        return true
    end
    return false
end

-- Shared "Open / Save / Copy URL" action menu for albums and playlists.
-- Handles Save/Copy internally; returns true if the caller should open the
-- item (via browse_album / api_get_playlist_tracks) themselves, since the
-- follow-up navigation (session push/pop depth, pending-seek handling) differs
-- by call site.
local function album_action_menu(album)
    local acts = {"Open Album", "Save Album", "Albumart", "Copy URL", "Album Details"}
    if (album.artists or {})[1] then table.insert(acts, 2, "Go to Artist") end
    local al_ac_key = "album-ac:" .. (album.id or "")
    local pre_sel = 0
    local saved = Util.pos_get(al_ac_key)
    if type(saved) == "string" then
        for i, a in ipairs(acts) do if a == saved then pre_sel = i - 1; break end end
    end
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
        Util.pos_put(al_ac_key, action)
    end
    if action == "Save Album" then
        rofi_message(do_save_album(album.id) and "Album saved" or "Failed to save album")
    elseif action == "Copy URL" then
        copy_spotify_url("album", album.id)
        rofi_message("Copied URL")
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

local function playlist_action_menu(pl)
    local acts = {"Open Playlist", "Save Playlist", "Copy URL"}
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
    if action == "Save Playlist" then
        rofi_message(do_save_playlist(pl.id) and "Playlist saved" or "Failed to save playlist")
    elseif action == "Copy URL" then
        copy_spotify_url("playlist", pl.id)
        rofi_message("Copied URL")
    end
    return action == "Open Playlist"
end

local function do_playback_cmd(cmd)
    local token = get_token()
    if not token then return nil end
    local device_id = get_spotifyd_device()
    local url = "https://api.spotify.com/v1/me/player/" .. cmd
        .. (device_id and ("?device_id=" .. device_id) or "")
    local r = shell(string.format("curl -s --max-time 3 -o /dev/null -w '%%{http_code}' -X POST %s -H %s -H 'Content-Length: 0'", shell_quote(url), shell_quote("Authorization: Bearer " .. token)))
    if r and r:match("2..") then mem_bust("queue"); P.recent_cmd_at = os.time() end
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
            uris[#uris+1] = "spotify:track:" .. queue_tracks[i]
        end
        if #uris > 0 then body = json.encode({uris=uris, offset={position=0}}) end
    end
    if not body then return false end
    local r = shell(string.format("curl -s --max-time 3 -o /dev/null -w '%%{http_code}' -X PUT %s -H %s -H 'Content-Type: application/json' -d %s", shell_quote("https://api.spotify.com/v1/me/player/play" .. dparam), shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
    if r and r:match("2..") then
        queue_idx = new_idx
        flush_queue()
        P.recent_cmd_at = os.time()
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
            if d.images and #d.images > 0 then
                for _, t in ipairs(tracks) do
                    if not t.album then t.album = {} end
                    if not t.album.images or #t.album.images == 0 then
                        t.album.images = d.images
                    end
                end
            end
        end
        return d
    end)
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
    local lines = {}
    local function row(label, val)
        local k = 15
        return string.rep(" ", k - #label)
            .. Util.markup('<span foreground="#9bbfbf">') .. label .. Util.markup("</span>")
            .. "  " .. tostring(val)
    end
    local add = function(label, val)
        if val ~= nil and tostring(val) ~= "" then lines[#lines+1] = row(label, val) end
    end
    local names = {}
    for _, ar in ipairs(d.artists or {}) do
        if ar.name and ar.name ~= "" then names[#names+1] = ar.name end
    end
    add("Name", d.name)
    if #names > 0 then add("Artists", table.concat(names, ", ")) end
    add("Type", d.album_type)
    add("Release date", d.release_date)
    add("Total tracks", d.total_tracks)
    add("Label", d.label)
    if d.genres and #d.genres > 0 then add("Genres", table.concat(d.genres, ", ")) end
    if d.popularity ~= nil then add("Popularity", tostring(d.popularity)) end
    if d.external_urls and d.external_urls.spotify then add("URL", d.external_urls.spotify) end
    if d.external_ids and d.external_ids.upc then add("UPC", d.external_ids.upc) end
    add("ID", d.id)
    if #lines == 0 then lines[1] = "No details available" end
    rofi_message(table.concat(lines, "\n"), THEME_META)
end

Util.view_track_details = function(item)
    local d = api_get("tracks/" .. (item.id or ""), Util.with_market())
    if not d then
        rofi_message("Could not load track details")
        return
    end
    local lines = {}
    local function row(label, val)
        local k = 15
        return string.rep(" ", k - #label)
            .. Util.markup('<span foreground="#9bbfbf">') .. label .. Util.markup("</span>")
            .. "  " .. tostring(val)
    end
    local add = function(label, val)
        if val ~= nil and tostring(val) ~= "" then lines[#lines+1] = row(label, val) end
    end
    local names = {}
    for _, ar in ipairs(d.artists or {}) do
        if ar.name and ar.name ~= "" then names[#names+1] = ar.name end
    end
    add("Name", d.name)
    if #names > 0 then add("Artists", table.concat(names, ", ")) end
    if d.album and d.album.name then add("Album", d.album.name) end
    if d.album and d.album.album_type then add("Type", d.album.album_type) end
    if d.disc_number then add("Disc", d.disc_number) end
    if d.track_number then add("Track", d.track_number) end
    if d.duration_ms then
        add("Duration", string.format("%d:%02d", math.floor(d.duration_ms / 60000),
            math.floor((d.duration_ms % 60000) / 1000)))
    end
    if d.explicit then add("Explicit", "yes") end
    if d.popularity ~= nil then add("Popularity", tostring(d.popularity)) end
    if d.external_urls and d.external_urls.spotify then add("URL", d.external_urls.spotify) end
    if d.external_ids and d.external_ids.isrc then add("ISRC", d.external_ids.isrc) end
    add("ID", d.id)
    if #lines == 0 then lines[1] = "No details available" end
    rofi_message(table.concat(lines, "\n"), THEME_META)
end

api_get_playlist_tracks = function(playlist_id)
    return cached_fetch("playlist_tracks_" .. playlist_id, P.mass .. "/playlist_tracks_" .. playlist_id .. ".json", 1800, function()
        return Util.paged_fetch("playlists/" .. playlist_id .. "/tracks",
            -- `explicit` has to be in the mask: this is the only track source in
            -- the file that narrows the response, so without it every track read
            -- out of a playlist lost its explicit glyph in list rows, in the
            -- message bar and in Track Details. `is_playable` is in for the same
            -- reason -- the mask would otherwise drop the one field that says
            -- whether the track can actually play here.
            function(o) return Util.with_market("limit=100&offset=" .. o .. "&fields=items(track(id,name,duration_ms,explicit,is_playable,artists,album(id,name,images,artists)),added_at),next") end,
            function(d, items) return #items == 0 or not d.next end,
            function(entry)
                if entry.track and entry.track.id then
                    entry.track.added_at = entry.added_at
                    return entry.track
                end
                return nil
            end)
    end)
end

local function api_search(query, stype)
    local mem_key = "search:" .. query .. ":" .. stype
    local cached = mem_get(mem_key)
    if cached then return cached end
    local d = api_get("search", Util.with_market("q=" .. url_encode(query) .. "&type=" .. stype .. "&limit=" .. P.max))
    if d then
        for _, k in ipairs({"tracks","albums","artists","playlists"}) do
            if d[k] and d[k].items then d[k] = d[k].items end
        end
        mem_set(mem_key, d, 30)
    end
    return d
end

local function api_get_me()
    return cached_fetch("me_profile", P.cache .. "/me_profile.json", CACHE_TTL_MED, function()
        return api_get("me")
    end)
end
-- Util.market() needs this, and it is declared far above where this local
-- exists. Published rather than duplicated so there stays one profile fetch.
Util.api_get_me = api_get_me

local function api_get_my_playlists()
    return cached_fetch("my_playlists", P.cache .. "/my_playlists.json", CACHE_TTL_SHORT, function()
        return Util.paged_fetch("me/playlists",
            function(o) return "limit=50&offset=" .. o end,
            function(d, items) return #items == 0 or not d.next end)
    end)
end

-- PLAYLIST MEMBERSHIP INDEX
--
-- Answers "which of my playlists is this track in?" without a round trip, so the
-- action menu can offer Remove from Playlist no matter which view the track was
-- opened from. Only playlists you own or collaborate on are indexed -- Spotify
-- rejects writes to editorial ones, so offering removal for those would just
-- produce a failed request.
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

-- Read-only and non-blocking: view_actions already stalls up to 1.5s on
-- resolve_lyrics_state, so it must never also wait on a walk of every playlist.
-- A stale index is served while a rebuild runs in the background.
function Util.pl_index()
    local v = mem_get("pl_index")
    if v ~= nil then return v end
    local fresh = disk_get(P.pl_index, CACHE_TTL_SHORT)
    if fresh then mem_set("pl_index", fresh, CACHE_TTL_SHORT); return fresh end
    if not Util.detached then
        os.execute("nohup lua " .. shell_quote(P.dir .. "/spoot.lua")
            .. " --prefetch-plindex > /dev/null 2>&1 &")
    end
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
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X DELETE %s -H %s -H 'Content-Type: application/json' -d %s -o /dev/null",
        shell_quote(url), shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
    if not (r and r:match("2..")) then return false end
    disk_bust(P.mass .. "/playlist_tracks_" .. playlist_id .. ".json")
    mem_bust("playlist_tracks_" .. playlist_id)
    Util.pl_index_patch(playlist_id, track_id, false)
    return true
end

local function api_get_artist_albums(artist_id)
    return cached_fetch("artist_albums_" .. artist_id, P.mass .. "/artist_albums_" .. artist_id .. ".json", CACHE_TTL_LONG, function()
        return Util.paged_fetch("artists/" .. artist_id .. "/albums",
            function(o) return "limit=50&offset=" .. o .. "&include_groups=album,single,compilation" end,
            function(d, items) return #items == 0 or not d.next end)
    end)
end

local function api_get_artist_top_tracks(artist_id)
    return cached_fetch("artist_top_" .. artist_id, P.mass .. "/artist_top_" .. artist_id .. ".json", CACHE_TTL_MED, function()
        local me = api_get_me()
        local market = me and me.country
        local params = market and ("market=" .. market) or nil
        return api_get("artists/" .. artist_id .. "/top-tracks", params)
    end)
end

local function api_get_artist_related(artist_id)
    return cached_fetch("artist_related_" .. artist_id, P.mass .. "/artist_related_" .. artist_id .. ".json", CACHE_TTL_LONG, function()
        return api_get("artists/" .. artist_id .. "/related-artists")
    end)
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

local function api_get_recommendations(track_id)
    if not track_id then return nil end
    local d = api_get("recommendations", Util.with_market("seed_tracks=" .. track_id .. "&limit=20"))
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
    end)
end

local function api_get_category_playlists(cat_id)
    return cached_fetch("category_playlists_" .. cat_id, P.mass .. "/category_playlists_" .. cat_id .. ".json", CACHE_TTL_MED, function()
        local d = api_get("browse/categories/" .. cat_id .. "/playlists", "limit=20")
        if d and d.playlists and d.playlists.items then return d.playlists.items end
    end)
end

local function api_get_top_tracks()
    for _, rng in ipairs({"medium_term","long_term","short_term"}) do
        local tracks = cached_fetch("top_tracks_" .. rng, P.cache .. "/top_tracks_" .. rng .. ".json", CACHE_TTL_MED, function()
            local d = api_get("me/top/tracks", Util.with_market("limit=50&time_range=" .. rng))
            if not d or type(d.items) ~= "table" or #d.items == 0 then return nil end
            return d.items
        end)
        if tracks then return tracks end
    end
end

local function api_get_new_releases()
    return cached_fetch("new_releases", P.cache .. "/new_releases.json", CACHE_TTL_LONG, function()
        local d = api_get("browse/new-releases", "limit=20")
        if d and d.albums and d.albums.items and #d.albums.items > 0 then return d.albums.items end
    end)
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
    os.execute("nohup lua " .. shell_quote(P.dir .. "/spoot.lua")
        .. " --prefetch-lyrics " .. shell_quote(id)
        .. " " .. shell_quote(item.name or "")
        .. " " .. shell_quote(artist_names(item))
        .. " " .. shell_quote((item.album and item.album.name) or "")
        .. " " .. shell_quote(dur)
        .. " > /dev/null 2>&1 &")
    for _ = 1, 5 do
        if disk_get(disk, P.ttl_lyrics) ~= nil then return true end
        if disk_get(marker, P.ttl_lyrics) ~= nil then return false end
        os.execute("sleep 0.3")
    end
    return nil
end

-- VIEW: BROWSE

view_browse = function(entries, items, mesg, ctx, ctx_type, ctx_id, no_status)
    local is_track = ctx == "liked" or ctx == "top-tracks"
                  or ctx == "your-queue"
                  or ctx == "liked-by-artist" or ctx == "top-by-artist"
                  or ctx == "track" or ctx == "recommendations"
                  or ctx == "recently-played"
                  or (ctx_type and ctx_id)
    local is_album_list   = ctx == "album-list" or (ctx_type == "album" and not ctx_id) or ctx == "album" or ctx == "search-album"
    local is_album_grid   = ctx == "album-list" or (ctx_type == "album" and not ctx_id) or ctx == "search-album"
    local is_artist_list  = ctx == "artist-list" or ctx == "artist"
    local is_playlist_list = (ctx_type == "playlist" and not ctx_id) or ctx == "search-playlist"
    local is_search_all   = ctx == "all"
    local is_search_ctx   = is_search_all or (ctx and ctx:match("^search%-")) or ctx == "track" or ctx == "artist"
    local hide_single_artist = ctx == "album" or ctx == "liked-by-artist" or ctx == "top-by-artist"

    local v_key = ctx .. "|" .. (ctx_type or "") .. "|" .. (ctx_id or "")
    -- Left nil so rofi_dmenu's pos_key restores the remembered row. It is only
    -- assigned to force a specific row (jump-to-playing-track, or holding the
    -- cursor after a selection); an explicit sel always wins over pos_key.
    local pre_sel = nil
    local album_theme = nil
    if ctx == "album" then
        local a = items[1] and items[1].album
        local art_url = a and a.images and a.images[1] and a.images[1].url or nil
        local art_path = art_url and ensure_art(Util.art_url(art_url, "1e02")) or ""
        album_theme = Util.write_art_theme("album", art_path)
    end
    -- Regenerates the rows that carry live state (the ▶ marker and the liked
    -- heart). Handed to rofi_dmenu as `refresh` so a redraw triggered from
    -- inside it -- a track played or liked in a hotkey-opened action menu --
    -- shows the new state instead of the rows this loop last built. Album,
    -- artist and playlist rows have no such state and are left untouched, which
    -- also preserves the \0icon suffixes album_thumbs appends to them.
    -- Must match the flags the caller built `entries` with, or the first
    -- refresh silently re-renders the list differently: view_liked_tracks
    -- passes hide_liked, since a heart on every row of Liked Tracks is noise.
    local hide_liked = (ctx == "liked") or nil
    local function rebuild()
        if is_track then
            entries = format_entries(items, nil, hide_liked, hide_single_artist)
        elseif is_search_all then
            entries = {}
            for i, it in ipairs(items) do entries[i] = Util.format_mixed_item(it, i) end
        end
        if is_album_grid then Util.album_thumbs(entries, items) end
        return entries
    end
    while true do
        -- ctx_type/ctx_id/entries ride along so Shift+Return can hand the action
        -- menu the list it was opened from -- that is what lets it offer Remove
        -- from Playlist for the playlist you are actually browsing, and lets it
        -- drop the row here once the removal succeeds.
        -- Album, artist and playlist rows open their content on Return and their
        -- action menu on Shift+Return, so those lists claim the key (alt_select)
        -- and dispatch on it below. An album's TRACK list is is_album_list too,
        -- but is_track wins the dispatch there, so it keeps the default handler.
        local idx = rofi_dmenu(entries, {prompt=ctx or "Browse", mesg=mesg, custom=false, by_index=true, markup=(is_track or is_search_all or is_playlist_list or is_artist_list or is_album_list), theme=album_theme, use_menu=true, sel=pre_sel, pos_key=v_key, no_status=no_status or is_search_ctx, thumbs=is_album_grid, items=items, entries=entries, ctx_type=ctx_type, ctx_id=ctx_id, refresh=rebuild,
            alt_select=((is_album_list and not is_track) or is_artist_list or is_playlist_list or is_search_all) or nil})
        -- Read before anything else: the next rofi_dmenu call clears the flag.
        local alt = Util.alt_pressed
        Util.alt_pressed = false
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
            if item.id == current_id then
                if is_playing then
                    os.execute("playerctl pause 2>/dev/null")
                    is_playing = false
                else
                    os.execute("playerctl play 2>/dev/null")
                    is_playing = true
                end
            elseif do_play(item, ctx_type, ctx_id, items, idx) then
                -- Only on a request that actually went out: do_play refuses an
                -- unavailable track (and answers false with no token), and
                -- claiming it playing anyway moved the marker to a row that
                -- never started.
                current_track = item
                current_id = item.id
                is_playing = true
            end
            rebuild()
            pre_sel = idx - 1
        elseif is_search_all then
            local st = item._stype
            if st == "tracks" and alt then
                -- This list claims Shift+Return for its album and playlist rows,
                -- so a track row has to reproduce what rofi_dmenu's default
                -- handler would have done for it.
                if not Util.fast_now_track() then last_playback = 0; get_playback() end
                view_actions(item, ctx_type, ctx_id, items, idx, entries)
                if jump_to_track_pending then return end
                rebuild()
                pre_sel = idx - 1
            elseif st == "tracks" then
                local tctx, tcidx = nil, nil
                for j, it in ipairs(items) do
                    if it._stype == "tracks" then
                        if not tctx then tctx = {} end
                        tctx[#tctx+1] = it
                        if it == item then tcidx = #tctx end
                    end
                end
                if item.id == current_id then
                    if is_playing then
                        os.execute("playerctl pause 2>/dev/null")
                        is_playing = false
                    else
                        os.execute("playerctl play 2>/dev/null")
                        is_playing = true
                    end
                elseif do_play(item, ctx_type, ctx_id, tctx, tcidx) then
                    current_track = item
                    current_id = item.id
                    is_playing = true
                end
                get_playback()
                rebuild()
                pre_sel = idx - 1
            elseif st == "albums" then
                if not alt or album_action_menu(item) then
                    -- browse_album reports its own failure now.
                    browse_album(item.id, (item.name or "Unknown") .. album_suffix(item))
                    if jump_to_track_pending then return end
                end
            elseif st == "artists" then
                Util.open_artist(item, alt)
                if jump_to_track_pending then return end
            elseif st == "playlists" then
                if not alt or playlist_action_menu(item) then
                    Util.open_playlist(item)
                    if jump_to_track_pending then return end
                end
            end
            if st ~= "tracks" then
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
            if alt and ctx == "album-list" then
                local acts = {"Open Album", "Remove from Library", "Albumart", "Copy URL", "Album Details"}
                if (item.artists or {})[1] then table.insert(acts, 2, "Go to Artist") end
                -- act_alt, not alt: this list's own Shift+Return is already bound
                -- to the `alt` above, which is what opened this menu.
                local action = rofi_dmenu(acts, {prompt=item.name or "Album", mesg=(item.name or "Album") .. album_suffix(item), custom=false, theme=THEME_SUB, no_status=true, markup=true, pos_key="album-list-ac:" .. (item.id or ""), alt_select=true})
                local act_alt = Util.alt_pressed
                Util.alt_pressed = false
                if action == "Open Album" then
                    do_open = true
                elseif action == "Remove from Library" then
                    local token = get_token()
                    if token then
                        local url = "https://api.spotify.com/v1/me/albums?ids=" .. item.id
                        local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X DELETE %s -H %s -o /dev/null", shell_quote(url), shell_quote("Authorization: Bearer " .. token)))
                        if r and r:match("2..") then
                            mem_bust("saved_albums")
                            disk_bust(P.albums)
                            rofi_message("Removed from library")
                            table.remove(items, idx)
                            entries = {}
                            for i, a in ipairs(items) do entries[i] = display_album(a, true) end
                            mesg = "Saved Albums" .. SEP .. #items .. " albums"
                            if #items == 0 then return end
                            goto br_next
                        else rofi_message("Failed to remove") end
                    end
                elseif action == "Copy URL" then
                    copy_spotify_url("album", item.id)
                    rofi_message("Copied URL")
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
            end
            if do_open then
                -- browse_album reports its own failure now.
                browse_album(item.id, (item.name or "Unknown") .. album_suffix(item))
                if jump_to_track_pending then return end
            end
            pre_sel = idx - 1
        elseif is_artist_list then
            Util.open_artist(item, alt)
            entries[idx] = ctx == "artist" and string.format("%2d. %s", idx, display_artist(item)) or display_artist(item)
            pre_sel = idx - 1
        elseif is_playlist_list then
            if not alt or playlist_action_menu(item) then Util.open_playlist(item) end
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

-- VIEW: ALBUM ART

view_art = function(item)
    if not item or not item.album or not item.album.images or #item.album.images == 0 then
        rofi_message("No album art available"); return
    end
    local art_url = item.album.images[1].url
    local art_path = ensure_art(Util.art_url(art_url), "highres")
    if not art_path then rofi_message("No album art available"); return end
    local mesg = Util.pango_escape((item.name or "Unknown") .. SEP .. artist_names(item))
    local entry_tf = os.tmpname()
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

view_actions = function(item, ctx_type, ctx_id, all_items, cidx, entries)
    -- No longer collapses action-on-action: a nested action menu (Alt+Return or
    -- Shift+Return from inside one) is a real extra level now that rofi_dmenu
    -- redraws the menu underneath instead of closing it. Popping the parent's
    -- entry here would leave that still-visible menu without a stack entry.
    -- from_current records whether this menu was opened ON the track that was
    -- playing at the time. A warm start uses it to decide whether "restore the
    -- action menu" means the track named in the entry or whatever is playing
    -- now; without it, every restored action menu was redirected to the current
    -- track, so Shift+Return on some other row came back as the wrong track.
    -- `or nil` keeps the field out of session.json when false, so older session
    -- files (which have no such field) restore their own track.
    -- ctx_type/ctx_id are recorded so a warm start restores the menu with the
    -- list context it had. all_items/cidx cannot be restored, so a replayed menu
    -- can still remove the track, it just cannot prune a row that isn't there.
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
    actions[#actions+1] = "Copy URL"; akeys[#akeys+1] = "url"
    actions[#actions+1] = "More Like This"; akeys[#akeys+1] = "more"
    actions[#actions+1] = "Albumart"; akeys[#akeys+1] = "art"
    actions[#actions+1] = "Track Details"; akeys[#akeys+1] = "details"

    -- The four volatile labels are derived from live state on every draw rather
    -- than patched by hand in the selection branches, so they stay right when a
    -- nested action menu (Alt+Return from here) plays or likes this same track
    -- and rofi_dmenu redraws without this loop running.
    local DIM = '<span color="#6a707f">'
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
                custom=false, by_index=true, use_menu=true, theme=THEME_SUB, pos_key=pick_key,
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

    while true do
        local art_url = item.album and item.album.images and #item.album.images > 0
            and item.album.images[1].url or nil
        local art_path = ensure_art(Util.art_url(art_url, "1e02")) or ""
        local tmp_theme = Util.write_art_theme("action", art_path)
        local action_theme = tmp_theme
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
            Util.back_pressed = false
            if jump_to_track_pending then
                if tmp_theme then os.remove(tmp_theme) end
                return
            else
                if tmp_theme then os.remove(tmp_theme) end
                return
            end
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
                if album and album.id and album_action_menu(album) then
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
            os.execute("playerctl play 2>/dev/null")
            is_playing = true
        elseif key == "Play" then
            if do_play(item, ctx_type, ctx_id, all_items, cidx) then
                current_track = item
                current_id = item.id
                is_playing = true
            end
        elseif key == "Pause" then
            os.execute("playerctl pause 2>/dev/null")
            is_playing = false
        elseif key == "Add to Queue" then do_add_queue(item.id)
        elseif key == "Like" or key == "Unlike" then
            if do_like(item, key == "Unlike") then
                is_liked = not is_liked
                if not is_liked then if tmp_theme then os.remove(tmp_theme) end; return true end
            end
        elseif key == "Go to Album" then
            local album = item.album
            if album and album.id then
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
                    custom=false, by_index=true, use_menu=true, theme=THEME_SUB, markup=true, pos_key="remove-from-playlist"})
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
        elseif key == "Copy URL" then
            copy_spotify_url("track", item.id)
            rofi_message("Copied URL")
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
    local ae = {}
    for i, a in ipairs(items) do ae[i] = display_album(a) end
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

local function format_search_results(results, category, query)
    if category == "all" then
        local items = {}
        for _, rk in ipairs({"tracks","albums","artists","playlists"}) do
            local ci = results[rk]
            if ci and type(ci) == "table" then
                for i = 1, math.min(#ci, 5) do ci[i]._stype = rk; items[#items+1] = ci[i] end
            end
        end
        if #items == 0 then return nil end
        local n = math.min(#items, P.max); local entries = {}
        for i = 1, n do
            entries[#entries+1] = Util.format_mixed_item(items[i], i)
        end
        return items, entries, n .. " results for " .. query, "all", nil
    else
        local key = category .. "s"
        local items = results[key]
        if not items or type(items) ~= "table" or #items == 0 then return nil end
        local n = math.min(#items, P.max); local entries = {}
        for i = 1, n do
            local body
            if category == "track" then body = display_track(items[i])
            elseif category == "artist" then body = display_artist(items[i])
            elseif category == "album" then body = display_album(items[i], true)
            else body = display_playlist(items[i]) end
            entries[#entries+1] = string.format("%2d. %s", i, body)
        end
        local sctx = (category == "album" or category == "playlist") and "search-" .. category or category
        return items, entries, n .. " " .. key .. " for " .. query, sctx,
               (category == "album" and "album" or category == "playlist" and "playlist" or nil)
    end
end

-- Opening a view is ONE function, called by both the live menu and
-- replay_session. Where the two drifted apart -- replay calling view_browse
-- directly instead of through Util.scope -- the restored menu sat on a stack
-- missing its own entry, so anything opened from it was pushed onto the
-- grandparent and that shortened stack was what session_save wrote to disk.
-- That is what made the NEXT warm start land somewhere other than where you
-- left off. New views must follow this shape rather than being reimplemented
-- in replay_session.

function Util.open_playlist(pl)
    if not pl or not pl.id then return false end
    local tracks = api_get_playlist_tracks(pl.id)
    if not tracks then rofi_message("Failed to load playlist"); return false end
    if #tracks == 0 then rofi_message("Playlist is empty"); return false end
    Util.scope({view="playlist", playlist_id=pl.id, playlist_name=pl.name or "Playlist"}, function()
        local te = format_entries(tracks)
        view_browse(te, tracks, display_playlist(pl) .. SEP .. #tracks .. " tracks", "playlist", "playlist", pl.id)
    end)
    return true
end

-- on_change("rename"|"delete", pl) lets the playlist LIST that opened this menu
-- resync its rows. Replay passes nil: there is no list behind it to update.
function Util.open_playlist_actions(pl, on_change)
    if not pl or not pl.id then return end
    Util.scope({view="playlist-actions", playlist_id=pl.id, playlist_name=pl.name or "Playlist"}, function()
        -- Opening an empty playlist only ever produces the "Playlist is empty"
        -- message from Util.open_playlist, so say that on the row itself instead.
        -- Dimmed in place rather than dropped: a row that disappears shifts every
        -- index below it, and pos_key remembers this menu's cursor by index.
        -- Only a playlist someone made can be empty -- editorial ones always
        -- carry tracks, and me/playlists includes the editorial ones you follow.
        -- The replay entry point below passes only {id, name}, so fall back to
        -- the (cached) playlist list for the count when the object has none.
        local total = pl.tracks and tonumber(pl.tracks.total)
        if not total then
            for _, p in ipairs(api_get_my_playlists() or {}) do
                if p.id == pl.id then
                    total = p.tracks and tonumber(p.tracks.total)
                    pl.owner = pl.owner or p.owner
                    break
                end
            end
        end
        local is_empty = total == 0 and not (pl.owner and pl.owner.id == "spotify")
        local acts = {is_empty and Util.markup('<span color="#6a707f">Playlist is empty</span>')
                      or "Open Playlist", "Rename Playlist", "Delete Playlist", "Copy URL"}
        while true do
            local asel = rofi_dmenu(acts, {prompt=display_playlist(pl), mesg=display_playlist(pl), custom=false,
                use_menu=true, theme=THEME_SUB, no_status=true, markup=true, pos_key="playlist-ac:" .. (pl.id or "")})
            if not asel then return end
            local token = get_token()
            if asel == "Open Playlist" then
                Util.open_playlist(pl)
                if jump_to_track_pending then return end
            elseif asel == "Rename Playlist" then
                if not token then rofi_message("No auth")
                else
                    local nn = rofi_input("New Name", pl.name or "", P.THEME_SEARCH)
                    if nn ~= "" and nn ~= (pl.name or "") then
                        local url = "https://api.spotify.com/v1/playlists/" .. pl.id
                        local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X PUT %s -H %s -H 'Content-Type: application/json' -d %s -o /dev/null", shell_quote(url), shell_quote("Authorization: Bearer " .. token), shell_quote(json.encode({name=nn}))))
                        if r and r:match("2..") then
                            pl.name = nn; bust_my_playlists()
                            if on_change then on_change("rename", pl) end
                            rofi_message("Renamed")
                        else rofi_message("Failed") end
                    end
                end
            elseif asel == "Delete Playlist" then
                if not token then rofi_message("No auth")
                else
                    local c = rofi_dmenu({"DELETE","Cancel"}, {prompt="Delete", mesg="Delete " .. (pl.name or "") .. "?", custom=false, by_index=true, use_menu=true, theme=THEME_SUB, no_status=true, markup=true})
                    if c == 1 then
                        local url = "https://api.spotify.com/v1/playlists/" .. pl.id .. "/followers"
                        local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X DELETE %s -H %s -o /dev/null", shell_quote(url), shell_quote("Authorization: Bearer " .. token)))
                        if r and r:match("2..") then
                            bust_my_playlists()
                            disk_bust(P.mass .. "/playlist_tracks_" .. pl.id .. ".json"); mem_bust("playlist_tracks_" .. pl.id)
                            rofi_message("Deleted Playlist: " .. (pl.name or ""))
                            if on_change then on_change("delete", pl) end
                            return
                        else rofi_message("Failed to delete") end
                    end
                end
            elseif asel == "Copy URL" then
                copy_spotify_url("playlist", pl.id)
                rofi_message("Copied URL")
            end
        end
    end)
end

function Util.open_recommendations(track_id, track_name)
    local tracks = api_get_recommendations(track_id)
    if not tracks then rofi_message("No recommendations found"); return false end
    Util.scope({view="recommendations", track_id=track_id, recs_track_name=track_name or ""}, function()
        local te = format_entries(tracks)
        view_browse(te, tracks, "More Like " .. (track_name or ""), "recommendations", nil, nil)
    end)
    return true
end

function Util.open_search_results(category, query)
    category = category or "all"
    local stype = category == "all" and "track,album,artist,playlist" or category
    local results = api_search(query, stype)
    if not results then rofi_message("No results"); return false end
    Util.scope({view="search-results", category=category, query=query}, function()
        local items, entries, mesg, sctx, sctx_id = format_search_results(results, category, query)
        if not items then return end
        view_browse(entries, items, mesg, sctx, sctx_id, nil)
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
            Util.album_thumbs(ae, items)
            local aidx = rofi_dmenu(ae, {prompt=artist_name or "", mesg=mesg, custom=false, by_index=true,
                                         use_menu=true, no_status=true, markup=true, thumbs=true, pos_key=pk,
                                         alt_select=true,
                                         -- So F5 re-runs album_thumbs; view_browse gets this
                                         -- via its own `rebuild`.
                                         refresh=function() Util.album_thumbs(ae, items); return ae end})
            local alt = Util.alt_pressed
            Util.alt_pressed = false
            if not aidx then return end
            if aidx >= 1 and aidx <= #items then
                local al = items[aidx]
                if not alt or album_action_menu(al) then
                    browse_album(al.id, (al.name or "Unknown") .. album_suffix(al))
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
                                         by_index=true, use_menu=true, no_status=true, markup=true, pos_key=pk,
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
                     "Copy URL"}
    local art_ac_key = "artist-ac:" .. (artist.id or "")

    while true do
        local sel = rofi_dmenu(actions, {prompt=artist.name or "Artist", mesg=artist.name or "Artist",
                                         custom=false, use_menu=true, theme=THEME_SUB, no_status=true,
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
        elseif sel == "Copy URL" then
            copy_spotify_url("artist", artist.id)
            rofi_message("Copied URL")
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
                 use_menu=true, theme=THEME_LYR, sel=pre_sel, markup=true})
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
                        shell(string.format("curl -s --max-time 3 -o /dev/null -X PUT %s -H %s -H 'Content-Type: application/json' -d %s", shell_quote("https://api.spotify.com/v1/me/player/play" .. dparam), shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
                        P.recent_cmd_at = os.time()
                        current_track = item
                        current_id = item.id
                        is_playing = true
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
                {prompt="Lyrics", mesg=mesg_base, custom=false, use_menu=true, theme=THEME_LYR, markup=true, pos_key="lyrics:" .. (item.id or "")})
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
        if p.owner and (p.owner.id == my_id or p.collaborative) then
            names[#names+1] = p.name; ids[#ids+1] = p.id
        end
    end

    local idx = rofi_dmenu(names, {prompt="Add to Playlist", mesg="Select a playlist", custom=false, by_index=true, use_menu=true, markup=true, pos_key="add-to-playlist"})
    if not idx then return end

    local target_id, target_name
    if ids[idx] == "__create__" then
        local pl_name = rofi_input("New Playlist", "", P.THEME_SEARCH)
        if pl_name == "" then return end
        local url = "https://api.spotify.com/v1/users/" .. my_id .. "/playlists"
        local r = shell(string.format("curl -s --max-time 5 -X POST %s -H %s -H 'Content-Type: application/json' -d %s", shell_quote(url), shell_quote("Authorization: Bearer " .. token), shell_quote(json.encode({name=pl_name}))))
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
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X POST %s -H %s -H 'Content-Type: application/json' -d %s -o /dev/null", shell_quote(add_url), shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
    if r and r:match("2..") then
        disk_bust(P.mass .. "/playlist_tracks_" .. target_id .. ".json"); mem_bust("playlist_tracks_" .. target_id)
        -- Patch the membership index now rather than waiting for a rebuild, so
        -- Remove from Playlist offers this playlist immediately.
        Util.pl_index_patch(target_id, track_id, true, target_name)
    end
    rofi_message(r and r:match("2..") and "Added to playlist" or "Failed to add track")
end)
end

-- VIEW: PLAYLISTS

local function view_playlists()
    Util.scope({view="playlists"}, function()
    local token = get_token()
    if not token then rofi_message("No auth"); return end
    local pls = api_get_my_playlists() or {}
    local entries = {"Create New Playlist"}
    for _, p in ipairs(pls) do entries[#entries+1] = display_playlist(p) end

    while true do
        local idx = rofi_dmenu(entries, {prompt="Playlists", mesg="Playlists" .. SEP .. #pls, custom=false, by_index=true, use_menu=true, no_status=true, markup=true, pos_key="playlists||", alt_select=true})
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        if not idx then return end
        if idx == 1 then
            local pl_name = rofi_input("New Playlist", "", P.THEME_SEARCH)
            if pl_name == "" then goto pl_loop end
            local me = api_get_me()
            if me and me.id then
                local url = "https://api.spotify.com/v1/users/" .. me.id .. "/playlists"
                local r = shell(string.format("curl -s --max-time 5 -X POST %s -H %s -H 'Content-Type: application/json' -d %s", shell_quote(url), shell_quote("Authorization: Bearer " .. token), shell_quote(json.encode({name=pl_name}))))
                local cr = safe_decode(r)
                if cr then pls[#pls+1] = cr; entries[#entries+1] = display_playlist(cr); bust_my_playlists()
                else rofi_message("Failed to create") end
            end
        elseif idx >= 2 and idx - 1 <= #pls then
            local pl = pls[idx - 1]
            if alt then
                Util.open_playlist_actions(pl, function(what)
                    if what == "rename" then
                        table.sort(pls, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
                        entries = {"Create New Playlist"}
                        for _, p in ipairs(pls) do entries[#entries+1] = display_playlist(p) end
                    elseif what == "delete" then
                        local del_idx = nil
                        for i, p in ipairs(pls) do if p.id == pl.id then del_idx = i; break end end
                        if del_idx then table.remove(entries, del_idx + 1); table.remove(pls, del_idx) end
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

local function view_search(category)
    Util.scope({view="search", category=category}, function()
    while true do
        local key = category == "all" and "all" or category .. "s"
        local query = rofi_dmenu({}, {prompt="Search " .. category:sub(1,1):upper() .. category:sub(2), mesg="Search " .. key, use_menu=true, theme=P.THEME_SEARCH, no_status=true, markup=true})
        if not query then break end
        if not Util.open_search_results(category, query) then break end
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
        local idx = rofi_dmenu(ce, {prompt="Categories", mesg="Categories" .. SEP .. #cats, custom=false, by_index=true, use_menu=true, no_status=true, markup=true, pos_key="categories||"})
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
    local tracks = load_liked_tracks()
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
    local entries = {}
    for i, a in ipairs(al) do entries[i] = display_album(a, true) end
    view_browse(entries, al, "Saved Albums" .. SEP .. #al .. " albums", "album-list", "album", nil, true)
    if jump_to_track_pending then return end
end)
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

local function view_new_releases()
    local albums = api_get_new_releases() or {}
    if #albums == 0 then rofi_message("No new releases"); return end
    Util.scope({view="new-releases"}, function()
    local entries = {}
    for i, a in ipairs(albums) do entries[i] = display_album(a, true) end
    local v_key = "new-releases||"
    local pre_sel = nil
    while true do
        Util.album_thumbs(entries, albums)
        local idx = rofi_dmenu(entries, {prompt="New Releases", mesg="New Releases" .. SEP .. #albums .. " albums", custom=false, by_index=true, use_menu=true, no_status=true, sel=pre_sel, pos_key=v_key, markup=true, thumbs=true, alt_select=true,
            refresh=function() Util.album_thumbs(entries, albums); return entries end})
        local alt = Util.alt_pressed
        Util.alt_pressed = false
        if not idx then return end
        if idx >= 1 and idx <= #albums then
            pre_sel = idx - 1
            local al = albums[idx]
            if not alt or album_action_menu(al) then
                browse_album(al.id, (al.name or "Unknown") .. album_suffix(al))
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
        -- This response is the one track source that does NOT go through
        -- cached_fetch, so mark_availability has to be called by hand.
        d = api_get("me/player/queue", Util.with_market())
        if d then Util.mark_availability(d); mem_set("queue", d, 10) end
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
    -- No spotifyd_device_vol gate here. It only ever answered when a device
    -- lookup happened to run earlier in THIS process, so a fresh launch going
    -- straight to System > Volume skipped it entirely -- and when it did fire it
    -- blocked a menu that drives volume through playerctl, not the Spotify
    -- device API, so the device's supports_volume flag was not the capability
    -- being tested.
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

local function view_playback()
    -- Resync queue_idx to wherever playback actually is. A blind +1/-1 assumes
    -- queue_tracks is played in linear order, which breaks as soon as shuffle
    -- is on (Spotify's real next/previous track has no relation to our local
    -- index). Looking up current_id in queue_tracks keeps us correct in both.
    local function sync_queue_idx()
        if not queue_tracks or not current_id then return end
        for i, tid in ipairs(queue_tracks) do
            if tid == current_id then queue_idx = i; flush_queue(); return end
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
        add(current_track and "Seek" or Util.markup('<span color="#6a707f">Seek</span>'), "seek")
        add("Next Track", "next")
        add("Previous Track", "prev")
        add("Shuffle " .. (is_shuffle and Util.markup("<b>ON</b>") or Util.markup("<b>OFF</b>")), "shuffle")
        add("Repeat " .. (repeat_state=="off" and Util.markup("<b>OFF</b>") or (repeat_state=="track" and Util.markup("<b>TRACK</b>") or Util.markup("<b>CONTEXT</b>"))), "repeat")
        add("Open URL", "openurl")
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
            custom=false, use_menu=true, theme=THEME_SUB, markup=true, no_status=not current_track,
            sel=pre_sel, current=current_track, refresh=build_items})
        if not si then break end
        -- Resolved against `items` AS DRAWN -- the next pass's build_items has not
        -- run yet, so the label rofi echoed still matches the row it came from.
        for i, it in ipairs(items) do
            if Util.strip_markup(it) == Util.strip_markup(si) then
                pre_sel = i - 1; Util.pos_put(pb_key, keys[i]); break
            end
        end
        if si == "Pause" then
            local r = os.execute("playerctl pause 2>/dev/null")
            if r == true or r == 0 then is_playing = false else rofi_message("Failed to pause") end
        elseif si == "Resume" then
            local r = os.execute("playerctl play 2>/dev/null")
            if r == true or r == 0 then is_playing = true else rofi_message("Failed to resume") end
        elseif si == "Next Track" then
            local prev_id = current_id
            local r = do_playback_cmd("next")
            if r and r:match("2..") then
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
            if r and r:match("2..") then
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
        elseif si == "Open URL" then
            local url = Util.get_clipboard()
            if url and url ~= "" then open_url(url)
            else rofi_message("Clipboard is empty") end
        end
    end
end)
end

-- VIEW: SYSTEM

local function view_system()
    local cur_br = get_saved_bitrate()
    local cur_vol = get_playerctl_volume()
    local vol_label = cur_vol == 0 and "Muted" or (cur_vol .. "%")
    local items = {"Keybinds", "Volume " .. Util.markup("<b>") .. vol_label .. Util.markup("</b>"), "Bitrate " .. Util.markup("<b>") .. cur_br .. " kbps" .. Util.markup("</b>"),
                   "Jump to Trail Step",
                   "Clear Session",
                   "Refresh Library",
                   "Restart Daemons",
                   "Kill Daemons"}
    -- Rows 2 and 3 are patched in place below as the volume and bitrate change,
    -- so the cursor is remembered by these stable keys rather than by the label
    -- (which no longer matched once it had been rewritten). See Util.pos_row.
    local keys = {"keybinds", "volume", "bitrate", "trailjump",
                  "clearsession", "refresh", "restart", "kill"}
    Util.scope({view="system"}, function()
    local sys_key = "system:"
    local pre_sel = Util.pos_row(sys_key, keys)
    while true do
        local sel = rofi_dmenu(items, {prompt="System", custom=false, use_menu=true, theme=THEME_SUB, markup=true, no_status=true, sel=pre_sel})
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
                row("jump to trail step", "tab"),
                row("select", "return"),
                row("action menu (track / album / artist / playlist)", "shift + return"),
                row("jump to current track's action menu", "alt + return"),
                row("close", "escape"),
                row("clear session trail", "delete"),
                row("clear input / back one level", "backspace"),
                row("redraw / load missing thumbnails", "f5"),
                row("jump to main menu", "alt + space"),
                row("seek + / - 10s", "alt + = / -"),
                row("seek menu", "alt + e"),
                row("liked tracks", "alt + l"),
                row("recently played", "alt + p"),
                row("album art of current track", "alt + a"),
                row("lyrics of current track", "alt + y"),
                row("cycle repeat modes", "alt + r"),
                row("toggle shuffle", "alt + s"),
                row("open Spotify URL from clipboard", "alt + g"),
                row("jump to playing track (list)", "alt + c"),
                row("jump to current lyric line (lyrics)"),
            }, "\n"), THEME_BINDS)
        elseif clean:match("^Volume") then
            view_volume()
            cur_vol = get_playerctl_volume()
            vol_label = cur_vol == 0 and "Muted" or (cur_vol .. "%")
            items[2] = "Volume " .. Util.markup("<b>") .. vol_label .. Util.markup("</b>")
        elseif clean:match("^Bitrate") then
            local br_opts = {}
            for _, v in ipairs({96, 160, 320}) do
                if v == cur_br then
                    table.insert(br_opts, Util.markup('<span foreground="#b6e0a4">')
                        .. "\u{f00c} " .. v .. " kbps" .. (v == 160 and " (default)" or "") .. Util.markup("</span>"))
                else
                    local label = v .. " kbps"
                    if v == 160 then label = label .. " (default)" end
                    table.insert(br_opts, label)
                end
            end
            local chosen = rofi_dmenu(br_opts,
                {prompt="Bitrate", mesg="Current: " .. cur_br .. " kbps\nRestart daemons to apply", custom=false, markup=true, theme=THEME_SUB, no_status=true, crumb="Bitrate", pos_key="bitrate"})
            if chosen then
                local n = tonumber(Util.strip_markup(chosen):match("(%d+)"))
                if n then
                    save_bitrate(n); cur_br = n
                    items[3] = "Bitrate " .. Util.markup("<b>") .. n .. " kbps" .. Util.markup("</b>")
                    os.execute("notify-send -t 3000 --app-name=spoot 'Spoot' '" .. n .. " kbps — restart daemons to apply' &")
                end
            end
        elseif clean == "Refresh Library" then
            os.execute("notify-send -t 5000 --app-name=spoot 'spoot' 'Building Cache' &")
            local tracks, albums, artists, from_cache, failed = fetch_library_with_fallback()
            if tracks then
                save_library_cache(tracks, albums, artists)
                populate_liked_ids()
                os.execute("notify-send -t 3000 --app-name=spoot 'spoot' 'Caching Complete' &")
            else
                os.execute("notify-send -t 5000 --app-name=spoot 'Spoot' 'Library refresh failed' &")
            end
        elseif clean == "Jump to Trail Step" then
            Util.view_trail_jump(_session_stack)
            main_pending = true
            break
        elseif clean == "Clear Session" then
            Util.clear_trail()
            main_pending = true
            break
        elseif clean == "Restart Daemons" then
            os.execute("pkill -x spotifyd 2>/dev/null"); os.execute("pkill -f 'spoot.*--daemon' 2>/dev/null")
            Util.kill_recent_watch()
            Util.kill_playerctl_follow()
            Util.bust_device()
            -- Deliberately keeps P.trails: restarting audio plumbing has
            -- nothing to do with navigation history.
            os.execute("sleep 1")
            inv_playback()
            ensure_spotifyd()
            os.execute("sleep 3")
            os.execute("nohup lua " .. shell_quote(P.dir .. "/spoot.lua") .. " --daemon > /tmp/spoot_daemon.log 2>&1 &")
            Util.ensure_recent_watch()
        elseif clean == "Kill Daemons" then
            os.execute("pkill -x spotifyd 2>/dev/null")
            os.execute("pkill -f 'spoot.*--daemon' 2>/dev/null")
            Util.kill_recent_watch()
            Util.kill_playerctl_follow()
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
local function reg(view, label, open) VIEWS[view] = {label = label, open = open} end

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
end)
reg("seek", "Seek", function(s)
    if not s.track_id then return end
    if current_track and current_track.id == s.track_id then view_seek(current_track)
    else view_seek({id=s.track_id, name=s.strack_name or "", duration_ms=s.track_duration_ms or 0}) end
end)
reg("album", "Album", function(s)
    if s.album_id then browse_album(s.album_id) end
end)
reg("playlist", "Playlist", function(s)
    if not s.playlist_id then return end
    Util.open_playlist(api_get("playlists/" .. s.playlist_id)
        or {id=s.playlist_id, name=s.playlist_name or "Playlist"})
end)
reg("playlist-actions", "Playlist", function(s)
    if not s.playlist_id then return end
    Util.open_playlist_actions({id=s.playlist_id, name=s.playlist_name or "Playlist"})
end)
reg("recommendations", "More Like", function(s)
    if s.track_id then Util.open_recommendations(s.track_id, s.recs_track_name) end
end)
reg("search-results", "Search", function(s)
    if s.query then Util.open_search_results(s.category, s.query) end
end)
reg("category-playlists", "Category", function(s)
    if s.category_id then Util.open_category_playlists(s.category_id, s.category_name) end
end)
reg("add-to-playlist", "Add to Playlist", function(s)
    if s.track_id then view_add_pl(s.track_id, s.track_name) end
end)
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
reg("search", "Search", function(s)
    if s.category then view_search(s.category) end
end)
reg("liked",            "Liked Tracks",     function() view_liked_tracks() end)
reg("top-tracks",       "Top Tracks",       function() view_top_tracks() end)
reg("your-queue",       "Your Queue",       function() view_your_queue() end)
reg("recently-played",  "Recently Played",  function() view_recently_played() end)
reg("saved-albums",     "Saved Albums",     function() view_saved_albums() end)
reg("followed-artists", "Followed Artists", function() view_followed_artists() end)
reg("new-releases",     "New Releases",     function() view_new_releases() end)
reg("categories",       "Categories",       function() view_categories() end)
reg("playlists",        "Playlists",        function() view_playlists() end)
reg("volume",           "Volume",           function() view_volume() end)
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

function Util.view_trail_jump(stack)
    local SEP = "  \u{F17B7}  "
    local opts = {}
    local function push(prefix, name, ostack, depth)
        opts[#opts+1] = {label=prefix .. name, stack=ostack, depth=depth}
    end
    local first = true
    -- Same guard as Util.parts_from_stack: a junk stack entry must not be able
    -- to take the whole menu down.
    local function step_name(e, last_name)
        if type(e) ~= "table" then return view_label(nil), last_name end
        local name = crumb_name(e)
        if name and name ~= last_name then return name, name end
        return view_label(e.view), last_name
    end
    local function add_trail(stk, with_main)
        if with_main then
            push(first and "" or SEP, "Main", stk, 0)
            first = false
            if stk then
                local last_name = nil
                for i = 1, #stk do
                    local e = stk[i]
                    local name, ln = step_name(e, last_name)
                    last_name = ln
                    push("> ", name, stk, i)
                end
            end
            return
        end
        if not stk or #stk == 0 then return end
        local last_name = nil
        for i = 1, #stk do
            local e = stk[i]
            local name, ln = step_name(e, last_name)
            last_name = ln
            push(i == 1 and (first and "" or SEP) or "> ", name, stk, i)
        end
        first = false
    end
    for _, t in ipairs(Util.trail_history) do
        if type(t) == "table" and type(t.stack) == "table" then add_trail(t.stack) end
    end
    add_trail(stack, true)
    if #opts <= 1 then
        rofi_message("You left no trail")
    else
        local labels = {}
        for i, o in ipairs(opts) do labels[i] = o.label end
        local idx = rofi_dmenu(labels, {prompt="Jump to Trail Step", custom=false, by_index=true, use_menu=true, theme=Util.THEME_TRAIL, markup=true, no_status=true, no_alt_space=true, sel=#labels - 1})
        if idx and idx >= 1 and idx <= #opts then
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
    os.execute("rm -f /tmp/spoot_code /tmp/spoot_oauth_pid 2>/dev/null")
    local lock = "/tmp/spoot_instance.lock"
    local existing = trim(read_file(lock) or "")
    if existing ~= "" and existing:match("^%d+$") then
        local alive = trim(shell("kill -0 " .. existing .. " 2>/dev/null && echo alive") or "") == "alive"
        local cmdline = alive and trim(shell("cat /proc/" .. existing .. "/cmdline 2>/dev/null") or "") or ""
        if alive and cmdline:find("spoot") then os.exit(0) end
    end
    local pid = Util.get_own_pid()
    if pid then Util.secure_write(lock, tostring(pid)) end
end

local function ensure_daemon()
    local daemon_pid = trim(read_file("/tmp/spoot_daemon.pid") or "")
    local daemon_alive = false
    if daemon_pid ~= "" and tonumber(daemon_pid) then
        local cmdline = trim(shell("cat /proc/" .. daemon_pid .. "/cmdline 2>/dev/null") or "")
        if cmdline:find("spoot") and cmdline:find("--daemon") then
            daemon_alive = trim(shell("kill -0 " .. daemon_pid .. " 2>/dev/null && echo alive") or "") == "alive"
        end
    end
    if not daemon_alive then
        os.execute("nohup lua " .. shell_quote(P.dir .. "/spoot.lua") .. " --daemon > /tmp/spoot_daemon.log 2>&1 &")
    end
    return daemon_alive
end

function Util.ensure_recent_watch()
    local pid = trim(read_file("/tmp/spoot_recent.pid") or "")
    local alive = false
    if pid ~= "" and tonumber(pid) then
        local cmdline = trim(shell("cat /proc/" .. pid .. "/cmdline 2>/dev/null") or "")
        if cmdline:find("spoot") and cmdline:find("--recent%-watch") then
            alive = trim(shell("kill -0 " .. pid .. " 2>/dev/null && echo alive") or "") == "alive"
        end
    end
    if not alive then
        os.execute("nohup lua " .. shell_quote(P.dir .. "/spoot.lua") .. " --recent-watch > /tmp/spoot_recent_watch.log 2>&1 &")
    end
end

function Util.kill_recent_watch()
    local wp = trim(read_file("/tmp/spoot_recent.pid") or "")
    -- Validated before interpolation, like every sibling that reads a pid file
    -- (init_instance_lock, ensure_daemon, Util.spawn_art_prefetch). The pkill
    -- below is the fallback, so a garbled file costs nothing.
    if wp:match("^%d+$") then os.execute("kill " .. wp .. " 2>/dev/null") end
    os.execute("pkill -f 'spoot.*--recent-watch' 2>/dev/null")
    os.remove("/tmp/spoot_recent.pid")
end

function Util.kill_playerctl_follow()
    os.execute("pkill -f 'playerctl[ -]--follow metadata' 2>/dev/null")
end

local function check_rate_cooldown()
    local rate_cool = read_file("/tmp/spoot_rate_cooldown")
    if rate_cool then
        local until_t = tonumber(trim(rate_cool))
        if until_t and os.time() < until_t then
            local secs = until_t - os.time()
            rofi_message("Spotify API rate limit active.\nRetry after " .. secs .. "s.")
            return true
        end
        os.remove("/tmp/spoot_rate_cooldown")
    end
    return false
end

-- PLAYBACK state only. Runs on a cold start (the MPRIS daemon wasn't alive),
-- where the now-playing caches really are stale. It must NOT touch P.session:
-- where you were in the menus has nothing to do with whether the daemon
-- survived, and clearing it here is what made menu retention look random --
-- it worked while the daemon happened to be up, and silently reset after a
-- reboot, a crash, or Restart/Kill Daemons.
local function clear_last_playback()
    os.execute("playerctl pause 2>/dev/null")
    os.remove(P.now); os.remove(P.now_track)
    current_track = nil; current_id = nil; previous_id = nil
    is_playing = false; last_playback = 0
end

local function init_library(cold_start)
    ensure_spotifyd_auth()
    ensure_auth()
    ensure_spotifyd()
    load_queue()
    if cold_start then clear_last_playback() end
    (function()
        local raw = read_file(P.state)
        if raw then local d = safe_decode(raw)
            if d then
                if d.repeat_state then repeat_state = d.repeat_state end
                if d.shuffle ~= nil then is_shuffle = d.shuffle end
            end
        end
    end)()
    -- Missing and stale were two branches with byte-identical bodies. cache_stale
    -- is still only reached when all three files exist, so a missing cache never
    -- pays for its tail reads.
    if not (cache_exists(P.liked) and cache_exists(P.albums) and cache_exists(P.artists))
       or cache_stale(P.liked) or cache_stale(P.albums) or cache_stale(P.artists) then
        os.execute("notify-send -t 5000 --app-name=spoot 'spoot' 'Building Cache' &")
        local tracks, albums, artists = fetch_library_with_fallback()
        save_library_cache(tracks, albums, artists)
        os.execute("notify-send -t 3000 --app-name=spoot 'spoot' 'Caching Complete' &")
    end
    populate_liked_ids()
    -- Warm the playlist membership index out of band. Nothing waits on it: the
    -- action menu serves the last known index and picks up the new one next run.
    if not disk_get(P.pl_index, CACHE_TTL_SHORT) then
        os.execute("nohup lua " .. shell_quote(P.dir .. "/spoot.lua")
            .. " --prefetch-plindex > /dev/null 2>&1 &")
    end
    Util.trail_load()
    session_load()
    replay_session(true)
    last_playback = os.time()
end

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
        local mesg = function() return current_track and track_mesg(current_track) or nil end

        local entries = {}
        local function add(v) if v then entries[#entries+1] = v end end
        add("Playback")
        add("Your Queue"); add("Liked Tracks"); add("Top Tracks"); add("Saved Albums")
        add("Followed Artists"); add("Playlists"); add("New Releases")
        add("Recently Played"); add("Categories"); add("Search")
        add("System")

        local sel = rofi_dmenu(entries, {prompt="Spotify", mesg=mesg, pos_key=main_key, custom=false, markup=true, no_status=not current_track})
        if sel then sel = sel:gsub("<[^>]+>", "") end

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

        if      sel == "Search" then
            local tp = {"All","Tracks","Albums","Artists","Playlists"}
            local p  = {"all","track","album","artist","playlist"}
            local st_key = "search-type:"
            local si = rofi_dmenu(tp, {prompt="Search", mesg="Search", custom=false, by_index=true, use_menu=true, theme=THEME_SUB, no_status=true, pos_key=st_key, crumb="Search", markup=true})
            if si and si >= 1 and si <= #tp then
                local cat = p[si]:lower()
                view_search(cat)
            end
        elseif  sel == "Liked Tracks"     then view_liked_tracks()
        elseif  sel == "Saved Albums"     then view_saved_albums()
        elseif  sel == "Followed Artists" then view_followed_artists()
        elseif  sel == "Playlists"        then view_playlists()
        elseif  sel == "Categories"       then view_categories()
        elseif  sel == "Your Queue"       then view_your_queue()
        elseif  sel == "Top Tracks"       then view_top_tracks()
        elseif  sel == "New Releases"     then view_new_releases()
        elseif  sel == "Recently Played"  then view_recently_played()
        elseif  sel == "Playback"          then view_playback()
        elseif  sel == "System"        then view_system()
        end
        ::m1::
    end
end

-- DAEMON MODE — MPRIS listener for zero-API-call notifications

local function daemon_mode()
    local lock = "/tmp/spoot_daemon.pid"
    local claim = "/tmp/spoot_daemon.lock"
    local mypid = Util.get_own_pid()
    local claimed = trim(shell("mkdir " .. claim .. " 2>/dev/null && echo ok") or "") == "ok"
    if not claimed then
        local holder = tonumber((read_file(claim .. "/pid") or ""):match("(%d+)"))
        local holder_alive = holder and holder ~= mypid
            and trim(shell("kill -0 " .. holder .. " 2>/dev/null && echo alive") or "") == "alive"
            and (trim(shell("cat /proc/" .. holder .. "/cmdline 2>/dev/null") or "")):find("spoot")
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
    if prev_pid and prev_pid > 0 and prev_pid ~= mypid then
        local cmdline = trim(shell("cat /proc/" .. prev_pid .. "/cmdline 2>/dev/null") or "")
        if cmdline:find("spoot") then
            os.execute("kill " .. prev_pid .. " 2>/dev/null; sleep 0.1")
        end
    end
    if mypid then Util.secure_write(lock, tostring(mypid)) end
    Util.kill_playerctl_follow()

    local NOTIFY_FILE = "/tmp/spoot_last_notify"
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
        track_id = Util.extract_track_id(track_id)
        local duration = tonumber(duration_raw) and tonumber(duration_raw) / 1000000 or nil
        local track_changed = track_id and #track_id > 0 and track_id ~= last_track_id
        local title_changed = title and title ~= "" and title ~= last_title
        if not track_changed and not title_changed then return end
        if track_id and #track_id > 0 then
            write_file(P.now, json.encode({ id=track_id, name=title,
                artists={{name=artist or ""}}, album={name=album or ""},
                duration_ms=math.floor((duration or 0) * 1000),
                playing=trim(shell("playerctl status 2>/dev/null")) == "Playing" }))
            last_track_id = track_id
        end
        if title and title ~= "" then last_title = title end
        -- One helper instead of three spawns plus an inline notify. The old
        -- order was self-defeating: --prefetch-track and --prefetch-lyrics were
        -- launched here and the notification was composed two statements later,
        -- reading the very caches those processes had not written yet -- so a
        -- track's first play always lost its explicit and lyrics glyphs, and the
        -- dedupe above meant they were never filled in afterwards. The helper
        -- fetches first and notifies last, off this loop so nothing blocks the
        -- playerctl --follow stream.
        if title and #trim(title) > 0 and not notify_seen(track_id) then
            os.execute("nohup lua " .. shell_quote(P.dir .. "/spoot.lua")
                .. " --notify " .. shell_quote(track_id or "")
                .. " " .. shell_quote(title)
                .. " " .. shell_quote(artist or "")
                .. " " .. shell_quote(album or "")
                .. " " .. shell_quote(duration and tostring(math.floor(duration)) or "")
                .. " " .. shell_quote(art_url or "")
                .. " > /dev/null 2>&1 &")
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
    if mypid then Util.secure_write("/tmp/spoot_recent.pid", tostring(mypid)) end
    local last_id = nil
    local nil_strikes = 0
    local function poll()
        local d = api_get("me/player", Util.with_market())
        if not d or type(d) ~= "table" or not d.item or not d.item.id then
            nil_strikes = nil_strikes + 1
            return
        end
        nil_strikes = 0
        local id = d.item.id
        if id ~= last_id then
            record_recent_play(d.item)
            last_id = id
        end
    end
    while true do
        local cooldown = tonumber((read_file("/tmp/spoot_rate_cooldown") or ""):match("%d+"))
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
    if not title or #trim(title) == 0 then os.exit(0) end

    -- Off the follow loop now, so the full retry budget is affordable.
    local art_path = ""
    if art_url then art_path = ensure_art(Util.art_url(art_url, "1e02")) or "" end

    local track
    if id and id:match("^[A-Za-z0-9]+$") then
        -- Market + collapse, like every other track source: without it this
        -- writer left 183 available_markets entries in now_track.json -- ~a third
        -- of a file fast_now_track reads and decodes on nearly every menu entry.
        track = api_get("tracks/" .. id, Util.with_market())
        if track then
            Util.mark_availability(track)
            -- `playing` is written here as well; run_prefetch_track omitted it
            -- while get_playback includes it, which left fast_now_track reading
            -- transport state from the daemon's one-shot snapshot instead.
            write_file(P.now_track, json.encode({
                item = track,
                playing = trim(shell("playerctl status 2>/dev/null")) == "Playing",
            }))
        end
        Util.fetch_and_cache_lyrics(id, title, artist or "", album, duration)
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
        Util.mark_availability(track)
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

-- The tail of a thumbnail grid, handed over by Util.spawn_art_prefetch as a
-- url<TAB>path list. Consumed and removed immediately so a crash here cannot
-- leave the file behind.
function Util.run_prefetch_art_batch()
    Util.detached = true
    local lf = arg[2]
    if not lf or #lf == 0 then os.exit(0) end
    local raw = read_file(lf)
    os.remove(lf)
    if not raw then os.exit(0) end
    local list = {}
    for url, path in raw:gmatch("([^\t\n]+)\t([^\t\n]+)") do
        list[#list+1] = {url = url, path = path}
    end
    if #list > 0 then ensure_cache(); Util._art_batch(list) end
    os.exit(0)
end

-- ── Backspace monitor ─────────────────────────────────────────────────
-- Plain Backspace is ambiguous: rofi edits the filter natively, but when
-- the filter is already empty a Backspace press is swallowed by rofi's
-- keyboard grab. This daemon-level monitor watches the keyboard at the
-- evdev layer (Wayland) and, while the filter is known to be empty,
-- re-injects the internal "back one level" combo (Control+Shift+Delete =
-- kb-custom-1) through its own uinput virtual keyboard.
--
-- Note: the combo deliberately does NOT include Backspace. spbsd injects
-- on the very Backspace keydown the user is still physically holding, and
-- compositors dedupe a second press of an already-held keycode, so a
-- fresh key (Delete) is used instead.
--
--   * Util.BS_C_SOURCE / Util.bs_compile  tiny C helper ("spbsd"): passive
--     evdev reader that forwards every EV_KEY event as "K <code> <val>"
--     lines on the ev.fifo, and injects the combo through uinput on demand
--     when told to via the cmd.fifo (Wayland only, no wtype needed).
--   * Util.bsmon_mode (--bsmon)           background Lua process holding a
--     shadow of rofi's filter string (per-key word class, "w"/"s") from the
--     forwarded key stream, so Ctrl+BackSpace word-deletes mirror rofi's
--     textbox_cursor_dec_word exactly; when a plain Backspace keydown
--     arrives with the shadow already empty it tells spbsd to inject
--     Control+Shift+Delete.
--   * Util.bs_start/bs_launch/bs_stop      lifecycle glue: started on the
--     first interactive menu, reused by every later one, torn down once in
--     Util.clean_exit. Spawn is fully async, so
--     menus open instantly; a BackSpace pressed in the first instant of a
--     brand-new menu (before spbsd reports READY) may be missed.

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
    local run = "/tmp/spoot_bs_" .. pid .. "_" .. tostring(math.random(10000, 99999))
    os.execute("mkdir -p " .. shell_quote(run))
    local evf = run .. "/ev.fifo"
    local cmdf = run .. "/cmd.fifo"
    os.execute("mkfifo " .. shell_quote(evf) .. " " .. shell_quote(cmdf) .. " 2>/dev/null")
    -- Written before the monitor starts so it can never see a missing control
    -- file and mistake that for "the app exited".
    Util._bs_gen = 1
    write_file(run .. "/gen", "1 " .. (clear_bs and "1" or "0"))
    local cmd = string.format("nohup lua %s --bsmon %s %s > %s 2>&1 &",
        shell_quote(P.dir .. "/spoot.lua"),
        shell_quote(run), clear_bs and "1" or "0",
        shell_quote(run .. "/bsmon.log"))
    os.execute(cmd)
    return { run = run, ev = evf, cmd = cmdf }
end

-- The monitor used to be spawned and killed around EVERY menu draw: a whole
-- lua interpreter re-parsing this 214KB file (~18ms) plus mkdir/mkfifo/pkill/
-- rm -rf (~8ms), on all 29 render sites. It now starts once per app run and is
-- reused; each draw only bumps a generation counter in a small control file.
--
-- That generation matters for correctness, not just theming: bsmon keeps two
-- pieces of per-menu state that previously reset only because the process was
-- thrown away -- its shadow copy of rofi's filter text, and `injected`, a
-- ONE-SHOT latch allowing a single back-injection per process. A persistent
-- monitor that ignored the generation would send "back" once and then look
-- dead for the rest of the session.
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
        if app_pid ~= "" then                    -- app died without cleaning up
            local alive = io.open("/proc/" .. app_pid .. "/stat", "r")
            if not alive then os.exit(0) end
            alive:close()
        end
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
elseif arg and arg[1] == "--prefetch-plindex" then
    Util.run_prefetch_plindex()
elseif arg and arg[1] == "--notify" then
    Util.run_notify()
elseif arg and arg[1] == "--bsmon" then
    Util.bsmon_mode()
elseif arg and arg[1] then
    os.exit(2)
else
    main()
end
end)()
