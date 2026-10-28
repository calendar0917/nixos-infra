#!/usr/bin/env python3
"""Headless regression checks for the niri power menu and lock wait helpers.

The scripts under test are Nix-built wrappers. Pass their store paths explicitly:

    python3 tests/test_desktop_polish.py \
      --power-menu /nix/store/...-niri-power-menu/bin/niri-power-menu \
      --power /nix/store/...-niri-power/bin/niri-power \
      --lock-wait /nix/store/...-niri-lock-wait/bin/niri-lock-wait \
      --layout /nix/store/...-niri-wlogout-layout \
      --style /nix/store/...-niri-wlogout-style.css

No real session, lock screen, suspend or display is touched.
"""

import argparse
import json
import os
import stat
import subprocess
import tempfile
import textwrap
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--power-menu", required=True)
parser.add_argument("--power", required=True)
parser.add_argument("--lock-wait", required=True)
parser.add_argument("--layout", required=True)
parser.add_argument("--style", required=True)
parser.add_argument("--narrow-style", required=True)
args = parser.parse_args()


def write_exec(path: Path, text: str) -> None:
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run(command, env):
    return subprocess.run(
        command,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def parse_object_stream(path: Path):
    text = path.read_text(encoding="utf-8")
    decoder = json.JSONDecoder()
    objects = []
    index = 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        obj, index = decoder.raw_decode(text, index)
        objects.append(obj)
    return objects


def test_layout():
    entries = parse_object_stream(Path(args.layout))
    assert [entry["label"] for entry in entries] == [
        "lock",
        "suspend",
        "logout",
        "reboot",
        "shutdown",
    ]
    assert [entry["keybind"] for entry in entries] == ["l", "u", "e", "r", "s"]
    assert [entry["text"].split()[0] for entry in entries] == [
        "锁屏",
        "挂起",
        "退出",
        "重启",
        "关机",
    ]
    css = Path(args.style).read_text(encoding="utf-8")
    for label in ["lock", "suspend", "logout", "reboot", "shutdown"]:
        marker = f"share/wlogout/icons/{label}.png"
        assert marker in css, f"missing icon for {label}"
    narrow = Path(args.narrow_style).read_text(encoding="utf-8")
    for css_text, icon_size in [(css, 40), (narrow, 26)]:
        assert f"background-size: {icon_size}px {icon_size}px" in css_text
        assert "background-color: rgba(17, 17, 27, 0.55)" in css_text
        for label in ["lock", "suspend", "logout", "reboot", "shutdown"]:
            assert f"share/wlogout/icons/{label}.png" in css_text
    print("PASS: wlogout layout is a JSON object stream with five Chinese cards")
    print("PASS: wide/narrow CSS reference the five packaged icons")


def test_power_menu_layout(tmp: Path):
    fake_niri = tmp / "niri"
    fake_wlogout = tmp / "wlogout"
    fake_notify = tmp / "notify-send"
    write_exec(
        fake_niri,
        """
        #!/bin/sh
        printf '%s\n' "$FAKE_OUTPUT_JSON"
        """,
    )
    write_exec(
        fake_wlogout,
        """
        #!/bin/sh
        : > "$FAKE_ARGS"
        for arg in "$@"; do printf '%s\n' "$arg" >> "$FAKE_ARGS"; done
        """,
    )
    write_exec(fake_notify, "#!/bin/sh\nexit 0\n")

    runtime = tmp / "runtime"
    runtime.mkdir(mode=0o700)

    cases = [
        (1280, 720, 5, 296, 296, 284, 284, args.style),
        (1536, 960, 5, 424, 424, 404, 404, args.style),
        (1920, 1080, 5, 616, 616, 464, 464, args.style),
        (700, 800, 1, 190, 190, 184, 184, args.narrow_style),
    ]

    for width, height, columns, left, right, top, bottom, style in cases:
        args_file = tmp / f"args-{width}x{height}"
        output = {
            "name": "eDP-1",
            "logical": {"width": width, "height": height, "scale": 1},
        }
        env = os.environ | {
            "XDG_RUNTIME_DIR": str(runtime),
            "FAKE_OUTPUT_JSON": json.dumps(output),
            "FAKE_ARGS": str(args_file),
            "NIRI_POWER_MENU_NIRI": str(fake_niri),
            "NIRI_POWER_MENU_WLOGOUT": str(fake_wlogout),
            "NIRI_POWER_MENU_NOTIFY": str(fake_notify),
        }
        result = run([args.power_menu], env)
        assert result.returncode == 0, result.stderr
        argv = args_file.read_text(encoding="utf-8").splitlines()

        def value(flag):
            return argv[argv.index(flag) + 1]

        assert "-p" in argv and value("-p") == "layer-shell"
        assert "-n" in argv
        assert value("-b") == str(columns)
        assert value("-L") == str(left)
        assert value("-R") == str(right)
        assert value("-T") == str(top)
        assert value("-B") == str(bottom)
        assert value("-c") == ("12" if columns == 5 else "0")
        assert value("-r") == ("0" if columns == 5 else "8")
        assert argv[argv.index("--layout") + 1] == args.layout
        assert argv[argv.index("--css") + 1] == style
        print(f"PASS: power menu geometry {width}x{height} -> {columns} column(s)")

    bad_args = tmp / "args-bad"
    for label, output in [
        ("missing logical size", {"name": "eDP-1", "logical": None}),
        ("tiny output", {"name": "eDP-1", "logical": {"width": 20, "height": 20}}),
        ("output too small for a single column", {"name": "eDP-1", "logical": {"width": 300, "height": 200}}),
    ]:
        env = os.environ | {
            "XDG_RUNTIME_DIR": str(runtime),
            "FAKE_OUTPUT_JSON": json.dumps(output),
            "FAKE_ARGS": str(bad_args),
            "NIRI_POWER_MENU_NIRI": str(fake_niri),
            "NIRI_POWER_MENU_WLOGOUT": str(fake_wlogout),
            "NIRI_POWER_MENU_NOTIFY": str(fake_notify),
        }
        result = run([args.power_menu], env)
        assert result.returncode != 0, label
        assert not bad_args.exists(), label
        print(f"PASS: power menu rejects {label} without launching wlogout")


def test_lock_wait(tmp: Path):
    fake_loginctl = tmp / "loginctl"
    fake_systemctl = tmp / "systemctl"
    fake_sleep = tmp / "sleep"
    write_exec(
        fake_loginctl,
        """
        #!/bin/sh
        prop="$4"
        case "$prop" in
          UID)
            if [ "${FAKE_LOGIN_INVALID:-0}" = 1 ]; then
              echo "No session known" >&2
              exit 1
            fi
            echo "${FAKE_LOGIN_UID:-$(id -u)}"
            ;;
          LockedHint)
            if [ -n "${FAKE_LOCK_COUNTER:-}" ]; then
              n=0
              [ -f "$FAKE_LOCK_COUNTER" ] && n=$(cat "$FAKE_LOCK_COUNTER")
              n=$((n + 1))
              echo "$n" > "$FAKE_LOCK_COUNTER"
              if [ "$n" -ge "${FAKE_LOCK_AFTER:-1}" ]; then echo yes; else echo no; fi
            else
              echo "${FAKE_LOCKED:-yes}"
            fi
            ;;
          *) exit 2 ;;
        esac
        """,
    )
    write_exec(
        fake_systemctl,
        """
        #!/bin/sh
        case "$1 $2" in
          "--user start")
            [ "${FAKE_START_FAIL:-0}" = 1 ] && exit 1
            exit 0
            ;;
          "--user show")
            echo "${FAKE_UNIT_STATE:-active}"
            exit 0
            ;;
          *) exit 2 ;;
        esac
        """,
    )
    write_exec(fake_sleep, "#!/bin/sh\nexit 0\n")

    base = {
        "XDG_SESSION_ID": "test-session",
        "NIRI_LOCK_WAIT_SYSTEMCTL": str(fake_systemctl),
        "NIRI_LOCK_WAIT_LOGINCTL": str(fake_loginctl),
        "NIRI_LOCK_WAIT_SLEEP": str(fake_sleep),
    }

    def check(label, extra, expected):
        env = os.environ | base | extra
        result = run([args.lock_wait], env)
        assert result.returncode == expected, (
            label,
            result.returncode,
            result.stderr,
        )
        print(f"PASS: niri-lock-wait {label}")

    check("already locked", {}, 0)
    counter = tmp / "counter"
    check(
        "delayed LockedHint",
        {
            "FAKE_LOCK_COUNTER": str(counter),
            "FAKE_LOCK_AFTER": "4",
        },
        0,
    )
    assert counter.read_text().strip() == "4"
    check("invalid session", {"FAKE_LOGIN_INVALID": "1"}, 1)
    check("wrong UID", {"FAKE_LOGIN_UID": "999"}, 1)
    check("lock unit start failure", {"FAKE_START_FAIL": "1"}, 1)
    check("lock process failure", {"FAKE_UNIT_STATE": "failed"}, 1)
    check("timeout", {"FAKE_LOCKED": "no"}, 1)

    env = os.environ | base
    env.pop("XDG_SESSION_ID")
    result = run([args.lock_wait], env)
    assert result.returncode == 1
    print("PASS: niri-lock-wait rejects a missing XDG_SESSION_ID")


def test_power_actions(tmp: Path):
    fake_fuzzel = tmp / "fuzzel"
    fake_systemctl = tmp / "power-systemctl"
    fake_niri = tmp / "power-niri"
    fake_lock = tmp / "lock"
    fake_lock_wait = tmp / "lock-wait"
    fake_notify = tmp / "power-notify"
    calls_file = tmp / "calls"

    write_exec(
        fake_fuzzel,
        """
        #!/bin/sh
        echo fuzzel >> "$FAKE_CALLS"
        echo "${FAKE_FUZZEL_CHOICE:-取消}"
        """,
    )
    write_exec(
        fake_systemctl,
        """
        #!/bin/sh
        echo "systemctl $*" >> "$FAKE_CALLS"
        exit "${FAKE_SYSTEMCTL_RC:-0}"
        """,
    )
    write_exec(
        fake_niri,
        """
        #!/bin/sh
        echo "niri $*" >> "$FAKE_CALLS"
        """,
    )
    write_exec(fake_lock, '#!/bin/sh\necho lock >> "$FAKE_CALLS"\n')
    write_exec(
        fake_lock_wait,
        '#!/bin/sh\necho lock-wait >> "$FAKE_CALLS"\nexit "${FAKE_LOCK_WAIT_RC:-0}"\n',
    )
    write_exec(fake_notify, "#!/bin/sh\nexit 0\n")

    base = {
        "FAKE_CALLS": str(calls_file),
        "NIRI_POWER_FUZZEL": str(fake_fuzzel),
        "NIRI_POWER_SYSTEMCTL": str(fake_systemctl),
        "NIRI_POWER_NIRI": str(fake_niri),
        "NIRI_POWER_LOCK": str(fake_lock),
        "NIRI_POWER_LOCK_WAIT": str(fake_lock_wait),
        "NIRI_POWER_NOTIFY": str(fake_notify),
    }

    def check(action, extra, expected_rc, expected_calls):
        calls_file.write_text("", encoding="utf-8")
        env = os.environ | base | extra
        result = run([args.power, action], env)
        assert result.returncode == expected_rc, (action, result.returncode, result.stderr)
        calls = calls_file.read_text(encoding="utf-8").splitlines()
        assert calls == expected_calls, (action, calls, expected_calls)
        print(f"PASS: niri-power {action} -> {calls or 'no action'}")

    check("suspend", {"FAKE_LOCK_WAIT_RC": "1"}, 1, ["lock-wait"])
    check(
        "suspend",
        {"FAKE_LOCK_WAIT_RC": "0"},
        0,
        ["lock-wait", "systemctl suspend"],
    )
    check("logout", {"FAKE_FUZZEL_CHOICE": "取消"}, 0, ["fuzzel"])
    check("reboot", {"FAKE_FUZZEL_CHOICE": "取消"}, 0, ["fuzzel"])
    check("shutdown", {"FAKE_FUZZEL_CHOICE": "取消"}, 0, ["fuzzel"])
    check(
        "logout",
        {"FAKE_FUZZEL_CHOICE": "退出登录"},
        0,
        ["fuzzel", "niri msg action quit --skip-confirmation"],
    )
    check("reboot", {"FAKE_FUZZEL_CHOICE": "重启"}, 0, ["fuzzel", "systemctl reboot"])
    check("shutdown", {"FAKE_FUZZEL_CHOICE": "关机"}, 0, ["fuzzel", "systemctl poweroff"])
    check("lock", {}, 0, ["lock"])


with tempfile.TemporaryDirectory(prefix="niri-power-test.") as tmpdir:
    tmp = Path(tmpdir)
    test_layout()
    test_power_menu_layout(tmp)
    test_lock_wait(tmp)
    test_power_actions(tmp)

print("ALL TESTS PASSED")
