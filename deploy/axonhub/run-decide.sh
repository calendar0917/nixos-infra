#!/bin/sh
# 每轮只做只读画像 + 严格模型决策；不调用 apply.py，不写 axonhub。
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=/etc/profiles/per-user/calendar/bin/python3
STATE_DIR=${AXONHUB_DECIDE_STATE_DIR:-"$HOME/.local/state/axonhub/decisions"}
LOCK_FILE="$STATE_DIR/decide.lock"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec /run/current-system/sw/bin/flock -n "$LOCK_FILE" /bin/sh -c '
    set -eu
    "$1" "$2/profile.py" --output "$3/profile-latest.json"
    "$1" "$2/decide.py" --mode model \
        --profile "$3/profile-latest.json" \
        --state-dir "$3" \
        --json-out "$3/decision-latest.json" \
        --page-out "$3/decision-latest.md"
' sh "$PYTHON" "$HERE" "$STATE_DIR"
