#!/usr/bin/env python3
"""Incremental GitHub activity evidence for weekly retros (stdlib only).

Collection is transactional: any unreadable endpoint fails the run before state is
replaced. Event time determines accounting; observed time identifies late evidence.
This collector does not claim session cost/round coverage: those require manifests.
"""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urlencode


def timestamp(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(timezone.utc)


def iso(value):
    return value.isoformat().replace('+00:00', 'Z')


def atomic(path, data):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=target.parent, delete=False) as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write('\n')
        name = f.name
    os.replace(name, target)


def api(endpoint):
    result = subprocess.run(['gh', 'api', endpoint], capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError('GitHub read failed: ' + endpoint + ': ' + result.stderr[:300])
    return json.loads(result.stdout)


def pages(endpoint, field=None):
    page = 1
    while True:
        response = api(endpoint + ('&' if '?' in endpoint else '?') + urlencode({'per_page': 100, 'page': page}))
        rows = response[field] if field else response
        if not isinstance(rows, list):
            raise ValueError('Expected paginated list: ' + endpoint)
        yield from rows
        if len(rows) < 100:
            return
        page += 1


def collect(state, repos, since, until, observed=None):
    observed = observed or iso(datetime.now(timezone.utc))
    if timestamp(since) >= timestamp(until):
        raise ValueError('Collection must advance time')
    if state.get('collected_until') and timestamp(until) < timestamp(state['collected_until']):
        raise ValueError('Cannot move collection backwards')
    # Work on a copy: callers can retry without partially advanced state.
    result = json.loads(json.dumps(state))
    events = {e['id']: e for e in result.get('events', [])}
    items = result.setdefault('items', {})

    def add(repo, number, kind, identity, when, url, payload):
        if not when or timestamp(when) >= timestamp(until):
            return
        eid = f'{repo}:{number}:{kind}:{identity}'
        if eid not in events or events[eid]['payload'] != payload:
            # A corrected source record replaces the same event, never another round.
            # Its new observation time exposes the correction in the next retro.
            events[eid] = dict(id=eid, occurred_at=when, observed_at=observed,
                               repo=repo, item=number, kind=kind, url=url, payload=payload)

    for repo in repos:
        endpoint = f'repos/{repo}'
        changed = list(pages(endpoint + '/issues?' + urlencode({'state': 'all', 'since': since, 'sort': 'updated', 'direction': 'asc'})))
        # Open items are mandatory even without activity: silence can be a stall.
        open_items = list(pages(endpoint + '/issues?state=open'))
        selected = {row['number']: row for row in changed + open_items}
        # A closed PR can finish CI without bumping issue updated_at. Keep polling
        # its recorded pending commits until they finish, even outside the issue feed.
        for old in list(items.values()):
            if old['repo'] == repo and old.get('pending_check_shas') and old['item'] not in selected:
                selected[old['item']] = api(f"{endpoint}/issues/{old['item']}")
        for number, row in selected.items():
            key = f'{repo}#{number}'
            url = row['html_url']
            previous = items.get(key, {})
            items[key] = dict(repo=repo, item=number, title=row['title'], url=url,
                              state=row['state'], created_at=row['created_at'],
                              updated_at=row['updated_at'], closed_at=row.get('closed_at'),
                              labels=[v['name'] for v in row.get('labels', [])],
                              is_pr='pull_request' in row, observed_at=observed)
            add(repo, number, 'opened', number, row['created_at'], url, {'title': row['title']})
            # Stable open items still contribute idle exposure, without re-reading their
            # entire history every 30 minutes. Revisit a row newer than the previous cutoff
            # because the last pass deliberately omitted events at/after its cutoff.
            refresh = (not previous or previous.get('updated_at') != row['updated_at']
                       or timestamp(row['updated_at']) >= timestamp(state.get('collected_until', since)))
            for event in (pages(f'{endpoint}/issues/{number}/timeline') if refresh else []):
                kind = event.get('event', '')
                when = event.get('created_at') or event.get('submitted_at')
                if kind == 'commented':
                    body = event.get('body') or ''
                    if '<!-- agent-summary -->' in body:
                        for line in body.splitlines():
                            marker = re.search(r'<!-- agent-event kind=([^ ]+) ts=([^ ]+) -->', line)
                            if not marker:
                                continue
                            event_kind, event_time = marker.groups()
                            details = {'body': line[:2000], 'comment_id': event.get('id')}
                            if event_kind == 'stats':
                                cost = re.search(r'\$(\d+(?:\.\d+)?)', line)
                                duration = re.search(r'·\s*(\d+(?:\.\d+)?)s', line)
                                if cost:
                                    details['cost_usd'] = float(cost.group(1))
                                if duration:
                                    details['duration_s'] = float(duration.group(1))
                            identity = str(event.get('id')) + ':' + event_kind + ':' + event_time
                            add(repo, number, 'agent-' + event_kind, identity, event_time,
                                event.get('html_url') or url, details)
                        continue
                    # A mutable bot summary is an observation, not a new worker round.
                    # Use update time and content identity to preserve successive versions.
                    when = event.get('updated_at') or when
                    revision = hashlib.sha256(body.encode()).hexdigest()[:16]
                    identity = str(event.get('id')) + ':' + revision
                    payload = {'body': body[:8000], 'author': event.get('user', {}).get('login'),
                               'created_at': event.get('created_at'), 'updated_at': when}
                else:
                    identity = event.get('id') or hashlib.sha256(json.dumps(event, sort_keys=True).encode()).hexdigest()[:20]
                    payload = {k: event[k] for k in ('state', 'commit_id', 'label', 'source') if k in event}
                if kind in ('commented', 'closed', 'reopened', 'labeled', 'unlabeled', 'cross-referenced', 'referenced', 'committed'):
                    add(repo, number, kind, identity, when, event.get('html_url') or url, payload)
            if 'pull_request' in row:
                pr = api(f'{endpoint}/pulls/{number}')
                items[key]['merged_at'] = pr.get('merged_at')
                add(repo, number, 'merged', number, pr.get('merged_at'), url, {})
                for review in (pages(f'{endpoint}/pulls/{number}/reviews') if refresh else []):
                    add(repo, number, 'review', review['id'], review.get('submitted_at'), review['html_url'],
                        {'state': review['state'], 'body': (review.get('body') or '')[:8000]})
                # Read every PR commit, not only HEAD: earlier failed CI is retro evidence.
                # Read historical heads once; then refresh HEAD and any checks still running.
                commits = (list(pages(f'{endpoint}/pulls/{number}/commits')) if refresh
                           else [{'sha': pr['head']['sha']}])
                commits += [{'sha': sha} for sha in previous.get('pending_check_shas', [])]
                pending = set()
                checked = set()
                for commit in commits:
                    sha = commit['sha']
                    if sha in checked:
                        continue
                    checked.add(sha)
                    for check in pages(f'{endpoint}/commits/{sha}/check-runs?filter=all', 'check_runs'):
                        if not check.get('completed_at') or timestamp(check['completed_at']) >= timestamp(until):
                            pending.add(sha)
                        when = check.get('completed_at') or check.get('started_at')
                        # Identity is the check run alone: a pending→completed re-read CORRECTS
                        # the record (conclusion lives in the payload), never adds a second event.
                        add(repo, number, 'check', str(check['id']),
                            when, check.get('html_url') or url,
                            {'name': check['name'], 'conclusion': check.get('conclusion'), 'sha': sha})
                items[key]['pending_check_shas'] = sorted(pending)
    result.update(version=1, events=sorted(events.values(), key=lambda e: (e['occurred_at'], e['id'])),
                  collected_until=until, observed_at=observed, repos=sorted(repos))
    return result


REFERENCES = {'cross-referenced', 'referenced'}


def bundle(state, since, until, keep=40, covered_at=None, source_revision=None):
    start, end = timestamp(since), timestamp(until)
    if start >= end:
        raise ValueError('Window must have positive duration')
    if timestamp(state['collected_until']) < end:
        raise ValueError('Collection does not cover requested cutoff')
    selected = [e for e in state['events'] if start <= timestamp(e['occurred_at']) < end]
    by_item = {}
    for event in selected:
        by_item.setdefault(f"{event['repo']}#{event['item']}", []).append(event)
    tasks = []
    for key, item in state['items'].items():
        evs = by_item.get(key, [])
        direct = [e for e in evs if e['kind'] not in REFERENCES]
        # Historical open intervals reconstructed from lifecycle events; current state
        # alone cannot describe a window before a later close/reopen.
        lifecycle = sorted((e for e in state['events'] if f"{e['repo']}#{e['item']}" == key
                            and e['kind'] in {'opened', 'closed', 'reopened', 'merged'}), key=lambda e: e['occurred_at'])
        opened = timestamp(item['created_at'])
        intervals = []
        for event in lifecycle:
            at = timestamp(event['occurred_at'])
            if event['kind'] in {'closed', 'merged'} and opened is not None:
                intervals.append((opened, at)); opened = None
            elif event['kind'] == 'reopened':
                opened = at
        if opened is not None:
            intervals.append((opened, end))
        # Standing idle time is time after the most recent substantive event while
        # open. It is an exposure metric, never proof of a failure or blocked work.
        substantive = [timestamp(e['occurred_at']) for e in state['events']
                       if f"{e['repo']}#{e['item']}" == key and e['kind'] not in REFERENCES
                       and timestamp(e['occurred_at']) < end]
        last = max(substantive, default=timestamp(item['created_at']))
        idle = sum(max(0, (min(b, end) - max(a, start, last)).total_seconds()) for a, b in intervals)
        # Ordinary parked feature backlog is not an active platform stall.
        active = any(label.startswith('agent/') for label in item.get('labels', [])) or item.get('is_pr')
        if not active:
            idle = 0
        if not direct and not idle:
            continue
        failures = sum(e['kind'] == 'check' and e['payload'].get('conclusion') in {'failure', 'timed_out', 'cancelled'}
                       or e['kind'] == 'review' and e['payload'].get('state') == 'CHANGES_REQUESTED' for e in direct)
        tasks.append(dict(key=key, project=item['repo'].split('/')[-1], issue=item['item'], repo=item['repo'],
                          events=evs, context=item, standing_stall_seconds=idle,
                          failure_events=failures, direct_event_count=len(direct)))
    tasks.sort(key=lambda t: (-t['failure_events'], -t['direct_event_count'], -t['standing_stall_seconds'], t['key']))
    late = [e for e in state['events'] if timestamp(e['occurred_at']) < start
            and timestamp(e['observed_at']) > timestamp(covered_at or since)]
    # Full counters are calculated before any prompt-sized sampling.
    worker_stats = [e for e in selected if e['kind'] == 'agent-stats']
    result = dict(version=1, window={'since': since, 'until': until},
                collected_until=state['collected_until'], scope_source=state.get('scope_source', 'unknown'), repos=state.get('repos', []),
                population={'event_count': len(selected), 'task_count': len(tasks),
                            'by_kind': dict(Counter(e['kind'] for e in selected)),
                            'failure_events': sum(t['failure_events'] for t in tasks),
                            'worker_stat_records': len(worker_stats),
                            'worker_cost_measured_records': sum('cost_usd' in e['payload'] for e in worker_stats),
                            'worker_cost_usd': (sum(e['payload'].get('cost_usd', 0) for e in worker_stats) if any('cost_usd' in e['payload'] for e in worker_stats) else None),
                            'worker_duration_s': sum(e['payload'].get('duration_s', 0) for e in worker_stats),
                            'standing_stall_seconds': sum(t['standing_stall_seconds'] for t in tasks)},
                tasks=tasks[:keep], selected_task_count=min(len(tasks), keep),
                late_arrivals=late,
                limitations=['GitHub activity only; worker sessions, token cost, deployments and legacy commit statuses are not collected.',
                             'Standing stall is idle open-time exposure, not a failure verdict.',
                             'Comment revisions use updated_at; dated agent-event markers supply stats where emitted. Stats mirrored on issue and PR may describe the same ride: records are not unique runs or full cost coverage.'])
    result['source_revision'] = source_revision or 'unknown'
    result['covered_at'] = state.get('observed_at')
    result['late_arrival_count'] = len(late)
    # Preserve the complete evidence in the collector state; prompts get a declared,
    # deterministic bounded sample with original event ids and links for retrieval.
    for task in result['tasks']:
        task['event_count'] = len(task['events'])
        task['events'] = task['events'][-12:]
        task['events'] = [dict(e, payload={k: (v[:300] if isinstance(v, str) else v)
                                         for k, v in e['payload'].items() if k != 'source'}) for e in task['events']]
    result['late_arrivals'] = [dict(id=e['id'], occurred_at=e['occurred_at'], observed_at=e['observed_at'],
                                  repo=e['repo'], item=e['item'], kind=e['kind'], url=e['url']) for e in late[:40]]
    result['sampling'] = {'max_tasks': keep, 'max_events_per_task': 12, 'max_late_events': 40,
                          'max_serialized_bytes': 60000, 'full_evidence': 'collector state artifact'}
    while len(json.dumps(result).encode()) > 59000 and result['tasks']:
        result['tasks'].pop()
    result['selected_task_count'] = len(result['tasks'])
    result['bundle_id'] = hashlib.sha256(json.dumps(result, sort_keys=True).encode()).hexdigest()
    return result


def repository_scope(stacks_path):
    stacks = {s['name']: s for s in json.loads(Path(stacks_path).read_text())['stacks']}
    try:
        command = ['kubectl', 'get', 'agentstacks.platform.teststuff.net', '-o', 'json']
        result = subprocess.run(command, text=True, capture_output=True, check=True, timeout=30)
        claims = json.loads(result.stdout)['items']
        for claim in claims:
            stacks[claim['metadata']['name']] = {'repos':[r['name'] for r in claim['spec']['repos']]}
        source = 'live claims over committed mirror'
    except (OSError, subprocess.SubprocessError, ValueError, KeyError):
        source = 'committed mirror (live claim read unavailable)'
    repos = sorted({r if '/' in r else os.environ.get('ORG', 'teststuffstash') + '/' + r
                    for s in stacks.values() for r in s['repos']})
    return repos, source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('collect', 'bundle'):
        p = sub.add_parser(command)
        p.add_argument('--state', required=True)
        p.add_argument('--output', required=True)
        p.add_argument('--since')
        p.add_argument('--until')
        if command == 'collect':
            p.add_argument('--repo', action='append')
            p.add_argument('--stacks', default=str(Path(__file__).with_name('stacks.json')))
        else:
            p.add_argument('--keep', type=int, default=40)
            p.add_argument('--covered-at')
            p.add_argument('--source-revision')
    args = parser.parse_args()
    state = json.loads(Path(args.state).read_text()) if Path(args.state).exists() else {}
    until = args.until or iso(datetime.now(timezone.utc))
    since = args.since or state.get('collected_until') or iso(timestamp(until) - timedelta(days=7))
    if args.command == 'collect':
        repos, scope = (args.repo, 'explicit repo scope') if args.repo else repository_scope(args.stacks)
        result = collect(state, repos, since, until)
        result['scope_source'] = scope
        atomic(args.output, result)
        if Path(args.output) != Path(args.state):
            atomic(args.state, result)
    else:
        if not args.since or not args.until:
            parser.error('bundle requires explicit --since and --until')
        atomic(args.output, bundle(state, since, until, args.keep, args.covered_at, args.source_revision))


if __name__ == '__main__':
    main()
