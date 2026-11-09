#!/usr/bin/env bash
# Read-only health and security checks for the Hermes deployment.
set -u -o pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly COMPOSE_FILE="$APP_DIR/compose.yaml"
readonly ENV_FILE="$APP_DIR/.env"
readonly DATA_ENV="$APP_DIR/data/.env"
readonly DATA_CONFIG="$APP_DIR/data/config.yaml"

PASS=0
FAIL=0
PENDING=0
LOG_TMP=""
INSPECT_TMP=""
BIND_TMP=""
HTTP_TMP=""

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*" >&2; }
pending() { PENDING=$((PENDING + 1)); printf 'PENDING  %s\n' "$*"; }
info() { printf '%s\n' "$*"; }

cleanup() {
  rm -f -- "${LOG_TMP:-}" "${INSPECT_TMP:-}" "${BIND_TMP:-}" "${HTTP_TMP:-}"
}
trap cleanup EXIT

if [[ "$(id -u)" -eq 0 ]]; then
  fail "run this script as calendar, not as root"
  exit 1
fi
if [[ "$(id -un)" != "calendar" ]]; then
  fail "expected user calendar (got $(id -un))"
  exit 1
fi
if [[ ! -f "$COMPOSE_FILE" || ! -f "$ENV_FILE" || ! -f "$DATA_ENV" || ! -f "$DATA_CONFIG" ]]; then
  fail "missing deployment files; run scripts/init.sh first"
  exit 1
fi

for command in curl docker ip python3 sudo tailscale; do
  if ! command -v "$command" >/dev/null 2>&1; then
    fail "required command not found: $command"
    exit 1
  fi
done

if sudo docker compose version >/dev/null 2>&1; then
  COMPOSE=(sudo docker compose)
elif sudo docker-compose version >/dev/null 2>&1; then
  COMPOSE=(sudo docker-compose)
else
  fail "Docker Compose v2 is not available"
  exit 1
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

wait_for_http() {
  local port="$1" code=""
  for _ in $(seq 1 60); do
    code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://$tailscale_ip:$port/" 2>/dev/null || true)"
    case "$code" in
      000|503) sleep 2 ;;
      *) return 0 ;;
    esac
  done
  return 1
}

info "== Deployment =="
if [[ -f "$ENV_FILE" ]] && compose config --quiet 2>/dev/null; then
  pass "docker compose config is valid"
else
  fail "docker compose config is invalid"
fi

tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [[ -n "$tailscale_ip" ]]; then
  iface="$(ip -4 -o addr show | awk -v ip="$tailscale_ip" '$4 ~ ("^" ip "/") {print $2; exit}')"
  if [[ -n "$iface" && "$iface" == tailscale* ]]; then
    pass "Tailscale online on $iface with IPv4 $tailscale_ip"
  else
    fail "Tailscale IPv4 $tailscale_ip is not assigned to a Tailscale interface"
  fi
else
  fail "Tailscale has no IPv4 address"
fi

configured_ip="$(env_value "$ENV_FILE" TAILSCALE_IPV4 || true)"
if [[ -n "$tailscale_ip" && "$configured_ip" == "$tailscale_ip" ]]; then
  pass ".env Tailscale IPv4 matches the live address"
else
  fail ".env Tailscale IPv4 (${configured_ip:-<unset>}) does not match live address (${tailscale_ip:-<none>})"
fi

image_ref="$(env_value "$ENV_FILE" HERMES_IMAGE || true)"
if [[ "$image_ref" == *"@sha256:"* ]]; then
  pass "HERMES_IMAGE is pinned by digest"
else
  fail "HERMES_IMAGE is not pinned by digest"
fi

container_state="$(sudo docker inspect -f '{{.State.Status}}' hermes-agent 2>/dev/null || true)"
if [[ "$container_state" == "running" ]]; then
  pass "container hermes-agent is running"
else
  fail "container hermes-agent is not running (status: ${container_state:-missing})"
fi

if [[ "$container_state" == "running" ]]; then
  gateway_ready="false"
  for _ in $(seq 1 30); do
    if sudo docker top hermes-agent -eo pid,args 2>/dev/null | grep -Eq 'gateway[[:space:]]+run'; then
      gateway_ready="true"
      break
    fi
    sleep 2
  done
  if [[ "$gateway_ready" == "true" ]]; then
    pass "Hermes Gateway process is present"
  else
    fail "Hermes Gateway process was not found"
  fi

  if wait_for_http 9120; then
    pass "Webapp HTTP endpoint is ready on port 9120"
  else
    fail "Webapp HTTP endpoint did not become ready on port 9120"
  fi
  if wait_for_http 9119; then
    pass "Dashboard HTTP endpoint is ready on port 9119"
  else
    fail "Dashboard HTTP endpoint did not become ready on port 9119"
  fi
  for port in 9120 9119; do
    code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/" 2>/dev/null || true)"
    if [[ "$code" == "200" || "$code" == "302" || "$code" == "401" ]]; then
      pass "loopback http://127.0.0.1:$port/ answers (HTTP $code)"
    else
      fail "loopback http://127.0.0.1:$port/ does not answer (HTTP ${code:-none})"
    fi
  done

  for port in 9120 9119; do
    if sudo docker exec hermes-agent /opt/hermes/.venv/bin/python -c \
      "import socket; s=socket.create_connection(('127.0.0.1', $port), 3); s.close()" >/dev/null 2>&1; then
      pass "container listener is accepting connections on 127.0.0.1:$port"
    else
      fail "container listener is not accepting connections on 127.0.0.1:$port"
    fi
  done
