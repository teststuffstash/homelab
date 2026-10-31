# Island facts — the router pair

> The §Island facts block for the **router-pair** island (OPNsense CARP, `.1` VIP; nodes
> `opnsense-nx02` .70 + `opnsense-pve` .71; the test VM and the rebuild drill). Rules:
> [`gateway/intake.md`](../../gateway/intake.md) — this file replaces only its §Island facts and
> island read rows. Island list: [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

- **Repo** `teststuffstash/homelab`; paths `ansible/opnsense-*` + `ansible/roles/opnsense-*` +
  `ansible/group_vars/opnsense.yml`, `ansible/router-nodes/`, `ansible/test-vm/`,
  `ansible/{,roles/}pve-router-killswitch*`, `opnsense/`, `tofu/opnsense-{router,test}.tf`,
  `scripts/opnsense-*`, `argocd/resources/opnsense-config-backup/`.
- **Owning docs to read** (the section the item names): [`router-move.md`](../router-move.md)
  (§Status is the live state), [`opnsense-test-vm.md`](../opnsense-test-vm.md),
  [`management-box.md`](../management-box.md) §Router config converge — BACKUP-only.
- **Membership** — `island_members router-pair` in
  [`intake-select.sh`](../../gateway/scripts/intake-select.sh): title `opnsense` / `carp` /
  `router pair` / `router-move` / `haproxy` / `unbound` / `wireguard` / `dnsmasq`, or every `Touches`
  entry under the prefixes. Bare `router` is NOT a cue — the model router (`openrouter-proxy`) is
  the agent loop's.
- **Write tier** (`classify_touches`, run 2026-10-31): every path above = `machine-merge` (ADR-128's
  narrowed gate). Machine-merge is not the same as safe to queue — see below.
- **How a merge reaches live**: a router-path PR head is applied to the **test VM** by the box and
  posts `opnsense-test-vm` ([`opnsense-test-vm.md`](../opnsense-test-vm.md) header); after merge
  the box converges the **CARP BACKUP only** (`backup-only` mode, ADR-152); the MASTER is converged
  by the seat (`opnsense-router-node.sh converge <node>`).
- **`seat`, always**: any change that needs the MASTER converged, a CARP failover, a window
  (ADR-145's shape), firmware/plugin upgrades (official path, test VM first), the WAN leg, the
  cert carry to the BACKUP (FU-297), the root password or API users (wallet), and anything the
  router-move §Status lists as next. Queue only what the test VM + BACKUP converge prove on their
  own (a play's check-mode fix, a lint, the drill harness, docs).
- Never iterate destructive OPNsense endpoints (`/reboot`, `/poweroff`) — they execute
  ([`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) §Safety).
