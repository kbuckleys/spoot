<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://github.com/user-attachments/assets/5b4d8a87-b8d6-4f07-941c-a3361f5ba01f">
  <img src="https://github.com/user-attachments/assets/5b4d8a87-b8d6-4f07-941c-a3361f5ba01f" alt="spoot">
</picture></p>

<h3 align="center">
<b>A keyboard-first Spotify client</b> --  Part of the <a href="https://github.com/kbuckleys/ZENWORKS">ZENWORKS</a> Suite
</h3>

# The philosophy behind spoot
Spotify clients (official one included) are too big and often glorified in comparison to what they're supposed to do. An optimal music player (for me, personally) should be something small, clear, easy and quick to interact with, which no player that I know of delivers. The original iteration and purpose of spoot was to act as a quick control panel for [spotify-player](https://github.com/aome510/spotify-player) which back then was my Spotify client of choice, but even that player -despite its speed and accessibility- wasn't enough for my use case. spoot was meant to bridge that gap, think of it as a remote control for your stereo system.

But as spoot's development pressed on, it became mature enough to be its own player, with its own small but comprehensive ecosystem. The idea was to be able to quickly access my library from anywhere, and do whatever I'd typically do on a desktop Spotify client without having to bring up a window cluttered to the brim with distractions and corporate directives, disrupting my workflow in the process. That's the point of spoot. A music player should not have to be a dedicated space governing and imposing its own rules instead of catering to the user. Music players can be better, smaller and quicker without having to sacrifice functionality or user experience.

But most importantly, a music player should pretty much know its place. It's not the user's center of attention.

# Limitations:
Third-party Spotify clients are inherently bound to what the Spotify Web API allows, and spoot is no exception. I felt obligated to be upfront about what spoot cannot do, for reassurance and to save your time

- **Remove from queue -- Spotify Web API limitation**
  - Local queue can be implemented as an alternative. In which case it will provide full control over its functions. However...
    - It adds complexity and relative bloat for what it's supposed to do
    - Local implementation also means zero sync with other Spotify clients/connect devices

- **Recently Played is purely local -- ```spotifyd``` quirk**
  - The live counterpart seems to suffer from issues through the daemon itself, even with the Activity Sharing privacy setting enabled. May be revisited in future iterations but it's highly unlikely

- **Episode progress retention**
  - like Recently Played, the same ```spotifyd``` limitation extends to your episode progress, thus, it's also purely local, but works incredibly well throughout cold starts
 
- **Lyrics use LRCLIB**
  - While I'd love to use Spotify's own database, it's currently reserved to the official client's internal use. Possible to implement, but breaks the ToS

- **Crossfade**
  - `librespot` -which is what ```spotifyd``` wraps- can only decode one stream at a time, so a true overlapping crossfade isn't possible. However, an implementation of a pseudo alternative is doable but it won't realistically make for a positive addition. The overall value of such implementation simply doesn't justify the added complexity and costly bloat
    
    > This was already tested in an internal build, it required an additional separate process dedicated just for the function of detecting starting and near-ending tracks. It was also fighting playerctl's volume during its 5s-windows and ended up reserving a significant chunk in the codebase. In the end; it wasn't exactly smart enough to detect tracks that already start loud/pitched, resulting in this track criteria not starting off as they were intended by their artists. The cons vastly outweighed the pros, thus scrapped

# Dependencies
The included install script can automatically take care of everything for you, but it's important to be clear about what spoot requires

**Required:** ```Wayland session``` &nbsp; ```Spotify Premium``` &nbsp; ```Qt 6.5+``` &nbsp; ```LayerShellQt 6.1+``` &nbsp; ```Lua 5.4+ (with headers)``` &nbsp; ```lua-cjson``` &nbsp; ```spotifyd 0.4+``` &nbsp; ```openssl``` &nbsp; ```xdg-utils``` &nbsp; ```procps-ng``` &nbsp; ```JetBrainsMono Nerd Font (Propo)```

**Optional:** ```songrec``` + ```parec``` (pulseaudio-utils) for Listen

