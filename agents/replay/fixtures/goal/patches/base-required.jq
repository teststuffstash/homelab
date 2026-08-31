# base-required — a task/goal + agent/queued issue whose body has NO Base: line.
# The goal-decompose block must refuse it: the orphan line names both legal values
# and links the consumer card. No decompose unit is emitted.
. + [
  {
    "number": 300,
    "title": "Goal without Base: line",
    "labels": [
      {"name": "task/goal"},
      {"name": "agent-fix"},
      {"name": "agent/queued"}
    ],
    "body": "Budget: 12\nVerdict-authority: human\n"
  }
]