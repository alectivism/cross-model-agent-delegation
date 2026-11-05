"""Offline tests for accounts.py: endpoint shapes across plans, scoring, rendering.

Run: python3 -m unittest discover -s for-claude-code/skills/claude-accounts/tests
No network, no Keychain: every test feeds parse_usage/compute directly.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import accounts as A  # noqa: E402

NOW = 1_800_000_000
ISO = lambda secs: __import__("datetime").datetime.fromtimestamp(NOW + secs, __import__("datetime").timezone.utc).isoformat()

# Response shapes. Pro/Team: five_hour + seven_day. Max-style plans add
# per-model weekly buckets. Usage-based seats can return nulls throughout.
PRO = {"five_hour": {"utilization": 12.0, "resets_at": ISO(3 * 3600)},
       "seven_day": {"utilization": 30.0, "resets_at": ISO(4 * 86400)}}
MAX_PER_MODEL = {"five_hour": {"utilization": 5.0, "resets_at": ISO(4 * 3600)},
                 "seven_day": {"utilization": 20.0, "resets_at": ISO(3 * 86400)},
                 "seven_day_opus": {"utilization": 72.0, "resets_at": ISO(3 * 86400)},
                 "seven_day_sonnet": None}
NO_WINDOW = {"five_hour": {"utilization": 0.0, "resets_at": None},
             "seven_day": {"utilization": 0.0, "resets_at": ISO(6 * 86400)}}
USAGE_BASED = {"five_hour": None, "seven_day": None, "extra_usage": {"is_enabled": True}}
EMPTY = {}


def entry(data, status="ok"):
    return {"status": status, "buckets": A.parse_usage(data) if data is not None else {}}


def cache(main, alt):
    return {"main": main, "alt": alt}


class Parse(unittest.TestCase):
    def test_pro(self):
        b = A.parse_usage(PRO)
        self.assertEqual(b["5h"]["used"], 12.0)
        self.assertEqual(A.weekly_binding(b, NOW)["used"], 30.0)

    def test_max_takes_most_used_weekly(self):
        b = A.weekly_binding(A.parse_usage(MAX_PER_MODEL), NOW)
        self.assertEqual(b["used"], 72.0)
        self.assertEqual(b["bucket"], "seven_day_opus")

    def test_nulls_and_missing(self):
        self.assertEqual(A.parse_usage(USAGE_BASED), {})
        self.assertEqual(A.parse_usage(EMPTY), {})
        self.assertEqual(A.parse_usage(None), {})

    def test_epoch_forms(self):
        self.assertEqual(A._epoch(NOW), NOW)
        self.assertEqual(A._epoch(NOW * 1000), NOW)
        self.assertEqual(A._epoch(ISO(0)), NOW)
        self.assertIsNone(A._epoch("not a date"))


class Score(unittest.TestCase):
    def st(self, used, secs_left, alt=NO_WINDOW, alt_status="ok"):
        main = {"five_hour": {"utilization": used, "resets_at": ISO(secs_left)},
                "seven_day": {"utilization": 10.0, "resets_at": ISO(5 * 86400)}}
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
        hot = {"five_hour": {"utilization": 99.0, "resets_at": ISO(3600)}}
        st = A.compute(cache(entry(PRO), entry(hot, "idle")), now=NOW)
        self.assertEqual(st["alt"]["state"], "CLOSED")

    def test_idle_with_passed_reset_counts_as_reset(self):
        old = {"five_hour": {"utilization": 99.0, "resets_at": ISO(-60)},
               "seven_day": {"utilization": 5.0, "resets_at": ISO(86400)}}
        st = A.compute(cache(entry(PRO), entry(old, "idle")), now=NOW)
        self.assertEqual(st["alt"]["state"], "OPEN")

    def test_cache_for_other_dir_is_ignored(self):
        e = entry(PRO); e["dir"] = "/somewhere/else"
        st = A.compute(cache(entry(PRO), e), now=NOW)
        self.assertEqual(st["alt"]["state"], "SIGNED_OUT")

    def test_usage_based_main_is_unknown_not_crash(self):
        st = A.compute(cache(entry(USAGE_BASED), entry(PRO)), now=NOW)
        self.assertEqual(st["main"]["state"], "UNKNOWN")
        self.assertFalse(st["use_alt"])


class Weekly(unittest.TestCase):
    def test_expired_per_model_bucket_does_not_hide_live_weekly(self):
        data = {"seven_day": {"utilization": 80.0, "resets_at": ISO(2 * 86400)},
                "seven_day_opus": {"utilization": 90.0, "resets_at": ISO(-60)}}
        st = A.compute(cache(entry(data), entry(NO_WINDOW)), now=NOW)
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


if __name__ == "__main__":
    unittest.main()
