#!/usr/bin/env bash
# Custom governance-lint for the non-dot-meta fixture — tests that a GOVERNANCE entry
# escaping a non-dot metacharacter (\+) is correctly unescaped to a literal `+`.
# The sibling guarded_paths() uses a capture-group form that handles any character;
# governance_paths() must use the same form, not the dot-only s/\././g.
GOVERNANCE='^(\.github/|something\+else$)'