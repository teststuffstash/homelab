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
- Tofu in the main root needs two secret vars; source them from the cred files:
  `export TF_VAR_grafana_admin_password=$(cat ~/.claude/homelab-ha/grafana_admin_password)` and
  `export TF_VAR_ha_prometheus_token=$(cat ~/.claude/homelab-ha/prometheus_llat)`.

## Secrets (out of repo)

In the jail under `~/.claude/`: `homelab-opnsense/{key,secret}`, `homelab-pve-ssh/{api_token_*,id_ed25519}`,
`homelab-matchbox/{ca.crt,client.crt,client.key}`, `homelab-ha/{owner_password,prometheus_llat,grafana_admin_password,access_token,refresh_token}`,
`homelab-droplet/ota_password`, `cloudflare/{read-key,write-key,acme-token,ha-client.p12,...}`,
`homelab-aws/{audit-key,audit-secret}`. Tofu state/`*.tfvars`/`kubeconfig`/`talosconfig` are gitignored.

## OPNsense as code

OPNsense (router @ .1, currently 26.1.x) is managed with the `oxlorg.opnsense` Ansible collection.
Playbooks: `opnsense-bgp.yml` (FRR/BGP ↔ Cilium), `opnsense-acme.yml` (Let's Encrypt, **DNS-01 via
Cloudflare** — `ACME_CF_TOKEN`, since `teststuff.net` moved off Route53),
`opnsense-haproxy.yml` (HTTPS reverse proxy), `opnsense-unbound-hosts.yml` (static DNS overrides),
plus `opnsense/dnsmasq-dhcp.py` (LAN DHCP). **Run them with the wrapper** (handles the httpx
interpreter + creds):

```bash
bash scripts/opnsense-playbook.sh ansible/opnsense-haproxy.yml          # or any opnsense-*.yml
bash scripts/opnsense-playbook.sh ansible/opnsense-unbound-hosts.yml -e ...   # extra args pass through
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
  `/unbound/service/reconfigure` (the `opnsense-unbound-hosts.yml` handler does this). Match on
  `[hostname, domain, record_type]` (exclude `value`) to update-in-place on a repoint.
- Verify a DNS record bypassing the jail's stale Docker/host cache: `devbox run -- dig +short
  <name> @192.168.2.1` (jail `getent` caches the pre-change answer).
- ACME: os-acme-client doesn't persist the cert `description`, so the module can't adopt
  GUI-created certs → playbooks are create-if-absent guarded on name.
- ⚠️ Never iterate destructive firmware endpoints (`/firmware/reboot`, `/poweroff`) with a real
  body to "discover" them — they execute.

### LAN DHCP / DNS

LAN DHCP was migrated **ISC dhcpd → dnsmasq** (ISC has no settings API). `opnsense/dnsmasq-dhcp.py`
rebuilds it idempotently (range .10–.245, gateway/DNS .1, domain `teststuff.net`, static
reservations incl. the metal nodes). dnsmasq is **DHCP-only** (`port=0`) so Unbound keeps `:53`.
PXE is NOT served here — it's a separate dnsmasq proxy-DHCP on the Matchbox LXC (see provisioning).
⚠️ **Pending one-time click-op:** ISC dhcpd is stopped but still `enable=1` in config.xml (no API to
disable) — uncheck *Services → ISC DHCPv4 → [LAN] → Enable* in the UI for reboot-safety.

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
- **WoL recovery** (tested on hp-01): `talosctl shutdown` → S5, then a magic packet from a
  hostNetwork pod on the same L2 segment (the jail is NAT'd and can't). Set BIOS boot order
  disk-first or wake→Ready takes ~5 min of PXE timeouts.

## Power-loss / ghost-node recovery

After a **simultaneous cold power-cycle** (whole lab loses power), metal Talos nodes can rejoin
under generated `talos-xxx` hostnames — they DHCP-discover before OPNsense's dnsmasq is back up, so
Talos can't get its reserved hostname and makes one up. Symptoms: `kubectl get nodes` shows
`talos-xxx` ghosts next to (or instead of) the real metal names, volumes fail to attach
(Multi-Attach / "driver.longhorn.io not found"). The hostname can't be pinned in config (see
`tofu/metal.tf`), so recover with reboots:

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
applied imperatively (`kubectl cp` + restart). Tokens at `~/.claude/homelab-ha/`.

- HAProxy frontend must have **HTTP/2 disabled** or the HA WebSocket fails to upgrade.
- Integrations are scriptable via the config-flow REST API; **Tuya (plugs/power) is NOT** — needs
  the user's Smart Life QR login in the UI.
- Token refresh: `POST http://192.168.40.10:8123/auth/token` form `grant_type=refresh_token`,
  `refresh_token=<~/.claude/homelab-ha/refresh_token>`, `client_id=http://192.168.2.61:30123/`
  (the original onboarding origin — others 401). Minting a long-lived token needs the websocket API
  (`auth/long_lived_access_token`), not REST.

## UniFi

Controller migrated off the dead T61 to the cluster (`tofu/unifi.tf`): linuxserver
unifi-network-application + Mongo 7.0 on Longhorn, VIP `192.168.40.12`. Image pinned by digest
(UniFi Network 10.3.58). APs + the USW-Lite switch adopt via the inform host
`ubiquiti.teststuff.net` (Unbound override → .40.12); reboot a device to force re-inform. **Do NOT
switch to UniFi OS Server** — it needs privileged/systemd-PID1 and won't run on Talos. The Inform
Host setting is under *Device Updates and Settings* in the new UI.

## ESPHome / Droplet

The Droplet plant-waterer (ESP32 @ .245, ESPHome native API on 6053). Config
`esphome/config/droplettest.yaml`; flash with `devbox run flash-droplet` (a pip-venv shim — nix
esphome's PlatformIO can't run under the jail's seccomp). Service docs: `docs/office-plants/`.
OTA password at `~/.claude/homelab-droplet/ota_password`.

## Cloudflare (live)

Home Assistant is reachable from anywhere at **`https://ha.teststuff.net`** via a Cloudflare Tunnel
(`cloudflared` Deployment, ns `cloudflared`) gated by **client-certificate mTLS** (WAF-enforced). All
as code in `tofu/cloudflare/` (infra) + `tofu/cloudflare-token/` (scoped tokens); design + the full
decision/gotcha record in `docs/cloudflare.md`.

- **Apply (infra):** `export CLOUDFLARE_API_TOKEN=$(cat ~/.claude/cloudflare/write-key)` then
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
