#!/usr/bin/env python3
"""Seed and sync a second login's .claude.json from the main one.

~/.claude.json holds two kinds of data: shared configuration (MCP servers,
per-project MCP toggles and trust) and account state (oauthAccount, org caches,
usage caches). The second config dir needs the first and must never get the
second, so this copies an explicit allowlist only.

Runs on every launch of the second login. Idempotent: it writes only when
something changed, atomically, mode 0600, under the same lock directory
Claude Code uses (<file>.lock, stale after 10 s).

  sync_config.py <alt config dir> [--quiet]
"""
import json
import os
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
_main = os.environ.get("CLAUDE_MAIN_DIR")
MAIN_DIR = os.path.abspath(os.path.expanduser(_main)) if _main else os.path.join(HOME, ".claude")
# Default config dir keeps .claude.json in $HOME; a custom CLAUDE_CONFIG_DIR keeps it inside the dir.
SRC = (os.path.join(MAIN_DIR, ".claude.json")
       if MAIN_DIR != os.path.join(HOME, ".claude")
       else os.path.join(HOME, ".claude.json"))
_args = [a for a in sys.argv[1:] if not a.startswith("--")]
DST_DIR = os.path.abspath(os.path.expanduser(_args[0])) if _args else os.path.join(HOME, ".claude-personal")
DST = os.path.join(DST_DIR, ".claude.json")

# Copied once, when the second login's file is first created: UI and onboarding
# flags, so the second login doesn't start with first-run prompts.
SEED_KEYS = [
    "hasCompletedOnboarding", "lastOnboardingVersion", "theme", "autoUpdates",
    "autoUpdatesProtectedForNative", "installMethod", "optionAsMetaKeyInstalled",
    "hasCompletedClaudeInChromeOnboarding", "claudeInChromeDefaultEnabled",
    "teammateMode", "workflowSizeGuideline", "showSpinnerTree", "diffSidebarOpen",
    "autoConnectIde", "hasSeenAutoModeEntryWarning",
    "hasResetAutoModeOptInForDefaultOffer", "effortCalloutDismissed",
    "effortCalloutV2Dismissed", "hasSeenTasksHint", "lastReleaseNotesSeen",
]
# Kept in sync on every launch.
TOP_SYNC_KEYS = ["mcpServers"]
PROJECT_SYNC_KEYS = [
    "allowedTools", "mcpServers", "disabledMcpServers", "enabledMcpjsonServers",
    "disabledMcpjsonServers", "hasTrustDialogAccepted",
    "hasClaudeMdExternalIncludesApproved", "hasClaudeMdExternalIncludesWarningShown",
]
# One-way approvals: copied when the main login has them, never removed, so a
# folder trusted only on the second login stays trusted.
NO_DELETE = {"hasTrustDialogAccepted", "hasClaudeMdExternalIncludesApproved",
             "hasClaudeMdExternalIncludesWarningShown"}


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def main():
    quiet = "--quiet" in sys.argv
    src = load(SRC)
    if src is None:
        print(f"sync_config: {SRC} not found", file=sys.stderr)
        return 1
    if not os.path.isdir(DST_DIR):
        print(f"sync_config: {DST_DIR} missing; run setup.sh first", file=sys.stderr)
        return 1
    # Claude Code guards the file with a proper-lockfile directory; take the
    # same lock (treated as stale after 10 s). Best effort: a second login's
    # session that writes without the lock between our read and replace would
    # lose that write, which is why this runs before launch, not during.
    lock = DST + ".lock"
    deadline = time.time() + 3
    while True:
        try:
            os.mkdir(lock)
            break
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(lock) > 10:
                    os.rmdir(lock)
                    continue
            except OSError:
                pass
            if time.time() > deadline:
                if not quiet:
                    print("sync_config: second login's .claude.json busy; skipped this time")
                return 0
            time.sleep(0.1)
    try:
        return sync(src, quiet)
    finally:
        try:
            os.rmdir(lock)
        except OSError:
            pass


def sync(src, quiet):
    dst = load(DST)
    seeded = dst is None
    dst = dst or {}
    changes = []

    if seeded:
        for k in SEED_KEYS:
            if k in src:
                dst[k] = src[k]
        changes.append("seeded")

    for k in TOP_SYNC_KEYS:
        if k in src and dst.get(k) != src[k]:
            dst[k] = src[k]
            changes.append(k)
        elif k not in src and k in dst:
            del dst[k]
            changes.append(f"-{k}")

    proj_changed = 0
    dproj = dst.setdefault("projects", {})
    for path, cfg in (src.get("projects") or {}).items():
        d = dproj.setdefault(path, {})
        for k in PROJECT_SYNC_KEYS:
            if k in cfg and d.get(k) != cfg[k]:
                d[k] = cfg[k]
                proj_changed += 1
            elif k not in cfg and k in d and k not in NO_DELETE:
                del d[k]
                proj_changed += 1
    if proj_changed:
        changes.append(f"{proj_changed} project settings")

    if changes:
        fd, tmp = tempfile.mkstemp(dir=DST_DIR, prefix=".claude.json.")
        with os.fdopen(fd, "w") as f:
            json.dump(dst, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, DST)
    if not quiet:
        print("sync_config: " + (", ".join(changes) if changes else "already in sync"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
