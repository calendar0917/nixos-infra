#!/usr/bin/env python3
"""Static checks for the headless Docker/Compose foundation.

The tests parse the Compose example and evaluate the NixOS configuration. They
do not start containers, touch the Docker socket, or change the running system.
"""

import json
import re
import subprocess
import unittest
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
COMPOSE = REPO / "deploy/nixos-smoke/compose.yaml"
NIXOS_DEFAULT = REPO / "hosts/nixos/default.nix"
DOCKER_NIX = REPO / "hosts/nixos/docker.nix"


class ServerDockerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = yaml.safe_load(COMPOSE.read_text(encoding="utf-8"))
        cls.service = cls.document["services"]["smoke"]

        expression = f"""
        let
          flake = builtins.getFlake "git+file:{REPO}";
          nixos = flake.nixosConfigurations.nixos.config;
          main = flake.nixosConfigurations.main.config;
        in {{
          dockerEnable = nixos.virtualisation.docker.enable;
          dockerOnBoot = nixos.virtualisation.docker.enableOnBoot;
          listenOptions = nixos.virtualisation.docker.listenOptions;
          daemonSettings = nixos.virtualisation.docker.daemon.settings;
          dockerAfter = nixos.systemd.services.docker.after;
          dockerRequires = nixos.systemd.services.docker.requires;
          dockerWants = nixos.systemd.services.docker.wants;
          dockerEnvironment = nixos.systemd.services.docker.environment;
          userGroups = nixos.users.users.calendar.extraGroups;
          firewallTcpPorts = nixos.networking.firewall.allowedTCPPorts;
          mainDockerEnable = main.virtualisation.docker.enable;
          mainDockerProxy = main.systemd.services.docker.environment.HTTP_PROXY;
        }}
        """
        result = subprocess.run(
            ["nix", "eval", "--json", "--impure", "--expr", expression],
            cwd=REPO,
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                "nix eval failed:\n" + (result.stderr or result.stdout).strip()
            )
        cls.nix = json.loads(result.stdout)

    def test_compose_project_and_fixed_image(self) -> None:
        self.assertEqual(self.document["name"], "nixos-smoke")
        image = self.service["image"]
        self.assertEqual(image, "nginx:1.27.4-alpine")
        self.assertNotRegex(image, r"(^|:)latest$")

    def test_compose_binds_only_loopback(self) -> None:
        self.assertEqual(self.service["ports"], ["127.0.0.1:18080:80"])
        self.assertNotIn("network_mode", self.service)
        self.assertNotIn("privileged", self.service)
        self.assertFalse(self.service.get("privileged", False))

    def test_compose_has_security_and_resource_limits(self) -> None:
        self.assertTrue(self.service["read_only"])
        self.assertIn("no-new-privileges:true", self.service["security_opt"])
        self.assertNotIn("volumes", self.service)
        self.assertNotIn("devices", self.service)
        self.assertNotIn("cap_add", self.service)
        self.assertEqual(self.service["mem_limit"], "128m")
        self.assertEqual(self.service["pids_limit"], 64)
        self.assertEqual(self.service["cpus"], "0.50")

        tmpfs = self.service["tmpfs"]
        for required in ("/var/cache/nginx", "/var/run", "/tmp"):
            self.assertTrue(
                any(entry.startswith(required) for entry in tmpfs),
                f"missing tmpfs for {required}: {tmpfs}",
            )

    def test_compose_restarts_and_rotates_logs(self) -> None:
        self.assertEqual(self.service["restart"], "unless-stopped")
        logging = self.service["logging"]
        self.assertEqual(logging["driver"], "json-file")
        self.assertEqual(logging["options"]["max-size"], "10m")
        self.assertEqual(logging["options"]["max-file"], "3")

    def test_module_is_imported_and_uses_bounded_logs(self) -> None:
        self.assertIn("./docker.nix", NIXOS_DEFAULT.read_text(encoding="utf-8"))
        source = DOCKER_NIX.read_text(encoding="utf-8")
        self.assertIn("enable = true", source)
        self.assertIn("enableOnBoot = true", source)
        self.assertIn('logDriver = "json-file"', source)
        self.assertIn('"max-size" = "10m"', source)
        self.assertIn('"max-file" = "3"', source)
        self.assertIn("pkgs.nftables", source)
        self.assertIn("/srv/containers", source)

    def test_docker_is_enabled_and_has_no_tcp_api(self) -> None:
        self.assertTrue(self.nix["dockerEnable"])
        self.assertTrue(self.nix["dockerOnBoot"])
        self.assertEqual(self.nix["listenOptions"], ["/run/docker.sock"])
        self.assertEqual(self.nix["daemonSettings"]["hosts"], ["fd://"])
        self.assertFalse(
            any("tcp" in item.lower() for item in self.nix["listenOptions"])
        )
        self.assertEqual(
            self.nix["daemonSettings"]["log-driver"], "json-file"
        )
        self.assertEqual(
            self.nix["daemonSettings"]["log-opts"],
            {"max-size": "10m", "max-file": "3"},
        )

    def test_docker_proxy_is_local_and_not_a_mihomo_dependency(self) -> None:
        env = self.nix["dockerEnvironment"]
        self.assertEqual(env["HTTP_PROXY"], "http://127.0.0.1:7897")
        self.assertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7897")
        self.assertIn("100.64.0.0/10", env["NO_PROXY"])
        for dependency in (
            self.nix["dockerAfter"]
            + self.nix["dockerRequires"]
            + self.nix["dockerWants"]
        ):
            self.assertNotEqual(dependency, "mihomo.service")
            self.assertNotEqual(dependency, "campus-login.service")

    def test_user_is_not_in_docker_group_and_only_ingress_ports_are_opened(self) -> None:
        self.assertNotIn("docker", self.nix["userGroups"])
        ports = set(self.nix["firewallTcpPorts"])
        self.assertNotIn(18080, ports)
        self.assertNotIn(7897, ports)
        self.assertNotIn(9090, ports)
        self.assertNotIn(2375, ports)
        self.assertNotIn(2376, ports)
        self.assertNotIn(5432, ports)
        # Stage 3 adds the host Caddy entry. Docker itself still exposes no
        # public container port; 80/443 are owned by the NixOS Caddy service.
        self.assertIn(80, ports)
        self.assertIn(443, ports)

    def test_main_docker_behavior_is_unchanged(self) -> None:
        self.assertTrue(self.nix["mainDockerEnable"])
        self.assertEqual(
            self.nix["mainDockerProxy"], "http://127.0.0.1:7897"
        )

    def test_docs_and_example_exist(self) -> None:
        for path in (
            REPO / "docs/SERVER_DOCKER.md",
            REPO / "deploy/nixos-smoke/README.md",
        ):
            self.assertTrue(path.is_file(), path)
            self.assertGreater(path.stat().st_size, 0)
        docs = (REPO / "docs/SERVER_DOCKER.md").read_text(encoding="utf-8")
        self.assertIn("127.0.0.1:18080", docs)
        self.assertIn("/srv/containers", docs)
        self.assertIn("down -v", docs)
        # The image name must be documented as a pinned tag, not a floating one.
        self.assertIsNone(re.search(r"nginx:latest", docs))


if __name__ == "__main__":
    unittest.main(verbosity=2)
