#!/usr/bin/env python3
"""Manage runtime Caddy site fragments for nixos.20050917.xyz.

Business sites are not declared in services.caddy.virtualHosts. They live in
/etc/caddy/sites-enabled and are imported by the NixOS-generated Caddyfile, so
adding or removing a normal Docker service never needs nixos-rebuild.

The command only accepts one DNS label and a loopback TCP port. It validates
the complete generated Caddyfile with `caddy validate`, then reloads Caddy. A
failed validation or reload restores the previous fragment.
"""

from __future__ import annotations

import argparse
import fcntl
import grp
import os
import re
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

BASE_DOMAIN = "20050917.xyz"
RESERVED_NAMES = frozenset({"nixos"})
DEFAULT_SITES_DIR = Path("/etc/caddy/sites-enabled")
DEFAULT_CADDY_CONFIG = Path("/etc/caddy/caddy_config")
DEFAULT_ACME_DIR = Path("/var/lib/acme/20050917.xyz")
DEFAULT_CADDY_GROUP = "caddy"
DEFAULT_CADDY = "caddy"
DEFAULT_SYSTEMCTL = "systemctl"
COMMAND_TIMEOUT = 45

MIN_PORT = 1024
MAX_PORT = 65535
# Never route these through the public HTTPS ingress. Ports 22/80/443 are
# already below MIN_PORT; the rest are local control or database services.
DENIED_PORTS = frozenset(
    {
        2019,  # Caddy admin API
        2375,  # Docker TCP (must never be enabled)
        2376,  # Docker TLS (must never be enabled)
        3306,  # MySQL/MariaDB
        5432,  # PostgreSQL
        6379,  # Redis
        7897,  # Mihomo mixed proxy
        9090,  # Mihomo API
        9091,
        11211,  # memcached
        27017,  # MongoDB
    }
)

NAME_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
MANAGED_HEADER = "# Managed by ingressctl; manual changes will be overwritten."
LOCK_NAME = ".ingressctl.lock"


class IngressError(Exception):
    """A user-visible failure; no success message may be printed."""


class ValidationError(IngressError):
    pass


class ReloadError(IngressError):
    pass


@dataclass(frozen=True)
class Route:
    name: str
    port: int
    path: Path


def validate_name(name: str) -> str:
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise IngressError(
            "route name must be a single lowercase DNS label "
            "(letters, digits and hyphens, 1-63 characters)"
        )
    if name in RESERVED_NAMES:
        raise IngressError(f"route name {name!r} is reserved")
    return name


def validate_port(value: int | str) -> int:
    if isinstance(value, bool):
        raise IngressError("port must be an integer")
    try:
        port = int(value)
    except (TypeError, ValueError):
        raise IngressError("port must be an integer") from None
    if str(value).strip() != str(port):
        raise IngressError("port must be a plain integer")
    if port < MIN_PORT or port > MAX_PORT:
        raise IngressError(f"port must be between {MIN_PORT} and {MAX_PORT}")
    if port in DENIED_PORTS:
        raise IngressError(f"port {port} is reserved for a local/system service")
    return port


def route_domain(name: str) -> str:
    return f"{validate_name(name)}.{BASE_DOMAIN}"


def render_site(name: str, port: int, *, acme_dir: Path = DEFAULT_ACME_DIR) -> str:
    name = validate_name(name)
    port = validate_port(port)
    return (
        f"{MANAGED_HEADER}\n\n"
        f"{name}.{BASE_DOMAIN} {{\n"
        f"    tls {acme_dir}/fullchain.pem {acme_dir}/key.pem\n"
        f"    encode zstd gzip\n"
        f"    reverse_proxy 127.0.0.1:{port}\n"
        f"}}\n"
    )


def _mode_allows(
    info: os.stat_result, group_id: int, group_bit: int, other_bit: int
) -> bool:
    if info.st_mode & other_bit:
        return True
    return info.st_gid == group_id and bool(info.st_mode & group_bit)


def _ancestors(path: Path) -> Iterator[Path]:
    current = path
    while True:
        yield current
        if current.parent == current:
            break
        current = current.parent


def _read_site(path: Path) -> Route | None:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None
    if not text.startswith(MANAGED_HEADER):
        return None
    host = re.search(
        rf"(?m)^([a-z0-9](?:[a-z0-9-]{{0,61}}[a-z0-9])?)\.{re.escape(BASE_DOMAIN)} \{{$",
        text,
    )
    upstream = re.search(r"(?m)^\s+reverse_proxy 127\.0\.0\.1:(\d+)$", text)
    if host is None or upstream is None:
        return None
    try:
        name = validate_name(host.group(1))
        port = validate_port(upstream.group(1))
    except IngressError:
        return None
    return Route(name=name, port=port, path=path)


