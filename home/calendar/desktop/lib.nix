# Small shared helpers for the niri Waybar shell. This is plain Nix data, not a
# second module framework: clipboard, panel and lock modules all need the same
# niri-bound unit shape and the same transition guard against DMS.
{
  pkgs,
  lib,
}:

let
  niriLib = {
    # Home Manager may start newly added units while the old generation is
    # still logged in with DMS. Refuse to start the Waybar shell helpers while
    # DMS is active; the next graphical login has no DMS unit.
    noDmsGuard = pkgs.writeShellScript "niri-shell-guard-no-dms" ''
      if ${lib.getExe' pkgs.systemd "systemctl"} --user is-active --quiet dms.service; then
        exit 1
      fi
      exit 0
    '';

    niriUnit = {
      PartOf = [ "niri.service" ];
      BindsTo = [ "niri.service" ];
      After = [ "niri.service" ];
    };

    niriInstall = {
      WantedBy = [ "niri.service" ];
    };

    # The unit itself enforces single-instance semantics through systemd: a
    # second start while hyprlock is running is a no-op, not a new process.
    niriLock = pkgs.writeShellApplication {
      name = "niri-lock";
      runtimeInputs = [ pkgs.systemd ];
      text = ''
        exec ${lib.getExe' pkgs.systemd "systemctl"} --user start niri-lock-screen.service
      '';
    };

    # Start the existing lock unit and wait until logind really reports
    # LockedHint=yes for this session. niri 26.04 sets that hint only after
    # the lock surface has been committed, so this is not a SetLockedHint
    # shortcut. The unit must remain active while we wait; a crashed Hyprlock
    # must fail immediately instead of letting a suspend proceed.
    niriLockWait = pkgs.writeShellApplication {
      name = "niri-lock-wait";
      runtimeInputs = with pkgs; [
        coreutils
        systemd
      ];
      text = ''
        set -euo pipefail

        session_id="''${XDG_SESSION_ID:-}"
        if [ -z "$session_id" ]; then
          echo "niri-lock-wait: XDG_SESSION_ID is not set; cannot identify the current logind session" >&2
          exit 1
        fi

        # Absolute paths by default. The environment overrides exist only so
        # the headless regression tests can substitute stub commands.
        systemctl_bin="''${NIRI_LOCK_WAIT_SYSTEMCTL:-${lib.getExe' pkgs.systemd "systemctl"}}"
        loginctl_bin="''${NIRI_LOCK_WAIT_LOGINCTL:-${lib.getExe' pkgs.systemd "loginctl"}}"
        sleep_bin="''${NIRI_LOCK_WAIT_SLEEP:-${lib.getExe' pkgs.coreutils "sleep"}}"

        uid="$(id -u)"
        if ! session_uid="$("$loginctl_bin" show-session "$session_id" -p UID --value 2>&1)"; then
          echo "niri-lock-wait: logind session '$session_id' is not valid: $session_uid" >&2
          exit 1
        fi
        if [ "$session_uid" != "$uid" ]; then
          echo "niri-lock-wait: logind session '$session_id' belongs to UID $session_uid, not $uid" >&2
          exit 1
        fi

        if ! "$systemctl_bin" --user start niri-lock-screen.service; then
          echo "niri-lock-wait: failed to start niri-lock-screen.service" >&2
          exit 1
        fi

        # 60 * 50ms is about three seconds, excluding command overhead. Do not
        # extend logind's global inhibitor timeout here.
        for _ in $(seq 1 60); do
          state="$("$systemctl_bin" --user show niri-lock-screen.service -p ActiveState --value 2>/dev/null || true)"
          case "$state" in
            active|activating)
              ;;
            *)
              echo "niri-lock-wait: niri-lock-screen.service is '$state'; refusing to continue" >&2
              exit 1
              ;;
          esac

          locked="$("$loginctl_bin" show-session "$session_id" -p LockedHint --value 2>/dev/null || true)"
          if [ "$locked" = "yes" ]; then
            exit 0
          fi
          "$sleep_bin" 0.05
        done

        echo "niri-lock-wait: timed out waiting for logind LockedHint=yes in session '$session_id'" >&2
        exit 1
      '';
    };
  };
in
niriLib
