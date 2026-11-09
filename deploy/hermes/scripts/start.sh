#!/usr/bin/env bash
# Start Hermes on the current Tailscale IPv4 only. Never fall back to 0.0.0.0.
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly COMPOSE_FILE="$APP_DIR/compose.yaml"
readonly ENV_FILE="$APP_DIR/.env"
readonly DATA_ENV="$APP_DIR/data/.env"
readonly DATA_CONFIG="$APP_DIR/data/config.yaml"

log() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  rm -f -- "${RENDER_TMP:-}" "${INSPECT_TMP:-}"
}
trap cleanup EXIT

[[ "$(id -u)" -ne 0 ]] || fail "run this script as calendar, not as root."
[[ "$(id -un)" == "calendar" ]] || fail "expected user calendar (got $(id -un))."
[[ -f "$COMPOSE_FILE" ]] || fail "missing $COMPOSE_FILE"
[[ -f "$ENV_FILE" ]] || fail "missing .env; run scripts/init.sh first."
[[ -f "$DATA_ENV" && -f "$DATA_CONFIG" ]] || fail "missing data/.env or data/config.yaml; run scripts/init.sh first."

for command in curl docker ip python3 sudo tailscale; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

if sudo docker compose version >/dev/null 2>&1; then
  COMPOSE=(sudo docker compose)
elif sudo docker-compose version >/dev/null 2>&1; then
  COMPOSE=(sudo docker-compose)
else
  fail "Docker Compose v2 is not available."
fi

compose() {
  "${COMPOSE[@]}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

env_value() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
if not path.is_file():
    raise SystemExit(0)
for raw in path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    name, value = line.split("=", 1)
    name = name.strip()
    if name.startswith("export "):
        name = name[7:].strip()
    if name == key:
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        print(value)
        break
PY
}

