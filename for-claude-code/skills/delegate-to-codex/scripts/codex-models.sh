#!/usr/bin/env bash
# codex-models.sh — resolve Codex model tiers from the live model catalog.
#
# Codex CLI keeps a server-fetched catalog at $CODEX_HOME/models_cache.json
# (refreshed on every codex run, ETag-checked). Each entry has a `priority`
# (1 = newest/most capable), `visibility` (list|hide), an `upgrade` pointer the
# server sets when a model is superseded, and `supported_reasoning_levels`.
# Resolving from that file means the wrapper follows new releases (GPT-6 Sol,
# GPT-6.x, ...) without anyone editing a slug here.
#
# Tiers resolve by FAMILY (the size word in the slug), newest generation first:
#   frontier  newest "astra"  (2026-09-22: gpt-6-astra)   biggest, most capable
#   standard  newest "sol"    (2026-09-22: gpt-6-sol)     everyday workhorse
#   fast      newest "luna"   (2026-09-22: gpt-6-luna)    cheap leaf model
# "Newest" = highest version parsed from gpt-<version>-<family>, ties broken
# by catalog priority; any server `upgrade` pointer is then followed.
#
# Why not catalog rank: `priority` is OpenAI's picker order, not capability.
# On 2026-09-22 the catalog put gpt-6-sol at p0 above gpt-6-astra at p1, and
# the old rank rule silently swapped frontier and standard. Families are
# overridable: CODEX_FRONTIER_FAMILY / CODEX_STANDARD_FAMILY / CODEX_FAST_FAMILY.
# A family missing from the catalog falls back UP (fast -> standard -> frontier,
# frontier -> top by priority), never silently down.
#
# Usage:
#   codex-models.sh resolve <frontier|standard|fast> -> prints slug (source on stderr)
#   codex-models.sh efforts <slug>               -> prints supported efforts, one per line
#   codex-models.sh list                         -> catalog table
#   codex-models.sh check                        -> staleness + agent TOML drift report
#   codex-models.sh sync-agents                  -> rewrite `model =` in ~/.codex/agents/*.toml
#                                                   from each file's `# codex-tier:` tag

set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CACHE="$CODEX_HOME/models_cache.json"
AGENTS_DIR="$CODEX_HOME/agents"
FRONTIER_FAMILY="${CODEX_FRONTIER_FAMILY:-astra}"
STANDARD_FAMILY="${CODEX_STANDARD_FAMILY:-sol}"
FAST_FAMILY="${CODEX_FAST_FAMILY:-luna}"
# Last-resort pins if the catalog is missing or unreadable. Update when you
# notice them drifting; `check` warns when they disagree with the catalog.
FALLBACK_FRONTIER="gpt-6-astra"
FALLBACK_STANDARD="gpt-6-sol"
FALLBACK_FAST="gpt-6-luna"
STALE_DAYS=7

die() { echo "codex-models: $*" >&2; exit 2; }
have_cache() { [ -r "$CACHE" ] && jq -e '.models | length > 0' "$CACHE" >/dev/null 2>&1; }

cache_age_days() {
  local fetched epoch now
  fetched="$(jq -r '.fetched_at // empty' "$CACHE")"
  [ -n "$fetched" ] || { echo 9999; return; }
  epoch="$(python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$fetched" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  echo $(( (now - epoch) / 86400 ))
}

# Follow `upgrade` pointers (string slug or object with model/slug/target).
follow_upgrade() {
  local slug="$1" next hops=0
  while :; do
    next="$(jq -r --arg s "$slug" '
      .models[] | select(.slug==$s) | .upgrade
      | if type=="string" then . elif type=="object" then (.model // .slug // .target // empty) else empty end' "$CACHE" 2>/dev/null || true)"
    [ -n "$next" ] && [ "$next" != "null" ] && [ "$next" != "$slug" ] || break
    slug="$next"; hops=$((hops+1)); [ $hops -lt 5 ] || break
  done
  echo "$slug"
}

# Newest listed model of a family: slug gpt-<ver>-<family>[-suffix]; sort by
# numeric version desc, then priority asc. Prints nothing if the family is absent.
newest_in_family() {
  jq -r --arg f "$1" '
    [ .models[] | select(.visibility=="list")
      | select(.slug | test("^gpt-[0-9.]+-" + $f + "($|-)"))
      | . + {ver: (.slug | capture("^gpt-(?<v>[0-9.]+)-").v | split(".") | map(tonumber))} ]
    | sort_by([(.ver | map(-.)), .priority]) | .[0].slug // empty' "$CACHE"
}

resolve() {
  local tier="$1" slug
  if [ -n "${CODEX_MODEL:-}" ]; then
    echo "codex-models: $tier -> $CODEX_MODEL (source=CODEX_MODEL env override)" >&2
    echo "$CODEX_MODEL"; return
  fi
  if ! have_cache; then
    case "$tier" in frontier) slug="$FALLBACK_FRONTIER" ;; standard) slug="$FALLBACK_STANDARD" ;; fast) slug="$FALLBACK_FAST" ;; *) die "unknown tier: $tier" ;; esac
    echo "codex-models: $tier -> $slug (source=FALLBACK; catalog missing at $CACHE)" >&2
    echo "$slug"; return
  fi
  case "$tier" in
    frontier) slug="$(newest_in_family "$FRONTIER_FAMILY")"
              if [ -z "$slug" ]; then
                slug="$(jq -r '[.models[] | select(.visibility=="list")] | sort_by(.priority) | .[0].slug' "$CACHE")"
                echo "codex-models: WARNING no listed '$FRONTIER_FAMILY' model; frontier falls back to top-priority $slug" >&2
              fi ;;
    standard) slug="$(newest_in_family "$STANDARD_FAMILY")"
              if [ -z "$slug" ]; then
                slug="$(resolve frontier 2>/dev/null)"
                echo "codex-models: WARNING no listed '$STANDARD_FAMILY' model; standard falls back to frontier $slug" >&2
              fi ;;
    fast)     slug="$(newest_in_family "$FAST_FAMILY")"
              if [ -z "$slug" ]; then
                slug="$(resolve standard 2>/dev/null)"
                echo "codex-models: WARNING no listed '$FAST_FAMILY' model; fast falls back to standard $slug" >&2
              fi ;;
    *) die "unknown tier: $tier" ;;
  esac
  slug="$(follow_upgrade "$slug")"
  local age; age="$(cache_age_days)"
  [ "$age" -le "$STALE_DAYS" ] || echo "codex-models: WARNING catalog is ${age}d old (any codex run refreshes it)" >&2
  echo "codex-models: $tier -> $slug (source=catalog, fetched $(jq -r .fetched_at "$CACHE"))" >&2
  echo "$slug"
}

