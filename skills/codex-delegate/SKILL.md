---
name: codex-delegate
description: Use when delegating any task to the Codex CLI (codex exec, GPT-5.6, "ask Codex", cross-model review, second opinion, offload to GPT) or when choosing a Codex model/effort tier. Covers single calls and Codex-side multi-agent orchestration.
---

# Codex Delegation

## Core rule

Optionally, a PreToolUse hook (`scripts/codex-guard.sh`, see repo README for registration) blocks raw `codex exec` from the Bash tool. Bypass only with a `CODEX_RAW=1` prefix plus a stated reason (e.g. a flag the wrapper can't express, like `--output-schema`).

Never hand-assemble `codex exec` flags. Classify the task into one class and run the wrapper; it owns model, effort, sandbox, MCP/plugin suppression, auth hygiene, and output handling:

```bash
~/.claude/skills/codex-delegate/scripts/codex-run.sh <class> [options] "<full-context prompt>"
# last stdout line: OUT=<file>  → Read that file. NEVER pipe codex stdout through head/tail.
```

## Task classes

| Class | Model / effort | Use for |
|---|---|---|
| `commit` | luna / medium | commit msgs, renames, trivial mechanical |
| `implement` | luna / xhigh (workspace-write) | small, fully specified code change |
| `explore` | sol / medium | ambiguous, needs repo exploration or judgment |
| `ingest` | terra / medium | long-context read-heavy extraction |
| `review` | sol / medium | review, second opinions, feedback, verdicts, architecture |
| `hardest` | sol / xhigh | after a cheaper class failed, or genuinely hardest |

Options: `--escalate` (one rung up), `--effort low|medium|high|xhigh|max` (effort only, model stays class-pinned), `--write`, `--web`, `-C <dir>`, `-o <file>`.

Use `--escalate` after a failure, or upfront when a wrong verdict would trigger an irreversible or outward-facing action; state which reason applies. Use `--effort` to tune within a class the same way: class defaults hold unless you state why this task is unusually hard or trivial for its class (e.g. `implement --effort max` for a compact but hard problem, `review --effort low` for a formatting check).

Deviating from the mapping means passing a different class, not different flags. If no class fits, say so to the user instead of improvising.

## Model facts (verified 2026-07-16, codex-cli 0.144.1)

- The config.toml default model is never load-bearing: the Codex desktop app rewrites it when the user changes the model picker. The wrapper always pins `-m`.
- Luna: capable on small bounded tasks, but recall degrades over long contexts. Never use it for ingestion or multi-file sweeps.
- Terra: niche; only worth it for long-context read-heavy work (`ingest`).
- MCP suppression is `--ignore-user-config` (drops all MCP servers AND plugins; auth survives via CODEX_HOME). `-c 'mcp_servers={}'` is a NO-OP: TOML table overrides merge (verify yourself with `codex mcp list -c 'mcp_servers={}'`). To keep some servers, use `-c 'mcp_servers.<name>.enabled=false'` per server.
- Prompt must be self-contained: with MCP off Codex can't look anything up (`--web` re-adds built-in search only).

## Codex-side subagents (multi-agent)

`multi_agent` v1 is stable and enabled by default. In any `codex exec` run, Codex can spawn its own subagents. Predefined roles live in `~/.codex/agents/*.toml`: `luna-leaf` (xhigh default, small bounded), `sol-reviewer` (medium, adversarial), `terra-ingest` (medium, bulk reads). The orchestrator may tune a spawn's `reasoning_effort` off the role default under the same rule as `--effort`: unusually hard or trivial for its class, reason stated in its plan.

Spawn-tool surface depends on the PARENT model (verified 2026-07-16): luna parents get `multi_agent_v1__spawn_agent` with `model`+`reasoning_effort`; sol parents get v2-style "collab" tools that HIDE those fields by default (openai/codex#31814), silently running every leaf on Sol. The wrapper fixes this by passing `features.multi_agent_v2.hide_spawn_agent_metadata=false` and `tool_namespace="agents"`; end-to-end verified (sol/medium orchestrator ran two luna/low leaves, fields accepted). Raw calls without those flags lose leaf routing on sol parents. Do not otherwise enable `multi_agent_v2`.

For a fan-out job, run class `explore` or `review` and instruct the orchestrator explicitly, e.g.: "Spawn one luna-leaf agent per file, close each agent after collecting its result, then synthesize." Known behaviors:
- Caps: 6 concurrent threads (completed agents hold slots until `close_agent`), depth 1 (child can't spawn grandchild).
- Children inherit the PARENT's live sandbox; a TOML `sandbox_mode` is not authoritative. For a guaranteed read-only reviewer, run it as its own top-level `codex-run.sh review`.
- Full-history forks reject model/effort overrides; use fresh bounded children when routing to cheaper models.
- Approvals can't be granted mid-run in exec mode, so pick the sandbox up front.
- The `~/.codex/agents/*.toml` roles apply only to agents Codex spawns internally; the wrapper governs top-level calls. Keep both in sync via this skill.

## Quota awareness

Codex quota is invisible headless (only per-turn token counts via `--json`); treat its "workspace is out of credits" error as the signal to fall back to Claude subagents. If you maintain a snapshot of your Claude rate limits (e.g. a statusline script writing `~/.claude/usage-snapshot.json`), check it before large fan-outs and shift heavy reasoning to Codex when the 7-day window runs hot.

## Common mistakes

| Mistake | Fix |
|---|---|
| Piping codex stdout through `tail`/`head` | Read the `OUT=` file (truncation silently dropped a real finding) |
| Assuming the config default model applies | The wrapper always pins `-m`; sessions misreport their model this way |
| Starting on sol high "because stakes" | `review` = sol medium; escalate only after a failure, and say so |
| Luna for data ingestion | `ingest` (terra); Luna breaks on long contexts |
| Full context missing from prompt | MCP is off — include the diff/files/claims inline or via `-C` |
| Raw `codex exec` in a background task hangs | codex waits on piped stdin; the wrapper redirects `</dev/null` |
