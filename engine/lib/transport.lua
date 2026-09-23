-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- spoot Spotify Client ~ Part of the ZENWORKS Suite
-- https://github.com/kbuckleys/

-- THE WAY OUT OF THE ENGINE: every request, every gate in front of one, every
-- notification and every word to the player. Util.http and Util.curl_batch are
-- the only two roads to the network (the batch lives with the artwork, which is
-- its main customer); the connection gate, the rate gate and the request log
-- stand in front of both, and the player and the notification daemon are the
-- same idea one bus over -- one function each, native through the host when
-- there is one, a forked tool when there is not.
--
-- An installer, like lib/art.lua: spoot.lua calls it with Util and the handful
-- of its own file locals this code reads, and everything lands on Util under
-- the name it always had. `ctx` is exactly those locals and nothing more --
-- luac -l on this file shows no other name reaching outside it.
return function(Util, ctx)
    local P, json, SEP = ctx.P, ctx.json, ctx.SEP
    local read_file, shell, shell_quote, trim =
        ctx.read_file, ctx.shell, ctx.shell_quote, ctx.trim

    -- One definition of "the request worked". Nineteen call sites spelled this
    -- inline as `r and r:match("2..")`, two of them inverted, so a nil check was
    -- easy to drop. Deliberately keeps the loose "2.." rather than an anchored
    -- ^2%d%d$: curl's -w '%{http_code}' always emits three digits (or 000 on a
    -- transport failure), so the two agree on every value curl can produce, and
    -- loosening nothing means this cannot reject a response the old code accepted.
    function Util.is2xx(r)
        return r ~= nil and tostring(r):match("^2%d%d$") ~= nil
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
    -- WHERE THE GATE'S TWO NUMBERS LIVE. In the host they are process-wide values
    -- (spoot.shared) that the engine and every job read and write alike -- this is
    -- asked before EVERY request, and as a file it was a read each time and a write
    -- plus a chmod fork per 429. Outside a host there is only this process and its
    -- helpers, and the file is still how those agree.
    function Util.shared_num(name, file)
        if Util.host and Util.host.shared then
            local n = Util.host.shared(name)
            return n and math.floor(n)
        end
        return tonumber((read_file(file) or ""):match("%d+"))
    end
    function Util.shared_put(name, file, v)
        if Util.host and Util.host.shared then Util.host.shared(name, v); return end
        if v == nil then os.remove(file) else Util.secure_write(file, v) end
    end

    -- ONE WRITER AT A TIME, across every Lua state in the process -- the engine
    -- and each job are separate states on separate threads, and a file they all
    -- read-merge-write loses whichever update lands first. The host's named lock
    -- when there is one; outside it there is one process and nothing to race.
    function Util.locked(name, fn)
        if Util.host and Util.host.with_lock then return Util.host.with_lock(name, fn) end
        return fn()
    end

    function Util.rate_cool()
        local n = Util.shared_num("rate-cooldown", P.rate_cooldown)
        if not n then return 0 end
        local left = n - os.time()
        if left <= 0 then Util.shared_put("rate-cooldown", P.rate_cooldown, nil); return 0 end
        return left
    end

    -- SHUT THE GATE, AND SAY SO AT MOST NOW AND THEN.
    --
    -- The one writer of P.rate_cooldown. It existed in api_get's 429 branch alone,
    -- which left the batch path -- Util.paged_fetch's parallel page fetch, the only
    -- thing here that can earn fifty 429s in one second -- writing nothing at all: a
    -- burst got itself limited, said nothing, and every request behind it walked into
    -- the same closed window.
    --
    -- `secs` is what the server asked for where a header was seen, clamped at both
    -- ends: a floor so a header of "1" cannot become a busy loop, a ceiling so a
    -- pathological value cannot take the app off the network for an hour.
    --
    -- THE NOTICE IS THROTTLED SEPARATELY, and this is "i get the rate limit
    -- notification A LOT". Spotify's limits are rolling, so one limit is many
    -- cooldowns: the window closes, the next request re-arms it, and a notice that
    -- fired whenever the gate went from open to shut fired on every one of them. Its
    -- own clock, P.rate_say_every apart, so a limit that lasts ten minutes is one
    -- sentence rather than twenty.
    --
    -- SAYING IT IS THE CALLER'S, exactly as Util.net_note above says of itself and
    -- for the same reason: ui_say is a local declared several thousand lines below
    -- this, so a call from here is a global lookup and a nil call. What comes back is
    -- the sentence -- composed once, here, where the numbers are -- or nil when this
    -- arm is not worth interrupting anyone over.
    function Util.rate_arm(secs, headers)
        -- WHAT SPOTIFY ASKED FOR, NOT SIX TIMES IT.
        --
        -- Measured against the live API: a throttled request comes back
        -- `retry-after: 2`. Two seconds. This turned that into thirty.
        --
        -- The old floor was 5 "so a header of 1 cannot become a busy loop", and the
        -- old default was 30 for the callers that have no header to read -- the page
        -- batch, the library sweep, the search prefetch, a refused play. Between them
        -- a two-second nudge shut the gate for five seconds at best and thirty at
        -- worst, and the gate is GLOBAL: while it is closed every read in the app
        -- returns nil without asking. That is the whole app going dead -- the list not
        -- updating, the now-playing bar frozen, "could not play that", "No results" --
        -- for half a minute, because Spotify asked for two seconds.
        --
        -- There is no busy loop to protect against. The gate is not a retry loop; it
        -- is a skip. Nothing re-sends when it expires, the next thing you DO sends,
        -- and if that is still early Spotify says so again and this re-arms. Honouring
        -- the number costs one more refused request in the worst case and buys back
        -- the twenty-eight seconds the app spent pretending to be offline.
        --
        -- The ceiling stays: a pathological header must not take the app off the
        -- network for an hour. The default drops to 3, which is the size of the
        -- nudges this API actually sends.
        secs = tonumber(secs)
            or tonumber(string.match(headers or "", "[Rr]etry%-[Aa]fter:%s*(%d+)"))
            or 3
        secs = math.max(1, math.min(secs, 60))
        Util.shared_put("rate-cooldown", P.rate_cooldown, os.time() + secs)
        -- A background job arms the gate and never speaks: the gate is about the
        -- ACCOUNT, the notice is about the person looking at the screen.
        if Util.detached then return secs, nil end
        local said = Util.shared_num("rate-said", P.rate_said)
        if said and os.time() - said < P.rate_say_every then return secs, nil end
        Util.shared_put("rate-said", P.rate_said, os.time())
        return secs, "Spotify API rate limit reached (429)" .. SEP
                     .. "using cache for " .. secs .. "s"
    end

    -- WHY THAT DID NOTHING, when the answer is "Spotify said later".
    --
    -- A read that finds the gate shut returns nil, and every caller then says its own
    -- generic failure: "Failed to load playlist" for a playlist that is perfectly
    -- fine, "Failed to skip" for a player that is working. That is the whole of
    -- "selecting a playlist can sometimes do nothing and print the failed to load
    -- playlist message" -- the playlist was never the problem and the message named
    -- it anyway.
    --
    -- The gate knows the real reason and how long it has left, so it says so; the
    -- caller's own sentence is kept for the case that really is a failure. Wrapped
    -- around the message rather than replacing it, so a site that gains a new failure
    -- mode still says something true.
    -- ...AND EVERY READ THAT CAN FAIL WEARS IT. A nil from api_get means the gate
    -- was shut, or a 401, or a dead link -- never "Spotify looked and found nothing"
    -- -- so a site that answers one with "No playlists", "No albums found" or "Queue
    -- is empty" is claiming the read SUCCEEDED. Nine of them did, which is the same
    -- fault Util.open_search_results carried as "No results".
    --
    -- Wrapped rather than replaced, so a site whose fetch also answers nil for a
    -- genuinely empty list keeps the sentence that is true in that case and gains the
    -- real reason in the other.
    function Util.rate_why(fallback)
        local left = Util.rate_cool()
        if left <= 0 then return fallback end
        -- SAID IN FULL NOW AND THEN, NOT FIFTEEN TIMES A MINUTE.
        --
        -- Util.rate_arm learned this for its own notice -- "a limit that lasts ten
        -- minutes is one sentence rather than twenty" -- and this function, which is
        -- reached by every failed read in the app, never did. On a shared client id
        -- the gate is shut a good fraction of the time, so every list, every search
        -- and every detail sheet that missed its cache announced the rate limit
        -- again. The information is worth having once; after that it is the app
        -- telling you the same thing about itself over and over while you try to use
        -- it.
        --
        -- The repeat still SAYS something -- a read that did nothing must never look
        -- like a read that worked -- but it leads with what you were doing and tags
        -- the reason in two words. Same clock as Util.rate_arm's notice, so the long
        -- explanation and the short one do not both fire for the same window.
        local said = Util.shared_num("rate-said", P.rate_said)
        if said and os.time() - said < P.rate_say_every then
            -- WITH THE SECONDS. "rate limited" alone could not tell a ten-second
            -- window from a gate that never reopens; a number that counts down can.
            return fallback .. SEP .. "rate limited, " .. left .. "s"
        end
        Util.shared_put("rate-said", P.rate_said, os.time())
        return "Spotify is rate limiting" .. SEP .. "using cache -- retrying in " .. left .. "s"
    end

    -- WHICH SPOTIFY APP SPOOT IS SPEAKING AS.
    --
    -- Yours if you have registered one, and the shared fallback if you have not. A
    -- rate limit belongs to the APP, not to the account, so a single id compiled into
    -- every copy of spoot means one pool of requests split between everyone running
    -- it -- and there is nothing a well-behaved client can do about that from its own
    -- side.
    --
    -- REGISTERING YOUR OWN IS NOT THE FIX IT LOOKS LIKE, and this note used to say it
    -- was ("two minutes, and hands you the whole quota"). That was written before
    -- November 2024, when Spotify closed a set of endpoints to every app created
    -- after that date. The fallback id predates the change and still reaches them; a
    -- new one does not, and answers 403 or 404 instead:
    --
    --   browse/categories                 Categories
    --   browse/categories/{id}/playlists  Made For You, Discover Weekly, Charts
    --   browse/featured-playlists         Featured Playlists
    --   recommendations                   Discover by Genre
    --   available-genre-seeds             the genre list itself
    --   artists/{id}/related-artists      Related Artists
    --
    -- That is six of the nine Collections tiles plus a row in every artist menu. So
    -- the choice is a whole quota against a smaller app, and it is a real trade
    -- rather than an upgrade -- which is why the System sheet now states both halves
    -- instead of recommending one.
    --
    -- Nothing here changes for a registered id that is OLDER than the cutoff; those
    -- keep the access they had.
    --
    -- Validated rather than trusted: a Spotify app id is 32 hex characters, and a
    -- file holding a pasted-in newline, a URL or half a word would otherwise turn
    -- every request into a 400 with nothing saying why. Anything that is not an id
    -- falls back, so a bad paste degrades to the old behaviour instead of breaking
    -- authentication.
    --
    -- Read fresh each time rather than memoised: it changes about once in the life of
    -- an install, and the three callers are the OAuth handshake and the token
    -- refresh -- none of them hot, all of them ruined by a stale answer.
    function Util.client_id()
        local raw = trim(read_file(P.client) or "")
        if raw:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
            return raw
        end
        return P.spotify
    end

    -- EVERY REQUEST, WRITTEN DOWN, when asked for.
    --
    -- Util.http is the ONE way out of this process on both transports, so it is the
    -- only place that can answer "what is spoot actually asking for". Off unless
    -- SPOOT_REQLOG names a file, so it costs a single getenv on a path that is
    -- already doing network I/O.
    --
    -- It exists because every measurement of request volume so far was taken against
    -- the curl path, and the app people actually run is the embedded one -- which
    -- goes through Util.host.http above and was invisible to all of it.
    -- On Util, not as locals: the chunk body is at Lua's 200-local cap, which is why
    -- the file says so in half a dozen places.
    Util.REQLOG = os.getenv("SPOOT_REQLOG")
    function Util.req_log(req, code)
        if not Util.REQLOG then return end
        -- Private from the first byte: it names every request the account made.
        if not Util._reqlog_made then
            Util._reqlog_made = true
            local e = io.open(Util.REQLOG, "a")
            if e then e:close(); os.execute("chmod 600 " .. shell_quote(Util.REQLOG) .. " 2>/dev/null") end
        end
        local f = io.open(Util.REQLOG, "a")
        if not f then return end
        -- The BODY too, for writes: a play is entirely described by its body -- which
        -- context, which offset -- and without it the log says a play happened but
        -- not what it asked for. EXCEPT a login's: a refresh token or an
        -- authorization code is a credential, and a debug log is not a place for one.
        local body = req.body
        if type(body) == "table" then body = "(table)" end
        if tostring(req.url or ""):match("^https?://accounts%.spotify%.com") then
            body = body and "(redacted)" or nil
        end
        f:write(string.format("%s\t%s\t%s\t%s\t%s\n", tostring(Util.mono and Util.mono() or os.time()),
            tostring(code or "-"), tostring(req.method or "GET"), tostring(req.url or "?"),
            tostring(body or "")))
        f:close()
    end

    -- WHAT ONE REQUEST SAYS ABOUT THE LINK. Any answer at all, from anywhere, proves
    -- it is up, so that always clears the gate. But only SPOTIFY failing to answer
    -- may shut it: a cover off the CDN or a lyrics lookup against lrclib timing out
    -- is that host being slow, and it used to take every Spotify request in the
    -- engine off the network for NET_DOWN_SECS with it.
    function Util.net_seen(req, code)
        if code and code > 0 then return Util.net_note(code) end
        local host = tostring(req and req.url or ""):match("^https?://([^/:?#]+)") or ""
        if host == "api.spotify.com" or host == "accounts.spotify.com" then Util.net_note(code) end
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
            Util.req_log(req, r and r.code)
            -- `bg` answers 0 by design -- it waits for nothing -- so it must not be
            -- read as the link being down.
            if not req.bg then Util.net_seen(req, r and r.code) end
            return r
        end
        local hdr = Util.api_hdr_path()
        local c = {"curl -s --max-time ", tostring(req.timeout or 10)}
        if req.compressed then c[#c+1] = " --compressed" end
        -- No header dump for `bg`: nothing reads it, and a backgrounded curl
        -- writing the shared file could clobber a foreground request's Retry-After.
        if not req.bg then c[#c+1] = " -D " .. shell_quote(hdr) end
        c[#c+1] = " -w '\\n%{http_code}'"
        if req.method and req.method ~= "GET" then c[#c+1] = " -X " .. shell_quote(req.method) end
        -- HEADERS IN A CONFIG FILE, not on argv. An Authorization header on the
        -- command line is readable by every local user through /proc for as long
        -- as the request runs; the config sits in the 0700 scratch directory,
        -- which is how Util.curl_batch has always sent its token.
        local cfg
        if req.headers and #req.headers > 0 then
            cfg = Util.tmpfile("curlhdr")
            local f = io.open(cfg, "w")
            if f then
                for _, h in ipairs(req.headers) do
                    f:write('header = "', Util._curl_cfg_quote(h), '"\n')
                end
                f:close()
                c[#c+1] = " -K " .. shell_quote(cfg)
            else
                cfg = nil
            end
        end
        -- --data-raw, not -d: -d reads a FILE when the body starts with "@".
        if req.body ~= nil then c[#c+1] = " --data-raw " .. shell_quote(req.body) end
        c[#c+1] = " " .. shell_quote(req.url)
        if req.bg then
            -- Backgrounded, output discarded, nothing awaited -- and the config
            -- removed once curl has finished with it.
            os.execute("{ " .. table.concat(c) .. " > /dev/null 2>&1"
                .. (cfg and ("; rm -f " .. shell_quote(cfg)) or "") .. "; } &")
            return {code = 0, body = "", headers = ""}
        end
        local r = shell(table.concat(c)) or ""
        if cfg then os.remove(cfg) end
        local out = {code = tonumber(r:match("\n(%d+)\n?$")) or 0,
                     body = r:match("^(.-)\n%d+\n?$") or "",
                     headers = read_file(hdr) or ""}
        Util.net_seen(req, out.code)
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
        -- spotifyd unless told otherwise, matching the host's mprisName: a bare
        -- playerctl picks whichever player it likes, which may be a browser tab.
        local pc = "playerctl -p " .. shell_quote(req.player or "spotifyd")
        local op, v = req.op, req.value
        local function run(args)
            return trim(shell(pc .. " " .. args .. " 2>/dev/null") or "")
        end
        local function did(args)
            local r = os.execute(pc .. " " .. args .. " 2>/dev/null")
            return {ok = r == true or r == 0}
        end
        -- GetAll has no playerctl spelling; Util.player_state reads this as "ask
        -- for each field on its own".
        if op == "state" then return {ok = false, unsupported = true} end
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
        elseif (op == "setvol" or op == "setpos" or op == "seek") and tonumber(v) == nil then
            return {ok = false}
        elseif op == "setvol" then
            return did("volume " .. string.format("%.2f", v))
        elseif op == "setpos" then
            return did("position " .. string.format("%.2f", v))
        elseif op == "seek" then
            -- playerctl spells a relative seek "10+" / "10-" rather than with a sign.
            return did("position " .. string.format("%.2f", math.abs(v)) .. (v < 0 and "-" or "+"))
        end
        -- Named verbs only: `op` goes onto a shell line unquoted.
        local VERBS = {play = true, pause = true, ["play-pause"] = true,
                       next = true, previous = true, stop = true}
        if not VERBS[op] then return {ok = false} end
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
        --
        -- THE HEADERS RIDE ALONG as a second return. Every existing caller reads only
        -- the first value and is untouched -- but a 429 carries Retry-After, and
        -- without it the one write that matters had to guess. Measured against the
        -- live API: a refused play answers `retry-after: 17` where the guess was 3, so
        -- spoot stood down for three seconds and then walked straight back into a
        -- seventeen-second window. Spotify ESCALATES a repeat on a throttled endpoint
        -- -- 2s, then 12s, then 17s -- so guessing low is not a small error. It is the
        -- thing that keeps the throttle alive.
        return opts.raw and r.body or tostring(r.code), r.headers
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
end