**Only when running the engine outside the spoot binary** (`lua engine/spoot.lua`, `SPOOT_FORCE_CURL`, `SPOOT_FORCE_PLAYERCTL`): ```curl``` &nbsp; ```playerctl``` &nbsp; ```wl-clipboard``` &nbsp; ```libnotify``` &nbsp; ```perl```

# Setup
It's a breeze. ```sh setup``` will automatically install the required core dependencies -- you don't even need to chmod the install script if you prefix the filename with ```sh``` as denoted -- then launch spoot. Run it as yourself, not with sudo: it asks for root only for the package manager. At this point, you'll be automatically redirected to a Spotify authentication page, login with your Spotify account and you're done

- Run ```sh setup```
- Complete the Spotify authentication step
- Have fun

> The ```.desktop``` file will point to the binary inside the spoot dir where you extracted it

**OPTIONAL:** If you want to set up keybinds for quicker access
- For spoot -- Set a keybind pointing to ```<spoot dir>/bin/spoot```
- For listener -- Set a keybind pointing to ```<spoot dir>/bin/spoot --listen```
  > You can still access this panel from ```main > playback```

**Where spoot stores its files:**
- Everything is stored in the spoot directory where you extracted it and in ```~/.cache/spoot/```
- spoot also generates a ```.desktop``` file that lives in ```~/.local/share/applications/```, its icon in ```~/.local/share/icons/hicolor/```, and (if your distribution doesn't package it) the font in ```~/.local/share/fonts/JetBrainsMonoNerd/```

# Controls
Keybinds can also be viewed from ```Main > System > Keybinds```

| Keybind | Description | Context |
| --- | --- | --- |
| `f1` | view keybinds sheet | Universal |
| `tab` | trail menu / history | Universal |
| `return` | select -- play/pause/resume selected item | Universal |
| `delete` | delete entry in search or trail history | Search history, Trail history |
| `escape` | clear filter, close a card, then hide spoot | Universal |
| `backspace` | clear filter, then back one level | Universal |
| `alt` `=` `-` | quick seek + / - 10s | Universal |
| `shift` `return` | hovered item's action menu | Any list or grid row |
| `alt` `return` | jump to main menu | Universal |
| `alt` `delete` | clear session | Universal |
| `alt` `e` | jump to seek menu | Universal |
| `alt` `f` | search, from anywhere -- opens as a card, costs no trail step | Universal |
| `alt` `l` | jump to liked tracks | Universal |
| `alt` `p` | jump to recently played | Universal |
| `alt` `t` | jump to top tracks | Universal |
| `alt` `q` | jump to your queue | Universal |
| `space` | play / pause -- unless you are typing | Universal |
| `alt` `y` | jump to lyrics of current track | Universal |
| `alt` `a` | jump to albumart of current track | Universal |
| `alt` `r` | cycle repeat modes | Universal |
| `alt` `s` | toggle shuffle | Universal |
| `alt` `g` | open the spotify link on the clipboard | Universal |
| `alt` `c` | jump to the playing track -- from any view; walks back to the list it was played from, or opens playback if that list is gone | Universal |
| `alt` `←` `→` | walk back and forth along the trail -- non-destructive, the trail stays whole | Universal |
| `ctrl` `←` `→` | previous / next track | Universal |
| `home` `end` / `pgup` `pgdn` | first / last row, a page at a time | Any list or grid |

# Development

- `engine/smoke.sh` drives the built binary's `--serve` protocol against your
  signed-in account and checks every reply. It toggles shuffle twice, so the
  account ends as it started.
- `engine/views.sh` probes every view and compares row counts and shapes with
  `engine/views.golden`. That file was recorded against one particular account,
  so on any other run `sh engine/views.sh --record` once before comparing.
- `ui/check.sh` exercises the running window and needs a Wayland session.
- A ThreadSanitizer build (see `CMakeLists.txt`) should be run with
  `TSAN_OPTIONS=suppressions=$PWD/src/tsan.supp`.
