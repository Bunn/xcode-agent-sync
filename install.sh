#!/usr/bin/env bash
# Install the xcode-agent-sync skill for Claude Code and Codex.
#
#   ./install.sh          symlink the skill (a later `git pull` updates it)
#   ./install.sh --copy   copy it instead
#   ./install.sh --run    install, then run the sync right away

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_SRC="$REPO_DIR/skills/xcode-agent-sync"
MODE="link"
RUN=0

for arg in "$@"; do
  case "$arg" in
    --copy) MODE="copy" ;;
    --run) RUN=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option '$arg'" >&2; exit 1 ;;
  esac
done

install_into() {
  local dir="$1" dest="$1/xcode-agent-sync"
  mkdir -p "$dir"
  if [ -L "$dest" ] || [ -e "$dest" ]; then
    rm -rf "$dest"
  fi
  if [ "$MODE" = "link" ]; then
    ln -s "$SKILL_SRC" "$dest"
  else
    cp -R "$SKILL_SRC" "$dest"
  fi
  echo "✔ $dest"
}

install_into "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"   # Claude Code
install_into "$HOME/.agents/skills"                         # Codex (and other Agent Skills clients)

echo
echo "Start a new agent session, then ask it to \"sync Xcode skills\" (or run /xcode-agent-sync in Claude Code)."

if [ "$RUN" -eq 1 ]; then
  echo
  exec bash "$SKILL_SRC/scripts/sync.sh"
fi
