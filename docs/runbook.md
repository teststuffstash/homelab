# Runbook — operating the homelab

Day-to-day operational recipes and the hard-won gotchas behind them. Companion to
`ARCHITECTURE.md` (shape) and `ROADMAP.md` (what/when). Provisioning a new node has its own doc:
`docs/provisioning.md`.

## Tooling / devbox

All CLI tools come from `devbox.json` (Nix, shared host `/nix`) — nothing is on the bare `$PATH`.

```bash
devbox run -- tofu -chdir=tofu plan          # tofu always with -chdir=tofu
devbox run -- kubectl --kubeconfig tofu/kubeconfig get pods -A
devbox run -- talosctl --talosconfig tofu/talosconfig -n <ip> <cmd>
devbox run nodes        # kubectl get nodes -o wide
devbox run k9s          # cluster TUI
```

Gotchas:
- `nix` needs `export NIX_CONFIG="experimental-features = nix-command flakes"`.
- **`devbox run` writes chatter to STDOUT — never `$(devbox run -- …)` a VALUE without filtering.**
  Use `devbox run -q -- <cmd> | tail -1`, or the plugin/info lines land inside the value. This is
  not hypothetical: on 2026-08-05 a python-plugin line ended up welded into a minted kube token
  (`Directoryexistsbutisnotavalid…eyJhbGciOi…`), and the resulting kubeconfig answered a bare 401,
  which reads exactly like an expired token. Fixed at both ends —
  `tools/stack-jail.sh` filters + shape-gates the JWT, and the plugin no longer talks (below).
- **The python venv must NOT live in the shared workspace.** `devbox.json` sets
  `VENV_DIR=$HOME/.cache/devbox-venv/homelab`, because `/workspace` is the same directory as the
  host's `~/Projects` and a venv's `bin/python` is an **absolute** symlink into whichever project
  root created it. Sharing one `.venv` made the two sides invalidate each other on every single
  run — devbox's `venvShellHook.sh` checks `bin/python` exists, sees a dangling link, prints
  *"Directory exists but is not a valid virtual environment. Creating a new one…"* and rebuilds it,
  forever. `$HOME` differs (`/home/node` in the jail, `/home/rasmus` on the host), so each side
  keeps its own and neither touches the repo. Nothing here uses that venv (ESPHome has its own
  `esphome/.flash-venv`); it exists only because devbox auto-creates one for `python3`.
- `devbox run` runs scripts under **dash** and from the **repo root** regardless of `cwd` →
  use `tofu -chdir=...` / absolute paths, and avoid `bash -c '<multiline>'` (mangles newlines).
  Don't put `source <(... completion)` in `init_hook` — it parse-errors under dash and breaks
  every `devbox run`.
- **The main root runs on the management box since 2026-09-13** (state + creds moved there,
  ADR-129/-131): `devbox run mgmt-tf -- plan|apply` (ssh, committed ref — `MGMT_REF=origin/<branch>`);
  `tf-plan`/`tf-apply` refuse and say so. A PR the sentinel's stage 1 REFUSES (provider/backend/CLI
  surface) gets its required verdict from `devbox run mgmt-human-plan -- <pr>` after you read the
  diff; a full `mgmt-tf apply` of master un-wedges the apply loop. [`management-box.md`](management-box.md) §MB3.
- Tofu's OTHER roots still take secret vars locally — **don't pass them by hand, use the wrappers**:
  `devbox run tf-plan` / `devbox run tf-apply` sourced them via `scripts/tf.sh` (→ `keepass-env.sh`
  reads the KeePass wallet; the GitHub-App key resolves from the cred dir). These work **in the jail
  (`~/.claude`) or on the host (`~/Projects/.claude-data`)** — same dual-path trick as `garage-s3`.
  `proxmox_api_token` + non-secret IDs stay in `tofu/terraform.tfvars`. `devbox run tf-validate`
  needs no secrets. To seed/refresh the wallet (incl. the Forgejo runner token): `devbox run keepass-init`.

## Secrets (out of repo)

The **KeePass wallet** (`~/.claude/homelab-keepass/`, key-file-only) holds ALL Tier-0 values —
OPNsense/Proxmox/Cloudflare/Garage/HA/AWS/droplet/GitHub-App creds (docs/secrets.md).
String secrets: `source scripts/keepass-env.sh` (tofu vars + `CLOUDFLARE_API_TOKEN`/`ACME_CF_TOKEN`).
File-shaped ones (SSH keys, matchbox certs, App PEMs, the `.p12`, esphome `secrets.yaml`):
`bash scripts/wallet-files.sh` regenerates any missing `~/.claude/<dir>/` cache file from the wallet
(tf.sh/github-tf.sh call it automatically). Tofu state/`*.tfvars`/`kubeconfig`/`talosconfig` are gitignored.

## OPNsense as code

OPNsense (router @ .1, currently 26.1.x) is managed with the `oxlorg.opnsense` Ansible collection.
Layout is **thin playbooks → roles**, with config values in `ansible/group_vars/` (see
`ansible/readme.md`): `opnsense-bgp.yml` (FRR/BGP ↔ Cilium), `opnsense-acme.yml` (Let's Encrypt,
**DNS-01 via Cloudflare** — `ACME_CF_TOKEN`, since `teststuff.net` moved off Route53),
`opnsense-haproxy.yml` (HTTPS reverse proxy), `opnsense-unbound.yml` (static DNS overrides),
plus `opnsense/dnsmasq-dhcp.py` (LAN DHCP). **Run them with the wrapper** (handles the httpx
interpreter + creds + `ANSIBLE_CONFIG`):

```bash
bash scripts/opnsense-playbook.sh ansible/opnsense-haproxy.yml          # or any opnsense-*.yml
bash scripts/opnsense-playbook.sh ansible/opnsense-unbound.yml -e ...    # extra args pass through
```

Why the wrapper exists (the non-obvious bits):
- `oxlorg.opnsense` needs **`httpx`**, provided by the pinned nix flake `ansible/controller-env/`.
- **`devbox run` strips `ANSIBLE_PYTHON_INTERPRETER`**, and that env var is ignored for the implicit
  localhost anyway → the interpreter must be passed as **`-e ansible_python_interpreter=...`**.
