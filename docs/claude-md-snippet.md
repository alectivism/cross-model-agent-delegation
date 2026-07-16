# CLAUDE.md snippet: delegation and routing rules

Add to `~/.claude/CLAUDE.md` (personal, all projects) or a repo's `CLAUDE.md`. Rules files are always in context; that's what makes them the right layer for routing defaults (a skill only loads when Claude decides it's relevant).

```markdown
## Subagent routing

Default subagents to **sonnet** — it handles review, search, docs-lookup,
summarization, extraction, and bulk/mechanical work. Reserve the top-tier
model for deep reasoning, architectural judgment, tricky debugging, and
high-stakes long-form prose.

**The inheritance trap:** a subagent whose definition has no `model:` field
defaults to `inherit` — it silently runs on the session model. Built-in agent
types (`general-purpose`, `Explore`, `Plan`, `fork`) have no pin either. So
when spawning a built-in or ad-hoc subagent for non-deep work, ALWAYS pass
`model: "sonnet"` in the Agent call. Custom agents in `~/.claude/agents/` pin
`model:` (and optionally `effort:`) in frontmatter — prefer them.

## Codex CLI (shelling out)

When shelling out to the Codex CLI non-interactively, always use the wrapper:
`~/.claude/skills/codex-delegate/scripts/codex-run.sh <class> "<prompt>"`
(classes: commit, implement, explore, ingest, review, hardest). It pins
model+effort per class and passes `--ignore-user-config`, which drops all MCP
servers and plugins (the multi-minute cold-start). Note `-c 'mcp_servers={}'`
does NOT work — TOML table overrides merge, so an empty table is a no-op.
Put full context in the prompt (MCP off means Codex can't look things up);
add `--web` if it needs web search. Read the file printed as `OUT=<path>`;
never pipe codex stdout through head/tail.
```
