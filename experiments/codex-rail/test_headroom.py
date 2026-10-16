import copy
import unittest
from headroom import Headroom, ReportError, Verdict


class HeadroomTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000
        self.room = Headroom(lambda: self.now)
        self.report = dict(observed_at=990, source="poll", limited=False, windows=[
            dict(used_percent=20, resets_at=2000, window_minutes=300),
            dict(used_percent=64, resets_at=9000, window_minutes=10080)])

    def test_normalization_and_admission(self):
        self.assertEqual(self.room.verdict(), Verdict.UNKNOWN)
        snapshot = self.room.observe(self.report)
        self.assertEqual(snapshot.windows[1].used, 0.64)
        self.assertEqual(self.room.verdict(), Verdict.ADMIT)
        self.report['windows'][0]['used_percent'] = 100
        self.assertEqual(self.room.verdict(), Verdict.ADMIT)

    def test_both_windows_and_explicit_limit_gate(self):
        for window in (0, 1):
            report = copy.deepcopy(self.report)
            report['windows'][window]['used_percent'] = 95
            room = Headroom(lambda: self.now)
            room.observe(report)
            self.assertEqual(room.verdict(), Verdict.LIMITED)
        self.report['limited'] = True
        self.room.observe(self.report)
        self.assertEqual(self.room.verdict(), Verdict.LIMITED)

    def test_stale_future_and_out_of_order_cannot_overwrite(self):
        self.room.observe(self.report)
        for at in (800, 880, 989, 990, 1001, True, float('nan'), float('inf')):
            report = dict(self.report, observed_at=at, limited=True)
            with self.subTest(at=at), self.assertRaises(ReportError):
                self.room.observe(report)
            self.assertEqual(self.room.verdict(), Verdict.ADMIT)
        self.room.observe(dict(self.report, observed_at=999, source="jail", limited=True))
        self.assertEqual(self.room.verdict(), Verdict.LIMITED)

    def test_age_boundary_reset_and_clock_rollback_require_new_observation(self):
        self.room.observe(self.report)
        self.now = 1110
        self.assertEqual(self.room.verdict(), Verdict.STALE)
        self.now = 980
        self.assertEqual(self.room.verdict(), Verdict.STALE)
        self.now = 1000
        self.report['windows'][0]['resets_at'] = 1010
        self.room.observe(dict(self.report, observed_at=999))
        self.now = 1010
        self.assertEqual(self.room.verdict(), Verdict.STALE)

    def test_malformed_windows_and_nonfinite_values(self):
        invalid = [None, {}, dict(self.report, limited=0), dict(self.report, source="untrusted"),
                   dict(self.report, windows=[]), dict(self.report, windows=[self.report['windows'][0]] * 2)]
        for key, values in {'used_percent': [True, -1, 101, float('nan'), float('inf')],
                            'resets_at': [True, 999, float('nan')],
                            'window_minutes': [True, 301]}.items():
            for value in values:
                report = copy.deepcopy(self.report)
                report['windows'][0][key] = value
                invalid.append(report)
        for report in invalid:
            with self.subTest(report=report), self.assertRaises(ReportError):
                self.room.observe(report)
        self.assertEqual(self.room.verdict(), Verdict.UNKNOWN)

    def test_restart_is_unknown_without_new_report(self):
        self.room.observe(self.report)
        self.assertEqual(Headroom(lambda: self.now).verdict(), Verdict.UNKNOWN)


if __name__ == '__main__':
    unittest.main()
