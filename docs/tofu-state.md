# OpenTofu state — where it lives, and why that is a design question (FU-012)

Every tofu root in this repo *kept* its state as a **local, gitignored file in the jail** — and
the reason that had to change is not tidiness: nothing running anywhere else can `plan` at all. The
FU-097 drift belt and any out-of-cluster applier were both blocked on it. As of 2026-08-04 three of
the five roots are on encrypted remote state in Garage; `main` and `github` are not, for reasons
that are rulings rather than backlog (see the cone table).

It is also the single most dangerous change in the repo. A root that loses its state does not fail
loudly — it plans to **create** everything it already owns. Everything below is shaped by that.

## What is built (2026-08-04)

| Piece | Where | Status |
|---|---|---|
| Garage bucket `homelab-tofu-state` + rw key | `argocd/resources/tofu-state/garage-workspace.yaml` (Crossplane Workspace, ADR-076 CREATE-pattern, 1Gi cap) | **LIVE** — reconciled, key in the `tofu-state-s3` connection Secret |
| Credential + endpoint + encryption env | `scripts/tofu-state-env.sh` (source-me) | built |
| Per-root migration | `scripts/tofu-state-migrate.sh` → `devbox run tofu-state-migrate` | used for real on 3 roots |
| Generated backend block | written by the script into `<root>/backend.tf` | **3 roots LIVE** |
| Wallet entries | `tofu-state-{key-id,secret,passphrase}`, seeded by `scripts/keepass-init.sh` | **seeded 2026-08-04** |

**Three roots migrated 2026-08-04** — all verified the same way, with the local state file
**deleted** first so the plan can only be reading Garage, and each compared against a plan taken
*before* the move:

| root | resources | before → after |
|---|---|---|
| `cloudflare` | 14 | `0 add / 1 change / 0 destroy` both sides — the one change is pre-existing comment drift on the ddclient-owned DDNS record |
| `provisioning` | 2 | `No changes` → `No changes` |
| `infisical` | 13 | `No changes` → `No changes` |

Every object in the bucket is genuine ciphertext: top-level keys are
`encrypted_data`/`encryption_version`/`meta`/`serial`/`lineage`, no `resources`. All three run
**`use_lockfile = false`**, deliberately — see the ruling below.

`main` and `github` are unmigrated.

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

**Encryption is per ROOT, not per shell** — and that was learned by breaking something. The first
version exported `TF_ENCRYPTION` from every `tofu-state-env.sh` source, so the moment the passphrase
landed in the wallet, `devbox run tf-plan` died on the main root with *"encountered unencrypted
payload without unencrypted method configured"*: its state is still plaintext. Seeding a secret is
not supposed to break an unrelated root.

So callers name their root (`TOFU_STATE_ROOT_DIR`) and the default `auto` mode turns encryption on
only when that root has a `backend.tf` — migrated means encrypted, by construction. `on` forces it
(the migration needs the passphrase *before* it writes the file). Sourcing with no root named yields
no `TF_ENCRYPTION` at all, so a migrated root then fails loudly on read rather than being silently
rewritten in plaintext — fail-closed in the direction that matters. Wired into `scripts/tf.sh` and
`tofu/infisical/apply.sh`; **any future wrapper for a migrated root needs the same two lines.**

## The locking ruling — Garage does not enforce conditional writes

OpenTofu's S3 backend gets mutual exclusion from `use_lockfile = true`, which is **S3-native
locking**: it works only if the object store honours `If-None-Match: *` — a second PUT to an
existing key must fail with `412 PreconditionFailed`.

**Measured on the live Garage (v2.3.0) over 20 trials — 20/20 the second conditional PUT SUCCEEDS**,
returning a fresh `VersionId`; identical whether the two PUTs are back-to-back or separated by a
round trip, so it is not a consistency race, it is simply not implemented. Conditional writes are
not enforced. `use_lockfile = true` here would give the *appearance* of state locking with none of
the substance, and two concurrent applies could interleave into a corrupt state.

> The 20-trial run happened because the probe **disagreed with itself** between two consecutive
> runs. Cause: the first version read the verdict by grepping the output for `412` on both paths,
> so a *successful* PUT whose random ETag/VersionId contained the substring `412` reported
> "conditional writes honoured" — the exact opposite of the truth, from the check whose whole job
> is to refuse. Fixed to key off the **exit status**, inspecting the error string only on the
> failure path; now deterministic (5/5). Worth keeping as a specimen: this is the
> silent-success class (FU-125/FU-108/FU-131) reappearing *inside the guard built to prevent it*.

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
| `cloudflare` | no — external zone, no cluster dependency | **MIGRATED 2026-08-04** — the safe canary, and it worked |
| `provisioning` | no — Matchbox LXC on Proxmox | **MIGRATED 2026-08-04** |
| `infisical` | partly | **MIGRATED 2026-08-04** — its state holds the Infisical client secret, so getting it out of a plaintext file was the point; still slated to leave tofu (`minimize-tofu` direction) |
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

The three wallet entries are **seeded and idempotent** — `scripts/keepass-init.sh` now owns them, so
a fresh wallet gets them without a manual step:

- `tofu-state-key-id` / `tofu-state-secret` — copied out of the `tofu-state-s3` connection Secret.
  That in-cluster Secret is a **bootstrap fallback only**: a credential that lives only in the
  cluster is unreachable exactly when the cluster is what you are rebuilding.
- `tofu-state-passphrase` — generated there, alphanumeric (it lands in an HCL string inside a shell
  heredoc, where `$`, `\` and `"` all mean something). **Losing this entry loses every migrated
  root's state**, which makes the wallet backup the real dependency, not the bucket.

⚠ **Do not delete a root's `backend.tf` to regenerate it.** Once `.terraform/` points at S3, a
missing backend block makes `init` fail and the state look unreadable. The script refuses at that
point rather than proceeding (confirmed live, 2026-08-04) — but the fix is to restore the file, not
to re-run the migration.

## Why `tofu init` moved into `scripts/tf.sh`

`devbox run tf-plan` used to run a bare `tofu -chdir=tofu init` before calling the wrapper. With an
S3 backend that bare init has no credentials and fails *before* `tf.sh` can supply them, so init now
happens inside `tf.sh`, after the wallet and state env are sourced. Verified: `devbox run tf-plan`
still reaches a clean "No changes" with the local backend.
