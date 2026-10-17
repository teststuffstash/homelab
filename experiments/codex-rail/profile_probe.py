"""Observe a pinned CLI's synthetic first request through the gateway (FU-270).

This is a partial, dated SIWC request-shape comparison, NOT an upstream emulator,
credential validator, entitlement check, or live canary. The fake upstream still
accepts the request. Only fixed field names, counts and booleans leave the observer;
no prompt, tool name/arguments, header value, token, or arbitrary key is exported.
Run in the gateway's locked environment; see README.md.
"""

from __future__ import annotations

import argparse
import json

# Official preview restrictions checked 2026-10-17. This is deliberately NOT
# imported by production. Unknown tools remain unverified, never assumed supported.
UNSUPPORTED_FIELDS = frozenset({
    "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata",
    "moderation", "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier",
    "temperature", "top_logprobs", "top_p", "truncation", "user", "previous_response_id",
})
UNSUPPORTED_TOOLS = frozenset({
    "image_generation", "file_search", "code_interpreter", "computer", "computer_use_preview",
    "mcp", "tool_search", "programmatic_tool_calling",
})
KNOWN_TOOLS = UNSUPPORTED_TOOLS | {"function", "custom", "namespace", "web_search", "web_search_preview"}


def summarize(body: dict, headers: dict) -> dict:
    """Compare only the documented restrictions observable in this request.

    Unknown structures are counted, not reflected. Namespace children live in
    `tools`; additional_tools items also carry `tools`. We do not interpret schemas.
    """
    kinds: dict[str, int] = {}
    blocked: set[str] = set()
    ungrouped = 0
    unknown = 0

    def visit(items, grouped=False, depth=0):
        nonlocal ungrouped, unknown
        if not isinstance(items, list) or depth > 8:
            unknown += 1
            return
        for tool in items:
            raw = tool.get("type") if isinstance(tool, dict) else None
            kind = raw if isinstance(raw, str) and raw in KNOWN_TOOLS else "unknown"
            kinds[kind] = kinds.get(kind, 0) + 1
            if kind == "unknown":
                unknown += 1
            elif kind in UNSUPPORTED_TOOLS:
                blocked.add(kind)
            elif kind in {"function", "custom"} and not grouped:
                ungrouped += 1
            elif kind == "namespace":
                visit(tool.get("tools"), grouped=True, depth=depth + 1)

    visit(body.get("tools", []))
    inputs = body.get("input")
    system_message = False
    if isinstance(inputs, list):
        for item in inputs:
            if not isinstance(item, dict):
                unknown += 1
                continue
            if item.get("type") == "additional_tools":
                visit(item.get("tools"), grouped=True)
            if item.get("role") == "system":
                system_message = True
    unsupported = sorted(UNSUPPORTED_FIELDS.intersection(body))
    required = body.get("store") is False and body.get("stream") is True and isinstance(inputs, list)
    return {
        "stream_store_input_shape_matches": required,
        "unsupported_fields_present": unsupported,
        "tool_type_counts": dict(sorted(kinds.items())),
        "unsupported_tool_types_present": sorted(blocked),
        "ungrouped_function_or_custom_tools": ungrouped,
        "system_message_present": system_message,
        "unknown_tool_or_input_shapes": unknown,
        "account_header_present": "chatgpt-account-id" in {k.lower() for k in headers},
        "documented_blocker_observed": bool(not required or unsupported or blocked or ungrouped or system_message),
        "full_profile_compatibility_verified": False,
    }


def main():
    # Import only for the native run: the pure structural checks need no dependencies.
    from compat import run

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", required=True)
    parser.add_argument("--expect-version", required=True)
    args = parser.parse_args()
    observations = []
    evidence = run(args.codex, args.expect_version,
                   request_observer=lambda body, headers: observations.append(summarize(body, headers)))
    print(json.dumps({"fixture": evidence, "siwc_request_shape_observations": observations}, indent=2))


if __name__ == "__main__":
    main()
