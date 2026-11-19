#!/usr/bin/env python3
"""Static and transaction tests for the KOLOE ingress/DDNS stage.

The tests use a local fake Cloudflare API, fake Caddy/systemctl executables and
temporary runtime directories. They never contact Cloudflare, request a real
certificate, reload the real Caddy service or change a NixOS generation.

Run with the pinned environment:

    scripts/check-server-ingress
"""

from __future__ import annotations

import grp
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
ZONE_ID = "0123456789abcdef0123456789abcdef"
RECORD_NAME = "nixos.20050917.xyz"
PUBLIC_ADDRESS = "2606:4700:4700::1111"
OTHER_ADDRESS = "2606:4700:4700::2222"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ddns = load_module("cf_ddns_under_test", REPO / "hosts/nixos/scripts/cf-ddns.py")
ingress = load_module("ingressctl_under_test", REPO / "hosts/nixos/scripts/ingressctl.py")


class FakeCloudflareState:
    def __init__(
        self,
        records: list[dict] | None = None,
        *,
        list_status: int = 200,
        write_status: int = 200,
        delay: float = 0.0,
        expected_token: str | None = None,
    ) -> None:
        self.records = [dict(record) for record in (records or [])]
        self.list_status = list_status
        self.write_status = write_status
        self.delay = delay
        self.expected_token = expected_token
        self.calls: list[tuple[str, object]] = []
        self._next_id = 1

    @property
    def writes(self) -> list[tuple[str, object]]:
        return [call for call in self.calls if call[0] in {"POST", "PATCH"}]