- The collection isn't preinstalled in a fresh jail (`ansible-galaxy collection install -r
  ansible/collections/requirements.yml`).
- Collection pin must track os-frr / OPNsense version (currently `oxlorg.opnsense==25.7.8` for
  os-frr 1.52 / OPNsense 26.1).

Settings with **no API at all** (legacy pages — a GUI click by necessity, recorded here so nobody
hunts for a playbook; each one names the code it affects):
- **Interfaces → Settings → *Turn off IPv6*** (`system.ipv6allow`): OPNsense derives Unbound's
  `do-ip6` from it (`unbound.inc`). **Ticked 2026-09-16** (FU-215): the WAN has no IPv6, so
  `do-ip6: yes` made every github resolution burn its send budget on unreachable v6 authoritatives
  (`SERVFAIL … exceeded the maximum number of sends`). Leave it ticked until the WAN has v6.

API/module gotchas:
- The generic **`raw`** module is the escape hatch for plugins with no/incompatible module (HAProxy
  backend/frontend/server). **Mutating `raw` commands need `action: post`** — they default to `get`
  and silently no-op (`{"result":"failed"}`).
- `unbound_host` **saves but does not apply** — Unbound keeps serving the old answer until you POST
  `/unbound/service/reconfigure` (the `opnsense-unbound` role's handler does this). Match on
  `[hostname, domain, record_type]` (exclude `value`) to update-in-place on a repoint.
- Verify a DNS record bypassing the jail's stale Docker/host cache: `devbox run -- dig +short
  <name> @192.168.2.1` (jail `getent` caches the pre-change answer).
- ACME: os-acme-client doesn't persist the cert `description`, so the module can't adopt
  GUI-created certs → playbooks are create-if-absent guarded on name.
- ⚠️ Never iterate destructive firmware endpoints (`/firmware/reboot`, `/poweroff`) with a real
  body to "discover" them — they execute.

### Expose an in-cluster service over HTTPS (`<name>.teststuff.net`)

1. Edit `group_vars/opnsense.yml`: add the hostname to **`acme_cert_specs`** (`restart_action: "reload
   haproxy"`) and a **`haproxy_proxied_services`** entry `{ name, cert_domain, vip, backend_ip,
   backend_port }`. Each frontend needs its **own IP-alias VIP from `192.168.3.0/24`**
   (`docs/ip-plan.md`, ADR-088 — never inside the `.2.x` host range; convention: last octet mirrors
   the backend's `40.x` octet). The haproxy role auto-creates the Unbound override (`name → vip`)
   and rebinds the frontend if a vip changes (stale alias/override cleanup is via API — see the
   `group_vars/opnsense.yml` header). ⚠ **A VIP-alias reconfigure flushes the FRR kernel routes**
   (all `40.x` black-holes while BGP still shows Established): recover with a real FRR cycle —
   `api/quagga/service/stop` + `start` (the `restart` endpoint is a no-op) — then confirm
   `40.x` rows in `api/diagnostics/interface/get_routes`. Full story: `group_vars/opnsense.yml`.
2. Run **in this order**:
   - `bash scripts/opnsense-playbook.sh ansible/opnsense-acme.yml` — creates the cert spec **and now
     signs + polls it to `statusCode == 200`** before returning (FU-078, resolved 2026-07-15: the role
     signs any spec'd cert that isn't issued yet and waits ~30–60s for DNS-01). No manual sign step.
     _Fallback if a cert is somehow stuck unsigned:_ `POST /api/acmeclient/certificates/sign/<uuid>`
     (uuid from `certificates/search`), poll `statusCode == 200`, or *ACME → Certificates → (sign)*.
   - `bash scripts/opnsense-playbook.sh ansible/opnsense-haproxy.yml` — server/backend/frontend + VIP.
3. If the backend app emits absolute URLs, point its base URL at the https name (e.g. Forgejo
   `gitea.config.server.ROOT_URL = https://<name>.teststuff.net/` in `tofu/forgejo.tf`).
4. Verify: `devbox run -- dig +short <name>.teststuff.net @192.168.2.1` → the VIP; `curl -sI
   https://<name>.teststuff.net` → 200; `echo | openssl s_client -connect <name>.teststuff.net:443
   -servername <name>.teststuff.net | openssl x509 -noout -subject` → CN matches (not `opnsense...`).

⚠️ **If you ran haproxy *before* the cert was signed**, the frontend was created with an empty cert
(`certRefId` was blank) and serves the default `opnsense.teststuff.net` cert → TLS CN mismatch (`curl`
exit 60 / HTTP 000). The haproxy role is **create-if-absent**, so a plain re-run won't re-link it —
**delete the `<name>-frontend`** (`POST /api/haproxy/settings/delFrontend/<uuid>`) and re-run
`opnsense-haproxy.yml` so it recreates the frontend with the now-issued `certRefId`. (Done for
`forgejo.teststuff.net` → VIP `.9` → `192.168.40.15:3000`, 2026-06-11.)

### Delegate a stack subdomain (`*.<stack>.teststuff.net`, opt-in — ADR-092)

Give a stack self-service over its own hostnames: homelab wires the wildcard ONCE, then the stack
adds names as HTTPRoutes in its `-iac` repo with **no homelab change**. Prereq (once, platform):
Gateway API CRDs + `gatewayAPI.enabled` in Cilium + the `cilium` GatewayClass (see the ADR-092
rollout below). Per stack:

1. **homelab** — `group_vars/opnsense.yml`: add a wildcard cert to `acme_cert_specs`
   (`{ name: <stack>-wildcard, alt_names: ["*.<stack>.teststuff.net"], restart_action: "reload
   haproxy" }`) and a `stack_gateways` entry (`{ name, cert_domain: <stack>-wildcard,
   wildcard_domain: <stack>.teststuff.net, vip: 3.x, backend_ip: 40.x, backend_port: 80 }`) — pick a
   free `3.x ↔ 40.x` pair. Run `opnsense-acme.yml` then `opnsense-haproxy.yml` (same VIP-flush caveat
   as above). The role now also writes the **wildcard** Unbound override `*.<stack> → vip`.
2. **stack `-iac` repo** — a `Gateway` (`gatewayClassName: cilium`, `spec.addresses` = the `40.x` VIP,
   `spec.infrastructure.labels.bgp: advertise`, an HTTP `:80` listener `hostname: "*.<stack>.teststuff.net"`)
   + one `HTTPRoute` per hostname. Cross-namespace backends need a platform-owned `ReferenceGrant` in
   the target ns. Reference: `argocd/platform/gateway*.yaml`, oracle-iac `oracle-fleet/infra/gateway.yaml`.
3. Verify: `dig +short anything.<stack>.teststuff.net @192.168.2.1` → the VIP (wildcard resolves);
   `kubectl get gateway,httproute -n <stack-ns>` → Programmed/Accepted; `curl https://<svc>.<stack>.teststuff.net`.

### Retire a per-name HTTPS entry

Removing a `haproxy_proxied_services`/`acme_cert_specs` entry does **not** delete the live objects
(the role is create-if-absent). API-delete the orphans: the `<name>-frontend`
(`POST /api/haproxy/settings/delFrontend/<uuid>`), `<name>-backend` (`delBackend`), `<name>-srv`
(`delServer`), the IP-alias VIP (`interfaces/vip_settings/delItem/<uuid>` — ⚠ triggers the FRR flush,
cycle FRR after), the Unbound host override (`unbound/settings/delHostOverride/<uuid>` + reconfigure),
and the ACME cert (`acmeclient/certificates/removeCertificate/<uuid>`). Then reconfigure haproxy.
(Used at the oracle-specs → specs.oracle cutover, 2026-07-15 — ⚠ the OLD name/VIP
(`oracle-specs.teststuff.net` / 3.20) is deliberately KEPT LIVE until the oracle stack migrates
it — `ansible/group_vars/opnsense.yml` says so, and both names serve 200 as of 2026-08-11.)

### LAN DHCP / DNS

LAN DHCP was migrated **ISC dhcpd → dnsmasq** (ISC has no settings API). `opnsense/dnsmasq-dhcp.py`
rebuilds it idempotently (range .10–.245, gateway/DNS .1, domain `teststuff.net`, static
reservations incl. the metal nodes). dnsmasq is **DHCP-only** (`port=0`) so Unbound keeps `:53`.
PXE is NOT served here — it's a separate dnsmasq proxy-DHCP on the Matchbox LXC (see provisioning).
ISC DHCPv4 is fully disabled (stopped **and** unchecked in the UI — reboot-safe); dnsmasq is the
only LAN DHCP.

## Storage (Longhorn)

