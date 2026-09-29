#!/usr/bin/env bash
# Validate an OPNsense router-config change (a PR touching ansible/opnsense-* or the oxlorg
# collection pin) against a REAL OPNsense API: the throwaway test VM on nx-02 (FU-297).
# `ansible-playbook --check` proves plumbing only; this applies, reads the running daemons
# back over SSH, and rolls the VM back afterwards.
#
#   bash scripts/opnsense-test-vm.sh --pr 2033 [--post] [--status] [--keep] [--steps "1 2 3 4 5"]
#   bash scripts/opnsense-test-vm.sh --pr 2033 --steps prep     # no VM: guard + syntax-check, both refs
#   bash scripts/opnsense-test-vm.sh --base <ref> --head <ref> [...]
#   bash scripts/opnsense-test-vm.sh --ref <rev> --steps "1 all"   # the rebuild drill: no fetch
#
# Steps (the flow in docs/runbook.md §OPNsense test VM):
#   1  rollback   qm rollback <vmid> <snapshot> on nx-02, start, wait for the API; preflight
#                 (os-frr / os-haproxy / os-acme-client present) + the fixture (below)
#   2  base       master's collection pin + roles: acme, bgp, unbound, haproxy -> must succeed;
#                 then a base RERUN (what is already non-idempotent on master: steps 3/5 label
#                 those tasks pre-existing, never a regression). FU-298: bgpd started if absent
#   3  head       the PR's collection + roles on top -> must succeed; changed= per play and the
#                 changed task names are recorded (classified after step 5, see the report)
#   4  mutation   with HEAD: one new value per service (BGP neighbour, Unbound override,
#                 HAProxy service = VIP + frontend + its override) must reach the RUNNING daemon
#                 (vtysh running-config, drill @127.0.0.1, ifconfig/sockstat). Negative control:
#                 BASE roles + HEAD collection (the #2033 regression shape) — the same kind of
#                 mutation is saved but should NOT reach the daemon
#   5  fresh      rollback again, HEAD plays twice: run 1 succeeds, run 2 changed=0 everywhere
#   all           (the rebuild drill, scripts/opnsense-drill.sh) converge ALL router code at HEAD
#                 once: every ansible/opnsense-*.yml play, then opnsense/dnsmasq-dhcp.py and
#                 opnsense/tuya-egress.py (OPN_HOST pinned to the VM). ddclient gets a dummy
#                 Cloudflare token (its account needs one; the VM's update is refused upstream)
#
# The production router is unreachable to this script BY CONSTRUCTION:
#   - it never calls scripts/opnsense-playbook.sh and never loads ansible/inventory.yml as an
#     inventory: every play gets `-i ansible/test-vm/inventory.yml` (whose one host reads its
#     address from OPN_TEST_HOST) + `--limit opnsense-test-vm`;
#   - OPN_TEST_HOST must be an IPv4 literal that is neither 192.168.2.1 nor the address the
#     prod inventory gives the `opnsense` group (read, never used as a target);
#   - ansible/test-vm/guard.yml runs before EVERY play with the same inventory + vars and
#     asserts the RENDERED opnsense_conn.firewall (what the modules will dial);
#   - the API creds are the test VM's own wallet entries (default opnsense-test-api-{key,secret}),
#     minted on the VM: the router would reject them even if everything above failed;
#   - rollback refuses unless `qm config <vmid>` names the VM OPN_TEST_VM_NAME.
#
# Collections: one install PER REF into its own path under the workdir (`-p`), selected with
# ANSIBLE_COLLECTIONS_PATH per play and version-checked against that ref's requirements.yml.
# The shared default path (~/.ansible/collections, what the prod wrapper installs into) is
# never touched.
#
# Isolation overrides (ansible/test-vm/overrides.yml): BGP neighbours -> RFC 5737 addresses,
# router-id -> the VM; no ACME cert specs (no LE order, no Cloudflare write); ACME_CF_TOKEN is
# unset. The HAProxy role asserts an ACME cert row per frontend, so the fixture imports ONE
# self-signed cert into the VM's trust store and creates DISABLED ACME rows (auto-renew off)
# of every needed name bound to it. NOT validated here: ACME issuance/signing, the Cloudflare
# validation repoint, the cert's restart actions, HAProxy serving a real backend.
#
# Environment (no defaults for the first two — the VM's identity is an explicit input):
#   OPN_TEST_HOST        the VM's WAN IPv4 on vmbr0 (API + SSH path)          [required]
#   OPN_TEST_VMID        its Proxmox vmid on nx-02                             [required]
#   OPN_TEST_SNAPSHOT    baseline snapshot name                  (default baseline)
#   OPN_TEST_VM_NAME     expected `qm config` name               (default opnsense-test)
#   OPN_TEST_PVE         hypervisor                              (default 192.168.2.59, nx-02)
#   OPN_TEST_PVE_KEY     ssh key for the hypervisor              (default ~/.claude/homelab-pve-ssh/id_ed25519)
#   OPN_TEST_SSH_KEY     ssh key for root@VM                     (default: OPN_TEST_PVE_KEY)
#   OPN_TEST_KEY_ENTRY / OPN_TEST_SECRET_ENTRY  wallet entries   (default opnsense-test-api-key / -secret)
#   OPN_TEST_API_KEY / OPN_TEST_API_SECRET      pre-set creds win over the wallet
#   OPN_TEST_WORKDIR     worktrees, collections, logs, report    (default: mktemp -d)
#   OPN_TEST_EXTRA_VARS  one more `-e @file` after overrides.yml on every play (the drill's
#                        BGP neighbour = its fake peer)                (default: none)
#   OPN_DHCP_REMAP       passed to opnsense/dnsmasq-dhcp.py by step `all` (its header)
#
# Exit: 0 PASS, 1 FAIL (a step assertion), 2 usage / guard / environment.
set -euo pipefail

