#!/bin/bash
# Statusline script for GLM mode — displays context + Z.ai quota
# Fetch/cache/decide logic lives in glm_quota_refresh.sh (shared with the
# quota-guard hook); this script only parses stdin and renders output.

MODE="bar"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CACHE_DIR="/tmp/.glm-quota-cache"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse stdin from Claude Code ---
input=""
ctx_pct=""
ctx_tokens=""
ctx_total=""
model_name=""
native_5h=""
native_5h_reset=""
native_7d=""
native_7d_reset=""

if [[ ! -t 0 ]]; then
  input=$(cat 2>/dev/null || true)
  if [[ -n "$input" ]]; then
    ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
    ctx_total=$(echo "$input" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
    # Total tokens = input + output + cache read + cache creation
    ctx_tokens=$(echo "$input" | jq -r '(.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0) + (.context_window.current_usage.cache_read_input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0)' 2>/dev/null)
    model_name=$(echo "$input" | jq -r '.model.display_name // .model.id // empty' 2>/dev/null)
    # Native Claude/Anthropic plan usage — same numbers as claude.ai's usage
    # page, provided directly by Claude Code, no API call needed. Only
    # populated when talking to Anthropic's own backend (absent in GLM mode).
    native_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
    native_5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
    native_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
    native_7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)
  fi
fi

if [[ -z "${GLM_QUOTA_ACTIVE:-}" && -n "$native_5h" ]]; then
  # Claude Code already gave us native usage for free — persist it for the
  # pause/resume decision script instead of re-fetching via Keychain.
  mkdir -p "$CACHE_DIR" 2>/dev/null
  jq -n \
    --arg h "${native_5h:-null}" --arg hr "${native_5h_reset:-null}" \
    --arg d "${native_7d:-null}" --arg dr "${native_7d_reset:-null}" \
    '{
      five_hour_pct: ($h | if . == "null" then null else tonumber end),
      five_hour_reset_epoch: ($hr | if . == "null" then null else tonumber end),
      seven_day_pct: ($d | if . == "null" then null else tonumber end),
      seven_day_reset_epoch: ($dr | if . == "null" then null else tonumber end)
    }' > "${CACHE_DIR}/claude-native-quota.json" 2>/dev/null
fi

# Fetch (or reuse cached) quota + refresh the pause/resume decision state.
# Same script the quota-guard hook triggers, so there's a single fetch/cache
# implementation for both display and pause/resume.
bash "${SCRIPT_DIR}/glm_quota_refresh.sh"

# --- Helper: format reset time (ms epoch) → Xm / Xh / Xj ---
fmt_reset() {
  local ms="${1%%.*}"
  [[ -z "$ms" || "$ms" == "null" ]] && return
  local s=$(( ms / 1000 ))
  local now=$(date +%s)
  local diff=$(( s - now ))
  if (( diff <= 0 )); then
    printf 'now'
  elif (( diff < 3600 )); then
    printf '%dm' $(( (diff + 59) / 60 ))
  elif (( diff < 86400 )); then
    printf '%dh' $(( (diff + 1800) / 3600 ))
  else
    printf '%dj' $(( (diff + 43200) / 86400 ))
  fi
}

# --- Helper: format reset time (seconds epoch) → Xm / Xh / Xj ---
fmt_reset_s() {
  local s="${1%%.*}"
  [[ -z "$s" || "$s" == "null" ]] && return
  local now=$(date +%s)
  local diff=$(( s - now ))
  if (( diff <= 0 )); then
    printf 'now'
  elif (( diff < 3600 )); then
    printf '%dm' $(( (diff + 59) / 60 ))
  elif (( diff < 86400 )); then
    printf '%dh' $(( (diff + 1800) / 3600 ))
  else
    printf '%dj' $(( (diff + 43200) / 86400 ))
  fi
}

# --- Helper: render bar segment ---
render_bar() {
  local pct="${1%.*}"
  pct=${pct:-0}
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100

  local color reset=''
  if (( pct >= 90 )); then color=''
  elif (( pct >= 70 )); then color=''
  else color=''
  fi

  local fmt_pct="$pct"
  if [[ "$2" == "1d" ]]; then
    fmt_pct=$(printf '%.1f' "$1" 2>/dev/null)
  fi

  if [[ "$MODE" == "text" ]]; then
    printf "${color}%s%%${reset}" "$fmt_pct"
    return
  fi

  local filled=$(( (pct + 5) / 10 ))
  local empty=$(( 10 - filled ))
  (( filled > 10 )) && filled=10
  local bar=""
  for (( j=0; j<filled; j++ )); do bar+="█"; done
  for (( j=0; j<empty; j++ )); do bar+="░"; done
  printf "${color}%s %s%%${reset}" "$bar" "$fmt_pct"
}

# --- Read cached quota for display ---
token_5h=""
token_5h_2=""
mcp_pct=""
mcp_cur=""
mcp_max=""
reset_5h=""
reset_7d=""
reset_mcp=""