env_set() {
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import os
import sys
import tempfile

path = sys.argv[1]
assignments = []
for item in sys.argv[2:]:
    if "=" not in item:
        raise SystemExit(f"invalid env assignment: {item!r}")
    key, value = item.split("=", 1)
    assignments.append((key, value))
targets = dict(assignments)

old_lines = []
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        old_lines = fh.read().splitlines()

new_lines = []
seen = set()
for raw in old_lines:
    stripped = raw.strip()
    if not stripped or stripped.startswith("#") or "=" not in stripped:
        new_lines.append(raw)
        continue
    name = stripped.split("=", 1)[0].strip()
    if name.startswith("export "):
        name = name[7:].strip()
    if name not in targets:
        new_lines.append(raw)
        continue
    if name in seen:
        continue
    new_lines.append(f"{name}={targets[name]}")
    seen.add(name)

for key, _value in assignments:
    if key not in seen:
        new_lines.append(f"{key}={targets[key]}")
        seen.add(key)

directory = os.path.dirname(os.path.abspath(path)) or "."
fd, tmp = tempfile.mkstemp(prefix=".env.", dir=directory, text=True)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(new_lines).rstrip("\n") + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    os.chmod(path, 0o600)
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

check_tailscale_ip() {
  local ip="$1" iface
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "invalid Tailscale IPv4: $ip"
  iface="$(ip -4 -o addr show | awk -v ip="$ip" '$4 ~ ("^" ip "/") {print $2; exit}')"
  [[ -n "$iface" ]] || fail "Tailscale IPv4 $ip is not assigned to a local interface."
  [[ "$iface" == tailscale* ]] || fail "Tailscale IPv4 $ip is assigned to $iface, not a Tailscale interface."
  python3 - "$ip" <<'PY' || fail "Tailscale is not running with the expected IPv4."
import json
import subprocess
import sys

ip = sys.argv[1]
try:
    status = json.loads(subprocess.check_output(["tailscale", "status", "--json"], text=True))
except Exception as exc:
    raise SystemExit(str(exc))
if status.get("BackendState") != "Running":
    raise SystemExit(f"BackendState={status.get('BackendState')!r}")
if ip not in ((status.get("Self") or {}).get("TailscaleIPs") or []):
    raise SystemExit(f"{ip} is not in Self.TailscaleIPs")
PY
}

log "Checking Tailscale..."
tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[[ -n "$tailscale_ip" ]] || fail "Tailscale has no IPv4 address. Refusing to fall back to 0.0.0.0."
check_tailscale_ip "$tailscale_ip"

configured_ip="$(env_value "$ENV_FILE" TAILSCALE_IPV4 || true)"
if [[ "$configured_ip" != "$tailscale_ip" ]]; then
  log "Tailscale IPv4 changed from ${configured_ip:-<unset>} to $tailscale_ip; updating local config..."
  if [[ "$(sudo docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null || true)" == "true" ]]; then
    log "Stopping hermes-agent before changing the bound address..."
    compose stop hermes >/dev/null
  fi
  env_set "$ENV_FILE" "TAILSCALE_IPV4=$tailscale_ip"
  compose run --rm --no-deps -T -e HERMES_DASHBOARD=0 \
    -e "HERMES_NEW_IP=$tailscale_ip" \
    hermes sh -c '
      set -eu
      hermes config set webapp.enabled true
      hermes config set webapp.host 0.0.0.0
      hermes config set webapp.port 9120
      hermes config set webapp.public_url "http://$HERMES_NEW_IP:9120"
    '
else
  log "Tailscale IPv4: $tailscale_ip"
fi

compose config --quiet

# Render the Compose model and enforce the binding boundary before any
# container is started.
RENDER_TMP="$(mktemp)"
chmod 600 "$RENDER_TMP"
compose config --format json > "$RENDER_TMP"
python3 - "$tailscale_ip" "$RENDER_TMP" <<'PY'
import json
import sys

ip = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as fh:
    model = json.load(fh)

service = (model.get("services") or {}).get("hermes")
if not isinstance(service, dict):
    raise SystemExit("compose model has no hermes service")
if service.get("network_mode") == "host":
    raise SystemExit("host networking is forbidden")
if service.get("privileged"):
    raise SystemExit("privileged mode is forbidden")

ports = service.get("ports") or []
expected = {("9120", 9120), ("9119", 9119)}
seen = set()
for entry in ports:
    host_ip = entry.get("host_ip")
    published = str(entry.get("published", ""))
    target = int(entry.get("target", 0))
    protocol = entry.get("protocol", "tcp")
    if host_ip != ip:
        raise SystemExit(f"published port {published}:{target} binds {host_ip!r}, not {ip}")
    if protocol != "tcp":
        raise SystemExit(f"published port {published}:{target} uses {protocol}, not tcp")
    key = (published, target)
    if key not in expected:
        raise SystemExit(f"unexpected published port {published}:{target}")
    seen.add(key)
if seen != expected:
    raise SystemExit(f"published ports are {sorted(seen)}, expected {sorted(expected)}")

volumes = service.get("volumes") or []
for volume in volumes:
    source = str(volume.get("source", ""))
    target = str(volume.get("target", ""))
    if target == "/var/run/docker.sock" or "docker.sock" in source:
        raise SystemExit("the Docker socket must not be mounted")
    if target == "/opt/data" and not source.endswith("/deploy/hermes/data"):
        raise SystemExit(f"unexpected /opt/data source: {source}")
PY

log "Starting Hermes..."
compose up -d

container_state=""
for _ in $(seq 1 30); do
  container_state="$(sudo docker inspect -f '{{.State.Status}}' hermes-agent 2>/dev/null || true)"
  [[ "$container_state" == "running" ]] && break
  sleep 1
done
[[ "$container_state" == "running" ]] || fail "hermes-agent did not reach running state (status: ${container_state:-missing})."
[[ "$(sudo docker inspect -f '{{.State.Restarting}}' hermes-agent)" == "false" ]] || fail "hermes-agent is restarting; check logs."

INSPECT_TMP="$(mktemp)"
chmod 600 "$INSPECT_TMP"
sudo docker inspect hermes-agent > "$INSPECT_TMP"
python3 - "$tailscale_ip" "$INSPECT_TMP" <<'PY'
import json
import sys

ip = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as fh:
    data = json.load(fh)[0]
bindings = (data.get("HostConfig") or {}).get("PortBindings") or {}
missing = {"9120/tcp", "9119/tcp"} - set(bindings)
if missing:
    raise SystemExit(f"missing published bindings: {sorted(missing)}")
for key, entries in bindings.items():
    for entry in entries or []:
        host_ip = entry.get("HostIp")
        host_port = str(entry.get("HostPort", ""))
        if host_ip != ip:
            raise SystemExit(f"{key} is published on {host_ip!r}, not {ip}")
        if key not in {"9120/tcp", "9119/tcp"}:
            raise SystemExit(f"unexpected published binding: {key} -> {host_port}")
extra = set(bindings) - {"9120/tcp", "9119/tcp"}
if extra:
    raise SystemExit(f"unexpected published ports: {sorted(extra)}")
PY

for port in 9120 9119; do
  ready="false"
  for _ in $(seq 1 60); do
    code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://$tailscale_ip:$port/" 2>/dev/null || true)"
    case "$code" in
      000|503) sleep 2 ;;
      *) ready="true"; break ;;
    esac
  done
  [[ "$ready" == "true" ]] || fail "Hermes did not become ready on port $port; check logs with: sudo docker compose --env-file .env logs --tail=200"
done

log ""
log "Hermes is running."
log "  Webapp:    http://$tailscale_ip:9120"
log "  Dashboard: http://$tailscale_ip:9119"
log "  Logs:      sudo docker compose --env-file .env logs -f --tail=100"
log "  Check:     scripts/check.sh"
