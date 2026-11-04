#!/usr/bin/env bash
# setup.sh — add a second Claude Code login that shares your configuration.
#
#   setup.sh [name]          default name: personal
#
# Creates ~/.claude-<name> and a launcher ~/.local/bin/claude-<name>. Plain
# `claude` keeps using ~/.claude. Then sign in once:  claude-<name> auth login
#
# Why a second config dir: Claude Code keys its login (macOS Keychain item, or
# .credentials.json elsewhere) to the config dir. /login inside a session
# replaces the login for that whole dir, which moves every open session on it.
# A second dir is a second login, and both stay signed in.
#
# Shared by symlink (the list below): settings, CLAUDE.md, skills, agents,
# commands, hooks, plugins, and the session store, so either login can resume
# the other's conversations. Not shared: the login itself, account fields in
# .claude.json, cached org-managed settings, policy limits, running-session
# registry, caches. Add more names with CLAUDE_ACCOUNTS_SHARE_EXTRA="a b".
#
# Idempotent. Undo: claude-<name> auth logout; rm -rf ~/.claude-<name>
# ~/.local/bin/claude-<name> (only symlinks and one .claude.json live there).
set -euo pipefail

NAME="${1:-personal}"
case "$NAME" in *[!a-zA-Z0-9_-]*|"") echo "setup: name must be letters, digits, - or _" >&2; exit 2 ;; esac
SRC="${CLAUDE_MAIN_DIR:-$HOME/.claude}"
DST="$HOME/.claude-$NAME"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SHARE=(
  CLAUDE.md settings.json settings.local.json keybindings.json
  agents commands skills hooks scripts output-styles plugins
  projects history.jsonl file-history paste-cache session-env shell-snapshots
  tasks teams todos plans
  ${CLAUDE_ACCOUNTS_SHARE_EXTRA:-}
)

[ -d "$SRC" ] || { echo "setup: $SRC not found; run claude once first" >&2; exit 2; }
# Never overwrite a command that isn't ours (an existing claude-<name> install).
LAUNCHER="$HOME/.local/bin/claude-$NAME"
if { [ -e "$LAUNCHER" ] || [ -L "$LAUNCHER" ]; } \
   && [ "$(readlink -f "$LAUNCHER" 2>/dev/null)" != "$(readlink -f "$HERE/claude-alt")" ]; then
  echo "setup: $LAUNCHER already exists and is not this launcher; nothing changed. Pick another name or move it aside." >&2
  exit 2
fi
mkdir -p "$DST"; chmod 700 "$DST"
linked=0
for item in "${SHARE[@]}"; do
  [ -e "$SRC/$item" ] || continue
  [ -L "$DST/$item" ] && continue
  if [ -e "$DST/$item" ]; then
    echo "setup: $DST/$item is a real file or dir; left alone (move it aside to share it)" >&2
    continue
  fi
  ln -s "$SRC/$item" "$DST/$item"; linked=$((linked + 1))
done
echo "setup: $linked new links in $DST"

python3 "$HERE/sync_config.py" "$DST"

mkdir -p "$HOME/.local/bin"
[ -L "$LAUNCHER" ] || ln -s "$HERE/claude-alt" "$LAUNCHER"
echo "setup: launcher $HOME/.local/bin/claude-$NAME"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "setup: add ~/.local/bin to PATH" >&2 ;; esac
echo "next:  claude-$NAME auth login     (pick the other account in the browser)"
