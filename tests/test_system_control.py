#!/usr/bin/env python3
"""Headless regression checks for the unified niri system control center.

The script under test is the Nix-built wrapper. Pass its path explicitly:

    python3 tests/test_system_control.py \
      --system-control /nix/store/.../bin/niri-system-control \
      --waybar-config /nix/store/.../waybar/niri.jsonc \
      --waybar-style /nix/store/.../waybar/style-niri.css \
      --niri-config /nix/store/.../niri/config.kdl

Every TUI command, fzf invocation, brightness device, power profile and
systemctl call is replaced by a stub. Nothing here changes a real backlight,
network connection, Bluetooth device, audio profile, power mode or lid
inhibitor, and nothing locks or suspends.
"""

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--system-control", required=True)
parser.add_argument("--waybar-config", required=True)
parser.add_argument("--waybar-style", required=True)
parser.add_argument("--niri-config", required=True)
parser.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
args = parser.parse_args()

# The wrapper resolves its own absolute store path for fzf's child shells.
SELF = str(Path(args.system_control).resolve())

MAIN_ITEMS = [
    "网络连接",
    "蓝牙设备",
    "音频与音量",
    "屏幕亮度",
    "电源性能模式",
    "合盖行为",
    "系统监控",
    "退出",
]

PPD_LIST = """\
  performance:
    CpuDriver:\tamd_pstate
    PlatformDriver:\tplatform_profile
    Degraded:   no

* balanced:
    CpuDriver:\tamd_pstate
    PlatformDriver:\tplatform_profile

  power-saver:
    CpuDriver:\tamd_pstate
    PlatformDriver:\tplatform_profile
"""


def write_exec(path: Path, text: str) -> None:
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


tmp = Path(tempfile.mkdtemp(prefix="system-control-test."))

fzf_log = tmp / "fzf.jsonl"
fzf_queue = tmp / "fzf-queue"
tool_log = tmp / "tools.jsonl"
kitty_log = tmp / "kitty.jsonl"
brightness_state = tmp / "brightness.json"
brightness_log = tmp / "brightness.jsonl"
power_log = tmp / "power.jsonl"
systemctl_log = tmp / "systemctl.jsonl"
lid_state = tmp / "lid-state"

fzf_bin = tmp / "fzf"
kitty_bin = tmp / "kitty"
brightnessctl_bin = tmp / "brightnessctl"
powerprofilesctl_bin = tmp / "powerprofilesctl"
systemctl_bin = tmp / "systemctl"
nmtui_bin = tmp / "nmtui"
bluetui_bin = tmp / "bluetui"
wiremix_bin = tmp / "wiremix"
btop_bin = tmp / "btop"

write_exec(
    fzf_bin,
    f"""\
    #!{sys.executable}
    import json
    import os
    import sys

    argv = sys.argv[1:]
    data = sys.stdin.read()
    with open(os.environ["FAKE_FZF_LOG"], "a", encoding="utf-8") as handle:
        handle.write(json.dumps({{"args": argv, "input": data}}, ensure_ascii=False) + "\\n")

    queue_path = os.environ["FAKE_FZF_QUEUE"]
    lines = []
    if os.path.exists(queue_path):
        lines = [line for line in open(queue_path, encoding="utf-8").read().splitlines()]
    if not lines:
        sys.exit(130)

    with open(queue_path, "w", encoding="utf-8") as handle:
        for line in lines[1:]:
            handle.write(line + "\\n")
    print(lines[0])
    """,
)

write_exec(
    kitty_bin,
    f"""\
    #!{sys.executable}
    import json
    import os
    import sys

    with open(os.environ["FAKE_KITTY_LOG"], "a", encoding="utf-8") as handle:
        handle.write(json.dumps(sys.argv[1:], ensure_ascii=False) + "\\n")
    """,
)

