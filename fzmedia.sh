#!/bin/sh

# Parse CLI flags (override config)
while getopts "s:p:r:f:m:c:hdt:" opt; do
  case "$opt" in
    s) FLAG_MEDIA_ROOT=$OPTARG ;;
    p) FLAG_VIDEO_PLAYER=$OPTARG ;;
    r) FLAG_RESUME_PLAYER=$OPTARG ;;
    f) FLAG_FUZZY_FINDER=$OPTARG ;;
    m) FLAG_M3U_FILE=$OPTARG ;;
    c) FLAG_CACHE_DIR=$OPTARG ;;
    d) DOWNLOAD_MEDIA="true" ;;
    t) DOWNLOAD_TOOL=$OPTARG ;;
    h)
      cat <<EOF
Usage: $(basename "$0") [-s MEDIA_ROOT] [-p VIDEO_PLAYER] [-f FUZZY_FINDER] [-m M3U_FILE]

  -s  media root path        (directory or HTTP index, overrides MEDIA_ROOT)
  -p  video player command   (overrides VIDEO_PLAYER)
  -r  resume player command  (overrides RESUME_PLAYER)
  -f  fuzzy-finder command   (overrides FUZZY_FINDER)
  -m  path to m3u file       (overrides M3U_FILE)
  -c  path to cache dir      (overrides CACHE_DIR)
  -d  download the video instead of play
  -t  download tool          (overrides DOWNLOAD_TOOL)
  -h  this help
EOF
      exit 0
      ;;
    *) exit 1 ;;
  esac
done
shift $((OPTIND - 1))

# Load configuration, apply defaults, and ensure MEDIA_ROOT is set
sourceconf() {
  [ -z $XDG_CONFIG_HOME ] && local config_home="$HOME/.config" || config_home="$XDG_CONFIG_HOME"
  [ -z $XDG_CACHE_HOME ] && local cache_home="$HOME/.cache" || cache_home="$XDG_CACHE_HOME"
  local config_dir="$config_home/fzmedia"
  local config_file="$config_dir/config"

  # Ensure the config directory exists and create the file if it doesn't
  mkdir -p "$config_dir"
  touch "$config_file"
  . "$config_file"

  # Define all VAR=default pairs once
  set -- \
    "MEDIA_ROOT=" \
    "VIDEO_PLAYER=mpv --save-position-on-quit --no-resume-playback" \
    "RESUME_PLAYER=mpv --save-position-on-quit" \
    "DOWNLOAD_TOOL=wget -c -i" \
    "FUZZY_FINDER=fzy" \
    "M3U_FILE=/tmp/fzmedia.m3u" \
    "PREFERRED_ORDER=movies/,tv/,anime/,music/" \
    "CACHE_DIR=$cache_home/fzmedia"

  # Apply defaults: for each “VAR=default”, do : "${VAR:=default}"
  for each in "$@"; do eval ": \"\${${each%%=*}:=${each#*=}}\""; done

  # Ensure the cache directory exists now that CACHE_DIR is set
  mkdir -p "$CACHE_DIR"

  # Append any missing VAR lines (commented or not) to the end of the config file
  for each in "$@"; do
    var=${each%%=*}
    eval "val=\$$var"
    # only MEDIA_ROOT gets a custom trailing comment; everything else uses “#default”
    if ! grep -q -E "^[[:space:]]*#?[[:space:]]*$var=" "$config_file"; then
      if [ "$var" = "MEDIA_ROOT" ]; then
        printf '#%s="%s" #/path/to/file or http://example.com\n' \
          "$var" "$val" >> "$config_file"
      else
        printf '#%s="%s" #default\n' \
          "$var" "$val" >> "$config_file"
      fi
    fi
  done

}


# URL-encode stdin lines (safe='/')
url_encode() {
  python3 -c '
import sys, urllib.parse as ul
print("\n".join(
    ul.quote(ul.unquote(line.strip()), safe="/")
    for line in sys.stdin
))'
}

