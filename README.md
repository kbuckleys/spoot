<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://github.com/user-attachments/assets/5b4d8a87-b8d6-4f07-941c-a3361f5ba01f">
  <img src="image-light.png" alt="">
</picture></p>

<h3><p align="center">
A keyboard-centric Spotify client</b> --  Part of the <a href="https://github.com/kbuckleys/ZENWORKS">ZENWORKS</a> Suite
<br>

# The philosophy behind spoot
Spotify clients (official one included) are too big and often glorified in comparison to what they're supposed to do. An optimal music player (for me, personally) should be something small, clear, easy and quick to interact with, which no player that I know of delivers. The original iteration and purpose of spoot was to act as a quick control panel for [spotify-player](https://github.com/aome510/spotify-player) which back then was my Spotify client of choice, but even that player -despite its speed and accessibility- wasn't enough for my use case. spoot was meant to bridge that gap, think of it as a remote control for your stereo system.

But as spoot's development pressed on, it became mature enough to be its own player, with its own small but comprehensive ecosystem. The idea was to be able to quickly access my library from anywhere, and do whatever I'd typically do on a desktop Spotify client without having to bring up a window cluttered to the brim with distractions and corporate directives, disrupting my workflow in the process. That's the point of spoot. A music player should not have to be a dedicated space governing and imposing its own rules instead of catering to the user. Music players can be better, smaller and quicker without having to sacrifice functionality or user experience.

But most importantly, a music player should pretty much know its place. It's not the user's center of attention.

# Functionality
- Setup is a breeze. First run will prompt you to automatically sync missing dependencies with your permission, then take you to Spotify's authentication page. Authenticate, and at which point you can start using spoot right away
- Your paths are nested and retained by default, given the number of menus and submenus

# Limitations:
Third-party Spotify clients are inherently bound to what the Spotify Web API allows, and spoot is no exception

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
Installation is automatic if you allow it, spoot will attempt to automatically install the missing dependencies for you. Should all its measures fail, you'll be prompted with a command you can copy straight from spoot that you can input in your terminal to get the dependencies, with zero effort

```Wayland session``` &nbsp; ```Spotify Premium``` &nbsp; ```Qt 6``` &nbsp; ```LayerShellQt``` &nbsp; ```lua 5.4+``` &nbsp; ```lua-cjson``` &nbsp; ```spotifyd``` &nbsp; ```playerctl``` &nbsp; ```curl``` &nbsp; ```openssl``` &nbsp; ```perl``` &nbsp; ```xdg-utils``` &nbsp; ```procps-ng``` &nbsp; ```wl-clipboard``` &nbsp; ```JetBrainsMono Nerd Font Propo```

- wl-copy or xclip (wl-clipboard, xclip, xsel) — copying a web link
- xdg-open (xdg-utils) — opening the login page in your browser
- perl (perl) — receiving the login callback
- openssl (openssl) — the login handshake
- pkill (procps-ng / procps) — stopping spoot's own background helpers

# Installation
- Place the spoot directory wherever you want
- Make ```/bin/spoot``` executable
- Set a keybind for it in your compositor's config
- Have fun

**OPTIONAL:** Set a second keybind if you want on-the-fly track detection
- Set a keybind pointing to ```/bin/spoot --listen```
  > You can still access this panel from ```main > playback```

# Controls
Keybinds can also be viewed from <b>Main > System > Keybinds</b>

| Keybind | Description | Context |
| --- | --- | --- |
| `Tab` | trail menu / history | Universal |
| `Return` | select -- play/pause/resume selected item | Universal |
| `Delete` | delete entry in search or trail history | Search history, Trail history |
| `Escape` | clear filter, then hide spoot | Universal |
| `Backspace` | clear filter, then back one level | Universal |
| `Alt` + `=` / `-` | quick seek + / - 10s | Universal |
| `Shift` + `Return` | hovered item's action menu | Any list or grid row |
| `Alt` + `Return` | jump to current track's action menu | Universal |
| `Alt` + `Delete` | clear session | Universal |
| `Alt` + `Space` | jump to main menu | Universal |
| `Alt` + `E` | jump to seek menu | Universal |
| `Alt` + `L` | jump to liked tracks | Universal |
| `Alt` + `P` | jump to recently played | Universal |
| `Alt` + `T` | jump to top tracks | Universal |
| `Alt` + `Q` | jump to your queue | Universal |
| `Space` | play / pause -- unless you are typing | Universal |
| `Alt` + `Y` | jump to lyrics of current track | Universal |
| `Alt` + `A` | jump to albumart of current track | Universal |
| `Alt` + `R` | cycle repeat modes | Universal |
| `Alt` + `S` | toggle shuffle | Universal |
| `Alt` + `G` | open spotify web link | Universal |
| `Alt` + `C` | jump to the playing track -- from any view; walks back to the list it was played from, or opens playback if that list is gone | Universal |
| `Alt` + `←` / `→` | walk back and forth along the trail -- non-destructive, the trail stays whole | Universal |
| `Ctrl` + `←` / `→` | previous / next track | Universal |
| `Alt` + `1`–`9` | jump to a step in the trail, or click the step itself | Universal |
