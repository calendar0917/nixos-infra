#!/usr/bin/env bash
# Initialize the Hermes deployment without overwriting existing runtime state.
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly COMPOSE_FILE="$APP_DIR/compose.yaml"
readonly ENV_FILE="$APP_DIR/.env"
readonly DATA_DIR="$APP_DIR/data"
readonly DATA_ENV="$DATA_DIR/.env"
readonly DATA_CONFIG="$DATA_DIR/config.yaml"
readonly HERMES_TAG="nousresearch/hermes-agent:stable"
readonly MERGE_SCRIPT="$DATA_DIR/.hermes-merge-config.py"

log() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  rm -f -- "$MERGE_SCRIPT"
}
trap cleanup EXIT

[[ "$(id -u)" -ne 0 ]] || fail "run this script as calendar, not as root."
[[ "$(id -un)" == "calendar" ]] || fail "expected user calendar (got $(id -un)); data is owned by the desktop account."
[[ -f "$COMPOSE_FILE" ]] || fail "missing $COMPOSE_FILE"

repo_root="$(git -C "$APP_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "deploy/hermes is not inside a Git checkout."
[[ "$APP_DIR" == "$repo_root/deploy/hermes" ]] || fail "run the committed deploy/hermes tree from the repository."

for command in docker git ip python3 sudo tailscale; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

if sudo docker compose version >/dev/null 2>&1; then
  COMPOSE=(sudo docker compose)
elif sudo docker-compose version >/dev/null 2>&1; then
  COMPOSE=(sudo docker-compose)
else
  fail "Docker Compose v2 is not available (tried 'sudo docker compose' and 'sudo docker-compose')."
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

env_has_nonempty() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
if not path.is_file():
    raise SystemExit(1)
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
        raise SystemExit(0 if value else 1)
raise SystemExit(1)
PY
}

# Update or append keys atomically. Existing keys not named here are preserved.
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
os.makedirs(directory, mode=0o700, exist_ok=True)
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
self_info = status.get("Self") or {}
if ip not in (self_info.get("TailscaleIPs") or []):
    raise SystemExit(f"{ip} is not in Self.TailscaleIPs")
PY
}

log "Checking Docker daemon and Tailscale..."
sudo docker info >/dev/null 2>&1 || fail "cannot talk to the Docker daemon with sudo."
tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[[ -n "$tailscale_ip" ]] || fail "Tailscale has no IPv4 address. Refusing to fall back to 0.0.0.0."
check_tailscale_ip "$tailscale_ip"

if [[ "$(sudo docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null || true)" == "true" ]]; then
  log "Stopping the running hermes-agent before touching shared state..."
  compose stop hermes >/dev/null
fi

log "Preparing local runtime directories..."
umask 077
install -d -m 700 "$DATA_DIR"
if [[ ! -f "$DATA_DIR/.gitignore" ]]; then
  printf '# Runtime state; never commit.\n*\n!.gitignore\n' > "$DATA_DIR/.gitignore"
  chmod 600 "$DATA_DIR/.gitignore"
fi

image_ref="$(env_value "$ENV_FILE" HERMES_IMAGE || true)"
if [[ -z "$image_ref" || "$image_ref" != *"@sha256:"* ]]; then
  log "Pulling official $HERMES_TAG to resolve its digest..."
  sudo docker pull "$HERMES_TAG"
  image_ref="$(sudo docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$HERMES_TAG" \
    | grep -m1 '^nousresearch/hermes-agent@sha256:' || true)"
  [[ -n "$image_ref" ]] || fail "could not resolve the pulled image digest."
else
  if ! sudo docker image inspect "$image_ref" >/dev/null 2>&1; then
    log "Pulling pinned Hermes image..."
    sudo docker pull "$image_ref"
  fi
fi

env_set "$ENV_FILE" \
  "TAILSCALE_IPV4=$tailscale_ip" \
  "HERMES_IMAGE=$image_ref" \
  "HERMES_UID=$(id -u)" \
  "HERMES_GID=$(id -g)"

compose config --quiet

log "Running the official Hermes setup (non-interactive, existing state preserved)..."
compose run --rm --no-deps -T -e HERMES_DASHBOARD=0 hermes setup --non-interactive

[[ -f "$DATA_CONFIG" ]] || fail "Hermes setup did not create data/config.yaml."
[[ -f "$DATA_ENV" ]] || fail "Hermes setup did not create data/.env."
chmod 700 "$DATA_DIR"
chmod 600 "$DATA_ENV" "$DATA_CONFIG" 2>/dev/null || true

# Keep the official setup's generated secrets (for example API_SERVER_KEY),
# and add only the credentials that are not present yet.
if ! env_has_nonempty "$DATA_ENV" HERMES_DASHBOARD_BASIC_AUTH_USERNAME; then
  env_set "$DATA_ENV" "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin"
fi

if ! env_has_nonempty "$DATA_ENV" HERMES_DASHBOARD_BASIC_AUTH_PASSWORD \
   && ! env_has_nonempty "$DATA_ENV" HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH; then
  web_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  env_set "$DATA_ENV" "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$web_password"
  unset web_password
fi

# Hermes refuses a signing secret shorter than 16 bytes, and a rejected
# secret silently skips the password provider (the dashboard then fails
# closed on a non-loopback bind). Keep a 32+ character margin and replace a
# too-short value; this invalidates existing browser sessions by design.
secret_len="$(python3 - "$DATA_ENV" <<'PY'
import sys
from pathlib import Path

