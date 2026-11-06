#!/usr/bin/env python3
"""Usage for two Claude Code logins (main + alt): statusline segment and status line.

Subcommands
  segment            record this session's usage from the statusline's stdin JSON,
                     then print compact text for the statusline. Wire it into the
                     statusline of both logins; it is the only data source.
  line               one-line status for a UserPromptSubmit hook, from the cache
  json               full computed state

Accounts
  main  the default config dir (~/.claude, or CLAUDE_MAIN_DIR)
  alt   CLAUDE_ALT_DIR, default ~/.claude-<CLAUDE_ALT_NAME>, i.e. ~/.claude-personal
  Labels: CLAUDE_MAIN_LABEL (default "main"), CLAUDE_ALT_LABEL (default: the alt
  dir name without ".claude-", e.g. "personal").

Where the numbers come from
  Only the `rate_limits` object Claude Code passes to the statusline on stdin
  (five_hour and seven_day, each with used_percentage and resets_at). Each
  render records its own login's numbers in the cache; the other login's
  numbers are whatever its own statusline last recorded. This script reads no
  credentials and makes no network calls.

Staleness
  A login with no render for CLAUDE_ACCOUNTS_STALE seconds (default 900) is
  "idle": its last observation is kept, a window whose reset time has passed
  counts as reset, and with no observation at all the login is UNKNOWN (never
  chosen).
"""
import datetime as _dt
import json
import os
import sys
import tempfile
import time
import unicodedata

HOME = os.path.expanduser("~")
DEFAULT_DIR = os.path.join(HOME, ".claude")
MAIN_DIR = os.environ.get("CLAUDE_MAIN_DIR", DEFAULT_DIR)
ALT_DIR = os.environ.get("CLAUDE_ALT_DIR") or os.path.join(HOME, ".claude-" + os.environ.get("CLAUDE_ALT_NAME", "personal"))
MAIN_LABEL = os.environ.get("CLAUDE_MAIN_LABEL", "main")
ALT_LABEL = os.environ.get("CLAUDE_ALT_LABEL") or (
    os.path.basename(ALT_DIR.rstrip("/")).replace(".claude-", "", 1).lstrip(".") or "alt")
CACHE = os.environ.get("CLAUDE_ACCOUNTS_CACHE", os.path.join(DEFAULT_DIR, "claude-accounts-usage.json"))
STALE = int(os.environ.get("CLAUDE_ACCOUNTS_STALE", "900"))

WIN = {"5h": 5 * 3600, "7d": 7 * 86400}
CAP, FLOOR = 3.0, 0.02
CLOSED_PCT, TIGHT_PCT, TIGHT_H = 10, 25, 0.7
HYSTERESIS = 1.25
# Main 5h thresholds: hand side work to the second login from 20% used when on
# pace to run out (H < 1), from 50% at any pace; at 75% suggest moving the
# conversation itself, which side-work delegation never does.
PACE_MIN_USED, ALWAYS_USED, SWITCH_USED, NEAR_RESET_S = 20, 50, 75, 900


# ---------------------------------------------------------------- paths

def _norm(d):
    return unicodedata.normalize("NFC", os.path.abspath(os.path.expanduser(d)))


def _is_default(d):
    return _norm(d) == _norm(DEFAULT_DIR)


# ---------------------------------------------------------------- parsing

