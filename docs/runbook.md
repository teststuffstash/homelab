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
- `devbox run` runs scripts under **dash** and from the **repo root** regardless of `cwd` →
  use `tofu -chdir=...` / absolute paths, and avoid `bash -c '<multiline>'` (mangles newlines).
  Don't put `source <(... completion)` in `init_hook` — it parse-errors under dash and breaks
  every `devbox run`.
- Tofu in the main root needs secret vars — **don't pass them by hand, use the wrappers**:
  `devbox run tf-plan` / `devbox run tf-apply` source them via `scripts/tf.sh` (→ `keepass-env.sh`
  reads the KeePass wallet; the GitHub-App key resolves from the cred dir). These work **in the jail
  (`~/.claude`) or on the host (`~/Projects/.claude-data`)** — same dual-path trick as `garage-s3`.
  `proxmox_api_token` + non-secret IDs stay in `tofu/terraform.tfvars`. `devbox run tf-validate`
  needs no secrets. To seed/refresh the wallet (incl. the Forgejo runner token): `devbox run keepass-init`.

## Secrets (out of repo)

The **KeePass wallet** (`~/.claude/homelab-keepass/`, key-file-only) holds ALL Tier-0 values —
OPNsense/Proxmox/Cloudflare/Garage/HA/AWS/droplet/GitHub-App creds (FU-001, docs/secrets.md).
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
2. Run **in this order** — the sign step in the middle is the trap:
   - `bash scripts/opnsense-playbook.sh ansible/opnsense-acme.yml` — creates the cert **spec only; does
     NOT issue it** (the role is create-if-absent; issuance is left to OPNsense's ACME cron).
   - ⚠️ **Sign the cert before running haproxy.** Trigger issuance now instead of waiting for the cron:
     `POST /api/acmeclient/certificates/sign/<uuid>` (uuid from `certificates/search`), then poll
     `certificates/search` until that cert's `statusCode == 200` (DNS-01 takes ~30–60s). Or click
     *ACME → Certificates → (sign)* in the GUI.
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

### LAN DHCP / DNS

LAN DHCP was migrated **ISC dhcpd → dnsmasq** (ISC has no settings API). `opnsense/dnsmasq-dhcp.py`
rebuilds it idempotently (range .10–.245, gateway/DNS .1, domain `teststuff.net`, static
reservations incl. the metal nodes). dnsmasq is **DHCP-only** (`port=0`) so Unbound keeps `:53`.
PXE is NOT served here — it's a separate dnsmasq proxy-DHCP on the Matchbox LXC (see provisioning).
ISC DHCPv4 is fully disabled (stopped **and** unchecked in the UI — reboot-safe); dnsmasq is the
only LAN DHCP.

## Storage (Longhorn)

`tofu/longhorn.tf` — Helm 1.12.0, `longhorn` is the **default StorageClass** (replica=2, zone
soft-anti-affinity across wk-02/thinkcentre/hp-01). All stateful services use Longhorn PVCs (not
node-pinned). A `longhorn-fast` SC (replica=1, node-local) lives on the ThinkCentre's 2×Optane,
formatted+mounted via `metal.tf` `optane_disks` and registered with
`scripts/longhorn-register-optane.sh`.

- ⚠️ **Never `talosctl upgrade` a Proxmox *nocloud* VM** — the reboot loses the cloud-init static
  IP/hostname and it rejoins as a DHCP/default-name ghost. Add extensions by baking them into the
  VM image (`image.tf` `talos_longhorn` schematic) and recreating (`tofu apply -replace=...`).
  **Metal nodes upgrade fine** (see provisioning doc).
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
  thinkcentre `8c:89:a5:23:49:da`, wk-metal-01 `50:7b:9d:01:b3:54`, wk-metal-02 `68:f7:28:80:84:09`.
  (NB: a plain `talosctl reboot` keeps the node powered → it returns on its own; WoL is only for an
  S5/powered-off node.)

### Re-imaging a metal node (change install extensions, e.g. drop qemu-guest-agent)
Metal nodes **upgrade fine** (unlike nocloud VMs). To switch a metal node to a new install image
WITHOUT a reset/reinstall: `talosctl -n <ip> -e <ip> upgrade --image <factory installer>` then
`talosctl -n <ip> -e <ip> reboot`. ⚠ On a **worker** the upgrade installs to the B partition then
errors `kubeconfig is only available on control plane nodes` at its auto-drain step and does NOT
reboot — that's why the explicit `reboot` follows (switches to B). Verify with `talosctl get
extensions` + node `Ready`. The current metal image is `image.tf` `talos_image_factory_schematic.metal`
(iscsi-tools + util-linux-tools, no qemu-guest-agent — the latter hung the boot on bare metal).

## CloudNativePG (Postgres)

CNPG `Cluster`s (`infisical-pg`, `forgejo-pg`) run with `enablePodMonitor` + the `cnpg`
PrometheusRule group and Grafana dashboard (`tofu/dashboards/cnpg.json`) — added after forgejo-pg-2
sat as a broken replica for 2.5 days unnoticed (2026-06).

- **Broken-replica recovery** (crash-loop on `pg_rewind: could not find common ancestor of the
  source and target cluster's timelines` after a failover, readiness 500): no data loss if the
  primary is intact — delete the replica's PVC **and** pod so CNPG re-clones it via `pg_basebackup`:
  `kubectl -n <ns> delete pvc <cluster>-N; kubectl -n <ns> delete pod <cluster>-N` (it returns as
  the next instance number, e.g. `-2` → `-3`). If a replica re-diverges, suspect the node it landed on.

## Power-loss / ghost-node recovery

Historically, after a **simultaneous cold power-cycle** (whole lab loses power), metal Talos nodes
could rejoin under generated `talos-xxx` hostnames — they DHCP-discover before OPNsense's dnsmasq
is back up, so Talos can't get its reserved hostname and makes one up. **Metal hostnames are now
pinned** via an install-time `HostnameConfig` patch (`tofu/metal.tf` `pin_hostname`, default on),
so this shouldn't recur. If a ghost still appears (e.g. a node was reinstalled without the patch):
symptoms are `kubectl get nodes` showing `talos-xxx` ghosts next to (or instead of) the real metal
names, and volumes failing to attach (Multi-Attach / "driver.longhorn.io not found"). Recover with
reboots:

1. **Reboot each ghosted metal node** to reclaim its reserved hostname (dnsmasq is healthy now):
   `devbox run -- talosctl --talosconfig tofu/talosconfig -n <ip> reboot`. Do storage nodes
   (hp-01/thinkcentre) **one at a time** (talosctl reboot blocks until healthy). The node returns
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

## Home Assistant

Deployed in-cluster (`tofu/homeassistant.tf`), VIP `192.168.40.10:8123`, HTTPS at
`homeassistant.teststuff.net` via OPNsense HAProxy. Config kept in `homeassistant/ha-config/`,
applied imperatively (`kubectl cp` + restart). Tokens in the wallet (`ha-access-token`, `ha-refresh-token`).

- HAProxy frontend must have **HTTP/2 disabled** or the HA WebSocket fails to upgrade.
- Integrations are scriptable via the config-flow REST API; **Tuya (plugs/power) is NOT** — needs
  the user's Smart Life QR login in the UI.
- Token refresh: `POST http://192.168.40.10:8123/auth/token` form `grant_type=refresh_token`,
  `refresh_token=<wallet: ha-refresh-token>`, `client_id=http://192.168.2.61:30123/`
  (the original onboarding origin — others 401). Minting a long-lived token needs the websocket API
  (`auth/long_lived_access_token`), not REST.

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
  tofu ignores its content (dynamic Telia lease) — who updates it is FU-075 (static IP vs ddclient).
