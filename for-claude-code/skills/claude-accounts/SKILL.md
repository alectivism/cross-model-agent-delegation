---
name: claude-accounts
description: Run a second Claude Code login (for example work and personal) side by side with one shared configuration, move a conversation from one login to the other, or run a task on the second login from the first. Use for "switch accounts", "use my other account", "claude-personal", the ACCOUNTS line, or setting this up.
---

# Two Claude logins, one configuration

Claude Code keys its login to the config dir: the macOS Keychain item `Claude Code-credentials` for `~/.claude`, `Claude Code-credentials-<sha256(dir)[:8]>` for any other `CLAUDE_CONFIG_DIR` (observed in 2.1.318), or `<dir>/.credentials.json` on other platforms per the docs (untested here). So a second config dir is a second login, and both stay signed in. `/login` inside a session instead replaces the login for the whole dir: every open session on that dir moves to the new account, and switching back needs another browser sign-in.

| Command | Login | Config dir |
|---|---|---|
| `claude` | main | `~/.claude` |
| `claude-<name>` | second | `~/.claude-<name>` (symlinks into `~/.claude`) |

## Setup (once)

```bash
${CLAUDE_SKILL_DIR}/scripts/setup.sh personal   # any name; default personal
claude-personal auth login                                    # pick the other account in the browser
claude-personal auth status                                   # expect its email and configDirectory ~/.claude-personal
```

`setup.sh` links settings, CLAUDE.md, skills, agents, commands, hooks, plugins and the session store into the new dir. `sync_config.py` copies MCP servers and per-project MCP/trust settings from `~/.claude.json` on every launch, and never account fields. If the main login is an org seat (tested on Team), the launcher layers its cached org-managed settings onto the second login so both follow the same permission rules (`CLAUDE_ALT_ORG_SETTINGS=0` turns that off).

Not shared: the login, claude.ai connectors (each account's own claude.ai settings), and the background-session list.

## Moving a conversation to the other login (the user runs this)

1. `/exit` in the session.
2. `claude-personal --resume <id>` (or `claude --resume <id>` to go back). `--resume` with no ID opens a picker over every session from both logins.

The full conversation history goes to whichever account continues it.

## Running a task on the second login

Agent-tool subagents always bill the calling login, so a task meant for the second login goes through the wrapper:

```bash
${CLAUDE_SKILL_DIR}/scripts/alt-run.sh [--name personal] [--model M] [--effort E] [--resume ID] [-C dir] "<full-context prompt>"
# stdout ends: ACCOUNTS ... / SESSION=<id> / OUT=<file>  → Read OUT. Follow up with --resume <SESSION>.
```

The child has the same skills and tools but none of this conversation, so write the prompt as a complete brief. Long tasks: run it in the background. A failed run exits 1, shows `is_error=True` on stderr and puts the reason in OUT; raw JSON is at `<OUT>.json`.

## Usage for both logins

`scripts/accounts.py` reads 5h and weekly usage for both logins from the OAuth usage endpoint that `/usage` uses (undocumented; every field is parsed defensively, so a plan that omits a bucket just shows fewer numbers). Weekly is the most-used weekly bucket, including per-model weekly caps where a plan has them.

- **Hook line:** add `python3 ${CLAUDE_SKILL_DIR}/scripts/accounts.py line` as a `UserPromptSubmit` hook. It prints `ACCOUNTS main 5h 48%/4h25m 7d 16% H=0.59 TIGHT | personal 5h 0% ... OPEN` and refreshes in the background at most every 3 minutes. `H` is a pace ratio: remaining quota over remaining fraction of the window; under 1 runs out before the reset.
- **Statusline:** `accounts.py segment` prints `main 5h 48% (4h25m) 7d 16% | personal 5h 0% 7d 0%`. Pipe the statusline's stdin JSON into it so the session's own `rate_limits` are the fallback. A dot appears only at 70%+ (🟡) or 90%+ (🔴); weekly reset times appear at 70%+.
- Labels: `CLAUDE_MAIN_LABEL` (default `main`), `CLAUDE_ALT_LABEL` (default the name).
- `use=<name>` on the line means the main login is short on headroom (under 25% left, or its 5h window 20%+ used and on pace to run out before the reset, or 50%+ used at any pace; never within 15 minutes of a reset) and the second login has room. `switch=<name>` (75%+ of the main 5h window, or out) means the conversation itself should move: `/compact`, `/exit`, then `claude-<name> --resume <id>` (resume replays the whole transcript on the other login, and the prompt cache doesn't carry across).
- `idle` means that login's access token has expired from disuse, so the probe can't read it. The line keeps the last reading (a 5h bucket whose reset time has passed shows as reset) and shows `UNKNOWN` if there is none yet. `SIGNED_OUT` means run `claude-<name> auth login`.
- The probe never refreshes tokens. A refresh rotates the stored refresh token and would sign Claude Code out.

## Troubleshooting

- A hook or script that edits `.claude.json` must honor `CLAUDE_CONFIG_DIR` (`$CLAUDE_CONFIG_DIR/.claude.json` when set, `~/.claude.json` otherwise), or the second login never sees its changes.
- New top-level items in `~/.claude` that should be shared: re-run `setup.sh <name>`, or set `CLAUDE_ACCOUNTS_SHARE_EXTRA`.
- Undo: `claude-<name> auth logout`, then `rm -rf ~/.claude-<name> ~/.local/bin/claude-<name>`.
- Tests (offline, no Keychain or network): `python3 -m unittest discover -s tests`.
