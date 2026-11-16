#!/usr/bin/env python3
"""Manage Mihomo profiles, runtime configuration and local control API.

This CLI deliberately has no third-party proxy-management framework. It uses
PyYAML for parsing/serialising and the standard library for downloads, file
locking, systemd calls and the local REST API.

Runtime state lives under /etc/mihomo (root-only). Imported YAML and
subscription URLs never enter the Nix store or Git.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import copy
import fcntl
import getpass
import http.client
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("proxyctl: the PyYAML module is missing\n")
    raise SystemExit(1)

DEFAULT_STATE_DIR = Path("/etc/mihomo")
MIXED_PORT = 7897
API_HOST = "127.0.0.1"
API_PORT = 9090
API_BASE = f"http://{API_HOST}:{API_PORT}"

MAX_CONFIG_BYTES = 16 * 1024 * 1024
MAX_SOURCE_URL_BYTES = 8 * 1024
MAX_LOG_BYTES = 4096
DOWNLOAD_TIMEOUT = 30
MIHOMO_TEST_TIMEOUT = 30
SERVICE_READY_TIMEOUT = 20

PROFILE_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
URL_RE = re.compile(r"https?://[^\s\"'<>]+")
NODE_URI_RE = re.compile(
    r"^(?:ss|ssr|vmess|vless|trojan|hysteria|hysteria2|hy2|tuic|snell|socks|http)://",
    re.IGNORECASE,
)

FORCED_REMOVED_KEYS = (
    "port",
    "socks-port",
    "redir-port",
    "tproxy-port",
    "external-controller-tls",
    "external-controller-unix",
    "external-controller-pipe",
    "external-doh-server",
    "external-ui",
    "external-ui-name",
    "external-ui-url",
    "tls",
    "certificate",
    "private-key",
)


class ProxyCtlError(Exception):
    pass


class ConfigError(ProxyCtlError):
    pass


class ProfileError(ProxyCtlError):
    pass


class DownloadError(ProxyCtlError):
    pass


class ApiError(ProxyCtlError):
    pass


@dataclass(frozen=True)
class StatePaths:
    root: Path

    @property
    def profiles(self) -> Path:
        return self.root / "profiles"

    @property
    def sources(self) -> Path:
        return self.root / "sources"

    @property
    def active(self) -> Path:
        return self.root / "active.yaml"

    @property
    def active_name(self) -> Path:
        return self.root / "active-name"

    @property
    def last_good(self) -> Path:
        return self.root / "last-good.yaml"

    @property
    def secret(self) -> Path:
        return self.root / "api-secret"

    @property
    def lock(self) -> Path:
        return self.root / ".proxyctl.lock"


def state_paths() -> StatePaths:
    raw = os.environ.get("PROXYCTL_STATE_DIR", str(DEFAULT_STATE_DIR))
    return StatePaths(Path(raw))


def systemctl_bin() -> str:
    return os.environ.get("PROXYCTL_SYSTEMCTL", "systemctl")


def mihomo_bin() -> str | None:
    configured = os.environ.get("PROXYCTL_MIHOMO")
    if configured:
        return configured
    return shutil.which("mihomo")


def die(message: str, code: int = 1) -> None:
    sys.stderr.write(f"proxyctl: error: {sanitize_text(message)}\n")
    raise SystemExit(code)


def require_root() -> None:
    if os.geteuid() != 0:
        die("this command requires root (use sudo)")


def sanitize_text(text: str, extra_secrets: tuple[str, ...] = ()) -> str:
    """Remove secrets and URLs from any text that may reach a terminal/log."""
    if not text:
        return ""
    for value in extra_secrets:
        if value:
            text = text.replace(value, "<secret>")
    text = URL_RE.sub("<url>", text)
    text = re.sub(r"(?i)(authorization:\s*bearer\s+)\S+", r"\1<secret>", text)
    text = text.replace("\x00", "")
    if len(text) > MAX_LOG_BYTES:
        text = text[:MAX_LOG_BYTES] + "\n...(truncated)"
    return text


def validate_name(name: str) -> str:
    if not PROFILE_NAME_RE.fullmatch(name or ""):
        raise ProfileError(
            "profile name must match [A-Za-z0-9_-]{1,64} "
            "(no dots, slashes, spaces or non-ASCII characters)"
        )
    return name


def _check_not_symlink(path: Path, label: str) -> None:
    if path.is_symlink():
        raise ProfileError(f"{label} must not be a symlink: {path}")


def ensure_state() -> StatePaths:
    paths = state_paths()
    for path in (paths.root, paths.profiles, paths.sources):
        _check_not_symlink(path, "state directory")
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, 0o700)
    return paths


def _read_limited(path: Path, limit: int, label: str) -> bytes:
    """Read a regular file, refusing symlinks and oversized content."""
    _check_not_symlink(path, label)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        raise ProfileError(f"{label} does not exist: {path}")
    except OSError as exc:
        raise ProfileError(f"cannot open {label} {path}: {exc.strerror or type(exc).__name__}")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ProfileError(f"{label} is not a regular file: {path}")
        if info.st_size > limit:
            raise ProfileError(f"{label} exceeds the {limit}-byte limit: {path}")
        chunks = []
        remaining = limit + 1
        while remaining > 0:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > limit:
            raise ProfileError(f"{label} exceeds the {limit}-byte limit: {path}")
        return data
    finally:
        os.close(fd)


def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp = Path(tmp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        dir_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            tmp.unlink()
        raise


def load_or_create_secret(paths: StatePaths) -> str:
    _check_not_symlink(paths.secret, "API secret")
    if paths.secret.exists():
        data = _read_limited(paths.secret, 4096, "API secret").decode("utf-8", "strict").strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", data):
            raise ConfigError(f"API secret is malformed: {paths.secret}")
        return data

    secret = secrets.token_hex(32)
    atomic_write(paths.secret, (secret + "\n").encode(), 0o600)
    return secret


def read_secret() -> str:
    paths = state_paths()
    _check_not_symlink(paths.secret, "API secret")
    if not paths.secret.exists():
        raise ConfigError(
            f"API secret is missing: {paths.secret}; "
            "run `sudo proxyctl init` after deploying the NixOS module"
        )
    data = _read_limited(paths.secret, 4096, "API secret").decode("utf-8", "strict").strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", data):
        raise ConfigError(f"API secret is malformed: {paths.secret}")
    return data


# ------------------------------------------------------------------ YAML

class _MihomoLoader(yaml.SafeLoader):
    """SafeLoader with YAML 1.2-style scalars and duplicate-key checks.

    PyYAML's default YAML 1.1 resolver turns unquoted `on`/`yes` into bools
    and `01234567` into an octal integer. Mihomo uses go-yaml v3 semantics;
    preserving a phone/password-like scalar matters more than YAML 1.1
    compatibility here.
    """

    def construct_mapping(self, node, deep=False):
        if not isinstance(node, yaml.MappingNode):
            raise ConfigError("YAML mapping expected")
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            try:
                hash(key)
            except TypeError:
                raise ConfigError("YAML mapping key is not hashable")
            if key in mapping:
                raise ConfigError(f"duplicate YAML key: {key!r}")
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def _configure_loader() -> None:
    resolvers = {}
    removed = {
        "tag:yaml.org,2002:bool",
        "tag:yaml.org,2002:int",
        "tag:yaml.org,2002:float",
        "tag:yaml.org,2002:timestamp",
        "tag:yaml.org,2002:value",
    }
    for first, entries in yaml.SafeLoader.yaml_implicit_resolvers.items():
        kept = [(tag, regexp) for tag, regexp in entries if tag not in removed]
        if kept:
            resolvers[first] = kept
    _MihomoLoader.yaml_implicit_resolvers = resolvers
    _MihomoLoader.add_implicit_resolver(
        "tag:yaml.org,2002:bool",
        re.compile(r"^(?:true|True|TRUE|false|False|FALSE)$"),
        list("tTfF"),
    )
    _MihomoLoader.add_implicit_resolver(
        "tag:yaml.org,2002:int",
        re.compile(r"^[-+]?(?:0|[1-9][0-9]*|0o[0-7]+|0x[0-9a-fA-F]+|0b[01]+)$"),
        list("-+0123456789"),
    )
    _MihomoLoader.add_implicit_resolver(
        "tag:yaml.org,2002:float",
        re.compile(
            r"^[-+]?(?:(?:[0-9]+\.[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?"
            r"|[0-9]+[eE][-+]?[0-9]+"
            r"|\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$"
        ),
        list("-+0123456789."),
    )


_configure_loader()


def _looks_like_html(text: str) -> bool:
    head = text.lstrip()[:2000].lower()
    return (
        head.startswith("<!doctype html")
        or head.startswith("<html")
        or "<html" in head
        or "<head" in head
        or "<body" in head
    )


def _looks_like_node_list(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return False
    if NODE_URI_RE.match(stripped):
        return True
    # A whole-body Base64 share list decodes to one URI per line. It is not a
    # complete Mihomo YAML document and must not silently replace a profile.
    compact = re.sub(r"\s+", "", stripped)
    if len(compact) >= 64 and re.fullmatch(r"[A-Za-z0-9+/=]+", compact):
        try:
            decoded = base64.b64decode(compact, validate=True).decode("utf-8", "ignore")
        except (ValueError, UnicodeDecodeError):
            return False
        return bool(NODE_URI_RE.search(decoded.lstrip()))
    return False


def _validate_string_keys(value, path="configuration") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                raise ConfigError(f"{path} contains a non-string key: {key!r}")
            _validate_string_keys(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _validate_string_keys(child, f"{path}[{index}]")


def load_yaml(data: bytes, label: str = "configuration") -> dict:
    if len(data) > MAX_CONFIG_BYTES:
        raise ConfigError(f"{label} exceeds the {MAX_CONFIG_BYTES}-byte limit")
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise ConfigError(f"{label} is not valid UTF-8")
    if _looks_like_html(text):
        raise ConfigError(f"{label} looks like an HTML/login page, not a Mihomo YAML file")
    if _looks_like_node_list(text):
        raise ConfigError(
            f"{label} looks like a node URI/Base64 list, not a complete Mihomo configuration"
        )
    try:
        document = yaml.load(text, Loader=_MihomoLoader)
    except ConfigError:
        raise
    except yaml.YAMLError as exc:
        problem = getattr(exc, "problem", None) or type(exc).__name__
        mark = getattr(exc, "problem_mark", None)
        location = f" at line {mark.line + 1}" if mark is not None else ""
        raise ConfigError(f"{label} is not valid YAML: {problem}{location}")
    if not isinstance(document, dict):
        raise ConfigError(f"{label} must be a YAML mapping, not {type(document).__name__}")
    if not document:
        raise ConfigError(f"{label} is empty")
    _validate_string_keys(document)
    required_any = ("proxies", "proxy-providers", "proxy-groups", "rules")
    if not any(key in document for key in required_any):
        raise ConfigError(
            f"{label} is not a complete Mihomo config "
            "(expected at least one of proxies/proxy-providers/proxy-groups/rules)"
        )
    return document


def _external_path(path: str) -> bool:
    normalised = path.replace("\\", "/")
    if normalised.startswith(("/", "~")):
        return True
    if re.match(r"^[A-Za-z]:/", normalised):
        return True
    return ".." in normalised.split("/")


def _check_provider_references(config: dict) -> None:
    for section in ("proxy-providers", "rule-providers"):
        providers = config.get(section)
        if providers is None:
            continue
        if not isinstance(providers, dict):
            raise ConfigError(f"{section} must be a mapping")
        for name, provider in providers.items():
            if not isinstance(provider, dict):
                raise ConfigError(f"{section}.{name} must be a mapping")
            url = provider.get("url")
            if url is not None:
                if not isinstance(url, str) or urllib.parse.urlsplit(url).scheme not in ("http", "https"):
                    raise ConfigError(
                        f"{section}.{name}.url must be an http(s) URL; "
                        "local file:// providers are not supported"
                    )
            path = provider.get("path")
            if path is not None:
                if not isinstance(path, str) or _external_path(path):
                    raise ConfigError(
                        f"{section}.{name}.path must stay inside the Mihomo state directory; "
                        "absolute, home and ../ paths are rejected"
                    )
            payload = provider.get("payload")
            if isinstance(payload, str) and (
                payload.startswith(("/", "~")) or payload.lower().startswith("file:")
            ):
                raise ConfigError(
                    f"{section}.{name}.payload must be inline data, not an external file"
                )


def normalize_config(document: dict, secret: str) -> dict:
    """Return a forced-safe runtime config without dropping business data."""
    config = copy.deepcopy(document)
    _check_provider_references(config)

    listeners = config.get("listeners")
    if listeners:
        raise ConfigError(
            "additional inbound `listeners` are not supported; remove them so only "
            f"the forced 127.0.0.1:{MIXED_PORT} mixed port is opened"
        )
    config.pop("listeners", None)

    for key in FORCED_REMOVED_KEYS:
        config.pop(key, None)

    dns = config.get("dns")
    if dns is not None:
        if not isinstance(dns, dict):
            raise ConfigError("dns must be a mapping")
        # A DNS listener would conflict with systemd-resolved. Nameservers and
        # enhanced-mode settings remain available for proxied DNS resolution.
        dns.pop("listen", None)
        config["dns"] = dns

    tun = config.get("tun")
    if tun is None:
        tun = {}
    elif not isinstance(tun, dict):
        raise ConfigError("tun must be a mapping")
    tun["enable"] = False
    config["tun"] = tun

    profile = config.get("profile")
    if profile is None:
        profile = {}
    elif not isinstance(profile, dict):
        raise ConfigError("profile must be a mapping")
    profile["store-selected"] = True
    config["profile"] = profile

    config["mixed-port"] = MIXED_PORT
    config["allow-lan"] = False
    config["bind-address"] = API_HOST
    config["external-controller"] = f"{API_HOST}:{API_PORT}"
    config["secret"] = secret

    # Defensive assertions for the invariants documented in proxy.nix.
    if config["tun"].get("enable") is not False:
        raise ConfigError("internal error: TUN was not disabled")
    if config.get("allow-lan") is not False or config.get("bind-address") != API_HOST:
        raise ConfigError("internal error: unsafe listener configuration")
    if config.get("external-controller") != f"{API_HOST}:{API_PORT}":
        raise ConfigError("internal error: unsafe controller configuration")
    if config.get("secret") != secret:
        raise ConfigError("internal error: API secret was not injected")
    return config


def dump_config(config: dict) -> bytes:
    return yaml.safe_dump(
        config,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
        width=4096,
    ).encode("utf-8")


def _validation_env(tmpdir: str) -> dict:
    env = os.environ.copy()
    for key in (
        "http_proxy",
        "https_proxy",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "all_proxy",
    ):
        env.pop(key, None)
    env["HOME"] = tmpdir
    env["XDG_CACHE_HOME"] = os.path.join(tmpdir, "cache")
    return env


def _seed_validation_geodata(tmpdir: str) -> None:
    """Make pinned GeoIP/GeoSite data visible to ``mihomo -t``.

    A profile using ``geodata-mode`` otherwise tries to download these files
    on first validation. That fails on a network that has not completed portal
    login yet, so the NixOS wrapper points these variables at store paths.
    """
    for env_name, filename in (
        ("PROXYCTL_GEOSITE", "GeoSite.dat"),
        ("PROXYCTL_GEOIP", "GeoIP.dat"),
    ):
        source = os.environ.get(env_name)
        if not source:
            continue
        if not os.path.isfile(source):
            raise ConfigError(f"{env_name} does not point to a readable file")
        destination = Path(tmpdir) / filename
        shutil.copyfile(source, destination)
        destination.chmod(0o600)


def validate_with_mihomo(data: bytes, secret: str) -> None:
    binary = mihomo_bin()
    if not binary:
        raise ConfigError(
            "mihomo binary not found; deploy the NixOS module or set PROXYCTL_MIHOMO"
        )
    if not os.path.isfile(binary) or not os.access(binary, os.X_OK):
        raise ConfigError(f"mihomo binary is not executable: {binary}")

    with tempfile.TemporaryDirectory(prefix="proxyctl-test.") as tmpdir:
        _seed_validation_geodata(tmpdir)
        config_path = Path(tmpdir) / "config.yaml"
        atomic_write(config_path, data, 0o600)
        try:
            result = subprocess.run(
                [binary, "-t", "-f", str(config_path), "-d", tmpdir],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=MIHOMO_TEST_TIMEOUT,
                env=_validation_env(tmpdir),
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise ConfigError(f"mihomo -t timed out after {MIHOMO_TEST_TIMEOUT}s")
        except OSError as exc:
            raise ConfigError(f"cannot execute mihomo -t: {exc.strerror or type(exc).__name__}")
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip()
            detail = sanitize_text(detail, (secret,))
            raise ConfigError(
                f"mihomo rejected the generated configuration (exit {result.returncode})"
                + (f": {detail}" if detail else "")
            )


def validated_runtime_config(data: bytes, secret: str) -> bytes:
    document = load_yaml(data)
    config = normalize_config(document, secret)
    runtime = dump_config(config)
    validate_with_mihomo(runtime, secret)
    return runtime


# ------------------------------------------------------------- downloads

class _HttpsOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise DownloadError("refusing a subscription redirect to a non-HTTPS URL")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def validate_subscription_url(url: str) -> str:
    if not url or len(url) > 8192 or any(ch.isspace() for ch in url):
        raise DownloadError("subscription URL is empty, too long, or contains whitespace")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise DownloadError("subscription URL must be an absolute https:// URL")
    return url


def describe_download_error(exc: BaseException) -> str:
    if isinstance(exc, urllib.error.HTTPError):
        return f"HTTP {exc.code}"
    if isinstance(exc, urllib.error.URLError):
        reason = exc.reason
        if isinstance(reason, (TimeoutError, socket.timeout)):
            return "download timeout"
        if isinstance(reason, ssl.SSLError):
            return "TLS verification failed"
        if isinstance(reason, DownloadError):
            return str(reason)
        return f"connection failed ({type(reason).__name__})"
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return "download timeout"
    return type(exc).__name__


def download_subscription(url: str, via_proxy: bool) -> bytes:
    validate_subscription_url(url)
    handlers = [
        urllib.request.ProxyHandler(
            {"http": f"http://{API_HOST}:{MIXED_PORT}", "https": f"http://{API_HOST}:{MIXED_PORT}"}
            if via_proxy
            else {}
        ),
        _HttpsOnlyRedirect(),
    ]
    opener = urllib.request.build_opener(*handlers)
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "proxyctl/1.0",
            "Accept": "application/yaml,text/yaml,text/plain,*/*",
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=DOWNLOAD_TIMEOUT) as response:
            if response.status != 200:
                raise DownloadError(f"subscription returned HTTP {response.status}")
            if urllib.parse.urlsplit(response.geturl()).scheme != "https":
                raise DownloadError("subscription redirected to a non-HTTPS URL")
            content_type = (response.headers.get("Content-Type") or "").lower()
            if "text/html" in content_type:
                raise DownloadError("subscription returned an HTML page instead of YAML")
            length = response.headers.get("Content-Length")
            if length:
                try:
                    if int(length) > MAX_CONFIG_BYTES:
                        raise DownloadError(
                            f"subscription is larger than the {MAX_CONFIG_BYTES}-byte limit"
                        )
                except ValueError:
                    pass
            data = response.read(MAX_CONFIG_BYTES + 1)
    except DownloadError:
        raise
    except (urllib.error.URLError, TimeoutError, socket.timeout, OSError, http.client.HTTPException) as exc:
        raise DownloadError(f"subscription download failed: {describe_download_error(exc)}")
    if len(data) > MAX_CONFIG_BYTES:
        raise DownloadError(f"subscription is larger than the {MAX_CONFIG_BYTES}-byte limit")
    if not data:
        raise DownloadError("subscription returned an empty body")
    return data


# --------------------------------------------------------------- profiles

def profile_path(name: str) -> Path:
    return state_paths().profiles / f"{validate_name(name)}.yaml"


def source_path(name: str) -> Path:
    return state_paths().sources / f"{validate_name(name)}.url"


def all_profile_names() -> list[str]:
    paths = state_paths()
    names: set[str] = set()
    if paths.profiles.is_dir():
        for item in paths.profiles.iterdir():
            if item.suffix == ".yaml" and PROFILE_NAME_RE.fullmatch(item.stem):
                names.add(item.stem)
    if paths.sources.is_dir():
        for item in paths.sources.iterdir():
            if item.suffix == ".url" and PROFILE_NAME_RE.fullmatch(item.stem):
                names.add(item.stem)
    return sorted(names)


def read_active_name() -> str | None:
    path = state_paths().active_name
    if not path.exists() or path.is_symlink():
        return None
    try:
        value = _read_limited(path, 256, "active profile name").decode("utf-8").strip()
    except (ProfileError, UnicodeDecodeError):
        return None
    return value if PROFILE_NAME_RE.fullmatch(value) else None


def read_source_url(name: str) -> str:
    path = source_path(name)
    try:
        value = _read_limited(path, MAX_SOURCE_URL_BYTES, "subscription URL").decode("utf-8").strip()
    except UnicodeDecodeError:
        raise ConfigError(f"subscription URL file is not valid UTF-8: {path}")
    return validate_subscription_url(value)


@contextlib.contextmanager
def exclusive_lock(paths: StatePaths):
    fd = os.open(paths.lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def import_profile(name: str, source: Path, force: bool = False) -> None:
    validate_name(name)
    paths = ensure_state()
    target = profile_path(name)
    if target.exists() and not force:
        raise ProfileError(f"profile already exists: {name}; use --force to replace it")
    data = _read_limited(source, MAX_CONFIG_BYTES, "source YAML")
    secret = load_or_create_secret(paths)
    validated_runtime_config(data, secret)
    atomic_write(target, data, 0o600)
    print(f"imported profile '{name}' ({len(data)} bytes); it is not active yet")


def set_subscription_url(name: str, url: str) -> None:
    validate_name(name)
    paths = ensure_state()
    validate_subscription_url(url)
    atomic_write(source_path(name), (url + "\n").encode("utf-8"), 0o600)
    print(f"saved HTTPS subscription URL for '{name}' (value not displayed)")
    if not profile_path(name).exists():
        print(f"no downloaded profile yet; run: sudo proxyctl refresh {name}")


def refresh_profile(name: str, via_proxy: bool) -> None:
    validate_name(name)
    paths = ensure_state()
    url = read_source_url(name)
    old_exists = profile_path(name).exists()
    try:
        data = download_subscription(url, via_proxy=via_proxy)
        secret = load_or_create_secret(paths)
        validated_runtime_config(data, secret)
    except (DownloadError, ConfigError, ProfileError):
        if old_exists:
            sys.stderr.write(
                f"proxyctl: refresh failed; profile '{name}' was left unchanged\n"
            )
        raise
    atomic_write(profile_path(name), data, 0o600)
    active = read_active_name()
    via = "through the local proxy" if via_proxy else "directly"
    print(f"refreshed profile '{name}' {via} ({len(data)} bytes)")
    if active == name:
        print("this is the active profile, but the running Mihomo was not switched; run `sudo proxyctl use " + name + "`")
    else:
        print("the active profile and running service were not changed")


# --------------------------------------------------------------- systemd

def run_systemctl(args: list[str], timeout: int = 30) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            [systemctl_bin(), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        raise ProxyCtlError("systemctl not found")
    except subprocess.TimeoutExpired:
        raise ProxyCtlError(f"systemctl {' '.join(args)} timed out")


def service_active() -> bool:
    result = run_systemctl(["is-active", "--quiet", "mihomo.service"], timeout=5)
    return result.returncode == 0


def local_tcp_listeners(ports: tuple[int, ...]) -> dict[int, list[tuple[str, str]]]:
    """Return listening addresses from /proc for the requested ports."""
    found: dict[int, list[tuple[str, str]]] = {port: [] for port in ports}
    for family, proc_path in (("ipv4", "/proc/net/tcp"), ("ipv6", "/proc/net/tcp6")):
        try:
            with open(proc_path, encoding="ascii") as handle:
                next(handle, None)
                for line in handle:
                    fields = line.split()
                    if len(fields) < 4 or fields[3] != "0A":
                        continue
                    address_hex, port_hex = fields[1].split(":")
                    port = int(port_hex, 16)
                    if port in found:
                        found[port].append((family, address_hex.upper()))
        except FileNotFoundError:
            continue
    return found


def check_local_bindings() -> None:
    listeners = local_tcp_listeners((MIXED_PORT, API_PORT))
    for port in (MIXED_PORT, API_PORT):
        if not listeners[port]:
            raise ProxyCtlError(f"local port {port} is not listening")
    loopback_v4 = "0100007F"
    loopback_v6 = "00000000000000000000000001000000"
    for port, entries in listeners.items():
        external = [
            f"{family}:{address}"
            for family, address in entries
            if address not in (loopback_v4, loopback_v6)
        ]
        if external:
            raise ProxyCtlError(
                f"port {port} is listening on a non-loopback address ({', '.join(external)})"
            )


def verify_service_ready() -> None:
    deadline = time.monotonic() + SERVICE_READY_TIMEOUT
    last_error = "service did not become ready"
    while time.monotonic() < deadline:
        try:
            if not service_active():
                last_error = "mihomo.service is not active"
            else:
                check_local_bindings()
                with socket.create_connection((API_HOST, MIXED_PORT), timeout=1):
                    pass
                api_json("GET", "/version", timeout=2)
                return
        except (ProxyCtlError, OSError) as exc:
            last_error = str(exc)
        time.sleep(0.5)
    raise ProxyCtlError(f"mihomo.service failed its local readiness check: {last_error}")


def restart_mihomo() -> None:
    result = run_systemctl(["restart", "mihomo.service"], timeout=30)
    if result.returncode != 0:
        detail = sanitize_text((result.stderr or result.stdout or "").strip())
        raise ProxyCtlError(
            "systemctl restart mihomo.service failed"
            + (f": {detail}" if detail else "")
        )


# --------------------------------------------------------------- switching

def _previous_config(paths: StatePaths) -> bytes | None:
    if paths.active.exists():
        return _read_limited(paths.active, MAX_CONFIG_BYTES, "active configuration")
    if paths.last_good.exists():
        return _read_limited(paths.last_good, MAX_CONFIG_BYTES, "last-good configuration")
    return None


def use_profile(name: str) -> None:
    validate_name(name)
    paths = ensure_state()
    with exclusive_lock(paths):
        source = profile_path(name)
        if not source.exists():
            if source_path(name).exists():
                raise ProfileError(
                    f"profile '{name}' has a subscription URL but has not been downloaded; "
                    f"run: sudo proxyctl refresh {name}"
                )
            raise ProfileError(
                f"profile '{name}' does not exist; run `proxyctl list` or `proxyctl add`"
            )
        original = _read_limited(source, MAX_CONFIG_BYTES, "profile YAML")
        secret = load_or_create_secret(paths)
        runtime = validated_runtime_config(original, secret)

        previous = _previous_config(paths)
        if previous is not None and paths.active.exists():
            atomic_write(paths.last_good, previous, 0o600)

        old_active = previous if paths.active.exists() else None
        atomic_write(paths.active, runtime, 0o600)
        try:
            restart_mihomo()
            verify_service_ready()
        except Exception as exc:
            reason = sanitize_text(str(exc), (secret,))
            sys.stderr.write(f"proxyctl: switch failed: {reason}\n")
            if previous is not None:
                atomic_write(paths.active, previous, 0o600)
                try:
                    restart_mihomo()
                    verify_service_ready()
                    sys.stderr.write("proxyctl: restored the previous active configuration\n")
                except Exception as rollback_exc:
                    sys.stderr.write(
                        "proxyctl: rollback restart failed: "
                        + sanitize_text(str(rollback_exc), (secret,))
                        + "\n"
                    )
            else:
                with contextlib.suppress(FileNotFoundError):
                    paths.active.unlink()
                result = run_systemctl(["stop", "mihomo.service"], timeout=30)
                if result.returncode != 0:
                    sys.stderr.write("proxyctl: could not stop the failed initial service\n")
                sys.stderr.write(
                    "proxyctl: no previous active configuration existed; "
                    "the failed active.yaml was removed\n"
                )
            raise ProxyCtlError(f"could not activate profile '{name}'")

        if old_active is None and previous is None:
            # First successful activation: keep a usable recovery copy.
            atomic_write(paths.last_good, runtime, 0o600)
        atomic_write(paths.active_name, (name + "\n").encode("utf-8"), 0o600)
        print(f"activated profile '{name}'")
        print(f"local proxy: http://{API_HOST}:{MIXED_PORT}")
        print(f"local API:   http://{API_HOST}:{API_PORT}")
        print("service readiness was verified locally; external connectivity is not part of the rollback check")


# --------------------------------------------------------------------- API

def api_json(
    method: str,
    path: str,
    payload: dict | None = None,
    *,
    base: str = API_BASE,
    secret: str | None = None,
    timeout: int = 5,
):
    token = secret if secret is not None else read_secret()
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    request = urllib.request.Request(
        base + path, data=data, headers=headers, method=method
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=timeout) as response:
            body = response.read()
            if not body:
                return {}
            return json.loads(body.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read(MAX_LOG_BYTES).decode("utf-8", "replace").strip()
        raise ApiError(f"Mihomo API returned HTTP {exc.code}" + (f": {body}" if body else ""))
    except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as exc:
        raise ApiError(f"cannot reach the local Mihomo API: {describe_download_error(exc)}")
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ApiError("Mihomo API returned invalid JSON")


def _proxies(base: str | None = None, secret: str | None = None) -> dict:
    data = api_json("GET", "/proxies", base=base or API_BASE, secret=secret)
    proxies = data.get("proxies")
    if not isinstance(proxies, dict):
        raise ApiError("Mihomo API response does not contain a proxies mapping")
    return proxies


def list_groups(base: str | None = None, secret: str | None = None) -> list[tuple[str, str, str]]:
    proxies = _proxies(base=base, secret=secret)
    groups = []
    for name, value in proxies.items():
        if not isinstance(value, dict) or not isinstance(value.get("all"), list):
            continue
        groups.append((name, str(value.get("type", "")), str(value.get("now", ""))))
    return sorted(groups, key=lambda item: item[0])


def group_detail(group: str, base: str | None = None, secret: str | None = None) -> dict:
    path = "/proxies/" + urllib.parse.quote(group, safe="")
    data = api_json("GET", path, base=base or API_BASE, secret=secret)
    if not isinstance(data.get("all"), list):
        raise ApiError(f"Mihomo API did not return a selector group named {group!r}")
    return data


def select_node(group: str, node: str, base: str | None = None, secret: str | None = None) -> None:
    detail = group_detail(group, base=base, secret=secret)
    candidates = [str(item) for item in detail.get("all", [])]
    if node not in candidates:
        raise ApiError(
            f"node {node!r} is not in group {group!r}; use `proxyctl nodes {group}`"
        )
    path = "/proxies/" + urllib.parse.quote(group, safe="")
    api_json("PUT", path, {"name": node}, base=base or API_BASE, secret=secret)
    current = group_detail(group, base=base, secret=secret).get("now")
    if str(current) != node:
        raise ApiError(
            f"selection request succeeded but the API still reports {current!r} for {group!r}"
        )


# ------------------------------------------------------------------ output

def command_list() -> None:
    paths = state_paths()
    if not paths.root.is_dir():
        raise ProfileError("Mihomo state is not initialized; run `sudo proxyctl init`")
    if not os.access(paths.root, os.R_OK | os.X_OK):
        raise ProfileError("profile metadata is root-only; run this command with sudo")
    try:
        names = all_profile_names()
        active = read_active_name()
    except PermissionError:
        raise ProfileError("profile metadata is root-only; run this command with sudo")
    print(f"state:  {paths.root}")
    print(f"active: {active or '(none)'}")
    if not names:
        print("no profiles; use `sudo proxyctl add <name> <yaml>` or `sudo proxyctl set-url <name>`")
        return
    print("name                   local-yaml  subscription  active")
    for name in names:
        local = "yes" if profile_path(name).exists() else "no"
        source = "yes" if source_path(name).exists() else "no"
        mark = "*" if name == active else ""
        print(f"{name:<22} {local:<11} {source:<13} {mark}")


def command_status() -> None:
    paths = state_paths()
    print(f"state:  {paths.root}{'' if paths.root.is_dir() else ' (not initialized)'}")
    print(f"service: {'active' if service_active() else 'inactive'}")
    active = read_active_name()
    state_readable = paths.root.is_dir() and os.access(paths.root, os.R_OK | os.X_OK)
    if active:
        print(f"active:  {active}")
    elif paths.root.is_dir() and not state_readable:
        print("active:  (requires root to read)")
    elif paths.active_name.exists():
        print("active:  (requires root to read)")
    else:
        print("active:  (none)")
    secret_available = paths.secret.exists() and os.access(paths.secret, os.R_OK)
    print(f"api-secret: {'present' if paths.secret.exists() else 'missing'}"
          + ("" if secret_available else " (root-only)"))
    try:
        check_local_bindings()
        print(f"listeners: 127.0.0.1:{MIXED_PORT} (mixed), {API_HOST}:{API_PORT} (api)")
    except ProxyCtlError as exc:
        print(f"listeners: {exc}")
    if secret_available:
        try:
            version = api_json("GET", "/version")
            if isinstance(version, dict):
                print("api:     reachable (version " + str(version.get("version", "unknown")) + ")")
        except ApiError as exc:
            print(f"api:     {exc}")
    else:
        print("api:     run with sudo to query the local controller")


def command_test() -> None:
    target = "https://www.gstatic.com/generate_204"
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler(
            {"http": f"http://{API_HOST}:{MIXED_PORT}", "https": f"http://{API_HOST}:{MIXED_PORT}"}
        )
    )
    request = urllib.request.Request(target, method="GET", headers={"User-Agent": "proxyctl/1.0"})
    started = time.monotonic()
    try:
        with opener.open(request, timeout=15) as response:
            status = response.status
            response.read(1024)
    except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as exc:
        raise ProxyCtlError(f"proxy test failed: {describe_download_error(exc)}")
    elapsed = time.monotonic() - started
    print(f"proxy test: HTTP {status} via {API_HOST}:{MIXED_PORT} in {elapsed:.2f}s")


def command_groups() -> None:
    groups = list_groups()
    if not groups:
        raise ApiError("Mihomo returned no selector/URLTest groups")
    for name, group_type, current in groups:
        print(f"{name}\t{group_type}\t{current}")


def command_nodes(group: str) -> None:
    detail = group_detail(group)
    current = str(detail.get("now", ""))
    for node in detail.get("all", []):
        marker = "*" if str(node) == current else " "
        print(f"{marker} {node}")


def command_select(group: str, node: str) -> None:
    select_node(group, node)
    print(f"selected {node!r} in group {group!r}")


def command_logs() -> None:
    try:
        result = subprocess.run(
            ["journalctl", "-u", "mihomo.service", "-n", "100", "--no-pager"],
            check=False,
        )
    except FileNotFoundError:
        raise ProxyCtlError("journalctl not found")
    raise SystemExit(result.returncode)


def command_init() -> None:
    paths = ensure_state()
    load_or_create_secret(paths)
    print(f"initialized root-only state at {paths.root}")
    print(f"API secret: {paths.secret} (value never printed)")
    if not all_profile_names():
        print("next: sudo proxyctl add <name> <yaml-path>")
        print("  or: sudo proxyctl set-url <name> && sudo proxyctl refresh <name>")
        print("then: sudo proxyctl use <name>")


# -------------------------------------------------------------------- CLI

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="proxyctl",
        description="Manage Mihomo profiles and the local Mihomo REST API.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init", help="create root-only state and a random API secret")

    sub.add_parser("list", help="list local/subscription profiles and the active one")

    add = sub.add_parser("add", help="import a complete local Mihomo YAML profile")
    add.add_argument("name")
    add.add_argument("yaml_path")
    add.add_argument("--force", action="store_true", help="replace an existing profile")

    url = sub.add_parser("set-url", help="store an HTTPS subscription URL (interactive)")
    url.add_argument("name")

    refresh = sub.add_parser("refresh", help="download and validate a subscription profile")
    refresh.add_argument("name")
    refresh.add_argument(
        "--via-proxy",
        action="store_true",
        help=f"download through the running local proxy at {API_HOST}:{MIXED_PORT}",
    )

    use = sub.add_parser("use", help="validate and atomically activate a profile")
    use.add_argument("name")

    sub.add_parser("status", help="show service, listener and active-profile status")
    sub.add_parser("test", help="test the local mixed proxy against an HTTPS endpoint")
    sub.add_parser("logs", help="show the last 100 journal entries for mihomo")

    sub.add_parser("groups", help="list proxy groups and their current selection")
    nodes = sub.add_parser("nodes", help="list candidates in a proxy group")
    nodes.add_argument("group")
    select = sub.add_parser("select", help="select a node in a proxy group")
    select.add_argument("group")
    select.add_argument("node")
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "init":
            require_root()
            command_init()
        elif args.command == "list":
            command_list()
        elif args.command == "add":
            require_root()
            import_profile(args.name, Path(args.yaml_path).expanduser(), args.force)
        elif args.command == "set-url":
            require_root()
            # Never read the URL from argv, shell history or a log.
            url = getpass.getpass("HTTPS subscription URL (input hidden): ").strip()
            set_subscription_url(args.name, url)
        elif args.command == "refresh":
            require_root()
            refresh_profile(args.name, args.via_proxy)
        elif args.command == "use":
            require_root()
            use_profile(args.name)
        elif args.command == "status":
            command_status()
        elif args.command == "test":
            command_test()
        elif args.command == "logs":
            command_logs()
        elif args.command == "groups":
            require_root()
            command_groups()
        elif args.command == "nodes":
            require_root()
            command_nodes(args.group)
        elif args.command == "select":
            require_root()
            command_select(args.group, args.node)
        else:
            raise ProxyCtlError(f"unknown command: {args.command}")
    except ProxyCtlError as exc:
        die(str(exc))
    except PermissionError:
        die("permission denied; this command requires root")
    except KeyboardInterrupt:
        die("interrupted", 130)


if __name__ == "__main__":
    main()
