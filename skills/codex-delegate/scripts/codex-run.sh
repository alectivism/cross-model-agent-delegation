#!/usr/bin/env bash
# codex-run.sh — deterministic wrapper for driving Codex CLI as a subagent.
# The caller classifies the task; this script owns model, effort, sandbox,
# MCP suppression, auth hygiene, and output handling. Never hand-roll flags.
#
# Usage:
#   codex-run.sh <task-class> [options] "<full-context prompt>"
#
# Task classes (model / effort / sandbox):
#   commit     luna  / medium / read-only        commit msgs, renames, trivial mechanical
#   implement  luna  / xhigh  / workspace-write  small well-bounded code change (leaf task)
#   explore    sol   / medium / read-only        ambiguous, needs repo exploration or judgment
#   ingest     terra / medium / read-only        long-context read-heavy extraction (luna recall breaks)
#   review     sol   / medium / read-only        adversarial review, verdicts, architecture
#   hardest    sol   / xhigh  / read-only        after a cheaper class failed, or genuinely hardest
#
# Options:
#   --escalate      one rung up (commit->luna xhigh, implement->sol medium+write,
#                   explore/review->sol high, ingest->sol medium, hardest->sol max)
#   --effort <e>    override effort only (low|medium|high|xhigh|max), model stays
#                   class-pinned; caller must state why. Applied after --escalate.
#   --write         force workspace-write sandbox
#   --web           enable built-in web search (stays MCP-free)
#   -C <dir>        repo/working dir (passed to codex -C)
#   -o <file>       output file (default: mktemp under $TMPDIR)
#
# Prints the output file path on the last line as OUT=<path>. Read that file;
# NEVER pipe codex stdout through head/tail (silent truncation, 2026-07-14).

set -euo pipefail

die() { echo "codex-run: $*" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: codex-run.sh <commit|implement|explore|ingest|review|hardest> [--escalate] [--write] [--web] [-C dir] [-o file] \"<prompt>\""

CLASS="$1"; shift
ESCALATE=0 WRITE=0 WEB=0 DIR="" OUT="" EFFORT_OVERRIDE=""
while [ $# -gt 1 ]; do
  case "$1" in
    --escalate) ESCALATE=1; shift ;;
    --effort)   EFFORT_OVERRIDE="$2"; shift 2 ;;
    --write)    WRITE=1; shift ;;
    --web)      WEB=1; shift ;;
    -C)         DIR="$2"; shift 2 ;;
    -o)         OUT="$2"; shift 2 ;;
    *)          die "unknown option: $1" ;;
  esac
done
PROMPT="$1"
[ -n "$PROMPT" ] || die "empty prompt"

SANDBOX="read-only"
case "$CLASS" in
  commit)    MODEL=gpt-5.6-luna;  EFFORT=medium ;;
  implement) MODEL=gpt-5.6-luna;  EFFORT=xhigh; SANDBOX="workspace-write" ;;
  explore)   MODEL=gpt-5.6-sol;   EFFORT=medium ;;
  ingest)    MODEL=gpt-5.6-terra; EFFORT=medium ;;
  review)    MODEL=gpt-5.6-sol;   EFFORT=medium ;;
  hardest)   MODEL=gpt-5.6-sol;   EFFORT=xhigh ;;
  *) die "unknown task class: $CLASS" ;;
esac

if [ "$ESCALATE" = 1 ]; then
  case "$CLASS" in
    commit)    MODEL=gpt-5.6-luna; EFFORT=xhigh ;;
    implement) MODEL=gpt-5.6-sol;  EFFORT=medium; SANDBOX="workspace-write" ;;
    explore)   MODEL=gpt-5.6-sol;  EFFORT=high ;;
    ingest)    MODEL=gpt-5.6-sol;  EFFORT=medium ;;
    review)    MODEL=gpt-5.6-sol;  EFFORT=high ;;
    hardest)   MODEL=gpt-5.6-sol;  EFFORT=max ;;
  esac
fi

if [ -n "$EFFORT_OVERRIDE" ]; then
  case "$EFFORT_OVERRIDE" in
    low|medium|high|xhigh|max) EFFORT="$EFFORT_OVERRIDE" ;;
    *) die "invalid --effort: $EFFORT_OVERRIDE" ;;
  esac
fi

[ "$WRITE" = 1 ] && SANDBOX="workspace-write"
[ -n "$OUT" ] || OUT="$(mktemp "${TMPDIR:-/tmp}/codex-run.XXXXXX")"  # BSD mktemp: Xs must be trailing

# --ignore-user-config is the real MCP/plugin kill switch. -c 'mcp_servers={}'
# is a no-op: TOML table overrides MERGE, verified via `codex mcp list` 2026-07-15.
# Auth still resolves via CODEX_HOME. Everything config.toml provided (model,
# effort, sandbox) is re-pinned explicitly below.
# multi_agent_v2 flags: sol parents get v2 "collab" spawn tools that HIDE
# model/reasoning_effort by default (openai/codex#31814); these restore them
# so a sol orchestrator can route luna/terra leaves. Verified 2026-07-16.
ARGS=(exec --ignore-user-config -m "$MODEL"
  -c "model_reasoning_effort=\"$EFFORT\""
  -c 'preferred_auth_method="chatgpt"'
  -c 'features.multi_agent_v2.hide_spawn_agent_metadata=false'
  -c 'features.multi_agent_v2.tool_namespace="agents"'
  -s "$SANDBOX"
  -o "$OUT")
[ "$WEB" = 1 ] && ARGS+=(-c 'tools.web_search=true')
[ -n "$DIR" ] && ARGS+=(-C "$DIR")

echo "codex-run: class=$CLASS model=$MODEL effort=$EFFORT sandbox=$SANDBOX web=$WEB" >&2
# </dev/null: with piped/absent stdin codex appends a <stdin> block and can hang
env -u OPENAI_API_KEY codex "${ARGS[@]}" "$PROMPT" >&2 </dev/null
echo "OUT=$OUT"
