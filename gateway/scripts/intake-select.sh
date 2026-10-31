#!/usr/bin/env bash
# intake-select — the deterministic half of the island intake sitting (gateway/intake.md).
#
# Lists the island's OPEN issues that nobody has ruled yet and says whether the sitting should
# fire: ≥ --min such issues, or the oldest ≥ --age-h hours. The judgment is the sitting's
# (an LLM over gateway/intake.md); this script only selects, exactly as coordinator-scan.sh
# selects units for the coordinator's clauses. bash + gh + jq + python3 (the ONE body parser,
# agents/issue_body.py — never a grep for Touches).
#
#   bash gateway/scripts/intake-select.sh [--island gateway] [--repo teststuffstash/homelab] [--min 3] [--age-h 24] [--json]
#
# A candidate is an open issue that
#   - belongs to the island (--island, default gateway; the table is island_members below): the
#     FIRST row of ISLANDS whose title regex matches, or under whose path prefixes every `Touches`
#     entry falls (each path goes to the island with the LONGEST matching prefix; a footprint that
#     spans two islands, or names an unowned path, belongs to none by Touches). So an issue maps
#     to at most one island, and the gateway row — first — selects exactly what it always did;
#   - carries NO `agent/*` lifecycle label and is not `task/goal` (a Goal is admitted by a human,
#     breaker #1), not a `post-launch:` / `stint:` container;
#   - has no standing intake ruling: no comment whose FIRST line starts with `intake:` — a ruled
#     item is either labelled (queue/seat), closed (close/fold) or standing (comment only), and
#     the standing ones are exactly the ones this predicate skips.
#
# Output: one line per candidate `<number>\t<age_h>\t<author>\t<title>`, then a verdict line
# `fire: <reason>` or `hold: <reason>` on stderr. Exit 0 = fire, 1 = hold, 2 = a probe failed
# (an empty answer from a failed read is NOT "no candidates" — jail-subagent-card, 2026-10-26).
# --json prints the candidate array instead of the lines (the verdict line still goes to stderr).
# Seam: INTAKE_ISSUES_JSON = a file holding the `gh issue list --json …` answer, served instead of
# the live read (agents/island-intake-test.sh drives membership through it).
#
# --source dig (FU-320, the first wired source — agents/coordinator/island-intake-argo.yaml runs it):
# the island's inputs are the deep dig's `cause-found` findings (docs/agents/roles.md §deep dig)
# whose text names the island, not yet ruled by an earlier APPLY sitting. They become the sitting's
# `text:` inputs (`source: dig`), so the dig itself files nothing and intake stays the island's one
# admission — dedup (step 2's `fold`) happens BEFORE anything is filed.
#
#   bash gateway/scripts/intake-select.sh --source dig [--island gateway] [--out sel.json]
#
#   inputs    = homelab/dig-<date>/<run>/finding-N.json over INTAKE_DIG_LOOKBACK_D days, verdict in
#               INTAKE_DIG_VERDICTS, text matching the island's pattern (island_pattern below)
#   ruled     = every input id an earlier APPLY receipt lists with an outcome other than `deferred`
#               (homelab/intake-<island>-<date>/<run>/receipt.json — the receipt is the ledger, the
#               way the dig's own findings are its re-dig key; the bucket is read with the READER key)
#   cap       = INTAKE_DAILY_MAX apply sittings per UTC day (the responder's daily-cap shape, counted
#               from the same receipts) — the lane's spend is a budget knob, not a code change
#   fire      = ≥ 1 unruled input and the cap not reached; else hold
# Exit 0 = fire, 1 = hold, 2 = a probe failed: an unreadable bucket is NEVER "no inputs" (it would
# also be "nothing ruled", i.e. the same findings fed again every day). Seam: INTAKE_TS_DIR = a local
# directory laid out like the bucket (<dir>/homelab/dig-…, <dir>/homelab/intake-…) served instead
# of S3 — gateway/scripts/intake-select-test.sh and a jail run use it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPO="teststuffstash/homelab"; MIN=3; AGE_H=24; JSON=0; SOURCE=issues; ISLAND=gateway; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2;;
    --island) ISLAND="$2"; shift 2;;
    --out)   OUT="$2"; shift 2;;
    --repo)  REPO="$2"; shift 2;;
    --min)   MIN="$2"; shift 2;;
    --age-h) AGE_H="$2"; shift 2;;
    --json)  JSON=1; shift;;
    -h|--help) sed -n '2,52p' "$0"; exit 0;;
    *) echo "intake-select: unknown arg $1" >&2; exit 2;;
  esac