write_exec(
    brightnessctl_bin,
    f"""\
    #!{sys.executable}
    import json
    import os
    import sys

    argv = sys.argv[1:]
    with open(os.environ["FAKE_BRIGHTNESS_LOG"], "a", encoding="utf-8") as handle:
        handle.write(json.dumps(argv) + "\\n")

    if os.environ.get("FAKE_BRIGHTNESS_FAIL_READ") == "1":
        print("fake brightnessctl: read failure", file=sys.stderr)
        sys.exit(1)

    state_path = os.environ["FAKE_BRIGHTNESS_STATE"]
    with open(state_path, encoding="utf-8") as handle:
        state = json.load(handle)

    if "max" in argv:
        if os.environ.get("FAKE_BRIGHTNESS_FAIL_MAX") == "1":
            print("fake brightnessctl: max failure", file=sys.stderr)
            sys.exit(1)
        print(state["max"])
        sys.exit(0)
    if "get" in argv:
        if os.environ.get("FAKE_BRIGHTNESS_FAIL_GET") == "1":
            print("fake brightnessctl: get failure", file=sys.stderr)
            sys.exit(1)
        print(state["current"])
        sys.exit(0)
    if "set" in argv:
        value = argv[-1]
        if not value.endswith("%"):
            sys.exit(2)
        percent = int(value[:-1])
        state["current"] = state["max"] * percent // 100
        with open(state_path, "w", encoding="utf-8") as handle:
            json.dump(state, handle)
        print(value)
        sys.exit(0)
    sys.exit(2)
    """,
)

write_exec(
    powerprofilesctl_bin,
    f"""\
    #!{sys.executable}
    import json
    import os
    import sys

    argv = sys.argv[1:]
    with open(os.environ["FAKE_POWER_LOG"], "a", encoding="utf-8") as handle:
        handle.write(json.dumps(argv) + "\\n")

    if argv == ["get"]:
        print(os.environ["FAKE_PPD_CURRENT"])
        sys.exit(0)
    if argv == ["list"]:
        print(os.environ["FAKE_PPD_LIST"], end="")
        sys.exit(0)
    if len(argv) == 2 and argv[0] == "set":
        sys.exit(0)
    sys.exit(2)
    """,
)

write_exec(
    systemctl_bin,
    f"""\
    #!{sys.executable}
    import json
    import os
    import sys

    argv = sys.argv[1:]
    with open(os.environ["FAKE_SYSTEMCTL_LOG"], "a", encoding="utf-8") as handle:
        handle.write(json.dumps(argv) + "\\n")

    state_path = os.environ["FAKE_LID_STATE"]
    state = open(state_path, encoding="utf-8").read().strip() if os.path.exists(state_path) else "inactive"

    if "is-active" in argv:
        sys.exit(0 if state == "active" else 1)
    if "start" in argv:
        open(state_path, "w", encoding="utf-8").write("active\\n")
        sys.exit(0)
    if "stop" in argv:
        open(state_path, "w", encoding="utf-8").write("inactive\\n")
        sys.exit(0)
    sys.exit(2)
    """,
)

for tool in (nmtui_bin, bluetui_bin, wiremix_bin, btop_bin):
    write_exec(
        tool,
        f"""\
        #!{sys.executable}
        import json
        import os
        import sys

        name = os.path.basename(sys.argv[0])
        with open(os.environ["FAKE_TOOL_LOG"], "a", encoding="utf-8") as handle:
            handle.write(json.dumps({{"tool": name, "args": sys.argv[1:]}}) + "\\n")
        sys.exit(int(os.environ.get("FAKE_TOOL_STATUS", "0")))
        """,
    )

