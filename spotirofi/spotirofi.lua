#!/usr/bin/lua

;(function()

-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

local P = {
    home      = os.getenv("HOME"),
    dir       = debug.getinfo(1, "S").source:match("^@(.*/)"),
    max       = 20,
    ttl       = 43200,
    spotify   = "d420a117a32841c2b3474932e49fb54b",
}
P.cache      = P.home .. "/.cache/spotirofi"
P.mass       = P.cache .. "/mass"
P.lyrics     = P.cache .. "/lyrics"
P.token      = P.cache .. "/token.json"
P.liked      = P.cache .. "/liked_tracks.json"
P.albums     = P.cache .. "/saved_albums.json"
P.artists    = P.cache .. "/followed_artists.json"
P.session    = P.cache .. "/session.json"
P.queue      = P.cache .. "/playback_queue.json"
P.art        = P.cache .. "/art"
P.liked_ids  = P.cache .. "/liked_ids.json"
P.volume     = P.cache .. "/volume.json"
P.recent     = P.cache .. "/recently_played.json"
P.bitrate    = P.cache .. "/bitrate"
P.state      = P.cache .. "/playback_state.json"
local EXIT = {
    back = 10, main = 11,
    open_url = 12, jump = 13, jump_kp = 14, liked = 15, queue = 16, volume = 17,
    track = 18, seek = 19, art = 20, repeat_toggle = 21, lyrics = 22,
    recent = 23, shuffle_toggle = 24,
}
local SEP = " \u{F01D8} "
local CACHE_TTL_SHORT = 300
local CACHE_TTL_MED = 3600
local CACHE_TTL_LONG = 86400
local PROGRESS_BAR_W = 20
local ICON_PREFIX = {
    tracks    = "\u{F0387} ",
    albums    = "\u{F0025} ",
    artists   = "\u{F415} ",
    playlists = "\u{F0411} ",
}
local liked = {}  -- set of liked track IDs

local current_track, current_id, previous_id, last_playback = nil, nil, nil, 0
local is_playing, is_shuffle, repeat_state = false, false, "off"
local _local_toggle_time = 0
local _action_theme_tmpl = nil
local _recovering = false

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

local function copy_to_clipboard(text)
    if os.getenv("WAYLAND_DISPLAY") then
        os.execute("echo " .. shell_quote(text) .. " | wl-copy 2>/dev/null")
    else
        os.execute("echo " .. shell_quote(text) .. " | xclip -selection clipboard 2>/dev/null")
    end
end

local function copy_spotify_url(kind, id) copy_to_clipboard("https://open.spotify.com/" .. kind .. "/" .. (id or "")) end

local function parse_spotify_url(url)
    if not url or url == "" then return nil, nil end
    url = url:match("^(.-)\n") or url
    url = url:gsub("[?#].*$", "")
    url = url:gsub("/+$", "")
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

local THEME, THEME_MENU, THEME_LYR, THEME_MSG, THEME_SUB, THEME_BINDS, THEME_ART = (function()
    os.execute("rm -f /tmp/spotirofi_theme_*.rasi 2>/dev/null")
    local function resolve(src, name)
        local content = read_file(src)
        if not content then return src end
        local resolved = content:gsub('@import "ZENON"', '@import "' .. P.dir .. '/style/ZENON"')
        if resolved == content then return src end
        local fixed = "/tmp/spotirofi_theme_" .. name .. ".rasi"
        local f = io.open(fixed, "w")
        if f then f:write(resolved); f:close(); return fixed end
        return src
    end
    local d = P.dir .. "/style"
    return resolve(d.."/main.rasi","main"), resolve(d.."/menu.rasi","menu"), resolve(d.."/lyrics.rasi","lyrics"),
           resolve(d.."/message.rasi","message"), resolve(d.."/sub.rasi","sub"), resolve(d.."/binds.rasi","binds"),
           resolve(d.."/art.rasi","art")
end)()

local _cache_ready = false
local function ensure_cache()
    if _cache_ready then return end
    os.execute("mkdir -p " .. shell_quote(P.cache) .. " " .. shell_quote(P.lyrics) .. " " .. shell_quote(P.mass) .. " " .. shell_quote(P.art))
    _cache_ready = true
end

local function write_file(p, d)
    ensure_cache()
    local t = p .. ".tmp"
    local f = io.open(t, "w")
    if not f then return false end
    f:write(d); f:close()
    return os.rename(t, p)
end

local function trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

local function strip_nulls(t)
    if type(t) ~= "table" then return t end
    local rm = {}
    for k, v in pairs(t) do
        if v == json.null then rm[#rm+1] = k
        elseif type(v) == "table" then t[k] = strip_nulls(v) end
    end
    for _, k in ipairs(rm) do t[k] = nil end
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
    if not d or type(d) ~= "table" or not d.fetched_at then return nil end
    if ttl and os.time() - d.fetched_at >= ttl then return nil end
    return d.data
end
local function disk_set(path, data)
    write_file(path, json.encode({data=data, fetched_at=os.time()}))
end
local function disk_bust(path) os.remove(path) end
local function bust_my_playlists()
    mem_bust("my_playlists")
    os.remove(P.cache .. "/my_playlists.json")
end
local function cache_exists(path)
    local f = io.open(path)
    if f then f:close(); return true end
    return false
end
local function cache_stale(path)
    local f = io.open(path, "r")
    if not f then return true end
    local head = f:read(256)
    local ts = head and tonumber(head:match('"fetched_at"%s*:%s*(%d+)'))
    if not ts then
        local ok = f:seek("end", -200)
        if not ok then f:close(); return true end
        local tail = f:read(200)
        ts = tail and tonumber(tail:match('"fetched_at"%s*:%s*(%d+)'))
    end
    f:close()
    return not ts or os.time() - ts >= P.ttl
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
        mem_set(key, v, ttl)
        if disk_path then disk_set(disk_path, v) end
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

local _session_stack = nil

local function session_load()
    local d = safe_decode(read_file(P.session))
    if d and type(d.stack) == "table" then
        _session_stack = d.stack
    else
        _session_stack = {}
    end
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

local function session_clear()
    _session_stack = {}
    os.remove(P.session)
end

-- ROFI

local main_pending    = false
local liked_pending, queue_pending, volume_pending = false, false, false
local seek_pending, jump_to_track_pending = false, false
local recent_pending = false
local shuffle_pending, repeat_pending = false, false
local function consume_pending_toggle()
    if shuffle_pending then shuffle_pending = false; return true end
    if repeat_pending then repeat_pending = false; return true end
    return false
end
local view_actions, view_artist, view_lyrics, view_add_pl, view_art
local browse_album, view_browse
local get_playback
local get_token
local display_track, rofi_message
local toggle_repeat, toggle_shuffle
local open_url

local function status_mesg()
    local DIM = "#6a707f"
    local r
    if repeat_state == "track" then r = '<span foreground="#fab387">\u{F0458}</span>'
    elseif repeat_state == "context" then r = "\u{F0456}"
    else r = '<span foreground="' .. DIM .. '">\u{F0457}</span>' end
    local s = is_shuffle and "\u{F074}" or '<span foreground="' .. DIM .. '">\u{F049D}</span>'
    return r .. "\u{2002}\u{2002}" .. s
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
    if main_pending or liked_pending or queue_pending or volume_pending or recent_pending then return nil end
    opts = opts or {}
    local prompt   = opts.prompt or ""
    local mesg     = opts.mesg
    local markup   = opts.markup
    local by_index = opts.by_index
    local theme    = opts.theme or (opts.use_menu and THEME_MENU or THEME)
    local eh       = opts.eh
    local sel      = opts.sel

    if seek_pending or jump_to_track_pending then return nil end
    local args = {"rofi","-dmenu","-config",P.dir.."/style/config.rasi","-theme",theme,"-p",prompt,"-i",
                  "-kb-custom-1","Alt+BackSpace","-kb-custom-2","Alt+space",
                  "-kb-custom-3","Alt+g","-kb-custom-4","Alt+Return",
                  "-kb-custom-5","Alt+KP_Enter",
                  "-kb-custom-6","Alt+l",
                  "-kb-custom-7","Alt+q",
                  "-kb-custom-8","Alt+v",
                  "-kb-custom-9","Alt+c",
                  "-kb-custom-10","Alt+e",
                  "-kb-custom-11","Alt+a",
                  "-kb-custom-12","Alt+r",
                  "-kb-custom-13","Alt+y",
                  "-kb-custom-14","Alt+p",
                  "-kb-custom-15","Alt+s"}
    if opts.custom == false then args[#args+1] = "-no-custom" end
    if markup then args[#args+1] = "-markup-rows"; args[#args+1] = "-markup" end
    if by_index then args[#args+1] = "-format"; args[#args+1] = "i" end
    if eh then args[#args+1] = "-eh"; args[#args+1] = tostring(eh) end
    if sel and sel > 0 then args[#args+1] = "-selected-row"; args[#args+1] = tostring(sel) end
    if not opts.no_status then
        local status = status_mesg()
        if status then mesg = mesg and (status .. "  " .. mesg) or status end
    end
    if mesg then args[#args+1] = "-mesg"; args[#args+1] = mesg end

    local entry_tf = os.tmpname()
    local f = io.open(entry_tf, "w")
    if not f then os.remove(entry_tf); return nil end
    for _, e in ipairs(entries or {}) do f:write(e, "\n") end
    f:close()

    local qa = {}
    for _, a in ipairs(args) do qa[#qa+1] = shell_quote(a) end
    local out_tf = os.tmpname()
    local cmd = table.concat(qa, " ") .. " < " .. shell_quote(entry_tf)
             .. " > " .. shell_quote(out_tf)
             .. " 2>/dev/null; printf '\\n__EXIT__%d__' $? >> " .. shell_quote(out_tf)
    os.execute(cmd)
    local raw = read_file(out_tf)
    os.remove(entry_tf)
    os.remove(out_tf)

    local exit_code = tonumber((raw or ""):match("__EXIT__(%d+)__")) or 0
    local result    = trim((raw or ""):match("^(.-)\n__EXIT__%d+__") or "")

    if exit_code == EXIT.back then session_pop(); return nil end
    if exit_code == EXIT.main then session_clear(); main_pending = true; return nil end
    if exit_code == EXIT.liked then session_clear(); liked_pending = true; return nil end
    if exit_code == EXIT.queue then session_clear(); queue_pending = true; return nil end
    if exit_code == EXIT.volume then session_clear(); volume_pending = true; return nil end
    if exit_code == EXIT.track then jump_to_track_pending = true; return nil end
    if exit_code == EXIT.seek then
        if current_track then seek_pending = true; return nil
        else rofi_message("No track playing"); return nil end
    end
    if exit_code == EXIT.art then
        if current_track then view_art(current_track)
        else rofi_message("No track playing") end
        return nil
    elseif exit_code == EXIT.recent then session_pop(); recent_pending = true; return nil
    elseif exit_code == EXIT.lyrics then
        last_playback = 0
        get_playback()
        if current_track then view_lyrics(current_track)
        else rofi_message("No track playing") end
        return nil
    elseif exit_code == EXIT.jump or exit_code == EXIT.jump_kp then
        last_playback = 0
        get_playback()
        if current_track then view_actions(current_track, "track")
        else rofi_message("No track playing") end
        return nil
    elseif exit_code == EXIT.repeat_toggle then toggle_repeat(); repeat_pending = true; return nil
    elseif exit_code == EXIT.shuffle_toggle then toggle_shuffle(); shuffle_pending = true; return nil
    elseif exit_code == EXIT.open_url then
        local ok, err = pcall(function()
            local url = trim(shell("wl-paste 2>/dev/null") or "")
            if url and url ~= "" then open_url(url)
            else rofi_message("Clipboard is empty") end
        end)
        if not ok then rofi_message("open_url error: " .. tostring(err)) end
        session_pop()
        return nil
    else
        if result == "" then os.exit(0) end
        if by_index then
            local n = tonumber(result)
            if not n or n < 0 then return nil end
            return n + 1
        end
        return result
    end
end

rofi_message = function(msg, theme)
    local tf = os.tmpname()
    os.execute("rofi -e " .. shell_quote(msg) .. " -config " .. shell_quote(P.dir.."/style/config.rasi") .. " -theme " .. shell_quote(theme or THEME_MSG) .. " -markup 2>/dev/null; printf '\\n__EXIT__%d__' $? >> " .. shell_quote(tf))
    local raw = read_file(tf)
    os.remove(tf)
    local ec = tonumber((raw or ""):match("__EXIT__(%d+)__")) or 1
    return ec == 0
end

local function rofi_input(prompt, preset)
    local in_tf  = os.tmpname()
    local out_tf = os.tmpname()
    local f = io.open(in_tf, "w")
    if f then f:write(preset or ""); f:close() end
    os.execute("rofi -dmenu -config " .. shell_quote(P.dir.."/style/config.rasi") .. " -p " .. shell_quote(prompt)
        .. " -theme " .. shell_quote(THEME_MENU)
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
                    local ttl = math.max(data.expires_at - os.time() - 120, 60)
                    mem_set("token", data.access_token, ttl)
                    return data.access_token
                end
            end
            return data.access_token
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
        .. "if($x){open(F,\">\",\"/tmp/spotirofi_code\");print F $x;close(F)}"
        .. "print $c \"HTTP/1.1 200 OK\\r\\n\\r\\nok\";close $c;close $s'"
    os.execute(srv .. " & echo $! > /tmp/spotirofi_oauth_pid")
    os.execute("xdg-open " .. shell_quote(auth_url) .. " 2>/dev/null &")

    local function kill_oauth_server()
        local pid = trim(read_file("/tmp/spotirofi_oauth_pid") or "")
        if pid ~= "" and pid:match("^%d+$") then os.execute("kill " .. pid .. " 2>/dev/null") end
        os.remove("/tmp/spotirofi_oauth_pid")
    end

    local attempts = 0
    while true do
        local code = trim(read_file("/tmp/spotirofi_code") or "")
        if #code > 0 then
            os.remove("/tmp/spotirofi_code")
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
            os.remove("/tmp/spotirofi_code")
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

local function ensure_art(art_url)
    if not art_url or #art_url == 0 then return nil end
    local hash = art_url:match("/image/([%w]+)") or art_url:match("/([%w_%-]+)$")
    if not hash then return nil end
    ensure_cache()
    local art_path = P.art .. "/" .. hash .. ".jpg"
    local fh = io.open(art_path, "r")
    if fh then
        local size = fh:seek("end")
        fh:close()
        if size and size > 0 then return art_path end
        os.remove(art_path)
    end
    os.execute("curl -s --max-time 5 -o " .. shell_quote(art_path) .. " " .. shell_quote(art_url))
    fh = io.open(art_path, "r")
    if fh then
        local size = fh:seek("end")
        fh:close()
        if size and size > 0 then return art_path end
        os.remove(art_path)
    end
    return nil
end

-- SPOTIFYD MANAGEMENT

local function get_spotifyd_device()
    local cached = mem_get("spotifyd_device")
    if cached then return cached end
    local token = get_token()
    if not token then return nil end
    local d = safe_decode(shell("curl -s --max-time 3 -H " .. shell_quote("Authorization: Bearer " .. token) .. " 'https://api.spotify.com/v1/me/player/devices'"))
    if not d or not d.devices then return nil end
    local dev_id, dev_supports_vol = nil, false
    for _, dev in ipairs(d.devices) do
        if dev.name and dev.name:lower():find("spotirofi") then dev_id = dev.id; dev_supports_vol = dev.supports_volume; break end
    end
    if not dev_id then
        for _, dev in ipairs(d.devices) do
            if dev.is_active then dev_id = dev.id; dev_supports_vol = dev.supports_volume; break end
        end
    end
    if not dev_id and #d.devices > 0 then dev_id = d.devices[1].id; dev_supports_vol = d.devices[1].supports_volume end
    if dev_id then
        mem_set("spotifyd_device", dev_id, 120)
        mem_set("spotifyd_device_vol", dev_supports_vol, 120)
    end
    return dev_id
end

local SPOTIFYD_CREDS = P.home .. "/.cache/spotifyd/oauth/credentials.json"

local function ensure_spotifyd_auth()
    local f = io.open(SPOTIFYD_CREDS); if f then f:close(); return end
    os.execute("spotifyd authenticate")
end

local function ensure_spotifyd()
    local pid = trim(shell("pgrep -x spotifyd 2>/dev/null") or "")
    if pid == "" then
        os.execute("spotifyd --no-daemon --device-name spotirofi --backend pulseaudio --use-mpris --volume-normalisation --initial-volume " .. get_saved_volume() .. " --bitrate " .. get_saved_bitrate() .. " > /dev/null 2>&1 &")
        shell("for i in $(seq 1 15); do pgrep -x spotifyd >/dev/null 2>&1 && break; sleep 0.3; done")
    end
end

-- DATA CACHE

local function api_get(path, params, _retry)
    local token = get_token()
    if not token then return nil end
    local url = "https://api.spotify.com/v1/" .. path
    if params then url = url .. "?" .. params end
    local hdr = os.tmpname()
    local r = shell("curl -s --max-time 5 -D " .. shell_quote(hdr) .. " -w '\\n%{http_code}' -H " .. shell_quote("Authorization: Bearer " .. token) .. " " .. shell_quote(url))
    local status = tonumber(string.match(r or "", "\n(%d+)\n?$")) or 0
    local body = string.match(r or "", "^(.-)\n%d+\n?$") or r or ""
    if status == 429 then
        local hf = io.open(hdr, "r")
        local headers = hf and hf:read("*a") or ""
        if hf then hf:close() end
        local secs = string.match(headers, "[Rr]etry%-[Aa]fter:%s*(%d+)") or "30"
        os.remove(hdr)
        write_file("/tmp/spotirofi_rate_cooldown", os.time() + tonumber(secs) + 30)
        rofi_message("Spotify API rate limit reached (429). Retry after " .. secs .. "s.")
        return nil
    end
    os.remove(hdr)
    if status == 401 then
        rofi_message("Spotify token expired (401). Restart rofi to refresh.")
        return nil
    end
    if status >= 500 and not _retry then
        os.execute("sleep 1")
        return api_get(path, params, true)
    end
    if status >= 400 then return nil end
    return safe_decode(body)
end

local liked_by_artist_id = nil

local function get_liked_by_artist(artist_id)
    if not liked_by_artist_id then return {} end
    return liked_by_artist_id[artist_id] or {}
end

local function load_liked_tracks_full()
    local tracks = {}
    local token = get_token()
    if not token then return tracks end
    local offset = 0
    while true do
        local d = api_get("me/tracks", "limit=50&offset=" .. offset)
        if not d or not d.items or #d.items == 0 then break end
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
        curl_cmd(base .. "me/tracks?limit=50&offset=0", tmpdir .. "/lk_0.json"),
        curl_cmd(base .. "me/albums?limit=50&offset=0", tmpdir .. "/al_0.json"),
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
        lk_cmds[#lk_cmds+1] = curl_cmd(base .. "me/tracks?limit=50&offset=" .. (i * 50), tmpdir .. "/lk_" .. i .. ".json")
    end
    for i = 1, albums_pages - 1 do
        al_cmds[#al_cmds+1] = curl_cmd(base .. "me/albums?limit=50&offset=" .. (i * 50), tmpdir .. "/al_" .. i .. ".json")
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
            os.execute(curl_cmd(base .. "me/tracks?limit=50&offset=" .. (i * 50), f))
        end
    end
    for i = 1, albums_pages - 1 do
        local f = tmpdir .. "/al_" .. i .. ".json"
        if not page_valid(f) then
            os.execute("sleep 1")
            os.execute(curl_cmd(base .. "me/albums?limit=50&offset=" .. (i * 50), f))
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

    local ok_tracks = (#tracks > 0 and (tracks_total == 0 or #tracks >= tracks_total))
    local ok_albums = (#albums > 0 and (albums_total == 0 or #albums >= albums_total))
    local ok_artists = (#artists > 0)

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
    if cached then return cached end
    local c = safe_decode(read_file(P.albums))
    if c and c.items and type(c.items) == "table" and #c.items > 0 then
        if not c.fetched_at or os.time() - c.fetched_at < P.ttl then
            mem_set("saved_albums", c.items, P.ttl)
            return c.items
        end
    end
    local items = {}
    local offset = 0
    while true do
        local d = api_get("me/albums", "limit=50&offset=" .. offset)
        if not d or not d.items or #d.items == 0 then break end
        for _, e in ipairs(d.items) do
            if e.album then items[#items+1] = e.album end
        end
        if #d.items < 50 then break end
        offset = offset + 50
    end
    table.sort(items, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    if #items > 0 then
        write_file(P.albums, json.encode({fetched_at=os.time(), items=items}))
    end
    mem_set("saved_albums", items, P.ttl)
    return items
end

local function load_followed_artists()
    local cached = mem_get("followed_artists")
    if cached then return cached end
    local c = safe_decode(read_file(P.artists))
    if c and c.items and type(c.items) == "table" and #c.items > 0 then
        if not c.fetched_at or os.time() - c.fetched_at < P.ttl then
            mem_set("followed_artists", c.items, P.ttl)
            return c.items
        end
    end
    local items = {}
    local after = nil
    while true do
        local p = "type=artist&limit=50"
        if after then p = p .. "&after=" .. after end
        local d = api_get("me/following", p)
        if not d or not d.artists or not d.artists.items or #d.artists.items == 0 then break end
        for _, a in ipairs(d.artists.items) do items[#items+1] = a end
        if not d.artists.next then break end
        after = d.artists.cursors and d.artists.cursors.after
    end
    table.sort(items, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    if #items > 0 then
        write_file(P.artists, json.encode({fetched_at=os.time(), items=items}))
    end
    mem_set("followed_artists", items, P.ttl)
    return items
end

local function fetch_library_with_fallback()
    local tracks, albums, artists = parallel_fetch_library()
    if not tracks or #tracks == 0 then tracks = load_liked_tracks_full() end
    if not albums or #albums == 0 then albums = load_saved_albums() end
    if not artists or #artists == 0 then artists = load_followed_artists() end
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

local function save_library_cache(tracks, albums, artists)
    if tracks then
        mem_set("liked_tracks", tracks, P.ttl)
        build_liked_artist_index(tracks)
        if #tracks > 0 then
            write_file(P.liked, json.encode({fetched_at=os.time(), tracks=tracks}))
            local ids = {}
            for _, t in ipairs(tracks) do if t.id then ids[#ids+1] = t.id end end
            write_file(P.liked_ids, json.encode(ids))
        end
    end
    if albums then
        mem_set("saved_albums", albums, P.ttl)
        if #albums > 0 then
            write_file(P.albums, json.encode({fetched_at=os.time(), items=albums}))
        end
    end
    if artists then
        mem_set("followed_artists", artists, P.ttl)
        if #artists > 0 then
            write_file(P.artists, json.encode({fetched_at=os.time(), items=artists}))
        end
    end
end

local function load_liked_tracks()
    local cached = mem_get("liked_tracks")
    if cached then
        if not liked_by_artist_id then build_liked_artist_index(cached) end
        return cached
    end
    local c = safe_decode(read_file(P.liked))
    if c and c.tracks and type(c.tracks) == "table" and #c.tracks > 0 then
        if not c.fetched_at or os.time() - c.fetched_at < P.ttl then
            mem_set("liked_tracks", c.tracks, P.ttl)
            build_liked_artist_index(c.tracks)
            return c.tracks
        end
    end
    local tracks = load_liked_tracks_full()
    if #tracks > 0 then
        write_file(P.liked, json.encode({fetched_at=os.time(), tracks=tracks}))
        local ids = {}
        for _, t in ipairs(tracks) do if t.id then ids[#ids+1] = t.id end end
        write_file(P.liked_ids, json.encode(ids))
    end
    mem_set("liked_tracks", tracks, P.ttl)
    build_liked_artist_index(tracks)
    return tracks
end

-- PLAYBACK STATE

local inv_playback  -- forward declaration

get_playback = function()
    if os.time() - last_playback < 5 then return end
    last_playback = os.time()
    local d = api_get("me/player")
    if not d or not d.item then
        if not _recovering and queue_tracks and #queue_tracks > 0 then
            _recovering = true
            local ok = recover_playback(0, true)
            _recovering = false
            if ok then return end
        end
        inv_playback()
        return
    end
    current_track = d.item
    current_id    = d.item.id
    is_playing    = d.is_playing == true
    if os.time() - _local_toggle_time > 5 then
        is_shuffle    = d.shuffle_state == true
        repeat_state  = d.repeat_state or "off"
        write_file(P.state, json.encode({repeat_state=repeat_state, shuffle=is_shuffle}))
    end
end

inv_playback = function()
    current_track = nil; current_id = nil; is_playing = false
end

open_url = function(url)
    local kind, id = parse_spotify_url(url)
    if not kind then rofi_message("Not a valid Spotify URL"); return end
    if kind == "track" then
        local d = api_get("tracks/" .. id)
        if d then view_actions(d, "track")
        else rofi_message("Track not found") end
    elseif kind == "album" then
        local d = api_get("albums/" .. id)
        if d then browse_album(id, (d.name or "Album") .. SEP .. artist_names(d))
        else rofi_message("Album not found") end
    elseif kind == "artist" then
        local d = api_get("artists/" .. id)
        if d then view_artist({id=d.id, name=d.name or "Artist"})
        else rofi_message("Artist not found") end
    elseif kind == "playlist" then
        local d = api_get("playlists/" .. id)
        if d then
            local tracks = api_get_playlist_tracks(id)
            if tracks and #tracks > 0 then
                session_push({view="playlist", playlist_id=id})
                local te = format_entries(tracks)
                view_browse(te, tracks, (d.name or "Playlist") .. SEP .. #tracks .. " tracks", "playlist", "playlist", id)
                session_pop()
                if seek_pending or jump_to_track_pending then return end
            else rofi_message("Playlist is empty") end
        else rofi_message("Playlist not found") end
    end
end

-- RECENTLY PLAYED

local recent_tracks = disk_get(P.recent) or {}
local _recent_dirty = false
local _recent_dirty_since = 0

local function record_recent_play(track)
    if not track or not track.id then return end
    for i = #recent_tracks, 1, -1 do
        if recent_tracks[i].id == track.id then
            table.remove(recent_tracks, i)
        end
    end
    table.insert(recent_tracks, 1, track)
    while #recent_tracks > 100 do
        table.remove(recent_tracks)
    end
    _recent_dirty = true
    _recent_dirty_since = os.time()
end

local function flush_recent_play()
    if not _recent_dirty then return end
    if os.time() - _recent_dirty_since < 5 then return end
    _recent_dirty = false
    disk_set(P.recent, recent_tracks)
end

-- DISPLAY HELPERS

display_track = function(item, hide_artist)
    local an = hide_artist and "" or artist_names(item)
    local p  = item.id == current_id and (is_playing and "\u{f04b} " or "\u{f04c} ") or ""
    local l  = liked[item.id] and "\u{f05d}  " or ""
    local e  = item.explicit and "\u{f071} " or ""
    local txt = p .. l .. e .. (item.name or "Unknown") .. (hide_artist and "" or SEP .. an)
    if item.id == current_id then txt = "<span foreground=\"#b6e0a4\">" .. txt .. "</span>" end
    return txt
end

local function display_album(item)
    return (item.name or "Unknown") .. SEP .. artist_names(item)
end

local function display_artist(item)
    return item.name or "Unknown"
end

local function display_playlist(item)
    local prefix = (item.owner and item.owner.id == "spotify") and "\u{f1bc}  " or ""
    return prefix .. (item.name or "Unknown")
end

local _fmt_cache_entries = nil
local _fmt_cache_tracks  = nil
local _fmt_cache_key     = nil

local function format_entries(tracks, hide_artist)
    local key = (current_id or "") .. tostring(is_playing) .. tostring(hide_artist)
    if _fmt_cache_tracks == tracks and _fmt_cache_key == key then
        return _fmt_cache_entries
    end
    local entries = {}
    for i, t in ipairs(tracks) do entries[i] = string.format("%2d. %s", i, display_track(t, hide_artist)) end
    _fmt_cache_entries = entries
    _fmt_cache_tracks  = tracks
    _fmt_cache_key     = key
    return entries
end

local function view_recently_played()
    local tracks = recent_tracks
    if #tracks == 0 then rofi_message("No recently played tracks"); return end
    session_push({view="recently-played"})
    local entries = format_entries(tracks)
    view_browse(entries, tracks, "Recently Played" .. SEP .. #tracks .. " tracks", "recently-played", nil, nil)
    session_pop()
    if seek_pending or jump_to_track_pending then return end
end

local function bust_format_cache()
    _fmt_cache_entries = nil
    _fmt_cache_tracks  = nil
    _fmt_cache_key     = nil
end

local function get_playerctl_position()
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

local function track_mesg(item)
    local p = item.id == current_id and (is_playing and "\u{f04b}  " or "\u{f04c}  ") or ""
    local l = liked[item.id] and "\u{f05d} " or ""
    local e = item.explicit and " \u{f071}" or ""
    return p .. (item.name or "") .. SEP .. artist_names(item) .. "  " .. l .. e
end

local function progress_bar(pct)
    local filled = math.floor(math.max(0, math.min(pct, 1)) * PROGRESS_BAR_W + 0.5)
    return string.rep("\u{2588}", filled) .. string.rep("\u{2591}", PROGRESS_BAR_W - filled)
end

local function seek_mesg(item)
    local row1 = track_mesg(item)
    local pos = math.max(get_playerctl_position(), 0)
    local dur = (item.duration_ms or 0) / 1000
    if dur <= 0 then return row1 end
    local elapsed = string.format("%d:%02d", math.floor(pos / 60), math.floor(pos % 60))
    local total = string.format("%d:%02d", math.floor(dur / 60), math.floor(dur % 60))
    return row1 .. "\n" .. elapsed .. "  " .. progress_bar(pos / dur) .. "  " .. total
end

local function vol_mesg()
    local row1 = current_track and track_mesg(current_track) or "Volume"
    local vol = get_playerctl_volume()
    return row1 .. "\n" .. vol .. "%  " .. progress_bar(vol / 100) .. "  100%"
end

-- QUEUE

local queue_tracks  = nil
local queue_idx     = 0
local queue_context = nil

local function load_queue()
    local raw = read_file(P.queue)
    if not raw then return end
    local d = safe_decode(raw)
    if d then
        queue_tracks  = d.tracks
        queue_idx     = d.idx or 0
        queue_context = d.context or nil
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

local function do_play(item, ctx, ctx_type, ctx_id, all_items, idx)
    local context_uri
    if ctx_type and ctx_id then context_uri = "spotify:" .. ctx_type .. ":" .. ctx_id
    end

    if all_items and idx then save_queue(all_items, idx, context_uri) end
    local token = get_token()
    if not token then return end
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
        shell(string.format("curl -s --max-time 3 -o /dev/null -w '%%{http_code}' -X PUT 'https://api.spotify.com/v1/me/player/play%s' -H %s -H 'Content-Type: application/json' -d %s", dparam, shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
    end
end

local _liked_dirty = false

local function flush_liked_cache()
    if not _liked_dirty then return end
    _liked_dirty = false
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
        local d = api_get("me/tracks?ids=" .. table.concat(new_ids, ","))
        if d and d.tracks then
            for _, t in ipairs(d.tracks) do
                if t then tracks[#tracks + 1] = t end
            end
        end
    end
    write_file(P.liked, json.encode({fetched_at=os.time(), tracks=tracks}))
    local ids = {}
    for _, t in ipairs(tracks) do if t.id then ids[#ids+1] = t.id end end
    write_file(P.liked_ids, json.encode(ids))
    build_liked_artist_index(tracks)
    bust_format_cache()
end

local function do_like(item, unlike)
    local token = get_token()
    if not token then rofi_message("Cannot like: no token"); return false end
    local verb = unlike and "DELETE" or "PUT"
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -o /dev/null -X %s 'https://api.spotify.com/v1/me/tracks?ids=%s' -H %s", verb, item.id, shell_quote("Authorization: Bearer " .. token)))
    if not r or not r:match("2..") then
        rofi_message(unlike and "Failed to unlike" or "Failed to like")
        return false
    end
    if unlike then liked[item.id] = false else liked[item.id] = true end
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
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -o /dev/null -X %s 'https://api.spotify.com/v1/me/following?type=artist&ids=%s' -H %s -H 'Content-Length: 0'", verb, artist_id, shell_quote("Authorization: Bearer " .. token)))
    return r and r:match("2..")
end

local function do_add_queue(track_id)
    local token = get_token()
    if not token then rofi_message("Cannot add to queue: no token"); return end
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X POST 'https://api.spotify.com/v1/me/player/queue?uri=spotify:track:%s' -H %s -o /dev/null", track_id, shell_quote("Authorization: Bearer " .. token)))
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
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X PUT 'https://api.spotify.com/v1/me/albums?ids=%s' -H %s -o /dev/null", album_id, shell_quote("Authorization: Bearer " .. token)))
    if r and r:match("2..") then
        disk_bust(P.albums)
        return true
    end
    return false
end

local function do_save_playlist(playlist_id)
    local token = get_token()
    if not token then rofi_message("Cannot save playlist: no token"); return false end
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X PUT 'https://api.spotify.com/v1/playlists/%s/followers' -H %s -H 'Content-Length: 0' -o /dev/null", playlist_id, shell_quote("Authorization: Bearer " .. token)))
    if r and r:match("2..") then
        bust_my_playlists()
        return true
    end
    return false
end

local function do_playback_cmd(cmd)
    local token = get_token()
    if not token then return nil end
    local r = shell(string.format("curl -s --max-time 3 -o /dev/null -w '%%{http_code}' -X POST 'https://api.spotify.com/v1/me/player/%s' -H %s -H 'Content-Length: 0'", cmd, shell_quote("Authorization: Bearer " .. token)))
    if r and r:match("2..") then mem_bust("queue") end
    return r
end

local function recover_playback(direction, force)
    if not queue_tracks or #queue_tracks == 0 then return false end
    local new_idx = queue_idx + direction
    if new_idx < 1 then new_idx = 1 end
    if new_idx > #queue_tracks then new_idx = #queue_tracks end
    if not force and new_idx == queue_idx then return false end
    local token = get_token()
    if not token then return false end
    mem_bust("spotifyd_device")
    local device_id = get_spotifyd_device()
    local dparam = device_id and "?device_id=" .. device_id or ""
    local body
    if queue_context then
        body = json.encode({context_uri=queue_context, offset={position=new_idx-1}})
    else
        local uris = {}
        for i = new_idx, math.min(#queue_tracks, new_idx + 49) do
            uris[#uris+1] = "spotify:track:" .. queue_tracks[i]
        end
        if #uris > 0 then body = json.encode({uris=uris, offset={position=0}}) end
    end
    if not body then return false end
    local r = shell(string.format("curl -s --max-time 3 -o /dev/null -w '%%{http_code}' -X PUT 'https://api.spotify.com/v1/me/player/play%s' -H %s -H 'Content-Type: application/json' -d %s", dparam, shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
    if r and r:match("2..") then
        queue_idx = new_idx
        flush_queue()
        last_playback = 0; get_playback()
        return true
    end
    return false
end

-- API HELPERS

local function api_get_album(album_id)
    return cached_fetch("album_" .. album_id, P.mass .. "/album_" .. album_id .. ".json", CACHE_TTL_LONG, function()
        local d = api_get("albums/" .. album_id)
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
                if not page or not page.items or #page.items == 0 then break end
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

local function api_get_playlist_tracks(playlist_id)
    return cached_fetch("playlist_tracks_" .. playlist_id, P.mass .. "/playlist_tracks_" .. playlist_id .. ".json", 1800, function()
        local all_tracks = {}
        local offset = 0
        while true do
            local params = "limit=100&offset=" .. offset .. "&fields=items(track(id,name,duration_ms,artists,album(id,name,images)),added_at),next"
            local d = api_get("playlists/" .. playlist_id .. "/tracks", params)
            if not d or not d.items or #d.items == 0 then break end
            for _, entry in ipairs(d.items) do
                if entry.track and entry.track.id then
                    entry.track.added_at = entry.added_at
                    all_tracks[#all_tracks+1] = entry.track
                end
            end
            if not d.next or #d.items < 100 then break end
            offset = offset + 100
        end
        return #all_tracks > 0 and all_tracks or nil
    end)
end

local function api_search(query, stype)
    local mem_key = "search:" .. query .. ":" .. stype
    local cached = mem_get(mem_key)
    if cached then return cached end
    local d = api_get("search", "q=" .. url_encode(query) .. "&type=" .. stype .. "&limit=" .. P.max)
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

local function api_get_my_playlists()
    return cached_fetch("my_playlists", P.cache .. "/my_playlists.json", CACHE_TTL_SHORT, function()
        local all = {}
        local offset = 0
        while true do
            local d = api_get("me/playlists", "limit=50&offset=" .. offset)
            if not d or not d.items or #d.items == 0 then break end
            for _, pl in ipairs(d.items) do all[#all+1] = pl end
            if not d.next or #d.items < 50 then break end
            offset = offset + 50
        end
        return #all > 0 and all or nil
    end)
end

local function api_get_artist_albums(artist_id)
    return cached_fetch("artist_albums_" .. artist_id, P.mass .. "/artist_albums_" .. artist_id .. ".json", CACHE_TTL_LONG, function()
        return api_get("artists/" .. artist_id .. "/albums", "limit=50&include_groups=album,single,compilation")
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

local function api_get_recommendations(track_id)
    local d = api_get("recommendations", "seed_tracks=" .. track_id .. "&limit=20")
    return (d and d.tracks and #d.tracks > 0) and d.tracks or nil
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
            local d = api_get("me/top/tracks", "limit=50&time_range=" .. rng)
            return (d and d.items and #d.items > 0) and d.items
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
            text = text:match("^%s*(.-)%s*$")
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

local function api_get_lyrics(track_name, artist_name, album_name, duration)
    if not track_name or #track_name == 0 then return nil end
    local get_url = "https://lrclib.net/api/get?track_name=" .. url_encode(track_name)
    if artist_name and #artist_name > 0 then get_url = get_url .. "&artist_name=" .. url_encode(artist_name) end
    if album_name and #album_name > 0 then get_url = get_url .. "&album_name=" .. url_encode(album_name) end
    if duration and duration > 0 then get_url = get_url .. "&duration=" .. tostring(math.floor(duration)) end
    local r = trim(shell("curl -s --max-time 5 " .. shell_quote(get_url)))
    local d = safe_decode(r)
    if d then
        local synced = parse_lrc(d.syncedLyrics)
        if synced then return synced end
        if d.plainLyrics then
            local lines = lyrics_to_lines(d.plainLyrics)
            if lines then return {lines=lines} end
        end
    end

    local search_url = "https://lrclib.net/api/search?track_name=" .. url_encode(track_name)
    if artist_name and #artist_name > 0 then search_url = search_url .. "&artist_name=" .. url_encode(artist_name) end
    r = trim(shell("curl -s --max-time 5 " .. shell_quote(search_url)))
    d = safe_decode(r)
    if not d or #d == 0 then return nil end

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
    return best
end

-- VIEW: BROWSE

view_browse = function(entries, items, mesg, ctx, ctx_type, ctx_id)
    local is_track = ctx == "liked" or ctx == "top-tracks"
                  or ctx == "your-queue"
                  or ctx == "liked-by-artist" or ctx == "top-by-artist"
                  or ctx == "track" or ctx == "recommendations"
                  or ctx == "recently-played"
                  or (ctx_type and ctx_id)
    local is_album_list   = ctx == "album-list" or (ctx_type == "album" and not ctx_id) or ctx == "album" or ctx == "search-album"
    local is_artist_list  = ctx == "artist-list" or ctx == "artist"
    local is_playlist_list = (ctx_type == "playlist" and not ctx_id) or ctx == "search-playlist"
    local is_search_all   = ctx == "all"
    local is_search_ctx   = is_search_all or ctx:match("^search%-") or ctx == "track" or ctx == "artist"

    local pre_sel = 0
    while true do
        local idx = rofi_dmenu(entries, {prompt=ctx or "Browse", mesg=mesg, custom=false, by_index=true, markup=is_track, use_menu=true, sel=pre_sel, no_status=is_search_ctx})
        if jump_to_track_pending then
            jump_to_track_pending = false
            if current_id then
                pre_sel = 0
                for i = 1, #items do
                    if items[i].id == current_id then pre_sel = i - 1; break end
                end
            end
            goto br_next
        elseif seek_pending then return
        elseif not idx then if consume_pending_toggle() then goto br_next end; return
        elseif idx < 1 or idx > #items then goto br_next
        else
            local item = items[idx]

        if is_track then
            local unliked = view_actions(item, ctx, ctx_type, ctx_id, items, idx, entries)
            if seek_pending then return end
            if unliked and ctx == "liked" then
                table.remove(entries, idx)
                table.remove(items, idx)
                mesg = "Liked Tracks" .. SEP .. #items .. " tracks"
                if #items == 0 then return nil end
            else
                get_playback()
                entries = format_entries(items)
                pre_sel = idx - 1
            end
        elseif is_search_all then
            local st = item._stype
            if st == "tracks" then
                view_actions(item, ctx, ctx_type, ctx_id, items, idx, entries)
                if seek_pending then return end
                get_playback()
                entries = format_entries(items)
                pre_sel = idx - 1
            elseif st == "albums" then
                local action = rofi_dmenu({"Open Album", "Save Album", "Copy URL"}, {prompt=item.name or "Album", mesg=artist_names(item), custom=false, theme=THEME_SUB})
                if action == "Save Album" then
                    rofi_message(do_save_album(item.id) and "Album saved" or "Failed to save album")
                elseif action == "Copy URL" then
                    copy_spotify_url("album", item.id)
                    rofi_message("Copied URL")
                elseif action == "Open Album" then
                    if browse_album(item.id, (item.name or "Unknown") .. SEP .. artist_names(item)) then
                        if seek_pending then return end
                    else rofi_message("Failed to load album") end
                end
            elseif st == "artists" then
                view_artist(item)
                if seek_pending then return end
            elseif st == "playlists" then
                local action = rofi_dmenu({"Open Playlist", "Save Playlist", "Copy URL"}, {prompt=display_playlist(item), mesg=artist_names(item), custom=false, theme=THEME_SUB})
                if action == "Save Playlist" then
                    rofi_message(do_save_playlist(item.id) and "Playlist saved" or "Failed to save playlist")
                elseif action == "Copy URL" then
                    copy_spotify_url("playlist", item.id)
                    rofi_message("Copied URL")
                elseif action == "Open Playlist" then
                    local tracks = api_get_playlist_tracks(item.id)
                    if tracks and #tracks > 0 then
                        session_push({view="playlist", playlist_id=item.id})
                        local te = format_entries(tracks)
                        view_browse(te, tracks, (item.name or "Unknown") .. SEP .. #tracks .. " tracks", "playlist", "playlist", item.id)
                        session_pop()
                        if seek_pending then return end
                    else rofi_message("Failed to load playlist") end
                end
            end
            if st ~= "tracks" then
                local pf = ICON_PREFIX[st] or ""
                entries[idx] = string.format("%2d. %s", idx, pf .. (item.name or "Unknown"))
            end
        elseif is_album_list then
            local do_open = true
            if ctx == "search-album" then
                local action = rofi_dmenu({"Open Album", "Save Album", "Copy URL"}, {prompt=item.name or "Album", mesg=artist_names(item), custom=false, theme=THEME_SUB})
                if action == "Save Album" then
                    rofi_message(do_save_album(item.id) and "Album saved" or "Failed to save album")
                    do_open = false
                elseif action == "Copy URL" then
                    copy_spotify_url("album", item.id)
                    rofi_message("Copied URL")
                    do_open = false
                end
            elseif ctx == "album-list" then
                local action = rofi_dmenu({"Open Album", "Remove from Library", "Copy URL"}, {prompt=item.name or "Album", mesg=artist_names(item), custom=false, theme=THEME_SUB})
                if action == "Remove from Library" then
                    local token = get_token()
                    if token then
                        local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X DELETE 'https://api.spotify.com/v1/me/albums?ids=%s' -H %s -o /dev/null", item.id, shell_quote("Authorization: Bearer " .. token)))
                        if r and r:match("2..") then
                            disk_bust(P.albums)
                            rofi_message("Removed from library")
                            table.remove(entries, idx); table.remove(items, idx)
                            mesg = "Saved Albums" .. SEP .. #items .. " albums"
                            if #items == 0 then return end
                            goto br_next
                        else rofi_message("Failed to remove") end
                    end
                    do_open = false
                elseif action == "Copy URL" then
                    copy_spotify_url("album", item.id)
                    rofi_message("Copied URL")
                    do_open = false
                end
            end
            if do_open then
                if browse_album(item.id, (item.name or "Unknown") .. SEP .. artist_names(item)) then
                    if seek_pending then return end
                else rofi_message("Failed to load album") end
            end
        elseif is_artist_list then
            view_artist(item)
            if seek_pending then return end
            entries[idx] = display_artist(item)
        elseif is_playlist_list then
            local do_open = true
            local action = rofi_dmenu({"Open Playlist", "Save Playlist", "Copy URL"}, {prompt=display_playlist(item), mesg=artist_names(item), custom=false, theme=THEME_SUB})
            if action == "Save Playlist" then
                rofi_message(do_save_playlist(item.id) and "Playlist saved" or "Failed to save playlist")
                do_open = false
            elseif action == "Copy URL" then
                copy_spotify_url("playlist", item.id)
                rofi_message("Copied URL")
                do_open = false
            end
            if do_open then
                local tracks = api_get_playlist_tracks(item.id)
                if tracks and #tracks > 0 then
                    session_push({view="playlist", playlist_id=item.id})
                    local te = format_entries(tracks)
                    view_browse(te, tracks, (item.name or "Unknown") .. SEP .. #tracks .. " tracks", "playlist", "playlist", item.id)
                    session_pop()
                    if seek_pending then return end
                else rofi_message("Failed to load playlist") end
            end
        end end
        ::br_next::
    end
end

browse_album = function(album_id, mesg)
    local ad = api_get_album(album_id)
    if not ad or not ad.tracks or #ad.tracks == 0 then return false end
    session_push({view="album", album_id=album_id})
    local te = format_entries(ad.tracks, true)
    view_browse(te, ad.tracks, mesg, "album", "album", album_id)
    session_pop()
    if seek_pending or jump_to_track_pending then return end
    return true
end

-- VIEW: ALBUM ART

view_art = function(item)
    if not item or not item.album or not item.album.images or #item.album.images == 0 then
        rofi_message("No album art available"); return
    end
    local art_url = item.album.images[1].url
    local art_path = ensure_art(art_url)
    if not art_path then rofi_message("No album art available"); return end
    local mesg = (item.name or "Unknown") .. SEP .. artist_names(item)
    local entry_tf = os.tmpname()
    local ef = io.open(entry_tf, "w")
    if ef then
        ef:write("\0icon\x1f" .. art_path .. "\n")
        ef:close()
    end
    os.execute("rofi -dmenu -config " .. shell_quote(P.dir.."/style/config.rasi") .. " -theme " .. shell_quote(THEME_ART)
        .. " -mesg " .. shell_quote(mesg)
        .. " -markup-rows -no-custom"
        .. " < " .. shell_quote(entry_tf)
        .. " > /dev/null 2>/dev/null")
    os.remove(entry_tf)
end

-- VIEW: TRACK ACTIONS

local view_seek  -- forward declaration

view_actions = function(item, ctx, ctx_type, ctx_id, all_items, cidx, entries)
    session_push({view="action", track_id=item.id, track_name=item.name or "",
                  track_artists=item.artists or {}, track_album=item.album or {},
                  track_duration_ms=item.duration_ms or 0})
    local is_liked = liked[item.id]
    local in_pl    = ctx_type == "playlist" and ctx_id

    local play_label = item.id == current_id and (is_playing and "Pause" or "Resume") or "Play"
    local actions = {play_label}
    actions[#actions+1] = "Seek"
    actions[#actions+1] = "Add to Queue"
    local like_idx = #actions + 1
    actions[#actions+1] = is_liked and "Unlike" or "Like"
    actions[#actions+1] = "Go to Album"
    actions[#actions+1] = "Go to Artist"
    actions[#actions+1] = "Add to Playlist"
    if in_pl then actions[#actions+1] = "Remove from Playlist" end
    actions[#actions+1] = "Lyrics"
    actions[#actions+1] = "Copy URL"
    actions[#actions+1] = "More Like This"
    actions[#actions+1] = "Album Art"

    while true do
        local art_url = item.album and item.album.images and #item.album.images > 0
            and item.album.images[1].url or nil
        local art_path = ensure_art(art_url) or ""
        local tmp_theme = P.cache .. "/action_theme.rasi"
        local tf = io.open(tmp_theme, "w")
        if tf then
            if not _action_theme_tmpl then
                local raw = read_file(P.dir .. "/style/action.rasi") or ""
                _action_theme_tmpl = raw:gsub('@import "ZENON"', '@import "' .. P.dir .. '/style/ZENON"')
            end
            local rasi_content = _action_theme_tmpl:gsub("%%s", art_path)
            if art_path == "" then
                rasi_content = rasi_content:gsub("background%-image:%s*url%(\"\",%s*both%);", "")
            end
            tf:write(rasi_content)
            tf:close()
        end
        local action_theme = tmp_theme
        actions[2] = item.id == current_id and "Seek" or '<span color="#6a707f">Seek</span>'
        local sel = rofi_dmenu(actions,
            {prompt="Action", mesg=track_mesg(item), sel=0, custom=false, theme=action_theme, markup=true})
        if not sel then
            if seek_pending then
                seek_pending = false
                view_seek(item)
            elseif jump_to_track_pending then
                session_pop()
                if tmp_theme then os.remove(tmp_theme) end
                return
            elseif consume_pending_toggle() then
                -- continue loop
            else
                if tmp_theme then os.remove(tmp_theme) end
                return
            end
        end

        if sel == "Resume" then
            os.execute("playerctl play 2>/dev/null")
            is_playing = true
            actions[1] = "Pause"
        elseif sel == "Play" then
            do_play(item, ctx, ctx_type, ctx_id, all_items, cidx)
            current_track = item
            current_id = item.id
            is_playing = true
            last_playback = 0
            actions[1] = "Pause"
        elseif sel == "Pause" then
            os.execute("playerctl pause 2>/dev/null")
            is_playing = false
            actions[1] = "Resume"
        elseif sel == "Add to Queue" then do_add_queue(item.id)
        elseif sel == "Like" or sel == "Unlike" then
            if do_like(item, sel == "Unlike") then
                is_liked = not is_liked
                actions[like_idx] = is_liked and "Unlike" or "Like"
                if not is_liked then if tmp_theme then os.remove(tmp_theme) end; session_pop(); return true end
            end
        elseif sel == "Go to Album" then
            local album = item.album
            if album and album.id then
                local action = rofi_dmenu({"Open Album", "Save Album", "Copy URL"}, {prompt=album.name or "Album", mesg=(album.name or "Album") .. " - " .. artist_names(album), custom=false, theme=THEME_SUB})
                if action == "Save Album" then
                    rofi_message(do_save_album(album.id) and "Album saved" or "Failed to save album")
                elseif action == "Copy URL" then
                    copy_spotify_url("album", album.id)
                    rofi_message("Copied URL")
                elseif action == "Open Album" then
                    browse_album(album.id, album.name .. SEP .. artist_names(album))
                end
            end
        elseif sel == "Go to Artist" then
            if item.artists and #item.artists > 0 then view_artist(item.artists[1]) end
        elseif sel == "Add to Playlist" then view_add_pl(item.id)
        elseif sel == "Remove from Playlist" then
            local token = get_token()
            if token then
                local body = json.encode({tracks={{uri="spotify:track:" .. item.id}}})
                local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X DELETE 'https://api.spotify.com/v1/playlists/%s/tracks' -H %s -H 'Content-Type: application/json' -d %s -o /dev/null", ctx_id, shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
                if r and r:match("2..") then
                    disk_bust(P.mass .. "/playlist_tracks_" .. ctx_id .. ".json"); mem_bust("playlist_tracks_" .. ctx_id)
                    if entries and cidx then
                        table.remove(entries, cidx)
                        table.remove(all_items, cidx)
                    end
                    if tmp_theme then os.remove(tmp_theme) end
                    session_pop(); return
                end
            end
        elseif sel == "Lyrics" then view_lyrics(item)
        elseif sel == "Copy URL" then
            copy_spotify_url("track", item.id)
            rofi_message("Copied URL")
        elseif sel == "More Like This" then
            local tracks = api_get_recommendations(item.id)
            if not tracks then rofi_message("No recommendations found")
            else
                session_push({view="recommendations", track_id=item.id, track_name=item.name or ""})
                local te = format_entries(tracks)
                view_browse(te, tracks, "More Like " .. (item.name or ""), "recommendations", nil, nil)
                session_pop()
            end
        elseif sel == "Album Art" then view_art(item)
        elseif sel == "Seek" then
            view_seek(item)
        end
    end
end

-- SHARED HELPERS (used by both view functions and replay_session)

local function fetch_artist_albums(artist_id, artist_name)
    local d = api_get_artist_albums(artist_id)
    if not d or not d.items then return nil end
    local ae = {}
    for i, a in ipairs(d.items) do ae[i] = display_album(a) end
    return d.items, ae, (artist_name or "") .. SEP .. #d.items .. " albums"
end

local function fetch_liked_by_artist(artist_id, artist_name)
    load_liked_tracks()
    local tracks = get_liked_by_artist(artist_id)
    if #tracks == 0 then return nil end
    table.sort(tracks, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    local te = format_entries(tracks, true)
    return tracks, te, (artist_name or "") .. SEP .. #tracks .. " liked tracks"
end

local function fetch_artist_top_tracks(artist_id, artist_name)
    local d = api_get_artist_top_tracks(artist_id)
    if not d or not d.tracks or #d.tracks == 0 then return nil end
    local te = format_entries(d.tracks, true)
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
            local st = items[i]._stype
            local pfx = ICON_PREFIX[st] or ""
            local df = st == "tracks" and display_track or st == "albums" and display_album
                    or st == "artists" and display_artist or display_playlist
            entries[#entries+1] = string.format("%2d. %s", i, pfx .. df(items[i]))
        end
        return items, entries, n .. " results for " .. query, "all", nil
    else
        local key = category .. "s"
        local items = results[key]
        if not items or type(items) ~= "table" or #items == 0 then return nil end
        local n = math.min(#items, P.max); local entries = {}
        for i = 1, n do
            local df = category == "track" and display_track or category == "artist" and display_artist or category == "album" and display_album or display_playlist
            entries[#entries+1] = string.format("%2d. %s", i, df(items[i]))
        end
        local sctx = (category == "album" or category == "playlist") and "search-" .. category or category
        return items, entries, n .. " " .. key .. " for " .. query, sctx,
               (category == "album" and "album" or category == "playlist" and "playlist" or nil)
    end
end

-- VIEW: ARTIST ACTIONS

view_artist = function(artist)
    session_push({view="artist-actions", artist_id=artist.id, artist_name=artist.name or ""})
    local is_followed = api_check_following(artist.id)
    local actions = {"View All Albums", "View Liked Tracks", "View Top Tracks",
                     "Related Artists",
                     is_followed and "Unfollow Artist" or "Follow Artist",
                     "Copy URL"}

    while true do
        ::artist_next::
        local sel = rofi_dmenu(actions, {prompt=artist.name or "Artist", mesg=artist.name or "Artist", sel=0, custom=false, use_menu=true, theme=THEME_SUB})
        if not sel then
            if consume_pending_toggle() then goto artist_next end
            session_pop()
            if seek_pending or jump_to_track_pending then return end
            return
        end

        if sel == "View All Albums" then
            session_push({view="artist-albums", artist_id=artist.id, artist_name=artist.name or ""})
            local items, ae, mesg = fetch_artist_albums(artist.id, artist.name)
            if not items then session_pop(); rofi_message("No albums found")
            else
                while true do
                    ::alb_next::
                    local aidx = rofi_dmenu(ae, {prompt=artist.name, mesg=mesg, custom=false, by_index=true, use_menu=true})
                    if not aidx then if consume_pending_toggle() then goto alb_next end; session_pop(); if seek_pending or jump_to_track_pending then session_pop(); return end; break end
                    if aidx >= 1 and aidx <= #items then
                        local al = items[aidx]
                        local action = rofi_dmenu({"Open Album", "Save Album", "Copy URL"}, {prompt=al.name or "Album", mesg=artist_names(al), custom=false, theme=THEME_SUB})
                        if action == "Save Album" then
                            rofi_message(do_save_album(al.id) and "Album saved" or "Failed to save album")
                        elseif action == "Copy URL" then
                            copy_spotify_url("album", al.id)
                            rofi_message("Copied URL")
                        elseif action == "Open Album" then
                            if browse_album(al.id, (al.name or "Unknown") .. SEP .. artist_names(al)) then
                                if seek_pending then session_pop(); session_pop(); return end
                            end
                        end
                    end
                end
            end
        elseif sel == "View Liked Tracks" then
            session_push({view="liked-by-artist", artist_id=artist.id, artist_name=artist.name or ""})
            local tracks, te, mesg = fetch_liked_by_artist(artist.id, artist.name)
            if not tracks then session_pop(); rofi_message("No liked tracks by this artist")
            else
                view_browse(te, tracks, mesg, "liked-by-artist", nil, nil)
                session_pop()
                if seek_pending or jump_to_track_pending then session_pop(); return end
            end
        elseif sel == "View Top Tracks" then
            session_push({view="top-by-artist", artist_id=artist.id, artist_name=artist.name or ""})
            local tracks, te, mesg = fetch_artist_top_tracks(artist.id, artist.name)
            if not tracks then session_pop(); rofi_message("No top tracks found")
            else
                view_browse(te, tracks, mesg, "top-by-artist", nil, nil)
                session_pop()
                if seek_pending or jump_to_track_pending then session_pop(); return end
            end
        elseif sel == "Related Artists" then
            session_push({view="related", artist_id=artist.id, artist_name=artist.name or ""})
            local artists, ae, mesg = fetch_related_artists(artist.id, artist.name)
            if not artists then session_pop(); rofi_message("No related artists found")
            else
                while true do
                    ::rel_next::
                    local ridx = rofi_dmenu(ae, {prompt="Related to " .. artist.name, mesg=mesg, custom=false, by_index=true, use_menu=true})
                    if not ridx then if consume_pending_toggle() then goto rel_next end; session_pop(); if seek_pending or jump_to_track_pending then session_pop(); return end; break end
                    if ridx >= 1 and ridx <= #artists then
                        view_artist(artists[ridx])
                        if seek_pending then session_pop(); session_pop(); return end
                    end
                end
            end
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
end

-- VIEW: LYRICS (via lrclib.net)

view_lyrics = function(item)
    session_push({view="lyrics", track_id=item.id, track_name=item.name or "", track_artists=item.artists or {}})
    local id = item.id or ""
    local dur = item.duration_ms and item.duration_ms / 1000 or nil
    local alb = item.album and item.album.name or nil
    local data = cached_fetch("lyrics_" .. id, P.lyrics .. "/lyrics_" .. id .. ".json", nil, function()
        return api_get_lyrics(item.name, artist_names(item), alb, dur)
    end)

    local display_lines, timestamps
    if type(data) == "table" and data.lines then
        display_lines = data.lines
        timestamps = data.times
    elseif type(data) == "table" then
        display_lines = data
    end

    if not display_lines or #display_lines == 0 then session_pop(); rofi_message("No lyrics found"); return end

    local mesg_base = track_mesg(item)
    if timestamps then
        local pre_sel = 0
        while true do
            ::lr_next::
            local sel_line = rofi_dmenu(display_lines,
                {prompt="Lyrics", mesg=mesg_base .. "\n&gt; Search or select a line to jump to &lt;", custom=false,
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
            if not sel_line then if consume_pending_toggle() then goto lr_next end; break end
            local found_idx
            for i, l in ipairs(display_lines) do
                if l == sel_line then found_idx = i; break end
            end
            if found_idx and timestamps[found_idx] then
                local ts = timestamps[found_idx]
                local is_current = current_track and current_track.id == item.id
                if is_current then
                    os.execute("playerctl position " .. string.format("%.2f", ts) .. " 2>/dev/null")
                    if not is_playing then os.execute("playerctl play-pause &") end
                else
                    local token = get_token()
                    if token then
                        local device_id = get_spotifyd_device()
                        local dparam = device_id and "?device_id=" .. device_id or ""
                        local ms = math.floor(ts * 1000)
                        local body = json.encode({uris={"spotify:track:" .. item.id}, position_ms=ms})
                        shell(string.format("curl -s --max-time 3 -o /dev/null -X PUT 'https://api.spotify.com/v1/me/player/play%s' -H %s -H 'Content-Type: application/json' -d %s", dparam, shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
                        current_track = item
                        current_id = item.id
                        is_playing = true
                        last_playback = 0
                    end
                end
                local mins = math.floor(ts / 60)
                local secs = math.floor(ts % 60)
                os.execute("notify-send -t 2000 --app-name=spotirofi 'Spotirofi' 'Seeked to "
                    .. mins .. ":" .. string.format("%02d", secs) .. "' &")
                pre_sel = found_idx - 1
            end
        end
    else
        while true do
            ::lr_next_plain::
            rofi_dmenu(display_lines,
                {prompt="Lyrics", mesg=mesg_base, custom=false, use_menu=true, theme=THEME_LYR})
            if jump_to_track_pending then jump_to_track_pending = false; goto lr_next_plain end
            break
        end
    end
    session_pop()
    if seek_pending or jump_to_track_pending then return end
end

-- VIEW: ADD TO PLAYLIST

view_add_pl = function(track_id)
    session_push({view="add-to-playlist", track_id=track_id})
    local token = get_token()
    if not token then session_pop(); return end
    local items = api_get_my_playlists()
    if not items then session_pop(); return end
    local me = api_get_me()
    local my_id = me and me.id
    if not my_id then session_pop(); rofi_message("Cannot determine user ID"); return end

    local names = {"Create New Playlist"}
    local ids   = {"__create__"}
    for _, p in ipairs(items) do
        if p.owner and (p.owner.id == my_id or p.collaborative) then
            names[#names+1] = p.name; ids[#ids+1] = p.id
        end
    end

    local idx = rofi_dmenu(names, {prompt="Add to Playlist", mesg="Select a playlist", custom=false, by_index=true, use_menu=true})
    if not idx then
        session_pop()
        if seek_pending or jump_to_track_pending then return end
        return
    end

    local target_id
    if ids[idx] == "__create__" then
        local pl_name = rofi_input("New Playlist", "")
        if pl_name == "" then session_pop(); return end
        local r = shell(string.format("curl -s --max-time 5 -X POST 'https://api.spotify.com/v1/users/%s/playlists' -H %s -H 'Content-Type: application/json' -d %s", my_id, shell_quote("Authorization: Bearer " .. token), shell_quote(json.encode({name=pl_name}))))
        local cr = safe_decode(r)
        if not cr or not cr.id then session_pop(); rofi_message("Failed to create playlist"); return end
        target_id = cr.id
        bust_my_playlists()
    else
        target_id = ids[idx]
    end

    local body = json.encode({uris={"spotify:track:" .. track_id}})
    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X POST 'https://api.spotify.com/v1/playlists/%s/tracks' -H %s -H 'Content-Type: application/json' -d %s -o /dev/null", target_id, shell_quote("Authorization: Bearer " .. token), shell_quote(body)))
    if r and r:match("2..") then disk_bust(P.mass .. "/playlist_tracks_" .. target_id .. ".json"); mem_bust("playlist_tracks_" .. target_id) end
    rofi_message(r and r:match("2..") and "Added to playlist" or "Failed to add track")
    session_pop()
end

-- VIEW: PLAYLISTS

local function view_playlists()
    session_push({view="playlists"})
    local token = get_token()
    if not token then session_pop(); rofi_message("No auth"); return end
    local pls = api_get_my_playlists() or {}
    local entries = {"Create New Playlist"}
    for i, p in ipairs(pls) do entries[#entries+1] = display_playlist(p) end

    while true do
        ::pl_next::
        local idx = rofi_dmenu(entries, {prompt="Playlists", mesg="Playlists" .. SEP .. #pls, custom=false, by_index=true, use_menu=true})
        if not idx then
            if consume_pending_toggle() then goto pl_next end
            session_pop()
            if seek_pending or jump_to_track_pending then return end
            return
        end
        if idx == 1 then
            local pl_name = rofi_input("New Playlist", "")
            if pl_name == "" then goto pl_loop end
            local me = api_get_me()
            if me and me.id then
                local r = shell(string.format("curl -s --max-time 5 -X POST 'https://api.spotify.com/v1/users/%s/playlists' -H %s -H 'Content-Type: application/json' -d %s", me.id, shell_quote("Authorization: Bearer " .. token), shell_quote(json.encode({name=pl_name}))))
                local cr = safe_decode(r)
                if cr then pls[#pls+1] = cr; entries[#entries+1] = display_playlist(cr); bust_my_playlists()
                else rofi_message("Failed to create") end
            end
        elseif idx >= 2 and idx - 1 <= #pls then
            local pl = pls[idx - 1]
            session_push({view="playlist-actions", playlist_id=pl.id, playlist_name=pl.name or "Playlist"})
            local acts = {"Open Playlist", "Rename Playlist", "Delete Playlist", "Copy URL"}
            ::pl_act::
            local asel = rofi_dmenu(acts, {prompt=display_playlist(pl), mesg=display_playlist(pl), sel=0, custom=false, use_menu=true})
            if not asel then
                if consume_pending_toggle() then goto pl_act end
                if seek_pending or jump_to_track_pending then
                    session_pop()
                    session_pop()
                    return
                end
                session_pop()
                goto pl_loop
            end
            if asel == "Open Playlist" then
                local tracks = api_get_playlist_tracks(pl.id)
                if tracks then
                    session_push({view="playlist", playlist_id=pl.id})
                    local te = format_entries(tracks)
                    view_browse(te, tracks, (pl.name or "Playlist") .. SEP .. #tracks .. " tracks", "playlist", "playlist", pl.id)
                    session_pop()
                    if seek_pending or jump_to_track_pending then session_pop(); session_pop(); return end
                end
                goto pl_act
            elseif asel == "Rename Playlist" then
                local nn = rofi_input("New Name", pl.name or "")
                if nn == "" or nn == (pl.name or "") then goto pl_act end
                local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X PUT 'https://api.spotify.com/v1/playlists/%s' -H %s -H 'Content-Type: application/json' -d %s -o /dev/null", pl.id, shell_quote("Authorization: Bearer " .. token), shell_quote(json.encode({name=nn}))))
                if r and r:match("2..") then
                    pl.name = nn; bust_my_playlists()
                    table.sort(pls, function(a,b) return (a.name or ""):lower() < (b.name or ""):lower() end)
                    entries = {"Create New Playlist"}
                    for _, p in ipairs(pls) do entries[#entries+1] = display_playlist(p) end
                    rofi_message("Renamed")
                else rofi_message("Failed") end
                goto pl_act
            elseif asel == "Delete Playlist" then
                local c = rofi_dmenu({"Yes, delete","Cancel"}, {prompt="Delete", mesg="Delete '" .. (pl.name or "") .. "'?", custom=false, by_index=true, use_menu=true})
                if c == 1 then
                    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X DELETE 'https://api.spotify.com/v1/playlists/%s/followers' -H %s -o /dev/null", pl.id, shell_quote("Authorization: Bearer " .. token)))
                    if r and r:match("2..") then
                        bust_my_playlists()
                        disk_bust(P.mass .. "/playlist_tracks_" .. pl.id .. ".json"); mem_bust("playlist_tracks_" .. pl.id)
                        rofi_message("Deleted")
                        local del_idx = nil
                        for i, p in ipairs(pls) do if p.id == pl.id then del_idx = i; break end end
                        if del_idx then table.remove(entries, del_idx + 1); table.remove(pls, del_idx) end
                        session_clear()
                        break
                    else rofi_message("Failed to delete") end
                end
                goto pl_act
            elseif asel == "Copy URL" then
                copy_spotify_url("playlist", pl.id)
                rofi_message("Copied URL")
                goto pl_act
            end
        end
        ::pl_loop::
    end
end

-- VIEW: SEARCH

local function view_search(category)
    while true do
        local key = category == "all" and "all" or category .. "s"
        local query = rofi_dmenu({}, {prompt="Search " .. category:sub(1,1):upper() .. category:sub(2), mesg="Search " .. key, use_menu=true, no_status=true})
        if not query then if consume_pending_toggle() then goto sr_loop end; return end
        local stype = category == "all" and "track,album,artist,playlist" or category
        local results = api_search(query, stype)
        if not results then rofi_message("No results"); return end

        session_push({view="search-results", category=category, query=query})
        local items, entries, mesg, sctx, sctx_id = format_search_results(results, category, query)
        if not items then session_pop(); goto sr_loop end
        view_browse(entries, items, mesg, sctx, sctx_id, nil)
        session_pop()
        if seek_pending or jump_to_track_pending then return end
        ::sr_loop::
    end
end

-- VIEW: CATEGORIES

local function view_categories()
    local cats = api_get_categories()
    if not cats or #cats == 0 then rofi_message("No categories available"); return end
    session_push({view="categories"})
    local ce = {}
    for _, c in ipairs(cats) do ce[#ce+1] = c.name end

    while true do
        local idx = rofi_dmenu(ce, {prompt="Categories", mesg="Categories" .. SEP .. #cats, custom=false, by_index=true, use_menu=true})
        if not idx then
            if consume_pending_toggle() then goto cat_loop end
            session_pop()
            if seek_pending or jump_to_track_pending then return end
            return
        end
        if idx < 1 or idx > #cats then goto cat_loop end
        local cat = cats[idx]
        local pls, pe, mesg = fetch_category_playlists(cat.id, cat.name)
        if not pls then rofi_message("No playlists"); goto cat_loop end
        session_push({view="category-playlists", category_id=cat.id, category_name=cat.name})
        view_browse(pe, pls, mesg, "playlist", "playlist", nil)
        session_pop()
        if seek_pending then session_pop(); return end
        ::cat_loop::
    end
end

-- VIEW: TOP TRACKS / LIKED / SAVED / FOLLOWED / CURATED / QUEUE

local function view_top_tracks()
    local tracks = api_get_top_tracks()
    if not tracks then rofi_message("No top tracks"); return end
    session_push({view="top-tracks"})
    local entries = format_entries(tracks)
    view_browse(entries, tracks, "Top Tracks" .. SEP .. #tracks .. " tracks", "top-tracks", nil, nil)
    session_pop()
    if seek_pending or jump_to_track_pending then return end
end

local function view_liked_tracks()
    local tracks = load_liked_tracks()
    if #tracks == 0 then rofi_message("No liked tracks"); return end
    session_push({view="liked"})
    local entries = format_entries(tracks)
    view_browse(entries, tracks, "Liked Tracks" .. SEP .. #tracks .. " tracks", "liked", nil, nil)
    session_pop()
    if seek_pending or jump_to_track_pending then return end
end

local function view_saved_albums()
    local al = load_saved_albums()
    if #al == 0 then rofi_message("No saved albums"); return end
    session_push({view="saved-albums"})
    local entries = {}
    for i, a in ipairs(al) do entries[i] = display_album(a) end
    view_browse(entries, al, "Saved Albums" .. SEP .. #al .. " albums", "album-list", "album", nil)
    session_pop()
    if seek_pending or jump_to_track_pending then return end
end

local function view_followed_artists()
    local ar = load_followed_artists()
    if #ar == 0 then rofi_message("No followed artists"); return end
    session_push({view="followed-artists"})
    local entries = {}
    for i, a in ipairs(ar) do entries[i] = display_artist(a) end
    view_browse(entries, ar, "Followed Artists" .. SEP .. #ar .. " artists", "artist-list", nil, nil)
    session_pop()
    if seek_pending or jump_to_track_pending then return end
end

local function view_new_releases()
    local albums = api_get_new_releases() or {}
    if #albums == 0 then rofi_message("No new releases"); return end
    session_push({view="new-releases"})
    local entries = {}
    for i, a in ipairs(albums) do entries[i] = display_album(a) end
    while true do
        ::nr_next::
        local idx = rofi_dmenu(entries, {prompt="New Releases", mesg="New Releases" .. SEP .. #albums .. " albums", custom=false, by_index=true, use_menu=true})
        if not idx then
            if consume_pending_toggle() then goto nr_next end
            session_pop()
            if seek_pending or jump_to_track_pending then return end
            return
        end
        if idx >= 1 and idx <= #albums then
            local al = albums[idx]
            local action = rofi_dmenu({"Open Album", "Save Album", "Copy URL"}, {prompt=al.name or "Album", mesg=artist_names(al), custom=false, theme=THEME_SUB})
            if action == "Save Album" then
                rofi_message(do_save_album(al.id) and "Album saved" or "Failed to save album")
            elseif action == "Copy URL" then
                copy_spotify_url("album", al.id)
                rofi_message("Copied URL")
            elseif action == "Open Album" then
                if browse_album(al.id, al.name .. SEP .. artist_names(al)) then
                    if seek_pending or jump_to_track_pending then session_pop(); return end
                end
            end
        end
    end
end

local function view_your_queue()
    local d = mem_get("queue")
    if not d then
        d = api_get("me/player/queue")
        if d then mem_set("queue", d, 10) end
    end
    if not d then rofi_message("Queue is empty"); return end
    local tracks = {}
    if d.currently_playing and type(d.currently_playing) == "table" and d.currently_playing.id then tracks[#tracks+1] = d.currently_playing end
    if d.queue then for _, t in ipairs(d.queue) do if type(t) == "table" and t.id then tracks[#tracks+1] = t end end end
    if #tracks == 0 then rofi_message("Queue is empty"); return end
    session_push({view="your-queue"})
    local entries = format_entries(tracks)
    local user_q = d.queue and #d.queue or 0
    local mesg = "Your Queue" .. SEP .. user_q .. " tracks"
    if user_q > 0 then mesg = mesg .. " (may include Spotify suggestions)" end
    view_browse(entries, tracks, mesg, "your-queue", nil, nil)
    session_pop()
    if seek_pending or jump_to_track_pending then return end
end

local function view_volume()
    local supports_vol = mem_get("spotifyd_device_vol")
    if supports_vol == false then
        rofi_message("Device doesn't support volume control"); return
    end
    while true do
        ::vol_next::
        local vi = rofi_dmenu({"Volume +5", "Volume -5", '<span foreground="#20242a">────────────────────</span>',
                               "Mute", "25%", "50%", "75%", "100%"},
            {prompt="Volume", mesg=vol_mesg(), custom=false, theme=THEME_SUB, markup=true, no_status=not current_track})
        if not vi then if consume_pending_toggle() then goto vol_next end; break end
        local vol = get_playerctl_volume()
        if vi == "Volume +5" then
            local nv = math.min(vol + 5, 100)
            os.execute("playerctl volume " .. string.format("%.2f", nv / 100) .. " 2>/dev/null")
            save_volume(nv)
        elseif vi == "Volume -5" then
            local nv = math.max(vol - 5, 0)
            os.execute("playerctl volume " .. string.format("%.2f", nv / 100) .. " 2>/dev/null")
            save_volume(nv)
        else
            local vol_presets = {Mute=0, ["25%"]=25, ["50%"]=50, ["75%"]=75, ["100%"]=100}
            local v = vol_presets[vi]
            if v then os.execute("playerctl volume " .. string.format("%.2f", v / 100) .. " 2>/dev/null"); save_volume(v) end
        end
    end
end

-- VIEW: PLAYBACK CONTROLS

view_seek = function(item)
    session_push({view="seek", track_id=item.id, track_name=item.name or "", track_artists=item.artists or {}, track_duration_ms=item.duration_ms or 0})
    local seeks = {"+10s", "-10s", "+30s", "-30s", '<span foreground="#20242a">────────────────────</span>', "1:00", "2:00", "0:00"}
    while true do
        ::seek_next::
        local si = rofi_dmenu(seeks, {prompt="Seek", mesg=seek_mesg(item), sel=0, custom=false, theme=THEME_SUB, markup=true})
        if not si then if consume_pending_toggle() then goto seek_next end; break end
        local sign, secs = si:match("^([%+%-])(%d+)s$")
        if sign then
            local cur = get_playerctl_position()
            local delta = sign == "+" and tonumber(secs) or -tonumber(secs)
            local dur = (item.duration_ms or 0) / 1000
            local target = math.max(0, math.min(dur > 0 and dur or math.huge, math.floor(cur + delta + 0.5)))
            os.execute("playerctl position " .. target .. " 2>/dev/null")
        else
            local m, s = si:match("^(%d+):(%d+)$")
            if m and s then
                local target = tonumber(m) * 60 + tonumber(s)
                local dur = (item.duration_ms or 0) / 1000
                target = math.max(0, math.min(dur > 0 and dur or math.huge, target))
                os.execute("playerctl position " .. target .. " 2>/dev/null")
            end
        end
    end
    session_pop()
    if seek_pending or jump_to_track_pending then return end
end

local function view_playback()
    while true do
        ::pb_next::
        local play_label = current_track and (is_playing and "Pause" or "Resume") or nil
        local items = {}
        if play_label then items[#items+1] = play_label end
        items[#items+1] = current_track and "Seek" or '<span color="#6a707f">Seek</span>'
        items[#items+1] = "Next Track"
        items[#items+1] = "Previous Track"
        items[#items+1] = is_shuffle and "Shuffle: On" or "Shuffle: Off"
        items[#items+1] = repeat_state=="off" and "Repeat: Off" or (repeat_state=="track" and "Repeat: Track" or "Repeat: Context")
        items[#items+1] = "Open URL"
        local mesg = current_track and track_mesg(current_track) or "Playback"
        local si = rofi_dmenu(items, {prompt="Playback", mesg=mesg, custom=false, use_menu=true, theme=THEME_SUB, markup=true, no_status=not current_track})
        if not si then if consume_pending_toggle() then goto pb_next end; break end
        if si == "Pause" then
            local r = os.execute("playerctl pause 2>/dev/null")
            if r == true or r == 0 then is_playing = false else rofi_message("Failed to pause") end
        elseif si == "Resume" then
            local r = os.execute("playerctl play 2>/dev/null")
            if r == true or r == 0 then is_playing = true else rofi_message("Failed to resume") end
        elseif si == "Next Track" then
            local r = do_playback_cmd("next")
            if r and r:match("2..") then
                last_playback = 0; get_playback()
                if queue_tracks and queue_idx < #queue_tracks then queue_idx = queue_idx + 1 end
            elseif not recover_playback(1) then rofi_message("Failed to skip") end
        elseif si == "Previous Track" then
            local r = do_playback_cmd("previous")
            if r and r:match("2..") then
                last_playback = 0; get_playback()
                if queue_idx > 1 then queue_idx = queue_idx - 1 end
            elseif not recover_playback(-1) then rofi_message("Failed to go back") end
        elseif si:find("^Shuffle") then toggle_shuffle()
        elseif si:find("^Repeat") then toggle_repeat()
        elseif si == "Seek" then
            if current_track then view_seek(current_track) end
        elseif si == "Open URL" then
            local url = trim(shell("wl-paste 2>/dev/null") or "")
            if url and url ~= "" then open_url(url)
            else rofi_message("Clipboard is empty") end
        end
    end
end

-- VIEW: SYSTEM

local function view_system()
    local cur_br = get_saved_bitrate()
    local cur_vol = get_playerctl_volume()
    local vol_label = cur_vol == 0 and "Muted" or (cur_vol .. "%")
    local items = {"Keybinds", "Volume <b>" .. vol_label .. "</b>", "Bitrate <b>" .. cur_br .. " kbps</b>",
                   "Refresh Library",
                   "Restart Daemons",
                   "Kill Daemons"}
    while true do
        ::sys_next::
        local sel = rofi_dmenu(items, {prompt="System", mesg="System", custom=false, use_menu=true, theme=THEME_SUB, markup=true, no_status=true})
        if not sel then if consume_pending_toggle() then goto sys_next end; break end
        local clean = sel:gsub("<[^>]+>", "")
        if clean == "Keybinds" then
            rofi_message("<b>Alt+Return      </b> Jump to main menu\n<b>Alt+Backspace   </b> Back one level\n<b>Alt+Space       </b> Exit to main menu\n<b>Alt+l           </b> Liked tracks\n<b>Alt+q           </b> Your queue\n<b>Alt+p           </b> Recently played\n<b>Alt+v           </b> Volume\n<b>Alt+a           </b> Album art of current track\n<b>Alt+y           </b> Lyrics of current track\n<b>Alt+c           </b> Jump to playing track (list)\n                 Jump to current lyric line (lyrics)\n<b>Alt+e           </b> Seek current track\n<b>Alt+r           </b> Toggle repeat\n<b>Alt+s           </b> Toggle shuffle\n<b>Alt+g           </b> Open Spotify URL from clipboard\n<b>Return          </b> Select\n<b>Escape          </b> Close", THEME_BINDS)
        elseif clean:match("^Volume") then
            view_volume()
            cur_vol = get_playerctl_volume()
            vol_label = cur_vol == 0 and "Muted" or (cur_vol .. "%")
            items[2] = "Volume <b>" .. vol_label .. "</b>"
        elseif clean:match("^Bitrate") then
            local br_opts = {}
            for _, v in ipairs({96, 160, 320}) do
                if v == cur_br then
                    table.insert(br_opts, "<span foreground=\"#b6e0a4\">"
                        .. "\u{f00c}  " .. v .. " kbps</span>")
                else
                    local label = v .. " kbps"
                    if v == 160 then label = label .. " (default)" end
                    table.insert(br_opts, label)
                end
            end
            local chosen = rofi_dmenu(br_opts,
                {prompt="Bitrate", mesg="Current: " .. cur_br .. " kbps\nRestart daemons to apply", custom=false, markup=true, theme=THEME_SUB, no_status=true})
            if chosen then
                local n = tonumber(chosen:match("(%d+)"))
                if n then
                    save_bitrate(n); cur_br = n
                    items[3] = "Bitrate <b>" .. n .. " kbps</b>"
                    os.execute("notify-send -t 3000 --app-name=spotirofi 'Spotirofi' '" .. n .. " kbps — restart daemons to apply' &")
                end
            end
        elseif clean == "Refresh Library" then
            os.execute("notify-send -t 5000 --app-name=spotirofi 'Spotirofi' 'Refreshing library...' &")
            os.remove(P.liked); os.remove(P.albums); os.remove(P.artists); os.remove(P.liked_ids)
            mem_bust("liked_tracks"); mem_bust("saved_albums"); mem_bust("followed_artists")
            local tracks, albums, artists = fetch_library_with_fallback()
            save_library_cache(tracks, albums, artists)
            populate_liked_ids()
            os.execute("notify-send -t 3000 --app-name=spotirofi 'Spotirofi' 'Library refreshed' &")
        elseif clean == "Restart Daemons" then
            os.execute("pkill -x spotifyd 2>/dev/null"); os.execute("pkill -f 'spotirofi.*--daemon' 2>/dev/null"); os.execute("sleep 1")
            inv_playback()
            ensure_spotifyd()
            os.execute("sleep 3")
            os.execute("lua " .. P.dir .. "/spotirofi.lua --daemon &")
        elseif clean == "Kill Daemons" then
            os.execute("pkill -x spotifyd 2>/dev/null")
            os.execute("pkill -f 'spotirofi.*--daemon' 2>/dev/null")
            os.execute("pkill -x rofi 2>/dev/null")
            os.exit(0)
        end
    end
end

-- SESSION REPLAY

local function replay_session()
    local s = session_peek()
    if not s then return end

    while s do
        session_pop()
        get_playback()
        local v = s.view

        if v == "action" and s.track_id then
            if current_track then
                view_actions(current_track, "track")
            else
                view_actions({id=s.track_id, name=s.track_name or "", artists=s.track_artists or {},
                    album=s.track_album or {}, duration_ms=s.track_duration_ms or 0}, "track")
            end
        elseif v == "lyrics" and s.track_id then
            if current_track then
                view_lyrics(current_track)
            else
                view_lyrics({id=s.track_id, name=s.track_name or "", artists=s.track_artists or {}})
            end
        elseif v == "album" and s.album_id then
            session_push({view="album", album_id=s.album_id})
            local ad = api_get_album(s.album_id)
            if ad and ad.tracks and #ad.tracks > 0 then
                local te = format_entries(ad.tracks, true)
                view_browse(te, ad.tracks, "", "album", "album", s.album_id)
            end
            session_pop()
        elseif v == "playlist" and s.playlist_id then
            session_push({view="playlist", playlist_id=s.playlist_id})
            local tracks = api_get_playlist_tracks(s.playlist_id)
            if tracks and #tracks > 0 then
                local te = format_entries(tracks)
                view_browse(te, tracks, "", "playlist", "playlist", s.playlist_id)
            end
            session_pop()
        elseif v == "liked"              then view_liked_tracks()
        elseif v == "top-tracks"         then view_top_tracks()
        elseif v == "your-queue"         then view_your_queue()

        elseif v == "new-releases"      then view_new_releases()
        elseif v == "recently-played"   then view_recently_played()
        elseif v == "artist-actions" and s.artist_id then
            view_artist({id=s.artist_id, name=s.artist_name or ""})
        elseif v == "artist-albums" and s.artist_id then
            local items, ae, mesg = fetch_artist_albums(s.artist_id, s.artist_name)
            if items then
                while true do
                    local aidx = rofi_dmenu(ae, {prompt=s.artist_name or "", mesg=mesg, custom=false, by_index=true, use_menu=true})
                    if not aidx then break end
                    if aidx >= 1 and aidx <= #items then
                        local al = items[aidx]
                        local action = rofi_dmenu({"Open Album", "Save Album", "Copy URL"}, {prompt=al.name or "Album", mesg=artist_names(al), custom=false, theme=THEME_SUB})
                        if action == "Save Album" then
                            rofi_message(do_save_album(al.id) and "Album saved" or "Failed to save album")
                        elseif action == "Copy URL" then
                            copy_spotify_url("album", al.id)
                            rofi_message("Copied URL")
                        elseif action == "Open Album" then
                            if browse_album(al.id, (al.name or "Unknown") .. SEP .. artist_names(al)) then
                                if seek_pending then return end
                            end
                        end
                    end
                end
            end
        elseif v == "liked-by-artist" and s.artist_id then
            local tracks, te, mesg = fetch_liked_by_artist(s.artist_id, s.artist_name)
            if tracks then view_browse(te, tracks, mesg, "liked-by-artist", nil, nil) end
        elseif v == "top-by-artist" and s.artist_id then
            local tracks, te, mesg = fetch_artist_top_tracks(s.artist_id, s.artist_name)
            if tracks then view_browse(te, tracks, mesg, "top-by-artist", nil, nil) end
        elseif v == "related" and s.artist_id then
            local artists, ae, mesg = fetch_related_artists(s.artist_id, s.artist_name)
            if artists then
                while true do
                    local ridx = rofi_dmenu(ae, {prompt="Related to " .. (s.artist_name or ""), mesg=mesg, custom=false, by_index=true, use_menu=true})
                    if not ridx then break end
                    if ridx >= 1 and ridx <= #artists then
                        view_artist(artists[ridx])
                        if seek_pending then return end
                    end
                end
            end
        elseif v == "recommendations" and s.track_id then
            local rec_id = current_track and current_track.id or s.track_id
            local rec_name = current_track and current_track.name or s.track_name
            local tracks = api_get_recommendations(rec_id)
            if tracks then
                local te = format_entries(tracks)
                view_browse(te, tracks, "More Like " .. (rec_name or ""), "recommendations", nil, nil)
            end
        elseif v == "categories"          then view_categories()
        elseif v == "playlists"           then view_playlists()
        elseif v == "saved-albums"        then view_saved_albums()
        elseif v == "followed-artists"    then view_followed_artists()
        elseif v == "search-results" and s.query then
            local stype = (s.category or "all") == "all" and "track,album,artist,playlist" or (s.category or "track")
            local results = api_search(s.query, stype)
            if results then
                local items, entries, mesg, sctx, sctx_id = format_search_results(results, s.category or "all", s.query)
                if items then view_browse(entries, items, mesg, sctx, sctx_id, nil) end
            end
        elseif v == "category-playlists" and s.category_id then
            local pls, pe, mesg = fetch_category_playlists(s.category_id, s.category_name)
            if pls then view_browse(pe, pls, mesg, "playlist", "playlist", nil) end
        elseif v == "playlist-actions" and s.playlist_id then
            local token = get_token()
            if not token then goto rnext end
            local pl = {id=s.playlist_id, name=s.playlist_name or "Playlist"}
            local acts = {"Open Playlist", "Rename Playlist", "Delete Playlist", "Copy URL"}
            while true do
            ::rp_act::
            local asel = rofi_dmenu(acts, {prompt=display_playlist(pl), mesg=display_playlist(pl), sel=0, custom=false, use_menu=true})
            if not asel then if consume_pending_toggle() then goto rp_act end; break end
            if asel == "Open Playlist" then
                local tracks = api_get_playlist_tracks(pl.id)
                if tracks then
                    local te = format_entries(tracks)
                    view_browse(te, tracks, (pl.name or "Playlist") .. SEP .. #tracks .. " tracks", "playlist", "playlist", pl.id)
                    if seek_pending then return end
                end
                goto rp_act
            elseif asel == "Rename Playlist" then
                local nn = rofi_input("New Name", pl.name or "")
                if nn == "" or nn == (pl.name or "") then goto rp_act end
                local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X PUT 'https://api.spotify.com/v1/playlists/%s' -H %s -H 'Content-Type: application/json' -d %s -o /dev/null", pl.id, shell_quote("Authorization: Bearer " .. token), shell_quote(json.encode({name=nn}))))
                if r and r:match("2..") then pl.name = nn; bust_my_playlists(); rofi_message("Renamed") else rofi_message("Failed") end
                goto rp_act
            elseif asel == "Delete Playlist" then
                local c = rofi_dmenu({"Yes, delete","Cancel"}, {prompt="Delete", mesg="Delete '" .. (pl.name or "") .. "'?", custom=false, by_index=true, use_menu=true})
                if c == 1 then
                    local r = shell(string.format("curl -s --max-time 5 -w '%%{http_code}' -X DELETE 'https://api.spotify.com/v1/playlists/%s/followers' -H %s -o /dev/null", pl.id, shell_quote("Authorization: Bearer " .. token)))
                    if r and r:match("2..") then bust_my_playlists(); disk_bust(P.mass .. "/playlist_tracks_" .. pl.id .. ".json"); mem_bust("playlist_tracks_" .. pl.id); rofi_message("Deleted"); break
                    else rofi_message("Failed to delete") end
                end
                goto rp_act
            elseif asel == "Copy URL" then
                copy_spotify_url("playlist", pl.id)
                rofi_message("Copied URL")
                goto rp_act
            end
            end
        elseif v == "add-to-playlist" and s.track_id then
            view_add_pl(s.track_id)
        end

        ::rnext::
        s = session_peek()
    end
end

-- MAIN

local function init_instance_lock()
    os.execute("rm -f /tmp/spotirofi_code /tmp/spotirofi_oauth_pid 2>/dev/null")
    local lock = "/tmp/spotirofi_instance.lock"
    local existing = trim(read_file(lock) or "")
    if existing ~= "" then
        if not existing:match("^%d+$") then existing = "" end
        local alive = existing ~= "" and trim(shell("kill -0 " .. existing .. " 2>/dev/null && echo alive") or "") or ""
        if alive == "alive" then os.exit(0) end
    end
    local pid = trim(shell("echo -n $PPID") or "")
    if pid ~= "" then
        local f = io.open(lock, "w")
        if f then f:write(pid); f:close() end
    end
end

local function ensure_daemon()
    local daemon_pid = trim(read_file("/tmp/spotirofi_daemon.pid") or "")
    local daemon_alive = false
    if daemon_pid ~= "" and tonumber(daemon_pid) then
        daemon_alive = trim(shell("kill -0 " .. daemon_pid .. " 2>/dev/null && echo alive") or "") == "alive"
    end
    if not daemon_alive then
        os.execute("lua " .. P.dir .. "/spotirofi.lua --daemon &")
    end
end

local function check_rate_cooldown()
    local rate_cool = read_file("/tmp/spotirofi_rate_cooldown")
    if rate_cool then
        local until_t = tonumber(trim(rate_cool))
        if until_t and os.time() < until_t then
            local secs = until_t - os.time()
            rofi_message("Spotify API rate limit active.\nRetry after " .. secs .. "s.")
            return
        end
        os.remove("/tmp/spotirofi_rate_cooldown")
    end
end

local function init_library()
    ensure_spotifyd_auth()
    ensure_auth()
    ensure_spotifyd()
    load_queue()
    ;(function()
        local raw = read_file(P.state)
        if raw then local d = safe_decode(raw)
            if d then
                if d.repeat_state then repeat_state = d.repeat_state end
                if d.shuffle ~= nil then is_shuffle = d.shuffle end
            end
        end
    end)()
    populate_liked_ids()
    if not (cache_exists(P.liked) and cache_exists(P.albums) and cache_exists(P.artists)) then
        os.execute("notify-send -t 5000 --app-name=spotirofi 'Spotirofi' 'First run: building library...' &")
        local tracks, albums, artists = fetch_library_with_fallback()
        save_library_cache(tracks, albums, artists)
        os.execute("notify-send -t 3000 --app-name=spotirofi 'Spotirofi' 'Library ready' &")
    elseif cache_stale(P.liked) or cache_stale(P.albums) or cache_stale(P.artists) then
        os.execute("notify-send -t 5000 --app-name=spotirofi 'Spotirofi' 'Refreshing library...' &")
        local tracks, albums, artists = fetch_library_with_fallback()
        save_library_cache(tracks, albums, artists)
        os.execute("notify-send -t 3000 --app-name=spotirofi 'Spotirofi' 'Library refreshed' &")
    end
    session_load()
    replay_session()
    last_playback = 0
end

local function main()
    init_instance_lock()
    ensure_daemon()
    check_rate_cooldown()
    init_library()

    while true do
        flush_liked_cache()
        flush_recent_play()
        get_playback()
        if current_id and current_id ~= previous_id then
            record_recent_play(current_track)
            previous_id = current_id
        end
        local has_track = current_track ~= nil
        local mesg = has_track and track_mesg(current_track) or "spotirofi"

        local entries = {}
        local function add(v) if v then entries[#entries+1] = v end end
        add("Playback")
        add("Your Queue"); add("Liked Tracks"); add("Top Tracks"); add("Saved Albums")
        add("Followed Artists"); add("Playlists"); add("New Releases")
        add("Recently Played"); add("Categories"); add("Search")
        add("System")

        local sel = rofi_dmenu(entries, {prompt="Spotify", mesg=mesg, sel=0, custom=false, markup=true, no_status=not current_track})
        if sel then sel = sel:gsub("<[^>]+>", "") end

        if main_pending   then main_pending   = false; goto m1 end
        if liked_pending  then liked_pending  = false; view_liked_tracks(); goto m1 end
        if queue_pending  then queue_pending  = false; view_your_queue(); goto m1 end
        if recent_pending then recent_pending = false; view_recently_played(); goto m1 end
        if volume_pending then volume_pending = false; view_volume(); goto m1 end
        if jump_to_track_pending then jump_to_track_pending = false; goto m1 end
        if seek_pending   then seek_pending   = false
            last_playback = 0; get_playback()
            if current_track then view_seek(current_track) end
            goto m1
        end
        if not sel then goto m1 end

        if      sel == "Search" then
            local tp = {"All","Tracks","Albums","Artists","Playlists"}
            local p  = {"all","track","album","artist","playlist"}
            local si = rofi_dmenu(tp, {prompt="Search", mesg=mesg, custom=false, by_index=true, use_menu=true, theme=THEME_SUB, no_status=true})
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
    local lock = "/tmp/spotirofi_daemon.pid"
    local prev = read_file(lock)
    local prev_pid = prev and tonumber(prev:match("(%d+)"))
    if prev_pid and prev_pid > 0 then
        local cmdline = trim(shell("cat /proc/" .. prev_pid .. "/cmdline 2>/dev/null") or "")
        if cmdline:find("spotirofi") then
            os.execute("kill " .. prev_pid .. " 2>/dev/null; sleep 0.1")
        end
    end
    local f = io.open("/proc/self/stat")
    local raw = f and f:read("*a")
    if f then f:close() end
    local mypid = raw and tonumber(raw:match("^(%d+)"))
    if mypid then write_file(lock, tostring(mypid)) end

    local NOTIFY_FILE = "/tmp/spotirofi_last_notify"
    local last_title = nil

    local function daemon_notify(title, artist, art_url, track_id)
        if not title then return end
        if track_id and #track_id > 0 then
            local prev_id = read_file(NOTIFY_FILE)
            if prev_id and trim(prev_id) == track_id then return end
            write_file(NOTIFY_FILE, track_id)
        end
        local art_path = ensure_art(art_url) or ""
        local icon = #art_path > 0 and ("--icon=" .. shell_quote(art_path)) or ""
        os.execute("notify-send --app-name=spotirofi " .. icon
            .. " " .. shell_quote(title)
            .. " " .. shell_quote(artist or "") .. " &")
    end

    local function process_snap(snap)
        if not snap then return end
        snap = trim(snap)
        local title, artist, art_url, track_id, album, duration_raw = snap:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
        if track_id then local cleaned = track_id:gsub("^'", ""):gsub("'$", ""); track_id = cleaned:match("^/spotify/track/(.+)") or cleaned:match("^spotify:track:(.+)") or track_id end
        local duration = tonumber(duration_raw) and tonumber(duration_raw) / 1000000 or nil
        if title and title ~= "" and title ~= last_title then
            daemon_notify(title, artist, art_url, track_id)
            last_title = title
            if track_id and #track_id > 0 then
                os.execute("nohup lua " .. shell_quote(P.dir .. "/spotirofi.lua")
                    .. " --prefetch-lyrics " .. shell_quote(track_id)
                    .. " " .. shell_quote(title)
                    .. " " .. shell_quote(artist or "")
                    .. " " .. shell_quote(album or "")
                    .. " " .. shell_quote(duration and tostring(math.floor(duration)) or "")
                    .. " > /dev/null 2>&1 &")
            end
        end
    end

    local function daemon_loop()
        process_snap(shell("playerctl metadata -f '{{title}}|{{artist}}|{{mpris:artUrl}}|{{mpris:trackid}}|{{album}}|{{mpris:length}}' 2>/dev/null"))
        local p = io.popen("playerctl --follow metadata -f '{{title}}|{{artist}}|{{mpris:artUrl}}|{{mpris:trackid}}|{{album}}|{{mpris:length}}' 2>/dev/null", "r")
        if not p then return nil end
        for line in p:lines() do
            process_snap(line)
        end
        p:close()
    end

    while true do
        daemon_loop()
        os.execute("sleep 2")
    end
end

if arg and arg[1] == "--daemon" then
    daemon_mode()
elseif arg and arg[1] == "--prefetch-lyrics" and arg[2] and arg[3] and arg[4] then
    local id = arg[2]
    local disk = P.lyrics .. "/lyrics_" .. id .. ".json"
    local existing = disk_get(disk)
    if existing then os.exit(0) end
    local album = arg[5] ~= "" and arg[5] or nil
    local duration = arg[6] and tonumber(arg[6]) or nil
    local result = api_get_lyrics(arg[3], arg[4], album, duration)
    if result then
        disk_set(disk, result)
    end
    os.exit(0)
else
    main()
end

end)()
