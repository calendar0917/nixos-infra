#!/usr/bin/env bash
# NixOS dual-boot installation assistant for the Arch main machine.
#
# This is the single on-site entry point. It is safe by construction:
#   - Ventoy is only ever mounted/read through a read-only view.
#   - Arch subvolumes (@, @home, @log, @pkg) are never created or deleted.
#   - The local Mihomo profile is copied to a private tmpfs directory; it is
#     never written to Ventoy, Git, the Nix store or the installation target.
#   - Every step that writes the target disk requires a separate typed phrase.
#   - It never runs mkfs, never repartitions, never changes the btrfs default
#     subvolume, never deletes snapshots, and never installs #nixos.
#
# Modes:
#   (none)            interactive menu (the normal on-site entry)
#   --prepare         stage A: copy repo + import the read-only Ventoy cache
#   --network         stage B: direct network / local Mihomo checks
#   --check           stage C: read-only disk, ESP and backup-record checks
#   --install         stage D: interactive installation wizard
#   --status          show the real current state (read-only)
#   --cleanup         stop local Mihomo, remove runtime proxy, unmount ro mounts
#   --record-backup   Arch-side: archive ESP, verify on the mini host, write a
#                     non-sensitive offline verification record for Ventoy
#   --help            this help
#
# There is deliberately no --yes/--force and no unattended disk mode.

set -uo pipefail
ORIG_ARGS=("$@")
umask 022
export LC_ALL=C

SCRIPT_VERSION="2026-10-28.2"
SELF=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
REPO=${START_REPO:-/root/nixos-infra}
ARCH_HOME=/run/arch-home
BACKUP_HOST=${START_BACKUP_HOST:-calendar@10.77.77.2}
BACKUP_OUT=${START_BACKUP_OUT:-/var/tmp/esp-backup-record.txt}
MODE=menu
BUNDLE=${START_BUNDLE:-}
LIB_ONLY=${START_LIB_ONLY:-0}

# ---------------------------------------------------------------------------
# output, logging, state
# ---------------------------------------------------------------------------

STATE_DIR=${START_STATE_DIR:-/run/nixos-install}
LOG_DIR="$STATE_DIR/log"
LOG=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

say() { printf '%s\n' "$*"; [ -n "$LOG" ] && printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG"; }
ok()   { printf '%sPASS%s %s\n' "$C_GRN" "$C_OFF" "$*"; [ -n "$LOG" ] && printf 'PASS %s\n' "$*" >>"$LOG"; }
warn() { printf '%sWARN%s %s\n' "$C_YEL" "$C_OFF" "$*"; [ -n "$LOG" ] && printf 'WARN %s\n' "$*" >>"$LOG"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*"; [ -n "$LOG" ] && printf 'FAIL %s\n' "$*" >>"$LOG"; FAILS=$((FAILS + 1)); }
stop() { printf '%sSTOP%s %s\n' "$C_RED" "$C_OFF" "$*"; [ -n "$LOG" ] && printf 'STOP %s\n' "$*" >>"$LOG"; STOPS=$((STOPS + 1)); }
note() { printf 'NOTE %s\n' "$*"; [ -n "$LOG" ] && printf 'NOTE %s\n' "$*" >>"$LOG"; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

die() { printf '%sSTOP%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

WARNINGS=0; FAILS=0; STOPS=0
MIHOMO_STARTED_THIS_RUN=0
reset_counters() { WARNINGS=0; FAILS=0; STOPS=0; }

state_init() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$STATE_DIR/state" || die "无法创建 $STATE_DIR"
  chmod 700 "$STATE_DIR" "$LOG_DIR" "$STATE_DIR/state" 2>/dev/null || true
  if [ -z "$LOG" ]; then
    LOG="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"
    : >"$LOG"; chmod 600 "$LOG" 2>/dev/null || true
    ln -sfn "$LOG" "$LOG_DIR/latest.log" 2>/dev/null || true
  fi
}
sset() { printf '%s\n' "$2" >"$STATE_DIR/state/$1" 2>/dev/null || true; }
sget() { cat "$STATE_DIR/state/$1" 2>/dev/null || true; }
sdel() { rm -f "$STATE_DIR/state/$1" 2>/dev/null || true; }

stage_log() {
  LOG="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$1.log"
  : >"$LOG"; chmod 600 "$LOG" 2>/dev/null || true
  ln -sfn "$LOG" "$LOG_DIR/latest.log" 2>/dev/null || true
}

pause_enter() {
  local _x
  printf '\n按 Enter 返回菜单（不会执行任何操作）... '
  IFS= read -r _x || true
}

ask_yes() {
  local prompt=$1 answer
  printf '%s [y/N] ' "$prompt"
  IFS= read -r answer || return 1
  case "$answer" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

confirm_phrase() {
  local phrase=$1 description=$2 answer
  say ""
  say "即将执行: $description"
  say "如果确认继续，请输入下面的短语（区分大小写）："
  printf '  %s\n> ' "$phrase"
  IFS= read -r answer || { say "ABORT: 没有输入，已取消。"; return 1; }
  if [ "$answer" != "$phrase" ]; then
    say "ABORT: 输入不匹配，未执行该操作。"
    return 1
  fi
  log_confirm "$phrase"
  return 0
}

log_confirm() { [ -n "$LOG" ] && printf 'CONFIRMED %s\n' "$1" >>"$LOG"; }

run_logged() {
  local desc=$1; shift
  say "→ $desc"
  [ -n "$LOG" ] && printf 'CMD: %s\n' "$*" >>"$LOG"
  "$@" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  [ -n "$LOG" ] && printf 'RC(%s)=%s\n' "$desc" "$rc" >>"$LOG"
  return "$rc"
}

show_log_tail() {
  [ -n "$LOG" ] && [ -f "$LOG" ] || return 0
  say "最近日志 ($LOG)："
  tail -n 25 "$LOG" | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

elf_x86_64_header() {
  # Fallback for environments where `file` has no magic database. Reads the
  # ELF ident and e_machine directly: 64-bit little-endian x86-64 (0x3e).
  od -An -tx1 -w20 -N20 "$1" 2>/dev/null | awk '
    { if ($1=="7f" && $2=="45" && $3=="4c" && $4=="46" \
        && $5=="02" && $6=="01" && $19=="3e" && $20=="00") exit 0; exit 1 }
  '
}

mount_is_ro() {
  local opts
  opts=$(findmnt -rno OPTIONS -T "$1" 2>/dev/null) || return 1
  case ",$opts," in *,ro,*) return 0;; esac
  return 1
}

port_listening() {
  local port=$1
  if have ss; then
    ss -ltnH "sport = :$port" 2>/dev/null | grep . >/dev/null && return 0
  fi
  timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null
}

probe_url() {
  local url=$1 proxy=${2:-} code
  if [ -n "$proxy" ]; then
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 -x "$proxy" "$url" 2>/dev/null) || return 1
  else
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$url" 2>/dev/null) || return 1
  fi
  case "$code" in 2*|3*) return 0;; *) return 1;; esac
}

retry_probe() {
  # URL, proxy (may be empty), attempts. URL-test groups need a few seconds to
  # finish their first health check; do not declare a slow node dead on the
  # first packet.
  local url=$1 proxy=${2:-} tries=${3:-10} i
  for i in $(seq 1 "$tries"); do
    probe_url "$url" "$proxy" && return 0
    sleep 2
  done
  return 1
}

detect_iso() {
  ISO_ID=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | head -1)
  ISO_VER=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -1)
  ISO_PRETTY=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -1)
  LIVE=no
  case "$(findmnt -n -o FSTYPE / 2>/dev/null)" in overlay|tmpfs|squashfs) LIVE=yes;; esac
  [ "$(findmnt -n -o FSTYPE /nix/.ro-store 2>/dev/null)" = "squashfs" ] && LIVE=yes
  UEFI=no
  [ -d /sys/firmware/efi ] && UEFI=yes
}

refresh_devices() {
  PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
  VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)
  DISK=""; DISK_MODEL=""; DISK_SIZE_B=""; BTRFS_UUID=""; ESP_UUID=""; DISK_COUNT=0
  local disks
  disks=$(lsblk -dno NAME,TYPE,RM 2>/dev/null | awk '$2=="disk" && $3=="0" && $1 !~ /^(zram|loop|sr|ram)/ {print $1}')
  DISK_COUNT=$(printf '%s\n' "$disks" | sed '/^$/d' | wc -l)
  if [ "$DISK_COUNT" -eq 1 ]; then
    DISK=$disks
    DISK_MODEL=$(lsblk -dno MODEL "/dev/$DISK" 2>/dev/null | sed 's/^ *//;s/ *$//')
    DISK_SIZE_B=$(lsblk -bdno SIZE "/dev/$DISK" 2>/dev/null | tr -d ' ')
    BTRFS_UUID=$(lsblk -rno UUID,FSTYPE "/dev/$DISK" 2>/dev/null | awk '$2=="btrfs"{print $1}' | head -1)
    ESP_UUID=$(lsblk -rno UUID,FSTYPE "/dev/$DISK" 2>/dev/null | awk '$2=="vfat"{print $1}' | head -1)
    # The Live ISO normally has udev, but a minimal/rescue environment may not
    # populate lsblk's UUID/FSTYPE columns. Read the superblocks directly.
    if [ -z "$BTRFS_UUID" ] || [ -z "$ESP_UUID" ]; then
      local p t u
      for p in "/dev/${DISK}"p* "/dev/${DISK}"[0-9]*; do
        [ -b "$p" ] || continue
        t=$(blkid -s TYPE -o value "$p" 2>/dev/null)
        u=$(blkid -s UUID -o value "$p" 2>/dev/null)
        case "$t" in
          btrfs) [ -n "$BTRFS_UUID" ] || BTRFS_UUID=$u;;
          vfat)  [ -n "$ESP_UUID" ] || ESP_UUID=$u;;
        esac
      done
    fi
  fi
}

mount_top_ro() {
  mkdir -p "$STATE_DIR/btrfs-top"
  if findmnt -rn -M "$STATE_DIR/btrfs-top" >/dev/null 2>&1; then return 0; fi
  mount -o "subvolid=5,ro" "/dev/disk/by-uuid/$BTRFS_UUID" "$STATE_DIR/btrfs-top" 2>/dev/null || return 1
  CLEAN_TOP=1
  return 0
}

unmount_top() {
  if findmnt -rn -M "$STATE_DIR/btrfs-top" >/dev/null 2>&1; then
    umount "$STATE_DIR/btrfs-top" 2>/dev/null || return 1
  fi
  CLEAN_TOP=0
  return 0
}

subvol_present() {
  local name=$1 top=$STATE_DIR/btrfs-top
  btrfs subvolume list -a -p -t "$top" 2>/dev/null \
    | grep -E "(^|[[:space:]])${name}([[:space:]]|$)" >/dev/null
}

btrfs_default_id() {
  btrfs subvolume get-default "$STATE_DIR/btrfs-top" 2>/dev/null | awk 'NR==1{print $2}'
}

find_esp_mount() {
  local m dev
  dev=$(readlink -f "/dev/disk/by-uuid/$ESP_UUID" 2>/dev/null || true)
  m=""
  [ -n "$dev" ] && m=$(findmnt -n -o TARGET -S "$dev" 2>/dev/null | head -1)
  [ -n "$m" ] || m=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$ESP_UUID" 2>/dev/null | head -1)
  if [ -n "$m" ]; then
    ESP_PATH=$m; ESP_OWN_MOUNT=0
    if ! mount_is_ro "$m"; then
      note "ESP 已由系统以读写挂载在 $m；本阶段只读取哈希，不写入"
    fi
    return 0
  fi
  mkdir -p "$STATE_DIR/arch-esp"
  if mount -o ro "/dev/disk/by-uuid/$ESP_UUID" "$STATE_DIR/arch-esp" 2>/dev/null; then
    ESP_PATH="$STATE_DIR/arch-esp"; ESP_OWN_MOUNT=1; CLEAN_ESP=1
    return 0
  fi
  return 1
}

unmount_esp() {
  if [ "${ESP_OWN_MOUNT:-0}" = "1" ] && findmnt -rn -M "$STATE_DIR/arch-esp" >/dev/null 2>&1; then
    umount "$STATE_DIR/arch-esp" 2>/dev/null || return 1
  fi
  CLEAN_ESP=0
  return 0
}

key_esp_files() {
  printf '%s\n' \
    amd-ucode.img \
    vmlinuz-linux-lts \
    EFI/Linux/arch-linux-lts.efi \
    EFI/systemd/systemd-bootx64.efi \
    EFI/BOOT/BOOTX64.EFI \
    EFI/Lenovo/BIOS/SelfHealing.fd \
    loader/loader.conf
  if [ -d "$ESP_PATH/loader/credentials" ]; then
    find "$ESP_PATH/loader/credentials" -maxdepth 1 -type f -name 'nvpcr-anchor.*.cred' \
      -printf 'loader/credentials/%f\n' 2>/dev/null
  fi
}

esp_key_required() {
  case "$1" in
    amd-ucode.img|vmlinuz-linux-lts|EFI/Linux/arch-linux-lts.efi|\
    EFI/systemd/systemd-bootx64.efi|EFI/BOOT/BOOTX64.EFI|\
    EFI/Lenovo/BIOS/SelfHealing.fd|loader/loader.conf) return 0;;
    *) return 1;;
  esac
}

# ---------------------------------------------------------------------------
# Ventoy discovery (read-only)
# ---------------------------------------------------------------------------

CLEAN_VENTOY=0
VENTOY_MOUNT=""
VENTOY_ORIGINAL=""

cleanup_ventoy() {
  if [ "$CLEAN_VENTOY" = "1" ]; then
    umount "$STATE_DIR/ventoy" 2>/dev/null || true
    CLEAN_VENTOY=0
  fi
}

