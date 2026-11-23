#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/statusline-hud"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SETTINGS_FILE="${HUD_SETTINGS_FILE:-${HOME:-/tmp}/.gemini/antigravity-cli/settings.json}"

CONFIG_DEFAULTS='{"preset":"standard","showTitle":false,"showMode":true,"showPath":true,"showGit":true,"showQuota":true,"show3pQuota":true,"showActivity":true,"showSandboxOff":false,"showTokens":true,"showCache":true,"showDuration":true,"showCost":true}'
VALID_PRESETS='["standard","compact","minimal"]'

PREVIEW_PAYLOAD='{"cwd":"/home/user/projects/statusline-hud","conversation_title":"Refactor statusline layout","agent_state":"working","cycle_mode":"plan","model":{"display_name":"Gemini 4 Neon (XHigh)"},"vcs":{"type":"git","branch":"main","dirty":true},"context_window":{"used_percentage":18.4,"total_input_tokens":261000,"total_output_tokens":7000,"current_usage":{"input_tokens":30000,"cache_read_input_tokens":98000,"cache_creation_input_tokens":0}},"quota":{"gemini-5h":{"remaining_fraction":0.82,"reset_in_seconds":3600},"gemini-weekly":{"remaining_fraction":0.93,"reset_in_seconds":560580},"3p-5h":{"remaining_fraction":0.70,"reset_in_seconds":7200},"3p-weekly":{"remaining_fraction":0.85,"reset_in_seconds":400000}},"artifact_count":2,"subagents":[{"name":"a","status":"running"},{"name":"b","status":"completed"}],"task_count":1,"sandbox":{"enabled":false},"cost":{"total_usd":0.42,"estimated":true},"terminal_width":120}'

jq_install_hint() {
  case "${OSTYPE:-}" in
    darwin*) printf 'brew install jq' ;;
    *)       printf 'sudo apt install jq  # or: sudo dnf install jq / pacman -S jq' ;;
  esac
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'Error: jq is required (%s)\n' "$(jq_install_hint)" >&2
    exit 1
  fi
}

to_tilde_path() {
  local p="$1" h="${HOME:-}"
  h="${h%/}"
  if [ -n "$h" ] && [ "$p" = "$h" ]; then
    printf '~'
  elif [ -n "$h" ] && [[ "$p" == "$h/"* ]]; then
    printf '~/%s' "${p#"$h/"}"
  else
    printf '%s' "$p"
  fi
}

expand_tilde() {
  local p="$1" h="${HOME:-}"
  h="${h%/}"
  if [ -n "$h" ] && [ "$p" = "~" ]; then
    printf '%s' "$h"
  elif [ -n "$h" ] && [[ "$p" == "~/"* ]]; then
    printf '%s/%s' "$h" "${p#"~/"}"
  else
    printf '%s' "$p"
  fi
}

