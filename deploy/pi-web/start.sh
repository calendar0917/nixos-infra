#!/usr/bin/env bash
set -euo pipefail

if [[ ! -t 0 ]]; then
  echo "Error: Pi Web launcher requires an interactive terminal." >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "Error: npx is not available." >&2
  exit 1
fi

umask 077

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/pi-web"
password_file="$config_dir/password"

install -d -m 700 "$config_dir"

if [[ -L "$password_file" ]]; then
  echo "Error: password file must not be a symlink." >&2
  exit 1
fi

set_password() {
  local first second

  while true; do
    read -r -s -p "设置 Pi Web 密码（至少16字符）: " first || return 1
    printf '\n'

    read -r -s -p "确认密码: " second || return 1
    printf '\n'

    if (( ${#first} < 16 )); then
      echo "密码长度不能少于16个字符。"
      continue
    fi

    if [[ "$first" != "$second" ]]; then
      echo "两次密码不一致。"
      continue
    fi

    printf '%s' "$first" > "$password_file"
    chmod 600 "$password_file"
    echo "密码已安全保存。"
    return 0
  done
}

echo "================================"
echo "         Pi Web Launcher"
echo "================================"

if [[ -f "$password_file" ]]; then
  chmod 600 "$password_file"

  echo "1) 使用现有密码启动（默认）"
  echo "2) 重设密码并启动"
  echo "3) 退出"
  echo

  read -r -p "请选择 [1]: " choice

  case "${choice:-1}" in
    1)
      ;;
    2)
      set_password
      ;;
    3)
      exit 0
      ;;
    *)
      echo "无效选项。" >&2
      exit 1
      ;;
  esac
else
  echo "首次运行，请设置登录密码。"
  set_password
fi

if [[ ! -s "$password_file" || ! -r "$password_file" ]]; then
  echo "Error: password file is missing or empty." >&2
  exit 1
fi

export PI_WEB_PASSWORD
PI_WEB_PASSWORD="$(cat "$password_file")"

export PI_SKIP_VERSION_CHECK=1
export PI_TELEMETRY=0
export PI_WEB_SKIP_VERSION_CHECK=1

echo
echo "Pi Web 即将启动"
echo "监听地址: 0.0.0.0:30141"

if command -v tailscale >/dev/null 2>&1; then
  tailscale_ip="$(tailscale ip -4 2>/dev/null || true)"

  if [[ -n "$tailscale_ip" ]]; then
    echo "Tailscale: http://${tailscale_ip}:30141"
  fi
fi

echo "局域网: http://<主机局域网IPv4>:30141"
echo "按 Ctrl+C 停止服务"
echo

npx --yes @agegr/pi-web@latest \
  --hostname 0.0.0.0 \
  --port 30141 \
  --no-open
