#!/usr/bin/env bash
# On-demand display mode menu for the main host's niri session.
#
# This helper changes only niri's temporary output state through IPC. It never
# edits a display configuration file: persistent layouts are written by
# wdisplays into ~/.config/kanshi/config and applied by kanshi. Hotplug handling
# is kanshi's job, not this menu's. The external-only branch refuses to turn off
# the internal panel until it has observed an external output actually become
# active.
set -euo pipefail

internal_output="eDP-1"

# Defaults come from writeShellApplication's runtimeInputs. The environment
# overrides exist so the headless regression tests can substitute stubs.
niri_bin="${NIRI_DISPLAY_MENU_NIRI:-niri}"
jq_bin="${NIRI_DISPLAY_MENU_JQ:-jq}"
fuzzel_bin="${NIRI_DISPLAY_MENU_FUZZEL:-fuzzel}"
wdisplays_bin="${NIRI_DISPLAY_MENU_WDISPLAYS:-wdisplays}"
sleep_bin="${NIRI_DISPLAY_MENU_SLEEP:-sleep}"

outputs_json=""

fail() {
  echo "niri-display-menu: $*" >&2
  exit 1
}

# Replace the cached snapshot and reject malformed IPC responses before any
# output command is allowed to run. Disabled outputs are valid, so nullable
# current_mode/logical values are accepted; a missing or non-array modes field
# is not.
refresh_outputs() {
  local json

  if ! json="$("$niri_bin" msg -j outputs 2>/dev/null)"; then
    fail "cannot read display state through niri IPC"
  fi

  if ! "$jq_bin" -e '
    if type != "object" then
      false
    else
      all(to_entries[];
        try (
          (.value | type) == "object"
          and (.value.name | type) == "string"
          and .key == .value.name
          and (.value | has("modes"))
          and (.value.modes | type) == "array"
          and (.value | has("current_mode"))
          and ((.value.current_mode | type) == "number" or .value.current_mode == null)
          and (.value | has("logical"))
          and ((.value.logical | type) == "object" or .value.logical == null)
        ) catch false
      )
    end
  ' <<<"$json" >/dev/null 2>&1; then
    fail "niri returned invalid or unexpected output JSON"
  fi

  outputs_json="$json"
}

output_exists() {
  local name="$1"
  # shellcheck disable=SC2016
  "$jq_bin" -e --arg name "$name" '
    (type == "object") and has($name)
  ' <<<"$outputs_json" >/dev/null
}

