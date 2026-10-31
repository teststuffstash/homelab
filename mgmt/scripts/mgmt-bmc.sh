#!/usr/bin/env bash
# mgmt-bmc — reach a BMC on the management segment THROUGH the management box
# (docs/management-box.md §MB4 item 7, "Access from the operator's workstation").
#
#   devbox run bmc -- <node> <ipmitool args…>   # e.g. nx-02 chassis power status | nx-01 sol activate
#   devbox run bmc-web -- <node>                # ssh -L to the BMC's web GUI / HTML5 iKVM
#
# The BMCs sit at static 192.168.15.x with no gateway (machines.yaml `bmc:`), and only the box
# has a leg on that segment, so ipmitool runs ON the box. The password never rides argv: it goes
# over the ssh session's stdin and the box side runs `ipmitool -E` (reads IPMI_PASSWORD). SOL
# needs the tty for itself, so it stages the password in a 0600 file on the box first
# (`ipmitool -f`) and removes it when the session ends.
#
# Password: the wallet entry named in machines.yaml (`bmc.wallet`, `<node>-bmc-password`; its
# UserName attribute, default ADMIN) — or IPMI_PASSWORD from the caller's environment, which wins.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${MGMT_HOST:-192.168.2.53}"
usage() { echo "usage: $0 ipmi <node> <ipmitool args…> | web <node>" >&2; exit 2; }
[ $# -ge 2 ] || usage
mode="$1" node="$2"; shift 2

CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -d "$d/homelab-pve-ssh" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "mgmt-bmc: cred dir not found (homelab-pve-ssh/ — the key the box trusts)" >&2; exit 1; }
SSH=(ssh -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$CRED/homelab-pve-ssh/id_ed25519")

entry="$(jq -r --arg n "$node-bmc" '.[$n] // empty | "\(.ip) \(.wallet)"' "$ROOT/mgmt/nixos/hosts/mgmt/bmc.json")"
[ -n "$entry" ] || { echo "mgmt-bmc: $node has no bmc: entry in machines/machines.yaml (known: $(jq -r 'keys|join(" ")' "$ROOT/mgmt/nixos/hosts/mgmt/bmc.json"))" >&2; exit 2; }
read -r ip wallet <<<"$entry"

if [ "$mode" = web ]; then
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  echo "mgmt-bmc: $node-bmc web GUI → https://localhost:$port  (self-signed; Ctrl+C closes the tunnel)" >&2
  exec "${SSH[@]}" -N -L "127.0.0.1:$port:$ip:443" "root@$HOST"
fi
[ "$mode" = ipmi ] && [ $# -ge 1 ] || usage

user=ADMIN pw="${IPMI_PASSWORD:-}"
if [ -z "$pw" ]; then
  KDB="$CRED/homelab-keepass/homelab.kdbx" KEYX="$CRED/homelab-keepass/homelab.keyx"
  kp() { keepassxc-cli show -q --no-password -k "$KEYX" -a "$2" "$KDB" "$1" 2>/dev/null; }
  pw="$(kp "$wallet" Password || true)"
  u="$(kp "$wallet" UserName || true)"; [ -n "$u" ] && user="$u"
  [ -n "$pw" ] || { echo "mgmt-bmc: no wallet entry $wallet (FU-288) — pass IPMI_PASSWORD=… for now" >&2; exit 1; }
fi
args="$(printf '%q ' "$@")"
# Addressed by IP, not the box's hosts name, so the verb works the same before the box's closure
# carries the hosts entries.
base="ipmitool -I lanplus -H $ip -U $(printf '%q' "$user")"

if [ "$1" = sol ]; then
  f="$(printf '%s' "$pw" | "${SSH[@]}" "root@$HOST" 'umask 077; f=$(mktemp); cat > "$f"; echo "$f"')"
  # shellcheck disable=SC2064
  trap "${SSH[*]} root@$HOST rm -f $f" EXIT
  echo "mgmt-bmc: $node-bmc SOL — ~~. ends it (ssh eats one ~; a bare ~. drops the ssh instead)" >&2
  "${SSH[@]}" -t "root@$HOST" "$base -f $f $args"
else
  printf '%s\n' "$pw" | "${SSH[@]}" "root@$HOST" "IFS= read -r IPMI_PASSWORD; export IPMI_PASSWORD; exec $base -E $args"
fi
