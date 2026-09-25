# not-major-lane: the PR does not carry `major` — an ordinary PR handed to the script must be
# refused, or the handoff label would park a reflex-lane PR (C9 excludes `major/awaiting-human`).
.labels |= map(select(.name != "major"))
