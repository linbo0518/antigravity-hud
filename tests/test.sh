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

assert_max_width() {
  local name="$1" output="$2" max_cols="$3"
  if command -v python3 >/dev/null 2>&1; then
    local bad=""
    bad=$(python3 -c 'import re, sys, unicodedata
max_cols = int(sys.argv[1])
ansi = re.compile(r"\x1b\[[0-9;]*m")
for line in sys.argv[2].splitlines():
    plain = ansi.sub("", line)
    w = 0
    for ch in plain:
        if unicodedata.combining(ch) or ch in ("\u200b", "\u200c", "\u200d", "\u200e", "\u200f"):
            continue
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    if w > max_cols:
        print(f"{w}: {plain}")
        break' "$max_cols" "$output")
    if [ -n "$bad" ]; then
      fail "$name: line width ${bad%%:*} > $max_cols: ${bad#*: }"
    else
      pass
    fi
    return
  fi
  local line plain w
  while IFS= read -r line; do
    plain=$(strip_ansi "$line")
    w=${#plain}
    case "$plain" in *🔧*) w=$((w + 1)) ;; esac
    case "$plain" in *⏳*) w=$((w + 1)) ;; esac
    if [ "$w" -gt "$max_cols" ]; then
      fail "$name: line width $w > $max_cols: $plain"
      return
    fi
  done <<< "$output"
  pass
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

# 2. Default wide working session (showTitle=false, showSandboxOff=false -> 3 lines)
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
assert_not_contains "sandbox off hidden by default" "$PLAIN" "sandbox off"
assert_contains "wide mode" "$PLAIN" "PLAN"
assert_contains "wide subagents" "$PLAIN" "subagents 1/2"
assert_contains "wide artifacts" "$PLAIN" "artifacts 2"
assert_contains "wide tasks" "$PLAIN" "tasks 1"
assert_contains "wide transcript tokens" "$PLAIN" "token 105k (100k↑ 5k↓)"
assert_contains "wide transcript cache 1dp" "$PLAIN" "cache 90.0%"
assert_contains "wide transcript duration" "$PLAIN" "15m"
assert_contains "wide cost" "$PLAIN" '~$0.42'
assert_max_width "wide 120 width" "$OUT" 120

# 3. Confirm pending + queued + Vim + 2 quotas @ 110 cols (3 lines, drops bars and fits <= 110)
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
assert_not_contains "zero artifacts hidden" "$PLAIN" "artifacts"
assert_not_contains "zero tasks hidden" "$PLAIN" "tasks"
LINE2=$(printf '%s\n' "$PLAIN" | sed -n '2p')
assert_not_contains "line2 dropped bars at 110" "$LINE2" "█"
assert_max_width "confirm 110 width" "$OUT" 110

# 4. Fresh session collapses to 1 line on BOTH narrow (85) and wide (120) screens
for cols in 85 120; do
  OUT=$(printf '{"cwd":"/tmp","agent_state":"idle","model":{"display_name":"Gemini 4"},"sandbox":{"enabled":false},"terminal_width":%d}' "$cols" | "$STATUSLINE")
  PLAIN=$(strip_ansi "$OUT")
  assert_eq "fresh ${cols} collapses to 1 line" "$(printf '%s\n' "$PLAIN" | wc -l | tr -d ' ')" "1"
  assert_not_contains "fresh ${cols} hides sandbox off" "$PLAIN" "sandbox off"
  assert_max_width "fresh ${cols} width" "$OUT" "$cols"
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

# 6. 80-99 col split pane keeps running tasks & preserves AUTO mode ahead of model/path truncation
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
assert_contains "split 88 keeps artifacts when room allows" "$PLAIN" "artifacts 2"
assert_max_width "split 88 width" "$OUT" 88

# 7. Strict width stress test across narrow, split, and medium terminals (with showTitle=true)
CFG_TITLE="${TMP_DIR}/cfg-title"
mkdir -p "${CFG_TITLE}/statusline-hud"
printf '{"showTitle":true,"showSandboxOff":true}\n' > "${CFG_TITLE}/statusline-hud/config.json"
for cols in 60 75 80 95 100 110 120; do
  OUT=$(XDG_CONFIG_HOME="$CFG_TITLE" "$STATUSLINE" <<< "{
    \"cwd\":\"/home/user/projects/my-very-long-project-name\",
    \"conversation_title\":\"✨ 修复 ✅ bug ⚡ 重构状态栏并排查窄屏折行以及跨平台兼容性问题 Refactor HUD\",
    \"agent_state\":\"tool_use\",
    \"tool_confirmation_pending\":true,
    \"pending_input_count\":2,
    \"cycle_mode\":\"accept-edits\",
    \"vim\":{\"mode\":\"VISUAL LINE\"},
    \"model\":{\"display_name\":\"Gemini 4 Neon (XHigh)\"},
    \"vcs\":{\"type\":\"git\",\"branch\":\"feature/refactor-statusline-layout\",\"dirty\":true},
    \"context_window\":{\"used_percentage\":42.5,\"total_input_tokens\":4500000,\"total_output_tokens\":122000,\"current_usage\":{\"input_tokens\":5000,\"cache_read_input_tokens\":95000,\"cache_creation_input_tokens\":0}},
    \"quota\":{
      \"gemini-5h\":{\"remaining_fraction\":0.82,\"reset_in_seconds\":3600},
      \"gemini-weekly\":{\"remaining_fraction\":0.93,\"reset_in_seconds\":560580},
      \"3p-5h\":{\"remaining_fraction\":0.70,\"reset_in_seconds\":7200},
      \"3p-weekly\":{\"remaining_fraction\":0.85,\"reset_in_seconds\":400000}
    },
    \"artifact_count\":3,
    \"subagents\":[{\"name\":\"a\",\"status\":\"running\"},{\"name\":\"b\",\"status\":\"completed\"}],
    \"task_count\":2,
    \"sandbox\":{\"enabled\":false},
    \"cost\":{\"total_usd\":12.34,\"estimated\":true},
    \"terminal_width\":${cols}
  }")
  assert_max_width "stress width ${cols} (with emoji title)" "$OUT" "$cols"
