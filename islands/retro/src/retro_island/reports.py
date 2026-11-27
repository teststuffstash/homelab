"""The `reports` world (specs/worlds/README.md): the strict reader of its manifest.

`specs/worlds/reports/manifest.json` is a JSON list of `{"path", "sha256"}` objects, each naming a
report by its path in this repo. A report is read in place, never copied; a missing field, an unknown
field or a field of the wrong type raises, and so does a report whose sha256 differs from the manifest's.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

ISLAND = Path(__file__).resolve().parent.parent.parent
REPO = ISLAND.parent.parent
MANIFEST = ISLAND / "specs" / "worlds" / "reports" / "manifest.json"

_FIELDS = {"path", "sha256"}


class ReportError(ValueError):
    """The manifest or a report does not match the world's definition."""


@dataclass(frozen=True)
class Report:
    path: str
    sha256: str
    text: str


def load_manifest(manifest: Path = MANIFEST) -> list[dict[str, str]]:
    raw = json.loads(Path(manifest).read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ReportError("manifest: expected a list")
    for i, obj in enumerate(raw):
        where = f"manifest[{i}]"
        if not isinstance(obj, dict):
            raise ReportError(f"{where}: expected an object")
        missing, unknown = _FIELDS - obj.keys(), obj.keys() - _FIELDS
        if missing:
            raise ReportError(f"{where}: missing field(s) {sorted(missing)}")
        if unknown:
            raise ReportError(f"{where}: unknown field(s) {sorted(unknown)}")
        for f in sorted(_FIELDS):
            if not isinstance(obj[f], str):
                raise ReportError(f"{where}.{f}: expected a string")
    return raw


def load(manifest: Path = MANIFEST, repo: Path = REPO) -> list[Report]:
    """Every report the manifest names, read from `repo` and checked against its sha256."""
    reports = []
    for obj in load_manifest(manifest):
        data = (Path(repo) / obj["path"]).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest != obj["sha256"]:
            raise ReportError(f"{obj['path']}: sha256 {digest} != manifest {obj['sha256']}")
        reports.append(Report(obj["path"], digest, data.decode("utf-8")))
    return reports
