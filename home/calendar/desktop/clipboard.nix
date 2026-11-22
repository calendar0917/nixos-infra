{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  niriEnabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
  shell = if osConfig != null then (osConfig.my.desktop.niri.shell or "dms") else "dms";
  enabled = niriEnabled && shell == "waybar";
  niriLib = import ./lib.nix { inherit pkgs lib; };

  # All cliphist clients use the same session database. Do not fall back to
  # ~/.cache/cliphist: that is the old persistent database and is deliberately
  # left untouched.
  cliphistSession = pkgs.writeShellApplication {
    name = "niri-cliphist-session";
    runtimeInputs = with pkgs; [
      cliphist
      coreutils
      wl-clipboard
      cliphistStore
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
      session_dir="$runtime_dir/niri-cliphist"
      db="$session_dir/db"

      # shellcheck disable=SC2329 # invoked from the EXIT trap
      cleanup() {
        rm -rf -- "$session_dir"
      }

      # A previous compositor may have died without running its stop job.
      # Starting from an empty directory is the only reliable way to avoid
      # carrying clipboard data into the next graphical session.
      rm -rf -- "$session_dir"
      mkdir -m 700 -- "$session_dir"

      export CLIPHIST_DB_PATH="$db"
      # cliphist 0.7.0 only accepts these as CLI flags. They are exported too
      # so the per-item store helper enforces the same limits; the exported
      # names are not read by cliphist itself.
      export CLIPHIST_MAX_ITEMS=100
      export CLIPHIST_MAX_STORE_SIZE=2097152
      umask 077

      trap 'cleanup' EXIT
      trap 'exit 0' HUP INT TERM

      wl-paste --type text --watch niri-cliphist-store &
      text_pid=$!
      wl-paste --type image --watch niri-cliphist-store &
      image_pid=$!

      # A watcher exiting while the session is still up is a failure and
      # should restart the pair. A normal systemd stop exits through the TERM
      # trap above instead.
      set +e
      wait -n "$text_pid" "$image_pid"
      kill "$text_pid" "$image_pid" 2>/dev/null
      wait "$text_pid" "$image_pid" 2>/dev/null
      exit 1
    '';
  };

  # xwayland-satellite can leave the X11 CLIPBOARD selection owned by itself
  # while it refuses to hand out the data (upstream issue #485). Native Wayland
  # clients keep working, but every X11 client, such as ONLYOFFICE and QQ,
  # pastes nothing until the satellite is restarted. This fallback watches new
  # Wayland text and images and makes xclip the X11 owner only while the X11
  # side cannot return the same bytes, so a healthy satellite is never touched.
  x11ClipBridge = pkgs.writeShellApplication {
    name = "niri-x11-clipbridge";
    runtimeInputs = with pkgs; [
      coreutils
      wl-clipboard
      xclip
    ];
    text = ''
      max_size="''${CLIPBRIDGE_MAX_SIZE:-2097152}"
      image_max_size="''${CLIPBRIDGE_IMAGE_MAX_SIZE:-33554432}"

      # niri exports DISPLAY for the session; a user unit started later can
      # still miss it, so fall back to the socket directory and wait for the
      # on-demand Xwayland instead of restart-looping.
      display="''${DISPLAY:-}"
      while [ -z "$display" ]; do
        for socket in /tmp/.X11-unix/X*; do
          if [ -S "$socket" ]; then
            display=":''${socket##*/X}"
            break
          fi
        done
        if [ -z "$display" ]; then
          sleep 2
        fi
      done
      export DISPLAY="$display"

      umask 077

      # Text. Command substitution drops trailing newlines on both sides, so
      # satellite echoing the X11 owner back into Wayland does not look like
      # new content and cannot ping-pong. When the same copy also offers an
      # image (copying a picture out of a browser), the image branch wins:
      # xclip can only serve one target per owner, and a picture is what the
      # user wanted there.
      push_text_once() {
        offer="$(timeout 2 wl-paste --list-types 2>/dev/null || true)"
        case "$offer" in
          *image/*) return 0 ;;
        esac
        data="$(head -c "$max_size")"
        [ -n "$data" ] || return 0
        current="$(timeout 2 xclip -o -selection clipboard 2>/dev/null | head -c "$max_size" || true)"
        if [ "$current" = "$data" ]; then
          return 0
        fi
        printf '%s' "$data" | timeout 2 xclip -selection clipboard -i || return 0
      }

      # wl-paste hands over whichever image/* MIME type it picked, so the type
      # announced to X11 is sniffed from the same magic bytes cliphist uses.
      image_mime() {
        header="$(od -An -tx1 -N12 "$1" | tr -d ' \n')"
        case "$header" in
          89504e47*) printf 'image/png' ;;
          ffd8ff*) printf 'image/jpeg' ;;
          47494638*) printf 'image/gif' ;;
          424d*) printf 'image/bmp' ;;
          52494646????????57454250) printf 'image/webp' ;;
        esac
      }

      # Images are compared byte for byte in files: command substitution would
      # strip trailing newlines from the binary data.
      push_image_once() {
        tmp="$(mktemp "''${XDG_RUNTIME_DIR:-/tmp}/clipbridge.XXXXXX")"
        cur="$(mktemp "''${XDG_RUNTIME_DIR:-/tmp}/clipbridge.XXXXXX")"
        # One byte past the cap: an oversized picture is dropped instead of
        # handing a truncated (and therefore broken) file to xclip.
        head -c "$((image_max_size + 1))" > "$tmp"
        if [ "$(stat -c %s -- "$tmp")" -gt "$image_max_size" ]; then
          rm -f -- "$tmp" "$cur"
          return 0
        fi
        mime="$(image_mime "$tmp")"
        if [ -s "$tmp" ] && [ -n "$mime" ] \
          && timeout 3 xclip -o -selection clipboard -t "$mime" > "$cur" 2>/dev/null \
          && cmp -s -- "$tmp" "$cur"; then
          rm -f -- "$tmp" "$cur"
          return 0
        fi
        if [ -n "$mime" ]; then
          timeout 5 xclip -selection clipboard -t "$mime" -i "$tmp" || true
        fi
        rm -f -- "$tmp" "$cur"
      }

      case "''${1:-}" in
        --push-text)
          push_text_once
          exit 0
          ;;
        --push-image)
          push_image_once
          exit 0
          ;;
      esac

      # Two watchers: text and any image/* type. If either one dies, the pair
      # is restarted instead of leaving half of the bridge down.
      while :; do
        wl-paste --type text --watch "$0" --push-text &
        text_pid=$!
        wl-paste --type image --watch "$0" --push-image &
        image_pid=$!
        wait -n "$text_pid" "$image_pid" || true
        kill "$text_pid" "$image_pid" 2>/dev/null || true
        wait "$text_pid" "$image_pid" 2>/dev/null || true
        sleep 1
      done
    '';
  };

  # One capped store helper for both clipboard watch types. cliphist detects
  # images from their magic bytes, so the helper does not need to know which
  # watcher invoked it.
  cliphistStore = pkgs.writeShellApplication {
    name = "niri-cliphist-store";
    runtimeInputs = with pkgs; [
      cliphist
      coreutils
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
      db="''${CLIPHIST_DB_PATH:?CLIPHIST_DB_PATH is not set}"
      max_items="''${CLIPHIST_MAX_ITEMS:-100}"
      max_size="''${CLIPHIST_MAX_STORE_SIZE:-2097152}"
      tmp="$(mktemp "$runtime_dir/niri-cliphist/item.XXXXXX")"
      trap 'rm -f -- "$tmp"' EXIT

      # Read one byte past the limit so oversized data is rejected without
      # buffering an arbitrary amount of clipboard content on tmpfs.
      head -c "$((max_size + 1))" > "$tmp"
      size="$(stat -c %s -- "$tmp")"
      if [ "$size" -le "$max_size" ]; then
        cliphist -db-path "$db" -max-items "$max_items" store < "$tmp"
      fi
    '';
  };

  clipboardMenu = pkgs.writeShellApplication {
    name = "niri-clipboard-menu";
    runtimeInputs = with pkgs; [
      cliphist
      fuzzel
      coreutils
      wl-clipboard
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
      db="$runtime_dir/niri-cliphist/db"

      # No live session database: exit quietly. Never fall back to the old
      # ~/.cache/cliphist database.
      if [ ! -s "$db" ]; then
        exit 0
      fi

      export CLIPHIST_DB_PATH="$db"

      if ! selection="$(cliphist -db-path "$db" list | fuzzel --dmenu --prompt='Clipboard: ')"; then
        exit 0
      fi
      if [ -z "$selection" ]; then
        exit 0
      fi

      mime=""
      case "$selection" in
        *"image/png"*) mime="image/png" ;;
        *"image/jpeg"*) mime="image/jpeg" ;;
        *"image/gif"*) mime="image/gif" ;;
        *"image/webp"*) mime="image/webp" ;;
        *"image/bmp"*) mime="image/bmp" ;;
      esac

      if [ -n "$mime" ]; then
        printf '%s\n' "$selection" | cliphist -db-path "$db" decode | wl-copy --type "$mime"
      else
        printf '%s\n' "$selection" | cliphist -db-path "$db" decode | wl-copy
      fi
    '';
  };
in
{
  config = lib.mkIf enabled {
    home.packages = with pkgs; [
      cliphist
      clipboardMenu
    ];

    systemd.user.services.niri-cliphist = {
      Unit = niriLib.niriUnit // {
        Description = "Session-local cliphist watchers";
      };
      Service = {
        Type = "simple";
        ExecCondition = niriLib.noDmsGuard;
        ExecStart = "${cliphistSession}/bin/niri-cliphist-session";
        Restart = "on-failure";
        RestartSec = 1;
        UMask = "0077";
      };
      Install = niriLib.niriInstall;
    };

    systemd.user.services.niri-x11-clipbridge = {
      Unit = niriLib.niriUnit // {
        Description = "Wayland-to-X11 clipboard fallback for the niri session";
      };
      Service = {
        Type = "simple";
        ExecCondition = niriLib.noDmsGuard;
        ExecStart = "${x11ClipBridge}/bin/niri-x11-clipbridge";
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install = niriLib.niriInstall;
    };
  };
}
