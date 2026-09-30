#!/usr/bin/env python3
"""FU-058: durable orchestration for weekly activity retros and daily finding checks.

The bucket is state; git holds the procedure. Local --store supports isolated rehearsal.
Only publication advances coverage. Analysis retries reuse a frozen evidence bundle.
"""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent


def run(*args, **kwargs):
    return subprocess.run(list(args), check=True, text=True, capture_output=True, **kwargs).stdout


def utc(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(timezone.utc)


def iso(value):
    return value.strftime('%Y-%m-%dT%H:%M:%SZ')


def cutoff(now):
    day = utc(now).replace(hour=0, minute=0, second=0, microsecond=0)
    return iso(day - timedelta(days=day.weekday()))


class Store:
    def __init__(self, local=None):
        self.local = Path(local) if local else None
        self.prefix = 's3://' + os.environ.get('AGENT_TS_BUCKET', 'agent-transcripts') + '/_retro/'

    def command(self, verb, *args, write=False):
        env = dict(os.environ, AWS_REGION='garage')
        role = 'WRITER' if write else 'READER'
        env['AWS_ACCESS_KEY_ID'] = os.environ['AGENT_TS_' + role + '_ID']
        env['AWS_SECRET_ACCESS_KEY'] = os.environ['AGENT_TS_' + role + '_SECRET']
        return run('s5cmd', '--endpoint-url', os.environ['AGENT_TS_ENDPOINT'], verb, *args, env=env)

    def get(self, key, default=None):
        if self.local:
            p = self.local / key
            return json.loads(p.read_text()) if p.exists() else default
        try:
            return json.loads(self.command('cat', self.prefix + key))
        except subprocess.CalledProcessError as exc:
            # Auth/network failures MUST NOT reset the checkpoint or accumulated activity.
            if 'NoSuchKey' in exc.stderr or 'specified key does not exist' in exc.stderr:
                return default
            raise

    def put(self, key, value):
        if self.local:
            p = self.local / key
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_suffix('.tmp')
            tmp.write_text(json.dumps(value, indent=2) + '\n')
            tmp.replace(p)
        else:
            with tempfile.TemporaryDirectory() as d:
                p = Path(d) / 'data.json'
                p.write_text(json.dumps(value))
                self.command('cp', str(p), self.prefix + key, write=True)

    def publications(self, series):
        if self.local:
            return [json.loads(p.read_text()) for p in sorted((self.local / series / 'runs').glob('*/publication.json'))]
        try:
            listing = self.command('ls', self.prefix + series + '/runs/*/publication.json')
        except subprocess.CalledProcessError as exc:
            if 'no object found' in exc.stderr.lower() or 'NoSuchKey' in exc.stderr:
                return []
            raise
        keys = [line.split()[-1] for line in listing.splitlines() if line.strip()]
        return [self.get(k.removeprefix(self.prefix)) for k in sorted(keys)]


def collect(args, store, temp):
    state = store.get('activity.json', {})
    path = temp / 'activity.json'
    path.write_text(json.dumps(state))
    command = [sys.executable, str(ROOT / 'retro_activity.py'), 'collect', '--state', str(path), '--output', str(path), '--until', args.now]
    if not state:
        command += ['--since', iso(utc(cutoff(args.now)) - timedelta(days=7))]
    for repo in args.repo:
        command += ['--repo', repo]
    run(*command)
    result = json.loads(path.read_text())
    store.put('activity.json', result)
    print('activity collection persisted through ' + args.now)


def prepare(args, store, temp):
    end = cutoff(args.now)
    checkpoint = store.get(args.series + '/checkpoint.json', {})
    start = checkpoint.get('until', iso(utc(end) - timedelta(days=7)))
    if utc(start) >= utc(end):
        raise ValueError('this weekly window is already published')
    key = args.series + '/runs/' + end.replace(':', '').replace('-', '')
    bundle = store.get(key + '/bundle.json')
    if bundle is None:
        state = store.get('activity.json')
        if not state or utc(state['collected_until']) < utc(end):
            raise ValueError('activity coverage has not reached the cutoff; collect before preparing')
        path = temp / 'activity.json'
        path.write_text(json.dumps(state))
        output = temp / 'bundle.json'
        command = [sys.executable, str(ROOT / 'retro_activity.py'), 'bundle', '--state', str(path), '--output', str(output), '--since', start, '--until', end, '--keep', '40']
        if checkpoint.get('covered_at'):
            command += ['--covered-at', checkpoint['covered_at']]
        run(*command)
        bundle = json.loads(output.read_text())
        bundle['source_revision'] = run('git', 'rev-parse', 'HEAD', cwd=ROOT.parent).strip()
        bundle['prepared_at'] = args.now
        runs = [int(m.group(1)) for p in (ROOT.parent / 'docs/agents/retros').glob('*.md')
                if (m := re.search(re.escape(args.series) + r'-r(\d+)-', p.name))]
        bundle['run_id'] = 'r' + str(max(runs + [int(checkpoint.get('run_id', 'r0')[1:])]) + 1)
        previous_findings = store.get(args.series + '/findings.json', {}).get('findings', [])
        bundle['previous_findings'] = [
            {k: f[k] for k in ('id', 'mechanism', 'surface', 'summary', 'related_work') if k in f}
            for f in previous_findings[-30:]]
        bundle['previous_findings_total'] = len(previous_findings)
        bundle['series'] = args.series
        bundle['storage_key'] = key
        bundle.pop('bundle_id', None)
        # Budget the COMPLETE bundle, including prior findings, before argv transport.
        while len(json.dumps(bundle).encode()) > 60000 and bundle['previous_findings']:
            bundle['previous_findings'].pop(0)
        while len(json.dumps(bundle).encode()) > 60000 and bundle['tasks']:
            bundle['tasks'].pop()
        bundle['selected_task_count'] = len(bundle['tasks'])
        bundle['bundle_id'] = hashlib.sha256(json.dumps(bundle, sort_keys=True).encode()).hexdigest()
        store.put(key + '/bundle.json', bundle)
    Path(args.output).write_text(json.dumps(bundle, separators=(',', ':')) + '\n')
    print('frozen activity bundle ' + bundle['bundle_id'])


def publish(args, store, temp):
    bundle = json.loads(Path(args.bundle).read_text())
    if bundle['series'] != args.series:
        raise ValueError('bundle series mismatch')
    unhashed = {k: v for k, v in bundle.items() if k != 'bundle_id'}
    if hashlib.sha256(json.dumps(unhashed, sort_keys=True).encode()).hexdigest() != bundle['bundle_id']:
        raise ValueError('frozen evidence bundle hash mismatch')
    previous = store.get(args.series + '/checkpoint.json', {})
    if previous and previous['until'] not in (bundle['window']['since'], bundle['window']['until']):
        raise ValueError('bundle is not contiguous with published coverage')
    reports = {}
    command = [sys.executable, str(ROOT / 'retro_findings.py'), '--output', str(temp / 'findings.json'), '--markdown', str(temp / 'findings.md')]
    for entry in args.report:
        model, path = entry.split('=', 1)
        reports[model] = Path(path).read_text()
        command += ['--report', entry]
    run(*command)
    # Parsing is strict before coverage moves; a report without findings metadata needs repair.
    publication = {'bundle_id': bundle['bundle_id'], 'window': bundle['window'],
                   'report_pr': args.pr, 'published_at': args.now, 'reports': reports,
                   'findings': json.loads((temp / 'findings.json').read_text())}
    store.put(bundle['storage_key'] + '/publication.json', publication)
    # A partial model run still covers the same source period; missing cell remains explicit in PR.
    previous = store.get(args.series + '/checkpoint.json', {})
    end = bundle['window']['until']
    if previous and utc(previous['until']) > utc(end):
        raise ValueError('refusing to move coverage backwards')
    store.put(args.series + '/checkpoint.json', {'until': end, 'covered_at': bundle['prepared_at'],
                                               'bundle_id': bundle['bundle_id'], 'run_id': bundle['run_id'], 'report_pr': args.pr})
    print('published evidence coverage through ' + end)


def reconcile(args, store, temp):
    publications = store.publications(args.series)
    if not publications:
        print('no published findings to reconcile')
        return
    command = [sys.executable, str(ROOT / 'retro_findings.py'), '--output', str(temp / 'findings.json'), '--markdown', str(temp / 'findings.md'), '--github']
    previous = store.get(args.series + '/findings.json')
    decisions = store.get(args.series + '/decisions.json')
    if decisions:
        p = temp / 'decisions.json'
        p.write_text(json.dumps(decisions))
        command += ['--decisions', str(p)]
    if previous:
        p = temp / 'previous.json'
        p.write_text(json.dumps(previous))
        command += ['--previous', str(p)]
    for i, publication in enumerate(publications):
        for model, body in publication['reports'].items():
            p = temp / ('report-' + str(i) + '-' + re.sub(r'[^a-zA-Z0-9]', '-', model) + '.md')
            p.write_text(body)
            command += ['--report', model + '=' + str(p)]
    run(*command)
    result = json.loads((temp / 'findings.json').read_text())
    result['checked_at'] = args.now
    store.put(args.series + '/findings.json', result)
    print((temp / 'findings.md').read_text())


def accept(args, store, temp):
    import retro_queue
    state = store.get(args.series + '/findings.json')
    if state is None:
        raise ValueError('reconcile published reports before accepting findings')
    decisions = store.get(args.series + '/decisions.json', {})
    decisions.update(json.loads(Path(args.decisions).read_text()))
    known = {f['id'] for f in state['findings']}
    if set(decisions) - known:
        raise ValueError('decision IDs must name existing findings')
    receipt = store.get(args.series + '/acceptance-receipts.json', {})
    for key, url in receipt.items():
        if key in decisions:
            decisions[key]['canonical_issue'] = url
    actions = retro_queue.plan(state, decisions)
    print(json.dumps(actions, indent=2))
    if not args.apply:
        return
    if any(a['action'] == 'create-and-queue' and not (decisions[a['id']].get('origin_issue') or args.batch) for a in actions):
        raise ValueError('new findings require a --batch or origin_issue before filing')
    store.put(args.series + '/decisions.json', decisions)
    retro_queue.apply(state, decisions, receipt,
                      lambda values: store.put(args.series + '/acceptance-receipts.json', values), args.batch)
    store.put(args.series + '/decisions.json', decisions)
    # Separate completion record: publication is not disposition or dispatch.
    store.put(args.series + '/acceptance.json', {'checked_at': args.now, 'actions': actions, 'receipts': receipt})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['collect', 'prepare', 'publish', 'reconcile', 'accept'])
    parser.add_argument('--store', help='local directory instead of S3, for rehearsal')
    parser.add_argument('--series', default='platform')
    parser.add_argument('--now', default=iso(datetime.now(timezone.utc)))
    parser.add_argument('--repo', action='append', default=[])
    parser.add_argument('--output', default='/work/bundle.json')
    parser.add_argument('--bundle')
    parser.add_argument('--report', action='append', default=[])
    parser.add_argument('--pr')
    parser.add_argument('--decisions')
    parser.add_argument('--batch')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch('[a-z0-9-]+', args.series):
        parser.error('invalid series')
    if args.action == 'publish' and (not args.bundle or not args.report or not args.pr):
        parser.error('publish requires --bundle, --report MODEL=PATH, --pr URL')
    if args.action == 'accept' and not args.decisions:
        parser.error('accept requires --decisions; --apply explicitly authorizes filing/queueing')
    with tempfile.TemporaryDirectory() as d:
        globals()[args.action](args, Store(args.store), Path(d))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        print('retro pipeline failed: ' + str(exc), file=sys.stderr)
        sys.exit(1)