BASE_ENV = {
    "SYSTEM_CONTROL_FZF": str(fzf_bin),
    "SYSTEM_CONTROL_KITTY": str(kitty_bin),
    "SYSTEM_CONTROL_NMTUI": str(nmtui_bin),
    "SYSTEM_CONTROL_BLUETUI": str(bluetui_bin),
    "SYSTEM_CONTROL_WIREMIX": str(wiremix_bin),
    "SYSTEM_CONTROL_BTOP": str(btop_bin),
    "SYSTEM_CONTROL_BRIGHTNESSCTL": str(brightnessctl_bin),
    "SYSTEM_CONTROL_POWERPROFILESCTL": str(powerprofilesctl_bin),
    "SYSTEM_CONTROL_SYSTEMCTL": str(systemctl_bin),
    "FAKE_FZF_LOG": str(fzf_log),
    "FAKE_FZF_QUEUE": str(fzf_queue),
    "FAKE_KITTY_LOG": str(kitty_log),
    "FAKE_BRIGHTNESS_LOG": str(brightness_log),
    "FAKE_BRIGHTNESS_STATE": str(brightness_state),
    "FAKE_POWER_LOG": str(power_log),
    "FAKE_PPD_CURRENT": "balanced",
    "FAKE_PPD_LIST": PPD_LIST,
    "FAKE_SYSTEMCTL_LOG": str(systemctl_log),
    "FAKE_LID_STATE": str(lid_state),
    "FAKE_TOOL_LOG": str(tool_log),
}


def reset(
    *,
    queue=(),
    brightness=(1000, 650),
    lid="inactive",
) -> None:
    fzf_log.write_text("", encoding="utf-8")
    fzf_queue.write_text("".join(f"{item}\n" for item in queue), encoding="utf-8")
    tool_log.write_text("", encoding="utf-8")
    kitty_log.write_text("", encoding="utf-8")
    brightness_log.write_text("", encoding="utf-8")
    power_log.write_text("", encoding="utf-8")
    systemctl_log.write_text("", encoding="utf-8")
    brightness_state.write_text(
        json.dumps({"max": brightness[0], "current": brightness[1]}), encoding="utf-8"
    )
    lid_state.write_text(f"{lid}\n", encoding="utf-8")


