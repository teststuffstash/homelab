# devbox-update fixtures — the recorded lock diffs scripts/devbox-update-test.sh runs `lock_moves` over

- `pr2260-old.lock` / `pr2260-new.lock` — homelab#2260 (the weekly bump of 2026-10-06, 18 moves): the
  gate flagged ONE major (argo-workflows 3.6 → 4.0) and was blind to the openssl 3.6.0 → 3.5.8 DOWNGRADE
  (nixpkgs re-pointed the default alias to the 3.5 LTS, NixOS/nixpkgs#564262) and the python3
  3.12 → 3.14 / opentofu 1.12 → 1.13 / kubectl 1.36 → 1.37 line moves — gap register G17,
  `docs/dependency-upgrades.md`; ADR-141 as amended 2026-10-06. Verbatim `devbox.lock` at the PR's
  merge-base and head.
