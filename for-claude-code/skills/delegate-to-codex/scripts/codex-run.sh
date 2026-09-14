#!/usr/bin/env bash
# codex-run.sh — deterministic wrapper for driving Codex CLI as a subagent.
# The caller classifies the task; this script owns model, effort, sandbox,
# MCP suppression, auth hygiene, and output handling. Never hand-roll flags.
#
# Usage:
#   codex-run.sh <task-class> [options] "<full-context prompt>"
#
# Models are NOT pinned here. Each class maps to a TIER, and codex-models.sh
# resolves the tier against Codex's live catalog ($CODEX_HOME/models_cache.json,
# refreshed on every codex run), so a new release (GPT-6 Sol, GPT-6.x, ...)
# is picked up automatically:
#   frontier  top listed model by catalog priority   (2026-09-14: gpt-6-astra)
#   fast      cheap leaf model, follows server upgrade pointers (gpt-5.6-luna)
#
# Task classes (tier / effort / sandbox). Tuned for a Pro-level ChatGPT plan:
# the frontier model is the default; `fast` only where a better model
# genuinely adds nothing.
#   commit     fast     / medium / read-only        commit msgs, renames, trivial mechanical
#   implement  frontier / high   / workspace-write  bounded code change (leaf task)
#   explore    frontier / medium / read-only        ambiguous, needs repo exploration or judgment
#   ingest     frontier / medium / read-only        long-context read-heavy extraction
#   review     frontier / high   / read-only        adversarial review, verdicts, architecture
#   hardest    frontier / xhigh  / read-only        after another class failed, or genuinely hardest
#   prose      frontier / medium / read-only        readability / copy editing of reader-facing prose,
#                                                   second-model plain-language review
#
# Options:
#   --escalate      one rung up (commit->frontier medium, implement->xhigh,
#                   explore/ingest/prose->high, review->xhigh, hardest->max)
#   --effort <e>    override effort only (low|medium|high|xhigh|max|ultra); model
#                   stays tier-resolved; caller must state why. Applied after
#                   --escalate. Validated against the model's supported list.
#                   `ultra` = max reasoning + automatic sub-agent delegation:
#                   heavy on quota, use only for hardest-class work.
#   --model <slug>  pin an explicit catalog slug for this call (A/B runs,
#                   reproducing an old result). Caller must state why.
#   --fast-tier     request the "Fast" service tier (2x speed, ~2x usage).
#                   Default is service_tier="default" to conserve quota.
#   --write         force workspace-write sandbox
#   --web           enable built-in web search (stays MCP-free)
#   -C <dir>        repo/working dir (passed to codex -C)
#   -o <file>       output file (default: mktemp under $TMPDIR)
#   --schema <file> JSON Schema file constraining the model's final message
#                   (codex --output-schema); the OUT file then holds strict JSON
#   --img <file>    attach an image to the initial prompt (codex -i). Repeatable:
#                   pass --img once per file. Use for table/figure pages so the
#                   model reads them multimodally instead of from stripped text.
#
# Prints the output file path on the last line as OUT=<path>. Read that file;
# NEVER pipe codex stdout through head/tail (silent truncation, 2026-07-14).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS="$HERE/codex-models.sh"

die() { echo "codex-run: $*" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: codex-run.sh <commit|implement|explore|ingest|review|hardest|prose> [--escalate] [--effort E] [--model SLUG] [--fast-tier] [--write] [--web] [-C dir] [-o file] [--schema file] [--img file]... \"<prompt>\""

CLASS="$1"; shift
ESCALATE=0 WRITE=0 WEB=0 FAST_TIER=0 DIR="" OUT="" EFFORT_OVERRIDE="" MODEL_OVERRIDE="" SCHEMA=""
IMAGES=()
while [ $# -gt 1 ]; do
  case "$1" in
    --escalate)  ESCALATE=1; shift ;;
    --effort)    EFFORT_OVERRIDE="$2"; shift 2 ;;
    --model)     MODEL_OVERRIDE="$2"; shift 2 ;;
    --fast-tier) FAST_TIER=1; shift ;;
    --write)     WRITE=1; shift ;;
    --web)       WEB=1; shift ;;
    -C)          DIR="$2"; shift 2 ;;
    -o)          OUT="$2"; shift 2 ;;
    --schema)    SCHEMA="$2"; shift 2 ;;
    --img)       [ -f "$2" ] || die "--img file not found: $2"; IMAGES+=("$2"); shift 2 ;;
    *)           die "unknown option: $1" ;;
  esac
done
PROMPT="$1"
[ -n "$PROMPT" ] || die "empty prompt"

SANDBOX="read-only"
case "$CLASS" in
  commit)    TIER=fast;     EFFORT=medium ;;
  implement) TIER=frontier; EFFORT=high; SANDBOX="workspace-write" ;;
  explore)   TIER=frontier; EFFORT=medium ;;
  ingest)    TIER=frontier; EFFORT=medium ;;
  review)    TIER=frontier; EFFORT=high ;;
  hardest)   TIER=frontier; EFFORT=xhigh ;;
  prose)     TIER=frontier; EFFORT=medium ;;
  *) die "unknown task class: $CLASS" ;;
