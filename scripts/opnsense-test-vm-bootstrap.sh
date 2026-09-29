#!/usr/bin/env bash
# opnsense-test (FU-297): BUILD the OPNsense test VM's guest — its first boot through to the
# baseline snapshot. The VM's HARDWARE is tofu (tofu/opnsense-test.tf); USING it (per-run
# rollback to the baseline, the plays, the report) is scripts/opnsense-test-vm.sh. Why this
# mechanism, and the recipes: docs/opnsense-test-vm.md.
#
#   bash scripts/opnsense-test-vm-bootstrap.sh bootstrap   # never-booted disk → snapshot `baseline`
#   bash scripts/opnsense-test-vm-bootstrap.sh status      # power, snapshots, version, plugins
#   bash scripts/opnsense-test-vm-bootstrap.sh render F    # the seed config.xml to F (debug; mode 600)
#
# Same env names as the harness: OPN_TEST_VMID (9110), OPN_TEST_HOST (192.168.2.67),
# OPN_TEST_SNAPSHOT (baseline) — the harness's own defaults/expectations, so what this builds
# is what it rolls back to.
#
# Secrets live in the wallet ONLY (created on first bootstrap if missing):
#   opnsense-test-root-password  opnsense-test-api-key  opnsense-test-api-secret
# SSH: root key login with the shared pve seed key (~/.claude/homelab-pve-ssh/id_ed25519).
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

VMID="${OPN_TEST_VMID:-9110}"                       # = tofu var.opnsense_test_vm_id
WAN_IP="${OPN_TEST_HOST:-192.168.2.67}"           # = tofu var.opnsense_test_wan_ip_cidr
WAN_BITS=24
GATEWAY=192.168.2.1
MGMT_NET=192.168.2.0/24
LAN_IP=192.168.1.1                                 # docs/ip-plan.md: 1.0/24, isolated-bridge carve
LAN_BITS=24
LAN_DHCP_START=192.168.1.100
LAN_DHCP_END=192.168.1.199
SERIES=26.1.11                                     # prod's version (GET /api/core/firmware/info)
PLUGINS="os-frr os-haproxy os-acme-client"         # what the ansible/opnsense-*.yml plays drive
SNAP="${OPN_TEST_SNAPSHOT:-baseline}"      # the harness default (OPN_TEST_SNAPSHOT)

NX02=root@192.168.2.59
SSH_KEY="$HOME/.claude/homelab-pve-ssh/id_ed25519"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -i "$SSH_KEY")
KP_DB="$HOME/.claude/homelab-keepass/homelab.kdbx"
KP_KEY="$HOME/.claude/homelab-keepass/homelab.keyx"
SEED_ISO=opnsense-test-seed.iso                    # on nx-02 local:iso, only during bootstrap

log() { printf '[opnsense-test] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
nx() { ssh "${SSH_OPTS[@]}" "$NX02" "$@"; }
vm_ssh() { ssh "${SSH_OPTS[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o LogLevel=ERROR "root@$WAN_IP" "$@"; }

kp() { DEVBOX_QUIET=1 devbox run --quiet -- keepassxc-cli "$@"; }
kp_get() { kp show -q --no-password -k "$KP_KEY" -a Password "$KP_DB" "$1" 2>/dev/null; }
kp_has() { kp show -q --no-password -k "$KP_KEY" "$KP_DB" "$1" >/dev/null 2>&1; }
# Add an entry with a given value (stdin, never argv). Refuses to overwrite.
kp_add() {
  kp_has "$1" && die "wallet entry $1 already exists — refusing to overwrite"
  printf '%s\n' "$2" | kp add -q --no-password -k "$KP_KEY" -p "$KP_DB" "$1" >/dev/null
  [ "$(kp_get "$1")" = "$2" ] || die "wallet write of $1 did not read back"
}

ensure_secrets() {
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
  keys_b64="$(base64 -w0 < "$SSH_KEY.pub")"
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
  nx "umask 077; mkdir -p /root/opnsense-test-seed/conf && cat > /root/opnsense-test-seed/conf/config.xml" < "$tmp/iso/conf/config.xml"
  nx "genisoimage -quiet -R -J -V OPNSEED -o /var/lib/vz/template/iso/$SEED_ISO /root/opnsense-test-seed && rm -rf /root/opnsense-test-seed && chmod 600 /var/lib/vz/template/iso/$SEED_ISO"
  nx "qm set $VMID --ide2 local:iso/$SEED_ISO,media=cdrom >/dev/null"

  log "first boot, answering the config importer over the serial socket"
  nx "qm start $VMID"
  printf '%s\n' "$SERIAL_DRIVER" | nx "cat > /root/opnsense-importer-driver.py"
  nx "python3 /root/opnsense-importer-driver.py /var/run/qemu-server/$VMID.serial0" > "$tmp/console.log" 2>&1 \
    || { tail -40 "$tmp/console.log" >&2; die "importer drive failed (console tail above)"; }
  nx "rm -f /root/opnsense-importer-driver.py"
  wait_api 600
  log "API up on $WAN_IP with the wallet key; $(api GET core/firmware/info | jq -r .product.product_version)"

  firmware_update
  for p in $PLUGINS; do
    log "install $p"
    api POST "core/firmware/install/$p" >/dev/null
    wait_firmware_job
  done

  log "clean shutdown → drop the seed CD → snapshot $SNAP"
  nx "qm shutdown $VMID --timeout 180"
  nx "qm set $VMID --delete ide2 && rm -f /var/lib/vz/template/iso/$SEED_ISO"
  nx "qm snapshot $VMID $SNAP --description 'FU-297 baseline: $SERIES + $PLUGINS, API+SSH, before any homelab playbook'"
  nx "qm start $VMID"
  wait_api 600
  cmd_status
}

wait_firmware_job() {  # poll upgradestatus until done; a reboot request is followed
  local st deadline=$(( $(date +%s) + 1800 ))
  sleep 5
  while :; do
    st="$(api GET core/firmware/upgradestatus 2>/dev/null | jq -r .status 2>/dev/null || echo down)"
    case "$st" in
      done) return 0 ;;
      reboot) log "firmware job asks for a reboot"; api POST core/firmware/reboot >/dev/null || true
              sleep 60; wait_api 900; return 0 ;;
      error) die "firmware job failed: $(api GET core/firmware/upgradestatus | jq -r .log | tail -5)" ;;
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
    wait_firmware_job
  done
  v="$(api GET core/firmware/info | jq -r .product.product_version)"
  case "$v" in "$SERIES"|"$SERIES"_*) return 0 ;; esac
  die "still at $v after 3 update passes — the mirror's 26.1 head moved past $SERIES? (doc §Version)"
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

case "${1:-}" in
  bootstrap) cmd_bootstrap ;;
  status)    cmd_status ;;
  render)    [ -n "${2:-}" ] || die "usage: render <out-file>"; ensure_secrets; render "$2" ;;
  *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac
