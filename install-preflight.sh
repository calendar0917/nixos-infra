#!/usr/bin/env bash
# Read-only preflight for the Arch/NixOS dual-boot installation.
#
# This script never creates subvolumes, mounts an installation target, edits
# the ESP, or runs nixos-install. It only inspects the current environment,
# the repository, and (if already mounted) /mnt.
#
# Exit codes:
#   0  read-only report passed (no install target), or installation-stage checks passed
#   1  FAIL: a real problem was found; do not install
#   2  usage error / target was not "main"
#  10  expected state: MAIN HARDWARE NOT GENERATED (installation blocked)

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET=""

usage() {
  cat <<'EOF'
Usage: ./install-preflight.sh [--repo DIR] [--target main]

  --repo DIR      repository root (default: this script's directory)
  --target main   installation-stage check. Requires the physical main host,
                  real main hardware, and all four /mnt target mounts.
  --help          show this help

Without --target, the script is a read-only report and does not require /mnt.
It never falls back to #nixos. #nixos is the NixOS mini host; #main is the
Arch main machine. --target main with missing target mounts exits non-zero.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ROOT=$2
      shift 2
      ;;
    --target)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      TARGET=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -n "$TARGET" ] && [ "$TARGET" != "main" ]; then
  echo "STOP: --target must be main."
  echo "      #nixos is the NixOS mini host, not the Arch main machine."
  echo "      Refusing target: $TARGET"
  exit 2
fi

MAIN_HW="$ROOT/hosts/main/hardware-configuration.nix"
MINI_HW="$ROOT/hosts/nixos/hardware-configuration.nix"

FAIL=0
WARN=0
EXPECTED_MISSING=0
FLAKE_MAIN=no
MAIN_HW_PRESENT=no
TARGET_MOUNTS=not-mounted
TARGET_MOUNTS_OK=no
HOST_OK=no
MNT_ROOT_OK=no
MNT_HOME_OK=no
MNT_NIX_OK=no
MNT_BOOT_OK=no
HW_ROOT_UUID=""
HW_HOME_UUID=""
HW_NIX_UUID=""
HW_BOOT_UUID=""

say() { printf '%s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; WARN=$((WARN + 1)); }
bad() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf 'NOTE: %s\n' "$*"; }

fs_block() {
  # Print the fileSystems."<key>" block from a generated hardware file.
  awk -v key="$1" '
    index($0, "fileSystems.\"" key "\"") { inblock = 1 }
    inblock { print }
    inblock && $0 ~ /^[[:space:]]*};/ { exit }
  ' "$MAIN_HW"
}

uuid_from_text() {
  printf '%s\n' "$1" | grep -o '/dev/disk/by-uuid/[A-Za-z0-9-]*' | head -1 | sed 's#.*/##'
}

say "== NixOS install preflight (read-only) =="
say "Repo:   $ROOT"
if [ -n "$TARGET" ]; then
  say "Target: $TARGET (explicitly confirmed)"
else
  say "Target: none (read-only report; installation is not confirmed)"
fi
say ""

# ---------- Environment ----------
os_id=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | head -1)
version_id=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -1)
pretty_name=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -1)
rootfs=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
ro_store_fs=$(findmnt -n -o FSTYPE /nix/.ro-store 2>/dev/null || true)
live=no
case "$rootfs" in
  overlay|tmpfs|squashfs) live=yes ;;
esac
if [ "$ro_store_fs" = "squashfs" ]; then
  live=yes
fi

say "[ENV] OS: ${pretty_name:-unknown} (ID=${os_id:-unknown}, VERSION_ID=${version_id:-unknown})"
say "[ENV] live root filesystem: ${rootfs:-unknown}; /nix/.ro-store: ${ro_store_fs:-not-mounted}"

if [ "$os_id" = "nixos" ] && [ "$live" = "yes" ]; then
  ok "running a NixOS Live ISO"
elif [ "$os_id" = "nixos" ]; then
  note "running NixOS, but not detected as a Live ISO (installed system?)"
else
  note "not running the NixOS ISO; this is a read-only rehearsal environment"
fi

