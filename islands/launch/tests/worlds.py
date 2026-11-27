"""The strict reader for the gateway-seam worlds (Goal #3480 pins 1–2; homelab#3483).

`load_world(id)` returns one world file; `World.get(*path)` returns a field the caller asks for and
raises when the file lacks it — never a default. `validate_body` checks a world's `body` against the
supplier's schema (`gateway/specs/endpoints/sessions.schema.json`, read in place, never copied).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import jsonschema

ISLAND = Path(__file__).resolve().parent.parent
WORLDS = ISLAND / "specs" / "worlds" / "gateway"
SUPPLIER_SCHEMA = ISLAND.parent.parent / "gateway" / "specs" / "endpoints" / "sessions.schema.json"

# world id → the part of the supplier's schema its body must satisfy
SCHEMA_PART = {
    "gw-dispatch-bound": ("post", "dispatch_bound"),
    "gw-dispatch-unbound": ("post", "dispatch"),
    "gw-defer": ("post", "defer"),
    "gw-error": ("$defs", "error_envelope"),
}


class WorldError(Exception):
    """An unknown world, or a field the world file lacks."""


@dataclass(frozen=True)
class World:
    id: str
    data: dict[str, Any]

    def get(self, *path: str) -> Any:
        """The value at `path` (e.g. `get("body", "session", "id")`); a missing key is an error."""
        node: Any = self.data
        for i, key in enumerate(path):
            if not isinstance(node, dict) or key not in node:
                raise WorldError(f"world {self.id}: no field {'.'.join(path[: i + 1])!r}")
            node = node[key]
        return node


def world_ids() -> list[str]:
    return sorted(p.stem for p in WORLDS.glob("*.json"))


def load_world(world_id: str) -> World:
    path = WORLDS / f"{world_id}.json"
    if world_id not in SCHEMA_PART or not path.is_file():
        raise WorldError(f"unknown gateway world {world_id!r}; known: {', '.join(world_ids())}")
    data = json.loads(path.read_text(encoding="utf-8"))
    for key in ("provenance", "status", "body"):
        if key not in data:
            raise WorldError(f"world {world_id}: file lacks {key!r}")
    return World(world_id, data)


def supplier_schema() -> dict[str, Any]:
    return json.loads(SUPPLIER_SCHEMA.read_text(encoding="utf-8"))


def part_schema(world_id: str) -> dict[str, Any]:
    """The schema part for `world_id`, self-contained over the supplier's `$defs`/`post`."""
    schema = supplier_schema()
    node: Any = schema
    for key in SCHEMA_PART[world_id]:
        node = node[key]
    node = json.loads(json.dumps(node))
    return {**node, "$defs": schema["$defs"], "post": schema["post"]}


def validate_body(world: World, body: dict[str, Any] | None = None) -> list[str]:
    """Validation error messages of `body` (default: the world's own) against its schema part."""
    validator = jsonschema.Draft202012Validator(
        part_schema(world.id), format_checker=jsonschema.FormatChecker()
    )
    body = world.get("body") if body is None else body
    problems = [e.message for e in validator.iter_errors(body)]
    if world.id == "gw-error":
        problems += _error_class_problems(world, body)
    return sorted(problems)


def _error_class_problems(world: World, body: dict[str, Any]) -> list[str]:
    """The error world names a class the supplier defines, with the status the supplier gives it."""
    errors = supplier_schema()["errors"]
    code = body.get("error", {}).get("code") if isinstance(body, dict) else None
    problems = []
    if code != "tokenreview-transient":
        problems.append(f"error.code {code!r} is not 'tokenreview-transient'")
    if code not in errors:
        problems.append(f"error.code {code!r} is not a class of the supplier's errors")
    elif world.get("status") != errors[code]["status"]:
        problems.append(f"status {world.get('status')!r} != supplier status {errors[code]['status']}")
    return problems


STACKS = ISLAND / "specs" / "worlds" / "stacks"
STACK_REQUIRED = ("name", "repos", "mainRepo", "routerMode")


def load_stack_world(world_id: str) -> World:
    """A recorded stack row (`stack-platform`), read strictly: provenance with the commit, and the
    row's required fields — a missing one is an error, never a default."""
    path = STACKS / f"{world_id}.json"
    if not path.is_file():
        raise WorldError(f"unknown stack world {world_id!r}")
    world = World(world_id, json.loads(path.read_text(encoding="utf-8")))
    for key in ("source", "row", "commit"):
        world.get("provenance", key)
    for key in STACK_REQUIRED:
        world.get("row", key)
    return world
