# workflow-pin-revert-lock-flake-candidate

The lock shape with the box flake (2026-10-10, class 13): the weekly `devbox-update` merge of
`devbox.lock` + `mgmt/nixos/flake.lock` is the candidate, picked over an older lock-only merge; a
newer merge pairing the flake lock with `flake.nix` is walked past (an owned edit, not a re-resolve).
Contract prose in `fixture.yaml`; the sibling `workflow-pin-revert-lock-candidate` pins the
devbox-lock-only case.