if [ "$version_id" = "26.05" ]; then
  ok "ISO version is 26.05 (matches hosts/main stateVersion)"
elif [ -n "$version_id" ]; then
  warn "ISO VERSION_ID is $version_id, not 26.05; verify before installation"
fi

if [ -d /sys/firmware/efi ]; then
  ok "UEFI firmware boot"
else
  bad "not booted in UEFI mode; do not continue"
fi

vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)
product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
board=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)
first_disk_name=$(lsblk -dno NAME,TYPE,RM 2>/dev/null | awk '$2 == "disk" && $3 == "0" && $1 !~ /^(zram|loop|sr|ram)/ { print $1; exit }')
if [ -n "$first_disk_name" ]; then
  first_disk=$(lsblk -dno NAME,SIZE,MODEL "/dev/$first_disk_name" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g')
else
  first_disk=""
fi
say "[MACHINE] ${vendor} / ${product} / board ${board}"
say "[MACHINE] first internal disk: ${first_disk:-unknown}"

case "$product" in
  21LG)
    HOST_OK=yes
    ok "recorded Arch main machine (LENOVO ThinkBook 16 G6+ AHP)"
    ;;
  ITX-FP5)
    bad "this is the NixOS mini host (KOLOE ITX-FP5), not the Arch main machine"
    ;;
  *)
    bad "product '$product' is not the recorded main (LENOVO 21LG); refusing"
    ;;
esac

# ---------- Hardware file ----------
say ""
if [ -e "$MAIN_HW" ]; then
  MAIN_HW_PRESENT=yes
  ok "hosts/main/hardware-configuration.nix exists"

  if [ -L "$MAIN_HW" ]; then
    bad "main hardware is a symlink; it must be a real generated file"
  fi
  if [ ! -s "$MAIN_HW" ]; then
    bad "main hardware is empty"
  fi
  if [ -f "$MINI_HW" ] && cmp -s "$MAIN_HW" "$MINI_HW"; then
    bad "main hardware is byte-identical to hosts/nixos/hardware-configuration.nix"
  fi
  if grep -Eq 'PLACEHOLDER|CHANGEME|00000000-0000-0000-0000-000000000000|<[^>]*UUID' "$MAIN_HW"; then
    bad "main hardware contains a placeholder/empty UUID"
  fi

  hw_uuids=$(grep -o '/dev/disk/by-uuid/[A-Za-z0-9-]*' "$MAIN_HW" 2>/dev/null | sed 's#.*/##' | sort -u)
  actual_uuids=$(lsblk -rno UUID 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u)
  if [ -z "$hw_uuids" ]; then
    bad "main hardware has no /dev/disk/by-uuid entries"
  elif [ -z "$actual_uuids" ]; then
    warn "lsblk returned no UUIDs; cannot cross-check main hardware against this machine"
  else
    while IFS= read -r uuid; do
      [ -n "$uuid" ] || continue
      if printf '%s\n' "$actual_uuids" | grep -qxF "$uuid"; then
        ok "hardware UUID ${uuid:0:8}... exists on this machine"
      else
        bad "hardware UUID ${uuid:0:8}... is not present on this machine (copied or stale file?)"
      fi
    done <<< "$hw_uuids"
  fi

  if [ -f "$MINI_HW" ]; then
    mini_uuids=$(grep -o '/dev/disk/by-uuid/[A-Za-z0-9-]*' "$MINI_HW" 2>/dev/null | sed 's#.*/##' | sort -u)
    common_uuids=$(comm -12 <(printf '%s\n' "$hw_uuids") <(printf '%s\n' "$mini_uuids"))
    if [ -n "$common_uuids" ]; then
      bad "main hardware shares a UUID with the mini host hardware file"
    fi
  fi

  root_block=$(fs_block "/")
  home_block=$(fs_block "/home")
  nix_block=$(fs_block "/nix")
  boot_block=$(fs_block "/boot")
  HW_ROOT_UUID=$(uuid_from_text "$root_block")
  HW_HOME_UUID=$(uuid_from_text "$home_block")
  HW_NIX_UUID=$(uuid_from_text "$nix_block")
  HW_BOOT_UUID=$(uuid_from_text "$boot_block")

  if printf '%s\n' "$root_block" | grep -Eq 'subvol=/?@nixos(["[:space:],]|$)'; then
    ok "main root uses subvol=@nixos"
  else
    bad "main root does not use subvol=@nixos"
    if printf '%s\n' "$root_block" | grep -Eq 'subvol=/?@(["[:space:],]|$)'; then
      bad "main root uses subvol=@ (Arch root); refusing"
    fi
  fi
  if printf '%s\n' "$home_block" | grep -Eq 'subvol=/?@nixos-home(["[:space:],]|$)'; then
    ok "main /home uses subvol=@nixos-home"
  else
    bad "main /home does not use subvol=@nixos-home"
  fi
  if printf '%s\n' "$nix_block" | grep -Eq 'subvol=/?@nixos-nix(["[:space:],]|$)'; then
    ok "main /nix uses subvol=@nixos-nix"
  else
    bad "main /nix does not use subvol=@nixos-nix"
  fi
  if printf '%s\n' "$boot_block" | grep -q 'vfat'; then
    ok "main /boot is vfat (existing ESP)"
  else
    bad "main /boot is not vfat; expected the existing Arch ESP"
  fi
