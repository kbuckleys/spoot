<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://github.com/user-attachments/assets/5b4d8a87-b8d6-4f07-941c-a3361f5ba01f">
  <img src="image-light.png" alt="">
</picture></p>

<h3><p align="center">
A keyboard-centric Spotify client</b> --  An advanced <a href="https://github.com/davatorium/rofi">rofi</a> interface powered by <a href="https://github.com/Spotifyd/spotifyd">spotifyd</a>
<br>
Part of the <a href="https://github.com/kbuckleys/ZENWORKS">ZENWORKS</a> Suite
</p></h3>

<br>

https://github.com/user-attachments/assets/f0d46590-c18e-4a06-9ac5-4488df955887

<p align="center">
  This is a full-fledged, standalone Spotify client in a single Lua file! Yes, you read that correctly
</p>

# The philosophy behind spoot
Spotify clients (official one included) are too big and often glorified in comparison to what they're supposed to do. An optimal music player (for me, personally) should be something small, clear, easy and quick to interact with, which no player that I know of delivers. The original iteration and purpose of spoot was to act as a quick control panel for [spotify-player](https://github.com/aome510/spotify-player) which back then was my Spotify client of choice, but even that player -despite its speed and accessibility- wasn't enough for my use case. spoot was meant to bridge that gap, think of it as a remote control for your stereo system.

But as spoot's development pressed on, it became mature enough to be its own player, with its own small but comprehensive ecosystem. The idea was to be able to quickly access my library from anywhere, and do whatever I'd typically do on a desktop Spotify client without having to bring up a window cluttered to the brim with distractions and corporate directives, disrupting my workflow in the process. That's the point of spoot. A music player should not have to be a dedicated space governing and imposing its own rules instead of catering to the user. Music players can be better, smaller and quicker without having to sacrifice functionality or user experience.

But most importantly, a music player should pretty much know its place. It's not the user's center of attention.

# Functionality
- First run will automatically take you to Spotify's authentication page (two separate pages in fact, that's just a ```spotifyd``` quirk). At launch, spoot will notify you that it's building cache and will automatically run the daemons and display the main menu once it's done, at which point you can start using the rofi interface right away
- Cache gets updated every 12 hours, a safeguard in case you made external changes to your library from, say; your phone or another Spotify client. There's also a manual option to refresh the cache, <b>but only use it when you absolutely have to.</b> Your activity on the player is dynamically and locally refreshed anyway, so you'll probably never have to use this option
- Your paths are nested and retained by default, given the number of menus and submenus. This is why some custom keybinds had to be set in place, instead of reopening the main menu every time and going through multiple depth levels

# Limitations:
Third-party Spotify clients are inherently bound to what the Spotify Web API allows, and spoot is no exception
- **Remove from queue (Spotify Web API limitation)**
  - Local queue can be implemented as an alternative. In which case it will provide full control over its functions. However...
    - It adds complexity and relative bloat for what it's supposed to do
    - Local implementation also means zero sync with other Spotify clients/connect devices

- **Podcast management**
  - Not that spoot can't do it, I simply didn't implement support for it, for two primary reasons;
    - Spotify's API doesn't expose some of the key features that help make listening to podcasts accessible, like chapter management
    - This may sound subjective, but it's a relatively niche medium to cover

- **Recently Played is purely local**
  - The live counterpart seems to suffer from issues through Spotify's Web API, even with the Activity Sharing privacy setting enabled. May be revisited in future iterations but it's highly unlikely
 
- **Crossfade**
  - `spotifyd` and `librespot` can only decode one stream at a time, so a true overlapping crossfade isn't possible. However, an implementation of a pseudo alternative is doable but it won't realistically make for a positive addition. The overall value of such implementation simply doesn't justify the added complexity and costly bloat
    
    > This was already tested in an internal build, it required an additional separate process dedicated just for the function of detecting starting and near-ending tracks. It was also fighting playerctl's volume during its 5s-windows and ended up reserving a significant chunk in the codebase. In the end; it wasn't exactly smart enough to detect tracks that already start loud/pitched, resulting in this track criteria not starting off as they were intended by their artists. The cons vastly outweighed the pros, thus scrapped

