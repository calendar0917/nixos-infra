{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.backup;

  backupScript = pkgs.writeShellApplication {
    name = "backup-to-usb";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      gnugrep
      systemd
      util-linux
    ];
    text = ''
      set -euo pipefail

      MOUNT_POINT=${lib.escapeShellArg cfg.mountPoint}
      EXPECTED_UUID=${lib.escapeShellArg (if cfg.usbUuid != null then cfg.usbUuid else "")}
      PASSWORD_FILE=${lib.escapeShellArg cfg.passwordFile}
      MARKER=".nixos-backup-target"

      die() {
        printf 'error: %s\n' "$*" >&2
        exit 1
      }

      require_root() {
        [ "$(id -u)" -eq 0 ] || die "run this command with sudo"
      }

      verify_usb() {
        [ -d "$MOUNT_POINT" ] || die "mount point does not exist: $MOUNT_POINT"
        findmnt --mountpoint "$MOUNT_POINT" >/dev/null 2>&1 \
          || die "$MOUNT_POINT is not a mount point; insert and mount the backup USB first"

        local source target dev parent removable transport root_source root_dev root_parent actual_uuid
        source="$(findmnt -n -o SOURCE --mountpoint "$MOUNT_POINT")"
        target="$(findmnt -n -o TARGET --mountpoint "$MOUNT_POINT")"
        [ "$(readlink -f "$MOUNT_POINT")" = "$(readlink -f "$target")" ] \
          || die "$MOUNT_POINT resolves to $target, refusing to continue"

        # btrfs may report /dev/sdb1[/subvol]; resolve the block device part.
        source="''${source%%\[*}"
        dev="$(readlink -f "$source")"
        parent="$(lsblk -no PKNAME "$dev" | head -n1)"
        parent="''${parent:+/dev/$parent}"
        parent="''${parent:-$dev}"

        if ! read -r removable transport < <(lsblk -ndo RM,TRAN "$parent"); then
          die "cannot inspect device $parent with lsblk"
        fi
        if [ "$removable" != "1" ] && [ "$transport" != "usb" ]; then
          die "$source is not a removable USB device (RM=$removable, TRAN=$transport)"
        fi

        root_source="$(findmnt -n -o SOURCE /)"
        root_dev="$(readlink -f "$root_source")"
        root_parent="$(lsblk -no PKNAME "$root_dev" | head -n1)"
        root_parent="''${root_parent:+/dev/$root_parent}"
        [ -z "$root_parent" ] || [ "$parent" != "$root_parent" ] \
          || die "refusing to write a backup to the system disk ($parent)"

        [ -f "$MOUNT_POINT/$MARKER" ] \
          || die "marker $MOUNT_POINT/$MARKER is missing; this is not the backup USB"

        if [ -n "$EXPECTED_UUID" ]; then
          actual_uuid="$(lsblk -ndo UUID "$dev" | head -n1)"
          [ "$actual_uuid" = "$EXPECTED_UUID" ] \
            || die "USB UUID mismatch: expected $EXPECTED_UUID, got $actual_uuid"
        fi

        [ -r "$PASSWORD_FILE" ] \
          || die "restic password file is not readable: $PASSWORD_FILE"

        command -v restic-usb >/dev/null 2>&1 \
          || die "restic-usb wrapper not found; is my.backup.enable set?"

        printf 'verified backup target: %s (%s, %s)\n' "$MOUNT_POINT" "$source" "$parent"
      }

      ensure_repository() {
        if ! restic-usb cat config >/dev/null 2>&1; then
          printf 'initializing restic repository under %s/restic\n' "$MOUNT_POINT"
          restic-usb init
        fi
      }

      usage() {
        cat <<'EOF'
      Usage: sudo backup-to-usb [--check|--snapshots]

        (no option)  verify the USB, initialize the repository if needed,
                     then run the manual restic backup service
        --check      run `restic check --read-data-subset=5%`
        --snapshots  list snapshots without creating a new one
      EOF
      }

      require_root
      verify_usb

      case "''${1:-}" in
        "" )
          ensure_repository
          systemctl start restic-backups-usb.service
          printf '\nsnapshots after backup:\n'
          restic-usb snapshots
          ;;
        --check )
          restic-usb check --read-data-subset=5%
          ;;
        --snapshots )
          restic-usb snapshots
          ;;
        --help|-h )
          usage
          ;;
        * )
          usage
          exit 1
          ;;
      esac
    '';
  };
in
{
  options.my.backup = {
    enable = lib.mkEnableOption "manual USB Restic backups";

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/run/media/calendar/NIXOS-BACKUP";
      description = "Mount point of the backup USB. It must be a real mount point.";
    };

    usbUuid = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional filesystem UUID. When set, the backup wrapper refuses any
        other device even if it happens to be mounted at `mountPoint`.
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/secrets/restic-password";
      description = ''
        Root-only restic password file. This is intentionally independent of
        SOPS so that restoring the repository never requires decrypting SOPS
        first.
      '';
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/home/calendar/life"
        "/home/calendar/code/nixos-infra"
        "/var/lib/sops-nix"
        "/home/calendar/.config/sops/age"
        "/home/calendar/.ssh"
        "/home/calendar/.gnupg"
        "/home/calendar/.local/share/keyrings"
      ];
      description = ''
        Paths to include. Missing paths produce a warning and are skipped.
        Git repositories and their .git directories are included in full.
      '';
    };

    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "**/.cache"
        "**/.direnv"
        "**/.venv"
        "**/node_modules"
        "**/__pycache__"
        "**/.pytest_cache"
        "**/.mypy_cache"
        "**/.ruff_cache"
      ];
      description = ''
        Only re-creatable cache/build directories are excluded. Do not add
        broad patterns such as `code`, `build`, `dist`, or `.git`: they can
        hide real source and uncommitted work.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.restic.backups.usb = {
      repository = "${cfg.mountPoint}/restic";
      passwordFile = cfg.passwordFile;
      exclude = cfg.exclude;
      dynamicFilesFrom = ''
        for path in ${lib.escapeShellArgs cfg.paths}; do
          if [ -e "$path" ]; then
            printf '%s\n' "$path"
          else
            printf 'warning: backup path missing: %s\n' "$path" >&2
          fi
        done
      '';

      # No timer. This is intentionally a manual, attended operation.
      timerConfig = null;
      initialize = false;
      runCheck = false;
      inhibitsSleep = true;
      extraBackupArgs = [ "--tag" "manual-usb" ];
    };

    # Even if someone starts the unit directly, systemd must confirm the USB
    # is mounted and carries the marker file.
    systemd.services."restic-backups-usb".unitConfig = {
      ConditionPathIsMountPoint = cfg.mountPoint;
      ConditionPathExists = "${cfg.mountPoint}/.nixos-backup-target";
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/secrets 0700 root root -"
    ];

    environment.systemPackages = [ backupScript ];
  };
}
