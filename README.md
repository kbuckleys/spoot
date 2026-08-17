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
- First run will automatically take you to Spotify's authentication page. Authenticate, and at which point you can start using spoot right away
- Your paths are nested and retained by default, given the number of menus and submenus. This is why some custom keybinds had to be set in place, instead of reopening the main menu every time and going through multiple depth levels

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

```Wayland session``` &nbsp; ```Spotify Premium``` &nbsp; ```spotifyd``` &nbsp; ```songrec``` &nbsp; ```lua 5.4+``` &nbsp; ```lua-cjson``` &nbsp; ```playerctl``` &nbsp; ```curl``` &nbsp; ```perl``` &nbsp; ```wl-clipboard``` &nbsp; ```JetBrainsMono Nerd Font```

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

<body>
  <table>
    <thead>
      <tr><th>Key</th><th>Action</th><th>Context</th></tr>
    </thead>
    <tbody>
      <tr><td><kbd>tab</kbd></td><td>trail menu / history -- search type filter</td><td>contextual</td></tr>
      <tr><td><kbd>return</kbd></td><td>select -- play/pause/resume selected item</td><td>contextual</td></tr>
      <tr><td><kbd>delete</kbd></td><td>delete entry in search or trail history</td><td>contextual</td></tr>
      <tr><td><kbd>escape</kbd></td><td>collapse current menu</td><td>universal</td></tr>
      <tr><td><kbd>backspace</kbd></td><td>clear input / back one level</td><td>universal</td></tr>
      <tr><td><kbd>alt = / -</kbd></td><td>quick seek +10s / -10s</td><td>universal</td></tr>
      <tr><td><kbd>shift return</kbd></td><td>hovered item's action menu</td><td>contextual</td></tr>
      <tr><td><kbd>alt return</kbd></td><td>jump to current track's Action Menu</td><td>universal</td></tr>
      <tr><td><kbd>alt delete</kbd></td><td>clear session</td><td>universal</td></tr>
      <tr><td><kbd>alt space</kbd></td><td>jump to main menu</td><td>universal</td></tr>
      <tr><td><kbd>alt e</kbd></td><td>jump to seek menu</td><td>universal</td></tr>
      <tr><td><kbd>alt l</kbd></td><td>jump to liked tracks</td><td>universal</td></tr>
      <tr><td><kbd>alt p</kbd></td><td>jump to recently played</td><td>universal</td></tr>
      <tr><td><kbd>alt y</kbd></td><td>jump to lyrics of current track</td><td>universal</td></tr>      
      <tr><td><kbd>alt a</kbd></td><td>jump to albumart of current track</td><td>universal</td></tr>
      <tr><td><kbd>alt r</kbd></td><td>cycle repeat modes</td><td>universal</td></tr>
      <tr><td><kbd>alt s</kbd></td><td>toggle shuffle</td><td>universal</td></tr>
      <tr><td><kbd>alt g</kbd></td><td>open spotify web link</td><td>universal</td></tr>
      <tr><td><kbd>alt c</kbd></td><td>jump to current track in list / jump to current lyric line in lyrics view</td><td>contextual</td></tr>
    </tbody>
  </table>
</body>
</html>
