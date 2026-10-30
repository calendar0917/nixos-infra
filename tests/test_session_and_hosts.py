#!/usr/bin/env python3
"""Headless regression checks for the Sway/Niri session lifecycle and host split.

Run through `scripts/check-desktop`, or directly:

    python3 tests/test_session_and_hosts.py \
      --activation /nix/store/...-home-manager-generation

`--activation` is main's built Home Manager activation package; the checks read
the real generated systemd units and session files from it. Nothing here
starts, stops, locks or reconfigures the running desktop: the exit watcher is
only executed with stub `swaymsg`/`systemctl`/`sleep` binaries.
"""

import argparse
import configparser
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
from collections import Counter
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--activation", required=True)
parser.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
args = parser.parse_args()

REPO = Path(args.repo).resolve()
ACTIVATION = Path(args.activation).resolve()
HOME_FILES = ACTIVATION / "home-files"
UNITS = HOME_FILES / ".config/systemd/user"

MAIN = "main"
MINI = "nixos"

# One evaluation per host: names of the files Home Manager would install plus
# the few option values that cannot be read from main's activation package.
EVAL_APPLY = r"""
c:
let
  h = c.config.home-manager.users.calendar;
in {
  swayConfig = baseNameOf (toString h.xdg.configFile."sway/config".source);
  fuzzelConfig = baseNameOf (toString h.xdg.configFile."fuzzel/fuzzel.ini".source);
  waybarStyle = baseNameOf (toString h.xdg.configFile."waybar/style.css".source);
  kanshiEnabled = h.services.kanshi.enable;
  kanshiManagedConfig = h.xdg.configFile ? "kanshi/config";
  kanshiTarget = h.services.kanshi.systemdTarget;
  kanshiSettings = h.services.kanshi.settings;
  kittyFontSize = h.programs.kitty.settings.font_size;
  niriUnsetEnvironment =
    c.config.systemd.user.services.niri.serviceConfig.UnsetEnvironment or [ ];
  swayUnits =
    builtins.filter (n: builtins.match "sway-.*" n != null)
      (builtins.attrNames h.systemd.user.services);
}
"""


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def unit(name: str) -> str:
    path = UNITS / name
    if not path.exists():
        fail(f"generated unit is missing: {path}")
    return read(path)


def ini_value(path: Path, section: str, key: str) -> str:
    cp = configparser.ConfigParser()
    cp.read_string(read(path))
    if not cp.has_section(section) or not cp.has_option(section, key):
        fail(f"{path.name}: missing [{section}] {key}")
    return cp.get(section, key)