usage() { sed -n '2,24p' "$0" >&2; exit 2; }
die() { echo "opnsense-test-vm: $*" >&2; exit 2; }

PR=''; BASE_REF=''; HEAD_REF=''; STEPS='1 2 3 4 5'; POST=0; STATUS=0; KEEP=0; NOFETCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    --base) BASE_REF="$2"; shift 2 ;;
    --head) HEAD_REF="$2"; shift 2 ;;
    --ref) BASE_REF="$2"; HEAD_REF="$2"; NOFETCH=1; shift 2 ;;
    --steps) STEPS="$2"; shift 2 ;;
    --post) POST=1; shift ;;
    --status) STATUS=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$PR" ] || { [ -n "$BASE_REF" ] && [ -n "$HEAD_REF" ]; } || usage
{ [ "$POST" -eq 0 ] && [ "$STATUS" -eq 0 ]; } || [ -n "$PR" ] || die "--post/--status need --pr"

cd "$(dirname "$0")/.."
ROOT="$PWD"
export NIX_CONFIG="experimental-features = nix-command flakes"
# The devbox toolchain on PATH for the whole run (ansible, yq, jq, curl, openssl, gh) — one
# resolution instead of a `devbox run` per call; the plays get their interpreter via -e below.
eval "$(devbox shellenv)"

INV="$ROOT/ansible/test-vm/inventory.yml"
OVR="$ROOT/ansible/test-vm/overrides.yml"
GUARD_SRC="$ROOT/ansible/test-vm/guard.yml"
PLAYS='opnsense-acme.yml opnsense-bgp.yml opnsense-unbound.yml opnsense-haproxy.yml'

# ---------------------------------------------------------------- guard: which box ----------
: "${OPN_TEST_HOST:?set OPN_TEST_HOST to the test VM WAN address (FU-297)}"
: "${OPN_TEST_VMID:?set OPN_TEST_VMID to the test VM vmid on nx-02 (FU-297)}"
SNAP="${OPN_TEST_SNAPSHOT:-baseline}"
VMNAME="${OPN_TEST_VM_NAME:-opnsense-test}"
PVE="${OPN_TEST_PVE:-192.168.2.59}"
PVE_KEY="${OPN_TEST_PVE_KEY:-$HOME/.claude/homelab-pve-ssh/id_ed25519}"
VM_KEY="${OPN_TEST_SSH_KEY:-$PVE_KEY}"
KEY_ENTRY="${OPN_TEST_KEY_ENTRY:-opnsense-test-api-key}"
SECRET_ENTRY="${OPN_TEST_SECRET_ENTRY:-opnsense-test-api-secret}"

echo "$OPN_TEST_HOST" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "OPN_TEST_HOST must be an IPv4 literal"
PROD_HOST="$(yq -r '.all.children.opnsense.hosts[].ansible_host' "$ROOT/ansible/inventory.yml")"
[ -n "$PROD_HOST" ] || die "could not read the prod router address from ansible/inventory.yml"
[ "$OPN_TEST_HOST" != "$PROD_HOST" ] && [ "$OPN_TEST_HOST" != 192.168.2.1 ] \
  || die "REFUSING: OPN_TEST_HOST=$OPN_TEST_HOST is the production router"
case "$KEY_ENTRY$SECRET_ENTRY" in *opnsense-api-key*|*opnsense-api-secret*)
  die "REFUSING: the test harness never reads the router's wallet entries" ;; esac

# ---------------------------------------------------------------- workdir + creds ------------
WORK="${OPN_TEST_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/opnsense-test-vm.XXXXXX")}"
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
LOG="$WORK/logs"; mkdir -p "$LOG"
REPORT="$WORK/report.md"; : > "$REPORT"
CURLCFG="$WORK/.curl-auth"
WORKTREES=''
cleanup() {
  rm -f "$CURLCFG"
  if [ "$KEEP" -eq 0 ]; then
    for wt in $WORKTREES; do git worktree remove --force "$wt" >/dev/null 2>&1 || true; done
  fi
}
trap cleanup EXIT

if [ -z "${OPN_TEST_API_KEY:-}" ] || [ -z "${OPN_TEST_API_SECRET:-}" ]; then
  _kp_db="$HOME/.claude/homelab-keepass/homelab.kdbx"
  [ -f "$_kp_db" ] || die "no wallet and no OPN_TEST_API_KEY/SECRET"
  _kp_get() { keepassxc-cli show -q --no-password -k "$HOME/.claude/homelab-keepass/homelab.keyx" \
                -a Password "$_kp_db" "$1" 2>/dev/null; }
  OPN_TEST_API_KEY="$(_kp_get "$KEY_ENTRY" || true)"
  OPN_TEST_API_SECRET="$(_kp_get "$SECRET_ENTRY" || true)"
fi
[ -n "$OPN_TEST_API_KEY" ] && [ -n "$OPN_TEST_API_SECRET" ] \
  || die "empty test-VM API creds (wallet entries $KEY_ENTRY / $SECRET_ENTRY missing?)"
# What group_vars' opnsense_conn reads — set to the TEST creds, for this process only.
export OPN_API_KEY="$OPN_TEST_API_KEY" OPN_API_SECRET="$OPN_TEST_API_SECRET"
export OPN_TEST_HOST OPN_TEST_GUARD=opnsense-test-vm
unset ACME_CF_TOKEN
( umask 077; printf 'user = "%s:%s"\n' "$OPN_TEST_API_KEY" "$OPN_TEST_API_SECRET" > "$CURLCFG" )

