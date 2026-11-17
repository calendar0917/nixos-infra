{
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  # Mark Shot is a main-only desktop application. The mini host keeps its
  # existing session and base Yazi setup untouched.
  isMain = osConfig != null && (osConfig.networking.hostName or "") == "main";

  # The release is an AppImage, so wrap the fixed Type 2 image instead of
  # unpacking and patching an archive by hand. The URL and hash are pinned to
  # v0.2.0; do not replace the hash to make a different download build.
  markShot = pkgs.appimageTools.wrapType2 {
    pname = "mark-shot";
    version = "0.2.0";
    src = pkgs.fetchurl {
      url = "https://github.com/jswysnemc/mark-shot/releases/download/v0.2.0/mark-shot-native-0.2.0-linux-x86_64.AppImage";
      sha256 = "b85f67274916b4a1636c3a3e1a9797a6393eff3b6f84c0ba17b31ed9c3469981";
    };
    meta = {
      description = "Native screenshot, annotation and scrolling capture editor";
      homepage = "https://github.com/jswysnemc/mark-shot";
      license = with lib.licenses; [
        mit
        asl20
      ];
      mainProgram = "mark-shot";
      platforms = [ "x86_64-linux" ];
    };
  };

  # One compositor-facing entry point. Capture and scrolling both save into the
  # existing ~/Pictures/Screenshots directory and use `-t cs` so Mark Shot both
  # copies the finished image and writes the file itself. No tray service or
  # global-shortcut daemon is started.
  desktopShot = pkgs.writeShellApplication {
    name = "desktop-shot";
    runtimeInputs = with pkgs; [
      coreutils
      libnotify
      markShot
    ];
    text = ''
      mark_shot_bin="''${DESKTOP_SHOT_MARK_SHOT:-${lib.getExe markShot}}"
      notify_bin="''${DESKTOP_SHOT_NOTIFY:-${lib.getExe' pkgs.libnotify "notify-send"}}"
      home="''${HOME:?HOME is not set}"
      screenshot_dir="''${DESKTOP_SHOT_DIR:-$home/Pictures/Screenshots}"

      usage() {
        cat >&2 <<'EOF'
      Usage: desktop-shot {capture|scroll|pin}

        capture  Mark Shot region capture and annotation
        scroll   Mark Shot scrolling screenshot
        pin      pin the current clipboard as a floating window
      EOF
      }

      notify() {
        "$notify_bin" --app-name=Mark-Shot -- "$1" "''${2:-}" >/dev/null 2>&1 || true
      }

      if [ "$#" -ne 1 ]; then
        usage
        exit 2
      fi

      case "$1" in
        capture)
          if ! mkdir -p -- "$screenshot_dir" || [ ! -w "$screenshot_dir" ]; then
            notify "Screenshot directory is not writable" "$screenshot_dir"
            exit 1
          fi
          exec "$mark_shot_bin" --output "$screenshot_dir" -t cs
          ;;
        scroll)
          if ! mkdir -p -- "$screenshot_dir" || [ ! -w "$screenshot_dir" ]; then
            notify "Screenshot directory is not writable" "$screenshot_dir"
            exit 1
          fi
          exec "$mark_shot_bin" --scroll --output "$screenshot_dir" -t cs
          ;;
        pin)
          exec "$mark_shot_bin" --pin-clipboard
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    '';
  };

  # Small Yazi-facing wrapper for `c t`. It only forwards a real image file to
  # Mark Shot's pin window and reports invalid selections instead of passing a
  # directory or text file to the application.
  yaziPinImage = pkgs.writeShellApplication {
    name = "yazi-pin-image";
    runtimeInputs = with pkgs; [
      coreutils
      file
      libnotify
      markShot
    ];
    text = ''
      mark_shot_bin="''${YAZI_PIN_MARK_SHOT:-${lib.getExe markShot}}"
      file_bin="''${YAZI_PIN_FILE:-${lib.getExe' pkgs.file "file"}}"
      notify_bin="''${YAZI_PIN_NOTIFY:-${lib.getExe' pkgs.libnotify "notify-send"}}"

      notify() {
        "$notify_bin" --app-name=Yazi -- "$1" "''${2:-}" >/dev/null 2>&1 || true
        if [ -n "''${2:-}" ]; then
          printf 'yazi-pin-image: %s: %s\n' "$1" "$2" >&2
        else
          printf 'yazi-pin-image: %s\n' "$1" >&2
        fi
      }

      if [ "$#" -ne 1 ] || [ -z "$1" ]; then
        notify "No image to pin" "Put the cursor on an image file first."
        exit 2
      fi

      image="$1"
      if [ ! -f "$image" ]; then
        notify "Cannot pin this entry" "Not a regular file: $image"
        exit 1
      fi

      mime="$("$file_bin" -b --mime-type -- "$image" 2>/dev/null || true)"
      case "$mime" in
        image/*) ;;
        *)
          notify "Cannot pin this file" "Not an image: $image (''${mime:-unknown type})"
          exit 1
          ;;
      esac

      if ! "$mark_shot_bin" --pin-image "$image"; then
        notify "Mark Shot could not pin the image" "$image"
        exit 1
      fi
    '';
  };
in
{
  config = lib.mkIf isMain {
    home.packages = [
      markShot
      desktopShot
      yaziPinImage
    ];
  };
}
