#!/usr/bin/env bash
# Unified terminal system control center for the main host's niri session.
#
# The package wrapper supplies every tool through runtimeInputs, so this script
# never depends on the interactive Fish shell's PATH, aliases or functions.
# Subcommands run in the current terminal; `launch` is the only command that
# starts Kitty, and the main menu loops inside that single window.
#
# The environment overrides below exist so the headless regression tests can
# substitute stub commands. A normal session never needs to set them.
set -euo pipefail

fzf_bin="${SYSTEM_CONTROL_FZF:-fzf}"
kitty_bin="${SYSTEM_CONTROL_KITTY:-kitty}"
nmtui_bin="${SYSTEM_CONTROL_NMTUI:-nmtui}"
bluetui_bin="${SYSTEM_CONTROL_BLUETUI:-bluetui}"
wiremix_bin="${SYSTEM_CONTROL_WIREMIX:-wiremix}"
btop_bin="${SYSTEM_CONTROL_BTOP:-btop}"
brightnessctl_bin="${SYSTEM_CONTROL_BRIGHTNESSCTL:-brightnessctl}"
powerprofilesctl_bin="${SYSTEM_CONTROL_POWERPROFILESCTL:-powerprofilesctl}"
systemctl_bin="${SYSTEM_CONTROL_SYSTEMCTL:-systemctl}"

backlight_device="${SYSTEM_CONTROL_BACKLIGHT_DEVICE:-amdgpu_bl1}"
brightness_min=5
lid_unit=lid-keep-awake.service

# Absolute path to this wrapper. fzf's execute-silent and preview commands run
# in a child shell, so a bare command name would depend on PATH there.
self="${SYSTEM_CONTROL_SELF:-}"
if [ -z "$self" ]; then
  self="$(readlink -f -- "${BASH_SOURCE[0]}")"
fi

main_items=(
  "网络连接"
  "蓝牙设备"
  "音频与音量"
  "屏幕亮度"
  "电源性能模式"
  "合盖行为"
  "系统监控"
  "退出"
)

# Catppuccin Mocha, close to the Fuzzel and Waybar palettes already in use.
fzf_colors='fg:#cdd6f4,bg:#1e1e2e,hl:#89b4fa,fg+:#1e1e2e,bg+:#89b4fa,hl+:#1e1e2e,info:#f9e2af,prompt:#89b4fa,pointer:#f5c2e7,marker:#a6e3a1,spinner:#f5c2e7,header:#6c7086,border:#45475a'

fzf_base=(
  --height=100%
  --layout=reverse
  --border=rounded
  --border-label=' 系统控制中心 '
  --color="$fzf_colors"
)

error() {
  printf 'niri-system-control: %s\n' "$*" >&2
}

pause_for_user() {
  printf '按 Enter 返回控制中心…' >&2
  read -r _ || true
}

usage() {
  cat <<'EOF'
niri-system-control — 终端系统控制中心

用法：
  niri-system-control launch [命令]   在 Kitty 浮动窗口中打开控制中心
  niri-system-control menu            在当前终端打开主菜单
  niri-system-control network         网络连接（nmtui）
  niri-system-control bluetooth       蓝牙设备（bluetui）
  niri-system-control audio           音频与音量（wiremix）
  niri-system-control brightness      屏幕亮度 TUI
  niri-system-control brightness-status
                                      输出当前亮度百分比
  niri-system-control brightness-step N
                                      增减 N 个百分点（带符号整数）
  niri-system-control brightness-set N
                                      将亮度设为 N%（自动限制到 5%–100%）
  niri-system-control power           电源性能模式 TUI
  niri-system-control lid             合盖行为 TUI
  niri-system-control monitor         系统监控（btop）

主菜单：方向键选择，Enter 确认，Esc 退出。
亮度 TUI：←/h 降低 5%，→/l 提高 5%，H 降低 1%，L 提高 1%。
EOF
}

is_integer() {
  # No leading zeros: avoids Bash octal interpretation in arithmetic.
  [[ "$1" =~ ^(0|[1-9][0-9]{0,3})$ ]]
}