output_has_modes() {
  local name="$1"
  # shellcheck disable=SC2016
  "$jq_bin" -e --arg name "$name" '
    ((.[$name] // {}).modes // []) | length > 0
  ' <<<"$outputs_json" >/dev/null
}

output_is_active() {
  local name="$1"
  # shellcheck disable=SC2016
  "$jq_bin" -e --arg name "$name" '
    if has($name) then
      (.[$name].current_mode != null) and (.[$name].logical != null)
    else
      false
    end
  ' <<<"$outputs_json" >/dev/null
}

has_any_active_output() {
  "$jq_bin" -e '
    any(.[]; (.current_mode != null) and (.logical != null))
  ' <<<"$outputs_json" >/dev/null
}

list_outputs_with_modes() {
  "$jq_bin" -r '
    to_entries[]
    | select((.value.modes | length) > 0)
    | .value.name
  ' <<<"$outputs_json"
}

list_external_outputs_with_modes() {
  # shellcheck disable=SC2016
  "$jq_bin" -r --arg internal "$internal_output" '
    to_entries[]
    | select(.value.name != $internal)
    | select((.value.modes | length) > 0)
    | .value.name
  ' <<<"$outputs_json"
}

list_active_external_outputs() {
  # shellcheck disable=SC2016
  "$jq_bin" -r --arg internal "$internal_output" '
    to_entries[]
    | select(.value.name != $internal)
    | select((.value.current_mode != null) and (.value.logical != null))
    | .value.name
  ' <<<"$outputs_json"
}

enable_output() {
  local name="$1"
  if ! "$niri_bin" msg output "$name" on; then
    echo "niri-display-menu: failed to enable output '$name'" >&2
    return 1
  fi
}

disable_output() {
  local name="$1"
  if ! "$niri_bin" msg output "$name" off; then
    echo "niri-display-menu: failed to disable output '$name'" >&2
    return 1
  fi
}

# Poll for a completed modeset instead of trusting the IPC command's exit
# status. Twenty 50ms sleeps keep the upper bound near one second.
wait_for_active_output() {
  local -a candidates=("$@")
  local attempt name

  for ((attempt = 0; attempt < 20; attempt++)); do
    refresh_outputs
    for name in "${candidates[@]}"; do
      if output_is_active "$name"; then
        return 0
      fi
    done
    if ((attempt < 19)); then
      "$sleep_bin" 0.05
    fi
  done

  return 1
}

restore_internal() {
  refresh_outputs
  if output_is_active "$internal_output"; then
    return 0
  fi
  if ! output_has_modes "$internal_output"; then
    echo "niri-display-menu: cannot restore $internal_output: missing or no available modes" >&2
    return 1
  fi
  if ! enable_output "$internal_output"; then
    return 1
  fi
  if ! wait_for_active_output "$internal_output"; then
    echo "niri-display-menu: $internal_output did not become active after restore" >&2
    return 1
  fi
}

internal_only() {
  refresh_outputs
  if ! output_exists "$internal_output" || ! output_has_modes "$internal_output"; then
    fail "$internal_output is not connected or has no available modes; no outputs were changed"
  fi

  # Never proceed to the off commands until the internal panel is actually
  # active. An IPC "on" acknowledgement is not a completed modeset.
  if ! enable_output "$internal_output"; then
    fail "could not enable $internal_output; external outputs were left untouched"
  fi
  if ! wait_for_active_output "$internal_output"; then
    fail "$internal_output did not become active; external outputs were left untouched"
  fi

  local -a external_active=()
  mapfile -t external_active < <(list_active_external_outputs)

  local name
  for name in "${external_active[@]}"; do
    if ! disable_output "$name"; then
      fail "failed to disable external output '$name'; $internal_output remains active"
    fi
  done

  refresh_outputs
  if ! has_any_active_output; then
    fail "no active output remains after switching to $internal_output"
  fi
}

extend_displays() {
  refresh_outputs

  local -a targets=()
  mapfile -t targets < <(list_outputs_with_modes)
  if ((${#targets[@]} == 0)); then
    fail "no output has available modes; no outputs were changed"
  fi

  local name
  local failed=0
  for name in "${targets[@]}"; do
    if ! enable_output "$name"; then
      failed=1
    fi
  done

  if ! wait_for_active_output "${targets[@]}"; then
    fail "no output became active; no outputs were turned off"
  fi

  if ((failed != 0)); then
    fail "one or more outputs could not be enabled; other outputs were left enabled"
  fi
}

external_only() {
  refresh_outputs

  local -a externals=()
  mapfile -t externals < <(list_external_outputs_with_modes)
  if ((${#externals[@]} == 0)); then
    fail "no connected external output has available modes; $internal_output was not changed"
  fi

  local name
  local failed=0
  for name in "${externals[@]}"; do
    if ! enable_output "$name"; then
      failed=1
    fi
  done

  if ((failed != 0)); then
    echo "niri-display-menu: one or more external outputs failed to enable" >&2
    if ! restore_internal; then
      echo "niri-display-menu: could not confirm that $internal_output is active" >&2
    fi
    fail "refusing to turn off $internal_output after an external enable failure"
  fi

  # Require an observed active external output before the internal panel is
  # turned off. This is the safety boundary for the external-only branch.
  if ! wait_for_active_output "${externals[@]}"; then
    echo "niri-display-menu: no external output became active" >&2
    if ! restore_internal; then
      echo "niri-display-menu: could not confirm that $internal_output is active" >&2
    fi
    fail "refusing to turn off $internal_output because no external output is active"
  fi

  if ! disable_output "$internal_output"; then
    fail "failed to turn off $internal_output; external output remains enabled"
  fi

  refresh_outputs
  if ! has_any_active_output; then
    echo "niri-display-menu: no active output remains after disabling $internal_output" >&2
    echo "niri-display-menu: attempting to restore $internal_output" >&2
    if ! enable_output "$internal_output"; then
      echo "niri-display-menu: failed to restore $internal_output" >&2
    fi
    exit 1
  fi
}

menu() {
  local selection

  # Use the selected index, not localized labels, to dispatch actions. Escape
  # and an empty response both exit without touching any output.
  if ! selection="$(
    printf '%s\n' \
      '仅笔记本屏幕' \
      '扩展显示' \
      '仅外接显示器' \
      '高级显示设置（wdisplays）' \
      | "$fuzzel_bin" --dmenu --index --prompt='显示模式: '
  )"; then
    exit 0
  fi
  if [ -z "$selection" ]; then
    exit 0
  fi

  case "$selection" in
    0)
      internal_only
      ;;
    1)
      extend_displays
      ;;
    2)
      external_only
      ;;
    3)
      exec "$wdisplays_bin"
      ;;
    *)
      fail "invalid menu selection '$selection'"
      ;;
  esac
}

menu
