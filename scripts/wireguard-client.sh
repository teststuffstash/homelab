#!/usr/bin/env bash
# Render a WireGuard client config for a peer listed in group_vars (wireguard_peers).
#
#   bash scripts/wireguard-client.sh laptop         # write ~/.claude/homelab-wireguard/laptop.conf
#   bash scripts/wireguard-client.sh phone --qr     # + QR in the terminal (WireGuard app scans it)
#
# The peer's PRIVATE key lives only in the Tier-0 KeePass wallet (entry
# wireguard-<name>-privkey) — created here if missing, in which case paste the printed
# pubkey into ansible/group_vars/opnsense.yml (wireguard_peers) and run
#   bash scripts/opnsense-playbook.sh ansible/opnsense-wireguard.yml
# The server pubkey + tunnel settings are read live from the OPNsense API / group_vars,
# so the rendered .conf never goes stale. Output dir is out-of-repo (never in git).
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <peer-name> [--qr]" >&2; exit 2; }
PEER="$1"; QR="${2:-}"

cd "$(dirname "$0")/.."
export DEVBOX_QUIET=1
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

GV=ansible/group_vars/opnsense.yml
KP_DIR="$HOME/.claude/homelab-keepass"
DB="$KP_DIR/homelab.kdbx"; KEYX="$KP_DIR/homelab.keyx"
OUT_DIR="$HOME/.claude/homelab-wireguard"

dvb() { devbox run --quiet -- "$@"; }
kp()  { dvb keepassxc-cli "$@"; }
gv()  { dvb yq ".$1" "$GV"; }

# --- peer entry from group_vars -------------------------------------------------
TUNNEL_IP="$(gv "wireguard_peers[] | select(.name == \"$PEER\") | .tunnel_ip")"
[ -n "$TUNNEL_IP" ] && [ "$TUNNEL_IP" != null ] || { echo "peer '$PEER' not in $GV (wireguard_peers)" >&2; exit 1; }
ENDPOINT="$(gv wireguard_endpoint_host):$(gv wireguard_port)"
DNS="$(gv wireguard_client_dns)"
NETWORKS="$(gv wireguard_client_networks)"

# --- private key from the wallet (generate on first use) ------------------------
ENTRY="wireguard-${PEER}-privkey"
if ! kp show -q --no-password -k "$KEYX" "$DB" "$ENTRY" >/dev/null 2>&1; then
  dvb wg genkey | kp add -q --no-password -k "$KEYX" --password-prompt "$DB" "$ENTRY" >/dev/null
  echo "+ generated $ENTRY — paste this pubkey into $GV (wireguard_peers) and re-run the playbook:"
  kp show -q --no-password -k "$KEYX" -a Password "$DB" "$ENTRY" | dvb wg pubkey
fi
PRIVKEY="$(kp show -q --no-password -k "$KEYX" -a Password "$DB" "$ENTRY")"

# --- server pubkey, live from the OPNsense API -----------------------------------
OPN_API_KEY="$(kp show -q --no-password -k "$KEYX" -a Password "$DB" opnsense-api-key)"
OPN_API_SECRET="$(kp show -q --no-password -k "$KEYX" -a Password "$DB" opnsense-api-secret)"
SERVER_PUB="$(curl -sk -u "$OPN_API_KEY:$OPN_API_SECRET" https://192.168.2.1/api/wireguard/server/searchServer \
  | dvb jq -r '.rows[] | select(.name == "roadwarrior") | .pubkey')"
[ -n "$SERVER_PUB" ] || { echo "no 'roadwarrior' WireGuard instance on OPNsense — run the playbook first" >&2; exit 1; }

mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
CONF="$OUT_DIR/$PEER.conf"
cat >"$CONF" <<EOF
[Interface]
PrivateKey = $PRIVKEY
Address = $TUNNEL_IP/32
DNS = $DNS

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = $NETWORKS
Endpoint = $ENDPOINT
PersistentKeepalive = 25
EOF
chmod 600 "$CONF"
echo "wrote $CONF"

if [ "$QR" = "--qr" ]; then
  dvb qrencode -t ansiutf8 <"$CONF"
fi
