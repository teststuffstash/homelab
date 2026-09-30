#!/usr/bin/env bash
# opnsense-test (FU-297): BUILD the OPNsense test VM's guest — its first boot through to the
# baseline snapshot. The VM's HARDWARE is tofu (tofu/opnsense-test.tf); USING it (per-run
# rollback to the baseline, the plays, the report) is scripts/opnsense-test-vm.sh. Why this
# mechanism, and the recipes: docs/opnsense-test-vm.md.
#
#   bash scripts/opnsense-test-vm-bootstrap.sh bootstrap   # never-booted disk → snapshot `baseline`
#   bash scripts/opnsense-test-vm-bootstrap.sh finish      # resume after the import (VM up, no snapshot)
#   bash scripts/opnsense-test-vm-bootstrap.sh status      # power, snapshots, version, plugins
#   bash scripts/opnsense-test-vm-bootstrap.sh render F    # the seed config.xml to F (debug; mode 600)
#   bash scripts/opnsense-test-vm-bootstrap.sh create      # EPHEMERAL VMs only (the rebuild drill):
#   bash scripts/opnsense-test-vm-bootstrap.sh destroy     #   the hardware tofu gives 9110, by qm
#
# Same env names as the harness: OPN_TEST_VMID (9110), OPN_TEST_HOST (192.168.2.67),
# OPN_TEST_SNAPSHOT (baseline), OPN_TEST_VM_NAME (opnsense-test), OPN_TEST_PVE (nx-02),
# OPN_TEST_PVE_KEY — the harness's own defaults/expectations, so what this builds is what it
# rolls back to. OPN_TEST_LAN_BRIDGE (vmbr1) and OPN_TEST_NANO_IMG (the tofu-downloaded nano) matter
# to `create` only.
#
# Secrets live in the wallet (created on first bootstrap if missing):
#   opnsense-test-root-password  opnsense-test-api-key  opnsense-test-api-secret
# unless ALL THREE are pre-set as OPN_TEST_ROOT_PASSWORD / OPN_TEST_API_KEY / OPN_TEST_API_SECRET —
# the rebuild drill mints a throwaway set per run (in memory, dies with the VM) and the box has
# no wallet (docs/opnsense-test-vm.md §The rebuild drill).
# SSH: root key login with the shared pve seed key (~/.claude/homelab-pve-ssh/id_ed25519).
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

VMID="${OPN_TEST_VMID:-9110}"                       # = tofu var.opnsense_test_vm_id
VMNAME="${OPN_TEST_VM_NAME:-opnsense-test}"         # what `qm config` must say (create/destroy guard)
LAN_BRIDGE="${OPN_TEST_LAN_BRIDGE:-vmbr1}"          # create only; tofu wires 9110's
TOFU_VMID=9110                                      # the tofu-owned VM: create/destroy never touch it
WAN_IP="${OPN_TEST_HOST:-192.168.2.67}"           # = tofu var.opnsense_test_wan_ip_cidr
WAN_BITS="${OPN_TEST_WAN_BITS:-24}"               # standing: the node's LAN mask (prod's /22)
GATEWAY=192.168.2.1
MGMT_NET=192.168.2.0/24
LAN_IP=192.168.1.1                                 # docs/ip-plan.md: 1.0/24, isolated-bridge carve
LAN_BITS=24
LAN_DHCP_START=192.168.1.100
LAN_DHCP_END=192.168.1.199
SERIES=26.7.5                                      # prod's version = the series head the mirror serves (= 9110's baseline)
NANO_VERSION=26.7                                  # = tofu var.opnsense_test_nano_version (the birth image)
PLUGINS="os-frr os-haproxy os-acme-client"         # what the ansible/opnsense-*.yml plays drive
SNAP="${OPN_TEST_SNAPSHOT:-baseline}"      # the harness default (OPN_TEST_SNAPSHOT)
# The ROUTER REHEARSAL shape (docs/opnsense-test-vm.md §The router rehearsal; ephemeral VMs only):
SHAPE="${OPN_TEST_SHAPE:-test}"                    # test | router | standing (ADR-144: the node's LAN = vmbr0 at WAN_IP, WAN = WAN_BRIDGE)
WAN_PCI="${OPN_TEST_WAN_PCI:-}"                    # router: the host NIC passed through as the WAN
WAN_MAC="${OPN_TEST_WAN_MAC:-}"                    # router: the MAC the WAN spoofs (the ISP lease follows it)
WAN_MODE="${OPN_TEST_WAN_MODE:-passthrough}"       # router: passthrough (igb0) | bridged (vtnet2 on WAN_BRIDGE)
WAN_BRIDGE="${OPN_TEST_WAN_BRIDGE:-vmbr9}"         # bridged: a RUNTIME host bridge, WAN_PCI's netdev its only port
case "$WAN_MODE" in passthrough|bridged) ;; *) echo "OPN_TEST_WAN_MODE must be passthrough|bridged" >&2; exit 2 ;; esac
CARRY_FROM="${OPN_TEST_CARRY_FROM:-}"              # a decrypted prod config.xml (0600) to carry identity from
CARRY="${OPN_TEST_CARRY:-trust,acme,api-users}"    # opnsense/test-vm/seed-shape.py --carry

