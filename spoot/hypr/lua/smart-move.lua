-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

local smart_move = {}

-- Helper to check if active window is floating
local function is_window_floating()
	local window = hl.get_active_window()
	return window and window.floating or false
end

function smart_move.smart_move(direction)
	if is_window_floating() then
		-- Floating: move by absolute pixels (50px)
		local dx, dy = 0, 0
		if direction == "l" then
			dx = -50
		elseif direction == "r" then
			dx = 50
		elseif direction == "u" then
			dy = -50
		elseif direction == "d" then
			dy = 50
		end
		hl.dispatch(hl.dsp.window.move({ x = dx, y = dy, relative = true }))
	else
		-- Tiled: swap directionally
		hl.dispatch(hl.dsp.window.move({ direction = direction }))
	end
end

-- BINDS
hl.bind("SUPER + SHIFT + LEFT", function()
	smart_move.smart_move("l")
end, { repeating = true })

hl.bind("SUPER + SHIFT + RIGHT", function()
	smart_move.smart_move("r")
end, { repeating = true })

hl.bind("SUPER + SHIFT + UP", function()
	smart_move.smart_move("u")
end, { repeating = true })

hl.bind("SUPER + SHIFT + DOWN", function()
	smart_move.smart_move("d")
end, { repeating = true })

-- SNAP TO EDGE
hl.bind("SUPER + SHIFT + CONTROL + LEFT", function()
	hl.dispatch(hl.dsp.window.move({ direction = "l" }))
end)

hl.bind("SUPER + SHIFT + CONTROL + RIGHT", function()
	hl.dispatch(hl.dsp.window.move({ direction = "r" }))
end)

hl.bind("SUPER + SHIFT + CONTROL + UP", function()
	hl.dispatch(hl.dsp.window.move({ direction = "u" }))
end)

hl.bind("SUPER + SHIFT + CONTROL + DOWN", function()
	hl.dispatch(hl.dsp.window.move({ direction = "d" }))
end)

return smart_move
