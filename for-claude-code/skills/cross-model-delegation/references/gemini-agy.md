# Gemini via the Antigravity CLI (agy)

Google retired the Gemini CLI for consumer accounts on 2026-06-18; the Antigravity CLI (`agy`) replaced it. `agy` runs on a Google AI Pro or Ultra subscription through a Google account login stored in the OS keychain, so a call costs nothing beyond the subscription. Gemini 4 Argon reached the Antigravity CLI on 2026-10-13 for Ultra ([9to5Google](https://9to5google.com/2026/10/13/gemini-app-4-argon/)) and began rolling out to Pro on 2026-10-15 ([Antigravity on X](https://x.com/antigravity/status/2110040034489381228)); a Pro account ran it on 2026-11-06.

## Setup

1. Install the Antigravity CLI from Google's installer, then run `agy` once interactively and sign in with your Google account.
2. `agy models` must list `gemini-4-argon-*`. If it doesn't, update the CLI: agy self-updates on launch, and a 1.1.x build on 2026-11-06 listed no Argon until it updated itself to 1.5.2.
3. Optional: to make sure an API key never takes over, set `security.auth.enforcedType` to `oauth-personal` in `~/.gemini/settings.json` and list any Gemini or Google API-key variables you export under `advanced.excludedEnvVars`. The wrapper also unsets every exported `*_KEY` and `*_TOKEN` variable for its own call.

## Run it

```bash
scripts/agy-run.sh <class> "<full-context prompt>"
```

| Class | Model | Use for |
|---|---|---|
| `prose` | Gemini 4 Argon (Medium) | drafting, rewriting, tone and voice critique |
| `review` | Gemini 4 Argon (High) | second opinion on a draft, plan or argument |
| `fast` | Gemini 3.8 Flash (Low) | extraction, mechanical edits, large-file reads |
| `image` | Gemini 3.8 Flash (Medium) | images through agy's built-in `generate_image` tool |

Options: `--model <id>` (any id from `agy models`), `-C <dir>`, `-o <file>`. The last stdout line is `OUT=<file>`; read it. Exit 1 means the run failed and OUT says why; the raw JSON (status, token usage) is kept at `<OUT>.json`.

Where Argon fits: it writes well and is weaker at code. Use it as the third family on writing checks (drafts, messaging, published prose) beside a Claude and a Codex run. For code, Codex `review` stays the cross-family reviewer and Argon is an extra opinion.

Behavior to know:
- agy sees only the prompt: none of the calling conversation, Claude's MCP servers, skills or memory.
- In print mode agy runs its tools without asking. The wrapper therefore starts it in a fresh empty temp dir; pass `-C` only for a directory it may read.
- `agy -p --model X "prompt"` fails: `-p` takes the next word as its prompt. The wrapper passes `--print="<prompt>"` last, which also keeps a prompt starting with `-` from being read as a flag.
- `--output-format json` returns `status`, `response` and token `usage`, but not the model that served the call. Its log (`~/.gemini/antigravity-cli/log/`) records `Resolving model <id>` if you need to check.
- agy's browser subagent doesn't run on macOS, and its web search returns index summaries, not full pages.

## Quota

Google doesn't report Argon usage. The Antigravity backend's quota endpoints (`v1internal:retrieveUserQuotaSummary` and `v1internal:fetchAvailableModels`) list per-group 5-hour and weekly buckets for the Claude/GPT models and one remaining fraction per Gemini Flash model, but on 2026-11-06 Argon appeared in neither, and a 14k-token Argon (High) run left every reported bucket at 100%. Treat Argon headroom as unknown; a quota error from the wrapper is the only signal.

## Claude and GPT inside agy

agy also serves Claude Opus/Sonnet 5.5 and GPT-OSS 120B on the Google subscription. Google's quota summary says each model group has its own 5-hour and weekly limits, and on 2026-11-06 an Opus call moved only the Claude/GPT group (to 1.7% used) while Gemini stayed at 0%. So it is extra capacity, not a share of Gemini's, but small: one 8k-token Opus call used 1.7% of the 5-hour bucket. For a self-contained review or writing prompt that needs no tools or memory, it's a fallback when your Claude quota is tight: `agy-run.sh --model claude-opus-5-5-medium review "..."`.