`tofu/longhorn.tf` — Helm 1.12.0, `longhorn` is the **default StorageClass** (replica=2, zone
soft-anti-affinity). All stateful services use Longhorn PVCs (not node-pinned). ⚠ **Since
2026-09-12 the `std` tier has exactly TWO schedulable nodes** (m70s + hp-01; wk-02 left the tier
for good on 2026-09-14 and thinkcentre left cluster duty), so every r=2 std volume must hold
one copy on each — soft anti-affinity means a capacity squeeze surfaces as SILENT co-location,
not a Pending volume. The `longhorn-fast` SC (replica=1, node-local; SCRATCH for disk-write-heavy
pods — eligibility ruling in `docs/storage-ledger.md`) has **no backing disk** until the Optane
pair lands on wk-metal-04 (FU-234); registration is `scripts/longhorn-register-optane.sh <node>`,
the mounts come from that node's `longhorn_disks` in `machines/machines.yaml` (`tofu/metal.tf`
only consumes it).

- ⚠️ **Never `talosctl upgrade` a Proxmox *nocloud* VM without its exact Image Factory nocloud
  installer** — a generic installer loses the cloud-init static IP/hostname and it rejoins as a
  DHCP/default-name ghost. `scripts/node-maintenance.sh upgrade` reads the platform, schematic and
  version from tofu and refuses an implicit extension change; control planes use
  `devbox run cp-upgrade -- <node>`. See `docs/provisioning.md` for the complete recipe.
- Longhorn disk mounts must be **under `/var/lib/longhorn`** — longhorn-manager only host-mounts
  that path. A disk with a pre-existing filesystem wedges Talos boot → `talosctl wipe disk` first.
- Stuck `instance-manager`/`longhorn-manager` after node churn → `kubectl delete` the pod (the
  DaemonSet recreates it).
- **WoL recovery** (tested on hp-01): `talosctl shutdown` → S5, then a magic packet from a host on
  the same L2 segment (the jail is NAT'd and can't — but Proxmox/OPNsense/another metal node can).
  Set BIOS boot order disk-first or wake→Ready takes ~5 min of PXE timeouts. **Recipe** — send from
  Proxmox over SSH (works from the jail; verified 2026-06-19):
  ```bash
  ssh -i ~/.claude/homelab-pve-ssh/id_ed25519 -o IdentitiesOnly=yes root@192.168.2.3 \
    'python3 -c "import socket; m=bytes.fromhex(\"b4b52fdf01bc\"); p=b\"\xff\"*6+m*16; \
     s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(1,6,1); \
     s.sendto(p,(\"255.255.255.255\",9))"'
  ```
  Physical NIC MACs (from `opnsense/dnsmasq-dhcp.py` reservations): hp-01 `b4:b5:2f:df:01:bc`,
  wk-metal-01 `50:7b:9d:01:b3:54`, wk-metal-02 `68:f7:28:80:84:09`,
  m70s `e0:be:03:3d:8a:d1` (⚠ WoL **untested** on this box; its BIOS is PXE-first, so a wake that
  does reach it netboots — which is the console-free reinstall path, not a fault).
  (NB: a plain `talosctl reboot` keeps the node powered → it returns on its own; WoL is only for an
  S5/powered-off node.)

### Reading a fleet disk's identity and health (SMART, link, wear)

Talos gives no shell, so a disk question on a cluster node is answered by an **ephemeral privileged
pod pinned to that node**. This is the probe that identified wk-metal-04's SA400 and its degraded
SATA link (`docs/storage-ledger.md` §2026-09-05) and read the M70s's OEM NVMe at onboarding — it
was re-improvised both times before being written down here (FU-222).

```bash
SP=<your scratchpad>
cat > $SP/diskprobe.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: diskprobe, namespace: kata-spike }
spec:
  nodeName: <NODE>                 # pins the probe; without it you read some other box
  restartPolicy: Never
  hostPID: true
  tolerations: [{ operator: Exists }]     # so it lands on tainted/ephemeral nodes too
  containers:
    - name: probe
      image: alpine:3.20
      command: ["sh","-c","apk add --no-cache nvme-cli smartmontools >/dev/null 2>&1;
        nvme smart-log /dev/nvme0n1 | grep -iE 'critical_warning|percentage_used|available_spare|power_on_hours|power_cycles|unsafe_shutdowns|media_errors|^temperature';
        nvme id-ctrl /dev/nvme0n1 -H | grep -iE '^fr |^mn |^sn |oacs';
        cat /sys/class/nvme/nvme0/device/current_link_speed /sys/class/nvme/nvme0/device/current_link_width;
        smartctl -a /dev/sda | grep -iE 'Device Model|Percentage Used|Power_On_Hours|CRC_Error|SATA Version|Wear'"]
      securityContext: { privileged: true }
      volumeMounts: [{ name: dev, mountPath: /dev }, { name: sys, mountPath: /sys }]
  volumes:
    - name: dev
      hostPath: { path: /dev, type: Directory }
    - name: sys
      hostPath: { path: /sys, type: Directory }
EOF
devbox run -- kubectl --kubeconfig tofu/kubeconfig apply -f $SP/diskprobe.yaml
devbox run -- kubectl --kubeconfig tofu/kubeconfig -n kata-spike wait --for=condition=Ready pod/diskprobe --timeout=120s
devbox run -- kubectl --kubeconfig tofu/kubeconfig -n kata-spike logs diskprobe      # apk install takes ~20s; re-read if short
devbox run -- kubectl --kubeconfig tofu/kubeconfig -n kata-spike delete pod diskprobe
```

Which fields actually decide something:

- **`percentage_used`** (NVMe) / **`Percentage Used Endurance Indicator`** (SATA) — the standardized
  wear figure, and the one to trust. ⚠ Kingston SA400's vendor attribute 231 `SSD_Life_Left` reads
  a *different* number for the same drive (6 vs 5 %); prefer the standardized field.
- **`current_link_speed` / `current_link_width`** (NVMe) or `SATA Version ... current:` — a drive
  negotiating below its rating is the wk-metal-04 signature. Pair with the SATA
  `UDMA_CRC_Error_Count`: a climbing CRC counter means the **cable**, not the drive.
- **`oacs` bit 0 "Security Send and Receive Supported"** says the drive *has* TCG/Opal, not that it
  is locked — an Opal-locked drive does not present a usable namespace at all.
- **`unsafe_shutdowns` vs `power_cycles`** — context for an ex-office pull, not a fault on its own.

`nodeName` + `tolerations: Exists` are the two lines people drop; without them the pod schedules
somewhere else or refuses to land on the tainted node you wanted to read.

### Single worker maintenance window (cordon → drain → shutdown → wake)

For one WORKER at a time (metal or VM) — a SATA cable, a RAM swap, a BIOS change — the
deterministic path is **`devbox run node-maintenance {preflight|down|up} <node>`**
(`scripts/node-maintenance.sh`; first run: wk-metal-04, 2026-09-06). `preflight` is read-only and
computes "safe to pull the plug": node Ready + Talos API reachable; **no degraded attached Longhorn
volume anywhere**; every ATTACHED volume with a replica on the node has a running sibling
elsewhere (FAIL — the drain would block on it); a DETACHED volume whose last replica is stopped on
the node is a WARN — its data is offline for the window and returns with the disk, and the drain
is allowed because the cluster runs `node-drain-policy=allow-if-replica-is-stopped`
(`tofu/longhorn.tf`, 2026-09-09: the default `block-if-contains-last-replica` blocked thinkcentre's
window on two detached replica-1 transcripts volumes — replica-1 classes are by design);
an ATTACHED last replica and any ride / Argo Workflow / coordinator pod are the **settle** class:
**`settle`** cordons the node, waits for transient consumers to finish (bare pods, Jobs,
Workflows, anything in an agent namespace; ≤ `SETTLE_TIMEOUT` 3600 s) and MOVES a last replica a
long-lived pod holds (StatefulSet/Deployment: `numberOfReplicas`+1 → rebuild elsewhere → delete
the local replica → restore the count; `DRY=1` reports instead of acting). `down` runs it before
the drain, so a drain is never left to block on Longhorn's PDB (operator direction 2026-09-09);
no volume attached on the node; then the workload read — StatefulSet pods, Argo/agent ride pods
and single-replica Deployments are WARNs (`FORCE=1` accepts them). `down` runs preflight, cordons,
drains (DaemonSets ignored), confirms Longhorn's node view, then `talosctl shutdown` and waits for
NotReady. `up` sends WoL from pve for a metal node (MAC from `opnsense/dnsmasq-dhcp.py`), waits
Ready, uncordons, then waits until the Longhorn node is Schedulable and every attached volume is
healthy again. Replicas on the node go degraded for the window; Longhorn starts rebuilding them
elsewhere after `replica-replenishment-wait-interval` (600 s) — a longer window just means a
re-sync when the node returns. cp-01 is out of scope (only control plane → §Proxmox host
maintenance window).