# ---------------------------------------------------------------- helpers --------------------
rep() { printf '%s\n' "$*" >> "$REPORT"; }
api() { # api GET|POST <path under /api/> [json]
  if [ -n "${3:-}" ]; then
    curl -sS -k -K "$CURLCFG" --max-time 60 -X "$1" -H 'Content-Type: application/json' \
      --data "$3" "https://$OPN_TEST_HOST/api/$2"
  else
    curl -sS -k -K "$CURLCFG" --max-time 60 -X "$1" "https://$OPN_TEST_HOST/api/$2"
  fi
}
api_first() { # GET the first endpoint spelling that answers JSON (snake_case vs camelCase)
  local p out
  for p in "$@"; do
    out="$(api GET "$p" 2>/dev/null || true)"
    if echo "$out" | jq -e 'type == "object" and (.rows != null or .status == null)' >/dev/null 2>&1; then
      printf '%s' "$out"; return 0
    fi
  done
  return 1
}
vm_ssh() { ssh -i "$VM_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
             -o UserKnownHostsFile="$WORK/known_hosts" "root@$OPN_TEST_HOST" "$@"; }
pve_ssh() { ssh -i "$PVE_KEY" -o BatchMode=yes -o ConnectTimeout=10 "root@$PVE" "$@"; }

# ---------------------------------------------------------------- refs -----------------------
if [ -n "$PR" ]; then
  meta="$(gh pr view "$PR" --json headRefOid,baseRefName,state,url)"
  HEAD_SHA="$(echo "$meta" | jq -r .headRefOid)"
  BASE_BRANCH="$(echo "$meta" | jq -r .baseRefName)"
  PR_URL="$(echo "$meta" | jq -r .url)"
  git fetch -q origin "$BASE_BRANCH" "pull/$PR/head"
  BASE_SHA="$(git rev-parse "origin/$BASE_BRANCH")"
  git cat-file -e "$HEAD_SHA^{commit}" || die "PR head $HEAD_SHA not fetched"
else
  # --ref: a revision already here (the box's checkout — whose fetches are authenticated by its
  # own loop, never an anonymous one from this script).
  [ "$NOFETCH" -eq 1 ] || git fetch -q origin
  BASE_SHA="$(git rev-parse --verify "$BASE_REF^{commit}")"
  HEAD_SHA="$(git rev-parse --verify "$HEAD_REF^{commit}")"
fi

declare -A WT COL PY CVER
prep_ref() { # prep_ref base|head <sha>
  local name="$1" sha="$2" wt="$WORK/$1" col="$WORK/$1-collections" want got
  if [ -d "$wt" ]; then git -C "$wt" checkout -q --detach "$sha"; else git worktree add -q --detach "$wt" "$sha"; fi
  WORKTREES="$WORKTREES $wt"
  # The guard must sit NEXT TO the plays: playbook-adjacent group_vars are where
  # opnsense_conn comes from, and the guard asserts the rendered value.
  cp "$GUARD_SRC" "$wt/ansible/zz-test-vm-guard.yml"
  # ANSIBLE_COLLECTIONS_PATH too: without it galaxy consults the DEFAULT path, finds the
  # prod wrapper's copy there, and installs nothing ("already installed").
  ANSIBLE_COLLECTIONS_PATH="$col" \
    ansible-galaxy collection install -r "$wt/ansible/collections/requirements.yml" -p "$col" \
    > "$LOG/$name-galaxy.log" 2>&1 || die "collection install for $name failed — $LOG/$name-galaxy.log"
  want="$(yq -r '.collections[] | select(.name == "oxlorg.opnsense") | .version' "$wt/ansible/collections/requirements.yml")"
  got="$(jq -r .collection_info.version "$col/ansible_collections/oxlorg/opnsense/MANIFEST.json")"
  [ "$want" = "$got" ] || die "$name: requirements pin $want but $col holds $got"
  WT[$name]="$wt"; COL[$name]="$col"; CVER[$name]="$got"
  PY[$name]="$(nix build --no-link --print-out-paths "path:$wt/ansible/controller-env")/bin/python3"
}

# ansible_on <roles-ref> <collection-ref> <play> [ansible-playbook args ...]
# The ONE ansible-playbook invocation of this script: the test inventory (never the prod one),
# --limit to the test host, the isolation overrides, then the caller's args (later -e wins).
ansible_on() {
  local wt="${WT[$1]}" cref="$2" play="$3"; shift 3
  env ANSIBLE_CONFIG="$wt/ansible/ansible.cfg" ANSIBLE_COLLECTIONS_PATH="${COL[$cref]}" \
      ANSIBLE_NOCOLOR=1 ANSIBLE_FORCE_COLOR=0 ANSIBLE_RETRY_FILES_ENABLED=0 \
    ansible-playbook -i "$INV" --limit opnsense-test-vm "$wt/ansible/$play" \
      -e "@$OVR" ${OPN_TEST_EXTRA_VARS:+-e "@$OPN_TEST_EXTRA_VARS"} "$@" -e "opnsense_prod_host=$PROD_HOST" \
      -e "ansible_python_interpreter=${PY[$cref]}"
}

