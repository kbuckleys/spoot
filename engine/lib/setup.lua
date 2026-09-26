-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- spoot Spotify Client ~ Part of the ZENWORKS Suite
-- https://github.com/kbuckleys/

-- WHAT A FIRST RUN STILL OWES: the programs spoot needs on PATH, the Spotify
-- login (token.json) and the playback device's own login (spotifyd's
-- credentials) -- asked by `--doctor`, by the UI at startup, and by the setup
-- flow that walks you through the two logins.
--
-- An installer, like the rest of lib/.
return function(Util, ctx)
    local P = ctx.P
    local read_file, shell, shell_quote, trim = ctx.read_file, ctx.shell, ctx.shell_quote, ctx.trim

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
        -- Only when it has actually happened. See get_token: the running session is
        -- fine and the copy on disk is not, which is invisible until the next launch
        -- asks you to sign in again -- so it is worth a line while someone is looking.
        if Util.token_unsaved then
            L[#L+1] = "          WARNING -- the refreshed credential could not be written to"
            L[#L+1] = "          " .. P.token .. ". This session keeps working;"
            L[#L+1] = "          the next launch will ask you to sign in again."
        end
        L[#L+1] = "device:   " .. (st.device and "authorised"
                                   or "NOT authorised (spotifyd has no credentials, so nothing plays)")
        -- WHOSE RATE LIMIT THIS INSTALL SPENDS, which is the first thing to know when
        -- everything answers 429 and you have done nothing. See Util.client_id.
        local cid = Util.client_id()
        local pad = "\n                                        "
        L[#L+1] = "client:   " .. cid .. (cid == P.spotify
            and "  (SHARED -- every spoot install uses this one, so its rate limit is"
                .. pad .. "split between all of them. Registering your own at"
                .. pad .. "developer.spotify.com/dashboard (redirect URI"
                .. pad .. "http://127.0.0.1:8989/login, then: spoot --client-id <id>)"
                .. pad .. "gives you a pool of your own. Measured on this account,"
            .. pad .. "same endpoint and rate: shared id 8 of 12 refused, a"
            .. pad .. "private one 0 of 12. An app created after"
                .. pad .. "Nov 2024 loses Categories, Made For You, Discover Weekly,"
                .. pad .. "Charts, Featured Playlists, Discover by Genre and Related"
                .. pad .. "Artists -- Spotify closed those endpoints to new apps."
                .. pad .. "This id predates that. It is a trade, not an upgrade.)"
            or "  (your own)")
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
            Util.wait(0.1)
        end
        if url then os.execute("xdg-open " .. shell_quote(url) .. " >/dev/null 2>&1 &") end
        -- The credentials file appearing IS the success signal -- the same "believe
        -- the system, not the exit code" rule the dependency install follows.
        for _ = 1, 180 do
            if Util.device_ready() then break end
            Util.wait(1)
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
end
