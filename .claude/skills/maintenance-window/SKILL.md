---
name: maintenance-window
description: >
  Wrap ANY change to live infrastructure in a declared window with a baseline, a background alert
  watch, and a before/after comparison. Use for every mutating act, not just tofu: `tofu apply`,
  `talosctl patch|upgrade|apply-config`, `kubectl rollout restart|delete|drain`, a Helm or ArgoCD
  sync you trigger by hand, a node reinstall, a router change. Triggers: "apply", "upgrade",
  "restart", "reinstall", "drain", "patch the cluster", "maintenance", "let's do the rollout".
  The other maintenance skills (tofu-apply, onboard-metal-node, opnsense-as-code) run INSIDE this.
---

# Maintenance window — never change live infrastructure blind

> **Glance first**: [`../GAPS.md`](../GAPS.md) §maintenance-window — unpromoted sightings apply
> until closed (contract: [`../README.md`](../README.md)).

**The failure this kills: the seat changes live infrastructure, reports success, and the OPERATOR
is the one who finds out it broke.** On 2026-09-20 a control-plane config apply took every
ServiceAccount token in the cluster out of validity and dropped the in-cluster API path on 10 of
12 nodes. The session verified `kubectl get nodes` (12/12 `Ready`), declared the step done, and
moved on. The operator noticed ~30 minutes later, from Alertmanager. Scrape targets had gone
48 → 0; cilium-operator, crossplane, cnpg-operator, longhorn's csi-provisioner and
kube-state-metrics were all CrashLoopBackOff; the ARC runners were wedged, so CI had stopped.

Every one of those signals existed the whole time. Nobody was looking at them.

## The rule

**A mutating act on live infrastructure runs inside an open window, with a baseline taken before
and compared after.** Not "a risky act" — you do not get to judge that in advance. The apply above
was a one-line config change with a clean plan and a rehearsal behind it.

```bash
devbox run maint -- open --reason "<what you are doing, in the responder's words>"   # prints the window id
# ... do the work, running `check` between steps ...
devbox run maint -- check [--id <id>]
devbox run maint -- close [--id <id>]
```

`open` snapshots firing alerts, `sum(up)`, non-Running pods and the cilium apiserver-backend
count, then writes the [declared window](../../../docs/glossary.md) (`agents/seat-window.sh` →
the `responder-window` ConfigMap) so the responder does not burn triage sessions on alerts a
person is causing. The box's node reconciler also reads that record and will NOT sync while any
window is open — a window on a `reconcile: auto` node holds it off that node too. When the window
exists to WATCH the reconciler act (an attended sync), open it with `--node <n>
--admit-reconciler`. `check` diffs live against that baseline. `close` refuses while anything is
still off baseline.

**Note your window id.** `open` prints it (`✓ window <id> open …`) and keeps the baseline in a
slot of its own (`~/.claude/maintenance-window/<id>/`). Without `--id`, `check`/`close` act on
the ONE open window and **refuse, listing them, when several are open** — which is the normal
state while a subagent runs its own window beside yours (a seat and its subagent clobbered each
other's single slot on 2026-09-22). So whenever a subagent may have a window open, pass it
explicitly: `devbox run maint -- check --id <id>`, `devbox run maint -- close --id <id>`;
`devbox run maint -- list` shows them. A stale slot from a dead session goes with
`close --id <it> --force`.

A probe that **could not be read** prints `⚠ … UNREADABLE` and blocks exactly like a regression —
"we did not look" is never `ok`, and a dead apiserver still yields the whole breakdown rather than
a bare error. `open` refuses to bank a baseline any probe failed to read, since every later `check`
would compare favourably against it.

## Arm the watch — the session must SEE alerts, not be told about them

`check` is a point read. Across a long window the seat also needs to be *interrupted*, so:

**Arm a background alert watch at `open` and keep it for the whole window.** Use `Monitor`
(persistent) — the same pattern [`meta-coordinate`](../meta-coordinate/SKILL.md) §5 uses for the
standing watches — polling the firing-alert set and reporting anything absent from the baseline:

```
curl -s $PROM/api/v1/alerts | jq -r '[.data.alerts[]|select(.state=="firing")|.labels.alertname]|unique[]'
```

A new alert name is a **stop signal**: stop the maintenance, diagnose, and only then continue.
It is not a footnote for the summary. The watch dies with the session — re-arm it after `/clear`.

## What `check` actually checks, and why each one is there

| Check | The lesson behind it |
|---|---|
| new firing alerts | the operator saw them first |
| `sum(up)` fell | 48 → 0 scrape targets went unnoticed for ~30 min |
| cilium holds `10.96.0.1:443` on every node | **every apiserver restart drops this backend fleet-wide and Cilium does not re-sync it** — pods get `connection refused` to the API while nodes still read `Ready`. Seen twice in one day. Fix: `kubectl -n kube-system rollout restart ds/cilium`. Callable alone as `devbox run maint cilium-check` (exit 0 clean / 2 missing / 3 unread) — run it after ANY apiserver restart; `cp-upgrade` runs it itself, either side of the reboot |
| non-Running pods rose | controllers crashloop on a broken API path |
| CI stranded in `queued` | ARC listeners restart during cluster work and never re-claim jobs queued during the gap — they sit in `queued` forever and surface as `CiDispatchStalled` |

## Hard-won, and not obvious

- **`Ready` is not health.** The data plane survives things the control plane does not: running
  pods keep running, nodes keep reporting `Ready`, and a token-authenticated call is the only
  thing that fails. A verification that reads a `Ready` column proves nothing about an apiserver
  change. Probe something that uses a **ServiceAccount token**.
- **`--mode=try` is not a guaranteed revert.** It auto-reverted twice on 2026-09-20 and then did
  not: an `apiServer.extraArgs` patch was still live seven minutes later and had to be removed by
  hand with `$patch: delete`. Treat try-mode as a convenience, never as the reason a step is safe.
- **A declared window does not make a change safe.** It suppresses LLM triage. It prevents
  nothing. Do not let opening one substitute for caution.
- **Rehearsing on one node can be structurally blind.** The 2026-09-20 endpoint change was
  rehearsed on a worker; the flag it actually moved (`--service-account-issuer`) only exists on
  the control plane. Ask what the rehearsal *cannot* observe before trusting it.
- **Stranded CI does not self-heal.** Cancel, wait for `completed/cancelled`, then `gh run rerun`.
  A plain `rerun` on a still-queued run returns "already running" and changes nothing.

## Incident exit

When the window ends badly, the close is not the end:

1. **Make git match live before anything else.** A revert applied only to the cluster leaves
   master declaring the broken state, and the next apply — yours or the box's loop — re-breaks it.
2. Sweep stranded CI across every repo (`check` lists them), not just the one you were watching.
3. Recycle pods that hold now-invalid credentials — a *container* restart keeps the projected
   token; the pod has to be recreated.
4. Route the writing: an incident postmortem to `docs/incidents/`, the residual action to an FU,
   a skill-shaped lesson to [`GAPS.md`](../GAPS.md). Ask before writing a postmortem — not every
   bad window earns one.
