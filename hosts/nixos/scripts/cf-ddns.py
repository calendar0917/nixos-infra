#!/usr/bin/env python3
"""Cloudflare IPv6 DDNS for nixos.20050917.xyz.

The address is derived from the current IPv6 default route and the addresses
on that physical interface. External "what is my IP" services are deliberately
not used: the host can have campus, Docker, Tailscale and privacy addresses at
the same time.

The Cloudflare API token and zone ID are read from systemd credentials when
available, with /etc/cloudflare as the manual-run fallback. Neither value is
ever written to stdout, stderr or the Nix store.

The script can be run manually for inspection:

    sudo python3 cf-ddns.py --dry-run

Exit status 0 means either a successful reconciliation or "no usable IPv6",
which leaves DNS untouched. Any configuration, API or ambiguity error exits 1
so the systemd timer reports a failure and retries on its next run.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import logging
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

try:
    import requests
except ImportError:
    sys.stderr.write("cloudflare-ddns: the requests module is missing\n")
    raise SystemExit(78)

LOG = logging.getLogger("cloudflare-ddns")

RECORD_NAME = "nixos.20050917.xyz"
ZONE_NAME = "20050917.xyz"
RECORD_TTL = 120

DEFAULT_CREDENTIALS_DIR = Path("/etc/cloudflare")
DEFAULT_API_BASE = "https://api.cloudflare.com/client/v4"
# The only proxy mode this service may use. It is selected with an optional
# /etc/cloudflare/ddns.env (CF_DDNS_PROXY=...) and never by changing routes or
# enabling a TUN device.
ALLOWED_PROXY = "http://127.0.0.1:7897"
DEFAULT_REQUEST_TIMEOUT = 15.0

ZONE_ID_RE = re.compile(r"^[0-9a-f]{32}$", re.IGNORECASE)

# Interfaces that must never be used as the public uplink. Match names, not
# routes: the route's preferred source can still be a privacy address.
VIRTUAL_INTERFACE_PREFIXES = (
    "docker",
    "veth",
    "br-",
    "virbr",
    "vnet",
    "tailscale",
    "tun",
    "tap",
    "wg",
    "zt",
    "cni",
    "flannel",
    "kube",
    "podman",
    "meta",
    "mihomo",
    "clash",
    "dummy",
    "ifb",
    "vxlan",
    "gre",
    "sit",
    "ip6tnl",
    "lxc",
    "lxd",
    "incus",
    "qemu",
    "vmnet",
)


class DdnsError(Exception):
    """Base class for errors that should be visible in the journal."""


class CredentialError(DdnsError):
    pass


class AddressSelectionError(DdnsError):
    pass


class CommandError(DdnsError):
    pass


class CloudflareError(DdnsError):
    pass


class ConflictError(CloudflareError):
    pass


@dataclass(frozen=True)
class Credentials:
    token: str
    zone_id: str


@dataclass(frozen=True)
class SyncResult:
    action: str
    record_id: str | None
    content: str
    previous: str | None = None


def redact_secret(message: object, secret: str | None) -> str:
    text = str(message)
    if secret:
        text = text.replace(secret, "[redacted]")
    return text


def is_virtual_interface(name: str) -> bool:
    if not name or name in { "lo", "lo0" }:
        return True
    return name.startswith(VIRTUAL_INTERFACE_PREFIXES)


def _metric(route: dict[str, Any]) -> int:
    try:
        return int(route.get("metric", 0))
    except (TypeError, ValueError):
        return 0


def select_uplink(default_routes: Iterable[dict[str, Any]]) -> str | None:
    """Pick the physical interface with the lowest IPv6 default-route metric.

    NetworkManager owns the metrics. A tie between different physical
    interfaces is ambiguous and must not be guessed: the caller leaves DNS
    untouched and asks a human to inspect `ip -6 route show default`.
    """
    candidates: list[tuple[int, str]] = []
    for route in default_routes:
        if route.get("dst") not in (None, "default"):
            continue
        device = route.get("dev")
        if not isinstance(device, str) or not device:
            continue
        if is_virtual_interface(device):
            continue
        candidates.append((_metric(route), device))

    if not candidates:
        return None

    best_metric = min(metric for metric, _ in candidates)
    best_devices = {device for metric, device in candidates if metric == best_metric}
    if len(best_devices) != 1:
        raise AddressSelectionError(
            "ambiguous IPv6 default route with equal metric on "
            + ", ".join(sorted(best_devices))
        )
    return best_devices.pop()


def _flag_is_set(info: dict[str, Any], flag: str) -> bool:
    value = info.get(flag)
    if value is True:
        return True
    flags = info.get("flags")
    if isinstance(flags, list):
        return flag in flags
    if isinstance(flags, str):
        return flag in {part.strip() for part in flags.split(",")}
    return False


def _is_usable_global(value: str) -> bool:
    try:
        address = ipaddress.IPv6Address(value.split("%", 1)[0])
    except ValueError:
        return False
    return not (
        address.is_unspecified
        or address.is_loopback
        or address.is_link_local
        or address.is_multicast
        or address.is_private
        or not address.is_global
    )


def select_ipv6(addresses: Iterable[dict[str, Any]], interface: str) -> str | None:
    """Return the single stable global IPv6 address on *interface*.

    Temporary privacy addresses, deprecated/tentative addresses, ULA,
    link-local and multicast addresses are ignored. More than one remaining
    stable address is ambiguous; refusing is safer than publishing a stale or
    privacy address.
    """
    candidates: set[str] = set()
    for link in addresses:
        if link.get("ifname") != interface:
            continue
        for info in link.get("addr_info", []):
            if info.get("family") != "inet6":
                continue
            if info.get("scope") != "global":
                continue
            if any(
                _flag_is_set(info, flag)
                for flag in ("temporary", "deprecated", "tentative", "dadfailed")
            ):
                continue
            local = info.get("local")
            if not isinstance(local, str):
                continue
            if not _is_usable_global(local):
                continue
            candidates.add(str(ipaddress.IPv6Address(local.split("%", 1)[0])))

    if not candidates:
        return None
    if len(candidates) > 1:
        raise AddressSelectionError(
            f"multiple stable global IPv6 addresses on {interface}: "
            + ", ".join(sorted(candidates))
        )
    return candidates.pop()


def run_ip_json(arguments: list[str], ip_bin: str = "ip") -> Any:
    try:
        completed = subprocess.run(
            [ip_bin, "-j", "-6", *arguments],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CommandError(f"failed to run {ip_bin}: {exc.__class__.__name__}") from None
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise CommandError(
            f"{ip_bin} {' '.join(arguments)} failed"
            + (f": {detail}" if detail else "")
        )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        raise CommandError(f"{ip_bin} returned invalid JSON") from None


def get_ipv6(ip_bin: str = "ip") -> tuple[str | None, str | None]:
    routes = run_ip_json(["route", "show", "default"], ip_bin=ip_bin)
    if not isinstance(routes, list):
        raise CommandError("ip route returned an unexpected JSON type")
    interface = select_uplink(routes)
    if interface is None:
        return None, None

    addresses = run_ip_json(["addr", "show", "dev", interface], ip_bin=ip_bin)
    if not isinstance(addresses, list):
        raise CommandError("ip addr returned an unexpected JSON type")
    return interface, select_ipv6(addresses, interface)


def _credential_directory() -> Path:
    from_systemd = os.environ.get("CREDENTIALS_DIRECTORY")
    if from_systemd:
        return Path(from_systemd)
    return DEFAULT_CREDENTIALS_DIR


def _read_secret_file(path: Path) -> str:
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise CredentialError(f"missing credential file: {path}") from None
    except OSError as exc:
        raise CredentialError(f"cannot inspect credential file {path}: {exc.strerror}") from None
    if not path.is_file() or path.is_symlink():
        raise CredentialError(f"credential is not a regular file: {path}")
    if info.st_size == 0:
        raise CredentialError(f"credential file is empty: {path}")
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise CredentialError(f"cannot read credential file {path}: {exc.strerror}") from None
    if not value:
        raise CredentialError(f"credential file is empty: {path}")
    if info.st_mode & 0o077:
        LOG.warning("credential file %s is readable by group/other; expected 0600", path)
    return value


def load_credentials(credentials_dir: str | Path | None = None) -> Credentials:
    root = Path(credentials_dir) if credentials_dir is not None else _credential_directory()
    token = _read_secret_file(root / "token")
    zone_id = _read_secret_file(root / "zone-id")
    if not ZONE_ID_RE.fullmatch(zone_id):
        raise CredentialError(
            f"zone-id in {root / 'zone-id'} is not a 32-character hexadecimal Cloudflare zone ID"
        )
    return Credentials(token=token, zone_id=zone_id)


def load_proxy() -> str | None:
    value = (os.environ.get("CF_DDNS_PROXY") or "").strip()
    if not value:
        return None
    if value != ALLOWED_PROXY:
        raise CredentialError(
            f"CF_DDNS_PROXY must be empty or {ALLOWED_PROXY}; refusing {value!r}"
        )
    return value


class CloudflareClient:
    def __init__(
        self,
        token: str,
        zone_id: str,
        *,
        api_base: str = DEFAULT_API_BASE,
        proxy: str | None = None,
        timeout: float = DEFAULT_REQUEST_TIMEOUT,
        session: requests.Session | None = None,
    ) -> None:
        if not token:
            raise CredentialError("Cloudflare API token is empty")
        if proxy is not None and proxy != ALLOWED_PROXY:
            raise CredentialError(f"refusing unexpected proxy {proxy!r}")
        self._token = token
        self._zone_id = zone_id
        self._api_base = api_base.rstrip("/")
        self._timeout = timeout
        self._session = session or requests.Session()
        self._session.trust_env = False
        self._session.proxies = (
            {"http": proxy, "https": proxy} if proxy is not None else {}
        )
        self._session.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            }
        )

    def __repr__(self) -> str:
        return f"CloudflareClient(zone_id={self._zone_id!r})"

    def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
    ) -> Any:
        url = f"{self._api_base}/zones/{self._zone_id}{path}"
        try:
            response = self._session.request(
                method,
                url,
                params=params,
                json=body,
                timeout=self._timeout,
            )
        except requests.Timeout:
            raise CloudflareError(
                "Cloudflare API request timed out; the next timer run will retry"
            ) from None
        except requests.RequestException as exc:
            raise CloudflareError(
                f"Cloudflare API request failed ({exc.__class__.__name__}); "
                "the next timer run will retry"
            ) from None

        if response.status_code == 429:
            raise CloudflareError(
                "Cloudflare API rate limited (HTTP 429); the next timer run will retry"
            )
        if response.status_code >= 500:
            raise CloudflareError(
                f"Cloudflare API returned HTTP {response.status_code}; "
                "the next timer run will retry"
            )

        try:
            payload = response.json()
        except ValueError:
            raise CloudflareError(
                f"Cloudflare API returned non-JSON data (HTTP {response.status_code})"
            ) from None
        if not isinstance(payload, dict):
            raise CloudflareError("Cloudflare API returned an unexpected JSON type")

        if not payload.get("success"):
            errors = payload.get("errors")
            details: list[str] = []
            if isinstance(errors, list):
                for error in errors:
                    if isinstance(error, dict):
                        code = error.get("code")
                        message = error.get("message")
                        details.append(
                            ": ".join(
                                str(part)
                                for part in (code, message)
                                if part not in (None, "")
                            )
                        )
            detail = "; ".join(part for part in details if part)
            raise CloudflareError(
                f"Cloudflare API rejected the request (HTTP {response.status_code})"
                + (f": {detail}" if detail else "")
            )

        if response.status_code >= 400:
            raise CloudflareError(
                f"Cloudflare API returned HTTP {response.status_code}"
            )

        result = payload.get("result")
        return result

    def list_records(self, name: str) -> list[dict[str, Any]]:
        result = self._request(
            "GET",
            "/dns_records",
            params={"name": name, "per_page": 100},
        )
        if not isinstance(result, list):
            raise CloudflareError("Cloudflare DNS record list has an unexpected type")
        return [record for record in result if isinstance(record, dict)]

    def create_aaaa(self, name: str, content: str) -> dict[str, Any]:
        result = self._request(
            "POST",
            "/dns_records",
            body={
                "type": "AAAA",
                "name": name,
                "content": content,
                "ttl": RECORD_TTL,
                "proxied": False,
            },
        )
        if not isinstance(result, dict):
            raise CloudflareError("Cloudflare create response has an unexpected type")
        return result

    def update_aaaa(self, record_id: str, content: str) -> dict[str, Any]:
        result = self._request(
            "PATCH",
            f"/dns_records/{record_id}",
            body={
                "content": content,
                "ttl": RECORD_TTL,
                "proxied": False,
            },
        )
        if not isinstance(result, dict):
            raise CloudflareError("Cloudflare update response has an unexpected type")
        return result


def _exact_name(record: dict[str, Any], name: str) -> bool:
    value = record.get("name")
    return isinstance(value, str) and value.rstrip(".").lower() == name.lower()


def _validate_existing(record: dict[str, Any], name: str) -> None:
    if record.get("type") != "AAAA":
        raise ConflictError(f"{name} has a non-AAAA record; refusing to modify it")
    if record.get("proxied") is True:
        raise ConflictError(
            f"{name} is Cloudflare-proxied; set the AAAA record to DNS only first"
        )
    content = record.get("content")
    if not isinstance(content, str) or not _is_usable_global(content):
        raise ConflictError(
            f"{name} has an unexpected AAAA content; inspect the record manually"
        )
    if not record.get("id"):
        raise ConflictError(f"{name} AAAA record has no id")


def reconcile(
    client: CloudflareClient,
    record_name: str,
    address: str,
    *,
    dry_run: bool = False,
) -> SyncResult:
    records = client.list_records(record_name)
    exact = [record for record in records if _exact_name(record, record_name)]

    cnames = [record for record in exact if record.get("type") == "CNAME"]
    if cnames:
        raise ConflictError(
            f"{record_name} already has a CNAME; remove it manually before creating AAAA"
        )

    aaaa_records = [record for record in exact if record.get("type") == "AAAA"]
    if len(aaaa_records) > 1:
        raise ConflictError(
            f"{record_name} has {len(aaaa_records)} AAAA records; "
            "refusing to guess which one to update"
        )

    if not aaaa_records:
        if dry_run:
            LOG.info("would create AAAA %s -> %s", record_name, address)
            return SyncResult("would-create", None, address)
        created = client.create_aaaa(record_name, address)
        record_id = created.get("id")
        LOG.info("created AAAA %s -> %s", record_name, address)
        return SyncResult("created", str(record_id) if record_id else None, address)

    record = aaaa_records[0]
    _validate_existing(record, record_name)
    previous = str(record.get("content", ""))
    if previous == address:
        LOG.info("AAAA %s unchanged -> %s", record_name, address)
        return SyncResult("unchanged", str(record.get("id")), address, previous)

    if dry_run:
        LOG.info("would update AAAA %s: %s -> %s", record_name, previous, address)
        return SyncResult("would-update", str(record.get("id")), address, previous)

    client.update_aaaa(str(record.get("id")), address)
    LOG.info("updated AAAA %s: %s -> %s", record_name, previous, address)
    return SyncResult("updated", str(record.get("id")), address, previous)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Update the nixos.20050917.xyz AAAA record from the host's IPv6 uplink."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show the address and planned change without writing to Cloudflare",
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="cloudflare-ddns: %(levelname)s %(message)s",
    )

    token: str | None = None
    try:
        interface, address = get_ipv6()
        if interface is None:
            LOG.warning(
                "no physical IPv6 default route; leaving %s unchanged", RECORD_NAME
            )
            return 0
        if address is None:
            LOG.warning(
                "no stable global IPv6 address on %s; leaving %s unchanged",
                interface,
                RECORD_NAME,
            )
            return 0

        credentials = load_credentials()
        token = credentials.token
        proxy = load_proxy()
        client = CloudflareClient(
            credentials.token,
            credentials.zone_id,
            proxy=proxy,
        )
        LOG.info(
            "selected interface=%s address=%s record=%s proxy=%s",
            interface,
            address,
            RECORD_NAME,
            "127.0.0.1:7897" if proxy else "direct",
        )
        result = reconcile(client, RECORD_NAME, address, dry_run=args.dry_run)
        LOG.info("result=%s record=%s", result.action, RECORD_NAME)
        return 0
    except DdnsError as exc:
        LOG.error("%s", redact_secret(exc, token))
        return 1
    except Exception as exc:  # noqa: BLE001 - never leak unexpected values to logs
        LOG.error(
            "unexpected failure (%s); leaving DNS unchanged",
            redact_secret(exc.__class__.__name__, token),
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
