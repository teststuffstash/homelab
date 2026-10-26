#!/usr/bin/env bash
# Carry renewed Let's Encrypt certificates from the CARP MASTER router to the BACKUP (FU-297,
# docs/router-move.md §The identity the new router carries). Only the MASTER can order: the WAN
# gate gives the BACKUP no WAN link, so its own acme.sh renewals fail structurally (statusCode 400)
# and its carried copies age out — a failover after that serves an expired cert. This is the
# BACKUP's renewal path: the MASTER's trust-store cert + key land on the BACKUP under the SAME
# refid (every HAProxy frontend binds `ssl_certificates` by refid — verified on both nodes), the
# BACKUP's ACME row takes the MASTER's status fields (so its cron stops ordering what it cannot
# order), then ONE HAProxy reconfigure on the BACKUP.
#
#   bash scripts/opnsense-cert-carry.sh <master> <backup> [--dry-run] [--only <name,...>]
#
# <master>/<backup>: nx02 | pve (ansible/router-nodes/inventory.yml ansible_host) or an IPv4
# literal (the FU-297 test VM as a target). Refuses unless <master> is currently CARP MASTER
# (/api/diagnostics/interface/get_vip_status) and <backup> is not. Idempotent: a copy whose
# notAfter already equals the MASTER's is `up-to-date`, nothing is written, HAProxy is not
# touched. `--dry-run` prints the same plan and performs NO POST.
#
# Per cert: `<name>  backup <notAfter> -> master <notAfter>  <action>` where action is one of
#   carry        the MASTER's cert is newer: trust set/<uuid> on the BACKUP (same refid)
#   add          the BACKUP has no trust cert with that refid (minted on the MASTER after the
#                seed, e.g. homelab.teststuff.net 2026-10-16): trust add under the MASTER's refid;
#                the BACKUP's HAProxy frontend binds it at the next opnsense-haproxy converge
#   up-to-date   same notAfter on both — skipped
#   backup-newer the BACKUP's copy is newer (never expected; the MASTER renews) — skipped, exit 3
#   no-row       the BACKUP has no ACME row of that name — cert carried, status not written, exit 3
#
# API (OPNsense 26.7, verified READ-ONLY against the live pair 2026-10-26):
#   GET  trust/cert/search                   rows: uuid, refid, descr, caref, valid_to, crt_payload, prv_payload
#   POST trust/cert/set/<uuid> | add          {"cert":{"action":"import","refid":…,"crt_payload":…,"prv_payload":…}}
#                                             (CertController::setBaseHook keeps a non-empty refid, checks key<->cert)
#   GET  acmeclient/certificates/search|get   rows: uuid, name, certRefId, statusCode, lastUpdate, statusLastUpdate
#   POST acmeclient/certificates/update/<uuid>  {"certificate":{…}} (plain setBase; the status fields are model fields)
#   POST haproxy/service/reconfigure
#
# Creds: the wallet pair opnsense-api-{key,secret} (prod's, carried to both nodes) — OPN_API_KEY /
# OPN_API_SECRET pre-set win. A target with its own creds (the test VM): OPN_BACKUP_API_KEY /
# OPN_BACKUP_API_SECRET, or OPN_BACKUP_KEY_ENTRY / OPN_BACKUP_SECRET_ENTRY naming wallet entries.
# The trust search carries private keys: it lives in a 0700 workdir and is shredded on exit.
#
# Exit: 0 done (or nothing to do) · 1 fatal (guard, API error) · 2 usage · 3 done with warnings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
usage() { sed -n '11p' "$0" >&2; exit 2; }
log() { echo "[cert-carry] $*" >&2; }
die() { log "FAIL: $*"; exit 1; }

MASTER=''; BACKUP=''; DRY=0; ONLY=''
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --only) [ -n "${2:-}" ] || usage; ONLY="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) if [ -z "$MASTER" ]; then MASTER="$1"; elif [ -z "$BACKUP" ]; then BACKUP="$1"; else usage; fi; shift ;;
  esac
done
[ -n "$MASTER" ] && [ -n "$BACKUP" ] || usage
[ "$MASTER" != "$BACKUP" ] || die "master and backup are the same node"

