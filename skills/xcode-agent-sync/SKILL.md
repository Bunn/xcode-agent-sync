---
name: xcode-agent-sync
description: "Sync the selected Xcode's agent skills and the Xcode MCP server (xcrun mcpbridge) into Claude Code and Codex, then verify the agent matches the newest Xcode. Use after installing or updating Xcode (including betas), when Xcode skills look stale or missing, when the `xcode` MCP server isn't connecting, or when the user asks to update, install, export, or check Xcode skills or MCP for their coding agent."
---

# Xcode Agent Sync

Xcode ships agent skills and an MCP server that change with every release.
This skill brings Claude Code and Codex up to date with the selected Xcode in a
single run. The deterministic work lives in `scripts/sync.sh`. Your job is to run it,
read its report, and help the user resolve anything it flags.

## Run it

Run the script from this skill's directory (use the absolute path):

```bash
bash <skill-dir>/scripts/sync.sh
```

It will:

1. Confirm `xcode-select` points to a full Xcode and warn if a **newer Xcode
   is installed but not selected**.
2. Copy the Xcode-provided skills for each agent it finds:
   - Claude Code → `~/.claude/skills/`
   - Codex → `~/.agents/skills/`

   The source is Xcode's packaged agent plugin (`xcrun agent plugin path`),
   which carries every skill in an agent-specific form. The script falls back to
   `xcrun agent skills export` on older Xcodes, and when the plugin ships no
   skills (Xcode 27.2). Only skills it installed are
   updated or removed (tracked in `.xcode-agent-sync` in each skills dir).
   The user's own skills are never touched.
3. Add the `xcode` MCP server (`xcrun mcpbridge`) if it's missing: user
   scope for Claude, global config for Codex.
4. Check the Xcode setting "Allow external agents to use Xcode tools" and
   run a live MCP handshake with Xcode to confirm the tools respond.

Useful flags: `--check` (report only, exits 2 on drift), `--agent claude|codex`
(limit to one agent), `--no-probe` (skip the live handshake), `--update-clis`
(also run `claude update` / `codex update`; ask the user first).

## After it runs

Summarize the result for the user in a few lines: Xcode version/build, which
skills were added, updated, or removed per agent, the MCP status, and the probe
result. Then handle anything flagged:

| Report says | What to do |
| --- | --- |
| Newer Xcode installed but not selected | Show the user the `sudo xcode-select -s …` command from the report. Don't run sudo yourself. Re-run the sync after they switch. |
| External-agents setting looks off / probe failed | Ask the user to turn on Xcode > Settings > Intelligence > Model Context Protocol > "Allow external agents to use Xcode tools", approve any prompt Xcode shows, then re-run. |
| Xcode isn't running | Ask the user to open Xcode (ideally with their project), then re-run to verify. |
| MCP exists but doesn't run `xcrun mcpbridge` | Show the fix command from the report and run it only if the user agrees, since it replaces their config. |
| Duplicate copy in `~/.codex/skills` | Explain that Codex also loads that legacy folder. Offer to remove the stale copy. |
| `CLI not on PATH` | The skills were still installed. Point the user to Apple's command for adding the MCP server once the CLI is installed. |
| "Restart your agent sessions" | Tell the user that new skills and MCP servers load in a **new** session, including this one. |

If the user wants to know whether their agent CLI is current, report the
versions the script printed and offer to re-run with `--update-clis`.

Never edit the synced Xcode skills by hand, because the next sync overwrites them.
