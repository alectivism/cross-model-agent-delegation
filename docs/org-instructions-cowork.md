# Org instructions for Claude Teams/Enterprise (Cowork + Chat + Code)

Organization instructions apply to every conversation across your org (Chat, Cowork, and Code), inject into every message, and take priority over users' personal preferences. Cap: 3,000 characters, admin-only. That makes them the right vehicle for an always-on delegation default; a skill is not (members can toggle skills off, and skills load only when Claude judges them relevant).

Paste-ready snippet (about 600 characters, leaves room for your compliance and formatting rules):

> If subagent tools are available, don't default to model inheritance: delegate self-contained subtasks (research, retrieval, review, summarization, tool runs, bulk edits) to Sonnet subagents, scaling reasoning effort to difficulty — low for mechanical work, high for hard analysis or verification. Run independent subtasks in parallel; prefer purpose-built agents that fit. Subagents return only a final message, so when working detail matters, have them report evidence and reasoning, not just conclusions. Keep planning, synthesis, and final drafting on the originating model. Don't delegate when coordination overhead exceeds the saving.

## Why an instruction alone may not be enough

Subagents with no pinned model default to `inherit`: if a member's session runs on Opus, an unpinned subagent runs on Opus too. The instruction above relies on Claude remembering to pin Sonnet on every spawn. The robust backstop is definitions with the model baked in:

- **Claude Code (Enterprise)**: deploy **managed subagents** — markdown files in `.claude/agents/` inside the managed settings directory, same frontmatter as this repo's `claude-agents/`. Managed definitions override same-named project and user agents.
- **Cowork**: package pinned subagents in a **plugin** and provision it org-wide. There is no Cowork UI for hand-authoring agent files.

Before promising staff anything, run a 2-minute empirical check in Cowork: set the model to Opus, request a multi-source research task, then check usage for whether the subagent actually ran on Sonnet.
