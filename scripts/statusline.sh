#!/bin/bash
set -euo pipefail

# ─── ANSI Palette & Layout Constants (Standard 16-color) ─────────────────────
R=$'\033[0m'
B=$'\033[1m'
I=$'\033[3m'

FG_CYAN=$'\033[36m'
FG_WHITE=$'\033[37m'
FG_GRAY=$'\033[90m'
FG_BRIGHT_RED=$'\033[91m'
FG_BRIGHT_GREEN=$'\033[92m'
FG_BRIGHT_YELLOW=$'\033[93m'
FG_BRIGHT_BLUE=$'\033[94m'
FG_BRIGHT_MAGENTA=$'\033[95m'
FG_BRIGHT_CYAN=$'\033[96m'
FG_BRIGHT_WHITE=$'\033[97m'

NUM_COLOR="${FG_BRIGHT_WHITE}${B}"
SEP="${FG_GRAY} │ ${R}"
PAD="  "

# Precomputed bar segments avoid multibyte string slicing (safe under LC_ALL=C).
BAR_FULL_STEPS=(
  "" "█" "██" "███" "████" "█████"
  "██████" "███████" "████████" "█████████" "██████████"
)
BAR_EMPTY_STEPS=(
  "" "░" "░░" "░░░" "░░░░" "░░░░░"
  "░░░░░░" "░░░░░░░" "░░░░░░░░" "░░░░░░░░░" "░░░░░░░░░░"
)

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "${PAD}${FG_BRIGHT_YELLOW}⚠ statusline requires jq${R}"
  exit 0
fi

# Current epoch seconds (zero-fork on Bash 4.2+)
if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
  printf -v NOW_EPOCH '%(%s)T' -1
else
  NOW_EPOCH=$(date +%s 2>/dev/null || printf '0')
fi

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

CACHE_ROOT="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/statusline-hud"
CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/statusline-hud/config.json"

JQ_CFG_ARGS=(--arg cfg_raw "{}" --arg home "${HOME:-}" --arg fallback_pwd "${PWD:-}")
if [ -r "$CONFIG_FILE" ]; then
  JQ_CFG_ARGS=(--rawfile cfg_raw "$CONFIG_FILE" --arg home "${HOME:-}" --arg fallback_pwd "${PWD:-}")
fi

# Shared cleanup for CLI values and Git branch names.
JQ_TEXT_LIB='
  def strip_ansi:
    gsub("\u001b\\[[0-9;?]*[ -/]*[@-~]"; "")
    | gsub("\u001b\\][^\u0007\u001b]*(\u0007|\u001b\\\\)"; "");

  def clean_str:
    if type == "string" then
      strip_ansi | gsub("[\u0000-\u001f\u007f-\u009f]"; "")
    else "" end;

  def clean_title:
    if type == "string" then
      strip_ansi
      | gsub("[\r\n\t]+"; " ")
      | gsub("[\u0000-\u001f\u007f-\u009f]"; "")
      | gsub("  +"; " ") | sub("^ "; "") | sub(" $"; "")
    else "" end;
'

# ─── Parse stdin & config.json (Single jq pass, NUL-delimited KV stream) ─────
row1=(Status Mode Model Context Path Git)
row2=(GeminiQuota 3pQuota)
row3=(Artifacts Subagents Tasks Sandbox Tokens TokenSpeed Cache Duration Cost Title)
HIDDEN=" " NARROW=1
STATE="idle" CONFIRM_PENDING="false" PENDING_INPUT="0" CYCLE_MODE="" VIM_MODE=""
USED_TENTHS=0 CWD="" PATH_TEXT="" VCS_TYPE="" VCS_BRANCH="" VCS_DIRTY="false"
SANDBOX="false" ARTIFACTS=0 SUBAGENT_RUNNING=0 SUBAGENT_TOTAL=0 BG_TASKS=0
MODEL="" TITLE_FMT="" CONV_ID="" TRANSCRIPT_PATH=""
COST_FMT_VAL="" COST_EST="false" TOK_IN=0 TOK_OUT=0 CUR_CACHE_PCT="--"
GEMINI_5H_TENTHS="--" GEMINI_5H_AMT="--" GEMINI_5H_RESET="--"
GEMINI_WEEKLY_TENTHS="--" GEMINI_WEEKLY_AMT="--" GEMINI_WEEKLY_RESET="--"
THIRD_PARTY_5H_TENTHS="--" THIRD_PARTY_5H_AMT="--" THIRD_PARTY_5H_RESET="--"
THIRD_PARTY_WEEKLY_TENTHS="--" THIRD_PARTY_WEEKLY_AMT="--" THIRD_PARTY_WEEKLY_RESET="--"

while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
  printf -v "$_k" '%s' "$_v"