tool() { if command -v "$1" >/dev/null 2>&1; then "$@"; else devbox run --quiet -- "$@"; fi; }
INV=ansible/router-nodes/inventory.yml
resolve() {   # nx02|pve -> the node's ansible_host; an IPv4 literal passes through
  case "$1" in
    nx02|pve) tool yq -r ".all.children.opnsense.hosts[\"opnsense-$1\"].ansible_host" "$INV" ;;
    *) grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$1" || die "'$1' is neither nx02|pve nor an IPv4 literal"; echo "$1" ;;
  esac
}
MH="$(resolve "$MASTER")"; BH="$(resolve "$BACKUP")"
for h in "$MH" "$BH"; do [ "$h" != 192.168.2.1 ] || die "a node is never addressed as the .1 VIP"; done
[ "$MH" != "$BH" ] || die "master and backup resolve to the same address ($MH)"

KDB="$HOME/.claude/homelab-keepass/homelab.kdbx"
kp() { tool keepassxc-cli show -q --no-password -k "$HOME/.claude/homelab-keepass/homelab.keyx" -a Password "$KDB" "$1" 2>/dev/null; }
WORK="$(mktemp -d)"; chmod 700 "$WORK"
cleanup() { find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
umask 077
MK="${OPN_API_KEY:-$(kp opnsense-api-key)}"; MS="${OPN_API_SECRET:-$(kp opnsense-api-secret)}"
[ -n "$MK" ] && [ -n "$MS" ] || die "empty OPNsense API creds (wallet entry opnsense-api-key/-secret, or OPN_API_KEY/OPN_API_SECRET)"
BK="${OPN_BACKUP_API_KEY:-}"; BS="${OPN_BACKUP_API_SECRET:-}"
if [ -z "$BK" ] && [ -n "${OPN_BACKUP_KEY_ENTRY:-}" ]; then BK="$(kp "$OPN_BACKUP_KEY_ENTRY")"; BS="$(kp "${OPN_BACKUP_SECRET_ENTRY:?set OPN_BACKUP_SECRET_ENTRY with OPN_BACKUP_KEY_ENTRY}")"; fi
printf 'user = "%s:%s"\n' "$MK" "$MS" > "$WORK/m.curl"
printf 'user = "%s:%s"\n' "${BK:-$MK}" "${BS:-$MS}" > "$WORK/b.curl"
unset MK MS BK BS

# api <m|b> GET|POST <path> [json-file] -> body on stdout; a non-2xx is fatal with the body shown
api() {
  local cfg="$WORK/$1.curl" host out code
  case "$1" in m) host="$MH" ;; b) host="$BH" ;; esac
  out="$WORK/resp.$$"
  if [ "$2" = POST ] && [ -n "${4:-}" ]; then
    code="$(curl -sk -K "$cfg" --max-time 60 -o "$out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      --data "@$4" "https://$host/api/$3")" || die "POST $host/api/$3: curl failed"
  elif [ "$2" = POST ]; then   # a bodyless POST (service/reconfigure): no JSON content-type — an empty JSON body is a 400
    code="$(curl -sk -K "$cfg" --max-time 60 -o "$out" -w '%{http_code}' -X POST "https://$host/api/$3")" || die "POST $host/api/$3: curl failed"
  else
    code="$(curl -sk -K "$cfg" --max-time 60 -o "$out" -w '%{http_code}' "https://$host/api/$3")" || die "GET $host/api/$3: curl failed"
  fi
  case "$code" in 2*) cat "$out"; rm -f "$out" ;; *) log "$2 $host/api/$3 -> HTTP $code: $(cut -c1-400 "$out")"; rm -f "$out"; return 1 ;; esac
}
post() { [ "$DRY" = 0 ] || die "internal: POST under --dry-run"; api "$@"; }   # every write funnels through here

# ---- the CARP guard: <master> IS MASTER now, <backup> is not ------------------------------------
carp_role() {   # the status of the carp VIP(s) on a node: MASTER|BACKUP|INIT|…, "none" when no CARP
  api "$1" GET diagnostics/interface/get_vip_status | tool jq -r '[.rows[]? | select(.mode=="carp") | .status] | unique | if length==0 then "none" else join(",") end'
}
MROLE="$(carp_role m)" || die "cannot read $MASTER's CARP status"
[ "$MROLE" = MASTER ] || die "refusing: $MASTER ($MH) is CARP '$MROLE', not MASTER — the carry runs FROM the node that renews"
BROLE="$(carp_role b)" || die "cannot read $BACKUP's CARP status"
case "$BROLE" in
  MASTER|*MASTER*) die "refusing: $BACKUP ($BH) reports CARP '$BROLE' too — split brain or wrong arguments" ;;
  BACKUP) ;;
  none) log "note: $BACKUP ($BH) has no CARP VIP (a test VM?) — carrying anyway" ;;
  *) log "note: $BACKUP ($BH) is CARP '$BROLE'" ;;
