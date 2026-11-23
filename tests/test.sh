#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUSLINE="${ROOT_DIR}/scripts/statusline.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export XDG_CACHE_HOME="${TMP_DIR}/cache"
export XDG_CONFIG_HOME="${TMP_DIR}/empty-config"

PASS=0
FAIL=0

strip_ansi() {
  local s="$1" clean="" rest
  while [[ "$s" == *$'\033['* ]]; do
    clean+="${s%%$'\033['*}"
    rest="${s#*$'\033['}"
    s="${rest#*m}"
  done
  printf '%s' "${clean}${s}"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

pass() {
  PASS=$((PASS + 1))
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass
  else
    fail "$name: expected to contain '$needle', got: $haystack"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass
  else
    fail "$name: expected NOT to contain '$needle', got: $haystack"
  fi
}

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass
  else
    fail "$name: expected '$expected', got '$actual'"
  fi
}

# 1. Syntax & executable bit check
bash -n "$STATUSLINE" && pass || fail "bash -n syntax check"
[ -x "$STATUSLINE" ] && pass || fail "scripts/statusline.sh executable bit"

# Build a synthetic transcript with a non-planner row whose content contains "PLANNER_RESPONSE"
NOW_S=$(date +%s)
START_ISO=$(date -u -d "@$((NOW_S - 900))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -r "$((NOW_S - 900))" '+%Y-%m-%dT%H:%M:%SZ')
SYN_TRANS="${TMP_DIR}/transcript.jsonl"
cat > "$SYN_TRANS" <<EOF
{"step_index":0,"type":"USER_INPUT","created_at":"${START_ISO}","content":"hello"}
{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"${START_ISO}","input_tokens":10000,"cache_read_tokens":90000,"output_tokens":5000}
{"step_index":2,"type":"GENERIC","created_at":"${START_ISO}","content":"mentions PLANNER_RESPONSE inside tool output"}
EOF

# 2. Default wide working session (showTitle=false, known sandbox state -> 3 lines)
OUT=$(printf '%s' "{
  \"cwd\":\"/tmp\",
  \"conversation_id\":\"test-conv-1\",
  \"conversation_title\":\"Refactor statusline layout\",
  \"transcript_path\":\"${SYN_TRANS}\",
  \"agent_state\":\"working\",
  \"cycle_mode\":\"plan\",
  \"model\":{\"display_name\":\"Gemini 4 Neon (XHigh)\"},
  \"context_window\":{\"used_percentage\":14.24,\"total_input_tokens\":500,\"total_output_tokens\":100},
  \"quota\":{
    \"gemini-5h\":{\"remaining_fraction\":0.82,\"reset_in_seconds\":3600},
    \"gemini-weekly\":{\"remaining_fraction\":0.93,\"reset_in_seconds\":560580}
  },
  \"artifact_count\":2,
  \"subagents\":[{\"name\":\"a\",\"status\":\"running\"},{\"name\":\"b\",\"status\":\"completed\"}],
  \"task_count\":1,
  \"sandbox\":{\"enabled\":false},
  \"cost\":{\"total_usd\":0.4213,\"estimated\":true},
  \"terminal_width\":120
}" | "$STATUSLINE")
PLAIN=$(strip_ansi "$OUT")
assert_eq "default wide line count" "$(printf '%s\n' "$PLAIN" | wc -l | tr -d ' ')" "3"
assert_not_contains "title hidden by default" "$PLAIN" "Refactor statusline layout"
assert_contains "sandbox OFF shown by default" "$PLAIN" "sandbox OFF"
assert_contains "wide mode" "$PLAIN" "PLAN"
assert_contains "wide subagents" "$PLAIN" "subagents 1/2"
assert_contains "wide artifacts" "$PLAIN" "artifacts 2"
assert_contains "wide tasks" "$PLAIN" "tasks 1"
assert_contains "wide transcript tokens" "$PLAIN" "token 105k (100k↑ 5k↓)"
assert_contains "wide transcript cache 1dp" "$PLAIN" "cache 90.0%"
assert_contains "wide transcript duration" "$PLAIN" "15m"
assert_contains "wide cost" "$PLAIN" '~$0.42'

# The transcript cache must also distinguish no reported usage from a reported zero.
for usage in '{}' '{"type":"PLANNER_RESPONSE","input_tokens":0,"output_tokens":0}'; do
  printf '%s\n' "$usage" > "$TMP_DIR/zero.jsonl"
  for run in 1 2; do
    OUT=$("$STATUSLINE" <<< "{\"cwd\":\"/tmp\",\"conversation_id\":\"zero\",\"transcript_path\":\"$TMP_DIR/zero.jsonl\"}")
    if [ "$usage" = '{}' ]; then assert_not_contains "unknown transcript usage ($run)" "$OUT" "token "
    else assert_contains "zero transcript usage ($run)" "$(strip_ansi "$OUT")" "token 0"; fi
  done
done

# 3. Confirm pending + queued + Vim + 2 quotas @ 110 cols
OUT=$(printf '%s' '{
  "cwd":"/tmp",
  "agent_state":"tool_use",
  "tool_confirmation_pending":true,
  "pending_input_count":2,
  "cycle_mode":"accept-edits",
  "vim":{"mode":"NORMAL"},
  "model":{"display_name":"Gemini 4 Neon (XHigh)"},
  "context_window":{
    "used_percentage":24.5,
    "total_input_tokens":120000,
    "total_output_tokens":30000,
    "current_usage":{"input_tokens":30000,"cache_read_input_tokens":90000,"cache_creation_input_tokens":0}
  },
  "quota":{
    "gemini-5h":{"remaining_fraction":0.82,"reset_in_seconds":3600},
    "gemini-weekly":{"remaining_fraction":0.93,"reset_in_seconds":560580},
    "3p-5h":{"remaining_fraction":0.70,"reset_in_seconds":7200},
    "3p-weekly":{"remaining_fraction":0.85,"reset_in_seconds":400000}
  },
  "subagents":[{"name":"a","status":"completed"},{"name":"b","status":"completed"}],
  "sandbox":{"enabled":true},
  "cost":{"total_usd":1.25,"estimated":false},
  "terminal_width":110
}' | "$STATUSLINE")
PLAIN=$(strip_ansi "$OUT")
assert_eq "confirm session 3 lines" "$(printf '%s\n' "$PLAIN" | wc -l | tr -d ' ')" "3"
assert_contains "confirm state" "$PLAIN" "⚠ CONFIRM (+2)"
assert_contains "mode + vim" "$PLAIN" "EDITS [N]"
assert_contains "current_usage cache fallback 1dp" "$PLAIN" "cache 75.0%"
assert_contains "subagents 0/2" "$PLAIN" "subagents 0/2"
assert_contains "sandbox ON" "$PLAIN" "sandbox ON"
assert_not_contains "absent artifacts hidden" "$PLAIN" "artifacts"
assert_not_contains "absent tasks hidden" "$PLAIN" "tasks"
LINE2=$(printf '%s\n' "$PLAIN" | sed -n '2p')
assert_contains "wide quotas retain bars" "$LINE2" "█"

# 4. Fresh session collapses to 1 line on BOTH narrow (85) and wide (120) screens
for cols in 85 120; do
  OUT=$(printf '{"cwd":"/tmp","agent_state":"idle","model":{"display_name":"Gemini 4"},"terminal_width":%d}' "$cols" | "$STATUSLINE")
  PLAIN=$(strip_ansi "$OUT")
  assert_eq "fresh ${cols} collapses to 1 line" "$(printf '%s\n' "$PLAIN" | wc -l | tr -d ' ')" "1"
  assert_not_contains "fresh ${cols} omits unknown sandbox" "$PLAIN" "sandbox"
done

# 5. Partial / disabled / remaining_amount quota + reviewing + auto + model.id fallback
OUT=$(printf '%s' '{
  "cwd":"/tmp",
  "agent_state":"reviewing",
  "cycle_mode":"auto",
  "model":{"id":"gemini-4-custom"},
  "quota":{
    "gemini-5h":{"remaining_fraction":0.5,"disabled":true},
    "gemini-weekly":{"remaining_fraction":0.9378,"reset_in_seconds":560580},
    "3p-5h":{"remaining_amount":42,"reset_in_seconds":1800}
  },
  "terminal_width":120
}' | "$STATUSLINE")
PLAIN=$(strip_ansi "$OUT")
assert_contains "reviewing state" "$PLAIN" "◈ REVIEW"
assert_contains "auto mode" "$PLAIN" "AUTO"
assert_contains "model id fallback" "$PLAIN" "gemini-4-custom"
assert_contains "weekly only" "$PLAIN" "Gemini week"
assert_not_contains "disabled 5h hidden" "$PLAIN" "Gemini 5h"
assert_contains "remaining_amount has left label" "$PLAIN" "3P 5h 42 left"

