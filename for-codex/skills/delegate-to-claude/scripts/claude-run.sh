#!/usr/bin/env bash
# claude-run.sh — deterministic wrapper for driving Claude Code as a subagent.
# The mirror image of codex-run.sh. The caller classifies the task; this script
# owns model, effort, permission mode, tool surface, MCP/skill suppression,
# auth hygiene, and output handling. Never hand-roll flags.
#
# Usage:
#   claude-run.sh <task-class> [options] "<full-context prompt>"
#
# Task classes (model / effort / permission mode):
#   commit     haiku  / low    / read-only      commit msgs, renames, trivial mechanical
#   implement  sonnet / high   / write           small well-bounded code change (leaf task)
#   explore    sonnet / medium / read-only       ambiguous, needs repo exploration or judgment
#   ingest     haiku  / medium / read-only       long-context read-heavy extraction
#   review     sonnet / high   / read-only       adversarial review, verdicts, architecture
#   hardest    opus   / xhigh  / read-only       after a cheaper class failed, or genuinely hardest
#
# Options:
#   --escalate      one rung up (commit->sonnet medium, implement->sonnet xhigh,
#                   explore->sonnet high, ingest->sonnet medium,
#                   review->opus high, hardest->opus max)
#   --effort <e>    override effort only (low|medium|high|xhigh|max), model stays
#                   class-pinned; caller must state why. Applied after --escalate.
#   --write         force the write-capable mode instead of read-only
#   --web           add WebSearch and WebFetch to the tool surface
#   -C <dir>        working directory (this script cd's there; the CLI has no -C)
#   -o <file>       output file (default: mktemp under $TMPDIR)
#   --json          emit the CLI's JSON envelope instead of plain text
#
# Prints the output file path on the last line as OUT=<path>. Read that file.
#
# Verified 2026-07-27 against Claude Code 2.1.220. See SKILL.md for the four
# gotchas this script exists to route around.

set -euo pipefail

die() { echo "claude-run: $*" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: claude-run.sh <commit|implement|explore|ingest|review|hardest> [--escalate] [--effort E] [--write] [--web] [-C dir] [-o file] [--json] \"<prompt>\""

CLASS="$1"; shift
ESCALATE=0 WRITE=0 WEB=0 JSON=0 DIR="" OUT="" EFFORT_OVERRIDE=""
while [ $# -gt 1 ]; do
  case "$1" in
    --escalate) ESCALATE=1; shift ;;
    --effort)   EFFORT_OVERRIDE="$2"; shift 2 ;;
    --write)    WRITE=1; shift ;;
    --web)      WEB=1; shift ;;
    --json)     JSON=1; shift ;;
    -C)         DIR="$2"; shift 2 ;;
    -o)         OUT="$2"; shift 2 ;;
    *)          die "unknown option: $1" ;;
  esac
done
PROMPT="$1"
[ -n "$PROMPT" ] || die "empty prompt"

# Full IDs, not aliases. `--model haiku` silently resolves to Sonnet 5 (the
# help text only documents fable/opus/sonnet aliases), so a haiku-tier call
# would quietly bill at Sonnet. Verified 2026-07-27 by reading modelUsage in
# the --output-format json envelope.
HAIKU="claude-haiku-4-5-20251001"
SONNET="claude-sonnet-5"
OPUS="claude-opus-5"

MODE="read-only"
case "$CLASS" in
  commit)    MODEL="$HAIKU";  EFFORT=low ;;
  implement) MODEL="$SONNET"; EFFORT=high;   MODE="write" ;;
  explore)   MODEL="$SONNET"; EFFORT=medium ;;
  ingest)    MODEL="$HAIKU";  EFFORT=medium ;;
  review)    MODEL="$SONNET"; EFFORT=high ;;
  hardest)   MODEL="$OPUS";   EFFORT=xhigh ;;
  *) die "unknown task class: $CLASS" ;;
esac

