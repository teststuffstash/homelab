#!/usr/bin/env python3
"""Offline regressions for activity-window finding dispositions and evidence retention."""
import json
import unittest
import retro_findings as rf

ISSUE = 'https://github.com/example/project/issues/12'
PR = 'https://github.com/example/project/pull/13'
NOW = '2026-09-28T05:00:00+00:00'


def candidate():
    return {'mechanism': 'stale-window', 'surface': 'agents/retro-rank.py',
            'summary': 'Historical work selected', 'evidence': [ISSUE], 'related_work': [PR]}


def state():
    return rf.combine(None, [('opus', 'run1', [candidate()])], NOW)


def read(url):
    return {'state': 'open', 'merged_at': None}


class FindingsTests(unittest.TestCase):
    def test_strict_model_schema(self):
        envelope = {'schema_version': 1, 'findings': [candidate()]}
        text = 'BEGIN-RETRO-FINDINGS\n```retro-findings-json\n' + json.dumps(envelope) + '\n```\nEND-RETRO-FINDINGS'
        self.assertEqual(rf.extract(text), [candidate()])
        with self.assertRaises(ValueError):
            rf.extract(text + '\n' + text)
        envelope['findings'][0]['accepted_by'] = 'operator'
        with self.assertRaises(ValueError):
            rf.extract('```retro-findings-json\n' + json.dumps(envelope) + '\n```')

    def test_cross_model_dedupe_retains_occurrences_and_rerun_idempotent(self):
        original = state()
        new = rf.combine(original, [('deepseek', 'run2', [candidate()])], NOW)
        self.assertEqual(len(new['findings']), 1)
        self.assertEqual(len(new['findings'][0]['occurrences']), 2)
        self.assertEqual(new, rf.combine(new, [('deepseek', 'run2', [candidate()])], NOW))
        self.assertEqual(len(original['findings'][0]['occurrences']), 1)

    def test_reference_and_merge_alone_do_not_prove_fix(self):
        result = rf.reconcile(state(), {}, lambda url: {'state': 'closed', 'merged_at': NOW}, NOW)
        self.assertEqual(result['findings'][0]['reconciliation']['disposition'], 'insufficient_evidence')

    def test_matched_merge_is_unverified_and_original_evidence_survives(self):
        result = state()
        key = result['findings'][0]['id']
        decisions = {key: {'matched_work': [PR], 'evidence': [PR]}}
        rf.reconcile(result, decisions, lambda url: {'state': 'closed', 'merged_at': NOW}, NOW)
        self.assertEqual(result['findings'][0]['reconciliation']['disposition'], 'implemented_unverified')
        self.assertEqual(result['findings'][0]['occurrences'][0]['evidence'], [ISSUE])
        rf.reconcile(result, {}, lambda url: {'state': 'closed', 'merged_at': NOW}, NOW)
        self.assertEqual(result['findings'][0]['reconciliation']['disposition'], 'implemented_unverified')

    def test_closed_issue_does_not_prove_implementation(self):
        result = state()
        key = result['findings'][0]['id']
        rf.reconcile(result, {key: {'matched_work': [ISSUE], 'evidence': [ISSUE]}}, lambda url: {'state': 'closed'}, NOW)
        self.assertEqual(result['findings'][0]['reconciliation']['disposition'], 'insufficient_evidence')

    def test_failure_cannot_prepare_queue(self):
        result = state()
        key = result['findings'][0]['id']
        decisions = {key: {'disposition': 'new_work_needed', 'canonical_issue': ISSUE,
                           'accepted_by': 'human', 'accepted_at': NOW, 'evidence': [ISSUE]}}
        rf.reconcile(result, decisions, lambda url: {'error': 'unavailable'}, NOW)
        self.assertFalse(result['findings'][0]['reconciliation']['queue_prepared'])
        rf.reconcile(result, decisions, read, NOW)
        self.assertTrue(result['findings'][0]['reconciliation']['queue_prepared'])

    def test_unaccepted_and_noncanonical_references(self):
        result = state()
        key = result['findings'][0]['id']
        rf.reconcile(result, {key: {'disposition': 'new_work_needed', 'evidence': [ISSUE], 'canonical_issue': ISSUE}}, read, NOW)
        self.assertFalse(result['findings'][0]['reconciliation']['queue_prepared'])
        with self.assertRaises(ValueError):
            rf.reconcile(result, {key: {'matched_work': ['https://evil.invalid/issue']}}, read, NOW)

    def test_verified_requires_separate_evidence(self):
        result = state()
        key = result['findings'][0]['id']
        rf.reconcile(result, {key: {'disposition': 'verified'}}, read, NOW)
        self.assertEqual(result['findings'][0]['reconciliation']['disposition'], 'insufficient_evidence')
        rf.reconcile(result, {key: {'disposition': 'verified', 'evidence': [ISSUE]}}, read, NOW)
        self.assertEqual(result['findings'][0]['reconciliation']['disposition'], 'verified')


if __name__ == '__main__':
    unittest.main()