fi

info ""
info "== Host publishing boundary =="
if [[ "$container_state" == "running" && -n "$tailscale_ip" ]]; then
  INSPECT_TMP="$(mktemp)"
  chmod 600 "$INSPECT_TMP"
  if sudo docker inspect hermes-agent > "$INSPECT_TMP" 2>/dev/null; then
    BIND_TMP="$(mktemp)"
    chmod 600 "$BIND_TMP"
    python3 - "$tailscale_ip" "$INSPECT_TMP" > "$BIND_TMP" <<'PY'
import json
import sys

ip = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as fh:
    data = json.load(fh)[0]
bindings = (data.get("HostConfig") or {}).get("PortBindings") or {}
errors = []
if set(bindings) != {"9120/tcp", "9119/tcp"}:
    errors.append(f"published bindings are {sorted(bindings)}, expected 9120/tcp and 9119/tcp")
for key, entries in bindings.items():
    for entry in entries or []:
        if entry.get("HostIp") not in ("0.0.0.0", ip):
            errors.append(f"{key} host IP is {entry.get('HostIp')!r}, expected 0.0.0.0")
if errors:
    print("\n".join("FAIL  " + item for item in errors))
    raise SystemExit(1)
print("PASS  Docker publishes only 9119/9120, on 0.0.0.0")
print("PASS  Gateway API port 8642 has no host binding")
PY
    while IFS= read -r line; do
      printf '%s\n' "$line"
      case "$line" in
        PASS*) PASS=$((PASS + 1)) ;;
        FAIL*) FAIL=$((FAIL + 1)) ;;
      esac
    done < "$BIND_TMP"
  else
    fail "cannot inspect the container port bindings"
  fi

  for port in 9119 9120; do
    if sudo ss -lntp 2>/dev/null | grep -Eq "(^|[[:space:]])0\\.0\\.0\\.0:$port[[:space:]]"; then
      pass "docker-proxy listens on 0.0.0.0:$port (loopback, LAN and Tailscale)"
    else
      fail "nothing listens on 0.0.0.0:$port"
    fi
  done
  if sudo ss -lntp 2>/dev/null | grep -Eq ':(8642)([[:space:]]|$)'; then
    fail "something is listening on host port 8642"
  else
    pass "no listener on host port 8642"
  fi
fi

info ""
info "== HTTP and authentication =="
if [[ "$container_state" == "running" && -n "$tailscale_ip" ]]; then
  HTTP_TMP="$(mktemp)"
  chmod 600 "$HTTP_TMP"
  python3 - "$tailscale_ip" "$DATA_ENV" > "$HTTP_TMP" <<'PY'
import http.client
import json
import sys
from http.cookies import SimpleCookie

ip = sys.argv[1]
env_path = sys.argv[2]
values = {}
with open(env_path, encoding="utf-8") as fh:
    for raw in fh.read().splitlines():
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

username = values.get("HERMES_DASHBOARD_BASIC_AUTH_USERNAME", "")
password = values.get("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD", "")
if values.get("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH") and not password:
    print("FAIL  web auth has only a password hash; no password is available for the login check")
    raise SystemExit(1)
if not username or not password:
    print("FAIL  web auth username/password are missing from data/.env")
    raise SystemExit(1)