done

# ── the island table ─────────────────────────────────────────────────────────────────────────────
# One row per island in island_pattern (dig text) AND island_members (issues); a new island adds
# both rows plus its §Island facts file (gateway/intake.md names where those live). ISLANDS is the
# PRECEDENCE order — most specific first, gateway first so its selection never moves: an item
# belongs to the first island that claims it, so it is never ruled by two sittings.
ISLANDS="gateway router-pair mgmt-box dependency-upgrades substrate agent-loop"

# island_pattern <island> → the ERE (jq test) a dig finding's text must match to be this island's.
island_pattern() {
  case "$1" in
    gateway)             printf '%s' 'gateway/|agent-gateway|GW-[A-Z]';;
    router-pair)         printf '%s' '[Oo][Pp][Nn][Ss]ense|CARP|RouterPair|RouterWan|Unbound|router-move|ansible/opnsense';;
    mgmt-box)            printf '%s' 'mgmt/|Mgmt[A-Z]|UpgradeLease|management box|mgmt-(tf|lease|reconcile|apply)';;
    dependency-upgrades) printf '%s' '[Rr]enovate|VersionSet|version-sets/|DependencyClass|lock-intake';;
    substrate)           printf '%s' '[Gg]arage|[Ll]onghorn|[Tt]alos|Cilium|CNPG|cnpg|etcd|ControlPlane|Disk[A-Z]|Nvme|Pve[A-Z]|SERVICES\.md';;
    agent-loop)          printf '%s' 'agents/|Agent[A-Z]|coordinat|reviewer-session|agent-session|openrouter-proxy|OpenRouter|RouterRun|RouterRotation|Subscription[A-Z]';;
    *) return 1;;
  esac
}

