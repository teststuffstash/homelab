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
        # Idle-only task: no events in the window, so the context must still carry the link.
        self.assertEqual(before['tasks'][0]['events'], [])
        self.assertEqual(before['tasks'][0]['context']['url'], 'https://example/issues/1')

    def test_population_before_sampling_and_hash(self):
        state = self.collect([summary(marker('22'))])
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z', keep=0,
                       source_revision='abc')
        self.assertEqual(out['tasks'], [])
        self.assertEqual(out['population']['worker_stat_records'], 1)
        self.assertEqual(out['source_revision'], 'abc')
        self.assertEqual(len(out['bundle_id']), 64)

    def test_closed_pr_pending_checks_are_revisited(self):
        row = dict(item(), state='closed', pull_request={})
        prior = {'repo':'o/r', 'item':1, 'updated_at':row['updated_at'],
                 'pending_check_shas':['abc']}
        state = {'items':{'o/r#1':prior}, 'events':[],
                 'collected_until':'2026-09-29T00:00:00Z'}
        def read(endpoint):
            if '/pulls/' in endpoint:
                return {'head':{'sha':'abc'}, 'merged_at':None}
            return row
        def paged(endpoint, field=None):
            if '/check-runs' in endpoint:
                return iter([{'id':5, 'name':'ci', 'completed_at':'2026-09-29T12:00:00Z',
                              'conclusion':'failure'}])
            return iter([])
        with patch.object(a, 'api', side_effect=read), patch.object(a, 'pages', side_effect=paged):
            result = a.collect(state, ['o/r'], state['collected_until'], '2026-09-30T00:00:00Z')
        self.assertEqual(len([e for e in result['events'] if e['kind']=='check']), 1)
        self.assertEqual(result['items']['o/r#1']['pending_check_shas'], [])

    def test_pending_check_completion_corrects_not_duplicates(self):
        row = dict(item(), pull_request={})
        runs = [{'id':5, 'name':'ci', 'started_at':'2026-09-28T10:00:00Z', 'completed_at':None,
                 'conclusion':None}]
        def read(endpoint):
            return {'head':{'sha':'abc'}, 'merged_at':None}
        def paged(endpoint, field=None):
            if '/check-runs' in endpoint:
                return iter(copy.deepcopy(runs))
            if '/commits' in endpoint:
                return iter([{'sha':'abc'}])
            if '/issues?' in endpoint:
                return iter([row])
            return iter([])
        with patch.object(a, 'api', side_effect=read), patch.object(a, 'pages', side_effect=paged):
            state = a.collect({}, ['o/r'], '2026-09-28T00:00:00Z', '2026-09-28T12:00:00Z')
            runs[0].update(completed_at='2026-09-28T12:30:00Z', conclusion='failure')
            state = a.collect(state, ['o/r'], '2026-09-28T12:00:00Z', '2026-09-29T00:00:00Z')
        checks = [e for e in state['events'] if e['kind'] == 'check']
        self.assertEqual(len(checks), 1)
        self.assertEqual(checks[0]['payload']['conclusion'], 'failure')

    def test_api_retries_transient_but_not_permanent(self):
        from types import SimpleNamespace as R
        replies = [R(returncode=1, stderr='(HTTP 504)', stdout=''), R(returncode=0, stderr='', stdout='{"ok":1}')]
        with patch.object(a.subprocess, 'run', side_effect=replies), patch.object(a.time, 'sleep'):
            self.assertEqual(a.api('x'), {'ok': 1})
        stalled = [a.subprocess.TimeoutExpired(['gh'], 120), R(returncode=0, stderr='', stdout='{"ok":2}')]
        with patch.object(a.subprocess, 'run', side_effect=stalled), patch.object(a.time, 'sleep'):
            self.assertEqual(a.api('x'), {'ok': 2})
        with patch.object(a.subprocess, 'run', side_effect=a.subprocess.TimeoutExpired(['gh'], 120)) as run, \
                patch.object(a.time, 'sleep'):
            with self.assertRaises(RuntimeError):
                a.api('x')
            self.assertEqual(run.call_count, 3)
        with patch.object(a.subprocess, 'run', return_value=R(returncode=1, stderr='(HTTP 403)', stdout='')) as run:
            with self.assertRaises(RuntimeError):
                a.api('x')
            self.assertEqual(run.call_count, 1)

    def test_pages_retrieves_second_page(self):
        with patch.object(a, 'api', side_effect=[list(range(100)), [100]]) as api:
            self.assertEqual(len(list(a.pages('repos/o/r/issues'))), 101)
        self.assertIn('page=2', api.call_args_list[1].args[0])


