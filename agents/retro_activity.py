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
import time
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


TRANSIENT = re.compile(r'HTTP 5\d\d|timed? ?out|connection reset', re.I)


def api(endpoint, attempts=3, pause=5):
    # A transient 5xx is retried in place: the pass is transactional, so one GitHub 504 would
    # otherwise discard every repo read before it (seen in the 2026-10-01 rehearsal). Anything
    # else — and a 5xx that persists — still fails the whole run before state is replaced.
    # A stalled connection that hits the local timeout is the same transient class as a 504.
    for attempt in range(attempts):
        try:
            result = subprocess.run(['gh', 'api', endpoint], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            result = subprocess.CompletedProcess(['gh', 'api', endpoint], 1, '', 'local timeout after 120s')
        if not result.returncode:
            return json.loads(result.stdout)
        if attempt + 1 < attempts and TRANSIENT.search(result.stderr):
            time.sleep(pause * (attempt + 1))
            continue
        raise RuntimeError('GitHub read failed: ' + endpoint + ': ' + result.stderr[:300])


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
                items[key]['head_sha'] = pr['head']['sha']
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
                        payload = {'name': check['name'], 'conclusion': check.get('conclusion'), 'sha': sha}
                        # Store output summary/text for cancelled checks so bundle() can classify
                        # the cancellation reason without an extra API call per cancelled run.
                        if check.get('conclusion') == 'cancelled':
                            output = check.get('output') or {}
                            summary = output.get('summary') or ''
                            text = output.get('text') or ''
                            if summary or text:
                                payload['output_summary'] = str(summary)[:500]
                                payload['output_text'] = str(text)[:500]
                        add(repo, number, 'check', str(check['id']),
                            when, check.get('html_url') or url, payload)
                items[key]['pending_check_shas'] = sorted(pending)
    result.update(version=1, events=sorted(events.values(), key=lambda e: (e['occurred_at'], e['id'])),
                  collected_until=until, observed_at=observed, repos=sorted(repos))
    return result


REFERENCES = {'cross-referenced', 'referenced'}


def compact(event):
    """One prompt-sized line of an event: when, what, a ≤160-char detail, and its link."""
    p = event.get('payload', {})
    detail = ' '.join(str(p[k]['name'] if isinstance(p[k], dict) else p[k])
                      for k in ('name', 'state', 'conclusion', 'label') if p.get(k))
    body = p.get('body') or p.get('title') or ''
    if body:
        detail = (detail + ' ' if detail else '') + ' '.join(str(body).split())[:160]
    out = {'at': event['occurred_at'], 'kind': event['kind'], 'url': event['url']}
    if detail:
        out['detail'] = detail
    return out


def _classify_cancellation(event, item):
    """Classify a cancelled check run: 'superseded', 'infra', or 'other'.

    superseded — a newer SHA on the PR, or the check-run output says "Canceling since a
    higher priority waiting request". These are excluded from item pain and reported as a
    population metric (wasted CI / wall time).

    infra — "runner has received a shutdown signal", "lost communication with the server".
    These are their own infra_failure_events signal.

    other — counted as a failure event, with the message kept.
    """
    payload = event.get('payload', {})
    sha = payload.get('sha', '')
    head_sha = item.get('head_sha', '')
    # Superseded by a newer SHA on the PR
    if head_sha and sha and sha != head_sha:
        return 'superseded'
    # Check the output summary/text for known cancellation reasons
    summary = (payload.get('output_summary') or '').lower()
    text = (payload.get('output_text') or '').lower()
    reason = summary + '\n' + text
    if 'higher priority' in reason or 'canceling since' in reason:
        return 'superseded'
    if 'shutdown signal' in reason or 'lost communication' in reason:
        return 'infra'
    return 'other'


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

    # Build PR→issue links from cross-referenced events. When a PR references an issue
    # (closing reference / cross-reference), the PR's failures roll up to the issue.
    pr_to_issue = {}
    for event in state['events']:
        if event['kind'] == 'cross-referenced':
            source = event['payload'].get('source', {})
            if isinstance(source, dict) and 'issue' in source:
                src_issue = source['issue']
                src_repo = src_issue.get('repository', {}).get('full_name', event['repo'])
                src_number = src_issue.get('number')
                if src_number is not None:
                    src_key = f"{src_repo}#{src_number}"
                    tgt_key = f"{event['repo']}#{event['item']}"
                    # Only PR→issue links: check if the source item is a PR
                    src_item = state['items'].get(src_key, {})
                    if src_item.get('is_pr'):
                        pr_to_issue[src_key] = tgt_key

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

        # Classify each event into the new pain categories
        failure_events = 0
        infra_failure_events = 0
        superseded_cancellations = 0
        agent_pain_events = 0
        for e in direct:
            if e['kind'] == 'check' and e['payload'].get('conclusion') == 'cancelled':
                cls = _classify_cancellation(e, item)
                if cls == 'superseded':
                    superseded_cancellations += 1
                elif cls == 'infra':
                    infra_failure_events += 1
                else:
                    failure_events += 1
            elif e['kind'] == 'check' and e['payload'].get('conclusion') in {'failure', 'timed_out'}:
                failure_events += 1
            elif e['kind'] == 'review' and e['payload'].get('state') == 'CHANGES_REQUESTED':
                failure_events += 1
            elif e['kind'] in ('agent-block', 'agent-strike', 'agent-arbitrate', 'agent-park'):
                agent_pain_events += 1

        # Weighted score: real failures dominate, but standing stall on agent/*-labelled
        # items carries real weight so blocked issues rank above cancellation-only PRs.
        # Weights chosen so a blocked issue with a week of stall (~604800s) and agent pain
        # events outranks a PR with a handful of non-superseded cancellations.
        W_FAILURE = 1000
        W_INFRA = 500
        W_AGENT_PAIN = 500
        W_EVENT = 10
        W_STALL = 0.005
        score = (failure_events * W_FAILURE + infra_failure_events * W_INFRA
                 + agent_pain_events * W_AGENT_PAIN
                 + len(direct) * W_EVENT + idle * W_STALL)

        tasks.append(dict(key=key, project=item['repo'].split('/')[-1], issue=item['item'], repo=item['repo'],
                          events=evs, context=item, standing_stall_seconds=idle,
                          failure_events=failure_events, infra_failure_events=infra_failure_events,
                          superseded_cancellations=superseded_cancellations,
                          agent_pain_events=agent_pain_events,
                          direct_event_count=len(direct), score=score))

    # Roll PR failures up to linked issues (credit issues)
    for pr_key, issue_key in pr_to_issue.items():
        pr_task = next((t for t in tasks if t['key'] == pr_key), None)
        issue_task = next((t for t in tasks if t['key'] == issue_key), None)
        if pr_task and issue_task:
            issue_task['failure_events'] += pr_task['failure_events']
            issue_task['direct_event_count'] += pr_task['direct_event_count']
            issue_task['score'] += pr_task['failure_events'] * W_FAILURE + pr_task['direct_event_count'] * W_EVENT

    tasks.sort(key=lambda t: (-t['score'], t['key']))
    late = [e for e in state['events'] if timestamp(e['occurred_at']) < start
            and timestamp(e['observed_at']) > timestamp(covered_at or since)]
    # Full counters are calculated before any prompt-sized sampling.
    worker_stats = [e for e in selected if e['kind'] == 'agent-stats']
    result = dict(version=1, window={'since': since, 'until': until},
                collected_until=state['collected_until'], scope_source=state.get('scope_source', 'unknown'), repos=state.get('repos', []),
                population={'event_count': len(selected), 'task_count': len(tasks),
                            'by_kind': dict(Counter(e['kind'] for e in selected)),
                            'failure_events': sum(t['failure_events'] for t in tasks),
                            'infra_failure_events': sum(t['infra_failure_events'] for t in tasks),
                            'superseded_cancellations': sum(t['superseded_cancellations'] for t in tasks),
                            'agent_pain_events': sum(t['agent_pain_events'] for t in tasks),
                            'worker_stat_records': len(worker_stats),
                            'worker_cost_measured_records': sum('cost_usd' in e['payload'] for e in worker_stats),
                            'worker_cost_usd': (sum(e['payload'].get('cost_usd', 0) for e in worker_stats) if any('cost_usd' in e['payload'] for e in worker_stats) else None),
                            'worker_duration_s': sum(e['payload'].get('duration_s', 0) for e in worker_stats),
                            'standing_stall_seconds': sum(t['standing_stall_seconds'] for t in tasks)},
                tasks=tasks[:keep], selected_task_count=min(len(tasks), keep),
                late_arrivals=late,
                limitations=['GitHub activity only; worker sessions, token cost, deployments and legacy commit statuses are not collected.',
                             'Standing stall is idle open-time exposure, not a failure verdict.',
                             'Comment revisions use updated_at; dated agent-event markers supply stats where emitted. Stats mirrored on issue and PR may describe the same ride: records are not unique runs or full cost coverage.',
                             'Cancelled checks are classified: superseded (newer SHA or higher-priority request) → wasted-CI metric; infra (shutdown/lost-communication) → platform signal; other → counted as failure.'])
    result['source_revision'] = source_revision or 'unknown'
    result['covered_at'] = state.get('observed_at')
    result['late_arrival_count'] = len(late)
    # Preserve the complete evidence in the collector state; prompts get a declared,
    # deterministic bounded sample with original event ids and links for retrieval.
    # Prompt-side events are COMPACT: the task already names repo/item, the collector state keeps
    # ids and observation times, the url is the retrieval handle (kept on the task context too:
    # an idle-only task has no events to carry one). The verbose form cost ~7 KB a
    # task and left 5 of 118 tasks in the 60 KB budget (2026-10-01 oracle-fleet rehearsal).
    for task in result['tasks']:
        task['event_count'] = len(task['events'])
        task['events'] = [compact(e) for e in task['events'][-8:]]
        task['context'] = {k: v for k, v in task['context'].items()
                           if k in ('title', 'url', 'state', 'is_pr', 'labels', 'created_at', 'closed_at', 'merged_at')}
        for k in ('project', 'repo', 'issue'):
            task.pop(k)
    result['late_arrivals'] = [dict(compact(e), key=f"{e['repo']}#{e['item']}", observed_at=e['observed_at'])
                               for e in late[:20]]
    result['sampling'] = {'max_tasks': keep, 'max_events_per_task': 8, 'max_late_events': 20,
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