# 6. Split panes keep the selected work and activity components.
OUT=$(printf '%s' '{
  "cwd":"/home/user/projects/my-very-long-project-name",
  "agent_state":"working",
  "cycle_mode":"auto",
  "model":{"display_name":"Gemini 4 Neon (XHigh)"},
  "vcs":{"type":"git","branch":"feature/long-branch-name","dirty":true},
  "context_window":{"used_percentage":25.0,"total_input_tokens":50000,"total_output_tokens":5000},
  "artifact_count":2,
  "task_count":1,
  "terminal_width":88
}' | "$STATUSLINE")
PLAIN=$(strip_ansi "$OUT")
assert_contains "split 88 preserves AUTO mode" "$PLAIN" "AUTO"
assert_contains "split 88 keeps running tasks" "$PLAIN" "tasks 1"
assert_contains "split 88 keeps artifacts" "$PLAIN" "artifacts 2"

# 7. Explicit zero is still data; an absent field is not.
OUT=$("$STATUSLINE" <<< '{"cwd":"/tmp","artifact_count":0,"subagents":[],"task_count":0,"cost":{"total_usd":0},"context_window":{"used_percentage":0,"total_input_tokens":0,"total_output_tokens":0},"terminal_width":100}')
PLAIN=$(strip_ansi "$OUT")
assert_contains "known zero metrics" "$PLAIN" 'artifacts 0 │ subagents 0/0 │ tasks 0 │ token 0 (0↑ 0↓) │ $0.00'
assert_contains "known zero context" "$PLAIN" '0.0%'
OUT=$("$STATUSLINE" <<< '{"cwd":"/tmp","terminal_width":120}')
assert_eq "absent metrics do not create rows" "$(strip_ansi "$OUT")" '  ● READY │ /tmp'

# 8. The same component list is used at both widths, even when it overflows.
CFG_TITLE="${TMP_DIR}/cfg-title"
mkdir -p "${CFG_TITLE}/statusline-hud"
printf '{"showTitle":true}\n' > "${CFG_TITLE}/statusline-hud/config.json"
OUT=$(XDG_CONFIG_HOME="$CFG_TITLE" "$STATUSLINE" <<< '{"cwd":"/项目/很长的项目名","conversation_title":"✨ 修复标题","task_count":1,"terminal_width":20,"model":{"display_name":"Gemini 4 Neon (XHigh)"},"vcs":{"branch":"feature/很长的分支名"}}')
PLAIN=$(strip_ansi "$OUT")
assert_eq "no pruning, no separate title row" "$PLAIN" $'  ● READY │ Gemini 4 Neon │ …/很长的项目名 │ feature/很长的分支名\n  tasks 1 │ ▸ ✨ 修复标题'

# 9. LC_ALL=C locale safety (no broken UTF-8 bar bytes, still shows bar on wide screen)
OUT=$(LC_ALL=C "$STATUSLINE" <<< '{
  "cwd":"/tmp",
  "agent_state":"working",
  "context_window":{"used_percentage":35},
  "terminal_width":120
}')
PLAIN=$(strip_ansi "$OUT")
assert_contains "LC_ALL=C renders valid progress bar" "$PLAIN" "████░░░░░░ 35.0%"
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$OUT" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' && pass || fail "LC_ALL=C valid UTF-8 output"
fi

# 10. Trailing slash HOME & root CWD (Bash 3.2 empty-array safety)
OUT=$(printf '{"cwd":"%s/","agent_state":"idle","terminal_width":80}' "$HOME" | "$STATUSLINE")
assert_contains "trailing slash HOME renders ~" "$(strip_ansi "$OUT")" "│ ~"
OUT=$(printf '{"cwd":"///","agent_state":"idle","terminal_width":80}' | "$STATUSLINE")
assert_contains "multiple slashes renders /" "$(strip_ansi "$OUT")" "│ /"

