# Spike — rotating the Talos API CA under a tofu-declared cluster

**Tracked by:** FU-264. **Status:** lab-probed 2026-09-22 on a disposable control plane (§Lab
results). The state-reconciliation question is answered (candidate A), and the production recipe is
§The recipe. **Production rotation DONE 2026-09-22 14:55–15:14Z** (§Production run).
**Why now:** a talosconfig carrying the `os:admin` certificate **and its private key** was
committed to public master on 2026-09-21
([incident](../incidents/2026-09-21-talosconfig-committed-to-public-master.md)). Talos has no CRL,
so that identity is valid until **2027-05-29** and only a CA rotation invalidates it.
**Operator ruling (2026-09-21):** rotate, but *after* the three-control-plane rollout is stable —
every apply that week taught something new, and a PKI rotation mid-rollout compounds.

## What is actually exposed

The leaked certificate **is tofu's own admin identity**. Its SHA-256 fingerprint (`24:B1:52:7F…`)
is the one in `talos_machine_secrets.this.client_configuration`, so the same identity is in
`tofu/talosconfig`, `/var/lib/mgmt/talosconfig` and the nixos-anywhere staging copy (checked
2026-09-22). Rotating the CA therefore also kills the talosconfig every consumer uses. The state
has to mint a new one, and that is why the tofu half below is required rather than cosmetic.

| | leaked | consequence |
|---|---|---|
| `os:admin` client certificate + **private key** | yes | full Talos API admin on the LAN until 2027-05-29: machine config read/write, reset, reboot, and `talosctl kubeconfig` → cluster-admin on Kubernetes |
| Talos CA **certificate** | yes | public by nature; it is what clients verify against |
| Talos CA **private key** | **not directly** | a talosconfig never carries it. **But a control plane's machine config does** (`machine.ca.key`), and the leaked identity can read that config. The same read returns the Kubernetes CA key, etcd CA key, aggregator CA key, the ServiceAccount signing key, the cluster secret and the secretbox key |
| Kubernetes CA / the k8s admin key | not directly | reachable *through* the Talos API with the leaked identity (the row above) |

The API is LAN-only (`192.168.2.0/24`) plus WireGuard peers; nothing in
[`cloudflare.md`](../cloudflare.md) publishes it. So the exposure is bounded by network position,
not by the credential — which is why "rotate, but finish the rollout first" is a defensible call
and "do not rotate at all" is not.

**What a rotation does and does not fix: the scope question.** `rotate-ca` defends against *future*
use of the leaked certificate. If the certificate was **already used** from inside the LAN, the user
holds every key in the third row. `rotate-ca` rotates two of them (Talos CA, Kubernetes issuing CA);
the ServiceAccount key, etcd CA, aggregator CA, cluster secret and secretbox key stay as they were.
Recovering from real use is a new cluster PKI (a rebuild), not this recipe. Nothing records Talos API
use, so the choice is a judgement:

- **Not used** (the working assumption — LAN-only, 15 minutes on the tip): rotating the **Talos CA
  alone** removes the only live credential that came out of the leak. This is the recommended
  scope, `--kubernetes=false`.
- **Used**: `--kubernetes=true` fixes one key out of six. It also forces a recycle of every
  in-cluster API client pod (§Lab results, finding 4). It is not a halfway point worth that cost.
  The honest answer to "used" is a rebuild.

## What `talosctl rotate-ca` does

These flags are verified against the pinned `talosctl` **v1.13.8**, the jail's and the box's devbox
alike (`devbox run -- talosctl rotate-ca --help`, 2026-09-22):

- `--talos` / `--kubernetes`: which CA to rotate. Both default to `true`.
- `--dry-run`: defaults to **`true`**.
- `--control-plane-nodes`, `--worker-nodes`, `--init-node`: the topology. Pass it explicitly.
- `-o, --output`: where the new talosconfig is written (default `talosconfig`).
- `--with-docs`, `--with-examples`: both default to `true`, and every patched machine config gets
  the docs and examples re-rendered into it.
- `--k8s-endpoint`: optional. The lab did not need it.

For Kubernetes, only the API-server issuing CA is rotated.

The sequence it runs, per node, with a connectivity check between each step:

