#!/usr/bin/env bash
# claude-alt.sh — run Claude Code on your second login with the shared config.
# Installed by setup.sh as ~/.local/bin/claude-<name>; the name it is invoked
# under picks the config dir (claude-personal -> ~/.claude-personal).
#
#   claude-<name>                   new session on the second login
#   claude-<name> --resume [id]     continue any session (either login) on it
#   claude-<name> auth login|status one-time sign-in / check which account
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
INVOKED="$(basename "$0")"
NAME="${INVOKED#claude-}"
[ "$NAME" = "alt" ] || [ "$NAME" = "$INVOKED" ] && NAME="${CLAUDE_ALT_NAME:-personal}"
export CLAUDE_CONFIG_DIR="$HOME/.claude-$NAME"
MAIN="${CLAUDE_MAIN_DIR:-$HOME/.claude}"

[ -d "$CLAUDE_CONFIG_DIR" ] || { echo "claude-$NAME: $CLAUDE_CONFIG_DIR missing; run $HERE/setup.sh $NAME" >&2; exit 2; }

# An Anthropic key or token variable outranks the subscription login, so a stray
# one would silently run this login on someone else's account. Unset them; other
# variables (ones your MCP servers may use) are left alone.
for v in $(compgen -e); do
  case "$v" in ANTHROPIC_*_KEY|ANTHROPIC_*_TOKEN|CLAUDE_CODE_*_TOKEN) unset "$v" 2>/dev/null || : ;; esac
done

python3 "$HERE/sync_config.py" "$CLAUDE_CONFIG_DIR" --quiet \
  || echo "claude-$NAME: config sync failed; using last synced config" >&2

# If the main login is an org seat (Team/Enterprise), its server-managed settings (permission
# rules, auto-mode rules) are cached in remote-settings.json. Layer them in so
# both logins follow the same rules. CLAUDE_ALT_ORG_SETTINGS=0 turns this off.
EXTRA=()
case "${1:-}" in
  auth|mcp|plugin|plugins|doctor|update|install|setup-token|config|agents|ps|attach|logs|stop|kill|rm|import|help|-h|--help|-v|--version) ;;
  *) [ "${CLAUDE_ALT_ORG_SETTINGS:-1}" != 0 ] && [ -f "$MAIN/remote-settings.json" ] \
       && EXTRA+=(--settings "$MAIN/remote-settings.json") ;;
esac

exec claude ${EXTRA[@]+"${EXTRA[@]}"} "$@"
