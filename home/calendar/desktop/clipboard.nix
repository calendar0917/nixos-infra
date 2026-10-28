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
  };
}