**The window also declares itself to the alert path, in two halves that cover different label
shapes** (FU-230; `SILENCE=0` opts out of both). `settle`/`down` open Alertmanager silences keyed on
`node`, `instance`, the node's pod names and — on a zone node — the Garage health set, and `up`
expires them; those silences live on an emptyDir, so a monitoring restart mid-window drops them
(FU-195). They cannot reach the rollout class at all: `KubeDaemonSetRolloutStuck` and kin carry
neither `node` nor `instance`, and the pod that goes Pending is minted AFTER the silence. So the
same acts also open a **declared window** ([`agents/seat-window.sh`](../agents/seat-window.sh) → a
ConfigMap the responder reads, [glossary](glossary.md)) naming those alert NAMES, which suppresses
the LLM triage for them only — they still fire, still notify, still show in Grafana. Declare one by
hand for work this script does not drive (a Proxmox host window, a cable):
`bash agents/seat-window.sh open --reason "…" --alerts A,B --hours 3`, then `close --node <n>`;
`list` shows what is live.

Two lessons from the first run:

- **WoL does not survive an AC cut.** The NIC is armed by the previous boot and only on standby
  power — a box that was unplugged for the work needs the button once. `up` says so after 120 s
  without a ping and keeps waiting.
- **Replaced replicas leave orphans on the returning disk.** During a window longer than
  `replica-replenishment-wait-interval` Longhorn rebuilds the node's replicas elsewhere and the
  old directories come back as `orphans.longhorn.io` — still counting as used space. wk-metal-04's
  141G stale Garage copy pushed the disk under the 25 % minimum-free rule and blocked the Garage
  volume's own rebuild onto it ("insufficient storage") until the orphans were deleted.
  `orphan-resource-auto-deletion=replica-data` (tofu/longhorn.tf) now removes them after 300 s;
  `up` lists whatever is left and `DELETE_ORPHANS=1` removes them once every volume is healthy.

### Retire a node from cluster duty (decommission)

The reverse of the onboarding list (`.claude/skills/onboard-metal-node`) — the same "nothing
fails when you skip it" property applies, so it is a checklist. First run: `thinkcentre`,
2026-09-12 (it left to be the R12 management-box pilot). Order matters where noted.

1. **Storage out first.** Evict the node's Longhorn replicas and let them rebuild elsewhere —
   ⚠ check the TARGET capacity before starting, because `replica-soft-anti-affinity=true` means
   a tier without room silently CO-LOCATES both copies of a volume instead of refusing:
   ```bash
   K="devbox run -- kubectl --kubeconfig tofu/kubeconfig"
   $K -n longhorn-system patch nodes.longhorn.io <node> --type=merge \
     -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
   # watch to zero (thinkcentre: 16 replicas, 3 min 19 s), degraded must stay 0
   $K -n longhorn-system get replicas.longhorn.io -o json | jq '[.items[]|select(.spec.nodeID=="<node>")]|length'
   ```
   Then the co-location check — **no volume may have two running replicas on one node**:
   ```bash
   $K -n longhorn-system get replicas.longhorn.io -o json | jq -r \
     '[.items[]|select(.status.currentState=="running")]|group_by(.spec.volumeName)[]
      |{v:.[0].spec.volumeName,n:[.[].spec.nodeID]}|select((.n|unique|length)!=(.n|length))|.v'
   ```
