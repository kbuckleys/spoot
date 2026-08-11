-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

hl.window_rule({ match = { class = "mpv" },                               float = true, })
hl.window_rule({ match = { class = "swayimg" },                           float = true })
hl.window_rule({ match = { class = "xdg-desktop-portal-gtk" },            float = true, size = { 1000, 1000 }})
hl.window_rule({ match = { class = "re.fossplant.songrec" },              float = true, size = { 800, 1100 }})
hl.window_rule({ match = { class = "kitty", title = "termfilechooser" },  float = true, size = {1000, 450}})
hl.window_rule({ match = { class = "kitty", title = "runner" },           float = true, size = {1000, 1000}})
hl.window_rule({ match = { class = "steam", title = "Steam Settings" },   float = true})
hl.window_rule({ match = { class = "kitty", title = "bandwhich" },        float = true, size = { 1000, 800 }})
hl.window_rule({ match = { class = "kitty",title = "sysmon" },            float = true, size = { 1000, 1100 }})
hl.window_rule({ match = { class = "kitty",title = "Wiremix" },           float = true, size = { 650, 650 }})
hl.window_rule({ match = { class = "kitty",title = "ZENU" },              float = true, size = { 1000, 1100 }})

-- BORDERS
hl.window_rule({ match = { fullscreen = true },  border_color = "#fab38799"})
hl.window_rule({ match = { float = true },       border_color = "#b6e0a499"})

-- SHADOWS (only floating)
hl.window_rule({ match = { float = false }, no_shadow = true })

-- SPECIAL WORKSPACE
hl.workspace_rule({ workspace = "special:special", gaps_out = 30 })