# island_members <island> → line 1: the title ERE (grep -iE); then one `Touches` path prefix per
# line (a plain string prefix; a trailing `/` makes it a directory). Prefixes come from each
# island's owning docs (docs/spikes/context-and-autonomy.md §C7) + CLAUDE.md §Repo layout; the
# facts files (docs/intake/<island>.md) explain them. argocd/resources/agent-gateway/ and
# .github/workflows/** are deliberately nobody's (the gateway row stays as built; workflows are
# operator-author — a seat surface on every island).
island_members() {
  case "$1" in
    gateway) printf '%s\n' '^gateway([:/ ]|$)|\bGW-[A-Z]' \
      gateway/;;
    router-pair) printf '%s\n' '^(opnsense|carp|router[- ]pair|router-move|haproxy|unbound|wireguard|dnsmasq)\b' \
      opnsense/ ansible/opnsense- ansible/roles/opnsense- ansible/group_vars/opnsense.yml ansible/router-nodes/ \
      ansible/test-vm/ ansible/pve-router-killswitch.yml ansible/roles/pve-router-killswitch/ \
      tofu/opnsense-router.tf tofu/opnsense-test.tf scripts/opnsense- docs/router-move.md docs/opnsense-test-vm.md \
      argocd/resources/opnsense-config-backup/ argocd/platform/opnsense-config-backup.yaml;;
    mgmt-box) printf '%s\n' '^(mgmt|management[- ]box|upgrade[- ]lease)\b' \
      mgmt/ docs/management-box.md argocd/resources/mgmt-metrics/ argocd/platform/mgmt-metrics.yaml \
      argocd/resources/upgrade-lease-reader/ argocd/resources/kube-prometheus-stack-lease/ \
      argocd/platform/kube-prometheus-stack-lease.yaml scripts/node-maintenance.sh scripts/maintenance-window.sh \
      scripts/controlplane-upgrade.sh scripts/host-maintenance.sh scripts/runner-maintenance;;
    dependency-upgrades) printf '%s\n' '^(renovate|dependenc(y|ies)|deps|version[- ]sets?|S9)\b' \
      .github/renovate-global.json docs/dependency-upgrades.md docs/dependency-classes.yaml docs/renovate.md \
      version-sets/ argocd/resources/version-sets/ scripts/renovate- scripts/lock-intake-lint scripts/dependency-coverage;;
    substrate) printf '%s\n' '^(garage|longhorn|talos|cilium|cnpg|postgres|etcd|control[- ]plane|matchbox|proxmox|pve|prometheus-rules-lint)\b' \
      tofu/ machines/ SERVICES.md docs/controlplane-ha.md docs/storage-ledger.md docs/garage.md docs/garage-bulk-migration.md \
      docs/longhorn-backup.md argocd/resources/garage- argocd/resources/longhorn- argocd/resources/talos-substrate/ \
      argocd/resources/postgres/ argocd/resources/pg-backup/ argocd/resources/node-fstrim/ argocd/resources/smartctl-exporter/ \
      argocd/resources/pve-metrics/ argocd/platform/garage argocd/platform/longhorn- argocd/platform/postgres.yaml \
      argocd/platform/cnpg-operator.yaml argocd/platform/pg-backup.yaml argocd/platform/node-fstrim.yaml \
      argocd/platform/pve-metrics.yaml scripts/garage- scripts/longhorn- scripts/pg-backup.sh scripts/prometheus-rules-lint.sh \
      ansible/garage-backup.yml ansible/roles/garage-backup/ ansible/group_vars/garage_backup.yml ansible/matchbox \
      ansible/roles/matchbox ansible/group_vars/matchbox.yml ansible/pve- ansible/roles/pve- ansible/group_vars/pve.yml \
      ansible/host_vars/;;
    agent-loop) printf '%s\n' '^(scan|coordinator|reviewer|ride|worker rides?|arbitrate|responder|deep dig|dig|fixer|fleet-strike|epic dispositions|agent-session|retro-batch|ci-red lane|model_drift_rows|ADR-103)\b|model scout' \
      agents/ docs/agents/ .agents/ tofu/github/ argocd/resources/openrouter-proxy/ argocd/resources/agentstack/ \
      argocd/platform/agent-coordinator.yaml argocd/platform/agent-fixer.yaml argocd/platform/agentstack.yaml \
      argocd/platform/openrouter-proxy.yaml argocd/platform/openrouter-operator.yaml;;
    *) return 1;;
  esac
}

# The table, flattened once per run (no fork per path): TRES[i] = row i's title ERE, in ISLANDS
# order; PFX[j]/PISL[j] = every prefix and its island.
TRES=(); PFX=(); PISL=(); _TBL=0
load_table() {
  [ "$_TBL" = 1 ] && return 0; _TBL=1
  local isl pre first
  for isl in $ISLANDS; do
    first=1
    while IFS= read -r pre; do
      if [ "$first" = 1 ]; then TRES+=("$pre"); first=0; continue; fi
      [ -n "$pre" ] && { PFX+=("$pre"); PISL+=("$isl"); }
    done < <(island_members "$isl")
  done
}

# island_of_path <path> → the island whose prefix is the LONGEST match (tofu/opnsense-router.tf is
# the router pair's though tofu/ is the substrate's; equal length → the earlier ISLANDS row);
# prints nothing when no island owns it.
island_of_path() {
  load_table
  local p="$1" j best="" blen=0
  for j in "${!PFX[@]}"; do
    case "$p" in "${PFX[$j]}"*) [ "${#PFX[$j]}" -gt "$blen" ] && { best="${PISL[$j]}"; blen="${#PFX[$j]}"; };; esac
  done
  printf '%s' "$best"
}

