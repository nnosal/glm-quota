#!/bin/bash
# PreToolUse hook: blocks costly tool calls when the quota guard says
# PAUSE/STOP — GLM peak-hour aware in GLM mode, flat threshold otherwise
# (native Claude 5h/7d limits).
#
# Freshness is decoupled from the statusline: during a long autonomous
# workflow, the statusline can go quiet for minutes (Claude Code only
# refreshes it on certain UI events), which would otherwise leave this
# guard checking stale data exactly when it matters most. So this hook
# also triggers glm_quota_refresh.sh itself — but throttled to at most
# once per TRIGGER_INTERVAL regardless of how many tool calls fire in
# between, so a busy workflow doesn't spawn a refresh process per call.
# The refresh script has its own separate network-fetch TTLs (300s/120s)
# on top of this, so actual API calls stay bounded either way.
#
# This hook itself only ever reads the cached pause-state.json for the
# allow/deny decision below — no network calls in the deny path, so it
# stays fast. Fails open (allows the call) if state is missing, stale,
# or unreadable.

CACHE_DIR="/tmp/.glm-quota-cache"
STATE_FILE="${CACHE_DIR}/pause-state.json"
MAX_STATE_AGE=600 # seconds; beyond this we consider the state stale and fail open

TRIGGER_MARKER="${CACHE_DIR}/refresh-trigger.marker"
TRIGGER_INTERVAL=60 # seconds; caps background refresh spawns, independent of tool-call rate

marker_age=999999
if [[ -f "$TRIGGER_MARKER" ]]; then
  marker_ts=$(stat -f %m "$TRIGGER_MARKER" 2>/dev/null || stat -c %Y "$TRIGGER_MARKER" 2>/dev/null || echo 0)
  marker_age=$(( $(date +%s) - marker_ts ))
fi

if (( marker_age >= TRIGGER_INTERVAL )); then
  mkdir -p "$CACHE_DIR" 2>/dev/null
  touch "$TRIGGER_MARKER" 2>/dev/null
  REFRESH_SCRIPT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/scripts/glm_quota_refresh.sh"
  [[ -f "$REFRESH_SCRIPT" ]] && ( bash "$REFRESH_SCRIPT" >/dev/null 2>&1 & )
fi

[[ ! -f "$STATE_FILE" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

state_ts=$(stat -f %m "$STATE_FILE" 2>/dev/null || stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)
now_s=$(date +%s)
age=$(( now_s - state_ts ))
(( age > MAX_STATE_AGE )) && exit 0

decision=$(jq -r '.decision // "CONTINUE"' "$STATE_FILE" 2>/dev/null)
[[ "$decision" != "PAUSE" && "$decision" != "STOP" ]] && exit 0

reason=$(jq -r '.reason // "Quota guard active"' "$STATE_FILE" 2>/dev/null)
resume_local=$(jq -r '.resume_at_local // "unknown"' "$STATE_FILE" 2>/dev/null)
resume_seconds=$(jq -r '.resume_in_seconds // empty' "$STATE_FILE" 2>/dev/null)

message="Quota guard (${decision}): ${reason} Resume at: ${resume_local}"
if [[ -n "$resume_seconds" ]]; then
  message+=" (in ${resume_seconds}s). Call ScheduleWakeup with delaySeconds=${resume_seconds} to resume this workflow automatically, then stop for now."
else
  message+=". Call ScheduleWakeup once you know the resume time, then stop for now."
fi

jq -n \
  --arg reason "$message" \
  '{hookSpecificOutput: {permissionDecision: "deny"}, systemMessage: $reason}'
exit 0