1. Add the new CA as accepted.
2. Make the new CA the issuer, keeping the old one accepted.
3. Remove the old CA.
4. Write the new talosconfig.

## The problem this spike exists for: tofu holds the old bundle

`talos_machine_secrets.this` is the declared PKI, and every machine config, the talosconfig data
source and `talos_cluster_kubeconfig` derive from it. After a live rotation the state still holds
the **old** CA. The resource is `prevent_destroy` with a frozen `talos_version` (#1825, FU-263 (a)),
so "let tofu regenerate it" is closed on purpose: regenerating produces a NEW PKI, not a rotation.

Before the lab, the feared failure was that the next `talos_machine_configuration_apply` would push
the old CA back. **The lab disproved that** (finding 5): after a rotation the old client certificate
cannot authenticate, so a stale-state apply hangs and fails rather than reverting anything. The real
costs of leaving state stale are these:

- `plan` reads `No changes`, so nothing warns you.
- Every Talos apply, from the box's loop or a human, hangs until killed.
- `devbox run talosconfig` keeps re-issuing the dead, leaked identity.

## State-reconciliation candidates

| | candidate | what a later plan does | verdict |
|---|---|---|---|
| **A** | Rebuild a bundle from a live CP config (`talosctl gen secrets --from-controlplane-config`), then `tofu state rm talos_machine_secrets.this` and `tofu import talos_machine_secrets.this <bundle>` | See the note below the table. | **Recommended. Lab-proven** end to end |
| B | `lifecycle { ignore_changes = … }` | nothing — no config attribute changes; the problem is the *state* content, which `ignore_changes` does not touch | rejected: a no-op for this failure |
| C | Drop the resource for a data path: the bundle in the wallet or Infisical, fed through `yamldecode` into `machine_secrets` | Five consumers need re-plumbing. There is no provider-side client-cert minting, so it would need a `tls_locally_signed_cert` over an ed25519 CA | rejected for FU-264: a redesign, and the state still holds the keys |
| D | `state pull`, hand-edit the JSON, `state push` | the same end state as A, minus the provider minting the client cert | rejected: hand-edited secret JSON, and A does the same thing through the provider |
| E | `-replace` / regenerate | a NEW PKI; every node keeps trusting the old CA | forbidden (`prevent_destroy`, #1825) |
| F | leave the state stale | `No changes`; Talos applies hang; client configs re-issue the leaked identity | rejected (finding 5) |

What candidate A's later plans do:

- Plan 1 (secrets only) shows one in-place `talos_version` change, `"v1.3" -> "v1.13.2"`. The import
  records `v1.3`, and every secret shows `(known after apply)`. That is cosmetic: every CA, key,
  cluster id and secret comes back byte-identical.
- Plan 2 updates the config-apply resources in place. The content is semantically identical to what
  `rotate-ca` left live, so nothing reboots.
- Plan 3 reads `No changes`.

An `import {}` block through a PR is the declarative twin of A. It still needs a prior `state rm` or
`removed {}` step and a bundle file on the box, so it costs two PRs for the same end state. The
`mgmt-tf` CLI snapshots state after every `state`/`import` anyway.

## Lab results (2026-09-22)

**The rig.** VM 8199 `cp-upgrade-lab` on nx-02 (nvme-thin pool at 40.7% before and 40.8% after),
from the `talos-v1.14.1-nocloud` image, installed by
[`scripts/controlplane-lab-install.sh`](../../scripts/controlplane-lab-install.sh). It ran at
`192.168.2.69`, which was cleared per [`ip-plan.md`](../ip-plan.md): `git grep` found nothing and
`nmap -sn` showed nothing up.

**Why the lab was isolated.** `gen config cp-upgrade-lab` mints its own bundle, which gives it its
own cluster id, CA and etcd. `apply-config --insecure` only lands on a maintenance-mode node. Every
later call named the lab's own talosconfig and only `.69`.

**How the tofu half ran.** A **scratch** tofu root mirrored `tofu/talos.tf`'s shape (secrets pinned
`v1.13.2` + `prevent_destroy`, contract `v1.13.10`, `no_reboot` config apply, `talos_cluster_kubeconfig`)
against that node only.

**What stayed untouched.** The main state, the box and every production node. The whole probe ran
inside a [declared window](../glossary.md), and the VM was destroyed after.

1. **`gen secrets --from-controlplane-config` + `tofu import talos_machine_secrets.this <bundle>`
   works** on provider 0.11.0. The import records `talos_version = "v1.3"`, and pinning
   `--talos-version` on `gen secrets` does not change the bundle. The follow-up in-place update to
   `v1.13.2` plans every cert and key as `(known after apply)`. **Proven on a state copy:** os, k8s,
   etcd and aggregator cert+key, cluster id and secret, and the bootstrap/secretbox/aescbc secrets
   are byte-identical after the update, and so is the client certificate.
2. **`rotate-ca` prints the current AND new CA private keys to stdout**, even in dry-run (the
   "Current/New Talos CA" blocks), along with the new talosconfig. Never run it where the output
   reaches a transcript. Redirect it to a `0600` file and read it through
   `grep -vE '^\s+(key|crt|ca):'`.
3. **Topology flags.** `--init-node X` together with `--control-plane-nodes X` lists X twice. Pass
   `--control-plane-nodes` and `--worker-nodes` only. A combined `--talos --kubernetes` **dry-run**
   ends in `failed to create new client with rotated Talos CA: failed to determine endpoints`.
   **So does a `--talos`-only dry run** (corrected by the production run, 2026-09-22): in v1.13.8
   `rotateCA` re-creates its client from the talosconfig `rotateTalosCA` returns, and a dry run
   returns nil (`cmd/talosctl/cmd/talos/rotate-ca.go`). Every Talos dry run therefore exits 1 AFTER
   a clean pass. A real run saves the talosconfig before that call.
4. **The real rotation took 12 s on one node**, exit 0. Afterwards:
   - The old tofu talosconfig and the installer's talosconfig were refused (`authentication handshake
     failed`), and the new one worked.
   - The old kubeconfig was refused. With `--insecure-skip-tls-verify` it got `Unauthorized`, so the
     old k8s client cert is dead too.
   - kube-apiserver restarted. kube-scheduler and kube-controller-manager crashlooped about 1 min,
     then recovered on their own (the §CP3 shape in [`controlplane-ha.md`](../controlplane-ha.md)).
   - ⚠ **With `--kubernetes`, every in-cluster API client that started before the rotation broke and
     stayed broken**: coredns, kube-proxy and flannel logged `x509: certificate signed by unknown
     authority` for 3+ minutes, although `kube-root-ca.crt` already held only the new CA. A
     `rollout restart` of each cleared it. In production that means every API-using pod in the
     cluster (Cilium, the operators, Argo, Longhorn, CNPG, …), which is why the recommended scope is
     `--kubernetes=false` (§What is actually exposed).
   - The live config was left with **no** `acceptedCAs` and with the new `machine.ca.key` /
     `cluster.ca.key` in it, which is what makes candidate A possible.
5. **A stale state cannot push the old CA back.**
   - `plan` read `No changes`.
   - An apply of a config change (a node label) hung in `Still modifying…` for 6+ minutes until
     killed.
   - The live machine config hash was unchanged and the label never landed.

   The old client certificate is refused, so the provider retries TLS instead of writing. For the
   box this means a stale state is a **hang holding the apply lock**, not a silent revert.
6. **Candidate A, end to end:**

   | step | result |
   |---|---|
   | build the bundle from the live config | done |
   | `state rm` | allowed despite `prevent_destroy` |
   | `import` | succeeded |
   | first plan | `0 to add, 3 to change, 0 to destroy` (secrets ~, config apply ~, kubeconfig ~) |
   | first apply | the secrets update landed. The two dependent resources failed with `Provider produced inconsistent final plan`, which is harmless |
   | second apply | `1 changed` |
   | plan | **`No changes`** |
   | after the second apply | PKI fingerprint identical to the rotated live config; **no reboot** (same boot id); a comment-normalised semantic diff of `rotate-ca`'s config vs tofu's re-render: **identical** |
   | tofu's talosconfig output | now works |
   | tofu's kubeconfig (k8s CA rotated) | still dialled the old CA, although `plan` was clean. That is the FU-259 capture shape |
   | `-replace=talos_cluster_kubeconfig.this` | fixed it; plan clean again |

   The recipe below splits plan 1 into a `-target`ed secrets-only step, so the dependents are
   planned against the settled secrets instead of failing once.

**What the lab could not observe:**

- **Workers.** It was a one-node control plane, so the worker leg of `rotate-ca` ran in no lab.
- **Three-member etcd and the VIP.**
- **`--talos` on its own.** The real run rotated both CAs, so what the Talos half alone restarts is
  unmeasured. It rewrites only `machine.ca`/`acceptedCAs`, and no Kubernetes component consumes
  those.

The recipe's per-node checks and the window cover these gaps. They are not closed.

## The recipe — production, three control planes

Operator-attended. Every Talos call runs **on [the management box](../management-box.md)**: it holds
`/var/lib/mgmt/talosconfig` and the main state, and its talosctl is the same v1.13.8. That keeps
the CA keys `rotate-ca` prints off the jail and out of any transcript.

The topology is 13 nodes:

- **Control planes:** cp-01 `.51`, cp-02 `.65`, wk-metal-02 `.183`.
- **Workers:** `.54 .56 .58 .61 .62 .63 .64 .182 .184 .186`.
- **Not a node:** thinkcentre `.53`, the box itself.

Re-read `kubectl get nodes -o wide` first. If it does not show exactly those 13, stop and fix the
lists.

**0. Preconditions** (seat, in the jail). All of these must hold before starting:

- No rollout in flight.
- `maint check` clean.
- `devbox run maint -- open --reason "FU-264 Talos CA rotation" --hours 3`, with the alert watch
  armed. The window also holds the reconciler off.

**1. Freeze the box and snapshot** (as root on the box: `ssh root@192.168.2.53`, host key pinned
from the wallet. Keep ONE root shell open through step 5's bundle build, because the variables
carry over):

```bash
systemctl stop mgmt-apply.timer mgmt-reconcile.timer mgmt-sentinel.timer   # the apply loop ignores windows
R=/var/lib/mgmt/rotation; mkdir -m700 -p $R; cd /var/lib/mgmt/apply/homelab
B=/var/lib/mgmt/apply/homelab/.devbox/nix/profile/default/bin; TCTL=$B/talosctl; YQ=$B/yq  # bare: devbox run would inject a wrong TALOSCONFIG/KUBECONFIG
OLD=/var/lib/mgmt/talosconfig; install -m600 $OLD $R/talosconfig-old
CPS=192.168.2.51,192.168.2.65,192.168.2.183
WKS=192.168.2.54,192.168.2.56,192.168.2.58,192.168.2.61,192.168.2.62,192.168.2.63,192.168.2.64,192.168.2.182,192.168.2.184,192.168.2.186
env -u KUBECONFIG $TCTL --talosconfig $OLD -n $CPS -e 192.168.2.51 etcd status          # 3 members, one leader, no errors
env -u KUBECONFIG $TCTL --talosconfig $OLD -n 192.168.2.51 -e 192.168.2.51 etcd snapshot /var/lib/mgmt/etcd-snapshots/pre-rotate-ca-$(date -u +%Y%m%dT%H%M%SZ).db
/var/lib/homelab/scripts/mgmt-state-snapshot.sh main && install -m600 /var/lib/mgmt/state/main/terraform.tfstate $R/pre-rotate.tfstate
```

**Abort here** if etcd is not 3/3 healthy or either snapshot fails.

**Undo for this step:** restart the three timers.

**2. Dry run:**

```bash
ROT() { env -u KUBECONFIG $TCTL rotate-ca --talosconfig $OLD -e 192.168.2.51 -n 192.168.2.51 \
  --control-plane-nodes $CPS --worker-nodes $WKS --talos=true --kubernetes=false \
  --with-docs=false --with-examples=false -o $R/talosconfig-new "$@"; }
ROT --dry-run=true > $R/dry-run.log 2>&1; echo "exit=$?"; chmod 600 $R/dry-run.log
grep -vE '^\s+(key|crt|ca):' $R/dry-run.log
```

**Expected:**

- The topology lists 3 control planes + 10 workers, **each exactly once**.
- Every "Verifying connectivity" line reads `OK (dry-run)`, one per node.
- The mutations read `skipped (dry-run)`.
- It ends with `Dry-run mode enabled, no changes were made`, then `failed to create new client with
  rotated Talos CA: failed to determine endpoints` and `exit=1`: the dry-run artefact of §Lab
  results item 3. Any OTHER error, or a non-zero exit before the "Dry-run mode enabled" line, aborts.

**Abort** on any of these:

- a missing or duplicated node;
- a node that is not `OK`;
- a non-zero exit.

Nothing has changed at this point.

(`--with-docs=false --with-examples=false` keeps the live configs as bare as tofu renders them, so
step 4's re-delivery is not a comment-rewrite of 13 configs.)

**3. Rotate:**

```bash
ROT --dry-run=false > $R/rotate.log 2>&1; echo "exit=$?"; chmod 600 $R/rotate.log
grep -vE '^\s+(key|crt|ca):' $R/rotate.log | grep -vE '^(context|contexts):'
```

The lab shows transient `retrying error: … unknown certificate authority` lines between phases.
They are normal.

**Expected:** per node, `OK` at each of the phases in §What `talosctl rotate-ca` does, then
`Writing new talosconfig`, then `exit=0`.

**If it fails before "Making new Talos CA the issuing CA":** the old CA still issues, and
`talosconfig-old` still works. The new CA is merely also accepted. Stop, diagnose and re-run. A
re-run generates yet another CA, and that is fine.

**If it fails after that point:** there is no rotate-back, because `rotate-ca` only mints new CAs.
**Go forward.** The new talosconfig is inside `rotate.log` (the "Generating new talosconfig" block)
if `-o` was never written. Carve it out into `$R/talosconfig-new`, finish the remaining phases by
re-running against the nodes still on the old CA, and escalate. Keep `rotate.log`: it and the CP
configs are the only copies of the new CA key until step 4 lands it in state.

**4. Verify, and install the interim talosconfig on the box:**

```bash
for ip in $(echo $CPS,$WKS | tr , ' '); do env -u KUBECONFIG $TCTL --talosconfig $R/talosconfig-new -n $ip -e 192.168.2.51 version >/dev/null 2>&1 && echo "$ip ok" || echo "$ip FAIL"; done   # 13 × ok
env -u KUBECONFIG $TCTL --talosconfig $R/talosconfig-old -n 192.168.2.51 -e 192.168.2.51 version 2>&1 | grep -q 'authentication handshake failed' && echo OLD-REFUSED
env -u KUBECONFIG $TCTL --talosconfig $R/talosconfig-new -n $CPS -e 192.168.2.51 etcd status
install -m600 $R/talosconfig-new /var/lib/mgmt/talosconfig   # interim — step 6 replaces it with tofu's
```

In the jail: `devbox run maint -- check` and `devbox run maint cilium-check`. Kubernetes should not
have moved, because its CA was not touched.

**Abort signal:**

- any `FAIL`;
- the old talosconfig NOT refused;
- etcd not 3/3.

**5. Reconcile the state** (candidate A). Run it in the jail through `mgmt-tf` — it serialises with
the box's lock and snapshots after each `state`/`import`. First build the bundle **on the box** and
prove all three control planes agree:

```bash
for ip in 192.168.2.51 192.168.2.65 192.168.2.183; do
  env -u KUBECONFIG $TCTL --talosconfig /var/lib/mgmt/talosconfig -n $ip -e $ip get machineconfig -o yaml \
    | $YQ -r 'select(.metadata.id=="v1alpha1") | .spec' > $R/cp-$ip.yaml
  env -u KUBECONFIG $TCTL gen secrets --from-controlplane-config $R/cp-$ip.yaml -o $R/secrets-$ip.yaml
done; chmod 600 $R/*.yaml
cmp $R/secrets-192.168.2.51.yaml $R/secrets-192.168.2.65.yaml && cmp $R/secrets-192.168.2.51.yaml $R/secrets-192.168.2.183.yaml && install -m600 $R/secrets-192.168.2.51.yaml $R/secrets.yaml
```

(`get machineconfig` returns two resources, `persistent` and `v1alpha1`. Unfiltered, the pair makes
`gen secrets` fail with `duplicate document`.)

Then, in the jail:

```bash
devbox run mgmt-tf -- state rm talos_machine_secrets.this
devbox run mgmt-tf -- import talos_machine_secrets.this /var/lib/mgmt/rotation/secrets.yaml
devbox run mgmt-tf -- plan -target=talos_machine_secrets.this      # → plan id P1
```

**Expected P1**, read the WHOLE plan:

- exactly `# talos_machine_secrets.this will be updated in-place`;
- `~ talos_version = "v1.3" -> "v1.13.2"`;
- every cert/key/id shown as `(known after apply)`;
- `Plan: 0 to add, 1 to change, 0 to destroy.`

The unknowns are cosmetic (lab finding 1).

**A WRONG P1**, and so an abort, is any of these:

- `must be replaced`, `-/+`, or any `destroy`;
- a `prevent_destroy` error;
- more than one resource.

If `import` or P1 is wrong, the state is still recoverable from the pre-`state rm` snapshot. That
snapshot holds the old, dead identity: safe as a pause (applies hang, they cannot revert), but not a
place to stay.

`MGMT_YES=1 devbox run mgmt-tf -- apply <P1>` (without `MGMT_YES=1` it waits on a `[y/N]` prompt no
non-interactive caller can answer), then `devbox run mgmt-tf -- plan`, which gives plan id P2.

**Expected P2:**

- **only** in-place updates to the 13 `talos_machine_configuration_apply.node[…]` / `.metal[…]`
  instances (the new client cert and a new `machine_configuration_hash`);
- `talos_cluster_kubeconfig.this` updated in place, or absent;
- `Plan: 0 to add, 13 (or 14) to change, 0 to destroy.`

Optionally spot-check one control plane before applying. Render it with
`mgmt-tf -- console` → `nonsensitive(data.talos_machine_configuration.node["cp-01"].machine_configuration)`,
then run `talosctl apply-config --dry-run` against `.51`. The diff should be empty or comments only.

**A WRONG P2** is any of these, and each means abort and resolve that drift first, in its own plan:

- any `proxmox_*`, `kubernetes_*` or other non-Talos change;
- any create, replace or destroy;
- a node count other than 13.

`apply <P2>`. If some instances fail with `Provider produced inconsistent final plan`, plan again
and apply that id. The lab converged on the second pass. Last, `plan` must read **`No changes`**.

(If `--kubernetes` was chosen as well, add
`plan -replace=talos_cluster_kubeconfig.this -target=talos_cluster_kubeconfig.this` → apply. A clean
plan does NOT mean the captured kubeconfig is current. Lab finding 6, FU-259.)

**6. Redistribute** (jail). Every copy is regenerated from the state, never hand-copied:

- `devbox run talosconfig`. It writes `tofu/talosconfig` **and** `/var/lib/mgmt/talosconfig`
  from state, replacing step 4's interim copy. Check that both carry the same new fingerprint:
  `yq -r '.contexts[].crt' <file> | base64 -d | openssl x509 -noout -fingerprint -sha256 -enddate`.
  The import mints a fresh one-year client cert, so `notAfter` is no longer 2027-05-29.
- `bash scripts/mgmt-provision-secrets.sh`, without `--push`. It re-stages
  `~/.claude/homelab-mgmt/extra-files/var/lib/mgmt/talosconfig`, the nixos-anywhere reinstall seed.
  That copy is the leaked identity today.
- The **wallet** holds no talosconfig. `wallet-files.sh`/`keepass-env.sh` name none (grep,
  2026-09-22), so there is nothing to rotate there.
- **In-cluster:** no Talos API consumer (no `kubernetesTalosAPIAccess`, no talosconfig Secret under
  `argocd/`). Nothing to redistribute.
- The **operator's host** (`~/.talos/config` on pop-os, if any) is the operator's own step.
- If `--kubernetes`: also run `devbox run kubeconfig`. Then roll every API-client workload (lab
  finding 4), starting with `kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator
  deploy/coredns`.

**7. Prove it, and restore.**

The closure proof uses the leaked blob itself:

```bash
git show 17424211:tofu/nix-shell-env > <scratch>/leaked; chmod 600 <scratch>/leaked
talosctl --talosconfig <scratch>/leaked -n 192.168.2.51 -e 192.168.2.51 version   # must fail: authentication handshake failed
```

That failure is **client-side** (`x509: certificate signed by unknown authority`: the leaked config no
longer trusts the server), and an attacker can skip server verification. The proof that matters is
the server rejecting the leaked client cert. Carve its `crt`/`key` into 0600 files (rename the key's
`ED25519 PRIVATE KEY` PEM header to `PRIVATE KEY` for openssl) and, per node:

```bash
(printf 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n\x00\x00\x00\x04\x00\x00\x00\x00\x00'; sleep 3) \
  | openssl s_client -connect <ip>:50000 -cert leaked.crt -key leaked.key -alpn h2 | grep -a 'alert'   # must print: alert unknown ca
shred -u <scratch>/leaked <scratch>/leaked.crt <scratch>/leaked.key
```

The new identity, run the same way with `-CAfile` from the new talosconfig, must read `Verify return
code: 0 (ok)` and no alert.

Then restore and clean up:

- On the box: `systemctl start mgmt-apply.timer mgmt-reconcile.timer mgmt-sentinel.timer`, then
  watch one `mgmt-apply` tick and one belt/probe tick go green.
- Shred `$R/talosconfig-old`, `$R/cp-*.yaml`, `$R/secrets*.yaml` and the logs once the state has
  been snapshotted.
- `maint check`, then `close`.

The pre-rotation state snapshots on the box and in `homelab-tofu-state-backups/` now hold a dead
identity and a retired CA. Restoring one reproduces lab finding 5: a hang, not a revert.

## What must NOT be done

- **Do not `-replace` `talos_machine_secrets.this`.** That is a new cluster PKI, not a rotation:
  every node would keep trusting the old CA and nothing would hold valid certificates for the new
  one. The `prevent_destroy` added in #1825 exists to make that a plan-time error.
- **Do not rotate to "clean up" the issuer.** `local.sa_issuer` is frozen by
  [ADR-136](../adr.md) and names `.51` for this cluster's lifetime; it is unrelated to the CA and
  moving it 401s every ServiceAccount token at once.
- **Do not run `rotate-ca` through `devbox run`, or anywhere its stdout is captured.** devbox
  injects `TALOSCONFIG`/`KUBECONFIG` (on the box, paths that do not exist), and the output carries
  CA private keys (lab finding 2).

## Production run (2026-09-22, seat, operator-authorized)

Per §The recipe, from the box, `--talos=true --kubernetes=false`, 13 nodes (3 CP + 10 workers) on
v1.14.1 with talosctl v1.13.8 (safe: the config contract is v1.13.10, so no config carries a v1.14-only
field for the older client to drop).

- **Pre:** etcd 3/3, one leader, no errors; etcd snapshot `pre-rotate-ca-20260922T145546Z.db`; state s331.
- **Dry run:** 13 × OK in every phase, then the dry-run artefact (§Lab results item 3), exit 1.
- **Rotate:** exit 0, every phase 13/13, "Removing old Talos CA from the accepted CAs", new talosconfig
  written. Kubernetes untouched (`maint check` clean, cilium 13/13).
- **State:** the three CP-derived bundles identical; `state rm` + `import` (s332/s333); P1 exactly the
  expected single in-place change (its `+ aescbc_encryption_secret` is plan-time unknown: after apply
  it stayed `null`, and all 13 secrets/CAs byte-matched the live bundle); P2 15 in-place (13 config
  applies, `talos_cluster_kubeconfig`, and `talos_machine_bootstrap` whose only change is its client
  credentials — bootstrap acts on create only); a cp-01 render dry-run against the node: `No changes`;
  P2 applied clean on the first pass; the following plan: `No changes`.
- **Redistributed:** `devbox run talosconfig` (jail + box, one fingerprint, notAfter 2027-09-22), the
  nixos-anywhere seed re-staged. No `~/.talos` in the jail; the operator's host copy (if any) is theirs.
- **Proof:** every node answers the leaked cert with TLS `alert unknown ca`; the new one verifies.
- **Restore:** box timers on, one clean tick each of apply/reconcile/sentinel; the rotation working
  files (old/new talosconfig, CP configs, bundles, logs, the plaintext pre-rotate state) shredded.