else
  EXPECTED_MISSING=1
  say "MAIN HARDWARE NOT GENERATED — EXPECTED BEFORE INSTALLATION"
  say "  hosts/main/hardware-configuration.nix is intentionally absent."
  say "  This is not a flake error. nixosConfigurations.main is not expected yet."
  say "  Do not run nixos-install --flake .#nixos; #nixos is the mini host."
  note "Generate it only after the @nixos/@nixos-home/@nixos-nix mounts pass."
fi

# ---------- Flake ----------
say ""
if command -v nix >/dev/null 2>&1; then
  nix_err=$(mktemp)
  attrs=$(cd "$ROOT" && nix --extra-experimental-features 'nix-command flakes' \
    eval --json --offline --no-write-lock-file \
    '.#nixosConfigurations' --apply builtins.attrNames 2>"$nix_err")
  nix_rc=$?
  if [ "$nix_rc" -eq 0 ]; then
    say "[FLAKE] nixosConfigurations: $attrs"
    if printf '%s' "$attrs" | grep -q '"nixos"'; then
      ok "flake exposes nixos (the mini host)"
    else
      warn "flake does not expose nixos; expected for this repository"
    fi
    if printf '%s' "$attrs" | grep -q '"main"'; then
      FLAKE_MAIN=yes
      ok "flake exposes main (the Arch main machine)"
    else
      FLAKE_MAIN=no
      if [ "$MAIN_HW_PRESENT" = "yes" ]; then
        bad "main hardware exists but flake does not expose main (is it in the git index?)"
      else
        note "flake exposes no main; this is expected until main hardware is generated"
      fi
    fi
  else
    if [ "$MAIN_HW_PRESENT" = "yes" ]; then
      bad "flake evaluation failed while main hardware exists"
    else
      warn "flake evaluation failed; import the Ventoy cache, then retry"
    fi
    sed -n '1,8p' "$nix_err" | sed 's/^/  /'
    FLAKE_MAIN=unknown
  fi
  rm -f "$nix_err"
else
  warn "nix not found; cannot verify flake outputs"
  FLAKE_MAIN=unknown
fi

# ---------- Git tracking ----------
if [ "$MAIN_HW_PRESENT" = "yes" ]; then
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$ROOT" check-ignore -q 'hosts/main/hardware-configuration.nix'; then
      bad "main hardware is ignored by git; a Git flake will not see it"
    elif git -C "$ROOT" ls-files --error-unmatch 'hosts/main/hardware-configuration.nix' >/dev/null 2>&1; then
      ok "main hardware is tracked by git"
    else
      bad "main hardware exists but is not in the git index; run git add first"
    fi
  else
    warn "repository is not a git work tree; Git-flake evaluation cannot be verified"
  fi
fi

