#!/usr/bin/env python3
"""Usage for two Claude Code logins (main + alt): probe, status line, statusline segment.

Subcommands
  refresh            read both logins' usage now and write the cache
  line               one-line status for a UserPromptSubmit hook (refreshes in the
                     background when the cache is older than CLAUDE_ACCOUNTS_TTL)
  segment            compact text for a statusline; pipe the statusline's stdin
                     JSON in so the session's own rate_limits act as a fallback
  json               full computed state

Accounts
  main  the default config dir (~/.claude, or CLAUDE_MAIN_DIR)
  alt   CLAUDE_ALT_DIR, default ~/.claude-<CLAUDE_ALT_NAME>, i.e. ~/.claude-personal
  Labels: CLAUDE_MAIN_LABEL (default "main"), CLAUDE_ALT_LABEL (default: the alt
  dir name without ".claude-", e.g. "personal").

Where the numbers come from
  The OAuth usage endpoint behind /usage (GET /api/oauth/usage). It is not a
  documented API: fields can change, and every parse below tolerates a missing
  or null bucket so the statusline degrades to fewer segments instead of
  breaking. Live-tested on one Team and one Max login (macOS, Claude Code
  2.1.318); other plans are covered by offline response-shape tests only.
  API-key (Console) logins have no OAuth token and show as signed out.

Credentials
  macOS: the login Keychain item Claude Code writes, named
  "Claude Code-credentials" for the default dir and
  "Claude Code-credentials-<sha256(config dir)[:8]>" for any other
  CLAUDE_CONFIG_DIR (observed in Claude Code 2.1.318).
  Linux/Windows: <config dir>/.credentials.json.
  The token is sent only to api.anthropic.com and never printed or stored. It
  is NEVER refreshed here: a refresh rotates the stored refresh token and signs
  Claude Code out. An expired access token is reported "idle": the last
  observed numbers are kept, a window whose reset time has passed counts as
  reset, and with no observation the login is UNKNOWN (never chosen).
"""
import datetime as _dt
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.request

HOME = os.path.expanduser("~")
DEFAULT_DIR = os.path.join(HOME, ".claude")
MAIN_DIR = os.environ.get("CLAUDE_MAIN_DIR", DEFAULT_DIR)
ALT_DIR = os.environ.get("CLAUDE_ALT_DIR") or os.path.join(HOME, ".claude-" + os.environ.get("CLAUDE_ALT_NAME", "personal"))
MAIN_LABEL = os.environ.get("CLAUDE_MAIN_LABEL", "main")
ALT_LABEL = os.environ.get("CLAUDE_ALT_LABEL") or (
    os.path.basename(ALT_DIR.rstrip("/")).replace(".claude-", "", 1).lstrip(".") or "alt")
CACHE = os.environ.get("CLAUDE_ACCOUNTS_CACHE", os.path.join(DEFAULT_DIR, "claude-accounts-usage.json"))
TTL = int(os.environ.get("CLAUDE_ACCOUNTS_TTL", "180"))
URL = "https://api.anthropic.com/api/oauth/usage"

WIN = {"5h": 5 * 3600, "7d": 7 * 86400}
CAP, FLOOR = 3.0, 0.02
CLOSED_PCT, TIGHT_PCT, TIGHT_H = 10, 25, 0.7
HYSTERESIS = 1.25
PACE_MIN_USED, NEAR_RESET_S = 40, 900


# ---------------------------------------------------------------- credentials

def _norm(d):
    return unicodedata.normalize("NFC", os.path.abspath(os.path.expanduser(d)))


def _is_default(d):
    return _norm(d) == _norm(DEFAULT_DIR)


def keychain_service(config_dir):
    if _is_default(config_dir):
        return "Claude Code-credentials"
    return "Claude Code-credentials-" + hashlib.sha256(_norm(config_dir).encode()).hexdigest()[:8]


def read_creds(config_dir):
    """Return the claudeAiOauth dict, or None. Never logs the token."""
    raw = None
    if sys.platform == "darwin":
        r = subprocess.run(["security", "find-generic-password", "-s", keychain_service(config_dir),
                            "-a", os.environ.get("USER", ""), "-w"], capture_output=True, text=True)
        if r.returncode == 0:
            raw = r.stdout
    if raw is None:
        try:
            with open(os.path.join(config_dir, ".credentials.json")) as f:
                raw = f.read()
        except OSError:
            return None
    try:
        return json.loads(raw).get("claudeAiOauth")
    except Exception:
        return None


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


def parse_usage(data):
    """Endpoint JSON -> {"5h": {...}, "7d": {...}} with whatever is present.

    Weekly buckets (seven_day and any per-model seven_day_*) are all kept under
    "7d_all"; scoring picks the most-used one that hasn't reset yet, since on
    plans with per-model weekly caps that is the one that binds."""
    out = {}
    fh = data.get("five_hour") if isinstance(data, dict) else None
    if isinstance(fh, dict) and fh.get("utilization") is not None:
        out["5h"] = {"used": float(fh["utilization"]), "resets_at": _epoch(fh.get("resets_at"))}
    weekly = []
    for k, v in (data.items() if isinstance(data, dict) else []):
        if k.startswith("seven_day") and isinstance(v, dict) and v.get("utilization") is not None:
            weekly.append({"used": float(v["utilization"]), "resets_at": _epoch(v.get("resets_at")), "bucket": k})
    if weekly:
        out["7d_all"] = weekly
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


