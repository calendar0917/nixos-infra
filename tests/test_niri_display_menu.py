#!/usr/bin/env python3
"""Headless regression checks for the niri display mode menu.

The script under test is the Nix-built wrapper. Pass its path explicitly:

    python3 tests/test_niri_display_menu.py \
      --display-menu /nix/store/...-niri-display-menu/bin/niri-display-menu

The fixtures substitute fake niri, fuzzel, wdisplays and sleep executables.
They never touch a real niri session or physical output.
"""

import argparse
import copy
import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--display-menu", required=True)
args = parser.parse_args()

MENU_ITEMS = [
    "仅笔记本屏幕",
    "扩展显示",
    "仅外接显示器",
    "高级显示设置（wdisplays）",
]

LOGICAL = {
    "x": 0,
    "y": 0,
    "width": 1280,
    "height": 800,
    "scale": 1,
    "transform": "Normal",
}

MODE = {
    "width": 2560,
    "height": 1600,
    "refresh_rate": 60000,
    "is_preferred": True,
}


def write_exec(path: Path, text: str) -> None:
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def output(name: str, *, active: bool = True, modes: bool = True) -> dict:
    return {
        "name": name,
        "make": "Test",
        "model": name,
        "serial": None,
        "physical_size": [340, 220],
        "modes": [copy.deepcopy(MODE)] if modes else [],
        "current_mode": 0 if active else None,
        "is_custom_mode": False,
        "vrr_supported": False,
        "vrr_enabled": False,
        "logical": copy.deepcopy(LOGICAL) if active else None,
    }


def is_active(state: dict, name: str) -> bool:
    entry = state[name]
    return entry["current_mode"] is not None and entry["logical"] is not None


fake_niri = None
fake_fuzzel = None
fake_wdisplays = None
fake_sleep = None
state_file = None
calls_file = None
fuzzel_args_file = None
fuzzel_input_file = None


def make_fakes(tmp: Path) -> None:
    global fake_niri, fake_fuzzel, fake_wdisplays, fake_sleep
    global state_file, calls_file, fuzzel_args_file, fuzzel_input_file

    state_file = tmp / "niri-state.json"
    calls_file = tmp / "calls"
    fuzzel_args_file = tmp / "fuzzel-args"
    fuzzel_input_file = tmp / "fuzzel-input"

    fake_niri = tmp / "niri"
    fake_fuzzel = tmp / "fuzzel"
    fake_wdisplays = tmp / "wdisplays"
    fake_sleep = tmp / "sleep"

    write_exec(
        fake_niri,
        f"""\
        #!{sys.executable}
        import json
        import os
        import sys

        state_path = os.environ["FAKE_NIRI_STATE"]
        calls_path = os.environ["FAKE_CALLS"]


        def log(line):
            with open(calls_path, "a", encoding="utf-8") as handle:
                handle.write(line + "\\n")


        def read_state():
            with open(state_path, encoding="utf-8") as handle:
                return json.load(handle)


        def write_state(state):
            with open(state_path, "w", encoding="utf-8") as handle:
                json.dump(state, handle)


        def name_set(variable):
            return set(filter(None, os.environ.get(variable, "").split(",")))


        argv = sys.argv[1:]

        if argv == ["msg", "-j", "outputs"]:
            log("query")
            if os.environ.get("FAKE_NIRI_QUERY_FAIL") == "1":
                print("fake niri: IPC unavailable", file=sys.stderr)
                sys.exit(1)
            if "FAKE_NIRI_INVALID_JSON" in os.environ:
                print(os.environ["FAKE_NIRI_INVALID_JSON"])
                sys.exit(0)
            print(json.dumps(read_state()))
            sys.exit(0)

        if (
            len(argv) == 4
            and argv[0] == "msg"
            and argv[1] == "output"
            and argv[3] in ("on", "off")
        ):
            name = argv[2]
            action = argv[3]
            log(f"output {{name}} {{action}}")
            state = read_state()
            if name not in state:
                print(f"fake niri: unknown output {{name}}", file=sys.stderr)
                sys.exit(1)

            if action == "on":
                if name in name_set("FAKE_NIRI_FAIL_ON"):
                    print(f"fake niri: failed to enable {{name}}", file=sys.stderr)
                    sys.exit(1)
                if name not in name_set("FAKE_NIRI_NEVER_ACTIVE"):
                    state[name]["current_mode"] = 0
                    if not isinstance(state[name].get("logical"), dict):
                        state[name]["logical"] = {{
                            "x": 0,
                            "y": 0,
                            "width": 1280,
                            "height": 800,
                            "scale": 1,
                            "transform": "Normal",
                        }}
            else:
                if os.environ.get("FAKE_NIRI_OFF_DEACTIVATES_ALL") == "1":
                    for entry in state.values():
                        entry["current_mode"] = None
                        entry["logical"] = None
                else:
                    state[name]["current_mode"] = None
                    state[name]["logical"] = None

            write_state(state)
            sys.exit(0)

        print(f"fake niri: unsupported invocation: {{argv}}", file=sys.stderr)
        sys.exit(2)
        """,
    )

    write_exec(
        fake_fuzzel,
        f"""\
        #!{sys.executable}
        import os
        import sys

        with open(os.environ["FAKE_CALLS"], "a", encoding="utf-8") as handle:
            handle.write("fuzzel\\n")

        with open(os.environ["FAKE_FUZZEL_ARGS"], "w", encoding="utf-8") as handle:
            handle.write("\\n".join(sys.argv[1:]) + "\\n")

        with open(os.environ["FAKE_FUZZEL_INPUT"], "w", encoding="utf-8") as handle:
            handle.write(sys.stdin.read())

        if os.environ.get("FAKE_FUZZEL_CANCEL") == "1":
            sys.exit(1)

        choice = os.environ.get("FAKE_FUZZEL_CHOICE", "0")
        if choice != "__empty__":
            print(choice)
        """,
    )

    write_exec(
        fake_wdisplays,
        """\
        #!/bin/sh
        printf 'wdisplays\\n' >> "$FAKE_CALLS"
        exit "${FAKE_WDISPLAYS_RC:-0}"
        """,
    )
    write_exec(fake_sleep, "#!/bin/sh\nexit 0\n")