class IngressManager:
    def __init__(
        self,
        *,
        sites_dir: str | Path | None = None,
        caddy_config: str | Path | None = None,
        acme_dir: str | Path | None = None,
        caddy_bin: str | None = None,
        systemctl_bin: str | None = None,
        caddy_group: str | None = None,
        timeout: int = COMMAND_TIMEOUT,
    ) -> None:
        self.sites_dir = Path(
            sites_dir or os.environ.get("INGRESSCTL_SITES_DIR", DEFAULT_SITES_DIR)
        )
        self.caddy_config = Path(
            caddy_config
            or os.environ.get("INGRESSCTL_CADDY_CONFIG", DEFAULT_CADDY_CONFIG)
        )
        self.acme_dir = Path(
            acme_dir or os.environ.get("INGRESSCTL_ACME_DIR", DEFAULT_ACME_DIR)
        )
        self.caddy_bin = caddy_bin or os.environ.get(
            "INGRESSCTL_CADDY", DEFAULT_CADDY
        )
        self.systemctl_bin = systemctl_bin or os.environ.get(
            "INGRESSCTL_SYSTEMCTL", DEFAULT_SYSTEMCTL
        )
        self.caddy_group = caddy_group or os.environ.get(
            "INGRESSCTL_CADDY_GROUP", DEFAULT_CADDY_GROUP
        )
        self.timeout = timeout
        self.lock_path = self.sites_dir / LOCK_NAME

    # ---------------------------------------------------------------- safety

    def _check_directory(self, path: Path, *, label: str) -> None:
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            raise IngressError(
                f"{label} is missing: {path}; deploy ingress.nix first"
            ) from None
        except OSError as exc:
            raise IngressError(f"cannot inspect {label} {path}: {exc.strerror}") from None
        if not stat.S_ISDIR(info.st_mode):
            raise IngressError(f"{label} is not a real directory: {path}")
        if info.st_uid != os.geteuid():
            raise IngressError(
                f"{label} must be owned by the invoking user (root in production): {path}"
            )
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise IngressError(f"{label} must not be group/world writable: {path}")

    def check_sites_dir(self) -> None:
        self._check_directory(self.sites_dir, label="sites directory")
        self._check_directory(self.sites_dir.parent, label="sites parent directory")

    def _target(self, name: str) -> Path:
        validate_name(name)
        return self.sites_dir / f"{name}.caddy"

    def _assert_safe_target(self, target: Path) -> None:
        try:
            info = os.lstat(target)
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode):
            raise IngressError(f"refusing symbolic-link route target: {target}")
        if not stat.S_ISREG(info.st_mode):
            raise IngressError(f"refusing non-regular route target: {target}")
        if info.st_uid != os.geteuid():
            raise IngressError(f"route file has an unexpected owner: {target}")
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise IngressError(f"route file must not be group/world writable: {target}")

    @contextmanager
    def _locked(self) -> Iterator[None]:
        self.check_sites_dir()
        flags = os.O_CREAT | os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(self.lock_path, flags, 0o600)
        except OSError as exc:
            raise IngressError(
                f"cannot open lock file {self.lock_path}: {exc.strerror}"
            ) from None
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                raise IngressError(f"unsafe lock file: {self.lock_path}")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise IngressError(
                    "another ingressctl operation is in progress"
                ) from None
            yield
        finally:
            os.close(fd)

    def _fsync_directory(self) -> None:
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        fd = os.open(self.sites_dir, flags)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def _write_atomic(self, target: Path, data: bytes) -> None:
        fd, temporary_name = tempfile.mkstemp(
            prefix=f".{target.name}.", suffix=".tmp", dir=self.sites_dir
        )
        temporary = Path(temporary_name)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o644)
            os.replace(temporary, target)
            self._fsync_directory()
        except Exception:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
            raise

    def _restore(self, target: Path, previous: bytes | None) -> None:
        if previous is None:
            try:
                target.unlink()
            except FileNotFoundError:
                return
            self._fsync_directory()
        else:
            self._write_atomic(target, previous)

    # ------------------------------------------------------------ validation

    def check_certificate(self) -> None:
        success_marker = self.acme_dir / "acme-success"
        if not success_marker.is_file():
            raise IngressError(
                f"{success_marker} is missing; the wildcard certificate has not been "
                "issued successfully yet, so publishing HTTPS now would serve the "
                "self-signed placeholder"
            )
        try:
            group_id = grp.getgrnam(self.caddy_group).gr_gid
        except KeyError:
            raise IngressError(f"group {self.caddy_group!r} does not exist") from None

        for directory in reversed(list(_ancestors(self.acme_dir))):
            try:
                info = os.stat(directory)
            except OSError as exc:
                raise IngressError(
                    f"cannot inspect certificate path {directory}: {exc.strerror}"
                ) from None
            if not stat.S_ISDIR(info.st_mode):
                raise IngressError(f"certificate path is not a directory: {directory}")
            if not _mode_allows(info, group_id, stat.S_IXGRP, stat.S_IXOTH):
                raise IngressError(
                    f"group {self.caddy_group!r} cannot traverse certificate directory "
                    f"{directory}; check ACME group permissions"
                )

        for filename in ("fullchain.pem", "key.pem"):
            path = self.acme_dir / filename
            try:
                info = os.lstat(path)
            except FileNotFoundError:
                raise IngressError(f"certificate file is missing: {path}") from None
            except OSError as exc:
                raise IngressError(
                    f"cannot inspect certificate file {path}: {exc.strerror}"
                ) from None
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                raise IngressError(f"certificate file is not a regular file: {path}")
            if info.st_size == 0:
                raise IngressError(f"certificate file is empty: {path}")
            if not _mode_allows(info, group_id, stat.S_IRGRP, stat.S_IROTH):
                raise IngressError(
                    f"group {self.caddy_group!r} cannot read certificate file {path}"
                )

    def _run(self, command: list[str], *, label: str) -> subprocess.CompletedProcess[str]:
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=self.timeout,
                check=False,
            )
        except FileNotFoundError:
            raise IngressError(f"{label}: command not found: {command[0]}") from None
        except subprocess.TimeoutExpired:
            raise IngressError(f"{label}: command timed out") from None
        except OSError as exc:
            raise IngressError(f"{label}: {exc.__class__.__name__}") from None
        return completed

    @staticmethod
    def _detail(completed: subprocess.CompletedProcess[str]) -> str:
        output = (completed.stderr or completed.stdout or "").strip()
        if len(output) > 4000:
            output = output[-4000:]
        return output

    def validate_config(self) -> None:
        completed = self._run(
            [
                self.caddy_bin,
                "validate",
                "--config",
                str(self.caddy_config),
                "--adapter",
                "caddyfile",
            ],
            label="caddy validate",
        )
        if completed.returncode != 0:
            detail = self._detail(completed)
            raise ValidationError(
                "generated Caddy configuration is invalid (exit "
                f"{completed.returncode})"
                + (f": {detail}" if detail else "")
            )

    def reload_caddy(self) -> None:
        completed = self._run(
            [self.systemctl_bin, "reload", "caddy"],
            label="systemctl reload caddy",
        )
        if completed.returncode != 0:
            detail = self._detail(completed)
            raise ReloadError(
                f"Caddy reload failed (exit {completed.returncode})"
                + (f": {detail}" if detail else "")
            )

    # ---------------------------------------------------------------- routes

    def list_sites(self) -> list[Route]:
        if not self.sites_dir.is_dir():
            return []
        routes: list[Route] = []
        for path in sorted(self.sites_dir.glob("*.caddy")):
            if path.is_symlink() or not path.is_file():
                continue
            route = _read_site(path)
            if route is not None:
                routes.append(route)
        return routes

    def _rollback(
        self,
        target: Path,
        previous: bytes | None,
        failure: Exception,
    ) -> None:
        try:
            self._restore(target, previous)
        except Exception as restore_exc:  # noqa: BLE001
            raise IngressError(
                f"{failure}; rollback of {target} failed: {restore_exc}"
            ) from None
        if isinstance(failure, ReloadError):
            try:
                self.reload_caddy()
            except Exception as reload_exc:  # noqa: BLE001
                raise IngressError(
                    f"{failure}; old route file was restored but Caddy could not "
                    f"reload it: {reload_exc}"
                ) from None
        raise IngressError(str(failure)) from None

    def publish(self, name: str, port: int | str, *, force: bool = False) -> Route:
        name = validate_name(name)
        port = validate_port(port)
        self.check_certificate()
        target = self._target(name)
        with self._locked():
            self._assert_safe_target(target)
            previous: bytes | None = None
            if target.exists():
                if not force:
                    raise IngressError(
                        f"route already exists: {target}; use --force to replace it"
                    )
                previous = target.read_bytes()

            content = render_site(name, port, acme_dir=self.acme_dir).encode("utf-8")
            if previous == content:
                print(f"route unchanged: {route_domain(name)} -> 127.0.0.1:{port}")
                return Route(name=name, port=port, path=target)

            try:
                self._write_atomic(target, content)
                self.validate_config()
                self.reload_caddy()
            except Exception as exc:  # noqa: BLE001
                self._rollback(target, previous, exc)
                raise AssertionError("unreachable") from None

            print(f"published route: {route_domain(name)} -> 127.0.0.1:{port}")
            return Route(name=name, port=port, path=target)

    def remove(self, name: str) -> None:
        name = validate_name(name)
        target = self._target(name)
        with self._locked():
            self._assert_safe_target(target)
            if not target.exists():
                raise IngressError(f"route does not exist: {target}")
            previous = target.read_bytes()
            try:
                target.unlink()
                self._fsync_directory()
                self.validate_config()
                self.reload_caddy()
            except Exception as exc:  # noqa: BLE001
                self._rollback(target, previous, exc)
                raise AssertionError("unreachable") from None
            print(f"removed route: {route_domain(name)}")

    def check(self) -> None:
        self.check_certificate()
        with self._locked():
            for path in sorted(self.sites_dir.glob("*.caddy")):
                self._assert_safe_target(path)
            self.validate_config()
        print("configuration valid; certificate readable by Caddy")

    def status(self) -> int:
        healthy = True
        marker = self.acme_dir / "acme-success"
        print(f"acme directory: {self.acme_dir}")
        if os.geteuid() == 0:
            print(f"certificate issued: {'yes' if marker.is_file() else 'no'}")
            try:
                self.check_certificate()
            except IngressError as exc:
                healthy = False
                print(f"certificate check: FAILED: {exc}")
            else:
                print("certificate check: ok")
        else:
            print(
                "certificate check: requires root; run "
                "'sudo ingressctl status' for file/group verification"
            )

        routes = self.list_sites()
        print(f"enabled routes: {len(routes)}")
        for route in routes:
            print(f"  {route_domain(route.name)} -> 127.0.0.1:{route.port}")
        if not routes:
            print("  (none)")

        completed = self._run(
            [self.systemctl_bin, "is-active", "caddy"],
            label="systemctl is-active caddy",
        )
        active = completed.returncode == 0
        state = (completed.stdout or "").strip() or "unknown"
        print(f"caddy service: {'active' if active else 'inactive'} ({state})")
        if not active:
            healthy = False
        return 0 if healthy else 1