esac
log "master $MASTER ($MH) is CARP MASTER; backup $BACKUP ($BH) is CARP $BROLE$( [ "$DRY" = 1 ] && echo '; DRY RUN — no writes')"

# ---- read both sides once ------------------------------------------------------------------------
api m GET acmeclient/certificates/search > "$WORK/m.acme" || die "master ACME rows unreadable"
api b GET acmeclient/certificates/search > "$WORK/b.acme" || die "backup ACME rows unreadable"
api m GET trust/cert/search > "$WORK/m.trust" || die "master trust store unreadable"
api b GET trust/cert/search > "$WORK/b.trust" || die "backup trust store unreadable"
jqf() { tool jq "$@"; }
utc() { date -u -d "@$1" +%F 2>/dev/null || echo "@$1"; }

# the master's issued rows (statusCode 200 with a bound trust cert), optionally filtered by --only
only_filter='true'
if [ -n "$ONLY" ]; then only_filter='(.name as $n | ($only | split(",")) | index($n) != null)'; fi
mapfile -t ROWS < <(jqf -r --arg only "$ONLY" \
  ".rows[] | select(.statusCode==\"200\" and .certRefId!=\"\" and $only_filter) | [.uuid,.name,.certRefId,.statusCode,.lastUpdate,.statusLastUpdate] | @tsv" "$WORK/m.acme")
[ "${#ROWS[@]}" -gt 0 ] || die "no issued ACME row on the master matches${ONLY:+ --only $ONLY}"
if [ -n "$ONLY" ]; then
  for n in ${ONLY//,/ }; do
    jqf -e --arg n "$n" '[.rows[] | select(.name==$n)] | length > 0' "$WORK/m.acme" >/dev/null || die "--only: the master has no ACME row named $n"
  done
fi

WARN=0; CARRIED=0; declare -a PLAN=()
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r m_uuid name refid m_status m_last m_statuslast <<< "$row"
  m_to="$(jqf -r --arg r "$refid" '[.rows[] | select(.refid==$r)][0].valid_to // empty' "$WORK/m.trust")"
  [ -n "$m_to" ] || { echo "$name  master has no trust cert for refid $refid  skip"; WARN=1; continue; }
  b_uuid="$(jqf -r --arg r "$refid" '[.rows[] | select(.refid==$r)][0].uuid // empty' "$WORK/b.trust")"
  b_to="$(jqf -r --arg r "$refid" '[.rows[] | select(.refid==$r)][0].valid_to // empty' "$WORK/b.trust")"
  b_acme="$(jqf -r --arg n "$name" '[.rows[] | select(.name==$n)][0].uuid // empty' "$WORK/b.acme")"
  if [ -z "$b_uuid" ]; then action=add
  elif [ "$m_to" -gt "$b_to" ]; then action=carry
  elif [ "$m_to" -eq "$b_to" ]; then action=up-to-date
  else action=backup-newer; WARN=1; fi
  [ -n "$b_acme" ] || { action="$action,no-row"; WARN=1; }
  echo "$name  backup $( [ -n "$b_to" ] && utc "$b_to" || echo none) -> master $(utc "$m_to")  $action"
  case "$action" in carry*|add*) PLAN+=("$m_uuid|$name|$refid|$b_uuid|$b_acme|$m_last|$m_statuslast|${action%%,*}") ;; esac
done

if [ "${#PLAN[@]}" -eq 0 ]; then log "nothing to carry"; exit $(( WARN ? 3 : 0 )); fi
if [ "$DRY" = 1 ]; then log "dry run: ${#PLAN[@]} cert(s) would be written to $BACKUP, then one HAProxy reconfigure"; exit $(( WARN ? 3 : 0 )); fi