done

# 8. CJK & Emoji path/branch width accounting
OUT=$(printf '%s' '{
  "cwd":"/home/user/项目目录/我的超级状态栏插件项目",
  "agent_state":"working",
  "cycle_mode":"plan",
  "model":{"display_name":"Gemini 4 Neon (XHigh)"},
  "vcs":{"type":"git","branch":"特性/✨多行状态栏优化分支","dirty":true},
  "context_window":{"used_percentage":15.0},
  "terminal_width":105
}' | "$STATUSLINE")
assert_max_width "CJK & emoji path/branch at 105" "$OUT" 105

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

# 11. Wide compact preset hides ONLY bars while preserving adaptive metrics & git details
CFG_COMPACT="${TMP_DIR}/cfg-compact-only"
mkdir -p "${CFG_COMPACT}/statusline-hud"
printf '{"preset":"compact"}\n' > "${CFG_COMPACT}/statusline-hud/config.json"
OUT=$(XDG_CONFIG_HOME="$CFG_COMPACT" "$STATUSLINE" <<< "{
  \"cwd\":\"${ROOT_DIR}\",
  \"agent_state\":\"working\",
  \"cycle_mode\":\"plan\",
  \"model\":{\"display_name\":\"Gemini 4 Neon (XHigh)\"},
  \"quota\":{\"gemini-5h\":{\"remaining_fraction\":0.8,\"reset_in_seconds\":3600}},
  \"context_window\":{\"used_percentage\":20,\"total_input_tokens\":50000,\"total_output_tokens\":10000},
  \"artifact_count\":2,
  \"subagents\":[{\"name\":\"a\",\"status\":\"completed\"}],
  \"task_count\":1,
  \"cost\":{\"total_usd\":2.5},
  \"terminal_width\":160
}")
PLAIN=$(strip_ansi "$OUT")
assert_not_contains "wide compact hides bars" "$PLAIN" "█"
assert_contains "wide compact keeps artifacts" "$PLAIN" "artifacts 2"
assert_contains "wide compact keeps tasks" "$PLAIN" "tasks 1"
assert_contains "wide compact keeps subagents" "$PLAIN" "subagents 0/1"
assert_contains "wide compact keeps token breakdown" "$PLAIN" "token 60k (50k↑ 10k↓)"

# 12. Full JSON module toggles (showTitle, showPath, showActivity, showSandboxOff, showMode, show3pQuota, showCost)
CFG_CUSTOM="${TMP_DIR}/cfg-custom"
mkdir -p "${CFG_CUSTOM}/statusline-hud"
cat > "${CFG_CUSTOM}/statusline-hud/config.json" <<'EOF'
{
  "preset": "standard",
  "showTitle": true,
  "showMode": false,
  "showPath": false,
  "show3pQuota": false,
  "showActivity": false,
  "showSandboxOff": true,
  "showCost": false
}
EOF
OUT=$(XDG_CONFIG_HOME="$CFG_CUSTOM" "$STATUSLINE" <<< '{
  "cwd":"/tmp/secret-project",
  "conversation_title":"Visible title",
  "agent_state":"working",
  "cycle_mode":"plan",
  "model":{"display_name":"Gemini 4"},
  "quota":{
    "gemini-5h":{"remaining_fraction":0.8,"reset_in_seconds":3600},
    "3p-5h":{"remaining_fraction":0.7,"reset_in_seconds":3600}
  },
  "artifact_count":2,
  "subagents":[{"name":"a","status":"running"}],
  "task_count":1,
  "context_window":{"used_percentage":20,"total_input_tokens":5000,"total_output_tokens":1000},
  "sandbox":{"enabled":false},
  "cost":{"total_usd":2.5},
  "terminal_width":140
}')
PLAIN=$(strip_ansi "$OUT")
assert_contains "showTitle=true shows title" "$(printf '%s\n' "$PLAIN" | sed -n '1p')" "▸ Visible title"
assert_not_contains "showMode=false hides PLAN" "$PLAIN" "PLAN"
assert_not_contains "showPath=false hides cwd" "$PLAIN" "secret-project"
assert_not_contains "show3pQuota=false hides 3P" "$PLAIN" "3P"
assert_not_contains "showActivity=false hides artifacts" "$PLAIN" "artifacts"
assert_not_contains "showActivity=false hides subagents" "$PLAIN" "subagents"
assert_not_contains "showActivity=false hides tasks" "$PLAIN" "tasks"
assert_contains "showSandboxOff=true shows sandbox off" "$PLAIN" "sandbox off"
assert_not_contains "showCost=false hides cost" "$PLAIN" '$2.50'

