#!/usr/bin/env bash
# Guard: block raw `claude -p` from a Codex shell call and redirect to
# claude-run.sh, which owns model/effort/permission-mode/tool-surface flags.
# Bypass deliberately with CLAUDE_RAW=1 in the command. claude-run.sh itself is
# exempt (its internal claude call is not a tool invocation).
#
# Mirror of codex-guard.sh. Reads a JSON tool-call envelope on stdin and emits
# a deny decision on stdout when it matches.

input=$(cat)
cmd=$(printf '%s' "$input" | /usr/bin/env jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *claude-run.sh*|*CLAUDE_RAW=1*) exit 0 ;;
esac

# `claude -p` / `claude --print`, but not `claude mcp`, `claude plugin`, etc.
if printf '%s' "$cmd" | grep -qE '(^|[;&|([:space:]])claude[[:space:]]+([^;&|]*[[:space:]])?(-p|--print)([[:space:]]|$)'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Raw 'claude -p' is blocked. Use the deterministic wrapper: ~/.codex/skills/delegate-to-claude/scripts/claude-run.sh <commit|implement|explore|ingest|review|hardest> [--escalate] [--effort E] [--write] [--web] [-C dir] \"<full-context prompt>\" then read the OUT= file (see the delegate-to-claude skill). Raw calls silently run Sonnet when you write --model haiku, and load every MCP server. To bypass intentionally, prefix the command with CLAUDE_RAW=1 and state why."}}
JSON
fi
exit 0
