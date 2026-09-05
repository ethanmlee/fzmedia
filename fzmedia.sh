#!/bin/sh

# Table of config variables: flag|var|default_command|help|config_comment
# fucking hell I wish posix shell had arrays
config_spec() {
  cat << 'EOF'
s|MEDIA_ROOT||media root path|/path/to/file or http://example.com
p|VIDEO_PLAYER|mpv --save-position-on-quit --no-resume-playback|video player command|default
r|RESUME_PLAYER|mpv --save-position-on-quit|resume player command|default
f|FUZZY_FINDER|fzy|fuzzy-finder command|default
m|M3U_FILE|/tmp/fzmedia.m3u|path to m3u file|default
c|CACHE_DIR|$cache_home/fzmedia|path to cache dir|default
u|||poll the continue watching playlists, print to the terminal, then exit||
d|||download instead of play||
t|DOWNLOAD_TOOL|wget -c -i|download tool|default
|PREFERRED_ORDER|movies/,tv/,anime/,music/||default
h|||display this help||
EOF
}

# Parse CLI flags (override config)
flags() {
  spec=$(config_spec)
  optstring=$(printf '%s\n' "$spec" | while IFS='|' read -r flag var _; do
    [ -n "$flag" ] && printf '%s%s' "$flag" "${var:+:}"
  done)

  while getopts "$optstring" opt; do
    var=$(printf '%s\n' "$spec" | awk -F'|' -v f="$opt" '$1==f{print $2;exit}')
    case "$opt" in
      u) POLL_AND_EXIT=true ;;
      d) DOWNLOAD_MEDIA=true ;;
      h) usage ;;
      *) [ -n "$var" ] && eval "FLAG_$var=\$OPTARG" || exit 1 ;;
    esac
  done
  shift $((OPTIND - 1))
}

usage() {
  printf 'Usage: %s [-s MEDIA_ROOT] [-p VIDEO_PLAYER] [-f FUZZY_FINDER] [-m M3U_FILE]\n\n' "$(basename "$0")"
  config_spec | while IFS='|' read -r flag var _ help _; do
    if [ -n "$flag" ]; then
      if [ -n "$var" ]; then
        printf '  -%s %s (overrides %s)\n' "$flag" "$help" "$var"
      else
        printf '  -%s %s\n' "$flag" "$help"
      fi
    fi
  done
  exit 0
}

source_conf() {
  [ -z "$XDG_CONFIG_HOME" ] && config_home="$HOME/.config" || config_home="$XDG_CONFIG_HOME"
  config_dir="$config_home/fzmedia"
  config_file="$config_dir/config"
  mkdir -p "$config_dir"
  touch "$config_file"
  # shellcheck disable=SC1090
  . "$config_file"
}

# Load configuration, apply defaults, and ensure MEDIA_ROOT is set
create_conf() {

  [ -z "$XDG_CACHE_HOME" ] && cache_home="$HOME/.cache" || cache_home="$XDG_CACHE_HOME"

  spec=$(mktemp)
  config_spec > "$spec"

  while IFS='|' read -r _ var default _ comment; do
    if [ -n "$var" ]; then
      eval "default=\"$default\""
      # Apply defaults: for each “VAR=default”, do : "${VAR:=default}"
      eval ": \"\${$var:=\$default}\""
      # Append any missing VAR lines (commented or not) to the end of the config file
      if ! grep -q -E "^[[:space:]]*#?[[:space:]]*$var=" "$config_file"; then
        eval "val=\$$var"
        printf '#%s="%s" #%s\n' "$var" "$val" "${comment:-default}" >> "$config_file"
      fi
    fi
  done < "$spec"

  # Apply flag overrides
  while IFS='|' read -r flag var _ _ _; do
    if [ -n "$flag" ] && [ -n "$var" ]; then
      eval "flag_val=\${FLAG_$var-}"
      if [ -n "$flag_val" ]; then
        eval "$var=\$flag_val"
      fi
    fi
  done < "$spec"

  rm -f "$spec"

  mkdir -p "$CACHE_DIR"

  [ -z "$MEDIA_ROOT" ] && printf "Error: MEDIA_ROOT must be set in %s \n" "$config_file" >&2 && exit 1
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
  }' |
    sort -k1,1n |
    cut -f2
}

list_entries() {
  case "$1" in
    http://* | https://*)
      wget -q -O - "$1" |
        sed -n 's/.*href="\([^"]*\)".*/\1/p' |
        sed '1d' |
        url_decode
      ;;
    *)
      # assume $1 is a directory on disk (with or without trailing slash)
      dir="${1%/}"
      (cd "$dir" 2> /dev/null && ls -1p)
      ;;
  esac
}

snapshot_m3u_files() {
  pre=$(mktemp)
  grep -h -v '^#' "$CACHE_DIR"/*.m3u | sed 's#^.*/##' | sort -u > "$pre"
  trap 'rm -f "$pre" "$post"' EXIT
}

diff_m3u_files() {
  post=$(mktemp)
  grep -h -v '^#' "$CACHE_DIR"/*.m3u | sed 's#^.*/##' | sort -u > "$post"
  comm -13 "$pre" "$post"
  rm -f "$pre" "$post"
}

