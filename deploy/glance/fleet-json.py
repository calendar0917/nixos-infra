#!/usr/bin/env python3
"""把 scripts/fleet-status --json 的结果用 HTTP 暴露给 Glance 的 custom-api widget。

为什么需要它：Glance 自带的 server-stats 只读本机（127.0.0.1 上的 /proc），
nixos / az / hw 的 uptime、负载、磁盘它拿不到。这台机器上唯一能查四台状态的
是 scripts/fleet-status，所以这里起一个只用 loopback 的小 HTTP 服务转发一下。

- 监听 127.0.0.1:8771，只给本机的 Glance 和 cloudflared 用
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


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path.split("?")[0] not in ("/fleet.json", "/"):
            self.send_error(404)
            return
        try:
            body = collect()
        except Exception as exc:  # noqa: BLE001
            body = json.dumps({"error": str(exc)}).encode()
            self.send_response(503)
        else:
            self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # quiet: journald already keeps the unit log
        pass


if __name__ == "__main__":
    threading.Thread(target=warmer, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()