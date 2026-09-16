# Spike — Flux tofu-controller as the management box's controller substrate

**Tracked by:** FU-242. **Status:** not started (written 2026-09-16 from the design sitting that produced
ADR-132). **Nothing runs on the box during this spike** — the box is the recovery root and a spike is the
thing not yet trusted. **Where:** a throwaway VM on `pve`, created by hand and deleted after; plain k3s +
Flux + tofu-controller. Phase two, if phase one says yes: the same VM built as a NixOS closure
(`services.k3s.images` / `manifests`), which is also the dry run for the box.

## The question

Can a single-node k3s on the box, running Flux + tofu-controller, replace `mgmt-sentinel.sh` /
`mgmt-apply.sh` / `mgmt-probe.sh` as the reconciler ADR-132 describes — with the box's constraints intact:
state and credentials never leave the box, plan text never leaves it, the timer-driven loops' fail-closed
semantics kept or bettered, one closure = the whole cluster?

## What must be answered (kill-order)

1. **Versions.** Does it drive OUR pinned OpenTofu (`devbox.lock`) and the provider mirror
   (`-lockfile=readonly`), or does its runner image dictate tofu/provider versions? A third toolchain beside
   the jail's and the box's is FU-240's skew again.
2. **Our roots as they are.** `main` with `-state=` on a local file; the Garage roots with `TF_ENCRYPTION`
   and `scripts/tofu-state-env.sh` in the runner's environment; per-root credentials from Secrets. Spike
   against the two READ-ONLY roots only (`github`, `cloudflare` — FU-238's plan-only shape): they can plan
   and can change nothing.
3. **The approval model.** `approvePlan` takes a plan id a human commits to git — the human plan as a commit
   on master. See it end to end: plan appears → id lands → apply runs. Compare with `mgmt-human-plan`.
4. **Drift-only mode and visibility.** Where the plan text lives (a Secret in the mini cluster = inside the
   box: "verdict only leaves the box" holds?), what surfaces as status, whether the `management-sentinel`
   commit status can be posted from a notification instead of bash.
5. **Failure legibility.** An unreachable provider, an erroring plan, a stuck state lock: named states with
   an alert path, or silent retries (the responder incident's shape)? What does `kubectl get terraform` show
   at 03:00 to a seat that has never seen the thing?

## What would settle it

Five yes/no answers plus one measured number (RSS of the mini cluster idle). **Yes** = adopt for the box,
ADR-132 gets its mechanism, the bash loops become the fallback. **No** on 1 or 2 = keep hand-rolling and
retire this spike with the reason. **No** on 5 alone = adopt with a belt written first.

## Out of scope

Metal lifecycle (Tinkerbell/Rufio), the management network, control planes — ADR-132/-133 sequence them
after this. Nothing here touches `nixos/hosts/mgmt/`.