# 11. Independent switches, explicit false and inheritance on both sides of the breakpoint.
CFG_CUSTOM="${TMP_DIR}/cfg-custom"
mkdir -p "$CFG_CUSTOM/statusline-hud"
printf '%s\n' '{"showMode":false,"showGeminiQuota":false,"showTasks":false,"showTitle":true,"showSandbox":false,"narrow":{"showGeminiQuota":true,"show3pQuota":false,"showTasks":true,"showArtifacts":false,"showTitle":false,"showSandbox":true}}' > "$CFG_CUSTOM/statusline-hud/config.json"
for cols in 99 100; do
  OUT=$(XDG_CONFIG_HOME="$CFG_CUSTOM" "$STATUSLINE" <<< "{
    \"cwd\":\"/tmp\",\"cycle_mode\":\"plan\",\"terminal_width\":$cols,\"conversation_title\":\"My title\",
    \"quota\":{\"gemini-5h\":{\"remaining_fraction\":0.5},\"3p-5h\":{\"remaining_amount\":42}},
    \"task_count\":2,\"artifact_count\":1,\"subagents\":[],\"sandbox\":{\"enabled\":false}
  }")
  PLAIN=$(strip_ansi "$OUT")
  if [ "$cols" -eq 99 ]; then
    assert_eq "narrow delta both directions, stable order" "$PLAIN" $'  ● READY │ /tmp\n  Gemini 5h 50.0%\n  subagents 0/0 │ tasks 2 │ sandbox OFF'
  else
    assert_eq "ordinary switches at 100 cols" "$PLAIN" $'  ● READY │ /tmp\n  3P 5h 42 left\n  artifacts 1 │ subagents 0/0 │ ▸ My title'
  fi
done

# 12. Empty narrow inherits all ordinary flags; an empty quota row has no placeholder.
for cfg in '{"showModel":false,"showPath":false,"showTitle":true}' '{"showModel":false,"showPath":false,"showTitle":true,"narrow":{}}'; do
  printf '%s\n' "$cfg" > "$CFG_CUSTOM/statusline-hud/config.json"
  OUT=$(XDG_CONFIG_HOME="$CFG_CUSTOM" "$STATUSLINE" <<< '{"cwd":"/tmp","model":{"id":"hidden"},"conversation_title":"Only title","terminal_width":80}')
  assert_eq "ordinary switches inherited without extra separators" "$(strip_ansi "$OUT")" $'  ● READY\n  ▸ Only title'
done

# 13. Real git repository status parsing (wide counts, narrow branch-only, detached HEAD)
if command -v git >/dev/null 2>&1; then
  GIT_REPO="${TMP_DIR}/git-repo"
  mkdir -p "$GIT_REPO"
  git -C "$GIT_REPO" init -q -b main
  git -C "$GIT_REPO" config user.email "test@example.com"
  git -C "$GIT_REPO" config user.name "Test"
  printf 'a\n' > "$GIT_REPO/a.txt"
  printf 'b\n' > "$GIT_REPO/b.txt"
  git -C "$GIT_REPO" add a.txt b.txt && git -C "$GIT_REPO" commit -q -m "init"
  printf 'a2\n' > "$GIT_REPO/a.txt"
  rm "$GIT_REPO/b.txt"
  printf 'c\n' > "$GIT_REPO/c.txt"
  git -C "$GIT_REPO" add c.txt
  printf 'u\n' > "$GIT_REPO/u.txt"
  OUT=$(XDG_CACHE_HOME="${TMP_DIR}/git-cache" "$STATUSLINE" <<< "{\"cwd\":\"${GIT_REPO}\",\"terminal_width\":120}")
  assert_contains "git wide shows dirty counts" "$(strip_ansi "$OUT")" "main* !1 +1 ✘1 ?1"
  OUT=$(XDG_CACHE_HOME="${TMP_DIR}/git-cache" "$STATUSLINE" <<< "{\"cwd\":\"${GIT_REPO}\",\"terminal_width\":80}")
  PLAIN=$(strip_ansi "$OUT")
  assert_contains "git narrow shows dirty branch" "$PLAIN" "main*"
  assert_not_contains "git narrow omits counts" "$PLAIN" "!1"
  git -C "$GIT_REPO" checkout -q --detach HEAD
  DETACH_SHA=$(git -C "$GIT_REPO" rev-parse --short=7 HEAD)
  OUT=$(XDG_CACHE_HOME="${TMP_DIR}/git-cache-detach" "$STATUSLINE" <<< "{\"cwd\":\"${GIT_REPO}\",\"terminal_width\":120}")
  assert_contains "git detached HEAD uses short sha" "$(strip_ansi "$OUT")" "${DETACH_SHA}* !1 +1 ✘1 ?1"
