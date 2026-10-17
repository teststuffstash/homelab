"""Meaningful negatives for the offline request-shape report, not an API validator."""

import json
import unittest

from profile_probe import summarize


class ProfileProbeTests(unittest.TestCase):
    def body(self, **changes):
        return {"stream": True, "store": False, "input": [], **changes}

    def test_documented_shapes_do_not_claim_entitlement(self):
        for tools, inputs in [
            ([{"type": "namespace", "tools": [{"type": "function"}]}], []),
            ([], [{"type": "additional_tools", "tools": [{"type": "custom"}]}]),
        ]:
            with self.subTest(tools=tools):
                result = summarize(self.body(tools=tools, input=inputs), {})
                self.assertFalse(result["documented_blocker_observed"])
                self.assertFalse(result["full_profile_compatibility_verified"])

    def test_bare_functions_and_unsupported_fields_are_reported(self):
        result = summarize(self.body(tools=[{"type": "function"}], temperature=0,
                                     previous_response_id=None), {})
        self.assertEqual(result["ungrouped_function_or_custom_tools"], 1)
        self.assertEqual(result["unsupported_fields_present"], ["previous_response_id", "temperature"])
        self.assertTrue(result["documented_blocker_observed"])

    def test_nested_unsupported_tools_are_not_hidden(self):
        result = summarize(self.body(input=[{"type": "additional_tools", "tools": [
            {"type": "namespace", "tools": [{"type": "tool_search"}]}]}]), {})
        self.assertEqual(result["unsupported_tool_types_present"], ["tool_search"])
        self.assertTrue(result["documented_blocker_observed"])

    def test_required_modes_and_system_messages(self):
        for change in [{"store": True}, {"stream": False}, {"input": "hello"},
                       {"input": [{"type": "message", "role": "system"}]}]:
            with self.subTest(change=change):
                self.assertTrue(summarize(self.body(**change), {})["documented_blocker_observed"])

    def test_unknowns_and_values_do_not_escape(self):
        secret = "DUMMY-SECRET-DO-NOT-EXPORT"
        result = summarize(self.body(**{secret: secret}, tools=[
            {"type": secret, "name": secret}, {"type": "function", "description": secret}],
            input=[{"role": "user", "content": secret}]),
            {"Authorization": secret, "ChatGPT-Account-ID": secret, secret: secret})
        self.assertNotIn(secret, json.dumps(result))
        self.assertEqual(result["unknown_tool_or_input_shapes"], 1)
        self.assertTrue(result["account_header_present"])

    def test_malformed_and_deep_tools_are_bounded(self):
        nested = [{"type": "function"}]
        for _ in range(12):
            nested = [{"type": "namespace", "tools": nested}]
        for tools in [None, [{"type": []}], [{"type": "namespace"}], nested]:
            with self.subTest(tools=tools):
                self.assertGreater(summarize(self.body(tools=tools), {})["unknown_tool_or_input_shapes"], 0)


if __name__ == "__main__":
    unittest.main()