NX02="root@${OPN_TEST_PVE:-192.168.2.59}"
SSH_KEY="${OPN_TEST_PVE_KEY:-$HOME/.claude/homelab-pve-ssh/id_ed25519}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -i "$SSH_KEY")
KP_DB="$HOME/.claude/homelab-keepass/homelab.kdbx"
KP_KEY="$HOME/.claude/homelab-keepass/homelab.keyx"
SEED_ISO="opnsense-seed-$VMID.iso"                 # on nx-02 local:iso, only during bootstrap (per vmid)

log() { printf '[opnsense-test] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
nx() { ssh "${SSH_OPTS[@]}" "$NX02" "$@"; }
vm_ssh() { ssh "${SSH_OPTS[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o LogLevel=ERROR "root@$WAN_IP" "$@"; }

kp() { DEVBOX_QUIET=1 devbox run --quiet -- keepassxc-cli "$@"; }
kp_get() {  # pre-set env wins (all three or none — ensure_secrets checks)
  case "$1" in
    opnsense-test-root-password) [ -z "${OPN_TEST_ROOT_PASSWORD:-}" ] || { printf '%s\n' "$OPN_TEST_ROOT_PASSWORD"; return; } ;;
    opnsense-test-api-key)       [ -z "${OPN_TEST_API_KEY:-}" ]       || { printf '%s\n' "$OPN_TEST_API_KEY"; return; } ;;
    opnsense-test-api-secret)    [ -z "${OPN_TEST_API_SECRET:-}" ]    || { printf '%s\n' "$OPN_TEST_API_SECRET"; return; } ;;
  esac
  kp show -q --no-password -k "$KP_KEY" -a Password "$KP_DB" "$1" 2>/dev/null
}
kp_has() { kp show -q --no-password -k "$KP_KEY" "$KP_DB" "$1" >/dev/null 2>&1; }
# Add an entry with a given value (stdin, never argv). Refuses to overwrite.
kp_add() {
  kp_has "$1" && die "wallet entry $1 already exists — refusing to overwrite"
  printf '%s\n' "$2" | kp add -q --no-password -k "$KP_KEY" -p "$KP_DB" "$1" >/dev/null
  [ "$(kp_get "$1")" = "$2" ] || die "wallet write of $1 did not read back"
}

