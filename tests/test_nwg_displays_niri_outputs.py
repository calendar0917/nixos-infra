#!/usr/bin/env python3
"""Headless regression checks for nwg-displays' niri list_outputs()."""
import argparse
import ast
import copy
import json
import types

parser = argparse.ArgumentParser()
parser.add_argument("--source", required=True)
args = parser.parse_args()
with open(args.source, encoding="utf-8") as handle:
    tree = ast.parse(handle.read())
fn = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "list_outputs")
fixture = {}
socket_mode = False
messages = []
ctx = {
    "os": types.SimpleNamespace(getenv=lambda key: "/test/niri.sock" if key == "NIRI_SOCKET" else None),
    "json": json,
    "eprint": lambda *parts: messages.append(" ".join(map(str, parts))),
    "niri_msg": lambda command: json.dumps({"Ok": {"Outputs": fixture}}),
    "Gdk": types.SimpleNamespace(
        Display=types.SimpleNamespace(
            get_default=lambda: types.SimpleNamespace(get_n_monitors=lambda: 0)
        )
    ),
}

def run(*positional, **keyword):
    if socket_mode:
        raise FileNotFoundError("test: niri CLI unavailable")
    return types.SimpleNamespace(stdout=json.dumps(fixture))

ctx["subprocess"] = types.SimpleNamespace(run=run)
exec(compile(ast.Module(body=[fn], type_ignores=[]), args.source, "exec"), ctx)
mode = {"width": 1920, "height": 1080, "refresh_rate": 60000, "is_preferred": True}
active = {
    "make": "Test", "model": "Panel", "current_mode": 0, "modes": [mode],
    "logical": {"x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1, "transform": "Normal"},
}
disabled = dict(active, current_mode=None, logical=None)

fixture = {"eDP-1": copy.deepcopy(active)}
out = ctx["list_outputs"]()
assert list(out) == ["eDP-1"] and out["eDP-1"]["active"] is True
print("PASS: active output")

fixture = {"eDP-1": copy.deepcopy(active), "DP-1": copy.deepcopy(disabled)}
out = ctx["list_outputs"]()
assert len(out) == 2 and out["DP-1"]["active"] is False
assert out["DP-1"]["physical-width"] == 1920
assert out["DP-1"]["physical-height"] == 1080
assert out["DP-1"]["monitor"] is None
print("PASS: disabled output retained with usable preferred mode")

fixture = {"DP-1": copy.deepcopy(disabled)}
out = ctx["list_outputs"]()
assert list(out) == ["DP-1"] and out["DP-1"]["active"] is False
print("PASS: all outputs disabled")

fixture = {"DP-1": dict(copy.deepcopy(disabled), current_mode=999)}
out = ctx["list_outputs"]()
assert out["DP-1"]["physical-width"] == 1920 and out["DP-1"]["active"] is False
print("PASS: out-of-range current_mode")

fixture = {"eDP-1": copy.deepcopy(active), "DP-1": dict(copy.deepcopy(disabled), modes=[])}
out = ctx["list_outputs"]()
assert list(out) == ["eDP-1"]
assert any("no available modes" in message for message in messages)
print("PASS: output without modes does not hide healthy output")

fixture = {"eDP-1": copy.deepcopy(active)}
socket_mode = True
out = ctx["list_outputs"]()
assert out["eDP-1"]["active"] is True
print("PASS: nested socket fallback response")
