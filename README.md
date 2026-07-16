# Claude Delegation Kit

Deterministic multi-model delegation for [Claude Code](https://code.claude.com): drive the OpenAI **Codex CLI** as a subagent engine with pinned model/effort routing, plus model-pinned Claude subagent templates and org-level guidance for Claude Teams/Enterprise.

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

Requires: Codex CLI installed and logged in (`codex login`), `jq`, and Claude Code. Then in any Claude Code session:

```
~/.claude/skills/codex-delegate/scripts/codex-run.sh review "Adversarially review this diff: ..."
```

Claude Code picks the skill up automatically; it instructs Claude to classify each Codex task into one of six classes (`commit`, `implement`, `explore`, `ingest`, `review`, `hardest`) and let the script own every flag.

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
- **There is no global "all subagents use X" setting.** Pinning happens per definition (frontmatter) or per call (the `model` parameter on the Agent tool).
- **One-off/undefined subagents and built-in types (`general-purpose`, `Explore`, `Plan`, `fork`) inherit the session model.** An Opus session that spawns an ad-hoc researcher runs it on Opus unless the call passes `model` explicitly. This is the single biggest silent cost leak; the templates in `claude-agents/` exist to close it.
- Enterprise: **managed subagents** (agent files deployed via the managed settings directory) override same-named user/project agents — the org-wide pinning mechanism.

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
