-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- spoot Spotify Client ~ Part of the ZENWORKS Suite
-- https://github.com/kbuckleys/

-- COVER URLS AND COVER FILES -- the pure half of spoot's artwork: rewriting a
-- CDN url to the rendition wanted, naming the image a url points at, and
-- deciding whether a file on disk is a whole, drawable picture.
--
-- The first piece moved out of engine/spoot.lua. That file is one chunk, and a
-- Lua chunk may hold 200 locals -- the ceiling behind every "On Util, not a
-- local" note in it. A module's own functions do not count against it.
--
-- AN INSTALLER, NOT A LIBRARY: spoot.lua calls this with its Util table and
-- every function lands on Util under the name it always had, so no call site
-- anywhere changed. Nothing here reads a file local of spoot.lua -- only Util,
-- which is passed in, and the standard library.
return function(Util)
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
    -- Neither transport ever says nil: a request the clock cut off, or one that
    -- never started, comes back as "0" from the host and "000" from curl. Both
    -- are the never-reached-the-server case, and were being written off as dead.
    Util.art_retry_worthwhile = function(code, truncated)
        if code == nil then return true end          -- never reached the server
        if truncated then return true end            -- arrived short
        local n = tonumber(code)
        if not n then return false end
        if n == 0 then return true end               -- no answer at all
        return n == 408 or n == 429 or n >= 500      -- server said "later"
    end
end
