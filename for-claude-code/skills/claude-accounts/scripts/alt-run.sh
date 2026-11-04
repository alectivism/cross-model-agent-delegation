#!/usr/bin/env bash
# alt-run.sh — run one headless Claude Code task on your second login and hand
# the answer back to the calling session. Same contract as codex-run.sh.
#
# The child has the same skills, CLAUDE.md, hooks and MCP servers as your main
# login (claude.ai connectors come from the second account's own settings). It
# sees none of the caller's conversation, so the prompt must carry full context.
#
# Usage:
#   alt-run.sh [options] "<full-context prompt>"
# Options:
#   --name <n>         which second login (default: $CLAUDE_ALT_NAME or personal)
#   --model <m>        model alias or id (default: your settings)
#   --effort <e>       low|medium|high|xhigh|max (default: your settings)
#   --mode <m>         permission mode (default: your settings)
#   --resume <id>      continue an earlier session, from this script or any login
#   -C <dir>           working directory (default: current)
#   -o <file>          output file (default: mktemp)
#
# Last two stdout lines, always: SESSION=<id> then OUT=<file>. Read OUT.
# Exit status: 0 on success, 1 when the run failed (reason in OUT), 2 on bad usage.
# Raw JSON result (turns, errors) at <OUT>.json, child stderr at <OUT>.err.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
die() { echo "alt-run: $*" >&2; exit 2; }

NAME="${CLAUDE_ALT_NAME:-personal}" MODEL="" EFFORT="" MODE="" RESUME="" DIR="" OUT=""
while [ $# -gt 1 ]; do
  case "$1" in
    --name)   NAME="$2"; shift 2 ;;
    --model)  MODEL="$2"; shift 2 ;;
    --effort) case "$2" in low|medium|high|xhigh|max) EFFORT="$2" ;; *) die "invalid --effort: $2" ;; esac; shift 2 ;;
    --mode)   MODE="$2"; shift 2 ;;
    --resume) RESUME="$2"; shift 2 ;;
    -C)       DIR="$2"; shift 2 ;;
    -o)       OUT="$2"; shift 2 ;;
    *)        die "unknown option: $1" ;;
  esac
done
[ $# -eq 1 ] && [ -n "$1" ] || die 'usage: alt-run.sh [--name N] [--model M] [--effort E] [--mode M] [--resume ID] [-C dir] [-o file] "<prompt>"'
PROMPT="$1"
LAUNCHER="$HOME/.local/bin/claude-$NAME"
[ -x "$LAUNCHER" ] || die "$LAUNCHER not found; run $HERE/setup.sh $NAME"

[ -n "$OUT" ] || OUT="$(mktemp "${TMPDIR:-/tmp}/alt-run.XXXXXX")"
META="$OUT.json"; ERR="$OUT.err"; SID=""
trap 'echo "SESSION=$SID"; echo "OUT=$OUT"' EXIT

ARGS=(-p --output-format json)
[ -n "$MODEL" ]  && ARGS+=(--model "$MODEL")
[ -n "$EFFORT" ] && ARGS+=(--effort "$EFFORT")
[ -n "$MODE" ]   && ARGS+=(--permission-mode "$MODE")
[ -n "$RESUME" ] && ARGS+=(--resume "$RESUME")
[ -n "$DIR" ] && { cd "$DIR" || die "cannot cd to $DIR"; }

echo "alt-run: login=$NAME model=${MODEL:-default} effort=${EFFORT:-default} mode=${MODE:-default} resume=${RESUME:-no} cwd=$PWD" >&2

# When called from inside a Claude Code session, drop the parent's session
# identity so the child starts as its own top-level session.
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_BRIDGE_SESSION_ID \
    -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT \
    "$LAUNCHER" "${ARGS[@]}" "$PROMPT" </dev/null >"$META" 2>"$ERR" && RC=0 || RC=$?

if SID="$(python3 - "$META" "$OUT" <<'PY'
import json, sys
meta, out = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(meta))
except Exception:
    open(out, "w").write("alt-run FAILED: no JSON result.\n" + open(meta).read()[:2000])
    sys.exit(1)
failed = bool(d.get("is_error")) or not d.get("result")
open(out, "w").write(d.get("result") or f"alt-run FAILED: {d.get('subtype')} {d.get('errors') or ''}")
print(f"alt-run: is_error={d.get('is_error')} turns={d.get('num_turns')} "
      f"duration_s={round((d.get('duration_ms') or 0) / 1000)}", file=sys.stderr)
print(d.get("session_id") or "", end="")
sys.exit(1 if failed else 0)
PY
)"; then STATUS=0; else STATUS=1; fi
[ "$RC" -eq 0 ] || STATUS=1
[ -s "$ERR" ] && { echo "alt-run: child stderr (first lines):" >&2; head -5 "$ERR" >&2; }

# The run moved the second login's meter; refresh and show both logins.
CLAUDE_ALT_NAME="$NAME" python3 "$HERE/accounts.py" refresh 2>/dev/null || true
exit $STATUS