def eval_host(host: str) -> dict:
    result = subprocess.run(
        [
            "nix",
            "eval",
            "--json",
            "--apply",
            EVAL_APPLY,
            f"{REPO}#nixosConfigurations.{host}",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        fail(f"nix eval for {host} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


# ---------------------------------------------------------------- host split


def test_host_split(evaluated: dict) -> None:
    main = evaluated[MAIN]
    mini = evaluated[MINI]

    assert main["swayConfig"] == "config-main", main
    assert mini["swayConfig"] == "config", mini

    assert main["fuzzelConfig"] == "fuzzel-main.ini", main
    assert mini["fuzzelConfig"] == "fuzzel.ini", mini

    assert main["waybarStyle"] == "style-sway-main.css", main
    assert mini["waybarStyle"] == "style.css", mini

    assert main["swayUnits"] == ["sway-bg", "sway-exit-watch", "sway-mako", "sway-waybar"], main
    assert mini["swayUnits"] == [], mini
    print("PASS: main and the mini host resolve their own Sway/Fuzzel/Waybar files")


def test_no_bare_exec_in_main_sway_config() -> None:
    main_config = read(HOME_FILES / ".config/sway/config")
    for helper in ("waybar", "mako", "swaybg"):
        for line in main_config.splitlines():
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            assert f"exec {helper}" not in stripped, (helper, stripped)

    # The systemd units own those processes instead.
    assert "waybar/config.jsonc" in unit("sway-waybar.service"), "waybar config path"
    assert "waybar/style.css" in unit("sway-waybar.service"), "waybar style path"
    assert "/bin/mako" in unit("sway-mako.service"), "mako exec"
    assert "background.jpg" in unit("sway-bg.service"), "wallpaper"

    # The mini host intentionally still uses its original bare exec lines.
    mini_config = REPO / "config/sway/config"
    assert "exec waybar" in read(mini_config), "mini host keeps bare exec waybar"
    print("PASS: main has no bare exec waybar/mako/swaybg; the mini host is unchanged")


def test_sway_units_bind_session_target() -> None:
    for name in (
        "sway-waybar.service",
        "sway-mako.service",
        "sway-bg.service",
        "sway-exit-watch.service",
    ):
        text = unit(name)
        assert "WantedBy=sway-session.target" in text, (name, text)
        assert "PartOf=sway-session.target" in text, (name, text)
        assert "BindsTo=sway-session.target" in text, (name, text)
        assert "After=sway-session.target" in text, (name, text)

        want_link = UNITS / "sway-session.target.wants" / name
        assert want_link.exists(), f"missing WantedBy link {want_link}"

    # The niri shell units must survive untouched and must not be reused.
    niri_units = {"waybar.service", "swaybg.service", "swaync.service"}
    for name in niri_units:
        assert (UNITS / name).exists(), f"niri unit disappeared: {name}"
        assert "niri.service" in unit(name), name

    for name in ("sway-waybar.service", "sway-mako.service", "sway-bg.service", "sway-exit-watch.service"):
        assert name not in niri_units
    print("PASS: Sway helpers bind sway-session.target and never shadow the niri units")


# ------------------------------------------------------------------ watcher

FAKE_SWAYMSG = """\
#!{python}
import os
import sys

argv = sys.argv[1:]
with open(os.environ["FAKE_CALLS"], "a", encoding="utf-8") as handle:
    handle.write("swaymsg " + " ".join(argv) + "\\n")

mode = os.environ["FAKE_SWAY_MODE"]
state_dir = os.environ["FAKE_STATE_DIR"]
subscribed = os.path.join(state_dir, "subscribed")

if "-t" in argv:
    index = argv.index("-t")
    command = argv[index + 1] if index + 1 < len(argv) else ""
    if command == "get_version":
        if mode == "never":
            sys.exit(1)
        if mode == "always":
            sys.exit(0)
        sys.exit(1 if os.path.exists(subscribed) else 0)
    if command == "subscribe":
        open(subscribed, "w", encoding="utf-8").close()
        sys.exit(0)

sys.exit(2)
"""

FAKE_SYSTEMCTL = """\
#!{python}
import os
import sys

argv = sys.argv[1:]
with open(os.environ["FAKE_CALLS"], "a", encoding="utf-8") as handle:
    handle.write("systemctl " + " ".join(argv) + "\\n")

if "--user" in argv and "is-active" in argv and argv[-1] == "niri.service":
    sys.exit(0 if os.environ.get("FAKE_NIRI_ACTIVE") == "1" else 1)

sys.exit(0)
"""


def write_exec(path: Path, text: str) -> None:
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def watcher_exec_start() -> str:
    text = unit("sway-exit-watch.service")
    for line in text.splitlines():
        if line.startswith("ExecStart="):
            return line.split("=", 1)[1].strip()
    fail("sway-exit-watch.service has no ExecStart")


def run_watcher(tmp: Path, *, niri_active: bool, sway_mode: str) -> tuple[int, list[str], str]:
    tmp.mkdir(parents=True, exist_ok=True)
    state_dir = tmp / "state"
    state_dir.mkdir(exist_ok=True)
    calls = tmp / "calls"
    calls.write_text("", encoding="utf-8")

    fake_swaymsg = tmp / "swaymsg"
    fake_systemctl = tmp / "systemctl"
    fake_sleep = tmp / "sleep"
    write_exec(fake_swaymsg, FAKE_SWAYMSG.format(python=sys.executable))
    write_exec(fake_systemctl, FAKE_SYSTEMCTL.format(python=sys.executable))
    write_exec(fake_sleep, "#!/bin/sh\nexit 0\n")

    env = os.environ.copy()
    env.update(
        {
            "SWAYSOCK": "/run/user/1000/sway-ipc.1000.999999.sock",
            "SWAY_EXIT_WATCH_SWAYMSG": str(fake_swaymsg),
            "SWAY_EXIT_WATCH_SYSTEMCTL": str(fake_systemctl),
            "SWAY_EXIT_WATCH_SLEEP": str(fake_sleep),
            "FAKE_CALLS": str(calls),
            "FAKE_STATE_DIR": str(state_dir),
            "FAKE_SWAY_MODE": sway_mode,
            "FAKE_NIRI_ACTIVE": "1" if niri_active else "0",
        }
    )

    result = subprocess.run(
        [watcher_exec_start()],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return result.returncode, calls.read_text(encoding="utf-8").splitlines(), result.stderr


def stop_calls(calls: list[str]) -> list[str]:
    return [call for call in calls if call.startswith("systemctl") and " stop " in f" {call} "]


def test_exit_watcher() -> None:
    with tempfile.TemporaryDirectory(prefix="sway-exit-watch.") as tmpdir:
        tmp = Path(tmpdir)

        # A running niri must never lose graphical-session.target.
        rc, calls, stderr = run_watcher(tmp / "niri", niri_active=True, sway_mode="gone_after_subscribe")
        assert rc == 0, (rc, stderr)
        assert "systemctl --user unset-environment SWAYSOCK" in calls, calls
        stops = stop_calls(calls)
        assert stops == ["systemctl --user --no-block stop sway-session.target"], (stops, stderr)
        assert not any("graphical-session.target" in call for call in stops), stops
        subscribe = [c for c in calls if c.startswith("swaymsg") and "subscribe" in c]
        assert subscribe and '["shutdown"]' in subscribe[0], subscribe

        # Without niri, both targets are stopped asynchronously.
        rc, calls, stderr = run_watcher(tmp / "plain", niri_active=False, sway_mode="gone_after_subscribe")
        assert rc == 0, (rc, stderr)
        stops = stop_calls(calls)
        assert stops == [
            "systemctl --user --no-block stop sway-session.target graphical-session.target"
        ], (stops, stderr)

        # Sway still answering after the subscription ended: retry, do not stop.
        rc, calls, stderr = run_watcher(tmp / "alive", niri_active=False, sway_mode="always")
        assert rc != 0, (rc, stderr)
        assert stop_calls(calls) == [], calls
        assert not any("unset-environment" in call for call in calls), calls

        # IPC never reachable: also a retry, never a teardown.
        rc, calls, stderr = run_watcher(tmp / "dead", niri_active=False, sway_mode="never")
        assert rc != 0, (rc, stderr)
        assert stop_calls(calls) == [], calls

    script = read(Path(watcher_exec_start()))
    for forbidden in ("pkill", "killall", "kill -"):
        assert forbidden not in script, (forbidden, script)
    print("PASS: the exit watcher never stops graphical-session.target while niri runs")


# --------------------------------------------------------------- inheritance


def test_niri_does_not_inherit_swaysock(evaluated: dict) -> None:
    assert "SWAYSOCK" in evaluated[MAIN]["niriUnsetEnvironment"], evaluated[MAIN]
    assert evaluated[MINI]["niriUnsetEnvironment"] == [], evaluated[MINI]
    print("PASS: only main's niri unit unsets SWAYSOCK")


# ------------------------------------------------------------------- kanshi


def test_kanshi_config_stays_writable() -> None:
    assert not (HOME_FILES / ".config/kanshi/config").exists(), (
        "Home Manager must not install ~/.config/kanshi/config"
    )
    want_link = UNITS / "graphical-session.target.wants/kanshi.service"
    assert want_link.exists(), f"missing {want_link}"

    kanshi_unit = unit("kanshi.service")
    assert "PartOf=graphical-session.target" in kanshi_unit, kanshi_unit
    assert "Requires=graphical-session.target" in kanshi_unit, kanshi_unit

    # Run the real activation snippet from the generated activate script.
    activate = read(ACTIVATION / "activate")
    match = re.search(
        r'^kanshiFile=.*?^fi$',
        activate,
        flags=re.MULTILINE | re.DOTALL,
    )
    assert match, "kanshi activation block not found in the generated script"
    snippet = match.group(0)
    assert "[ ! -e \"$kanshiFile\" ]" in snippet, snippet

    with tempfile.TemporaryDirectory(prefix="kanshi-activate.") as tmpdir:
        home = Path(tmpdir)
        script = "set -euo pipefail\nrun() { \"$@\"; }\n" + snippet
        env = {"HOME": str(home), "PATH": os.environ.get("PATH", "/usr/bin:/bin")}

        def activate_once() -> subprocess.CompletedProcess:
            return subprocess.run(
                ["bash", "-c", script],
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        result = activate_once()
        assert result.returncode == 0, (result.returncode, result.stderr)
        config = home / ".config/kanshi/config"
        assert config.is_file() and not config.is_symlink(), config
        assert config.stat().st_mode & stat.S_IWUSR, "seeded config is not writable"
        assert "output eDP-1 enable" in read(config), read(config)

        saved = "profile docked {\n    output eDP-1 enable\n    output DP-1 enable\n}\n"
        config.write_text(saved, encoding="utf-8")
        result = activate_once()
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert read(config) == saved, "activation overwrote the saved Kanshi profile"
    print("PASS: kanshi config is seeded once, writable, and never overwritten")


def test_kanshi_options(evaluated: dict) -> None:
    main = evaluated[MAIN]
    assert main["kanshiEnabled"] is True, main
    assert main["kanshiTarget"] == "graphical-session.target", main
    assert main["kanshiSettings"] == [], main
    assert main["kanshiManagedConfig"] is False, main
    assert evaluated[MINI]["kanshiEnabled"] is False, evaluated[MINI]
    print("PASS: kanshi runs on main only with settings = []")


# ------------------------------------------------------------ niri recovery


def test_internal_panel_recovery() -> None:
    niri_config = read(HOME_FILES / ".config/niri/config.kdl")

    directives = [
        line.strip()
        for line in niri_config.splitlines()
        if line.strip() and not line.lstrip().startswith("//")
    ]
    assert not any(line.startswith("include") for line in directives), directives
    assert "Mod+Alt+P" in niri_config, niri_config
    assert "niri msg output eDP-1 on" in niri_config, niri_config

    assert re.search(r'Mod\+P\b(?!\+)', niri_config), "Mod+P binding missing"
    assert 'spawn "wdisplays"' in niri_config, niri_config
    assert 'spawn "niri-display-menu"' in niri_config, niri_config

    menu = read(REPO / "home/calendar/desktop/display-menu.sh")
    assert 'internal_output="eDP-1"' in menu, menu
    assert 'restore_internal' in menu, menu
    assert "nwg" not in menu.lower(), menu
    print("PASS: eDP-1 keeps its recovery entry and Mod+P opens wdisplays")


# --------------------------------------------------------- fuzzel and kitty


def test_fuzzel_and_kitty(evaluated: dict) -> None:
    fuzzel = HOME_FILES / ".config/fuzzel/fuzzel.ini"
    expected = {
        "font": "JetBrains Mono:size=14",
        "width": "54",
        "lines": "14",
        "horizontal-pad": "20",
        "vertical-pad": "12",
        "inner-pad": "8",
        # Colours, radius and icons must stay identical to the shared file.
        "terminal": "kitty",
        "prompt": "run:",
        "icons-enabled": "yes",
    }
    for key, value in expected.items():
        assert ini_value(fuzzel, "main", key) == value, (key, value)

    colors = {
        "background": "1e1e2eff",
        "text": "cdd6f4ff",
        "match": "89b4faff",
        "selection": "313244ff",
        "selection-text": "cdd6f4ff",
        "border": "89b4faff",
    }
    for key, value in colors.items():
        assert ini_value(fuzzel, "colors", key) == value, (key, value)
    assert ini_value(fuzzel, "border", "width") == "1"
    assert ini_value(fuzzel, "border", "radius") == "8"

    mini_fuzzel = REPO / "config/sway/fuzzel/fuzzel.ini"
    assert ini_value(mini_fuzzel, "main", "font") == "JetBrains Mono:size=11"
    assert ini_value(mini_fuzzel, "main", "width") == "45"
    assert ini_value(mini_fuzzel, "main", "lines") == "12"

    assert evaluated[MAIN]["kittyFontSize"] == 13.5, evaluated[MAIN]
    assert evaluated[MINI]["kittyFontSize"] == 11, evaluated[MINI]
    print("PASS: main's Fuzzel geometry and Kitty font size match the request")


# -------------------------------------------------------------- sway binds


def normalize_binding(key: str) -> str:
    token = key.replace("$mod", "Mod4")
    parts = token.split("+")
    return "+".join(sorted(parts[:-1]) + [parts[-1]])


def sway_bindings(config: str) -> list[str]:
    bindings = []
    for line in config.splitlines():
        stripped = line.strip()
        if not stripped.startswith("bindsym"):
            continue
        tokens = stripped.split()
        key = next((token for token in tokens[1:] if not token.startswith("--")), None)
        assert key is not None, stripped
        bindings.append(normalize_binding(key))
    return bindings


def test_sway_bindings() -> None:
    config = read(HOME_FILES / ".config/sway/config")
    bindings = sway_bindings(config)

    duplicates = [key for key, count in Counter(bindings).items() if count > 1]
    assert duplicates == [], f"duplicate Sway bindings: {duplicates}"

    required = [
        "$mod+t",
        "$mod+e",
        "$mod+d",
        "Mod1+space",
        "$mod+m",
        "$mod+p",
        "Mod1+l",
        "$mod+v",
        "$mod+Ctrl+v",
    ]
    for key in required:
        assert normalize_binding(key) in bindings, (key, sorted(bindings))

    expected_lines = [
        "bindsym $mod+t exec kitty",
        "bindsym $mod+e exec nautilus",
        "bindsym $mod+d exec fuzzel",
        "bindsym Mod1+space exec fuzzel",
        "bindsym $mod+m exec kitty -e btop",
        "bindsym $mod+p exec wdisplays",
        "bindsym Mod1+l exec swaylock -f",
        "bindsym $mod+v floating toggle",
        "bindsym $mod+Ctrl+v split v",
    ]
    lines = {line.strip() for line in config.splitlines()}
    for line in expected_lines:
        assert line in lines, line

    # Kept behaviour from the shared config.
    for kept in (
        "XF86AudioRaiseVolume",
        "XF86AudioLowerVolume",
        "XF86MonBrightnessUp",
        "XF86MonBrightnessDown",
        "grim",
        "workspace number 1",
        "workspace number 9",
        "focus left",
        "move right",
    ):
        assert kept in config, kept
    assert "include /etc/sway/config.d/*" in config, "session integration include missing"
    assert "swaynag" in config, "exit confirmation missing"

    # Sway must keep its own workspace module, never the niri one.
    waybar_config = json.loads(read(HOME_FILES / ".config/waybar/config.jsonc"))
    assert "sway/workspaces" in waybar_config["modules-left"], waybar_config["modules-left"]
    assert "niri/workspaces" not in json.dumps(waybar_config), "niri module leaked into Sway"
    assert waybar_config["height"] == 34, waybar_config
    assert waybar_config["margin-top"] == 6, waybar_config
    assert waybar_config["margin-left"] == 8, waybar_config
    assert waybar_config["margin-right"] == 8, waybar_config

    style = read(HOME_FILES / ".config/waybar/style.css")
    assert "Catppuccin Mocha" in style, "main's Sway style is not the Catppuccin one"
    assert "JetBrains Mono" in style, style
    print("PASS: main's Sway bindings are unique, complete and Catppuccin-styled")


# ----------------------------------------------------------- removed overlay


def test_nwg_displays_overlay_is_gone() -> None:
    for relative in (
        "hosts/main/nwg-displays.nix",
        "patches/nwg-displays-niri-null-outputs.patch",
        "tests/test_nwg_displays_niri_outputs.py",
    ):
        assert not (REPO / relative).exists(), f"still present: {relative}"

    self_path = Path(__file__).resolve()
    allowed = {"START.sh", "install-preflight.sh"}
    for path in REPO.rglob("*"):
        if not path.is_file() or path.resolve() == self_path:
            continue
        relative = path.relative_to(REPO)
        if relative.parts[0] in {".git", "docs"}:
            continue
        if relative.name in allowed:
            continue
        if path.suffix not in {".nix", ".kdl", ".sh", ".py", ".ini", ".css", ".json"}:
            continue
        text = path.read_text(encoding="utf-8", errors="replace").lower()
        assert "nwg" not in text, f"stale nwg reference in {relative}"
    print("PASS: no build, config or test file references nwg-displays any more")


def main() -> None:
    evaluated = {MAIN: eval_host(MAIN), MINI: eval_host(MINI)}
    test_host_split(evaluated)
    test_no_bare_exec_in_main_sway_config()
    test_sway_units_bind_session_target()
    test_exit_watcher()
    test_niri_does_not_inherit_swaysock(evaluated)
    test_kanshi_config_stays_writable()
    test_kanshi_options(evaluated)
    test_internal_panel_recovery()
    test_fuzzel_and_kitty(evaluated)
    test_sway_bindings()
    test_nwg_displays_overlay_is_gone()
    print("ALL TESTS PASSED")


main()