# run_play <tag> <roles-ref> <collection-ref> <play> [extra-vars file ...]
# -> $LOG/<tag>.log, $LOG/<tag>.changed (task :: item lines), RC / CHANGED / FAILED globals
run_play() {
  local tag="$1" rref="$2" cref="$3" play="$4"; shift 4
  local ev=() f recap
  for f in "$@"; do ev+=(-e "@$f"); done
  _ansible() { ansible_on "$rref" "$cref" "$1" "${ev[@]}"; }
  _ansible zz-test-vm-guard.yml > "$LOG/$tag.guard.log" 2>&1 \
    || { cat "$LOG/$tag.guard.log" >&2; die "guard refused before $tag (see above)"; }
  set +e; _ansible "$play" > "$LOG/$tag.log" 2>&1; RC=$?; set -e
  awk '/^(TASK|RUNNING HANDLER) \[/ { t = $0; sub(/ \*+$/, "", t) }
       /^changed: / { print t " :: " $0 }' "$LOG/$tag.log" > "$LOG/$tag.changed"
  recap="$(grep -E '^opnsense-test-vm +:' "$LOG/$tag.log" | tail -1 || true)"
  CHANGED="$(echo "$recap" | sed -n 's/.*changed=\([0-9]*\).*/\1/p')"; CHANGED="${CHANGED:-?}"
  FAILED="$(echo "$recap" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"; FAILED="${FAILED:-?}"
  if grep -q 'Failed to translate' "$LOG/$tag.log"; then RC=97; fi
  echo "  $tag: rc=$RC changed=$CHANGED failed=$FAILED" >&2
  printf '| `%s` | %s | %s | %s | %s |\n' "$tag" "$rref roles / $cref collection (${CVER[$cref]})" \
    "$RC" "$CHANGED" "$FAILED" >> "$WORK/recaps.md"
}
recap_table() { # print the recap rows for tags matching $1
  rep '| run | code under test | rc | changed | failed |'
  rep '|---|---|---|---|---|'
  grep -F "\`$1" "$WORK/recaps.md" >> "$REPORT" || true
}
changed_list() { # the changed tasks of one tag, fenced
  if [ -s "$LOG/$1.changed" ]; then
    rep "<details><summary>\`$1\` changed tasks ($(wc -l < "$LOG/$1.changed"))</summary>"; rep ''
    rep '```'; cut -c1-220 "$LOG/$1.changed" >> "$REPORT"; rep '```'; rep '</details>'; rep ''
  fi
}
fail_tail() { rep '```'; tail -25 "$LOG/$1.log" | cut -c1-240 >> "$REPORT"; rep '```'; }

VERDICT=PASS
failstep() { VERDICT=FAIL; rep "**FAIL** — $*"; echo "FAIL: $*" >&2; }

# ---------------------------------------------------------------- step 1: rollback -----------
rollback() {
  local name st i code
  name="$(pve_ssh "qm config $OPN_TEST_VMID" | sed -n 's/^name: //p')"
  [ "$name" = "$VMNAME" ] || die "REFUSING rollback: vmid $OPN_TEST_VMID on $PVE is '$name', not '$VMNAME'"
  pve_ssh "qm listsnapshot $OPN_TEST_VMID" | grep -qw -- "$SNAP" || die "no snapshot '$SNAP' on vmid $OPN_TEST_VMID"
  pve_ssh "qm rollback $OPN_TEST_VMID $SNAP" >&2
  st="$(pve_ssh "qm status $OPN_TEST_VMID")"
  case "$st" in *running*) ;; *) pve_ssh "qm start $OPN_TEST_VMID" >&2 ;; esac
  for i in $(seq 1 120); do
    code="$(curl -sk -K "$CURLCFG" --max-time 5 -o /dev/null -w '%{http_code}' \
              "https://$OPN_TEST_HOST/api/diagnostics/system/system_information" || true)"
    [ "$code" = 200 ] && break
    [ "$code" = 401 ] || [ "$code" = 403 ] && die "API answers $code — the test creds do not belong to $OPN_TEST_HOST"
    sleep 5
  done
  [ "$code" = 200 ] || die "API not up 10 min after rollback (last HTTP $code)"
  for i in $(seq 1 24); do vm_ssh true 2>/dev/null && break; sleep 5; done
  vm_ssh true || die "no ssh root@$OPN_TEST_HOST after rollback"
  sleep 15   # configd + the plugin services settle after the API answers
}

fixture_names() { # every cert_domain the HAProxy role will look up, over both refs, + the mutations
  local r
  for r in base head; do
    yq -r '((.haproxy_proxied_services // []) + (.stack_gateways // []))[].cert_domain' \
      "${WT[$r]}/ansible/group_vars/opnsense.yml"
  done
  echo fu297-pos.teststuff.net; echo fu297-neg.teststuff.net
}

# The role's Let's Encrypt account, pre-created AND registered, so the VM matches prod's state.
# FU-298 (fresh-router defect #1). Why: oxlorg.opnsense's acme_account register() (identical in 25.7.8 and 26.1.11,
# plugins/module_utils/main/acme_account.py) POSTs `acmeclient/accounts/register` with NO uuid,
# while os-acme-client's AccountsController::registerAction($uuid) only routes register/<uuid>
# -> HTTP 404 on any account whose statusCode is not 200. Prod never reaches that call (its
# account registered long ago -> early return); a fresh box always does. A pre-existing upstream
# defect on BOTH refs, not a property of the change under test — so the fixture registers via
# the right route, and the report says so. This contacts Let's Encrypt (account only: no order,
# no DNS write). Per run, not baked into the snapshot: the baseline stays "fresh OPNsense + API
# key", and every piece of state the plays rely on is in git, here.
fixture_account() {
  local gv="${WT[base]}/ansible/group_vars/opnsense.yml" name email uuid out i st=''
  name="$(yq -r '.acme_account_name' "$gv")"; email="$(yq -r '.acme_account_email' "$gv")"
  uuid="$(api GET acmeclient/accounts/search | jq -r --arg n "$name" '.rows[]? | select(.name == $n) | .uuid' | head -1)"
  if [ -z "$uuid" ]; then  # the shape the role's acme_account task creates
    out="$(api POST acmeclient/accounts/add "$(jq -n --arg n "$name" --arg e "$email" \
      '{account: {enabled: "1", name: $n, email: $e, ca: "letsencrypt"}}')")"
    uuid="$(echo "$out" | jq -r '.uuid // empty')"; [ -n "$uuid" ] || die "fixture: accounts/add ($name) said: $out"
  fi
  st="$(api GET acmeclient/accounts/search | jq -r --arg u "$uuid" '.rows[]? | select(.uuid == $u) | .statusCode')"
  if [ "$st" != 200 ]; then
    out="$(api POST "acmeclient/accounts/register/$uuid" '{}')"
    echo "$out" | jq -e '.response != null' >/dev/null || die "fixture: accounts/register/$uuid said: $out"
    for i in $(seq 1 24); do
      st="$(api GET acmeclient/accounts/search | jq -r --arg u "$uuid" '.rows[]? | select(.uuid == $u) | .statusCode')"
      [ "$st" = 200 ] && break; sleep 5
    done
    [ "$st" = 200 ] || die "fixture: account '$name' not registered after 2 min (statusCode '$st')"
  fi
  echo "  fixture: account '$name' registered (statusCode 200)" >&2
}

