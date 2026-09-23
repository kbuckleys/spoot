-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- spoot Spotify Client ~ Part of the ZENWORKS Suite
-- https://github.com/kbuckleys/

-- WHAT SPOOT REMEMBERS BETWEEN LAUNCHES, as opposed to what it caches from
-- Spotify: the UI settings and the two player toggles, where each episode was
-- left, which row each menu's cursor was on, the search history and which page
-- each query was left on, and the menus you have closed. Small JSON files under
-- P.cache, each with one reader and one writer here.
--
-- An installer, like lib/art.lua and lib/transport.lua. `ctx` carries the file
-- helpers spoot.lua owns -- read_file, write_file, safe_decode, trim, and the
-- disk_get/disk_set envelope every cache in the app shares -- so these files are
-- written exactly the way the rest are.
return function(Util, ctx)
    local P, json = ctx.P, ctx.json
    local read_file, write_file, safe_decode, trim =
        ctx.read_file, ctx.write_file, ctx.safe_decode, ctx.trim
    local disk_get, disk_set = ctx.disk_get, ctx.disk_set

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

    -- EPISODE RESUME -- see P.eresume.

    -- Returns the stored position (nil when there is none) AND whether the episode
    -- was finished here. Two values because "no position" is true of both a
    -- never-played episode and one played to the end, and only the second should be
    -- dimmed as played.
    --
    -- Every caller assigns or compares -- never concatenates -- for the reason
    -- spelled out above Util.strip_markup.
    -- ONE READ PER DRAW, NOT ONE PER ROW. Util.episode_progress asks for every
    -- episode row it renders, and a show's list is two hundred of them -- each a
    -- read and a decode of the same file. Held for two seconds, which covers a
    -- draw; this state's own writes replace it at once, and another state's
    -- (the recorder in a job) are picked up two seconds later.
    function Util.eresume_map()
        local now = os.time()
        if Util._eres and now - Util._eres_at < 2 then return Util._eres end
        local m = disk_get(P.eresume)
        Util._eres, Util._eres_at = (type(m) == "table") and m or {}, now
        return Util._eres
    end

    function Util.eresume_get(id)
        if not id then return nil, false end
        local m = Util.eresume_map()
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
        -- Fresh from disk, never the memo: this rewrites the whole file.
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
        Util._eres, Util._eres_at = m, os.time()
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
        -- Locked like every other read-modify-write of a shared cache: a refresh
        -- landing between the read and the write below would otherwise be
        -- overwritten with the old payload, stamped as current.
        return Util.locked("cache:" .. path, function()
            local raw = read_file(path)
            if not raw then return false end
            -- Counted first: a replace capped at one could never see a second hit.
            local _, hits = raw:gsub('"fetched_at":%s*%d+', "%0")
            if hits ~= 1 then return false end
            local out = raw:gsub('"fetched_at":%s*%d+', '"fetched_at":' .. os.time(), 1)
            -- write_file answers os.rename's nil-on-failure, not false, so this is a
            -- truthiness test rather than a comparison.
            return not not write_file(path, out)
        end)
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
                                "category_id", "show_id", "episode_id", "setting",
                                "query", "category", "genre"}) do
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
end
