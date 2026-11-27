# Island facts — the router pair

> The §Island facts block for the **router-pair** island (OPNsense CARP, `.1` VIP; nodes
> `opnsense-nx02` .70 + `opnsense-pve` .71; the test VM and the rebuild drill). Rules:
> [`islands/intake/rules/intake.md`](../../islands/intake/rules/intake.md) — this file holds only
> the island's facts, under `## Sources` the island's own rows of its §What you read table, and
> under `## What a ride can do` the recipe, write tier, gates and reach. Island list:
> [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

Body shape: edit

- **Repo** `teststuffstash/homelab`; paths `ansible/opnsense-*` + `ansible/roles/opnsense-*` +
  `ansible/group_vars/opnsense.yml`, `ansible/router-nodes/`, `ansible/test-vm/`,
  `ansible/{,roles/}pve-router-killswitch*`, `opnsense/`, `tofu/opnsense-{router,test}.tf`,
  `scripts/opnsense-*`, `argocd/resources/opnsense-config-backup/`.
- **Owning docs to read** (the section the item names): [`router-move.md`](../router-move.md)
  (§Status is the live state), [`opnsense-test-vm.md`](../opnsense-test-vm.md),
  [`management-box.md`](../management-box.md) §Router config converge — BACKUP-only.
- **Membership** — `island_members router-pair` in
  [`intake-select.sh`](../../islands/intake/scripts/intake-select.sh): title `opnsense` / `carp` /
  `router pair` / `router-move` / `haproxy` / `unbound` / `wireguard` / `dnsmasq`, or every `Touches`
  entry under the prefixes. Bare `router` is NOT a cue — the model router (`openrouter-proxy`) is
  the agent loop's.
- **How a merge reaches live**: a router-path PR head is applied to the **test VM** by the box and
  posts `opnsense-test-vm` ([`opnsense-test-vm.md`](../opnsense-test-vm.md) header); after merge
  the box converges the **CARP BACKUP only** (`backup-only` mode, ADR-152); the MASTER is converged
  by the seat (`opnsense-router-node.sh converge <node>`).
- **`seat`, always**: any change that needs the MASTER converged, a CARP failover, a window
  (ADR-145's shape) on a surface the [capability ledger](../management-box.md#the-capability-ledger--what-the-box-has-been-tested-doing-on-its-own-fu-097) lists `attended` or `manual`, firmware/plugin upgrades (official path, test VM first), the WAN leg, the
  cert carry's identity/privileges (the nightly run itself is the box's, FU-297), the root password or API users (wallet), and anything the
  router-move §Status lists as next. Queue only what the test VM + BACKUP converge prove on their
  own (a play's check-mode fix, a lint, the drill harness, docs).
- Never iterate destructive OPNsense endpoints (`/reboot`, `/poweroff`) — they execute
  ([`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) §Safety).

## Sources

How a sitting runs a Prometheus query or a kube read: the LIVE READS block of
[`sitting.sh`](../../islands/intake/scripts/sitting.sh).

| question | read | note |
|---|---|---|
| The pair's live state and what is next (the hand-kept register) | [`router-move.md`](../router-move.md) §Status | as of its own date; anything it lists as next is `seat` |
| Where the routers' config is declared (VIPs, HAProxy frontends, DNS overrides, BGP, DHCP) | [`ansible/group_vars/opnsense.yml`](../../ansible/group_vars/opnsense.yml), the role under `ansible/roles/opnsense-<part>/`, `opnsense/dnsmasq-dhcp.py`; a new address's range: [`ip-plan.md`](../ip-plan.md) | per-service VIP and hostname assignments are [`SERVICES.md`](../../SERVICES.md)'s |
| Which node is the CARP master | Prometheus `router_node_carp_master{job="pve-node"}` | one series per router VM (`host`, `vmid`); exactly one is 1; **experiment** |
| Did the box's last converge of the routers succeed | Prometheus `mgmt_router_verdict_last_result{host="mgmt"}` and `time() - mgmt_router_verdict_last_run_timestamp_seconds{host="mgmt"}` | value 1 on the last `state`; the box converges the BACKUP only; **experiment** |
| Firmware: was each node read, is an update offered | Prometheus `mgmt_router_firmware_read_ok{host="mgmt"}` and `mgmt_router_firmware_update_offered_since_timestamp_seconds{host="mgmt"}` | an upgrade itself is `seat`; **experiment** |
| The rebuild drill's last run and stage | Prometheus `mgmt_opnsense_drill_success{host="mgmt"}`, `time() - mgmt_opnsense_drill_last_run_timestamp_seconds{host="mgmt"}` | **experiment** |
| Age of the config backup | Prometheus `time() - opnsense_config_backup_last_success_timestamp_seconds` | pushed by the `opnsense-config-backup` CronJob; **experiment** |
| The island's alert rules | `argocd/resources/mgmt-metrics/{router-verdict,router-firmware,router-disk,opnsense-drill,cert-carry}.yaml`, [`argocd/resources/opnsense-config-backup/prometheusrule.yaml`](../../argocd/resources/opnsense-config-backup/prometheusrule.yaml), and `RouterPairMasterCount` / `RouterWanGateSilent` / `RouterMasterWanDark` in [`argocd/resources/pve-metrics/prometheusrule.yaml`](../../argocd/resources/pve-metrics/prometheusrule.yaml); as deployed `kubectl -n monitoring get prometheusrules` | `UnboundGithubServfail` lives in `argocd/resources/blackbox/blackbox.yaml` |
| What a router actually runs (its config, a play's check-mode diff) | the recipe in [`runbook.md`](../runbook.md) §OPNsense as code — `scripts/opnsense-playbook.sh` with `--check` | **seat-only**: it needs the router credentials and the LAN; a sitting reads the gauges above and the `opnsense-test-vm` check on the PR instead |

Never: a router endpoint from a sitting; never iterate `/reboot`, `/poweroff`.

## What a ride can do

- **Recipe**: [`.agents/fix.yaml`](../../.agents/fix.yaml) (a `task/build` item: [`.agents/build.yaml`](../../.agents/build.yaml)).
- **Write tier** (`classify_touches` in [`agents/footprint.sh`](../../agents/footprint.sh), run 2026-11-20):
  every path of the island = `machine-merge` (ADR-128's narrowed gate) — `ansible/opnsense-*`,
  `ansible/roles/opnsense-*`, `ansible/group_vars/opnsense.yml`, `ansible/router-nodes/**`,
  `ansible/test-vm/**`, `opnsense/**`, `tofu/opnsense-{router,test}.tf`, `scripts/opnsense-*`,
  `argocd/resources/opnsense-config-backup/**`, `docs/router-move.md`. Machine-merge is not the
  same as safe to queue — the `seat`, always list above decides that.
- **Gates**: `pr-open` runs `devbox run pr-gate` — the CI gates the diff selects plus `scan-secrets`; the map is
  [`scripts/diff-ci.sh`](../../scripts/diff-ci.sh).
  `tofu/*.tf` selects `tofu fmt -check`; `scripts/**` and `opnsense/*.py` select `shellcheck-lint`,
  `sigpipe-lint`, `py-compile-lint`; `argocd/resources/**` selects the manifest and rule lints;
  `ansible/**` selects no gate of its own. The gate that matters is not the ride's: the box
  applies the PR head to the test VM and posts `opnsense-test-vm`.
- **Reach**: the repo's one claim block — the list is [agent-loop.md §What a ride can do](agent-loop.md#what-a-ride-can-do).
  For this island that is the router gauges in Prometheus and nothing else.
- **Not reachable, so intake reads it and writes it into the body**: every router (the pair, the
  test VM, the drill VM), their API and web UI, the hypervisors, the wallet credentials and Loki.
  A ride cannot run a play, even in check mode; a value only the router holds is read by the
  seat and written into the body, or the item is `seat`.