# ── New tests for cancellation classification, issue crediting, weighted score ──────────

def check_event(conclusion='failure', sha='abc', output_summary=None, output_text=None):
    """Build a check event payload for testing."""
    p = {'name': 'ci', 'conclusion': conclusion, 'sha': sha}
    if output_summary:
        p['output_summary'] = output_summary
    if output_text:
        p['output_text'] = output_text
    return p


def make_event(kind, payload=None, occurred_at='2026-09-22T12:00:00Z', repo='o/r', item=1):
    return {'id': f'{repo}:{item}:{kind}:x', 'kind': kind, 'occurred_at': occurred_at,
            'observed_at': '2026-09-29T00:00:00Z', 'repo': repo, 'item': item,
            'url': f'https://example/issues/{item}', 'payload': payload or {}}


class ClassificationTests(unittest.TestCase):
    """Cancellation classification: superseded, infra, other."""

    def test_superseded_by_newer_sha(self):
        """A cancelled check whose SHA differs from the PR head SHA is superseded."""
        item = {'head_sha': 'def456', 'is_pr': True}
        ev = make_event('check', check_event('cancelled', sha='abc123'))
        self.assertEqual(a._classify_cancellation(ev, item), 'superseded')

    def test_superseded_by_higher_priority_message(self):
        """A cancelled check with 'Canceling since a higher priority' is superseded."""
        item = {'head_sha': 'abc123', 'is_pr': True}
        ev = make_event('check', check_event('cancelled', sha='abc123',
                        output_summary='Canceling since a higher priority waiting request'))
        self.assertEqual(a._classify_cancellation(ev, item), 'superseded')

    def test_infra_shutdown_signal(self):
        """A cancelled check with 'shutdown signal' is infra."""
        item = {'head_sha': 'abc123', 'is_pr': True}
        ev = make_event('check', check_event('cancelled', sha='abc123',
                        output_summary='The runner has received a shutdown signal'))
        self.assertEqual(a._classify_cancellation(ev, item), 'infra')

    def test_infra_lost_communication(self):
        """A cancelled check with 'lost communication' is infra."""
        item = {'head_sha': 'abc123', 'is_pr': True}
        ev = make_event('check', check_event('cancelled', sha='abc123',
                        output_text='lost communication with the server'))
        self.assertEqual(a._classify_cancellation(ev, item), 'infra')

    def test_other_cancellation(self):
        """A cancelled check without known signals is 'other' (counted as failure)."""
        item = {'head_sha': 'abc123', 'is_pr': True}
        ev = make_event('check', check_event('cancelled', sha='abc123',
                        output_summary='Cancelled by user'))
        self.assertEqual(a._classify_cancellation(ev, item), 'other')

    def test_no_head_sha_falls_back_to_message(self):
        """Without head_sha, classification relies on the output message."""
        item = {'is_pr': True}
        ev = make_event('check', check_event('cancelled', sha='abc123',
                        output_summary='Canceling since a higher priority waiting request'))
        self.assertEqual(a._classify_cancellation(ev, item), 'superseded')

    def test_no_output_falls_back_to_other(self):
        """Without output summary/text and matching SHA, cancellation is 'other'."""
        item = {'head_sha': 'abc123', 'is_pr': True}
        ev = make_event('check', check_event('cancelled', sha='abc123'))
        self.assertEqual(a._classify_cancellation(ev, item), 'other')