fixture() {
  local refid acct val row n added=0 key crt out
  key="$WORK/fixture.key"; crt="$WORK/fixture.crt"
  # Pinned openssl, every algorithm explicit (no defaults to drift). Throwaway, never committed.
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -sha384 -nodes -days 30 \
    -subj "/CN=fu297-fixture.invalid" -keyout "$key" -out "$crt" >/dev/null 2>&1
  fixture_account
  refid="$(api GET trust/cert/search | jq -r '.rows[]? | select(.descr == "fu297-fixture") | .refid' | head -1)"
  if [ -z "$refid" ]; then
    out="$(api POST trust/cert/add "$(jq -n --rawfile c "$crt" --rawfile k "$key" \
      '{cert: {action: "import", descr: "fu297-fixture", crt_payload: $c, prv_payload: $k}}')")"
    echo "$out" | jq -e '.result == "saved"' >/dev/null || die "fixture: trust/cert/add said: $out"
    refid="$(api GET trust/cert/search | jq -r '.rows[]? | select(.descr == "fu297-fixture") | .refid' | head -1)"
  fi
  [ -n "$refid" ] || die "fixture: imported cert has no refid"
  acct="$(api GET acmeclient/accounts/search | jq -r '.rows[]? | select(.name == "fu297-fixture") | .uuid' | head -1)"
  if [ -z "$acct" ]; then  # add only — registering is a separate call this never makes
    out="$(api POST acmeclient/accounts/add \
      '{"account":{"enabled":"1","name":"fu297-fixture","email":"fu297-fixture@teststuff.net","ca":"letsencrypt"}}')"
    acct="$(echo "$out" | jq -r '.uuid // empty')"; [ -n "$acct" ] || die "fixture: accounts/add said: $out"
  fi
  val="$(api GET acmeclient/validations/search | jq -r '.rows[]? | select(.name == "fu297-fixture") | .uuid' | head -1)"
  if [ -z "$val" ]; then
    out="$(api POST acmeclient/validations/add \
      '{"validation":{"enabled":"1","name":"fu297-fixture","method":"dns01","dns_service":"dns_cf"}}')"
    val="$(echo "$out" | jq -r '.uuid // empty')"; [ -n "$val" ] || die "fixture: validations/add said: $out"
  fi
  for n in $(fixture_names | sort -u); do
    api GET acmeclient/certificates/search | jq -e --arg n "$n" '[.rows[]? | select(.name == $n)] | length > 0' \
      >/dev/null && continue
    row="$(jq -n --arg n "$n" --arg a "$acct" --arg v "$val" --arg r "$refid" \
      '{certificate: {enabled: "0", name: $n, description: $n, altNames: "", account: $a,
        validationMethod: $v, keyLength: "key_ec384", autoRenewal: "0", certRefId: $r}}')"
    out="$(api POST acmeclient/certificates/add "$row")"
    echo "$out" | jq -e '.result == "saved"' >/dev/null || die "fixture: certificates/add $n said: $out"
    added=$((added + 1))
  done
  # The HAProxy role reads certRefId off these rows; if the API dropped it, the frontends
  # would bind no certificate and the haproxy step would test nothing real. Stop instead.
  api GET acmeclient/certificates/search | jq -e --arg r "$refid" \
    '[.rows[] | select(.name | test("^fu297-(pos|neg)\\.")) | .certRefId == $r] | all and length == 2' >/dev/null \
    || die "fixture: the API did not keep certRefId on the ACME rows — the HAProxy step cannot run (FU-297)"
  echo "  fixture: cert $refid, $added ACME rows added" >&2
}

preflight() {
  local pk
  OPN_VERSION="$(vm_ssh 'opnsense-version' 2>/dev/null || echo '?')"
  pk="$(vm_ssh "pkg query '%n %v' os-frr os-haproxy os-acme-client" 2>/dev/null || true)"
  PLUGINS="$(echo "$pk" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  for n in os-frr os-haproxy os-acme-client; do
    echo "$pk" | grep -q "^$n " || die "plugin $n is not installed on the test VM (baseline incomplete)"
  done
}

# FU-298 (fresh-router defect #2): enabling BGP writes `bgpd` into /etc/rc.conf.d/frr, but the
# reload the plays trigger does not restart watchfrr, so on a FRESH box bgpd never starts and the
# running config holds no neighbours at all — on base and head alike (master reproduces it).
# Prod never meets it (bgpd has run for years). Called after the first bgp converge of a fresh
# box, so the step-4 FRR check tests the reload flag, not daemon startup. A REAL cycle, stop then
# start (docs/runbook.md: the quagga `restart` endpoint is a no-op).
FRR_CYCLED=0
frr_start_bgpd_if_absent() {
  local i
  vm_ssh 'pgrep -x bgpd' >/dev/null 2>&1 && return 0
  api POST quagga/service/stop '{}' >/dev/null; sleep 3
  api POST quagga/service/start '{}' >/dev/null
  for i in $(seq 1 20); do vm_ssh 'pgrep -x bgpd' >/dev/null 2>&1 && break; sleep 3; done
  vm_ssh 'pgrep -x bgpd' >/dev/null 2>&1 || die "FU-298: bgpd still not running after an FRR stop/start"
  FRR_CYCLED=$((FRR_CYCLED + 1))
  echo "  FU-298: bgpd was not running after the fresh bgp converge — FRR stopped + started" >&2
}

# A task in a tag's changed list? (for the base-rerun comparisons)
changed_in() { grep -qF -- "$1" "$LOG/$2.changed" 2>/dev/null; }