is_signed_integer() {
  [[ "$1" =~ ^[+-]?(0|[1-9][0-9]{0,3})$ ]]
}

clamp_percent() {
  local value="$1"
  if (( value < brightness_min )); then
    printf '%d\n' "$brightness_min"
  elif (( value > 100 )); then
    printf '100\n'
  else
    printf '%d\n' "$value"
  fi
}

# Read and validate the real device maximum before any write. This keeps a
# missing or renamed backlight from silently changing another device.
read_backlight_max() {
  local max
  if ! max="$("$brightnessctl_bin" -d "$backlight_device" max 2>/dev/null)"; then
    error "无法读取背光设备 $backlight_device 的最大亮度；未做任何更改"
    return 1
  fi
  if ! [[ "$max" =~ ^[0-9]+$ ]]; then
    error "背光设备 $backlight_device 返回无效的最大亮度 '$max'；未做任何更改"
    return 1
  fi
  max=$((10#$max))
  if (( max <= 0 )); then
    error "背光设备 $backlight_device 的最大亮度为 0；未做任何更改"
    return 1
  fi
  printf '%d\n' "$max"
}

current_percent() {
  local max current percent
  if ! max="$(read_backlight_max)"; then
    return 1
  fi
  if ! current="$("$brightnessctl_bin" -d "$backlight_device" get 2>/dev/null)"; then
    error "无法读取背光设备 $backlight_device 的当前亮度；未做任何更改"
    return 1
  fi
  if ! [[ "$current" =~ ^[0-9]+$ ]]; then
    error "背光设备 $backlight_device 返回无效的当前亮度 '$current'；未做任何更改"
    return 1
  fi
  current=$((10#$current))
  if (( current > max )); then
    error "背光设备 $backlight_device 的当前亮度高于最大值；未做任何更改"
    return 1
  fi
  percent=$(( (current * 100 + max / 2) / max ))
  printf '%d\n' "$percent"
}

# Absolute percentage written only after the device has been read successfully
# again. This refuses to write when either `max` or `get` fails, so a renamed or
# partially available device cannot fall back to another backlight. No relative
# decrement is ever passed to brightnessctl.
apply_percent() {
  local target="$1"
  if ! current_percent >/dev/null; then
    return 1
  fi
  if ! "$brightnessctl_bin" -d "$backlight_device" set "${target}%" >/dev/null; then
    error "写入背光设备 $backlight_device 失败"
    return 1
  fi
}

brightness_status() {
  local percent
  if ! percent="$(current_percent)"; then
    return 1
  fi
  printf '当前亮度：%d%%\n' "$percent"
}

brightness_step() {
  local delta="${1:-}" current target
  if ! is_signed_integer "$delta"; then
    error "brightness-step 需要带符号整数百分比，例如 -5 或 +5"
    return 2
  fi
  delta="${delta#+}"
  if ! current="$(current_percent)"; then
    return 1
  fi
  target="$(clamp_percent "$(( current + delta ))")"
  if ! apply_percent "$target"; then
    return 1
  fi
  printf '当前亮度：%d%%\n' "$target"
}

brightness_set() {
  local requested="${1:-}" target
  if ! is_integer "$requested"; then
    error "brightness-set 需要整数百分比，例如 50"
    return 2
  fi
  target="$(clamp_percent "$requested")"
  if ! apply_percent "$target"; then
    return 1
  fi
  printf '当前亮度：%d%%\n' "$target"
}

# Internal dispatcher used by the fzf Enter binding. Selecting a preset or a
# step row applies it immediately and leaves the brightness UI open.
brightness_action() {
  local action="${1:-}"
  case "$action" in
    -5) brightness_step -5 ;;
    +5) brightness_step 5 ;;
    -1) brightness_step -1 ;;
    +1) brightness_step 1 ;;
    5 | 25 | 50 | 75 | 100) brightness_set "$action" ;;
    *)
      error "未知的亮度操作 '$action'"
      return 2
      ;;
  esac
}

