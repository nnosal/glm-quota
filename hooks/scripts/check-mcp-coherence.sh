#!/bin/bash
# SessionStart hook: verify Zai MCP coherence with active mode
# Returns a message if MCP config is inconsistent, silent otherwise

SETTINGS="$HOME/.claude/settings.json"

ZAI_MPCS=("zai-mcp-server" "web-reader" "zread" "duckduckgo")

is_glm=false
if [[ "${GLM_QUOTA_ACTIVE:-}" == "1" && "${ANTHROPIC_BASE_URL:-}" =~ api\.z\.ai|bigmodel\.cn ]]; then
  # Session launched with the GLM activation flag set (e.g. via a mise/shell
  # task's env block) — authoritative, no need to inspect settings.json.
  is_glm=true
elif [[ -f "$SETTINGS" ]]; then
  # Fallback for setups that swap settings.json wholesale instead of using
  # the env-var flag (e.g. settings.json_glm / settings.json_claude).
  BASE_URL=$(grep -o '"ANTHROPIC_BASE_URL"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS" 2>/dev/null | head -1 | grep -o '"https\?://[^"]*"')
  [[ "$BASE_URL" =~ api\.z\.ai|bigmodel\.cn ]] && is_glm=true
fi

# Extract enabledMcpjsonServers as comma-separated list
enabled=$(grep -A 100 '"enabledMcpjsonServers"' "$SETTINGS" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | paste -sd ',' - 2>/dev/null)

issues=""

for mcp in "${ZAI_MPCS[@]}"; do
  in_enabled=false
  [[ ",$enabled," =~ ",$mcp," ]] && in_enabled=true

  if $is_glm && ! $in_enabled; then
    issues+="  - MISSING: $mcp should be enabled (GLM mode active)\n"
  fi

  if ! $is_glm && $in_enabled; then
    issues+="  - EXTRA: $mcp should be disabled (not GLM mode)\n"
  fi
done

if [[ -n "$issues" ]]; then
  mode_label="Claude Pro"
  $is_glm && mode_label="GLM/Zai"

  echo ""
  echo "⚠ GLM Quota Plugin — MCP coherence check:"
  echo "  Mode detected: $mode_label"
  echo "  Issues found:"
  printf "$issues"
  echo ""
  echo "  Run /glm-quota:fix-mcp to auto-fix, or edit settings.json manually."
  echo ""
fi
