#!/usr/bin/env bash
# Save the live Wayland clipboard image into Yazi's current directory.
#
# Yazi's `shell` action starts the process with Yazi's current manager
# directory as its working directory, so the process cwd is the directory
# shown in Yazi. The script is also usable directly from a shell, where the
# process cwd is the shell's current directory. Use `pwd -P` rather than the
# inherited $PWD variable: a parent process can chdir without rewriting PWD.
#
# This reads the clipboard only. It never calls wl-copy and does not depend on
# cliphist, so an image larger than cliphist's 2 MiB session limit can still be
# pasted while it is on the live clipboard.

set -euo pipefail

notify() {
  local title="$1"
  local body="${2:-}"
  if [ -n "$notify_bin" ]; then
    "$notify_bin" --app-name=Yazi -- "$title" "$body" >/dev/null 2>&1 || true
  fi
  if [ -n "$body" ]; then
    printf 'yazi-paste-image: %s: %s\n' "$title" "$body" >&2
  else
    printf 'yazi-paste-image: %s\n' "$title" >&2
  fi
}

wl_paste_bin="${YAZI_PASTE_WL_PASTE:-wl-paste}"
file_bin="${YAZI_PASTE_FILE:-file}"
notify_bin="${YAZI_PASTE_NOTIFY:-$(command -v notify-send || true)}"
# `pwd` output ends with a newline; append a sentinel and strip only that
# newline plus sentinel so a directory name ending in a newline is preserved.
dest_dir="$(pwd -P; printf x)"
dest_dir="${dest_dir%$'\nx'}"

if [ "$#" -ne 0 ]; then
  notify "Usage: yazi-paste-image" "This command takes no arguments."
  exit 2
fi

if [ ! -d "$dest_dir" ] || [ ! -w "$dest_dir" ]; then
  notify "Cannot paste image" "Current directory is not writable: $dest_dir"
  exit 1
fi

# Ask the clipboard which representations it offers. An empty clipboard exits
# non-zero here, so no file is created for that case.
if ! types="$("$wl_paste_bin" --list-types 2>/dev/null)"; then
  notify "No image on the clipboard" "The clipboard is empty or unavailable."
  exit 1
fi

mime=""
available=$'\n'"$types"$'\n'
for candidate in image/png image/jpeg image/webp; do
  if [[ "$available" == *$'\n'"$candidate"$'\n'* ]]; then
    mime="$candidate"
    break
  fi
done

if [ -z "$mime" ]; then
  notify "No supported image on the clipboard" "Available types: ${types//$'\n'/, }"
  exit 1
fi

# Write to a temporary file in the destination first. This keeps incomplete
# clipboard reads out of the final directory and lets us detect the real image
# type before choosing the extension.
tmp=""
cleanup() {
  if [ -n "$tmp" ]; then
    rm -f -- "$tmp"
  fi
}
trap cleanup EXIT

if ! tmp="$(mktemp --tmpdir="$dest_dir" .yazi-paste-image.XXXXXX)"; then
  notify "Cannot paste image" "Failed to create a temporary file in $dest_dir"
  exit 1
fi

if ! "$wl_paste_bin" --type "$mime" >"$tmp" 2>/dev/null; then
  notify "Failed to read clipboard image" "Clipboard type: $mime"
  exit 1
fi

if [ ! -s "$tmp" ]; then
  notify "Clipboard image is empty" "No data was received from the clipboard."
  exit 1
fi

# Trust the bytes, not only the advertised MIME type. This also prevents text
# or HTML data from being saved with a .png extension.
detected="$("$file_bin" -b --mime-type -- "$tmp" 2>/dev/null || true)"
case "$detected" in
  image/png) ext=png ;;
  image/jpeg) ext=jpg ;;
  image/webp) ext=webp ;;
  *)
    notify "Unsupported clipboard image" "Detected type: ${detected:-unknown}"
    exit 1
    ;;
esac

stamp="$(date +%Y%m%d-%H%M%S)"
target=""
for _ in $(seq 1 100); do
  suffix="$(printf '%04x' "$((RANDOM % 65536))")"
  candidate="$dest_dir/Screenshot-$stamp-$suffix.$ext"
  # Reserve the name atomically. noclobber makes the redirection fail instead
  # of truncating an existing file.
  if (set -o noclobber; : >"$candidate") 2>/dev/null; then
    target="$candidate"
    break
  fi
done

if [ -z "$target" ]; then
  notify "Cannot paste image" "Failed to allocate a unique screenshot filename."
  exit 1
fi

if ! cat -- "$tmp" >"$target"; then
  rm -f -- "$target"
  notify "Failed to save clipboard image" "Removed the incomplete file: $target"
  exit 1
fi

rm -f -- "$tmp"
tmp=""
notify "Image pasted" "$target"
