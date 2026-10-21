{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.backup;

  expectedUuid = if cfg.usbUuid != null then cfg.usbUuid else "";

  verifyScript = pkgs.writeShellApplication {
    name = "verify-usb-backup-target";
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
      EXPECTED_UUID=${lib.escapeShellArg expectedUuid}
      PASSWORD_FILE=${lib.escapeShellArg cfg.passwordFile}
      MARKER=".nixos-backup-target"

      die() {
        printf 'error: %s\n' "$*" >&2
        exit 1
      }

      [ "$(id -u)" -eq 0 ] || die "run this command with sudo"

      # This is a mandatory identity check, not a warning. A null value means
      # the real USB UUID has not been configured yet.
      [ -n "$EXPECTED_UUID" ] \
        || die "my.backup.usbUuid is empty; set the real backup USB UUID before enabling or starting the service"
      [ -d "$MOUNT_POINT" ] || die "mount point does not exist: $MOUNT_POINT"
      findmnt --mountpoint "$MOUNT_POINT" >/dev/null 2>&1 \
        || die "$MOUNT_POINT is not a mount point; insert and mount the backup USB first"

      source="$(findmnt -n -o SOURCE --mountpoint "$MOUNT_POINT")"
      target="$(findmnt -n -o TARGET --mountpoint "$MOUNT_POINT")"
      [ "$(readlink -f "$MOUNT_POINT")" = "$(readlink -f "$target")" ] \
        || die "$MOUNT_POINT resolves to $target, refusing to continue"

      # btrfs may report /dev/sdb1[/subvol]; compare the block device itself.
      source="''${source%%\[*}"
      dev="$(readlink -f "$source")"
      [ -b "$dev" ] || die "$source is not a block device"
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
      root_source="''${root_source%%\[*}"
      root_dev="$(readlink -f "$root_source")"
      root_parent="$(lsblk -no PKNAME "$root_dev" | head -n1)"
      root_parent="''${root_parent:+/dev/$root_parent}"
      [ -z "$root_parent" ] || [ "$parent" != "$root_parent" ] \
        || die "refusing to write a backup to the system disk ($parent)"

      [ -f "$MOUNT_POINT/$MARKER" ] \
        || die "marker $MOUNT_POINT/$MARKER is missing; this is not the backup USB"

      actual_uuid="$(lsblk -ndo UUID "$dev" | head -n1)"
      [ "$actual_uuid" = "$EXPECTED_UUID" ] \
        || die "USB UUID mismatch: expected $EXPECTED_UUID, got ''${actual_uuid:-<none>}"

      [ -r "$PASSWORD_FILE" ] \
        || die "restic password file is not readable: $PASSWORD_FILE"

      # Missing critical data is a hard failure, not a warning. This runs on
      # every start, including a direct `systemctl start`.
      for path in ${lib.escapeShellArgs cfg.paths}; do
        [ -e "$path" ] || die "required backup path missing: $path"
      done

      printf 'verified backup target: %s (%s, %s, UUID %s)\n' \
        "$MOUNT_POINT" "$source" "$parent" "$actual_uuid"
    '';
  };

  backupScript = pkgs.writeShellApplication {
    name = "backup-to-usb";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'USAGE'
      Usage: sudo backup-to-usb [--init|--check|--snapshots]

        (no option)  verify the USB, then run the manual restic backup service
        --init       verify the USB and initialize a new restic repository
        --check      run `restic check --read-data-subset=5%`
        --snapshots  list snapshots without creating a new one

      The repository is never initialized implicitly. Run --init exactly once
      for a new backup USB, and only after the UUID in my.backup.usbUuid has
      been verified.
      USAGE
      }

      case "''${1:-}" in
        --help|-h )
          usage
          exit 0
          ;;
      esac

      ${verifyScript}/bin/verify-usb-backup-target

      case "''${1:-}" in
        "" )
          systemctl start restic-backups-usb.service
          printf '\nsnapshots after backup:\n'
          restic-usb snapshots
          ;;
        --init )
          set +e
          restic-usb cat config >/dev/null 2>&1
          status=$?
          set -e
          case "$status" in
            0)
              printf 'error: restic repository already exists; refusing to reinitialize\n' >&2
              exit 1
              ;;
            10)
              restic-usb init
              ;;
            * )
              printf 'error: cannot inspect the repository (restic exit %s); refusing to initialize\n' "$status" >&2
              exit 1
              ;;
          esac
          ;;
        --check )
          restic-usb check --read-data-subset=5%
          ;;
        --snapshots )
          restic-usb snapshots
          ;;
        * )
          usage >&2
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
        Filesystem UUID of the backup USB. Required when `enable` is true. The
        UUID is checked by the systemd service itself before every backup, not
        only by the `backup-to-usb` wrapper.
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
        "/home/calendar/.local/share/io.github.clash-verge-rev.clash-verge-rev"
      ];
      description = ''
        Paths to include. Every configured path must exist: a missing path
        aborts the backup instead of silently producing an incomplete archive.
        The Clash Verge directory contains GUI-managed profiles and
        subscriptions; its logs and local backups are excluded below.
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
        "**/io.github.clash-verge-rev.clash-verge-rev/logs"
        "**/io.github.clash-verge-rev.clash-verge-rev/clash-verge-rev-backup"
      ];
      description = ''
        Only re-creatable caches, logs and local app backups are excluded. Do
        not add broad patterns such as `code`, `build`, `dist`, or `.git`:
        they can hide real source and uncommitted work.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.usbUuid != null && cfg.usbUuid != "";
        message = "my.backup.usbUuid must be set to the real backup USB filesystem UUID before enabling backups.";
      }
    ];

    services.restic.backups.usb = {
      repository = "${cfg.mountPoint}/restic";
      passwordFile = cfg.passwordFile;
      exclude = cfg.exclude;

      # The script exits non-zero when any configured path is missing. The
      # restic module runs this after backupPrepareCommand and before restic.
      dynamicFilesFrom = ''
        for path in ${lib.escapeShellArgs cfg.paths}; do
          if [ ! -e "$path" ]; then
            printf 'error: required backup path missing: %s\n' "$path" >&2
            exit 1
          fi
          printf '%s\n' "$path"
        done
      '';

      # Every service start, including `systemctl start`, runs this identity
      # check. There is deliberately no implicit `restic init`.
      backupPrepareCommand = "${verifyScript}/bin/verify-usb-backup-target";

      # No timer. This is intentionally a manual, attended operation.
      timerConfig = null;
      initialize = false;
      runCheck = false;
      inhibitsSleep = true;
      extraBackupArgs = [ "--tag" "manual-usb" ];
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/secrets 0700 root root -"
    ];

    environment.systemPackages = [
      backupScript
      verifyScript
    ];
  };
}