def run(commands, *, stdin_text="", **env):
    current = os.environ.copy()
    current.update(BASE_ENV)
    current.update(env)
    return subprocess.run(
        [SELF, *commands],
        env=current,
        input=stdin_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def read_jsonl(path: Path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


# --------------------------------------------------------------- dispatching


def test_help_and_unknown_command():
    result = run(["definitely-not-a-command"])
    assert result.returncode != 0, result
    assert "niri-system-control" in result.stderr, result.stderr
    assert "网络连接" in result.stderr, result.stderr
    print("PASS: unknown commands show help and fail")


def test_launch_uses_one_kitty_window():
    reset()
    result = run(["launch"])
    assert result.returncode == 0, result.stderr
    calls = read_jsonl(kitty_log)
    assert len(calls) == 1, calls
    argv = calls[0]
    assert "--app-id=system-control" in argv, argv
    assert "--title=系统控制" in argv, argv
    assert argv[-2] == SELF, argv
    assert argv[-1] == "menu", argv

    reset()
    result = run(["launch", "network"])
    assert result.returncode == 0, result.stderr
    argv = read_jsonl(kitty_log)[0]
    assert argv[-2] == SELF, argv
    assert argv[-1] == "network", argv
    print("PASS: launch starts a single Kitty window with app-id system-control")


def test_direct_subcommands():
    for command, tool in (
        (["network"], "nmtui"),
        (["bluetooth"], "bluetui"),
        (["audio"], "wiremix"),
        (["monitor"], "btop"),
    ):
        reset()
        result = run(command)
        assert result.returncode == 0, (command, result.stderr)
        calls = read_jsonl(tool_log)
        assert [call["tool"] for call in calls] == [tool], (command, calls)
    print("PASS: direct subcommands run the selected TUI in the current terminal")


def test_main_menu_order_and_escape():
    reset()
    result = run(["menu"])
    assert result.returncode == 0, result.stderr
    calls = read_jsonl(fzf_log)
    assert len(calls) == 1, calls
    assert calls[0]["input"].splitlines() == MAIN_ITEMS, calls[0]["input"]
    assert "--color=" in " ".join(calls[0]["args"]) or any(
        item.startswith("--color=") for item in calls[0]["args"]
    ), calls[0]["args"]
    print("PASS: the main menu lists the eight items in the fixed order and Esc exits")


def test_subtui_returns_to_menu():
    reset(queue=["系统监控"])
    result = run(["menu"])
    assert result.returncode == 0, result.stderr
    assert [call["tool"] for call in read_jsonl(tool_log)] == ["btop"]
    assert len(read_jsonl(fzf_log)) == 2, "menu did not reopen after btop"
    print("PASS: leaving a sub-TUI returns to the same main menu")


def test_subtui_error_stays_visible():
    reset(queue=["系统监控"])
    result = run(["menu"], stdin_text="\n", FAKE_TOOL_STATUS="3")
    assert result.returncode == 0, result.stderr
    assert "异常退出" in result.stderr, result.stderr
    assert "3" in result.stderr, result.stderr
    assert len(read_jsonl(fzf_log)) == 2, "menu did not reopen after the error"
    print("PASS: a failing sub-TUI shows an error and returns to the menu")


# ---------------------------------------------------------------- brightness


def brightness_calls():
    return read_jsonl(brightness_log)


def set_calls():
    return [call for call in brightness_calls() if "set" in call]


def test_brightness_status():
    reset(brightness=(65535, 32768))
    result = run(["brightness-status"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().endswith("50%"), result.stdout

    reset(brightness=(1000, 650))
    result = run(["brightness-status"])
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip().endswith("65%"), result.stdout
    print("PASS: brightness-status computes the device percentage")


def test_brightness_step_and_clamp():
    reset(brightness=(1000, 500))
    result = run(["brightness-step", "+5"])
    assert result.returncode == 0, result.stderr
    assert set_calls()[-1][-1] == "55%", set_calls()
    assert result.stdout.strip().endswith("55%"), result.stdout

    reset(brightness=(1000, 500))
    assert run(["brightness-step", "-5"]).returncode == 0
    assert set_calls()[-1][-1] == "45%", set_calls()

    # 4% is below the floor: a -5 step must clamp to 5%, never 0%.
    reset(brightness=(1000, 40))
    assert run(["brightness-step", "-5"]).returncode == 0
    assert set_calls()[-1][-1] == "5%", set_calls()

    reset(brightness=(1000, 980))
    assert run(["brightness-step", "+5"]).returncode == 0
    assert set_calls()[-1][-1] == "100%", set_calls()

    reset(brightness=(1000, 1000))
    assert run(["brightness-step", "+1"]).returncode == 0
    assert set_calls()[-1][-1] == "100%", set_calls()
    print("PASS: brightness-step applies signed deltas and clamps to 5..100")


def test_brightness_set_clamps():
    reset(brightness=(1000, 500))
    assert run(["brightness-set", "0"]).returncode == 0
    assert set_calls()[-1][-1] == "5%", set_calls()

    reset(brightness=(1000, 500))
    assert run(["brightness-set", "150"]).returncode == 0
    assert set_calls()[-1][-1] == "100%", set_calls()

    reset(brightness=(1000, 500))
    assert run(["brightness-set", "not-a-number"]).returncode != 0
    assert set_calls() == [], "invalid input wrote to the backlight"
    print("PASS: brightness-set clamps 0 to 5%, 150 to 100%, and rejects garbage")


def test_brightness_read_failure_never_writes():
    reset()
    result = run(["brightness-set", "50"], FAKE_BRIGHTNESS_FAIL_READ="1")
    assert result.returncode != 0, result
    assert "无法读取背光设备" in result.stderr, result.stderr
    assert set_calls() == [], "a failed device read still wrote brightness"

    reset()
    result = run(["brightness-step", "5"], FAKE_BRIGHTNESS_FAIL_READ="1")
    assert result.returncode != 0, result
    assert set_calls() == [], "a failed device read still wrote brightness"

    # `set` must verify both reads too, not only the maximum.
    reset()
    result = run(["brightness-set", "50"], FAKE_BRIGHTNESS_FAIL_GET="1")
    assert result.returncode != 0, result
    assert set_calls() == [], "a failed current-brightness read still wrote"

    reset(brightness=(0, 0))
    result = run(["brightness-set", "50"])
    assert result.returncode != 0, result
    assert "最大亮度为 0" in result.stderr, result.stderr
    assert set_calls() == [], "a zero-max device was written"
    print("PASS: unreadable, invalid and zero-max backlights are never written")


def test_brightness_tui_keys_use_absolute_self():
    reset()
    result = run(["brightness"])
    assert result.returncode == 0, result.stderr
    calls = read_jsonl(fzf_log)
    assert len(calls) == 1, calls
    argv = calls[0]["args"]
    joined = "\n".join(argv)

    assert f"--preview='{SELF}' brightness-status" in joined or (
        f"'{SELF}' brightness-status" in joined
    ), argv
    for binding in ("left", "h", "right", "l", "H", "L", "enter"):
        assert any(
            item.startswith(f"{binding}:execute-silent(") for item in argv
        ), (binding, argv)
    for delta in ("-5", "5", "-1", "1"):
        assert f"'{SELF}' brightness-step {delta}" in joined, (delta, argv)
    assert f"'{SELF}' brightness-action {{1}}" in joined, argv
    assert "refresh-preview" in joined, argv

    items = calls[0]["input"].splitlines()
    for preset in ("5%", "25%", "50%", "75%", "100%"):
        assert any(preset in item for item in items), (preset, items)
    print("PASS: the brightness TUI wires live step keys and presets through its absolute path")


# -------------------------------------------------------------------- power


def power_calls():
    return read_jsonl(power_log)


def test_power_menu_only_sets_listed_modes():
    reset(queue=["power-saver|x"])
    result = run(["power"])
    assert result.returncode == 0, result.stderr
    sets = [call for call in power_calls() if call and call[0] == "set"]
    assert sets == [["set", "power-saver"]], sets

    # Selecting the active profile must not run a redundant set.
    reset(queue=["balanced|x"])
    result = run(["power"])
    assert result.returncode == 0, result.stderr
    assert [call for call in power_calls() if call and call[0] == "set"] == []

    # performance is not in this device's list: refuse instead of guessing.
    reset(queue=["performance|x"])
    result = run(["power"], FAKE_PPD_LIST="* balanced:\n  power-saver:\n")
    assert result.returncode == 0, result.stderr
    assert [call for call in power_calls() if call and call[0] == "set"] == []
    assert "不在设备支持的列表" in result.stderr, result.stderr
    print("PASS: power profiles are limited to the modes the device lists")


# ---------------------------------------------------------------------- lid


def systemctl_calls():
    return read_jsonl(systemctl_log)


def lid_actions():
    actions = []
    for call in systemctl_calls():
        if "start" in call:
            actions.append("start")
        elif "stop" in call:
            actions.append("stop")
    return actions


def test_lid_menu_targets_explicit_state():
    reset(lid="inactive", queue=["normal|x", "awake|x", "awake|x", "normal|x"])
    result = run(["lid"])
    assert result.returncode == 0, result.stderr
    assert lid_actions() == ["start", "stop"], lid_actions()
    assert not any("toggle" in " ".join(call) for call in systemctl_calls())

    header = "\n".join(read_jsonl(fzf_log)[0]["args"])
    assert "Alt+L" in header, header
    assert "不会自动触发挂起前锁屏" in header, header
    print("PASS: lid selection starts/stops only on a real state change and shows the safety tip")


# -------------------------------------------------------------- static checks


def test_wrapper_runtime_inputs():
    script = Path(SELF).read_text(encoding="utf-8")
    path_lines = [line for line in script.splitlines() if line.startswith("export PATH=")]
    assert path_lines, "writeShellApplication did not export a runtime PATH"
    path = path_lines[0]
    for tool in (
        "btop-",
        "brightnessctl-",
        "bluetui-",
        "fzf-",
        "kitty-",
        "networkmanager-",
        "power-profiles-daemon-",
        "systemd-",
        "wiremix-",
    ):
        assert tool in path, (tool, path)
    print("PASS: all TUI tools resolve through the wrapper's own PATH")


def test_waybar_layout_and_css():
    config = json.loads(Path(args.waybar_config).read_text(encoding="utf-8"))
    assert config["modules-left"] == [
        "custom/launcher",
        "niri/workspaces",
        "cpu",
        "memory",
        "network#traffic",
    ], config["modules-left"]
    assert config["modules-center"] == ["custom/clock"], config["modules-center"]
    assert config["modules-right"] == [
        "network#status",
        "battery",
        "custom/lid-mode",
        "custom/notification",
        "custom/system-control",
        "group/tray",
    ], config["modules-right"]

    text = json.dumps(config, ensure_ascii=False)
    for removed in (
        "group/monitor",
        "custom/monitor-toggle",
        "pulseaudio",
        "bluetooth",
        "power-profiles-daemon",
        "backlight",
    ):
        assert removed not in text, f"removed module still present: {removed}"

    assert config["cpu"]["format"] == "CPU {usage}%", config["cpu"]
    assert config["cpu"]["interval"] == 3, config["cpu"]
    assert "btop" in config["cpu"]["on-click"], config["cpu"]
    assert config["memory"]["format"] == "RAM {percentage}%", config["memory"]
    assert config["memory"]["interval"] == 5, config["memory"]
    assert "bandwidthDownBytes" in config["network#traffic"]["tooltip-format"]

    control = config["custom/system-control"]
    assert control["tooltip"] == "系统控制中心 · Mod+S", control
    assert control["on-click"].endswith(" launch"), control
    assert config["network#status"]["on-click"].endswith(" launch network"), config["network#status"]

    style = Path(args.waybar_style).read_text(encoding="utf-8")
    for removed in ("custom-monitor-toggle", "power-profiles-daemon", "backlight", "pulseaudio"):
        assert removed not in style, f"stale CSS selector remains: {removed}"
    assert "#custom-system-control" in style, style
    assert "#network.traffic" in style, style
    assert "#cpu" in style and "#memory" in style, style
    print("PASS: Waybar shows resources on the left and only required status on the right")


def test_niri_shortcut_and_window_rule():
    text = Path(args.niri_config).read_text(encoding="utf-8")

    bindings = [
        line.strip()
        for line in text.splitlines()
        if re.match(r"^\s*Mod\+S\b(?!\+)", line)
    ]
    assert len(bindings) == 1, bindings
    assert "System control center" in bindings[0], bindings[0]

    block = re.search(
        r"^\s*Mod\+S\b(?!\+)[^\n]*\{\n(.*?)^\s*\}",
        text,
        flags=re.MULTILINE | re.DOTALL,
    )
    assert block, "Mod+S has no binding block"
    assert 'spawn "niri-system-control" "launch"' in block.group(1), block.group(1)

    assert "superproductivity://toggle-visibility" not in text
    assert "Super Productivity: Show/hide" not in text
    assert 'spawn "xdg-open" "superproductivity://add-task"' in text
    assert 'Mod+Alt+S { spawn-sh "pkill orca || exec orca"; }' in text

    assert 'match app-id="^system-control$"' in text
    assert "open-floating true" in text
    assert "default-column-width { fixed 760; }" in text
    assert "default-window-height { fixed 520; }" in text
    assert 'match app-id="^kitty$"' in text, "the original kitty rule was replaced"

    dms = (Path(args.repo) / "config/niri/config-dms.kdl").read_text(encoding="utf-8")
    assert 'Mod+S hotkey-overlay-title="DMS settings"' in dms, "mini host Mod+S changed"
    assert "niri-system-control" not in dms, "control center leaked into the DMS config"
    print("PASS: Mod+S opens the control center and the DMS/Super Productivity bindings are preserved")


def main() -> None:
    test_help_and_unknown_command()
    test_launch_uses_one_kitty_window()
    test_direct_subcommands()
    test_main_menu_order_and_escape()
    test_subtui_returns_to_menu()
    test_subtui_error_stays_visible()
    test_brightness_status()
    test_brightness_step_and_clamp()
    test_brightness_set_clamps()
    test_brightness_read_failure_never_writes()
    test_brightness_tui_keys_use_absolute_self()
    test_power_menu_only_sets_listed_modes()
    test_lid_menu_targets_explicit_state()
    test_wrapper_runtime_inputs()
    test_waybar_layout_and_css()
    test_niri_shortcut_and_window_rule()
    print("ALL SYSTEM CONTROL TESTS PASSED")


main()