discover_bundle() {
  if [ -n "$BUNDLE" ]; then
    [ -d "$BUNDLE" ] || { stop "指定的 bundle 不存在: $BUNDLE"; return 1; }
    if ! mount_is_ro "$BUNDLE"; then
      warn "bundle 不是只读挂载（测试/高级用法）: $BUNDLE"
    fi
    validate_bundle || return 1
    return 0
  fi

  local dev="" src="" t

  # Reuse an existing read-only view from an earlier stage/menu action.
  if findmnt -rn -M "$STATE_DIR/ventoy" >/dev/null 2>&1; then
    if mount_is_ro "$STATE_DIR/ventoy"; then
      CLEAN_VENTOY=1
      VENTOY_MOUNT="$STATE_DIR/ventoy"
      BUNDLE="$VENTOY_MOUNT/nixos-install"
      say "Ventoy: $STATE_DIR/ventoy (ro, 已挂载)"
      validate_bundle
      return $?
    fi
    umount "$STATE_DIR/ventoy" 2>/dev/null || true
  fi

  if [ -e /dev/disk/by-label/Ventoy ]; then
    dev=$(readlink -f /dev/disk/by-label/Ventoy 2>/dev/null || true)
  fi
  if [ -n "$dev" ]; then
    src=$(findmnt -n -o TARGET -S "$dev" 2>/dev/null | head -1 || true)
  fi

  # Graphical ISO / udisks auto-mount: <mount>/nixos-install/START.sh
  if [ -z "$src" ]; then
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      if [ -f "$t/nixos-install/START.sh" ] || [ -f "$t/nixos-install/repo/flake.nix" ]; then
        src=$t; break
      fi
    done < <(findmnt -rn -o TARGET 2>/dev/null)
  fi

  mkdir -p "$STATE_DIR/ventoy"
  if [ -n "$src" ]; then
    VENTOY_ORIGINAL=$src
    if ! mount --bind "$src" "$STATE_DIR/ventoy" 2>/dev/null; then
      stop "无法把 $src 只读 bind 到 $STATE_DIR/ventoy"
      return 1
    fi
  elif [ -n "$dev" ]; then
    if ! mount -o ro "$dev" "$STATE_DIR/ventoy" 2>/dev/null; then
      stop "无法只读挂载 $dev"
      return 1
    fi
  else
    stop "找不到 Ventoy（没有 LABEL=Ventoy，也没有已挂载的 nixos-install/）"
    say "检查: lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS"
    say "如果 U 盘未挂载，先关闭文件管理器，再重试；不要格式化 U 盘。"
    return 1
  fi

  if ! mount -o remount,ro,bind "$STATE_DIR/ventoy" 2>/dev/null; then
    if ! mount_is_ro "$STATE_DIR/ventoy"; then
      umount "$STATE_DIR/ventoy" 2>/dev/null || true
      stop "Ventoy 视图不是只读；拒绝继续"
      return 1
    fi
  fi
  if ! mount_is_ro "$STATE_DIR/ventoy"; then
    umount "$STATE_DIR/ventoy" 2>/dev/null || true
    stop "Ventoy 视图不是只读；拒绝继续"
    return 1
  fi
  CLEAN_VENTOY=1
  VENTOY_MOUNT="$STATE_DIR/ventoy"
  BUNDLE="$VENTOY_MOUNT/nixos-install"
  say "Ventoy: $STATE_DIR/ventoy (ro)$( [ -n "$VENTOY_ORIGINAL" ] && printf ' ← %s' "$VENTOY_ORIGINAL" )"
  validate_bundle
}

validate_bundle() {
  local b=$BUNDLE
  [ -f "$b/START.sh" ] || { stop "缺少 $b/START.sh"; return 1; }
  [ -d "$b/repo" ] || { stop "缺少 $b/repo/"; return 1; }
  [ -d "$b/cache" ] || { stop "缺少 $b/cache/"; return 1; }
  [ -f "$b/repo/flake.nix" ] || { stop "repo 不是 nixos-infra 工作树"; return 1; }
  [ -f "$b/repo/hosts/nixos/hardware-configuration.nix" ] || {
    stop "repo 缺少 hosts/nixos/hardware-configuration.nix（#nixos 无法求值）"; return 1;
  }
  [ ! -e "$b/repo/secrets" ] || { stop "Ventoy repo 含 secrets；拒绝使用"; return 1; }
  [ ! -e "$b/repo/hosts/main/hardware-configuration.nix" ] || {
    stop "Ventoy repo 含 main hardware；这会覆盖现场生成的真实文件"; return 1;
  }
  ok "bundle 结构完整"
}

# ---------------------------------------------------------------------------
# stage A: repo + writable cache copy + offline verification
# ---------------------------------------------------------------------------

cache_structure() {
  local c=$BUNDLE/cache n nars
  [ -f "$c/nix-cache-info" ] || { bad "cache 缺 nix-cache-info"; return 1; }
  grep -q '^StoreDir: /nix/store' "$c/nix-cache-info" || { bad "cache StoreDir 不是 /nix/store"; return 1; }
  n=$(find "$c" -maxdepth 1 -type f -name '*.narinfo' | wc -l)
  nars=$(find "$c/nar" -type f -name '*.nar.xz' 2>/dev/null | wc -l)
  [ "$n" -ge 1 ] || { bad "cache 没有 narinfo"; return 1; }
  [ "$nars" -ge 1 ] || { bad "cache/nar 没有 nar.xz"; return 1; }
  local nf
  for nf in "$c"/*.narinfo; do
    [ -f "$nf" ] || continue
    grep -q '^StorePath: /nix/store/' "$nf" || { bad "损坏的 narinfo: ${nf##*/}"; return 1; }
    grep -q '^NarHash: sha256:' "$nf" || { bad "narinfo 缺 NarHash: ${nf##*/}"; return 1; }
  done
  CACHE_MB=$(du -sm "$c" 2>/dev/null | awk '{print $1}')
  [ -n "$CACHE_MB" ] && [ "$CACHE_MB" -ge 1 ] || { bad "无法读取 cache 大小"; return 1; }
  ok "cache 结构正常（${CACHE_MB} MiB，$n 个 narinfo）"
  return 0
}