# island_of_issue <title> <touches> → the one island the issue belongs to (first ISLANDS row whose
# title regex matches or that owns every Touches entry), or nothing.
island_of_issue() {
  load_table
  local title="$1" touches="$2" tisl="" p pi i=0 isl
  if [ -n "$touches" ]; then
    for p in $(printf '%s' "$touches" | tr ',' ' '); do
      pi="$(island_of_path "$p")"
      if [ -z "$pi" ] || { [ -n "$tisl" ] && [ "$pi" != "$tisl" ]; }; then tisl=""; break; fi
      tisl="$pi"
    done
  fi
  for isl in $ISLANDS; do
    if [ "$tisl" = "$isl" ] || grep -qiE "${TRES[$i]}" <<< "$title"; then
      printf '%s' "$isl"; return 0
    fi
    i=$((i + 1))
  done
}

# ── --source dig ─────────────────────────────────────────────────────────────────────────────────
TS_BUCKET="${AGENT_TS_BUCKET:-agent-transcripts}"
TS_ENDPOINT="${AGENT_TS_ENDPOINT:-http://garage.garage.svc.cluster.local:3900}"
_s5() { AWS_ACCESS_KEY_ID="${AGENT_TS_READER_ID:-}" AWS_SECRET_ACCESS_KEY="${AGENT_TS_READER_SECRET:-}" AWS_REGION=garage \
          s5cmd --endpoint-url "$TS_ENDPOINT" "$@"; }