# ---------- Boot hook / target mounts ----------
say ""
if [ -f "$ROOT/hosts/main/boot.nix" ]; then
  if grep -q 'extraInstallCommands' "$ROOT/hosts/main/boot.nix"; then
    if grep -q '/boot/loader/loader.conf' "$ROOT/hosts/main/boot.nix"; then
      note "main boot hook edits /boot/loader/loader.conf"
      note "during nixos-install this runs inside nixos-enter, so /boot is the target ESP"
      note "never run the generated install-systemd-boot.sh manually from the Live shell"
    else
      warn "main boot hook exists but /boot/loader/loader.conf was not found in it"
    fi
  fi
fi

if findmnt -rn -M /mnt >/dev/null 2>&1; then
  TARGET_MOUNTS=mounted
  note "/mnt is mounted; checking the installation-stage layout"

  mnt_opts=$(findmnt -rn -o OPTIONS -M /mnt 2>/dev/null || true)
  home_opts=$(findmnt -rn -o OPTIONS -M /mnt/home 2>/dev/null || true)
  nix_opts=$(findmnt -rn -o OPTIONS -M /mnt/nix 2>/dev/null || true)
  boot_opts=$(findmnt -rn -o OPTIONS -M /mnt/boot 2>/dev/null || true)
  boot_fs=$(findmnt -rn -o FSTYPE -M /mnt/boot 2>/dev/null || true)
  mnt_uuid=$(findmnt -rn -o UUID -M /mnt 2>/dev/null || true)
  home_uuid=$(findmnt -rn -o UUID -M /mnt/home 2>/dev/null || true)
  nix_uuid=$(findmnt -rn -o UUID -M /mnt/nix 2>/dev/null || true)
  boot_uuid=$(findmnt -rn -o UUID -M /mnt/boot 2>/dev/null || true)

  if printf '%s\n' "$mnt_opts" | grep -Eq 'subvol=/?@nixos([,[:space:]]|$)'; then
    MNT_ROOT_OK=yes
    ok "/mnt options contain subvol=@nixos"
  else
    bad "/mnt is not mounted with subvol=@nixos"
  fi
  if printf '%s\n' "$home_opts" | grep -Eq 'subvol=/?@nixos-home([,[:space:]]|$)'; then
    MNT_HOME_OK=yes
    ok "/mnt/home options contain subvol=@nixos-home"
  else
    bad "/mnt/home is not mounted with subvol=@nixos-home"
  fi
  if printf '%s\n' "$nix_opts" | grep -Eq 'subvol=/?@nixos-nix([,[:space:]]|$)'; then
    MNT_NIX_OK=yes
    ok "/mnt/nix options contain subvol=@nixos-nix"
  else
    bad "/mnt/nix is not mounted with subvol=@nixos-nix"
  fi

  if [ "$boot_fs" = "vfat" ]; then
    if [ "$MAIN_HW_PRESENT" = "yes" ] && [ -n "$HW_BOOT_UUID" ] && [ "$boot_uuid" != "$HW_BOOT_UUID" ]; then
      bad "/mnt/boot UUID does not match main hardware /boot (not the original Arch ESP)"
    elif [ ! -f /mnt/boot/EFI/Linux/arch-linux-lts.efi ]; then
      bad "/mnt/boot is vfat but has no Arch UKI; not the original Arch ESP"
    elif [ ! -f /mnt/boot/EFI/Lenovo/BIOS/SelfHealing.fd ]; then
      bad "/mnt/boot is vfat but has no Lenovo self-healing file; not the original Arch ESP"
    else
      MNT_BOOT_OK=yes
      ok "/mnt/boot is the original Arch ESP (vfat, UUID, UKI, Lenovo file)"
    fi
  else
    bad "/mnt/boot is not a mounted vfat ESP"
  fi

  if [ "$MAIN_HW_PRESENT" = "yes" ] && [ -n "$HW_ROOT_UUID" ] && [ "$mnt_uuid" != "$HW_ROOT_UUID" ]; then
    bad "/mnt UUID does not match main hardware / (wrong Btrfs filesystem)"
  fi
  if [ "$MAIN_HW_PRESENT" = "yes" ] && [ -n "$HW_HOME_UUID" ] && [ "$home_uuid" != "$HW_HOME_UUID" ]; then
    bad "/mnt/home UUID does not match main hardware /home"
  fi
  if [ "$MAIN_HW_PRESENT" = "yes" ] && [ -n "$HW_NIX_UUID" ] && [ "$nix_uuid" != "$HW_NIX_UUID" ]; then
    bad "/mnt/nix UUID does not match main hardware /nix"
  fi

  extra_mounts=$(findmnt -R /mnt -n -o TARGET 2>/dev/null | grep -vE '^/mnt(/home|/nix|/boot)?$' || true)
  if [ -n "$extra_mounts" ]; then
    bad "unexpected mounts under /mnt: $(printf '%s' "$extra_mounts" | tr '\n' ' ')"
  fi

  if [ "$MNT_ROOT_OK" = "yes" ] && [ "$MNT_HOME_OK" = "yes" ] \
    && [ "$MNT_NIX_OK" = "yes" ] && [ "$MNT_BOOT_OK" = "yes" ]; then
    TARGET_MOUNTS_OK=yes
  fi

  if [ "$TARGET" = "main" ] && { [ "$os_id" != "nixos" ] || [ "$live" != "yes" ]; }; then
    bad "--target main installation-stage checks require the NixOS Live ISO"
  fi

  if findmnt -rn -M /boot >/dev/null 2>&1; then
    mnt_boot_id=$(findmnt -rn -o MAJ:MIN -M /mnt/boot 2>/dev/null || true)
    live_boot_id=$(findmnt -rn -o MAJ:MIN -M /boot 2>/dev/null || true)
    if [ -n "$mnt_boot_id" ] && [ -n "$live_boot_id" ] && [ "$mnt_boot_id" != "$live_boot_id" ]; then
      note "current /boot differs from /mnt/boot; this is expected outside the install chroot"
      note "do not edit loader.conf from this shell; nixos-install does it inside nixos-enter"
    fi
  fi
