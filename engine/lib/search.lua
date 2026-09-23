-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- spoot Spotify Client ~ Part of the ZENWORKS Suite
-- https://github.com/kbuckleys/

-- WHAT A SEARCH IS: the six types it covers, the pages its results are split
-- into, the query string and cache key one search is known by, and the names of
-- the P.mass files that hold caches keyed by arbitrary text. The request itself
-- (api_search) and the view stay in spoot.lua; this is the vocabulary they share.
--
-- An installer, like the rest of lib/. SEARCH_PAGES reads Util.is_video_show as
-- it is built, which spoot.lua defines long before this is loaded.
return function(Util, ctx)
    local P = ctx.P
    local mem_bust, shell_quote, url_encode = ctx.mem_bust, ctx.shell_quote, ctx.url_encode

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
end
