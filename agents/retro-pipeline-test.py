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
        self.args = argparse.Namespace(series='platform', now=NOW, output=str(self.root / 'bundle.json'),
                                       min_tasks=0)
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

    def write_ledger(self, rows):
        path = self.root / 'store' / '_ledger.jsonl'
        path.write_text(''.join(json.dumps(r) + '\n' for r in rows))

    def test_ledger_rows_are_windowed_not_all_time(self):
        # The r6 misbehaviour: an all-time pain rank re-surfaced August's blocked tasks every
        # Monday while a 9-round task emitted inside the window never ranked.
        old = {'ts':'2026-08-25T10:00:00Z', 'key':'homelab#913', 'terminal_label':'agent/blocked',
               'rounds':[{'model':'m','exit_status':'clean'}] * 8}
        now = {'ts':'2026-09-27T18:30:34Z', 'key':'oracle-fleet#753', 'terminal_label':'agent/blocked',
               'snapshot':True, 'rounds':[{'model':'m','exit_status':'ci-failed','error_class':'ci-red','ci':False}]}
        done = dict(now, ts='2026-09-27T20:00:00Z', snapshot=None, terminal_label='agent/done',
                    rounds=[{'model':'haiku','exit_status':'clean','ci':True}] * 2)
        late = dict(old, ts='2026-09-28T00:00:00Z', key='homelab#2000')  # at the cutoff: next window
        self.write_ledger([old, now, done, late])
        p.prepare(self.args, self.store, self.root)
        ledger = json.loads(Path(self.args.output).read_text())['ledger']
        self.assertEqual([r['key'] for r in ledger['rows']], ['oracle-fleet#753'])
        self.assertEqual(ledger['rows'][0]['terminal_label'], 'agent/done')  # latest emit wins
        self.assertEqual(ledger['population']['rows_emitted'], 2)
        self.assertEqual(ledger['population']['first_touch_by_model'], {'haiku': {'tasks':1, 'non_clean':0}})

    def test_quiet_window_refuses_and_rolls_forward(self):
        self.args.min_tasks = 1
        with self.assertRaisesRegex(ValueError, 'GUARD REFUSED'):
            p.prepare(self.args, self.store, self.root)
        self.assertIsNone(self.store.get('platform/runs/20260928T000000Z/bundle.json'))
        self.assertIsNone(self.store.get('platform/checkpoint.json'))

    def test_remote_publications_rebuild_relative_keys(self):
        remote = p.Store()
        listing = '2026/09/28 07:00:00   812  20260928T000000Z/publication.json\n'
        calls = []
        def command(verb, *args, write=False):
            calls.append((verb,) + args)
            return listing if verb == 'ls' else json.dumps({'reports': {}})
        with patch.object(remote, 'command', side_effect=command):
            self.assertEqual(remote.publications('platform'), [{'reports': {}}])
        self.assertEqual(calls[-1], ('cat', 's3://agent-transcripts/_retro/platform/runs/20260928T000000Z/publication.json'))

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

    def test_remote_missing_key_is_first_run(self):
        remote = p.Store()
        # The exact s5cmd 2.3 / Garage stderr for an absent key (live probe 2026-10-02).
        error = subprocess.CalledProcessError(1, ['s5cmd'], stderr='ERROR "cat s3://agent-transcripts/_retro/activity.json": '
                                              'given object s3://agent-transcripts/_retro/activity.json not found')
        with patch.object(remote, 'command', side_effect=error):
            self.assertEqual(remote.get('activity.json', {}), {})
            self.assertEqual(remote.ledger(), [])

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

    def test_harvest_retry_restores_report_after_checkout(self):
        import os
        repo = self.root / 'repo'
        repo.mkdir()
        env = dict(os.environ, GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                   GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        def git(*args):
            return p.run('git', *args, cwd=repo, env=env)
        git('init', '-b', 'master')
        git('commit', '--allow-empty', '-m', 'base')
        git('remote', 'add', 'origin', str(repo))
        git('checkout', '-b', 'retro/retry')
        reports = repo / 'docs/agents/retros'
        reports.mkdir(parents=True)
        report = reports / '2026-09-28-platform-r6-opus.md'
        report.write_text('previous report')
        git('add', '.'); git('commit', '-m', 'published report')
        git('update-ref', 'refs/pull/123/head', 'HEAD')
        git('checkout', 'master')
        git('branch', '-D', 'retro/retry')
        reports.mkdir(parents=True, exist_ok=True)
        report.write_text('retry report')
        source = (Path(__file__).parent / 'coordinator/retro-argo.yaml').read_text()
        block = source.split('              mkdir -p /tmp/retro-reports', 1)[1].split('              git add docs/agents/retros/', 1)[0]
        block = 'mkdir -p /tmp/retro-reports' + block
        block = block.replace('/tmp/retro-reports', str(self.root / 'saved'))
        prefix = 'DATE=2026-09-28; STACK=platform; RUN=r6; BR=retro/retry; gh() { echo https://github.com/o/r/pull/123; }; '
        p.run('bash', '-ec', prefix + block, cwd=repo, env=env)
        self.assertEqual(report.read_text(), 'retry report')

    def harvest_publish(self, open_pr, merged_pr, same_as_master):
        """Run the harvest's branch→PR selection with stubbed gh and push."""
        import os
        repo = self.root / 'h'
        repo.mkdir()
        env = dict(os.environ, GIT_AUTHOR_NAME='T', GIT_AUTHOR_EMAIL='t@example.invalid',
                   GIT_COMMITTER_NAME='T', GIT_COMMITTER_EMAIL='t@example.invalid')
        def git(*args):
            return p.run('git', *args, cwd=repo, env=env)
        reports = repo / 'docs/agents/retros'
        reports.mkdir(parents=True)
        report = reports / '2026-09-28-platform-r6-opus.md'
        git('init', '-b', 'master')
        if same_as_master:
            report.write_text('report'); git('add', '.')
        git('commit', '--allow-empty', '-m', 'base')
        git('update-ref', 'refs/remotes/origin/master', 'HEAD')
        report.write_text('report')
        source = (Path(__file__).parent / 'coordinator/retro-argo.yaml').read_text()
        block = source.split('              mkdir -p /tmp/retro-reports', 1)[1].split('              REPORT_ARGS=()', 1)[0]
        block = ('mkdir -p /tmp/retro-reports' + block).replace('/tmp/retro-reports', str(self.root / 'saved'))
        log = self.root / 'calls'
        prefix = ('DATE=2026-09-28; STACK=platform; RUN=r6; BR=retro/r6; N=1; DEAD_NOTE=; GH_TOKEN=t; '
                  'gh() { echo "gh $*" >> %s; case "$*" in *"pr create"*) echo https://new/pull/9;; '
                  '*"--state open"*) echo "%s";; *"--state merged"*) echo "%s";; esac; }; '
                  'git() { if [ "$1" = push ]; then echo "push" >> %s; else command git "$@"; fi; }; '
                  % (log, open_pr, merged_pr, log))
        out = p.run('bash', '-ec', prefix + block + '\nprintf "%s" "$REPORT_PR"', cwd=repo, env=env)
        calls = log.read_text() if log.exists() else ''
        self.assertNotIn('--state all', calls)
        return out.splitlines()[-1], calls

    def test_harvest_never_reuses_a_dead_pr_for_new_reports(self):
        out, calls = self.harvest_publish('', 'https://old/pull/1', same_as_master=False)
        self.assertEqual(out, 'https://new/pull/9')
        self.assertIn('push', calls)

    def test_harvest_reuses_merged_pr_only_when_already_on_master(self):
        out, calls = self.harvest_publish('', 'https://old/pull/1', same_as_master=True)
        self.assertEqual(out, 'https://old/pull/1')
        self.assertNotIn('push', calls)
        self.assertNotIn('pr create', calls)

    def test_retro_session_missing_bundle_is_a_clean_fatal(self):
        import os
        path = Path(__file__).parent / 'retro-session.sh'
        source = path.read_text().split('# >>>REPLAY:retro-window-run-id>>>', 1)[1].split('# <<<REPLAY:retro-window-run-id<<<', 1)[0]
        env = dict(os.environ, LEDGER=str(self.root / 'typo.json'), RUN_ID='r6')
        result = subprocess.run(['bash', '-ec', source], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('FATAL', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

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
        guard = next(t for t in spec['workflowSpec']['templates'] if t['name'] == 'guard')
        self.assertIn('--min-tasks "{{workflow.parameters.minWindowTasks}}"', guard['container']['args'][0])
        env = {e['name']: e for e in guard['container']['env']}
        self.assertTrue(env['GH_TOKEN']['valueFrom']['secretKeyRef'].get('optional'))


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