# <prefix under homelab/> <file glob> → one JSON object per line, each stamped with `_key` (the
# object's path under homelab/). Bucket rows are `<date> <time> <size> <key>`; the key column may be
# relative to the listed prefix or full, so the path is rebuilt from the `<run>/<file>` tail.
ts_read_objects() {
  local prefix="$1" glob="$2" f rel
  if [ -n "${INTAKE_TS_DIR:-}" ]; then
    for f in "$INTAKE_TS_DIR"/homelab/$prefix/*/$glob; do
      [ -f "$f" ] || continue
      rel="${f#"$INTAKE_TS_DIR"/homelab/}"
      jq -c --arg k "$rel" '. + {_key: $k}' "$f" 2>/dev/null || echo "intake-select: unparseable $rel — skipped" >&2
    done
    return 0
  fi
  # s5cmd answers a prefix with no objects with an ERROR + exit 1 — the NORMAL case here (today's
  # receipts before the first sitting, a day the dig did not run), so it must not trip `set -e`:
  # the positive control in cmd_dig already proved the bucket is readable. (2026-10-28: the first
  # in-cluster dry-run died here with exit 1, which the workflow then read as a hold.)
  local rows; rows="$(_s5 ls "s3://$TS_BUCKET/homelab/$prefix/*" 2>/dev/null || true)"
  printf '%s\n' "$rows" | awk 'NF {print $NF}' \
    | { grep -E "/${glob//\*/[^/]*}\$" || true; } | sed -E 's#^.*/([^/]+/[^/]+)$#\1#' | sort -u \
    | while read -r rel; do
        _s5 cat "s3://$TS_BUCKET/homelab/$prefix/$rel" 2>/dev/null \
          | jq -c --arg k "$prefix/$rel" '. + {_key: $k}' 2>/dev/null \
          || echo "intake-select: unreadable $prefix/$rel — skipped" >&2
      done
}
cmd_dig() {
  local pat now lookback verdicts dmax d k findings receipts sel n today sittings
  pat="$(island_pattern "$ISLAND")" || { echo "intake-select: no dig pattern for island '$ISLAND'" >&2; exit 2; }
  # Precedence (ISLANDS order): a finding an EARLIER island's pattern claims is that island's, never
  # this one's too — one finding, one sitting. `(?!)` (matches nothing) when this is the first row.
  local isl earlier='(?!)'
  for isl in $ISLANDS; do [ "$isl" = "$ISLAND" ] && break; earlier="$earlier|$(island_pattern "$isl")"; done
  now="${INTAKE_NOW:-$(date -u +%s)}"; lookback="${INTAKE_DIG_LOOKBACK_D:-7}"
  verdicts="${INTAKE_DIG_VERDICTS:-cause-found}"; dmax="${INTAKE_DAILY_MAX:-2}"
  # Positive control first (rule #6): a listing of the prefix that FAILS is not an empty prefix.
  if [ -n "${INTAKE_TS_DIR:-}" ]; then
    [ -d "$INTAKE_TS_DIR/homelab" ] || { echo "intake-select: INTAKE_TS_DIR has no homelab/ — probe failed" >&2; exit 2; }
  else
    [ -n "${AGENT_TS_READER_ID:-}" ] || { echo "intake-select: no bucket READER key — cannot read findings or receipts (fail-closed)" >&2; exit 2; }
    command -v s5cmd >/dev/null 2>&1 || { echo "intake-select: s5cmd missing" >&2; exit 2; }
    _s5 ls "s3://$TS_BUCKET/homelab/" >/dev/null 2>&1 || { echo "intake-select: bucket listing failed ($TS_ENDPOINT) — probe failed" >&2; exit 2; }
  fi
  findings=""; receipts=""
  for k in $(seq 0 "$lookback"); do
    d="$(date -u -d "@$(( now - k * 86400 ))" +%Y-%m-%d)"
    findings="${findings}$(ts_read_objects "dig-$d" 'finding-*.json')"$'\n'
    receipts="${receipts}$(ts_read_objects "intake-$ISLAND-$d" 'receipt.json')"$'\n'
  done
  today="$(date -u -d "@$now" +%Y-%m-%d)"
  sel="$(jq -n --arg pat "$pat" --arg earlier "$earlier" --arg verdicts "$verdicts" --arg island "$ISLAND" --arg today "$today" \
      --argjson dmax "$dmax" --arg ts "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" \
      --slurpfile f <(printf '%s' "$findings" | grep -v '^$' || true) \
      --slurpfile r <(printf '%s' "$receipts" | grep -v '^$' || true) '
    def fid: (._key | sub("\\.json$"; ""));
    ([ $r[] | select(.schema == "island-intake-receipt/v1" and .mode == "apply")
            | .ruled[]? | select(.outcome != "deferred") | .input ] | unique) as $ruled
    | ([ $r[] | select(.schema == "island-intake-receipt/v1" and .mode == "apply" and .session_ran == true
                       and ((.ts // "") | startswith($today))) ] | length) as $sittings
    | [ $f[] | select(.schema == "dig-finding/v1")
             | select(.verdict as $v | ($verdicts | split(",")) | index($v))
             | select(([.cause, .recommendation, (.evidence // []), (.related // []), .pr] | tostring)
                      | test($pat) and (test($earlier) | not))
             | {id: fid, run: (.run // ""), verdict, alerts: (.alerts // []), members: (.members // []),
                cause, recommendation, evidence: (.evidence // []), related: (.related // []), pr: (.pr // "")} ] as $match
    | [ $match[] | select(.id as $i | $ruled | index($i) | not) ] as $inputs
    | {schema: "island-intake-select/v1", island: $island, source: "dig", ts: $ts,
       counts: {matched: ($match | length), ruled: (($match | length) - ($inputs | length)), inputs: ($inputs | length)},
       sittings_today: $sittings, daily_max: $dmax, inputs: $inputs}')" \
    || { echo "intake-select: selection jq failed" >&2; exit 2; }
  [ -n "$OUT" ] && printf '%s\n' "$sel" > "$OUT" || printf '%s\n' "$sel"
  printf '%s' "$sel" | jq -r '.inputs[] | "\(.id)\t\(.verdict)\t\(.alerts | join(", ") | .[0:80])"' >&2
  n="$(printf '%s' "$sel" | jq '.counts.inputs')"; sittings="$(printf '%s' "$sel" | jq '.sittings_today')"
  if [ "$n" -eq 0 ]; then
    echo "hold: no unruled dig finding names island $ISLAND ($(printf '%s' "$sel" | jq -c .counts))" >&2; exit 1
  elif [ "$sittings" -ge "$dmax" ]; then
    echo "hold: daily cap — $sittings apply sitting(s) today (INTAKE_DAILY_MAX=$dmax); $n input(s) wait for tomorrow" >&2; exit 1
  fi
  echo "fire: $n unruled dig finding(s) for island $ISLAND" >&2; exit 0
}
case "$SOURCE" in
  issues) ;;
  dig) cmd_dig; exit $?;;
  *) echo "intake-select: unknown --source $SOURCE (issues|dig)" >&2; exit 2;;
esac

island_members "$ISLAND" >/dev/null || { echo "intake-select: no membership row for island '$ISLAND'" >&2; exit 2; }
PARSER="$ROOT/agents/issue_body.py"
[ -f "$PARSER" ] || { echo "intake-select: $PARSER missing (run from a homelab checkout)" >&2; exit 2; }

# One list call (REST, paginated by gh); the body rides it so membership needs no second read.
if [ -n "${INTAKE_ISSUES_JSON:-}" ]; then
  issues="$(cat "$INTAKE_ISSUES_JSON" 2>/dev/null)" || { echo "intake-select: INTAKE_ISSUES_JSON unreadable" >&2; exit 2; }
else
  issues="$(gh issue list --repo "$REPO" --state open --limit 500 \
    --json number,title,body,labels,createdAt,author,comments 2>/dev/null)" || {
    echo "intake-select: gh issue list failed for $REPO" >&2; exit 2; }
fi
[ -n "$issues" ] || { echo "intake-select: empty answer from gh issue list (not a verdict)" >&2; exit 2; }

now="$(date -u +%s)"
cands='[]'
count="$(printf '%s' "$issues" | jq 'length')"
i=0
while [ "$i" -lt "$count" ]; do
  row="$(printf '%s' "$issues" | jq -c ".[$i]")"; i=$((i + 1))
  num="$(printf '%s' "$row" | jq -r .number)"
  title="$(printf '%s' "$row" | jq -r .title)"
  # containers and lifecycle-labelled items are never candidates
  case "$title" in post-launch:*|stint:*) continue;; esac
  if printf '%s' "$row" | jq -e '[.labels[].name | select(startswith("agent/") or . == "task/goal")] | length > 0' >/dev/null; then
    continue
  fi
  # membership: the island table (island_of_issue — title, else every Touches entry, first row wins)
  touches="$(printf '%s' "$row" | jq -r '.body // ""' | python3 "$PARSER" get Touches --ref "${REPO}#${num}" 2>/dev/null || true)"
  [ "$(island_of_issue "$title" "$touches")" = "$ISLAND" ] || continue
  # a standing ruling: a comment whose first line starts with `intake:`
  if printf '%s' "$row" | jq -e '[.comments[]? | .body | split("\n")[0] | select(startswith("intake:"))] | length > 0' >/dev/null; then
    continue
  fi
  created="$(printf '%s' "$row" | jq -r .createdAt)"
  cts="$(date -u -d "$created" +%s 2>/dev/null || echo "$now")"
  age_h=$(( (now - cts) / 3600 ))
  cands="$(printf '%s' "$cands" | jq -c --argjson n "$num" --argjson a "$age_h" \
    --arg t "$title" --arg au "$(printf '%s' "$row" | jq -r '.author.login')" \
    '. + [{number: $n, age_h: $a, author: $au, title: $t}]')"
done

n="$(printf '%s' "$cands" | jq 'length')"
oldest="$(printf '%s' "$cands" | jq '[.[].age_h] | max // 0')"
if [ "$JSON" = 1 ]; then
  printf '%s\n' "$cands" | jq .
else
  printf '%s' "$cands" | jq -r '.[] | "\(.number)\t\(.age_h)h\t\(.author)\t\(.title)"'
fi
if [ "$n" -ge "$MIN" ]; then
  echo "fire: $n unruled $ISLAND issues (min $MIN)" >&2; exit 0
elif [ "$n" -gt 0 ] && [ "$oldest" -ge "$AGE_H" ]; then
  echo "fire: oldest unruled $ISLAND issue is ${oldest}h (≥ ${AGE_H}h)" >&2; exit 0
else
  echo "hold: $n unruled $ISLAND issues, oldest ${oldest}h" >&2; exit 1
fi