fi

# 14. Broken config.json gracefully falls back to defaults without failing
CFG_BAD="${TMP_DIR}/cfg-bad"
mkdir -p "${CFG_BAD}/statusline-hud"
printf '{not valid json,,,' > "${CFG_BAD}/statusline-hud/config.json"
OUT=$(XDG_CONFIG_HOME="$CFG_BAD" "$STATUSLINE" <<< '{
  "cwd":"/tmp",
  "conversation_title":"Hidden by default",
  "agent_state":"working",
  "cycle_mode":"plan",
  "model":{"display_name":"Gemini 4"},
  "terminal_width":120
}')
PLAIN=$(strip_ansi "$OUT")
assert_contains "broken config falls back cleanly" "$PLAIN" "PLAN"
assert_not_contains "broken config uses default showTitle=false" "$PLAIN" "Hidden by default"

# 15. ANSI escape & control character sanitization in untrusted strings
OUT=$(XDG_CONFIG_HOME="$CFG_TITLE" "$STATUSLINE" <<< '{
  "cwd":"/tmp/dir\u001b[31mred",
  "conversation_title":"clean \u001b[31mRED\u001b[0m \u001b]0;pwn\u0007 title",
  "agent_state":"idle",
  "model":{"display_name":"Model\u001b[2JName"},
  "vcs":{"type":"git","branch":"feat/\u001b[31mbad"},
  "terminal_width":120
}')
assert_not_contains "ANSI CSI 2J stripped" "$OUT" $'\033[2J'
assert_not_contains "ANSI CSI 31m stripped" "$OUT" $'\033[31m'
assert_not_contains "ANSI OSC stripped" "$OUT" 'pwn'
PLAIN=$(strip_ansi "$OUT")
assert_contains "clean text preserved after ANSI strip" "$PLAIN" "ModelName"
assert_contains "clean title text preserved" "$PLAIN" "clean RED title"

# 16. Adversarial / malformed stdin inputs must never exit non-zero
for bad in \
  '' \
  'not json' \
  '{"agent_state":"error","context_window":{"used_percentage":"NaN","total_input_tokens":"bad"}}' \
  '{"context_window":{"used_percentage":-5.5}}' \
  '{"context_window":{"used_percentage":150}}' \
  '{"quota":{"gemini-5h":{"remaining_fraction":1.2,"reset_in_seconds":-5}}}' \
  '{"model":null,"subagents":null,"cost":{"total_usd":-3}}'; do
  OUT=$(printf '%s' "$bad" | "$STATUSLINE")
  assert_not_contains "no negative pct" "$OUT" "-5.5%"
  assert_not_contains "no negative quota" "$OUT" "-20.0%"
done

# 17. /hud skill helper script (skills/hud/scripts/hud.sh) end-to-end validation
HUD_CTL="${ROOT_DIR}/skills/hud/scripts/hud.sh"
bash -n "$HUD_CTL" && pass || fail "hud.sh syntax check"
[ -x "$HUD_CTL" ] && pass || fail "hud.sh executable bit"

HUD_CFG_HOME="${TMP_DIR}/hud-ctl-cfg"
HUD_SETTINGS="${TMP_DIR}/hud-settings.json"
DOC_FIRST=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" doctor)
assert_contains "first run explains activation" "$DOC_FIRST" $'Environment ready; HUD not enabled yet\n  activate: /statusline '
assert_contains "default narrow displays inherit" "$DOC_FIRST" "showTitle       = [OFF]  narrow=inherit"
FIRST_PREVIEW=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" preview 80)
assert_contains "narrow preview shows status" "$FIRST_PREVIEW" "WORKING"
assert_not_contains "narrow preview uses short text" "$FIRST_PREVIEW" "█"
[ ! -e "$HUD_CFG_HOME" ] && pass || fail "preview must not create user config"
XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" unset narrow.showCost >/dev/null
[ ! -e "$HUD_CFG_HOME" ] && pass || fail "unset without config must not create user config"
if XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" unset unknownKey >/dev/null 2>&1; then
  fail "unset should reject unknown key without config"
