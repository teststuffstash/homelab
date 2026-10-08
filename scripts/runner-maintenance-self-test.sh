#!/usr/bin/env bash
# Self-test for scripts/runner-maintenance.sh — no GitHub, no Prometheus, no box.
#
# A fake `curl` on PATH serves the org runner list (with label DELETE/POST mutating it) and the
# Prometheus `up` query from a state dir; stub mgmt-tf / maintenance-window / seat-window scripts
# stand in for the box and the window. The cases pin the failure semantics the verb exists for:
# an unread runner list is never "idle", a timeout restores the labels, a plan that replaces any VM
# but the drained one is refused before a window opens.
#
#   devbox run runner-maint-self-test
set -uo pipefail

ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SUT="$ROOT/scripts/runner-maintenance.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ok $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
mkdir -p "$TMP/bin" "$TMP/state"
export FAKE="$TMP/state"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# method/url/body out of the verb's curl argv; state in $FAKE.
m=GET url="" data="" q=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    -d) data="$2"; shift 2 ;;
    --data-urlencode) q="$2"; shift 2 ;;
    -H|--max-time|-o|-w) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */api/v1/query)
    echo "$q" >> "$FAKE/prom-queries"
    case "$(cat "$FAKE/prom" 2>/dev/null || echo 1)" in
      fail) exit 7 ;;
      none) printf '{"status":"success","data":{"result":[]}}\n' ;;
      *) printf '{"status":"success","data":{"result":[{"metric":{},"value":[0,"%s"]}]}}\n' "$(cat "$FAKE/prom")" ;;
    esac ;;
  */actions/runners\?*)
    n=$(( $(cat "$FAKE/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/reads"
    [ -f "$FAKE/gh-fail-after" ] && [ "$n" -gt "$(cat "$FAKE/gh-fail-after")" ] && exit 22
    b=$(cat "$FAKE/busy-reads" 2>/dev/null || echo 0)
    jq -c --argjson busy "$([ "$n" -le "$b" ] && echo true || echo false)" \
      '{total_count:(.|length), runners: map(if .name == "ci-runner-01" then .busy = $busy else . end)}' "$FAKE/runners.json" ;;
  */actions/runners/*/labels/*)
    [ "$m" = DELETE ] || exit 22
    [ -f "$FAKE/delete-fail" ] && exit 22
    rest="${url##*/actions/runners/}"; id="${rest%%/*}"; l="${rest##*/}"
    jq --argjson id "$id" --arg l "$l" 'map(if .id == $id then .labels |= map(select(.name != $l)) else . end)' \
      "$FAKE/runners.json" > "$FAKE/r.tmp" && mv "$FAKE/r.tmp" "$FAKE/runners.json"
    echo "DELETE $id $l" >> "$FAKE/writes"; printf '{}\n' ;;
  */actions/runners/*/labels)
    [ "$m" = POST ] || exit 22
    rest="${url##*/actions/runners/}"; id="${rest%%/*}"
    jq --argjson id "$id" --argjson add "$(jq -c '.labels' <<<"$data")" \
      'map(if .id == $id then .labels += ($add | map({name:., type:"custom"})) else . end)' \
      "$FAKE/runners.json" > "$FAKE/r.tmp" && mv "$FAKE/r.tmp" "$FAKE/runners.json"
    echo "POST $id $data" >> "$FAKE/writes"; printf '{}\n' ;;
  *) echo "fake curl: unexpected $m $url" >&2; exit 22 ;;
esac
EOF
chmod +x "$TMP/bin/curl"

# Stubs for the box + the window (the verb takes their paths from env).
cat > "$TMP/mgmt-tf" <<'EOF'
#!/usr/bin/env bash
echo "mgmt-tf $*" >> "$FAKE/calls"
case "$1" in
  summary) [ -f "$FAKE/summary" ] || exit 1; echo "noise from the box"; printf 'MGMT_SUMMARY %s\r\n' "$(cat "$FAKE/summary")" ;;
  apply)   [ "${MGMT_YES:-}" = 1 ] || exit 9
           rc="$(cat "$FAKE/apply-rc" 2>/dev/null || echo 0)"; [ "$rc" = 0 ] || exit "$rc"
           # The replacement VM re-registers both slots with the declared labels (config.sh --replace).
           jq 'map(if (.name | startswith("ci-runner")) then .labels = ([{name:"self-hosted",type:"read-only"}]
                 + (["proxmox-vm","k3d","integration"] | map({name:., type:"custom"}))) else . end)' \
             "$FAKE/runners.json" > "$FAKE/r.tmp" && mv "$FAKE/r.tmp" "$FAKE/runners.json" ;;
esac
EOF
cat > "$TMP/maint" <<'EOF'
#!/usr/bin/env bash
echo "maint $*" >> "$FAKE/calls"
case "$1" in
  open) printf '== baseline ==\n  maintenance-window slot: w-1 — pass --id\n' ;;
  snapshot) printf '{"at":"t"}\n' ;;
  compare) exit "$(cat "$FAKE/compare-rc" 2>/dev/null || echo 0)" ;;
  close) exit 0 ;;
esac
EOF
cat > "$TMP/seatwin" <<'EOF'
#!/usr/bin/env bash
if [ -f "$FAKE/live-window" ]; then echo "  w-9  seat  node=wk-01"; else echo "no live seat window"; fi
EOF
chmod +x "$TMP/mgmt-tf" "$TMP/maint" "$TMP/seatwin"
: > "$TMP/kubeconfig"

reset() {
  rm -f "$FAKE"/*
  # Two VMs, two slots each; the declared custom set is tofu/ci-runner.tf's default.
  jq -n '[ {id:62,name:"ci-runner-01"}, {id:2979,name:"ci-runner-01-2"}, {id:14905,name:"ci-runner-02"},
           {id:14906,name:"ci-runner-02-2"}, {id:19669,name:"homelab-ephemeral-runner-x"} ]
    | map(. + {status:"online", busy:false, labels:([{name:"self-hosted",type:"read-only"}]
        + (if (.name | startswith("ci-runner")) then [{name:"proxmox-vm",type:"custom"},{name:"k3d",type:"custom"},{name:"integration",type:"custom"}] else [] end))})' \
    > "$FAKE/runners.json"
  echo 1 > "$FAKE/prom"
}
labels_of() { jq -r --arg n "$1" '.[] | select(.name == $n) | [.labels[] | select(.type == "custom") | .name] | join(",")' "$FAKE/runners.json"; }
run_sut() { # <expected rc> <name> <args…>
  local want="$1" name="$2"; shift 2
  PATH="$TMP/bin:$PATH" GH_RUNNER_TOKEN=fake RUNNER_POLL=0 DRAIN_TIMEOUT="${DT:-30}" VERIFY_TIMEOUT=5 COMPARE_SETTLE=0 \
    MGMT_TF="$TMP/mgmt-tf" MAINT_WINDOW="$TMP/maint" SEAT_WINDOW="$TMP/seatwin" KUBECONFIG="$TMP/kubeconfig" \
    RUNNER_EVIDENCE_DIR="$TMP/evidence" PROM_URL=http://prom.invalid GH_API_URL=https://gh.invalid \
    bash "$SUT" "$@" > "$TMP/out" 2>&1
  local rc=$?
  if [ "$rc" = "$want" ]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc, want $want"; sed 's/^/      /' "$TMP/out"; fi
}

echo "== drain"
reset
run_sut 0 "drain idle" drain ci-runner-01
[ "$(labels_of ci-runner-01)" = "" ] && [ "$(labels_of ci-runner-01-2)" = "" ] && ok "both slots lost their labels" || bad "labels still on: $(labels_of ci-runner-01) / $(labels_of ci-runner-01-2)"
[ "$(labels_of ci-runner-02)" = "proxmox-vm,k3d,integration" ] && ok "the other VM untouched" || bad "ci-runner-02 touched: $(labels_of ci-runner-02)"
run_sut 0 "undrain" undrain ci-runner-01
[ "$(labels_of ci-runner-01-2)" = "proxmox-vm,k3d,integration" ] && ok "undrain restored the declared set" || bad "undrain left: $(labels_of ci-runner-01-2)"

reset; echo 3 > "$FAKE/busy-reads"
run_sut 0 "drain waits out a busy slot" drain ci-runner-01
[ "$(cat "$FAKE/reads")" -ge 5 ] && ok "polled past the busy reads + two idle reads ($(cat "$FAKE/reads"))" || bad "only $(cat "$FAKE/reads") reads"

reset; echo 1000000 > "$FAKE/busy-reads"
DT=0 run_sut 2 "drain timeout refuses" drain ci-runner-01
[ "$(labels_of ci-runner-01)" = "proxmox-vm,k3d,integration" ] && ok "timeout restored the labels" || bad "timeout left: $(labels_of ci-runner-01)"

reset; echo 0 > "$FAKE/gh-fail-after"
run_sut 2 "drain with an unreadable list refuses, touches nothing" drain ci-runner-01
[ ! -s "$FAKE/writes" ] && ok "no label written" || bad "writes: $(cat "$FAKE/writes")"

reset; echo 2 > "$FAKE/gh-fail-after"   # read 1 (pre-drain) + read 2 (first poll) answer; read 3 fails
run_sut 1 "unreadable mid-drain: never idle; restore cannot read either → failed after acting" drain ci-runner-01
grep -q 'UNREADABLE mid-drain' "$TMP/out" && ok "said why" || bad "no mid-drain message"

reset; touch "$FAKE/delete-fail"
run_sut 2 "a label write that fails refuses" drain ci-runner-01

reset
run_sut 64 "a Talos node is refused" drain wk-01

echo "== verify"
reset
run_sut 0 "verify pass" verify ci-runner-02
grep -q 'instance="192.168.2.66:9100"' "$FAKE/prom-queries" && ok "exporter queried at the machines.yaml ip" || bad "query: $(cat "$FAKE/prom-queries")"
reset; jq 'map(if .name == "ci-runner-02-2" then .status = "offline" else . end)' "$FAKE/runners.json" > "$FAKE/x" && mv "$FAKE/x" "$FAKE/runners.json"
run_sut 1 "verify fails on an offline slot" verify ci-runner-02
reset; jq 'map(select(.name != "ci-runner-02-2"))' "$FAKE/runners.json" > "$FAKE/x" && mv "$FAKE/x" "$FAKE/runners.json"
run_sut 1 "verify fails on a missing slot" verify ci-runner-02
reset; jq 'map(if .name == "ci-runner-02" then .labels |= map(select(.name != "k3d")) else . end)' "$FAKE/runners.json" > "$FAKE/x" && mv "$FAKE/x" "$FAKE/runners.json"
run_sut 1 "verify fails on a partial label set" verify ci-runner-02
reset; echo 0 > "$FAKE/prom"
run_sut 1 "verify fails on exporter up=0" verify ci-runner-02
reset; echo none > "$FAKE/prom"
run_sut 1 "verify fails on no up series" verify ci-runner-02
reset; echo fail > "$FAKE/prom"
run_sut 1 "verify fails on Prometheus unreadable" verify ci-runner-02
reset; echo 0 > "$FAKE/gh-fail-after"
run_sut 1 "verify fails on GitHub unreadable" verify ci-runner-02

echo "== run"
vmchange() { # <name> <actions-json> [address]
  jq -nc --arg n "$1" --argjson a "$2" --arg addr "${3:-proxmox_virtual_environment_vm.x[0]}" \
    '{type:"proxmox_virtual_environment_vm", address:$addr, name:$n, actions:$a}'
}
summary() { jq -nc --argjson c "$1" '{plan_id:"p", plan_ref:"origin/master", plan_sha:"abc", scoped:true, changes:$c}' > "$FAKE/summary"; }
file_change='{"type":"proxmox_virtual_environment_file","address":"proxmox_virtual_environment_file.ci_runner_02_cloud_init[0]","actions":["delete","create"]}'

reset; summary "[$(vmchange ci-runner-01 '["delete","create"]'), $file_change]"
run_sut 3 "run refuses a plan replacing the OTHER VM" run p ci-runner-02
grep -q 'not ci-runner-02' "$TMP/out" && ok "named the VM it found" || bad "no scope reason"
grep -q '^maint' "$FAKE/calls" 2>/dev/null && bad "a window was touched" || ok "no window opened"

reset; summary "[$(vmchange ci-runner-01 '["delete","create"]'), $(vmchange ci-runner-02 '["create","delete"]')]"
run_sut 3 "run refuses a plan replacing both VMs" run p ci-runner-02
reset; summary "[$(vmchange ci-runner-02 '["update"]')]"
run_sut 3 "run refuses an in-place update (not a replace)" run p ci-runner-02
reset; summary "[$file_change]"
run_sut 3 "run refuses a plan with no VM change" run p ci-runner-02
reset
run_sut 3 "run refuses an unreadable plan summary" run p ci-runner-02
reset; summary "[$(vmchange ci-runner-02 '["create","delete"]'), $file_change]"; touch "$FAKE/live-window"
run_sut 3 "run refuses inside another live window" run p ci-runner-02

reset; summary "[$(vmchange ci-runner-02 '["create","delete"]' 'proxmox_virtual_environment_vm.ci_runner_02[0]'), $file_change]"
run_sut 0 "run happy path" run p ci-runner-02
for step in "mgmt-tf summary p" "maint open" "maint snapshot" "mgmt-tf apply p" "maint compare" "maint close --id w-1"; do
  grep -qF -- "$step" "$FAKE/calls" || bad "run never did: $step"
done
[ "$(grep -n 'mgmt-tf summary' "$FAKE/calls" | cut -d: -f1)" -lt "$(grep -n 'maint open' "$FAKE/calls" | cut -d: -f1)" ] \
  && ok "plan scope read before the window opened" || bad "order: $(tr '\n' ';' < "$FAKE/calls")"
grep -q -- '--force' "$FAKE/calls" && bad "closed with --force on the happy path" || ok "closed without --force"

reset; summary "[$(vmchange ci-runner-02 '["create","delete"]')]"; echo 1 > "$FAKE/apply-rc"
run_sut 1 "run: apply failure leaves the window open" run p ci-runner-02
grep -q 'maint close' "$FAKE/calls" && bad "closed the window after a failed apply" || ok "window left open"

reset; summary "[$(vmchange ci-runner-02 '["create","delete"]')]"; echo 0 > "$FAKE/prom"
run_sut 1 "run: never verifies → window left open" run p ci-runner-02
grep -q 'maint close' "$FAKE/calls" && bad "closed the window on a failed verify" || ok "window left open"

reset; summary "[$(vmchange ci-runner-02 '["create","delete"]')]"; echo 2 > "$FAKE/compare-rc"
run_sut 1 "run: regressed health compare → window left open" run p ci-runner-02

reset; summary "[$(vmchange ci-runner-02 '["create","delete"]')]"; echo 0 > "$FAKE/gh-fail-after"
run_sut 2 "run: drain refusal closes its window, applies nothing" run p ci-runner-02
grep -q 'mgmt-tf apply' "$FAKE/calls" && bad "applied after a refused drain" || ok "nothing applied"
grep -q 'maint close --id w-1 --force' "$FAKE/calls" && ok "its own window closed" || bad "window not closed"

echo
if [ "$fails" -eq 0 ]; then echo "runner-maintenance self-test: all passed"; else echo "runner-maintenance self-test: $fails FAILED"; exit 1; fi
