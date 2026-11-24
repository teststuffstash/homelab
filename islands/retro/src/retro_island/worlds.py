"""Recorded worlds (specs/worlds/README.md §Recorded worlds): the strict reader of one entry.

An entry is one JSON file `specs/worlds/<world>/<entry>.json`. A missing field, an unknown field or a
field of the wrong type raises; nothing is defaulted.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

WORLDS = Path(__file__).resolve().parent.parent.parent / "specs" / "worlds"

_TOP = {"surface", "request", "recorded_at", "recorded_by", "status", "body"}
_REQUEST = {"method", "path", "query"}
_RFC3339_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")


class EntryError(ValueError):
    """The entry does not match the shape the worlds page fixes."""


@dataclass(frozen=True)
class Request:
    method: str
    path: str
    query: dict[str, str]


@dataclass(frozen=True)
class Entry:
    surface: str
    request: Request
    recorded_at: str
    recorded_by: str
    status: int | None
    body: str | None


def _keys(obj: object, want: set[str], where: str) -> dict:
    if not isinstance(obj, dict):
        raise EntryError(f"{where}: expected an object")
    missing, unknown = want - obj.keys(), obj.keys() - want
    if missing:
        raise EntryError(f"{where}: missing field(s) {sorted(missing)}")
    if unknown:
        raise EntryError(f"{where}: unknown field(s) {sorted(unknown)}")
    return obj


def _str(v: object, where: str) -> str:
    if not isinstance(v, str):
        raise EntryError(f"{where}: expected a string")
    return v


def parse(text: str) -> Entry:
    raw = _keys(json.loads(text), _TOP, "entry")
    req = _keys(raw["request"], _REQUEST, "request")
    query = req["query"]
    if not isinstance(query, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in query.items()):
        raise EntryError("request.query: expected an object of strings")
    at = _str(raw["recorded_at"], "recorded_at")
    if not _RFC3339_UTC.match(at):
        raise EntryError("recorded_at: expected UTC RFC 3339 (…Z)")
    status, body = raw["status"], raw["body"]
    if (status is None) != (body is None):
        raise EntryError("status and body must both be null or both set")
    if status is not None:
        if isinstance(status, bool) or not isinstance(status, int):
            raise EntryError("status: expected an integer or null")
        _str(body, "body")
    return Entry(
        surface=_str(raw["surface"], "surface"),
        request=Request(_str(req["method"], "request.method"), _str(req["path"], "request.path"), dict(query)),
        recorded_at=at,
        recorded_by=_str(raw["recorded_by"], "recorded_by"),
        status=status,
        body=body,
    )


def load_path(path: Path) -> Entry:
    return parse(Path(path).read_text(encoding="utf-8"))


def load(world: str, entry: str, root: Path = WORLDS) -> Entry:
    return load_path(root / world / f"{entry}.json")
