#!/usr/bin/env python3
"""Headless regression checks for the Yazi and Mark Shot desktop workflow.

Run through `scripts/check-desktop`, or directly:

    python3 tests/test_yazi_screenshot.py \
      --activation /nix/store/...-home-manager-generation

The script tests the generated wrappers with temporary directories and stub
`wl-paste`/`mark-shot` commands. It never reads or changes the user's real
clipboard, screenshots, Mark Shot history, or disk devices.
"""

import argparse
import base64
import os
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--activation", required=True)
parser.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
args = parser.parse_args()

REPO = Path(args.repo).resolve()
ACTIVATION = Path(args.activation).resolve()
HOME_FILES = ACTIVATION / "home-files"
BIN = ACTIVATION / "home-path/bin"

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAIGNIUk0AAHomAACAhAAA+gAAAIDo"
    "AAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURf8AABniCTcAAAAHdElNRQfqCxAFEgu1L596AAAA"
    "JXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTExLTE2VDA1OjE4OjExKzAwOjAwvXQCxgAAACV0RVh0ZGF0"
    "ZTptb2RpZnkAMjAyNi0xMS0xNlQwNToxODoxMSswMDowMMwpunoAAAAodEVYdGRhdGU6dGltZXN0"
    "YW1wADIwMjYtMTEtMTZUMDU6MTg6MTErMDA6MDCbPJulAAAACklEQVQI12NgAAAAAgAB4iG8MwAA"
    "AABJRU5ErkJggg=="
)
JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkI"
    "CQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQ"
    "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAABAAED"
    "AREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEB"
    "AAAAAAAAAAAAAAAAAAAHCf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/ADoDFU3/2Q=="
)
WEBP = base64.b64decode(
    "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoBAAEAAgA0JaACdLoB+AADsAD+8MQL/yC5YXXI1/8g"
    "P+QH/ID/+PIAAAA="
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def check(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def run(
    command: list[str],
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int = 60,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env={**os.environ, **(env or {})},
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def make_fake_wl_paste(path: Path) -> None:
    write_executable(
        path,
        """#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --list-types)
    if [ "${FAKE_LIST_STATUS:-0}" -ne 0 ]; then
      exit "${FAKE_LIST_STATUS}"
    fi
    cat "$FAKE_TYPES"
    ;;
  --type)
    if [ "${FAKE_TYPE_STATUS:-0}" -ne 0 ]; then
      printf 'partial image data'
      exit "${FAKE_TYPE_STATUS}"
    fi
    cat "$FAKE_DATA"
    ;;
  *)
    exit 4
    ;;
esac
""",
    )


def make_fake_mark_shot(path: Path) -> None:
    write_executable(
        path,
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$FAKE_LOG"
exit "${FAKE_STATUS:-0}"
""",
    )


def make_fake_notify(path: Path) -> None:
    write_executable(
        path,
        """#!/usr/bin/env bash
exit 0
""",
    )


def paste_environment(
    work: Path,
    fake_wl_paste: Path,
    notify: Path,
    types: Path,
    data: Path,
    extra: dict[str, str] | None = None,
) -> dict[str, str]:
    env = {
        "HOME": str(work),
        "YAZI_PASTE_WL_PASTE": str(fake_wl_paste),
        "YAZI_PASTE_NOTIFY": str(notify),
        "FAKE_TYPES": str(types),
        "FAKE_DATA": str(data),
    }
    env.update(extra or {})
    return env


def paste_files(directory: Path) -> list[Path]:
    return sorted(directory.glob("Screenshot-*"))


# ----------------------------------------------------------- yazi-paste-image


def test_paste_image() -> None:
    binary = BIN / "yazi-paste-image"
    check(binary.is_file() and os.access(binary, os.X_OK), f"missing {binary}")

    with tempfile.TemporaryDirectory(prefix="yazi-paste-test-") as raw:
        root = Path(raw)
        notify = root / "notify"
        fake_wl_paste = root / "wl-paste"
        make_fake_notify(notify)
        make_fake_wl_paste(fake_wl_paste)
        types = root / "types"
        data = root / "data"

        def run_paste(
            work: Path,
            available: str,
            payload: bytes,
            extra_env: dict[str, str] | None = None,
        ) -> subprocess.CompletedProcess[str]:
            types.write_text(available, encoding="utf-8")
            data.write_bytes(payload)
            env = paste_environment(root, fake_wl_paste, notify, types, data, extra_env)
            return run([str(binary)], cwd=work, env=env)

        # Empty clipboard: wl-paste fails and no file must appear.
        empty = root / "empty"
        empty.mkdir()
        result = run_paste(empty, "", b"", {"FAKE_LIST_STATUS": "1"})
        check(result.returncode != 0, "empty clipboard should fail")
        check(not paste_files(empty), "empty clipboard created a file")

        # An unexpected argument is rejected before reading the clipboard.
        result = run(
            [str(binary), "unexpected"],
            cwd=empty,
            env=paste_environment(root, fake_wl_paste, notify, types, data),
        )
        check(result.returncode != 0, "unexpected argument was accepted")
        check(not paste_files(empty), "unexpected argument created a file")

        # Text-only clipboard is not an image.
        text = root / "text"
        text.mkdir()
        result = run_paste(text, "text/plain\n", b"hello")
        check(result.returncode != 0, "text clipboard should be rejected")
        check(not paste_files(text), "text clipboard created a screenshot file")

        # PNG is preferred and saved with the right extension.
        png_dir = root / "png"
        png_dir.mkdir()
        result = run_paste(png_dir, "image/png\nimage/jpeg\n", PNG)
        check(result.returncode == 0, result.stderr)
        png_files = paste_files(png_dir)
        check(len(png_files) == 1, f"expected one PNG, got {png_files}")
        check(png_files[0].suffix == ".png", f"wrong PNG suffix: {png_files[0]}")
        check(
            re.fullmatch(r"Screenshot-\d{8}-\d{6}-[0-9a-f]{4}\.png", png_files[0].name)
            is not None,
            f"unexpected screenshot name: {png_files[0].name}",
        )
        check(png_files[0].read_bytes() == PNG, "PNG contents changed")

        # A second run must not overwrite the first file.
        first_bytes = png_files[0].read_bytes()
        result = run_paste(png_dir, "image/png\n", PNG)
        check(result.returncode == 0, result.stderr)
        png_files = paste_files(png_dir)
        check(len(png_files) == 2, f"expected two PNGs, got {png_files}")
        check(png_files[0].read_bytes() == first_bytes, "existing image was overwritten")
        names = {path.name for path in png_files}
        check(len(names) == 2, f"duplicate screenshot names: {names}")

        # JPEG and WebP get their own extensions.
        for mime, payload, suffix in (
            ("image/jpeg\n", JPEG, ".jpg"),
            ("image/webp\n", WEBP, ".webp"),
        ):
            directory = root / mime.replace("/", "-")
            directory.mkdir()
            result = run_paste(directory, mime, payload)
            check(result.returncode == 0, result.stderr)
            files = paste_files(directory)
            check(len(files) == 1 and files[0].suffix == suffix, (mime, files))

        # PNG wins even when other image types are advertised.
        prefer = root / "prefer"
        prefer.mkdir()
        result = run_paste(prefer, "image/webp\nimage/png\nimage/jpeg\n", PNG)
        check(result.returncode == 0, result.stderr)
        files = paste_files(prefer)
        check(len(files) == 1 and files[0].suffix == ".png", files)

        # Advertised PNG with text payload must not become a fake PNG.
        mismatch = root / "mismatch"
        mismatch.mkdir()
        result = run_paste(mismatch, "image/png\n", b'<html>not an image</html>')
        check(result.returncode != 0, "text payload disguised as PNG was accepted")
        check(not paste_files(mismatch), "mismatched payload left a screenshot")
        check(
            not list(mismatch.glob(".yazi-paste-image.*")),
            "temporary file was not removed after MIME mismatch",
        )

        # A failed clipboard read must remove the partial temporary file.
        partial = root / "partial"
        partial.mkdir()
        result = run_paste(partial, "image/png\n", PNG, {"FAKE_TYPE_STATUS": "7"})
        check(result.returncode != 0, "failed clipboard read was accepted")
        check(not paste_files(partial), "failed clipboard read left a screenshot")
        check(
            not list(partial.glob(".yazi-paste-image.*")),
            "failed clipboard read left a temporary file",
        )

        # Spaces and non-ASCII directory names are handled verbatim.
        unicode_dir = root / "中文 目录" / "with space"
        unicode_dir.mkdir(parents=True)
        result = run_paste(unicode_dir, "image/png\n", PNG)
        check(result.returncode == 0, result.stderr)
        files = paste_files(unicode_dir)
        check(len(files) == 1 and files[0].parent == unicode_dir, files)

        # The live clipboard is not limited by cliphist's 2 MiB session cap.
        large = root / "large"
        large.mkdir()
        large_png = PNG + b"\0" * (3 * 1024 * 1024)
        result = run_paste(large, "image/png\n", large_png)
        check(result.returncode == 0, result.stderr)
        files = paste_files(large)
        check(len(files) == 1, f"large clipboard was not saved: {files}")
        check(files[0].stat().st_size > 3 * 1024 * 1024, "large image was truncated")

    print("PASS: yazi-paste-image handles empty/text/PNG/JPEG/WebP and large data")


# --------------------------------------------------------------- desktop-shot


def test_desktop_shot() -> None:
    binary = BIN / "desktop-shot"
    check(binary.is_file() and os.access(binary, os.X_OK), f"missing {binary}")

    with tempfile.TemporaryDirectory(prefix="desktop-shot-test-") as raw:
        root = Path(raw)
        fake_mark_shot = root / "mark-shot"
        notify = root / "notify"
        log = root / "args.log"
        make_fake_mark_shot(fake_mark_shot)
        make_fake_notify(notify)

        screenshot_dir = root / "中文 目录" / "Screenshots"
        env = {
            "DESKTOP_SHOT_MARK_SHOT": str(fake_mark_shot),
            "DESKTOP_SHOT_NOTIFY": str(notify),
            "DESKTOP_SHOT_DIR": str(screenshot_dir),
            "FAKE_LOG": str(log),
        }

        def invoke(*arguments: str) -> subprocess.CompletedProcess[str]:
            if log.exists():
                log.unlink()
            return run([str(binary), *arguments], env=env)

        result = invoke("capture")
        check(result.returncode == 0, result.stderr)
        check(
            log.read_text(encoding="utf-8").splitlines()
            == ["--output", str(screenshot_dir), "-t", "cs"],
            log.read_text(encoding="utf-8"),
        )
        check(screenshot_dir.is_dir(), "capture did not create the screenshot directory")
        check(
            screenshot_dir.stat().st_uid == os.getuid(),
            "screenshot directory is not owned by the user",
        )

        result = invoke("scroll")
        check(result.returncode == 0, result.stderr)
        check(
            log.read_text(encoding="utf-8").splitlines()
            == ["--scroll", "--output", str(screenshot_dir), "-t", "cs"],
            log.read_text(encoding="utf-8"),
        )

        result = invoke("pin")
        check(result.returncode == 0, result.stderr)
        check(
            log.read_text(encoding="utf-8").splitlines() == ["--pin-clipboard"],
            log.read_text(encoding="utf-8"),
        )

        # Unknown or incomplete arguments must not launch Mark Shot.
        for arguments in ([], ["bogus"], ["capture", "extra"]):
            result = invoke(*arguments)
            check(result.returncode != 0, f"accepted invalid arguments: {arguments}")
            check(not log.exists(), f"invalid arguments launched Mark Shot: {arguments}")

    print("PASS: desktop-shot maps capture/scroll/pin and rejects invalid arguments")


# --------------------------------------------------------------- yazi-pin-image


def test_yazi_pin_image() -> None:
    binary = BIN / "yazi-pin-image"
    check(binary.is_file() and os.access(binary, os.X_OK), f"missing {binary}")

    with tempfile.TemporaryDirectory(prefix="yazi-pin-test-") as raw:
        root = Path(raw)
        fake_mark_shot = root / "mark-shot"
        notify = root / "notify"
        log = root / "args.log"
        make_fake_mark_shot(fake_mark_shot)
        make_fake_notify(notify)

        image = root / "中文 图片.png"
        image.write_bytes(PNG)
        text = root / "note.txt"
        text.write_text("plain text\n", encoding="utf-8")

        env = {
            "YAZI_PIN_MARK_SHOT": str(fake_mark_shot),
            "YAZI_PIN_NOTIFY": str(notify),
            "FAKE_LOG": str(log),
        }

        def invoke(*arguments: str, extra_env: dict[str, str] | None = None):
            if log.exists():
                log.unlink()
            return run([str(binary), *arguments], env={**env, **(extra_env or {})})

        result = invoke(str(image))
        check(result.returncode == 0, result.stderr)
        check(
            log.read_text(encoding="utf-8").splitlines() == ["--pin-image", str(image)],
            log.read_text(encoding="utf-8"),
        )

        for arguments in (
            (),
            (str(root),),
            (str(text),),
            (str(root / "missing.png"),),
            (str(image), str(image)),
        ):
            result = invoke(*arguments)
            check(result.returncode != 0, f"accepted non-image input: {arguments}")
            check(not log.exists(), f"launched Mark Shot for non-image input: {arguments}")

        result = invoke(str(image), extra_env={"FAKE_STATUS": "1"})
        check(result.returncode != 0, "Mark Shot failure was reported as success")

    print("PASS: yazi-pin-image forwards only real images and reports failures")


# ------------------------------------------------------------ generated config


def test_yazi_config() -> None:
    yazi = tomllib.loads(read(HOME_FILES / ".config/yazi/yazi.toml"))
    previewers = yazi.get("plugin", {}).get("prepend_previewers", [])
    ouch_previewer = next((entry for entry in previewers if entry.get("run") == "ouch"), None)
    check(ouch_previewer is not None, "ouch archive previewer missing")
    check(
        ouch_previewer.get("mime")
        == "application/{*zip*,*7z*,*rar*,*tar*,*gzip*,*xz*,*zstd*,*bzip2*,*lz4*,*lzma*,*lzo*,*java-archive*}",
        ouch_previewer,
    )

    keymap = tomllib.loads(read(HOME_FILES / ".config/yazi/keymap.toml"))
    entries = keymap["mgr"]["prepend_keymap"]

    def key(entry: dict) -> tuple[str, ...]:
        on = entry["on"]
        return tuple(on) if isinstance(on, list) else (on,)

    by_key = {key(entry): entry for entry in entries}
    check(len(by_key) == len(entries), "Yazi keymap contains duplicate keys")
    expected = {
        ("C",): ("plugin ouch", "Compress selected files"),
        ("E",): ("shell -- ya pub extract --list %s", "Extract selected archives"),
        ("M",): ("plugin mount", "Mount and unmount drives"),
        ("c", "p"): ("plugin smart-paste", "Paste into hovered directory"),
        ("c", "i"): ("shell -- yazi-paste-image", "Save clipboard image to current directory"),
        ("c", "t"): ("shell -- yazi-pin-image %h", "Pin hovered image with Mark Shot"),
        ("g", "h"): ("cd ~", "Go home"),
        ("g", "c"): ("cd ~/code", "Go to ~/code"),
        ("g", "p"): ("cd ~/Pictures", "Go to ~/Pictures"),
        ("g", "s"): ("cd ~/Pictures/Screenshots", "Go to ~/Pictures/Screenshots"),
        ("g", "r"): (
            'shell -- ya emit cd "$(git rev-parse --show-toplevel)"',
            "Go to git repository root",
        ),
    }
    for binding, (run_command, description) in expected.items():
        check(binding in by_key, f"missing Yazi binding: {binding}")
        check(by_key[binding]["run"] == run_command, (binding, by_key[binding]))
        check(by_key[binding]["desc"] == description, (binding, by_key[binding]))

    # Keep the existing bindings and leave Yazi's trash semantics alone.
    for binding, run_command in (
        (("<Enter>",), "plugin smart-enter"),
        (("T",), "plugin toggle-pane max-preview"),
        (("<A-p>",), "plugin toggle-pane min-preview"),
        (("c", "m"), "plugin chmod"),
    ):
        check(binding in by_key and by_key[binding]["run"] == run_command, binding)
    for binding in (("d",), ("D",), ("g", "t"), ("g", "d")):
        check(binding not in by_key, f"built-in binding overridden: {binding}")

    plugins = {path.name for path in (HOME_FILES / ".config/yazi/plugins").iterdir()}
    for plugin in (
        "smart-enter.yazi",
        "full-border.yazi",
        "toggle-pane.yazi",
        "git.yazi",
        "chmod.yazi",
        "ouch.yazi",
        "mount.yazi",
        "smart-paste.yazi",
    ):
        check(plugin in plugins, f"Yazi plugin missing: {plugin}")

    init = read(HOME_FILES / ".config/yazi/init.lua")
    check('require("full-border"):setup()' in init, init)
    check('require("git"):setup()' in init, init)

    print("PASS: Yazi config keeps existing bindings and adds archive/paste/mount keys")


def test_compositor_bindings() -> None:
    niri = read(HOME_FILES / ".config/niri/config.kdl")
    for line in (
        'Ctrl+Q { spawn "desktop-shot" "capture"; }',
        'Ctrl+Shift+Q { spawn "desktop-shot" "scroll"; }',
        'Ctrl+Alt+Q { spawn "desktop-shot" "pin"; }',
        "Print { screenshot; }",
        "Ctrl+Print { screenshot-screen; }",
        "Alt+Print { screenshot-window; }",
        'Mod+E hotkey-overlay-title="File manager: Yazi" { spawn "kitty" "-e" "yazi"; }',
    ):
        check(line in niri, f"niri binding missing: {line}")
    check('spawn "nautilus"' not in niri, "niri still launches Nautilus directly")

    sway = read(HOME_FILES / ".config/sway/config")
    for line in (
        "bindsym $mod+e exec kitty -e yazi",
        "bindsym Ctrl+q exec desktop-shot capture",
        "bindsym Ctrl+Shift+q exec desktop-shot scroll",
        "bindsym Ctrl+Alt+q exec desktop-shot pin",
        "grim",
    ):
        check(line in sway, f"Sway binding missing: {line}")
    check("exec nautilus" not in sway, "Sway still launches Nautilus directly")

    # The mini host's original files are not part of this change.
    check(
        "Mod+E hotkey-overlay-title=\"File manager: Nautilus\"" in read(REPO / "config/niri/config-dms.kdl"),
        "config-dms.kdl was modified unexpectedly",
    )
    mini_sway = read(REPO / "config/sway/config")
    check("set $files nautilus" in mini_sway, "config/sway/config was modified unexpectedly")
    check("bindsym $mod+e exec $files" in mini_sway, "mini Sway Mod+E changed unexpectedly")

    print("PASS: niri and main Sway bind Mark Shot and Yazi; mini host files are unchanged")


# ---------------------------------------------------------------- mark-shot


def test_mark_shot_package() -> None:
    binary = BIN / "mark-shot"
    check(binary.is_file() and os.access(binary, os.X_OK), f"missing {binary}")
    # Mark Shot prepares its default user config on startup. Give the version
    # probe a throwaway HOME so checking packages never edits the real config.
    with tempfile.TemporaryDirectory(prefix="mark-shot-test-") as raw:
        home = Path(raw)
        result = run(
            [str(binary), "--version"],
            env={
                "HOME": str(home),
                "XDG_CONFIG_HOME": str(home / ".config"),
                "XDG_DATA_HOME": str(home / ".local/share"),
                "XDG_CACHE_HOME": str(home / ".cache"),
            },
            timeout=120,
        )
    check(result.returncode == 0, result.stderr)
    check(result.stdout.strip() == "mark-shot 0.2.0", result.stdout)

    print("PASS: mark-shot 0.2.0 is packaged and starts without a display")


def test_appimage_entry() -> None:
    """The hand-maintained AppImage needs a launcher entry and a detached run.

    `appimage-run` is a foreground program: run bare in a terminal it holds that
    terminal until the app exits. Both entry points go through the `ds-bot`
    wrapper, which forks the runner into its own session, and the desktop entry
    additionally declares Terminal=false so no terminal is created at all.
    """
    binary = BIN / "ds-bot"
    check(binary.is_file() and os.access(binary, os.X_OK), f"missing {binary}")

    wrapper = read(binary)
    check("setsid -f" in wrapper, "ds-bot does not detach appimage-run")
    check("appimage-run" in wrapper, "ds-bot does not call appimage-run")

    # Missing images must fail loudly instead of launching an empty window.
    with tempfile.TemporaryDirectory(prefix="ds-bot-test-") as raw:
        missing = Path(raw) / "absent.AppImage"
        result = run(
            [str(binary)],
            env={"DS_BOT_APPIMAGE": str(missing)},
            timeout=60,
        )
    check(result.returncode == 1, (result.returncode, result.stderr))
    check("no executable AppImage" in result.stderr, result.stderr)

    # xdg.desktopEntries installs the file through home.packages, so it lives
    # in the profile share directory rather than home-files. Exec points at the
    # wrapper's own store path, which is the same program the profile symlinks
    # to, so compare the trailing component instead of the whole path.
    packaged = sorted((ACTIVATION / "home-path/share/applications").glob("ds-bot.desktop"))
    check(bool(packaged), "ds-bot.desktop was not installed")
    entry = read(packaged[0])
    check("Terminal=false" in entry, entry)
    check("Icon=dsbot" in entry, entry)
    check("StartupWMClass=dsbot" in entry, entry)
    exec_line = next(
        (line for line in entry.splitlines() if line.startswith("Exec=")), ""
    )
    check(exec_line.endswith("/bin/ds-bot"), (exec_line, entry))
    check(
        not re.search(r"^Icon=/nix/store", entry, re.MULTILINE),
        "Icon must be a theme name, not a store path",
    )

    icon = HOME_FILES / ".local/share/icons/hicolor/256x256/apps/dsbot.png"
    check(icon.is_file(), f"missing icon {icon}")

    print("PASS: DS Bot has a detached command and a Terminal=false launcher entry")


def main() -> None:
    test_paste_image()
    test_desktop_shot()
    test_yazi_pin_image()
    test_yazi_config()
    test_compositor_bindings()
    test_mark_shot_package()
    test_appimage_entry()


if __name__ == "__main__":
    main()