def run_case(
    label: str,
    outputs: dict,
    choice: str,
    expected_ops: list[str],
    *,
    expected_rc: int = 0,
    extra_env: dict | None = None,
):
    state_file.write_text(json.dumps(outputs), encoding="utf-8")
    calls_file.write_text("", encoding="utf-8")
    fuzzel_args_file.write_text("", encoding="utf-8")
    fuzzel_input_file.write_text("", encoding="utf-8")

    env = os.environ.copy()
    env.update(
        {
            "NIRI_DISPLAY_MENU_NIRI": str(fake_niri),
            "NIRI_DISPLAY_MENU_FUZZEL": str(fake_fuzzel),
            "NIRI_DISPLAY_MENU_WDISPLAYS": str(fake_wdisplays),
            "NIRI_DISPLAY_MENU_SLEEP": str(fake_sleep),
            "FAKE_NIRI_STATE": str(state_file),
            "FAKE_CALLS": str(calls_file),
            "FAKE_FUZZEL_ARGS": str(fuzzel_args_file),
            "FAKE_FUZZEL_INPUT": str(fuzzel_input_file),
            "FAKE_FUZZEL_CHOICE": choice,
        }
    )
    if extra_env:
        env.update(extra_env)

    result = subprocess.run(
        [args.display_menu],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    calls = calls_file.read_text(encoding="utf-8").splitlines()
    ops = [call for call in calls if call.startswith("output ")]
    assert result.returncode == expected_rc, (
        label,
        result.returncode,
        result.stderr,
    )
    assert ops == expected_ops, (
        label,
        ops,
        expected_ops,
        calls,
        result.stderr,
    )
    state = json.loads(state_file.read_text(encoding="utf-8"))
    return result, calls, state


def assert_query_between(label: str, calls: list[str], first: str, second: str) -> None:
    first_index = calls.index(first)
    second_index = calls.index(second)
    assert first_index < second_index, (label, calls)
    assert "query" in calls[first_index + 1 : second_index], (label, calls)


def test_menu_contract(tmp: Path) -> None:
    _, calls, state = run_case(
        "menu contract",
        {"eDP-1": output("eDP-1")},
        "0",
        ["output eDP-1 on"],
    )
    assert calls[0] == "fuzzel", calls
    assert fuzzel_input_file.read_text(encoding="utf-8").splitlines() == MENU_ITEMS
    fuzzel_args = fuzzel_args_file.read_text(encoding="utf-8").splitlines()
    assert "--dmenu" in fuzzel_args and "--index" in fuzzel_args, fuzzel_args
    assert is_active(state, "eDP-1")
    print("PASS: menu shows the four fixed items and dispatches by index")


def test_internal_only() -> None:
    _, calls, state = run_case(
        "internal only, already active",
        {"eDP-1": output("eDP-1")},
        "0",
        ["output eDP-1 on"],
    )
    assert is_active(state, "eDP-1")
    assert "output DP-1 off" not in calls
    print("PASS: internal-only keeps the active internal panel")

    _, calls, state = run_case(
        "internal and external active",
        {"eDP-1": output("eDP-1"), "DP-1": output("DP-1")},
        "0",
        ["output eDP-1 on", "output DP-1 off"],
    )
    assert_query_between(
        "internal-only enable before external off",
        calls,
        "output eDP-1 on",
        "output DP-1 off",
    )
    assert is_active(state, "eDP-1") and not is_active(state, "DP-1")
    print("PASS: internal-only confirms eDP-1 before disabling active externals")

    half_null_current = output("DP-1")
    half_null_current["current_mode"] = None
    half_null_logical = output("DP-2")
    half_null_logical["logical"] = None
    _, calls, state = run_case(
        "half-null outputs are inactive",
        {
            "eDP-1": output("eDP-1"),
            "DP-1": half_null_current,
            "DP-2": half_null_logical,
        },
        "0",
        ["output eDP-1 on"],
    )
    assert is_active(state, "DP-1") is False
    assert is_active(state, "DP-2") is False
    print("PASS: null current_mode or logical is treated as disabled")

    _, _, state = run_case(
        "internal enable failure",
        {"eDP-1": output("eDP-1", active=False), "DP-1": output("DP-1")},
        "0",
        ["output eDP-1 on"],
        expected_rc=1,
        extra_env={"FAKE_NIRI_FAIL_ON": "eDP-1"},
    )
    assert is_active(state, "DP-1")
    assert not is_active(state, "eDP-1")
    print("PASS: internal enable failure leaves the active external panel on")

    _, _, state = run_case(
        "internal missing",
        {"DP-1": output("DP-1")},
        "0",
        [],
        expected_rc=1,
    )
    assert is_active(state, "DP-1")
    print("PASS: missing internal panel does not disable the last external output")


def test_extend() -> None:
    _, _, state = run_case(
        "extend from external-only",
        {"eDP-1": output("eDP-1", active=False), "DP-1": output("DP-1")},
        "1",
        ["output eDP-1 on", "output DP-1 on"],
    )
    assert is_active(state, "eDP-1") and is_active(state, "DP-1")
    print("PASS: extend enables both the internal and external outputs")

    _, _, state = run_case(
        "extend with one enable failure",
        {"eDP-1": output("eDP-1", active=False), "DP-1": output("DP-1")},
        "1",
        ["output eDP-1 on", "output DP-1 on"],
        expected_rc=1,
        extra_env={"FAKE_NIRI_FAIL_ON": "DP-1"},
    )
    assert is_active(state, "eDP-1") and is_active(state, "DP-1")
    print("PASS: extend keeps already-enabled outputs when one enable fails")

    _, _, state = run_case(
        "extend ignores outputs without modes",
        {
            "eDP-1": output("eDP-1"),
            "DP-1": output("DP-1", active=False, modes=False),
            "DP-2": output("DP-2", active=False),
        },
        "1",
        ["output eDP-1 on", "output DP-2 on"],
    )
    assert not is_active(state, "DP-1")
    assert is_active(state, "DP-2")
    print("PASS: an output with an empty modes list is not an enable target")


def test_external_only() -> None:
    _, calls, state = run_case(
        "external-only from internal",
        {"eDP-1": output("eDP-1"), "DP-1": output("DP-1", active=False)},
        "2",
        ["output DP-1 on", "output eDP-1 off"],
    )
    assert_query_between(
        "external-only enable before internal off",
        calls,
        "output DP-1 on",
        "output eDP-1 off",
    )
    assert is_active(state, "DP-1") and not is_active(state, "eDP-1")
    print("PASS: external-only enables and observes the external before eDP-1 off")

    _, _, state = run_case(
        "external-only without an external",
        {"eDP-1": output("eDP-1")},
        "2",
        [],
        expected_rc=1,
    )
    assert is_active(state, "eDP-1")
    print("PASS: external-only refuses to run without an external output")

    _, _, state = run_case(
        "external-only with only empty modes",
        {"eDP-1": output("eDP-1"), "DP-1": output("DP-1", active=False, modes=False)},
        "2",
        [],
        expected_rc=1,
    )
    assert is_active(state, "eDP-1") and not is_active(state, "DP-1")
    print("PASS: an external output with no modes cannot trigger eDP-1 off")

    _, _, state = run_case(
        "external enable command failure",
        {"eDP-1": output("eDP-1"), "DP-1": output("DP-1", active=False)},
        "2",
        ["output DP-1 on"],
        expected_rc=1,
        extra_env={"FAKE_NIRI_FAIL_ON": "DP-1"},
    )
    assert is_active(state, "eDP-1") and not is_active(state, "DP-1")
    print("PASS: external enable failure leaves the internal panel on")

    _, _, state = run_case(
        "external never becomes active",
        {"eDP-1": output("eDP-1"), "DP-1": output("DP-1", active=False)},
        "2",
        ["output DP-1 on"],
        expected_rc=1,
        extra_env={"FAKE_NIRI_NEVER_ACTIVE": "DP-1"},
    )
    assert is_active(state, "eDP-1") and not is_active(state, "DP-1")
    print("PASS: external command success without an active state keeps eDP-1 on")

    _, _, state = run_case(
        "restore internal after external failure",
        {"eDP-1": output("eDP-1", active=False), "DP-1": output("DP-1", active=False)},
        "2",
        ["output DP-1 on", "output eDP-1 on"],
        expected_rc=1,
        extra_env={"FAKE_NIRI_FAIL_ON": "DP-1"},
    )
    assert is_active(state, "eDP-1")
    print("PASS: failed external-only switch restores a disabled eDP-1")

    _, _, state = run_case(
        "multiple external outputs",
        {
            "eDP-1": output("eDP-1"),
            "DP-1": output("DP-1", active=False),
            "HDMI-A-1": output("HDMI-A-1", active=False),
        },
        "2",
        ["output DP-1 on", "output HDMI-A-1 on", "output eDP-1 off"],
    )
    assert is_active(state, "DP-1") and is_active(state, "HDMI-A-1")
    assert not is_active(state, "eDP-1")
    print("PASS: external-only enables all available external outputs")

    _, _, state = run_case(
        "final active check fallback",
        {"eDP-1": output("eDP-1"), "DP-1": output("DP-1", active=False)},
        "2",
        ["output DP-1 on", "output eDP-1 off", "output eDP-1 on"],
        expected_rc=1,
        extra_env={"FAKE_NIRI_OFF_DEACTIVATES_ALL": "1"},
    )
    assert is_active(state, "eDP-1")
    print("PASS: a failed final active check immediately restores eDP-1")


def test_failures_and_cancel() -> None:
    _, calls, state = run_case(
        "invalid JSON",
        {"eDP-1": output("eDP-1")},
        "0",
        [],
        expected_rc=1,
        extra_env={"FAKE_NIRI_INVALID_JSON": "{not json"},
    )
    assert calls[0] == "fuzzel" and calls[1] == "query", calls
    assert is_active(state, "eDP-1")
    print("PASS: invalid IPC JSON performs no output commands")

    malformed = {
        "eDP-1": {
            "name": "eDP-1",
            "current_mode": None,
            "logical": None,
        }
    }
    _, _, state = run_case(
        "missing modes field",
        malformed,
        "0",
        [],
        expected_rc=1,
    )
    assert state["eDP-1"]["current_mode"] is None
    print("PASS: an output without a modes field is rejected before any change")

    _, _, state = run_case(
        "IPC unavailable",
        {"eDP-1": output("eDP-1")},
        "0",
        [],
        expected_rc=1,
        extra_env={"FAKE_NIRI_QUERY_FAIL": "1"},
    )
    assert is_active(state, "eDP-1")
    print("PASS: unavailable IPC exits without output commands")

    _, calls, state = run_case(
        "Escape",
        {"eDP-1": output("eDP-1"), "DP-1": output("DP-1", active=False)},
        "0",
        [],
        extra_env={"FAKE_FUZZEL_CANCEL": "1"},
    )
    assert calls == ["fuzzel"], calls
    assert is_active(state, "eDP-1") and not is_active(state, "DP-1")
    print("PASS: Escape exits without querying or modifying outputs")

    _, calls, state = run_case(
        "empty selection",
        {"eDP-1": output("eDP-1")},
        "__empty__",
        [],
    )
    assert calls == ["fuzzel"], calls
    assert is_active(state, "eDP-1")
    print("PASS: an empty selection exits without output modifications")

    _, calls, state = run_case(
        "invalid index",
        {"eDP-1": output("eDP-1")},
        "99",
        [],
        expected_rc=1,
    )
    assert calls == ["fuzzel"], calls
    assert is_active(state, "eDP-1")
    print("PASS: an invalid index exits without output modifications")

    _, calls, state = run_case(
        "advanced settings",
        {"eDP-1": output("eDP-1")},
        "3",
        [],
    )
    assert calls == ["fuzzel", "wdisplays"], calls
    assert is_active(state, "eDP-1")
    print("PASS: advanced settings launches wdisplays directly")


with tempfile.TemporaryDirectory(prefix="niri-display-menu-test.") as tmpdir:
    tmp = Path(tmpdir)
    make_fakes(tmp)
    test_menu_contract(tmp)
    test_internal_only()
    test_extend()
    test_external_only()
    test_failures_and_cancel()

print("ALL TESTS PASSED")
