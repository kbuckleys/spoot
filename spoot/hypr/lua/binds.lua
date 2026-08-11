-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

-- DEFAULTS
local term = "kitty -1"
local web = "helium-browser"
local fman = term .. " yazi"

-- MISC
hl.bind("SUPER + SHIFT + ESCAPE",  hl.dsp.exec_cmd("hyprshutdown"), { locked = true })
hl.bind("SUPER + SHIFT + S",       hl.dsp.exec_cmd(term .. " -T sysmon btop"))
hl.bind("SUPER + RETURN",          hl.dsp.exec_cmd(term))
hl.bind("SUPER + P",               hl.dsp.exec_cmd(term .. " -T ZENU ~/.config/scripts/ZENU.lua"))
hl.bind("SUPER + SHIFT + P",       hl.dsp.exec_cmd(term .. " -T ZENU ~/.config/scripts/ZENU.lua update"))
hl.bind("SUPER + CONTROL + P",     hl.dsp.exec_cmd("hyprpicker -a"))
hl.bind("SUPER + Y",               hl.dsp.exec_cmd("killall -SIGUSR1 waybar"))
hl.bind("SUPER + SHIFT + Y",       hl.dsp.exec_cmd("killall waybar && waybar"))
hl.bind("SUPER + E",               hl.dsp.exec_cmd(fman))
hl.bind("SUPER + B",               hl.dsp.exec_cmd(web))

hl.bind("SUPER + SHIFT + H", function()
    hl.clear_crashed_lockscreen()
    hl.exec_cmd("hyprlock")
end, { locked = true })

-- ROFI
hl.bind("SUPER + ESCAPE",     hl.dsp.exec_cmd("~/.config/rofi/scripts/session/session.lua"))
hl.bind("SUPER + SPACE",      hl.dsp.exec_cmd("~/.config/rofi/scripts/runner/runner.lua"))
hl.bind("SUPER + C",          hl.dsp.exec_cmd("~/.config/rofi/scripts/cliphist/cliphist.lua"))
hl.bind("SUPER + SHIFT + C",  hl.dsp.exec_cmd("~/.config/rofi/scripts/calc/calc.lua"))
hl.bind("SUPER + S",          hl.dsp.exec_cmd("~/.config/rofi/scripts/rootsearch/rootsearch.lua"))
hl.bind("SUPER + J",          hl.dsp.exec_cmd("~/.config/rofi/scripts/rofimoji/rofimoji.lua"))
hl.bind("SUPER + SHIFT + J",  hl.dsp.exec_cmd("~/.config/rofi/scripts/nerd/nerd.lua"))
hl.bind("SUPER + M",          hl.dsp.exec_cmd("~/.config/rofi/scripts/spoot/spoot.lua"))
hl.bind("SUPER + SHIFT + M",  hl.dsp.exec_cmd("~/.config/rofi/scripts/spoot/spoot.lua --listen"))
hl.bind("SUPER + V",          hl.dsp.exec_cmd("~/.config/rofi/scripts/rbw/rbw.lua"))
hl.bind("SUPER + K",          hl.dsp.exec_cmd("~/.config/rofi/scripts/hitman/hitman.lua"))
hl.bind("SUPER + D",          hl.dsp.exec_cmd("~/.config/rofi/scripts/dictionary/dictionary.lua"))

-- WORKSPACES
hl.bind("SUPER + GRAVE",  hl.dsp.workspace.toggle_special("special"))
hl.bind("SUPER + 1",      hl.dsp.focus({ workspace = 1 }))
hl.bind("SUPER + 2",      hl.dsp.focus({ workspace = 2 }))
hl.bind("SUPER + 3",      hl.dsp.focus({ workspace = 3 }))
hl.bind("SUPER + 4",      hl.dsp.focus({ workspace = 4 }))
hl.bind("SUPER + 5",      hl.dsp.focus({ workspace = 5 }))

local function move_and_center(ws)
	hl.dispatch(hl.dsp.window.move({ workspace = ws }))
	local win = hl.get_active_window()
	if win and win.floating then
		hl.dispatch(hl.dsp.window.center())
	end
end

hl.bind("SUPER + SHIFT + GRAVE",  function() move_and_center("special:special") end)
hl.bind("SUPER + SHIFT + 1",      function() move_and_center(1) end)
hl.bind("SUPER + SHIFT + 2",      function() move_and_center(2) end)
hl.bind("SUPER + SHIFT + 3",      function() move_and_center(3) end)
hl.bind("SUPER + SHIFT + 4",      function() move_and_center(4) end)
hl.bind("SUPER + SHIFT + 5",      function() move_and_center(5) end)

-- WINDOW MANIPULATION
hl.bind("SUPER + SHIFT + F",  hl.dsp.window.fullscreen())
hl.bind("SUPER + SHIFT + W",  hl.dsp.window.center())
hl.bind("SUPER + SHIFT + Q",  hl.dsp.window.kill())
hl.bind("SUPER + X",          hl.dsp.layout("togglesplit"))
hl.bind("SUPER + W",          hl.dsp.window.pseudo())
hl.bind("SUPER + Q",          hl.dsp.window.close())
hl.bind("SUPER + Z",          hl.dsp.window.fullscreen({ mode = "maximized" }))

hl.bind("SUPER + F", function()
    hl.dispatch(hl.dsp.window.float({ action = "toggle" }))
    hl.dispatch(hl.dsp.window.center())
end)

