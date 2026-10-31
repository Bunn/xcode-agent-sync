#!/usr/bin/env bash
# xcode-agent-sync — install the selected Xcode's agent skills and MCP server
# into Claude Code and Codex, then verify the result.
#
# Safe to re-run: it only touches skills it installed (tracked in a manifest)
# and only adds the MCP server when it is missing.
#
# Compatible with the stock macOS /bin/bash (3.2).

set -euo pipefail

VERSION="1.0.0"
MCP_NAME="xcode"
MANIFEST_NAME=".xcode-agent-sync"

CLAUDE_SKILLS_DIR="${XAS_CLAUDE_SKILLS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills}"
CODEX_SKILLS_DIR="${XAS_CODEX_SKILLS_DIR:-$HOME/.agents/skills}"
CODEX_LEGACY_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"

usage() {
  cat <<EOF
xcode-agent-sync $VERSION

Sync Xcode-provided agent skills and the Xcode MCP server into Claude Code
and Codex, then verify everything matches the selected Xcode.

USAGE: sync.sh [options]

OPTIONS:
  --agent <claude|codex>  Only sync this agent (repeatable). Default: every
                          agent found on this Mac.
  --check                 Report drift without changing anything. Exits 2 if
                          anything is out of date.
  --no-probe              Skip the live MCP handshake with Xcode.
  --update-clis           Also run 'claude update' / 'codex update'.
  -h, --help              Show this help.

ENVIRONMENT:
  XAS_CLAUDE_SKILLS_DIR   Claude skills dir   (default: ~/.claude/skills)
  XAS_CODEX_SKILLS_DIR    Codex skills dir    (default: ~/.agents/skills)

EXIT CODES: 0 ok · 1 error · 2 drift found (--check)
EOF
}

CHECK_ONLY=0
PROBE=1
UPDATE_CLIS=0
AGENTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)
      [ $# -ge 2 ] || { echo "error: --agent needs a value" >&2; exit 1; }
      case "$2" in claude|codex) AGENTS="$AGENTS $2" ;; *) echo "error: unknown agent '$2'" >&2; exit 1 ;; esac
      shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --no-probe) PROBE=0; shift ;;
    --update-clis) UPDATE_CLIS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_B=""; C_0=""
fi

ERRORS=0
DRIFT=0
CHANGED=0

section() { printf '\n%s== %s ==%s\n' "$C_B" "$1" "$C_0"; }
ok()      { printf '  %s✔%s %s\n' "$C_OK" "$C_0" "$1"; }
info()    { printf '  %s·%s %s\n' "$C_DIM" "$C_0" "$1"; }
warn()    { printf '  %s!%s %s\n' "$C_WARN" "$C_0" "$1"; }
fail()    { printf '  %s✘%s %s\n' "$C_ERR" "$C_0" "$1"; ERRORS=$((ERRORS + 1)); }
drift()   { printf '  %s↻%s %s\n' "$C_WARN" "$C_0" "$1"; DRIFT=$((DRIFT + 1)); }

WORK="$(mktemp -d -t xcode-agent-sync)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- xcode

section "Xcode"

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEV_DIR" in
  "") fail "No developer directory selected. Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"; exit 1 ;;
  *CommandLineTools*) fail "xcode-select points at Command Line Tools, not Xcode. Run: sudo xcode-select -s /Applications/Xcode.app"; exit 1 ;;
esac

XCODE_APP="${DEV_DIR%/Contents/Developer}"
plist_version() { /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo "0"; }
XCODE_VERSION="$(plist_version "$XCODE_APP")"
XCODE_BUILD="$(xcodebuild -version 2>/dev/null | awk '/Build version/ {print $3}')"
ok "Selected Xcode $XCODE_VERSION ($XCODE_BUILD) at $XCODE_APP"

# Warn when a newer Xcode is installed but not selected (e.g. a fresh beta).
NEWEST_APP="$XCODE_APP"
NEWEST_VERSION="$XCODE_VERSION"
while IFS= read -r app; do
  [ -d "$app" ] || continue
  v="$(plist_version "$app")"
  if [ "$(printf '%s\n%s\n' "$NEWEST_VERSION" "$v" | sort -V | tail -n1)" != "$NEWEST_VERSION" ]; then
    NEWEST_APP="$app"; NEWEST_VERSION="$v"
  fi
done < <( { mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null || true
            ls -d /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app 2>/dev/null || true; } | sort -u)
