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

When you use Claude Code with Z.ai/GLM, you get rate-limited across token windows and MCP calls — but there's no built-in way to see where you stand. glm-quota gives you that visibility in two lines, updated on every turn. It also shows your context window usage so you know when to `/compact` before quality starts dropping.

## Statusline

```
⟡ glm-5.1 [1M] │ Ctx:█████░░░░░ 52% │ 520k/1000k │ ⚡ /compact
  5h:██░░░░░░░░ 22% ↻3h │ 7j:█░░░░░░░░░ 8% ↻6j │ MCP:172/4000 ↻18h
```

**Line 1** — your current model, a visual bar of context usage, the token counter, and a `⚡ /compact` reminder that appears past 50%.

**Line 2** — in GLM mode: your Z.ai quota (5-hour and 7-day token windows, MCP tool call usage, reset countdowns). Outside GLM mode: the same 5-hour/7-day rate limits Anthropic reports natively for your Claude plan (identical numbers to the claude.ai usage page) — no API calls needed, Claude Code already sends this data to every statusline script.

GLM quota only ever shows when both `GLM_QUOTA_ACTIVE=1` is set in the environment (e.g. by the task/script that launches Claude Code against Z.ai) and `ANTHROPIC_BASE_URL` points at Z.ai — never based on a leftover `ANTHROPIC_BASE_URL` alone. Everywhere else, line 2 falls back to native Claude plan usage, or stays empty if neither is available.

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

Then add this to your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ${HOME}/.claude/plugins/cache/nnosal-glm-quota/glm-quota/1.0.0/scripts/quota-statusline.sh --mode bar",
    "padding": 0
  }
}
```

> The cache path includes a version folder (e.g. `1.0.0`) and can vary. Run `find ~/.claude/plugins/cache/nnosal-glm-quota -iname quota-statusline.sh` after install to confirm the exact path.

Restart Claude Code and you're good to go.

## What's checked on startup

Each time you start a session, the plugin verifies that your Z.ai MCP servers are correctly enabled or disabled based on your current mode. If something looks off, you get a warning with a fix suggestion — no silent failures.

## Requirements

- Claude Code CLI
- A Z.ai / GLM account with API access
- `curl` and `jq` (standard on macOS/Linux)

## License

[MIT](LICENSE) — use it, fork it, improve it.
