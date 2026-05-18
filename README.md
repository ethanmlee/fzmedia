Just a shitty shell script to navigate file trees, play media files, and continue watching where you left off later. meant to be hackable, flexible, and minimal "replacement" for tools like plex for remote http indexes and local directories

# how to install

install with `sudo make install`

uninstall with `sudo make uninstall`

if you are running gentoo (based) then you can use [my gentoo overlay](https://github.com/dirtytowel/garbage-overlay). apt repo coming soon(tm)

# how it works

All it does is pass the file dirs from a http index or local dir to a fuzzy finder of your choice, then pass the output chosen from the fuzzy finder to a media player of your choice

`${MEDIA_ROOT} -> ${FUZZY_FINDER} -> ${VIDEO_PLAYER}`

MEDIA_ROOT: no default, needs to be set in config file or with -u {dir/url}

FUZZY_FINDER: confirmed working with `dmenu`, `fzy`, and `fzf`. defaults to `fzy`. it just passes stdin to another app so it should work with whatever fuzzy finder you like.

VIDEO_PLAYER: works with both mpv and vlc from my testing, though continue watching for m3u files works better with mpv. There is also an additional var that can be set for the resume player. resume player doesn't like it when an m3u file gets updated (like currently airing tv) so I wrote [mpvcw](https://github.com/dirtytowel/scritps/blob/master/mpvcw) to solve this problem.

the only thing this tool actually does is glue these preferences together.

# how to use/configure

A config file at `~/.config/fzmedia/config` is created if there is not one present. If you are missing a value that is required it will add a default.

```bash
# url or local path to browse. required (or pass -u)
MEDIA_ROOT="/path/to/file or http://example.com"

# player for new files. flags save position to ~/.local/state/mpv
VIDEO_PLAYER="mpv --save-position-on-quit --no-resume-playback" #default

# player for continue watching. --no-resume-playback dropped so it picks up where you left off
# vlc users: set both VIDEO_PLAYER and RESUME_PLAYER to "vlc", continue watching sucks ass with vlc though.
RESUME_PLAYER="mpv --save-position-on-quit" #default

# download tool must accept a file of URLs (-i). -c resumes partial downloads
DOWNLOAD_TOOL="wget -c -i"

# works with basic finders (fzf, fzy) and menu tools (dmenu, rofi)
FUZZY_FINDER="fzy" #default

# just url/path refs, deleted after player closes. /tmp is usually a ramdisk
M3U_FILE="/tmp/fzmedia.m3u" #default

# continue watching saves m3u files here. rename them manually if the auto name is ugly
# maybe you can write a script that parses and renames based off your library naming conventions
CACHE_DIR="~/.cache/fzmedia" #default

# override default alpha-numeric order. syntax matters
PREFERRED_ORDER="movies/,tv/,anime/,music/" #default
```

after the tool is installed in your $PATH you can call it with `fzmedia`. you can also pass the `-h` flag to print this help text to the terminal:

```
Usage: fzmedia [-s MEDIA_ROOT] [-p VIDEO_PLAYER] [-f FUZZY_FINDER] [-m M3U_FILE]

  -s  media root path        (directory or HTTP index, overrides MEDIA_ROOT)
  -p  video player command   (overrides VIDEO_PLAYER)
  -r  resume player command  (overrides RESUME_PLAYER)
  -f  fuzzy-finder command   (overrides FUZZY_FINDER)
  -m  path to m3u file       (overrides M3U_FILE)
  -c  path to cache dir      (overrides CACHE_DIR)
  -u  poll the continue watching playlists and exit
  -d  download the video instead of play
  -t  download tool          (overrides DOWNLOAD_TOOL)
  -h  this help
```

For example you could have the keybind `mod + f` set to `fzmedia -f "dmenu -i -l 10"` so that it opens in dmenu on the keybind. This gives the flexibility for when you want to use the tool in the terminal with a fuzzy finder such as `fzf` or `fzy`. You could have shows saved locally and not on my http index or want to use a different http index so you can override the default with `-u /path/to/dir` or `-u https://user:password@example.com`.

the continue watching queue is only populated after you confirm you want to add it. here's an example tree:
```
continue watching
├── A.m3u
├── B.m3u
├── rm/
│   ├── A.m3u
│   ├── B.m3u
│   └── ../
└── ../
```

when navigating directory trees you can search by name, go back up with cancel (`ctrl + c`, `esc`) or the `../` selection. you have to escape all the way up to the base dir to fully quit.

# I found a bug/issue, what do I do?

open an issue or PR if you find a bug or want to contribute. all contributions welcome.

# TODO
- continue watching update on open and only update continue watching and do not open flag.
- ssh as a media root source
- selfhosted apt repository for debian and ubuntu
- maybe a config file option and flag to specify whether you are using a menu or plain fuzzy finder. this could really level up the "UI" capabilities, such as renaming Continue watching m3u files or cleaner prompts, though I don't want to break compat with plain fuzzy finders
