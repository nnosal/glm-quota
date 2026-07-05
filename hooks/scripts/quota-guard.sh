#!/bin/bash
# PreToolUse hook: blocks costly tool calls when the quota guard says
# PAUSE/STOP — GLM peak-hour aware in GLM mode, flat threshold otherwise
# (native Claude 5h/7d limits). Reads only the cached pause-state.json
# written by glm_quota_decide.py — no network calls here, so this stays
# fast enough for a per-tool-call hook. Fails open (allows the call) if
# state is missing, stale, or unreadable.

STATE_FILE="/tmp/.glm-quota-cache/pause-state.json"
MAX_STATE_AGE=600 # seconds; beyond this we consider the state stale and fail open

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
