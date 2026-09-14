---
name: delegate-to-codex
description: Use when delegating any task to the Codex CLI (codex exec, GPT-6 / GPT-5.6, "ask Codex", cross-model review, second opinion, offload to GPT) or when choosing a Codex model/effort tier. Covers single calls and Codex-side multi-agent orchestration.
---

# Codex Delegation

## Core rule

A PreToolUse hook (`scripts/codex-guard.sh`) blocks raw `codex exec` from the Bash tool. Bypass only with a `CODEX_RAW=1` prefix plus a stated reason (e.g. a flag the wrapper can't express).

Never hand-assemble `codex exec` flags. Classify the task into one class and run the wrapper; it owns model, effort, sandbox, service tier, MCP/plugin suppression, auth hygiene, and output handling:

```bash
~/.claude/skills/delegate-to-codex/scripts/codex-run.sh <class> [options] "<full-context prompt>"
# last stdout line: OUT=<file>  → Read that file. NEVER pipe codex stdout through head/tail.
```

## Models are resolved, not pinned

The wrapper never hard-codes a model slug. Each class maps to a **tier**, and `scripts/codex-models.sh` resolves the tier against Codex's own server-fetched catalog at `~/.codex/models_cache.json` (every `codex` run refreshes it with an ETag check; the wrapper's own calls keep it fresh). New releases (GPT-6 Sol, GPT-6.x, whatever follows) are picked up on the next call with no edit here.

| Tier | Resolution rule | Resolves to (2026-09-14) |
|---|---|---|
| `frontier` | lowest `priority` among `visibility: list` models, then follow any server `upgrade` pointer | `gpt-6-astra` |
| `fast` | `$CODEX_FAST_FAMILY` (default `gpt-5.6-luna`), follow `upgrade` pointer; if the family leaves the catalog, fall back to `frontier` (never a silent downgrade) | `gpt-5.6-luna` |

Overrides: `CODEX_MODEL=<slug>` env or `--model <slug>` pins a slug for one call (A/B comparisons, reproducing an old run). State why. If the catalog is missing, hard-coded fallbacks in `codex-models.sh` apply and the stderr line says `source=FALLBACK`.

Maintenance: `codex-models.sh check` prints the catalog, the resolved tiers, and whether `~/.codex/agents/*.toml` pins have drifted; `codex-models.sh sync-agents` rewrites them. Run `check` whenever OpenAI announces a model, or if a run's stderr line shows an unexpected slug. The one thing that still needs a human is the fallback constants and this table's "resolves to" column.

## Task classes

Tuned for a Pro-level ChatGPT plan: frontier is the default everywhere; `fast` only where a stronger model adds nothing. On a Plus plan, consider moving `explore`, `ingest`, and `prose` to `--effort low` or adding a `fast` route for them.

| Class | Tier / effort | Use for |
|---|---|---|
| `commit` | fast / medium | commit msgs, renames, trivial mechanical |
| `implement` | frontier / high (workspace-write) | bounded, specified code change |
| `explore` | frontier / medium | ambiguous, needs repo exploration or judgment |
| `ingest` | frontier / medium | long-context read-heavy extraction |
| `review` | frontier / high | review, second opinions, feedback, verdicts, architecture |
| `hardest` | frontier / xhigh | after another class failed, or genuinely hardest |
| `prose` | frontier / medium | readability and copy editing of reader-facing prose; plain-language review by a second model |

