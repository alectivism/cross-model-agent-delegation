# Org instructions for Claude Teams/Enterprise (Cowork + Chat + Code)

Organization instructions apply to every conversation across your org (Chat, Cowork, and Code), inject into every message, and take priority over users' personal preferences. Cap: 3,000 characters, admin-only. That makes them the right vehicle for an always-on delegation default; a skill is not (members can toggle skills off, and skills load only when Claude judges them relevant).

Two paste-ready versions. Which one depends on whether you have shipped an org agent plugin (pinned definitions) yet. A field lesson baked into both: the orchestrator can set a subagent's *model* at call time but not its *effort*, so "scale effort to difficulty" is only actionable through named agents with effort presets — don't instruct knobs the model can't turn.

**Before you ship pinned agents** (pure-prose stopgap):

> If subagent tools are available, don't default to model inheritance. Delegate self-contained subtasks (research, retrieval, review, summarization, tool runs, bulk edits) to Sonnet subagents; escalate the model to Opus only for hard analysis or high-stakes verification. Prefer purpose-built agents when one fits over general-purpose. Run independent subtasks in parallel in a single message; don't delegate when coordination overhead exceeds the saving. Subagents return only a final message, so tell them exactly what to report back: evidence, sources, and reasoning in a tight brief, not raw dumps or bare conclusions. Keep planning, synthesis, and final drafting on the originating model.

**After you ship pinned agents** (policy lives in the definitions; the instruction names the agents and keeps the trigger):

> Delegate to control cost: hand self-contained subtasks (research, retrieval, review, summarization, tool runs, bulk edits) to the org-defined agents by name: [researcher] for multi-source research, [summarizer] for long documents, [bulk-worker] for repetitive batch work, [verifier] before drafts or numbers are sent or acted on. Fall back to a general-purpose subagent only when none fits, and set its model to Sonnet explicitly; subagents otherwise inherit the expensive session model. Run independent subtasks in parallel in a single message; don't delegate when coordination overhead exceeds the saving. Subagents see none of the conversation and return only a final message, so give them full context and tell them exactly what to report back: evidence, sources, and reasoning in a tight brief, not raw dumps or bare conclusions. Keep planning, synthesis, and final drafting on the originating model.

Do not open the clause with "When delegating": that makes the whole policy conditional on a decision the model may never take. The trigger list ("hand self-contained subtasks...") is what creates the delegation moment; the named agents tell it where to route. Keep both.

## Why an instruction alone may not be enough

Subagents with no pinned model default to `inherit`: if a member's session runs on Opus, an unpinned subagent runs on Opus too. The instruction above relies on Claude remembering to pin Sonnet on every spawn. The robust backstop is definitions with the model baked in:

- **Claude Code (Enterprise)**: deploy **managed subagents** — markdown files in `.claude/agents/` inside the managed settings directory, same frontmatter as this repo's `claude-agents/`. Managed definitions override same-named project and user agents.
- **Cowork**: package pinned subagents in a **plugin** and provision it org-wide. There is no Cowork UI for hand-authoring agent files.

Before promising staff anything, run a 2-minute empirical check in Cowork: set the model to Opus, request a multi-source research task, then check usage for whether the subagent actually ran on Sonnet.
