# 2026-08-11 — wk-metal-02 lost its IPv4 default route; CI fleet-wide "WAN class" reds + runner starvation

**Impact.** All `homelab-ephemeral` CI concurrency was binpacked on wk-metal-02 (runner pods
request no resources; nodeSelector spans wk-metal-01/-02), so a single node's WAN loss read as a
fleet-wide CI outage: `devbox` package resolution died on `cache.nixos.org` narinfo deadlines
(homelab PRs #250/#251/#254/#255/#260, snore-recorder#15, circles PR#79 — parked by the loop's
ci-red clause after two identical reds), runner AAD token fetches crawled (10–65s) and
`acquirejob` calls failed until the scale set deadlocked at `assigned=4` on stale broker
assignments, with every queued job "Waiting for a runner". Window: first observed red ~09:02Z
(snore#15), diagnosed 10:5xZ, resolved ~11:00Z. Duration of the route loss itself is unknown —
possibly since the previous evening (meta-state recorded the same failure signature then).

## Root cause

wk-metal-02's kernel **IPv4 default route was absent** while its DHCP lease stayed healthy:
`controller-runtime` logs show hourly `DHCP RENEW → ACK` with `Router: 192.168.2.1` in every ACK
(06:05Z…10:05Z), yet `talosctl get routes` had no `inet4/192.168.2.1//1024` row (wk-metal-01,
identical config, had it). Something removed the installed route post-boot and Talos's network
operator did not re-install it — an unchanged OperatorSpec means the controller believes the
route exists. What removed it is **not recoverable post-reboot** (the log buffer only reached
back to 06:05Z, all healthy); do not retro-fit a cause.

Consequences of "LAN fine, WAN dead": pod → LAN mirror 1.25ms while `cache.nixos.org` /
`api.github.com` timed out; nix resolution fell through the (healthy, populated) LAN substituter
to direct WAN and hit the 5s context deadline — the signature previously filed as the "FU-130
WAN class", which this incident shows can be a **node-local route loss, not vendor flake**.

## Diagnosis path (the recipe)

1. Throughput before counters (FU-150 lesson): runner pods `Running` ≠ jobs executing — the
   runner container logs showed `acquirejob` NotFound/Conflict(`MissingKey`)/Socket TryAgain.
2. `githubstatus.com` all-green + `GithubVendorOutage` quiet — correctly, as it turned out;
   a status page is THEIR view either way.
3. **The discriminator: identical probe pods per node** (arc-runner image, node-pinned):
   curl `cache.nixos.org` + `api.github.com` + the LAN mirror. m01: all 200 in ~100ms.
   m02: WAN 000/timeout, LAN 200/1ms → node-local.
4. Cilium clean (maps ~10%, conntrack 342/262k, controllers healthy) →
   `talosctl get routes` → no default → DHCP logs → healthy ACKs → OS-level route loss.

## Remediation

Cordon wk-metal-02 → delete runner pods + ARC listener (a fresh broker session clears the stale
`MissingKey` job assignments — without this the scale set stays pinned at max on ghost
assignments) → runners respawned on wk-metal-01 and the queue drained → `talosctl reboot`
wk-metal-02 → default route back, WAN probes 200/~130ms → uncordon.

## Residuals

- **Detection gap:** nothing alerted. The listener was alive and scaling, so FU-150's proposed
  `AutoscalingListener`-zero signal would NOT have caught this; the **queued-age** alternative
  (cause-agnostic throughput signal) would have. Evidence folded into FU-150.
- The "no WAN fetch remains" confirmation FU-130 is waiting on is falsified for the ARC-runner
  path: when master's locks drift past the baked warm store, devbox resolution reaches
  cache.nixos.org directly (the LAN pull-through is consulted but nix continues to the WAN
  substituter on miss/latency). Sighting noted on FU-130; the runner-image auto-bump (PR#260
  class) is the damper.
- A per-node WAN reachability belt was considered and NOT filed: queued-age covers the CI
  surface, and a node-pinned probe DaemonSet is standing machinery for a once-seen failure.