class BundleClassificationTests(unittest.TestCase):
    """bundle() correctly classifies cancellations and computes new metrics."""

    def collect(self, rows, state=None, observed='2026-09-29T00:00:00Z'):
        with patch.object(a, 'pages', side_effect=fake_pages(rows)):
            return a.collect(state or {}, ['o/r'], '2026-09-01T00:00:00Z',
                             '2026-09-29T00:00:00Z', observed)

    def test_superseded_cancellation_excluded_from_failure_events(self):
        """A superseded cancellation is NOT counted in failure_events."""
        rows = [summary(marker('22')),
                dict(id=11, event='closed', created_at='2026-09-24T00:00:00Z')]
        state = self.collect(rows)
        state['items']['o/r#1']['is_pr'] = True
        state['items']['o/r#1']['head_sha'] = 'def456'
        # Manually inject a superseded check event
        state['events'].append(make_event('check', check_event('cancelled', sha='abc123',
                                           output_summary='Canceling since a higher priority'),
                                          occurred_at='2026-09-23T12:00:00Z'))
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z')
        self.assertEqual(out['tasks'][0]['failure_events'], 0)
        self.assertEqual(out['tasks'][0]['superseded_cancellations'], 1)
        self.assertEqual(out['population']['superseded_cancellations'], 1)

    def test_infra_cancellation_counted_separately(self):
        """An infra cancellation is counted in infra_failure_events, not failure_events."""
        rows = [summary(marker('22'))]
        state = self.collect(rows)
        state['items']['o/r#1']['is_pr'] = True
        state['items']['o/r#1']['head_sha'] = 'abc123'
        state['events'].append(make_event('check', check_event('cancelled', sha='abc123',
                                           output_summary='runner has received a shutdown signal'),
                                          occurred_at='2026-09-23T12:00:00Z'))
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z')
        self.assertEqual(out['tasks'][0]['failure_events'], 0)
        self.assertEqual(out['tasks'][0]['infra_failure_events'], 1)
        self.assertEqual(out['population']['infra_failure_events'], 1)

    def test_other_cancellation_counted_as_failure(self):
        """An 'other' cancellation is counted in failure_events."""
        rows = [summary(marker('22'))]
        state = self.collect(rows)
        state['items']['o/r#1']['is_pr'] = True
        state['items']['o/r#1']['head_sha'] = 'abc123'
        state['events'].append(make_event('check', check_event('cancelled', sha='abc123',
                                           output_summary='Cancelled by user'),
                                          occurred_at='2026-09-23T12:00:00Z'))
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z')
        self.assertEqual(out['tasks'][0]['failure_events'], 1)
        self.assertEqual(out['tasks'][0]['superseded_cancellations'], 0)
        self.assertEqual(out['tasks'][0]['infra_failure_events'], 0)

    def test_agent_pain_events_counted(self):
        """agent-block/strike/arbitrate/park events are counted as agent_pain_events."""
        rows = [summary(marker('22'))]
        state = self.collect(rows)
        for kind in ('agent-block', 'agent-strike', 'agent-arbitrate', 'agent-park'):
            state['events'].append(make_event(kind, {'body': 'test'},
                                              occurred_at='2026-09-23T12:00:00Z'))
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z')
        self.assertEqual(out['tasks'][0]['agent_pain_events'], 4)
        self.assertEqual(out['population']['agent_pain_events'], 4)

    def test_weighted_score_ranks_blocked_issue_above_cancellation_pr(self):
        """A blocked issue with high stall ranks above a PR with a few cancellations."""
        # Issue: blocked since Sep 1, agent pain events, high stall
        issue_state = {
            'o/r#1': {'repo': 'o/r', 'item': 1, 'title': 'Blocked issue',
                      'url': 'https://example/issues/1', 'state': 'open',
                      'created_at': '2026-09-01T00:00:00Z',
                      'updated_at': '2026-09-28T00:00:00Z',
                      'labels': ['agent/blocked'], 'is_pr': False}
        }
        # PR: recent, events right up to window end so minimal stall
        pr_state = {
            'o/r#2': {'repo': 'o/r', 'item': 2, 'title': 'PR with cancellations',
                      'url': 'https://example/issues/2', 'state': 'open',
                      'created_at': '2026-09-27T00:00:00Z',
                      'updated_at': '2026-09-28T00:00:00Z',
                      'labels': [], 'is_pr': True, 'head_sha': 'abc123'}
        }
        state = {'version': 1, 'events': [], 'items': {**issue_state, **pr_state},
                 'collected_until': '2026-09-29T00:00:00Z',
                 'observed_at': '2026-09-29T00:00:00Z', 'repos': ['o/r']}
        # Issue: agent-block event early in window → lots of stall after it
        state['events'].append(make_event('agent-block', {'body': 'blocked'},
                                          occurred_at='2026-09-21T12:00:00Z', item=1))
        # PR: 2 'other' cancelled checks at the very end of the window → minimal stall
        for i in range(2):
            state['events'].append(make_event('check', check_event('cancelled', sha='abc123',
                                               output_summary='Cancelled by user'),
                                              occurred_at='2026-09-27T23:00:00Z', item=2))
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z', keep=10)
        # The blocked issue should rank first (higher score from stall + agent pain)
        self.assertEqual(out['tasks'][0]['key'], 'o/r#1')
        self.assertGreater(out['tasks'][0]['score'], out['tasks'][1]['score'])

    def test_issue_crediting_rolls_up_pr_failures(self):
        """PR failures roll up to the linked issue via cross-reference."""
        issue_state = {
            'o/r#1': {'repo': 'o/r', 'item': 1, 'title': 'Linked issue',
                      'url': 'https://example/issues/1', 'state': 'open',
                      'created_at': '2026-09-01T00:00:00Z',
                      'updated_at': '2026-09-28T00:00:00Z',
                      'labels': ['agent/in-progress'], 'is_pr': False}
        }
        pr_state = {
            'o/r#2': {'repo': 'o/r', 'item': 2, 'title': 'Fixing PR',
                      'url': 'https://example/issues/2', 'state': 'open',
                      'created_at': '2026-09-20T00:00:00Z',
                      'updated_at': '2026-09-28T00:00:00Z',
                      'labels': [], 'is_pr': True, 'head_sha': 'abc123'}
        }
        state = {'version': 1, 'events': [], 'items': {**issue_state, **pr_state},
                 'collected_until': '2026-09-29T00:00:00Z',
                 'observed_at': '2026-09-29T00:00:00Z', 'repos': ['o/r']}
        # PR has a check failure
        state['events'].append(make_event('check', check_event('failure', sha='abc123'),
                                          occurred_at='2026-09-23T12:00:00Z', item=2))
        # Cross-reference: PR #2 references issue #1
        state['events'].append({
            'id': 'o/r:1:cross-referenced:x', 'kind': 'cross-referenced',
            'occurred_at': '2026-09-25T00:00:00Z',
            'observed_at': '2026-09-29T00:00:00Z',
            'repo': 'o/r', 'item': 1,
            'url': 'https://example/issues/1',
            'payload': {'source': {'type': 'issue',
                                   'issue': {'number': 2,
                                             'repository': {'full_name': 'o/r'}}}}
        })
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z', keep=10)
        # The issue should have the PR's failure rolled up
        issue_task = next(t for t in out['tasks'] if t['key'] == 'o/r#1')
        self.assertGreater(issue_task['failure_events'], 0)


