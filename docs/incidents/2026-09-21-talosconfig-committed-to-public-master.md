# 2026-09-21 — a talosconfig (os:admin key) was committed to public master

**First symptom:** CI red on master — `sentinel-smoke` reporting `VIOLATION gitleaks: secret
material in the tree` (run 35570579293), repeated on the next PR opened from that commit.
**Class:** self-inflicted, seat-driven — a stray file in the working tree was swept into a
bookkeeping commit by a bulk `git add` and pushed to a **public** repository.
**Blast radius:** one `O=os:admin` Talos client certificate **and its private key**, valid to
2027-05-29. The Talos **CA private key did not leak** — a talosconfig carries the CA certificate
only, so no new identities can be minted from what was published.

## Timeline (UTC, 2026-09-21)

| when | what |
|---|---|
| ~06:53 | `tofu/nix-shell-env` appears in the working tree — a full talosconfig (`context`, `endpoints`, `ca`/`crt`/`key`). The command that wrote it was not identified; the file's mtime is the same minute as the commit below. |
| 06:53:29 | The previous session's wind-down bookkeeping commit `17424211` includes it alongside TICK-LOG, meta-state and the tracker — a bulk add, 4 files, one of them not bookkeeping. |
| ~06:55 | Pushed to `origin/master`. The `githooks/pre-push` gate runs: docs lints + `tofu fmt -check`. **None of them is a secret scan**, so the push proceeds. |
| 07:02 | CI's `sentinel-smoke` goes red on master, and again on PR#1825 opened from that head. |
| 07:05 | This session, investigating the PR's red CI, runs gitleaks locally and identifies the file. |
| 07:10 | `80fc47ab` — file removed from the tip, `tofu/.gitignore` closed. Exposure on the tip: ~15 minutes. |
| 07:12 | `63b69194` — gitleaks added to `githooks/pre-push`, scoped to the pushed commit range (~0.1 s; verified against the leaking commit itself). |

## Root cause

1. **A secret-shaped stray in a directory that is bulk-added.** `tofu/.gitignore` names
   `kubeconfig` and `talosconfig` — the two filenames the tooling writes. This file had neither
   name, so nothing ignored it, and a bulk `git add` does not distinguish "my bookkeeping edits"
   from "whatever else is in the tree".
2. **The direct lane has no secret scan.** A master push from the jail bypasses CI (OrgAdmin), and
   the pre-push hook — the lane's only gate, built for exactly this reason — checked docs and
   formatting. The gitleaks engine existed the whole time, in the sentinel, which is a
   *post-merge* reader for this lane. It found the leak eight minutes after publication.

## What held

- The sentinel's gitleaks engine caught it unprompted, which is how it surfaced at all.
- The credential is LAN-scoped: the Talos API answers on `192.168.2.0/24` and over WireGuard, and
  is not published through the tunnel (only `ha.teststuff.net` is public, `docs/cloudflare.md`).
- The CA private key stayed in the state file on the management box; the published material is one
  client identity, not the ability to mint more.

## Fixed here

- `80fc47ab` — removed from the tip; `nix-shell-env` added to `tofu/.gitignore`.
- `63b69194` — `githooks/pre-push` runs `gitleaks detect --log-opts=<pushed range>` against
  `policy/iac/gitleaks.toml` before the doc lints. Range-scoped, not a tree scan: a working tree
  here always holds a gitignored kubeconfig/talosconfig/tfstate, so `--no-git` would block every
  push. Exit 9 blocks; any other non-zero is reported as a tool error and does not block.

## Residual — the credential itself

**Removing the file does not un-publish it.** The blob stays reachable by SHA, and Talos has no
CRL: the leaked `os:admin` identity is valid until 2027-05-29 for anyone who can reach the API.
Invalidating it means rotating the Talos API CA (`talosctl rotate-ca`), which collides with the
machine-secrets freeze landed the same morning (FU-263 (a)) — tofu still holds the old bundle in
state, so a later apply would push the old CA back.

**Operator ruling 2026-09-21: rotate, but not now** — finish the three-control-plane rollout and
let it stabilise first. Tracked as **FU-264**.