# 13. Minimal preset via config.json (must stay 1 line even when showTitle=true)
CFG_MIN="${TMP_DIR}/cfg-min"
mkdir -p "${CFG_MIN}/statusline-hud"
printf '{"preset":"minimal","showTitle":true}\n' > "${CFG_MIN}/statusline-hud/config.json"
OUT=$(XDG_CONFIG_HOME="$CFG_MIN" "$STATUSLINE" <<< '{
  "cwd":"/tmp",
  "conversation_title":"Should hide in minimal",
  "agent_state":"idle",
  "model":{"display_name":"Gemini 4"},
  "quota":{"gemini-5h":{"remaining_fraction":0.5,"reset_in_seconds":3600}},
  "context_window":{"total_input_tokens":5000,"total_output_tokens":1000},
  "terminal_width":140
}')
assert_eq "minimal preset 1 line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
assert_not_contains "minimal hides title" "$(strip_ansi "$OUT")" "Should hide in minimal"

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
printf '{"model":"Gemini 4","statusLine":{"type":"command","command":"~/old.sh","enabled":false,"stack_with_default":true}}\n' > "$HUD_SETTINGS"

# doctor detects other command, enabled=false, stack_with_default=true, and smoke test passes
DOC_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" doctor)
assert_contains "doctor detects OTHER COMMAND" "$DOC_OUT" "OTHER COMMAND"
assert_contains "doctor detects enabled=false" "$DOC_OUT" "statusLine.enabled is false"
assert_contains "doctor detects stack_with_default" "$DOC_OUT" "stack_with_default is true"
assert_contains "doctor smoke passes" "$DOC_OUT" "smoke:    OK"
assert_contains "doctor lists default showTitle OFF" "$DOC_OUT" "showTitle       = [OFF]"

# set validates and writes config atomically; preview reflects changes cleanly (no ANSI)
SET_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" set preset=compact showTitle=true showCost=false)
assert_contains "set updates preset" "$SET_OUT" "preset          = compact"
assert_contains "set updates showTitle ON" "$SET_OUT" "showTitle       = [ON]"
assert_contains "set updates showCost OFF" "$SET_OUT" "showCost        = [OFF]"
PREV_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" preview 120)
assert_not_contains "preview strips ANSI" "$PREV_OUT" $'\033['
assert_contains "preview reflects showTitle=true" "$PREV_OUT" "▸ Refactor statusline layout"
assert_not_contains "preview reflects compact no bars" "$PREV_OUT" "█"
assert_not_contains "preview reflects showCost=false" "$PREV_OUT" '$0.42'

# toggle flips boolean keys without touching other settings
TOG_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" toggle showTitle showPath)
assert_contains "toggle flips showTitle OFF" "$TOG_OUT" "showTitle       = [OFF]"
assert_contains "toggle flips showPath OFF" "$TOG_OUT" "showPath        = [OFF]"
assert_contains "toggle keeps showCost OFF" "$TOG_OUT" "showCost        = [OFF]"
assert_contains "toggle keeps preset compact" "$TOG_OUT" "preset          = compact"

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
printf '{"show_title":true,"showCost":"yes","preset":"bad"}\n' > "${HUD_CFG_HOME}/statusline-hud/config.json"
DOC_WARN=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" HUD_SETTINGS_FILE="$HUD_SETTINGS" "$HUD_CTL" doctor)
assert_contains "doctor flags unknown key" "$DOC_WARN" 'unknown key "show_title"'
assert_contains "doctor flags wrong bool type" "$DOC_WARN" 'invalid type for "showCost"'
assert_contains "doctor flags invalid preset" "$DOC_WARN" 'invalid preset "bad"'

# corrupted config.json refuses silent overwrite on set, recoverable via reset
printf '{broken json' > "${HUD_CFG_HOME}/statusline-hud/config.json"
if XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" set showTitle=true >/dev/null 2>&1; then
  fail "set should refuse overwriting invalid JSON"
else
  pass
fi
RST_OUT=$(XDG_CONFIG_HOME="$HUD_CFG_HOME" "$HUD_CTL" reset)
assert_contains "reset restores defaults" "$RST_OUT" "showTitle       = [OFF]"

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

printf 'Tests finished: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