ensure_secrets() {
  local n=0
  for v in OPN_TEST_ROOT_PASSWORD OPN_TEST_API_KEY OPN_TEST_API_SECRET; do [ -z "${!v:-}" ] || n=$((n + 1)); done
  [ "$n" = 3 ] && return 0
  [ "$n" = 0 ] || die "set all three of OPN_TEST_ROOT_PASSWORD / _API_KEY / _API_SECRET, or none (the wallet)"
  kp_has opnsense-test-root-password || kp_add opnsense-test-root-password "$(openssl rand -base64 24)"
  # Same shapes OPNsense's own ApiKeyField::add() mints: base64 of 60 random bytes each.
  kp_has opnsense-test-api-key    || kp_add opnsense-test-api-key    "$(openssl rand -base64 60 | tr -d '\n')"
  kp_has opnsense-test-api-secret || kp_add opnsense-test-api-secret "$(openssl rand -base64 60 | tr -d '\n')"
}

API_AUTH=""
api() {  # api GET|POST <path> [json] — the wallet pair is read once per run
  local m="$1" p="$2" d="${3:-}"
  [ -n "$d" ] || d='{}'
  [ -n "$API_AUTH" ] || API_AUTH="$(kp_get opnsense-test-api-key):$(kp_get opnsense-test-api-secret)"
  if [ "$m" = POST ]; then
    curl -sfk --max-time 30 -u "$API_AUTH" -X POST -H 'Content-Type: application/json' -d "$d" "https://$WAN_IP/api/$p"
  else
    curl -sfk --max-time 30 -u "$API_AUTH" "https://$WAN_IP/api/$p"
  fi
}

wait_api() {  # until the API answers with our key (≤ $1 s)
  local deadline=$(( $(date +%s) + ${1:-600} ))
  until api GET core/firmware/info >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || die "API on $WAN_IP did not answer in time"
    sleep 10
  done
}