if [ "$ESCALATE" = 1 ]; then
  case "$CLASS" in
    commit)    MODEL="$SONNET"; EFFORT=medium ;;
    implement) MODEL="$SONNET"; EFFORT=xhigh; MODE="write" ;;
    explore)   MODEL="$SONNET"; EFFORT=high ;;
    ingest)    MODEL="$SONNET"; EFFORT=medium ;;
    review)    MODEL="$OPUS";   EFFORT=high ;;
    hardest)   MODEL="$OPUS";   EFFORT=max ;;
  esac
fi

if [ -n "$EFFORT_OVERRIDE" ]; then
  case "$EFFORT_OVERRIDE" in
    low|medium|high|xhigh|max) EFFORT="$EFFORT_OVERRIDE" ;;
    *) die "invalid --effort: $EFFORT_OVERRIDE" ;;
  esac
fi

[ "$WRITE" = 1 ] && MODE="write"
[ -n "$OUT" ] || OUT="$(mktemp "${TMPDIR:-/tmp}/claude-run.XXXXXX")"  # BSD mktemp: Xs must be trailing

# Read-only means no Bash, not just no Write. An allowlist that keeps Bash
# still has a write path (`echo > file`), and plan mode, which does close that
# path, drags the interactive plan-mode framing in with it: workers start
# writing plan documents into ~/.claude/plans and ending on "shall I proceed?"
# instead of answering. Dropping Bash is the stronger lock and the quieter one.
# Read/Glob/Grep is enough to explore a repo; anything a shell would have
# produced (a diff, a test run) belongs in the prompt.
if [ "$MODE" = "write" ]; then
  PERM_MODE="acceptEdits"
  TOOLS="default"
else
  PERM_MODE="dontAsk"
  TOOLS="Read,Glob,Grep,TodoWrite"
  [ "$WEB" = 1 ] && TOOLS="$TOOLS,WebSearch,WebFetch"
fi

# --strict-mcp-config with no --mcp-config is the MCP kill switch: it drops
# every configured server. Measured 2026-07-27 on this machine: 123 tools ->
# 29 built-ins, i.e. 94 tool schemas that would otherwise load every turn.
# --disable-slash-commands drops all skills for the same reason.
#
# NOT --bare. It looks like the equivalent of Codex's --ignore-user-config, but
# it also forces auth to ANTHROPIC_API_KEY or an apiKeyHelper and never reads
# OAuth or the keychain, so on a subscription it either fails or silently bills
# the API. Read its help text before you reach for it.
ARGS=(-p
  --model "$MODEL"
  --effort "$EFFORT"
  --permission-mode "$PERM_MODE"
  --strict-mcp-config
  --disable-slash-commands
  --no-session-persistence
  --tools "$TOOLS")

# There is no human on the other end. Without this, a worker ends its turn by
# offering next steps or asking which option you want, and the caller has to
# parse around it.
ARGS+=(--append-system-prompt "You are a non-interactive worker invoked by another agent, not by a person. Nobody will answer a follow-up question. Return the finished answer as your final message, with no preamble, no offer of next steps, and no closing question. If the task cannot be done with the tools you have, say so in one line and return whatever you did learn.")
[ "$JSON" = 1 ] && ARGS+=(--output-format json)
[ -n "$DIR" ] && ARGS+=(--add-dir "$DIR")

echo "claude-run: class=$CLASS model=$MODEL effort=$EFFORT mode=$MODE perm=$PERM_MODE web=$WEB tools=$TOOLS" >&2

# The prompt goes on STDIN, never as a positional argument. --tools,
# --add-dir, --allowedTools and --mcp-config are all variadic, so a trailing
# positional prompt gets swallowed as another value for whichever one came
# last ("Input must be provided either through stdin or as a prompt argument").
# Verified 2026-07-27.
#
# ANTHROPIC_API_KEY is unset so a key exported in the calling shell can't
# override subscription auth and bill the API instead.
(
  [ -n "$DIR" ] && cd "$DIR"
  printf '%s' "$PROMPT" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude "${ARGS[@]}"
) > "$OUT"

echo "OUT=$OUT"
