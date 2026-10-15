# add-c-members-new — `add-c-members` PLUS a SECOND undispositioned member (#303). The row that
# uses it carries the SAME `state-fp:goal-checkpoint-c:` marker as `goal-checkpoint-c-held`
# (hash of the set `#301`), so the current set `#301 #303` differs from the recorded one and the
# clause re-arms: ONE unit. This is the row that keeps the hold from becoming a permanent silence
# — the #2477 `goal-checkpoint-b-verdict-rearms` shape, on the member SET instead of a PR state.
. + [
  {
    "number": 301,
    "title": "bare tree member — machine-doable path",
    "labels": [],
    "body": "Touches: src/thing.py\n",
    "parent": { "number": 29 }
  },
  {
    "number": 302,
    "title": "adopted member — already released",
    "labels": [ { "name": "agent/queued" } ],
    "body": "Touches: src/other.py\n",
    "parent": { "number": 29 }
  },
  {
    "number": 303,
    "title": "bare tree member — the NEW one",
    "labels": [],
    "body": "Touches: src/third.py\n",
    "parent": { "number": 29 }
  }
]
