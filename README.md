<p align="center">
  <strong>glm-quota</strong>
</p>

<p align="center">
  See your context usage and Z.ai quota — right in your Claude Code statusline.
</p>

<p align="center">
  <a href="https://claude.ai/code"><img src="https://img.shields.io/badge/Claude%20Code-Plugin-blue" alt="Claude Code Plugin"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
</p>

---

When you use Claude Code with Z.ai/GLM, you get rate-limited across token windows and MCP calls — but there's no built-in way to see where you stand. glm-quota gives you that visibility in a single line, updated on every turn. It also shows your context window usage so you know when to `/compact` before quality starts dropping.

## Statusline

```
⟡ glm-5.1 [1M] │ Ctx:█████░░░░░ 52% │ 520k/1000k │ ⚡ /compact │ 5h:██░░░░░░░░ 22% ↻3h │ 7j:█░░░░░░░░░ 8% ↻6j │ MCP:172/4000 ↻18h
```

**Model + context** — your current model, a visual bar of context usage, the token counter, and a `⚡ /compact` reminder that appears past 50%. Always shown.

**Quota** — in GLM mode: your Z.ai quota (5-hour and 7-day token windows, MCP tool call usage, reset countdowns). Outside GLM mode: the same 5-hour/7-day rate limits Anthropic reports natively for your Claude plan (identical numbers to the claude.ai usage page) — no API calls needed, Claude Code already sends this data to every statusline script. Appears only after your first message in a fresh session (Anthropic only populates it after the first API response).

GLM quota only ever shows when both `GLM_QUOTA_ACTIVE=1` is set in the environment (e.g. by the task/script that launches Claude Code against Z.ai) and `ANTHROPIC_BASE_URL` points at Z.ai — never based on a leftover `ANTHROPIC_BASE_URL` alone. Everywhere else, the quota segment falls back to native Claude plan usage, or is omitted entirely if neither is available.

## Automatic pause/resume around peak hours

GLM peak hours (14:00–18:00 Beijing time) run at 3× quota consumption. This fork adds a guard that:

- Watches your 5-hour and 7-day token windows via the same cached quota data as the statusline
- Automatically pauses a running workflow before either window hits 95%
- Prefers resuming outside peak hours when only the 5h window is tight; if the 7-day window itself is near its limit, it waits for the 7-day reset regardless of peak hours
- Resumes on its own — no confirmation needed — by scheduling the next check at the right time

## Installation

This fork bundles its own marketplace file, so it installs directly — no separate marketplace repo needed.

```bash
claude plugin marketplace add nnosal/glm-quota
claude plugin install glm-quota
```

The plugin's hooks (MCP coherence check, pause/resume guard) activate automatically once installed. The status line itself has to be wired up separately, since Claude Code has no environment-variable override for it — only `settings.json` or the CLI's `--settings` flag can set it.

### Recommended: activate per-launch with `--settings`, not `settings.json`

Rather than permanently adding `statusLine` to `~/.claude/settings.json` (which would apply it to every Claude Code session, everywhere), inject it only where you actually launch Claude Code — a shell function or a `mise`/task-runner wrapper — using the `--settings` CLI flag:

```bash
cc() {
  if [ "${GLM_STATUS_LINE:-1}" = "1" ]; then
    local status_cmd='bash "$(find ~/.claude/plugins/cache/nnosal-glm-quota -iname quota-statusline.sh 2>/dev/null | head -1)" --mode bar'
    local settings_json
    settings_json=$(jq -nc --arg cmd "$status_cmd" '{statusLine:{type:"command",command:$cmd,padding:0}}')
    claude --settings "$settings_json" "$@"
  else
    claude "$@"
  fi
}
```

The `find` call resolves the plugin's cache path dynamically (it includes a version folder like `1.0.0` that changes on every update), so this never needs editing after a `claude plugin update`. Set `GLM_STATUS_LINE=0` to launch without the status line when needed. This same pattern works whether you're launching a native Claude session or a GLM one (e.g. inside a `mise` task that also sets `GLM_QUOTA_ACTIVE=1`).

### Alternative: `settings.json`

If you do want it globally, add this to `~/.claude/settings.json` instead:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"$(find ~/.claude/plugins/cache/nnosal-glm-quota -iname quota-statusline.sh 2>/dev/null | head -1)\" --mode bar",
    "padding": 0
  }
}
```

Restart Claude Code and you're good to go.

## What's checked on startup

Each time you start a session, the plugin verifies that your Z.ai MCP servers are correctly enabled or disabled based on your current mode. If something looks off, you get a warning with a fix suggestion — no silent failures.

## Requirements

- Claude Code CLI
- A Z.ai / GLM account with API access
- `curl` and `jq` (standard on macOS/Linux)

## License

[MIT](LICENSE) — use it, fork it, improve it.