# ---- write: trust cert under the same refid, then the ACME row's status fields -------------------
for p in "${PLAN[@]}"; do
  IFS='|' read -r m_uuid name refid b_uuid b_acme m_last m_statuslast action <<< "$p"
  # the MASTER's trust row -> an import body: the WHOLE row (search rows are already flat; the
  # `%x` labels and the computed/stored fields dropped) with action=import and the PEMs as
  # payloads. A minimal body saves on `add` but fails validation on `set` (the volatile Required
  # fields — cert_type, key_type, … — are checked on an existing node; probed on the test VM).
  jqf --arg r "$refid" '[.rows[] | select(.refid==$r)][0]
    | with_entries(select(.key | startswith("%") | not))
    | del(.uuid, .in_use, .is_user, .name, .valid_from, .valid_to, .crt, .prv, .csr, .csr_payload)
    | .action = "import" | .cert_type = (if .cert_type == "" then "server_cert" else .cert_type end) | {cert: .}' \
    "$WORK/m.trust" > "$WORK/cert.json"
  jqf -e '.cert.crt_payload | startswith("-----BEGIN CERTIFICATE-----")' "$WORK/cert.json" >/dev/null || die "$name: master trust row has no PEM crt_payload"
  jqf -e '.cert.prv_payload | startswith("-----BEGIN")' "$WORK/cert.json" >/dev/null || die "$name: master trust row has no private key payload"
  if [ "$action" = add ]; then r="$(post b POST trust/cert/add "$WORK/cert.json")" || die "$name: trust add failed"
  else r="$(post b POST "trust/cert/set/$b_uuid" "$WORK/cert.json")" || die "$name: trust set/$b_uuid failed"; fi
  shred -u "$WORK/cert.json"
  [ "$(jqf -r '.result // empty' <<< "$r")" = saved ] || die "$name: trust write not saved: $(cut -c1-400 <<< "$r")"
  # verify by reading the BACKUP back: the refid's notAfter must now be the MASTER's
  m_to="$(jqf -r --arg r "$refid" '[.rows[] | select(.refid==$r)][0].valid_to' "$WORK/m.trust")"
  b_now="$(api b GET trust/cert/search | jqf -r --arg r "$refid" '[.rows[] | select(.refid==$r)] | map(.valid_to) | unique | join(",")')"
  [ "$b_now" = "$m_to" ] || die "$name: backup reads valid_to '$b_now' after the write, master has $m_to"
  log "$name: trust $action -> backup refid $refid now valid to $(utc "$m_to")"
  CARRIED=$((CARRIED+1))
  [ -n "$b_acme" ] || { log "$name: no ACME row on the backup — status not written (the acme play creates rows)"; continue; }
  # the BACKUP's ACME row: get -> flatten dropdowns to their selected keys (an EMPTY relation comes
  # back as a JSON array `[]`, which the API rejects if posted back — "Unexpected error") -> take
  # the MASTER's status fields -> update. UniqueIdField `id` is not posted back.
  api b GET "acmeclient/certificates/get/$b_acme" | jqf --arg ref "$refid" --arg last "$m_last" --arg slast "$m_statuslast" '
    .certificate | del(.id)
    | with_entries(.value |= (if type=="array" then "" elif type=="object" then ([to_entries[] | select(.value.selected==1) | .key] | join(",")) else . end))
    | .certRefId=$ref | .lastUpdate=$last | .statusCode="200" | .statusLastUpdate=$slast
    | {certificate: .}' > "$WORK/acme.json"
  r="$(post b POST "acmeclient/certificates/update/$b_acme" "$WORK/acme.json")" || die "$name: ACME row update failed"
  [ "$(jqf -r '.result // empty' <<< "$r")" = saved ] || die "$name: ACME row not saved: $(cut -c1-400 <<< "$r")"
  log "$name: ACME row $b_acme -> certRefId $refid, statusCode 200, lastUpdate $(utc "$m_last")"
done

# ---- one HAProxy reconfigure on the BACKUP (the certs' restart action; the GUI cert, if any, is
#      picked up by the web GUI's next restart — not done here) -----------------------------------
r="$(post b POST haproxy/service/reconfigure)" || die "HAProxy reconfigure on $BACKUP failed"
[ "$(jqf -r '.status // empty' <<< "$r")" = ok ] || die "HAProxy reconfigure answered: $(cut -c1-400 <<< "$r")"
log "carried $CARRIED cert(s) to $BACKUP; HAProxy reconfigured"
exit $(( WARN ? 3 : 0 ))
