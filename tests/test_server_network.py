#!/usr/bin/env python3
"""Headless regression checks for campus-login, proxyctl and proxy.nix.

The tests never contact a real campus portal, download a real subscription or
touch the running Mihomo service. They use temporary state, a local fake HTTP
API and a stub `mihomo -t` executable.

Run with the pinned test environment (no system activation or real network):

    scripts/check-server-network
"""

import base64
import contextlib
import importlib.util
import io
import json
import logging
import os
import stat
import sys
import tempfile
import textwrap
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


campus = load_module("campus_login_under_test", REPO / "hosts/nixos/scripts/campus-login.py")
proxy = load_module("proxyctl_under_test", REPO / "hosts/nixos/scripts/proxyctl.py")


GOOD_PROFILE = """\
mixed-port: 0
allow-lan: true
bind-address: 0.0.0.0
external-controller: 0.0.0.0:9090
secret: input-secret
port: 7890
socks-port: 7891
redir-port: 7892
tproxy-port: 7893
external-ui: dashboard
tls:
  certificate: /home/calendar/cert.pem
tun:
  enable: true
dns:
  listen: 0.0.0.0:53
  nameserver:
    - 1.1.1.1
proxies:
  - name: on
    type: ss
    server: 192.0.2.10
    port: 443
    cipher: aes-128-gcm
    password: 01234567
proxy-groups:
  - name: 手动 选择/组
    type: select
    proxies:
      - on
rules:
  - MATCH,手动 选择/组
"""


