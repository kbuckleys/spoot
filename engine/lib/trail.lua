-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- spoot Spotify Client ~ Part of the ZENWORKS Suite
-- https://github.com/kbuckleys/

-- TAB'S CARD: Trail Steps -- the path you are standing on, any step of which you
-- can jump back to -- and Trail History, the menus you have closed. Picking a
-- step sends the UI a `jump`; picking a closed menu sends it a `restore` with
-- the path to it (see main.qml's goBack, which walks that path back up).
--
-- An installer, like the rest of lib/. ui_menu and ui_say arrive as WRAPPERS:
-- serve mode replaces both after this is loaded, so a plain reference taken now
-- would be the error stubs they start as.
return function(Util, ctx)
    local json = ctx.json
    local ui_menu, ui_say = ctx.ui_menu, ctx.ui_say
    local replay_session, view_label = ctx.replay_session, ctx.view_label

    -- Mode 2, Trail History: menus you closed that the trail no longer offers.
    --
    -- Rows are rendered from Util.parts_from_stack, the same function the breadcrumb
    -- and mode 1 use, so a step can never be named one way here and another there.
    -- The destination reads first and its context recedes behind it; rofi filters on
    -- the whole line, so typing either one finds the row.
    function Util.menu_hist_rows(live)
        local rows, entries = {}, {}
        local function reachable(path) return Util.stack_prefix(path, live) end
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
                    -- A PLACE WITH A PAST, handed to the UI to walk into. This used to
                    -- install the stack and draw its leaf right here, inside the trail
                    -- menu's own step -- so the trail held one hop for the whole
                    -- restored path, and Backspace from an album five menus deep
                    -- dropped straight back to wherever Trail History was opened,
                    -- which from Main is Main. The UI now appends a `restore` hop
                    -- (see SERVE_VIEWS.restore), and Backspace on it walks the path
                    -- back up one menu at a time. Same shape as the trail's own `jump`.
                    if e and type(e.stack) == "table" and #e.stack > 0 then
                        if Util.serving then
                            Util.serve_write({ev = "restore", stack = e.stack})
                            return
                        end
                        Util.session_set(json.decode(json.encode(e.stack)))
                    end
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
end
