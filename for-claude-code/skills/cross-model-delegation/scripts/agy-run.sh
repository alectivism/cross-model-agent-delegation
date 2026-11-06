#!/usr/bin/env bash
# agy-run.sh — run one headless Antigravity CLI (agy) task on a Google AI Pro or Ultra
# subscription (Google account login, never an API key) and hand the answer back.
#
# Usage: agy-run.sh [options] <class> "<full-context prompt>"
# Classes (model ids from `agy models`, verified 2026-11-06 on agy 1.5.2):
#   prose    Gemini 4 Argon (Medium)  drafting, rewriting, voice and tone critique
#   review   Gemini 4 Argon (High)    second opinion or critique of a draft, plan or argument
#   fast     Gemini 3.8 Flash (Low)   mechanical work, extraction, big-file reads
#   image    Gemini 3.8 Flash (Medium) image generation via agy's generate_image tool
# Options:
#   --model <id>   override the class model (any id from `agy models`)
#   -C <dir>       working directory agy may read (default: a fresh empty temp dir)
#   -o <file>      output file (default: mktemp)
#
# agy sees nothing of the calling conversation, has none of Claude's MCP servers
# or skills, and in print mode runs tools without asking, so the default working
# dir is an empty temp dir. Pass -C only when it must read files there.
# Last stdout line: OUT=<file>. Read OUT; a one-line summary goes to stderr.
# Exit status: 0 on success, 1 when the run failed (reason in OUT), 2 on bad usage.
set -uo pipefail
die() { echo "agy-run: $*" >&2; exit 2; }

MODEL="" DIR="" OUT=""
while [ $# -gt 2 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    -C) DIR="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
[ $# -eq 2 ] || die "usage: agy-run.sh [--model id] [-C dir] [-o file] <prose|review|fast|image> \"<prompt>\""
CLASS="$1" PROMPT="$2"
case "$CLASS" in
  prose)  DEF=gemini-4-argon-medium ;;
  review) DEF=gemini-4-argon-high ;;
  fast)   DEF=gemini-3.8-flash-low ;;
  image)  DEF=gemini-3.8-flash-medium ;;
  *) die "unknown class $CLASS" ;;
esac
MODEL="${MODEL:-$DEF}"
command -v agy >/dev/null || die "agy not installed"
if [ -z "$DIR" ]; then DIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-run.XXXXXX")"; fi
[ -d "$DIR" ] || die "no such dir $DIR"
OUT="${OUT:-$(mktemp "${TMPDIR:-/tmp}/agy-run.XXXXXX")}"

# --print=<prompt> keeps a prompt that starts with "-" from being read as a flag
# API-key variables are dropped so the run always bills the subscription login.
# (agy rejects `-p --model ...` because -p takes the next word as its prompt).
( cd "$DIR" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY -u GOOGLE_GENAI_API_KEY agy --model "$MODEL" --output-format json --print="$PROMPT" ) >"$OUT.json" 2>"$OUT.err"
RC=$?
if python3 - "$OUT.json" "$OUT" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    open(sys.argv[2], "w").write(f"agy-run: no JSON result ({e}); see {sys.argv[1]}.err\n"); sys.exit(1)
ok = d.get("status") == "SUCCESS" and (d.get("response") or "").strip()
open(sys.argv[2], "w").write((d.get("response") or f"agy-run: status {d.get('status')}") + "\n")
u = d.get("usage") or {}
print(f"agy-run: {d.get('status')} in {d.get('duration_seconds', 0):.0f}s, {u.get('total_tokens', '?')} tokens", file=sys.stderr)
sys.exit(0 if ok else 1)
PY
then STATUS=0; else STATUS=1; fi
[ "$RC" -eq 0 ] || STATUS=1
echo "OUT=$OUT"
exit $STATUS