def test_issue_crediting_dedup_same_pr_issue_pair(self):
        """Duplicate cross-references for the same PR/issue pair credit only once."""
        issue_state = {
            'o/r#1': {'repo': 'o/r', 'item': 1, 'title': 'Linked issue',
                      'url': 'https://example/issues/1', 'state': 'open',
                      'created_at': '2026-09-01T00:00:00Z',
                      'updated_at': '2026-09-28T00:00:00Z',
                      'labels': ['agent/in-progress'], 'is_pr': False}
        }
        pr_state = {
            'o/r#2': {'repo': 'o/r', 'item': 2, 'title': 'Fixing PR',
                      'url': 'https://example/issues/2', 'state': 'open',
                      'created_at': '2026-09-20T00:00:00Z',
                      'updated_at': '2026-09-28T00:00:00Z',
                      'labels': [], 'is_pr': True, 'head_sha': 'abc123'}
        }
        state = {'version': 1, 'events': [], 'items': {**issue_state, **pr_state},
                 'collected_until': '2026-09-29T00:00:00Z',
                 'observed_at': '2026-09-29T00:00:00Z', 'repos': ['o/r']}
        # PR has a check failure
        state['events'].append(make_event('check', check_event('failure', sha='abc123'),
                                          occurred_at='2026-09-23T12:00:00Z', item=2))
        # Two identical cross-references for the same PR→issue pair
        for i in range(2):
            state['events'].append({
                'id': f'o/r:1:cross-referenced:{i}', 'kind': 'cross-referenced',
                'occurred_at': '2026-09-25T00:00:00Z',
                'observed_at': '2026-09-29T00:00:00Z',
                'repo': 'o/r', 'item': 1,
                'url': 'https://example/issues/1',
                'payload': {'source': {'type': 'issue',
                                       'issue': {'number': 2,
                                                 'repository': {'full_name': 'o/r'}}}}
            })
        out = a.bundle(state, '2026-09-21T00:00:00Z', '2026-09-28T00:00:00Z', keep=10)
        issue_task = next(t for t in out['tasks'] if t['key'] == 'o/r#1')
        pr_task = next(t for t in out['tasks'] if t['key'] == 'o/r#2')
        # Issue should have exactly the PR's failure_events, not doubled
        self.assertEqual(issue_task['failure_events'], pr_task['failure_events'],
                         "duplicate cross-references must not double-credit failure_events")


if __name__ == '__main__':
    unittest.main()
