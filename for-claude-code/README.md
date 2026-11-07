# Cross-Model Delegation for Claude Code

Claude Code keeps planning and synthesis on your main model and hands worker tasks to other model families: the OpenAI Codex CLI (GPT-6 Astra, Sol and Luna) for code, review and reasoning, and Gemini 4 Argon through Google's Antigravity CLI for writing. A shell wrapper owns every command-line flag, so Claude only picks a task class (`commit`, `implement`, `explore`, `ingest`, `review`, `hardest`, `prose`) and never improvises model, effort or sandbox settings. The plugin also runs a second Claude login side by side with one shared configuration, and ships model-pinned agent templates so ad-hoc subagents stop inheriting an expensive session model.

Full documentation, model prices and the evidence behind the routing: [github.com/alectivism/cross-model-agent-delegation](https://github.com/alectivism/cross-model-agent-delegation).

## Install

```
/plugin marketplace add alectivism/cross-model-agent-delegation
/plugin install cross-model-delegation@cross-model-agent-delegation
```

## What's inside

- **`skills/cross-model-delegation`**: `codex-run.sh` (Codex wrapper), `codex-models.sh` (resolves Codex model tiers from the CLI's own catalog), `codex-guard.sh` (optional hook that blocks raw `codex exec`), `agy-run.sh` (Gemini wrapper), and the skill instructions.
- **`skills/claude-accounts`**: `setup.sh`, the `claude-alt.sh` launcher, `alt-run.sh`, `accounts.py` (usage for a statusline) and `sync_config.py`.
- **`agents/`**: nine Claude subagent templates with `model:` and `effort:` pinned, plus a blank `_template.md`.

## Requirements

Claude Code. For Codex delegation, the Codex CLI signed in to a ChatGPT plan. For Gemini, the Antigravity CLI (`agy`) signed in to a Google AI Pro or Ultra plan. `python3` for the account scripts and `jq` for the optional guard hook.

## What it runs, sends and writes

Nothing runs on install: the plugin has no hooks or MCP servers. Scripts run only when Claude or you invoke them.

- **`codex-run.sh`** runs your installed `codex` CLI with your prompt. The prompt goes to OpenAI under your own Codex login. It unsets every exported `*_KEY` and `*_TOKEN` variable for that call, so an API key in your shell can't switch the run from your ChatGPT plan to API billing. The answer is written to a temp file whose path it prints.
- **`codex-models.sh`** reads `$CODEX_HOME/models_cache.json`, which the Codex CLI maintains. Its `sync-agents` command rewrites the `model =` line in your `~/.codex/agents/*.toml` files.
- **`agy-run.sh`** runs your installed `agy` CLI with your prompt, which goes to Google under your own Google login. It unsets every exported `*_KEY` and `*_TOKEN` variable for that call, starts agy in a new empty temp folder, and writes the answer to a temp file.
- **`codex-guard.sh`** reads the hook's JSON input and prints a deny decision for raw `codex exec` commands. It sends nothing. It is active only if you add it to your `settings.json` yourself, pointing at its path inside the plugin's install folder.
- **`setup.sh <name>`** creates `~/.claude-<name>/` with symlinks back into `~/.claude`, and links a `claude-<name>` launcher into `~/.local/bin`.
- **`claude-alt.sh`** runs `sync_config.py`, then unsets any exported Anthropic key or token variable (so the second login can't run on an API key), then starts the `claude` CLI with `CLAUDE_CONFIG_DIR` set to the second config folder.
- **`sync_config.py`** copies MCP server and per-project settings from `~/.claude.json` into the second login's `.claude.json`. Login and account fields are never copied.
- **`alt-run.sh`** runs one headless `claude -p` task under the second login and writes the result to a temp file.
- **`accounts.py`** reads the `rate_limits` object Claude Code passes to the statusline on stdin and caches each login's 5h and weekly usage in `~/.claude/claude-accounts-usage.json`. It reads no credentials and makes no network calls.

Only the wrappers that run a model (`codex-run.sh`, `agy-run.sh`, `alt-run.sh`) send anything off your machine, each through the CLI you installed and signed in to. No script reads credentials or collects telemetry.

## License

MIT, as set in `plugin.json` and the repository's `LICENSE`.
