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

# Shared jq helpers for ANSI/control stripping and Unicode terminal cell widths.
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

  # Approximate terminal cell width for Unicode codepoints (CJK / fullwidth / wide emoji).
  def cp_w:
    if (. < 32) or (. >= 127 and . < 160) then 0
    elif (. >= 768 and . <= 879)
      or (. >= 8203 and . <= 8207)
      or (. >= 65024 and . <= 65039)
    then 0
    elif (. >= 4352 and . <= 4447)
      or (. == 8986 or . == 8987)
      or (. == 9001 or . == 9002)
      or (. >= 9193 and . <= 9196)
      or (. == 9200 or . == 9203)
      or (. == 9725 or . == 9726)
      or (. == 9748 or . == 9749)
      or (. >= 9800 and . <= 9811)
      or (. == 9855 or . == 9875 or . == 9889 or . == 9898 or . == 9899)
      or (. == 9917 or . == 9918 or . == 9924 or . == 9925 or . == 9934 or . == 9940)
      or (. == 9962 or . == 9970 or . == 9971 or . == 9973 or . == 9978 or . == 9981)
      or (. == 9989 or . == 9994 or . == 9995 or . == 10024 or . == 10060 or . == 10062)
      or (. >= 10067 and . <= 10069)
      or (. == 10071)
      or (. >= 10133 and . <= 10135)
      or (. == 10160 or . == 10175)
      or (. == 11035 or . == 11036 or . == 11088 or . == 11093)
      or (. >= 11904 and . <= 12350)
      or (. >= 12352 and . <= 42191)
      or (. >= 44032 and . <= 55203)
      or (. >= 63744 and . <= 64255)
      or (. >= 65040 and . <= 65135)
      or (. >= 65280 and . <= 65376)
      or (. >= 65504 and . <= 65510)
      or (. >= 127744 and . <= 129791)
      or (. >= 131072 and . <= 262141)
    then 2
    else 1 end;

  def disp_w:
    explode | reduce .[] as $c (0; . + ($c | cp_w));

  def trunc_w($max):
    if $max <= 0 then ""
    elif disp_w <= $max then .
    elif $max == 1 then "…"
    else
      (reduce (explode[]) as $c (
        {cps: [], w: 0, done: false};
        if .done then .
        else
          ($c | cp_w) as $cw
          | if (.w + $cw) <= ($max - 1) then
              .cps += [$c] | .w += $cw
            else
              .done = true
            end
        end
      ) | .cps | implode) + "…"
    end;
'

# ─── Parse stdin & config.json (Single jq pass, NUL-delimited KV stream) ─────
# Single source of truth for config defaults; jq emits CFG_* only on valid overrides.
CFG_PRESET="standard"
CFG_SHOW_TITLE="0" CFG_SHOW_MODE="1" CFG_SHOW_PATH="1" CFG_SHOW_GIT="1"
CFG_SHOW_QUOTA="1" CFG_SHOW_3P_QUOTA="1" CFG_SHOW_ACTIVITY="1" CFG_SHOW_SANDBOX_OFF="0"
CFG_SHOW_TOKENS="1" CFG_SHOW_CACHE="1" CFG_SHOW_DURATION="1" CFG_SHOW_COST="1"

STATE="idle" CONFIRM_PENDING="false" PENDING_INPUT="0"
CYCLE_MODE="" VIM_MODE=""
USED_TENTHS="0" CWD=""
CWD_L2="" CWD_L2_W="0" CWD_L1="" CWD_L1_W="0" CWD_SHORT="" CWD_SHORT_W="0"
VCS_TYPE="" VCS_BRANCH="" VCS_DIRTY="false" SANDBOX="false"
ARTIFACTS="0" SUBAGENT_RUNNING="0" SUBAGENT_TOTAL="0" BG_TASKS="0"
MODEL="" MODEL_W="0" MODEL_SHORT="" MODEL_SHORT_W="0"
TITLE_FMT="" COLS="80" CONV_ID="" TRANSCRIPT_PATH=""
COST_FMT_VAL="" COST_EST="false" TOK_IN="0" TOK_OUT="0" CUR_CACHE_PCT="--"
GEMINI_5H_TENTHS="--" GEMINI_5H_AMT="--" GEMINI_5H_RESET="--"
GEMINI_WEEKLY_TENTHS="--" GEMINI_WEEKLY_AMT="--" GEMINI_WEEKLY_RESET="--"
THIRD_PARTY_5H_TENTHS="--" THIRD_PARTY_5H_AMT="--" THIRD_PARTY_5H_RESET="--"
THIRD_PARTY_WEEKLY_TENTHS="--" THIRD_PARTY_WEEKLY_AMT="--" THIRD_PARTY_WEEKLY_RESET="--"

while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
  printf -v "$_k" '%s' "$_v"