# URL-decode stdin lines
url_decode() {
  python3 -c '
import sys, urllib.parse as ul
print("\n".join(
    ul.unquote_plus(line.strip())
    for line in sys.stdin
))'
}

reorder() {
  awk -v order="$PREFERRED_ORDER" '
  BEGIN {
    n = split(order, arr, ",")
    for (i=1; i<=n; i++) prio[arr[i]] = i
  }
  {
    p = ($0 in prio ? prio[$0] : n+1)
    print p "\t" $0
  }' \
  | sort -k1,1n \
  | cut -f2
}

list_entries() {
  case "$1" in
    http://*|https://*)
      wget -q -O - "$1" \
        | grep -oP '(?<=href=")[^"]*' \
        | sed '1d' \
        | url_decode
      ;;
    *)
      # assume $1 is a directory on disk (with or without trailing slash)
      dir="${1%/}"
      ( cd "$dir" 2>/dev/null && ls -1p )
      ;;
  esac
}

poll_m3u_files() {
  for f in "$CACHE_DIR"/*; do
    parent=$(basename "$f")
    sed '/^#EXTINF/d; s#/[^/]*$##' "$f" | sort -u |
    while IFS= read -r i; do
      printf "" > "$CACHE_DIR/$parent"
      for entry in $(list_entries "$i/"); do
        printf "#EXTM3U\n" >> "$CACHE_DIR/$parent"
        printf '%s\n' "$i/$entry" >> "$CACHE_DIR/$parent"
      done
    done
  done
}

# List and fuzzy‐select directory entries under a given URL
indexfzy() {
  list_entries "$1" | $FUZZY_FINDER
}
# supported media extensions
MEDIA_EXT='|.mkv|.mp4|.avi|.webm|.flv|.mov|.wmv|.m4v|.mp3|.flac|.wav|.aac|.ogg|.m4a|.gif|'
MEDIA_REGEX="\.\($(printf '%s' "$MEDIA_EXT")\)\$"

# Build an M3U playlist from a URL/directory, starting from first selected file

plbuild() {
  printf "#EXTM3U\n" > "$M3U_FILE"

  list_entries "$1" \
    | grep -iE "$MEDIA_REGEX" \
    | while IFS= read -r file; do
        printf '#EXTINF:-1,\n' >> "$M3U_FILE"
        case "$1" in
          http://*|https://*)
            enc=$(printf '%s' "$file" | url_encode)
            printf '%s/%s\n' "${1%/}" "$enc" >> "$M3U_FILE"
            ;;
          *)
            printf '%s/%s\n' "${1%/}" "$file" >> "$M3U_FILE"
            ;;
        esac
      done

  # remove everything before the chosen file
  if case "$1" in http://*|https://*) true;; *) false;; esac; then
    pattern=$(printf '%s' "$FILE" | url_encode)
  else
    pattern="$FILE"
  fi
  sed "0,/$pattern/{//!d;}" "$M3U_FILE" > "$M3U_FILE.tmp" \
    && mv "$M3U_FILE.tmp" "$M3U_FILE"

}

# Prompt via fuzzy finder whether to add to the add to continue watching cache dir
cont_watch() {
  ans=$( printf "don't add to continue watching\nadd to continue watching\n" | $FUZZY_FINDER ) || return
  [ "$ans" = "add to continue watching" ] && cp "$1" "$CACHE_DIR/${2%.*}.m3u"
}

manage_cache() {
  local sel
  sel=$(
    {
      for i in $(ls "${CACHE_DIR}"/*.m3u); do basename $i; done
      printf '../\n'
    } | $FUZZY_FINDER
  ) || return

  [ "$sel" = "../" ] && return
  [ -n "$sel" ] && rm -f "$CACHE_DIR/$sel"
}

# Parses a .m3u and downloads all files
# download() {
# }

# Navigate directories via fuzzy picker and play when reaching media files
navigate_and_play() {
  local current="${1%/}/"
  local choice

  while :; do
    choice=$(
      {
        [ "${current%/}" = "${MEDIA_ROOT%/}" ] \
          && ls "$CACHE_DIR"/*.m3u >/dev/null 2>&1 \
          && printf 'continue watching/\n'
        list_entries "$current" | reorder
        [ "${current%/}" = "${CACHE_DIR%/}" ] && printf 'rm\n'
        [ "${current%/}" != "${MEDIA_ROOT%/}" ] && printf '../\n'
      } | $FUZZY_FINDER
    )
    status=$?

    # If fuzzy‐finder was cancelled (Esc/Ctrl-C):
    #  • if at MEDIA_ROOT → exit
    #  • if at CACHE_DIR → current=MEDIA_ROOT
    #  • otherwise → current=parent
    if [ "$status" -ne 0 ]; then
      if [ "${current%/}" = "${MEDIA_ROOT%/}" ]; then
        exit
      elif [ "${current%/}" = "${CACHE_DIR%/}" ]; then
        current="${MEDIA_ROOT%/}/"
        continue
      else
        current="${current%/*/}/"
        continue
      fi
    fi

    [ -z "$choice" ] && exit

    case "$choice" in
      "continue watching/")
        current="${CACHE_DIR%/}/"
        ;;

      "rm")
        manage_cache
        # if CACHE_DIR is now empty of .m3u, reset to MEDIA_ROOT; otherwise stay in CACHE_DIR
        [ ! -e "$CACHE_DIR"/*.m3u ] && current="${MEDIA_ROOT%/}/" || current="${CACHE_DIR%/}/"
        ;;
      ../)
        [ "${current%/}" = "${CACHE_DIR%/}" ] && current="${MEDIA_ROOT%/}/" || current="${current%/*/}/"
        ;;

      */)
        current="${current}${choice}"
        ;;

      *)
        if printf '%s\n' "$choice" | grep -qiE '\.m3u$'; then
          if [ ! -z "$DOWNLOAD_MEDIA" ]; then
              # Strip m3u control lines
              sed -i '/^#/d' "$M3U_FILE"
              $DOWNLOAD_TOOL "$M3U_FILE"
          else
              $RESUME_PLAYER "${current}${choice}"
          fi
          break

        elif printf '%s\n' "$choice" | grep -qiE "$MEDIA_REGEX"; then
          FILE="$choice"
          plbuild "$current"
          if [ ! -z "$DOWNLOAD_MEDIA" ]; then
              # Strip m3u control lines
              sed -i '/^#/d' "$M3U_FILE"
              $DOWNLOAD_TOOL "$M3U_FILE"
          else
              $VIDEO_PLAYER "$M3U_FILE"
          fi
          cont_watch "$M3U_FILE" "$choice"
          rm -f "$M3U_FILE"
          break

        else
          printf "skipping non-media: $choice\n" >&2
        fi
        ;;
    esac
  done
}