poll_m3u_files() {
  [ -n "$POLL_AND_EXIT" ] && snapshot_m3u_files
  ls "$CACHE_DIR"/*.m3u > /dev/null 2>&1 || return
  for f in "$CACHE_DIR"/*.m3u; do
    parent=$(basename "$f")
    dirs=$(sed '/^#EXTINF/d; s#/[^/]*$##' "$f" | sort -u)
    [ -z "$dirs" ] && continue
    printf "#EXTM3U\n" > "$CACHE_DIR/$parent"
    printf '%s\n' "$dirs" | while IFS= read -r i; do
      list_entries "$i/" | while IFS= read -r entry; do
        printf '#EXTINF:-1,\n' >> "$CACHE_DIR/$parent"
        printf '%s\n' "$i/$entry" >> "$CACHE_DIR/$parent"
      done
    done
  done

  if [ -n "$POLL_AND_EXIT" ]; then
    diff_m3u_files
    exit 0
  fi
}

# supported media extensions
MEDIA_REGEX='\.(mkv|mp4|avi|webm|flv|mov|wmv|m4v|mp3|flac|wav|aac|ogg|m4a|gif)$'

# Build an M3U playlist from a URL/directory, starting from first selected file
plbuild() {
  start=$2
  printf "#EXTM3U\n" > "$M3U_FILE"
  case "$1" in
    http://* | https://*) base="$1" ;;
    *) base=$(cd "${1%/}" 2> /dev/null && pwd)/ || return ;;
  esac
  list_entries "$1" | grep -iE "$MEDIA_REGEX" | while IFS= read -r entry; do
    [ -n "$start" ] && [ "$entry" != "$start" ] && continue
    start=
    printf '#EXTINF:-1,\n' >> "$M3U_FILE"
    case "$base" in http://* | https://*) entry=$(printf '%s' "$entry" | url_encode) ;; esac
    printf '%s\n' "$base$entry" >> "$M3U_FILE"
  done
}

# Prompt via fuzzy finder whether to add to the add to continue watching cache dir
cont_watch() {
  ans=$(printf "don't add to continue watching\nadd to continue watching\n" | $FUZZY_FINDER) || return
  [ "$ans" = "add to continue watching" ] && cp "$1" "$CACHE_DIR/${2%.*}.m3u"
}

manage_cache() {
  sel=$(
    {
      for i in "$CACHE_DIR"/*.m3u; do [ -e "$i" ] && basename "$i"; done
      printf '../\n'
    } | $FUZZY_FINDER
  ) || return

  [ "$sel" = "../" ] && return
  [ -n "$sel" ] && rm -f "$CACHE_DIR/$sel"
}

play_or_download() {
  player=$1
  media=$2
  if [ -n "$DOWNLOAD_MEDIA" ]; then
    sed '/^#/d' "$M3U_FILE" > "$M3U_FILE.tmp" &&
      mv "$M3U_FILE.tmp" "$M3U_FILE"
    $DOWNLOAD_TOOL "$M3U_FILE"
  else
    # shellcheck disable=SC2086
    $player $media
  fi
}

# Navigate directories via fuzzy picker and play when reaching media files
navigate_and_play() {
  #normalize MEDIA_ROOT, CACHE_DIR at beginning here so leter code is more readable
  root="${MEDIA_ROOT%/}/"
  cache="${CACHE_DIR%/}/"
  current="$root"

  while :; do

    choice=$(
      {
        [ "$current" = "$root" ] &&
          ls "$CACHE_DIR"/*.m3u > /dev/null 2>&1 &&
          printf 'continue watching/\n'
        list_entries "$current" | reorder
        [ "$current" = "$cache" ] && printf 'rm\n'
        [ "$current" != "$root" ] && printf '../\n'
      } | $FUZZY_FINDER
    )
    status=$?

    # fuzzy finder exit logic (Esc/Ctrl-C)
    if [ "$status" -ne 0 ]; then
      [ "$current" = "$root" ] && exit
      [ "$current" = "$cache" ] && current="$root" || current="${current%/*/}/"
      continue
    fi

    [ -z "$choice" ] && exit
    case "$choice" in
      "continue watching/")
        current="$cache"
        ;;
      "rm")
        manage_cache
        # if CACHE_DIR is now empty of .m3u, reset to MEDIA_ROOT; otherwise stay in CACHE_DIR
        ls "$CACHE_DIR"/*.m3u > /dev/null 2>&1 && current="$cache" || current="$root"
        ;;
      ../)
        [ "$current" = "$cache" ] && current="$root" || current="${current%/*/}/"
        ;;
      */)
        current="${current}${choice}"
        ;;
      *)
        #if current choice is a .m3u then resume
        if printf '%s\n' "$choice" | grep -qiE '\.m3u$'; then
          play_or_download "$RESUME_PLAYER" "${current}${choice}"
          break
        #play and prompt to add to continue watching if is one of the supported media types
        elif printf '%s\n' "$choice" | grep -qiE "$MEDIA_REGEX"; then
          plbuild "$current" "$choice"
          play_or_download "$VIDEO_PLAYER" "$M3U_FILE"
          cont_watch "$M3U_FILE" "$choice"
          rm -f "$M3U_FILE"
          break
        else
          printf 'skipping non-media: %s\n' "$choice" >&2
        fi
        ;;

    esac
  done
}

main() {
  [ "$(id -u)" -eq 0 ] && printf "Do not run this script as root. Aborting.\n" && exit 1
  flags "$@"
  source_conf
  create_conf
  poll_m3u_files
  navigate_and_play
}

main "$@"