if [ "$NEWEST_APP" != "$XCODE_APP" ]; then
  warn "Newer Xcode $NEWEST_VERSION is installed at $NEWEST_APP but not selected."
  info "To use it: sudo xcode-select -s \"$NEWEST_APP\"  (then re-run this sync)"
else
  ok "This is the newest Xcode installed"
fi

if ! xcrun --find mcpbridge >/dev/null 2>&1; then
  fail "This Xcode has no agent support (xcrun mcpbridge not found). Xcode 26.3 or later is required."
  exit 1
fi

# ---------------------------------------------------------------- agents

has_agent() {
  case "$1" in
    claude) command -v claude >/dev/null 2>&1 || [ -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ] ;;
    codex)  command -v codex  >/dev/null 2>&1 || [ -d "${CODEX_HOME:-$HOME/.codex}" ] ;;
  esac
}

if [ -z "$AGENTS" ]; then
  for a in claude codex; do if has_agent "$a"; then AGENTS="$AGENTS $a"; fi; done
fi
if [ -z "$AGENTS" ]; then
  fail "Neither Claude Code nor Codex was found. Install one, or pass --agent."
  exit 1
fi

skills_dir_for() {
  case "$1" in claude) echo "$CLAUDE_SKILLS_DIR" ;; codex) echo "$CODEX_SKILLS_DIR" ;; esac
}

# Prints the directory holding this Xcode's skills, formatted for the agent.
# Prefers the packaged plugin (agent-specific, superset of 'skills export');
# falls back to 'skills export' when the plugin is missing or ships no skills
# (Xcode 27.2 materializes an empty plugin skills dir).
source_skills_dir() {
  local agent="$1" p out
  if p="$(xcrun agent plugin path --plugin-format "$agent" 2>/dev/null)" && [ -n "$(list_skills "$p/skills")" ]; then
    echo "$p/skills"
    return
  fi
  out="$WORK/export-$agent"
  if xcrun agent skills export --output-dir "$out" --replace-existing >/dev/null 2>&1 && [ -d "$out" ]; then
    echo "$out"
    return
  fi
  return 1
}

# Skill names (one per line) in a source dir: subdirectories with a SKILL.md.
list_skills() {
  local d
  for d in "$1"/*/; do
    if [ -f "$d/SKILL.md" ]; then basename "$d"; fi
  done | sort
}

# 'skills export' writes SKILL.md frontmatter keys in a different order on each
# run, so frontmatter lines are compared sorted and the body as-is.
normalized_skill_md() {
  if [ "$(head -n1 "$1")" = "---" ]; then
    sed -n '1,/^---$/p' "$1" | sort
    sed '1,/^---$/d' "$1"
  else
    cat "$1"
  fi
}

same_skill() {
  diff -rq -x SKILL.md "$1" "$2" >/dev/null 2>&1 &&
    [ -f "$1/SKILL.md" ] && [ -f "$2/SKILL.md" ] &&
    [ "$(normalized_skill_md "$1/SKILL.md")" = "$(normalized_skill_md "$2/SKILL.md")" ]
}

# Skill names recorded by a previous sync (manifest lines after the header).
manifest_skills() {
  if [ -f "$1" ]; then grep -v '^#' "$1" | sed '/^$/d' | sort; fi
}

manifest_build() {
  if [ -f "$1" ]; then sed -n 's/^# build: //p' "$1"; fi
}

sync_skills() {
  local agent="$1" src dest manifest names old n
  local added="" updated="" removed="" src_kind="plugin"

  if ! src="$(source_skills_dir "$agent")"; then
    fail "Could not get skills from Xcode for $agent (xcrun agent plugin path / skills export both failed)"
    return
  fi
  case "$src" in "$WORK"/*) src_kind="skills export" ;; esac
  dest="$(skills_dir_for "$agent")"
  manifest="$dest/$MANIFEST_NAME"
  names="$(list_skills "$src")"
  old="$(manifest_skills "$manifest")"

  if [ -z "$names" ]; then
    fail "Xcode returned no skills for $agent"
    return
  fi
  info "Source: $src ($src_kind, $(echo "$names" | wc -l | tr -d ' ') skills)"
  info "Target: $dest"

  for n in $names; do
    if [ ! -d "$dest/$n" ]; then
      added="$added $n"
    elif ! same_skill "$src/$n" "$dest/$n"; then
      updated="$updated $n"
    fi
  done
  # Skills a previous sync installed that this Xcode no longer ships.
  for n in $old; do
    case "$n" in */*|.*|"") continue ;; esac
    if ! grep -qx "$n" <<<"$names" && [ -d "$dest/$n" ]; then
      removed="$removed $n"
    fi
  done

  if [ -z "$added$updated$removed" ]; then
    if [ "$(manifest_build "$manifest")" != "$XCODE_BUILD" ] && [ "$CHECK_ONLY" -eq 0 ]; then
      write_manifest "$manifest" "$names"
    fi
    ok "$(echo "$names" | wc -l | tr -d ' ') skills match Xcode $XCODE_VERSION ($XCODE_BUILD)"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    if [ -n "$added" ]; then drift "Missing:$added"; fi
    if [ -n "$updated" ]; then drift "Outdated:$updated"; fi
    if [ -n "$removed" ]; then drift "No longer shipped by Xcode:$removed"; fi
  else
    mkdir -p "$dest"
    for n in $added $updated; do
      rsync -a --delete "$src/$n/" "$dest/$n/"
      chmod -R u+w "$dest/$n"  # Xcode ships these read-only
    done
    for n in $removed; do
      rm -rf "${dest:?}/${n:?}"
    done
    write_manifest "$manifest" "$names"
    CHANGED=$((CHANGED + 1))
    if [ -n "$added" ]; then ok "Installed:$added"; fi
    if [ -n "$updated" ]; then ok "Updated:$updated"; fi
    if [ -n "$removed" ]; then ok "Removed (no longer shipped):$removed"; fi
  fi

  # Codex also reads its legacy skills dir; same-named copies there go stale.
  if [ "$agent" = "codex" ] && [ "$CODEX_LEGACY_SKILLS_DIR" != "$dest" ]; then
    for n in $names; do
      if [ -d "$CODEX_LEGACY_SKILLS_DIR/$n" ]; then warn "Duplicate copy at $CODEX_LEGACY_SKILLS_DIR/$n may shadow the synced one. Consider removing it."; fi
    done
  fi
}

