#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUSLINE="${ROOT_DIR}/scripts/statusline.sh"

TMP_DIR="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT

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

iso_at() {
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

touch_at() {
  local stamp
  stamp=$(date -u -d "@$1" '+%Y%m%d%H%M.%S' 2>/dev/null \
    || date -u -r "$1" '+%Y%m%d%H%M.%S')
  TZ=UTC touch -t "$stamp" "$2"
}

# Build a synthetic transcript with a non-planner row whose content contains "PLANNER_RESPONSE"
NOW_S=$(date +%s)
START_ISO=$(iso_at "$((NOW_S - 900))")
SYN_TRANS="${TMP_DIR}/transcript.jsonl"
cat > "$SYN_TRANS" <<EOF
{"step_index":0,"type":"USER_INPUT","created_at":"${START_ISO}","content":"hello"}
{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"${START_ISO}","input_tokens":10000,"cache_read_tokens":90000,"output_tokens":5000,"tool_calls":[{"name":"run"}]}
{"step_index":2,"type":"GENERIC","created_at":"${START_ISO}","content":"mentions PLANNER_RESPONSE inside tool output"}
EOF
touch_at "$NOW_S" "$SYN_TRANS"

# Wide working session with transcript usage and conflicting sandbox reports.
OUT=$("$STATUSLINE" <<EOF
{
  "cwd":"/tmp", "terminal_width":120, "agent_state":"working", "cycle_mode":"plan",
  "conversation_id":"test-conv-1", "transcript_path":"${SYN_TRANS}",
  "context_window":{"total_input_tokens":500,"total_output_tokens":100},
  "quota":{"gemini-5h":{"remaining_fraction":0.82}},
  "subagents":[{"status":"running"},{"status":"completed"}],
  "sandbox":{"enabled":false}, "workspace":{"sandbox":{"enabled":true}},
  "cost":{"total_usd":0.4213,"estimated":true}
}
EOF
)
PLAIN=$(strip_ansi "$OUT")
assert_eq "default wide line count" "$(printf '%s\n' "$PLAIN" | wc -l | tr -d ' ')" "3"
assert_contains "top-level false wins over workspace true" "$PLAIN" "sandbox OFF"
assert_contains "wide mode" "$PLAIN" "PLAN"
assert_contains "wide subagents" "$PLAIN" "subagents 1/2"
assert_contains "wide transcript tokens" "$PLAIN" "tok 105k (100k↑ 5k↓)"
assert_contains "wide transcript token speed" "$PLAIN" "6 tok/s"
assert_contains "wide transcript cache 1dp" "$PLAIN" "cache 90.0%"
assert_contains "wide transcript duration" "$PLAIN" "15m"
assert_contains "wide cost" "$PLAIN" '~$0.42'

# Turn speed: skips prior turns & CHECKPOINT gap, handles "USER_INPUT" text in planner content, works without conversation_id.
TURN_TRANS="${TMP_DIR}/turn-speed.jsonl"
cat > "$TURN_TRANS" <<EOF
{"step_index":0,"type":"USER_INPUT","created_at":"$(iso_at $((NOW_S - 900)))","content":"old turn"}
{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"$(iso_at $((NOW_S - 900)))","input_tokens":1000,"cache_read_tokens":0,"output_tokens":1000}
{"step_index":2,"type":"USER_INPUT","created_at":"$(iso_at $((NOW_S - 100)))","content":"current turn"}
{"step_index":3,"type":"CHECKPOINT","created_at":"$(iso_at $((NOW_S - 100)))"}
{"step_index":4,"type":"PLANNER_RESPONSE","created_at":"$(iso_at $((NOW_S - 50)))","input_tokens":1000,"cache_read_tokens":0,"output_tokens":1000,"tool_calls":[{"name":"read"}],"content":"mentions USER_INPUT"}
{"step_index":5,"type":"GENERIC","created_at":"$(iso_at $((NOW_S - 25)))"}
{"step_index":6,"type":"PLANNER_RESPONSE","created_at":"$(iso_at $((NOW_S - 20)))","input_tokens":1000,"cache_read_tokens":0,"output_tokens":3000}
EOF
touch_at "$NOW_S" "$TURN_TRANS"
OUT=$("$STATUSLINE" <<< "{\"cwd\":\"/tmp\",\"transcript_path\":\"${TURN_TRANS}\",\"terminal_width\":120}")
PLAIN=$(strip_ansi "$OUT")
assert_contains "turn speed excludes checkpoint and previous turn without conv_id" "$PLAIN" "│ 80 tok/s │"

# System wake-up after completed turn (no tool_calls) starts a fresh turn; legacy 6-col cache auto-refreshes.
WAKE_TRANS="${TMP_DIR}/wake-speed.jsonl"
cat > "$WAKE_TRANS" <<EOF
{"step_index":0,"type":"USER_INPUT","created_at":"$(iso_at $((NOW_S - 600)))","content":"first"}
{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"$(iso_at $((NOW_S - 600)))","input_tokens":500,"cache_read_tokens":0,"output_tokens":500}
{"step_index":2,"type":"SYSTEM_MESSAGE","created_at":"$(iso_at $((NOW_S - 40)))","content":"subagent done"}
{"step_index":3,"type":"PLANNER_RESPONSE","created_at":"$(iso_at $((NOW_S - 40)))","input_tokens":500,"cache_read_tokens":0,"output_tokens":2000}
EOF
touch_at "$NOW_S" "$WAKE_TRANS"
OUT=$("$STATUSLINE" <<< "{\"cwd\":\"/tmp\",\"conversation_id\":\"wake-conv\",\"transcript_path\":\"${WAKE_TRANS}\",\"terminal_width\":120}")
assert_contains "system wake-up resets turn speed" "$(strip_ansi "$OUT")" "│ 50 tok/s │"
WAKE_CACHE="${XDG_CACHE_HOME}/statusline-hud/transcript/wake-conv.cache"
WAKE_STAT=$(stat -c '%Y %s' "$WAKE_TRANS" 2>/dev/null || stat -f '%m %z' "$WAKE_TRANS")
printf '%s 1000 2500 0.0 %s\n' "$WAKE_STAT" "$((NOW_S - 600))" > "$WAKE_CACHE"
OUT=$("$STATUSLINE" <<< "{\"cwd\":\"/tmp\",\"conversation_id\":\"wake-conv\",\"transcript_path\":\"${WAKE_TRANS}\",\"terminal_width\":120}")
assert_contains "legacy 6-column transcript cache refreshes speed" "$(strip_ansi "$OUT")" "│ 50 tok/s │"

# Trailing USER_INPUT with no planner response yet resets speed to 0 tok/s.
printf '{"step_index":4,"type":"USER_INPUT","created_at":"%s","content":"next"}\n' "$(iso_at "$NOW_S")" >> "$WAKE_TRANS"
touch_at "$((NOW_S + 5))" "$WAKE_TRANS"
OUT=$("$STATUSLINE" <<< "{\"cwd\":\"/tmp\",\"conversation_id\":\"wake-conv\",\"transcript_path\":\"${WAKE_TRANS}\",\"terminal_width\":120}")
assert_contains "new turn without response yet shows 0 tok/s" "$(strip_ansi "$OUT")" "│ 0 tok/s │"

# Transcript cache distinguishes no planner rows (keeps payload tokens) from explicit zero usage.
for usage in '{}' '{"type":"PLANNER_RESPONSE","input_tokens":0,"output_tokens":0}'; do
  printf '%s\n' "$usage" > "$TMP_DIR/zero.jsonl"
  for run in 1 2; do
    OUT=$("$STATUSLINE" <<< "{\"cwd\":\"/tmp\",\"conversation_id\":\"zero\",\"transcript_path\":\"$TMP_DIR/zero.jsonl\",\"context_window\":{\"total_input_tokens\":500,\"total_output_tokens\":100}}")
    if [ "$usage" = '{}' ]; then assert_contains "no planner usage keeps payload tokens ($run)" "$(strip_ansi "$OUT")" "tok 600"
    else assert_contains "zero transcript usage ($run)" "$(strip_ansi "$OUT")" "tok 0"; fi
  done
done

# Trailing SYSTEM_MESSAGE after an ended turn resets speed to 0 tok/s instead of collapsing on refreshed mtime.
WAIT_TRANS="${TMP_DIR}/wait-wakeup.jsonl"
cat > "$WAIT_TRANS" <<EOF
{"step_index":0,"type":"USER_INPUT","created_at":"$(iso_at $((NOW_S - 600)))","content":"first"}
{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"$(iso_at $((NOW_S - 600)))","input_tokens":500,"cache_read_tokens":0,"output_tokens":1500}
{"step_index":2,"type":"SYSTEM_MESSAGE","created_at":"$(iso_at "$NOW_S")","content":"subagent done"}
EOF
touch_at "$NOW_S" "$WAIT_TRANS"
OUT=$("$STATUSLINE" <<< "{\"cwd\":\"/tmp\",\"conversation_id\":\"wait-conv\",\"transcript_path\":\"${WAIT_TRANS}\",\"terminal_width\":120}")
assert_contains "trailing SYSTEM_MESSAGE after ended turn shows 0 tok/s" "$(strip_ansi "$OUT")" "│ 0 tok/s │"

# CHECKPOINT usage counts toward session tokens & cache without polluting turn speed.
CP_TRANS="${TMP_DIR}/checkpoint-usage.jsonl"
cat > "$CP_TRANS" <<EOF
{"step_index":0,"type":"USER_INPUT","created_at":"$(iso_at $((NOW_S - 200)))","content":"compact"}
{"step_index":1,"type":"CHECKPOINT","created_at":"$(iso_at $((NOW_S - 200)))","input_tokens":10000,"cache_read_tokens":90000,"output_tokens":4000}
{"step_index":2,"type":"PLANNER_RESPONSE","created_at":"$(iso_at $((NOW_S - 20)))","input_tokens":10000,"cache_read_tokens":0,"output_tokens":1000}
EOF
touch_at "$NOW_S" "$CP_TRANS"
OUT=$("$STATUSLINE" <<< "{\"cwd\":\"/tmp\",\"conversation_id\":\"cp-conv\",\"transcript_path\":\"${CP_TRANS}\",\"terminal_width\":120}")
PLAIN=$(strip_ansi "$OUT")
assert_contains "checkpoint tokens counted in session total" "$PLAIN" "tok 115k (110k↑ 5k↓)"
assert_contains "checkpoint cache counted in session cache" "$PLAIN" "cache 81.8%"
assert_contains "checkpoint excluded from turn speed" "$PLAIN" "│ 50 tok/s │"

# Rewind (strict step_index drop) during an unfinished turn resets speed even on SYSTEM_MESSAGE wake-up, while retaining consumed tokens.
RW_TRANS="${TMP_DIR}/rewind-mid-turn.jsonl"
cat > "$RW_TRANS" <<EOF
{"step_index":0,"type":"USER_INPUT","created_at":"$(iso_at $((NOW_S - 600)))","content":"start"}
{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"$(iso_at $((NOW_S - 600)))","input_tokens":1000,"cache_read_tokens":0,"output_tokens":2000,"tool_calls":[{"name":"read"}]}
{"step_index":2,"type":"GENERIC","created_at":"$(iso_at $((NOW_S - 590)))"}
{"step_index":1,"type":"SYSTEM_MESSAGE","created_at":"$(iso_at $((NOW_S - 20)))","content":"subagent done"}
{"step_index":2,"type":"PLANNER_RESPONSE","created_at":"$(iso_at $((NOW_S - 20)))","input_tokens":1000,"cache_read_tokens":0,"output_tokens":1000}
EOF
touch_at "$NOW_S" "$RW_TRANS"
OUT=$("$STATUSLINE" <<< "{\"cwd\":\"/tmp\",\"conversation_id\":\"rw-conv\",\"transcript_path\":\"${RW_TRANS}\",\"terminal_width\":120}")
PLAIN=$(strip_ansi "$OUT")
assert_contains "rewind keeps consumed tokens" "$PLAIN" "tok 5k (2k↑ 3k↓)"
assert_contains "rewind strict step_index drop resets turn speed" "$PLAIN" "│ 50 tok/s │"

# Confirmation takes priority over tool use; usage falls back to the payload.
OUT=$("$STATUSLINE" <<< '{
  "cwd":"/tmp","agent_state":"tool_use","tool_confirmation_pending":true,"pending_input_count":2,
  "cycle_mode":"accept-edits","vim":{"mode":"NORMAL"},"sandbox":{"enabled":true},
  "context_window":{"current_usage":{"input_tokens":30000,"cache_read_input_tokens":90000}}
}')
PLAIN=$(strip_ansi "$OUT")
assert_contains "confirm state" "$PLAIN" "⚠ CONFIRM (+2)"
assert_contains "mode + vim" "$PLAIN" "EDITS [N]"
assert_contains "current_usage cache fallback 1dp" "$PLAIN" "cache 75.0%"
assert_contains "sandbox ON" "$PLAIN" "sandbox ON"

# Partial quotas, disabled buckets and model.id fallback.
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
assert_contains "weekly usage retains bar on wide screen" "$PLAIN" "Gemini week █"
assert_not_contains "disabled 5h hidden" "$PLAIN" "Gemini 5h"
assert_contains "remaining_amount has left label" "$PLAIN" "3P 5h 42 left"

# Omitted fields use defaults; the empty quota row is omitted.
OUT=$("$STATUSLINE" <<< '{"cwd":"/tmp","terminal_width":120}')
PLAIN=$(strip_ansi "$OUT")
assert_eq "omitted wide defaults" "$PLAIN" $'  ● READY │ ctx ░░░░░░░░░░ 0.0% │ /tmp\n  artifacts 0 │ subagents 0/0 │ tasks 0 │ sandbox OFF │ tok 0 (0↑ 0↓) │ 0 tok/s │ 0m'

# A very narrow pane keeps the selected components even when they overflow.
OUT=$("$STATUSLINE" <<< '{"cwd":"/项目/很长的项目名","conversation_title":"✨ 修复标题","task_count":1,"terminal_width":20,"model":{"id":"gemini-4-neon","display_name":"Gemini 4 Neon (XHigh)"},"vcs":{"branch":"feature/很长的分支名"}}')
PLAIN=$(strip_ansi "$OUT")
assert_eq "no pruning, no separate title row" "$PLAIN" $'  ● READY │ Gemini 4 Neon (XHigh) │ ctx 0.0% │ …/很长的项目名 │ feature/很长的分支名\n  artifacts 0 │ subagents 0/0 │ tasks 1 │ sandbox OFF │ tok 0 │ 0 tok/s │ 0m │ ▸ ✨ 修复标题'

# LC_ALL=C locale safety (no broken UTF-8 bar bytes, still shows bar on wide screen)
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

# Trailing slash HOME & root CWD (Bash 3.2 empty-array safety)
OUT=$(printf '{"cwd":"%s/","agent_state":"idle","terminal_width":80}' "$HOME" | "$STATUSLINE")
assert_contains "trailing slash HOME renders ~" "$(strip_ansi "$OUT")" "│ ~"
OUT=$(printf '{"cwd":"///","agent_state":"idle","terminal_width":80}' | "$STATUSLINE")
assert_contains "multiple slashes renders /" "$(strip_ansi "$OUT")" "│ /"

# Independent switches, explicit false and inheritance on both sides of the breakpoint.
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
    assert_eq "narrow delta both directions, stable order" "$PLAIN" $'  ● READY │ ctx 0.0% │ /tmp\n  Gemini 5h 50.0%\n  subagents 0/0 │ tasks 2 │ sandbox OFF │ tok 0 │ 0 tok/s │ 0m'
  else
    assert_eq "ordinary switches at 100 cols" "$PLAIN" $'  ● READY │ ctx ░░░░░░░░░░ 0.0% │ /tmp\n  3P 5h 42 left\n  artifacts 1 │ subagents 0/0 │ tok 0 (0↑ 0↓) │ 0 tok/s │ 0m │ ▸ My title'
  fi
done

# Empty narrow inherits ordinary switches; empty rows have no placeholder.
printf '%s\n' '{"showModel":false,"showContext":false,"showPath":false,"showArtifacts":false,"showSubagents":false,"showTasks":false,"showSandbox":false,"showTokens":false,"showTokenSpeed":false,"showDuration":false,"narrow":{}}' > "$CFG_CUSTOM/statusline-hud/config.json"
OUT=$(XDG_CONFIG_HOME="$CFG_CUSTOM" "$STATUSLINE" <<< '{"cwd":"/tmp","model":{"id":"hidden"},"terminal_width":80}')
assert_eq "only the status row remains" "$(strip_ansi "$OUT")" '  ● READY'
OUT=$(XDG_CONFIG_HOME="$CFG_CUSTOM" "$STATUSLINE" <<< '{"cwd":"/tmp","model":{"id":"hidden"},"conversation_title":"Only title","terminal_width":80}')
assert_eq "ordinary switches inherited without extra separators" "$(strip_ansi "$OUT")" $'  ● READY\n  ▸ Only title'

# Real git repository status parsing (flags, diff lines, unborn/detached, narrow, cache v2)
if command -v git >/dev/null 2>&1; then
  render_git() {
    local out
    out=$(XDG_CACHE_HOME="$3" "$STATUSLINE" <<< "{\"cwd\":\"$1\",\"terminal_width\":$2}") || return
    strip_ansi "$out"
  }

  GIT_REPO="${TMP_DIR}/git-repo"
  mkdir -p "$GIT_REPO"
  git -C "$GIT_REPO" init -q -b main
  git -C "$GIT_REPO" config user.email "test@example.com"
  git -C "$GIT_REPO" config user.name "Test"

  # Unborn branch (before first commit): staged and staged+modified line stats
  printf '1\n2\n3\n' > "$GIT_REPO/a.txt"
  git -C "$GIT_REPO" add a.txt
  PLAIN=$(render_git "$GIT_REPO" 120 "${TMP_DIR}/git-cache-unborn1")
  assert_contains "git unborn staged" "$PLAIN" "main [+] (+3)"
  printf '1\n2x\n3\n4\n' > "$GIT_REPO/a.txt"
  PLAIN=$(render_git "$GIT_REPO" 120 "${TMP_DIR}/git-cache-unborn2")
  assert_contains "git unborn staged+modified" "$PLAIN" "main [+!] (+4)"

  # Clean committed repo
  printf 'b1\nb2\n' > "$GIT_REPO/b.txt"
  printf 'r1\n' > "$GIT_REPO/r.txt"
  git -C "$GIT_REPO" add a.txt b.txt r.txt && git -C "$GIT_REPO" commit -q -m "init"
  PLAIN=$(render_git "$GIT_REPO" 120 "${TMP_DIR}/git-cache-clean")
  assert_contains "git clean branch" "$PLAIN" "│ main"
  assert_not_contains "git clean omits brackets" "$PLAIN" "main ["
  assert_not_contains "git clean omits star" "$PLAIN" "main*"

  # Ahead & behind upstream on clean repo
  GIT_REMOTE="${TMP_DIR}/git-remote.git"
  GIT_OTHER="${TMP_DIR}/git-other"
  git init -q --bare -b main "$GIT_REMOTE"
  git -C "$GIT_REPO" remote add origin "$GIT_REMOTE"
  git -C "$GIT_REPO" push -q -u origin main
  git clone -q "$GIT_REMOTE" "$GIT_OTHER"
  git -C "$GIT_OTHER" config user.email "test@example.com"
  git -C "$GIT_OTHER" config user.name "Test"
  printf 'remote\n' > "$GIT_OTHER/remote.txt"
  git -C "$GIT_OTHER" add remote.txt && git -C "$GIT_OTHER" commit -q -m "remote" && git -C "$GIT_OTHER" push -q
  git -C "$GIT_REPO" fetch -q
  printf 'local\n' > "$GIT_REPO/local.txt"
  git -C "$GIT_REPO" add local.txt && git -C "$GIT_REPO" commit -q -m "local"
  PLAIN=$(render_git "$GIT_REPO" 120 "${TMP_DIR}/git-cache-ab")
  assert_contains "git clean ahead/behind" "$PLAIN" "main [↑1↓1]"
  PLAIN=$(render_git "$GIT_REPO" 80 "${TMP_DIR}/git-cache-ab")
  assert_not_contains "git clean narrow omits star" "$PLAIN" "main*"

  # Full flags (+, !, ✘, », ?, $, ↑, ↓), binary ignored in numstat, untracked excluded from diff
  printf 'stash\n' >> "$GIT_REPO/a.txt"
  git -C "$GIT_REPO" stash push -q -m "s1"
  printf 'c1\nc2\n' > "$GIT_REPO/c.txt"
  git -C "$GIT_REPO" add c.txt
  printf '\000\001\002' > "$GIT_REPO/bin.dat"
  git -C "$GIT_REPO" add bin.dat
  printf '1\n20\n3\n4\n' > "$GIT_REPO/a.txt"
  rm "$GIT_REPO/b.txt"
  git -C "$GIT_REPO" mv r.txt r2.txt
  printf 'u1\nu2\nu3\n' > "$GIT_REPO/u.txt"
  GIT_CACHE_FULL="${TMP_DIR}/git-cache-full"
  PLAIN=$(render_git "$GIT_REPO" 120 "$GIT_CACHE_FULL")
  assert_contains "git wide shows compact flags and diff lines" "$PLAIN" "main [+!✘»?$↑1↓1] (+3 −3)"
  PLAIN=$(render_git "$GIT_REPO" 120 "$GIT_CACHE_FULL")
  assert_contains "git cache v2 hit preserves flags and diff lines" "$PLAIN" "main [+!✘»?$↑1↓1] (+3 −3)"
  for f in "${GIT_CACHE_FULL}/statusline-hud/git"/*.cache; do
    printf '%s\ttrue\t9\t9\t1\t1\t1\t1\told\n' "$(date +%s)" > "$f"
  done
  PLAIN=$(render_git "$GIT_REPO" 120 "$GIT_CACHE_FULL")
  assert_contains "git legacy cache invalidated and refreshed" "$PLAIN" "main [+!✘»?$↑1↓1] (+3 −3)"

  PLAIN=$(render_git "$GIT_REPO" 80 "$GIT_CACHE_FULL")
  assert_contains "git narrow shows dirty branch" "$PLAIN" "main*"
  assert_not_contains "git narrow omits flags" "$PLAIN" "[+!"
  assert_not_contains "git narrow omits diff lines" "$PLAIN" "(+3"

  git -C "$GIT_REPO" checkout -q --detach HEAD
  DETACH_SHA=$(git -C "$GIT_REPO" rev-parse --short=7 HEAD)
  PLAIN=$(render_git "$GIT_REPO" 120 "${TMP_DIR}/git-cache-detach")
  assert_contains "git detached HEAD uses short sha" "$PLAIN" "${DETACH_SHA} [+!✘»?$] (+3 −3)"

  # Single-sided deletion and merge conflict (=)
  GIT_CONF="${TMP_DIR}/git-conf"
  mkdir -p "$GIT_CONF"
  git -C "$GIT_CONF" init -q -b main
  git -C "$GIT_CONF" config user.email "test@example.com"
  git -C "$GIT_CONF" config user.name "Test"
  printf 'l1\nl2\n' > "$GIT_CONF/f.txt"
  git -C "$GIT_CONF" add f.txt && git -C "$GIT_CONF" commit -q -m "base"
  rm "$GIT_CONF/f.txt"
  PLAIN=$(render_git "$GIT_CONF" 120 "${TMP_DIR}/git-cache-del")
  assert_contains "git deletion-only diff omits plus" "$PLAIN" "main [✘] (−2)"
  git -C "$GIT_CONF" checkout -q -- f.txt
  git -C "$GIT_CONF" checkout -q -b other
  printf 'other\nl2\n' > "$GIT_CONF/f.txt"
  git -C "$GIT_CONF" commit -q -am "other"
  git -C "$GIT_CONF" checkout -q main
  printf 'ours\nl2\n' > "$GIT_CONF/f.txt"
  git -C "$GIT_CONF" commit -q -am "ours"
  git -C "$GIT_CONF" merge --no-edit other >/dev/null 2>&1 || true
  PLAIN=$(render_git "$GIT_CONF" 120 "${TMP_DIR}/git-cache-conf")
  assert_contains "git merge conflict shows =" "$PLAIN" "main [=]"

  # Synthetic JSON dirty fallback without local git repo keeps star on wide screen
  OUT=$("$STATUSLINE" <<< '{"cwd":"/tmp","vcs":{"type":"git","branch":"main","dirty":true},"terminal_width":120}')
  assert_contains "synthetic dirty fallback keeps star" "$(strip_ansi "$OUT")" "main*"

  # Non-existent cwd inside a git repo does not walk ancestor .git or write git cache
  GIT_CACHE_MISSING="${TMP_DIR}/git-cache-missing"
  OUT=$(XDG_CACHE_HOME="$GIT_CACHE_MISSING" "$STATUSLINE" <<< "{\"cwd\":\"${GIT_REPO}/does-not-exist/sub\",\"vcs\":{\"type\":\"git\",\"branch\":\"remote-main\",\"dirty\":true},\"terminal_width\":120}")
  PLAIN=$(strip_ansi "$OUT")
  assert_contains "missing cwd keeps JSON vcs fallback" "$PLAIN" "remote-main*"
  assert_not_contains "missing cwd does not inspect ancestor git repo" "$PLAIN" "[+!"
  [ ! -d "${GIT_CACHE_MISSING}/statusline-hud/git" ] && pass || fail "missing cwd must not write git cache"
fi

# UTF-8 BOM in config.json is accepted by statusline.sh
CFG_BOM="${TMP_DIR}/cfg-bom"
mkdir -p "${CFG_BOM}/statusline-hud"
printf '\xef\xbb\xbf{"showTitle":false,"showCost":false}\n' > "${CFG_BOM}/statusline-hud/config.json"
OUT=$(XDG_CONFIG_HOME="$CFG_BOM" "$STATUSLINE" <<< '{
  "cwd":"/tmp",
  "conversation_title":"Hidden by BOM config",
  "cost":{"total_usd":1.25},
  "terminal_width":120
}')
PLAIN=$(strip_ansi "$OUT")
assert_not_contains "BOM config hides title" "$PLAIN" "Hidden by BOM config"
assert_not_contains "BOM config hides cost" "$PLAIN" '$1.25'

# Broken config.json gracefully falls back to defaults without failing
CFG_BAD="${TMP_DIR}/cfg-bad"
mkdir -p "${CFG_BAD}/statusline-hud"
printf '{not valid json,,,' > "${CFG_BAD}/statusline-hud/config.json"
OUT=$(XDG_CONFIG_HOME="$CFG_BAD" "$STATUSLINE" <<< '{
  "cwd":"/tmp",
  "conversation_title":"Shown by default",
  "agent_state":"working",
  "cycle_mode":"plan",
  "model":{"display_name":"Gemini 4"},
  "terminal_width":120
}')
PLAIN=$(strip_ansi "$OUT")
assert_contains "broken config falls back cleanly" "$PLAIN" "PLAN"
assert_contains "broken config uses default showTitle=true" "$PLAIN" "▸ Shown by default"

# ANSI escape & control character sanitization in untrusted strings
OUT=$("$STATUSLINE" <<< '{
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

# Invalid stdin still renders a usable status; out-of-range data is clamped.
OUT=$("$STATUSLINE" <<< 'not json')
assert_contains "invalid JSON renders the default status" "$(strip_ansi "$OUT")" "● READY │ ctx 0.0%"
OUT=$("$STATUSLINE" <<< '{"cwd":"/tmp","context_window":{"used_percentage":-5.5}}')
assert_contains "negative context clamps to zero" "$(strip_ansi "$OUT")" "ctx 0.0%"
OUT=$("$STATUSLINE" <<< '{"cwd":"/tmp","context_window":{"used_percentage":150},"quota":{"gemini-5h":{"remaining_fraction":1.2}}}')
PLAIN=$(strip_ansi "$OUT")
assert_contains "context clamps at 100%" "$PLAIN" "ctx 100.0%"
assert_contains "overfull quota shows zero used" "$PLAIN" "Gemini 5h 0.0%"

# Exercise /hud against real settings and config files in the temporary directory.
HUD_CTL="${ROOT_DIR}/skills/hud/scripts/hud.sh"
export XDG_CONFIG_HOME="${TMP_DIR}/hud-ctl-cfg"
export HUD_SETTINGS_FILE="${TMP_DIR}/hud-settings.json"
HUD_CONFIG_FILE="${XDG_CONFIG_HOME}/statusline-hud/config.json"
DOC_FIRST=$("$HUD_CTL" doctor)
assert_contains "first run explains activation" "$DOC_FIRST" "activate: /statusline "
"$HUD_CTL" preview 80 >/dev/null
[ ! -e "$XDG_CONFIG_HOME" ] && pass || fail "preview must not create user config"
"$HUD_CTL" unset narrow.showCost >/dev/null
[ ! -e "$XDG_CONFIG_HOME" ] && pass || fail "unset without config must not create user config"

printf '{"model":"Gemini 4","statusLine":{"type":"command","command":"~/old.sh","enabled":false,"stack_with_default":true}}\n' > "$HUD_SETTINGS_FILE"

# doctor detects other command, enabled=false, stack_with_default=true, and smoke test passes
DOC_OUT=$("$HUD_CTL" doctor)
assert_contains "doctor detects OTHER COMMAND" "$DOC_OUT" "OTHER COMMAND"
assert_contains "doctor detects enabled=false" "$DOC_OUT" "statusLine.enabled is false"
assert_contains "doctor detects stack_with_default" "$DOC_OUT" "stack_with_default is true"
assert_contains "doctor smoke passes" "$DOC_OUT" "smoke:    OK"

# Check effective settings via the real preview, not the update commands' reports.
"$HUD_CTL" set showCost=false narrow.showTasks=false >/dev/null
"$HUD_CTL" toggle narrow.showCost >/dev/null
PREV_OUT=$("$HUD_CTL" preview 80)
assert_contains "narrow toggle enables cost" "$PREV_OUT" '~$0.42'
assert_contains "preview includes token speed" "$PREV_OUT" 'tok/s'
assert_contains "preview uses tok label" "$PREV_OUT" 'tok 268k'
assert_not_contains "narrow hides tasks" "$PREV_OUT" 'tasks 1'
assert_not_contains "preview strips ANSI" "$PREV_OUT" $'\033['
PREV_OUT=$("$HUD_CTL" preview 120)
assert_contains "wide still includes tasks" "$PREV_OUT" 'tasks 1'
assert_not_contains "wide still hides cost" "$PREV_OUT" '~$0.42'
"$HUD_CTL" set showTokenSpeed=false >/dev/null
assert_not_contains "showTokenSpeed=false hides tok/s" "$("$HUD_CTL" preview 120)" 'tok/s'
"$HUD_CTL" set narrow.showTokenSpeed=true >/dev/null
assert_contains "narrow.showTokenSpeed=true overrides hidden speed" "$("$HUD_CTL" preview 80)" 'tok/s'
"$HUD_CTL" unset showTokenSpeed narrow.showTokenSpeed >/dev/null
"$HUD_CTL" unset narrow.showCost >/dev/null
PREV_OUT=$("$HUD_CTL" preview 80)
assert_not_contains "narrow preview inherits hidden cost after unset" "$PREV_OUT" '~$0.42'
assert_not_contains "unset preserves the other narrow override" "$PREV_OUT" 'tasks 1'
"$HUD_CTL" unset narrow.showTasks >/dev/null
assert_eq "last narrow override removed, base value preserved" "$(jq -c . "$HUD_CONFIG_FILE")" '{"showCost":false}'
"$HUD_CTL" set narrow.showCost=true >/dev/null
"$HUD_CTL" unset narrow >/dev/null
assert_eq "unset narrow preserves base settings" "$(jq -c . "$HUD_CONFIG_FILE")" '{"showCost":false}'

# Reject the whole batch, including the valid change preceding the bad argument.
cp "$HUD_CONFIG_FILE" "$TMP_DIR/before.json"
for invalid in unknownKey=true showTitle=maybe; do
  if "$HUD_CTL" set showCost=true "$invalid" >/dev/null 2>&1; then
    fail "set accepted $invalid"
  else
    pass
  fi
  cmp -s "$TMP_DIR/before.json" "$HUD_CONFIG_FILE" && pass || fail "set changed config after $invalid"
done

# doctor flags unknown keys and wrong types in hand-edited config.json
printf '%s\n' '{"show_title":true,"narrow":{"showTitle":"yes"}}' > "$HUD_CONFIG_FILE"
DOC_WARN=$("$HUD_CTL" doctor)
assert_contains "doctor flags unknown key" "$DOC_WARN" 'unknown key "show_title"'
assert_contains "doctor flags invalid nested type" "$DOC_WARN" 'invalid type for "narrow.showTitle"'

printf '{"narrow":false}\n' > "$HUD_CONFIG_FILE"
DOC_WARN=$("$HUD_CTL" doctor)
assert_contains "doctor validates narrow object" "$DOC_WARN" 'invalid type for "narrow"'
DOC_WARN_UNACTIVATED=$(HUD_SETTINGS_FILE="$TMP_DIR/no-settings.json" "$HUD_CTL" doctor)
assert_contains "doctor keeps activation hint when config has warnings" "$DOC_WARN_UNACTIVATED" $'issue(s) found; HUD not enabled yet\n  activate: /statusline '

# empty or multi-document config.json flagged consistently by doctor and rejected by set
for bad_cfg in '' '{}{}' '{broken json'; do
  printf '%s' "$bad_cfg" > "$HUD_CONFIG_FILE"
  DOC_BAD=$("$HUD_CTL" doctor)
  assert_contains "doctor flags invalid config (${bad_cfg:-empty})" "$DOC_BAD" "INVALID JSON"
  if "$HUD_CTL" set showTitle=true >/dev/null 2>&1; then
    fail "set should reject invalid config (${bad_cfg:-empty})"
  else
    pass
  fi
  cmp -s "$HUD_CONFIG_FILE" <(printf '%s' "$bad_cfg") && pass || fail "set overwrote malformed config"
done
"$HUD_CTL" reset >/dev/null
[ ! -e "$HUD_CONFIG_FILE" ] && pass || fail "reset should remove config"

# invalid statusLine type emits activate hint only once
printf '{"statusLine":"bad"}\n' > "$TMP_DIR/bad-sl.json"
DOC_BAD_SL=$(HUD_SETTINGS_FILE="$TMP_DIR/bad-sl.json" "$HUD_CTL" doctor)
assert_contains "doctor flags non-object statusLine" "$DOC_BAD_SL" "INVALID (statusLine is string"
assert_eq "non-object statusLine prints activate hint once" "$(printf '%s\n' "$DOC_BAD_SL" | grep -c 'activate: /statusline')" "1"

# missing jq skips smoke check instead of reporting smoke OK
NO_JQ_BIN="${TMP_DIR}/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for cmd in bash cat chmod date dirname head mkdir mv rm stat tr awk grep sed; do
  p=$(command -v "$cmd" 2>/dev/null || true)
  [ -n "$p" ] && ln -s "$p" "${NO_JQ_BIN}/${cmd}"
done
DOC_NO_JQ=$(PATH="$NO_JQ_BIN" HUD_SETTINGS_FILE="$TMP_DIR/no-settings.json" bash "$HUD_CTL" doctor)
assert_contains "missing jq skips smoke check" "$DOC_NO_JQ" "smoke:    SKIPPED (jq missing)"
assert_contains "missing jq reports 1 issue" "$DOC_NO_JQ" "1 issue(s) found"

# apply-settings preserves unrelated settings, sets command + enabled=true, enforces 0600
"$HUD_CTL" apply-settings >/dev/null
assert_eq "apply-settings preserves model" "$(jq -r '.model' "$HUD_SETTINGS_FILE")" "Gemini 4"
assert_eq "apply-settings sets enabled true" "$(jq -r '.statusLine.enabled' "$HUD_SETTINGS_FILE")" "true"
assert_eq "apply-settings preserves stack preference" "$(jq -r '.statusLine.stack_with_default' "$HUD_SETTINGS_FILE")" "true"
assert_eq "apply-settings uses private permissions" "$(stat -c '%a' "$HUD_SETTINGS_FILE" 2>/dev/null || stat -f '%Lp' "$HUD_SETTINGS_FILE")" "600"

DOC_ACTIVE=$("$HUD_CTL" doctor)
assert_contains "active HUD is ready" "$DOC_ACTIVE" "Environment ready; HUD enabled"
assert_not_contains "active HUD needs no activation command" "$DOC_ACTIVE" "activate: /statusline"
jq '.statusLine.enabled = false' "$HUD_SETTINGS_FILE" > "$TMP_DIR/disabled.json"
DOC_DISABLED=$(HUD_SETTINGS_FILE="$TMP_DIR/disabled.json" "$HUD_CTL" doctor)
assert_contains "disabled HUD has recovery command" "$DOC_DISABLED" "/statusline enable"
assert_contains "disabled HUD summary states disabled" "$DOC_DISABLED" "HUD configured but disabled"
assert_not_contains "disabled HUD is not active" "$DOC_DISABLED" "ACTIVE ->"
assert_not_contains "disabled HUD omits activate command" "$DOC_DISABLED" "activate: /statusline"

# Symlinked statusLine.command pointing to the same script is recognized as ACTIVE
SYM_PLUG="${TMP_DIR}/symlinked-plugin"
ln -s "$ROOT_DIR" "$SYM_PLUG"
printf '{"statusLine":{"type":"command","command":"%s/scripts/statusline.sh","enabled":true}}\n' "$SYM_PLUG" > "$TMP_DIR/symlink-settings.json"
DOC_SYM=$(HUD_SETTINGS_FILE="$TMP_DIR/symlink-settings.json" "$HUD_CTL" doctor)
assert_contains "symlinked script recognized as ACTIVE" "$DOC_SYM" "ACTIVE ->"
assert_contains "symlinked script summary reports enabled" "$DOC_SYM" "Environment ready; HUD enabled"

# UTF-8 BOM in settings.json and config.json handled cleanly by hud.sh
BOM_CFG_HOME="${TMP_DIR}/hud-bom-cfg"
mkdir -p "${BOM_CFG_HOME}/statusline-hud"
printf '\xef\xbb\xbf{"showCost":false}\n' > "${BOM_CFG_HOME}/statusline-hud/config.json"
printf '\xef\xbb\xbf{"model":"Gemini 4","statusLine":{"type":"command","command":"%s","enabled":true}}\n' "$STATUSLINE" > "$TMP_DIR/bom-settings.json"
DOC_BOM=$(XDG_CONFIG_HOME="$BOM_CFG_HOME" HUD_SETTINGS_FILE="$TMP_DIR/bom-settings.json" "$HUD_CTL" doctor)
assert_contains "doctor parses BOM settings.json as ACTIVE" "$DOC_BOM" "ACTIVE ->"
assert_contains "doctor parses BOM config.json as valid" "$DOC_BOM" "file:     OK (valid)"
assert_contains "doctor prints effective BOM config" "$DOC_BOM" "showCost        = [OFF]"
XDG_CONFIG_HOME="$BOM_CFG_HOME" "$HUD_CTL" set showTitle=false >/dev/null
assert_eq "set preserves keys from BOM config.json" "$(jq -c . "${BOM_CFG_HOME}/statusline-hud/config.json")" '{"showCost":false,"showTitle":false}'
HUD_SETTINGS_FILE="$TMP_DIR/bom-settings.json" "$HUD_CTL" apply-settings >/dev/null
assert_eq "apply-settings preserves keys from BOM settings.json" "$(jq -r '.model' "$TMP_DIR/bom-settings.json")" "Gemini 4"

# Inaccessible parent directories (sandbox/permission denied) are flagged and never treated as empty {}
if [ "$(id -u)" -ne 0 ]; then
  LOCKED_CFG="${TMP_DIR}/locked-cfg"
  LOCKED_SET="${TMP_DIR}/locked-set"
  mkdir -p "${LOCKED_CFG}/statusline-hud" "$LOCKED_SET"
  printf '{"showCost":false}\n' > "${LOCKED_CFG}/statusline-hud/config.json"
  printf '{"model":"keep"}\n' > "${LOCKED_SET}/settings.json"
  chmod 000 "$LOCKED_CFG" "$LOCKED_SET"

  DOC_LOCKED=$(XDG_CONFIG_HOME="$LOCKED_CFG" HUD_SETTINGS_FILE="${LOCKED_SET}/settings.json" "$HUD_CTL" doctor)
  assert_contains "doctor flags inaccessible settings dir" "$DOC_LOCKED" "status:   inaccessible (permission denied or sandboxed)"
  assert_contains "doctor flags inaccessible config dir" "$DOC_LOCKED" "file:     inaccessible (permission denied or sandboxed)"
  assert_contains "doctor flags inaccessible effective config" "$DOC_LOCKED" "(config inaccessible: permission denied or sandboxed)"
  assert_contains "doctor summary avoids false not-enabled claim" "$DOC_LOCKED" "HUD status unknown (settings inaccessible)"
  assert_not_contains "doctor omits activate hint when settings inaccessible" "$DOC_LOCKED" "activate: /statusline"
  if XDG_CONFIG_HOME="$LOCKED_CFG" "$HUD_CTL" set showTitle=false >/dev/null 2>&1; then
    fail "set must fail when config dir is inaccessible"
  else
    pass
  fi
  if XDG_CONFIG_HOME="$LOCKED_CFG" "$HUD_CTL" reset >/dev/null 2>&1; then
    fail "reset must fail when config dir is inaccessible"
  else
    pass
  fi
  if HUD_SETTINGS_FILE="${LOCKED_SET}/settings.json" "$HUD_CTL" apply-settings >/dev/null 2>&1; then
    fail "apply-settings must fail when settings dir is inaccessible"
  else
    pass
  fi
  chmod 700 "$LOCKED_CFG" "$LOCKED_SET"
  assert_eq "inaccessible config untouched after failed writes" "$(jq -c . "${LOCKED_CFG}/statusline-hud/config.json")" '{"showCost":false}'
  assert_eq "inaccessible settings untouched after failed apply" "$(jq -c . "${LOCKED_SET}/settings.json")" '{"model":"keep"}'

  # Deep locked ancestor (3+ levels) is detected, while execute-only (0111) parent with missing file is not flagged
  DEEP_LOCK="${TMP_DIR}/deep-lock"
  EXEC_ONLY="${TMP_DIR}/exec-only"
  mkdir -p "${DEEP_LOCK}/sub/cfg/statusline-hud" "${EXEC_ONLY}/statusline-hud"
  chmod 000 "$DEEP_LOCK"
  chmod 111 "$EXEC_ONLY"
  DOC_DEEP=$(XDG_CONFIG_HOME="${DEEP_LOCK}/sub/cfg" HUD_SETTINGS_FILE="$TMP_DIR/no-settings.json" "$HUD_CTL" doctor)
  assert_contains "doctor flags 3+ level inaccessible ancestor" "$DOC_DEEP" "file:     inaccessible (permission denied or sandboxed)"
  DOC_EXEC=$(XDG_CONFIG_HOME="$EXEC_ONLY" HUD_SETTINGS_FILE="$TMP_DIR/no-settings.json" "$HUD_CTL" doctor)
  assert_contains "execute-only parent with missing config is not falsely flagged" "$DOC_EXEC" "file:     not present (using defaults)"
  chmod 700 "$DEEP_LOCK" "$EXEC_ONLY"
fi

printf 'Tests finished: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
