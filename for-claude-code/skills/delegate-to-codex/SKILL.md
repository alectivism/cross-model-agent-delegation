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

| Tier | Resolution rule | Resolves to (2026-09-22) |
|---|---|---|
| `frontier` | newest listed `gpt-<ver>-astra` (`$CODEX_FRONTIER_FAMILY`), then any server `upgrade` pointer; if no Astra is listed, top model by priority, with a warning | `gpt-6-astra` |
| `standard` | newest listed `gpt-<ver>-sol` (`$CODEX_STANDARD_FAMILY`); falls back up to frontier | `gpt-6-sol` |
| `fast` | newest listed `gpt-<ver>-luna` (`$CODEX_FAST_FAMILY`); falls back up to standard | `gpt-6-luna` |

"Newest" is the highest version parsed from the slug, ties broken by catalog priority. Tiers resolve by family, not catalog rank, because `priority` is the model-picker order, not capability: on 2026-09-22 the catalog listed `gpt-6-sol` at p0 above `gpt-6-astra` at p1, and rank-based resolution swapped the frontier and standard tiers. New models only appear once the CLI is new enough (GPT-6 Sol and Luna arrived with codex-cli 0.156.0), so update the CLI when OpenAI announces a model.

Maintenance: `codex-models.sh check` prints the catalog, the resolved tiers, and whether `~/.codex/agents/*.toml` pins have drifted; `codex-models.sh sync-agents` rewrites them. Run `check` whenever OpenAI announces a model, or if a run's stderr line shows an unexpected slug. The one thing that still needs a human is the fallback constants and this table's "resolves to" column.

## Task classes

Astra, the frontier tier, costs several times Sol's usage per call, so it is reserved for review and the hardest calls, where a wrong verdict is expensive. Everything else runs on Sol, with Luna for mechanical work. Medium effort is the default; the catalog gives every current model a `default_reasoning_level` of `medium`.

| Class | Tier / effort | Use for |
|---|---|---|
| `commit` | fast / low | commit msgs, renames, trivial mechanical |
| `implement` | standard / medium (workspace-write) | bounded, specified code change |
| `explore` | standard / medium | ambiguous, needs repo exploration or judgment |
| `ingest` | standard / medium | long-context read-heavy extraction |
| `review` | frontier / medium | review, second opinions, feedback, verdicts, architecture |
| `hardest` | frontier / high | after another class failed, or genuinely hardest |
| `prose` | standard / medium | readability and copy editing of reader-facing prose; plain-language review by a second model |

Options: `--escalate` (one rung up: commit→medium, implement/explore/ingest/prose→frontier medium, review→high, hardest→xhigh; never ultra), `--effort low|medium|high|xhigh|max|ultra` (effort only; validated against the model's supported list and stepped down if unsupported), `--model <slug>`, `--priority`, `--verbosity low|medium|high`, `--ctx-mgmt`, `--write`, `--web`, `-C <dir>`, `-o <file>`, `--schema <file>`, `--img <file>`.

| Option | Maps to | Notes |
|---|---|---|
| `--priority` (was `--fast-tier`) | `service_tier="priority"` | "Fast" service tier: 2x speed on Astra, 1.5x on Sol and Luna, at 2.5x credit consumption. Unrelated to the `fast` model tier. Default is `service_tier="default"`; the catalog marks every model `default_service_tier: priority`, which `--ignore-user-config` would otherwise let through. |
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
- Listed 2026-09-22 (codex-cli 0.156.0), by priority: gpt-6-sol (0), gpt-6-astra (1, "most capable"), gpt-6-luna (2), gpt-5.6-sol (4), gpt-5.6-terra (5), gpt-5.6-luna (6), gpt-5.5 (7, retires 2026-10-14). Hidden: gpt-reserve, codex-auto-review. All GPT-6 models: 272k context, medium default effort, v2 multi-agent; Astra and Sol list `ultra`, Luna stops at `max`.
- The config.toml default model is never load-bearing: the Codex desktop app rewrites it when the user changes the picker. The wrapper always pins `-m` from the resolved tier.
- GPT-5.6 Luna (observed): fine on small bounded tasks, recall degrades over long contexts; GPT-6 Luna not yet characterized. It is the `fast` tier only; nothing routes ingestion or multi-file sweeps to it.
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

`multi_agent` is stable and enabled. In any `codex exec` run, Codex can spawn its own subagents. Predefined roles live in `~/.codex/agents/*.toml`; each carries a `# codex-tier: frontier|standard|fast` tag and `sync-agents` keeps the `model =` line current. Names are historical (`sol-reviewer`, `terra-ingest`); the tier tag, not the name, decides the model.

| Role | Tier / effort | Purpose |
|---|---|---|
| `luna-leaf` | fast / medium | single-file edit, tiny verdict |
| `sol-reviewer` | frontier / medium | adversarial review |
| `terra-ingest` | standard / medium | bulk reads, structured extraction |

Spawn-tool surface depends on the PARENT model's `multi_agent_version`: v1 parents (GPT-5.6 Luna) expose `spawn_agent` with `model`+`reasoning_effort`; v2 parents (every GPT-6 model, plus GPT-5.6 Sol and Terra) get "collab" tools that HIDE those fields by default (openai/codex#31814), silently running every leaf on the parent model. The wrapper passes `features.multi_agent_v2.hide_spawn_agent_metadata=false` and `tool_namespace="agents"` to restore them (end-to-end verified on a sol parent 2026-07-16; astra is v2 per the catalog, same flags apply). Do not otherwise enable `multi_agent_v2`.

For a fan-out job, run class `explore` or `review` and instruct the orchestrator explicitly, e.g.: "Spawn one luna-leaf agent per file, close each agent after collecting its result, then synthesize." Known behaviors:
- Caps: 6 concurrent threads (completed agents hold slots until `close_agent`), depth 1.
- Children inherit the PARENT's live sandbox; a TOML `sandbox_mode` is not authoritative. For a guaranteed read-only reviewer, run it as its own top-level `codex-run.sh review`.
- Full-history forks reject model/effort overrides; use fresh bounded children when routing to cheaper models.
- Approvals can't be granted mid-run in exec mode, so pick the sandbox up front.

## Quota awareness

Codex quota is invisible headless; treat the "workspace is out of credits" error as the signal to fall back to Claude subagents. Routing everything except review and hardest to Sol keeps Astra's usage for the calls that need it. `--priority` costs 2.5x credits for the same work, so it stays off by default; `ultra` costs a normal call plus its sub-agents, which is fine when the task actually splits. If you maintain a snapshot of your Claude rate limits (for example a statusline script writing `~/.claude/usage-snapshot.json`), check it before large fan-outs and shift heavy reasoning to Codex when the 7-day window runs hot.

## Common mistakes

| Mistake | Fix |
|---|---|
| Piping codex stdout through `tail`/`head` | Read the `OUT=` file (truncation silently dropped a real finding) |
| Hard-coding a model slug in a doc or script | Route through the tier; `codex-models.sh resolve frontier` if you need the slug |
| Assuming the config default model applies | The wrapper always pins `-m`; sessions misreport their model this way |
| Escalating "because stakes" without saying so | Allowed, but state which trigger applies (failure, or irreversible downstream action) |
| Luna for data ingestion | `ingest` (standard); Luna breaks on long contexts |
| Full context missing from prompt | MCP is off — include the diff/files/claims inline or via `-C` |
| Raw `codex exec` in a background task hangs | codex waits on piped stdin; the wrapper redirects `</dev/null` |
| Agent TOML pins drift after a release | `codex-models.sh check`, then `sync-agents` |