else
  note "/mnt is not mounted; Phase D target mounts have not started"
fi

# ---------- Summary ----------
say ""
if [ "$FAIL" -ne 0 ]; then
  say "RESULT: FAIL — STOP. Do not create subvolumes, mount targets, or install."
  say "        Fix the FAIL lines above, then rerun this script."
  exit 1
fi

if [ "$EXPECTED_MISSING" -ne 0 ]; then
  say "RESULT: STOP — expected pre-install state."
  say "        MAIN HARDWARE NOT GENERATED — EXPECTED BEFORE INSTALLATION"
  say "        Next: Phase D (separate authorization) must create and mount the"
  say "        three @nixos* subvolumes before nixos-generate-config --root /mnt."
  exit 10
fi

if [ -z "$TARGET" ]; then
  say "RESULT: PASS (read-only) — no install target confirmed."
  say "        Installation is not authorized by this script."
  exit 0
fi

if [ "$FLAKE_MAIN" != "yes" ]; then
  say "RESULT: FAIL — target main was requested, but the flake does not expose main."
  say "        Add the real generated hardware file to the git index; never copy"
  say "        hosts/nixos/hardware-configuration.nix to hosts/main."
  exit 1
fi

if [ "$TARGET_MOUNTS" != "mounted" ]; then
  say "RESULT: FAIL — --target main requires the Phase D target mounts."
  say "        /mnt, /mnt/home, /mnt/nix, /mnt/boot must all be mounted and verified."
  say "        This script does not authorize installation by itself."
  exit 1
fi

if [ "$HOST_OK" != "yes" ]; then
  say "RESULT: FAIL — --target main requires the LENOVO 21LG main machine."
  exit 1
fi

if [ "$TARGET_MOUNTS_OK" != "yes" ]; then
  say "RESULT: FAIL — target mounts are present but do not match the required layout."
  exit 1
fi

say "RESULT: PASS — main host, main hardware, and all four target mounts match."
say "        Installation still requires separate explicit authorization;"
say "        this script never runs nixos-install."
if [ "$live" != "yes" ]; then
  say "NOTE: this is not the NixOS ISO; do not install from this environment."
fi
exit 0