key = "HERMES_DASHBOARD_BASIC_AUTH_SECRET"
path = Path(sys.argv[1])
length = 0
if path.is_file():
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
            length = len(value)
            break
print(length)
PY
)"
if [[ "${secret_len:-0}" -lt 32 ]]; then
  session_secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  env_set "$DATA_ENV" "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$session_secret"
  unset session_secret
  if [[ "${secret_len:-0}" -gt 0 ]]; then
    log "Replaced a session secret shorter than 32 characters (existing sessions are reset)."
  fi
fi

# These are authorization boundaries, not optional defaults.
env_set "$DATA_ENV" \
  "QQ_ALLOW_ALL_USERS=false" \
  "GATEWAY_ALLOW_ALL_USERS=false"

if ! grep -qE '^[[:space:]]*(export[[:space:]]+)?QQ_APP_ID=' "$DATA_ENV"; then
  {
    printf '\n# QQ official Bot credentials. Fill these in with a local editor,\n'
    printf '# chmod 600 data/.env, then rerun scripts/init.sh. Never use a QQ\n'
    printf '# number as the OpenID.\n'
    printf '# QQ_APP_ID=\n'
    printf '# QQ_CLIENT_SECRET=\n'
    printf '# QQ_ALLOWED_USERS=\n'
    printf '# QQBOT_HOME_CHANNEL=\n'
  } >> "$DATA_ENV"
fi
chmod 600 "$DATA_ENV"

cat > "$MERGE_SCRIPT" <<'PY'
import os
import sys
import tempfile
from pathlib import Path

from ruamel.yaml import YAML

home = Path(os.environ.get("HERMES_HOME", "/opt/data"))
config_path = home / "config.yaml"
env_path = home / ".env"
ip = os.environ["HERMES_TAILSCALE_IP"]


def read_env(path):
    values = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        name = name.strip()
        if name.startswith("export "):
            name = name[7:].strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[name] = value
    return values


def split_ids(value):
    return [item.strip() for item in value.split(",") if item.strip()]


env = read_env(env_path)
yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 4096

with config_path.open("r", encoding="utf-8") as fh:
    document = yaml.load(fh)
if document is None:
    document = {}
if not isinstance(document, dict):
    raise SystemExit("config.yaml must contain a mapping at the top level")

webapp = document.get("webapp")
if not isinstance(webapp, dict):
    webapp = {}
webapp["enabled"] = True
webapp["host"] = "0.0.0.0"
webapp["port"] = 9120
webapp["public_url"] = f"http://{ip}:9120"
document["webapp"] = webapp

platforms = document.get("platforms")
if not isinstance(platforms, dict):
    platforms = {}
qqbot = platforms.get("qqbot")
if not isinstance(qqbot, dict):
    qqbot = {}
extra = qqbot.get("extra")
if not isinstance(extra, dict):
    extra = {}

allow_from = []
for key in ("QQ_ALLOWED_USERS", "QQBOT_HOME_CHANNEL"):
    for item in split_ids(env.get(key, "")):
        if item not in allow_from:
            allow_from.append(item)

missing = [name for name in ("QQ_APP_ID", "QQ_CLIENT_SECRET") if not env.get(name, "").strip()]
if not allow_from:
    missing.append("QQ_ALLOWED_USERS/QQBOT_HOME_CHANNEL")
qq_enabled = not missing

qqbot["enabled"] = qq_enabled
extra["dm_policy"] = "allowlist"
extra["allow_from"] = allow_from if qq_enabled else []
extra["group_policy"] = "disabled"
extra["group_allow_from"] = []
qqbot["extra"] = extra
platforms["qqbot"] = qqbot
document["platforms"] = platforms

fd, tmp_name = tempfile.mkstemp(prefix=".config.", dir=config_path.parent, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        yaml.dump(document, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, config_path)
    os.chmod(config_path, 0o600)
except BaseException:
    try:
        os.unlink(tmp_name)
    except FileNotFoundError:
        pass
    raise

# Read the result back so a broken write fails initialization loudly.
with config_path.open("r", encoding="utf-8") as fh:
    check = yaml.load(fh)
if not isinstance(check, dict) or check.get("webapp", {}).get("enabled") is not True:
    raise SystemExit("webapp configuration did not persist")
print(f"QQ enabled: {'yes' if qq_enabled else 'no'}")
if missing:
    print("QQ missing: " + ", ".join(missing))
PY
chmod 600 "$MERGE_SCRIPT"

log "Merging Webapp and QQ settings into data/config.yaml..."
compose run --rm --no-deps -T -e HERMES_DASHBOARD=0 \
  -e "HERMES_TAILSCALE_IP=$tailscale_ip" \
  hermes python /opt/data/.hermes-merge-config.py
rm -f -- "$MERGE_SCRIPT"

chmod 700 "$DATA_DIR"
chmod 600 "$DATA_ENV" "$DATA_CONFIG"

log ""
log "Hermes initialization complete."
log "  Tailscale IPv4: $tailscale_ip"
log "  Image: $image_ref"
log "  Data: $DATA_DIR"
log "  Web login: username admin; password stored in data/.env (not printed)"
log "  Webapp: http://$tailscale_ip:9120"
log "  Dashboard: http://$tailscale_ip:9119"
log "  QQ: see the 'QQ enabled' line above"
log "  Model: run 'sudo docker compose --env-file .env run --rm hermes setup model'"
log "         if it is not configured yet."
log "  Service is stopped; next: scripts/start.sh"
