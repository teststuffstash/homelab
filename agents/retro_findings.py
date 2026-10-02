#!/usr/bin/env python3
"""Consolidate retro candidates and reconcile current work, using read-only GitHub GETs.

Model reports are evidence, never acceptance authority. Decisions are separately supplied
operator/cross-review records. This program prepares dispositions; it never queues work.
"""
import argparse
import copy
import datetime as dt
import hashlib
import json
import re
import subprocess
from pathlib import Path

BLOCK = re.compile(r'^```retro-findings-json\s*\n(.*?)^```\s*$', re.M | re.S)
REF = re.compile(r'https://github\.com/([\w.-]+/[\w.-]+)/(issues|pull)/(\d+)$')


def identity(mechanism, surface):
    normalized = [re.sub(r'\s+', ' ', x.strip().lower()) for x in (mechanism, surface)]
    return 'rf-' + hashlib.sha256(json.dumps(normalized).encode()).hexdigest()[:16]


def extract(text):
    blocks = BLOCK.findall(text)
    if len(blocks) != 1:
        raise ValueError('report requires exactly one retro-findings-json block')
    data = json.loads(blocks[0])
    if not isinstance(data, dict) or data.get('schema_version') != 1 or not isinstance(data.get('findings'), list):
        raise ValueError('invalid finding envelope')
    for item in data['findings']:
        if not isinstance(item, dict):
            raise ValueError('finding must be an object')
        allowed = {'mechanism', 'surface', 'summary', 'evidence', 'related_work'}
        if set(item) - allowed:
            raise ValueError('candidate contains unsupported fields (acceptance belongs in decisions)')
        for field in ('mechanism', 'surface', 'summary'):
            if not isinstance(item.get(field), str) or not item[field].strip():
                raise ValueError('missing finding ' + field)
        for field in ('evidence', 'related_work'):
            values = item.get(field, [])
            if not isinstance(values, list) or any(not isinstance(v, str) or not v.startswith('https://') for v in values):
                raise ValueError('invalid ' + field)
        if not item.get('evidence'):
            raise ValueError('finding requires occurrence evidence')
        if any(not REF.fullmatch(v) for v in item.get('related_work', [])):
            raise ValueError('related_work requires canonical GitHub issue/PR URLs')
    return data['findings']


def combine(previous, reports, now):
    result = copy.deepcopy(previous or {'schema_version': 1, 'findings': []})
    if result.get('schema_version') != 1:
        raise ValueError('unsupported previous state schema')
    by_id = {f['id']: f for f in result['findings']}
    for model, report_id, candidates in reports:
        for candidate in candidates:
            key = identity(candidate['mechanism'], candidate['surface'])
            if key not in by_id:
                by_id[key] = dict(candidate, id=key, first_seen_at=now, occurrences=[], related_work=[])
            finding = by_id[key]
            occurrence = {'model': model, 'report': report_id, 'summary': candidate['summary'], 'evidence': candidate['evidence']}
            if occurrence not in finding['occurrences']:
                finding['occurrences'].append(occurrence)
            finding['related_work'] = sorted(set(finding['related_work']) | set(candidate.get('related_work', [])))
    result['findings'] = sorted(by_id.values(), key=lambda x: x['id'])
    result['checked_at'] = now
    return result


def github_get(url):
    match = REF.fullmatch(url)
    if not match:
        return {'error': 'not a canonical GitHub reference'}
    repo, kind, number = match.groups()
    endpoint = f'repos/{repo}/{"pulls" if kind == "pull" else "issues"}/{number}'
    try:
        proc = subprocess.run(['gh', 'api', '--method', 'GET', endpoint], text=True, capture_output=True, timeout=45)
        if proc.returncode:
            return {'error': 'GitHub read failed'}
        data = json.loads(proc.stdout)
        if data.get('state') not in ('open', 'closed'):
            return {'error': 'GitHub response missing state'}
        return {'state': data['state'], 'merged_at': data.get('merged_at'), 'updated_at': data.get('updated_at'), 'labels': [x['name'] for x in data.get('labels', [])]}
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError):
        return {'error': 'GitHub read unavailable'}


