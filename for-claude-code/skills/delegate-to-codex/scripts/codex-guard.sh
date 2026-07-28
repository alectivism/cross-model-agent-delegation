#!/usr/bin/env bash
# PreToolUse guard: block raw `codex exec` from Claude Code's Bash tool and
# redirect to codex-run.sh, which owns model/effort/sandbox/MCP-off flags.
# Bypass deliberately with CODEX_RAW=1 in the command. codex-run.sh itself is
# exempt (its internal codex call is not a tool invocation).

input=$(cat)
cmd=$(printf '%s' "$input" | /usr/bin/env jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *codex-run.sh*|*CODEX_RAW=1*) exit 0 ;;
esac

if printf '%s' "$cmd" | grep -qE '(^|[;&|([:space:]])codex[[:space:]]+(exec|e)([[:space:]]|$)'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Raw 'codex exec' is blocked. Use the deterministic wrapper: ~/.claude/skills/delegate-to-codex/scripts/codex-run.sh <commit|implement|explore|ingest|review|hardest> [--escalate] [--effort E] [--write] [--web] [-C dir] \"<full-context prompt>\" then Read the OUT= file (see the delegate-to-codex skill). To bypass intentionally, prefix the command with CODEX_RAW=1 and state why."}}
JSON
fi
exit 0