def make_exec(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class ServerNetworkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="server-network-test.")
        self.root = Path(self.tmp.name)
        self.state = self.root / "mihomo"
        self.env = mock.patch.dict(
            os.environ,
            {
                "PROXYCTL_STATE_DIR": str(self.state),
                "PROXYCTL_MIHOMO": str(self.root / "fake-mihomo"),
                "PROXYCTL_SYSTEMCTL": str(self.root / "fake-systemctl"),
            },
            clear=False,
        )
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(self.tmp.cleanup)
        make_exec(
            self.root / "fake-mihomo",
            """\
            #!/usr/bin/env python3
            import os
            import sys

            args = sys.argv[1:]
            if os.environ.get("FAKE_MIHOMO_FAIL") == "1":
                print("rejected by fake mihomo", file=sys.stderr)
                sys.exit(1)
            if os.environ.get("FAKE_MIHOMO_LEAK") == "1":
                path = args[args.index("-f") + 1]
                print(open(path, encoding="utf-8").read(), file=sys.stderr)
                sys.exit(1)
            print("configuration test is successful")
            """,
        )
        make_exec(
            self.root / "fake-systemctl",
            """\
            #!/usr/bin/env python3
            import sys
            sys.exit(0)
            """,
        )
        self.profile_file = self.root / "source.yaml"
        self.profile_file.write_text(GOOD_PROFILE, encoding="utf-8")

    def _secret(self) -> str:
        return proxy.load_or_create_secret(proxy.ensure_state())

    def _import(self, name="local", force=False):
        proxy.import_profile(name, self.profile_file, force=force)
        return self.state / "profiles" / f"{name}.yaml"

    # ------------------------------------------------------ campus DNS/creds

    def test_credentials_from_credential_directory(self) -> None:
        cred = self.root / "credentials"
        cred.mkdir()
        (cred / "username").write_text("10000000000\n", encoding="utf-8")
        (cred / "password").write_text("not-a-real-password\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": str(cred)}, clear=False):
            self.assertEqual(
                campus.resolve_credentials(),
                ("10000000000", "not-a-real-password"),
            )

    def test_missing_credential_reports_file(self) -> None:
        cred = self.root / "credentials"
        cred.mkdir()
        (cred / "username").write_text("10000000000\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": str(cred)}, clear=False):
            with self.assertRaises(campus.CredentialError) as caught:
                campus.resolve_credentials()
        self.assertIn(str(cred / "password"), str(caught.exception))

    def test_manual_credentials_keep_original_fallback(self) -> None:
        env = {
            "WIFI_USERNAME": "13800138000",
            "WIFI_PASSWORD": "",
        }
        with mock.patch.dict(os.environ, env, clear=False):
            os.environ.pop("CREDENTIALS_DIRECTORY", None)
            self.assertEqual(campus.resolve_credentials(), ("13800138000", "00138000"))

    # --------------------------------------------------------- campus probes

    def test_http_200_without_https_is_not_online(self) -> None:
        with mock.patch.object(campus, "_http_204_probe", return_value=(200, None)), \
             mock.patch.object(campus, "https_reachable", return_value=False):
            self.assertFalse(campus.is_online())
            self.assertEqual(campus.probe_connectivity()[0], "captive")

    def test_https_fallback_verifies_ambiguous_http(self) -> None:
        with mock.patch.object(campus, "_http_204_probe", return_value=(200, None)), \
             mock.patch.object(campus, "https_reachable", return_value=True):
            self.assertTrue(campus.is_online())
            self.assertEqual(campus.probe_connectivity(), ("online", "https-verified"))

    def test_http_timeout_falls_back_to_https(self) -> None:
        with mock.patch.object(campus, "_http_204_probe", return_value=(None, None)), \
             mock.patch.object(campus, "https_reachable", return_value=True):
            self.assertTrue(campus.is_online())

    def test_portal_parameters_are_not_logged(self) -> None:
        token = "TOPSECRETSESSION"
        cas_token = "CAS-EXECUTION-TOKEN"

        class Response:
            def __init__(self, status, location=None, url="http://110.184.24.61/login"):
                self.status_code = status
                self.headers = {"Location": location} if location else {}
                self.url = url

        class Session:
            def __init__(self):
                self.calls = 0

            def get(self, url, **kwargs):
                self.calls += 1
                self.assert_timeout(kwargs)
                if self.calls == 1:
                    return Response(
                        302,
                        location="http://portal.invalid/cas-sso/login"
                        f"?sessionId={token}&customPageId=page-1&userIp=10.0.0.2",
                    )
                return Response(
                    200,
                    url="http://110.184.24.61/cas-sso/login"
                    f"?sessionId={token}&customPageId=page-1"
                    f"&execution={cas_token}&userIp=10.0.0.2",
                )

            @staticmethod
            def assert_timeout(kwargs):
                assert kwargs.get("timeout"), "network requests must have a timeout"

        with mock.patch.object(campus, "https_reachable", return_value=False):
            with self.assertLogs("campus-login", level="DEBUG") as captured:
                result = campus.get_portal_params(Session())
        self.assertEqual(result[1], token)
        logs = "\n".join(captured.output)
        self.assertNotIn(token, logs)
        self.assertNotIn(cas_token, logs)
        self.assertNotIn("customPageId", logs)
        self.assertNotIn("userIp", logs)

    def test_login_submission_does_not_log_final_url(self) -> None:
        token = "TOKEN-IN-URL"

        class Response:
            status_code = 200
            url = f"http://110.184.24.61/ok?sessionId={token}&token={token}"
            text = "ok"

        class Session:
            def post(self, url, **kwargs):
                assert kwargs.get("timeout"), "POST needs a timeout"
                return Response()

        with self.assertLogs("campus-login", level="INFO") as captured:
            ok = campus.submit_login(
                Session(), "http://110.184.24.61", "user", "password",
                "execution",
                base64.b64encode(b"0123456789abcdef").decode(),
                "sid", "cid", "nas", "uip",
            )
        self.assertTrue(ok)
        self.assertNotIn(token, "\n".join(captured.output))

    def test_login_result_distinguishes_unverified_and_network_error(self) -> None:
        with mock.patch.object(campus, "do_login", return_value=True), \
             mock.patch.object(campus, "wait_online", return_value=False), \
             mock.patch.object(campus.time, "sleep", return_value=None):
            with self.assertLogs("campus-login", level="INFO") as captured:
                result = campus.login_until_ok("user", "password", retries=1, interval=1)
        self.assertEqual(result, 3)
        self.assertIn("submitted-unverified", "\n".join(captured.output))

        secret_url = "https://sub.example.invalid/?token=SHOULD-NOT-APPEAR"
        import requests

        def fail(*args, **kwargs):
            raise requests.Timeout(secret_url)

        with mock.patch.object(campus, "do_login", side_effect=fail), \
             mock.patch.object(campus.time, "sleep", return_value=None):
            with self.assertLogs("campus-login", level="INFO") as captured:
                result = campus.login_until_ok("user", "password", retries=1, interval=1)
        self.assertEqual(result, 1)
        logs = "\n".join(captured.output)
        self.assertIn("network-error", logs)
        self.assertNotIn("SHOULD-NOT-APPEAR", logs)

    def test_campus_service_restarts_and_uses_credentials(self) -> None:
        text = (REPO / "hosts/nixos/campus.nix").read_text(encoding="utf-8")
        self.assertIn('Restart = "always"', text)
        self.assertIn("LoadCredential", text)
        self.assertIn("/etc/campus-network/username", text)
        self.assertIn("/etc/campus-network/password", text)
        self.assertIn("campus-login.py", text)
        self.assertNotIn("WIFI_PASSWORD", text)

    # ------------------------------------------------------ proxy validation

    def test_runtime_config_forces_loopback_and_preserves_business_data(self) -> None:
        secret = "s" * 64
        runtime = proxy.validated_runtime_config(GOOD_PROFILE.encode(), secret)
        config = proxy.yaml.safe_load(runtime)
        self.assertEqual(config["mixed-port"], 7897)
        self.assertIs(config["allow-lan"], False)
        self.assertEqual(config["bind-address"], "127.0.0.1")
        self.assertEqual(config["external-controller"], "127.0.0.1:9090")
        self.assertEqual(config["secret"], secret)
        self.assertIs(config["tun"]["enable"], False)
        self.assertNotIn("listen", config["dns"])
        self.assertNotIn("listeners", config)
        for key in ("port", "socks-port", "redir-port", "tproxy-port", "external-ui", "tls"):
            self.assertNotIn(key, config)
        # Business data survives; YAML 1.1-style leading-zero passwords do not
        # silently become floats/octal values.
        self.assertEqual(config["proxies"][0]["name"], "on")
        self.assertEqual(config["proxies"][0]["password"], "01234567")
        self.assertEqual(config["proxy-groups"][0]["name"], "手动 选择/组")
        self.assertEqual(config["rules"], ["MATCH,手动 选择/组"])
        self.assertIs(config["profile"]["store-selected"], True)
        dump = runtime.decode()
        self.assertNotIn("0.0.0.0", dump)
        self.assertNotIn("input-secret", dump)

    def test_validation_seeds_pinned_geodata(self) -> None:
        geosite = self.root / "geosite.dat"
        geoip = self.root / "geoip.dat"
        geosite.write_bytes(b"geosite-test")
        geoip.write_bytes(b"geoip-test")
        fake = self.root / "fake-mihomo-geodata"
        make_exec(
            fake,
            """\
            #!/usr/bin/env python3
            import os
            import sys

            data_dir = sys.argv[sys.argv.index("-d") + 1]
            with open(os.path.join(data_dir, "GeoSite.dat"), "rb") as handle:
                assert handle.read() == b"geosite-test"
            with open(os.path.join(data_dir, "GeoIP.dat"), "rb") as handle:
                assert handle.read() == b"geoip-test"
            print("configuration test is successful")
            """,
        )
        with mock.patch.dict(
            os.environ,
            {
                "PROXYCTL_MIHOMO": str(fake),
                "PROXYCTL_GEOSITE": str(geosite),
                "PROXYCTL_GEOIP": str(geoip),
            },
            clear=False,
        ):
            proxy.validated_runtime_config(GOOD_PROFILE.encode(), "s" * 64)

    def test_additional_inbound_listener_is_rejected(self) -> None:
        data = GOOD_PROFILE.replace(
            "proxies:\n  - name: on",
            "listeners:\n  - name: public\n    type: http\n    port: 9999\nproxies:\n  - name: on",
            1,
        ).encode()
        with self.assertRaisesRegex(proxy.ConfigError, "listeners"):
            proxy.validated_runtime_config(data, "s" * 64)

    def test_external_provider_paths_are_rejected(self) -> None:
        bad = GOOD_PROFILE.replace(
            "proxies:\n  - name: on",
            "proxy-providers:\n  airport:\n    type: http\n"
            "    url: https://example.invalid/sub\n    path: /home/calendar/airport.yaml\n"
            "proxies:\n  - name: on",
            1,
        ).encode()
        with self.assertRaisesRegex(proxy.ConfigError, "state directory"):
            proxy.validated_runtime_config(bad, "s" * 64)

        file_url = GOOD_PROFILE.replace(
            "proxies:\n  - name: on",
            "rule-providers:\n  local:\n    type: file\n"
            "    behavior: classical\n    path: rules.yaml\n"
            "    url: file:///home/calendar/rules.yaml\n"
            "proxies:\n  - name: on",
            1,
        ).encode()
        with self.assertRaisesRegex(proxy.ConfigError, "http"):
            proxy.validated_runtime_config(file_url, "s" * 64)

    def test_invalid_yaml_does_not_replace_profile(self) -> None:
        target = self._import()
        before = target.read_bytes()
        bad = self.root / "bad.yaml"
        bad.write_text("proxies: [\n", encoding="utf-8")
        with self.assertRaises(proxy.ConfigError):
            proxy.import_profile("local", bad, force=True)
        self.assertEqual(target.read_bytes(), before)

    def test_html_base64_and_duplicate_keys_are_rejected(self) -> None:
        cases = [
            b"<!doctype html><html><body>login</body></html>",
            b"c3M6Ly9ZV1Z6TFRJMU5pMW5ZMjA2U0dWc2JHOD0=",
            b"proxies:\n  - name: a\nproxies:\n  - name: b\n",
        ]
        for data in cases:
            with self.subTest(data=data[:20]):
                with self.assertRaises(proxy.ConfigError):
                    proxy.load_yaml(data)

    def test_mihomo_test_failure_redacts_secret_and_urls(self) -> None:
        secret = "z" * 64
        data = GOOD_PROFILE.replace(
            "proxies:\n  - name: on",
            "proxy-providers:\n  airport:\n    type: http\n"
            "    url: https://user:TOKEN@example.invalid/sub?token=TOKEN\n"
            "    path: ./airport.yaml\n"
            "proxies:\n  - name: on",
            1,
        ).encode()
        with mock.patch.dict(os.environ, {"FAKE_MIHOMO_LEAK": "1"}, clear=False):
            with self.assertRaises(proxy.ConfigError) as caught:
                proxy.validated_runtime_config(data, secret)
        message = str(caught.exception)
        self.assertNotIn(secret, message)
        self.assertNotIn("TOKEN", message)
        self.assertNotIn("example.invalid", message)

    # ---------------------------------------------------------- persistence

    def test_init_creates_root_only_state_without_printing_secret(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()) as output:
            proxy.command_init()
        secret = (self.state / "api-secret").read_text(encoding="utf-8").strip()
        self.assertNotIn(secret, output.getvalue())
        self.assertEqual(stat.S_IMODE((self.state).stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.state / "profiles").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.state / "api-secret").stat().st_mode), 0o600)

    def test_use_missing_profile_has_recovery_hint(self) -> None:
        with self.assertRaisesRegex(proxy.ProfileError, "does not exist"):
            proxy.use_profile("missing")

    def test_import_is_atomic_and_refresh_failure_keeps_old(self) -> None:
        target = self._import()
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        original = target.read_bytes()
        with mock.patch.object(
            proxy, "download_subscription", side_effect=proxy.DownloadError("HTTP 502")
        ):
            with self.assertRaises(proxy.DownloadError):
                proxy.set_subscription_url("local", "https://example.invalid/sub?token=SECRET")
                proxy.refresh_profile("local", via_proxy=False)
        self.assertEqual(target.read_bytes(), original)
        # The URL is stored root-only and never echoed by list.
        self.assertEqual(
            proxy.read_source_url("local"), "https://example.invalid/sub?token=SECRET"
        )
        with contextlib.redirect_stdout(io.StringIO()) as output:
            proxy.command_list()
        self.assertNotIn("SECRET", output.getvalue())
        self.assertIn("subscription", output.getvalue())

    def test_refresh_success_does_not_switch_and_passes_proxy_flag(self) -> None:
        target = self._import()
        new = GOOD_PROFILE.replace("server: 192.0.2.10", "server: 192.0.2.11").encode()
        with mock.patch.object(proxy, "download_subscription", return_value=new) as download:
            proxy.set_subscription_url("local", "https://example.invalid/sub")
            proxy.refresh_profile("local", via_proxy=False)
            self.assertIs(download.call_args.kwargs["via_proxy"], False)
            proxy.refresh_profile("local", via_proxy=True)
            self.assertIs(download.call_args.kwargs["via_proxy"], True)
        self.assertEqual(target.read_bytes(), new)
        self.assertFalse((self.state / "active.yaml").exists())
        self.assertFalse((self.state / "active-name").exists())

    def test_use_switches_and_rolls_back(self) -> None:
        self._import("local")
        self._import("other")
        verification = {"fail_next": False, "calls": 0}

        def verify():
            verification["calls"] += 1
            if verification["fail_next"]:
                verification["fail_next"] = False
                raise proxy.ProxyCtlError("fake readiness failure")

        with mock.patch.object(proxy, "restart_mihomo", return_value=None), \
             mock.patch.object(proxy, "verify_service_ready", side_effect=verify):
            proxy.use_profile("local")
            first_active = (self.state / "active.yaml").read_bytes()
            first_last_good = (self.state / "last-good.yaml").read_bytes()
            self.assertEqual((self.state / "active-name").read_text().strip(), "local")
            self.assertEqual(first_active, first_last_good)

            proxy.use_profile("other")
            self.assertEqual((self.state / "active-name").read_text().strip(), "other")
            self.assertEqual((self.state / "last-good.yaml").read_bytes(), first_active)

            before = (self.state / "active.yaml").read_bytes()
            verification["fail_next"] = True
            with self.assertRaises(proxy.ProxyCtlError):
                proxy.use_profile("local")
            self.assertEqual((self.state / "active.yaml").read_bytes(), before)
            self.assertEqual((self.state / "active-name").read_text().strip(), "other")

            # A failed first activation removes the unverified active file and
            # does not invent an active-name.
            self.state.joinpath("active.yaml").unlink()
            self.state.joinpath("active-name").unlink()
            self.state.joinpath("last-good.yaml").unlink()
            verification["fail_next"] = True
            with mock.patch.object(proxy, "run_systemctl") as systemctl:
                with self.assertRaises(proxy.ProxyCtlError):
                    proxy.use_profile("local")
            systemctl.assert_called_with(["stop", "mihomo.service"], timeout=30)
            self.assertFalse((self.state / "active.yaml").exists())

    def test_uninitialized_list_points_to_init(self) -> None:
        with self.assertRaisesRegex(proxy.ProfileError, "proxyctl init"):
            proxy.command_list()

    def test_status_never_prints_the_api_secret(self) -> None:
        self._secret()
        with mock.patch.object(proxy, "service_active", return_value=True), \
             mock.patch.object(proxy, "check_local_bindings", return_value=None), \
             mock.patch.object(proxy, "api_json", return_value={"version": "test"}):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                proxy.command_status()
        secret = (self.state / "api-secret").read_text(encoding="utf-8").strip()
        self.assertNotIn(secret, output.getvalue())
        self.assertIn("reachable", output.getvalue())

    # --------------------------------------------------------------- API

    def test_api_supports_chinese_spaces_and_slashes(self) -> None:
        group = "手动 选择/组"
        node = "节点 A + 特殊"
        observed = {"put_path": None, "put_body": None}

        class Handler(BaseHTTPRequestHandler):
            current = "old-node"

            def log_message(self, *args):
                pass

            def _authorised(self):
                if self.headers.get("Authorization") != "Bearer " + "s" * 64:
                    self.send_response(401)
                    self.end_headers()
                    return False
                return True

            def do_GET(self):
                if not self._authorised():
                    return
                if self.path == "/proxies":
                    body = {
                        "proxies": {
                            group: {
                                "type": "Selector",
                                "now": self.current,
                                "all": ["old-node", node],
                            }
                        }
                    }
                elif self.path == "/proxies/" + proxy.urllib.parse.quote(group, safe=""):
                    body = {
                        "type": "Selector",
                        "now": self.current,
                        "all": ["old-node", node],
                    }
                else:
                    self.send_response(404)
                    self.end_headers()
                    return
                data = json.dumps(body, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_PUT(self):
                if not self._authorised():
                    return
                length = int(self.headers.get("Content-Length", "0"))
                observed["put_path"] = self.path
                observed["put_body"] = json.loads(self.rfile.read(length).decode())
                Handler.current = observed["put_body"]["name"]
                self.send_response(204)
                self.end_headers()

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f"http://127.0.0.1:{server.server_address[1]}"

        groups = proxy.list_groups(base=base, secret="s" * 64)
        self.assertEqual(groups, [(group, "Selector", "old-node")])
        detail = proxy.group_detail(group, base=base, secret="s" * 64)
        self.assertEqual(detail["all"], ["old-node", node])
        proxy.select_node(group, node, base=base, secret="s" * 64)
        self.assertEqual(
            observed["put_path"],
            "/proxies/" + proxy.urllib.parse.quote(group, safe=""),
        )
        self.assertEqual(observed["put_body"], {"name": node})


if __name__ == "__main__":
    unittest.main(verbosity=2)
