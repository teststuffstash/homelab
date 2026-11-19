"""Hand-written write answers validate against GitHub's REST description (goal #3490 pin 3): unlabelled.

Every `writes/<op>.<status>.json` of a recorded world is checked against `schemas/<op>.<status>.json`,
the response schema scripts/record_world.py extracted from github/rest-api-description at the commit
`provenance.yaml` names. A control answer with one required field removed must fail the same check.
"""

import copy
import json

import pytest
from jsonschema import Draft202012Validator

from .world import WORLDS, parse_provenance

RECORDED = ["pr-handoff", "pr-board"]


def answers() -> list:
    out = []
    for world in RECORDED:
        prov = parse_provenance((WORLDS / world / "provenance.yaml").read_text("utf-8"))
        for w in prov["writes"]:
            out += [pytest.param(world, f"{w['op']}.{s}.json", id=f"{world}/{w['op']}.{s}") for s in w.get("statuses", [])]
    return out


def validator(world: str, name: str) -> Draft202012Validator:
    schema = json.loads((WORLDS / world / "schemas" / name).read_text("utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def _resolve(schema: dict, node: dict) -> dict:
    while "$ref" in node:
        node = schema["$defs"][node["$ref"].removeprefix("#/$defs/")]
    return node


def drop_a_required_field(schema: dict, answer: object) -> tuple[object, str]:
    """The answer with the first required field its schema names removed (in an array: from the first item)."""
    node, target, where = _resolve(schema, schema), copy.deepcopy(answer), ""
    if isinstance(target, list):
        node, holder, where = _resolve(schema, node["items"]), target[0], "[0]."
    else:
        holder = target
    required = [k for k in node.get("required", []) if k in holder]
    if not required:
        pytest.skip(f"the description's schema requires no field ({node.get('title', '?')}) — any object validates, no control possible")
    del holder[required[0]]
    return target, where + required[0]


@pytest.mark.parametrize("world, name", answers())
def test_hand_written_answer_validates_against_the_rest_description(world, name):
    answer = json.loads((WORLDS / world / "writes" / name).read_text("utf-8"))
    errors = [f"{list(e.absolute_path)}: {e.message[:200]}" for e in validator(world, name).iter_errors(answer)]
    assert not errors


@pytest.mark.parametrize("world, name", answers())
def test_a_required_field_removed_fails_the_validation(world, name):
    v = validator(world, name)
    answer = json.loads((WORLDS / world / "writes" / name).read_text("utf-8"))
    control, removed = drop_a_required_field(v.schema, answer)
    assert not v.is_valid(control), f"{name} without {removed} still validates — the check cannot fail"


def test_the_one_gh_command_write_is_an_exit_status():
    prov = parse_provenance((WORLDS / "pr-handoff" / "provenance.yaml").read_text("utf-8"))
    merge = [w for w in prov["writes"] if w["method"] == "gh"]
    assert [(w["op"], w["exit"], w.get("statuses")) for w in merge] == [("pr-merge-auto", 0, None)]
