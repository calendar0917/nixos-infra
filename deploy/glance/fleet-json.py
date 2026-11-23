#!/usr/bin/env python3
"""把 scripts/fleet-status --json 的结果用 HTTP 暴露给 Glance 的 custom-api widget。

为什么需要它：Glance 自带的 server-stats 只读本机（127.0.0.1 上的 /proc），
nixos / az / hw 的 uptime、负载、磁盘它拿不到。这台机器上唯一能查四台状态的
是 scripts/fleet-status，所以这里起一个只用 loopback 的小 HTTP 服务转发一下。

- 监听 127.0.0.1:8771，只给本机的 Glance / Homepage 和 cloudflared 用
- `/fleet.json` 返回整份结果；`/host/<name>.json` 返回单台拍平的对象，
  给 Homepage 的 customapi widget 用（它只能按 flat 字段做 mappings）
- 后台线程每 CACHE_SECONDS 秒跑一次 fleet-status 预热缓存；请求只读缓存，立即返回
- 缓存过期也不阻塞：只要手上有上一次的结果就先返回它（最多 STALE_SECONDS 秒）
- fleet-status 内部是 ssh，四个 host 最坏各 8s 超时，所以不能每个请求都同步跑

运行：systemctl --user（见同目录 README.md）
"""

import json
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "fleet-status"
CACHE_SECONDS = 120
STALE_SECONDS = 900
PORT = 8771

_lock = threading.Lock()
_cache: dict = {"at": 0.0, "body": None, "error": None}


def refresh() -> None:
    """Run fleet-status once and swap it into the cache."""
    try:
        out = subprocess.run(
            ["bash", str(SCRIPT), "--json"],
            capture_output=True,
            timeout=120,
            check=True,
        ).stdout
        json.loads(out)  # refuse to cache something Glance cannot parse
        with _lock:
            _cache.update(at=time.time(), body=out, error=None)
    except Exception as exc:  # noqa: BLE001 - report, never crash the server
        with _lock:
            _cache["error"] = f"{type(exc).__name__}: {exc}"


def collect() -> bytes:
    """Never block on ssh: serve the last result, refreshing it in the background."""
    with _lock:
        body, at = _cache["body"], _cache["at"]
    if body is not None:
        return body
    refresh()  # first request after boot has nothing to serve yet
    with _lock:
        if _cache["body"] is None:
            raise RuntimeError(_cache["error"] or "fleet-status produced no output")
        return _cache["body"]


def warmer() -> None:
    while True:
        refresh()
        time.sleep(CACHE_SECONDS)


DASH = "—"


def flatten(host: dict) -> dict:
    """One host as a flat object, with a dash for every field it cannot fill."""
    if not host.get("reachable"):
        return {"host": host.get("host", ""), "reachable": False,
                "up": DASH, "load": DASH, "disk": DASH, "failed": DASH}
    out = {"host": host.get("host", ""), "reachable": True}
    for key in ("os", "up", "load", "disk", "failed", "docker"):
        out[key] = host.get(key) or DASH
    return out


def one_host(name: str) -> bytes | None:
    doc = json.loads(collect())
    for host in doc.get("hosts", []):
        if host.get("host") == name:
            return json.dumps(flatten(host), ensure_ascii=False).encode()
    return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        path = self.path.split("?")[0]
        if path.startswith("/host/") and path.endswith(".json"):
            try:
                body = one_host(path[len("/host/"):-len(".json")])
            except Exception:  # noqa: BLE001
                body = None
            if body is None:
                self.send_error(404)
                return
            self._reply(200, body)
        elif path in ("/fleet.json", "/"):
            try:
                self._reply(200, collect())
            except Exception as exc:  # noqa: BLE001
                self._reply(503, json.dumps({"error": str(exc)}).encode())
        else:
            self.send_error(404)

    def _reply(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # quiet: journald already keeps the unit log
        pass


if __name__ == "__main__":
    threading.Thread(target=warmer, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()