write_manifest() {
  {
    echo "# Managed by xcode-agent-sync — skills listed here are replaced on each sync."
    echo "# xcode: $XCODE_VERSION"
    echo "# build: $XCODE_BUILD"
    echo "# synced: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "$2"
  } > "$1"
}

# Checks the agent's "xcode" MCP entry; adds it at user scope when missing.
sync_mcp() {
  local agent="$1" out
  if ! command -v "$agent" >/dev/null 2>&1; then
    warn "'$agent' CLI not on PATH, so the MCP server can't be configured. Install the CLI or add it manually:"
    info "$agent mcp add ... xcode -- xcrun mcpbridge"
    return
  fi

  case "$agent" in
    claude)
      if out="$(claude mcp get "$MCP_NAME" 2>&1)"; then
        if grep -q 'Command: xcrun' <<<"$out" && grep -q 'Args: mcpbridge' <<<"$out"; then
          ok "MCP '$MCP_NAME' configured ($(echo "$out" | sed -n 's/^ *Scope: //p'))"
          if grep -qi 'status:.*fail' <<<"$out"; then
            warn "Claude reports the server failed to connect. Is Xcode running?"
          fi
        else
          fail "MCP '$MCP_NAME' exists but does not run 'xcrun mcpbridge'. Fix with: claude mcp remove $MCP_NAME && claude mcp add -s user --transport stdio $MCP_NAME -- xcrun mcpbridge"
        fi
      elif [ "$CHECK_ONLY" -eq 1 ]; then
        drift "MCP '$MCP_NAME' not configured"
      else
        claude mcp add -s user --transport stdio "$MCP_NAME" -- xcrun mcpbridge >/dev/null
        CHANGED=$((CHANGED + 1))
        ok "Added MCP '$MCP_NAME' (user scope): xcrun mcpbridge"
      fi
      ;;
    codex)
      if out="$(codex mcp get "$MCP_NAME" --json 2>/dev/null)"; then
        if echo "$out" | /usr/bin/python3 -I -c '