done < <(
  jq -j --arg modules "${row1[*]} ${row2[*]} ${row3[*]}" "${JQ_CFG_ARGS[@]}" "${JQ_TEXT_LIB}"'
    (($cfg_raw | ltrimstr("\ufeff") | fromjson? | objects) // {}) as $cfg |
    def kv($k; $v): "\($k)\u0000\($v)\u0000";
    def switches: if type == "object" then with_entries(select(.value | type == "boolean")) else {} end;

    def is_num: (type == "number") and (isnan | not) and (isinfinite | not);
    # Cap at 1e15 and normalize -0 so jq always emits plain decimal non-negative integers.
    def clean_uint: if is_num and . >= 0 and . <= 1e15 then (floor | if . == 0 then 0 else . end) else 0 end;
    def clamp_pct_tenths:
      if is_num then (if . <= 0 then 0 elif . >= 100 then 1000 else (. * 10 | round) end)
      else 0 end;
    def fmt_tenths: "\(. / 10 | floor).\(. % 10)";
    def fmt_usd:
      if is_num and . >= 0 and . <= 1e12 then
        (. * 100 | round) as $c | "\($c / 100 | floor).\(($c % 100) | tostring | if length == 1 then "0" + . else . end)"
      else "" end;

    def fmt_cwd($max_levels):
      if . == "" then ""
      else
        ($home | sub("/+$"; "")) as $h
        | (if ($h != "" and (. == $h or startswith($h + "/"))) then
             {prefix: "~/", rel: .[($h | length):]}
           elif startswith("/") then
             {prefix: "/", rel: .[1:]}
           else
             {prefix: "", rel: .}
           end) as $p
        | ($p.rel | split("/") | map(select(length > 0))) as $segs
        | ($segs | length) as $n
        | if $n == 0 then
            if $p.prefix == "/" then "/" else ($p.prefix | sub("/$"; "")) end
          elif $n > $max_levels then
            "…/" + ($segs[$n - $max_levels:] | join("/"))
          else
            $p.prefix + ($segs | join("/"))
          end
      end;

    def reset_in:
      if (is_num | not) then "--"
      else ((. / 60 | ceil) | if . <= 0 then 0 else . end) as $m
        | if $m >= 1440 then "\(($m / 1440 | floor))d\((($m % 1440) / 60 | floor))h"
          elif $m >= 60 then "\(($m / 60 | floor))h\($m % 60)m"
          else "\($m)m" end
      end;

    def quota($prefix; $key):
      ((.quota?[$key]? | objects | select(.disabled != true)) // {}) as $q
      | (if ($q.remaining_fraction | is_num) then
           $q.remaining_fraction | if . <= 0 then 1000 elif . >= 1 then 0 else ((1 - .) * 1000 | round) end
         else "--" end) as $tenths
      | (if $tenths == "--" and ($q.remaining_amount | is_num) then
           ($q.remaining_amount | clean_uint)
         else "--" end) as $amt
      | kv($prefix + "_TENTHS"; $tenths) + kv($prefix + "_AMT"; $amt)
        + kv($prefix + "_RESET"; ($q.reset_in_seconds | reset_in));

    def cur_cache_pct:
      (.context_window?.current_usage? // null) as $cu
      | if ($cu | type) == "object" and ($cu.cache_read_input_tokens? | is_num) then
          (($cu.input_tokens? | clean_uint)
            + ($cu.cache_read_input_tokens? | clean_uint)
            + ($cu.cache_creation_input_tokens? | clean_uint)) as $tot
          | if $tot > 0 then
              (($cu.cache_read_input_tokens | clean_uint) * 1000 / $tot | round) | fmt_tenths
            else "--" end
        else "--" end;

    ((.terminal_width? | clean_uint) < 100) as $narrow
    | (($cfg | switches) + (if $narrow then ($cfg.narrow | switches) else {} end)) as $opts
    | ((.workspace?.current_dir? // .cwd? // "") | clean_str | if . == "" then ($fallback_pwd | clean_str) else . end) as $cwd
    | kv("NARROW"; (if $narrow then 1 else 0 end))
    + kv("HIDDEN"; " " + ($modules | split(" ") | map(select(. != "Status" and $opts["show" + .] == false)) | join(" ")) + " ")
    + kv("STATE"; ((.agent_state // "idle") | tostring | clean_str | if . == "" then "idle" else . end))
    + kv("CONFIRM_PENDING"; (.tool_confirmation_pending? == true))
    + kv("PENDING_INPUT"; (.pending_input_count? | clean_uint))
    + kv("CYCLE_MODE"; (.cycle_mode? | clean_str))
    + kv("VIM_MODE"; (.vim?.mode? | clean_str))
    + kv("USED_TENTHS"; (.context_window?.used_percentage? | clamp_pct_tenths))
    + kv("CWD"; $cwd)
    + kv("PATH_TEXT"; ($cwd | fmt_cwd(if $narrow then 1 else 2 end)))
    + kv("VCS_TYPE"; (.vcs?.type? | clean_str))
    + kv("VCS_BRANCH"; ((.vcs?.branch? // .workspace?.vcs?.branch? // "") | clean_str))
    + kv("VCS_DIRTY"; ((.vcs?.dirty? // .workspace?.vcs?.dirty? // false) == true))
    + kv("SANDBOX"; ([(.sandbox?.enabled?, .workspace?.sandbox?.enabled?) | booleans][0] // false))
    + kv("ARTIFACTS"; (.artifact_count? | clean_uint))
    + kv("SUBAGENT_RUNNING"; (if (.subagents | type) == "array"
        then ([.subagents[] | select(type == "object" and .status == "running")] | length) else 0 end))
    + kv("SUBAGENT_TOTAL"; (if (.subagents | type) == "array" then (.subagents | length) else 0 end))
    + kv("BG_TASKS"; (.task_count? | clean_uint))
    + kv("MODEL"; ((.model?.display_name? // .model?.id? // "") | clean_str))
    + kv("TITLE_FMT"; (.conversation_title? | clean_title))
    + kv("CONV_ID"; ((.conversation_id? // .session_id? // "") | clean_str))
    + kv("TRANSCRIPT_PATH"; (.transcript_path? | clean_str))
    + kv("COST_FMT_VAL"; ((.cost?.total_usd? // .cost?.total_cost_usd?) | fmt_usd))
    + kv("COST_EST"; (.cost?.estimated? == true))
    + kv("TOK_IN"; (.context_window?.total_input_tokens? | clean_uint))
    + kv("TOK_OUT"; (.context_window?.total_output_tokens? | clean_uint))
    + kv("CUR_CACHE_PCT"; cur_cache_pct)
    + quota("GEMINI_5H"; "gemini-5h")
    + quota("GEMINI_WEEKLY"; "gemini-weekly")
    + quota("THIRD_PARTY_5H"; "3p-5h")
    + quota("THIRD_PARTY_WEEKLY"; "3p-weekly")
  ' 2>/dev/null
)

# ─── Helpers (Outvar pattern avoids subshell forks) ──────────────────────────
is_uints() {
  local v
  for v in "$@"; do
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
  done
}

visible() { [[ "$HIDDEN" != *" $1 "* ]]; }

print_row() {
  local key var line=""
  for key in "$@"; do
    visible "$key" || continue
    var="part$key"
    [ -n "${!var}" ] || continue
    line="${line}${line:+$SEP}${!var}"
  done
  if [ -n "$line" ]; then printf '%s\n' "${PAD}${line}"; fi
}

fmt_tokens() {
  local _out="$1" n="$2"
  if [ "$n" -ge 1000000 ]; then
    local tenths=$(( (n + 50000) / 100000 ))
    printf -v "$_out" '%s.%sM' "$((tenths / 10))" "$((tenths % 10))"
  elif [ "$n" -ge 1000 ]; then
    printf -v "$_out" '%sk' "$(( (n + 500) / 1000 ))"
  else
    printf -v "$_out" '%s' "$n"
  fi
}

fmt_duration() {
  local _out="$1" mins=$(( $2 / 60 ))
  if [ "$mins" -ge 1440 ]; then
    printf -v "$_out" '%sd%sh' "$((mins / 1440))" "$(((mins % 1440) / 60))"
  elif [ "$mins" -ge 60 ]; then
    printf -v "$_out" '%sh%sm' "$((mins / 60))" "$((mins % 60))"
  else
    printf -v "$_out" '%sm' "$mins"
  fi
}

fmt_metric() {
  printf -v "$1" '%s' "${FG_GRAY}$2 ${NUM_COLOR}$3${R}"
}

usage_bar() {
  local out="$1" tenths="$2" color="$FG_BRIGHT_GREEN" bar="" filled
  if [ "$tenths" -ge 900 ]; then color="$FG_BRIGHT_RED"
  elif [ "$tenths" -ge 600 ]; then color="$FG_BRIGHT_YELLOW"; fi
  if [ "$NARROW" -eq 0 ]; then
    filled=$(( (tenths + 50) / 100 ))
    bar="${color}${BAR_FULL_STEPS[filled]}${FG_GRAY}${BAR_EMPTY_STEPS[10-filled]} "
  fi
  printf -v "$out" '%s' "${bar}${color}$((tenths / 10)).$((tenths % 10))%${R}"
}

format_quota_item() {
  local out="$1" value=""
  if [ "$2" != "--" ]; then usage_bar value "$2"
  elif [ "$3" != "--" ]; then value="${NUM_COLOR}$3 left${R}"
  fi
  if [ -n "$value" ] && [ "$NARROW" -eq 0 ] && [ "$4" != "--" ]; then
    value+=" ${FG_GRAY}$4${R}"
  fi
  printf -v "$out" '%s' "$value"
}

format_quota_pair() {
  local out="$1" label="$2" five="" week="" pair="" week_label="week"
  [ "$NARROW" -eq 0 ] || week_label="wk"
  format_quota_item five "$3" "$4" "$5"
  format_quota_item week "$6" "$7" "$8"
  [ -z "$five" ] || pair="5h $five"
  [ -z "$week" ] || pair+="${pair:+${FG_GRAY} / }${week_label} $week"
  if [ -n "$pair" ]; then printf -v "$out" '%s' "${FG_GRAY}${label} ${pair}${R}"; fi
}

maybe_gc_cache() {
  local gc_stamp="${CACHE_ROOT}/.last_gc" last_gc=""
  if [ -r "$gc_stamp" ]; then
    read -r last_gc < "$gc_stamp" || true
  fi
  if is_uints "$last_gc" && [ $((NOW_EPOCH - last_gc)) -lt 86400 ] && [ $((NOW_EPOCH - last_gc)) -ge 0 ]; then
    return 0
  fi
  if [ -d "$CACHE_ROOT" ] || mkdir -p "$CACHE_ROOT" 2>/dev/null; then
    printf '%s\n' "$NOW_EPOCH" > "$gc_stamp" 2>/dev/null || true
    find "$CACHE_ROOT" -type f \( -name '*.cache' -o -name '*.tmp.*' \) -mtime +7 -delete 2>/dev/null || true
  fi
}

write_cache_file() {
  local dir="$1" file="$2" content="$3"
  if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
    printf '%s\n' "$content" > "${file}.tmp.$$" 2>/dev/null \
      && mv -f "${file}.tmp.$$" "$file" 2>/dev/null \
      || rm -f "${file}.tmp.$$" 2>/dev/null || true
    maybe_gc_cache
  fi
}

has_git_dir() {
  [ -n "${GIT_DIR:-}" ] && return 0
  local dir="${1%/}"
  [ -n "$dir" ] || dir="/"
  while :; do
    [ -e "$dir/.git" ] && return 0
    [ "$dir" = "/" ] && return 1
    [[ "$dir" == */* ]] || return 1
    dir="${dir%/*}"
    [ -n "$dir" ] || dir="/"
  done
}

git_cache_key() {
  local _out="$1" cwd="$2" key
  key="${cwd//_/_u}"
  key="${key//\//_s}"
  key="${key//[^A-Za-z0-9._-]/_x}"
  if [ "${#key}" -gt 160 ]; then
    local cksum_out
    cksum_out=$(printf '%s' "$cwd" | cksum 2>/dev/null || printf '0 0')
    key="h_${cksum_out// /_}"
  fi
  printf -v "$_out" '%s' "$key"
}

run_git() {
  local cwd="$1"
  shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" 2 git -C "$cwd" --no-optional-locks "$@" 2>/dev/null || true
  else
    git -C "$cwd" --no-optional-locks "$@" 2>/dev/null || true
  fi
}

run_git_diff_numstat() {
  local cwd="$1" oid="$2" base="HEAD"
  if [ -z "$oid" ] || [ "$oid" = "(initial)" ]; then
    base=$(run_git "$cwd" hash-object -t tree /dev/null)
    [ -n "$base" ] || return 0
  fi
  run_git "$cwd" -c diff.relative=false diff "$base" --numstat
}

parse_git_status() {
  local cwd="$1"
  if [ -n "$VCS_TYPE" ] && [ "$VCS_TYPE" != "git" ]; then
    return 0
  fi
  [ -d "$cwd" ] || return 0
  has_git_dir "$cwd" || return 0

  local gkey="" gdir="${CACHE_ROOT}/git" gfile=""
  local c_ver="" c_ts="" c_dirty="" c_a="" c_b="" c_flags="" c_ins="" c_del="" c_branch=""
  git_cache_key gkey "$cwd"
  gfile="${gdir}/${gkey}.cache"

  if [ -r "$gfile" ]; then
    IFS=$'\t' read -r c_ver c_ts c_dirty c_a c_b c_flags c_ins c_del c_branch < "$gfile" || true
    if [ "$c_ver" = "v2" ] \
      && is_uints "$c_ts" "$c_a" "$c_b" "$c_ins" "$c_del" \
      && [[ "$c_flags" =~ ^(-|[csmdrut]+)$ ]] \
      && [ $((NOW_EPOCH - c_ts)) -ge 0 ] && [ $((NOW_EPOCH - c_ts)) -le 2 ]; then
      if [ -z "$VCS_BRANCH" ]; then VCS_BRANCH="$c_branch"; fi
      if [ "$c_dirty" = "true" ]; then VCS_DIRTY="true"; fi
      GIT_AHEAD="$c_a" GIT_BEHIND="$c_b"
      GIT_FLAGS=""
      [ "$c_flags" = "-" ] || GIT_FLAGS="$c_flags"
      GIT_INS="$c_ins" GIT_DEL_LINES="$c_del"
      return 0
    fi
  fi

  local _line _oid="" _head="" _ab="" _a="" _b="" _x="" _y="" _stash=""
  local g_branch="" g_dirty="false" g_has_tracked=0
  local g_c=0 g_s=0 g_m=0 g_d=0 g_r=0 g_u=0 g_t=0
  while IFS= read -r _line; do
    case "$_line" in
      "# branch.oid "*)
        _oid="${_line#\# branch.oid }"
        ;;
      "# branch.head "*)
        _head="${_line#\# branch.head }"
        if [ "$_head" = "(detached)" ]; then
          if [ -n "$_oid" ] && [ "$_oid" != "(initial)" ]; then
            _head="${_oid:0:7}"
          else
            _head="detached"
          fi
        fi
        g_branch="$_head"
        ;;
      "# branch.ab "*)
        _ab="${_line#\# branch.ab }"
        _a="${_ab%% *}"
        _b="${_ab##* }"
        GIT_AHEAD="${_a#+}"
        GIT_BEHIND="${_b#-}"
        ;;
      "# stash "*)
        _stash="${_line#\# stash }"
        if is_uints "$_stash" && [ "$_stash" -gt 0 ]; then g_t=1; fi
        ;;
      "1 "*)
        g_has_tracked=1
        _x="${_line:2:1}"
        _y="${_line:3:1}"
        case "$_x" in
          A|M|T) g_s=1 ;;
          D)     g_d=1 ;;
        esac
        case "$_y" in
          A|M|T) g_m=1 ;;
          D)     g_d=1 ;;
        esac
        ;;
      "2 "*)
        g_has_tracked=1
        _x="${_line:2:1}"
        _y="${_line:3:1}"
        case "$_x" in
          R) g_r=1 ;;
          C) g_s=1 ;;
        esac
        case "$_y" in
          M|T) g_m=1 ;;
          D)   g_d=1 ;;
        esac
        ;;
      "u "*)
        g_has_tracked=1
        g_c=1
        ;;
      "? "*)
        g_u=1
        ;;
    esac
  done < <(run_git "$cwd" status --porcelain=v2 --branch --show-stash)

  if (( g_has_tracked || g_u )); then g_dirty="true"; fi
  if [ "$g_has_tracked" -eq 1 ]; then
    local _ins="" _del="" _rest=""
    while IFS=$'\t' read -r _ins _del _rest; do
      if is_uints "$_ins" "$_del"; then
        GIT_INS=$((GIT_INS + _ins))
        GIT_DEL_LINES=$((GIT_DEL_LINES + _del))
      fi
    done < <(run_git_diff_numstat "$cwd" "$_oid")
  fi

  if [[ "$g_branch" == *$'\033'* ]] || [[ "$g_branch" =~ [[:cntrl:]] ]]; then
    g_branch=$(jq -nr --arg s "$g_branch" "${JQ_TEXT_LIB}"'$s | clean_str' 2>/dev/null || printf '%s' "$g_branch" | tr -d '\000-\037\177')
  fi

  is_uints "$GIT_AHEAD" || GIT_AHEAD=0
  is_uints "$GIT_BEHIND" || GIT_BEHIND=0
  GIT_FLAGS=""
  [ "$g_c" -eq 0 ] || GIT_FLAGS+="c"
  [ "$g_s" -eq 0 ] || GIT_FLAGS+="s"
  [ "$g_m" -eq 0 ] || GIT_FLAGS+="m"
  [ "$g_d" -eq 0 ] || GIT_FLAGS+="d"
  [ "$g_r" -eq 0 ] || GIT_FLAGS+="r"
  [ "$g_u" -eq 0 ] || GIT_FLAGS+="u"
  [ "$g_t" -eq 0 ] || GIT_FLAGS+="t"
  if [ -z "$VCS_BRANCH" ]; then VCS_BRANCH="$g_branch"; fi
  if [ "$g_dirty" = "true" ]; then VCS_DIRTY="true"; fi

  local _cache_row="" _c_flags="${GIT_FLAGS:--}"
  printf -v _cache_row 'v2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$NOW_EPOCH" "$g_dirty" "$GIT_AHEAD" "$GIT_BEHIND" \
    "$_c_flags" "$GIT_INS" "$GIT_DEL_LINES" "$g_branch"
  write_cache_file "$gdir" "$gfile" "$_cache_row"
}

load_session_tokens() {
  local valid_conv_id=0 tpath=""
  [[ "$CONV_ID" =~ ^[A-Za-z0-9._-]+$ ]] && valid_conv_id=1

  if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    tpath="$TRANSCRIPT_PATH"
  elif [ "$valid_conv_id" -eq 1 ] && [ -n "${HOME:-}" ]; then
    local alt="${HOME}/.gemini/antigravity-cli/brain/${CONV_ID}/.system_generated/logs/transcript.jsonl"
    [ -r "$alt" ] && tpath="$alt"
  fi
  [ -n "$tpath" ] || return 0

  local cache_dir="${CACHE_ROOT}/transcript" cache_file="" mtime="" size="" cache_hit=0
  local c_mtime="" c_size="" s_in="" s_out="" session_pct="" first_ts="0" tok_speed="0"
  local stat_info=""

  case "${OSTYPE:-}" in
    darwin*|*bsd*) stat_info=$(stat -f '%m %z' "$tpath" 2>/dev/null) || true ;;
    *)             stat_info=$(stat -c '%Y %s' "$tpath" 2>/dev/null) || true ;;
  esac
  if [[ "$stat_info" == *" "* ]]; then
    mtime="${stat_info%% *}"
    size="${stat_info#* }"
  fi

  if [ "$valid_conv_id" -eq 1 ] && is_uints "$mtime" "$size"; then
    cache_file="${cache_dir}/${CONV_ID}.cache"
    if [ -r "$cache_file" ]; then
      read -r c_mtime c_size s_in s_out session_pct first_ts tok_speed < "$cache_file" || true
      if [ "$c_mtime" = "$mtime" ] && [ "$c_size" = "$size" ] \
        && is_uints "$first_ts" "$tok_speed" && { is_uints "$s_in" "$s_out" || [ "$s_in:$s_out" = '--:--' ]; } \
        && [[ "$session_pct" =~ ^(--|[0-9]+\.[0-9])$ ]]; then
        cache_hit=1
      fi
    fi
  fi

  if [ "$cache_hit" -eq 0 ]; then
    is_uints "$mtime" || mtime=0
    local parsed=""
    parsed=$(
      jq -n -R -r --argjson mtime "$mtime" '
        def parse_ts: (strings | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? | select(. > 0)) // 0;
        def finite_pos: (type == "number") and (isnan | not) and (isinfinite | not) and . > 0;
        def reset_turn: .turn_start = 0 | .turn_out = 0 | .turn_ended = false;
        # Rewind can reuse a step_index; all model calls still consumed tokens,
        # while a finished turn, USER_INPUT, or strict step_index drop resets turn speed.
        reduce (inputs | fromjson? | objects) as $x (
          ({first_ts: 0, last_step: null, total_in: null, total_out: null, cache_read: 0, missing_cache: false} | reset_turn);
          (if .first_ts == 0 then .first_ts = ($x.created_at? | parse_ts) else . end)
          | (if ($x.step_index? | type) == "number" then $x.step_index else null end) as $step
          | (if .turn_ended or ($x.type? == "USER_INPUT")
                or ($step != null and .last_step != null and $step < .last_step) then reset_turn else . end)
          | (if $step != null then .last_step = $step else . end)
          | if ($x.type? == "PLANNER_RESPONSE") then
              (if any($x | .input_tokens, .output_tokens, .cache_read_tokens, .cache_creation_tokens, .cache_creation_input_tokens; type == "number") then
                 (($x.input_tokens // 0) + ($x.cache_read_tokens // 0)
                   + ($x.cache_creation_tokens // $x.cache_creation_input_tokens // 0)) as $input
                 | .total_in += $input
                 | .total_out += ($x.output_tokens // 0)
                 | .cache_read += ($x.cache_read_tokens // 0)
                 | if $input > 0 and $x.cache_read_tokens == null then .missing_cache = true else . end
               else . end)
              | (if .turn_start == 0 then .turn_start = ($x.created_at? | parse_ts) else . end)
              | (if ($x.output_tokens? | finite_pos) then .turn_out += $x.output_tokens else . end)
              | .turn_ended = (
                  ((($x.tool_calls? | type) == "array" and ($x.tool_calls | length) > 0)
                   or (($x.truncated_fields? | type) == "array" and ($x.truncated_fields | index("tool_calls") != null)))
                  | not)
            else . end
        )
        | [.total_in // "--", .total_out // "--",
           (if .total_in > 0 and (.missing_cache | not) then
              (.cache_read * 1000 / .total_in | round) as $t
              | "\($t / 10 | floor).\($t % 10)"
            else "--" end),
           .first_ts,
           (if .turn_out > 0 and .turn_start > 0 and $mtime > .turn_start then
              (.turn_out / ($mtime - .turn_start) | round)
            else 0 end)] | @tsv
      ' < "$tpath" 2>/dev/null
    ) || true
    read -r s_in s_out session_pct first_ts tok_speed <<< "$parsed" || true
    is_uints "$s_in" "$s_out" || [ "$s_in:$s_out" = '--:--' ] || return 0
    is_uints "$first_ts" || first_ts=0
    is_uints "$tok_speed" || tok_speed=0

    if [ -n "$cache_file" ]; then
      write_cache_file "$cache_dir" "$cache_file" "${mtime} ${size} ${s_in} ${s_out} ${session_pct} ${first_ts} ${tok_speed}"
    fi
  fi

  if [ "$session_pct" != "--" ]; then
    SESSION_CACHE_PCT="$session_pct"
  fi
  if [ "$first_ts" -gt 0 ]; then
    SESSION_FIRST_TS="$first_ts"
  fi
  SESSION_TOK_SPEED="$tok_speed"
  if [ "$s_in" != '--' ]; then
    DISP_IN="$s_in"
    DISP_OUT="$s_out"
  fi
}

# ─── Line 1: State, Mode, Model, Context, CWD, VCS ───────────────────────────
if [ "$CONFIRM_PENDING" = "true" ]; then
  partStatus="${FG_BRIGHT_YELLOW}${B}⚠ CONFIRM${R}"
else
  case "$STATE" in
    idle)           partStatus="${FG_BRIGHT_GREEN}${B}● READY${R}" ;;
    working)        partStatus="${FG_BRIGHT_CYAN}${B}⚙ WORKING${R}" ;;
    tool_use)       partStatus="${FG_BRIGHT_MAGENTA}${B}🔧 TOOL${R}" ;;
    reviewing)      partStatus="${FG_BRIGHT_YELLOW}${B}◈ REVIEW${R}" ;;
    error)          partStatus="${FG_BRIGHT_RED}${B}✖ ERROR${R}" ;;
    thinking)       partStatus="${FG_BRIGHT_YELLOW}${B}◆ THINKING${R}" ;;
    authenticating) partStatus="${FG_WHITE}${B}⏳ AUTH${R}" ;;
    initializing)   partStatus="${FG_WHITE}${B}⏳ INIT${R}" ;;
    *)
      _state_up=$(printf '%s' "$STATE" | tr '[:lower:]' '[:upper:]')
      partStatus="${FG_WHITE}${B}⏳ ${_state_up}${R}"
      ;;
  esac
fi
if [ "$PENDING_INPUT" -gt 0 ]; then
  partStatus="${partStatus} ${FG_BRIGHT_YELLOW}(+${PENDING_INPUT})${R}"
fi
partMode=""
if visible Mode; then
  case "$CYCLE_MODE" in
    plan)         partMode="${FG_BRIGHT_BLUE}${B}PLAN${R}" ;;
    accept-edits) partMode="${FG_BRIGHT_YELLOW}${B}EDITS${R}" ;;
    auto)         partMode="${FG_BRIGHT_RED}${B}AUTO${R}" ;;
    "")           partMode="" ;;
    *)
      _mode_up=$(printf '%s' "$CYCLE_MODE" | tr '[:lower:]' '[:upper:]')
      partMode="${FG_WHITE}${B}${_mode_up}${R}"
      ;;
  esac
  if [ -n "$VIM_MODE" ]; then
    case "$VIM_MODE" in
      NORMAL)        _vim_tag="N" ;;
      INSERT)        _vim_tag="I" ;;
      VISUAL)        _vim_tag="V" ;;
      "VISUAL LINE") _vim_tag="VL" ;;
      *)             _vim_tag="$VIM_MODE" ;;
    esac
    partMode+="${partMode:+ }${FG_BRIGHT_CYAN}[${_vim_tag}]${R}"
  fi
fi

partModel="" partContext="" partPath="" partGit=""
[ -z "$MODEL" ] || partModel="${FG_BRIGHT_MAGENTA}${I}${MODEL}${R}"
[ -z "$PATH_TEXT" ] || partPath="${FG_CYAN}${PATH_TEXT}${R}"
usage_bar partContext "$USED_TENTHS"
partContext="${FG_GRAY}ctx ${partContext}"

GIT_AHEAD=0 GIT_BEHIND=0 GIT_FLAGS="" GIT_INS=0 GIT_DEL_LINES=0
if visible Git; then
  if [ -n "$CWD" ] && command -v git >/dev/null 2>&1; then parse_git_status "$CWD"; fi
  if [ -n "$VCS_BRANCH" ]; then
    if [ "$VCS_DIRTY" = true ]; then partGit="${FG_BRIGHT_RED}${VCS_BRANCH}"
    else partGit="${FG_BRIGHT_BLUE}${VCS_BRANCH}"; fi
    if [ "$NARROW" -eq 0 ]; then
      _git_status=""
      [[ "$GIT_FLAGS" != *c* ]] || _git_status+="${FG_BRIGHT_RED}="
      [[ "$GIT_FLAGS" != *s* ]] || _git_status+="${FG_BRIGHT_GREEN}+"
      [[ "$GIT_FLAGS" != *m* ]] || _git_status+="${FG_BRIGHT_YELLOW}!"
      [[ "$GIT_FLAGS" != *d* ]] || _git_status+="${FG_BRIGHT_RED}✘"
      [[ "$GIT_FLAGS" != *r* ]] || _git_status+="${FG_BRIGHT_MAGENTA}»"
      [[ "$GIT_FLAGS" != *u* ]] || _git_status+="${FG_GRAY}?"
      [[ "$GIT_FLAGS" != *t* ]] || _git_status+="${FG_BRIGHT_CYAN}\$"
      [ "$GIT_AHEAD" -eq 0 ] || _git_status+="${FG_BRIGHT_CYAN}↑${GIT_AHEAD}"
      [ "$GIT_BEHIND" -eq 0 ] || _git_status+="${FG_BRIGHT_CYAN}↓${GIT_BEHIND}"
      if [ -n "$_git_status" ]; then
        partGit+=" ${FG_GRAY}[${_git_status}${FG_GRAY}]"
      elif [ "$VCS_DIRTY" = true ]; then
        partGit+="${FG_BRIGHT_YELLOW}*"
      fi
      _git_diff=""
      [ "$GIT_INS" -eq 0 ] || _git_diff+="${FG_BRIGHT_GREEN}+${GIT_INS}"
      [ "$GIT_DEL_LINES" -eq 0 ] || _git_diff+="${_git_diff:+ }${FG_BRIGHT_RED}−${GIT_DEL_LINES}"
      [ -z "$_git_diff" ] || partGit+=" ${FG_GRAY}(${_git_diff}${FG_GRAY})"
    elif [ "$VCS_DIRTY" = true ]; then
      partGit+="${FG_BRIGHT_YELLOW}*"
    fi
    partGit+="$R"
  fi
fi

partGeminiQuota="" part3pQuota=""
format_quota_pair partGeminiQuota Gemini "$GEMINI_5H_TENTHS" "$GEMINI_5H_AMT" "$GEMINI_5H_RESET" \
  "$GEMINI_WEEKLY_TENTHS" "$GEMINI_WEEKLY_AMT" "$GEMINI_WEEKLY_RESET"
format_quota_pair part3pQuota 3P "$THIRD_PARTY_5H_TENTHS" "$THIRD_PARTY_5H_AMT" "$THIRD_PARTY_5H_RESET" \
  "$THIRD_PARTY_WEEKLY_TENTHS" "$THIRD_PARTY_WEEKLY_AMT" "$THIRD_PARTY_WEEKLY_RESET"

partTitle=""
fmt_metric partArtifacts artifacts "$ARTIFACTS"
fmt_metric partSubagents subagents "$SUBAGENT_RUNNING/$SUBAGENT_TOTAL"
fmt_metric partTasks tasks "$BG_TASKS"
if [ "$SANDBOX" = "true" ]; then
  partSandbox="${FG_GRAY}sandbox ${FG_BRIGHT_GREEN}${B}ON${R}"
else
  partSandbox="${FG_GRAY}sandbox OFF${R}"
fi
[ -z "$TITLE_FMT" ] || partTitle="${FG_GRAY}▸ ${FG_WHITE}${TITLE_FMT}${R}"

partCache="" partCost=""
SESSION_CACHE_PCT="$CUR_CACHE_PCT" SESSION_FIRST_TS=0 SESSION_TOK_SPEED=0 DISP_IN="$TOK_IN" DISP_OUT="$TOK_OUT"
if visible Tokens || visible TokenSpeed || visible Cache || visible Duration; then load_session_tokens; fi
fmt_tokens total "$(( DISP_IN + DISP_OUT ))"
fmt_metric partTokens tok "$total"
if [ "$NARROW" -eq 0 ]; then
  fmt_tokens input "$DISP_IN"
  fmt_tokens output "$DISP_OUT"
  partTokens+=" ${FG_GRAY}(${input}↑ ${output}↓)${R}"
fi
partTokenSpeed="${NUM_COLOR}${SESSION_TOK_SPEED}${R}${FG_GRAY} tok/s${R}"
[ "$SESSION_CACHE_PCT" = "--" ] || fmt_metric partCache cache "${SESSION_CACHE_PCT}%"
if [ "$SESSION_FIRST_TS" -gt 0 ] && [ "$NOW_EPOCH" -ge "$SESSION_FIRST_TS" ]; then
  fmt_duration partDuration "$((NOW_EPOCH - SESSION_FIRST_TS))"
else
  partDuration="0m"
fi
partDuration="${FG_GRAY}${partDuration}${R}"
if [ -n "$COST_FMT_VAL" ]; then
  prefix='$'
  [ "$COST_EST" != true ] || prefix='~$'
  partCost="${FG_BRIGHT_YELLOW}${prefix}${COST_FMT_VAL}${R}"
fi

print_row "${row1[@]}"
print_row "${row2[@]}"
print_row "${row3[@]}"