def start_fake_cloudflare(testcase: unittest.TestCase, state: FakeCloudflareState) -> str:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: object) -> None:  # noqa: A003
            return

        def _json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode("utf-8")
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except BrokenPipeError:
                pass

        def _authorized(self) -> bool:
            if state.expected_token is None:
                return True
            return (
                self.headers.get("Authorization")
                == f"Bearer {state.expected_token}"
            )

        def _record_id(self, parsed: urllib.parse.ParseResult) -> str | None:
            parts = parsed.path.strip("/").split("/")
            # client/v4/zones/<zone>/dns_records/<id>
            if len(parts) >= 6 and parts[4] == "dns_records":
                return parts[5]
            return None

        def _records_path(self, parsed: urllib.parse.ParseResult) -> bool:
            parts = parsed.path.strip("/").split("/")
            return (
                len(parts) >= 5
                and parts[0:2] == ["client", "v4"]
                and parts[2] == "zones"
                and parts[4] == "dns_records"
            )

        def do_GET(self) -> None:  # noqa: N802
            if state.delay:
                time.sleep(state.delay)
            parsed = urllib.parse.urlparse(self.path)
            state.calls.append(("GET", parsed.path))
            if not self._authorized():
                self._json(403, {"success": False, "errors": [{"message": "auth"}]})
                return
            if not self._records_path(parsed):
                self._json(404, {"success": False, "errors": [{"message": "not found"}]})
                return
            if state.list_status != 200:
                self._json(
                    state.list_status,
                    {"success": False, "errors": [{"message": "fake list failure"}]},
                )
                return
            query = urllib.parse.parse_qs(parsed.query)
            name = (query.get("name") or [None])[0]
            records = [record for record in state.records if record.get("name") == name]
            self._json(200, {"success": True, "result": records})

        def do_POST(self) -> None:  # noqa: N802
            if state.delay:
                time.sleep(state.delay)
            parsed = urllib.parse.urlparse(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            state.calls.append(("POST", body))
            if not self._authorized():
                self._json(403, {"success": False, "errors": [{"message": "auth"}]})
                return
            if not self._records_path(parsed):
                self._json(404, {"success": False, "errors": [{"message": "not found"}]})
                return
            if state.write_status != 200:
                self._json(
                    state.write_status,
                    {"success": False, "errors": [{"message": "fake write failure"}]},
                )
                return
            record = {
                "id": f"rec-{state._next_id}",
                "type": body["type"],
                "name": body["name"],
                "content": body["content"],
                "ttl": body.get("ttl", 1),
                "proxied": body.get("proxied", False),
            }
            state._next_id += 1
            state.records.append(record)
            self._json(200, {"success": True, "result": record})

        def do_PATCH(self) -> None:  # noqa: N802
            if state.delay:
                time.sleep(state.delay)
            parsed = urllib.parse.urlparse(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            state.calls.append(("PATCH", body))
            if not self._authorized():
                self._json(403, {"success": False, "errors": [{"message": "auth"}]})
                return
            record_id = self._record_id(parsed)
            if record_id is None:
                self._json(404, {"success": False, "errors": [{"message": "not found"}]})
                return
            if state.write_status != 200:
                self._json(
                    state.write_status,
                    {"success": False, "errors": [{"message": "fake write failure"}]},
                )
                return
            for record in state.records:
                if record.get("id") == record_id:
                    record.update(body)
                    self._json(200, {"success": True, "result": record})
                    return
            self._json(404, {"success": False, "errors": [{"message": "not found"}]})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def stop() -> None:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    testcase.addCleanup(stop)
    return f"http://127.0.0.1:{server.server_address[1]}/client/v4"


class ServerIngressTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        expression = f"""
        let
          flake = builtins.getFlake "git+file:{REPO}";
          nixos = flake.nixosConfigurations.nixos.config;
          main = flake.nixosConfigurations.main.config;
          acme = nixos.security.acme.certs."20050917.xyz";
          ddnsService = nixos.systemd.services."cloudflare-ddns";
          ddnsTimer = nixos.systemd.timers."cloudflare-ddns";
        in {{
          caddyEnable = nixos.services.caddy.enable;
          caddyEnableReload = nixos.services.caddy.enableReload;
          caddyExtraConfig = nixos.services.caddy.extraConfig;
          caddyGlobalConfig = nixos.services.caddy.globalConfig;
          caddyUser = nixos.services.caddy.user;
          caddyGroup = nixos.services.caddy.group;
          caddyVirtualHosts = nixos.services.caddy.virtualHosts;
          caddyInSystemPackages = builtins.any
            (package: (package.pname or "") == "caddy")
            nixos.environment.systemPackages;
          firewallTcpPorts = nixos.networking.firewall.allowedTCPPorts;
          firewallUdpPorts = nixos.networking.firewall.allowedUDPPorts;
          tmpfiles = nixos.systemd.tmpfiles.rules;
          ddnsServiceType = ddnsService.serviceConfig.Type;
          ddnsExecStart = ddnsService.serviceConfig.ExecStart;
          ddnsLoadCredential = ddnsService.serviceConfig.LoadCredential;
          ddnsEnvironmentFile = ddnsService.serviceConfig.EnvironmentFile;
          ddnsDynamicUser = ddnsService.serviceConfig.DynamicUser;
          ddnsAddressFamilies = ddnsService.serviceConfig.RestrictAddressFamilies;
          ddnsTimerWantedBy = ddnsTimer.wantedBy;
          ddnsTimerOnBoot = ddnsTimer.timerConfig.OnBootSec;
          ddnsTimerEvery = ddnsTimer.timerConfig.OnUnitActiveSec;
          ddnsTimerRandom = ddnsTimer.timerConfig.RandomizedDelaySec;
          ddnsTimerUnit = ddnsTimer.timerConfig.Unit;
          acmeDomain = acme.domain;
          acmeProvider = acme.dnsProvider;
          acmeGroup = acme.group;
          acmeCredentialFiles = acme.credentialFiles;
          acmeReloadServices = acme.reloadServices;
          acmeAuthoritativePropagation = acme.dnsAuthoritativePropagationCheck;
          acmeRecursivePropagation = acme.dnsRecursivePropagationCheck;
          acmeEmail = acme.email;
          mainCaddyEnable = main.services.caddy.enable;
          mainFirewallTcpPorts = main.networking.firewall.allowedTCPPorts;
          mainHasDdns = builtins.hasAttr "cloudflare-ddns" main.systemd.services;
          mainAcmeCerts = builtins.attrNames main.security.acme.certs;
          dockerEnable = nixos.virtualisation.docker.enable;
          mihomoEnable = nixos.services.mihomo.enable;
          tailscaleEnable = nixos.services.tailscale.enable;
          networkManagerEnable = nixos.networking.networkmanager.enable;
          mainDockerEnable = main.virtualisation.docker.enable;
        }}
        """
        result = subprocess.run(
            ["nix", "eval", "--json", "--impure", "--expr", expression],
            cwd=REPO,
            capture_output=True,
            text=True,
            timeout=240,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                "nix eval failed:\n" + (result.stderr or result.stdout).strip()
            )
        cls.nix = json.loads(result.stdout)

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="server-ingress-test.")
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    @staticmethod
    def _flatten(value: object) -> str:
        if isinstance(value, str):
            return value
        if isinstance(value, list):
            return " ".join(str(item) for item in value)
        return str(value)

    # -------------------------------------------------------------- addresses

    @staticmethod
    def _routes(primary: str, primary_metric: int, secondary: str, secondary_metric: int):
        return [
            {"dst": "default", "gateway": "fe80::1", "dev": "docker0", "metric": 1},
            {"dst": "default", "gateway": "fe80::1", "dev": "tailscale0", "metric": 2},
            {
                "dst": "default",
                "gateway": "fe80::1",
                "dev": primary,
                "metric": primary_metric,
                "pref": "medium",
            },
            {
                "dst": "default",
                "gateway": "fe80::1",
                "dev": secondary,
                "metric": secondary_metric,
                "pref": "medium",
            },
        ]

    @staticmethod
    def _addresses(interface: str, entries: list[dict]) -> list[dict]:
        return [{"ifname": interface, "addr_info": entries}]

    def test_selects_wired_or_wifi_uplink_by_metric(self) -> None:
        wired = self._routes("enp1s0", 100, "wlp2s0", 600)
        wifi = self._routes("wlp2s0", 100, "enp1s0", 600)
        self.assertEqual(ddns.select_uplink(wired), "enp1s0")
        self.assertEqual(ddns.select_uplink(wifi), "wlp2s0")

    def test_equal_physical_metrics_are_ambiguous(self) -> None:
        routes = self._routes("enp1s0", 100, "wlp2s0", 100)
        with self.assertRaises(ddns.AddressSelectionError):
            ddns.select_uplink(routes)

    def test_no_physical_default_route_is_not_an_update(self) -> None:
        routes = [
            {"dst": "default", "dev": "docker0", "metric": 1},
            {"dst": "default", "dev": "tailscale0", "metric": 2},
        ]
        self.assertIsNone(ddns.select_uplink(routes))

    def test_filters_temporary_deprecated_ula_and_link_local(self) -> None:
        entries = [
            {"family": "inet6", "local": PUBLIC_ADDRESS, "prefixlen": 64, "scope": "global"},
            {
                "family": "inet6",
                "local": OTHER_ADDRESS,
                "prefixlen": 64,
                "scope": "global",
                "temporary": True,
            },
            {
                "family": "inet6",
                "local": "2606:4700:4700::3333",
                "prefixlen": 64,
                "scope": "global",
                "flags": ["deprecated"],
            },
            {"family": "inet6", "local": "fd12:3456::1", "prefixlen": 64, "scope": "global"},
            {"family": "inet6", "local": "fe80::1", "prefixlen": 64, "scope": "link"},
            {"family": "inet6", "local": "ff02::1", "prefixlen": 64, "scope": "global"},
            {"family": "inet6", "local": "::1", "prefixlen": 128, "scope": "host"},
        ]
        self.assertEqual(
            ddns.select_ipv6(self._addresses("enp1s0", entries), "enp1s0"),
            PUBLIC_ADDRESS,
        )

    def test_only_temporary_or_non_global_is_no_address(self) -> None:
        entries = [
            {
                "family": "inet6",
                "local": PUBLIC_ADDRESS,
                "prefixlen": 64,
                "scope": "global",
                "temporary": True,
            },
            {"family": "inet6", "local": "fd12:3456::1", "prefixlen": 64, "scope": "global"},
            {"family": "inet6", "local": "fe80::1", "prefixlen": 64, "scope": "link"},
        ]
        self.assertIsNone(
            ddns.select_ipv6(self._addresses("enp1s0", entries), "enp1s0")
        )

    def test_multiple_stable_addresses_are_ambiguous(self) -> None:
        entries = [
            {"family": "inet6", "local": PUBLIC_ADDRESS, "prefixlen": 64, "scope": "global"},
            {"family": "inet6", "local": OTHER_ADDRESS, "prefixlen": 64, "scope": "global"},
        ]
        with self.assertRaises(ddns.AddressSelectionError):
            ddns.select_ipv6(self._addresses("enp1s0", entries), "enp1s0")

    def test_get_ipv6_uses_route_device(self) -> None:
        def fake_ip(arguments: list[str], ip_bin: str = "ip"):
            del ip_bin
            if arguments[:2] == ["route", "show"]:
                return self._routes("enp1s0", 100, "wlp2s0", 600)
            return self._addresses(
                "enp1s0",
                [
                    {
                        "family": "inet6",
                        "local": PUBLIC_ADDRESS,
                        "prefixlen": 64,
                        "scope": "global",
                    }
                ],
            )

        with mock.patch.object(ddns, "run_ip_json", side_effect=fake_ip):
            interface, address = ddns.get_ipv6()
        self.assertEqual(interface, "enp1s0")
        self.assertEqual(address, PUBLIC_ADDRESS)

    # -------------------------------------------------------------- credentials

    def _credential_dir(self) -> Path:
        directory = Path(tempfile.mkdtemp(prefix="cloudflare-", dir=self.root))
        (directory / "token").write_text("test-token-not-real\n", encoding="utf-8")
        (directory / "zone-id").write_text(ZONE_ID + "\n", encoding="utf-8")
        os.chmod(directory / "token", 0o600)
        os.chmod(directory / "zone-id", 0o600)
        return directory

    def test_credentials_and_zone_id_are_read_from_files(self) -> None:
        credentials = ddns.load_credentials(self._credential_dir())
        self.assertEqual(credentials.token, "test-token-not-real")
        self.assertEqual(credentials.zone_id, ZONE_ID)

    def test_missing_or_invalid_credentials_are_rejected(self) -> None:
        directory = self._credential_dir()
        (directory / "token").unlink()
        with self.assertRaises(ddns.CredentialError):
            ddns.load_credentials(directory)

        directory = self._credential_dir()
        (directory / "zone-id").write_text("not-a-zone-id\n", encoding="utf-8")
        with self.assertRaises(ddns.CredentialError):
            ddns.load_credentials(directory)

    def test_proxy_override_is_restricted_to_loopback_mihomo(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CF_DDNS_PROXY", None)
            self.assertIsNone(ddns.load_proxy())
        with mock.patch.dict(
            os.environ, {"CF_DDNS_PROXY": "http://127.0.0.1:7897"}, clear=False
        ):
            self.assertEqual(ddns.load_proxy(), "http://127.0.0.1:7897")
        with mock.patch.dict(
            os.environ, {"CF_DDNS_PROXY": "http://192.0.2.1:7897"}, clear=False
        ):
            with self.assertRaises(ddns.CredentialError):
                ddns.load_proxy()

    # -------------------------------------------------------------- Cloudflare

    def _client(
        self,
        state: FakeCloudflareState,
        *,
        token: str = "test-token-not-real",
        timeout: float = 1.0,
    ) -> tuple[ddns.CloudflareClient, FakeCloudflareState]:
        state.expected_token = token
        base = start_fake_cloudflare(self, state)
        return (
            ddns.CloudflareClient(
                token,
                ZONE_ID,
                api_base=base,
                timeout=timeout,
            ),
            state,
        )

    @staticmethod
    def _record(content: str = OTHER_ADDRESS, **extra: object) -> dict:
        record = {
            "id": "rec-existing",
            "type": "AAAA",
            "name": RECORD_NAME,
            "content": content,
            "ttl": 120,
            "proxied": False,
        }
        record.update(extra)
        return record

    def test_creates_aaaa_when_absent(self) -> None:
        client, state = self._client(FakeCloudflareState())
        result = ddns.reconcile(client, RECORD_NAME, PUBLIC_ADDRESS)
        self.assertEqual(result.action, "created")
        self.assertEqual(len(state.writes), 1)
        self.assertEqual(state.writes[0][0], "POST")
        self.assertEqual(state.records[0]["content"], PUBLIC_ADDRESS)
        self.assertFalse(state.records[0]["proxied"])

    def test_unchanged_address_does_not_write(self) -> None:
        client, state = self._client(
            FakeCloudflareState([self._record(PUBLIC_ADDRESS)])
        )
        result = ddns.reconcile(client, RECORD_NAME, PUBLIC_ADDRESS)
        self.assertEqual(result.action, "unchanged")
        self.assertEqual(state.writes, [])

    def test_changed_address_uses_patch(self) -> None:
        client, state = self._client(
            FakeCloudflareState([self._record(OTHER_ADDRESS)])
        )
        result = ddns.reconcile(client, RECORD_NAME, PUBLIC_ADDRESS)
        self.assertEqual(result.action, "updated")
        self.assertEqual([call[0] for call in state.writes], ["PATCH"])
        self.assertEqual(state.records[0]["content"], PUBLIC_ADDRESS)

    def test_dry_run_never_writes(self) -> None:
        client, state = self._client(FakeCloudflareState())
        result = ddns.reconcile(client, RECORD_NAME, PUBLIC_ADDRESS, dry_run=True)
        self.assertEqual(result.action, "would-create")
        self.assertEqual(state.writes, [])
        self.assertEqual(state.records, [])

    def test_multiple_aaaa_records_are_a_conflict(self) -> None:
        client, state = self._client(
            FakeCloudflareState(
                [self._record(OTHER_ADDRESS), self._record(PUBLIC_ADDRESS, id="rec-2")]
            )
        )
        with self.assertRaises(ddns.ConflictError):
            ddns.reconcile(client, RECORD_NAME, PUBLIC_ADDRESS)
        self.assertEqual(state.writes, [])

    def test_cname_is_a_conflict(self) -> None:
        client, state = self._client(
            FakeCloudflareState(
                [
                    {
                        "id": "rec-cname",
                        "type": "CNAME",
                        "name": RECORD_NAME,
                        "content": "example.invalid",
                        "proxied": False,
                    }
                ]
            )
        )
        with self.assertRaises(ddns.ConflictError):
            ddns.reconcile(client, RECORD_NAME, PUBLIC_ADDRESS)
        self.assertEqual(state.writes, [])

    def test_proxied_aaaa_is_a_conflict(self) -> None:
        client, state = self._client(
            FakeCloudflareState([self._record(OTHER_ADDRESS, proxied=True)])
        )
        with self.assertRaises(ddns.ConflictError):
            ddns.reconcile(client, RECORD_NAME, PUBLIC_ADDRESS)
        self.assertEqual(state.writes, [])

    def test_rate_limit_and_server_errors_do_not_write(self) -> None:
        for status in (429, 500, 503):
            with self.subTest(status=status):
                client, state = self._client(FakeCloudflareState(list_status=status))
                with self.assertRaises(ddns.CloudflareError):
                    ddns.reconcile(client, RECORD_NAME, PUBLIC_ADDRESS)
                self.assertEqual(state.writes, [])

    def test_timeout_is_reported_without_writing(self) -> None:
        client, state = self._client(
            FakeCloudflareState(delay=0.5),
            timeout=0.1,
        )
        with self.assertRaises(ddns.CloudflareError) as caught:
            ddns.reconcile(client, RECORD_NAME, PUBLIC_ADDRESS)
        self.assertIn("timed out", str(caught.exception))
        self.assertEqual(state.writes, [])

    def test_token_never_appears_in_failure_logs(self) -> None:
        token = "secret-token-must-not-leak"
        client, _ = self._client(
            FakeCloudflareState(list_status=500),
            token=token,
        )
        credentials = ddns.Credentials(token=token, zone_id=ZONE_ID)
        with mock.patch.object(ddns, "get_ipv6", return_value=("enp1s0", PUBLIC_ADDRESS)), \
             mock.patch.object(ddns, "load_credentials", return_value=credentials), \
             mock.patch.object(ddns, "load_proxy", return_value=None), \
             mock.patch.object(ddns, "CloudflareClient", return_value=client):
            with self.assertLogs("cloudflare-ddns", level="ERROR") as captured:
                self.assertEqual(ddns.main([]), 1)
        self.assertNotIn(token, "\n".join(captured.output))

    # ---------------------------------------------------------------- CLI/static

    def test_render_site_is_strict_and_uses_loopback(self) -> None:
        text = ingress.render_site("app", 8080)
        self.assertIn("app.20050917.xyz {", text)
        self.assertIn(
            "tls /var/lib/acme/20050917.xyz/fullchain.pem "
            "/var/lib/acme/20050917.xyz/key.pem",
            text,
        )
        self.assertIn("reverse_proxy 127.0.0.1:8080", text)
        self.assertIn("encode zstd gzip", text)
        self.assertNotIn("http://", text)
        self.assertNotIn("https://", text)

    def test_invalid_names_and_ports_are_rejected(self) -> None:
        for name in ("app", "my-app", "a1"):
            self.assertEqual(ingress.validate_name(name), name)
        for name in ("", "App", "app.example", "-app", "app-", "a" * 64, "a_b", "../x"):
            with self.subTest(name=name):
                with self.assertRaises(ingress.IngressError):
                    ingress.validate_name(name)

        self.assertEqual(ingress.validate_port(1024), 1024)
        self.assertEqual(ingress.validate_port("65535"), 65535)
        for port in (22, 80, 443, 1023, 2019, 2375, 2376, 5432, 7897, 9090, 65536):
            with self.subTest(port=port):
                with self.assertRaises(ingress.IngressError):
                    ingress.validate_port(port)

    def test_reserved_name_cannot_be_published(self) -> None:
        with self.assertRaises(ingress.IngressError):
            ingress.validate_name("nixos")
        with self.assertRaises(ingress.IngressError):
            ingress.render_site("nixos", 8080)

    def test_root_is_required_for_mutating_commands(self) -> None:
        with mock.patch.object(ingress.os, "geteuid", return_value=1000):
            with self.assertRaises(ingress.IngressError):
                ingress.require_root()
        with mock.patch.object(ingress.os, "geteuid", return_value=0):
            ingress.require_root()

    # ---------------------------------------------------------------- fixtures

    def _make_manager(self, *, issued: bool = True) -> tuple[ingress.IngressManager, dict]:
        sites = self.root / "sites"
        sites.mkdir()
        acme = self.root / "acme"
        acme.mkdir()
        os.chmod(self.root, 0o750)
        os.chmod(sites, 0o750)
        os.chmod(acme, 0o750)
        for filename in ("fullchain.pem", "key.pem"):
            path = acme / filename
            path.write_text("test certificate placeholder\n", encoding="utf-8")
            os.chmod(path, 0o640)
        if issued:
            (acme / "acme-success").write_text("ok\n", encoding="utf-8")

        caddy_config = self.root / "Caddyfile"
        caddy_config.write_text("import *\n", encoding="utf-8")

        caddy_log = self.root / "caddy.log"
        caddy = self.root / "fake-caddy"
        caddy.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "with open(os.environ['FAKE_CADDY_LOG'], 'a') as handle:\n"
            "    handle.write(' '.join(sys.argv[1:]) + '\\n')\n"
            "if os.environ.get('FAKE_CADDY_FAIL') == '1':\n"
            "    print('fake caddy rejected configuration', file=sys.stderr)\n"
            "    sys.exit(1)\n"
            "sys.exit(0)\n",
            encoding="utf-8",
        )
        os.chmod(caddy, 0o755)

        systemctl_log = self.root / "systemctl.log"
        systemctl = self.root / "fake-systemctl"
        systemctl.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "with open(os.environ['FAKE_SYSTEMCTL_LOG'], 'a') as handle:\n"
            "    handle.write(' '.join(sys.argv[1:]) + '\\n')\n"
            "if os.environ.get('FAKE_SYSTEMCTL_FAIL') == '1':\n"
            "    print('fake systemctl reload failed', file=sys.stderr)\n"
            "    sys.exit(1)\n"
            "if sys.argv[1:] == ['is-active', 'caddy']:\n"
            "    print('active')\n"
            "sys.exit(0)\n",
            encoding="utf-8",
        )
        os.chmod(systemctl, 0o755)

        environment = {
            "FAKE_CADDY_LOG": str(caddy_log),
            "FAKE_SYSTEMCTL_LOG": str(systemctl_log),
        }
        patcher = mock.patch.dict(os.environ, environment, clear=False)
        patcher.start()
        self.addCleanup(patcher.stop)

        group_name = grp.getgrgid(os.getgid()).gr_name
        manager = ingress.IngressManager(
            sites_dir=sites,
            caddy_config=caddy_config,
            acme_dir=acme,
            caddy_bin=str(caddy),
            systemctl_bin=str(systemctl),
            caddy_group=group_name,
        )
        return manager, {
            "sites": sites,
            "acme": acme,
            "caddy_log": caddy_log,
            "systemctl_log": systemctl_log,
        }

    # -------------------------------------------------------------- transactions

    def test_publish_writes_runtime_file_and_reloads(self) -> None:
        manager, paths = self._make_manager()
        route = manager.publish("app", 8080)
        target = paths["sites"] / "app.caddy"
        self.assertEqual(route.path, target)
        self.assertTrue(target.is_file())
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
        self.assertIn("app.20050917.xyz", target.read_text(encoding="utf-8"))
        self.assertIn("validate", paths["caddy_log"].read_text(encoding="utf-8"))
        self.assertIn("reload caddy", paths["systemctl_log"].read_text(encoding="utf-8"))
        self.assertEqual([item.name for item in manager.list_sites()], ["app"])

    def test_publish_refuses_overwrite_without_force(self) -> None:
        manager, paths = self._make_manager()
        target = paths["sites"] / "app.caddy"
        target.write_text("old route\n", encoding="utf-8")
        with self.assertRaises(ingress.IngressError):
            manager.publish("app", 8080)
        self.assertEqual(target.read_text(encoding="utf-8"), "old route\n")

    def test_publish_force_replaces_existing_route(self) -> None:
        manager, paths = self._make_manager()
        target = paths["sites"] / "app.caddy"
        target.write_text("old route\n", encoding="utf-8")
        manager.publish("app", 8081, force=True)
        self.assertIn("reverse_proxy 127.0.0.1:8081", target.read_text(encoding="utf-8"))

    def test_publish_validation_failure_restores_old_file(self) -> None:
        manager, paths = self._make_manager()
        target = paths["sites"] / "app.caddy"
        target.write_text("old route\n", encoding="utf-8")
        os.environ["FAKE_CADDY_FAIL"] = "1"
        self.addCleanup(os.environ.pop, "FAKE_CADDY_FAIL", None)
        with self.assertRaises(ingress.IngressError):
            manager.publish("app", 8080, force=True)
        self.assertEqual(target.read_text(encoding="utf-8"), "old route\n")
        self.assertFalse(paths["systemctl_log"].exists())

    def test_publish_reload_failure_restores_old_file(self) -> None:
        manager, paths = self._make_manager()
        target = paths["sites"] / "app.caddy"
        target.write_text("old route\n", encoding="utf-8")
        os.environ["FAKE_SYSTEMCTL_FAIL"] = "1"
        self.addCleanup(os.environ.pop, "FAKE_SYSTEMCTL_FAIL", None)
        with self.assertRaises(ingress.IngressError):
            manager.publish("app", 8080, force=True)
        self.assertEqual(target.read_text(encoding="utf-8"), "old route\n")
        reloads = paths["systemctl_log"].read_text(encoding="utf-8").splitlines()
        self.assertGreaterEqual(len(reloads), 2)

    def test_publish_reload_failure_removes_new_file(self) -> None:
        manager, paths = self._make_manager()
        os.environ["FAKE_SYSTEMCTL_FAIL"] = "1"
        self.addCleanup(os.environ.pop, "FAKE_SYSTEMCTL_FAIL", None)
        with self.assertRaises(ingress.IngressError):
            manager.publish("app", 8080)
        self.assertFalse((paths["sites"] / "app.caddy").exists())

    def test_remove_deletes_only_that_route(self) -> None:
        manager, paths = self._make_manager()
        manager.publish("app", 8080)
        manager.publish("git", 8081)
        manager.remove("app")
        self.assertFalse((paths["sites"] / "app.caddy").exists())
        self.assertTrue((paths["sites"] / "git.caddy").exists())

    def test_remove_validation_failure_restores_route(self) -> None:
        manager, paths = self._make_manager()
        target = paths["sites"] / "app.caddy"
        target.write_text("old route\n", encoding="utf-8")
        os.environ["FAKE_CADDY_FAIL"] = "1"
        self.addCleanup(os.environ.pop, "FAKE_CADDY_FAIL", None)
        with self.assertRaises(ingress.IngressError):
            manager.remove("app")
        self.assertEqual(target.read_text(encoding="utf-8"), "old route\n")

    def test_remove_missing_route_is_an_error(self) -> None:
        manager, _ = self._make_manager()
        with self.assertRaises(ingress.IngressError):
            manager.remove("missing")

    def test_certificate_must_be_issued_before_publish(self) -> None:
        manager, paths = self._make_manager(issued=False)
        with self.assertRaises(ingress.IngressError):
            manager.publish("app", 8080)
        self.assertFalse((paths["sites"] / "app.caddy").exists())

    def test_certificate_must_be_readable_by_caddy_group(self) -> None:
        manager, paths = self._make_manager()
        os.chmod(paths["acme"] / "key.pem", 0o600)
        with self.assertRaises(ingress.IngressError):
            manager.publish("app", 8080)
        self.assertFalse((paths["sites"] / "app.caddy").exists())

    def test_symlink_route_target_is_rejected(self) -> None:
        manager, paths = self._make_manager()
        outside = self.root / "outside.caddy"
        outside.write_text("outside\n", encoding="utf-8")
        (paths["sites"] / "app.caddy").symlink_to(outside)
        with self.assertRaises(ingress.IngressError):
            manager.publish("app", 8080, force=True)
        self.assertEqual(outside.read_text(encoding="utf-8"), "outside\n")

    # ------------------------------------------------------------- Caddy parser

    def test_generated_fragment_parses_with_caddy(self) -> None:
        caddy_bin = os.environ.get("INGRESSCTL_TEST_CADDY") or shutil.which("caddy")
        if not caddy_bin:
            self.skipTest("caddy binary not available; scripts/check-server-ingress provides it")
        fragment = self.root / "app.caddy"
        fragment.write_text(ingress.render_site("app", 8080), encoding="utf-8")
        completed = subprocess.run(
            [caddy_bin, "adapt", "--config", str(fragment), "--adapter", "caddyfile"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        adapted = json.loads(completed.stdout)
        self.assertIn("apps", adapted)

    # ----------------------------------------------------------------- NixOS

    def test_nixos_caddy_uses_runtime_import(self) -> None:
        self.assertTrue(self.nix["caddyEnable"])
        self.assertTrue(self.nix["caddyEnableReload"])
        self.assertEqual(self.nix["caddyVirtualHosts"], {})
        self.assertIn(
            "import /etc/caddy/sites-enabled/*.caddy",
            self.nix["caddyExtraConfig"],
        )
        self.assertIn("127.0.0.1:2080", self.nix["caddyExtraConfig"])
        self.assertIn("bind 127.0.0.1", self.nix["caddyExtraConfig"])
        self.assertIn("admin 127.0.0.1:2019", self.nix["caddyGlobalConfig"])
        self.assertEqual(self.nix["caddyUser"], "caddy")
        self.assertEqual(self.nix["caddyGroup"], "caddy")
        self.assertTrue(self.nix["caddyInSystemPackages"])

    def test_nixos_ddns_service_and_timer(self) -> None:
        self.assertEqual(self.nix["ddnsServiceType"], "oneshot")
        self.assertTrue(self.nix["ddnsDynamicUser"])
        self.assertIn("AF_NETLINK", self.nix["ddnsAddressFamilies"])
        self.assertEqual(self.nix["ddnsTimerOnBoot"], "2min")
        self.assertEqual(self.nix["ddnsTimerEvery"], "5min")
        self.assertEqual(self.nix["ddnsTimerRandom"], "45s")
        self.assertEqual(self.nix["ddnsTimerUnit"], "cloudflare-ddns.service")
        self.assertIn("timers.target", self.nix["ddnsTimerWantedBy"])
        self.assertIn("token:/etc/cloudflare/token", self.nix["ddnsLoadCredential"])
        self.assertIn("zone-id:/etc/cloudflare/zone-id", self.nix["ddnsLoadCredential"])
        self.assertIn("-/etc/cloudflare/ddns.env", self.nix["ddnsEnvironmentFile"])
        self.assertIn("cf-ddns.py", self._flatten(self.nix["ddnsExecStart"]))

    def test_nixos_acme_wildcard_certificate(self) -> None:
        self.assertEqual(self.nix["acmeDomain"], "*.20050917.xyz")
        self.assertEqual(self.nix["acmeProvider"], "cloudflare")
        self.assertEqual(self.nix["acmeGroup"], "caddy")
        self.assertEqual(
            self.nix["acmeCredentialFiles"],
            {"CLOUDFLARE_DNS_API_TOKEN_FILE": "/etc/cloudflare/token"},
        )
        self.assertIn("caddy.service", self.nix["acmeReloadServices"])
        self.assertTrue(self.nix["acmeAuthoritativePropagation"])
        self.assertTrue(self.nix["acmeRecursivePropagation"])
        self.assertIsNone(self.nix["acmeEmail"])

    def test_firewall_opens_only_http_https_tcp(self) -> None:
        ports = set(self.nix["firewallTcpPorts"])
        self.assertIn(80, ports)
        self.assertIn(443, ports)
        self.assertLessEqual(ports, {22, 80, 443})
        for port in (7897, 9090, 2375, 2376, 5432, 18080):
            self.assertNotIn(port, ports)
        self.assertNotIn(443, self.nix["firewallUdpPorts"])
        for port in (7897, 9090, 2375, 2376):
            self.assertNotIn(port, self.nix["firewallUdpPorts"])

    def test_runtime_directories_are_created_outside_store(self) -> None:
        rules = self.nix["tmpfiles"]
        self.assertTrue(
            any(
                "/etc/cloudflare 0700 root root" in rule
                for rule in rules
                if isinstance(rule, str)
            )
        )
        self.assertTrue(
            any(
                "/etc/caddy/sites-enabled" in rule
                for rule in rules
                if isinstance(rule, str)
            )
        )

    def test_existing_services_are_not_rewritten(self) -> None:
        self.assertTrue(self.nix["dockerEnable"])
        self.assertTrue(self.nix["mihomoEnable"])
        self.assertTrue(self.nix["tailscaleEnable"])
        self.assertTrue(self.nix["networkManagerEnable"])
        self.assertTrue(self.nix["mainDockerEnable"])

    def test_main_host_behavior_is_unchanged(self) -> None:
        self.assertFalse(self.nix["mainCaddyEnable"])
        self.assertFalse(self.nix["mainHasDdns"])
        self.assertNotIn(80, self.nix["mainFirewallTcpPorts"])
        self.assertNotIn(443, self.nix["mainFirewallTcpPorts"])
        self.assertNotIn("20050917.xyz", self.nix["mainAcmeCerts"])

    def test_sources_and_docs_are_present(self) -> None:
        for path in (
            REPO / "hosts/nixos/ddns.nix",
            REPO / "hosts/nixos/ingress.nix",
            REPO / "hosts/nixos/scripts/cf-ddns.py",
            REPO / "hosts/nixos/scripts/ingressctl.py",
            REPO / "docs/SERVER_INGRESS.md",
            REPO / "scripts/check-server-ingress",
        ):
            self.assertTrue(path.is_file(), path)
            self.assertGreater(path.stat().st_size, 0)

        ingress_source = (REPO / "hosts/nixos/ingress.nix").read_text(encoding="utf-8")
        self.assertNotIn("virtualHosts", ingress_source)
        self.assertIn("/etc/caddy/sites-enabled", ingress_source)
        self.assertIn("/etc/cloudflare/token", ingress_source)
        self.assertNotIn("CLOUDFLARE_DNS_API_TOKEN =", ingress_source)

        readme = (REPO / "README.md").read_text(encoding="utf-8")
        agents = (REPO / "AGENTS.md").read_text(encoding="utf-8")
        docs = (REPO / "docs/SERVER_INGRESS.md").read_text(encoding="utf-8")
        self.assertIn("ingressctl", readme)
        self.assertIn("ingressctl", agents)
        self.assertIn("ingressctl publish", docs)
        self.assertIn("nixos-rebuild", docs)
        self.assertIn("DNS only", docs)
        self.assertIn("SSH", docs)


if __name__ == "__main__":
    unittest.main(verbosity=2)