if [[ "${GLM_QUOTA_ACTIVE:-}" == "1" ]]; then
  data=$(cat "${CACHE_DIR}/quota.json" 2>/dev/null)
  if [[ -n "$data" ]]; then
    limit_count=$(echo "$data" | jq '.data.limits | length' 2>/dev/null)
    for (( i=0; i<limit_count; i++ )); do
      ltype=$(echo "$data" | jq -r ".data.limits[$i].type" 2>/dev/null)
      lpct=$(echo "$data" | jq -r ".data.limits[$i].percentage // 0" 2>/dev/null)
      lreset=$(echo "$data" | jq -r ".data.limits[$i].nextResetTime // empty" 2>/dev/null)

      if [[ "$ltype" == "TOKENS_LIMIT" ]]; then
        if [[ -z "$token_5h" ]]; then
          token_5h="$lpct"
          reset_5h="$lreset"
        else
          token_5h_2="$lpct"
          reset_7d="$lreset"
        fi
      elif [[ "$ltype" == "TIME_LIMIT" ]]; then
        mcp_pct="$lpct"
        mcp_cur=$(echo "$data" | jq -r ".data.limits[$i].currentValue // 0" 2>/dev/null)
        mcp_max=$(echo "$data" | jq -r ".data.limits[$i].usage // 0" 2>/dev/null)
        reset_mcp="$lreset"
      fi
    done
  fi
elif [[ -z "$native_5h" && -z "$native_7d" ]]; then
  # stdin didn't give us native usage (fresh session) — glm_quota_refresh.sh
  # just populated claude-native-quota.json via the Keychain fallback.
  native_cache=$(cat "${CACHE_DIR}/claude-native-quota.json" 2>/dev/null)
  if [[ -n "$native_cache" ]]; then
    native_5h=$(echo "$native_cache" | jq -r '.five_hour_pct // empty' 2>/dev/null)
    native_5h_reset=$(echo "$native_cache" | jq -r '.five_hour_reset_epoch // empty' 2>/dev/null)
    native_7d=$(echo "$native_cache" | jq -r '.seven_day_pct // empty' 2>/dev/null)
    native_7d_reset=$(echo "$native_cache" | jq -r '.seven_day_reset_epoch // empty' 2>/dev/null)
  fi
fi

# --- Build output — single line ---
line1="⟡"
line2=""

# Compute real context percentage from actual token count (with cache)
ctx_real_pct=""
if [[ -n "$ctx_tokens" && -n "$ctx_total" && "$ctx_total" -gt 0 ]]; then
  ctx_real_pct=$(( ctx_tokens * 100 / ctx_total ))
fi

# Line 1: model + context bar + cost
if [[ -n "$model_name" ]]; then
  line1+=" ${model_name}"
fi
if [[ -n "$ctx_real_pct" ]]; then
  line1+=" │ Ctx:$(render_bar "$ctx_real_pct")"
  if [[ -n "$ctx_tokens" && -n "$ctx_total" ]]; then
    ctx_k=$(( ctx_tokens / 1000 ))
    ctx_max_k=$(( ctx_total / 1000 ))
    line1+=" │ ${ctx_k}k/${ctx_max_k}k"
  fi
  if (( ctx_real_pct >= 50 )); then
    line1+=" │ ⚡ /compact"
  fi
fi

# Line 2: Z.ai quota (GLM mode) or native Claude plan usage (everywhere else)
if [[ -n "$token_5h" ]]; then
  line2+="5h:$(render_bar "$token_5h")"
  if [[ -n "$reset_5h" ]]; then line2+=" ↻$(fmt_reset "$reset_5h")"; fi
fi
if [[ -n "$token_5h_2" ]]; then
  line2+=" │ 7j:$(render_bar "$token_5h_2")"
  if [[ -n "$reset_7d" ]]; then line2+=" ↻$(fmt_reset "$reset_7d")"; fi
fi
if [[ -n "$mcp_pct" ]]; then
  [[ -n "$token_5h" || -n "$token_5h_2" ]] && line2+=" │ "
  line2+="MCP:${mcp_cur}/${mcp_max}"
  if [[ -n "$reset_mcp" ]]; then line2+=" ↻$(fmt_reset "$reset_mcp")"; fi
elif [[ -n "$native_5h" || -n "$native_7d" ]]; then
  if [[ -n "$native_5h" ]]; then
    line2+="5h:$(render_bar "$native_5h")"
    if [[ -n "$native_5h_reset" ]]; then line2+=" ↻$(fmt_reset_s "$native_5h_reset")"; fi
  fi
  if [[ -n "$native_7d" ]]; then
    [[ -n "$native_5h" ]] && line2+=" │ "
    line2+="7j:$(render_bar "$native_7d")"
    if [[ -n "$native_7d_reset" ]]; then line2+=" ↻$(fmt_reset_s "$native_7d_reset")"; fi
  fi
fi

# Merge onto a single line — line2 stays empty when there's no quota data to show.
if [[ -n "$line2" ]]; then
  printf '%b │ %b\n' "$line1" "$line2"
else
  printf '%b\n' "$line1"
fi
