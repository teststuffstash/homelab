# awaiting-human-not-armed: the pre-existing exclusion (a PR a human deliberately parked) — pinned
# beside the new one so the pair reads as one rule: the major lane is never self-armed.
map(if .number == 90 then .labels += [{"name": "major/awaiting-human"}] else . end)
