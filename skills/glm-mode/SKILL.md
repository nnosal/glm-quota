---
name: glm-mode
description: This skill provides context about the GLM/Zai mode in Claude Code. It is used by other plugin components (quota skill, MCP coherence hook) to understand the current mode, required MCP servers, and API configuration. Triggers when the user mentions "GLM mode", "Zai mode", "which MCP for GLM", or when internal plugin components need GLM mode context.
---

## Purpose

Provide authoritative knowledge about GLM/Zai mode configuration in Claude Code, including mode detection, required MCP servers, and API endpoints.

## Mode Detection

GLM mode requires **both**:

1. `GLM_QUOTA_ACTIVE=1` in the process environment — the sole activation gate.
   Set this only where Claude Code is actually launched against Z.ai (e.g. a
   dedicated mise/shell task's `env` block), never globally in a shell rc
   file. `ANTHROPIC_BASE_URL` alone is not trusted for activation: it can
   linger in a shell environment from an unrelated session and would
   otherwise make a plain Claude/Anthropic session falsely report as GLM.
2. `ANTHROPIC_BASE_URL` matching `*api.z.ai*` or `*bigmodel.cn*` — used to
   pick the actual API host once GLM mode is confirmed active.

Detection logic (all three plugin components — statusline, pause/resume
decision script, MCP coherence hook — implement this the same way):

```bash
[[ "$GLM_QUOTA_ACTIVE" == "1" && "$ANTHROPIC_BASE_URL" =~ api\.z\.ai|bigmodel\.cn ]]
```

The MCP coherence hook additionally falls back to grepping a static
`ANTHROPIC_BASE_URL` out of `~/.claude/settings.json` for setups that swap
`settings.json` wholesale (`settings.json_glm` / `settings.json_claude`)
instead of using the env-var flag.

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

Applies in **both** GLM and native Claude/Anthropic sessions — same
threshold logic, one difference: GLM enforces a peak-hour multiplier
(**14:00–18:00 Beijing time / Asia/Shanghai** is 3× quota consumption; the
rest of the day is 1–2×), so GLM resume times avoid that window. Native
Claude has no time-of-day multiplier, so resume is simply "whenever the
window resets."

### How it works

1. `scripts/glm_quota_decide.py` reads the cached quota (Z.ai `quota.json`
   in GLM mode, or `claude-native-quota.json` outside it) and writes
   `/tmp/.glm-quota-cache/pause-state.json` with one of:
   - `CONTINUE` — under budget, proceed normally
   - `PAUSE` — the 5h window is at ≥95%; resume once it resets (GLM mode
     additionally waits until we're outside the 14:00–18:00 Beijing peak
     window)
   - `STOP` — the 7-day window is at ≥95% (takes priority over the 5h
     state); resume only at the 7-day reset time, no matter what the 5h
     window says
2. `scripts/glm_quota_refresh.sh` is what actually keeps the underlying
   quota data current: fetches Z.ai in GLM mode or the Keychain-based
   native fallback otherwise (each respecting its own TTL — 300s/120s —
   so this never spams the API), then runs `glm_quota_decide.py`. This
   script is shared and triggered from **two** places:
   - `scripts/quota-statusline.sh`, for display, on Claude Code's own
     refresh cadence (new message, `/compact`, etc.)
   - `hooks/scripts/quota-guard.sh` itself, on every `Bash`/`Task` call —
     **decoupling freshness from the statusline**. A long autonomous
     workflow can leave the statusline quiet for minutes while still
     hammering tool calls, which used to mean pause-state.json went stale
     exactly when it mattered most. The hook now self-triggers a refresh,
     throttled to once per 60s (`refresh-trigger.marker`) regardless of
     how many tool calls fire in between — so no per-call process spawn,
     and no extra network calls beyond what the TTLs above already allow.
3. The `PreToolUse` hook `hooks/scripts/quota-guard.sh` reads the cached
   `pause-state.json` for its own allow/deny decision (no network call in
   that path, fails open if missing/stale) and, when the state is `PAUSE`
   or `STOP`, denies the call with a `systemMessage` containing
   `resume_at_local` and `resume_in_seconds`. Note: the refresh triggered
   by *this* call is fire-and-forget — it won't affect the current call's
   own decision, only the next one's.

### What the agent must do when denied

When a tool call is denied by this guard:

1. Read `resume_in_seconds` (or `resume_at_local`) from the hook's message.
2. Call **`ScheduleWakeup`** with that delay and a reason like "quota
   guard: resuming after 5h reset" (add "outside peak hours" for GLM).
3. Tell the user in one short sentence that the workflow is pausing and when
   it will resume automatically. Do not ask for confirmation — this is fully
   automatic.
4. No manual checkpoint is needed: the conversation state is already
   preserved; `ScheduleWakeup` simply re-enters the turn later, at which point
   the guard hook re-checks quota and either allows the call or denies again.

### Known limitations

- The `PreToolUse` matcher is `Bash|Task` — it does not match a top-level
  `Workflow` tool call directly, only the `Bash`/`Task` calls nested inside
  it. A workflow that crashes on a hard `429` before any of those nested
  calls got denied won't have had a chance to call `ScheduleWakeup` — the
  guard can only prevent *future* calls, not undo a rejection that already
  happened at the model-inference layer, which no hook type can intercept.
- If a session's process exits entirely (crash, hard `429`), nothing calls
  `ScheduleWakeup` for it — there's no live agent left to make that call.
  Resuming an interrupted session/workflow after that point is manual
  (`--resume`, then `Workflow({scriptPath, resumeFromRunId})`).