-- Mouse
hl.bind("SUPER + mouse:272",  hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273",  hl.dsp.window.resize(), { mouse = true })

-- Focus
hl.bind("SUPER + RIGHT",  hl.dsp.focus({ direction = "r" }))
hl.bind("SUPER + DOWN",   hl.dsp.focus({ direction = "d" }))
hl.bind("SUPER + LEFT",   hl.dsp.focus({ direction = "l" }))
hl.bind("SUPER + UP",     hl.dsp.focus({ direction = "u" }))

-- Resize
hl.bind("SUPER + CONTROL + RIGHT",  hl.dsp.window.resize({ x = 100, y = 0, relative = true }), { repeating = true })
hl.bind("SUPER + CONTROL + DOWN",   hl.dsp.window.resize({ x = 0, y = 100, relative = true }), { repeating = true })
hl.bind("SUPER + CONTROL + LEFT",   hl.dsp.window.resize({ x = -100, y = 0, relative = true }), { repeating = true })
hl.bind("SUPER + CONTROL + UP",     hl.dsp.window.resize({ x = 0, y = -100, relative = true }), { repeating = true })

-- Swap Window
hl.bind("SUPER + ALT + RIGHT",  hl.dsp.window.swap({ direction = "r" }), { description = "Swap window to the right" })
hl.bind("SUPER + ALT + DOWN",   hl.dsp.window.swap({ direction = "d" }), { description = "Swap window down" })
hl.bind("SUPER + ALT + LEFT",   hl.dsp.window.swap({ direction = "l" }), { description = "Swap window to the left" })
hl.bind("SUPER + ALT + UP",     hl.dsp.window.swap({ direction = "u" }), { description = "Swap window up" })

-- Window Switching
hl.bind("SUPER + TAB", function()
    hl.dispatch(hl.dsp.window.cycle_next())
    hl.dispatch(hl.dsp.window.bring_to_top())
end)

hl.bind("SUPER + SHIFT + TAB", function()
    local ws = hl.get_active_workspace()
    if not ws then return end

    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "bottom" }))

    local top
    for _, win in ipairs(hl.get_windows({ workspace = ws, mapped = true })) do
        if not win.hidden then top = win end
    end
    if top then
        hl.dispatch(hl.dsp.focus({ window = top }))
    end
end)

-- GROUPING
hl.bind("SUPER + SHIFT + G",  hl.dsp.group.toggle())
hl.bind("SUPER + G",          hl.dsp.group.lock_active({ action = "toggle" }))

hl.bind("ALT + SHIFT + TAB",  hl.dsp.group.prev(), { repeating = true })
hl.bind("ALT + TAB",          hl.dsp.group.next(), { repeating = true })

hl.bind("SUPER + SHIFT + ALT + RIGHT",  hl.dsp.window.move({ into_group = "r" }))
hl.bind("SUPER + SHIFT + ALT + DOWN",   hl.dsp.window.move({ into_group = "d" }))
hl.bind("SUPER + SHIFT + ALT + LEFT",   hl.dsp.window.move({ into_group = "l" }))
hl.bind("SUPER + SHIFT + ALT + UP",     hl.dsp.window.move({ into_group = "u" }))

hl.bind("SUPER + SHIFT + CONTROL + RIGHT",  hl.dsp.window.move({ out_of_group = true }))
hl.bind("SUPER + SHIFT + CONTROL + DOWN",   hl.dsp.window.move({ out_of_group = true }))
hl.bind("SUPER + SHIFT + CONTROL + LEFT",   hl.dsp.window.move({ out_of_group = true }))
hl.bind("SUPER + SHIFT + CONTROL + UP",     hl.dsp.window.move({ out_of_group = true }))

-- AUDIO
hl.bind("SUPER + EQUAL",  hl.dsp.exec_cmd("pamixer -i 1"), { repeating = true })
hl.bind("SUPER + MINUS",  hl.dsp.exec_cmd("pamixer -d 1"), { repeating = true })
hl.bind("SUPER + 9",      hl.dsp.exec_cmd(term .. " -T Wiremix wiremix"))
hl.bind("SUPER + 0",      hl.dsp.exec_cmd("pamixer -t"))

hl.bind("SUPER + SHIFT + EQUAL",  hl.dsp.exec_cmd("playerctl next"))
hl.bind("SUPER + SHIFT + MINUS",  hl.dsp.exec_cmd("playerctl play-pause"))
hl.bind("SUPER + SHIFT + 0",      hl.dsp.exec_cmd("playerctl previous"))

-- SCREEN ZOOM
local MAX_ZOOM = 10
local ZOOM_TOGGLE_FACTOR = 0.5

local function zoom(offset)
    local current = hl.get_config("cursor.zoom_factor")
    if offset ~= nil then
        if current == 0 then
            current = 1
        end
        current = current + offset
    elseif current ~= 0 then
        current = 0
    else
        current = ZOOM_TOGGLE_FACTOR
    end
    if current <= 1 then
        current = 0
    else
        current = math.min(MAX_ZOOM, current)
    end
    hl.config({ cursor = { zoom_factor = current } })
end

hl.bind("SUPER + CTRL + 0", zoom)
hl.bind("SUPER + CTRL + EQUAL", function()
    zoom(0.2)
end, { repeating = true })
hl.bind("SUPER + CTRL + MINUS", function()
    zoom(-0.2)
end, { repeating = true })

hl.bind("SUPER + CTRL + mouse:274", zoom)
hl.bind("SUPER + CTRL + mouse_up", function()
    zoom(0.2)
end)
hl.bind("SUPER + CTRL + mouse_down", function()
    zoom(-0.2)
end)
