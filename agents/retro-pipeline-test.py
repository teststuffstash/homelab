#!/usr/bin/env python3
"""Offline integration tests for coverage, publication and explicit queue acceptance."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import retro_pipeline as p
import retro_findings as f
import retro_queue as q

NOW = '2026-09-28T05:00:00Z'
REPORT = '''# report
```retro-findings-json
{"schema_version":1,"findings":[]}
```
'''


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = p.Store(str(self.root / 'store'))
        self.args = argparse.Namespace(series='platform', now=NOW, output=str(self.root / 'bundle.json'))
        self.store.put('activity.json', {'version':1, 'events':[], 'items':{},
                                       'collected_until':NOW, 'observed_at':NOW})

    def test_cutoff_and_immutable_prepare(self):
        self.assertEqual(p.cutoff('2026-09-30T13:00:00Z'), '2026-09-28T00:00:00Z')
        p.prepare(self.args, self.store, self.root)
        first = Path(self.args.output).read_bytes()
        self.assertIsNone(self.store.get('platform/checkpoint.json'))
        self.store.put('activity.json', {'invalid':True})
        p.prepare(self.args, self.store, self.root)
        self.assertEqual(first, Path(self.args.output).read_bytes())
        bundle = json.loads(first)
        self.assertEqual(bundle['window'], {'since':'2026-09-21T00:00:00Z','until':'2026-09-28T00:00:00Z'})

    def test_failed_or_missing_week_does_not_skip(self):
        self.store.put('platform/checkpoint.json', {'until':'2026-09-14T00:00:00Z','covered_at':'2026-09-14T05:00:00Z'})
        p.prepare(self.args, self.store, self.root)
        bundle = json.loads(Path(self.args.output).read_text())
        self.assertEqual(bundle['window']['since'], '2026-09-14T00:00:00Z')
        self.assertEqual(self.store.get('platform/checkpoint.json')['until'], '2026-09-14T00:00:00Z')

    def test_publication_validates_findings_before_checkpoint(self):
        p.prepare(self.args, self.store, self.root)
        report = self.root / 'report.md'
        report.write_text('Missing structured findings')
        self.args.bundle = self.args.output
        self.args.pr = 'https://github.com/o/r/pull/1'
        self.args.report = ['opus=' + str(report)]
        with self.assertRaises(subprocess.CalledProcessError):
            p.publish(self.args, self.store, self.root)
        self.assertIsNone(self.store.get('platform/checkpoint.json'))
        report.write_text(REPORT)
        p.publish(self.args, self.store, self.root)
        self.assertEqual(self.store.get('platform/checkpoint.json')['until'], '2026-09-28T00:00:00Z')
        self.assertEqual(len(self.store.publications('platform')), 1)
        with self.assertRaisesRegex(ValueError, 'already published'):
            p.prepare(self.args, self.store, self.root)

    def test_incomplete_collection_refuses(self):
        self.store.put('activity.json', {'collected_until':'2026-09-27T23:30:00Z'})
        with self.assertRaisesRegex(ValueError, 'coverage'):
            p.prepare(self.args, self.store, self.root)
        self.assertIsNone(self.store.get('platform/checkpoint.json'))

    def test_unreadable_bucket_does_not_reset(self):
        remote = p.Store()
        error = subprocess.CalledProcessError(1, ['s5cmd'], stderr='AccessDenied')
        with patch.object(remote, 'command', side_effect=error):
            with self.assertRaises(subprocess.CalledProcessError):
                remote.get('activity.json', {})

    def test_frozen_run_id_survives_unmerged_report(self):
        path = Path(__file__).parent / 'retro-session.sh'
        source = path.read_text().split('# >>>REPLAY:retro-window-run-id>>>', 1)[1].split('# <<<REPLAY:retro-window-run-id<<<', 1)[0]
        ledger = self.root / 'input.json'
        ledger.write_text('{"run_id":"r99"}')
        import os
        env = dict(os.environ, LEDGER=str(ledger), RUN_ID='r6')
        result = p.run('bash', '-ec', source + '\nprintf "%s" "$RUN_ID"', env=env)
        self.assertEqual(result, 'r99')
        ledger.write_text('{"run_id":"r99; malicious"}')
        with self.assertRaises(subprocess.CalledProcessError):
            p.run('bash', '-ec', source, env=env)

    def test_workflow_shares_guard_artifact(self):
        # Read shipped manifest via the pinned yq tool; do not copy its DAG into the test.
        path = Path(__file__).parent / 'coordinator/retro-argo.yaml'
        data = json.loads(p.run('yq','-o=json','.',str(path)))
        spec = data['spec']
        self.assertEqual(spec['schedules'], ['0 5 * * 1'])
        self.assertEqual(spec['timezone'], 'UTC')
        tasks = spec['workflowSpec']['templates'][0]['dag']['tasks']
        for name in ('cell-a','cell-b','harvest'):
            task = next(t for t in tasks if t['name'] == name)
            artifact = next(a for a in task['arguments']['artifacts'] if a['name']=='evidence')
            self.assertEqual(artifact['from'], '{{tasks.guard.outputs.artifacts.evidence}}')
        self.assertNotIn('retro-rank.py', path.read_text())
        self.assertNotIn('minNewTasks', path.read_text())


class QueueTests(unittest.TestCase):
    def setUp(self):
        candidate = {'mechanism':'empty-provider','surface':'agents/foo.sh','summary':'fails open',
                     'evidence':['https://github.com/o/r/issues/1'], 'related_work':[]}
        self.state=f.combine(None,[('opus','r1',[candidate])],NOW)
        self.key=self.state['findings'][0]['id']
        self.decision={'disposition':'new_work_needed','evidence':['https://github.com/o/r/issues/1'],
                       'accepted_by':'operator','accepted_at':NOW,'canonical_issue':'https://github.com/o/r/issues/2'}
        self.fetch=lambda url: {'state':'open','labels':[]}

    def test_unaccepted_report_cannot_queue(self):
        self.assertEqual(q.plan(self.state,{},self.fetch),[])
        self.decision.pop('accepted_by')
        self.assertEqual(q.plan(self.state,{self.key:self.decision},self.fetch),[])

    def test_fix_lands_after_acceptance_prevents_queue(self):
        self.state['findings'][0]['related_work']=['https://github.com/o/r/pull/3']
        def fetch(url):
            return {'state':'closed','merged_at':'2026-09-29T00:00:00Z'} if '/pull/' in url else {'state':'open'}
        result=q.plan(self.state,{self.key:self.decision},fetch)
        self.assertEqual(result[0]['action'],'skip')
        self.assertIn('after adjudication',result[0]['reason'])

    def test_queue_is_idempotent_and_preserves_holds(self):
        decisions={self.key:self.decision}
        calls=[]
        def api(endpoint,method='GET',data=None):
            calls.append((endpoint,method,data))
            return {'state':'open','labels':[{'name':'agent/blocked'}], 'body':'Touches: agents/foo.sh'}
        with patch.object(q,'api',side_effect=api):
            q.apply(self.state,decisions,{},lambda r:None,None,self.fetch)
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0][1],'GET')

    def test_apply_rechecks_and_queues_only_accepted_issue(self):
        calls=[]
        def api(endpoint,method='GET',data=None):
            calls.append((endpoint,method,data))
            return {'state':'open','labels':[], 'body':'---\nTouches: agents/foo.sh\nBase: master\n---'}
        with patch.object(q,'api',side_effect=api):
            q.apply(self.state,{self.key:self.decision},{},lambda r:None,None,self.fetch)
        self.assertEqual(calls[-1],('repos/o/r/issues/2/labels','POST',{'labels':['agent-fix','agent/queued']}))

    def test_existing_matched_unqueued_issue_can_be_accepted(self):
        self.decision['matched_work'] = [self.decision['canonical_issue']]
        self.assertEqual(q.plan(self.state,{self.key:self.decision},self.fetch)[0]['action'], 'queue')
        self.decision['matched_work'].append('https://github.com/o/r/pull/3')
        self.assertEqual(q.plan(self.state,{self.key:self.decision},self.fetch)[0]['action'], 'skip')

    def test_invalid_batch_refuses_before_creation(self):
        self.decision.pop('canonical_issue')
        self.decision['issue']={'repo':'o/r','title':'fix','body':'---\nTouches: agents/foo.sh\nBase: master\n---','labels':['task/build']}
        calls=[]
        def api(endpoint,method='GET',data=None):
            calls.append(method)
            return {'state':'closed','title':'retro-batch: r1'}
        with patch.object(q,'api',side_effect=api):
            with self.assertRaisesRegex(ValueError,'open retro-batch'):
                q.apply(self.state,{self.key:self.decision},{},lambda r:None,'https://github.com/o/r/issues/9',self.fetch)
        self.assertEqual(calls,['GET'])

    def test_creation_requires_valid_body_and_no_goal(self):
        self.decision.pop('canonical_issue')
        self.decision['issue']={'repo':'o/r','title':'fix','body':'---\nTouches: agents/foo.sh\nBase: master\n---','labels':['task/goal']}
        with self.assertRaisesRegex(ValueError,'Goal'):
            q.plan(self.state,{self.key:self.decision},self.fetch)


if __name__ == '__main__':
    unittest.main()