# Renders config.xml to $1 (mode 600). The API secret goes in as crypt(SHA-512) — what
# password_verify() checks (core Auth/API.php); the root password likewise.
render() {
  local out="$1"
  local root_hash api_line keys_b64
  root_hash="$(kp_get opnsense-test-root-password | openssl passwd -6 -stdin)"
  api_line="$(kp_get opnsense-test-api-key)|$(kp_get opnsense-test-api-secret | openssl passwd -6 -stdin)"
  # The public half; derived when no .pub sits beside the key (the box's copy is key-only).
  if [ -f "$SSH_KEY.pub" ]; then keys_b64="$(base64 -w0 < "$SSH_KEY.pub")"
  else keys_b64="$(ssh-keygen -y -f "$SSH_KEY" | base64 -w0)"; fi
  ( umask 077
    OUT="$out" ROOT_HASH="$root_hash" API_LINE="$api_line" KEYS_B64="$keys_b64" \
    WAN_IP="$WAN_IP" WAN_BITS="$WAN_BITS" GATEWAY="$GATEWAY" MGMT_NET="$MGMT_NET" \
    LAN_IP="$LAN_IP" LAN_BITS="$LAN_BITS" LAN_DHCP_START="$LAN_DHCP_START" LAN_DHCP_END="$LAN_DHCP_END" \
    python3 - <<'PY'
import os
s = open("opnsense/test-vm/config.xml.tmpl").read()
for k, v in {
    "ROOT_PASSWORD_HASH": os.environ["ROOT_HASH"], "API_KEY_LINE": os.environ["API_LINE"],
    "AUTHORIZED_KEYS_B64": os.environ["KEYS_B64"], "WAN_IP": os.environ["WAN_IP"],
    "WAN_BITS": os.environ["WAN_BITS"], "GATEWAY": os.environ["GATEWAY"],
    "MGMT_NET": os.environ["MGMT_NET"], "LAN_IP": os.environ["LAN_IP"],
    "LAN_BITS": os.environ["LAN_BITS"], "LAN_DHCP_START": os.environ["LAN_DHCP_START"],
    "LAN_DHCP_END": os.environ["LAN_DHCP_END"],
}.items():
    s = s.replace("@%s@" % k, v)
import re
assert not re.search(r"@[A-Z_]+@", s.split("-->", 1)[1]), "unfilled placeholder"
open(os.environ["OUT"], "w").write(s)
PY
  )
  # The router rehearsal (docs/opnsense-test-vm.md §The router rehearsal): reshape + carry.
  local shape_args=()
  [ "$SHAPE" != router ] || shape_args+=(--router --wan-mac "$WAN_MAC" --wan-if "$([ "$WAN_MODE" = bridged ] && echo vtnet2 || echo igb0)")
  [ "$SHAPE" != standing ] || shape_args+=(--standing --wan-mac "$WAN_MAC" --lan-ip "$WAN_IP/$WAN_BITS" --lan-gw "$GATEWAY")
  [ -z "$CARRY_FROM" ] || shape_args+=(--carry-from "$CARRY_FROM" --carry "$CARRY")
  [ ${#shape_args[@]} -eq 0 ] || python3 opnsense/test-vm/seed-shape.py "$out" "${shape_args[@]}"
}

# The serial-console driver, run ON nx-02 against QEMU's serial socket. It answers exactly two
# prompts of core's src/sbin/opnsense-importer (boot mode `-b`, reached from the `import`
# syshook): "Press any key to start the configuration importer" (a 7-second window) and
# "Select device to import from" — naming the CD it finds in the importer's own `camcontrol
# devlist` listing. Then it waits for the login prompt that ends the boot.
SERIAL_DRIVER=$(cat <<'PY'
import socket, sys, time, re
sock_path, deadline = sys.argv[1], time.time() + 900
s = socket.socket(socket.AF_UNIX); s.connect(sock_path); s.settimeout(1)
buf, state = b"", "wait-importer"
while time.time() < deadline:
    try:
        chunk = s.recv(4096)
    except socket.timeout:
        chunk = b""
    if chunk:
        buf += chunk; sys.stdout.write(chunk.decode("latin1")); sys.stdout.flush()
    if state == "wait-importer":
        if b"Bootstrapping config.xml" in buf:
            sys.exit("importer skipped: the factory config was written — see the doc's recovery")
        if b"start the configuration importer" in buf:
            s.sendall(b" "); state = "wait-device"; buf = b""
    elif state == "wait-device":
        if b"Select device to import from" in buf:
            # camcontrol devlist: "<QEMU QEMU DVD-ROM 2.5+>  at scbus1 target 0 lun 0 (pass0,cd0)"
            m = re.search(rb"[(,](cd\d+)[,)]", buf)
            if not m:
                sys.exit("no CD device in the importer's device list")
            s.sendall(m.group(1) + b"\r"); state = "wait-import"; buf = b""
    elif state == "wait-import":
        if b"could not be" in buf or b"No known partition" in buf:
            sys.exit("import failed")
        if b"login:" in buf:
            print("\n[driver] boot finished with the imported config"); sys.exit(0)
sys.exit("timeout in state " + state)
PY
)

vm_status() { nx "qm status $VMID" | awk '{print $2}'; }

# The STANDING shape's WAN must be dark before the node first boots wearing the old router's MAC:
# every physical port of WAN_BRIDGE without carrier (an admin-down port is raised to read it, then
# restored), and the bridge without a host address. The bridge is tofu's (tofu/opnsense-router.tf).
standing_wan_guard() {
  [ -n "$WAN_MAC" ] || die "standing shape needs OPN_TEST_WAN_MAC"
  nx "sh -s $WAN_BRIDGE" >&2 <<'SH' || die "WAN bridge refused (above)"
br=$1
[ -d /sys/class/net/$br/brif ] || { echo "$br is not a bridge on this host"; exit 1; }
[ -z "$(ip -br -4 addr show dev $br | awk '{print $3}')" ] || { echo "$br has a host address"; exit 1; }
n=0
for p in /sys/class/net/$br/brif/*; do
  [ -e "$p" ] || continue; i=$(basename $p)
  case $i in tap*|fwpr*|fwln*|veth*) continue ;; esac
  n=$((n+1)); up=$(cat /sys/class/net/$i/operstate); [ "$up" != down ] || { ip link set $i up; sleep 4; }
  c=$(cat /sys/class/net/$i/carrier 2>/dev/null || echo unreadable); [ "$up" != down ] || ip link set $i down
  [ "$c" = 0 ] || { echo "$i on $br carrier=$c - cabled? never boot the spoofed MAC onto a live WAN"; exit 1; }
done
[ $n -ge 1 ] || { echo "$br has no physical port"; exit 1; }
echo "$br: $n physical port(s), all dark, no address"
SH
}

cmd_bootstrap() {
  nx "qm config $VMID" >/dev/null 2>&1 || die "VM $VMID not on nx-02 — apply tofu/opnsense-test.tf first"
  [ "$(vm_status)" = stopped ] || die "VM $VMID is running — bootstrap needs the never-booted disk (doc §Recovery)"
  nx "qm listsnapshot $VMID" | grep -qw -- "$SNAP" && die "snapshot $SNAP exists — the VM is built; the harness rolls back to it"
  ensure_secrets

  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  local tmp="$TMPD"
  mkdir -p "$tmp/iso/conf"
  render "$tmp/iso/conf/config.xml"
  log "seed ISO → nx-02 local:iso/$SEED_ISO"
  nx "umask 077; mkdir -p /root/opnsense-seed-$VMID/conf && cat > /root/opnsense-seed-$VMID/conf/config.xml" < "$tmp/iso/conf/config.xml"
  nx "genisoimage -quiet -R -J -V OPNSEED -o /var/lib/vz/template/iso/$SEED_ISO /root/opnsense-seed-$VMID && rm -rf /root/opnsense-seed-$VMID && chmod 600 /var/lib/vz/template/iso/$SEED_ISO"
  nx "qm set $VMID --ide2 local:iso/$SEED_ISO,media=cdrom >/dev/null"

  [ "$SHAPE" != standing ] || standing_wan_guard
  log "first boot, answering the config importer over the serial socket"
  nx "qm start $VMID"
  printf '%s\n' "$SERIAL_DRIVER" | nx "cat > /root/opnsense-importer-driver-$VMID.py"
  nx "python3 /root/opnsense-importer-driver-$VMID.py /var/run/qemu-server/$VMID.serial0" > "$tmp/console.log" 2>&1 \
    || { tail -40 "$tmp/console.log" >&2; die "importer drive failed (console tail above)"; }
  nx "rm -f /root/opnsense-importer-driver-$VMID.py"
  wait_api 600
  log "API up on $WAN_IP with its API key; $(api GET core/firmware/info | jq -r .product.product_version)"

  cmd_finish
}

# The half after the first boot — also the RESUME verb: a bootstrap that died after the import
# (VM up, API answering with the wallet key, no snapshot yet) continues here; every step checks
# the outcome, not the job status, so a re-run redoes only what is missing.
cmd_finish() {
  [ "$(vm_status)" = running ] || die "VM $VMID is not running"
  nx "qm listsnapshot $VMID" | grep -qw -- "$SNAP" && die "snapshot $SNAP exists — nothing to finish"
  wait_api 300
  firmware_update
  local p
  for p in $PLUGINS; do
    if installed_plugin "$p"; then log "$p already installed"; continue; fi
    log "install $p"
    api POST "core/firmware/install/$p" >/dev/null
    wait_firmware_job || true
    installed_plugin "$p" || die "$p not installed after the firmware job"
  done

  log "clean shutdown → drop the seed CD → snapshot $SNAP"
  nx "qm shutdown $VMID --timeout 180"
  nx "qm config $VMID | grep -q '^ide2:' && qm set $VMID --delete ide2 >/dev/null; rm -f /var/lib/vz/template/iso/$SEED_ISO"
  nx "qm snapshot $VMID $SNAP --description 'FU-297 baseline: $SERIES + $PLUGINS, API+SSH, before any homelab playbook'"
  nx "qm start $VMID"
  wait_api 600
  cmd_status
}

installed_plugin() { api GET core/firmware/info | jq -e --arg p "$1" '.plugin[] | select(.name==$p and .installed=="1")' >/dev/null; }

# Poll upgradestatus until the job ends; a reboot request is followed. Returns 1 on a reported
# `error` — which the 2026-09-29 build saw for an update that had in fact landed (26.1.11_10 on
# disk), so callers judge by the OUTCOME (version / installed plugin), never by this status.
wait_firmware_job() {
  local st deadline=$(( $(date +%s) + 1800 ))
  sleep 5
  while :; do
    st="$(api GET core/firmware/upgradestatus 2>/dev/null | jq -r .status 2>/dev/null || echo down)"
    case "$st" in
      done) return 0 ;;
      reboot) log "firmware job asks for a reboot"; api POST core/firmware/reboot >/dev/null || true
              sleep 60; wait_api 900; return 0 ;;
      error) log "firmware job reports error (judged by outcome): $(api GET core/firmware/upgradestatus 2>/dev/null | jq -r .log 2>/dev/null | tail -3)"
             return 1 ;;
      down) sleep 20; wait_api 900 ;;  # the job may reboot on its own
    esac
    [ "$(date +%s)" -lt "$deadline" ] || die "firmware job did not finish"
    sleep 10
  done
}

firmware_update() {  # minor updates within the series until the version reads $SERIES
  local v i
  for i in 1 2 3; do
    v="$(api GET core/firmware/info | jq -r .product.product_version)"
    case "$v" in "$SERIES"|"$SERIES"_*) log "at $v"; return 0 ;; esac
    log "update pass $i from $v"
    api POST core/firmware/update >/dev/null
    wait_firmware_job || { sleep 30; wait_api 900; }
  done
  v="$(api GET core/firmware/info | jq -r .product.product_version)"
  case "$v" in "$SERIES"|"$SERIES"_*) return 0 ;; esac
  die "still at $v after 3 update passes — the mirror's ${SERIES%.*} head moved past $SERIES? (doc §Version)"
}

cmd_status() {
  echo "vm $VMID: $(vm_status)"
  nx "qm listsnapshot $VMID"
  if api GET core/firmware/info > /dev/null 2>&1; then
    api GET core/firmware/info | jq -r '"version: \(.product.product_version)", (.plugin[] | select(.installed=="1") | "plugin: \(.name) \(.version)")'
  else
    echo "API: not answering on $WAN_IP"
  fi
}

# ---- ephemeral VMs (the rebuild drill) — the hardware tofu gives 9110, made by qm --------------
# Same shape as tofu/opnsense-test.tf's VM (2 cores host, 2 GiB, 8 GiB on nvme-thin born from the
# nano image, net0 = LAN on the isolated bridge, net1 = WAN on vmbr0, serial console), created
# STOPPED — `bootstrap` owns the first boot. Both verbs refuse the tofu-owned vmid and any VM
# whose name is not OPN_TEST_VM_NAME, and that name may not be the tofu VM's.
NANO_IMG="${OPN_TEST_NANO_IMG:-/var/lib/vz/template/iso/OPNsense-$NANO_VERSION-nano-amd64.img}"   # = tofu proxmox_download_file.opnsense_nano_nx02 (local:iso — import-from wants the path)
ephemeral_guard() {
  [ "$VMID" != "$TOFU_VMID" ] || die "REFUSING: vmid $VMID is the tofu-owned test VM"
  [ "$VMNAME" != opnsense-test ] || die "REFUSING: '$VMNAME' is the tofu-owned test VM's name — set OPN_TEST_VM_NAME"
}
# The router shape's WAN NIC must be DARK: with the old router's MAC spoofed, a cabled port would
# take the ISP lease from the live router. Refuses a NIC with carrier, one enslaved to a bridge,
# one sharing its IOMMU group, or one the host holds an address on. Prints the PCI address.
# A NIC a previous run left on vfio-pci is handed back to its host driver first (wan_nic_release):
# with no host netdev there is no carrier to read, and "could not look" must never pass.
wan_nic_guard() {
  [ -n "$WAN_PCI" ] && [ -n "$WAN_MAC" ] || die "router shape needs OPN_TEST_WAN_PCI + OPN_TEST_WAN_MAC"
  wan_nic_release
  nx "sh -s $WAN_PCI" >&2 <<'SH' || die "WAN NIC $WAN_PCI refused (above)"
d=/sys/bus/pci/devices/$1
[ -d "$d" ] || { echo "no PCI device $1"; exit 1; }
[ "$(ls /sys/kernel/iommu_groups/$(basename $(readlink $d/iommu_group))/devices | wc -l)" = 1 ] || { echo "$1 shares its IOMMU group"; exit 1; }
ls $d/net/* >/dev/null 2>&1 || { echo "$1 has no host netdev (driver: $(basename $(readlink $d/driver 2>/dev/null) 2>/dev/null)) - cannot read its carrier"; exit 1; }
for n in $d/net/*; do
  i=$(basename $n)
  # carrier is unreadable on an admin-down port: raise it (no address), read, restore
  up=$(cat $n/operstate); [ "$up" != down ] || { ip link set $i up; sleep 4; }
  c=$(cat $n/carrier 2>/dev/null || echo unreadable); [ "$up" != down ] || ip link set $i down
  [ "$c" = 0 ] || { echo "$i ($1) carrier=$c - cabled?; never spoof the live router's MAC onto it"; exit 1; }
  [ ! -e $n/master ] || { echo "$i ($1) is enslaved to $(basename $(readlink $n/master))"; exit 1; }
  [ -z "$(ip -br addr show dev $i | awk '{print $3}')" ] || { echo "$i ($1) has a host address"; exit 1; }
done
SH
  printf '%s' "$WAN_PCI"
}
# Hand a passed-through NIC back to its host driver (Proxmox leaves it on vfio-pci after the VM
# stops), so the host sees its link again — the guard's carrier read depends on it.
wan_nic_release() {
  [ -n "$WAN_PCI" ] || return 0
  nx "sh -s $WAN_PCI" >&2 <<'SH'
d=/sys/bus/pci/devices/$1
[ "$(basename $(readlink $d/driver 2>/dev/null) 2>/dev/null)" = vfio-pci ] || exit 0
echo "$1: vfio-pci -> host driver"
echo "$1" > /sys/bus/pci/drivers/vfio-pci/unbind
echo > $d/driver_override
echo "$1" > /sys/bus/pci/drivers_probe
for _ in 1 2 3 4 5 6 7 8 9 10; do ls $d/net/* >/dev/null 2>&1 && break; sleep 1; done
sleep 3   # link detection settles before anyone reads carrier
SH
}
# The BRIDGED shape: WAN_PCI's netdev (dark, guarded above) becomes the only port of a runtime
# bridge with no host address; the VM's third virtio NIC sits on it. Never a bridge the host's
# /etc/network/interfaces defines — this one is created here and deleted by destroy.
wan_bridge_up() {
  nx "sh -s $WAN_PCI $WAN_BRIDGE" >&2 <<'SH' || die "could not build the WAN bridge (above)"
d=/sys/bus/pci/devices/$1; br=$2
grep -q "^iface $br " /etc/network/interfaces && { echo "$br is a configured host bridge - refusing"; exit 1; }
[ -e /sys/class/net/$br ] && { echo "$br already exists (a stale run?) - refusing"; exit 1; }
i=$(basename $(ls -d $d/net/* | head -1))
ip link add $br type bridge && ip link set $i master $br && ip link set $i up && ip link set $br up
[ -z "$(ip -br addr show dev $br | awk '{print $3}')" ] || { echo "$br has an address"; exit 1; }
echo "$br: port $i ($1), no address"
SH
}
wan_bridge_down() {
  nx "sh -s $WAN_PCI $WAN_BRIDGE" >&2 <<'SH'
d=/sys/bus/pci/devices/$1; br=$2
grep -q "^iface $br " /etc/network/interfaces && { echo "$br is a configured host bridge - leaving it"; exit 0; }
for n in $d/net/*; do [ -e $n ] || continue; i=$(basename $n); ip link set $i nomaster 2>/dev/null; ip link set $i down; done
[ -e /sys/class/net/$br ] && ip link del $br && echo "$br removed"
exit 0
SH
}
cmd_create() {
  ephemeral_guard
  nx "qm config $VMID" >/dev/null 2>&1 && die "vmid $VMID already exists on nx-02 — destroy it first"
  nx "grep -q '^iface $LAN_BRIDGE ' /etc/network/interfaces" || die "bridge $LAN_BRIDGE not on nx-02 (tofu/opnsense-test.tf)"
  nx "test -f $NANO_IMG" || die "$NANO_IMG not on nx-02 (tofu)"
  local pci=''
  if [ "$SHAPE" = router ] && [ "$WAN_MODE" = bridged ]; then
    wan_nic_guard >/dev/null; wan_bridge_up; pci="--net2 virtio,bridge=$WAN_BRIDGE,firewall=0,queues=2"
    log "create $VMNAME ($VMID): LAN $LAN_BRIDGE, MGMT vmbr0, WAN = vtnet2 on $WAN_BRIDGE over host NIC $WAN_PCI (bridged)"
  elif [ "$SHAPE" = router ]; then pci="--hostpci0 $(wan_nic_guard)"
    log "create $VMNAME ($VMID): LAN $LAN_BRIDGE, MGMT vmbr0, WAN = host NIC $WAN_PCI (passthrough)"
  else log "create $VMNAME ($VMID): LAN $LAN_BRIDGE, WAN vmbr0"; fi
  nx "qm create $VMID --name $VMNAME --tags 'opnsense;drill' --cores 2 --cpu host --memory 2048 --balloon 0 \
        --ostype other --scsihw virtio-scsi-pci --serial0 socket --onboot 0 \
        --net0 virtio,bridge=$LAN_BRIDGE,firewall=0 --net1 virtio,bridge=vmbr0,firewall=0 $pci \
        --scsi0 nvme-thin:0,import-from=$NANO_IMG,discard=on,ssd=1 --boot order=scsi0 >/dev/null"
  nx "qm disk resize $VMID scsi0 8G >/dev/null"
  nx "qm config $VMID | grep -E '^(name|net0|net1|scsi0):'"
}
cmd_destroy() {
  ephemeral_guard
  local name
  # "No such vm" must reach the branch below, not kill the script under pipefail (review,
  # #2111) — so the absent case exits 0 ON nx-02, and only an ssh failure (255) stays fatal.
  name="$(nx "if qm config $VMID >/dev/null 2>&1; then qm config $VMID | sed -n 's/^name: //p'; fi")"
  if [ -z "$name" ]; then
    [ "$SHAPE" != router ] || [ "$WAN_MODE" != bridged ] || wan_bridge_down
    log "vmid $VMID not present — nothing to destroy"; return 0
  fi
  [ "$name" = "$VMNAME" ] || die "REFUSING destroy: vmid $VMID is '$name', not '$VMNAME'"
  nx "qm stop $VMID --skiplock 1 >/dev/null 2>&1 || true; qm destroy $VMID --purge 1 --destroy-unreferenced-disks 1"
  nx "rm -f /var/lib/vz/template/iso/$SEED_ISO"
  if [ "$SHAPE" = router ] && [ "$WAN_MODE" = bridged ]; then wan_bridge_down
  elif [ "$SHAPE" = router ]; then wan_nic_release; fi
  log "destroyed $VMNAME ($VMID)"
}

case "${1:-}" in
  create)    cmd_create ;;
  destroy)   cmd_destroy ;;
  bootstrap) cmd_bootstrap ;;
  finish)    cmd_finish ;;
  status)    cmd_status ;;
  render)    [ -n "${2:-}" ] || die "usage: render <out-file>"; ensure_secrets; render "$2" ;;
  *) sed -n '2,24p' "$0" >&2; exit 2 ;;
esac