2. **De-declare it in the inventory, and apply BEFORE the node object is gone.** In
   `machines/machines.yaml` remove the Talos flags (`talos_metal_node`, `install_disk`,
   `longhorn_disks`, `pin_hostname`, `zone`) — keep the entry itself if the box still exists; it
   is the machine inventory, not a cluster list — then `devbox run -- python3 machines/generate.py`
   and drop the node from `local.longhorn_zones` (`tofu/longhorn.tf`) if it was a storage node.
   `devbox run tf-plan` must show exactly the node's own destroys (its
   `talos_machine_configuration_apply` + `kubernetes_labels`); the label destroy PATCHes the live
   node, so run it while the node object still exists.
   ⚠ **Read the plan for OTHER nodes' updates**: a parked, already-applied declaration PR makes a
   plan want to push a stale config to a different box (2026-09-12: master's hp-01 config predated
   PR#1606 and an apply would have dropped the 7600p mount that had just taken evicted replicas).
   Merge that PR and rebase first.
3. **Drain + shut down with the alert window declared:**
   `FORCE=1 devbox run node-maintenance down <node>` (§Single worker maintenance window — it
   silences the node's alerts, so the retirement does not cost the responder lane a session).
4. `kubectl delete node <node>` — the `nodes.longhorn.io` CR is auto-GC'd with it (verify).
5. **BGP neighbour out.** Drop the IP from `bgp_node_ips` in `ansible/group_vars/opnsense.yml`,
   then DELETE the live object — the role is create-if-absent, so re-running the playbook reports
   `changed=0` and leaves the neighbour configured (same class as §Retire a per-name HTTPS entry).
   A one-shot play with `oxlorg.opnsense.frr_bgp_neighbor: {peer_ip: <ip>, match_fields: ['ip'],
   state: absent}`, then verify against the router:
   `curl -sk -u "$K:$S" https://192.168.2.1/api/quagga/bgp/get | jq '.bgp.neighbors.neighbor'`
   → one entry per remaining node, nothing else. A neighbour with no cilium-agent behind it sits
   `active`/`connect` forever, which looks exactly like the onboarding miss the list prevents.
6. **The DHCP reservation and the smart plug STAY** if the box stays on the LAN (`opnsense/`,
   `homeassistant/`) — the machine still needs an address and a power path. Remove the MAC from
   §WoL recovery above (that list is for cluster recovery) and never re-add a Matchbox group for
   it (`tofu/provisioning/matchbox.tf`) unless you intend a reinstall.
7. **The doc rows the onboarding list names**, in reverse: `docs/provisioning.md`,
   `tofu/README.md`, `docs/network-physical.md`, `docs/storage-ledger.md` (tier tables + a ledger
   row for the eviction), `SERVICES.md` (if a tier or service changed), `ROADMAP.md`. The
   power/benchmark rows STAY — the box still draws watts.

### Re-imaging a node (change install extensions)

Metal nodes and nocloud VMs upgrade in place when passed their exact declared installer. Use
`scripts/node-maintenance.sh upgrade <node>`; it handles the control-plane endpoint, drain and
reboot, and verifies both version and schematic after rejoin. A schematic change is refused unless
`ALLOW_SCHEMATIC_CHANGE=1` explicitly makes the operation a re-image. The current metal schematic
is `image.tf` `talos_image_factory_schematic.metal` (iscsi-tools + util-linux-tools, no
qemu-guest-agent — the latter hung the boot on bare metal).

### Reclaiming thin-pool space from a Talos VM
Deleting data inside a Talos VM does **not** return blocks to the hypervisor's LVM thin pool.
Nothing in the guest issues TRIM, so the pool only ever grows — wk-02's guest held 118G while its
thin volume was 96.95% allocated, and pve's pool reached **99.14%** (at 100% every VM on that pool
goes read-only together).

**Which box and which pool — read this off the alert, do not assume.** There are two hypervisors,
each with its own pool, and a trim on one returns nothing to the other. Every `PveThinPool*` alert
carries `host` / `vg` / `lv`; the pairs today are:

| `host` | ssh | VG / pool LV | Talos VMs on it |
|---|---|---|---|
| `pve` | `192.168.2.3` | `pve` / `data` (Proxmox storage `local-lvm`) | cp-01, wk-01, wk-02, wk-03 (+ ci-runner-01, not a k8s node) |
| `nx-02` | `192.168.2.59` | `nvme-thin` / `data` (Proxmox storage `nvme-thin`) | wk-04 |

Below, `<host>`, `<vg>` and `<vmid>` are that row's values; the worked numbers are pve's.

Two prerequisites, then the trim:

1. **`discard=on` on the disk** (`ssd=1` too, it makes the guest advertise TRIM support). Set by
   tofu on every VM (`proxmox.tf` / `nx02.tf`), so this is a check, not a step — but it is a
   PENDING change when newly set: it needs a VM stop/start, not just a config write. `qm reboot`
   applies it.
   ```
   qm set <vmid> --scsi0 <storage>:vm-<vmid>-disk-0,...,discard=on,ssd=1   # e.g. 8112 / local-lvm
   qm pending <vmid> | grep scsi0     # cur == new once applied
   ```
2. **Run `fstrim` from a privileged pod on the node.** This is the part that surprises:

   **This is automated since 2026-08-25** — `argocd/resources/node-fstrim/` runs exactly this,
   twice daily on every pool VM (both hypervisors), with a reactive guard every 15 min above 79 %,
   and alerts if it stops (`NodeFstrimStale`). Reach for the manual form below only for a one-off
   on a node the CronJob does not cover (ci-runner-01) or when you need the reclaim NOW.

   ```
   kubectl run <node>-fstrim -n kata-spike --image=alpine:3.20 --restart=Never \
     --overrides='{"spec":{"nodeName":"<node>","tolerations":[{"operator":"Exists"}],
       "containers":[{"name":"fstrim","image":"alpine:3.20","command":["fstrim","-v","/hostvar"],
       "securityContext":{"privileged":true},
       "volumeMounts":[{"name":"hostvar","mountPath":"/hostvar"}]}],
       "volumes":[{"name":"hostvar","hostPath":{"path":"/var","type":"Directory"}}]}}'
   ```
   Use a namespace with `pod-security.kubernetes.io/enforce: privileged` (`kata-spike`,
   `longhorn-system`, `monitoring`). Verify on the node's OWN hypervisor:
   `ssh root@<host-ip> lvs -o vg_name,lv_name,data_percent`.

⚠ **Two approaches that look right and do NOT work** (both tried 2026-08-07, keep them dead):
- **`qm guest cmd <vmid> fstrim`** returns `{"paths": []}` and trims nothing. Talos' qemu-guest-agent
  does not enumerate the guest's filesystems — `qm agent <vmid> get-fsinfo` returns `[]`.
- **Mounting the guest partition on the hypervisor** (`losetup -P` + `mount /dev/loopNp5`) fails:
  `XFS: Superblock has unknown incompatible features (0xc0)` — Talos formats EPHEMERAL with XFS
  feature bits newer than the Proxmox kernel can mount. It refuses safely, but note the trap: if
  the mount fails and you run `fstrim` against the intended mountpoint anyway, you silently trim
  the **hypervisor's own root** instead. Check `mount` succeeded before trimming.

There is no `talosctl fstrim`, and Talos' `VolumeConfig` for EPHEMERAL exposes no `discard` mount
option, so this pod is the mechanism. Applies to every VM in the table above.

## CloudNativePG (Postgres)

CNPG `Cluster`s (`infisical-pg`, `forgejo-pg`) run with `enablePodMonitor` + the `cnpg`
PrometheusRule group and Grafana dashboard (`tofu/dashboards/cnpg.json`) — added after forgejo-pg-2
sat as a broken replica for 2.5 days unnoticed (2026-06).

- **Broken-replica recovery** (crash-loop on `pg_rewind: could not find common ancestor of the
  source and target cluster's timelines` after a failover, readiness 500): no data loss if the
  primary is intact — delete the replica's PVC **and** pod so CNPG re-clones it via `pg_basebackup`:
  `kubectl -n <ns> delete pvc <cluster>-N; kubectl -n <ns> delete pod <cluster>-N` (it returns as
  the next instance number, e.g. `-2` → `-3`). If a replica re-diverges, suspect the node it landed on.

## Proxmox host maintenance window (updates + reboot)

The hypervisor is deliberately the one hand-managed box (boot-from-git covers everything above
it); its routine package maintenance is code anyway: `devbox run -- ansible-playbook
ansible/pve-upgrade.yml` (ANSIBLE_CONFIG=ansible/ansible.cfg; SSH key is jail-local). The play
snapshots `/etc/pve` to `~/.claude/homelab-pve-backup/`, runs an IN-MAJOR `apt dist-upgrade`
(8→9-style major jumps are a separate, sources-edit event), and reports REBOOT-PENDING — it
never reboots. The host's thin pool is metered the same way — `devbox run -- ansible-playbook
ansible/pve-node-exporter.yml` puts node_exporter + a textfile timer on pve (FU-093; alerts
`PveThinPool*`/`PveVmIoError` in `argocd/resources/pve-metrics/`; re-run after a reinstall).
**A VM that reboots itself with nothing in the ring buffer** (wk-03, five times in a week —
homelab#882, `NodeRebootingRepeatedly`) gets a **serial console**: `serial = true` on the node in
`tofu/variables.tf` (→ `serial_device {}` in `proxmox.tf`; Talos already boots with
`console=ttyS0`), applied at a FULL stop/start of the VM — a guest reboot keeps the qemu
process, so pending hardware never lands that way; use `scripts/node-maintenance.sh down <node>`
→ `devbox run mgmt-tf -- apply` (the provider starts the stopped VM) → `up <node>`. The host
side is `devbox run -- ansible-playbook ansible/pve-serial-log.yml` (vmid list in
`ansible/group_vars/pve.yml`): a `qemu-serial-log@<vmid>` socat unit on pve appends the console
to `/var/log/qemu-serial/<vmid>.log` (logrotate weekly ×8) — the kernel's last words on a panic
are there, read them with `ssh root@192.168.2.3 tail -n 200 /var/log/qemu-serial/8113.log`. The
chardev takes one client, so `qm terminal <vmid>` needs the logger stopped first.
When a pool VM goes NotReady with its Talos API "no route to host", read the hypervisor FIRST:
`qm status <vmid> --verbose | grep qmpstatus` (`io-error` = paused on a failed write) and
`lvs -o lv_name,data_percent pve`. The reboot is a window (first run: 2026-08-18, ~15 min total outage):

1. **Pre-flight:** Longhorn 0 degraded volumes; no agent rides mid-flight you care about.
2. **Full-stop, not drain** — cp-01 is the only control plane, so the API goes down either
   way; metal workloads keep running headless, and a clean stop is just the planned version of
   the whole-lab power loss the platform already survives (§Power-loss below).
3. `qm shutdown` workers + ci-runner + `pct shutdown 210` (parallel is fine), **cp-01 LAST**,
   then `poweroff` on pve. wk-01/wk-02 take longest (Longhorn detach).
4. All guests + the LXC carry `onboot=1` and the X99 powers on after AC restore — on boot
   everything self-starts and the cluster reforms with no hands (verified: 10/10 Ready,
   ~10 min plug-out to all-Ready).
5. **Post:** `devbox run nodes` all Ready · Longhorn degraded count returns to 0 (replica
   re-sync is normal for ~minutes) · new kernel active (`uname -r`).

## Power-loss / ghost-node recovery

Historically, after a **simultaneous cold power-cycle** (whole lab loses power), metal Talos nodes
could rejoin under generated `talos-xxx` hostnames — they DHCP-discover before OPNsense's dnsmasq
is back up, so Talos can't get its reserved hostname and makes one up. **Metal hostnames are now
pinned** via an install-time `HostnameConfig` patch (the node's `pin_hostname` field in
`machines/machines.yaml`, default on; `tofu/metal.tf` only consumes it), so this shouldn't recur.
If a ghost still appears (e.g. a node was reinstalled without the patch): symptoms are `kubectl get
nodes` showing `talos-xxx` ghosts next to (or instead of) the real metal names, and volumes failing
to attach (Multi-Attach / "driver.longhorn.io not found"). Recover with reboots:

1. **Reboot each ghosted metal node** to reclaim its reserved hostname (dnsmasq is healthy now):
   `devbox run -- talosctl --talosconfig tofu/talosconfig -n <ip> reboot`. Do storage nodes
   (hp-01/m70s) **one at a time** (talosctl reboot blocks until healthy). The node returns
   as its real name; the `talos-xxx` object goes NotReady.
2. **If a Longhorn volume is wedged:** force-delete the stuck `discover-proc-kubelet-cmdline` pod
   (`kubectl -n longhorn-system delete pod discover-proc-kubelet-cmdline --force --grace-period=0`)
   to unblock the CSI driver; force-delete any workload pods stranded on ghost nodes to clear a
   Multi-Attach (`kubectl -n <ns> delete pod <p> --force --grace-period=0`), then delete+recreate
   the live workload pod so the RWO volume attaches.
3. **Delete the stale ghost k8s nodes:** `kubectl delete node talos-aaa talos-bbb ...` (only once
   the real names are back Ready).
4. **Clean stale Longhorn node CRs** (deletion is refused while schedulable): `kubectl -n
   longhorn-system patch nodes.longhorn.io <ghost> --type=merge -p
   '{"spec":{"allowScheduling":false,"evictionRequested":true}}'` — Longhorn then auto-GCs them.
5. **Verify:** `devbox run nodes` (real names only, Ready), all Longhorn volumes `attached`+`healthy`.

(VMs are unaffected — they get their identity from nocloud, not DHCP timing.)

### Loki crash-looping after a hard node power-off (tsdb-index WAL corruption)

Symptom: `loki-0` in CrashLoopBackOff, last log line `error running loki … corruption in segment
/loki/tsdb-index/wal/<period>/<n>/<seg> … unexpected checksum` — the index head WAL took a hard
stop mid-write (2026-09-09: hp-01's plug cycle; Loki was down 11.5 h before anyone read the
alert). The PVC is RWO on Longhorn, so a helper pod **pinned to the same node** can mount it
alongside the crashing pod; scaling the StatefulSet is not needed (and ArgoCD selfHeal would undo it):

```bash
K="devbox run -- kubectl --kubeconfig tofu/kubeconfig"
NODE=$($K -n loki get pod loki-0 -o jsonpath='{.spec.nodeName}')
# helper: busybox, nodeName=$NODE, runAsUser/fsGroup 10001, PVC data-loki-0 at /loki, sleep 600
$K -n loki exec loki-wal-fix -- sh -c 'mkdir -p /loki/wal-corrupt-$(date +%F) && mv /loki/tsdb-index/wal/<period>/<n> /loki/wal-corrupt-$(date +%F)/'
$K -n loki delete pod loki-wal-fix loki-0     # loki-0 restarts clean; Ready in ~1 min
```

What is lost: the unflushed chunks the ingester held (they died with the pod) and the index
entries in that segment — for the outage window, every tenant. Nothing else needs repair.
Multiple corrupt segments: the next restart names the next one; repeat.

## Home Assistant

Deployed in-cluster (`tofu/homeassistant.tf`), VIP `192.168.40.10:8123`, HTTPS at
`homeassistant.teststuff.net` via OPNsense HAProxy. Config kept in `homeassistant/ha-config/`,
applied imperatively (`kubectl cp` + restart). Token in the wallet (`ha-access-token` — a long-lived
token; `ha-prometheus-token` is the separate tofu-side one).

- HAProxy frontend must have **HTTP/2 disabled** or the HA WebSocket fails to upgrade.
- Integrations are scriptable via the config-flow REST API. **The Tuya CLOUD integration is not**
  — it needs the user's Smart Life/Tuya QR login in the UI (and a full delete+re-add when its
  session dies; a config-entry *reload* republishes cached values ONCE and looks like a fix).
  **`tuya_local` IS scriptable** and is the power source since 2026-08-07 (FU-038, archived):
  `bash scripts/ha-tuya-local.sh` installs the pinned custom component onto the /config PV and
  restarts HA; `bash scripts/ha-tuya-local-devices.sh` then creates one config entry per device
  from the wallet material (`tuya-local`/devices.json), idempotently. Both re-runnable.
- Token: `ha-access-token` in the wallet is a **long-lived access token** (~10y, no refresh dance —
  use it directly as `Authorization: Bearer`). The old `refresh_token` OAuth flow was retired
  (FU-003: the refresh token had died with `invalid_grant`).
- Regenerate it via the **websocket API** (REST can't mint one). Auth the websocket with any still-valid
  token (e.g. `ha-prometheus-token`) — no password/MFA — then send
  `{"type":"auth/long_lived_access_token","client_name":"…","lifespan":3650}`; the `result` is the
  new token. If every token is dead, auth the websocket by logging in with `ha-owner-password`
  instead. Full websocket handshake requires HTTP/2 **disabled** on the HAProxy frontend (above).

## UniFi

Controller runs in-cluster (`tofu/unifi.tf`): linuxserver
unifi-network-application + Mongo 7.0 on Longhorn, VIP `192.168.40.12`. Image pinned by digest
(UniFi Network 10.3.58). APs + the USW-Lite switch adopt via the inform host
`ubiquiti.teststuff.net` (Unbound override → .40.12); reboot a device to force re-inform. **Do NOT
switch to UniFi OS Server** — it needs privileged/systemd-PID1 and won't run on Talos. The Inform
Host setting is under *Device Updates and Settings* in the new UI.

## ESPHome / Droplet

The Droplet plant-waterer (ESP32 @ .245, ESPHome native API on 6053). Config
`esphome/config/office-plants-irrigation.yaml`; flash with `devbox run flash-irrigation` (a pip-venv shim — nix
esphome's PlatformIO can't run under the jail's seccomp). Service docs: `docs/office-plants/`.
Flash secrets (wifi/OTA/api key) = `esphome/config/secrets.yaml`, regenerated from the wallet by `scripts/wallet-files.sh`.

## Cloudflare (live)

Home Assistant is reachable from anywhere at **`https://ha.teststuff.net`** via a Cloudflare Tunnel
(`cloudflared` Deployment, ns `cloudflared`) gated by **client-certificate mTLS** (WAF-enforced). All
as code in `tofu/cloudflare/` (infra) + `tofu/cloudflare-token/` (scoped tokens); design + the full
decision/gotcha record in `docs/cloudflare.md`.

- **Apply (infra):** `source scripts/keepass-env.sh   # exports CLOUDFLARE_API_TOKEN (wallet: cloudflare-write-key)` then
  `devbox run -- tofu -chdir=tofu/cloudflare plan/apply`. The scoped write token is minted once by
  `tofu/cloudflare-token/` with an admin token, **outside the jail**.
- **Phone cert:** `bash scripts/make-client-p12.sh` → `~/.claude/cloudflare/ha-client.p12` (pinned
  openssl, explicit algorithms; the cert/key come from the `hashicorp/tls` provider + Cloudflare's
  managed CA). Install on the device; the HA app's **External URL** must be `https://ha.teststuff.net`
  (Internal stays `homeassistant.teststuff.net` for the fast LAN HAProxy path).
- **Gotchas (full list in `docs/cloudflare.md`):** the tunnel origin needs a **trailing-dot FQDN**
  (else the pod search-domain + the `*.local.teststuff.net` wildcard makes cloudflared dial
  `127.0.0.1` → 502); HA needs `http.use_x_forwarded_for` + `trusted_proxies` (pod CIDR) or it 400s.
- The Cloudflare **Docs MCP** is wired into this project (`claude mcp list`) — use it to ground
  Cloudflare work in current docs rather than stale model knowledge (provider v5 renamed resources).

## WireGuard VPN (full-LAN remote access)

Road-warrior WireGuard on OPNsense (ADR-090): laptop/phone dial `wg.teststuff.net:51820/udp` and
get the whole home network — LAN, HAProxy VIPs (`3.0/24`), BGP service VIPs (`32.0/19`) — with
Unbound DNS, so `*.teststuff.net` resolves like at home. Tunnel subnet `192.168.64.0/24`
(router `.1`, peers `.10+`). Split tunnel: only `192.168.0.0/16` rides the VPN.

- **Apply / change:** values in `ansible/group_vars/opnsense.yml` (`wireguard_*`), then
  `bash scripts/opnsense-playbook.sh ansible/opnsense-wireguard.yml`. Idempotent; re-linking the
  instance's peer list on drift is handled (same trap-class as the HAProxy frontend rebind).
- **Add a peer:** `bash scripts/wireguard-client.sh <name>` (generates a privkey into the KeePass
  wallet as `wireguard-<name>-privkey`, prints the pubkey) → add `{name, tunnel_ip, pubkey}` to
  `wireguard_peers` → run the playbook → re-run the script to render
  `~/.claude/homelab-wireguard/<name>.conf` (`--qr` renders a terminal QR for the phone app).
  Peer privkeys live ONLY in wallet + device; the server's privkey never leaves the router.
- **Verify without a client:** `scripts/wireguard-handshake-probe.py <host> 51820 <peer-privkey>
  <server-pubkey>` performs a real Noise handshake (needs a venv with `cryptography` — jail
  pip-venv pattern). `HANDSHAKE_OK` proves port + keys + peer registration end-to-end.
- **Endpoint freshness:** `wg.teststuff.net` is a DNS-only record in `tofu/cloudflare/dns.tf`;
  tofu owns its existence but ignores its content — **ddclient on OPNsense keeps it on the dynamic
  Telia WAN IP** (`ansible/opnsense-ddclient.yml`; native backend, `checkip` off the WAN interface,
  credential = the ACME zone-DNS token; plugin API namespace is `dyndns`, not `ddclient`).
  ddclient only writes when the WAN IP differs from its cached `current_ip` — to force/E2E-test a
  write: clear `current_ip` (`accounts/setItem`) then `dyndns/service/reconfigure` and watch the
  record via the Cloudflare API.

## Meta-session watch scripts (jail tooling)

The seven `agents/meta-*.sh` scripts are **jail meta-session machinery, not agent-platform
mechanism** — they run as Monitor probes inside the operator's meta-coordination sessions
(operator ruling 2026-08-10: the pointer lives in [`agents/roles.md`](agents/roles.md)
§meta-coordinator, the documentation lives here). When and how to arm them is
[`agents/meta-state.md`](agents/meta-state.md) §Re-arm (transient, per-session); this table is
the durable what-each-is:

| script | what it watches | cadence/shape |
|---|---|---|
| `meta-events.sh` | the FU-166(b) consolidated 120s edge-detected loop — needs-meta absorbed as a `--once` source, goal-thread User comments, aggregated alerts, doorbell famine, SEATPR terminals | persistent Monitor, **REQUIRED each meta session** (meta-state §Re-arm) |
| `meta-needs-attention.sh` | unreviewed platform PRs, `agent/blocked`, unlabeled>24h, stack codeowner parks | legacy standalone — absorbed as a meta-events source; do NOT double-arm beside it |
| `meta-throughput.sh` | queue-vs-movement per stack (a THROUGHPUT-STALL line is an incident, not calm) | run FIRST on every heartbeat sweep |
| `meta-alert-crosscheck.sh` | firing Alertmanager alerts vs the board (what fired that no session owns) | each heartbeat sweep, after throughput |
| `meta-watch-loop.sh` | per-stack loop events (ride opens, verdicts, merges) | OPTIONAL rollout-time tool (~10 routine events per real signal) |
| `meta-handoff-watch.sh` | the cross-jail handoff inbox | NOT standing — rollout days / active stack jails only |
| `meta-ride-edge-probe.sh` | doorbell/edge latency on a live ride (work-vs-wait ledger evidence) | ad-hoc, during goal-lane observation |

Probe hygiene rules (script files, dry-run under the real interpreter, PROBE-FAIL over silent
empty, kill leftovers by process before re-arming) stay in `meta-state.md` §Re-arm — they are
per-session practice, re-read at bootstrap.

## Registry cache

Pull-through mirrors for docker.io, ghcr.io, and mcr.microsoft.com (namespace `registry-cache`).
Each mirror is a distribution/registry v3 proxy Deployment (`mirror-docker-io`, `mirror-ghcr`,
`mirror-mcr`) with a Longhorn PVC and a LoadBalancer Service (BGP VIPs: .20, .21, .31).

### Mirror returning 5xx / corrupt blob

**Symptom:** `RegistryMirrorProbeFailing` alert fires (blackbox probe against `/v2/` returns 5xx
or timeout). Or: consumers see `unexpected commit digest` / `short read: expected N bytes but got
0` for a layer that exists upstream — the mirror has a committed blob that is corrupt on disk
(homelab#1282).

**Remedy — bounce the mirror Deployment:**

```bash
kubectl -n registry-cache rollout restart deploy/mirror-<name>
```

The restart re-runs the `store-maintenance.yaml` initContainer garbage-collect, which clears
corrupt committed blobs. This is the only reliable remedy for a poisoned blob on a proxied repo.

**What does NOT work:**

- `DELETE /v2/<name>/blobs/<digest>` returns **405 Method Not Allowed** on proxied repos despite
  `REGISTRY_STORAGE_DELETE_ENABLED=true` — the registry API does not support blob deletion for
  pull-through cache repos. Do not attempt this path.
- The weekly `gc-mirrors` CronJob (Sunday 04:00 UTC) also clears corrupt state, but waiting for
  it is not an incident response.

### Full disk / PVC sizing

**Symptom:** `RegistryMirrorCacheAlmostFull` alert fires (PVC >85% full). A full disk does NOT
crash the mirror — it silently TRUNCATES in-flight blob writes, and consumers see layer digest
mismatches + 500s.

**Remedy:** Check what is consuming space — legitimate blobs (capacity/TTL decision) vs `_uploads`
debris (should self-reap within ~1h via uploadpurging). If the working set has grown, increase
the PVC size in the mirror's `PersistentVolumeClaim` manifest (longhorn-bulk storage class).

### Weekly GC not running

**Symptom:** `RegistryGCMirrorsStale` or `RegistryGCMirrorsSuspended` alert fires.

**Remedy:** Check the CronJob exists and is not suspended:
```bash
kubectl -n registry-cache get cronjob gc-mirrors
kubectl -n registry-cache get jobs -l cronjob=gc-mirrors
```
If RBAC or scheduling broke, the pods will show Backoff or RBAC errors in events.

### Meta-session probe & triage discipline (durable)

Evicted from `meta-state.md` §Durable warnings 2026-08-23 (S4 #765 — non-transient content was
squatting in the transient file). Each rule was paid for at least once; dates and the full
incident detail are TICK-LOG's.

- **Absence is the easiest thing to fake.** When a probe returns empty/absent and that absence
  would change a conclusion, re-query the WHOLE object before believing it: `-o json` and read
  the structure — never `jsonpath` for a field whose path you are inferring, never `| head` a
  listing you are about to call complete. An empty result is a claim about your query, not
  about the world (three self-inflicted instances in one night, 2026-08-08: a `head -5` hiding
  a credential file; `spec.fixer` read at the wrong nesting; a native sidecar invisible to
  `.spec.containers`).
- **A firing-set transition is an event, not a measurement** — re-read the metric before
  claiming a condition ended. And **a deploy can silence an alert for its whole `for:`
  window**: restarting the emitting pod ends the old per-pod series and the `for:` timer
  restarts from zero (SubscriptionWeeklyPoolLow sat at 0.92 while "cleared", 2026-08-07).
  The class is SHIPPED (homelab#332): the restart-gap test — bridged vs deliberately-not-bridged per alert — lives at the head of `argocd/resources/openrouter-proxy/prometheusrule.yaml`, promtool-pinned.
- **`severity: info` alerts are SILENTLY SUPPRESSED in this cluster** — kube-prometheus-stack's
  stock `InfoInhibitor` inhibit rule holds them `suppressed` in Alertmanager; they dispatch to
  nothing (not the responder, not the Home Assistant webhook). Use `warning`. Tell:
  `curl -s 'http://192.168.40.14:9093/api/v2/alerts?inhibited=true'` — Prometheus saying
  `firing` is NOT evidence anyone was told. Mechanized: `prometheus-rules-lint` reds on unacknowledged `severity: info` (homelab#769).
- **A steady-state COUNTER cannot separate "at capacity" from "cannot work"** (`running: 4,
  pending: 0` reads identically either way). Capacity claims need a THROUGHPUT signal: a
  saturated pool has jobs RUNNING, a broken one has workers WAITING. (Also in the responder
  prompt since `ecb74bb`.)
- **A green surface is not a green outcome.** A workflow "failure" that already shipped its
  artifact; a ride pod `Succeeded` with its harness dead and nothing committed. The status
  field often answers a different question than the one asked — for a ride the durable signal
  is the `AGENT_STRIKE:` comment on the issue (ride pods are GC'd in minutes, so a log probe's
  silence proves nothing).
- **Check the bypass ACTORS before calling anything a human gate.** A `required-approval`
  ruleset whose only bypass is `OrganizationAdmin: always` is NOT a human gate — the jail
  credentials ARE that admin (`gh pr merge --admin`). Applies to every platform-lane repo where
  `reviewer.enabled=false` means no bot will ever approve. ⚠ Do NOT "fix" that by flipping
  `reviewer.enabled=true` on the `platform` claim — it would also point the bot at homelab and
  agent-coordinator, both tier-3.
- **"Written is not applied" — the tell is always the CALLER, not the config.** A router class
  only the worker launcher calls, a required check no workflow triggers on, a label description
  that never reached GitHub. A deadline is what turns a plausible reading into a checked one.
- **A reviewer that verifies code against ONE spec page is not verifying it against the
  CONTRACT** — two agents reasoned correctly inside one page and reached a remedy a sibling
  page forbids (circles#32, ruled 2026-08-06).
- **An operator-lane PR has NO machine owner** — `changes-requested`/`merge-conflict` units are
  `WORKER_AUTHOR`-scoped by design. The covering surfaces are `devbox run board` (review queue
  + codeowner parks) and `meta-needs-attention.sh` clause 4; a stalled human PR is found by a
  board sweep, never by the loop.

## Registry (first-party, push-mode) — prune + garbage-collect

The `registry.teststuff.net` registry (ns `registry`, `registry:3` on the Garage bucket `registry`,
ADR-121) has a 32Gi bucket cap and **no automatic retention** (FU-203). Ownership is the ADR-085
split: the stack's IaC decides the keep-set (oracle-iac#664 — the pinned digest + the newest date
tag + the previous pin) and untags/deletes what it no longer wants with its push credential
(`DELETE /v2/<repo>/manifests/<digest>` — `REGISTRY_STORAGE_DELETE_ENABLED=true`); homelab runs the
collector, which is the only step that needs the `registry` namespace. The standing collector is the `registry-garbage-collect` CronJob (runs Sundays 03:00 UTC; see `argocd/resources/registry/registry-gc-cronjob.yaml`); the recipe below is the ad-hoc path if needed between runs.

**Symptom of a full bucket:** the pusher sees an opaque **500** on a blob PATCH/PUT (Garage's
`403 Bucket size quota is reached` is swallowed by the registry), `api_s3_error_counter` does not
move, and the failed upload's bytes stay counted until purged (`UPLOADPURGING age: 1h`).

**Recipe (first run 2026-09-08, oracle handoff):**

```bash
K="devbox run -- kubectl --kubeconfig tofu/kubeconfig"
# 0. before: what the bucket holds
$K -n garage exec garage-0 -c garage -- ./garage bucket info registry | grep -E '^Size|^Objects'
# 1. dry run — lists the manifests/blobs it would remove; --delete-untagged removes manifests
#    no tag points at (a re-pointed tag leaves its old manifest behind exactly like this)
$K -n registry exec deploy/registry -c registry -- \
  registry garbage-collect --dry-run --delete-untagged /etc/distribution/config.yml
# 2. read it: every "marking manifest" line must be a digest a tag still serves
#    (HEAD /v2/<repo>/manifests/<tag> → Docker-Content-Digest); every "eligible" one must not be.
# 3. for real — same command without --dry-run. Do it in a window with no push in flight
#    (the oracle release is Tuesdays 07:17Z); it does not need the registry stopped.
# 4. verify: served tags still HEAD 200 with the same digest, the served layer HEAD 200 with its
#    full content-length, the deleted digest 404, and the bucket size dropped.
```

⚠ `--delete-untagged` is correct HERE and wrong on the pull-through mirrors — a mirror caches
digest-pinned pulls as untagged manifests, and that flag deletes exactly the images the pinning
convention produces (homelab#116; the mirrors' `store-maintenance.yaml` runs GC without it).

Measured 2026-09-08: dry run + real run ~1 min each on a 3-manifest repo; bucket 30.3 → 15.3 GiB.
The Garage "Size" counter before the run read ~8 GB above the sum of the listed objects — the
object listing (`aws s3 ls --recursive` with the registry's own key) is the number to trust when
they disagree.
