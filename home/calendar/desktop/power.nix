{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  niriEnabled = osConfig != null && (osConfig.my.desktop.niri.enable or false);
  shell = if osConfig != null then (osConfig.my.desktop.niri.shell or "dms") else "dms";
  enabled = niriEnabled && shell == "waybar";
  niriLib = import ./lib.nix { inherit pkgs lib; };

  # All five actions go through this one script. Lock and suspend reuse the
  # same niri-lock helpers as Alt+L and the logind sleep hook.
  powerMenu = pkgs.writeShellApplication {
    name = "niri-power";
    runtimeInputs = with pkgs; [
      fuzzel
      libnotify
      niri
      niriLib.niriLock
      niriLib.niriLockWait
      systemd
    ];
    text = ''
      set -euo pipefail

      action="''${1:?missing action}"

      fuzzel_bin="''${NIRI_POWER_FUZZEL:-${lib.getExe pkgs.fuzzel}}"
      niri_bin="''${NIRI_POWER_NIRI:-${lib.getExe pkgs.niri}}"
      systemctl_bin="''${NIRI_POWER_SYSTEMCTL:-${lib.getExe' pkgs.systemd "systemctl"}}"
      lock_bin="''${NIRI_POWER_LOCK:-${lib.getExe niriLib.niriLock}}"
      lock_wait_bin="''${NIRI_POWER_LOCK_WAIT:-${lib.getExe niriLib.niriLockWait}}"
      notify_bin="''${NIRI_POWER_NOTIFY:-${lib.getExe' pkgs.libnotify "notify-send"}}"

      confirm() {
        label="$1"
        # Cancel is the first and default entry. Escape or choosing anything
        # other than the exact label exits without performing the action.
        if ! choice="$(printf '取消\n%s\n' "$label" | "$fuzzel_bin" \
          --dmenu \
          --prompt='确认： ' \
          --lines=2 \
          --width=24 \
          --select='取消' \
          --font='Noto Sans CJK SC 14' \
          --background-color=1e1e2eff \
          --text-color=cdd6f4ff \
          --input-color=cdd6f4ff \
          --prompt-color=89b4faff \
          --selection-color=313244ff \
          --selection-text-color=cdd6f4ff \
          --border-color=45475aff \
          --border-width=1 \
          --border-radius=12)"; then
          return 1
        fi
        [ "$choice" = "$label" ]
      }

      case "$action" in
        lock)
          exec "$lock_bin"
          ;;
        suspend)
          # This must finish before systemctl suspend. If niri/logind cannot
          # prove that the lock surface is ready, cancel this suspend instead
          # of releasing the sleep inhibitor with an unlocked screen.
          if ! "$lock_wait_bin"; then
            echo "niri-power: refusing to suspend because the screen lock did not become ready" >&2
            "$notify_bin" "电源菜单" "锁屏未就绪，已取消挂起" >/dev/null 2>&1 || true
            exit 1
          fi
          exec "$systemctl_bin" suspend
          ;;
        logout)
          confirm "退出登录" || exit 0
          exec "$niri_bin" msg action quit --skip-confirmation
          ;;
        reboot)
          confirm "重启" || exit 0
          exec "$systemctl_bin" reboot
          ;;
        shutdown)
          confirm "关机" || exit 0
          exec "$systemctl_bin" poweroff
          ;;
        *)
          echo "niri-power: unknown action '$action'" >&2
          exit 2
          ;;
      esac
    '';
  };

  wlogoutEntries = [
    {
      label = "lock";
      action = "${powerMenu}/bin/niri-power lock";
      text = "锁屏  L";
      keybind = "l";
    }
    {
      label = "suspend";
      action = "${powerMenu}/bin/niri-power suspend";
      text = "挂起  U";
      keybind = "u";
    }
    {
      label = "logout";
      action = "${powerMenu}/bin/niri-power logout";
      text = "退出  E";
      keybind = "e";
    }
    {
      label = "reboot";
      action = "${powerMenu}/bin/niri-power reboot";
      text = "重启  R";
      keybind = "r";
    }
    {
      label = "shutdown";
      action = "${powerMenu}/bin/niri-power shutdown";
      text = "关机  S";
      keybind = "s";
    }
  ];

  # wlogout parses a stream of JSON objects, not one JSON array. Keep the
  # newline-separated object form and pass the generated file explicitly.
  wlogoutLayout = lib.concatMapStringsSep "\n" (entry: builtins.toJSON entry) wlogoutEntries + "\n";

  # Wide cards get the full 152px design. The narrow single-column layout has
  # only 80px per card (5*80 + 4*8 = 432), so use a compact icon/padding variant
  # instead of clipping the 40px icon into an 86px button.
  wlogoutStyle =
    {
      name,
      paddingTop,
      iconTop,
      iconSize,
    }:
    pkgs.writeText "niri-wlogout-style-${name}.css" ''
      * {
        font-family: "Noto Sans CJK SC", "JetBrains Mono", sans-serif;
        font-size: 14px;
        background-image: none;
        box-shadow: none;
      }

      /* Layer-shell surface: keep the desktop visible around the cards. */
      window {
        background-color: rgba(17, 17, 27, 0.55);
      }

      button {
        background-color: #1e1e2e;
        color: #cdd6f4;
        border: 1px solid #45475a;
        border-radius: 16px;
        padding: ${toString paddingTop}px 6px 4px 6px;
        background-repeat: no-repeat;
        background-position: center ${toString iconTop}px;
        background-size: ${toString iconSize}px ${toString iconSize}px;
        text-shadow: none;
        box-shadow: none;
        min-width: 0;
        min-height: 0;
      }

      button:hover,
      button:focus {
        background-color: #313244;
        border-color: #89b4fa;
        outline: none;
      }

      #lock {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/lock.png"));
      }

      #suspend {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/suspend.png"));
      }

      #logout {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/logout.png"));
      }

      #reboot {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/reboot.png"));
      }

      #shutdown {
        background-image: image(url("${pkgs.wlogout}/share/wlogout/icons/shutdown.png"));
      }

      #shutdown:hover,
      #shutdown:focus {
        border-color: #f38ba8;
      }
    '';

  wlogoutStyleWide = wlogoutStyle {
    name = "wide";
    paddingTop = 74;
    iconTop = 20;
    iconSize = 40;
  };

  wlogoutStyleNarrow = wlogoutStyle {
    name = "narrow";
    paddingTop = 34;
    iconTop = 4;
    iconSize = 26;
  };

  wlogoutLayoutFile = pkgs.writeText "niri-wlogout-layout" wlogoutLayout;

  # Widths requested by the user: five 128px cards plus four 12px gaps.
  # Height is one 152px card. The margins are computed from niri's logical
  # output size, not the physical mode, and all four edges are explicit.
  powerMenuLauncher = pkgs.writeShellApplication {
    name = "niri-power-menu";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      libnotify
      niri
      util-linux
      wlogout
    ];
    text = ''
      set -euo pipefail

      niri_bin="''${NIRI_POWER_MENU_NIRI:-${lib.getExe pkgs.niri}}"
      jq_bin="''${NIRI_POWER_MENU_JQ:-${lib.getExe pkgs.jq}}"
      wlogout_bin="''${NIRI_POWER_MENU_WLOGOUT:-${lib.getExe pkgs.wlogout}}"
      flock_bin="''${NIRI_POWER_MENU_FLOCK:-${lib.getExe' pkgs.util-linux "flock"}}"
      notify_bin="''${NIRI_POWER_MENU_NOTIFY:-${lib.getExe' pkgs.libnotify "notify-send"}}"

      fail() {
        echo "niri-power-menu: $*" >&2
        "$notify_bin" "电源菜单" "$*" >/dev/null 2>&1 || true
        exit 1
      }

      if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
        fail "XDG_RUNTIME_DIR is not set; cannot create the single-instance lock"
      fi

      # Hold the descriptor across exec so a second menu invocation exits
      # while the first wlogout process is still alive.
      exec 9>"$XDG_RUNTIME_DIR/niri-power-menu.lock"
      if ! "$flock_bin" -n 9; then
        exit 0
      fi

      if ! output_json="$("$niri_bin" msg -j focused-output 2>/dev/null)"; then
        fail "无法读取 niri 当前输出尺寸"
      fi

      if ! size="$("$jq_bin" -er \
        'select(.logical != null) | "\(.logical.width) \(.logical.height)"' \
        <<<"$output_json")"; then
        fail "当前 niri 输出没有逻辑尺寸，无法计算电源菜单布局"
      fi

      read -r output_w output_h <<<"$size"
      if [[ ! "$output_w" =~ ^[0-9]+$ || ! "$output_h" =~ ^[0-9]+$ ]]; then
        fail "niri 返回了无效的逻辑尺寸 '$size'"
      fi

      if [ "$output_w" -le 32 ] || [ "$output_h" -le 32 ]; then
        fail "当前输出尺寸 ''${output_w}x''${output_h} 太小，无法容纳电源菜单"
      fi

      if [ "$output_w" -ge 760 ] && [ "$output_h" -ge 320 ]; then
        columns=5
        content_w=688
        content_h=152
        column_spacing=12
        row_spacing=0
        css_file=${wlogoutStyleWide}
      else
        columns=1
        content_w=$((output_w - 32))
        if [ "$content_w" -gt 320 ]; then
          content_w=320
        fi
        content_h=$((output_h - 32))
        if [ "$content_h" -gt 432 ]; then
          content_h=432
        fi
        column_spacing=0
        row_spacing=8
        # Five compact cards plus four 8px gaps need 432px. Failing here is
        # better than launching a clipped or overlapping menu.
        if [ "$content_w" -lt 160 ] || [ "$content_h" -lt 432 ]; then
          fail "当前输出尺寸 ''${output_w}x''${output_h} 无法容纳单列电源菜单"
        fi
        css_file=${wlogoutStyleNarrow}
      fi

      left=$(((output_w - content_w) / 2))
      right=$((output_w - content_w - left))
      top=$(((output_h - content_h) / 2))
      bottom=$((output_h - content_h - top))

      exec "$wlogout_bin" \
        -p layer-shell \
        -n \
        -b "$columns" \
        -c "$column_spacing" \
        -r "$row_spacing" \
        -L "$left" \
        -R "$right" \
        -T "$top" \
        -B "$bottom" \
        --layout ${wlogoutLayoutFile} \
        --css "$css_file"
    '';
  };
in
{
  config = lib.mkIf enabled {
    home.packages = [
      powerMenu
      powerMenuLauncher
      pkgs.wlogout
    ];
  };
}