brightness_menu() {
  local -a items=(
    "-5|← / h      降低 5%"
    "+5|→ / l      提高 5%"
    "-1|H          降低 1%"
    "+1|L          提高 1%"
    "5|预设         5%"
    "25|预设        25%"
    "50|预设        50%"
    "75|预设        75%"
    "100|预设      100%"
  )

  # Enter stays inside fzf: execute-silent applies the change and
  # refresh-preview redraws the live percentage. Esc aborts back to the menu.
  if ! printf '%s\n' "${items[@]}" |
    "$fzf_bin" "${fzf_base[@]}" \
      --delimiter='|' \
      --with-nth=2.. \
      --prompt='亮度 > ' \
      --header='←/h 降低 5% · →/l 提高 5% · H 降低 1% · L 提高 1% · Enter 应用预设 · Esc 返回' \
      --preview "'$self' brightness-status" \
      --preview-window='up,3,border-bottom' \
      --bind "left:execute-silent('$self' brightness-step -5)+refresh-preview" \
      --bind "h:execute-silent('$self' brightness-step -5)+refresh-preview" \
      --bind "right:execute-silent('$self' brightness-step 5)+refresh-preview" \
      --bind "l:execute-silent('$self' brightness-step 5)+refresh-preview" \
      --bind "H:execute-silent('$self' brightness-step -1)+refresh-preview" \
      --bind "L:execute-silent('$self' brightness-step 1)+refresh-preview" \
      --bind "enter:execute-silent('$self' brightness-action {1})+refresh-preview" \
      >/dev/null; then
    return 0
  fi
}

profile_label() {
  case "$1" in
    performance) printf '性能' ;;
    balanced) printf '平衡' ;;
    power-saver) printf '节能' ;;
    *) printf '%s' "$1" ;;
  esac
}

power_menu() {
  local current list selection key mode label line
  local -a modes=()
  local -a items=()

  while :; do
    if ! current="$("$powerprofilesctl_bin" get 2>/dev/null)"; then
      error "无法读取当前电源性能模式"
      return 1
    fi
    current="${current%%$'\n'*}"
    current="${current%$'\r'}"

    if ! list="$("$powerprofilesctl_bin" list 2>/dev/null)"; then
      error "无法读取设备支持的电源性能模式"
      return 1
    fi
    modes=()
    while IFS= read -r line; do
      if [[ "$line" =~ ^[*[:space:]]*([A-Za-z0-9_-]+):[[:space:]]*$ ]]; then
        modes+=("${BASH_REMATCH[1]}")
      fi
    done <<<"$list"
    if ((${#modes[@]} == 0)); then
      error "电源性能服务没有列出任何可用模式"
      return 1
    fi

    items=()
    for mode in "${modes[@]}"; do
      label="$(profile_label "$mode")"
      if [ "$mode" = "$current" ]; then
        items+=("$mode|● $label · $mode（当前）")
      else
        items+=("$mode|○ $label · $mode")
      fi
    done

    if ! selection="$(printf '%s\n' "${items[@]}" |
      "$fzf_bin" "${fzf_base[@]}" \
        --delimiter='|' \
        --with-nth=2.. \
        --prompt='电源性能 > ' \
        --header="当前：$current · Enter 切换 · Esc 返回")"; then
      return 0
    fi
    [ -z "$selection" ] && return 0

    key="${selection%%|*}"
    local found=0
    for mode in "${modes[@]}"; do
      if [ "$mode" = "$key" ]; then
        found=1
        break
      fi
    done
    if ((found == 0)); then
      error "电源性能模式 '$key' 不在设备支持的列表中"
      pause_for_user
      continue
    fi
    if [ "$key" = "$current" ]; then
      # Already active: do not run a redundant set command.
      continue
    fi
    if ! "$powerprofilesctl_bin" set "$key"; then
      error "切换到电源性能模式 '$key' 失败"
      pause_for_user
    fi
  done
}

lid_is_active() {
  "$systemctl_bin" --user is-active --quiet "$lid_unit"
}

lid_menu() {
  local selection key active state_label header
  local -a items=()

  while :; do
    if lid_is_active; then
      active=1
      state_label='合盖保持运行'
    else
      active=0
      state_label='正常合盖行为'
    fi

    items=()
    if ((active)); then
      items+=("normal|○ 正常合盖行为（合盖后挂起）")
      items+=("awake|● 合盖保持运行（当前）")
    else
      items+=("normal|● 正常合盖行为（当前）")
      items+=("awake|○ 合盖保持运行")
    fi

    header="当前状态：$state_label"$'\n'"合盖保持运行不会自动触发挂起前锁屏，离开设备前建议按 Alt+L 锁屏。"

    if ! selection="$(printf '%s\n' "${items[@]}" |
      "$fzf_bin" "${fzf_base[@]}" \
        --delimiter='|' \
        --with-nth=2.. \
        --prompt='合盖行为 > ' \
        --header="$header")"; then
      return 0
    fi
    [ -z "$selection" ] && return 0

    key="${selection%%|*}"
    case "$key" in
      normal)
        # Same target state is an explicit no-op, never a blind toggle.
        if ((active)); then
          if ! "$systemctl_bin" --user stop "$lid_unit"; then
            error "停止 $lid_unit 失败"
            pause_for_user
          fi
        fi
        ;;
      awake)
        if ((!active)); then
          if ! "$systemctl_bin" --user start "$lid_unit"; then
            error "启动 $lid_unit 失败"
            pause_for_user
          fi
        fi
        ;;
      *)
        error "未知的合盖选项 '$key'"
        pause_for_user
        ;;
    esac
  done
}

