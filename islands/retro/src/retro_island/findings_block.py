"""RETRO-FINDINGS-BLOCK (specs/findings.md): a report's text → its candidate findings, or the one error.

Pure. The shapes (schema_version, the findings bound, the candidate's fields, the evidence and
related_work patterns) and the error strings are read from `specs/findings.schema.json`, never
re-declared here. Same outcomes as the old member `agents/retro_findings.py` `extract`.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

SCHEMA = json.loads((Path(__file__).resolve().parent.parent.parent / "specs" / "findings.schema.json").read_text(encoding="utf-8"))
_DEFS = SCHEMA["$defs"]
_ENVELOPE, _CANDIDATE = _DEFS["envelope"], _DEFS["candidate"]
ERRORS = list(_ENVELOPE["x-errors"])  # the keys, in schema order


def _error(prefix: str) -> str:
    (key,) = [k for k in ERRORS if k.startswith(prefix)]
    return key


E_BLOCK = _error("report requires")
E_ENVELOPE = _error("invalid finding")
E_FIELDS = _error("candidate contains")
E_EVIDENCE = _error("finding requires")
E_RELATED = _error("related_work requires")

_BLOCK = re.compile(r"^```retro-findings-json\s*\n(.*?)^```\s*$", re.M | re.S)
_REF = re.compile(_DEFS["github_ref"]["pattern"])
_EVIDENCE = _CANDIDATE["properties"]["evidence"]
_EVIDENCE_URL = re.compile(_EVIDENCE["items"]["pattern"])


class FindingsBlockError(ValueError):
    """Carries exactly one of ERRORS as its message."""


def _candidate(item: object) -> None:
    if not isinstance(item, dict):
        raise FindingsBlockError(E_ENVELOPE)
    props = _CANDIDATE["properties"]
    if not _CANDIDATE["additionalProperties"] and item.keys() - props.keys():
        raise FindingsBlockError(E_FIELDS)
    for f in _CANDIDATE["required"]:
        v = item.get(f)
        if f != "evidence" and (not isinstance(v, str) or len(v.strip()) < props[f]["minLength"]):
            raise FindingsBlockError(E_ENVELOPE)
    for f in ("evidence", "related_work"):
        v = item.get(f, [])
        if not isinstance(v, list) or any(not isinstance(u, str) or not _EVIDENCE_URL.match(u) for u in v):
            raise FindingsBlockError(E_ENVELOPE)
    if len(item.get("evidence", [])) < _EVIDENCE["minItems"]:
        raise FindingsBlockError(E_EVIDENCE)
    if any(not _REF.fullmatch(u) for u in item.get("related_work", [])):
        raise FindingsBlockError(E_RELATED)


def extract(text: str) -> list[dict]:
    """The candidates of the report's one block; raises FindingsBlockError(<one of ERRORS>)."""
    blocks = _BLOCK.findall(text)
    if len(blocks) != 1:
        raise FindingsBlockError(E_BLOCK)
    try:
        data = json.loads(blocks[0])
    except ValueError:
        raise FindingsBlockError(E_ENVELOPE) from None
    findings = data.get("findings") if isinstance(data, dict) else None
    if (
        not isinstance(findings, list)
        or data.get("schema_version") != _ENVELOPE["properties"]["schema_version"]["const"]
        or len(findings) > _ENVELOPE["properties"]["findings"]["maxItems"]
    ):
        raise FindingsBlockError(E_ENVELOPE)
    for item in findings:
        _candidate(item)
    return findings
