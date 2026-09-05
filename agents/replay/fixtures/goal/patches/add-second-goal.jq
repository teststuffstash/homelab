# add-second-goal — a SECOND open funded goal (#123) in the same repo plus a bare, unlabelled
# native descendant of it (#303). Two goals is the multi-goal shape the #1249 misfires happened
# in; the row asserts the lane walks BOTH goals (goal #123 gets its own assembly probe) and that
# neither of them queues #303 — filing is inert, ADR-122 (1).
#
# It used to pin the RETIRED walk's own goals match (`case " $goals " in` fails on the newline-
# separated `goals`, so a member under the 2nd goal was silently skipped). That code is gone;
# the world survives it.
. + [
  {
    "number": 123,
    "title": "Goal: second open goal for two-goal test",
    "labels": [
      {
        "name": "task/goal"
      }
    ],
    "body": "Second open goal.\n\nBudget: 8\n"
  },
  {
    "number": 303,
    "title": "bare tree member — resolves to second goal",
    "labels": [],
    "body": "Touches: src/other.py\n",
    "parent": {
      "number": 123
    }
  }
]