else
  pass
fi

printf '{"model":"Gemini 4","statusLine":{"type":"command","command":"~/old.sh","enabled":false,"stack_with_default":true}}\n' > "$HUD_SETTINGS"

# doctor detects other command, enabled=false, stack_with_default=true, and smoke test passes
DOC_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" doctor)
assert_contains "doctor detects OTHER COMMAND" "$DOC_OUT" "OTHER COMMAND"
assert_contains "doctor detects enabled=false" "$DOC_OUT" "statusLine.enabled is false"
assert_contains "doctor detects stack_with_default" "$DOC_OUT" "stack_with_default is true"
assert_contains "doctor smoke passes" "$DOC_OUT" "smoke:    OK"
assert_contains "doctor lists default showTitle OFF" "$DOC_OUT" "showTitle       = [OFF]"

# A narrow toggle uses its inherited value; writes do not affect the ordinary setting.
SET_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" set showTitle=true showCost=false narrow.showTasks=false)
assert_contains "set updates showTitle" "$SET_OUT" "showTitle       = [ON]"
TOG_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" toggle narrow.showCost showPath)
assert_contains "toggle reports inherited false flipped to true" "$TOG_OUT" 'showCost        = [OFF]  narrow=[ON]'
PREV_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" preview 80)
assert_contains "narrow toggle enables cost" "$PREV_OUT" '~$0.42 │ ▸ Refactor statusline layout'
assert_not_contains "narrow hides tasks" "$PREV_OUT" 'tasks 1'
assert_not_contains "preview strips ANSI" "$PREV_OUT" $'\033['
PREV_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" preview 120)
assert_contains "wide still includes tasks" "$PREV_OUT" 'tasks 1'
assert_not_contains "wide still hides cost" "$PREV_OUT" '~$0.42'
# unset restores narrow inheritance, prunes empty narrow object, and restores ordinary defaults
UNSET_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" unset narrow.showCost)
assert_contains "unset restores narrow inheritance" "$UNSET_OUT" 'showCost        = [OFF]  narrow=inherit'
assert_contains "unset keeps other narrow overrides" "$UNSET_OUT" 'showTasks       = [ON]   narrow=[OFF]'
PREV_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" preview 80)
assert_not_contains "narrow preview inherits hidden cost after unset" "$PREV_OUT" '~$0.42'
XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" unset narrow.showTasks >/dev/null
assert_eq "empty narrow object pruned" "$(jq 'has("narrow")' "${HUD_CFG_HOME}/statusline-hud/config.json")" "false"
XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" set narrow.showCost=true narrow.showTasks=false >/dev/null
UNSET_ALL=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" unset showCost narrow)
assert_contains "unset showCost and narrow restores defaults" "$UNSET_ALL" 'showCost        = [ON]   narrow=inherit'
assert_eq "unset narrow removes narrow key" "$(jq 'has("narrow")' "${HUD_CFG_HOME}/statusline-hud/config.json")" "false"
OUT=$("$STATUSLINE" <<< '{"sandbox":{"enabled":false},"workspace":{"sandbox":{"enabled":true}}}')
assert_contains "top-level false wins over workspace true" "$(strip_ansi "$OUT")" "sandbox OFF"

# invalid key/value rejected without corrupting config.json
if XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" set unknownKey=true >/dev/null 2>&1; then
  fail "set should reject unknown key"
else
  pass
fi
if XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" set preset=invalid >/dev/null 2>&1; then
  fail "set should reject invalid preset"
else
  pass
fi
if XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" set showTitle=maybe >/dev/null 2>&1; then
  fail "set should reject invalid boolean"
else
  pass
fi

# doctor flags unknown keys and wrong types in hand-edited config.json
printf '{"show_title":true,"showCost":"yes","preset":"bad","narrow":{"showTitle":"yes","bogus":true}}\n' > "${HUD_CFG_HOME}/statusline-hud/config.json"
DOC_WARN=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" doctor)
assert_contains "doctor flags unknown key" "$DOC_WARN" 'unknown key "show_title"'
assert_contains "doctor flags wrong bool type" "$DOC_WARN" 'invalid type for "showCost"'
assert_contains "removed presets are unknown" "$DOC_WARN" 'unknown key "preset"'
assert_contains "doctor checks nested types" "$DOC_WARN" 'invalid type for "narrow.showTitle"'
assert_contains "doctor checks nested keys" "$DOC_WARN" 'unknown key "narrow.bogus"'