resolve_statusline_script() {
  local cand
  for cand in \
    "${HUD_STATUSLINE_SCRIPT:-}" \
    "${PLUGIN_ROOT}/scripts/statusline.sh" \
    "${HOME:-}/.gemini/config/plugins/statusline-hud/scripts/statusline.sh" \
    "${PWD:-}/.agents/plugins/statusline-hud/scripts/statusline.sh" \
    "${HOME:-}/.gemini/antigravity-cli/statusline.sh"; do
    if [ -n "$cand" ] && [ -f "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

read_json_object_or_fail() {
  local file="$1" hint="$2"
  [ -e "$file" ] || { printf '{}'; return 0; }
  if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    printf 'Error: %s is not a valid JSON object%s\n' "$(to_tilde_path "$file")" "$hint" >&2
    exit 1
  fi
  cat "$file"
}

atomic_write_file() {
  local target="$1" content="$2" mode="${3:-}" tmp
  mkdir -p "$(dirname "$target")"
  tmp="${target}.tmp.$$"
  if (
    if [ "$mode" = "600" ]; then umask 077; fi
    printf '%s\n' "$content" > "$tmp" || exit 1
    if [ -n "$mode" ]; then chmod "$mode" "$tmp" 2>/dev/null || true; fi
  ) && mv -f "$tmp" "$target"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

print_effective_config() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '  (install jq to inspect effective config: %s)\n' "$(jq_install_hint)"
    return 0
  fi

  local jq_prog='
    (if type == "object" then . else {} end) as $cfg
    | $defaults | to_entries[]
    | .key as $k | .value as $def
    | (if $k == "preset" then
         if ($cfg.preset | type) == "string" and (($presets | index($cfg.preset)) != null) then $cfg.preset else null end
       else
         if ($cfg[$k] | type) == "boolean" then $cfg[$k] else null end
       end) as $ov
    | (if $ov != null then $ov else $def end) as $val
    | (if $ov == null then "default" elif $val != $def then "override" else "configured" end) as $src
    | [$k, ($val | tostring), $src] | @tsv
  '
  local out=""
  if [ -r "$CONFIG_FILE" ]; then
    out=$(jq -r --argjson defaults "$CONFIG_DEFAULTS" --argjson presets "$VALID_PRESETS" "$jq_prog" "$CONFIG_FILE" 2>/dev/null || true)
  fi
  if [ -z "$out" ]; then
    out=$(jq -nr --argjson defaults "$CONFIG_DEFAULTS" --argjson presets "$VALID_PRESETS" "{} | ${jq_prog}")
  fi

  local k val src
  while IFS=$'\t' read -r k val src; do
    if [ "$k" = "preset" ]; then
      printf '  %-15s = %-8s (%s)\n' "$k" "$val" "$src"
    elif [ "$val" = "true" ]; then
      printf '  %-15s = [ON]     (%s)\n' "$k" "$src"
    else
      printf '  %-15s = [OFF]    (%s)\n' "$k" "$src"
    fi
  done <<< "$out"
}

cmd_doctor() {
  local has_jq=0 script_path="" script_tilde="" issues=0

  printf '=== Environment ===\n'
  printf '  bash:     %s\n' "${BASH_VERSION:-unknown}"
  if command -v jq >/dev/null 2>&1; then
    has_jq=1
    printf '  jq:       OK (%s)\n' "$(jq --version 2>/dev/null || printf 'installed')"
  else
    printf '  jq:       MISSING (install: %s)\n' "$(jq_install_hint)"
    issues=$((issues + 1))
  fi
  if command -v git >/dev/null 2>&1; then
    printf '  git:      OK (%s)\n' "$(git --version 2>/dev/null | head -n 1)"
  else
    printf '  git:      not installed (optional)\n'
  fi

  printf '\n=== Statusline Script ===\n'
  if script_path=$(resolve_statusline_script); then
    script_tilde=$(to_tilde_path "$script_path")
    printf '  path:     %s\n' "$script_tilde"
    if [ -x "$script_path" ]; then
      printf '  exec:     OK (executable)\n'
    else
      printf '  exec:     NOT EXECUTABLE (run: chmod +x %s)\n' "$script_tilde"
      issues=$((issues + 1))
    fi
  else
    printf '  path:     NOT FOUND\n'
    issues=$((issues + 1))
  fi

  printf '\n=== Antigravity CLI Settings (%s) ===\n' "$(to_tilde_path "$SETTINGS_FILE")"
  if [ ! -e "$SETTINGS_FILE" ]; then
    printf '  status:   not found (statusLine not configured yet)\n'
    [ -n "$script_tilde" ] && printf '  activate: /statusline %s\n' "$script_tilde"
  elif [ ! -r "$SETTINGS_FILE" ]; then
    printf '  status:   unreadable (permission denied)\n'
  elif [ "$has_jq" -eq 0 ]; then
    printf '  status:   exists (install jq to inspect JSON)\n'
  else
    local sl_type="" sl_cmd="" sl_enabled="" sl_stack="" sl_cmd_exp=""
    if ! {
      IFS= read -r -d '' sl_type \
      && IFS= read -r -d '' sl_cmd \
      && IFS= read -r -d '' sl_enabled \
      && IFS= read -r -d '' sl_stack
    } < <(
      jq -j '
        if type != "object" then error("not object") else . end
        | (.statusLine | type) as $t
        | ($t + "\u0000"
          + (if $t == "object" then (.statusLine.command // "" | tostring) else "" end) + "\u0000"
          + (if $t == "object" and (.statusLine | has("enabled")) then (.statusLine.enabled | tostring) else "true" end) + "\u0000"
          + (if $t == "object" and (.statusLine | has("stack_with_default")) then (.statusLine.stack_with_default | tostring) else "false" end) + "\u0000")
      ' "$SETTINGS_FILE" 2>/dev/null
    ); then
      printf '  status:   INVALID JSON\n'
      issues=$((issues + 1))
    elif [ "$sl_type" = "null" ]; then
      printf '  status:   statusLine not configured\n'
      [ -n "$script_tilde" ] && printf '  activate: /statusline %s\n' "$script_tilde"
    elif [ "$sl_type" != "object" ]; then
      printf '  status:   INVALID (statusLine is %s, must be an object)\n' "$sl_type"
      [ -n "$script_tilde" ] && printf '  activate: /statusline %s\n' "$script_tilde"
      issues=$((issues + 1))
    else
      sl_cmd_exp=$(expand_tilde "$sl_cmd")
      if [ -z "$sl_cmd" ]; then
        printf '  status:   statusLine.command is empty\n'
        [ -n "$script_tilde" ] && printf '  activate: /statusline %s\n' "$script_tilde"
      elif [ -n "$script_path" ] && [ "$sl_cmd_exp" = "$script_path" ]; then
        printf '  status:   ACTIVE -> %s\n' "$sl_cmd"
      else
        printf '  status:   OTHER COMMAND -> %s\n' "$sl_cmd"
        [ -n "$script_tilde" ] && printf '  activate: /statusline %s\n' "$script_tilde"
      fi
      if [ "$sl_enabled" = "false" ]; then
        printf '  warning:  statusLine.enabled is false (run /statusline enable)\n'
        issues=$((issues + 1))
      fi
      if [ "$sl_stack" = "true" ]; then
        printf '  warning:  statusLine.stack_with_default is true (stacks below built-in bar)\n'
      fi
    fi
  fi

  printf '\n=== HUD Config (%s) ===\n' "$(to_tilde_path "$CONFIG_FILE")"
  if [ ! -e "$CONFIG_FILE" ]; then
    printf '  file:     not present (using defaults)\n'
  elif [ ! -r "$CONFIG_FILE" ]; then
    printf '  file:     unreadable\n'
    issues=$((issues + 1))
  elif [ "$has_jq" -eq 0 ]; then
    printf '  file:     exists (install jq to validate)\n'
  else
    local warnings=""
    if ! warnings=$(jq -r --argjson defaults "$CONFIG_DEFAULTS" --argjson presets "$VALID_PRESETS" '
      if type != "object" then error("not object") else . end
      | to_entries[]
      | .key as $k | .value as $v
      | if ($defaults | has($k) | not) then
          "unknown key \"\($k)\" (ignored)"
        elif $k == "preset" then
          if ($v | type) == "string" and (($presets | index($v)) != null) then empty
          else "invalid preset \($v | tojson) (expected standard|compact|minimal)" end
        else
          if ($v | type) == "boolean" then empty
          else "invalid type for \"\($k)\": \($v | tojson) (expected boolean)" end
        end
    ' "$CONFIG_FILE" 2>/dev/null); then
      printf '  file:     INVALID JSON (runtime falls back to defaults; fix or run reset)\n'
      issues=$((issues + 1))
    elif [ -n "$warnings" ]; then
      printf '  file:     valid JSON with warnings:\n'
      while IFS= read -r w; do
        printf '  warning:  %s\n' "$w"
      done <<< "$warnings"
      issues=$((issues + 1))
    else
      printf '  file:     OK (valid)\n'
    fi
  fi

  printf '\n=== Effective Config ===\n'
  print_effective_config

  printf '\n=== Smoke Check ===\n'
  if [ -n "$script_path" ] && [ -x "$script_path" ]; then
    local smoke_out=""
    if smoke_out=$(printf '{}' | "$script_path" 2>&1) && [ -n "$smoke_out" ]; then
      printf '  smoke:    OK (exit 0, output non-empty)\n'
    else
      printf '  smoke:    FAILED\n'
      issues=$((issues + 1))
    fi
  else
    printf '  smoke:    SKIPPED (script missing or not executable)\n'
  fi

  printf '\n=== Summary ===\n'
  if [ "$issues" -eq 0 ]; then
    printf '  health:   OK (0 issues)\n'
  else
    printf '  health:   %d issue(s) found\n' "$issues"
  fi
}

cmd_config() {
  printf 'Config file: %s\n' "$(to_tilde_path "$CONFIG_FILE")"
  print_effective_config
}

cmd_preview() {
  local width="${1:-120}" script_path payload
  if ! [[ "$width" =~ ^[0-9]+$ ]] || [ "$width" -lt 20 ]; then
    printf 'Error: width must be an integer >= 20\n' >&2
    exit 1
  fi
  script_path=$(resolve_statusline_script) || {
    printf 'Error: statusline.sh not found\n' >&2
    exit 1
  }
  if [ ! -x "$script_path" ]; then
    printf 'Error: %s is not executable (run chmod +x)\n' "$(to_tilde_path "$script_path")" >&2
    exit 1
  fi
  if command -v jq >/dev/null 2>&1; then
    payload=$(printf '%s' "$PREVIEW_PAYLOAD" | jq -c --argjson w "$width" '.terminal_width = $w')
  else
    payload="$PREVIEW_PAYLOAD"
  fi
  printf '%s' "$payload" | "$script_path" | awk '{gsub(/\033\[[0-9;]*m/, "")}1'
}

cmd_set() {
  require_jq
  if [ "$#" -lt 1 ]; then
    printf 'Usage: hud.sh set <key>=<value> [<key>=<value> ...]\n' >&2
    exit 1
  fi

  local cur updated
  cur=$(read_json_object_or_fail "$CONFIG_FILE" '. Fix it or run "hud.sh reset" first.')
  updated=$(printf '%s' "$cur" | jq \
    --argjson defaults "$CONFIG_DEFAULTS" \
    --argjson presets "$VALID_PRESETS" '
    reduce $ARGS.positional[] as $pair (
      .;
      ($pair | index("=")) as $eq
      | if $eq == null then error("invalid assignment \"\($pair)\" (expected key=value)") else . end
      | ($pair[0:$eq]) as $k
      | ($pair[$eq+1:]) as $v
      | if ($defaults | has($k) | not) then error("unknown config key \"\($k)\"")
        elif $k == "preset" then
          if ($presets | index($v)) != null then .preset = $v
          else error("invalid preset \"\($v)\" (expected: standard, compact, or minimal)") end
        elif ($v == "true" or $v == "on" or $v == "1") then .[$k] = true
        elif ($v == "false" or $v == "off" or $v == "0") then .[$k] = false
        else error("invalid boolean \"\($v)\" for \($k) (expected: true or false)") end
    )
  ' --args "$@") || exit 1

  atomic_write_file "$CONFIG_FILE" "$updated"
  printf 'Updated %s\n' "$(to_tilde_path "$CONFIG_FILE")"
  print_effective_config
}

cmd_toggle() {
  require_jq
  if [ "$#" -lt 1 ]; then
    printf 'Usage: hud.sh toggle <boolKey> [<boolKey> ...]\n' >&2
    exit 1
  fi

  local cur updated
  cur=$(read_json_object_or_fail "$CONFIG_FILE" '. Fix it or run "hud.sh reset" first.')
  updated=$(printf '%s' "$cur" | jq \
    --argjson defaults "$CONFIG_DEFAULTS" '
    reduce $ARGS.positional[] as $k (
      .;
      if ($defaults | has($k) | not) or (($defaults[$k] | type) != "boolean") then
        error("\"\($k)\" is not a boolean toggle key")
      else
        .[$k] = ((if (.[$k] | type) == "boolean" then .[$k] else $defaults[$k] end) | not)
      end
    )
  ' --args "$@") || exit 1

  atomic_write_file "$CONFIG_FILE" "$updated"
  printf 'Updated %s\n' "$(to_tilde_path "$CONFIG_FILE")"
  print_effective_config
}

cmd_reset() {
  if [ -e "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    printf 'Removed %s (restored defaults)\n' "$(to_tilde_path "$CONFIG_FILE")"
  else
    printf 'Already using defaults (%s not found)\n' "$(to_tilde_path "$CONFIG_FILE")"
  fi
  print_effective_config
}

cmd_apply_settings() {
  require_jq
  local script_path script_tilde cur updated
  script_path=$(resolve_statusline_script) || {
    printf 'Error: statusline.sh not found\n' >&2
    exit 1
  }
  script_tilde=$(to_tilde_path "$script_path")
  cur=$(read_json_object_or_fail "$SETTINGS_FILE" '; refusing to overwrite')

  updated=$(printf '%s' "$cur" | jq --arg cmd "$script_tilde" '
    .statusLine = (
      (if (.statusLine | type) == "object" then .statusLine else {} end)
      + {type: "command", command: $cmd, enabled: true}
    )
  ')

  atomic_write_file "$SETTINGS_FILE" "$updated" 600
  printf 'Updated %s -> statusLine.command = %s\n' "$(to_tilde_path "$SETTINGS_FILE")" "$script_tilde"
}

case "${1:-help}" in
  doctor)         shift; cmd_doctor "$@" ;;
  config)         shift; cmd_config "$@" ;;
  preview)        shift; cmd_preview "$@" ;;
  set)            shift; cmd_set "$@" ;;
  toggle)         shift; cmd_toggle "$@" ;;
  reset)          shift; cmd_reset "$@" ;;
  apply-settings) shift; cmd_apply_settings "$@" ;;
  *)
    cat <<'EOF'
Usage: hud.sh <command> [args...]

Commands:
  doctor                  Check jq, script permissions, settings.json, config.json, and smoke test
  config                  Show current effective configuration
  preview [width]         Render plain-text HUD preview (default width: 120)
  set <k>=<v> [...]       Validate and atomically update ~/.config/statusline-hud/config.json
  toggle <key> [...]      Flip one or more boolean config keys and save atomically
  reset                   Remove user config.json and restore defaults
  apply-settings          Atomically write statusLine into ~/.gemini/antigravity-cli/settings.json (0600)
EOF
    ;;
esac
