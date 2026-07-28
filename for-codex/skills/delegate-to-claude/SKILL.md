---
name: delegate-to-claude
description: Use when delegating any task from Codex to the Claude Code CLI (claude -p, "ask Claude", cross-model review, second opinion, offload to Claude, get a Claude verdict) or when choosing a Claude model/effort tier for a worker. Covers single calls and read-only vs write-capable workers.
---

# Delegating to Claude Code

You are running in Codex. This skill fires when work is better sent to a Claude worker than done here.

## Core rule

Never hand-assemble `claude -p` flags. Classify the task into one class and run the wrapper. It owns model, effort, permission mode, tool surface, MCP and skill suppression, auth hygiene, and output handling:

```bash
~/.codex/skills/delegate-to-claude/scripts/claude-run.sh <class> [options] "<full-context prompt>"
# last stdout line: OUT=<file>  → read that file
```

A PreToolUse-style guard (`scripts/claude-guard.sh`, registration in the repo README) blocks raw `claude -p` from the shell. Bypass only with a `CLAUDE_RAW=1` prefix plus a stated reason, for example a flag the wrapper cannot express such as `--json-schema`.

## Task classes

| Class | Model / effort | Mode | Use for |
|---|---|---|---|
| `commit` | haiku / low | read-only | commit messages, renames, trivial mechanical |
| `implement` | sonnet / high | write | small, fully specified code change |
| `explore` | sonnet / medium | read-only | ambiguous, needs repo exploration or judgment |
| `ingest` | haiku / medium | read-only | long-context read-heavy extraction |
| `review` | sonnet / high | read-only | review, second opinions, verdicts, architecture |
| `hardest` | opus / xhigh | read-only | after a cheaper class failed, or genuinely hardest |

Options: `--escalate` (one rung up), `--effort low|medium|high|xhigh|max` (effort only, model stays class-pinned), `--write`, `--web`, `-C <dir>`, `-o <file>`, `--json`.

Use `--escalate` after a failure, or upfront when a wrong verdict would trigger something irreversible or outward-facing; state which reason applies. Use `--effort` the same way: class defaults hold unless you say why this task is unusually hard or trivial for its class.

Deviating from the mapping means passing a different class, not different flags. If no class fits, say so instead of improvising.

## Why send work to Claude at all

Two reasons, both structural rather than "Claude is better":

- **Cross-family review.** Two models from the same family share blind spots. A Claude worker reviewing GPT output catches errors a second GPT pass will agree with. This is the highest-value class here, and it's why `review` sits on sonnet/high rather than the cheapest tier that would answer.
- **Separate quota pools.** ChatGPT and Claude subscriptions bill against different limits. Pushing leaf work across the boundary makes both last longer. When one side reports quota exhaustion, the other is unaffected.

## What read-only actually means here

Read-only classes get `Read,Glob,Grep,TodoWrite` and nothing else. No Bash, no Write, no Edit. This is deliberate and it constrains how you write prompts:

- The worker **cannot run a command**. If the task needs a diff, test output, `git log`, or a build result, run it here and paste it into the prompt.
- The worker **can** read, glob, and grep any file under the directory you pass with `-C`.
- Asking a read-only class to change a file returns a one-line refusal, not an error. That is the intended behavior, not a misconfiguration.

`implement` (or any class with `--write`) gets the default tool set in `acceptEdits`, so it can edit files without prompting. Scope it with `-C` and keep the task fully specified.

## Verified facts (2026-07-27, Claude Code 2.1.220)

- **`--model haiku` silently resolves to Sonnet 5.** Only `fable`, `opus`, and `sonnet` are documented aliases; `haiku` is not one, and instead of erroring it falls through to Sonnet. A haiku-tier call written with the alias bills at Sonnet and nothing in the output says so. The wrapper pins the full ID `claude-haiku-4-5-20251001`. Check any call yourself with `--output-format json` and read `modelUsage`.
- **`--strict-mcp-config` is the MCP kill switch**, and it is worth using on every worker call: 123 tools drop to 29 built-ins on a fully-loaded machine. Those 94 tool schemas would otherwise load every turn. `--disable-slash-commands` drops all skills for the same reason.
- **Do not reach for `--bare`.** It reads like the equivalent of Codex's `--ignore-user-config`, but it also forces auth to `ANTHROPIC_API_KEY` or an `apiKeyHelper` and never reads OAuth or the keychain. On a subscription it either fails outright or quietly bills the API.
- **The prompt must go on stdin, never as a positional argument.** `--tools`, `--add-dir`, `--allowedTools`, and `--mcp-config` are all variadic, so a trailing positional prompt is swallowed as another value for whichever came last. The symptom is a confusing `Input must be provided either through stdin or as a prompt argument` even though you passed a prompt.
- **Plan mode is the wrong lock for a worker.** `--permission-mode plan` does block writes including through Bash, but it also brings the interactive plan-mode framing: workers write plan documents into `~/.claude/plans/` and end on "shall I proceed?" instead of answering. Dropping Bash from the tool list is the stronger lock and the quieter one.
- **There is no `-C`.** The CLI has no working-directory flag; the wrapper `cd`s and passes `--add-dir`.
- **CLAUDE.md auto-discovery is on.** A worker started in a directory inherits that project's `CLAUDE.md`. Usually useful, occasionally not: point `-C` at the tree you actually want it reading.

## Writing the prompt

MCP is off and skills are off, so the worker cannot look anything up beyond the filesystem it can see and, with `--web`, the web. Everything it needs to reason about goes in the prompt or in the `-C` tree. In practice:

- Paste the diff, the failing output, or the claim to be checked inline.
- Say what "done" looks like in one sentence.
- For `review`, frame it adversarially: "try to refute this" beats "what do you think", which returns agreeable prose.

## Common mistakes

| Mistake | Fix |
|---|---|
| `--model haiku` | Use the wrapper. The alias silently runs Sonnet. |
| Prompt as a positional argument | The wrapper puts it on stdin; variadic flags eat trailing args. |
| Asking a read-only class to run tests | No Bash. Run them here, paste the output. |
| Starting on `hardest` because the task feels important | `review` is sonnet/high. Escalate after a failure, and say so. |
| `--bare` to strip config | It breaks subscription auth. Use `--strict-mcp-config`. |
| Trusting the printed model | Only `--output-format json` → `modelUsage` proves which model ran. |
