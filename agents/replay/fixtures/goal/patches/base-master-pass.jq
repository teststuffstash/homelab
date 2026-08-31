# base-master-pass — a task/goal + agent/queued issue whose body declares `Base: master`.
# The goal-decompose block must pass it: the decompose unit is emitted, no refusal.
# Base: master being explicit is the point — the choice is legal.
. + [
  {
    "number": 301,
    "title": "Goal with Base: master",
    "labels": [
      {"name": "task/goal"},
      {"name": "agent-fix"},
      {"name": "agent/queued"}
    ],
    "body": "Budget: 12\nVerdict-authority: human\nBase: master\n"
  }
]