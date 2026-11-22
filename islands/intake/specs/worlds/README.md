# worlds/ — the states island intake's access rows run in

A **world** is a named, recorded state of a surface the sitting talks to: expected behaviour is a
function of (identity, world). Worlds are mined from the live surface, never invented
([../../../README.md](../../../README.md) §Built from the specs, never copied). Most of
[access.md](../access.md)'s rows run over **the declared records** at the commit under test (the
rulesets, the manifest, the mint site, the App declaration, the gateway policy) — read in place,
no copy here. This directory holds only the GitHub answers.

## create-ref-refused-2026-11-22

[`create-ref-refused-2026-11-22.json`](create-ref-refused-2026-11-22.json) — the scan island's apply
sitting of 2026-11-22 calling `POST repos/teststuffstash/homelab/git/refs` for
`refs/heads/goal/3656-scan-checkpoint-b` as the sitting's identity, and GitHub's answer: `422`,
`Reference update failed`. Mined from that sitting's session record (the object path and tool-use
id are in the file's `provenance`). The body is whole (131 bytes, captured untruncated by the
sitting's own `2>&1 | head -c 800`); the status is the body's and `gh`'s status line; the response
**headers were not captured** — a world recorded by the step below has them. The body names no
rule: which ruleset refused is read from the rulesets, not from this answer.

## create-ref-accepted-2026-11-22

[`create-ref-accepted-2026-11-22.json`](create-ref-accepted-2026-11-22.json) — the same call as the
sitting's identity for the throwaway ref `refs/heads/goal/0-access-probe`, made from the jail after
`tofu/github` was applied with `do_not_enforce_on_create` (2026-11-22): `201` with the new ref. It
holds the status, the whole body and the headers that identify the answer (`x-github-request-id`,
`x-accepted-github-permissions`); the token came from the Secret the workflow's `GH_TOKEN` names,
read at call time and written nowhere. This answer settles the open question the refused world
left: the `pull_request` rule of `required-approval-goal` does not refuse a creation. The same
identity then deleted the probe ref (`204`) — it may delete a `goal/**` ref too; no row covers
that act yet ([access.md](../access.md) §INTAKE-ACCESS-GOAL-BRANCH).

To record a new one (after a ruleset change), as the sitting's identity on the same throwaway ref:

```bash
sha=$(gh api repos/teststuffstash/homelab/git/ref/heads/master --jq .object.sha)
gh api -i -X POST repos/teststuffstash/homelab/git/refs \
  -f ref=refs/heads/goal/0-access-probe -f sha="$sha"          # status line + headers + body
gh api -X DELETE repos/teststuffstash/homelab/git/refs/heads/goal/0-access-probe
```

A `422` instead means a rule refuses the creation again: record THAT answer as the world and
re-open the fix.
