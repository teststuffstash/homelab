# OpenTofu state — where it lives, and why that is a design question (FU-012)

Every tofu root in this repo keeps its state as a **local, gitignored file in the jail**. That is
the status quo this doc exists to change, and the reason it must change is not tidiness: nothing
that runs anywhere else can `plan` at all. The FU-097 drift belt and any out-of-cluster applier are
both blocked on it.

It is also the single most dangerous change in the repo. A root that loses its state does not fail
loudly — it plans to **create** everything it already owns. Everything below is shaped by that.

## What is built (2026-08-04)

| Piece | Where | Status |
|---|---|---|
| Garage bucket `homelab-tofu-state` + rw key | `argocd/resources/tofu-state/garage-workspace.yaml` (Crossplane Workspace, ADR-076 CREATE-pattern, 1Gi cap) | **LIVE** — reconciled, key in the `tofu-state-s3` connection Secret |
| Credential + endpoint + encryption env | `scripts/tofu-state-env.sh` (source-me) | built |
| Per-root migration | `scripts/tofu-state-migrate.sh` → `devbox run tofu-state-migrate` | built, dry-run exercised |
| Generated backend block | written by the script into `<root>/backend.tf` | not yet written to any root |

**No root has been migrated.** The blocker is measured, not procedural — see the locking ruling.

## Encryption: OpenTofu's, not the backend's

FU-012 asks for *remote and encrypted*. Garage has no server-side encryption, which looks like a
gap until you notice the right layer is above the backend: **OpenTofu native state encryption**
(1.7+) encrypts the payload before it ever leaves the process, so it holds for *any* backend and
for the local file too.

The configuration rides in the **`TF_ENCRYPTION` environment variable**, never in a committed
`.tf` — a passphrase in a public repo is not a passphrase. `scripts/tofu-state-env.sh` assembles it
from the wallet entry `tofu-state-passphrase` (pbkdf2 → aes_gcm).

Verified 2026-08-04 on a throwaway root, both directions:

- writing: the state file carries `key_provider.pbkdf2.wallet` + `encrypted_data` and **no readable
  resource attributes**;
- migrating: with `method "unencrypted" "migrate"` as a `fallback`, tofu reads the existing
  **plaintext** state once and rewrites it encrypted, with every resource intact.

The fallback is **opt-in and temporary** (`TOFU_STATE_ENC_FALLBACK=1`, which
`tofu-state-migrate.sh` sets for its own run only). Left on permanently it would silently accept a
plaintext state forever, which is the failure it exists to end.

## The locking ruling — Garage does not enforce conditional writes

OpenTofu's S3 backend gets mutual exclusion from `use_lockfile = true`, which is **S3-native
locking**: it works only if the object store honours `If-None-Match: *` — a second PUT to an
existing key must fail with `412 PreconditionFailed`.

**Measured on the live Garage (v2.3.0), twice, once through the script's probe and once by hand:
the second conditional PUT SUCCEEDS**, returning a fresh `VersionId`. Conditional writes are not
enforced. `use_lockfile = true` here would give the *appearance* of state locking with none of the
substance, and two concurrent applies could interleave into a corrupt state.

`scripts/tofu-state-migrate.sh` therefore **refuses to migrate by default** and prints this, rather
than writing a backend block that lies. The ruling that follows from it:

- ✅ **Garage is fine for the read-only belt, which is what FU-097 actually needs.** There is
  exactly one writer (the operator, from the jail) and the automated actor is a `plan` cron that
  never writes. Run it with `-lock=false` and `use_lockfile = false`, and there is no race to lose:
  the state is off the operator's machine, encrypted, and reachable from anywhere on the LAN.
- ⛔ **Not fine for an automated *applier*.** The moment a second writer exists, the missing lock is
  a real corruption path. That is a hard precondition on Phase 3.2's out-of-cluster applier, not a
  caveat to note afterwards.
- The escape hatches, in preference order: **(a)** check whether a newer Garage enforces conditional
  writes and upgrade — this is a version question, not a design one; **(b)** the **`pg` backend** on
  the LIVE CNPG Postgres, which locks with real advisory locks (`TF_ENCRYPTION` covers encryption
  either way); **(c)** `TOFU_STATE_NO_LOCK=1`, single-operator discipline, accepted deliberately.

## The dependency-cone problem, applied to state

`docs/dependency-upgrades.md` already carries the rule for *runners*: an applier must sit outside
the blast radius of what it changes. State has the same shape, inverted — everything else ArgoCD
manages is downstream of tofu, but tofu's **state** would now be downstream of ArgoCD, Crossplane,
Garage and Longhorn.

Concretely: the `main` root is what you would use to rebuild the cluster, and its state would live
*inside* the cluster. A cluster-down event is exactly when you need it and exactly when it is gone.

So the roots do not migrate as a set:

| Root | In the cone? | Ruling |
|---|---|---|
| `cloudflare` | no — external zone, no cluster dependency | **migrate first**, it is the safe canary |
| `provisioning` | no — Matchbox LXC on Proxmox | migrate |
| `infisical` | partly | migrate, but it is slated to leave tofu anyway (`minimize-tofu` direction) |
| `github` | no | operator-only root, host wallet; migrate last if at all |
| `main` | **yes, fully** | do NOT migrate on the strength of "the others worked". Needs an out-of-cone copy — the timestamped backups `tofu-state-migrate.sh` writes to `~/.claude/homelab-tofu-state-backups/` are that copy today, and something better (off-box, versioned) is what would settle it |

## Running a migration

```
devbox run tofu-state-migrate cloudflare              # DRY RUN — probes everything, changes nothing
devbox run tofu-state-migrate -- cloudflare --apply   # do it
```

One root per run, on purpose: five roots in a loop is five chances to notice a problem after it
stopped being cheap to fix. The script refuses rather than proceeds — it will not migrate a root
whose local state it cannot read (empty and already-migrated must never look alike), it backs the
file up outside the repo first, it verifies the resource **count** survived, and it **never deletes
the local state file**. A human does that, after seeing a clean plan.

**Before the first real run** the operator seeds two wallet entries (`scripts/keepass-init.sh`):

- `tofu-state-key-id` / `tofu-state-secret` — from the connection Secret:
  `kubectl -n crossplane-system get secret tofu-state-s3 -o jsonpath='{.data.access_key_id}' | base64 -d`
  (and `.secret_access_key`). The in-cluster Secret is a **bootstrap fallback only** — a credential
  that lives only in the cluster is unreachable when the cluster is what you are rebuilding.
- `tofu-state-passphrase` — new, high-entropy. **Losing it loses the state.** It belongs in the
  Tier-0 wallet next to the other bootstrap secrets (`docs/secrets.md`).

## Why `tofu init` moved into `scripts/tf.sh`

`devbox run tf-plan` used to run a bare `tofu -chdir=tofu init` before calling the wrapper. With an
S3 backend that bare init has no credentials and fails *before* `tf.sh` can supply them, so init now
happens inside `tf.sh`, after the wallet and state env are sourced. Verified: `devbox run tf-plan`
still reaches a clean "No changes" with the local backend.