printf '{"narrow":false}\n' > "${HUD_CFG_HOME}/statusline-hud/config.json"
DOC_WARN=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" doctor)
assert_contains "doctor validates narrow object" "$DOC_WARN" 'invalid type for "narrow"'
DOC_WARN_UNACTIVATED=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$TMP_DIR/no-settings.json" "$HUD_CTL" doctor)
assert_contains "doctor keeps activation hint when config has warnings" "$DOC_WARN_UNACTIVATED" $'issue(s) found; HUD not enabled yet\n  activate: /statusline '

# empty or multi-document config.json flagged consistently by doctor and rejected by set
for bad_cfg in '' '{}{}' '{broken json'; do
  printf '%s' "$bad_cfg" > "${HUD_CFG_HOME}/statusline-hud/config.json"
  DOC_BAD=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" doctor)
  assert_contains "doctor flags invalid config (${bad_cfg:-empty})" "$DOC_BAD" "INVALID JSON"
  if XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" set showTitle=true >/dev/null 2>&1; then
    fail "set should reject invalid config (${bad_cfg:-empty})"
  else
    pass
  fi
done
RST_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" reset)
assert_contains "reset restores defaults" "$RST_OUT" "showTitle       = [OFF]"

# invalid statusLine type emits activate hint only once
printf '{"statusLine":"bad"}\n' > "$TMP_DIR/bad-sl.json"
DOC_BAD_SL=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$TMP_DIR/bad-sl.json" "$HUD_CTL" doctor)
assert_contains "doctor flags non-object statusLine" "$DOC_BAD_SL" "INVALID (statusLine is string"
assert_eq "non-object statusLine prints activate hint once" "$(printf '%s\n' "$DOC_BAD_SL" | grep -c 'activate: /statusline')" "1"

# missing jq skips smoke check instead of reporting smoke OK
NO_JQ_BIN="${TMP_DIR}/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for cmd in bash cat chmod date dirname head mkdir mv rm stat tr awk grep sed; do
  p=$(command -v "$cmd" 2>/dev/null || true)
  [ -n "$p" ] && ln -s "$p" "${NO_JQ_BIN}/${cmd}"
done
DOC_NO_JQ=$(PATH="$NO_JQ_BIN" XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$TMP_DIR/no-settings.json" bash "$HUD_CTL" doctor)
assert_contains "missing jq skips smoke check" "$DOC_NO_JQ" "smoke:    SKIPPED (jq missing)"
assert_contains "missing jq reports 1 issue" "$DOC_NO_JQ" "1 issue(s) found"

# apply-settings preserves unrelated settings, sets command + enabled=true, enforces 0600
APP_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" apply-settings)
assert_contains "apply-settings updates statusLine" "$APP_OUT" "statusLine.command"
assert_eq "apply-settings preserves model" "$(jq -r '.model' "$HUD_SETTINGS")" "Gemini 4"
assert_eq "apply-settings sets enabled true" "$(jq -r '.statusLine.enabled' "$HUD_SETTINGS")" "true"
if [ "$(stat -c '%a' "$HUD_SETTINGS" 2>/dev/null || stat -f '%Lp' "$HUD_SETTINGS" 2>/dev/null)" = "600" ]; then
  pass
else
  fail "apply-settings should enforce 0600 permissions"
fi

DOC_ACTIVE=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" doctor)
assert_contains "active HUD is ready" "$DOC_ACTIVE" "Environment ready; HUD enabled"
assert_not_contains "active HUD needs no activation command" "$DOC_ACTIVE" "activate: /statusline"
jq '.statusLine.enabled = false' "$HUD_SETTINGS" > "$TMP_DIR/disabled.json"
DOC_DISABLED=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$TMP_DIR/disabled.json" "$HUD_CTL" doctor)
assert_contains "disabled HUD has recovery command" "$DOC_DISABLED" "/statusline enable"
assert_contains "disabled HUD summary states disabled" "$DOC_DISABLED" "HUD configured but disabled"
assert_not_contains "disabled HUD is not active" "$DOC_DISABLED" "ACTIVE ->"
assert_not_contains "disabled HUD omits activate command" "$DOC_DISABLED" "activate: /statusline"

printf 'Tests finished: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
