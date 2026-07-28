# Security Policy

## What this repo does to your machine

This is not a library you import. Installing it means putting shell scripts on your `PATH`-adjacent config directories and, optionally, registering a `PreToolUse` hook that intercepts every Bash command your agent runs. Specifically:

- `codex-run.sh` and `claude-run.sh` build and execute CLI invocations with a pinned sandbox mode, and write output to a temp file.
- `codex-guard.sh` and `claude-guard.sh` run as `PreToolUse` hooks and can block or allow tool calls.
- The agent and role definitions are written into `~/.claude/agents/` and `~/.codex/agents/`.

Read the scripts before installing them. They are short on purpose.

## Reporting a vulnerability

Email **alec@mmaglobal.com** with "cross-model-agent-delegation" in the subject. Include what you found, how to reproduce it, and what an attacker gets. I will acknowledge within a week.

Things worth reporting:

- A way to bypass `codex-guard.sh` or `claude-guard.sh` other than the documented `CODEX_RAW=1` / `CLAUDE_RAW=1` escape hatches.
- Command injection through a prompt argument, a filename, or an environment variable that reaches one of the wrapper scripts.
- Any path where a wrapper widens the sandbox beyond the mode named in its task class.
- Credential leakage: the wrappers deliberately run `env -u OPENAI_API_KEY` / `env -u ANTHROPIC_API_KEY` to force subscription auth, so a path that reintroduces an API key is a bug.

Please do not open a public issue for anything in that list.

## Not vulnerabilities

- The guard hooks are a routing gate, not a security boundary. They stop an agent from improvising flags; they do not contain a determined attacker who already controls your shell.
- Both CLIs can be pointed at a sandbox mode that writes to your workspace. That is the documented behavior of the `implement` task class.
- Model names, effort tiers, and vendor bug behaviors change without notice. A stale claim in the README is a docs bug, not a security issue.

## Supported versions

Only `main` is supported. Behavior is verified against specific CLI versions named in the README; older tags are historical.