done < <(
  jq -j "${JQ_CFG_ARGS[@]}" "${JQ_TEXT_LIB}"'
    (($cfg_raw | fromjson? | objects) // {}) as $cfg |
    def kv($k; $v): "\($k)\u0000\($v)\u0000";
    def cfg_bool($var; $k):
      if ($cfg[$k] | type) == "boolean" then kv($var; (if $cfg[$k] then 1 else 0 end))
      else "" end;
    def cfg_preset:
      ($cfg.preset? // "") as $p
      | if ($p == "standard" or $p == "compact" or $p == "minimal") then kv("CFG_PRESET"; $p)
        else "" end;

    def is_num: (type == "number") and (isnan | not) and (isinfinite | not);
    # Cap at 1e15 and normalize -0 so jq always emits plain decimal non-negative integers.
    def clean_uint: if is_num and . >= 0 and . <= 1e15 then (floor | if . == 0 then 0 else . end) else 0 end;
    def clamp_pct_tenths:
      if is_num then (if . <= 0 then 0 elif . >= 100 then 1000 else (. * 10 | round) end)
      else 0 end;
    def fmt_tenths: "\(. / 10 | floor).\(. % 10)";
    def fmt_usd:
      if is_num and . > 0 and . <= 1e12 then
        (. * 100 | round) as $c
        | if $c > 0 then "\($c / 100 | floor).\(($c % 100) | tostring | if length == 1 then "0" + . else . end)"
          else "" end
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

    def quota($pk; $ak; $rk; $key):
      (.quota?[$key]? // null) as $q
      | if ($q | type) != "object" or ($q.disabled? == true) then
          kv($pk; "--") + kv($ak; "--") + kv($rk; "--")
        else
          (if ($q.remaining_fraction? | is_num) then
             $q.remaining_fraction | if . <= 0 then 1000 elif . >= 1 then 0 else ((1 - .) * 1000 | round) end
           else "--" end) as $tenths
          | (if $tenths == "--" and ($q.remaining_amount? | is_num) then
               ($q.remaining_amount | clean_uint)
             else "--" end) as $amt
          | kv($pk; $tenths) + kv($ak; $amt) + kv($rk; ($q.reset_in_seconds? | reset_in))
        end;

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

    ((.terminal_width? | clean_uint) | if . < 20 then 80 else . end) as $cols
    | ((.workspace?.current_dir? // .cwd? // "") | clean_str | if . == "" then $fallback_pwd else . end) as $cwd
    | ($cwd | fmt_cwd(2)) as $cwd2
    | ($cwd | fmt_cwd(1)) as $cwd1
    | ($cwd1 | trunc_w(20)) as $cwds
    | ((.model?.display_name? // .model?.id? // "") | clean_str) as $model
    | ($model | trunc_w(18)) as $models
    | (.conversation_title? | clean_title) as $title
    | (if $title != "" then ($title | trunc_w($cols - 4)) else "" end) as $title_fmt

    | cfg_preset
    + cfg_bool("CFG_SHOW_TITLE"; "showTitle")
    + cfg_bool("CFG_SHOW_MODE"; "showMode")
    + cfg_bool("CFG_SHOW_PATH"; "showPath")
    + cfg_bool("CFG_SHOW_GIT"; "showGit")
    + cfg_bool("CFG_SHOW_QUOTA"; "showQuota")
    + cfg_bool("CFG_SHOW_3P_QUOTA"; "show3pQuota")
    + cfg_bool("CFG_SHOW_ACTIVITY"; "showActivity")
    + cfg_bool("CFG_SHOW_SANDBOX_OFF"; "showSandboxOff")
    + cfg_bool("CFG_SHOW_TOKENS"; "showTokens")
    + cfg_bool("CFG_SHOW_CACHE"; "showCache")
    + cfg_bool("CFG_SHOW_DURATION"; "showDuration")
    + cfg_bool("CFG_SHOW_COST"; "showCost")
    + kv("STATE"; ((.agent_state // "idle") | tostring | clean_str | if . == "" then "idle" else . end))
    + kv("CONFIRM_PENDING"; (.tool_confirmation_pending? == true))
    + kv("PENDING_INPUT"; (.pending_input_count? | clean_uint))
    + kv("CYCLE_MODE"; (.cycle_mode? | clean_str))
    + kv("VIM_MODE"; (.vim?.mode? | clean_str))
    + kv("USED_TENTHS"; (.context_window?.used_percentage? | clamp_pct_tenths))
    + kv("CWD"; $cwd)
    + kv("CWD_L2"; $cwd2)
    + kv("CWD_L2_W"; ($cwd2 | disp_w))
    + kv("CWD_L1"; $cwd1)
    + kv("CWD_L1_W"; ($cwd1 | disp_w))
    + kv("CWD_SHORT"; $cwds)
    + kv("CWD_SHORT_W"; ($cwds | disp_w))
    + kv("VCS_TYPE"; (.vcs?.type? | clean_str))
    + kv("VCS_BRANCH"; ((.vcs?.branch? // .workspace?.vcs?.branch? // "") | clean_str))
    + kv("VCS_DIRTY"; ((.vcs?.dirty? // .workspace?.vcs?.dirty? // false) == true))
    + kv("SANDBOX"; ((.sandbox?.enabled? // .workspace?.sandbox?.enabled? // false) == true))
    + kv("ARTIFACTS"; (.artifact_count? | clean_uint))
    + kv("SUBAGENT_RUNNING"; (if (.subagents | type) == "array"
        then ([.subagents[] | select(type == "object" and .status == "running")] | length)
        else 0 end))
    + kv("SUBAGENT_TOTAL"; (if (.subagents | type) == "array" then (.subagents | length) else 0 end))
    + kv("BG_TASKS"; (.task_count? | clean_uint))
    + kv("MODEL"; $model)
    + kv("MODEL_W"; ($model | disp_w))
    + kv("MODEL_SHORT"; $models)
    + kv("MODEL_SHORT_W"; ($models | disp_w))
    + kv("TITLE_FMT"; $title_fmt)
    + kv("COLS"; $cols)
    + kv("CONV_ID"; ((.conversation_id? // .session_id? // "") | clean_str))
    + kv("TRANSCRIPT_PATH"; (.transcript_path? | clean_str))
    + kv("COST_FMT_VAL"; ((.cost?.total_usd? // .cost?.total_cost_usd? // 0) | fmt_usd))
    + kv("COST_EST"; (.cost?.estimated? == true))
    + kv("TOK_IN"; (.context_window?.total_input_tokens? | clean_uint))
    + kv("TOK_OUT"; (.context_window?.total_output_tokens? | clean_uint))
    + kv("CUR_CACHE_PCT"; cur_cache_pct)
    + quota("GEMINI_5H_TENTHS"; "GEMINI_5H_AMT"; "GEMINI_5H_RESET"; "gemini-5h")
    + quota("GEMINI_WEEKLY_TENTHS"; "GEMINI_WEEKLY_AMT"; "GEMINI_WEEKLY_RESET"; "gemini-weekly")
    + quota("THIRD_PARTY_5H_TENTHS"; "THIRD_PARTY_5H_AMT"; "THIRD_PARTY_5H_RESET"; "3p-5h")
    + quota("THIRD_PARTY_WEEKLY_TENTHS"; "THIRD_PARTY_WEEKLY_AMT"; "THIRD_PARTY_WEEKLY_RESET"; "3p-weekly")
  ' 2>/dev/null
)

MAX_W=$((COLS - 2))
SHOW_BARS=1
if [ "$COLS" -lt 100 ] || [ "$CFG_PRESET" = "compact" ]; then
  SHOW_BARS=0
fi

# ─── Helpers (Outvar pattern avoids subshell forks) ──────────────────────────
is_uints() {
  local v
  for v in "$@"; do
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
  done
}

# Measure printable text and optionally compute a width-bounded truncation.
# Fast path stays zero-fork for pure printable ASCII; falls back to jq for non-ASCII or control chars.
measure_and_trunc() {
  local _out_clean="$1" _out_w="$2" _out_s="$3" _out_sw="$4" s="$5" limit="$6"
  local _ascii_re='^[ !-~]*$'
  if [[ "$s" =~ $_ascii_re ]]; then
    local len=${#s}
    printf -v "$_out_clean" '%s' "$s"
    printf -v "$_out_w" '%d' "$len"
    if [ "$len" -le "$limit" ]; then
      printf -v "$_out_s" '%s' "$s"
      printf -v "$_out_sw" '%d' "$len"
    else
      printf -v "$_out_s" '%s…' "${s:0:limit-1}"
      printf -v "$_out_sw" '%d' "$limit"
    fi
    return
  fi

  local _c="" _w="" _ts="" _tw=""
  IFS=$'\t' read -r _c _w _ts _tw < <(
    jq -nr --arg s "$s" --argjson lim "$limit" "${JQ_TEXT_LIB}"'
      ($s | clean_str) as $c
      | ($c | disp_w) as $w
      | ($c | trunc_w($lim)) as $ts
      | [$c, $w, $ts, ($ts | disp_w)] | @tsv
    ' 2>/dev/null
  ) || true
  is_uints "$_w" "$_tw" || { _c="$s"; _w=${#s}; _ts="$s"; _tw=${#s}; }
  printf -v "$_out_clean" '%s' "$_c"
  printf -v "$_out_w" '%d' "$_w"
  printf -v "$_out_s" '%s' "$_ts"
  printf -v "$_out_sw" '%d' "$_tw"
}

# Join (text, width) pairs with SEP (visible width 3) and output both joined text and total width.
join_parts() {
  local _out_s="$1" _out_w="$2" _res="" _w=0 _p _pw
  shift 2
  while [ "$#" -ge 2 ]; do
    _p="$1"
    _pw="$2"
    shift 2
    [ -n "$_p" ] || continue
    if [ -n "$_res" ]; then
      _res+="${SEP}${_p}"
      _w=$((_w + 3 + _pw))
    else
      _res="$_p"
      _w="$_pw"
    fi
  done
  printf -v "$_out_s" '%s' "$_res"
  printf -v "$_out_w" '%d' "$_w"
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
  local _out="$1" secs="$2"
  if [ "$secs" -lt 60 ]; then
    printf -v "$_out" ''
    return
  fi
  local mins=$((secs / 60))
  if [ "$mins" -ge 1440 ]; then
    printf -v "$_out" '%sd%sh' "$((mins / 1440))" "$(((mins % 1440) / 60))"
  elif [ "$mins" -ge 60 ]; then
    printf -v "$_out" '%sh%sm' "$((mins / 60))" "$((mins % 60))"
  else
    printf -v "$_out" '%sm' "$mins"
  fi
}

fmt_metric() {
  local _out="$1" _out_w="$2" label="$3" val="$4"
  printf -v "$_out" '%s' "${FG_GRAY}${label} ${NUM_COLOR}${val}${R}"
  printf -v "$_out_w" '%d' "$(( ${#label} + 1 + ${#val} ))"
}

# tenths is a pre-clamped integer in 0..1000 representing 0.0%..100.0%.
usage_bar() {
  local _out="$1" _out_w="$2" tenths="$3" show_bar="${4:-1}"
  local pct_fmt="$((tenths / 10)).$((tenths % 10))" bar_color filled

  if [ "$tenths" -ge 900 ]; then
    bar_color="$FG_BRIGHT_RED"
  elif [ "$tenths" -ge 600 ]; then
    bar_color="$FG_BRIGHT_YELLOW"
  else
    bar_color="$FG_BRIGHT_GREEN"
  fi

  if [ "$show_bar" -eq 0 ]; then
    printf -v "$_out" '%s' "${bar_color}${pct_fmt}%${R}"
    printf -v "$_out_w" '%d' "$(( ${#pct_fmt} + 1 ))"
    return
  fi

  filled=$(( (tenths + 50) / 100 ))
  printf -v "$_out" '%s' "${bar_color}${BAR_FULL_STEPS[filled]}${FG_GRAY}${BAR_EMPTY_STEPS[10-filled]} ${bar_color}${pct_fmt}%${R}"
  printf -v "$_out_w" '%d' "$(( 12 + ${#pct_fmt} ))"
}

# style: 2 = progress bar + reset, 1 = percentage + (reset), 0 = compact percentage (no reset)
format_quota_item() {
  local _out="$1" _out_w="$2" tenths="$3" amt="$4" reset="$5" style="$6"
  local _val="" _vw=0 show_bar=0
  [ "$style" -eq 2 ] && show_bar=1

  if [ "$tenths" != "--" ]; then
    usage_bar _val _vw "$tenths" "$show_bar"
  elif [ "$amt" != "--" ]; then
    _val="${NUM_COLOR}${amt} left${R}"
    _vw=$(( ${#amt} + 5 ))
  else
    printf -v "$_out" ''
    printf -v "$_out_w" '%d' 0
    return
  fi

  if [ "$style" -eq 0 ] || [ "$reset" = "--" ]; then
    printf -v "$_out" '%s' "$_val"
    printf -v "$_out_w" '%d' "$_vw"
  elif [ "$style" -eq 1 ]; then
    printf -v "$_out" '%s' "${_val} ${FG_GRAY}(${reset})${R}"
    printf -v "$_out_w" '%d' "$(( _vw + 3 + ${#reset} ))"
  else
    printf -v "$_out" '%s' "${_val} ${FG_GRAY}${reset}${R}"
    printf -v "$_out_w" '%d' "$(( _vw + 1 + ${#reset} ))"
  fi
}

format_quota_pair() {
  local _out="$1" _out_w="$2" label="$3" p5="$4" a5="$5" r5="$6" pw="$7" aw="$8" rw="$9" style="${10}"
  local _q5="" _w5=0 _qw="" _ww=0 _wk_lbl="week"
  [ "$style" -eq 0 ] && _wk_lbl="wk"
  format_quota_item _q5 _w5 "$p5" "$a5" "$r5" "$style"
  format_quota_item _qw _ww "$pw" "$aw" "$rw" "$style"
  if [ -n "$_q5" ] && [ -n "$_qw" ]; then
    printf -v "$_out" '%s' "${FG_GRAY}${label} 5h ${_q5}${FG_GRAY} / ${_wk_lbl} ${_qw}${R}"
    printf -v "$_out_w" '%d' "$(( ${#label} + 4 + _w5 + 4 + ${#_wk_lbl} + _ww ))"
  elif [ -n "$_q5" ]; then
    printf -v "$_out" '%s' "${FG_GRAY}${label} 5h ${_q5}${R}"
    printf -v "$_out_w" '%d' "$(( ${#label} + 4 + _w5 ))"
  elif [ -n "$_qw" ]; then
    printf -v "$_out" '%s' "${FG_GRAY}${label} ${_wk_lbl} ${_qw}${R}"
    printf -v "$_out_w" '%d' "$(( ${#label} + 2 + ${#_wk_lbl} + _ww ))"
  else
    printf -v "$_out" ''
    printf -v "$_out_w" '%d' 0
  fi
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

run_git_status() {
  local cwd="$1"
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" 2 git -C "$cwd" --no-optional-locks status --porcelain=v2 --branch 2>/dev/null || true
  else
    git -C "$cwd" --no-optional-locks status --porcelain=v2 --branch 2>/dev/null || true
  fi
}

parse_git_status() {
  local cwd="$1"
  if [ -n "$VCS_TYPE" ] && [ "$VCS_TYPE" != "git" ]; then
    return 0
  fi
  has_git_dir "$cwd" || return 0

  local gkey="" gdir="${CACHE_ROOT}/git" gfile=""
  local c_ts="" c_dirty="" c_a="" c_b="" c_m="" c_add="" c_d="" c_u="" c_branch=""
  git_cache_key gkey "$cwd"
  gfile="${gdir}/${gkey}.cache"

  if [ -r "$gfile" ]; then
    IFS=$'\t' read -r c_ts c_dirty c_a c_b c_m c_add c_d c_u c_branch < "$gfile" || true
    if is_uints "$c_ts" "$c_a" "$c_b" "$c_m" "$c_add" "$c_d" "$c_u" \
      && [ $((NOW_EPOCH - c_ts)) -ge 0 ] && [ $((NOW_EPOCH - c_ts)) -le 2 ]; then
      if [ -z "$VCS_BRANCH" ]; then VCS_BRANCH="$c_branch"; fi
      if [ "$c_dirty" = "true" ]; then VCS_DIRTY="true"; fi
      GIT_AHEAD="$c_a" GIT_BEHIND="$c_b"
      GIT_MOD="$c_m" GIT_ADD="$c_add" GIT_DEL="$c_d" GIT_UNTRACKED="$c_u"
      return 0
    fi
  fi

  local _line _oid="" _head="" _ab _a _b _xy g_branch="" g_dirty="false"
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
      "1 "*|"2 "*)
        g_dirty="true"
        _xy="${_line:2:2}"
        if [[ "$_xy" == *D* ]]; then
          GIT_DEL=$((GIT_DEL + 1))
        elif [[ "$_xy" == *A* ]]; then
          GIT_ADD=$((GIT_ADD + 1))
        else
          GIT_MOD=$((GIT_MOD + 1))
        fi
        ;;
      "u "*)
        g_dirty="true"
        GIT_MOD=$((GIT_MOD + 1))
        ;;
      "? "*)
        g_dirty="true"
        GIT_UNTRACKED=$((GIT_UNTRACKED + 1))
        ;;
    esac
  done < <(run_git_status "$cwd")

  if [[ "$g_branch" == *$'\033'* ]] || [[ "$g_branch" =~ [[:cntrl:]] ]]; then
    g_branch=$(jq -nr --arg s "$g_branch" "${JQ_TEXT_LIB}"'$s | clean_str' 2>/dev/null || printf '%s' "$g_branch" | tr -d '\000-\037\177')
  fi

  is_uints "$GIT_AHEAD" || GIT_AHEAD=0
  is_uints "$GIT_BEHIND" || GIT_BEHIND=0
  if [ -z "$VCS_BRANCH" ]; then VCS_BRANCH="$g_branch"; fi
  if [ "$g_dirty" = "true" ]; then VCS_DIRTY="true"; fi

  local _cache_row=""
  printf -v _cache_row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$NOW_EPOCH" "$g_dirty" "$GIT_AHEAD" "$GIT_BEHIND" \
    "$GIT_MOD" "$GIT_ADD" "$GIT_DEL" "$GIT_UNTRACKED" "$g_branch"
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
  local c_mtime="" c_size="" s_in="" s_out="" session_pct="" first_ts="0"

  if [ "$valid_conv_id" -eq 1 ]; then
    local stat_info=""
    case "${OSTYPE:-}" in
      darwin*|*bsd*) stat_info=$(stat -f '%m %z' "$tpath" 2>/dev/null) || true ;;
      *)             stat_info=$(stat -c '%Y %s' "$tpath" 2>/dev/null) || true ;;
    esac
    if [[ "$stat_info" == *" "* ]]; then
      mtime="${stat_info%% *}"
      size="${stat_info#* }"
    fi
    if is_uints "$mtime" "$size"; then
      cache_file="${cache_dir}/${CONV_ID}.cache"
      if [ -r "$cache_file" ]; then
        read -r c_mtime c_size s_in s_out session_pct first_ts < "$cache_file" || true
        if [ "$c_mtime" = "$mtime" ] && [ "$c_size" = "$size" ] \
          && is_uints "$s_in" "$s_out" "$first_ts" \
          && [[ "$session_pct" =~ ^(--|[0-9]+\.[0-9])$ ]]; then
          cache_hit=1
        fi
      fi
    fi
  fi

  if [ "$cache_hit" -eq 0 ]; then
    local parsed=""
    parsed=$(
      jq -n -R -r '
        # Rewind can reuse a step_index; both model calls still consumed tokens.
        reduce inputs as $line (
          {first_ts: 0, total_in: 0, total_out: 0, cache_read: 0, missing_cache: false};
          (if .first_ts == 0 and ($line | contains("created_at")) then
            (($line | fromjson? | objects | .created_at? | strings | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // 0) as $ts
            | if $ts > 0 then .first_ts = $ts else . end
           else . end)
          | if ($line | contains("PLANNER_RESPONSE")) then
              (($line | fromjson? | objects | select(.type == "PLANNER_RESPONSE")) // null) as $x
              | if $x != null then
                  (($x.input_tokens // 0) + ($x.cache_read_tokens // 0)
                    + ($x.cache_creation_tokens // $x.cache_creation_input_tokens // 0)) as $input
                  | .total_in += $input
                  | .total_out += ($x.output_tokens // 0)
                  | .cache_read += ($x.cache_read_tokens // 0)
                  | if $input > 0 and $x.cache_read_tokens == null then .missing_cache = true else . end
                else . end
            else . end
        )
        | [.total_in, .total_out,
           (if .total_in > 0 and (.missing_cache | not) then
              (.cache_read * 1000 / .total_in | round) as $t
              | "\($t / 10 | floor).\($t % 10)"
            else "--" end),
           .first_ts] | @tsv
      ' < "$tpath" 2>/dev/null
    ) || true
    read -r s_in s_out session_pct first_ts <<< "$parsed" || true
    is_uints "$s_in" "$s_out" || return 0
    is_uints "$first_ts" || first_ts=0

    if [ -n "$cache_file" ]; then
      write_cache_file "$cache_dir" "$cache_file" "${mtime} ${size} ${s_in} ${s_out} ${session_pct} ${first_ts}"
    fi
  fi

  if [ "$session_pct" != "--" ]; then
    SESSION_CACHE_PCT="$session_pct"
  fi
  if [ "$first_ts" -gt 0 ]; then
    SESSION_FIRST_TS="$first_ts"
  fi
  if [ $(( s_in + s_out )) -gt 0 ]; then
    DISP_IN="$s_in"
    DISP_OUT="$s_out"
  fi
}

# ─── Line 1: State, Mode, Model, Context, CWD, VCS ───────────────────────────
S_W=0
if [ "$CONFIRM_PENDING" = "true" ]; then
  S="${FG_BRIGHT_YELLOW}${B}⚠ CONFIRM${R}"
  S_W=9
else
  case "$STATE" in
    idle)           S="${FG_BRIGHT_GREEN}${B}● READY${R}"; S_W=7 ;;
    working)        S="${FG_BRIGHT_CYAN}${B}⚙ WORKING${R}"; S_W=9 ;;
    tool_use)       S="${FG_BRIGHT_MAGENTA}${B}🔧 TOOL${R}"; S_W=7 ;;
    reviewing)      S="${FG_BRIGHT_YELLOW}${B}◈ REVIEW${R}"; S_W=8 ;;
    error)          S="${FG_BRIGHT_RED}${B}✖ ERROR${R}"; S_W=7 ;;
    thinking)       S="${FG_BRIGHT_YELLOW}${B}◆ THINKING${R}"; S_W=10 ;;
    authenticating) S="${FG_WHITE}${B}⏳ AUTH${R}"; S_W=7 ;;
    initializing)   S="${FG_WHITE}${B}⏳ INIT${R}"; S_W=7 ;;
    *)
      _state_up=$(printf '%s' "$STATE" | tr '[:lower:]' '[:upper:]')
      S="${FG_WHITE}${B}⏳ ${_state_up}${R}"
      S_W=$(( 3 + ${#_state_up} ))
      ;;
  esac
fi
if [ "$PENDING_INPUT" -gt 0 ]; then
  S="${S} ${FG_BRIGHT_YELLOW}(+${PENDING_INPUT})${R}"
  S_W=$(( S_W + 4 + ${#PENDING_INPUT} ))
fi

MODE_FMT="" MODE_W=0
if [ "$CFG_SHOW_MODE" -eq 1 ]; then
  case "$CYCLE_MODE" in
    plan)         MODE_FMT="${FG_BRIGHT_BLUE}${B}PLAN${R}"; MODE_W=4 ;;
    accept-edits) MODE_FMT="${FG_BRIGHT_YELLOW}${B}EDITS${R}"; MODE_W=5 ;;
    auto)         MODE_FMT="${FG_BRIGHT_RED}${B}AUTO${R}"; MODE_W=4 ;;
    "")           MODE_FMT=""; MODE_W=0 ;;
    *)
      _mode_up=$(printf '%s' "$CYCLE_MODE" | tr '[:lower:]' '[:upper:]')
      MODE_FMT="${FG_WHITE}${B}${_mode_up}${R}"
      MODE_W=${#_mode_up}
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
    if [ -n "$MODE_FMT" ]; then
      MODE_FMT="${MODE_FMT} ${FG_BRIGHT_CYAN}[${_vim_tag}]${R}"
      MODE_W=$(( MODE_W + 3 + ${#_vim_tag} ))
    else
      MODE_FMT="${FG_BRIGHT_CYAN}[${_vim_tag}]${R}"
      MODE_W=$(( 2 + ${#_vim_tag} ))
    fi
  fi
fi

M="" M_SHORT=""
if [ -n "$MODEL" ]; then
  M="${FG_BRIGHT_MAGENTA}${I}${MODEL}${R}"
  M_SHORT="${FG_BRIGHT_MAGENTA}${I}${MODEL_SHORT}${R}"
fi

GIT_AHEAD=0 GIT_BEHIND=0 GIT_MOD=0 GIT_ADD=0 GIT_DEL=0 GIT_UNTRACKED=0
if [ "$CFG_SHOW_GIT" -eq 1 ] && [ -n "$CWD" ] && command -v git >/dev/null 2>&1; then
  parse_git_status "$CWD"
elif [ "$CFG_SHOW_GIT" -eq 0 ]; then
  VCS_BRANCH=""
fi

VCS_BRANCH_W=0 VCS_BRANCH_SHORT="" VCS_BRANCH_SHORT_W=0
if [ -n "$VCS_BRANCH" ]; then
  measure_and_trunc VCS_BRANCH VCS_BRANCH_W VCS_BRANCH_SHORT VCS_BRANCH_SHORT_W "$VCS_BRANCH" 18
fi

build_line1() {
  local show_ctx_bar="$1" cwd_mode="$2" git_mode="$3" show_mode="$4" model_mode="$5"
  local _ctx_bar="" _ctx_bar_w=0 _ctx="" _ctx_w=0
  local _mode="" _mw=0 _m="" _modw=0 _p="" _pw=0 _v="" _vw=0

  [ "$show_mode" -eq 1 ] && { _mode="$MODE_FMT"; _mw="$MODE_W"; }
  case "$model_mode" in
    2) _m="$M"; _modw="$MODEL_W" ;;
    1) _m="$M_SHORT"; _modw="$MODEL_SHORT_W" ;;
  esac

  usage_bar _ctx_bar _ctx_bar_w "$USED_TENTHS" "$show_ctx_bar"
  _ctx="${FG_GRAY}ctx ${_ctx_bar}"
  _ctx_w=$(( 4 + _ctx_bar_w ))

  if [ "$CFG_SHOW_PATH" -eq 1 ]; then
    case "$cwd_mode" in
      2) [ -n "$CWD_L2" ] && { _p="${FG_CYAN}${CWD_L2}${R}"; _pw="$CWD_L2_W"; } ;;
      1) [ -n "$CWD_L1" ] && { _p="${FG_CYAN}${CWD_L1}${R}"; _pw="$CWD_L1_W"; } ;;
      s) [ -n "$CWD_SHORT" ] && { _p="${FG_CYAN}${CWD_SHORT}${R}"; _pw="$CWD_SHORT_W"; } ;;
    esac
  fi

  if [ "$git_mode" != "0" ] && [ -n "$VCS_BRANCH" ]; then
    local _br="$VCS_BRANCH" _br_w="$VCS_BRANCH_W" _branch_str _vcs_extra="" _vcs_extra_w=0 _vcs_inds _ind _cnt
    if [ "$git_mode" = "s" ]; then
      _br="$VCS_BRANCH_SHORT"
      _br_w="$VCS_BRANCH_SHORT_W"
    fi
    if [ "$VCS_DIRTY" = "true" ]; then
      _branch_str="${FG_BRIGHT_RED}${_br}${FG_BRIGHT_YELLOW}*"
      _vw=$(( _br_w + 1 ))
    else
      _branch_str="${FG_BRIGHT_BLUE}${_br}"
      _vw="$_br_w"
    fi
    _vcs_inds=(
      "$GIT_AHEAD:${FG_BRIGHT_CYAN}↑"
      "$GIT_BEHIND:${FG_BRIGHT_CYAN}↓"
    )
    if [ "$git_mode" = "2" ]; then
      _vcs_inds+=(
        "$GIT_MOD:${FG_BRIGHT_YELLOW}!"
        "$GIT_ADD:${FG_BRIGHT_GREEN}+"
        "$GIT_DEL:${FG_BRIGHT_RED}✘"
        "$GIT_UNTRACKED:${FG_GRAY}?"
      )
    fi
    for _ind in "${_vcs_inds[@]}"; do
      _cnt="${_ind%%:*}"
      if [ "$_cnt" -gt 0 ]; then
        _vcs_extra+=" ${_ind#*:}${_cnt}"
        _vcs_extra_w=$(( _vcs_extra_w + 2 + ${#_cnt} ))
      fi
    done
    _v="${_branch_str}${_vcs_extra}${R}"
    _vw=$(( _vw + _vcs_extra_w ))
  fi

  join_parts LINE1 LINE1_W "$S" "$S_W" "$_mode" "$_mw" "$_m" "$_modw" "$_ctx" "$_ctx_w" "$_p" "$_pw" "$_v" "$_vw"
}

LINE1="" LINE1_W=0
if [ "$SHOW_BARS" -eq 1 ]; then
  build_line1 1 2 2 1 2
  [ "$LINE1_W" -gt "$MAX_W" ] && build_line1 1 1 1 1 2
  [ "$LINE1_W" -gt "$MAX_W" ] && build_line1 0 1 1 1 2
else
  build_line1 0 2 2 1 2
  [ "$LINE1_W" -gt "$MAX_W" ] && build_line1 0 1 1 1 2
fi
[ "$LINE1_W" -gt "$MAX_W" ] && build_line1 0 s s 1 2
[ "$LINE1_W" -gt "$MAX_W" ] && build_line1 0 s s 1 1
[ "$LINE1_W" -gt "$MAX_W" ] && build_line1 0 0 s 1 1
[ "$LINE1_W" -gt "$MAX_W" ] && build_line1 0 0 s 0 1
[ "$LINE1_W" -gt "$MAX_W" ] && build_line1 0 0 0 0 1
[ "$LINE1_W" -gt "$MAX_W" ] && build_line1 0 0 0 0 0

if [ "$CFG_PRESET" = "minimal" ]; then
  printf '%s\n' "${PAD}${LINE1}"
  exit 0
fi

# ─── Line 2: Quota (Collapsed when empty, degrades cleanly on narrow terminals)
build_line2() {
  local style="$1" include_3p="$2" _qgem="" _qgem_w=0 _q3p="" _q3p_w=0
  format_quota_pair _qgem _qgem_w "Gemini" \
    "$GEMINI_5H_TENTHS" "$GEMINI_5H_AMT" "$GEMINI_5H_RESET" \
    "$GEMINI_WEEKLY_TENTHS" "$GEMINI_WEEKLY_AMT" "$GEMINI_WEEKLY_RESET" \
    "$style"
  if [ "$include_3p" -eq 1 ]; then
    format_quota_pair _q3p _q3p_w "3P" \
      "$THIRD_PARTY_5H_TENTHS" "$THIRD_PARTY_5H_AMT" "$THIRD_PARTY_5H_RESET" \
      "$THIRD_PARTY_WEEKLY_TENTHS" "$THIRD_PARTY_WEEKLY_AMT" "$THIRD_PARTY_WEEKLY_RESET" \
      "$style"
  fi
  join_parts QUOTA_FMT QUOTA_W "$_qgem" "$_qgem_w" "$_q3p" "$_q3p_w"
}

QUOTA_FMT="" QUOTA_W=0
if [ "$CFG_SHOW_QUOTA" -eq 1 ]; then
  if [ "$SHOW_BARS" -eq 1 ]; then
    build_line2 2 "$CFG_SHOW_3P_QUOTA"
    [ "$QUOTA_W" -gt "$MAX_W" ] && build_line2 1 "$CFG_SHOW_3P_QUOTA"
  else
    build_line2 1 "$CFG_SHOW_3P_QUOTA"
  fi
  [ "$QUOTA_W" -gt "$MAX_W" ] && build_line2 0 "$CFG_SHOW_3P_QUOTA"
  if [ "$QUOTA_W" -gt "$MAX_W" ] && [ "$CFG_SHOW_3P_QUOTA" -eq 1 ]; then
    build_line2 0 0
  fi
fi

# ─── Line 3: Counts, Sandbox, Tokens, Cache, Duration, Cost ──────────────────
SESSION_CACHE_PCT="--"
SESSION_FIRST_TS="0"
DISP_IN="$TOK_IN" DISP_OUT="$TOK_OUT"
if [ "$CFG_SHOW_TOKENS" -eq 1 ] || [ "$CFG_SHOW_CACHE" -eq 1 ] || [ "$CFG_SHOW_DURATION" -eq 1 ]; then
  load_session_tokens
fi

if [ "$SESSION_CACHE_PCT" = "--" ] && [ "$CUR_CACHE_PCT" != "--" ]; then
  SESSION_CACHE_PCT="$CUR_CACHE_PCT"
fi

TOK_TOTAL=$(( DISP_IN + DISP_OUT ))

ART_FMT="" ART_W=0
SUB_FMT="" SUB_W=0 SUB_RUN_FMT="" SUB_RUN_W=0
BG_FMT="" BG_W=0
SB_FMT="" SB_W=0 SB_ON_FMT="" SB_ON_W=0

if [ "$CFG_SHOW_ACTIVITY" -eq 1 ]; then
  if [ "$ARTIFACTS" -gt 0 ]; then
    fmt_metric ART_FMT ART_W "artifacts" "$ARTIFACTS"
  fi
  if [ "$SUBAGENT_TOTAL" -gt 0 ]; then
    if [ "$SUBAGENT_RUNNING" -gt 0 ]; then
      SUB_FMT="${FG_GRAY}subagents ${FG_BRIGHT_CYAN}${B}${SUBAGENT_RUNNING}${R}${FG_GRAY}/${SUBAGENT_TOTAL}${R}"
      SUB_W=$(( 11 + ${#SUBAGENT_RUNNING} + ${#SUBAGENT_TOTAL} ))
      SUB_RUN_FMT="$SUB_FMT"
      SUB_RUN_W="$SUB_W"
    else
      SUB_FMT="${FG_GRAY}subagents 0/${SUBAGENT_TOTAL}${R}"
      SUB_W=$(( 12 + ${#SUBAGENT_TOTAL} ))
    fi
  fi
  if [ "$BG_TASKS" -gt 0 ]; then
    fmt_metric BG_FMT BG_W "tasks" "$BG_TASKS"
  fi
fi

if [ "$SANDBOX" = "true" ]; then
  SB_FMT="${FG_GRAY}sandbox ${FG_BRIGHT_GREEN}${B}ON${R}"
  SB_W=10
  SB_ON_FMT="$SB_FMT"
  SB_ON_W=10
elif [ "$CFG_SHOW_SANDBOX_OFF" -eq 1 ]; then
  SB_FMT="${FG_GRAY}sandbox off${R}"
  SB_W=11
fi

CACHE_FMT="" CACHE_W=0
if [ "$CFG_SHOW_CACHE" -eq 1 ] && [ "$SESSION_CACHE_PCT" != "--" ]; then
  fmt_metric CACHE_FMT CACHE_W "cache" "${SESSION_CACHE_PCT}%"
fi

DUR_FMT="" DUR_W=0
if [ "$CFG_SHOW_DURATION" -eq 1 ] && [ "$SESSION_FIRST_TS" -gt 0 ] && [ "$NOW_EPOCH" -ge "$SESSION_FIRST_TS" ]; then
  fmt_duration _dur_str "$((NOW_EPOCH - SESSION_FIRST_TS))"
  if [ -n "$_dur_str" ]; then
    DUR_FMT="${FG_GRAY}${_dur_str}${R}"
    DUR_W=${#_dur_str}
  fi
fi

COST_FMT="" COST_W=0
if [ "$CFG_SHOW_COST" -eq 1 ] && [ -n "$COST_FMT_VAL" ]; then
  _cost_prefix="\$"
  _cost_pw=1
  if [ "$COST_EST" = "true" ]; then
    _cost_prefix="~\$"
    _cost_pw=2
  fi
  COST_FMT="${FG_BRIGHT_YELLOW}${_cost_prefix}${COST_FMT_VAL}${R}"
  COST_W=$(( _cost_pw + ${#COST_FMT_VAL} ))
fi

TOK_FULL_FMT="" TOK_FULL_W=0 TOK_SHORT_FMT="" TOK_SHORT_W=0
if [ "$CFG_SHOW_TOKENS" -eq 1 ] && [ "$TOK_TOTAL" -gt 0 ]; then
  fmt_tokens _tok_tot_str "$TOK_TOTAL"
  fmt_metric TOK_SHORT_FMT TOK_SHORT_W "token" "$_tok_tot_str"
  fmt_tokens _tok_in_str "$DISP_IN"
  fmt_tokens _tok_out_str "$DISP_OUT"
  TOK_FULL_FMT="${TOK_SHORT_FMT} ${FG_GRAY}(${_tok_in_str}↑ ${_tok_out_str}↓)${R}"
  TOK_FULL_W=$(( TOK_SHORT_W + 6 + ${#_tok_in_str} + ${#_tok_out_str} ))
fi

LINE3="" LINE3_W=0
join_parts LINE3 LINE3_W \
  "$ART_FMT" "$ART_W" "$SUB_FMT" "$SUB_W" "$BG_FMT" "$BG_W" "$SB_FMT" "$SB_W" \
  "$TOK_FULL_FMT" "$TOK_FULL_W" "$CACHE_FMT" "$CACHE_W" "$DUR_FMT" "$DUR_W" "$COST_FMT" "$COST_W"
[ "$LINE3_W" -gt "$MAX_W" ] && join_parts LINE3 LINE3_W \
  "$ART_FMT" "$ART_W" "$SUB_FMT" "$SUB_W" "$BG_FMT" "$BG_W" "$SB_FMT" "$SB_W" \
  "$TOK_SHORT_FMT" "$TOK_SHORT_W" "$CACHE_FMT" "$CACHE_W" "$DUR_FMT" "$DUR_W" "$COST_FMT" "$COST_W"
[ "$LINE3_W" -gt "$MAX_W" ] && join_parts LINE3 LINE3_W \
  "$SUB_RUN_FMT" "$SUB_RUN_W" "$BG_FMT" "$BG_W" "$SB_ON_FMT" "$SB_ON_W" \
  "$TOK_SHORT_FMT" "$TOK_SHORT_W" "$CACHE_FMT" "$CACHE_W" "$DUR_FMT" "$DUR_W" "$COST_FMT" "$COST_W"
[ "$LINE3_W" -gt "$MAX_W" ] && join_parts LINE3 LINE3_W \
  "$SUB_RUN_FMT" "$SUB_RUN_W" "$BG_FMT" "$BG_W" "$SB_ON_FMT" "$SB_ON_W" \
  "$TOK_SHORT_FMT" "$TOK_SHORT_W" "$CACHE_FMT" "$CACHE_W" "$COST_FMT" "$COST_W"
[ "$LINE3_W" -gt "$MAX_W" ] && join_parts LINE3 LINE3_W \
  "$SUB_RUN_FMT" "$SUB_RUN_W" "$SB_ON_FMT" "$SB_ON_W" \
  "$TOK_SHORT_FMT" "$TOK_SHORT_W" "$COST_FMT" "$COST_W"
[ "$LINE3_W" -gt "$MAX_W" ] && join_parts LINE3 LINE3_W \
  "$TOK_SHORT_FMT" "$TOK_SHORT_W" "$COST_FMT" "$COST_W"

# ─── Output ──────────────────────────────────────────────────────────────────
if [ "$CFG_SHOW_TITLE" -eq 1 ] && [ -n "$TITLE_FMT" ]; then
  printf '%s\n' "${PAD}${FG_GRAY}▸ ${FG_WHITE}${TITLE_FMT}${R}"
fi
printf '%s\n' "${PAD}${LINE1}"
if [ -n "$QUOTA_FMT" ]; then
  printf '%s\n' "${PAD}${QUOTA_FMT}"
fi
if [ -n "$LINE3" ]; then
  printf '%s\n' "${PAD}${LINE3}"
fi
