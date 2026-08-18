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

```Wayland session``` &nbsp; ```Spotify Premium``` &nbsp; ```Qt 6``` &nbsp; ```LayerShellQt``` &nbsp; ```lua 5.4+``` &nbsp; ```lua-cjson``` &nbsp; ```spotifyd``` &nbsp; ```wl-clipboard``` &nbsp; ```playerctl``` &nbsp; ```curl``` &nbsp; ```openssl``` &nbsp; ```perl``` &nbsp; ```xdg-utils``` &nbsp; ```procps-ng``` &nbsp; ```wl-clipboard``` &nbsp; ```songrec``` &nbsp; ```pactl``` &nbsp; ```libnotify``` &nbsp; ```JetBrainsMono```

# Setup
It's a breeze. ```bash setup``` will automatically install the required core dependencies -- you don't even need to chmod the install script if you prefixed the filename with ```bash``` as denoted -- then launch spoot. At this point, you'll be automatically redirected to a Spotify authentication page, login with your Spotify account and you're done

- Run ```bash setup```
- Complete the Spotify authentication step
- Set a keybind for ```/bin/spoot``` in your compositor's config
- Have fun

**OPTIONAL:** Set a second keybind if you want on-the-fly track detection
- Set a keybind pointing to ```/bin/spoot --listen```
  > You can still access this panel from ```main > playback```

**Removal:**
- Simply run ```bash setup``` again and choose ```Remove```
  > This option will only remove spoot's compiled binary and dependencies you did not have prior to spoot's initial setup

# Building it yourself
Only follow these steps If you prefer building spoot manually, although the install script does exactly the same thing

**Prerequisites:**
- ```CMake 3.21+``` and a ```C++17``` compiler
- ```Qt 6 — Gui```, ```Qml```, ```Quick```, ```Network``` (development packages)
- ```LayerShellQt``` (development package)
- ```lua 5.4+``` and ```lua-cjson```

```
- cmake -S . -B build
- cmake --build build -j"$(nproc)"
```

> ```bin/spoot``` lands beside ```ui/``` and ```engine/``` — it resolves the project root from its own location, so it works as a keybind target from anywhere, and must stay where it lands. A second invocation hands its request to the first over a socket and exits, so binding the same command to a key toggles rather than starting a second copy

# Controls
Keybinds can also be viewed from ```Main > System > Keybinds```

| Keybind | Description | Context |
| --- | --- | --- |
| `tab` | trail menu / history | Universal |
| `return` | select -- play/pause/resume selected item | Universal |
| `delete` | delete entry in search or trail history | Search history, Trail history |
| `escape` | clear filter, then hide spoot | Universal |
| `backspace` | clear filter, then back one level | Universal |
| `alt` `=` / `-` | quick seek + / - 10s | Universal |
| `shift` `return` | hovered item's action menu | Any list or grid row |
| `alt` `return` | jump to current track's action menu | Universal |
| `alt` `delete` | clear session | Universal |
| `alt` `space` | jump to main menu | Universal |
| `alt` `e` | jump to seek menu | Universal |
| `alt` `l` | jump to liked tracks | Universal |
| `alt` `p` | jump to recently played | Universal |
| `alt` `t` | jump to top tracks | Universal |
| `alt` `q` | jump to your queue | Universal |
| `space` | play / pause -- unless you are typing | Universal |
| `alt` `y` | jump to lyrics of current track | Universal |
| `alt` `a` | jump to albumart of current track | Universal |
| `alt` `r` | cycle repeat modes | Universal |
| `alt` `s` | toggle shuffle | Universal |
| `alt` `g` | open spotify web link | Universal |
| `alt` `c` | jump to the playing track -- from any view; walks back to the list it was played from, or opens playback if that list is gone | Universal |
| `alt` `←` / `→` | walk back and forth along the trail -- non-destructive, the trail stays whole | Universal |
| `ctrl` `←` / `→` | previous / next track | Universal |
| `alt` `1`–`9` | jump to a step in the trail, or click the step itself | Universal |