# Entry point
main() {
  # Prevent running as root
  if [ "$(id -u)" -eq 0 ]; then
    printf "Do not run this script as root. Aborting.\n"
    exit 1
  fi

  sourceconf  # load config

  # Apply CLI overrides
  [ -n "$FLAG_MEDIA_ROOT" ]    && MEDIA_ROOT=$FLAG_MEDIA_ROOT
  [ -n "$FLAG_VIDEO_PLAYER" ]  && VIDEO_PLAYER=$FLAG_VIDEO_PLAYER
  [ -n "$FLAG_RESUME_PLAYER" ] && RESUME_PLAYER=$FLAG_RESUME_PLAYER
  [ -n "$FLAG_FUZZY_FINDER" ]  && FUZZY_FINDER=$FLAG_FUZZY_FINDER
  [ -n "$FLAG_M3U_FILE" ]      && M3U_FILE=$FLAG_M3U_FILE
  [ -n "$FLAG_CACHE_DIR" ]    && CACHE_DIR=$FLAG_CACHE_DIR

  # If MEDIA_ROOT is still empty after sourcing/applying defaults, error out
  [ -z "$MEDIA_ROOT" ] && printf "Error: MEDIA_ROOT must be set.\n" >&2 && return 1

  # Start navigation/playback
  #navigate_and_play "${MEDIA_ROOT%/}/"
  poll_m3u_files

}

main

