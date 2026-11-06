"""Offline tests for accounts.py: statusline rate_limits shapes, scoring, rendering.

Run: python3 -m unittest discover -s for-claude-code/skills/claude-accounts/tests
No network, no credentials: every test feeds parse_rate_limits/compute directly.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import accounts as A  # noqa: E402

NOW = 1_800_000_000

# Statusline stdin rate_limits shapes. A plan or seat may omit either bucket or
# send nulls (usage-based seats); resets_at arrives as epoch seconds.
def RL(five=None, five_in=None, week=None, week_in=None):
    out = {}
    if five is not None:
        out["five_hour"] = {"used_percentage": five, "resets_at": (NOW + five_in) if five_in is not None else None}
    if week is not None:
        out["seven_day"] = {"used_percentage": week, "resets_at": (NOW + week_in) if week_in is not None else None}
    return out


PRO = RL(12.0, 3 * 3600, 30.0, 4 * 86400)
NO_WINDOW = RL(0.0, None, 0.0, 6 * 86400)
USAGE_BASED = {"five_hour": None, "seven_day": None}
EMPTY = {}


def entry(data, status="ok"):
    return {"status": status, "observed_at": NOW, "buckets": A.parse_rate_limits(data) if data is not None else {}}


def cache(main, alt):
    return {"main": main, "alt": alt}


class Parse(unittest.TestCase):
    def test_pro(self):
        b = A.parse_rate_limits(PRO)
        self.assertEqual(b["5h"]["used"], 12.0)
        self.assertEqual(A.weekly_binding(b, NOW)["used"], 30.0)

    def test_takes_most_used_live_weekly(self):
        raw = {"7d_all": [{"used": 20.0, "resets_at": NOW + 3 * 86400, "bucket": "seven_day"},
                          {"used": 72.0, "resets_at": NOW + 3 * 86400, "bucket": "seven_day_opus"}]}
        b = A.weekly_binding(raw, NOW)
        self.assertEqual(b["used"], 72.0)
        self.assertEqual(b["bucket"], "seven_day_opus")

    def test_nulls_and_missing(self):
        self.assertEqual(A.parse_rate_limits(USAGE_BASED), {})
        self.assertEqual(A.parse_rate_limits(EMPTY), {})
        self.assertEqual(A.parse_rate_limits(None), {})

    def test_epoch_forms(self):
        self.assertEqual(A._epoch(NOW), NOW)
        self.assertEqual(A._epoch(NOW * 1000), NOW)
        self.assertEqual(A._epoch(__import__("datetime").datetime.fromtimestamp(NOW, __import__("datetime").timezone.utc).isoformat()), NOW)
        self.assertIsNone(A._epoch("not a date"))


class Score(unittest.TestCase):
    def st(self, used, secs_left, alt=NO_WINDOW, alt_status="ok"):
        main = RL(used, secs_left, 10.0, 5 * 86400)
        return A.compute(cache(entry(main), entry(alt, alt_status)), now=NOW)

    def test_open_no_switch(self):
        self.assertFalse(self.st(20, 4 * 3600)["use_alt"])

    def test_pace_trigger(self):
        # 50% used with 3h left: H = 0.5 / 0.6 = 0.83 < 1, so switch side work
        self.assertTrue(self.st(50, 3 * 3600)["use_alt"])

    def test_pace_needs_20_percent(self):
        self.assertFalse(self.st(15, int(4.5 * 3600))["use_alt"])

    def test_pace_at_25_percent_early(self):
        # 25% used with 4.5h left: H = 0.75 / 0.9 = 0.83 < 1
        self.assertTrue(self.st(25, int(4.5 * 3600))["use_alt"])

    def test_half_used_always_switches_side_work(self):
        st = self.st(55, 3600)
        self.assertTrue(st["use_alt"])
        self.assertFalse(st["switch"])

    def test_75_percent_suggests_moving_conversation(self):
        self.assertTrue(self.st(80, 2 * 3600)["switch"])

    def test_on_pace_no_switch(self):
        self.assertFalse(self.st(40, 2 * 3600)["use_alt"])

    def test_near_reset_no_switch(self):
        self.assertFalse(self.st(82, 600)["use_alt"])

    def test_nearly_out_switches_even_near_reset(self):
        self.assertTrue(self.st(95, 600)["use_alt"])

    def test_alt_signed_out_never(self):
        self.assertFalse(self.st(95, 600, alt=None, alt_status="signed_out")["use_alt"])

    def test_idle_without_observation_is_unknown(self):
        st = self.st(82, 3600, alt=None, alt_status="idle")
        self.assertEqual(st["alt"]["state"], "UNKNOWN")
        self.assertFalse(st["use_alt"])

    def test_idle_keeps_last_observation(self):
        hot = RL(99.0, 3600)
        st = A.compute(cache(entry(PRO), entry(hot, "idle")), now=NOW)
        self.assertEqual(st["alt"]["state"], "CLOSED")

    def test_idle_with_passed_reset_counts_as_reset(self):
        old = RL(99.0, -60, 5.0, 86400)
        st = A.compute(cache(entry(PRO), entry(old, "idle")), now=NOW)
        self.assertEqual(st["alt"]["state"], "OPEN")

    def test_cache_for_other_dir_is_ignored(self):
        e = entry(PRO); e["dir"] = "/somewhere/else"
        st = A.compute(cache(entry(PRO), e), now=NOW)
        self.assertIn(st["alt"]["state"], ("UNKNOWN", "SIGNED_OUT"))
        self.assertFalse(st["use_alt"])

    def test_usage_based_main_is_unknown_not_crash(self):
        st = A.compute(cache(entry(USAGE_BASED), entry(PRO)), now=NOW)
        self.assertEqual(st["main"]["state"], "UNKNOWN")
        self.assertFalse(st["use_alt"])


class Weekly(unittest.TestCase):
    def test_expired_per_model_bucket_does_not_hide_live_weekly(self):
        e = {"status": "ok", "observed_at": NOW, "buckets": {"7d_all": [
            {"used": 80.0, "resets_at": NOW + 2 * 86400, "bucket": "seven_day"},
            {"used": 90.0, "resets_at": NOW - 60, "bucket": "seven_day_opus"}]}}
        st = A.compute(cache(e, entry(NO_WINDOW)), now=NOW)
        self.assertEqual(st["main"]["buckets"]["7d"]["used"], 80.0)


class Render(unittest.TestCase):
    def test_null_weekly_reset_at_75_does_not_crash(self):
        b = A.bucket("7d", {"used": 75, "resets_at": None}, NOW)
        self.assertEqual(A.fmt(b, False), "7d 🟡75%")

    def test_fmt_hides_dot_and_weekly_reset_below_70(self):
        b = A.bucket("7d", {"used": 30, "resets_at": NOW + 86400}, NOW)
        self.assertEqual(A.fmt(b, False), "7d 30%")

    def test_fmt_weekly_reset_at_70(self):
        b = A.bucket("7d", {"used": 74, "resets_at": NOW + 2 * 86400}, NOW)
        self.assertRegex(A.fmt(b, False), r"^7d 🟡74% \(\w{3} \d{1,2}(:\d\d)?(am|pm)\)$")

    def test_fmt_5h_countdown(self):
        b = A.bucket("5h", {"used": 91, "resets_at": NOW + 1500}, NOW)
        self.assertEqual(A.fmt(b, True), "5h 🔴91% (25m)")

    def test_no_window_has_no_countdown(self):
        b = A.bucket("5h", {"used": 0, "resets_at": None}, NOW)
        self.assertEqual(A.fmt(b, True), "5h 0%")





class Record(unittest.TestCase):
    def test_stale_observation_reads_idle_but_keeps_numbers(self):
        e = entry(RL(99.0, 3600)); e["observed_at"] = NOW - A.STALE - 1
        st = A.compute(cache(entry(PRO), e), now=NOW)
        self.assertEqual(st["alt"]["status"], "idle")
        self.assertEqual(st["alt"]["state"], "CLOSED")

    def test_record_writes_only_its_own_login(self):
        import tempfile, json
        with tempfile.TemporaryDirectory() as d:
            A.CACHE = os.path.join(d, "c.json")
            json.dump({"alt": {"status": "ok", "observed_at": 1, "buckets": {}}}, open(A.CACHE, "w"))
            A.record("main", PRO, now=NOW)
            c = json.load(open(A.CACHE))
            self.assertEqual(c["main"]["buckets"]["5h"]["used"], 12.0)
            self.assertEqual(c["alt"]["observed_at"], 1)

    def test_record_ignores_empty_rate_limits(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            A.CACHE = os.path.join(d, "c.json")
            A.record("main", {}, now=NOW)
            self.assertFalse(os.path.exists(A.CACHE))


if __name__ == "__main__":
    unittest.main()
