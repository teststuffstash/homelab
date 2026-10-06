# annotations-outside — the failing check's annotation names a path OUTSIDE the declared Touches
# (`tofu/main.tf` vs `agents/coordinator-scan.sh, agents/replay/fixtures/goal`): the red is
# inherited from master in a file the PR does not touch, so it is not the PR's round to spend.
.[0].path = "tofu/main.tf"