efforts() {
  local slug="$1"
  if have_cache && jq -e --arg s "$slug" '.models[] | select(.slug==$s)' "$CACHE" >/dev/null; then
    jq -r --arg s "$slug" '.models[] | select(.slug==$s) | .supported_reasoning_levels[].effort' "$CACHE"
  else
    printf '%s\n' low medium high xhigh max   # unknown model: permissive default
  fi
}

list() {
  have_cache || die "no catalog at $CACHE"
  echo "catalog fetched: $(jq -r .fetched_at "$CACHE")  (client $(jq -r .client_version "$CACHE"))"
  jq -r '.models[] | select(.visibility=="list") | [ .priority, .slug, (.supported_reasoning_levels|map(.effort)|join("/")), .description ] | @tsv' "$CACHE" \
    | sort -n | awk -F'\t' '{printf "  p%-3s %-16s %-36s %s\n", $1, $2, $3, $4}'
}

agent_tier() { grep -m1 -E '^# codex-tier:' "$1" | sed -E 's/^# codex-tier:[[:space:]]*([a-z]+).*/\1/' || true; }
agent_model() { grep -m1 -E '^model[[:space:]]*=' "$1" | sed -E 's/^model[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/' || true; }

check() {
  list; echo
  local f fr st fa age
  fr="$(resolve frontier 2>/dev/null)"; st="$(resolve standard 2>/dev/null)"; fa="$(resolve fast 2>/dev/null)"
  age="$(cache_age_days)"
  echo "resolved: frontier=$fr standard=$st fast=$fa (catalog age ${age}d)"
  [ "$fr" = "$FALLBACK_FRONTIER" ] || echo "  NOTE: FALLBACK_FRONTIER=$FALLBACK_FRONTIER lags the catalog; bump it in codex-models.sh"
  [ "$st" = "$FALLBACK_STANDARD" ] || echo "  NOTE: FALLBACK_STANDARD=$FALLBACK_STANDARD lags the catalog; bump it in codex-models.sh"
  [ "$fa" = "$FALLBACK_FAST" ] || echo "  NOTE: FALLBACK_FAST=$FALLBACK_FAST lags the catalog; bump it in codex-models.sh"
  echo "agent TOMLs ($AGENTS_DIR):"
  local drift=0
  for f in "$AGENTS_DIR"/*.toml; do
    [ -f "$f" ] || continue
    local t m want
    t="$(agent_tier "$f")"; m="$(agent_model "$f")"
    case "$t" in frontier) want="$fr" ;; standard) want="$st" ;; fast) want="$fa" ;; *) want="" ;; esac
    if [ -z "$t" ]; then echo "  ?  $(basename "$f") model=$m (no '# codex-tier:' tag; untracked)"
    elif [ "$m" = "$want" ]; then echo "  ok $(basename "$f") tier=$t model=$m"
    else echo "  !! $(basename "$f") tier=$t model=$m -> should be $want (run: codex-models.sh sync-agents)"; drift=1; fi
  done
  return $drift
}

sync_agents() {
  local f fr fa
  fr="$(resolve frontier 2>/dev/null)"; st="$(resolve standard 2>/dev/null)"; fa="$(resolve fast 2>/dev/null)"
  for f in "$AGENTS_DIR"/*.toml; do
    [ -f "$f" ] || continue
    local t want
    t="$(agent_tier "$f")"
    case "$t" in frontier) want="$fr" ;; standard) want="$st" ;; fast) want="$fa" ;; *) continue ;; esac
    if [ "$(agent_model "$f")" != "$want" ]; then
      sed -i '' -E "s/^(model[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\1\"$want\"/" "$f"
      echo "updated $(basename "$f") -> $want"
    fi
  done
}

case "${1:-}" in
  resolve)     [ -n "${2:-}" ] || die "usage: resolve <frontier|standard|fast>"; resolve "$2" ;;
  efforts)     [ -n "${2:-}" ] || die "usage: efforts <slug>"; efforts "$2" ;;
  list)        list ;;
  check)       check ;;
  sync-agents) sync_agents ;;
  *) die "usage: codex-models.sh <resolve tier|efforts slug|list|check|sync-agents>" ;;
esac