cache_fingerprint() {
  local dir=$1
  (
    cd "$dir" || return 1
    find . -type f -printf '%P %s\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  ) 2>/dev/null | sha256sum | awk '{print $1}'
}

cache_store_paths() {
  local c=$BUNDLE/cache
  sed -n 's/^StorePath: //p' "$c"/*.narinfo 2>/dev/null | sed '/^$/d' | sort -u
}

nix_meta_ok() {
  nix --extra-experimental-features 'nix-command flakes' \
    flake metadata --offline "$REPO" >/dev/null 2>&1
}

cache_store_paths_valid() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    nix --extra-experimental-features 'nix-command flakes' path-info --offline "$p" >/dev/null 2>&1 || return 1
  done < <(cache_store_paths)
  return 0
}

check_space() {
  local avail_run avail_nix need_run need_nix
  avail_run=$(df -Pm "$STATE_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  avail_nix=$(df -Pm /nix/store 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "$avail_nix" ] || avail_nix=$(df -Pm /nix 2>/dev/null | awk 'NR==2{print $4}')
  need_run=$((CACHE_MB + 64))
  need_nix=$((CACHE_MB * 3 + 512))
  say "空间: $STATE_DIR 可用 ${avail_run:-?} MiB（需要 $need_run）；/nix/store 可用 ${avail_nix:-?} MiB（需要 $need_nix）"
  if [ -z "$avail_run" ] || [ "$avail_run" -lt "$need_run" ]; then
    stop "Live 临时目录空间不足；关闭程序或换一台内存更大的机器"
    return 1
  fi
  if [ -z "$avail_nix" ] || [ "$avail_nix" -lt "$need_nix" ]; then
    stop "Live /nix/store 空间不足（导入要解包约 400 MiB）；不要继续"
    return 1
  fi
  ok "临时空间足够"
  return 0
}

ensure_repo() {
  local src=$BUNDLE/repo prev
  if [ -e "$REPO" ] && [ ! -d "$REPO" ]; then
    stop "$REPO 存在但不是目录；先人工检查"
    return 1
  fi
  if [ -d "$REPO" ]; then
    if [ -f "$REPO/hosts/main/hardware-configuration.nix" ]; then
      ok "保留已有含 main hardware 的工作树（不复制 Ventoy 覆盖）"
    elif diff -rq --no-dereference --exclude=.git --exclude=result \
      --exclude='result-*' --exclude=secrets "$REPO" "$src" >/dev/null 2>&1; then
      ok "工作树与 Ventoy repo 一致"
    else
      prev="$REPO.previous.$(date +%Y%m%d-%H%M%S)"
      mv "$REPO" "$prev" || { stop "无法保留旧工作树 $REPO"; return 1; }
      cp -a "$src" "$REPO" || { stop "repo 复制失败"; return 1; }
      note "旧工作树（无 main hardware）已移到 $prev"
    fi
  else
    cp -a "$src" "$REPO" || { stop "repo 复制失败"; return 1; }
    ok "repo 已复制到 $REPO"
  fi

  [ ! -e "$REPO/secrets" ] || {
    stop "$REPO 含 secrets；不能用于持久配置/安装"
    return 1
  }
  if have git; then
    git -C "$REPO" init -q 2>/dev/null || true
    git -C "$REPO" add -A -- . ':!secrets' >/dev/null 2>&1 || true
    if ! git -C "$REPO" diff --cached --quiet 2>/dev/null; then
      git -C "$REPO" -c user.email=install@local -c user.name=install \
        commit -qm "local ISO prep" >/dev/null 2>&1 || true
    fi
  else
    warn "ISO 没有 git；Flake 将以 path: 方式求值（不阻止安装）"
  fi
  return 0
}

import_cache() {
  local src=$BUNDLE/cache fp tmp newfp rc fp_after
  fp=$(cache_fingerprint "$src")
  [ -n "$fp" ] || { stop "无法计算 cache 指纹"; return 1; }
  sset cache-source-fingerprint "$fp"

  if [ "$(sget cache-fingerprint)" = "$fp" ] && cache_store_paths_valid && nix_meta_ok; then
    ok "cache 已导入且离线 Flake 可求值（跳过重复导入）"
    sset prepare-pass yes
    return 0
  fi
  if nix_meta_ok && cache_store_paths_valid; then
    ok "离线 Flake 已可用（store 中已有全部输入）"
    sset cache-fingerprint "$fp"
    sset prepare-pass yes
    return 0
  fi

  check_space || return 1
  tmp=$(mktemp -d "$STATE_DIR/cache.XXXXXX") || { stop "无法创建可写 cache 副本"; return 1; }
  chmod 700 "$tmp"
  say "复制只读 cache → $tmp（Ventoy 不会被写入）"
  if ! ( cd "$src" && tar -cf - . ) | ( cd "$tmp" && tar -xpf - ); then
    stop "cache 复制失败；副本保留在 $tmp"
    return 1
  fi
  newfp=$(cache_fingerprint "$tmp")
  if [ "$newfp" != "$fp" ]; then
    stop "cache 副本指纹与源不一致；副本保留在 $tmp，未导入"
    return 1
  fi
  ok "cache 副本完整（源前后未变）"
  sset cache-dir "$tmp"

  say "从可写副本导入本地 store（这一步会在副本中创建 realisations，而不是在 Ventoy）"
  run_logged "nix copy --from file://$tmp --all" \
    nix --extra-experimental-features 'nix-command flakes' copy --from "file://$tmp" --all
  rc=$?
  if [ "$rc" -ne 0 ]; then
    stop "cache 导入失败（$rc）；副本和日志保留：$tmp"
    show_log_tail
    sset cache-failure "$(date -Iseconds) rc=$rc dir=$tmp"
    return 1
  fi
  if ! cache_store_paths_valid; then
    stop "导入后仍有 store path 无效；不要使用 --no-check-sigs 绕过"
    show_log_tail
    return 1
  fi
  run_logged "nix flake metadata --offline" \
    nix --extra-experimental-features 'nix-command flakes' flake metadata --offline "$REPO"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    stop "离线 Flake 求值失败：缓存不完整；副本保留在 $tmp"
    sset cache-failure "$(date -Iseconds) metadata dir=$tmp"
    return 1
  fi
  fp_after=$(cache_fingerprint "$src")
  if [ -z "$fp_after" ] || [ "$fp_after" != "$fp" ]; then
    stop "源 cache 在导入过程中发生变化；副本保留在 $tmp，未标记 A 阶段成功"
    sset cache-failure "$(date -Iseconds) source-changed dir=$tmp"
    return 1
  fi
  ok "源 cache 导入后仍与初始指纹一致（未被写入）"
  sset cache-fingerprint "$fp"
  sset cache-imported-at "$(date -Iseconds)"
  sset prepare-pass yes
  ok "A 阶段完成：cache 已导入，离线 Flake 已验证"
  return 0
}

stage_prepare() {
  stage_log prepare
  reset_counters
  hr; say "${C_BLD}A. 准备离线 Flake 缓存${C_OFF}"; hr
  detect_iso
  say "系统: ${ISO_PRETTY:-unknown} (ID=${ISO_ID:-?}, VERSION_ID=${ISO_VER:-?})"
  [ "$LIVE" = "yes" ] && ok "NixOS Live ISO" || warn "当前不是 Live ISO（只读演练环境）"
  discover_bundle || return 1
  ensure_repo || return 1
  cache_structure || return 1
  import_cache || return 1
  say ""
  if [ -n "$VENTOY_MOUNT" ]; then
    say "Ventoy 只读视图保留在 $VENTOY_MOUNT；源 cache 未修改。"
  else
    say "源 bundle: $BUNDLE（指定路径；未额外挂载 Ventoy）；源 cache 未修改。"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# stage B: network and local Mihomo
# ---------------------------------------------------------------------------

stop_mihomo() {
  local pid mdir
  pid=$(sget mihomo-pid)
  mdir=$(sget mihomo-dir)
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    if [ -n "$mdir" ] && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -F -- "$mdir/config.yaml" >/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      local i
      for i in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
      ok "本地 Mihomo 已停止"
    else
      warn "PID $pid 不是本助手启动的 Mihomo；不停止"
    fi
  fi
  sdel mihomo-pid
  sdel mihomo-dir
  sdel proxy-port
  sdel proxy-mode
  sdel proxy-ready
  sdel network-pass
  rm -f "$STATE_DIR/proxy.env" 2>/dev/null || true
  MIHOMO_STARTED_THIS_RUN=0
  # The binary, node profile and generated config are private runtime copies.
  # Remove them on cleanup/failure; logs do not contain the profile.
  case "$mdir" in
    "$STATE_DIR"/mihomo|/root/.nixos-install-mihomo)
      rm -rf -- "$mdir"
      ok "已删除 Mihomo 私有临时副本（二进制、profile、config）"
      ;;
    *)
      # State may have been lost (old version, interrupted run). Only remove a
      # directory that carries our marker; never remove an arbitrary path.
      local cand
      for cand in "$STATE_DIR/mihomo" /root/.nixos-install-mihomo; do
        if [ -f "$cand/.start-sh-private" ] || \
           { [ -f "$cand/config.yaml" ] && grep -q '^# generated by START.sh;' "$cand/config.yaml" 2>/dev/null; }; then
          rm -rf -- "$cand"
          ok "已删除遗留的 Mihomo 私有临时副本（$cand）"
        fi
      done
      ;;
  esac
  if [ -f /run/systemd/system/nix-daemon.service.d/10-nixos-install-proxy.conf ]; then
    rm -f /run/systemd/system/nix-daemon.service.d/10-nixos-install-proxy.conf
    if have systemctl; then
      systemctl daemon-reload 2>/dev/null || true
      systemctl try-restart nix-daemon.service 2>/dev/null || true
    fi
  fi
}

find_mihomo_binary() {
  local d=$1 c
  for c in "$d/mihomo-linux-amd64-compatible" "$d/mihomo" "$d/kit/mihomo"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

find_mihomo_profile() {
  local d=$1 c
  for c in "$d/kit/state/profile.yaml" "$d/state/profile.yaml" "$d/profile.yaml"; do
    [ -s "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

mihomo_source_config() {
  local d=$1 c
  for c in "$d/kit/config.yaml" "$d/config.yaml"; do
    [ -s "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

pick_port() {
  local want=$1 p
  for p in "$want" 17897 17898 17899 17900; do
    if ! port_listening "$p"; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}

start_mihomo_from_arch_home() {
  local bin profile cfg port src_port mdir uuid
  local arch_home="$ARCH_HOME/calendar/Downloads/mihomo"

  if [ ! -d "$arch_home" ]; then
    say "需要只读挂载 Arch 的 @home 才能读取 Mihomo。"
    say "当前 Btrfs 候选（不会自动选择第一个）："
    lsblk -rno NAME,FSTYPE,SIZE,MODEL 2>/dev/null \
      | awk '$2=="btrfs"{printf "  /dev/%s  %s  %s\n", $1, $3, $4}'
    printf '输入 Arch Btrfs 分区 UUID（不是设备名；q 取消）: '
    IFS= read -r uuid || return 1
    [ "$uuid" = "q" ] && return 1
    case "$uuid" in
      *[!0-9A-Fa-f-]*) stop "UUID 含非法字符"; return 1;;
    esac
    [ -b "/dev/disk/by-uuid/$uuid" ] || { stop "找不到 /dev/disk/by-uuid/$uuid"; return 1; }
    if [ "$(blkid -s TYPE -o value "/dev/disk/by-uuid/$uuid" 2>/dev/null)" != "btrfs" ]; then
      stop "该 UUID 不是 btrfs 分区"
      return 1
    fi
    if [ -n "${BTRFS_UUID:-}" ] && [ "$uuid" != "$BTRFS_UUID" ]; then
      warn "输入的 UUID 与内置盘 Btrfs UUID ($BTRFS_UUID) 不同"
      ask_yes "仍然只读挂载这个 UUID？" || return 1
    fi
    mkdir -p "$ARCH_HOME"
    chmod 700 "$ARCH_HOME" 2>/dev/null || true
    if ! mount -o "ro,subvol=@home" "/dev/disk/by-uuid/$uuid" "$ARCH_HOME"; then
      stop "只读挂载 Arch @home 失败"
      return 1
    fi
    CLEAN_ARCH_HOME=1
    ok "Arch @home 已只读挂载到 $ARCH_HOME"
  fi
  if ! mount_is_ro "$ARCH_HOME"; then
    stop "$ARCH_HOME 不是只读挂载；拒绝使用 Arch Home"
    return 1
  fi
  [ -d "$arch_home" ] || { stop "找不到 Arch 的 Mihomo 目录: $arch_home"; return 1; }
  bin=$(find_mihomo_binary "$arch_home") || { stop "Mihomo 目录没有可执行二进制"; return 1; }
  profile=$(find_mihomo_profile "$arch_home") || { stop "Mihomo 目录没有 profile.yaml/节点配置"; return 1; }
  cfg=$(mihomo_source_config "$arch_home") || true

  local ftype
  ftype=$(file -b "$bin" 2>/dev/null || true)
  say "Mihomo: $bin"
  [ -n "$ftype" ] && say "  $ftype"
  if printf '%s' "$ftype" | grep 'ELF.*64-bit.*x86-64' >/dev/null; then
    case "$ftype" in
      *static*) ok "x86-64 静态 ELF，可在 NixOS ISO 运行";;
      *) warn "x86-64 ELF 但不是静态链接；继续前会检查 ldd";;
    esac
  elif elf_x86_64_header "$bin"; then
    ok "ELF 头校验：64-bit little-endian x86-64"
    ftype="ELF 64-bit x86-64"
  else
    stop "Mihomo 不是 x86-64 ELF，不能用于 NixOS ISO"
    return 1
  fi
  if ! printf '%s' "$ftype" | grep 'static' >/dev/null; then
    local lddout
    lddout=$(ldd "$bin" 2>&1 || true)
    if printf '%s' "$lddout" | grep 'not found' >/dev/null; then
      stop "Mihomo 动态链接且缺少库；不继续"
      return 1
    fi
    if ! printf '%s' "$lddout" | grep 'not a dynamic executable' >/dev/null; then
      warn "无法确认 Mihomo 是否静态链接；ldd 输出已记录"
      printf '%s\n' "$lddout" >>"$LOG" 2>/dev/null || true
    fi
  fi
  local ver
  ver=$("$bin" -v 2>/dev/null | head -1 || true)
  say "版本: ${ver:-unknown}"

  src_port=7897
  if [ -n "$cfg" ]; then
    local p
    p=$(awk -F': *' '/^mixed-port:/{print $2; exit}' "$cfg")
    case "$p" in ''|*[!0-9]*) ;; *) [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] && src_port=$p;; esac
  fi
  port=$(pick_port "$src_port") || { stop "找不到空闲本地端口"; return 1; }
  [ "$port" != "$src_port" ] && note "端口 $src_port 被占用，改用 $port"

  umask 077
  mdir="$STATE_DIR/mihomo"
  mkdir -p "$mdir/state"
  chmod 700 "$STATE_DIR" "$mdir" "$mdir/state" 2>/dev/null || true
  : >"$mdir/.start-sh-private"; chmod 600 "$mdir/.start-sh-private" 2>/dev/null || true
  cp -- "$bin" "$mdir/mihomo" || { stop "复制 Mihomo 二进制失败"; return 1; }
  chmod 700 "$mdir/mihomo"
  cp -- "$profile" "$mdir/state/profile.yaml" || { stop "复制节点配置失败"; return 1; }
  chmod 600 "$mdir/state/profile.yaml"
  # Record the first copy immediately: even if the noexec fallback fails, the
  # private binary/profile must still be removable by cleanup.
  sset mihomo-dir "$mdir"

  # /run can be noexec on some media; fall back to the Live root overlay.
  if ! "$mdir/mihomo" -v >/dev/null 2>&1; then
    local first_mdir=$mdir
    note "$mdir 不能执行（noexec?）；改用 /root/.nixos-install-mihomo"
    mdir=/root/.nixos-install-mihomo
    mkdir -p "$mdir/state"
    chmod 700 "$mdir" "$mdir/state" 2>/dev/null || true
    : >"$mdir/.start-sh-private"; chmod 600 "$mdir/.start-sh-private" 2>/dev/null || true
    cp -- "$bin" "$mdir/mihomo" || { rm -rf -- "$first_mdir"; stop "复制 Mihomo 二进制失败"; return 1; }
    chmod 700 "$mdir/mihomo"
    cp -- "$profile" "$mdir/state/profile.yaml" || { rm -rf -- "$mdir" "$first_mdir"; stop "复制节点配置失败"; return 1; }
    chmod 600 "$mdir/state/profile.yaml"
    rm -rf -- "$first_mdir" 2>/dev/null || true
  fi

  # Record the final location (including the noexec fallback) before starting.
  sset mihomo-dir "$mdir"

  # The runtime copies are complete; Arch Home is no longer needed.
  if [ "${CLEAN_ARCH_HOME:-0}" = "1" ]; then
    if umount "$ARCH_HOME" 2>/dev/null; then
      CLEAN_ARCH_HOME=0
      ok "已卸载 Arch @home 只读挂载（使用私有临时副本）"
    else
      warn "Arch @home 卸载失败；只读挂载保留，稍后菜单 [7] 清理"
    fi
  fi

  # Safe temporary config: loopback only, no LAN, no TUN, no control API,
  # no system DNS takeover, no rule providers that need the internet.
  cat >"$mdir/config.yaml" <<EOF
# generated by START.sh; loopback only, no LAN/TUN/control API
mixed-port: $port
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: warning
ipv6: false
tun:
  enable: false
dns:
  enable: true
  ipv6: false
  enhanced-mode: redir-host
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
proxy-providers:
  airport:
    type: file
    path: ./profile.yaml
proxy-groups:
  - name: PROXY
    type: url-test
    use:
      - airport
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
rules:
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - DOMAIN-SUFFIX,local,DIRECT
  - MATCH,PROXY
EOF
  chmod 600 "$mdir/config.yaml"

  say "校验临时配置（不会启动 TUN、不会改系统 DNS/路由/防火墙）"
  if ! "$mdir/mihomo" -t -f "$mdir/config.yaml" -d "$mdir/state" >"$mdir/validate.log" 2>&1; then
    tail -n 20 "$mdir/validate.log" | sed 's/^/  /'
    stop "Mihomo 配置校验失败；未启动"
    return 1
  fi
  ok "Mihomo 配置校验通过"

  setsid "$mdir/mihomo" -f "$mdir/config.yaml" -d "$mdir/state" \
    >"$mdir/mihomo.log" 2>&1 < /dev/null &
  local pid=$!
  printf '%s\n' "$pid" >"$STATE_DIR/state/mihomo-pid"
  MIHOMO_STARTED_THIS_RUN=1

  local i
  for i in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -n 25 "$mdir/mihomo.log" | sed 's/^/  /'
      stop "Mihomo 启动失败"
      return 1
    fi
    port_listening "$port" && break
    sleep 0.25
  done
  if ! port_listening "$port"; then
    stop "Mihomo 没有在端口 $port 监听"
    return 1
  fi
  local addrs
  addrs=$(ss -ltnH "sport = :$port" 2>/dev/null | awk '{print $4}')
  if printf '%s\n' "$addrs" | grep -vE '^(127\.0\.0\.1|\[::1\]):' | grep . >/dev/null; then
    stop "Mihomo 监听了非回环地址；立即停止"
    stop_mihomo
    return 1
  fi
  ok "Mihomo 仅监听 127.0.0.1:$port"

  local p="http://127.0.0.1:$port"
  # The kit profile may be months old and its url-test group can pick a slow
  # node. Wait for a small 204 first, then use small endpoints (robots.txt,
  # nix-cache-info) instead of a full HTML page.
  if ! retry_probe "https://www.gstatic.com/generate_204" "$p" 12; then
    stop "经 Mihomo 无法完成最小连通性探测（节点可能已失效）"
    stop_mihomo
    return 1
  fi
  ok "经 Mihomo 最小连通性正常"
  if ! retry_probe "https://github.com/robots.txt" "$p" 10; then
    stop "经 Mihomo 访问 GitHub 失败"
    stop_mihomo
    return 1
  fi
  ok "经 Mihomo 访问 GitHub 成功"
  if retry_probe "https://cache.nixos.org/nix-cache-info" "$p" 5; then
    ok "经 Mihomo 访问 cache.nixos.org 成功"
  else
    warn "经 Mihomo 访问 cache.nixos.org 超时；TUNA 是首选 substituter，继续但会记录"
    note "若需 cache.nixos.org 也稳定，请先在 Arch 上更新 Mihomo 订阅（不要在 ISO 输入订阅 URL）"
  fi
  if ! retry_probe "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store/nix-cache-info" "$p" 10; then
    stop "经 Mihomo 访问 TUNA 失败"
    stop_mihomo
    return 1
  fi
  ok "经 Mihomo 访问 TUNA 成功"

  cat >"$STATE_DIR/proxy.env" <<EOF
export http_proxy=$p
export https_proxy=$p
export all_proxy=$p
export no_proxy=localhost,127.0.0.1,::1
EOF
  chmod 600 "$STATE_DIR/proxy.env"
  sset proxy-port "$port"
  sset proxy-mode mihomo
  sset proxy-ready yes

  # Real Nix download through the proxy (fetcher runs in this process).
  say "验证 Nix 经代理真实下载一个 store 中不存在的对象..."
  if ! run_logged "nix store prefetch-file (proxy)" \
      nix --extra-experimental-features 'nix-command flakes' store prefetch-file --json \
      --name nixos-install-netcheck \
      "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store/nix-cache-info"; then
    stop "Nix 经代理下载失败；代理方案不完整"
    stop_mihomo
    return 1
  fi
  ok "Nix 经代理下载成功"

  setup_daemon_proxy "$p"
  export http_proxy=$p https_proxy=$p all_proxy=$p no_proxy=localhost,127.0.0.1,::1
  return 0
}

setup_daemon_proxy() {
  local p=$1 dropin=/run/systemd/system/nix-daemon.service.d/10-nixos-install-proxy.conf pid
  if ! have systemctl || ! systemctl is-active --quiet nix-daemon.service 2>/dev/null; then
    note "nix-daemon 不是 systemd 服务（单用户模式）；当前 shell 的代理变量足够"
    return 0
  fi
  mkdir -p "$(dirname "$dropin")"
  cat >"$dropin" <<EOF
[Service]
Environment="http_proxy=$p"
Environment="https_proxy=$p"
Environment="all_proxy=$p"
Environment="no_proxy=localhost,127.0.0.1,::1"
EOF
  chmod 644 "$dropin"
  if ! systemctl daemon-reload 2>/dev/null || ! systemctl try-restart nix-daemon.service 2>/dev/null; then
    warn "无法重启 nix-daemon；D 阶段下载可能不走代理"
    return 1
  fi
  sleep 1
  pid=$(systemctl show -p MainPID --value nix-daemon.service 2>/dev/null || true)
  if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
    if tr '\0' '\n' <"/proc/$pid/environ" | grep '^http_proxy=' >/dev/null; then
      ok "nix-daemon（PID $pid）运行时环境已带代理"
    else
      warn "nix-daemon 环境里没有 http_proxy；继续前请检查"
      return 1
    fi
  fi
  return 0
}

source_proxy_if_ready() {
  if [ -f "$STATE_DIR/proxy.env" ]; then
    # shellcheck disable=SC1090
    . "$STATE_DIR/proxy.env"
    if [ -z "${http_proxy:-}" ] || [ -z "${https_proxy:-}" ]; then
      warn "代理环境文件不完整；不使用"
      unset http_proxy https_proxy all_proxy no_proxy
      return 1
    fi
    local p=${http_proxy#http://}
    p=${p%%:*}
    local port=${http_proxy##*:}
    if [ "$p" = "127.0.0.1" ] && port_listening "$port"; then
      return 0
    fi
    warn "代理环境存在但端口不监听；不使用死代理"
    unset http_proxy https_proxy all_proxy no_proxy
    return 1
  fi
  return 1
}

network_direct_ok() {
  # TUNA is the first configured substituter. cache.nixos.org and GitHub are
  # probed separately because they are often slow/throttled here; the flake
  # inputs are already cached, so they are not a hard requirement for install.
  probe_url "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store/nix-cache-info"
}

network_report() {
  DIRECT_OK=no
  say ""
  say "网络状态（只读）："
  if have nmcli; then
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | sed 's/^/  /'
  fi
  ip -brief address 2>/dev/null | sed 's/^/  /'
  ip route show default 2>/dev/null | sed 's/^/  /'
  if [ -f /etc/resolv.conf ]; then
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/  /'
  fi
  if network_direct_ok; then
    ok "直连 TUNA 可用（Nix 首选 substituter）"
    DIRECT_OK=yes
  else
    warn "直连 TUNA 不可用"
  fi
  probe_url "https://cache.nixos.org/nix-cache-info" \
    && note "直连 cache.nixos.org 可用" \
    || note "直连 cache.nixos.org 不可用/较慢（TUNA 仍是首选）"
  probe_url "https://github.com/robots.txt" \
    && note "直连 GitHub 可用" \
    || note "直连 GitHub 不可用（Flake 输入已离线缓存，不一定是阻塞）"
}

stage_network() {
  stage_log network
  reset_counters
  hr; say "${C_BLD}B. 安装网络 / 本地 Mihomo${C_OFF}"; hr
  detect_iso
  refresh_devices
  if source_proxy_if_ready; then
    if probe_url "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store/nix-cache-info" "$http_proxy"; then
      ok "已有可用代理 127.0.0.1:$(sget proxy-port)"
      sset network-pass yes
      return 0
    fi
    warn "已有代理端口在监听但 TUNA 不可达；停止旧代理并重新选择网络"
    stop_mihomo
  fi

  local choice direct
  while :; do
    network_report
    direct=$DIRECT_OK
    say ""
    say "小主机不是必需网络。优先顺序：ISO 本机 Wi-Fi → 本机 Mihomo → 手机 USB 共享 → 小主机 SSH 备用。"
    cat <<'EOF'
[1] 我已在图形界面连接 Wi-Fi / 手机 USB 共享，重新检查
[2] 从 Arch @home 启动本地 Mihomo（只读挂载，私有临时副本）
[3] 查看连接指引
[0] 返回菜单
EOF
    printf '选择: '
    IFS= read -r choice || return 1
    case "$choice" in
      1)
        if network_direct_ok; then
          sset network-mode direct; sset network-pass yes
          ok "网络直连可用（不依赖小主机）"
          return 0
        fi
        warn "仍无法访问 TUNA/cache.nixos.org；请检查 Wi-Fi 是否真的连上"
        ;;
      2)
        start_mihomo_from_arch_home || { sset network-pass no; show_log_tail; return 1; }
        sset network-pass yes
        ok "B 阶段完成：本地 Mihomo 可用"
        return 0
        ;;
      3)
        cat <<'EOF'

Wi-Fi：Graphical ISO 右上角网络菜单选择 SSID；密码只在图形界面输入。
USB 共享：手机开启“USB 网络共享”，ISO 会自动出现 usb*/enp* 接口。
不要为了直连网线修改 Arch 或小主机的持久 NetworkManager 设置。
本脚本不会创建/修改任何 NetworkManager profile，也不会关闭防火墙。
EOF
        ;;
      0) return 1;;
      *) warn "无效选择";;
    esac
  done
}