run_tui() {
  local label="$1"
  shift
  local status=0
  "$@" || status=$?
  if ((status != 0 && status != 130)); then
    printf '\n' >&2
    error "$label 异常退出（状态 $status）"
    pause_for_user
  fi
  return 0
}

main_menu_select() {
  printf '%s\n' "${main_items[@]}" |
    "$fzf_bin" "${fzf_base[@]}" \
      --prompt='控制中心 > ' \
      --header='↑/↓ 选择 · Enter 确认 · Esc 退出' \
      --pointer='▸' \
      --marker='✓'
}

menu() {
  local selection
  while :; do
    if ! selection="$(main_menu_select)"; then
      return 0
    fi
    case "$selection" in
      "网络连接")
        run_tui "网络连接" "$nmtui_bin"
        ;;
      "蓝牙设备")
        run_tui "蓝牙设备" "$bluetui_bin"
        ;;
      "音频与音量")
        run_tui "音频与音量" "$wiremix_bin"
        ;;
      "屏幕亮度")
        brightness_menu || true
        ;;
      "电源性能模式")
        power_menu || true
        ;;
      "合盖行为")
        lid_menu || true
        ;;
      "系统监控")
        run_tui "系统监控" "$btop_bin"
        ;;
      "退出" | "")
        return 0
        ;;
      *)
        error "未知菜单项 '$selection'"
        ;;
    esac
  done
}

launch() {
  local -a target=()
  if [ "$#" -gt 0 ]; then
    target=("$@")
  else
    target=(menu)
  fi
  exec "$kitty_bin" --app-id=system-control --title=系统控制 "$self" "${target[@]}"
}

main() {
  local command="${1:-}"
  case "$command" in
    launch)
      shift
      launch "$@"
      ;;
    menu)
      shift
      menu
      ;;
    network)
      shift
      exec "$nmtui_bin" "$@"
      ;;
    bluetooth)
      shift
      exec "$bluetui_bin" "$@"
      ;;
    audio)
      shift
      exec "$wiremix_bin" "$@"
      ;;
    brightness)
      shift
      brightness_menu
      ;;
    brightness-status)
      shift
      brightness_status
      ;;
    brightness-step)
      shift
      brightness_step "${1:-}"
      ;;
    brightness-set)
      shift
      brightness_set "${1:-}"
      ;;
    brightness-action)
      shift
      brightness_action "${1:-}"
      ;;
    power)
      shift
      power_menu
      ;;
    lid)
      shift
      lid_menu
      ;;
    monitor)
      shift
      exec "$btop_bin" "$@"
      ;;
    *)
      if [ -n "$command" ]; then
        error "未知命令 '$command'"
      fi
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
