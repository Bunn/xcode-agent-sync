# xcode-agent-sync

Each new Xcode release ships updated **agent skills** (SwiftUI, App Intents,
xctrace, accessibility, translation, and more) along with the **Xcode MCP server**
(`xcrun mcpbridge`). External agents don't pick these up on their own.
`xcode-agent-sync` is an [Agent Skill](https://agentskills.io) for **Claude
Code** and **Codex** that does the full update in one step:

- Installs the selected Xcode's skills into each agent. Missing skills are added, changed ones are updated,
  and skills Xcode dropped are removed. Your own skills are never touched.
- Adds the `xcode` MCP server when it's missing, following
  [Apple's instructions](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode).
- Verifies the result: the newest installed Xcode is the one selected, the
  "Allow external agents" setting is on, and a live MCP handshake with Xcode lists its tools.

```
== Xcode ==
  ✔ Selected Xcode 27.2 (27B52) at /Applications/Xcode.app
  ✔ This is the newest Xcode installed

== Claude Code ==
  · CLI: 2.1.296 (Claude Code)
  ✔ Installed: accessibility-dynamic-type-specialist … translation xctrace
  ✔ MCP 'xcode' configured (User config (available in all your projects))

== Codex ==
  · CLI: codex-cli 0.154.0
  ✔ 16 skills match Xcode 27.2 (27B52)
  ✔ Added MCP 'xcode': xcrun mcpbridge

== Xcode MCP connection ==
  ✔ "Allow external agents to use Xcode tools" is on
  ✔ Bridge reached Xcode, xcode-tools 25464: 54 tools
```

## Install

```bash
git clone https://github.com/Bunn/xcode-agent-sync.git
```

```bash
./xcode-agent-sync/install.sh --run
```

`install.sh` symlinks the skill into `~/.claude/skills` and `~/.agents/skills`,
so a later `git pull` updates it. Pass `--copy` to copy it instead.

Other options:

- **Claude Code plugin:** `/plugin marketplace add Bunn/xcode-agent-sync`, then
  `/plugin install xcode-agent-sync@xcode-agent-sync`.
- **Any Agent Skills client:** `npx skills add Bunn/xcode-agent-sync`.

## Use

After installing a new Xcode, ask your agent to *"sync Xcode skills"* (or run
`/xcode-agent-sync` in Claude Code). The agent runs the script, summarizes the
result, and walks you through anything that needs your attention, such as
switching `xcode-select` or turning on the Xcode setting. Afterward, start a new
session so it loads the new skills and MCP server.

You can also run the script directly, without an agent:

```bash
skills/xcode-agent-sync/scripts/sync.sh            # sync everything found
skills/xcode-agent-sync/scripts/sync.sh --check    # report only; exit 2 on drift
skills/xcode-agent-sync/scripts/sync.sh --agent codex --no-probe
skills/xcode-agent-sync/scripts/sync.sh --update-clis   # also run claude/codex update
```

## How it works

| Step | Detail |
| --- | --- |
| Skill source | `xcrun agent plugin path --plugin-format <claude\|codex>`: Xcode's packaged plugin, which carries the complete skill set in each agent's format. Falls back to `xcrun agent skills export` on Xcodes without plugin support, or whose plugin ships no skills (Xcode 27.2). |
| Skill targets | Claude Code: `~/.claude/skills` (or `$CLAUDE_CONFIG_DIR/skills`). Codex: `~/.agents/skills`. Override with `XAS_CLAUDE_SKILLS_DIR` / `XAS_CODEX_SKILLS_DIR`. |
| Ownership | A `.xcode-agent-sync` manifest in each skills dir lists the skills the script manages, so it never deletes skills it didn't install. |
| Up to date? | Each installed skill is compared file by file (`diff -r`) against what the selected Xcode ships. A version number alone could miss a changed skill. |
| MCP | `claude mcp add -s user --transport stdio xcode -- xcrun mcpbridge` and `codex mcp add xcode -- xcrun mcpbridge`, run only when missing. |
| Verification | Reads the Xcode setting, then runs an MCP `initialize` + `tools/list` against `xcrun mcpbridge` (only when Xcode is running). |

The script needs nothing beyond macOS and Xcode (`bash` 3.2, `rsync`, `python3`).

## Requirements

- macOS with Xcode 26.3 or later (the release that added `xcrun mcpbridge`)
- Claude Code and/or Codex CLI
- Xcode > Settings > Intelligence > **Allow external agents to use Xcode tools**

## License

MIT
