-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- spoot Spotify Client ~ Part of the ZENWORKS Suite
-- https://github.com/kbuckleys/

-- PROCESSES AND MARKUP: whether a pid file still names one of ours (read from
-- /proc, never a fork), the clipboard, and the two passes every row's text goes
-- through -- escaping it for markup, and stripping it back to what is shown.
--
-- An installer, like the rest of lib/. pid_str was a file local of spoot.lua
-- with no reader outside this code, so it came along.
return function(Util, ctx)
    local read_file, shell, trim = ctx.read_file, ctx.shell, ctx.trim

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
end
