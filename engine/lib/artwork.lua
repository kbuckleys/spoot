-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- spoot Spotify Client ~ Part of the ZENWORKS Suite
-- https://github.com/kbuckleys/

-- ARTWORK, FETCHED AND FILED: getting covers onto disk (one at a time, or as a
-- batch through the host with a retry pass and a wall-clock budget), the spool
-- that hands a grid's tail to a background job, the per-kind index that says
-- which cover a playlist or artist file currently holds, the glyph stand-ins for
-- rows that will never have one, and Util.album_thumbs, which decorates every
-- grid in the app. The pure url and file checks this builds on are lib/art.lua.
--
-- An installer, like the rest of lib/. `ctx` is the file helpers spoot.lua owns
-- that this reads -- nothing else reaches outside (luac -l shows only the
-- standard library). ensure_art was a file local of spoot.lua; it is published
-- as Util.ensure_art for the handful of callers outside this file.
return function(Util, ctx)
    local P = ctx.P
    local read_file, write_file, shell, shell_quote =
        ctx.read_file, ctx.write_file, ctx.shell, ctx.shell_quote
    local ensure_cache, disk_get, disk_set = ctx.ensure_cache, ctx.disk_get, ctx.disk_set

    -- How many album covers a thumbnail grid fetches before it is allowed to draw.
    -- The thumbs grid shows 5x3 = 15 at a time, so this is several screens of
    -- scroll headroom. An artist discography can run to 1500 albums (Rachmaninoff
    -- does), and fetching every cover up front is what made such a list look like a
    -- hang -- the rest is handed to a detached prefetch, see Util.album_thumbs.
    local THUMB_SYNC = 60

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
            if attempt < attempts then Util.wait(1) end
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
            -- `parallel` GOES ACROSS. It did not, and the host fired every job in the
            -- batch at once -- so the bound every caller here writes down was curl's
            -- alone and the embedded path, which is the one that actually runs, had
            -- none. See l_http_batch: a 32-page me/tracks sweep asking Spotify 32
            -- times in the same millisecond is what earned the standing 429 on that
            -- endpoint.
            -- opts.bodies: hand the pages back in memory rather than through the
            -- `out` files, for a caller that only wants to read them. `out` is then
            -- just the name each result is filed under. See l_http_batch.
            local res = Util.host.http{jobs = jobs, timeout = opts.timeout or 10,
                                       parallel = opts.parallel or 8, bodies = opts.bodies,
                                       headers = opts.header and {opts.header} or nil}
            if not res then return nil end
            -- One answer is enough to know the link is alive; one failure is not
            -- enough to know it is dead, because a batch can lose a page on its own.
            -- So only an ALL-ZERO batch arms the gate -- and only a batch aimed at
            -- SPOTIFY, by the rule Util.net_seen states: a cover batch the CDN did
            -- not answer is that host being slow, not the API being unreachable.
            local best, any = 0, false
            for out, r in pairs(res) do
                any = true
                got[out] = {code = tostring(r.code), size = r.size, body = r.body, cut = r.cut}
                if (tonumber(r.code) or 0) > best then best = tonumber(r.code) or 0 end
            end
            if any and jobs[1] then Util.net_seen({url = jobs[1].url}, best) end
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
        -- The same shape the host answers with: curl can only write files, so they
        -- are read back and removed here, and the caller never learns which path ran.
        if opts.bodies then
            for path, r in pairs(got) do
                r.body = read_file(path)
                os.remove(path)
            end
        end
        return got
    end

    -- The art pass on top of that transport: name a temp file per cover, fetch the
    -- batch, then validate and rename. Three passes, because a cover that came down
    -- truncated is worth one more try and a 404 is not.
    -- ARTWORK MAY NOT FREEZE THE APP, and for a long time it could freeze it for
    -- half a minute.
    --
    -- This ran with no timeout at all, so Util.curl_batch fell back to its 10s
    -- default -- three passes of that, with a one-second sleep between them, is 32
    -- seconds. The engine is ONE worker thread: the covers were deliberately fetched
    -- after the reply went out, which spares the request that asked for them and
    -- spares nothing else, because every command behind it -- the once-a-second
    -- playback poll included -- waits on this. That is the list and the now-playing
    -- bar going dead together for ten seconds and more.
    --
    -- Three bounds now. A tight per-request budget, because these are small files
    -- from a CDN and one that has not answered in five seconds is not going to. A
    -- WALL-CLOCK budget across the whole call, so the retries cannot add up however
    -- many covers a grid asks for. And Util.wait instead of a forked `sleep`, which
    -- is the same fix the rest of the file already made -- embedded it is a timer
    -- that keeps the bus dispatching rather than a process that stops everything.
    --
    -- A cover that misses all of that is not lost: it stays out of the art index, so
    -- the next draw asks again. Decoration retries; it does not get to stall the app.
    Util.ART_BATCH_TIMEOUT  = 5
    Util.ART_BATCH_CONNECT  = 2
    Util.ART_BATCH_BUDGET   = 8   -- seconds, whole call

    -- A COVER THAT IS NOT THERE, remembered for half an hour. A 404 or an image
    -- that will never decode was re-requested on every draw of every grid that
    -- held it, because only the id-keyed kinds record a write-off in their index.
    -- Kept in the host's shared store when there is one, so the engine and the
    -- prefetch jobs agree; per state otherwise.
    Util.ART_DEAD_TTL = 1800
    function Util.art_dead(url)
        local at
        if Util.host and Util.host.shared then at = Util.host.shared("artdead:" .. url)
        else at = Util._dead_art and Util._dead_art[url] end
        return at ~= nil and os.time() - at < Util.ART_DEAD_TTL
    end
    function Util.art_mark_dead(url)
        if Util.host and Util.host.shared then Util.host.shared("artdead:" .. url, os.time())
        else Util._dead_art = Util._dead_art or {}; Util._dead_art[url] = os.time() end
    end

    Util._art_batch = function(items)
        -- NOTHING TO FETCH FOR A FILE ALREADY WHOLE, or for one known to be gone.
        -- A grid's tail is spooled again on every redraw, and the worker used to
        -- download every entry whether or not an earlier chunk had landed it.
        -- Hash-named covers only: an id-keyed file keeps its path when its art
        -- changes, so being on disk says nothing about being current.
        local todo = {}
        for _, pd in ipairs(items) do
            if not pd.art_key and Util._art_valid_file(pd.path) then
                pd.ok = true
            elseif Util.art_dead(pd.url) then
                pd.dead = true
            else
                todo[#todo+1] = pd
            end
        end
        local started = Util.mono() or 0
        for pass = 1, 3 do
            if #todo == 0 then break end
            -- Out of time: leave the rest for the next draw rather than holding the
            -- engine to finish decorating this one.
            if pass > 1 and ((Util.mono() or 0) - started) >= Util.ART_BATCH_BUDGET then break end
            local jobs = {}
            for j, pd in ipairs(todo) do
                pd.tmp = pd.path .. ".tmp" .. Util._rand_suffix() .. "." .. j
                jobs[#jobs+1] = {url = pd.url, out = pd.tmp}
            end
            -- nil means the batch never ran, which is not the same as every cover
            -- failing: give up rather than sleep between three passes that cannot
            -- work either.
            local got = Util.curl_batch(jobs, {fail = true, parallel = 16,
                                               timeout = Util.ART_BATCH_TIMEOUT,
                                               connect_timeout = Util.ART_BATCH_CONNECT})
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
                    local truncated = (r and r.cut) and true or false
                    if not truncated and r and Util.is2xx(r.code) then
                        local fh = io.open(pd.tmp, "rb")
                        if fh then truncated = fh:seek("end") ~= r.size; fh:close() end
                    end
                    if Util.art_retry_worthwhile(r and r.code, truncated) then
                        retry[#retry+1] = pd
                    else
                        pd.dead = true   -- so the caller can stop asking for it
                        Util.art_mark_dead(pd.url)
                    end
                    os.remove(pd.tmp)
                end
                pd.tmp = nil
            end
            todo = retry
            -- Util.wait, not a forked sleep: embedded this is a timer that keeps the
            -- bus dispatching, and outside it is the same second without the fork.
            if #todo > 0 and pass < 3 then Util.wait(1) end
        end
    end

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
    -- SPOOLED, not handed to one process: the work is always written down, so a
    -- tail queued while a worker is running is drained by it rather than lost, and
    -- the in-flight check only decides whether a NEW worker is needed.
    --
    -- Answers the tail_action recorded in the thumbnail log.
    function Util.spawn_art_prefetch(list, kind)
        if not list or #list == 0 then return "empty" end
        local dir = Util.art_spool_dir()
        -- Once per state rather than a fork per spool.
        if not Util._spool_made then
            os.execute("mkdir -p " .. shell_quote(dir))
            Util._spool_made = true
        end
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

    -- WHAT A ROW WEARS WHEN IT WILL NEVER HAVE REAL ARTWORK.
    --
    -- Ten 300x300 PNGs shipped in engine/assets/ and stood here. They were pictures
    -- OF nerd icons -- an icon rasterised, saved, loaded back off disk, decoded and
    -- scaled into a 150px tile -- so the grid paid an image load per placeholder to
    -- draw a glyph the font already has. The font is the one dependency spoot cannot
    -- run without (ttf-jetbrains-mono-nerd, see the README), so the glyph is always
    -- there and always the right size: it is text, it scales to the tile, it takes
    -- the theme's colour, and nothing is fetched, decoded or cached to draw it.
    --
    -- NOT A PATH, AND IT MUST NOT LOOK LIKE ONE. Every real cover here is an
    -- absolute path, so the sentinel is prefixed rather than guessed at: anything
    -- the UI is handed as a row's icon either starts with "glyph:" and is drawn as
    -- text, or is a file. See Util.is_art_glyph, TileGrid's cover/glyph pair, and
    -- main.qml's backdrop, which shows nothing rather than a glyph blown up to 400px.
    --
    -- Keyed by the NAME the asset had, because that name is also the tile key the
    -- drop-in lookup in Util.shelf_tiles matches on -- one name for one thing, and
    -- the Collections and Podcasts grids go on finding their icons by row key.
    Util.ART_GLYPH_PREFIX = "glyph:"
    Util.ART_GLYPHS = {
        categories  = "\u{EB86}",
        collections = "\u{EC57}",
        genre       = "\u{F0F69}",
        new         = "\u{F044}",
        noart       = "\u{F00D}",
        playback    = "\u{F13E6}",
        playlist    = "\u{F0CB8}",
        podcasts    = "\u{F0994}",
        search      = "\u{E68F}",
        system      = "\u{EB52}"
    }

    -- One name to one sentinel, so no call site spells the prefix itself.
    function Util.art_glyph(name)
        local g = Util.ART_GLYPHS[name or ""]
        return g and (Util.ART_GLYPH_PREFIX .. g) or nil
    end

    -- ...and the test, for the handful of places that must not treat one as a file.
    function Util.is_art_glyph(v)
        return type(v) == "string" and v:sub(1, #Util.ART_GLYPH_PREFIX) == Util.ART_GLYPH_PREFIX
    end

    Util.ART_NONE     = Util.art_glyph("noart")     -- album with no cover
    Util.ART_PLAYLIST = Util.art_glyph("playlist")  -- playlist with no cover
    Util.ART_NEW      = Util.art_glyph("new")       -- the Create New Playlist tile
    -- Tiles that open a PICKER rather than a shelf, so no object's cover can stand
    -- for them and they would otherwise wear the "no cover" mark. ART_GENRE serves
    -- Collections' Discover by Genre AND the Podcasts grid's Search tile -- both are
    -- "type a name and see what comes back" -- while ART_CATEGORIES serves
    -- Collections' Categories.
    Util.ART_GENRE      = Util.art_glyph("genre")
    Util.ART_CATEGORIES = Util.art_glyph("categories")

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
        -- Under the lock, or the engine and a prefetch job merging at once each
        -- write back the index they read and one of them loses its covers.
        local idx = Util.locked("artidx:" .. kind, function()
            local cur = disk_get(cfg.index) or {}
            for k, v in pairs(updates) do
                if v == false then cur[k] = nil else cur[k] = v end
            end
            disk_set(cfg.index, cur)
            return cur
        end)
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

    -- The view's own choice of cover, recorded so the context cover beside an
    -- action menu is what the view chose rather than a second guess made by
    -- re-resolving the item.
    -- `art_url` is where to GO AND GET IT if the path came back empty, which is what
    -- a caller asking cache-only gets on a first visit. Recorded rather than fetched
    -- here, so the menu goes out now and its backdrop follows -- see
    -- Util.serve_ctx_art, which runs after the rows.
    --
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
    -- One line per grid draw: what a draw DECIDED is the only evidence left once
    -- the grid has moved on, so it is recorded as the draw happens.
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
    -- A row whose cover is not on disk yet gets no icon (see the decoration loop
    -- below); a fetch that failed stays in `missing`, re-statted every call, so
    -- the next redraw retries.
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
        --
        -- ...AND A ROW MAY STILL NAME ITS OWN STAND-IN, exactly as one filed under a
        -- kind may -- see the `fb` above, whose comment describes this case and only
        -- reached half of it. A row with no Spotify object behind it wears
        -- Util.ART_NONE otherwise, which is the "no cover" mark: it says the thing
        -- has no artwork, when the truth is that it is not the kind of thing that
        -- has any. The genre grid is the case that found it -- 126 rows that are
        -- words, not objects.
        return it.art_fallback or Util.ART_NONE
    end

    -- `focus` is the row the menu is about to open on (0-based, same convention as
    -- ui_menu's `sel`). Covers are fetched outwards from there rather than from
    -- the top of the list, because those are the ones about to be drawn -- see
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
                -- to the UI, the decode failed, and because spoot believed that cover
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
        -- Every row that has no file right now. None of these may be named as an
        -- icon (see the decoration loop). Rows fetched successfully just below drop
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
        -- NO ICON AT ALL for a cover that is not on disk yet. Never name a file
        -- that does not exist: an Image reloads only when its `source` CHANGES, so
        -- a path named before the file lands leaves it in Error, and the art event
        -- that follows names the identical string and changes nothing. An empty
        -- source lets the grid draw its own placeholder, and the art event then
        -- names a path that IS a change.
        local placeholders = 0
        for i, e in ipairs(entries or {}) do
            local p = paths[i]
            -- STRIP OUR OWN FIELD, NOT EVERYTHING AFTER THE FIRST NUL.
            --
            -- This cut at the first \0 on the grounds that "\0icon is the only field
            -- appended to a row, and always last". It is not: the track formatters
            -- append "\0meta\x1f<column>" for the duration-and-status column, and a
            -- row that went through here lost it -- silently, because a missing column
            -- looks like a row that simply has none.
            --
            -- Removed by name instead, so each side-channel owns its own field and
            -- neither cares what else is attached or in what order. Still stripped
            -- unconditionally, which is what lets a redraw promote a row that had no
            -- cover last time.
            local bare = (e:gsub("\0icon\x1f[^\0]*", ""))
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

    Util.ensure_art = ensure_art
end
