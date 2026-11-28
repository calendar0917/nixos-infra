#!/bin/sh
# 安装/更新用户级 decide service+timer。
# 改频率只改一个数：AXONHUB_DECIDE_INTERVAL_MINUTES=30 ./install-axonhub-decide.sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INTERVAL=${AXONHUB_DECIDE_INTERVAL_MINUTES:-10}
case "$INTERVAL" in
    ''|*[!0-9]*) echo "AXONHUB_DECIDE_INTERVAL_MINUTES 必须是正整数" >&2; exit 2 ;;
esac
if [ "$INTERVAL" -lt 1 ]; then
    echo "AXONHUB_DECIDE_INTERVAL_MINUTES 必须 >= 1" >&2
    exit 2
fi
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
install -m 0644 "$HERE/axonhub-decide.service" "$UNIT_DIR/axonhub-decide.service"
install -m 0644 "$HERE/axonhub-decide.timer" "$UNIT_DIR/axonhub-decide.timer"
# 仓库模板保留默认 10；安装目录按同一个环境变量同步渲染。
sed -i "s/^Environment=AXONHUB_DECIDE_INTERVAL_MINUTES=.*/Environment=AXONHUB_DECIDE_INTERVAL_MINUTES=$INTERVAL/" \
    "$UNIT_DIR/axonhub-decide.service"
sed -i "s/^OnUnitActiveSec=.*/OnUnitActiveSec=${INTERVAL}min/" \
    "$UNIT_DIR/axonhub-decide.timer"
chmod 0755 "$HERE/run-decide.sh"
systemctl --user daemon-reload
systemctl --user enable --now axonhub-decide.timer
printf 'installed interval=%smin unit_dir=%s\n' "$INTERVAL" "$UNIT_DIR"
systemctl --user list-timers axonhub-decide.timer --no-pager
