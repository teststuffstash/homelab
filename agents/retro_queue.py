#!/usr/bin/env python3
"""Explicitly accept retro findings, then file/queue surviving work (FU-058).

Scheduled reconciliation never calls this command. --apply is the seat's acceptance act;
report text cannot authorize itself. Default is a read-only plan. Receipts make retries
idempotent, and exact finding markers recover an issue if a receipt write was interrupted.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess

import issue_body
import retro_findings as findings


def api(endpoint, method='GET', data=None):
    command = ['gh', 'api', '--method', method, endpoint]
    if data is not None:
        command += ['--input', '-']
    proc = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                          text=True, capture_output=True, check=True, timeout=120)
    return json.loads(proc.stdout) if proc.stdout.strip() else None


def all_issues(repo):
    page = 1
    while True:
        rows = api(f'repos/{repo}/issues?state=all&per_page=100&page={page}')
        yield from (r for r in rows if 'pull_request' not in r)
        if len(rows) < 100:
            break
        page += 1


def issue_ref(url):
    match = findings.REF.fullmatch(url or '')
    if not match or match.group(2) != 'issues':
        raise ValueError('expected canonical issue URL')
    return match.group(1), int(match.group(3))


def plan(state, decisions, fetch=findings.github_get):
    now = datetime.now(timezone.utc).isoformat()
    findings.reconcile(state, decisions, fetch, now)
    output = []
    for finding in state['findings']:
        decision = finding.get('decision', {})
        if not decision.get('accepted_by') or not decision.get('accepted_at'):
            continue
        review = finding['reconciliation']
        matched_issue = (review['disposition'] == 'covered_by_existing_work'
                         and decision.get('canonical_issue') in decision.get('matched_work', [])
                         and not any('/pull/' in u and v.get('state') == 'open'
                                     for u, v in review['work'].items() if u in decision.get('matched_work', [])))
        if review['disposition'] != 'new_work_needed' and not matched_issue:
            output.append({'id': finding['id'], 'action': 'skip', 'reason': review['reason']})
            continue
        if any('error' in r for r in review['work'].values()):
            raise ValueError('unreadable related work for ' + finding['id'])
        canonical = decision.get('canonical_issue')
        if canonical:
            repo, number = issue_ref(canonical)
            if review['work'][canonical]['state'] != 'open':
                output.append({'id': finding['id'], 'action': 'skip', 'reason': 'canonical issue is closed'})
                continue
            output.append({'id': finding['id'], 'action': 'queue', 'repo': repo, 'number': number})
        else:
            spec = decision.get('issue', {})
            repo, title, body = spec.get('repo'), spec.get('title'), spec.get('body')
            if not repo or not title or not body:
                raise ValueError('accepted new work requires issue repo/title/body: ' + finding['id'])
            issue_ref('https://github.com/' + repo + '/issues/1')
            fields = issue_body.parse_block(body)
            if not fields.get('Touches') or fields.get('Base') != 'master':
                raise ValueError('new ordinary work requires machine-block Touches and Base: master')
            if not any(l.startswith('task/') for l in spec.get('labels', [])):
                raise ValueError('new work requires a task/* classification')
            if any(l.startswith('agent/') or l == 'task/goal' for l in spec.get('labels', [])):
                raise ValueError('acceptance cannot manufacture Goal or lifecycle labels')
            output.append({'id': finding['id'], 'action': 'create-and-queue', 'repo': repo,
                           'title': title, 'body': body, 'labels': spec['labels']})
    return output


def apply(state, decisions, receipt, save, batch, fetch=findings.github_get):
    # Reconcile immediately before EVERY mutation group, not once when the report was written.
    for initial in plan(state, decisions, fetch):
        key = initial['id']
        current = next(p for p in plan(state, decisions, fetch) if p['id'] == key)
        if current['action'] == 'skip':
            continue
        decision = decisions[key]
        repo = current['repo']
        if current['action'] == 'create-and-queue':
            parent_url = decision.get('origin_issue') or batch
            if not parent_url:
                raise ValueError('new work requires an existing retro-batch or origin issue')
            parent_repo, parent = issue_ref(parent_url)
            parent_issue = api(f'repos/{parent_repo}/issues/{parent}')
            if parent_url == batch and (parent_issue['state'] != 'open' or not parent_issue.get('title', '').startswith('retro-batch:')):
                raise ValueError('batch must be an open retro-batch container')
            marker = '<!-- retro-finding:' + key + ' -->'
            candidates = [r for r in all_issues(repo) if marker in (r.get('body') or '')]
            if len(candidates) > 1:
                raise ValueError('duplicate finding issues require disposition: ' + key)
            if candidates:
                issue = candidates[0]
            else:
                issue = api(f'repos/{repo}/issues', 'POST', {
                    'title': current['title'], 'body': current['body'] + '\n\n' + marker,
                    'labels': current['labels']})
            receipt[key] = issue['html_url']
            save(receipt)
            decision['canonical_issue'] = issue['html_url']
            current = {'number': issue['number'], 'repo': repo}
        if decision.get('issue'):
            issue = api(f'repos/{repo}/issues/{current["number"]}')
            # Keep existing origin ancestry. A fresh standalone finding binds into the batch.
            parent_url = decision.get('origin_issue') or batch
            if not parent_url:
                raise ValueError('new work requires an existing retro-batch or origin issue')
            parent_repo, parent = issue_ref(parent_url)
            parent_issue = api(f'repos/{parent_repo}/issues/{parent}')
            if parent_url == batch and (parent_issue['state'] != 'open' or not parent_issue.get('title', '').startswith('retro-batch:')):
                raise ValueError('batch must be an open retro-batch container')
            children = []
            page = 1
            while True:
                rows = api(f'repos/{parent_repo}/issues/{parent}/sub_issues?per_page=100&page={page}')
                children.extend(rows)
                if len(rows) < 100:
                    break
                page += 1
            if not any(r['id'] == issue['id'] for r in children):
                api(f'repos/{parent_repo}/issues/{parent}/sub_issues', 'POST', {'sub_issue_id': issue['id']})
        # A resumed receipt always goes through a fresh canonical state read.
        refreshed = plan(state, decisions, fetch)
        if not any(p['id'] == key and p['action'] == 'queue' for p in refreshed):
            continue
        issue = api(f'repos/{repo}/issues/{current["number"]}')
        labels = {l['name'] for l in issue['labels']}
        if issue['state'] != 'open' or any(l.startswith('agent/') for l in labels):
            continue  # already queued/riding/held: never overwrite a lifecycle decision
        if not issue_body.get(issue.get('body') or '', 'Touches'):
            raise ValueError('cannot queue issue without Touches')
        api(f'repos/{repo}/issues/{current["number"]}/labels', 'POST', {'labels': ['agent-fix', 'agent/queued']})
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', required=True)
    parser.add_argument('--decisions', required=True)
    parser.add_argument('--receipts', required=True)
    parser.add_argument('--batch', help='existing open retro-batch issue URL for new standalone findings')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    state = json.loads(Path(args.state).read_text())
    decisions = json.loads(Path(args.decisions).read_text())
    p = Path(args.receipts)
    receipts = json.loads(p.read_text()) if p.exists() else {}
    for key, url in receipts.items():
        if key in decisions:
            decisions[key]['canonical_issue'] = url
    actions = plan(state, decisions)
    print(json.dumps(actions, indent=2))
    if args.apply:
        if any(a['action'] == 'create-and-queue' and not (decisions[a['id']].get('origin_issue') or args.batch) for a in actions):
            parser.error('new issues require --batch or origin_issue before filing')
        def save(values):
            tmp = p.with_suffix('.tmp')
            tmp.write_text(json.dumps(values, indent=2) + '\n')
            tmp.replace(p)
        apply(state, decisions, receipts, save, args.batch)
        Path(args.decisions).write_text(json.dumps(decisions, indent=2) + '\n')


if __name__ == '__main__':
    main()