esac

if [ "$ESCALATE" = 1 ]; then
  case "$CLASS" in
    commit)    TIER=frontier; EFFORT=medium ;;
    implement) EFFORT=xhigh ;;
    explore)   EFFORT=high ;;
    ingest)    EFFORT=high ;;
    review)    EFFORT=xhigh ;;
    hardest)   EFFORT=max ;;
    prose)     EFFORT=high ;;
  esac
fi

if [ -n "$MODEL_OVERRIDE" ]; then
  MODEL="$MODEL_OVERRIDE"; SOURCE="--model override"
else
  MODEL="$("$MODELS" resolve "$TIER")" || die "model resolution failed for tier $TIER"
  SOURCE="tier=$TIER"
fi

if [ -n "$EFFORT_OVERRIDE" ]; then
  case "$EFFORT_OVERRIDE" in
    low|medium|high|xhigh|max|ultra) EFFORT="$EFFORT_OVERRIDE" ;;
    *) die "invalid --effort: $EFFORT_OVERRIDE" ;;
  esac
fi
# Validate effort against the catalog (e.g. luna has no `ultra`); fall back one
# rung rather than letting the API reject the call.
SUPPORTED="$("$MODELS" efforts "$MODEL" | tr '\n' ' ')"
if ! printf '%s' "$SUPPORTED" | grep -qw "$EFFORT"; then
  LAST="$(printf '%s' "$SUPPORTED" | awk '{print $NF}')"
  echo "codex-run: effort '$EFFORT' unsupported on $MODEL (supports: $SUPPORTED); using $LAST" >&2
  EFFORT="$LAST"
fi

[ "$WRITE" = 1 ] && SANDBOX="workspace-write"
[ -n "$OUT" ] || OUT="$(mktemp "${TMPDIR:-/tmp}/codex-run.XXXXXX")"  # BSD mktemp: Xs must be trailing
SERVICE_TIER="default"; [ "$FAST_TIER" = 1 ] && SERVICE_TIER="priority"

# --ignore-user-config is the real MCP/plugin kill switch. -c 'mcp_servers={}'
# is a no-op: TOML table overrides MERGE, verified via `codex mcp list` 2026-07-15.
# Auth still resolves via CODEX_HOME. Everything config.toml provided (model,
# effort, sandbox, service_tier) is re-pinned explicitly below. service_tier
# matters: the catalog marks every model default_service_tier="priority"
# ("Fast: 2x speed, increased usage"), which --ignore-user-config would let
# through and burn quota at ~2x.
# multi_agent_v2 flags: v2-parent models (astra, sol, terra per the catalog's
# multi_agent_version) get "collab" spawn tools that HIDE model/reasoning_effort
# by default (openai/codex#31814); these restore them so an orchestrator can
# route leaves. Verified on sol 2026-07-16.
ARGS=(exec --ignore-user-config -m "$MODEL"
  -c "model_reasoning_effort=\"$EFFORT\""
  -c "service_tier=\"$SERVICE_TIER\""
  -c 'preferred_auth_method="chatgpt"'
  -c 'features.multi_agent_v2.hide_spawn_agent_metadata=false'
  -c 'features.multi_agent_v2.tool_namespace="agents"'
  -s "$SANDBOX"
  -o "$OUT")
[ "$WEB" = 1 ] && ARGS+=(-c 'tools.web_search=true')
if [ -n "$SCHEMA" ]; then
  [ -f "$SCHEMA" ] || die "--schema file not found: $SCHEMA"
  ARGS+=(--output-schema "$SCHEMA")
fi
# -i/--image is VARIADIC in clap (`-i, --image <FILE>...`), so the space form
# `-i file` greedily swallows the prompt positional that follows it — observed
# 2026-08-28: codex then reported "No prompt provided via stdin" and hung on
# stdin. The `--image=FILE` equals form binds exactly one value per occurrence,
# so repeat it once per file. Do not "simplify" this back to `-i "$img"`.
if [ "${#IMAGES[@]}" -gt 0 ]; then
  for img in "${IMAGES[@]}"; do ARGS+=("--image=$img"); done
fi
[ -n "$DIR" ] && ARGS+=(-C "$DIR")

echo "codex-run: class=$CLASS model=$MODEL ($SOURCE) effort=$EFFORT service_tier=$SERVICE_TIER sandbox=$SANDBOX web=$WEB images=${#IMAGES[@]}" >&2
# </dev/null: with piped/absent stdin codex appends a <stdin> block and can hang
env -u OPENAI_API_KEY codex "${ARGS[@]}" "$PROMPT" >&2 </dev/null
echo "OUT=$OUT"
