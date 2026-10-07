# workflow-pin-revert-lock-candidate

The lock shape of the FU-1990 chain's candidate read (2026-10-07, class 7 majors armed): a merged
PR whose every file is a `devbox.lock` is a revert candidate; a newer unrelated merge, a `revert-*`
merge and a lock PR that also carries a fixture (worker-adapted, outside the class) are walked past.
Contract prose in `fixture.yaml`; the sibling `workflow-pin-revert-candidate` pins the workflow case.