Options: `--escalate` (one rung up: commit→frontier medium, implement→xhigh, explore/ingest/prose→high, review→xhigh, hardest→ultra), `--effort low|medium|high|xhigh|max|ultra` (effort only; validated against the model's supported list and stepped down if unsupported), `--model <slug>`, `--fast-tier`, `--write`, `--web`, `-C <dir>`, `-o <file>`, `--schema <file>`, `--img <file>`.

| Option | Maps to | Notes |
|---|---|---|
| `--fast-tier` | `service_tier="priority"` | "Fast" tier: 2x speed, roughly 2x usage. Default is `service_tier="default"`; the catalog marks every model `default_service_tier: priority`, which `--ignore-user-config` would otherwise let through. |
| `--effort ultra` | `model_reasoning_effort="ultra"` | Max reasoning plus automatic Codex-side sub-agent delegation. See the Ultra section below. |
| `--schema <file>` | `--output-schema` | JSON Schema constraining the final message; the `OUT=` file then holds strict JSON. Use whenever you parse the result mechanically. |
| `--img <file>` | `--image=<file>` | Repeatable (one `--img` per file). Attaches images for multimodal reading (PDF table/figure pages where `pdftotext` loses alignment). The wrapper uses the equals form because clap's variadic `-i file` swallows the prompt. |

Use `--escalate` after a failure, or upfront when a wrong verdict would trigger an irreversible or outward-facing action; state which. Use `--effort` to tune within a class the same way: class defaults hold unless you state why this task is unusually hard or trivial for its class (`implement --effort max` for a compact but hard problem, `review --effort low` for a formatting check).

Deviating from the mapping means passing a different class, not different flags. If no class fits, say so to the user instead of improvising.

## Handoffs are claims, not evidence

Codex output is a claim about the world, not an observation of it. Before you act on it or report it to the user:

- **Re-run any check it says it ran.** "Tests pass", "the import works", "no network calls" are assertions. Run the same command yourself and record what you saw. If you cannot re-run it, label the finding **reported**, not **observed**.
- **Spot-check the diff, not the summary.** For `implement` and `hardest`, read the actual changed lines. A confident summary can describe code that was never written.
- **Distinguish "found nothing" from "did not look."** If Codex returns a clean verdict, confirm from its output that it actually inspected the relevant files. With `--ignore-user-config` it has no MCP and cannot look anything up, so a gap in the prompt becomes a silent gap in the review.
- **Never chain unverified output into an irreversible action** (commit, push, send, publish, delete). Verify first, or escalate to a second class and compare.

State which of these you did. "Codex reported X; I re-ran `pytest` and observed 8 passed" is the target form.

## Model facts (verified 2026-09-14, codex-cli 0.153.4)

- Catalog (`~/.codex/models_cache.json`) fields that matter: `priority` (1 = top), `visibility` (`list`/`hide`), `upgrade` (server-set successor pointer, null today), `supported_reasoning_levels`, `multi_agent_version`, `default_service_tier`.
- Listed today, by priority: gpt-6-astra (1, "most capable"), gpt-5.6-sol (4, "workhorse"), gpt-5.6-terra (7), gpt-5.6-luna (8), gpt-5.5 (12, previous generation). Hidden: gpt-reserve, codex-auto-review.
- The config.toml default model is never load-bearing: the Codex desktop app rewrites it when the user changes the picker. The wrapper always pins `-m` from the resolved tier.
- Luna: fine on small bounded tasks, recall degrades over long contexts. It is the `fast` tier only; nothing routes ingestion or multi-file sweeps to it.
- MCP suppression is `--ignore-user-config` (drops all MCP servers AND plugins; auth survives via CODEX_HOME). `-c 'mcp_servers={}'` is a NO-OP: TOML table overrides merge. To keep some servers, use `-c 'mcp_servers.<name>.enabled=false'` per server.
- Prompt must be self-contained: with MCP off Codex can't look anything up (`--web` re-adds built-in search only).

## Ultra mode: automatic sub-agent delegation

`ultra` is a reasoning level above `max` on the frontier models (astra, sol, terra list it; luna does not). At `ultra` the model reasons at maximum depth and decides on its own when to spawn Codex sub-agents for parallelizable or context-heavy parts of the task, using the same multi-agent machinery described below. Nothing else needs enabling: `multi_agent` is on, the wrapper already passes the v2 spawn-metadata flags, and the roles in `~/.codex/agents/` are available to the orchestrator.

How to invoke:

```bash
codex-run.sh hardest --escalate "<prompt>"        # hardest's escalation rung is ultra
codex-run.sh review --effort ultra "<prompt>"      # any frontier class, state why
```

Observed 2026-09-14: `hardest --effort ultra` on gpt-6-astra with a three-file read task spawned one sub-agent unprompted to read two of the files and synthesized the result itself (23.5k tokens, about 90 seconds, read-only sandbox). The wrapper steps `ultra` down to the model's top supported level when the resolved model lacks it, so a `commit --effort ultra` runs luna at `max` and says so on stderr.

When to reach for it: work that splits naturally (per-file review, per-source research, a repo sweep with a synthesis step) or a hard problem where a second internal pass is worth the tokens. When not to: single-file leaf tasks, anything where you need a guaranteed read-only child (sub-agents inherit the parent sandbox), or when you want to control the fan-out yourself, in which case use `explore`/`review` with explicit spawn instructions as below. Cost is a normal frontier call plus whatever the sub-agents consume; it is not the Fast service tier and does not change per-token pricing.

## Codex-side subagents (multi-agent)

`multi_agent` is stable and enabled. In any `codex exec` run, Codex can spawn its own subagents. Predefined roles live in `~/.codex/agents/*.toml`; each carries a `# codex-tier: frontier|fast` tag and `sync-agents` keeps the `model =` line current. Names are historical (`sol-reviewer`, `terra-ingest`); the tier tag, not the name, decides the model.

| Role | Tier / effort | Purpose |
|---|---|---|
| `luna-leaf` | fast / xhigh | single-file edit, tiny verdict |
| `sol-reviewer` | frontier / medium | adversarial review |
| `terra-ingest` | frontier / medium | bulk reads, structured extraction |

Spawn-tool surface depends on the PARENT model's `multi_agent_version`: v1 parents (luna) expose `spawn_agent` with `model`+`reasoning_effort`; v2 parents (astra, sol, terra) get "collab" tools that HIDE those fields by default (openai/codex#31814), silently running every leaf on the parent model. The wrapper passes `features.multi_agent_v2.hide_spawn_agent_metadata=false` and `tool_namespace="agents"` to restore them (end-to-end verified on a sol parent 2026-07-16; astra is v2 per the catalog, same flags apply). Do not otherwise enable `multi_agent_v2`.

For a fan-out job, run class `explore` or `review` and instruct the orchestrator explicitly, e.g.: "Spawn one luna-leaf agent per file, close each agent after collecting its result, then synthesize." Known behaviors:
- Caps: 6 concurrent threads (completed agents hold slots until `close_agent`), depth 1.
- Children inherit the PARENT's live sandbox; a TOML `sandbox_mode` is not authoritative. For a guaranteed read-only reviewer, run it as its own top-level `codex-run.sh review`.
- Full-history forks reject model/effort overrides; use fresh bounded children when routing to cheaper models.
- Approvals can't be granted mid-run in exec mode, so pick the sandbox up front.

## Quota awareness

Codex quota is invisible headless; treat the "workspace is out of credits" error as the signal to fall back to Claude subagents. A Pro-level plan makes frontier-by-default affordable. `--fast-tier` roughly doubles usage for the same work, so it stays off by default; `ultra` costs a normal call plus its sub-agents, which is fine when the task actually splits. If you maintain a snapshot of your Claude rate limits (for example a statusline script writing `~/.claude/usage-snapshot.json`), check it before large fan-outs and shift heavy reasoning to Codex when the 7-day window runs hot.

## Common mistakes

| Mistake | Fix |
|---|---|
| Piping codex stdout through `tail`/`head` | Read the `OUT=` file (truncation silently dropped a real finding) |
| Hard-coding a model slug in a doc or script | Route through the tier; `codex-models.sh resolve frontier` if you need the slug |
| Assuming the config default model applies | The wrapper always pins `-m`; sessions misreport their model this way |
| Escalating "because stakes" without saying so | Allowed, but state which trigger applies (failure, or irreversible downstream action) |
| Luna for data ingestion | `ingest` (frontier); Luna breaks on long contexts |
| Full context missing from prompt | MCP is off — include the diff/files/claims inline or via `-C` |
| Raw `codex exec` in a background task hangs | codex waits on piped stdin; the wrapper redirects `</dev/null` |
| Agent TOML pins drift after a release | `codex-models.sh check`, then `sync-agents` |