# ---------------------------------------------------------------- evidence (step 4) ----------
running_bgp() { vm_ssh "vtysh -c 'show running-config'" 2>/dev/null | grep -c "neighbor $1 " || true; }
saved_bgp() { api_first quagga/bgp/search_neighbor quagga/bgp/searchNeighbor | grep -c "\"$1\"" || true; }
running_dns() { vm_ssh "drill @127.0.0.1 $1 A" 2>/dev/null | grep -Ec "IN[[:space:]]+A[[:space:]]+$2\$" || true; }
saved_dns() { api_first unbound/settings/search_host_override unbound/settings/searchHostOverride \
                | jq --arg h "${1%%.*}" '[.rows[]? | select(.hostname == $h)] | length' || echo 0; }
running_vip() { vm_ssh 'ifconfig -a' 2>/dev/null | grep -c "inet $1 " || true; }
saved_vip() { api_first interfaces/vip_settings/search_item interfaces/vip_settings/searchItem | grep -c "\"$1\"" || true; }
listening() { vm_ssh 'sockstat -4l' 2>/dev/null | grep -c "$1:443" || true; }

mutation_vars() { # mutation_vars <roles-ref> <suffix pos|neg> <last octet> -> file
  local r="$1" s="$2" o="$3" f="$WORK/mutation-$2.yml" gv="${WT[$1]}/ansible/group_vars/opnsense.yml"
  yq -n "
    .bgp_node_ips = (load(\"$OVR\").bgp_node_ips + [\"192.0.2.$o\"]) |
    .unbound_hosts = ((load(\"$gv\").unbound_hosts // []) + [{\"hostname\": \"fu297-$s-unbound\",
       \"domain\": \"teststuff.net\", \"value\": \"192.0.2.$o\", \"description\": \"FU-297 test mutation\"}]) |
    .haproxy_proxied_services = ((load(\"$gv\").haproxy_proxied_services // []) + [{\"name\": \"fu297$s\",
       \"cert_domain\": \"fu297-$s.teststuff.net\", \"vip\": \"192.168.3.$o\",
       \"backend_ip\": \"192.0.2.$o\", \"backend_port\": 80}])" > "$f"
  echo "$f"
}
ev_row() { rep "| $1 | $2 | $3 | $4 |"; }

# ================================================================ run ========================
{
  echo "## OPNsense test-VM validation (FU-297)"
  echo
  [ -n "$PR" ] && echo "PR: $PR_URL"
  echo "- validated **head \`$HEAD_SHA\`** against **base \`$BASE_SHA\`**"
  echo "- test VM: vmid $OPN_TEST_VMID on $PVE, snapshot \`$SNAP\`, API $OPN_TEST_HOST — $(date -u +%FT%TZ)"
  echo "- harness: \`scripts/opnsense-test-vm.sh\` @ \`$(git rev-parse --short HEAD)\`, steps: $STEPS"
} >> "$REPORT"
: > "$WORK/recaps.md"

prep_ref base "$BASE_SHA"
prep_ref head "$HEAD_SHA"
rep "- collections: base \`oxlorg.opnsense ${CVER[base]}\`, head \`oxlorg.opnsense ${CVER[head]}\` (separate paths, never the shared default)"

has() { case " $STEPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Step "prep" (no VM needed): the guard + --syntax-check of every play, on both refs, and
# the mutation vars rendered — what can be proven before the VM exists.
if has prep; then
  echo "prep: guard + syntax-check, both refs" >&2
  rep ''; rep '### prep (no VM)'; rep ''
  for r in base head; do
    ansible_on "$r" "$r" zz-test-vm-guard.yml > "$LOG/prep-$r-guard.log" 2>&1 \
      || { cat "$LOG/prep-$r-guard.log" >&2; die "guard refused ($r)"; }
    for p in $PLAYS; do
      ansible_on "$r" "$r" "$p" --syntax-check > "$LOG/prep-$r-${p%.yml}.log" 2>&1 \
        || { failstep "$r \`$p\` --syntax-check"; fail_tail "prep-$r-${p%.yml}"; }
    done
  done
  yq -e '.bgp_node_ips | length == 4' "$(mutation_vars head pos 97)" >/dev/null || failstep 'mutation vars (pos)'
  yq -e '.haproxy_proxied_services[-1].name == "fu297neg"' "$(mutation_vars base neg 96)" >/dev/null || failstep 'mutation vars (neg)'
  rep "guard passed and all four plays syntax-check on both refs: $VERDICT"
fi

if has 1; then
  echo "step 1: rollback" >&2
  rollback; preflight; fixture
  rep "- OPNsense: \`$OPN_VERSION\`; plugins: $PLUGINS"
  rep ''; rep '### 1. Rollback to baseline'; rep ''
  rep "Rolled back to \`$SNAP\`, API + SSH up, fixture in place (one self-signed cert, disabled ACME rows bound to it)."
fi

if has 2; then
  echo "step 2: base converge" >&2
  rep ''; rep '### 2. Converge on BASE (prod today)'; rep ''
  for p in $PLAYS; do
    run_play "2-base-${p%.yml}" base base "$p"
    [ "$RC" -eq 0 ] || { failstep "base \`$p\` rc=$RC"; fail_tail "2-base-${p%.yml}"; }
    if [ "$p" = opnsense-bgp.yml ] && [ "$RC" -eq 0 ]; then frr_start_bgpd_if_absent; fi
  done
  recap_table '2-base-'
  # Base rerun = what is ALREADY non-idempotent on master. Later steps compare against it, so a
  # pre-existing flip is labelled pre-existing instead of being blamed on the change under test.
  for p in $PLAYS; do run_play "2-rerun-${p%.yml}" base base "$p"; done
  rep ''; rep 'Base rerun (the pre-existing non-idempotence baseline):'; rep ''
  recap_table '2-rerun-'
  rep ''
  for p in $PLAYS; do changed_list "2-rerun-${p%.yml}"; done
  [ "$VERDICT" = PASS ] || { rep ''; rep 'Base did not converge — later steps skipped.'; STEPS=''; }
fi

if has 3; then
  echo "step 3: head on top" >&2
  rep ''; rep '### 3. Apply HEAD on top of the converged base'; rep ''
  for p in $PLAYS; do
    run_play "3-head-${p%.yml}" head head "$p"
    [ "$RC" -eq 0 ] || { failstep "head \`$p\` rc=$RC (97 = API translation error)"; fail_tail "3-head-${p%.yml}"; }
  done
  recap_table '3-head-'
  rep ''
  for p in $PLAYS; do changed_list "3-head-${p%.yml}"; done
fi

if has 4; then
  echo "step 4: mutations reach the running daemons" >&2
  rep ''; rep '### 4. A mutation reaches the RUNNING service'; rep ''
  pos="$(mutation_vars head pos 97)"
  for p in opnsense-bgp.yml opnsense-unbound.yml opnsense-haproxy.yml; do
    run_play "4-pos-${p%.yml}" head head "$p" "$pos"
    [ "$RC" -eq 0 ] || { failstep "HEAD mutation run \`$p\` rc=$RC"; fail_tail "4-pos-${p%.yml}"; }
  done
  recap_table '4-pos-'
  rep ''; rep '| HEAD (roles + collection) | saved (API) | running (daemon) | pass |'; rep '|---|---|---|---|'
  a="$(saved_bgp 192.0.2.97)"; b="$(running_bgp 192.0.2.97)"
  ev_row 'FRR neighbour 192.0.2.97 (`vtysh show running-config`)' "$a" "$b" "$([ "$b" -ge 1 ] && echo yes || echo NO)"
  [ "$b" -ge 1 ] || failstep 'BGP neighbour saved but not in the running FRR config'
  a="$(saved_dns fu297-pos-unbound.teststuff.net)"; b="$(running_dns fu297-pos-unbound.teststuff.net 192.0.2.97)"
  ev_row 'Unbound override (unbound role; `drill @127.0.0.1`)' "$a" "$b" "$([ "$b" -ge 1 ] && echo yes || echo NO)"
  [ "$b" -ge 1 ] || failstep 'Unbound role override does not resolve on the running Unbound'
  a="$(saved_vip 192.168.3.97)"; b="$(running_vip 192.168.3.97)"
  ev_row 'IP-alias VIP 192.168.3.97 (haproxy role; `ifconfig`)' "$a" "$b" "$([ "$b" -ge 1 ] && echo yes || echo NO)"
  [ "$b" -ge 1 ] || failstep 'HAProxy VIP saved but not configured on the interface'
  b="$(listening 192.168.3.97)"
  ev_row 'HAProxy frontend on 192.168.3.97:443 (`sockstat -4l`)' '-' "$b" "$([ "$b" -ge 1 ] && echo yes || echo NO)"
  [ "$b" -ge 1 ] || failstep 'HAProxy is not listening on the new frontend'
  a="$(saved_dns fu297-pos.teststuff.net)"; b="$(running_dns fu297-pos.teststuff.net 192.168.3.97)"
  ev_row 'Unbound override (haproxy role, no handler; `drill`)' "$a" "$b" "$([ "$b" -ge 1 ] && echo yes || echo NO)"
  [ "$b" -ge 1 ] || failstep 'HAProxy-role Unbound override does not resolve on the running Unbound'
  rep ''
  rep 'The unbound role also notifies a `reconfigure unbound` handler, so its row passes with or without `reload` — the haproxy-role override (no handler) and the FRR neighbour are the rows that isolate the flag.'

  # Negative control: master's roles (no explicit reload) on the HEAD collection = #2033's regression.
  neg="$(mutation_vars base neg 96)"
  for p in opnsense-bgp.yml opnsense-haproxy.yml; do run_play "4-neg-${p%.yml}" base head "$p" "$neg"; done
  rep ''; rep 'Negative control — BASE roles on the HEAD collection (the regression shape; informational, a failing play here is expected-possible: HAProxy cannot bind a VIP that was never applied):'; rep ''
  recap_table '4-neg-'
  rep ''; rep '| BASE roles + HEAD collection | saved (API) | running (daemon) | regression reproduced |'; rep '|---|---|---|---|'
  a="$(saved_bgp 192.0.2.96)"; b="$(running_bgp 192.0.2.96)"
  ev_row 'FRR neighbour 192.0.2.96' "$a" "$b" "$([ "$a" -ge 1 ] && [ "$b" -eq 0 ] && echo yes || echo no)"
  a="$(saved_vip 192.168.3.96)"; b="$(running_vip 192.168.3.96)"
  ev_row 'IP-alias VIP 192.168.3.96' "$a" "$b" "$([ "$a" -ge 1 ] && [ "$b" -eq 0 ] && echo yes || echo no)"
  a="$(saved_dns fu297-neg.teststuff.net)"; b="$(running_dns fu297-neg.teststuff.net 192.168.3.96)"
  ev_row 'Unbound override (haproxy role)' "$a" "$b" "$([ "$a" -ge 1 ] && [ "$b" -eq 0 ] && echo yes || echo no)"
fi

if has 5; then
  echo "step 5: fresh converge + idempotence" >&2
  rep ''; rep '### 5. Fresh converge on HEAD + idempotent rerun'; rep ''
  rollback; fixture
  for p in $PLAYS; do
    run_play "5-run1-${p%.yml}" head head "$p"
    [ "$RC" -eq 0 ] || { failstep "fresh HEAD \`$p\` rc=$RC"; fail_tail "5-run1-${p%.yml}"; }
    if [ "$p" = opnsense-bgp.yml ] && [ "$RC" -eq 0 ]; then frr_start_bgpd_if_absent; fi
  done
  for p in $PLAYS; do
    run_play "5-run2-${p%.yml}" head head "$p"
    [ "$RC" -eq 0 ] || { failstep "HEAD rerun \`$p\` rc=$RC"; fail_tail "5-run2-${p%.yml}"; }
    if [ "$CHANGED" != 0 ]; then
      t="${p%.yml}"; new=0
      while IFS= read -r line; do
        changed_in "${line%% :: *}" "2-rerun-$t" || new=1
      done < "$LOG/5-run2-$t.changed"
      if [ "$new" -eq 1 ]; then failstep "HEAD rerun \`$p\` not idempotent (changed=$CHANGED)"
      else rep "- pre-existing: HEAD rerun \`$p\` changed=$CHANGED, every task also changes on the BASE rerun (not this change)"; fi
    fi
  done
  recap_table '5-run1-'
  rep ''; recap_table '5-run2-'
  rep ''
  for p in $PLAYS; do changed_list "5-run2-${p%.yml}"; done
fi

# Step all (the rebuild drill): every piece of router code once, at HEAD, onto the VM. The two
# python scripts dial OPN_HOST — pinned here to the guarded test address, never their default.
if has all; then
  echo "step all: converge every router-code unit at HEAD" >&2
  rep ''; rep '### all. Converge ALL router code at HEAD'; rep ''
  for p in $PLAYS opnsense-ddclient.yml opnsense-wireguard.yml; do
    if [ "$p" = opnsense-ddclient.yml ]; then export ACME_CF_TOKEN=fu297-drill-not-a-token; fi
    run_play "all-${p%.yml}" head head "$p"
    unset ACME_CF_TOKEN
    [ "$RC" -eq 0 ] || { failstep "\`$p\` rc=$RC"; fail_tail "all-${p%.yml}"; }
  done
  recap_table 'all-'
  for py in dnsmasq-dhcp tuya-egress; do
    set +e
    OPN_HOST="$OPN_TEST_HOST" python3 "${WT[head]}/opnsense/$py.py" > "$LOG/all-$py.log" 2>&1; RC=$?
    set -e
    rep "- \`opnsense/$py.py\`: rc=$RC"
    [ "$RC" -eq 0 ] || { failstep "\`opnsense/$py.py\` rc=$RC"; fail_tail "all-$py"; }
  done
fi

# Step 3 classification: a task that changed on HEAD-over-base AND again on the idempotent
# rerun re-writes every run (a field-mapping regression); one that changed only in step 3 is a
# one-time transition (the new collection writing a field the old one left alone, or the
# reload fix re-applying).
if has 3 && has 5; then
  rep ''; rep '### Step 3 changes, classified'; rep ''
  any=0
  for p in $PLAYS; do
    t="${p%.yml}"; [ -s "$LOG/3-head-$t.changed" ] || continue
    while IFS= read -r line; do
      any=1; task="${line%% :: *}"
      if changed_in "$task" "2-rerun-$t"; then
        rep "- pre-existing (also changes on the BASE rerun — not this change): \`$task\`"
      elif changed_in "$task" "5-run2-$t"; then
        rep "- MAPPING REGRESSION (changes on every HEAD run, not on base): \`$task\`"; VERDICT=FAIL
      else
        rep "- one-time transition (not on the rerun): \`$task\`"
      fi
    done < "$LOG/3-head-$t.changed"
  done
  [ "$any" -eq 1 ] || rep '- none: HEAD over the converged base changed nothing.'
fi

rep ''
rep '### Notes'
rep '- **FU-298, fresh-router defect 1, both refs** (not the change under test): `oxlorg.opnsense` `acme_account` `register()` POSTs `acmeclient/accounts/register` without the account uuid; os-acme-client only routes `register/<uuid>` → HTTP 404 on any unregistered account. Prod never reaches it (its account is registered, the module returns early); a fresh box cannot converge the acme play. The fixture pre-registers the account via `register/<uuid>` so the VM matches prod.'
if [ "$FRR_CYCLED" -gt 0 ]; then
  rep "- **FU-298, fresh-router defect 2, both refs**: after the first bgp converge bgpd was not running (the reload does not restart watchfrr, so the \`bgpd\` just written into rc.conf.d/frr never starts); the harness stopped + started FRR ($FRR_CYCLED×) so the step-4 FRR check tests the reload flag, not daemon startup."
fi
rep ''
rep '### Not validated here'
rep '- ACME issuance/signing, the Cloudflare DNS-01 validation repoint and the certs'"'"' restart actions (no specs, no `ACME_CF_TOKEN` on the VM). The acme play does converge general settings, the account and the actions; the fixture registers that account with Let'"'"'s Encrypt from the VM each run (account only — no order, no DNS write; LE allows 10 new accounts per IP per 3 h, a run uses 2).'
rep '- HAProxy against a real certificate or backend: the frontends bind a self-signed fixture cert; backends are unreachable addresses.'
rep '- BGP sessions: neighbours are RFC 5737 addresses, so FRR config is proven, not peering.'
rep '- ddclient / WireGuard plays and `opnsense/dnsmasq-dhcp.py` (out of scope for this harness).'
rep ''
rep "**Verdict: $VERDICT** at head \`$HEAD_SHA\`. Logs: \`$LOG\` (on the jail that ran it)."

echo "report: $REPORT" >&2
if [ "$POST" -eq 1 ]; then gh pr comment "$PR" --body-file "$REPORT" >&2; fi
if [ "$STATUS" -eq 1 ]; then
  st=success; [ "$VERDICT" = PASS ] || st=failure
  gh api -X POST "repos/{owner}/{repo}/statuses/$HEAD_SHA" -f state="$st" -f context=opnsense-test-vm \
    -f description="OPNsense test VM (FU-297): $VERDICT at ${HEAD_SHA:0:12}" >/dev/null \
    || echo "commit status NOT written — the token needs Commit statuses: write (the jail PAT gets 403, probed 2026-09-29); the PR comment names the sha" >&2
fi
[ "$VERDICT" = PASS ]
