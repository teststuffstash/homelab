#!/usr/bin/env python3
"""retro_guard_expr — the verdict of a PromQL-guarded retro series (homelab#3140).

Reads ONE Prometheus instant-query response (`/api/v1/query`) on stdin and exits with the
guard's verdict, which retro-argo.yaml's guard step branches on exactly as it branches on
`retro_pipeline.py prepare`:

    0  FIRE  — some sample is > 0: the series has work; the run rides
    3  QUIET — every sample is 0: a quiet week (the outcome=quiet push, nothing rides)
    1  FAIL  — no samples, a non-success status, or unparsable input: an ABSENT gauge is a
               broken exporter (or a dead Prometheus), never a quiet week — the run fails so
               RetroReportOverdue pages honestly instead of a silent quiet push forever
               (the same reasoning as the ledger guard's "0 tasks is a dead collector").

The query is the series' own (`guardExpr`); write it so that it yields a single 0/1 sample —
`max(<gauge>) > bool <threshold>` — and an empty vector only when the gauge is missing.
"""
import json
import sys

FIRE, QUIET, FAIL = 0, 3, 1


def verdict(text):
    try:
        body = json.loads(text)
    except ValueError:
        return FAIL, 'GUARD FAILED: unparsable Prometheus response (%d bytes) — an absent or dead Prometheus is a failed run, not a quiet week' % len(text)
    if not isinstance(body, dict) or body.get('status') != 'success':
        return FAIL, 'GUARD FAILED: Prometheus status %r — %s' % (
            body.get('status') if isinstance(body, dict) else None,
            body.get('error', 'no error text') if isinstance(body, dict) else 'not an object')
    data = body.get('data') or {}
    result = data.get('result')
    if data.get('resultType') == 'scalar' and isinstance(result, list) and len(result) == 2:
        result = [{'metric': {}, 'value': result}]
    if not isinstance(result, list) or not result:
        return FAIL, 'GUARD FAILED: the guard query returned NO samples — the gauge is absent (exporter down, metric renamed), which is a failed run, never a quiet week'
    values = []
    for sample in result:
        try:
            values.append(float(sample['value'][1]))
        except (KeyError, IndexError, TypeError, ValueError):
            return FAIL, 'GUARD FAILED: malformed sample in the guard query result: %r' % (sample,)
    if any(v != v for v in values):  # NaN
        return FAIL, 'GUARD FAILED: NaN sample in the guard query result'
    top = max(values)
    if top > 0:
        return FIRE, 'guard: FIRE — guard query max %g over %d sample(s)' % (top, len(values))
    return QUIET, 'GUARD REFUSED: quiet week — guard query max %g over %d sample(s); the window rolls forward' % (top, len(values))


def main():
    code, line = verdict(sys.stdin.read())
    print(line, file=sys.stderr if code == FAIL else sys.stdout)
    sys.exit(code)


if __name__ == '__main__':
    main()