def require_root() -> None:
    if os.geteuid() != 0:
        raise IngressError("this command must be run as root; use sudo")


def _print_routes(routes: list[Route]) -> None:
    if not routes:
        print("no enabled routes")
        return
    for route in routes:
        print(f"{route_domain(route.name)}\t127.0.0.1:{route.port}\t{route.path}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Publish or remove dynamic Caddy routes for 20050917.xyz."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list", help="list enabled routes")
    subparsers.add_parser("status", help="show certificate, routes and Caddy state")
    subparsers.add_parser("check", help="validate the complete Caddy configuration")

    publish_parser = subparsers.add_parser(
        "publish", help="publish NAME.20050917.xyz to 127.0.0.1:PORT"
    )
    publish_parser.add_argument("name")
    publish_parser.add_argument("port")
    publish_parser.add_argument(
        "--force",
        action="store_true",
        help="replace an existing route with the same name",
    )

    remove_parser = subparsers.add_parser("remove", help="remove a published route")
    remove_parser.add_argument("name")

    args = parser.parse_args(argv)
    manager = IngressManager()

    try:
        if args.command == "list":
            _print_routes(manager.list_sites())
            return 0
        if args.command == "status":
            return manager.status()
        if args.command == "check":
            require_root()
            manager.check()
            return 0
        if args.command == "publish":
            require_root()
            manager.publish(args.name, args.port, force=args.force)
            return 0
        if args.command == "remove":
            require_root()
            manager.remove(args.name)
            return 0
    except IngressError as exc:
        print(f"ingressctl: error: {exc}", file=sys.stderr)
        return 1

    parser.error(f"unknown command {args.command!r}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