def _epoch(v):
    if v in (None, ""):
        return None
    if isinstance(v, (int, float)):
        return int(v / 1000) if v > 1e12 else int(v)
    try:
        return int(_dt.datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def parse_rate_limits(rl):
    """Statusline stdin rate_limits -> {"5h": {...}, "7d_all": [...]} with whatever is present."""
    out = {}
    rl = rl if isinstance(rl, dict) else {}
    fh = rl.get("five_hour")
    if isinstance(fh, dict) and fh.get("used_percentage") is not None:
        out["5h"] = {"used": float(fh["used_percentage"]), "resets_at": _epoch(fh.get("resets_at"))}
    sd = rl.get("seven_day")
    if isinstance(sd, dict) and sd.get("used_percentage") is not None:
        out["7d_all"] = [{"used": float(sd["used_percentage"]), "resets_at": _epoch(sd.get("resets_at")),
                          "bucket": "seven_day"}]
    return out


def weekly_binding(raw, now):
    """Most-used weekly bucket whose window hasn't passed (a passed one reads 0)."""
    cands = raw.get("7d_all") or ([raw["7d"]] if raw.get("7d") else [])
    best = None
    for c in cands:
        live = dict(c)
        if c.get("resets_at") and c["resets_at"] <= now:
            live["used"] = 0.0
        if best is None or live["used"] > best["used"]:
            best = live
    return best


# ---------------------------------------------------------------- cache

def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except Exception:
        return {}


def record(key, rate_limits, now=None):
    """Store this login's numbers from its own statusline. Never touches the other key."""
    buckets = parse_rate_limits(rate_limits)
    if not buckets:
        return
    now = now or int(time.time())
    d = MAIN_DIR if key == "main" else ALT_DIR
    lock = os.path.join(tempfile.gettempdir(), ".claude-accounts.lock")
    try:
        os.mkdir(lock)
    except FileExistsError:
        return  # another render is writing; the next render records
    try:
        cache = load_cache()
        cache[key] = {"status": "ok", "observed_at": now, "dir": _norm(d), "buckets": buckets}
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CACHE), prefix=".claude-accounts.")
        with os.fdopen(fd, "w") as f:
            json.dump(cache, f, indent=2)
        os.replace(tmp, CACHE)
    finally:
        os.rmdir(lock)


# ---------------------------------------------------------------- scoring

def bucket(name, b, now):
    if not b or b.get("used") is None:
        return None
    used = round(float(b["used"]), 1)
    resets = b.get("resets_at")
    if name == "5h" and not resets:      # no open window: nothing used yet
        return {"name": name, "used": used, "remaining": 100 - used, "H": CAP, "left_s": None}
    if resets and resets <= now:
        return {"name": name, "used": 0.0, "remaining": 100.0, "H": CAP, "left_s": None, "lapsed": True}
    left = (resets - now) if resets else None
    f = max((left if left is not None else WIN[name]) / WIN[name], FLOOR)
    r = 100 - used
    return {"name": name, "used": used, "remaining": r, "H": min((r / 100) / f, CAP),
            "left_s": left, "resets_at": resets}


def score(bs):
    live = [b for b in bs if b]
    if not live:
        return None, "UNKNOWN"
    H = min(b["H"] for b in live)
    worst = min(b["remaining"] for b in live)
    if worst < CLOSED_PCT:
        return H, "CLOSED"
    if worst < TIGHT_PCT or H < TIGHT_H:
        return H, "TIGHT"
    return H, "OPEN"


def account_state(entry, now):
    entry = entry or {}
    status = entry.get("status", "unconfigured")
    if status == "ok" and entry.get("observed_at") and now - entry["observed_at"] > STALE:
        status = "idle"
    raw = entry.get("buckets") or {}
    # Idle (no render for STALE seconds) keeps the last observation: a window whose reset has
    # passed counts as reset; with no observation at all the state is UNKNOWN.
    bs = {"5h": bucket("5h", raw.get("5h"), now), "7d": bucket("7d", weekly_binding(raw, now), now)}
    if status == "idle":
        for b in bs.values():
            if b:
                b["idle"] = True
    H, st = score(bs.values())
    if status in ("signed_out", "unconfigured"):
        st = "SIGNED_OUT"
    return {"status": status, "buckets": bs, "H": H, "state": st}


def compute(cache=None, now=None):
    now = now or int(time.time())
    cache = load_cache() if cache is None else cache
    for key, d in (("main", MAIN_DIR), ("alt", ALT_DIR)):
        e = cache.get(key)
        if isinstance(e, dict) and e.get("dir") and e["dir"] != _norm(d):
            cache = {**cache, key: None}
    main = account_state(cache.get("main") or {"status": "unknown"}, now)
    alt_entry = cache.get("alt") or {"status": "unknown" if os.path.isdir(ALT_DIR) else "unconfigured"}
    alt = account_state(alt_entry, now)
    # Leave out a main 5h window that resets within NEAR_RESET_S with 10%+ left:
    # finishing on main is cheaper than a hand-off for a few minutes.
    route = [b for b in main["buckets"].values()
             if b and not (b["name"] == "5h" and b.get("left_s") is not None
                           and b["left_s"] <= NEAR_RESET_S and b["remaining"] >= CLOSED_PCT)]
    H_r, st_r = score(route)
    m5 = next((b for b in route if b["name"] == "5h"), None)
    pace = bool(m5 and ((m5["used"] >= PACE_MIN_USED and m5["H"] < 1.0) or m5["used"] >= ALWAYS_USED))
    if st_r in ("TIGHT", "CLOSED"):
        use_alt = alt["state"] == "OPEN" or (alt["state"] == "TIGHT" and (alt["H"] or 0) >= (H_r or 0) * HYSTERESIS)
    else:
        use_alt = pace and alt["state"] == "OPEN"
    switch = bool(use_alt and (st_r == "CLOSED" or (m5 and m5["used"] >= SWITCH_USED)))
    return {"ts": now, "main": main, "alt": alt, "use_alt": use_alt, "switch": switch,
            "labels": {"main": MAIN_LABEL, "alt": ALT_LABEL}}