def probe(config_dir, now):
    creds = read_creds(config_dir)
    if not creds or not creds.get("accessToken"):
        return {"status": "signed_out", "observed_at": now}
    base = {"observed_at": now, "plan": creds.get("subscriptionType")}
    if (creds.get("expiresAt") or 0) / 1000 <= now + 30:
        return {**base, "status": "idle"}
    req = urllib.request.Request(URL, headers={
        "Authorization": "Bearer " + creds["accessToken"],
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-accounts-usage",
    })
    try:
        data = json.loads(urllib.request.urlopen(req, timeout=10).read())
    except Exception as e:
        return {**base, "status": "error", "error": f"{type(e).__name__}"}
    return {**base, "status": "ok", "buckets": parse_usage(data), "last_ok_at": now}


# ---------------------------------------------------------------- cache

def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except Exception:
        return {}


def refresh():
    now = int(time.time())
    cache = load_cache()
    for key, d in (("main", MAIN_DIR), ("alt", ALT_DIR)):
        if key == "alt" and not os.path.isdir(ALT_DIR):
            cache[key] = {"status": "unconfigured", "observed_at": now}
            continue
        res = probe(d, now)
        res["dir"] = _norm(d)
        prev = cache.get(key) or {}
        if prev.get("dir") != res["dir"]:   # a different account was configured
            prev = {}
        if res["status"] != "ok":   # keep the last good numbers
            for k in ("buckets", "last_ok_at"):
                if k in prev:
                    res[k] = prev[k]
        cache[key] = res
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(CACHE), prefix=".claude-accounts.")
    with os.fdopen(fd, "w") as f:
        json.dump(cache, f, indent=2)
    os.replace(tmp, CACHE)
    return cache


def refresh_in_background():
    try:
        age = time.time() - os.path.getmtime(CACHE)
    except OSError:
        age = 1e9
    if age <= TTL:
        return
    lock = os.path.join(tempfile.gettempdir(), ".claude-accounts.lock")
    try:
        os.mkdir(lock)
    except FileExistsError:
        try:
            if time.time() - os.path.getmtime(lock) > 60:
                os.rmdir(lock)
        except OSError:
            pass
        return
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "_refresh_locked", lock],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


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
    raw = entry.get("buckets") or {}
    # Idle (token expired) keeps the last observation: a window whose reset has
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
    main = account_state(cache.get("main"), now)
    alt = account_state(cache.get("alt"), now)
    # Leave out a main 5h window that resets within NEAR_RESET_S with 10%+ left:
    # finishing on main is cheaper than a hand-off for a few minutes.
    route = [b for b in main["buckets"].values()
             if b and not (b["name"] == "5h" and b.get("left_s") is not None
                           and b["left_s"] <= NEAR_RESET_S and b["remaining"] >= CLOSED_PCT)]
    H_r, st_r = score(route)
    m5 = next((b for b in route if b["name"] == "5h"), None)
    pace = bool(m5 and m5["used"] >= PACE_MIN_USED and m5["H"] < 1.0)
    if st_r in ("TIGHT", "CLOSED"):
        use_alt = alt["state"] == "OPEN" or (alt["state"] == "TIGHT" and (alt["H"] or 0) >= (H_r or 0) * HYSTERESIS)
    else:
        use_alt = pace and alt["state"] == "OPEN"
    return {"ts": now, "main": main, "alt": alt, "use_alt": use_alt,
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
    st = compute()
    me, other = ("alt", "main") if this_is_alt else ("main", "alt")
    a = st[me]
    # Fallback for the session's own account: statusline stdin rate_limits.
    if not any(a["buckets"].values()) and stdin_json:
        rl = (stdin_json or {}).get("rate_limits") or {}
        now = st["ts"]
        a = {"buckets": {
            "5h": bucket("5h", {"used": (rl.get("five_hour") or {}).get("used_percentage"),
                                "resets_at": (rl.get("five_hour") or {}).get("resets_at")}, now),
            "7d": bucket("7d", {"used": (rl.get("seven_day") or {}).get("used_percentage"),
                                "resets_at": (rl.get("seven_day") or {}).get("resets_at")}, now)}}
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
        segs.append(f"{st['labels'][key]} {' '.join(bits)}{h} {a['state']}")
    out = "ACCOUNTS " + " | ".join(segs)
    if st["use_alt"]:
        out += f" | use={st['labels']['alt']}"
    return out


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "line"
    if cmd == "_refresh_locked":
        try:
            refresh()
        finally:
            try:
                os.rmdir(argv[2])
            except OSError:
                pass
        return 0
    if cmd == "refresh":
        refresh()
        print(line())
    elif cmd == "line":
        refresh_in_background()
        print(line())
    elif cmd == "segment":
        refresh_in_background()
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