def reconcile(state, decisions, fetch, now):
    """Decision evidence is supplied separately; mere references never establish coverage.

    decisions maps finding IDs to {disposition, evidence:[URLs], matched_work:[URLs],
    canonical_issue:URL, accepted_by:str, accepted_at:ISO}. Only matched_work is treated
    as substantively covering this mechanism. Queue readiness still requires a live open
    canonical issue and never causes a write. Re-run immediately before any queue act.
    """
    for finding in state['findings']:
        decision = decisions.get(finding['id'], finding.get('decision', {}))
        if not isinstance(decision, dict):
            raise ValueError('decision must be an object')
        finding['decision'] = copy.deepcopy(decision)
        evidence = decision.get('evidence', [])
        if not isinstance(evidence, list) or any(not isinstance(v, str) or not v.startswith('https://') for v in evidence):
            raise ValueError('decision evidence must be URLs')
        matched = decision.get('matched_work', [])
        if not isinstance(matched, list) or any(not isinstance(v, str) or not REF.fullmatch(v) for v in matched):
            raise ValueError('matched_work must contain canonical GitHub references')
        canonical = decision.get('canonical_issue')
        if canonical and (not REF.fullmatch(canonical) or '/issues/' not in canonical):
            raise ValueError('canonical_issue must be a GitHub issue URL')
        urls = set(finding['related_work']) | set(matched) | ({canonical} if canonical else set())
        reads = {url: fetch(url) for url in sorted(urls)}
        status, reason = 'insufficient_evidence', 'Awaiting substantive cross-review of candidate and related work.'
        requested = decision.get('disposition')
        if requested in ('disproved', 'verified') and evidence:
            status, reason = requested, 'Explicit evidence-backed adjudication; occurrence history retained.'
        elif any('error' in reads[u] for u in matched):
            reason = 'Matched work could not be read; do not queue duplicate work.'
        elif matched and evidence:
            if any(reads[u].get('merged_at') for u in matched):
                status, reason = 'implemented_unverified', 'Substantively matched PR merged; deployment/effectiveness not yet verified.'
            elif any(reads[u].get('state') == 'open' for u in matched):
                status, reason = 'covered_by_existing_work', 'Cross-review matched this mechanism to open work.'
            else:
                reason = 'Matched work closed without implementation evidence; closure alone is insufficient.'
        elif requested == 'new_work_needed' and evidence and any(
                value.get('merged_at') and value['merged_at'] > decision.get('accepted_at', '')
                for url, value in reads.items() if url in finding['related_work']):
            reason = 'Related PR merged after adjudication; recheck its substance before filing or queueing.'
        elif requested == 'new_work_needed' and evidence:
            status, reason = 'new_work_needed', 'Cross-review confirms a remaining gap; current linked work recorded below.'
        accepted = bool(decision.get('accepted_by') and decision.get('accepted_at') and canonical and evidence)
        ready = bool(status == 'new_work_needed' and accepted and reads.get(canonical, {}).get('state') == 'open' and not any('error' in value for value in reads.values()))
        finding['reconciliation'] = {'checked_at': now, 'disposition': status, 'reason': reason, 'evidence': evidence, 'work': reads, 'accepted': accepted, 'canonical_issue': canonical, 'queue_prepared': ready, 'queue_action': 'Existing authorized queue decider must recheck immediately before queueing.' if ready else None}
    state['checked_at'] = now
    return state


def markdown(state):
    lines = ['# Retro finding reconciliation', '', 'Checked: ' + state['checked_at'], '', 'Occurrence evidence is historical; dispositions describe current action status.', '']
    for finding in state['findings']:
        review = finding['reconciliation']
        lines.extend([f"## {finding['id']}: {finding['summary']}", '', f"**{review['disposition']}** — {review['reason']}", '', f"Mechanism: `{finding['mechanism']}`; surface: `{finding['surface']}`.", ''])
        for occurrence in finding['occurrences']:
            lines.append(f"- {occurrence['model']} / {occurrence['report']}: " + ', '.join(occurrence['evidence']))
        lines.append('')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', action='append', default=[], metavar='MODEL=PATH')
    parser.add_argument('--previous')
    parser.add_argument('--decisions', help='separate evidence-backed cross-review JSON keyed by finding ID')
    parser.add_argument('--github', action='store_true', help='read current GitHub state (GET only)')
    parser.add_argument('--output', required=True)
    parser.add_argument('--markdown', required=True)
    args = parser.parse_args()
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    previous = json.loads(Path(args.previous).read_text()) if args.previous else None
    decisions = json.loads(Path(args.decisions).read_text()) if args.decisions else {}
    reports = []
    for spec in args.report:
        model, path = spec.split('=', 1)
        text = Path(path).read_text()
        report_id = hashlib.sha256(text.encode()).hexdigest()
        reports.append((model, report_id, extract(text)))
    state = combine(previous, reports, now)
    fetch = github_get if args.github else lambda url: {'error': 'live GitHub reads disabled'}
    reconcile(state, decisions, fetch, now)
    Path(args.output).write_text(json.dumps(state, indent=2) + '\n')
    Path(args.markdown).write_text(markdown(state) + '\n')


if __name__ == '__main__':
    main()
