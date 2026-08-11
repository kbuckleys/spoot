-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

-- MONITORS
hl.monitor({ output = "DP-1",      mode = "2560x1440@180",  position = "auto", })
hl.monitor({ output = "HDMI-A-1",  mode = "1920x1080@100",  position = "auto", transform = 3, })

-- ENV
-- Nvidia cache limit set to 20 GB
hl.env("__GL_SHADER_DISK_CACHE_SIZE", "21474836480")
hl.env("__GL_SHADER_DISK_CACHE_SKIP_CLEANUP", "1")

-- CURSOR
hl.env("HYPRCURSOR_THEME", "GoogleDot-Black")
hl.env("XCURSOR_THEME", "GoogleDot-Black")
hl.env("HYPRCURSOR_SIZE", "6")
hl.env("XCURSOR_SIZE", "6")

hl.config({
	misc = {
		allow_session_lock_restore = true,
		font_family = "JetBrainsMono Nerd Font Propo",
		disable_splash_rendering = true,
		initial_workspace_tracking = 0,
		close_special_on_empty = true,
		disable_hyprland_logo = true,
		background_color = 0x000000,
		middle_click_paste = false,
	},

	ecosystem = {
		no_donation_nag = true,
	},

	input = {
		accel_profile = "flat",
        focus_on_close = 2,
		sensitivity = -0.6,
		repeat_delay = 200,
		repeat_rate = 35,
	},

	general = {
        layout = "scrolling",
		col = {
			inactive_border = "#9bbfbf4d",
			active_border = "#9bbfbfcc",
		},
		gaps_out = 4,
		gaps_in = -1,
		snap = {
			enabled = true,
            border_overlap = true,
		},
	},

	dwindle = {
		preserve_split = true,
	},
    scrolling = {
        column_width = 0.95,
        focus_fit_method = 0,
        wrap_focus = true,
    },
	decoration = {
		dim_special = 0.8,
		blur = {
            enabled = false
		},
		shadow = {
            range = 200,
            render_power = 1,
            offset = { 0, 20 },
            scale = 0.9,
            color = "rgba(0,0,0,0.6)",
            color_inactive = "rgba(0,0,0,0.4)",
		},
	},

	group = {
		col = {
            border_locked_inactive = "#e78284",
			border_locked_active = "#e78284",
			border_inactive = "#eebebe",
			border_active = "#eebebe",
		},
		groupbar = {
			text_color_inactive = "#dfdfdd",
			col = {
				locked_active = "#e78284",
				locked_inactive = "#20242a",
				active = "#eebebe",
				inactive = "#20242a",
			},
			font_family = "JetBrainsMono Nerd Font Propo",
			text_color = "#000000",
			font_weight_active = "bold",
			indicator_height = 0,
			gradients = true,
			font_size = 14,
			gaps_out = 0,
			rounding = 0,
			gaps_in = 0,
			height = 24,
		},
	},

	binds = {
		hide_special_on_workspace_change = true,
		scroll_event_delay = 0,
	},
})