# ---------------------------------------------------------------------------
# stage C: read-only checks + offline backup record
# ---------------------------------------------------------------------------

record_get() { grep -m1 "^$1=" "$REC_FILE" 2>/dev/null | cut -d= -f2-; }

record_check() {
  local rec="$BUNDLE/esp-backup-record.txt"
  local f field v rel cur missing=0 required
  REC_FILE=$rec
  say ""
  say "== ESP 备份离线验证记录 =="
  if [ ! -f "$rec" ]; then
    stop "Ventoy 缺少 esp-backup-record.txt"
    say "  补救（在小主机可达时，于 Arch 上执行）："
    say "    sudo ./START.sh --record-backup"
    say "    然后只把 /var/tmp/esp-backup-record.txt 复制到 Ventoy/nixos-install/"
    say "  不要只因为小主机网络不通就跳过备份检查。"
    return 1
  fi
  if [ "$(record_get format)" != "nixos-infra-esp-backup-record-v1" ]; then
    stop "记录格式未知或损坏: ${rec}"
    return 1
  fi
  for field in generated_at host_product esp_uuid archive_name archive_sha256 \
    archive_location archive_created_at archive_verified_at archive_verified_by \
    archive_verified_result restic_password_offline_copy; do
    v=$(record_get "$field")
    [ -n "$v" ] || { bad "记录缺少字段: $field"; missing=1; }
  done
  [ "$missing" = "0" ] || return 1
  if [ "$(record_get archive_verified_result)" != "OK" ]; then
    stop "记录中的 mini 校验结果不是 OK"
    return 1
  fi
  if ! printf '%s' "$(record_get archive_sha256)" | grep -E '^[0-9a-f]{64}$' >/dev/null; then
    stop "记录中的 archive_sha256 不是 64 位小写十六进制"
    return 1
  fi
  if [ "$(record_get host_product)" != "$PRODUCT" ]; then
    stop "记录的机器 ($(record_get host_product)) 与当前 ($PRODUCT) 不符"
    return 1
  fi
  if [ "$(printf '%s' "$(record_get esp_uuid)" | tr 'a-f' 'A-F')" != "$(printf '%s' "$ESP_UUID" | tr 'a-f' 'A-F')" ]; then
    stop "记录的 ESP UUID 与当前 ESP 不符"
    return 1
  fi

  for required in EFI/Linux/arch-linux-lts.efi vmlinuz-linux-lts loader/loader.conf \
    EFI/systemd/systemd-bootx64.efi EFI/BOOT/BOOTX64.EFI EFI/Lenovo/BIOS/SelfHealing.fd; do
    [ -n "$(record_get "file.$required")" ] || { bad "记录缺少关键文件哈希: $required"; missing=1; }
  done
  [ "$missing" = "0" ] || return 1

  while IFS= read -r line; do
    case "$line" in file.*) ;; *) continue;; esac
    rel=${line#file.}
    v=${rel#*=}
    rel=${rel%%=*}
    case "$rel" in /*|*..*)
      bad "记录包含非法文件路径: $rel"
      missing=1
      continue;;
    esac
    if [ ! -f "$ESP_PATH/$rel" ]; then
      bad "ESP 上已不存在记录中的文件: $rel"
      missing=1
      continue
    fi
    cur=$(sha256sum "$ESP_PATH/$rel" 2>/dev/null | awk '{print $1}')
    if [ "$cur" != "$v" ]; then
      bad "ESP 文件与备份记录不一致: $rel"
      say "     记录 ${v:0:16}... / 当前 ${cur:0:16}..."
      local mt
      mt=$(stat -c '%y' "$ESP_PATH/$rel" 2>/dev/null || true)
      say "     当前 mtime: ${mt:-unknown}"
      missing=1
    fi
  done < <(grep '^file\.' "$rec")
  if [ "$missing" != "0" ]; then
    stop "当前 ESP 与上次备份记录不一致：ESP 在备份后发生变化"
    say "  这表示上次 ESP 备份没有覆盖当前 Arch UKI/内核；必须重新备份并重新生成记录。"
    say "  不要用旧记录继续安装，也不要把 Ventoy 改成可写。"
    return 1
  fi

  ok "当前 ESP 关键文件与离线备份记录完全一致"
  say "  记录生成: $(record_get generated_at)"
  say "  归档: $(record_get archive_name)"
  say "  SHA256: $(record_get archive_sha256)"
  say "  位置: $(record_get archive_location)"
  say "  上次 mini 校验: $(record_get archive_verified_at)（$(record_get archive_verified_by)）"
  say "  依据：之前的离线备份验证记录，不是本次实时 SSH 校验。"
  say "  备份之后若发生 ESP 变化，上面的哈希比对会 STOP。"

  say ""
  say "请人工确认：Restic 仓库密码的独立恢复副本现在可用（不在本机、不依赖小主机）。"
  if ! ask_yes "确认可用？"; then
    stop "用户未确认 Restic 密码独立恢复副本；安装阻塞"
    return 1
  fi
  sset record-verified yes
  sset record-archive "$(record_get archive_name)"
  sset record-archive-sha "$(record_get archive_sha256)"
  return 0
}

stage_check() {
  stage_log check
  reset_counters
  hr; say "${C_BLD}C. 只读磁盘 / ESP / 备份检查${C_OFF}"; hr
  detect_iso
  refresh_devices
  discover_bundle || { bad "无法读取 Ventoy 上的备份记录"; return 1; }

  say "机器: ${VENDOR} / ${PRODUCT}"
  say "内置盘: ${DISK:-none} ${DISK_MODEL:-} ${DISK_SIZE_B:-}"
  say "Btrfs UUID: ${BTRFS_UUID:-none}  ESP UUID: ${ESP_UUID:-none}"

  [ "$UEFI" = "yes" ] && ok "UEFI 启动" || bad "不是 UEFI 启动；不要继续"
  if [ "$PRODUCT" = "21LG" ]; then
    ok "记录的主力机 LENOVO 21LG"
  elif [ "$PRODUCT" = "ITX-FP5" ]; then
    bad "这是 NixOS 小主机（ITX-FP5），不是 Arch 主力机"
  else
    bad "机器 $PRODUCT 不是记录的 LENOVO 21LG"
  fi
  if [ "$DISK_COUNT" -ne 1 ]; then
    bad "内置盘不是恰好一个（找到 $DISK_COUNT）；不要把 Ventoy/移动盘当目标"
  else
    ok "内置盘唯一: /dev/$DISK"
  fi
  case "${DISK_MODEL:-}" in
    *UMIS*) ok "内置盘是 UMIS NVMe";;
    "") bad "无法读取内置盘型号";;
    *) bad "内置盘型号不是 UMIS: $DISK_MODEL";;
  esac
  if [ -n "${DISK_SIZE_B:-}" ] && [ "$DISK_SIZE_B" -ge 950000000000 ] && [ "$DISK_SIZE_B" -le 1100000000000 ]; then
    ok "内置盘容量约 953.9G"
  else
    bad "内置盘容量异常: ${DISK_SIZE_B:-unknown} bytes"
  fi
  [ -n "$BTRFS_UUID" ] && ok "Btrfs UUID 唯一: $BTRFS_UUID" || bad "找不到唯一 Btrfs 分区"
  [ -n "$ESP_UUID" ] && ok "ESP UUID: $ESP_UUID" || bad "找不到 vfat ESP"
  [ "$FAILS" -eq 0 ] || { show_log_tail; return 1; }

  if ! findmnt -rn -M /mnt >/dev/null 2>&1; then
    ok "/mnt 没有遗留挂载"
  else
    warn "/mnt 已有挂载（可能是重复运行/部分安装）；不自动卸载，只验证布局"
    findmnt -R /mnt | sed 's/^/  /'
    if verify_target_mounts; then
      sset partial-install yes
    else
      bad "/mnt 已有挂载但布局不符合目标；不要覆盖"
    fi
  fi

  say ""
  say "== Btrfs 子卷（只读顶层挂载）=="
  if ! mount_top_ro; then
    bad "Btrfs 顶层只读挂载失败"
    return 1
  fi
  btrfs subvolume list -a -p -t "$STATE_DIR/btrfs-top" 2>/dev/null \
    | grep -v '\.snapshots/' | sed -n '1,40p' | sed 's/^/  /'
  note "（只显示前 40 个非快照子卷；Snapper 快照不显示、不修改）"
  local s
  for s in @ @home @log @pkg; do
    subvol_present "$s" && ok "Arch 子卷 $s 存在" || bad "缺少 Arch 子卷 $s"
  done
  local def
  def=$(btrfs_default_id)
  if [ "$def" = "5" ]; then ok "Btrfs 默认子卷仍是 ID 5"; else bad "Btrfs 默认子卷不是 5（$def）"; fi
  local free_mb
  free_mb=$(df -Pm "$STATE_DIR/btrfs-top" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$free_mb" ] && [ "$free_mb" -ge 102400 ]; then
    ok "Btrfs 可用空间 ${free_mb} MiB（≥100 GiB）"
  else
    bad "Btrfs 可用空间不足 100 GiB（${free_mb:-unknown} MiB）"
  fi
  local nixos_count=0
  for s in @nixos @nixos-home @nixos-nix; do
    if subvol_present "$s"; then
      nixos_count=$((nixos_count + 1))
    fi
  done
  if [ "$nixos_count" -eq 3 ]; then
    warn "已有完整 @nixos/@nixos-home/@nixos-nix：现场有上次安装状态，需要检查"
    sset partial-install yes
    note "D 阶段会再次要求输入 CONTINUE-PARTIAL；不会删除或重建已有子卷"
  elif [ "$nixos_count" -gt 0 ]; then
    stop "只存在 $nixos_count/3 个 @nixos* 子卷：部分安装，保留现场并人工检查"
    sset partial-install yes
  fi
  unmount_top || warn "Btrfs 顶层卸载失败（只读挂载，可稍后处理）"

  say ""
  say "== Arch ESP（只读）=="
  if ! find_esp_mount; then
    bad "ESP 只读挂载失败"
    return 1
  fi
  say "ESP: $ESP_PATH"
  if [ -f "$ESP_PATH/EFI/Linux/arch-linux-lts.efi" ]; then
    ok "Arch UKI 存在"
    sha256sum "$ESP_PATH/EFI/Linux/arch-linux-lts.efi" | awk '{print $1}' >"$STATE_DIR/state/arch-uki-before"
    sset arch-uki-before "$(cat "$STATE_DIR/state/arch-uki-before")"
  else
    bad "缺少 Arch UKI"
  fi
  if [ -f "$ESP_PATH/EFI/Lenovo/BIOS/SelfHealing.fd" ]; then
    ok "Lenovo SelfHealing.fd 存在"
  else
    bad "缺少 Lenovo SelfHealing.fd；/mnt/boot 可能不是原 ESP"
  fi
  local esp_free
  esp_free=$(df -Pm "$ESP_PATH" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$esp_free" ] && [ "$esp_free" -ge 300 ]; then
    ok "ESP 可用 ${esp_free} MiB（≥300）"
  else
    bad "ESP 可用空间不足 300 MiB（${esp_free:-unknown}）"
  fi
  if have efibootmgr; then
    if efibootmgr >/dev/null 2>&1; then
      efibootmgr | sed -n 's/^BootOrder: //p' >"$STATE_DIR/state/efi-bootorder-before"
      sset efi-bootorder-before "$(cat "$STATE_DIR/state/efi-bootorder-before")"
      ok "已记录 EFI BootOrder: $(cat "$STATE_DIR/state/efi-bootorder-before")"
    else
      bad "efibootmgr 读取失败（efivarfs 不可用）"
    fi
  else
    bad "没有 efibootmgr；无法验证 NVRAM 不变"
  fi

  sset btrfs-uuid "$BTRFS_UUID"
  sset esp-uuid "$ESP_UUID"
  sset internal-disk "$DISK"

  say ""
  say "== install-preflight.sh（只读）=="
  if [ ! -f "$REPO/install-preflight.sh" ]; then
    bad "缺少 $REPO/install-preflight.sh"
  else
    local pf_rc=0
    bash "$REPO/install-preflight.sh" 2>&1 | tee -a "$LOG" | sed 's/^/  /'
    pf_rc=${PIPESTATUS[0]}
    case "$pf_rc" in
      0) ok "preflight PASS";;
      10)
        if [ -f "$REPO/hosts/main/hardware-configuration.nix" ]; then
          bad "preflight 返回 10，但 main hardware 已存在"
        else
          ok "preflight 预期：MAIN HARDWARE NOT GENERATED（D4 现场生成）"
        fi
        ;;
      2) bad "preflight 用法错误/目标被拒绝（返回 2）";;
      *) bad "preflight 返回 $pf_rc；见上面的 FAIL 行";;
    esac
  fi

  # The offline flake must be evaluable before phase D.
  if nix_meta_ok; then
    ok "离线 Flake 可求值"
  else
    stop "离线 Flake 不可求值：先执行菜单 [1] 准备缓存"
  fi

  if [ ! -f "$REPO/hosts/nixos/hardware-configuration.nix" ]; then
    bad "缺少 mini hardware；#nixos 无法求值"
  fi

  record_check || true
  unmount_esp || warn "ESP 只读挂载卸载失败（只读，无写入）"

  say ""
  if [ "$FAILS" -eq 0 ] && [ "$STOPS" -eq 0 ]; then
    sset check-pass yes
    sset check-at "$(date -Iseconds)"
    ok "C 阶段 PASS：所有只读安全检查通过；安装尚未授权"
    return 0
  fi
  sset check-pass no
  say "C 阶段未通过：FAIL=$FAILS STOP=$STOPS"
  say "根据上面的 STOP/FAIL 修复；不要重启、不要清理现场。"
  return 1
}

# ---------------------------------------------------------------------------
# stage D: interactive installation
# ---------------------------------------------------------------------------

verify_target_mounts() {
  local mnt_home mnt_nix mnt_boot
  findmnt -rn -M /mnt >/dev/null 2>&1 || { stop "/mnt 未挂载"; return 1; }
  if ! findmnt -M /mnt -o OPTIONS -n 2>/dev/null | grep -E 'subvol=/?@nixos([,[:space:]]|$)' >/dev/null; then
    stop "/mnt 不是 subvol=@nixos"; return 1
  fi
  if ! findmnt -M /mnt/home -o OPTIONS -n 2>/dev/null | grep -E 'subvol=/?@nixos-home([,[:space:]]|$)' >/dev/null; then
    stop "/mnt/home 不是 subvol=@nixos-home"; return 1
  fi
  if ! findmnt -M /mnt/nix -o OPTIONS -n 2>/dev/null | grep -E 'subvol=/?@nixos-nix([,[:space:]]|$)' >/dev/null; then
    stop "/mnt/nix 不是 subvol=@nixos-nix"; return 1
  fi
  mnt_boot=$(findmnt -M /mnt/boot -o UUID -n 2>/dev/null | head -1)
  if [ "$mnt_boot" != "$ESP_UUID" ]; then
    stop "/mnt/boot UUID 不是原 ESP UUID"; return 1
  fi
  if [ "$(findmnt -M /mnt/boot -o FSTYPE -n 2>/dev/null)" != "vfat" ]; then
    stop "/mnt/boot 不是 vfat"; return 1
  fi
  if [ ! -f /mnt/boot/EFI/Linux/arch-linux-lts.efi ]; then
    stop "/mnt/boot 没有 Arch UKI（不是原 ESP）"; return 1
  fi
  local extra
  extra=$(findmnt -R /mnt -n -o TARGET 2>/dev/null | grep -vE '^/mnt(/home|/nix|/boot)?$' || true)
  if [ -n "$extra" ]; then
    stop "/mnt 下有额外挂载: $(printf '%s' "$extra" | tr '\n' ' ')"
    return 1
  fi
  ok "/mnt、/mnt/home、/mnt/nix、/mnt/boot 布局正确"
  return 0
}

main_hardware_checks() {
  local hw=$1
  [ -s "$hw" ] || { stop "hardware 文件为空: $hw"; return 1; }
  grep -Eq 'subvol=/?@nixos(["[:space:],]|$)' "$hw" || { stop "hardware 根不是 @nixos"; return 1; }
  grep -Eq 'subvol=/?@nixos-home(["[:space:],]|$)' "$hw" || { stop "hardware home 不是 @nixos-home"; return 1; }
  grep -Eq 'subvol=/?@nixos-nix(["[:space:],]|$)' "$hw" || { stop "hardware nix 不是 @nixos-nix"; return 1; }
  grep -q 'fsType = "vfat"' "$hw" || { stop "hardware /boot 不是 vfat"; return 1; }
  grep -q "$BTRFS_UUID" "$hw" || { stop "hardware 缺 Btrfs UUID"; return 1; }
  grep -q "$ESP_UUID" "$hw" || { stop "hardware 缺 ESP UUID"; return 1; }
  if [ -f "$REPO/hosts/nixos/hardware-configuration.nix" ] && cmp -s "$hw" "$REPO/hosts/nixos/hardware-configuration.nix"; then
    stop "main hardware 与 mini hardware 完全相同（复制错误）"; return 1
  fi
  ok "main hardware 内容符合 @nixos/@nixos-home/@nixos-nix + vfat /boot"
  return 0
}

install_partial_state() {
  local p=no
  if mount_top_ro; then
    local s
    for s in @nixos @nixos-home @nixos-nix; do
      subvol_present "$s" && p=yes
    done
    unmount_top || true
  fi
  findmnt -rn -M /mnt >/dev/null 2>&1 && p=yes
  [ -f "$REPO/hosts/main/hardware-configuration.nix" ] && p=yes
  [ -d /mnt/etc/nixos ] && p=yes
  printf '%s\n' "$p"
}

installation_guard() {
  local partial
  if [ "$(sget check-pass)" != "yes" ]; then
    stop "C 阶段尚未 PASS；先执行菜单 [3] 并修复所有 STOP/FAIL"
    return 1
  fi
  if [ "$(sget record-verified)" != "yes" ]; then
    stop "备份记录尚未验证；重新执行菜单 [3]"
    return 1
  fi
  partial=$(install_partial_state)
  if [ "$partial" = "yes" ]; then
    warn "检测到已有现场状态（子卷/@mnt/配置之一）；不会删除或重建"
    say "这是重复运行或部分安装。先查看菜单 [5]，必要时按 docs/ARCH_DUAL_BOOT.md 15.8 检查。"
    confirm_phrase "CONTINUE-PARTIAL" "在已有现场状态上继续（不删除任何现有数据）" || return 1
  fi
  return 0
}

d2_subvolumes() {
  local top="$STATE_DIR/btrfs-top-rw" s def_before
  say ""
  say "== D2 创建三个 NixOS 子卷（写磁盘，需独立授权）=="
  say "目标: /dev/disk/by-uuid/$BTRFS_UUID（只创建 @nixos、@nixos-home、@nixos-nix）"
  say "绝不删除 @、@home、@log、@pkg；绝不改默认子卷；绝不格式化。"
  mkdir -p "$top"
  if findmnt -rn -M "$top" >/dev/null 2>&1; then
    umount "$top" 2>/dev/null || { stop "临时顶层挂载 $top 仍在使用；不要强制卸载"; return 1; }
    note "已清理上次中断留下的临时顶层挂载 $top"
  fi
  mount -o subvolid=5 "/dev/disk/by-uuid/$BTRFS_UUID" "$top" || { stop "Btrfs 顶层挂载失败"; return 1; }
  def_before=$(btrfs subvolume get-default "$top" 2>/dev/null | awk 'NR==1{print $2}')
  local count=0
  for s in @nixos @nixos-home @nixos-nix; do
    [ -e "$top/$s" ] && count=$((count + 1))
  done
  if [ "$count" -eq 3 ]; then
    warn "三个 @nixos* 子卷已存在：跳过创建，只验证（不删除、不重建）"
    if [ "$def_before" != "5" ]; then
      stop "默认子卷不是 5（$def_before）；停止"
      umount "$top"; return 1
    fi
    for s in @nixos @nixos-home @nixos-nix; do
      btrfs subvolume list -a -p -t "$top" | grep -E "(^|[[:space:]])${s}([[:space:]]|$)" >/dev/null || {
        stop "找不到已有子卷 $s"; umount "$top"; return 1;
      }
    done
    umount "$top" || { stop "顶层卸载失败"; return 1; }
    ok "已有三个 NixOS 子卷；默认子卷仍为 5"
    return 0
  fi
  if [ "$count" -gt 0 ]; then
    stop "只存在 $count/3 个 @nixos* 子卷：部分创建现场，不能自动补齐"
    say "请保留现场并按 docs/ARCH_DUAL_BOOT.md 15.8 人工检查。"
    umount "$top"; return 1
  fi
  if [ "$def_before" != "5" ]; then
    stop "默认子卷不是 5（$def_before）；停止"
    umount "$top"; return 1
  fi
  if ! confirm_phrase "CREATE-SUBVOLS" "在 $BTRFS_UUID 上创建三个 NixOS 子卷"; then
    umount "$top"; return 1
  fi
  for s in @nixos @nixos-home @nixos-nix; do
    btrfs subvolume create "$top/$s" || { stop "$s 创建失败"; umount "$top"; return 1; }
  done
  def_after=$(btrfs subvolume get-default "$top" 2>/dev/null | awk 'NR==1{print $2}')
  if [ "$def_before" != "5" ] || [ "$def_after" != "5" ]; then
    stop "默认子卷变化（$def_before -> $def_after）；保留现场，停止"
    umount "$top"; return 1
  fi
  for s in @nixos @nixos-home @nixos-nix; do
    btrfs subvolume list -a -p -t "$top" | grep -E "(^|[[:space:]])${s}([[:space:]]|$)" >/dev/null || {
      stop "创建后找不到 $s"; umount "$top"; return 1;
    }
  done
  umount "$top" || { stop "顶层卸载失败"; return 1; }
  ok "三个 NixOS 子卷已创建；默认子卷仍为 5"
  return 0
}

d3_mount_target() {
  say ""
  say "== D3 挂载安装目标（写挂载，需独立授权）=="
  if findmnt -rn -M /mnt >/dev/null 2>&1; then
    warn "/mnt 已挂载；只验证，不卸载、不重挂"
    verify_target_mounts || return 1
    return 0
  fi
  if [ -n "$(ls -A /mnt 2>/dev/null)" ]; then
    stop "/mnt 非空；不要覆盖，先人工处理"
    return 1
  fi
  say "将执行（不会 mkfs）："
  cat <<EOF
  mount -o subvol=@nixos,compress=zstd:3,ssd,discard=async,space_cache=v2 /dev/disk/by-uuid/$BTRFS_UUID /mnt
  mkdir -p /mnt/home /mnt/nix /mnt/boot
  mount -o subvol=@nixos-home,... /dev/disk/by-uuid/$BTRFS_UUID /mnt/home
  mount -o subvol=@nixos-nix,...  /dev/disk/by-uuid/$BTRFS_UUID /mnt/nix
  mount -o fmask=0077,dmask=0077 /dev/disk/by-uuid/$ESP_UUID /mnt/boot
EOF
  confirm_phrase "MOUNT-TARGET" "把 @nixos/@nixos-home/@nixos-nix 和原 ESP 挂到 /mnt" || return 1
  mount -o "subvol=@nixos,compress=zstd:3,ssd,discard=async,space_cache=v2" \
    "/dev/disk/by-uuid/$BTRFS_UUID" /mnt || { stop "/mnt 挂载失败"; return 1; }
  if [ -n "$(ls -A /mnt 2>/dev/null)" ]; then
    stop "@nixos 非空；停止，不覆盖"
    return 1
  fi
  mkdir -p /mnt/home /mnt/nix /mnt/boot || { stop "创建挂载点失败"; return 1; }
  mount -o "subvol=@nixos-home,compress=zstd:3,ssd,discard=async,space_cache=v2" \
    "/dev/disk/by-uuid/$BTRFS_UUID" /mnt/home || { stop "/mnt/home 挂载失败"; return 1; }
  mount -o "subvol=@nixos-nix,compress=zstd:3,ssd,discard=async,space_cache=v2" \
    "/dev/disk/by-uuid/$BTRFS_UUID" /mnt/nix || { stop "/mnt/nix 挂载失败"; return 1; }
  mount -o fmask=0077,dmask=0077 "/dev/disk/by-uuid/$ESP_UUID" /mnt/boot || { stop "/mnt/boot 挂载失败"; return 1; }
  verify_target_mounts || return 1
  return 0
}

d4_hardware() {
  local hw="$REPO/hosts/main/hardware-configuration.nix" cand=/mnt/etc/nixos/hardware-configuration.nix
  say ""
  say "== D4 现场生成 main hardware =="
  if [ -f "$hw" ]; then
    ok "已有 main hardware；保留，不重新生成、不覆盖"
    main_hardware_checks "$hw" || return 1
    if have git && ! git -C "$REPO" ls-files --error-unmatch hosts/main/hardware-configuration.nix >/dev/null 2>&1; then
      git -C "$REPO" add hosts/main/hardware-configuration.nix >/dev/null 2>&1 || {
        stop "main hardware 无法加入 git index"; return 1; }
      git -C "$REPO" -c user.email=install@local -c user.name=install \
        commit -qm "add generated main hardware" >/dev/null 2>&1 || true
    fi
    return 0
  fi
  if [ -f "$cand" ]; then
    warn "已存在 $cand（可能来自上次部分安装）；先验证并复用，不重新生成"
    main_hardware_checks "$cand" || return 1
  else
    say "将执行: nixos-generate-config --root /mnt"
    say "完成后检查 /mnt/etc/nixos/hardware-configuration.nix 的 UUID 和子卷。"
    confirm_phrase "GENERATE-HARDWARE" "在 /mnt 生成 main hardware（写目标盘）" || return 1
    run_logged "nixos-generate-config --root /mnt" nixos-generate-config --root /mnt || {
      stop "nixos-generate-config 失败"; return 1; }
    [ -f "$cand" ] || { stop "没有生成 $cand"; return 1; }
    main_hardware_checks "$cand" || return 1
  fi
  cp "$cand" "$hw" || { stop "复制 hardware 到 repo 失败"; return 1; }
  if have git; then
    git -C "$REPO" add hosts/main/hardware-configuration.nix >/dev/null 2>&1 || {
      stop "main hardware 无法加入 git index"; return 1; }
    git -C "$REPO" -c user.email=install@local -c user.name=install \
      commit -qm "add generated main hardware" >/dev/null 2>&1 || true
  fi
  ok "main hardware 已保存到 $hw（本地 Git，未 push）"
  return 0
}

copy_repo_to_target() {
  local target=/mnt/etc/nixos stamp only_generated=0 skip_replace=0 leftover
  # Refuse before writing anything if the work tree contains runtime/private
  # material. The tar excludes .git/result/secrets, but these names are not
  # valid repo content and must never reach the target.
  if find "$REPO" -maxdepth 2 \( -name mihomo -o -name 'proxy.env' -o -name 'arch-home' \) | grep . >/dev/null; then
    stop "工作树包含运行时/Arch Home 内容（$REPO）；拒绝写入目标"
    return 1
  fi
  if [ -d "$target" ]; then
    # nixos-generate-config also writes configuration.nix. It is not used by
    # this flake; preserve it aside instead of deleting it or forcing a
    # "replace target config" confirmation for our own generated staging file.
    if [ -f "$target/configuration.nix" ] && [ ! -f "$target/flake.nix" ]; then
      stamp=$(date +%Y%m%d-%H%M%S)
      mv "$target/configuration.nix" "$target/configuration.nix.generated.$stamp" || {
        stop "无法保留生成的 configuration.nix"; return 1; }
      only_generated=1
      note "生成的 configuration.nix 已保留为 configuration.nix.generated.$stamp（Flake 不使用）"
    fi
    if [ "$only_generated" = "1" ]; then
      leftover=$(find "$target" -mindepth 1 -maxdepth 1 \
        ! -name 'configuration.nix.generated.*' | wc -l)
      if [ "$leftover" -eq 0 ]; then
        skip_replace=1
        note "目标仅有生成的 configuration.nix；保留它并直接写入 Flake（不移动整个目录）"
      fi
    fi
    if [ "$skip_replace" = "0" ]; then
      if diff -rq --no-dereference --exclude=.git --exclude=result \
        --exclude='result-*' --exclude=secrets "$REPO" "$target" >/dev/null 2>&1; then
        ok "/mnt/etc/nixos 与工作树一致；复用，不覆盖"
        return 0
      fi
      warn "/mnt/etc/nixos 已存在且与工作树不同；不会自动覆盖"
      say "现有配置会先移到 $target.previous.<时间>，不删除。"
      confirm_phrase "REPLACE-TARGET-CONFIG" "保留旧目录并重新写入 /mnt/etc/nixos" || return 1
      stamp=$(date +%Y%m%d-%H%M%S)
      mv "$target" "$target.previous.$stamp" || { stop "无法保留旧目标配置"; return 1; }
      note "旧目标配置已移到 $target.previous.$stamp"
    fi
  fi
  mkdir -p "$target" || { stop "无法创建 $target"; return 1; }
  ( cd "$REPO" && tar --exclude=.git --exclude=result --exclude='result-*' \
      --exclude=secrets -cf - . ) | ( cd "$target" && tar -xpf - ) || {
    stop "复制 Flake 到目标失败"; return 1; }
  [ ! -e "$target/secrets" ] || { stop "/mnt/etc/nixos 含 secrets"; return 1; }
  [ ! -e "$target/.git" ] || { stop "/mnt/etc/nixos 含 .git"; return 1; }
  [ ! -e "$target/result" ] || { stop "/mnt/etc/nixos 含 result"; return 1; }
  if find "$target" -maxdepth 2 \( -name mihomo -o -name 'proxy.env' -o -name 'arch-home' \) | grep . >/dev/null; then
    stop "/mnt/etc/nixos 意外包含运行时/Arch Home 内容"
    return 1
  fi
  [ -f "$target/flake.nix" ] || { stop "目标 Flake 不完整"; return 1; }
  [ -f "$target/hosts/main/hardware-configuration.nix" ] || { stop "目标 Flake 缺 main hardware"; return 1; }
  ok "Flake 已持久化到 /mnt/etc/nixos"
  return 0
}

d5_persist_build() {
  say ""
  say "== D5 持久化 Flake、复制输入到目标 store、构建 #main =="
  confirm_phrase "PERSIST-FLAKE" "把 Flake 写入 /mnt/etc/nixos（目标盘，不安装）" || return 1
  copy_repo_to_target || return 1
  local target=/mnt/etc/nixos result="$STATE_DIR/result-main"
  ( cd "$target" && run_logged "nix flake show --offline" \
      nix --extra-experimental-features 'nix-command flakes' flake show --offline ) || {
    stop "目标 Flake 无法离线求值"; return 1; }
  if ! bash "$target/install-preflight.sh" --repo "$target" --target main 2>&1 | tee -a "$LOG" | sed 's/^/  /'; then
    stop "目标配置 preflight --target main 失败"; return 1
  fi
  say "构建 #main（会下载/构建完整闭包；可能 10-60 分钟）"
  say "代理/网络环境：$([ -n "${http_proxy:-}" ] && printf '%s' "$http_proxy" || echo direct)"
  say "命令: nix flake archive ... 然后 nixos-rebuild build --out-link $result --flake $target#main"
  confirm_phrase "BUILD-MAIN" "复制 Flake 输入到目标 store 并构建 NixOS main 闭包（不写 ESP、不安装）" || return 1
  say "把 Flake 源和全部输入显式复制到目标 store（/mnt/nix/store）"
  run_logged "nix flake archive --offline --to local?root=/mnt" \
    nix --extra-experimental-features 'nix-command flakes' flake archive --offline \
    --to 'local?root=/mnt' "$target" || { stop "目标 store 复制失败"; return 1; }
  run_logged "nixos-rebuild build #main" \
    nixos-rebuild build --out-link "$result" --flake "$target#main" || {
    stop "nixos-rebuild build 失败；保留现场"; return 1; }
  [ -e "$result/etc/fstab" ] || { stop "构建结果缺少 etc/fstab"; return 1; }
  sset build-result "$result"
  ok "main 构建成功: $result"
  return 0
}

d6_verify_build() {
  local result
  result=$(sget build-result)
  [ -n "$result" ] && [ -e "$result/etc/fstab" ] || { stop "没有构建结果"; return 1; }
  say ""
  say "== D6 验证构建出的 fstab / ESP =="
  grep -Eq 'subvol=/?@nixos([,[:space:]]|$)' "$result/etc/fstab" || { stop "fstab 根不是 @nixos"; return 1; }
  grep -Eq 'subvol=/?@nixos-home([,[:space:]]|$)' "$result/etc/fstab" || { stop "fstab home 不是 @nixos-home"; return 1; }
  grep -Eq 'subvol=/?@nixos-nix([,[:space:]]|$)' "$result/etc/fstab" || { stop "fstab nix 不是 @nixos-nix"; return 1; }
  if grep -Eq 'subvol=/?@([,[:space:]]|$)' "$result/etc/fstab"; then
    stop "fstab 仍含 Arch @（危险）"; return 1
  fi
  local efi
  efi=$(nix --extra-experimental-features 'nix-command flakes' eval --offline --raw \
    "/mnt/etc/nixos#nixosConfigurations.main.config.boot.loader.efi.efiSysMountPoint" 2>/dev/null)
  if [ "$efi" = "/boot" ]; then ok "efiSysMountPoint=/boot"; else stop "efiSysMountPoint=$efi"; return 1; fi
  [ "$(findmnt -M /mnt/boot -o UUID -n | head -1)" = "$ESP_UUID" ] || { stop "/mnt/boot UUID 不匹配"; return 1; }
  [ -f /mnt/boot/EFI/Linux/arch-linux-lts.efi ] || { stop "Arch UKI 丢失"; return 1; }
  local esp_free
  esp_free=$(df -Pm /mnt/boot | awk 'NR==2{print $4}')
  [ "$esp_free" -ge 300 ] || { stop "ESP 可用 ${esp_free} MiB < 300"; return 1; }
  ok "fstab、ESP、Arch UKI、空间全部正常"
  reset_counters
  return 0
}

d7_install() {
  say ""
  say "== D7 执行 nixos-install（真正写入目标盘/ESP，需独立明确授权）=="
  if [ "$(sget install-done)" = "yes" ]; then
    ok "本现场已完成 nixos-install；跳过重复安装（继续 D8/D9）"
    return 0
  fi
  sdel install-done
  source_proxy_if_ready || true
  if ! probe_url "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store/nix-cache-info"; then
    if ! probe_url "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store/nix-cache-info" "${http_proxy:-}"; then
      stop "安装前 TUNA 不可达；不要开始 nixos-install"
      return 1
    fi
  fi
  ok "安装前网络检查通过"
  [ -n "${NIX_CONFIG:-}" ] || { stop "NIX_CONFIG 为空"; return 1; }
  say "命令: nixos-install --flake /mnt/etc/nixos#main --no-root-passwd"
  say "不会修改 NVRAM（canTouchEfiVariables=false）；boot hook 会校验并保留 Arch 默认项。"
  confirm_phrase "INSTALL-NIXOS" "运行 nixos-install 写入 @nixos* 和共享 ESP" || return 1
  local rc inst_out="$STATE_DIR/nixos-install.out"
  sdel install-done
  : >"$inst_out"; chmod 600 "$inst_out" 2>/dev/null || true
  nixos-install --flake /mnt/etc/nixos#main --no-root-passwd 2>&1 | tee -a "$LOG" "$inst_out"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    stop "nixos-install 失败（$rc）；没有自动清理，子卷和挂载保留"
    show_log_tail
    return 1
  fi
  if ! grep -q 'loader.conf: Arch UKI is the default entry' "$inst_out"; then
    stop "安装退出 0，但 boot hook 的 Arch 默认项校验没有在这次输出中出现；不要重启"
    show_log_tail
    return 1
  fi
  sset install-done yes
  ok "nixos-install 完成，boot hook 已把 Arch UKI 设为默认"
  return 0
}

d8_password() {
  say ""
  say "== D8 设置 calendar 密码（不会写日志）=="
  confirm_phrase "SET-PASSWORD" "在目标系统上设置 calendar 密码（写目标盘）" || return 1
  if ! nixos-enter --root /mnt -c 'passwd calendar'; then
    stop "设置 calendar 密码失败；不要重启，先检查"
    return 1
  fi
  ok "calendar 密码已设置"
  return 0
}

d9_verify_boot() {
  say ""
  say "== D9 校验 Arch UKI / 启动项 / NVRAM =="
  local before after order
  before=$(sget arch-uki-before)
  [ -n "$before" ] || { stop "缺少 C 阶段记录的 Arch UKI 哈希"; return 1; }
  after=$(sha256sum /mnt/boot/EFI/Linux/arch-linux-lts.efi 2>/dev/null | awk '{print $1}')
  if [ "$before" != "$after" ]; then
    stop "Arch UKI SHA256 安装前后不一致"; return 1
  fi
  ok "Arch UKI SHA256 未变: $after"
  [ -f /mnt/boot/loader/loader.conf ] || { stop "缺少 /mnt/boot/loader/loader.conf"; return 1; }
  [ "$(grep -c '^default[[:space:]]' /mnt/boot/loader/loader.conf 2>/dev/null)" -eq 1 ] || {
    stop "loader.conf default 行数异常"; return 1; }
  grep -qx 'default arch-linux-lts.efi' /mnt/boot/loader/loader.conf || {
    stop "loader.conf 默认不是 Arch UKI"; return 1; }
  ok "loader.conf 默认项是 arch-linux-lts.efi"
  find /mnt/boot/loader/entries -name 'nixos-*.conf' -print -quit 2>/dev/null | grep . >/dev/null || {
    stop "没有 NixOS 启动项"; return 1; }
  local boot_list
  boot_list=$(bootctl --esp-path=/mnt/boot list 2>/dev/null) || { stop "bootctl 读取失败"; return 1; }
  printf '%s\n' "$boot_list" | grep 'arch-linux-lts.efi' >/dev/null || { stop "bootctl 看不到 Arch UKI"; return 1; }
  printf '%s\n' "$boot_list" | grep -Ei 'nixos' >/dev/null || { stop "bootctl 看不到 NixOS"; return 1; }
  ok "bootctl 同时看到 Arch UKI 和 NixOS"
  order=$(efibootmgr | sed -n 's/^BootOrder: //p')
  if [ "$order" != "$(sget efi-bootorder-before)" ]; then
    stop "EFI BootOrder 安装前后不一致"; return 1
  fi
  efibootmgr -v | grep 'Linux Boot Manager' >/dev/null || { stop "原 Linux Boot Manager 消失"; return 1; }
  ok "EFI BootOrder 未变: $order"
  return 0
}

d10_finalize() {
  say ""
  say "== D10 持久 Flake / 目标 store / 卸载 =="
  sdel install-complete
  local target=/mnt/etc/nixos
  [ -f "$target/flake.nix" ] && [ -f "$target/hosts/main/hardware-configuration.nix" ] || {
    stop "/mnt/etc/nixos 不完整"; return 1; }
  [ ! -e "$target/secrets" ] || { stop "/mnt/etc/nixos 含 secrets"; return 1; }
  ( cd "$target" && nix --extra-experimental-features 'nix-command flakes' flake show --offline >/dev/null 2>&1 ) || {
    stop "持久源在 Live store 中不可求值"; return 1; }
  nixos-enter --root /mnt -c 'cd /etc/nixos && nix flake show --offline' >/dev/null 2>&1 || {
    stop "目标 store 缺少 Flake 输入；E3 将无法离线求值"; return 1; }
  ok "目标系统可离线求值 /etc/nixos"
  sync
  if ! umount -R /mnt 2>/dev/null; then
    stop "/mnt 卸载失败（busy）；不要强制、不要重启"
    findmnt -R /mnt | sed 's/^/  /'
    return 1
  fi
  [ -z "$(findmnt -R /mnt -n 2>/dev/null)" ] || { stop "/mnt 仍有挂载"; return 1; }
  sset install-complete yes
  if [ "$(sget proxy-mode)" = "mihomo" ]; then
    stop_mihomo
  fi
  ok "D 阶段 PASS"
  say ""
  say "现在可以手动重启（脚本不会自动重启）。"
  say "重启后：systemd-boot 默认仍是 Arch；请手动选择 NixOS 做首次启动验收。"
  say "首次启动后按 docs/ARCH_DUAL_BOOT.md 阶段 E 检查，再回到 Arch 验收。"
  return 0
}

stage_install() {
  stage_log install
  reset_counters
  hr; say "${C_BLD}D. NixOS 安装向导（每个写盘步骤独立确认）${C_OFF}"; hr
  detect_iso
  refresh_devices
  if [ "$LIVE" != "yes" ] || [ "$ISO_ID" != "nixos" ]; then
    stop "D 阶段只能在 NixOS Live ISO 中执行"
    return 1
  fi
  installation_guard || return 1
  if [ -n "$(sget partial-install)" ] && [ "$(sget partial-install)" = "yes" ]; then
    warn "C 阶段发现已有 @nixos* 子卷；继续前请确认这是上次现场，不是别的系统"
  fi
  if [ -n "$(sget btrfs-uuid)" ] && [ "$(sget btrfs-uuid)" != "$BTRFS_UUID" ]; then
    stop "C 阶段确认的 Btrfs UUID 与当前不一致；重新执行 [3]"
    return 1
  fi
  if [ -n "$(sget esp-uuid)" ] && [ "$(sget esp-uuid)" != "$ESP_UUID" ]; then
    stop "C 阶段确认的 ESP UUID 与当前不一致；重新执行 [3]"
    return 1
  fi
  if [ "$ISO_VER" != "26.05" ]; then
    warn "ISO VERSION_ID=$ISO_VER，配置 stateVersion=26.05"
    say "确认后才会继续（不改配置里的 stateVersion）。"
    confirm_phrase "STATE-VERSION-OK" "接受 ISO 版本与 stateVersion 的差异" || return 1
  fi
  if [ ! -e "/mnt/boot/EFI/Linux/arch-linux-lts.efi" ] && findmnt -rn -M /mnt >/dev/null 2>&1; then
    stop "/mnt/boot 不是原 Arch ESP"
    return 1
  fi

  say ""
  say "计划：D2 创建子卷 → D3 挂载 → D4 现场 hardware → D5 构建 → D6 验证"
  say "      → D7 nixos-install → D8 密码 → D9 UKI/NVRAM → D10 卸载"
  confirm_phrase "INSTALL-MAIN" "开始 main 安装向导（此时还没有写盘）" || return 1

  d2_subvolumes || return 1
  d3_mount_target || return 1
  d4_hardware || return 1
  d5_persist_build || return 1
  d6_verify_build || return 1
  d7_install || return 1
  d8_password || return 1
  d9_verify_boot || return 1
  d10_finalize || return 1
  return 0
}

# ---------------------------------------------------------------------------
# status / recovery / cleanup
# ---------------------------------------------------------------------------

detect_subvol_state() {
  SV="@unknown"
  if [ -n "${BTRFS_UUID:-}" ] && mount_top_ro; then
    local out=""
    local s
    for s in @ @home @log @pkg @nixos @nixos-home @nixos-nix; do
      subvol_present "$s" && out="$out $s"
    done
    unmount_top || true
    SV=${out:-none}
  fi
}

stage_status() {
  stage_log status
  detect_iso
  refresh_devices
  say "${C_BLD}当前状态${C_OFF}（只读；不会写盘）"
  hr
  say "ISO:      ${ISO_PRETTY:-unknown} (ID=${ISO_ID:-?}, VERSION_ID=${ISO_VER:-?}); live=$LIVE; UEFI=$UEFI"
  say "机器:     ${VENDOR:-?} / ${PRODUCT:-?}"
  say "内置盘:   ${DISK:-none} ${DISK_MODEL:-} ${DISK_SIZE_B:-}"
  say "Btrfs:    ${BTRFS_UUID:-none}"
  say "ESP:      ${ESP_UUID:-none}"
  say "Ventoy:   ${VENTOY_MOUNT:-未挂载（菜单 1 会自动发现）}"
  say "工作树:   $REPO $( [ -d "$REPO" ] && printf '存在' || printf '不存在' )"
  if [ -f "$REPO/hosts/main/hardware-configuration.nix" ]; then
    say "main HW:  已生成 ($(sha256sum "$REPO/hosts/main/hardware-configuration.nix" | cut -c1-16)...)"
  else
    say "main HW:  尚未生成（D4 现场生成）"
  fi
  say "cache:    $( [ -n "$(sget cache-fingerprint)" ] && printf '已导入 %s' "$(sget cache-imported-at)" || printf '未导入' )"
  say "proxy:    $( [ -n "$(sget proxy-mode)" ] && printf '%s 127.0.0.1:%s' "$(sget proxy-mode)" "$(sget proxy-port)" || printf 'direct/未设置' )"
  if [ "$(sget check-pass)" = "yes" ]; then
    if [ "$ISO_ID" = "nixos" ]; then
      say "C PASS:   yes"
    else
      say "C PASS:   yes（旧状态来自 $ISO_ID；到 NixOS ISO 重新执行 [3] 才有效）"
    fi
  else
    say "C PASS:   no"
  fi
  if [ "$(sget record-verified)" = "yes" ]; then
    if [ "$ISO_ID" = "nixos" ]; then
      say "备份记录: 已验证 $(sget record-archive)"
    else
      say "备份记录: 旧状态已验证 $(sget record-archive)（需在 ISO 重新校验）"
    fi
  else
    say "备份记录: 未验证"
  fi
  detect_subvol_state
  say "子卷:    $SV"
  if findmnt -rn -M /mnt >/dev/null 2>&1; then
    say "/mnt:     已挂载"
    findmnt -R /mnt -o TARGET,SOURCE,FSTYPE,OPTIONS | sed 's/^/  /'
  else
    say "/mnt:     未挂载"
  fi
  say "安装:     $( [ "$(sget install-complete)" = yes ] && echo complete || { [ "$(sget install-done)" = yes ] && echo 'install done / verify pending' || echo not-started; } )"
  say "日志:     $LOG_DIR/latest.log"
  hr
  say "下一步：按 1 → 2 → 3 顺序；C 全部 PASS 后才进入 4。"
}

stage_recovery() {
  stage_log recovery
  say "${C_BLD}失败排查 / 恢复说明${C_OFF}"
  hr
  cat <<'EOF'
1. 先看日志（不含密码/订阅/私钥）：
     ls -lt /run/nixos-install/log/
     tail -50 /run/nixos-install/log/latest.log

2. A3 cache 报 “cache/realisations: Read-only file system”：
   这是旧命令直接让 Nix 在只读 Ventoy 上创建元数据。本助手已改为
   “复制到 /run/nixos-install/cache.XXXXXX 再 nix copy”。不要再 remount rw，
   不要 rm -rf 旧副本；失败的副本和日志会保留，重跑菜单 [1] 即可。

3. 网络：
   Wi-Fi 先通过图形界面连接；手机可开 USB 网络共享。
   本地 Mihomo 只监听 127.0.0.1，不含 TUN/DNS 劫持；停止用菜单 [7]。
   小主机只是备用，不是必需。

4. C 阶段 STOP（尤其备份记录）：
   如果提示 “ESP 文件与备份记录不一致”，说明上次 ESP 备份没有覆盖当前
   Arch UKI/内核。回 Arch，在小主机可达时执行：
     sudo ./START.sh --record-backup
   然后把 /var/tmp/esp-backup-record.txt 复制到 Ventoy/nixos-install/。
   不要把 tar.gz 归档放到 Ventoy；不要跳过备份检查。

5. D 阶段部分完成（子卷/挂载/配置已存在）：
   助手不会删除或重建。先看菜单 [5]，再按 docs/ARCH_DUAL_BOOT.md 15.8
   只读检查 @nixos/@nixos-home/@nixos-nix、/mnt 挂载和 /mnt/etc/nixos。
   需要卸载时人工执行：
     findmnt -R /mnt
     umount -R /mnt        # 只有确认没有安装进程时

6. 禁止：
   mkfs、重新分区、btrfs subvolume delete、改默认子卷、删 Snapper 快照、
   安装 #nixos、未验证就覆盖共享 ESP、自动回滚删除目录。
   不要重启来“重试”；重启不能修复磁盘状态。
EOF
}

stage_cleanup() {
  stage_log cleanup
  say "停止本地 Mihomo / 清理运行时状态（不删除 cache 副本、不卸载 /mnt）"
  stop_mihomo
  if findmnt -rn -M "$ARCH_HOME" >/dev/null 2>&1; then
    if mount_is_ro "$ARCH_HOME"; then
      umount "$ARCH_HOME" 2>/dev/null && ok "已卸载 Arch @home 只读挂载" || warn "Arch @home 卸载失败"
    else
      warn "$ARCH_HOME 不是只读挂载；不自动卸载"
    fi
  fi
  if findmnt -rn -M /mnt >/dev/null 2>&1; then
    warn "/mnt 仍挂载；为保留现场不自动卸载（人工确认后用 umount -R /mnt）"
  fi
  say "cache 副本保留在 $STATE_DIR/cache.*；日志在 $LOG_DIR。"
}

# ---------------------------------------------------------------------------
# Arch-side: ESP archive + mini verification + offline record
# ---------------------------------------------------------------------------

stage_record_backup() {
  state_init
  stage_log record
  reset_counters
  hr; say "${C_BLD}Arch 侧：ESP 备份 + 小主机校验 + 离线记录${C_OFF}"; hr
  detect_iso
  if [ "$LIVE" = "yes" ] || [ "$ISO_ID" = "nixos" ]; then
    stop "--record-backup 只能在 Arch 上运行，不能在 NixOS ISO 内运行"
    return 1
  fi
  refresh_devices
  if [ "$PRODUCT" != "21LG" ]; then
    stop "当前机器 $PRODUCT 不是 LENOVO 21LG"
    return 1
  fi
  if [ "$DISK_COUNT" -ne 1 ]; then
    stop "内置盘不是恰好一个"
    return 1
  fi
  if ! findmnt -rn -M /boot >/dev/null 2>&1; then
    stop "/boot 未挂载；先在 Arch 挂载 ESP"
    return 1
  fi
  if [ "$(findmnt -M /boot -o UUID -n | head -1)" != "$ESP_UUID" ]; then
    stop "/boot UUID 不是内置盘上的 ESP UUID"
    return 1
  fi
  ESP_PATH=/boot
  ESP_OWN_MOUNT=0
  ok "ESP: /boot ($ESP_UUID)"

  say "检查小主机 SSH（$BACKUP_HOST）..."
  if ! ssh -o ConnectTimeout=8 -o BatchMode=no "$BACKUP_HOST" 'printf "mini-ok\n"' 2>&1 | tee -a "$LOG" | grep -x 'mini-ok' >/dev/null; then
    stop "无法通过 SSH 连接小主机；未生成有效记录"
    say "  小主机可达后重试；不要伪造记录。"
    return 1
  fi
  ok "小主机 SSH 可用"

  local stamp archive tar_rc gz_rc local_sha remote_sha avail created_at
  created_at=$(date -Iseconds)
  stamp=$(date +%Y%m%d-%H%M%S)
  archive="/var/tmp/arch-esp-$stamp.tar.gz"
  avail=$(df -Pm /var/tmp 2>/dev/null | awk 'NR==2{print $4}')
  if [ -z "$avail" ] || [ "$avail" -lt 200 ]; then
    stop "/var/tmp 可用空间不足 200 MiB（${avail:-unknown}）"
    return 1
  fi
  mkdir -p "$(dirname "$BACKUP_OUT")" || { stop "无法创建记录目录"; return 1; }
  umask 077
  say "创建 ESP 归档: $archive"
  sudo tar --numeric-owner --xattrs --acls -C "$ESP_PATH" -cpf - . | gzip -9 >"$archive"
  local -a ps=("${PIPESTATUS[@]}")
  tar_rc=${ps[0]}; gz_rc=${ps[1]:-1}
  if [ "$tar_rc" -ne 0 ] || [ "$gz_rc" -ne 0 ] || [ ! -s "$archive" ]; then
    stop "归档失败（tar=$tar_rc gzip=$gz_rc）；保留未完成文件 $archive"
    return 1
  fi
  ( cd /var/tmp && sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256" )
  local_sha=$(sha256sum "$archive" | awk '{print $1}')
  ok "归档 SHA256: $local_sha"

  ssh "$BACKUP_HOST" 'umask 077; mkdir -p ~/arch-esp-backups' || {
    stop "无法创建小主机备份目录"; return 1; }
  if ! scp "$archive" "$archive.sha256" "$BACKUP_HOST:arch-esp-backups/" 2>&1 | tee -a "$LOG"; then
    stop "复制归档到小主机失败"
    return 1
  fi
  remote_sha=$(ssh "$BACKUP_HOST" "cd ~/arch-esp-backups && sha256sum -c $(basename "$archive").sha256" 2>&1)
  printf '%s\n' "$remote_sha" | tee -a "$LOG" | sed 's/^/  /'
  if ! printf '%s\n' "$remote_sha" | grep "$(basename "$archive"): OK" >/dev/null; then
    stop "小主机 sha256sum -c 未通过；未生成记录"
    return 1
  fi
  if ! ssh "$BACKUP_HOST" "tar -tzf ~/arch-esp-backups/$(basename "$archive") >/dev/null" 2>/dev/null; then
    stop "小主机无法读取归档（tar -tzf 失败）；未生成记录"
    return 1
  fi
  ok "小主机已校验归档并可读取"

  say "比对当前 ESP 与归档内关键文件（确保归档覆盖当前 UKI/内核）..."
  local rel old cur h
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    old=$(tar -xzf "$archive" -O "./$rel" 2>/dev/null | sha256sum | awk '{print $1}')
    cur=$(sudo sha256sum "$ESP_PATH/$rel" 2>/dev/null | awk '{print $1}')
    if [ -z "$cur" ] || [ "$old" != "$cur" ]; then
      stop "归档与当前 ESP 不一致: $rel"
      say "  归档 ${old:0:16}... / 当前 ${cur:0:16}..."
      return 1
    fi
  done < <(key_esp_files)
  ok "归档覆盖当前 ESP 关键文件"

  say ""
  say "请人工确认：Restic 仓库密码的独立恢复副本现在可用（不在本机、不依赖小主机）。"
  if ! ask_yes "确认可用？"; then
    stop "用户未确认 Restic 密码独立恢复副本；未写记录"
    return 1
  fi

  local tmp="$BACKUP_OUT.tmp.$$"
  {
    printf 'format=nixos-infra-esp-backup-record-v1\n'
    printf 'generated_at=%s\n' "$(date -Iseconds)"
    printf 'host_vendor=%s\n' "$VENDOR"
    printf 'host_product=%s\n' "$PRODUCT"
    printf 'esp_uuid=%s\n' "$ESP_UUID"
    printf 'esp_device=%s\n' "/dev/disk/by-uuid/$ESP_UUID"
    printf 'archive_name=%s\n' "$(basename "$archive")"
    printf 'archive_sha256=%s\n' "$local_sha"
    printf 'archive_location=%s:~/arch-esp-backups/%s\n' "$BACKUP_HOST" "$(basename "$archive")"
    printf 'archive_created_at=%s\n' "$created_at"
    printf 'archive_verified_at=%s\n' "$(date -Iseconds)"
    printf 'archive_verified_by=%s\n' "ssh $BACKUP_HOST sha256sum -c $(basename "$archive").sha256"
    printf 'archive_verified_result=OK\n'
    printf 'restic_password_offline_copy=user-confirmed %s\n' "$(date -Iseconds)"
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      h=$(sudo sha256sum "$ESP_PATH/$rel" | awk '{print $1}')
      printf 'file.%s=%s\n' "$rel" "$h"
    done < <(key_esp_files)
  } >"$tmp" || { stop "无法写入临时记录 $tmp"; return 1; }
  if [ -f "$BACKUP_OUT" ]; then
    mv "$BACKUP_OUT" "$BACKUP_OUT.previous.$(date +%Y%m%d-%H%M%S)" || {
      stop "无法保留旧记录 $BACKUP_OUT"; return 1; }
  fi
  mv "$tmp" "$BACKUP_OUT" || { stop "无法写入记录 $BACKUP_OUT"; return 1; }
  chmod 644 "$BACKUP_OUT" || { stop "无法设置记录权限 $BACKUP_OUT"; return 1; }
  ok "离线验证记录已写入: $BACKUP_OUT"
  say ""
  say "下一步（只复制这个文本文件，不要复制 tar.gz）："
  say "  # 先确认 Ventoy 数据分区挂载点，不要假设 /dev/sda1"
  say "  VNT=\$(findmnt -n -o TARGET -L Ventoy | head -1)"
  say "  install -m 0644 '$BACKUP_OUT' \"\$VNT/nixos-install/esp-backup-record.txt\""
  say "  sha256sum '$BACKUP_OUT' \"\$VNT/nixos-install/esp-backup-record.txt\""
  say ""
  say "归档保留在本机: $archive（需要离线副本时另行加密，不要明文放 Ventoy）"
  return 0
}

# ---------------------------------------------------------------------------
# menus and main
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
NixOS 双系统安装助手 v$SCRIPT_VERSION

用法:
  bash START.sh              # 交互菜单（唯一现场入口）
  bash START.sh --prepare    # A: 导入 Ventoy 只读 cache 并离线求值
  bash START.sh --network    # B: 检查网络 / 启动本地 Mihomo
  bash START.sh --check      # C: 只读磁盘、ESP、备份记录检查
  bash START.sh --install    # D: 交互式安装（每个写盘步骤要短语确认）
  bash START.sh --status     # 只读状态
  bash START.sh --cleanup    # 停止 Mihomo / 运行时清理（不卸载 /mnt）
  bash START.sh --record-backup [--backup-host USER@HOST] [--out FILE]
                             # Arch 侧: 备份 ESP、mini 校验、写离线记录
  bash START.sh --help

安全边界:
  - 不运行 mkfs，不重新分区，不删除子卷/快照，不改 Btrfs 默认子卷。
  - 只安装 #main；#nixos 永远只属于小主机。
  - 没有 --yes/--force，也没有无人值守写盘模式。
  - Ventoy 只通过只读视图访问；cache 复制到 /run/nixos-install/cache.* 再导入。

参数:
  --bundle DIR       指定 <VENTOY>/nixos-install（测试/高级；默认自动发现）
  --backup-host H    小主机 SSH 目标（默认 $BACKUP_HOST）
  --out FILE         记录输出路径（默认 $BACKUP_OUT）
EOF
}

main_menu() {
  local choice
  while :; do
    clear 2>/dev/null || true
    detect_iso
    refresh_devices
    printf '%s\n' "${C_BLD}NixOS 双系统安装助手${C_OFF}  v$SCRIPT_VERSION"
    printf '机器: %s / %s   ISO: %s %s   UEFI: %s\n' \
      "${VENDOR:-?}" "${PRODUCT:-?}" "${ISO_ID:-?}" "${ISO_VER:-?}" "$UEFI"
    printf '目标: main（Arch 必须保留）   小主机: 仅备份，不是安装网络前提\n'
    hr
    printf '[1] 准备离线 Flake 缓存        %s\n' "$( [ -n "$(sget cache-fingerprint)" ] && echo '已导入' || echo '')"
    printf '[2] 检查网络 / 启动本地 Mihomo  %s\n' "$( [ -n "$(sget network-pass)" ] && echo "PASS $(sget proxy-mode)" || echo '')"
    printf '[3] 只读磁盘与备份检查          %s\n' "$( [ "$(sget check-pass)" = yes ] && echo 'PASS' || echo '')"
    printf '[4] 进入 NixOS 安装向导         %s\n' "$( [ "$(sget install-complete)" = yes ] && echo 'DONE' || { [ "$(sget install-done)" = yes ] && echo 'partial' || echo ''; } )"
    printf '[5] 查看当前状态\n'
    printf '[6] 查看失败原因 / 恢复说明\n'
    printf '[7] 停止 Mihomo / 运行时清理\n'
    printf '[0] 退出\n'
    hr
    if findmnt -rn -M /mnt >/dev/null 2>&1; then
      printf '%s注意%s /mnt 已挂载；重复安装前先看菜单 [5] 和 [6]\n' "$C_YEL" "$C_OFF"
    fi
    printf '选择: '
    IFS= read -r choice || return 0
    case "$choice" in
      1) stage_prepare; pause_enter;;
      2) stage_network; pause_enter;;
      3) stage_check; pause_enter;;
      4) stage_install; pause_enter;;
      5) stage_status; pause_enter;;
      6) stage_recovery; pause_enter;;
      7) stage_cleanup; pause_enter;;
      0) return 0;;
      *) ;;
    esac
  done
}

cleanup_all() {
  local rc=$?
  trap - EXIT
  if [ "${MIHOMO_STARTED_THIS_RUN:-0}" = "1" ] && [ "${KEEP_PROXY_ON_EXIT:-0}" != "1" ]; then
    stop_mihomo
  fi
  cleanup_ventoy
  if [ "${CLEAN_TOP:-0}" = "1" ]; then umount "$STATE_DIR/btrfs-top" 2>/dev/null || true; fi
  if findmnt -rn -M "$STATE_DIR/btrfs-top-rw" >/dev/null 2>&1; then
    umount "$STATE_DIR/btrfs-top-rw" 2>/dev/null || true
  fi
  if [ "${CLEAN_ESP:-0}" = "1" ]; then umount "$STATE_DIR/arch-esp" 2>/dev/null || true; fi
  if [ "${CLEAN_ARCH_HOME:-0}" = "1" ]; then
    if mount_is_ro "$ARCH_HOME"; then umount "$ARCH_HOME" 2>/dev/null || true; fi
  fi
  exit "$rc"
}

# Parse arguments before deciding on root.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0;;
    --status) MODE=status; shift;;
    --prepare) MODE=prepare; shift;;
    --network) MODE=network; shift;;
    --check) MODE=check; shift;;
    --install) MODE=install; shift;;
    --cleanup) MODE=cleanup; shift;;
    --record-backup) MODE=record; shift;;
    --bundle) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; BUNDLE=$2; shift 2;;
    --backup-host) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; BACKUP_HOST=$2; shift 2;;
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; BACKUP_OUT=$2; shift 2;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2;;
  esac
done

# Re-exec as root for on-site modes, but never for --record-backup (it must
# use the invoking user's SSH keys) and never for --help.
if [ "$EUID" -ne 0 ] && [ "$MODE" != "record" ]; then
  if ! have sudo; then
    die "需要 root；请用 sudo 运行，或先 sudo -i"
  fi
  exec sudo --preserve-env=START_BUNDLE,START_STATE_DIR,START_REPO,START_BACKUP_HOST,START_BACKUP_OUT -- "${BASH:-/usr/bin/bash}" "$SELF" "${ORIG_ARGS[@]}"
fi

# If someone runs --record-backup through sudo, drop back to the invoking user
# so ssh/scp use that user's keys. The sudo timestamp is still valid for tar.
if [ "$EUID" -eq 0 ] && [ "$MODE" = "record" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  exec sudo -u "$SUDO_USER" --preserve-env=START_BUNDLE,START_STATE_DIR,START_REPO,START_BACKUP_HOST,START_BACKUP_OUT -- "${BASH:-/usr/bin/bash}" "$SELF" "${ORIG_ARGS[@]}"
fi

if [ "$MODE" = "record" ]; then
  STATE_DIR=${START_STATE_DIR:-/var/tmp/nixos-install-record}
  LOG_DIR="$STATE_DIR/log"
fi

if [ "$LIB_ONLY" = "1" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; else exit 0; fi
fi

state_init
trap cleanup_all EXIT
trap 'printf "\n中断；不会自动清理安装目标。\n"; exit 130' INT TERM

# Common environment for every Nix invocation in this session.
export NIX_CONFIG="experimental-features = nix-command flakes
substituters = https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://cache.nixos.org/
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="

# A one-shot --network is intentionally usable as a hand-off to a later
# --install: keep the verified proxy alive. The menu (and --install/--check)
# stops only a Mihomo that this process started, unless it is the network mode.
if [ "$MODE" = "network" ]; then
  KEEP_PROXY_ON_EXIT=1
fi

case "$MODE" in
  menu) main_menu;;
  status) stage_status;;
  prepare) stage_prepare;;
  network) stage_network;;
  check) stage_check;;
  install) stage_install;;
  cleanup) stage_cleanup;;
  record) stage_record_backup;;
  *) die "未知模式: $MODE";;
esac
