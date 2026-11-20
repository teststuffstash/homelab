"""The island's strict read (goal #3490 pin 5): an answer lacking a field its page's schema requires is unreadable.

A shape mirrors one schema part: a dict is an object whose keys are its required fields, a one-element
list stands for each element of a list, a type is a leaf, and `Nullable(shape)` is a field the schema
types as `[<type>, "null"]` — present always, null allowed. Nothing here substitutes a default.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Nullable:
    shape: object


def lacking(value: object, shape: object, where: str = "") -> str | None:
    """The first required field `value` lacks — `without `<path>`` — or holds as null (where the schema allows
    no null) or as the wrong type — `with `<path>` not a <type>`; None when every required field is there."""
    if isinstance(shape, Nullable):
        return None if value is None else lacking(value, shape.shape, where)
    if isinstance(shape, dict):
        if not isinstance(value, dict):
            return f"with `{where.lstrip('.') or '(the answer)'}` not an object"
        for key, sub in shape.items():
            if key not in value:
                return f"without `{f'{where}.{key}'.lstrip('.')}`"
            found = lacking(value[key], sub, f"{where}.{key}")
            if found:
                return found
        return None
    if isinstance(shape, list):
        if not isinstance(value, list):
            return f"with `{where.lstrip('.') or '(the answer)'}` not a list"
        return next((f for i, item in enumerate(value) if (f := lacking(item, shape[0], f"{where}[{i}]"))), None)
    if shape is int and isinstance(value, bool):  # JSON true is not a number
        return f"with `{where.lstrip('.')}` not a int"
    return None if isinstance(value, shape) else f"with `{where.lstrip('.')}` not a {shape.__name__}"  # type: ignore[union-attr]
