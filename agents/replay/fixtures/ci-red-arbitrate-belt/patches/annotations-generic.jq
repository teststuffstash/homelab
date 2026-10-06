# annotations-generic — the ONLY annotation is Actions' generic failure annotation
# (`Process completed with exit code 1`, `path: .github`), which names no file. It is attached to
# every failed job, so it is not evidence that the red is the PR's: the belt must FAIL OPEN and
# escalate (reviewer finding 1, round 2 — counting it made `belt_paths` non-empty on nearly every
# red and HELD a real in-footprint red).
.[0].path = ".github"
