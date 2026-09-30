#!/usr/bin/env python3
"""Offline contract tests for retro activity collection/window accounting."""
import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('retro_activity', Path(__file__).with_name('retro_activity.py'))
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


def item(number=1):
    return {'number': number, 'html_url': f'https://example/issues/{number}', 'title': 'Spanning work',
            'state': 'open', 'created_at': '2026-09-01T00:00:00Z',
            'updated_at': '2026-09-28T00:00:00Z', 'labels': [{'name': 'agent/in-progress'}]}


def summary(body):
    return dict(id=10, event='commented', created_at='2026-09-01T00:00:00Z',
                updated_at='2026-09-28T00:00:00Z', body='<!-- agent-summary -->\n' + body)


def marker(day, cost=1):
    return f'- **run stats** · ${cost} · 60s <!-- agent-event kind=stats ts=2026-09-{day}T12:00:00Z -->'


def fake_pages(rows):
    def read(endpoint, field=None):
        if '/timeline' in endpoint:
            return iter(rows)
        return iter([item()])
    return read


class ActivityTests(unittest.TestCase):
    def collect(self, rows, state=None, observed='2026-09-29T00:00:00Z'):
        with patch.object(a, 'pages', side_effect=fake_pages(rows)):
            return a.collect(state or {}, ['o/r'], '2026-09-01T00:00:00Z',
                             '2026-09-29T00:00:00Z', observed)

    def test_spanning_issue_and_edited_summary(self):
        # Same issue's runs on Sep 20 and Sep 22 must belong to different
        # Monday windows, despite one summary comment created Sep 1.
        first = self.collect([summary(marker('20'))])
        first['items']['o/r#1']['updated_at'] = '2026-09-27T00:00:00Z'
        state = self.collect([summary(marker('20') + '\n' + marker('22', 2))], first)
        old = a.bundle(state, '2026-09-14T00:00:00Z', '2026-09-21T00:00:00Z')
        new = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z')
        self.assertEqual(old['population']['worker_stat_records'], 1)
        self.assertEqual(new['population']['worker_stat_records'], 1)
        self.assertEqual(new['population']['worker_cost_usd'], 2)
        self.assertEqual(old['tasks'][0]['key'], new['tasks'][0]['key'])
        self.assertEqual(len([e for e in state['events'] if e['kind'] == 'agent-stats']), 2)
        self.assertFalse(any(e['kind'] == 'commented' for e in state['events']))

    def test_stats_correction_is_not_a_new_round(self):
        first = self.collect([summary(marker('22', 1))])
        first['items']['o/r#1']['updated_at'] = '2026-09-27T00:00:00Z'
        second = self.collect([summary(marker('22', 3))], first, observed='2026-09-30T00:00:00Z')
        stats = [e for e in second['events'] if e['kind'] == 'agent-stats']
        self.assertEqual(len(stats), 1)
        self.assertEqual(stats[0]['payload']['cost_usd'], 3)
        self.assertEqual(stats[0]['observed_at'], '2026-09-30T00:00:00Z')

    def test_boundary_and_late_arrival(self):
        state = self.collect([summary(marker('21').replace('12:00', '00:00'))])
        before = a.bundle(state, '2026-09-14T00:00:00Z', '2026-09-21T00:00:00Z')
        after = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z')
        self.assertEqual(before['population']['worker_stat_records'], 0)
        self.assertEqual(after['population']['worker_stat_records'], 1)
        later = a.bundle(state, '2026-09-28T00:00:00Z', '2026-09-29T00:00:00Z',
                         covered_at='2026-09-28T05:00:00Z')
        self.assertTrue(any(e['kind'] == 'agent-stats' for e in later['late_arrivals']))
        acknowledged = a.bundle(state, '2026-09-28T00:00:00Z', '2026-09-29T00:00:00Z',
                                covered_at='2026-09-29T00:00:00Z')
        self.assertEqual(acknowledged['late_arrival_count'], 0)

    def test_failure_transaction_and_incomplete_bundle(self):
        state = self.collect([])
        original = copy.deepcopy(state)
        with patch.object(a, 'pages', side_effect=RuntimeError('403 inaccessible repo')):
            with self.assertRaises(RuntimeError):
                a.collect(state, ['secret/repo'], '2026-09-28T00:00:00Z', '2026-09-30T00:00:00Z')
        self.assertEqual(state, original)
        with self.assertRaises(ValueError):
            a.bundle(state, '2026-09-28T00:00:00Z', '2026-09-30T00:00:00Z')

    def test_merge_kept_reference_not_pain_and_historical_idle(self):
        rows = [summary(marker('22')),
                dict(id=11, event='closed', created_at='2026-09-24T00:00:00Z'),
                dict(id=12, event='cross-referenced', created_at='2026-09-25T00:00:00Z')]
        state = self.collect(rows)
        state['items']['o/r#1']['state'] = 'closed'
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z')
        self.assertEqual(out['population']['worker_stat_records'], 1)
        self.assertEqual(out['tasks'][0]['direct_event_count'], 2)
        self.assertEqual(out['tasks'][0]['failure_events'], 0)
        # Prior week's idle interval remains visible even though item is now closed.
        before = a.bundle(state, '2026-09-14T00:00:00Z', '2026-09-21T00:00:00Z')
        self.assertEqual(before['tasks'][0]['standing_stall_seconds'], 7 * 86400)

    def test_population_before_sampling_and_hash(self):
        state = self.collect([summary(marker('22'))])
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z', keep=0,
                       source_revision='abc')
        self.assertEqual(out['tasks'], [])
        self.assertEqual(out['population']['worker_stat_records'], 1)
        self.assertEqual(out['source_revision'], 'abc')
        self.assertEqual(len(out['bundle_id']), 64)

    def test_pages_retrieves_second_page(self):
        with patch.object(a, 'api', side_effect=[list(range(100)), [100]]) as api:
            self.assertEqual(len(list(a.pages('repos/o/r/issues'))), 101)
        self.assertIn('page=2', api.call_args_list[1].args[0])


if __name__ == '__main__':
    unittest.main()