# Dependencies
- Wayland session
- Spotify Premium ```no way around it```
- spotifyd
- rofi 1.7+
- lua 5.4+
- lua-cjson
- playerctl
- curl
- perl
- wl-clipboard
- JetBrainsMono Nerd Font

# Installation
First things first; spoot is designed to be as intuitive as possible, which meant giving the ```backspace``` key a double life -- as it is both editorial as well as navigational. This is something rofi cannot do naively, so it's crucial that you follow the first step in particular for an optimal experience.
- Add your username to the input group ```sudo usermod -aG input <username>``` and re-login for it to fully register
- Place the spoot directory wherever you want
- Make ```spoot.lua``` executable
- Set a keybind for it in your compositor's config
- Have fun

That's it! No need to place the directory inside rofi's config directory, no need to configure rofi or spotifyd themselves. The script is independent from rofi's and spotifyd's globals and is completely self-contained with its own config and theme files. Well except for that part where you have to add your username to the input group.

# Controls
Given the scope, you can be easily multiple levels deep as you navigate through menus, so it was important to set some keybinds in place for convenience and faster -hopefully organic- interactions.
> Keybinds can also be viewed from <b>Main > System > Keybinds</b>

<body>
  <table>
    <thead>
      <tr><th>Key</th><th>Action</th><th>Context</th></tr>
    </thead>
    <tbody>
      <tr><td><kbd>f5</kbd></td><td>List refresh failsafe (you'll probably never use this)</td><td>Universal</td></tr>
      <tr><td><kbd>tab</kbd></td><td>Jump to trail menu</td><td>Universal</td></tr>
      <tr><td><kbd>return</kbd></td><td>Select -- play/pause selected track</td><td>Universal</td></tr>
      <tr><td><kbd>delete</kbd></td><td>Delete a lookup history entry</td><td>Universal</td></tr>
      <tr><td><kbd>escape</kbd></td><td>Close</td><td>Universal</td></tr>
      <tr><td><kbd>backspace</kbd></td><td>Clear filter / Delete input / Back one level</td><td>Universal</td></tr>
      <tr><td><kbd>alt + =</kbd>  &nbsp;&nbsp;  <kbd>alt + -</kbd></td><td>Quick seek +10s / -10s</td><td>Universal</td></tr>
      <tr><td><kbd>shift + return</kbd></td><td>Selected track's Action Menu</td><td>Track</td></tr>
      <tr><td><kbd>alt + delete</kbd></td><td>Clear session</td><td>Universal</td></tr>
      <tr><td><kbd>alt + return</kbd></td><td>Jump to current track's Action Menu</td><td>Universal</td></tr>
      <tr><td><kbd>alt + space</kbd></td><td>Jump to Main Menu</td><td>Universal</td></tr>
      <tr><td><kbd>alt + e</kbd></td><td>Jump to Seek menu</td><td>Universal</td></tr>
      <tr><td><kbd>alt + l</kbd></td><td>Jump to Liked Tracks</td><td>Universal</td></tr>
      <tr><td><kbd>alt + p</kbd></td><td>Jump to Recently Played</td><td>Universal</td></tr>
      <tr><td><kbd>alt + y</kbd></td><td>Jump to current track's lyrics</td><td>Universal</td></tr>
      <tr><td><kbd>alt + a</kbd></td><td>View albumart of current track</td><td>Universal</td></tr>
      <tr><td><kbd>alt + c</kbd></td><td>Jump to current track in list / Jump to current lyric line</td><td>List / Lyrics</td></tr>
      <tr><td><kbd>alt + r</kbd></td><td>Cycle through Repeat modes</td><td>Universal</td></tr>
      <tr><td><kbd>alt + s</kbd></td><td>Toggle Shuffle</td><td>Universal</td></tr>
      <tr><td><kbd>alt + g</kbd></td><td>Paste and go to a Spotify web link</td><td>Universal</td></tr>
    </tbody>
  </table>
</body>
</html>
