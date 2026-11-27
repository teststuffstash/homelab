"""Gateway-seam worlds: whole files, validated against the supplier's schema; the strict reader.

Unlabelled on purpose — these prove the fixtures and the reader, not a spec row (homelab#3483).
"""

from __future__ import annotations

import copy

import jsonschema
import pytest

from worlds import SCHEMA_PART, World, WorldError, load_world, supplier_schema, world_ids

IDS = ["gw-defer", "gw-dispatch-bound", "gw-dispatch-unbound", "gw-error"]
PLACEHOLDER_TOKEN = "gws_" + "A" * 32


def test_the_four_worlds_exist() -> None:
    assert world_ids() == IDS


@pytest.mark.parametrize("world_id", IDS)
def test_world_body_validates_against_the_supplier_schema(world_id) -> None:
    world = load_world(world_id)
    assert validate(world) == []
    assert isinstance(world.get("status"), int)
    assert world.get("provenance", "kind") == "hand-written"


def validate(world, body=None):
    from worlds import validate_body

    return validate_body(world, body)


@pytest.mark.parametrize("world_id", IDS)
def test_validation_bites_when_a_required_property_is_removed(world_id) -> None:
    world = load_world(world_id)
    schema_required = {
        "gw-dispatch-bound": "model",
        "gw-dispatch-unbound": "env",
        "gw-defer": "reason",
        "gw-error": "error",
    }[world_id]
    body = copy.deepcopy(world.get("body"))
    del body[schema_required]
    assert validate(world, body) != []


def test_error_world_bites_on_a_wrong_code_or_status() -> None:
    world = load_world("gw-error")
    assert world.get("body", "error", "code") == "tokenreview-transient"
    assert world.get("status") == supplier_schema()["errors"]["tokenreview-transient"]["status"]
    wrong_code = copy.deepcopy(world.get("body"))
    wrong_code["error"]["code"] = "session-not-found"
    assert validate(world, wrong_code) != []
    unknown = copy.deepcopy(world.get("body"))
    unknown["error"]["code"] = "no-such-class"
    assert validate(world, unknown) != []
    wrong_status = World(world.id, {**world.data, "status": 404})
    assert validate(wrong_status) != []


def test_supplier_bound_part_requires_only_what_it_declares() -> None:
    """The supplier's bound part is satisfiable: `rail_choice` is required beside `session`, not in it."""
    part = supplier_schema()["post"]["dispatch_bound"]
    assert "rail_choice" in part["required"]
    assert "rail_choice" not in part["properties"]["session"]["required"]
    jsonschema.Draft202012Validator.check_schema(supplier_schema())


def test_every_world_has_a_schema_part() -> None:
    assert sorted(SCHEMA_PART) == IDS


def test_unknown_world_is_an_error() -> None:
    with pytest.raises(WorldError, match="unknown gateway world"):
        load_world("gw-nope")


def test_missing_field_is_an_error_never_a_default() -> None:
    world = load_world("gw-defer")
    assert world.get("body", "retry_after_s") == 120
    with pytest.raises(WorldError, match="no field 'body.nope'"):
        world.get("body", "nope")


def test_no_world_holds_a_real_credential() -> None:
    unbound = load_world("gw-dispatch-unbound")
    assert unbound.get("body", "session", "token") == PLACEHOLDER_TOKEN
    assert set(unbound.get("body", "env").values()) <= {
        PLACEHOLDER_TOKEN,
        "sonnet",
        unbound.get("body", "env", "ANTHROPIC_BASE_URL"),
    }
