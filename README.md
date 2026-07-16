# Claude Delegation Kit

Run [Claude Code](https://code.claude.com) with a powerful Anthropic model (Fable, Opus) as the **orchestrator**, and have it delegate the actual work to two pools of cheaper subagents: **Anthropic subagents** (Sonnet/Haiku, pinned per task type) and **GPT-5.6 subagents** (via the OpenAI Codex CLI on a ChatGPT subscription).

It does two related things:

1. **Cuts expensive-model token burn.** The orchestrator keeps planning, judgment, and final synthesis; research, review, retrieval, bulk edits, and mechanical work run on Sonnet/Haiku subagents or GPT-5.6 luna/terra leaves. Ad-hoc subagents in Claude Code silently inherit the session model, so an Opus session burns Opus on grep work unless something pins the model. This kit pins it.
2. **Spreads load across both subscriptions.** Claude quota and ChatGPT/Codex quota are separate pools. Routing self-contained reasoning, code review, and implementation leaf-work to Codex means your Claude limits last longer, and you get a cross-family bonus: a GPT model reviewing Claude's work (or vice versa) catches errors two same-family models share. That can be an adversarial review, a second opinion on a plan, or just "apply reasoning to this pile of search results" after cheap agents did the gathering.

You don't invoke any of this manually. You talk to Claude normally; the skill and rules make Claude classify and route on its own:

- "Fix the flaky retry test" → Claude does the fix, then delegates the verification to a `review`-class Codex call on gpt-5.6-sol.
- "What does our webhook layer actually do?" → an `explore`/`ingest` Codex call or a Sonnet researcher, depending on what's needed, with only the summary returning to your context.
- "Get a second opinion on this migration plan from GPT" → a `review`-class call, framed as feedback, not a bug hunt.
- A 40-file mechanical refactor → fan-out to luna/Haiku leaves, synthesis on the orchestrator.

The wrapper script exists so the *model classifies but never picks flags*: every Codex invocation goes through a task-class enum that pins model, reasoning effort, and sandbox deterministically.

![One orchestrator, two pools of cheaper workers](assets/architecture.svg)

## Why this pattern (the evidence)

This is the **orchestrator-worker pattern Anthropic benchmarked** on the Fable 5 launch: the strong model plans and delegates, cheap workers loop to completion, and most tokens bill at the worker rate. On BrowseComp (full set), Fable 5 orchestrating Sonnet 5 workers scored 86.8% at $18.53/problem vs 90.8% at $40.56 for all-Fable — **96% of the accuracy at 46% of the cost** — while all-Sonnet managed only 77.8%. ([the-decoder coverage](https://the-decoder.com/anthropics-fix-for-fable-5s-high-cost-is-turning-it-into-a-manager-that-delegates-to-sonnet-5/), [pattern guide](https://datasciencedojo.com/blog/claude-code-fable-5-orchestrator-workflow/))

![BrowseComp: accuracy vs cost per problem](assets/browsecomp.svg)

Anthropic also benchmarked the inverse "advisor" pattern (cheap model runs every turn, calls the strong model for guidance): ~92% of Fable's score at ~63% of the price on SWE-bench Pro. The orchestrator split won on both axes, which is why this kit implements the orchestrator pattern and not the advisor. This kit extends the benchmarked setup in two ways: the worker pool spans **two model families** (Sonnet/Haiku and GPT-5.6), and worker routing is **deterministic** (pinned definitions and a flag-owning script) rather than left to the orchestrator's judgment each spawn.

Everything here was built by fixing real failure modes, each independently verified (July 2026, codex-cli 0.144.1, Claude Code 2.1.x):

- `-c 'mcp_servers={}'` is a **no-op** (TOML table overrides merge), so the popular "disable MCP for speed" advice never worked; the real switch is `--ignore-user-config`.
- Codex's config default model is whatever the desktop app last wrote, so anything relying on it drifts silently.
- Sol-parent sessions get spawn tools that **hide** `model`/`reasoning_effort` ([openai/codex#31814](https://github.com/openai/codex/issues/31814)), silently running every subagent on Sol; two feature flags restore them.
- `codex exec` hangs on piped stdin in background runs; piping its stdout through `tail` silently truncates findings.
- Claude Code subagents default to `model: inherit`, so ad-hoc spawns from an Opus session burn Opus on mechanical work.

## What to install (the skill)

**The one thing to install is the `codex-delegate` skill.** Everything else is optional.

```bash
# 1. The skill (required) — wrapper script + routing rules
cp -r skills/codex-delegate ~/.claude/skills/

# 2. Codex-side subagent roles (recommended, for Codex multi-agent fan-outs)
mkdir -p ~/.codex/agents && cp codex-agents/*.toml ~/.codex/agents/

# 3. Claude subagent templates (optional, pick what you want)
mkdir -p ~/.claude/agents && cp claude-agents/*.md ~/.claude/agents/
```

Requires: Codex CLI installed and logged in (`codex login`), `jq`, and Claude Code. Also add the routing rules from [`docs/claude-md-snippet.md`](docs/claude-md-snippet.md) to your `CLAUDE.md` — that's the always-in-context layer that makes delegation happen by default instead of on request.

That's it. Claude Code loads the skill automatically whenever a task smells like Codex delegation ("ask GPT", "second opinion", "offload this review") or Claude itself decides to delegate. The skill instructs Claude to classify the task into one of six classes (`commit`, `implement`, `explore`, `ingest`, `review`, `hardest`) and run the wrapper, which owns every flag. You never type the script invocation yourself, though you can:

```bash
~/.claude/skills/codex-delegate/scripts/codex-run.sh review "Here is a plan and its context: ... What would you change and why?"
```

### Optional: hard enforcement hook

An instruction is a nudge; a hook is a gate. To block raw `codex exec` calls (with an explicit `CODEX_RAW=1` bypass), add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "~/.claude/skills/codex-delegate/scripts/codex-guard.sh",
        "timeout": 10
      }]
    }]
  }
}
```

## How the routing works

| Class | Model / effort | For |
|---|---|---|
| `commit` | luna / medium | commit messages, renames, trivial mechanical |
| `implement` | luna / xhigh (workspace-write) | small, fully specified code changes |
| `explore` | sol / medium | ambiguous work needing repo exploration or judgment |
| `ingest` | terra / medium | long-context read-heavy extraction (Luna's recall breaks here) |
| `review` | sol / medium | adversarial review, verdicts, architecture |
| `hardest` | sol / xhigh | after a cheaper class failed |

`--escalate` moves one rung up (allowed after a failure, or upfront when a wrong verdict triggers something irreversible). `--effort <level>` tunes effort within a class; the model stays pinned. The design principle: **the LLM only classifies; code owns the flags.** Determinism comes from shrinking the judgment surface to one enum, not from asking the model to remember rules.

The wrapper also bakes in: `--ignore-user-config` (drops ~20 MCP servers and ~50 plugins that otherwise cold-start for minutes), explicit sandbox (Codex configs often default to full access), `env -u OPENAI_API_KEY` (forces subscription auth), output to a file instead of stdout, `</dev/null` (background hang fix), and the [#31814](https://github.com/openai/codex/issues/31814) feature flags so a Sol orchestrator can actually route Luna/Terra leaves.

## Claude-side subagents: how model/effort pinning actually works

Facts current as of Claude Code 2.1.x ([docs](https://code.claude.com/docs/en/sub-agents)):

- Agent frontmatter supports **`model:`** (`sonnet`, `opus`, `haiku`, full ID, or `inherit`) and **`effort:`** (`low`..`max`). Both default to inheriting the session.
- **Model is settable at call time; effort is not.** The Agent tool exposes a per-call `model` override, but no effort parameter — effort only exists in definitions. So an instruction like "scale reasoning effort to difficulty" is unactionable for ad-hoc spawns; the orchestrator has no knob to turn. If you want effort routing, ship named agents with effort presets and instruct by agent name. That asymmetry is why this kit is definitions-first.
- **There is no global "all subagents use X" setting.** Pinning happens per definition (frontmatter) or per call (the `model` parameter on the Agent tool).
- **One-off/undefined subagents and built-in types (`general-purpose`, `Explore`, `Plan`, `fork`) inherit the session model.** An Opus session that spawns an ad-hoc researcher runs it on Opus unless the call passes `model` explicitly. This is the single biggest silent cost leak; the templates in `claude-agents/` exist to close it.
- **Bake the return format into each definition.** A subagent's report is appended to the main conversation and re-read on every subsequent turn, so a worker that dumps raw output taxes the orchestrator forever after. Every template in `claude-agents/` specifies what its final message must contain.
- Distribution: user-level (`~/.claude/agents/`), project (`.claude/agents/`), Enterprise **managed subagents** (managed settings directory; override same-named user/project agents), or a **plugin `agents/` directory** — the packaging unit that also reaches Cowork. Org admins can force-install plugins (Organization settings → Plugins, or `managed-settings.json`); note CLI users still install with `/plugin install`, and plugin agents ignore `hooks`, `mcpServers`, and `permissionMode` frontmatter. Skills cannot define agents; they can only reference them.

### The token economics (why this saves money at all)

The orchestrator re-reads its whole conversation every turn, including after each worker returns. Delegation pays because it controls what enters that transcript: a worker burns its tokens in a disposable context and hands back a tight brief, so 50k tokens of search noise become 500 tokens of summary, and prompt caching discounts the re-read of everything older. Two costs to respect: spawning has fixed overhead (system prompt + tool definitions load per worker, and multi-agent sessions run roughly 4-7x the raw tokens of single-agent), so tiny tasks are a net loss inline-able in one call; and nesting beyond two layers usually loses to context blindness — each layer only knows what its parent passed down. Fan out when the work is exploratory and bulky, stay inline when it's small, and stop at orchestrator → worker except when the middle layer genuinely compresses (a researcher fanning out per-source readers).

`claude-agents/` ships pinned templates: researcher, deep-research, content-writer, bug-investigator, doc-writer, pr-preparer, test-writer, dependency-auditor, adversarial-verifier, and a `_template.md`. The adversarial-verifier pairs with any generator as a generator/verifier split; run the verifier on a different model (or model family, via `codex-run.sh review`) than the generator — different models catch different errors.

## For Claude Teams/Enterprise admins (Cowork)

See [`docs/org-instructions-cowork.md`](docs/org-instructions-cowork.md) for a paste-ready organization instruction that propagates a lightweight version of this delegation policy to every member across Chat, Cowork, and Code, plus why an instruction alone isn't sufficient and what the plugin/managed-agent backstop looks like.

## Repo layout

```
skills/codex-delegate/           the skill: SKILL.md + codex-run.sh + codex-guard.sh
codex-agents/                    Codex subagent roles (~/.codex/agents/): luna-leaf, sol-reviewer, terra-ingest
claude-agents/                   model+effort-pinned Claude Code agent templates (~/.claude/agents/)
docs/org-instructions-cowork.md  org instruction for Teams/Enterprise admins
docs/claude-md-snippet.md        routing rules for your CLAUDE.md (always-in-context layer)
```

## Layered enforcement model

1. **Rules (CLAUDE.md)** — always in context; holds the routing policy. See `docs/claude-md-snippet.md`.
2. **Skill** — loaded on demand; holds the long-form detail and the scripts.
3. **Definitions** — agent frontmatter and TOML roles pin model/effort mechanically.
4. **Hook** — blocks the bypass path entirely.

A model reading a rule is compliance; a script owning the flags is determinism. Use both.

## Caveats

Model names (gpt-5.6-sol/terra/luna) and the #31814 behavior are point-in-time; re-verify after Codex CLI updates. The `codex features list` and `codex mcp list` commands are your friends — and don't trust an LLM's self-report of its own tool schema, ours confidently got it wrong in both directions. Verify with `--json` events or A/B tests.

## License

MIT