def request(port, method, path, body=None, cookie=None):
    conn = http.client.HTTPConnection(ip, port, timeout=10)
    headers = {"Accept": "text/html,application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if cookie:
        headers["Cookie"] = cookie
    try:
        conn.request(method, path, body=data, headers=headers)
        response = conn.getresponse()
        payload = response.read()
        return response.status, response.getheaders(), payload
    finally:
        conn.close()


def cookie_header(headers):
    jar = SimpleCookie()
    for key, value in headers:
        if key.lower() == "set-cookie":
            try:
                jar.load(value)
            except Exception:
                pass
    return "; ".join(f"{key}={morsel.value}" for key, morsel in jar.items())


failures = 0
for label, port in (("webapp", 9120), ("dashboard", 9119)):
    try:
        status, _headers, _body = request(port, "GET", "/")
        if status in (301, 302, 303, 307, 308, 401):
            print(f"PASS  {label}: unauthenticated page is protected (HTTP {status})")
        else:
            print(f"FAIL  {label}: unauthenticated page returned HTTP {status}, expected a redirect or 401")
            failures += 1

        status, _headers, _body = request(port, "GET", "/api/config")
        if status == 401:
            print(f"PASS  {label}: unauthenticated API returns 401")
        else:
            print(f"FAIL  {label}: unauthenticated /api/config returned HTTP {status}, expected 401")
            failures += 1

        login = {"provider": "basic", "username": username, "password": password, "next": "/"}
        status, headers, _body = request(port, "POST", "/auth/password-login", login)
        cookie = cookie_header(headers)
        if status == 200 and cookie:
            print(f"PASS  {label}: password login succeeds and sets a session cookie")
        else:
            print(f"FAIL  {label}: password login returned HTTP {status} or set no cookie")
            failures += 1
            cookie = ""

        if cookie:
            status, _headers, _body = request(port, "GET", "/api/config", cookie=cookie)
            if status == 200:
                print(f"PASS  {label}: authenticated API access succeeds")
            else:
                print(f"FAIL  {label}: authenticated /api/config returned HTTP {status}")
                failures += 1

            status, _headers, _body = request(port, "GET", "/", cookie=cookie)
            if status == 200:
                print(f"PASS  {label}: authenticated page loads")
            else:
                print(f"FAIL  {label}: authenticated page returned HTTP {status}")
                failures += 1

        bad = {"provider": "basic", "username": username, "password": password + "-wrong", "next": "/"}
        status, _headers, _body = request(port, "POST", "/auth/password-login", bad)
        if status == 401:
            print(f"PASS  {label}: wrong password is rejected (HTTP 401)")
        else:
            print(f"FAIL  {label}: wrong password returned HTTP {status}, expected 401")
            failures += 1
    except Exception as exc:
        print(f"FAIL  {label}: request failed ({type(exc).__name__})")
        failures += 1

raise SystemExit(1 if failures else 0)
PY
  while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      PASS*) PASS=$((PASS + 1)) ;;
      FAIL*) FAIL=$((FAIL + 1)) ;;
    esac
  done < "$HTTP_TMP"
fi

info ""
info "== Hermes logs and QQ =="
if [[ "$container_state" == "running" ]]; then
  LOG_TMP="$(mktemp)"
  chmod 600 "$LOG_TMP"
  sudo docker logs --tail=500 hermes-agent > "$LOG_TMP" 2>&1 || true

  if grep -Eq 'Refusing to bind|Address already in use|no auth providers are registered' "$LOG_TMP"; then
    fail "Hermes logs contain a bind or authentication startup failure"
  else
    pass "no bind/authentication startup failure in recent logs"
  fi

  if sudo docker exec hermes-agent hermes config get platforms.qqbot.enabled --json 2>/dev/null | grep -q 'true'; then
    qq_enabled="true"
  else
    qq_enabled="false"
  fi

  if [[ "$qq_enabled" == "true" ]]; then
    if grep -Eq 'QQBot.*Connected|QQBot.*Connected to gateway' "$LOG_TMP"; then
      pass "QQ Bot gateway is connected"
    elif grep -Eq 'QQ startup failed|qq_missing_credentials|qq_connect_error' "$LOG_TMP"; then
      fail "QQ Bot is enabled but its gateway failed to start"
    else
      pending "QQ Bot is enabled; confirm its connected log and a real allowlisted DM"
    fi
  else
    pass "QQ Bot is disabled (safe default; no credentials or OpenID configured)"
    pending "QQ credentials and OpenID allowlist have not been provided"
  fi
fi

info ""
info "== Exposure =="
info "Ports 9119/9120 are published on 0.0.0.0: reachable from loopback, the LAN"
info "and Tailscale. Login is still required on both; do not add router port"
info "forwarding, UPnP or Tailscale Funnel."
lan_ip="$(ip -4 -o addr show | awk '$2 != "lo" && $2 !~ /^(tailscale|docker|br-|veth)/ {split($4,a,"/"); print a[1]; exit}')"
if [[ -n "$lan_ip" ]]; then
  code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://$lan_ip:9119/" 2>/dev/null || true)"
  info "LAN address ${lan_ip}:9119 answers with HTTP ${code:-none} (must be a login, not content)"
fi

info ""
info "== Manual checks that cannot be proven on this host =="
pending "Access from a second Tailscale device and the tailnet ACL boundary"
pending "Docker/Tailscale boot order after a reboot (see README recovery steps)"
pending "A real model reply after model/provider configuration"
if pgrep -x niri >/dev/null 2>&1 || pgrep -x sway >/dev/null 2>&1; then
  pending "Behavior after laptop suspend/resume; Docker restart policy is not a scheduler"
fi

info ""
info "Summary: $PASS passed, $FAIL failed, $PENDING pending/manual"
[[ "$FAIL" -eq 0 ]]
