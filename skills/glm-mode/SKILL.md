---
name: glm-mode
description: This skill provides context about the GLM/Zai mode in Claude Code. It is used by other plugin components (quota skill, MCP coherence hook) to understand the current mode, required MCP servers, and API configuration. Triggers when the user mentions "GLM mode", "Zai mode", "which MCP for GLM", or when internal plugin components need GLM mode context.
---

## Purpose

Provide authoritative knowledge about GLM/Zai mode configuration in Claude Code, including mode detection, required MCP servers, and API endpoints.

## Mode Detection

GLM mode is active when `settings.json` contains:

```json
"ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic"
```

Detection logic: check if the env var `ANTHROPIC_BASE_URL` matches `*api.z.ai*` or `*bigmodel.cn*`.

## Required MCP Servers (GLM mode only)

When GLM mode is active, these 4 MCP servers must be in `enabledMcpjsonServers`:

1. `zai-mcp-server` — Zai vision/image analysis tools
2. `web-reader` — URL content fetching via Zai
3. `zread` — GitHub repository reading via Zai
4. `duckduckgo` — DuckDuckGo search via Zai

When GLM mode is NOT active (Claude Pro), these 4 must be removed from `enabledMcpjsonServers`.

## API Endpoints

| Purpose | URL |
|---------|-----|
| Base | `${ANTHROPIC_BASE_URL}` (resolves to `https://api.z.ai/api/anthropic`) |
| Quota | `${BASE}/api/monitor/usage/quota/limit` |
| Auth header | `Authorization: ${ANTHROPIC_AUTH_TOKEN}` |

## Settings Files

| File | Role |
|------|------|
| `~/.claude/settings.json` | Active config (currently GLM) |
| `~/.claude/settings.json_glm` | GLM reference |
| `~/.claude/settings.json_claude` | Claude Pro reference |

## Coherence Rules

- `enabledMcpjsonServers` must include the 4 Zai MCPs iff GLM mode is active
- `statusLine.command` should point to the quota script
- Web search: GLM mode → `mcp__duckduckgo__search`, Claude Pro → native `WebSearch`

## Automatic Pause/Resume for Long Workflows

GLM enforces peak-hour multipliers: **14:00–18:00 Beijing time (Asia/Shanghai)**
is 3× quota consumption; the rest of the day is 1–2×. A long-running workflow
should avoid burning quota into that window and should never run a token
window past 100%.

### How it works

1. `scripts/glm_quota_decide.py` runs after every statusline refresh (piggybacked
   in `scripts/quota-statusline.sh`, no extra network calls) and writes
   `/tmp/.glm-quota-cache/pause-state.json` with one of:
   - `CONTINUE` — under budget, proceed normally
   - `PAUSE` — the 5h window is at ≥95%; resume once it resets **and** we're
     outside the 14:00–18:00 Beijing peak window
   - `STOP` — the 7-day window is at ≥95% (takes priority over the 5h state);
     resume only at the 7-day reset time, no matter what the 5h window says
2. The `PreToolUse` hook `hooks/scripts/quota-guard.sh` reads only that cached
   file (no network call, fails open if missing/stale) and, when the state is
   `PAUSE` or `STOP`, denies the `Bash`/`Task` call with a `systemMessage`
   containing `resume_at_local` and `resume_in_seconds`.

### What the agent must do when denied

When a tool call is denied by this guard:

1. Read `resume_in_seconds` (or `resume_at_local`) from the hook's message.
2. Call **`ScheduleWakeup`** with that delay and a reason like "GLM quota
   guard: resuming after 5h reset, outside peak hours".
3. Tell the user in one short sentence that the workflow is pausing and when
   it will resume automatically. Do not ask for confirmation — this is fully
   automatic.
4. No manual checkpoint is needed: the conversation state is already
   preserved; `ScheduleWakeup` simply re-enters the turn later, at which point
   the guard hook re-checks quota and either allows the call or denies again.
