#!/bin/bash
# Shared quota refresh: fetches whichever source is relevant (Z.ai in GLM
# mode, or the Keychain-based native Claude fallback otherwise), respecting
# the existing per-source cache TTLs, then runs glm_quota_decide.py.
#
# No stdin dependency — callable from quota-statusline.sh (display) AND
# quota-guard.sh (pause/resume freshness) alike. Network calls stay bounded
# by the TTL checks below regardless of how often this script is invoked.

CACHE_DIR="/tmp/.glm-quota-cache"
mkdir -p "$CACHE_DIR" 2>/dev/null

BASE_URL="${ANTHROPIC_BASE_URL:-}"
AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"

# --- Helper: ISO8601 UTC timestamp → epoch seconds (portable GNU/BSD date) ---
iso_to_epoch() {
  local clean="${1%%.*}"
  [[ -z "$clean" ]] && return
  date -u -d "$clean" +%s 2>/dev/null || date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null
}

if [[ "${GLM_QUOTA_ACTIVE:-}" == "1" && -n "$AUTH_TOKEN" && "$BASE_URL" =~ api\.z\.ai|bigmodel\.cn ]]; then
  # --- GLM mode: refresh Z.ai quota if stale (300s TTL) ---
  host="${BASE_URL#*://}"
  host="${host%%/*}"
  BASE="https://${host}"
  CACHE_FILE="${CACHE_DIR}/quota.json"

  cache_age=999999
  if [[ -f "$CACHE_FILE" ]]; then
    cache_ts=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    cache_age=$(( $(date +%s) - cache_ts ))
  fi

  if (( cache_age >= 300 )); then
    data=$(curl -s --max-time 8 \
      -H "Authorization: ${AUTH_TOKEN}" \
      -H "Accept-Language: en-US" \
      -H "Content-Type: application/json" \
      "${BASE}/api/monitor/usage/quota/limit" 2>/dev/null)
    if [[ $? -eq 0 && -n "$data" ]]; then
      echo "$data" > "$CACHE_FILE"
    fi
  fi
else
  # --- Native Claude/Anthropic: refresh via Keychain if stale (120s TTL) ---
  if command -v security >/dev/null 2>&1; then
    NATIVE_CACHE_FILE="${CACHE_DIR}/claude-oauth-usage.json"

    native_cache_age=999999
    if [[ -f "$NATIVE_CACHE_FILE" ]]; then
      native_cache_ts=$(stat -f %m "$NATIVE_CACHE_FILE" 2>/dev/null || stat -c %Y "$NATIVE_CACHE_FILE" 2>/dev/null || echo 0)
      native_cache_age=$(( $(date +%s) - native_cache_ts ))
    fi

    if (( native_cache_age >= 120 )); then
      oauth_token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
      if [[ -n "$oauth_token" ]]; then
        native_data=$(curl -s --max-time 5 \
          -H "Authorization: Bearer ${oauth_token}" \
          -H "anthropic-beta: oauth-2025-04-20" \
          -H "Accept: application/json" \
          -H "Content-Type: application/json" \
          "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        oauth_token=""
        if [[ -n "$native_data" ]] && echo "$native_data" | jq -e '.five_hour // .seven_day' >/dev/null 2>&1; then
          echo "$native_data" > "$NATIVE_CACHE_FILE"
        fi
      fi
    fi

    if [[ -f "$NATIVE_CACHE_FILE" ]]; then
      native_data=$(cat "$NATIVE_CACHE_FILE" 2>/dev/null)
      native_5h=$(echo "$native_data" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
      native_5h_iso=$(echo "$native_data" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
      native_7d=$(echo "$native_data" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
      native_7d_iso=$(echo "$native_data" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)
      native_5h_reset=""
      native_7d_reset=""
      [[ -n "$native_5h_iso" ]] && native_5h_reset=$(iso_to_epoch "$native_5h_iso")
      [[ -n "$native_7d_iso" ]] && native_7d_reset=$(iso_to_epoch "$native_7d_iso")

      if [[ -n "$native_5h" || -n "$native_7d" ]]; then
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
    fi
  fi
fi

if command -v uv >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  uv run "${SCRIPT_DIR}/glm_quota_decide.py" >/dev/null 2>&1
fi