import json, sys
c = json.load(sys.stdin)
t = c.get("transport", c)
sys.exit(0 if t.get("command") == "xcrun" and t.get("args") == ["mcpbridge"] else 1)
'; then
          ok "MCP '$MCP_NAME' configured"
        else
          fail "MCP '$MCP_NAME' exists but does not run 'xcrun mcpbridge'. Fix with: codex mcp remove $MCP_NAME && codex mcp add $MCP_NAME -- xcrun mcpbridge"
        fi
      elif [ "$CHECK_ONLY" -eq 1 ]; then
        drift "MCP '$MCP_NAME' not configured"
      else
        codex mcp add "$MCP_NAME" -- xcrun mcpbridge >/dev/null
        CHANGED=$((CHANGED + 1))
        ok "Added MCP '$MCP_NAME': xcrun mcpbridge"
      fi
      ;;
  esac
}

for agent in $AGENTS; do
  case "$agent" in claude) section "Claude Code" ;; codex) section "Codex" ;; esac
  if command -v "$agent" >/dev/null 2>&1; then
    info "CLI: $("$agent" --version 2>/dev/null | head -n1)"
    if [ "$UPDATE_CLIS" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
      info "Running '$agent update'…"
      if "$agent" update >"$WORK/update-$agent.log" 2>&1; then
        ok "$agent update: $(tail -n1 "$WORK/update-$agent.log")"
      else
        warn "$agent update failed: $(tail -n1 "$WORK/update-$agent.log")"
      fi
    fi
  fi
  sync_skills "$agent"
  sync_mcp "$agent"
done

# ---------------------------------------------------------------- verify

section "Xcode MCP connection"

setting="$(defaults read com.apple.dt.Xcode IDEAllowUnauthenticatedAgents 2>/dev/null || true)"
case "$setting" in
  1) ok "\"Allow external agents to use Xcode tools\" is on" ;;
  0) warn "\"Allow external agents to use Xcode tools\" looks off. Turn it on in Xcode > Settings > Intelligence > Model Context Protocol." ;;
  *) info "Couldn't read the external-agents setting; the live probe below will confirm it." ;;
esac

if [ "$PROBE" -eq 0 ]; then
  info "Live probe skipped (--no-probe)"
elif ! pgrep -xq Xcode; then
  warn "Xcode isn't running, so the live probe was skipped. Open Xcode and re-run to verify end to end."
else
  # Speak just enough MCP to prove the bridge reaches Xcode and lists tools.
  if result="$(/usr/bin/python3 -I - <<'PY' 2>&1
import json, select, subprocess, sys, time

proc = subprocess.Popen(["xcrun", "mcpbridge"], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "xcode-agent-sync", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]
for m in msgs:
    proc.stdin.write((json.dumps(m) + "\n").encode())
proc.stdin.flush()

deadline, buf, server = time.time() + 30, b"", "xcode"
try:
    while time.time() < deadline:
        ready, _, _ = select.select([proc.stdout], [], [], 1)
        if not ready:
            if proc.poll() is not None:
                break
            continue
        chunk = proc.stdout.read1(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "error" in msg:
                print(msg["error"].get("message", "MCP error"))
                sys.exit(1)
            if msg.get("id") == 1:
                info = msg["result"].get("serverInfo", {})
                server = f'{info.get("name", "xcode")} {info.get("version", "")}'.strip()
            if msg.get("id") == 2:
                print(f'{server}: {len(msg["result"].get("tools", []))} tools')
                sys.exit(0)
    err = proc.stderr.read1(4096).decode(errors="replace").strip() if proc.poll() is not None else ""
    print(err or "timed out waiting for Xcode (approve the connection prompt in Xcode if one is showing)")
    sys.exit(1)
finally:
    proc.kill()
PY
)"; then
    ok "Bridge reached Xcode, $result"
  else
    fail "Bridge couldn't reach Xcode: $result"
    info "Check Xcode > Settings > Intelligence > \"Allow external agents to use Xcode tools\", and approve any prompt Xcode shows."
  fi
fi

# ---------------------------------------------------------------- summary

section "Summary"
if [ "$ERRORS" -gt 0 ]; then
  fail "$ERRORS problem(s) need attention (see ✘ above)"
  exit 1
elif [ "$DRIFT" -gt 0 ]; then
  drift "$DRIFT item(s) out of date. Run without --check to sync."
  exit 2
elif [ "$CHANGED" -gt 0 ]; then
  ok "Synced to Xcode $XCODE_VERSION ($XCODE_BUILD)"
  warn "Restart your agent sessions ($(echo $AGENTS | sed 's/ /, /g')) to load the new skills and MCP config."
else
  ok "Everything already matches Xcode $XCODE_VERSION ($XCODE_BUILD)"
fi