# ---------------------------------------------------------------- rendering

def countdown(secs):
    if secs is None:
        return ""
    if secs >= 86400:
        return f"{secs // 86400}d{(secs % 86400) // 3600}h"
    if secs >= 3600:
        return f"{secs // 3600}h{(secs % 3600) // 60:02d}m"
    return f"{secs // 60}m"


def clock(epoch):
    t = _dt.datetime.fromtimestamp(epoch + 30)  # resets land at :59:59
    h = t.strftime("%I").lstrip("0")
    ap = t.strftime("%p").lower()
    return f"{t.strftime('%a')} {h}{ap}" if t.minute == 0 else f"{t.strftime('%a')} {h}:{t.strftime('%M')}{ap}"


def fmt(b, always_reset):
    if not b:
        return ""
    u = round(b["used"])
    dot = "🔴" if u >= 90 else ("🟡" if u >= 70 else "")
    s = f"{b['name']} {dot}{u}%"
    if (always_reset or u >= 70) and b.get("left_s") and b.get("resets_at") and not b.get("lapsed"):
        s += f" ({countdown(b['left_s']) if b['name'] == '5h' else clock(b['resets_at'])})"
    return s


def segment(this_is_alt, stdin_json=None):
    me, other = ("alt", "main") if this_is_alt else ("main", "alt")
    if isinstance(stdin_json, dict):
        record(me, stdin_json.get("rate_limits"))
    st = compute()
    a = st[me]
    parts = []
    mine = " ".join(x for x in (fmt(a["buckets"].get("5h"), True), fmt(a["buckets"].get("7d"), False)) if x)
    if mine:
        parts.append(f"{st['labels'][me]} {mine}")
    o = st[other]
    if o["state"] != "SIGNED_OUT":
        theirs = " ".join(x for x in (fmt(o["buckets"].get("5h"), False), fmt(o["buckets"].get("7d"), False)) if x)
        parts.append(f"{st['labels'][other]} {theirs or 'idle'}")
    return " | ".join(parts)


def line():
    st = compute()
    segs = []
    for key in ("main", "alt"):
        a = st[key]
        if a["state"] == "SIGNED_OUT":
            if key == "alt" and a["status"] == "unconfigured":
                continue
            segs.append(f"{st['labels'][key]} SIGNED_OUT")
            continue
        bits = []
        for n in ("5h", "7d"):
            b = a["buckets"].get(n)
            if b:
                bits.append(f"{n} {b['used']:g}%" + (f"/{countdown(b['left_s'])}" if b.get("left_s") else ""))
        if a["status"] == "idle":
            bits.append("idle")
        h = f" H={a['H']:.2f}" if a["H"] is not None else ""
        segs.append(" ".join(x for x in (st['labels'][key], " ".join(bits), h.strip(), a['state']) if x))
    out = "ACCOUNTS " + " | ".join(segs)
    if st["use_alt"]:
        out += f" | use={st['labels']['alt']}"
    if st.get("switch"):
        out += f" | switch={st['labels']['alt']}"
    return out


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "line"
    if cmd == "line":
        print(line())
    elif cmd == "segment":
        stdin_json = None
        if not sys.stdin.isatty():
            try:
                stdin_json = json.loads(sys.stdin.read() or "null")
            except Exception:
                stdin_json = None
        cfg = os.environ.get("CLAUDE_CONFIG_DIR")
        this_is_alt = bool(cfg) and _norm(cfg) == _norm(ALT_DIR)
        print(segment(this_is_alt, stdin_json))
    elif cmd == "json":
        print(json.dumps(compute(), indent=2, default=str))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
