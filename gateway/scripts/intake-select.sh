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
# ATTRIBUTION inputs (homelab#3094's shape): an issue that passes the two filters above, is claimed
# by NO island and is BOT-filed (the brief's §Hard limits test: not author type `User` — `is_bot`,
# an `app/<slug>` or `<login>[bot]` login) is selected by `--island $ATTRIBUTION_ISLAND` only, marked
# `kind: attribution` (members are `kind: member`). The loop's filers leave component attribution to
# intake, so that sitting names the owning island(s) first (gateway/intake.md outcome `split`). A
# human-filed unclaimed issue stays nobody's — the seat's `none` list.
#
# Output: one line per candidate `<number>\t<age_h>\t<author>\t<title>` (an attribution input adds
# a fifth column `attribution`), then a verdict line
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
#               INTAKE_DIG_VERDICTS, OWNED by the island (finding_owner below): one of its ALERTS is
#               defined in the island's alert-rule file (island_alert_rules), or — when no island's
#               rules define any of its alerts — an evidence/related entry cites a path under the
#               island's `Touches` prefixes. Free prose never decides: "…/pushgateway/…" and "the
#               gateway seat" selected homelab#3162 and #3166 into the gateway sitting (2026-11-11).
#               An island with no alert-rule row yet keeps its text pattern (island_pattern).
#   ruled     = every input id an earlier APPLY receipt lists with an outcome other than `deferred`
#               (homelab/intake-<island>-<date>/<run>/receipt.json — the receipt is the ledger, the
#               way the dig's own findings are its re-dig key; the bucket is read with the READER key)
#   cap       = INTAKE_DAILY_MAX apply sittings per UTC day (the responder's daily-cap shape, counted
#               from the same receipts) — the lane's spend is a budget knob, not a code change
#   fire      = ≥ 1 unruled input and the cap not reached; else hold
# Exit 0 = fire, 1 = hold, 2 = a probe failed: an unreadable bucket is NEVER "no inputs" (it would
# also be "nothing ruled", i.e. the same findings fed again every day). Seam: INTAKE_TS_DIR = a local
# directory laid out like the bucket (<dir>/homelab/dig-…, <dir>/homelab/intake-…) served instead
# of S3 — agents/island-intake-test.sh and a jail run use it.
#
# The same source also presents RECURRING report-only RESPONDER findings (FU-320; the responder
# files nothing for them and writes `finding.json` only — docs/agents/roles.md §responder CAPTURE),
# as `kind: responder` inputs beside the dig's:
#   finding   = homelab/alert-<fp>/responder-r<k>-<ts>/finding.json (`responder-finding/v1`) over the
#               same INTAKE_DIG_LOOKBACK_D days (the run dir's date), that filed NO issue (`issue` empty)
#               and carries a non-empty `remediation_would` — a triage that found something to do and
#               had nowhere to put it
#   owner     = finding_owner's step 1 (its `alertname` is defined in an island's alert-rule file), else
#               its SUBJECT is a ride of an issue of this repo — `workload:<ns>/agent-<repo>-issue-<n>-r<k>`,
#               the pod name agents/agent-session.sh gives a ride — and the island that issue belongs
#               to (island_of_issue: its title, else every Touches entry). A ride pod is the ride of
#               ONE issue by construction, so the issue's island is the subject's; nothing enumerated.
#               The issue is read through INTAKE_ISSUES_JSON when set (a missing number is then a
#               probe failure; a row `{number, _status: 404|410}` is a gone issue), else `gh api
#               repos/<repo>/issues/<n>` (state any). A GONE issue (HTTP 404/410: deleted, transferred)
#               owns nothing: its findings join no class, one loud line names it, and
#               counts.responder.skipped.ride_issue_gone counts them — one deleted issue never holds
#               the whole selection. Any OTHER failed read (auth, rate limit, network) is exit 2
#   class     = the island's findings sharing `alertname` + owning namespace (`workload:<ns>/…`; any
#               other subject is its own namespace), ONE input per class with ≥ INTAKE_RESPONDER_MIN
#               (default 3) members, id `responder/<alertname>/<namespace>`, listing every member —
#               a one-off triage never starts a sitting; folding members by cause is the sitting's job
#   ruled     = the dig's ledger, unchanged: an APPLY receipt of the lookback that lists the class id
#               with an outcome other than `deferred`. A class still recurring after its ruling ages
#               out re-presents — by then every member postdates the ruling (same window).
#
# --source pile (FU-320, the second wired source — the same CronWorkflow runs it after the dig):
# the island's issue pile, as ONE selection in the dig's shape (`island-intake-select/v1`).
#
#   bash gateway/scripts/intake-select.sh --source pile [--island gateway] [--out sel.json]
#
#   member    = the default selection above (unruled, unlabelled) — `kind: member|attribution`.
#               An issue whose LATEST `intake:` ruling is `forward` counts as unruled (another
#               island's sitting passed it on and retitled it — gateway/intake.md step 0); its row
#               carries `forwards` = how many `intake: forward` comments it has (the hop cap's count).
#   reread    = `kind: reread`: the island's OPEN issues an earlier ruling left waiting on a human —
#               label `agent/blocked`, or the LATEST `intake:` ruling is `seat` — whose wait is
#               ≥ INTAKE_REREAD_AGE_D days old (default 3; the wait's date = the latest `intake:` /
#               `blocked-on:` comment, else the issue's last update), MINUS every one an APPLY
#               receipt of the last INTAKE_REREAD_EVERY_D days (default 7) lists with an outcome
#               other than `deferred`: an unchanged wait is not re-read daily, and the receipt is
#               the ledger of that (the dig source's pattern) — unless a target the comment that dates
#               the wait names (`#<n>`, `blocked-on: issue|pr=<n>`) closed or merged AFTER that receipt:
#               the row then re-presents carrying `stale` (ref_states, read only for hidden waits that
#               name one; seam INTAKE_REFS_JSON). Never a Goal or a container; an
#               issue carrying any OTHER `agent/*` label is the loop's, not a wait — UNLESS its
#               OPEN PR is parked on a human: the newest `blocked-on:` marker among that PR's
#               comments is `blocked-on: human` (a ruling of the PR lanes, written where the
#               issue's labels never show it). That issue is a reread too, `wait: pr-hold`, with
#               `pr` = the PR's number and the wait's date = the marker comment's. PR ↔ issue is
#               the escape source's link (closing reference, head branch `…issue-<n>…`, a
#               `Fixes/Closes/Resolves #<n>` body line). Only under INTAKE_PR_HOLDS=1 (default
#               off — no PR list is read without it).
#   id        = `<owner/repo>#<n>` — what the receipt's `ruled` lines carry
#   cap, fire = the dig's: ≥ 1 input and fewer than INTAKE_DAILY_MAX apply sittings today
# Exit codes as above (2 = the issue list, the open-PR list or the bucket could not be read). Seams:
# INTAKE_ISSUES_JSON + INTAKE_PRS_JSON (the open PRs, comments included) + INTAKE_TS_DIR + INTAKE_NOW.
#
# --source gaps (FU-320, night run 2026-11-14): the island's OWN incompleteness — the `⚑ gap` /
# `🚧 WIP` requirement rows of its specs index (`<specs root>/README.md`, the root from
# island_specs_root below), as `kind: gap` inputs (gateway/intake.md §Inputs `gap:`).
#
#   bash gateway/scripts/intake-select.sh --source gaps [--island gateway] [--out sel.json]
#
#   row       = an index table row whose first cell is `[<REQ-ID>](<page>#…)` and that carries `⚑ gap`
#               or `🚧`; id = `<specs page>#<REQ-ID>` (gateway/intake.md §Inputs `gap:`)
#   minus     = every id an APPLY receipt of the last INTAKE_GAP_LOOKBACK_D days (default 30) lists
#               with an outcome other than `deferred` (the dig's ledger), and every row an OPEN issue
#               already names (its title or body names the REQ-ID, or the row's own `#<n>` is open)
#   cap       = the first INTAKE_GAP_MAX (default 6) rows in index order; the rest re-present
#               tomorrow (no receipt line) — plus the daily INTAKE_DAILY_MAX, as every source
# An island with no specs root is a valid empty selection (exit 1); a DECLARED root whose index is
# unreadable is a probe failure (exit 2). Seams: INTAKE_ISSUES_JSON + INTAKE_TS_DIR + INTAKE_NOW.
#
# --source escape (FU-320, the island's improvement loop): the PRs of work this island QUEUED that
# drew a CHANGES_REQUESTED review — read later by the same sitting (gateway/intake-escape.md), one
# record per blocking finding, `kind: escape`.
#
#   bash gateway/scripts/intake-select.sh --source escape [--island gateway] [--out sel.json]
#
#   queued    = every issue id (`<owner/repo>#<n>`, the input or a ref) of a `queue`/`goal`/`requeue`
#               line in an APPLY receipt of this island's last INTAKE_ESCAPE_LOOKBACK_D days (default 30)
#               — an input's line (`ruled`) or an issue the sitting filed and ruled (`ruled_filed`)
#   PR        = OPEN or MERGED, created inside that window, linked to a queued issue (its closing
#               references, a head branch `…issue-<n>…`, or a `Fixes/Closes/Resolves #<n>` line in its
#               body), with at least one CHANGES_REQUESTED review; id = `<owner/repo>#<pr>`
#   minus     = every PR id an APPLY receipt of the same window lists (outcome ≠ deferred): read once
#   prior     = the `escapes` records of those receipts — the prompt's `escape-prior:` (step E counts a
#               class sighted on two inputs across sittings)
# Nothing queued → a valid empty selection and NO PR read. Exit codes as above (2 = the bucket or
# the PR list could not be read). Seams: INTAKE_PRS_JSON (the `gh pr list --json …` answer) +
# INTAKE_TS_DIR + INTAKE_NOW.
#
# --source wait (FU-320, the island's other improvement loop): the island's WAITS to classify —
# read later by the same sitting (gateway/intake-wait.md), one record per parking comment, `kind: wait`.
#
#   bash gateway/scripts/intake-select.sh --source wait [--island gateway] [--out sel.json]
#
#   item      = an issue of the island (island_of_issue), OPEN, or CLOSED inside the lookback — ONE batched
#               GraphQL read (comments + label/close timeline, author types: a Bot is a bot, whatever its login)
#   parking   = a comment whose newest `blocked-on:` marker is `human` (the scan's ONE grammar, BLOCKED_ON_DEF),
#               or an `intake: seat` with no marker. writer = `intake` (first line `intake:`, whoever's login —
#               the operator's login is the operator, no marker tells a seat session apart), else `lane` (a
#               bot: a ride's stop, a reviewer), else `human`. Only `intake` waits count toward the island's tally
#   release   = the first event after the parking comment of: a comment whose `intake:` outcome is not `seat`
#               or whose marker moved off `human` (`issue=` / `pr=`); `agent/blocked` removed by a non-bot;
#               the item closed. release = `operator` (a non-bot login), `reread` (the bot's `intake:`
#               comment), `lane` (any other bot). A later parking before it is a second parking, not a release
#   released  = every parking comment released inside INTAKE_WAIT_LOOKBACK_D (default 30) — the labelled examples
#   standing  = an OPEN item's newest parking, unreleased, older than INTAKE_WAIT_STANDING_D (default
#               INTAKE_REREAD_AGE_D, 3) days, that an APPLY receipt after it ruled `unchanged` at least once;
#               and an `agent/blocked` item with NO parking comment (dated by the label event; no receipt needed)
#   id        = `<owner/repo>#<n>@<parked_at>/<released|standing>` — a standing wait read once re-presents
#               when it is released
#   minus     = every wait id an APPLY receipt of the lookback lists (outcome ≠ deferred): read once
#   cap       = INTAKE_WAIT_MAX (default 6) per sitting: released first (oldest release first), then standing
#   prior     = the `waits` records of those receipts — the ledger's input (gateway/scripts/intake-wait-ledger.py)
#   stale     = NOT waits to classify: OPEN items whose newest marker names `issue=<n>` / `pr=<n>` that is
#               closed or merged, or whose unreleased human parking names `#<n>` that closed or merged AFTER it —
#               rows `kind: reread` (id `<owner/repo>#<n>`, the pile's) carrying `stale`, which the sitting
#               re-reads at once (step R), whatever the age floor; minus an APPLY receipt that listed the id
#               AFTER the target closed. Target states: ONE batched GraphQL read (ref_states).
# Exit codes as above (2 = the issue read, the target read or the bucket failed). Seams: INTAKE_ISSUES_JSON
# (the normalized item array: comments[].author.is_bot, events[]) + INTAKE_REFS_JSON ({"<n>": {state,
# closed_at}}) + INTAKE_TS_DIR + INTAKE_NOW. The pile's re-read ledger uses the same target read: a receipt
# that ruled a wait `unchanged` BEFORE a target its parking names closed does not hide it.
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
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0;;
    *) echo "intake-select: unknown arg $1" >&2; exit 2;;
  esac
done

# ── the island table ─────────────────────────────────────────────────────────────────────────────
# One row per island in island_pattern / island_alert_rules (dig findings) AND island_members
# (issues); a new island adds its rows plus its §Island facts file (gateway/intake.md names where those live). ISLANDS is the
# PRECEDENCE order — most specific first, gateway first so its selection never moves: an item
# belongs to the first island that claims it, so it is never ruled by two sittings.
# scan / launch / retro (night run 2026-11-14) sit right after the gateway: their title row
# (`<island> island:`) is narrower than agent-loop's `^scan` and their prefix (`islands/<island>/`)
# is nobody else's, so placing them before agent-loop moves no existing selection and keeps a
# "scan island: …" title off the agent-loop sitting.
ISLANDS="gateway scan launch retro router-pair mgmt-box dependency-upgrades substrate agent-loop"
# The island whose sitting receives the bot-filed issues no island claims (header: ATTRIBUTION
# inputs) — the loop's own filings, so the loop's island owns their first ruling.
ATTRIBUTION_ISLAND=agent-loop

# island_alert_rules <island> → the rule file(s), repo-relative, whose `alert:` names are the
# island's: a dig finding on one of them is the island's finding. Read from the checkout, so a new
# alert in the file needs no edit here. An island with no row falls back to island_pattern.
island_alert_rules() {
  case "$1" in
    gateway) printf '%s' 'argocd/resources/agent-gateway/prometheusrule.yaml';;
    *) ;;
  esac
}

# island_pattern <island> → the ERE (jq test) a dig finding's TEXT must match to be this island's —
# the fallback for an island with no island_alert_rules row (none of these has a wired sitting yet).
# The gateway has that row, so its findings are matched on alerts and evidence paths, never on text.
island_pattern() {
  case "$1" in
    gateway)             printf '%s' '(?!)';;
    scan|launch|retro)   printf '%s' "islands/$1/";;   # new islands: no alerts yet; a finding citing their tree
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
    scan|launch|retro) printf '%s\n' "^$1 island:" "islands/$1/";;   # islands/README.md (provisional home)
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

# island_specs_root <island> → the island's specs root, repo-relative (its index is <root>/README.md);
# nothing for an island without specs (--source gaps then selects nothing).
island_specs_root() {
  case "$1" in
    gateway) printf '%s' 'gateway/specs';;
    scan|launch|retro) printf '%s' "islands/$1/specs";;
    *) ;;
  esac
}

# The table, flattened once per run (no fork per path): TRES[i] = row i's title ERE, in ISLANDS
# order; PFX[j]/PISL[j] = every prefix and its island.
TRES=(); PFX=(); PISL=(); _TBL=0
declare -A TMATCH=()   # the title rows per item (island_of_issue); filled by the pile walk and ride_islands
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

# island_of_issue <title> <touches> <index> → the one island the issue belongs to (first ISLANDS row
# whose title regex matches or that owns every Touches entry), or nothing. The title rows are read
# from TMATCH (the walk's one grep per island over every title); a multi-line title greps its own.
island_of_issue() {
  load_table
  local title="$1" touches="$2" ix="$3" tisl="" p pi i=0 isl
  if [ -n "$touches" ]; then
    # shellcheck disable=SC2086  # word-split on the commas' spaces, as the entries always were
    for p in ${touches//,/ }; do
      pi="$(island_of_path "$p")"
      if [ -z "$pi" ] || { [ -n "$tisl" ] && [ "$pi" != "$tisl" ]; }; then tisl=""; break; fi
      tisl="$pi"
    done
  fi
  for isl in $ISLANDS; do
    if [ "$tisl" = "$isl" ] || [ -n "${TMATCH["$isl:$ix"]:-}" ] \
       || { case "$title" in *$'\n'*) grep -qiE "${TRES[$i]}" <<< "$title";; *) false;; esac; }; then
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
# Positive control (rule #6): a listing of the bucket that FAILS is not an empty bucket.
ts_probe() {
  if [ -n "${INTAKE_TS_DIR:-}" ]; then
    [ -d "$INTAKE_TS_DIR/homelab" ] || { echo "intake-select: INTAKE_TS_DIR has no homelab/ — probe failed" >&2; exit 2; }
  else
    [ -n "${AGENT_TS_READER_ID:-}" ] || { echo "intake-select: no bucket READER key — cannot read findings or receipts (fail-closed)" >&2; exit 2; }
    command -v s5cmd >/dev/null 2>&1 || { echo "intake-select: s5cmd missing" >&2; exit 2; }
    _s5 ls "s3://$TS_BUCKET/homelab/" >/dev/null 2>&1 || { echo "intake-select: bucket listing failed ($TS_ENDPOINT) — probe failed" >&2; exit 2; }
  fi
}
# <now> <days> → the island's receipts of today and the <days> days before it, one JSON per line.
read_receipts() {
  local k d
  for k in $(seq 0 "$2"); do
    d="$(date -u -d "@$(( $1 - k * 86400 ))" +%Y-%m-%d)"
    ts_read_objects "intake-$ISLAND-$d" 'receipt.json'
  done
}
# responder_day <rel> → the YYYYMMDD of a responder run dir (`…/responder-r<k>-<YYYYMMDD>T…Z/…`), or nothing.
responder_day() { if [[ "$1" =~ /responder-r[0-9]+-([0-9]{8})T ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi; }
# <now> <days> → the responder findings of today and the <days> days before it (by the run dir's
# date), one JSON per line stamped with `_key` (the path under homelab/). ONE listing covers every
# fingerprint; a run outside the window is never fetched.
read_responder() {
  local cut top f rel d rows
  cut="$(date -u -d "@$(( $1 - $2 * 86400 ))" +%Y%m%d)"; top="$(date -u -d "@$1" +%Y%m%d)"
  if [ -n "${INTAKE_TS_DIR:-}" ]; then
    for f in "$INTAKE_TS_DIR"/homelab/alert-*/responder-*/finding.json; do
      [ -f "$f" ] || continue
      rel="${f#"$INTAKE_TS_DIR"/homelab/}"; d="$(responder_day "$rel")"
      [ -n "$d" ] && [ "$d" -ge "$cut" ] && [ "$d" -le "$top" ] || continue
      jq -c --arg k "$rel" '. + {_key: $k}' "$f" 2>/dev/null || echo "intake-select: unparseable $rel — skipped" >&2
    done
    return 0
  fi
  # no match is s5cmd's ERROR + exit 1, the normal case on a quiet week (ts_read_objects' note)
  rows="$(_s5 ls "s3://$TS_BUCKET/homelab/alert-*/responder-*/finding.json" 2>/dev/null || true)"
  printf '%s\n' "$rows" | { grep -oE 'alert-[^/ ]+/responder-[^/ ]+/finding\.json$' || true; } | sort -u \
    | while read -r rel; do
        d="$(responder_day "$rel")"
        [ -n "$d" ] && [ "$d" -ge "$cut" ] && [ "$d" -le "$top" ] || continue
        _s5 cat "s3://$TS_BUCKET/homelab/$rel" 2>/dev/null | jq -c --arg k "$rel" '. + {_key: $k}' 2>/dev/null \
          || echo "intake-select: unreadable $rel — skipped" >&2
      done
}
# ride_islands <issue numbers…> → a JSON object {"<n>": "<island>" | "" | "!gone"}: the island each
# ride's issue belongs to (island_of_issue over its title + Touches, the pile's membership). Read
# through INTAKE_ISSUES_JSON when set, else `gh api repos/<repo>/issues/<n>` (any state: a finished
# ride's issue may be closed). A gone issue (HTTP 404/410; seam row `_status`) is `!gone` with one
# loud line — it owns nothing. Return 1 on any other failed read — an unread issue is not "nobody's".
ride_islands() {
  local n row title touches isl out='{}' t i err st
  load_table
  for n in "$@"; do
    st=""
    if [ -n "${INTAKE_ISSUES_JSON:-}" ]; then
      row="$(jq -c --argjson n "$n" '[.[] | select(.number == $n)] | first // empty' "$INTAKE_ISSUES_JSON" 2>/dev/null)" || row=""
      st="$(jq -r '._status // empty' <<< "${row:-null}" 2>/dev/null)" || st=""
    else
      err="$(mktemp)"
      row="$(gh api "repos/$REPO/issues/$n" 2>"$err")" || {
        row=""; st="$(grep -oE 'HTTP (404|410)' "$err" | head -1 | sed 's/HTTP //')" || st=""
        [ -n "$st" ] || sed 's/^/intake-select: gh: /' "$err" >&2; }
      rm -f "$err"
    fi
    case "$st" in
      404|410) echo "⚠ intake-select: issue #$n (a responder finding's ride) is GONE (HTTP $st) — its findings join no class, counted as skipped" >&2
               out="$(jq -c --arg n "$n" '. + {($n): "!gone"}' <<< "$out")"; continue;;
    esac
    [ -n "$row" ] || { echo "intake-select: issue #$n (a responder finding's ride) unreadable — cannot tell whose finding it is" >&2; return 1; }
    title="$(jq -r '.title // ""' <<< "$row")"
    touches="$(jq -r '.body // ""' <<< "$row" | python3 -I "$ROOT/agents/issue_body.py" get Touches 2>/dev/null || true)"
    # island_of_issue reads the title rows from TMATCH (the pile's one grep per island); fill row `ride`
    i=0; for t in $ISLANDS; do
      if grep -qiE "${TRES[$i]}" <<< "$title"; then TMATCH["$t:ride"]=1; else TMATCH["$t:ride"]=""; fi
      i=$((i + 1))
    done
    isl="$(island_of_issue "$title" "$touches" ride)"
    out="$(jq -c --arg n "$n" --arg i "$isl" '. + {($n): $i}' <<< "$out")"
  done
  printf '%s' "$out"
}
# The jq the responder half of --source dig shares between its two passes:
#   rf_live         a report-only finding with something to do (filed no issue, `remediation_would` non-empty)
#   rf_ns           its owning namespace (`workload:<ns>/…`, else the whole subject)
#   rf_ride($repo)  the issue number of a ride subject of <repo> (agent-<repo>-issue-<n>-r<k>), else empty
#   rule_owner($t)  the first island whose alert rules define its alertname (finding_owner's step 1)
# shellcheck disable=SC2016  # a jq program, not a shell expansion
JQ_RESPONDER='def esc: gsub("(?<c>[.\\[\\](){}*+?^$|\\\\])"; "\\\(.c)");
  def rf_live: select(.schema == "responder-finding/v1" and ((.issue // "") == "")
    and ((.remediation_would // []) | type == "array" and length > 0));
  def rf_ns: (.subject // "") as $s | (($s | capture("^workload:(?<ns>[^/]+)/") | .ns) // $s);
  def rf_ride($repo): (.subject // "") | capture("^workload:[^/]+/agent-" + ($repo | esc) + "-issue-(?<n>[0-9]+)-r[0-9]+$") | .n;
  def rule_owner($tbl): (.alertname // "") as $a | ([ $tbl[] | select(.alerts | index($a)) | .island ] | first);'

# The jq every receipt-reading source shares — one definition each of:
#   applied($r)       the APPLY receipts (dry-runs rule nothing)
#   sittings($r; $d)  today's APPLY sittings (the daily cap's count)
#   ruled_ids($r)     the input ids an APPLY receipt ruled (outcome ≠ deferred): the ledger — read once
#   queued_ids($r)    the ids (input or ref) of every queue/goal/requeue ruling an APPLY receipt carries,
#                     an input's (`ruled`) or an issue the sitting filed and ruled in the same pass
#                     (`ruled_filed`), each {id, run} — "what this island queued"
# shellcheck disable=SC2016  # a jq program, not a shell expansion
JQ_RECEIPTS='def applied($r): $r[] | select(.schema == "island-intake-receipt/v1" and .mode == "apply");
  def sittings($r; $today): [ applied($r) | select(.session_ran == true and ((.ts // "") | startswith($today))) ] | length;
  def ruled_ids($r): [ applied($r) | .ruled[]? | select(.outcome != "deferred") | .input ] | unique;
  def queued_ids($r): [ applied($r) | (.run // "") as $run | ((.ruled // []) + (.ruled_filed // []))[]
    | select(.outcome | IN("queue", "goal", "requeue")) | ([.input] + (.refs // []))[] | {id: ., run: $run} ];'

# owner_table → a JSON array, one row per island in ISLANDS order, that finding_owner (jq, in
# cmd_dig) walks: {island, alerts: [the names its rule files define], paths: [its Touches prefixes]
# | null, pat: its text fallback}. `paths` is set exactly when the island has an alert-rule row.
owner_table() {
  local isl files f alerts paths tbl='[]'
  for isl in $ISLANDS; do
    files="$(island_alert_rules "$isl")"; alerts='[]'; paths=null
    if [ -n "$files" ]; then
      for f in $files; do
        [ -r "$ROOT/$f" ] || { echo "intake-select: alert-rule file $f unreadable — cannot tell whose finding is whose" >&2; return 1; }
      done
      # shellcheck disable=SC2086  # $files is a space-separated list of repo paths
      alerts="$(cd "$ROOT" && grep -hoE '^[[:space:]]*- alert:[[:space:]]*[A-Za-z0-9_]+' $files | awk '{print $NF}' | sort -u | jq -R . | jq -sc .)"
      [ "$(printf '%s' "$alerts" | jq 'length')" -gt 0 ] || { echo "intake-select: no alert: names in $files — probe failed" >&2; return 1; }
      paths="$(island_members "$isl" | sed 1d | jq -R 'select(length > 0)' | jq -sc .)"
    fi
    tbl="$(printf '%s' "$tbl" | jq -c --arg i "$isl" --argjson a "$alerts" --argjson p "$paths" --arg pat "$(island_pattern "$isl")" \
      '. + [{island: $i, alerts: $a, paths: $p, pat: $pat}]')"
  done
  printf '%s' "$tbl"
}

cmd_dig() {
  local now lookback verdicts dmax rmin d k findings responders receipts sel n today sittings tbl need rides
  case " $ISLANDS " in *" $ISLAND "*) ;; *) echo "intake-select: no dig row for island '$ISLAND'" >&2; exit 2;; esac
  tbl="$(owner_table)" || exit 2
  now="${INTAKE_NOW:-$(date -u +%s)}"; lookback="${INTAKE_DIG_LOOKBACK_D:-7}"
  verdicts="${INTAKE_DIG_VERDICTS:-cause-found}"; dmax="${INTAKE_DAILY_MAX:-2}"
  rmin="${INTAKE_RESPONDER_MIN:-3}"   # the recurrence floor: a smaller responder class starts no sitting
  ts_probe
  findings=""
  for k in $(seq 0 "$lookback"); do
    d="$(date -u -d "@$(( now - k * 86400 ))" +%Y-%m-%d)"
    findings="${findings}$(ts_read_objects "dig-$d" 'finding-*.json')"$'\n'
  done
  responders="$(read_responder "$now" "$lookback")"
  receipts="$(read_receipts "$now" "$lookback")"
  today="$(date -u -d "@$now" +%Y-%m-%d)"
  # the ride issues whose island decides a responder finding — only for findings no alert rule owns,
  # in a class (alertname + namespace) that reaches the floor before ownership: a one-off reads nothing
  need="$(jq -rn --argjson tbl "$tbl" --arg repo "${REPO#*/}" --argjson min "$rmin" \
      --slurpfile f <(printf '%s' "$responders" | grep -v '^$' || true) "$JQ_RESPONDER"'
    [ $f[] | rf_live | select(rule_owner($tbl) == null) | {a: (.alertname // ""), ns: rf_ns, n: rf_ride($repo)} ]
    | group_by([.a, .ns]) | map(select(length >= $min)) | [ .[][] | .n | select(. != null) ] | unique | .[]')" \
    || { echo "intake-select: responder pre-pass jq failed" >&2; exit 2; }
  # shellcheck disable=SC2086  # one issue number per word
  rides="$(ride_islands $need)" || exit 2
  sel="$(jq -n --argjson tbl "$tbl" --arg verdicts "$verdicts" --arg island "$ISLAND" --arg today "$today" \
      --argjson dmax "$dmax" --argjson rmin "$rmin" --arg repo "${REPO#*/}" --argjson rides "$rides" \
      --arg ts "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" \
      --slurpfile f <(printf '%s' "$findings" | grep -v '^$' || true) \
      --slurpfile rf <(printf '%s' "$responders" | grep -v '^$' || true) \
      --slurpfile r <(printf '%s' "$receipts" | grep -v '^$' || true) "$JQ_RECEIPTS $JQ_RESPONDER"'
    def fid: (._key | sub("\\.json$"; ""));
    # a responder finding is the island its alert rules name, else the island of the issue its ride served
    def responder_owner: rule_owner($tbl) // (rf_ride($repo) as $n | $rides[$n]) // "";
    # finding_owner: ONE island per finding, so no finding is ruled by two sittings.
    #  1. the first ISLANDS row whose alert rules define one of the alerts of the finding (members[].alertname,
    #     else the leading token of an alerts[] line);
    #  2. only when the rules of NO island define any of them: the first row that claims it by its evidence —
    #     a path under that row Touches prefixes at a path boundary in evidence[] / related[]
    #     ("pushgateway/" is not "gateway/"), or, for a row with no alert rules yet, its text pattern.
    def finding_owner:
      . as $f
      | ([($f.members // [])[] | .alertname?] + [($f.alerts // [])[] | tostring | split(" ")[0]]
         | map(select(. != null and . != "")) | unique) as $names
      | ([ $tbl[] | select(.alerts as $a | any($names[]; . as $x | $a | index($x))) | .island ] | first)
        // ([ $tbl[] | select(
                if .paths != null then
                  ("(^|[^A-Za-z0-9_./-])(" + (.paths | map(esc) | join("|")) + ")") as $re
                  | any((($f.evidence // []) + ($f.related // []))[]; tostring | test($re))
                else
                  .pat as $pat
                  | ([$f.cause, $f.recommendation, ($f.evidence // []), ($f.related // []), $f.pr] | tostring | test($pat))
                end) | .island ] | first)
        // "";
    ruled_ids($r) as $ruled
    | sittings($r; $today) as $sittings
    | [ $f[] | select(.schema == "dig-finding/v1")
             | select(.verdict as $v | ($verdicts | split(",")) | index($v))
             | select(finding_owner == $island)
             | {id: fid, kind: "dig", run: (.run // ""), verdict, alerts: (.alerts // []), members: (.members // []),
                cause, recommendation, evidence: (.evidence // []), related: (.related // []), pr: (.pr // "")} ] as $match
    | [ $match[] | select(.id as $i | $ruled | index($i) | not) ] as $inputs
    | [ $rf[] | rf_live | select(responder_owner == $island) ] as $rmine
    | [ $rmine | group_by([(.alertname // ""), rf_ns])[] | select(length >= $rmin)
        | (.[0].alertname // "") as $a | (.[0] | rf_ns) as $ns | sort_by(.ts // "")
        | {id: ("responder/" + $a + "/" + $ns), kind: "responder", alertname: $a, namespace: $ns, count: length,
           first_ts: (.[0].ts // ""), last_ts: (.[-1].ts // ""),
           members: [ .[] | {finding: (._key | sub("/finding\\.json$"; "")), ts, fingerprint, subject, verdict,
                             route_repo, route_stack, self_referential, remediation_would} ]} ] as $rclasses
    | [ $rclasses[] | select(.id as $i | $ruled | index($i) | not) ] as $rinputs
    # a finding whose ride issue is GONE (ride_islands: HTTP 404/410) owns nothing — counted, never a hold
    | ([ $rf[] | rf_live | select(rule_owner($tbl) == null) | select((rf_ride($repo) as $n | $rides[$n]) == "!gone") ] | length) as $gone
    | {schema: "island-intake-select/v1", island: $island, source: "dig", ts: $ts,
       counts: {matched: ($match | length), ruled: (($match | length) - ($inputs | length)),
                responder: {findings: ($rmine | length), classes: ($rclasses | length),
                            ruled: (($rclasses | length) - ($rinputs | length)), inputs: ($rinputs | length),
                            skipped: {ride_issue_gone: $gone}},
                inputs: (($inputs | length) + ($rinputs | length))},
       responder_min: $rmin, sittings_today: $sittings, daily_max: $dmax, inputs: ($inputs + $rinputs)}')" \
    || { echo "intake-select: selection jq failed" >&2; exit 2; }
  [ -n "$OUT" ] && printf '%s\n' "$sel" > "$OUT" || printf '%s\n' "$sel"
  printf '%s' "$sel" | jq -r '.inputs[] | if .kind == "responder" then "\(.id)\tresponder×\(.count)\t\(.first_ts) → \(.last_ts)"
    else "\(.id)\t\(.verdict)\t\(.alerts | join(", ") | .[0:80])" end' >&2
  n="$(printf '%s' "$sel" | jq '.counts.inputs')"; sittings="$(printf '%s' "$sel" | jq '.sittings_today')"
  if [ "$n" -eq 0 ]; then
    echo "hold: no unruled dig finding or responder class is island $ISLAND's ($(printf '%s' "$sel" | jq -c .counts))" >&2; exit 1
  elif [ "$sittings" -ge "$dmax" ]; then
    echo "hold: daily cap — $sittings apply sitting(s) today (INTAKE_DAILY_MAX=$dmax); $n input(s) wait for tomorrow" >&2; exit 1
  fi
  echo "fire: $n unruled dig input(s) for island $ISLAND ($(printf '%s' "$sel" | jq -c '{dig: (.counts.inputs - .counts.responder.inputs), responder: .counts.responder.inputs}'))" >&2; exit 0
}
# read_issues → $issues: the repo's OPEN issues, one REST list call (paginated by gh), bodies and
# comments riding it; exit 2 on a failed or empty read (never "no issues").
read_issues() {
  if [ -n "${INTAKE_ISSUES_JSON:-}" ]; then
    issues="$(cat "$INTAKE_ISSUES_JSON" 2>/dev/null)" || { echo "intake-select: INTAKE_ISSUES_JSON unreadable" >&2; exit 2; }
  else
    issues="$(gh issue list --repo "$REPO" --state open --limit 500 \
      --json number,title,body,labels,createdAt,updatedAt,author,comments 2>/dev/null)" || {
      echo "intake-select: gh issue list failed for $REPO" >&2; exit 2; }
  fi
  [ -n "$issues" ] || { echo "intake-select: empty answer from gh issue list (not a verdict)" >&2; exit 2; }
  printf '%s' "$issues" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "intake-select: the issue list is not a JSON array" >&2; exit 2; }
}
# emit_sel <sel-json> <verdict-tail> — write the selection, then the dig's verdict (exit 0 fire / 1 hold)
emit_sel() {
  local sel="$1" what="$2" n sittings dmax
  if [ -n "$OUT" ]; then printf '%s\n' "$sel" > "$OUT"; else printf '%s\n' "$sel"; fi
  n="$(printf '%s' "$sel" | jq '.counts.inputs')"; sittings="$(printf '%s' "$sel" | jq '.sittings_today')"
  dmax="$(printf '%s' "$sel" | jq '.daily_max')"
  if [ "$n" -eq 0 ]; then
    echo "hold: no $what for island $ISLAND ($(printf '%s' "$sel" | jq -c .counts))" >&2; exit 1
  elif [ "$sittings" -ge "$dmax" ]; then
    echo "hold: daily cap — $sittings apply sitting(s) today (INTAKE_DAILY_MAX=$dmax); $n input(s) wait for tomorrow" >&2; exit 1
  fi
  echo "fire: $n $what for island $ISLAND ($(printf '%s' "$sel" | jq -c .counts))" >&2; exit 0
}

# ── --source gaps ────────────────────────────────────────────────────────────────────────────────
cmd_gaps() {
  local root now dmax gmax lookback receipts sel ts today
  island_members "$ISLAND" >/dev/null || { echo "intake-select: no membership row for island '$ISLAND'" >&2; exit 2; }
  now="${INTAKE_NOW:-$(date -u +%s)}"; dmax="${INTAKE_DAILY_MAX:-2}"
  gmax="${INTAKE_GAP_MAX:-6}"; lookback="${INTAKE_GAP_LOOKBACK_D:-30}"
  ts="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"; today="$(date -u -d "@$now" +%Y-%m-%d)"
  root="$(island_specs_root "$ISLAND")"
  if [ -z "$root" ]; then
    sel="$(jq -n --arg island "$ISLAND" --arg ts "$ts" --argjson dmax "$dmax" \
      '{schema: "island-intake-select/v1", island: $island, source: "gaps", ts: $ts, specs_root: null,
        counts: {rows: 0, ruled: 0, named: 0, over_cap: 0, inputs: 0}, sittings_today: 0, daily_max: $dmax, inputs: []}')"
    emit_sel "$sel" "gap rows (the island declares no specs root)"
  fi
  [ -r "$ROOT/$root/README.md" ] || { echo "intake-select: $root/README.md (the specs index) unreadable — probe failed" >&2; exit 2; }
  read_issues
  ts_probe
  receipts="$(read_receipts "$now" "$lookback")"
  sel="$(jq -n --arg island "$ISLAND" --arg root "$root" --arg repo "$REPO" --arg ts "$ts" --arg today "$today" \
      --argjson dmax "$dmax" --argjson gmax "$gmax" --slurpfile iss <(printf '%s' "$issues") \
      --rawfile idx "$ROOT/$root/README.md" \
      --slurpfile r <(printf '%s' "$receipts" | grep -v '^$' || true) "$JQ_RECEIPTS"'
    $iss[0] as $issues
    | ruled_ids($r) as $ruled
    | ([ $issues[] | .number ]) as $open
    | [ $idx | split("\n")[]
        | select(test("^\\|\\s*\\[[A-Z][A-Z0-9-]*\\]\\("))
        | select(test("⚑ gap|🚧"))
        | . as $line
        | (capture("^\\|\\s*\\[(?<req>[A-Z][A-Z0-9-]*)\\]\\((?<href>[^)]*)\\)")) as $m
        | ($root + "/" + ($m.href | sub("#.*$"; ""))) as $page
        | {id: ($page + "#" + $m.req), kind: "gap", requirement: $m.req, page: $page,
           marks: ([if ($line | test("⚑ gap")) then "⚑ gap" else empty end, if ($line | test("🚧")) then "🚧 WIP" else empty end]),
           refs: ([$line | scan("#([0-9]+)") | .[0] | tonumber] | unique),
           row: $line} ] as $rows
    | [ $rows[] | . as $g
        | select(any($open[]; . as $n | $g.refs | index($n))
                 or any($issues[]; ((.title // "") + "\n" + (.body // "")) | test("(^|[^A-Z0-9-])" + $g.requirement + "($|[^A-Z0-9-])")))
        | .id ] as $named
    | [ $rows[] | select(.id as $i | ($ruled | index($i) | not) and ($named | index($i) | not)) ] as $free
    | {schema: "island-intake-select/v1", island: $island, source: "gaps", ts: $ts, specs_root: $root,
       counts: {rows: ($rows | length), ruled: ([ $rows[] | select(.id as $i | $ruled | index($i)) ] | length),
                named: ($named | length), over_cap: ([($free | length) - $gmax, 0] | max),
                inputs: ([$free | length, $gmax] | min)},
       gap_max: $gmax, sittings_today: sittings($r; $today), daily_max: $dmax, inputs: $free[0:$gmax]}')" \
    || { echo "intake-select: gaps selection jq failed" >&2; exit 2; }
  printf '%s' "$sel" | jq -r '.inputs[] | "\(.id)\t\(.marks | join("+"))"' >&2
  emit_sel "$sel" "unruled, unnamed gap rows"
}

# ── --source escape ──────────────────────────────────────────────────────────────────────────────
cmd_escape() {
  local now dmax lookback receipts queued prs sel ts today since
  island_members "$ISLAND" >/dev/null || { echo "intake-select: no membership row for island '$ISLAND'" >&2; exit 2; }
  now="${INTAKE_NOW:-$(date -u +%s)}"; dmax="${INTAKE_DAILY_MAX:-2}"; lookback="${INTAKE_ESCAPE_LOOKBACK_D:-30}"
  ts="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"; today="$(date -u -d "@$now" +%Y-%m-%d)"
  since="$(date -u -d "@$(( now - lookback * 86400 ))" +%Y-%m-%d)"
  ts_probe
  receipts="$(read_receipts "$now" "$lookback")"
  # the issues this island queued, each with the run that queued it
  queued="$(jq -nc --arg repo "$REPO" --slurpfile r <(printf '%s' "$receipts" | grep -v '^$' || true) "$JQ_RECEIPTS"'
    [ queued_ids($r)[] | select(.id | test("^" + ($repo | gsub("\\."; "\\.")) + "#[0-9]+$"))
      | {n: (.id | sub(".*#"; "") | tonumber), run} ] | unique_by(.n)')" \
    || { echo "intake-select: escape receipt jq failed" >&2; exit 2; }
  if [ "$(printf '%s' "$queued" | jq 'length')" -eq 0 ]; then
    prs='[]'
  elif [ -n "${INTAKE_PRS_JSON:-}" ]; then
    prs="$(cat "$INTAKE_PRS_JSON" 2>/dev/null)" || { echo "intake-select: INTAKE_PRS_JSON unreadable" >&2; exit 2; }
  else
    prs="$(gh pr list --repo "$REPO" --state all --search "created:>=$since" --limit 1000 \
      --json number,title,state,url,headRefName,body,closingIssuesReferences,reviews 2>/dev/null)" \
      || { echo "intake-select: gh pr list failed for $REPO" >&2; exit 2; }
  fi
  printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "intake-select: the PR list is not a JSON array (not a verdict)" >&2; exit 2; }
  sel="$(jq -n --arg island "$ISLAND" --arg repo "$REPO" --arg ts "$ts" --arg today "$today" --argjson dmax "$dmax" \
      --argjson queued "$queued" --slurpfile prsf <(printf '%s' "$prs") \
      --slurpfile r <(printf '%s' "$receipts" | grep -v '^$' || true) "$JQ_RECEIPTS"'
    $prsf[0] as $prs
    | ruled_ids($r) as $read
    | def links($n): . as $p
        | (any(($p.closingIssuesReferences // [])[]; .number == $n))
          or (($p.headRefName // "") | test("(^|[/-])issue-" + ($n | tostring) + "($|[^0-9])"))
          or (($p.body // "") | test("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s*:?\\s+(" + ($repo | gsub("\\."; "\\.")) + ")?#" + ($n | tostring) + "\\b"));
    [ $prs[] | select(.state == "OPEN" or .state == "MERGED")
        | ([ (.reviews // [])[] | select(.state == "CHANGES_REQUESTED") ] | length) as $cr
        | select($cr > 0)
        | . as $p | ([ $queued[] | select(.n as $n | $p | links($n)) ] | first) as $q
        | select($q != null)
        | {id: ($repo + "#" + (.number | tostring)), kind: "escape", number, title, url, state,
           issue: ($repo + "#" + ($q.n | tostring)), queued_by: $q.run, changes_requested: $cr} ] as $match
    | [ $match[] | select(.id as $i | $read | index($i) | not) ] as $inputs
    | {schema: "island-intake-select/v1", island: $island, source: "escape", ts: $ts,
       counts: {queued: ($queued | length), prs: ($match | length), read: (($match | length) - ($inputs | length)),
                inputs: ($inputs | length)},
       sittings_today: sittings($r; $today), daily_max: $dmax, inputs: $inputs,
       prior: [ applied($r) | (.escapes // [])[] ]}')" \
    || { echo "intake-select: escape selection jq failed" >&2; exit 2; }
  printf '%s' "$sel" | jq -r '.inputs[] | "\(.id)\t\(.state)\tCR×\(.changes_requested)\t\(.issue)"' >&2
  emit_sel "$sel" "unread escape PRs"
}

# Touches of every issue through the ONE body parser (agents/issue_body.py's `get`, imported):
# what `jq -r '.body // ""' | python3 issue_body.py get Touches` printed, "" when it failed.
# shellcheck disable=SC2016
PY_TOUCHES='import json, shlex, sys
sys.path.insert(0, sys.argv[1])
try:
    import issue_body
except Exception:
    sys.exit(0)
for i, row in enumerate(json.load(sys.stdin)):
    body = row.get("body") if isinstance(row, dict) else None
    if body is None or body is False:
        body = ""
    elif not isinstance(body, str):
        body = json.dumps(body)
    try:
        v = issue_body.get(body + "\n", "Touches")
    except Exception:
        v = None
    v = (v or "").rstrip("\n")
    if v:
        print("F_touches[%d]=%s" % (i, shlex.quote(v)))'

# The ONE reader of the numbers a comment names — `#<n>` or this repo's full `<owner/repo>#<n>`, never another
# repo's — shared by the wait source (targets_of) and the pile's re-read ledger (F_refs), so the two agree.
# shellcheck disable=SC2016  # a jq program, not a shell expansion
JQ_REFS='def refs_in($self): [ (. // "") | scan("(?:^|[^A-Za-z0-9_/])(?:" + $repo_re + ")?#([0-9]+)\\b") | .[0] | tonumber | select(. != $self) ] | unique;'
REPO_RE="$(printf '%s' "$REPO" | sed 's/[.]/\\./g')"

# blocked_on_def → the scan's ONE marker grammar (`def blocked_on_kind:` — `human` / `issue=<n>` / `pr=<n>` / ""),
# read out of agents/coordinator-scan.sh's >>>REPLAY:blocked-on-jq>>> block, so no reader here can drift
# from it; exit 2 when it cannot be read.
blocked_on_def() {
  local d
  d="$(awk '$0 == "# >>>REPLAY:blocked-on-jq>>>" { b = 1; next }
    $0 == "# <<<REPLAY:blocked-on-jq<<<" { b = 0 }
    b && sub(/^BLOCKED_ON_DEF=\047/, "") && sub(/\047$/, "") { print }' "$ROOT/agents/coordinator-scan.sh" 2>/dev/null)" || d=''
  case "$d" in
    'def blocked_on_kind:'*';') printf '%s' "$d";;
    *) echo "intake-select: the blocked-on grammar (BLOCKED_ON_DEF in agents/coordinator-scan.sh's blocked-on-jq block) is unreadable" >&2; exit 2;;
  esac
}

# ref_states <numbers…> → {"<n>": {state: OPEN|CLOSED|MERGED|missing, closed_at}} — issues and PRs of $REPO in
# ONE GraphQL read (aliases). Seam INTAKE_REFS_JSON (a number it lacks is a failed read). Return 1 on a failed
# read: an unread target is never "still open". A number GitHub does not resolve (deleted) is `missing`.
ref_states() {
  [ $# -gt 0 ] || { printf '{}'; return 0; }
  local q n out
  if [ -n "${INTAKE_REFS_JSON:-}" ]; then
    out="$(jq -c '[$ARGS.positional[] as $n | {key: $n, value: .[$n]}] | if any(.value == null) then error("missing") else from_entries end' \
      "$INTAKE_REFS_JSON" --args "$@" 2>/dev/null)" || { echo "intake-select: INTAKE_REFS_JSON unreadable or lacks one of: $*" >&2; return 1; }
    printf '%s' "$out"; return 0
  fi
  q="query { repository(owner: \"${REPO%%/*}\", name: \"${REPO#*/}\") {"
  for n in "$@"; do
    q="$q r$n: issueOrPullRequest(number: $n) { __typename ... on Issue { state closedAt } ... on PullRequest { state mergedAt closedAt } }"
  done
  q="$q } }"
  # a NOT_FOUND alias makes gh exit 1 with the rest of the data intact — the data decides, not the exit
  out="$(gh api graphql -f query="$q" 2>/dev/null || true)"
  printf '%s' "$out" | jq -e '.data.repository | type == "object"' >/dev/null 2>&1 \
    || { echo "intake-select: the target-state read (GraphQL) failed" >&2; return 1; }
  printf '%s' "$out" | jq -c '.data.repository | to_entries | map({key: (.key | ltrimstr("r")),
    value: (if .value == null then {state: "missing", closed_at: null}
            else {state: .value.state, closed_at: (.value.mergedAt // .value.closedAt)} end)}) | from_entries'
}

# island_numbers <items json file> → the numbers of the items $ISLAND owns (island_of_issue over title +
# Touches, the pile's membership), one per line. ONE grep per island over every title, ONE parser run.
island_numbers() {
  local f="$1" i isl ln _ ti=0 cnt
  load_table
  local -a N=() T=()
  declare -A TC=()
  mapfile -t N < <(jq -r '.[].number' "$f")
  mapfile -t T < <(jq -r '.[] | (.title // "") | gsub("\n"; " ")' "$f")
  eval "$(python3 -I -c "${PY_TOUCHES/F_touches/TC}" "$ROOT/agents" < "$f" 2>/dev/null || true)"
  for isl in $ISLANDS; do
    while IFS=: read -r ln _; do TMATCH["$isl:w$((ln - 1))"]=1; done < <(printf '%s\n' "${T[@]}" | { grep -anE -i "${TRES[$ti]}" || true; })
    ti=$((ti + 1))
  done
  cnt="${#N[@]}"
  for ((i = 0; i < cnt; i++)); do
    [ "$(island_of_issue "${T[$i]}" "${TC[$i]:-}" "w$i")" = "$ISLAND" ] && printf '%s\n' "${N[$i]}"
  done
  return 0
}

# read_wait_items → $witems: the repo's OPEN issues + those CLOSED in the last <days> days, normalized
# ({number, title, body, state, createdAt, updatedAt, closedAt, author, labels, comments[{id, createdAt, body,
# author{login, is_bot}}], events[{type, createdAt, label, actor{login, is_bot}}]}), in ONE paginated GraphQL
# search per state — author TYPES come with it (a bot comment's login carries no `[bot]` in GraphQL).
read_wait_items() {
  local since="$1" q raw
  if [ -n "${INTAKE_ISSUES_JSON:-}" ]; then
    witems="$(cat "$INTAKE_ISSUES_JSON" 2>/dev/null)" || { echo "intake-select: INTAKE_ISSUES_JSON unreadable" >&2; exit 2; }
  else
    # shellcheck disable=SC2016  # GraphQL variables, not shell expansions
    q='query($q: String!, $endCursor: String) { search(query: $q, type: ISSUE, first: 50, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { ... on Issue { number title body state createdAt updatedAt closedAt author { __typename login }
        labels(first: 30) { nodes { name } }
        comments(last: 100) { nodes { databaseId createdAt body author { __typename login } } }
        timelineItems(last: 50, itemTypes: [LABELED_EVENT, UNLABELED_EVENT, CLOSED_EVENT, REOPENED_EVENT]) { nodes { __typename
          ... on LabeledEvent { createdAt label { name } actor { __typename login } }
          ... on UnlabeledEvent { createdAt label { name } actor { __typename login } }
          ... on ClosedEvent { createdAt actor { __typename login } }
          ... on ReopenedEvent { createdAt actor { __typename login } } } } } } } }'
    raw="$( { gh api graphql --paginate -f query="$q" -F q="repo:$REPO is:issue is:open" \
           && gh api graphql --paginate -f query="$q" -F q="repo:$REPO is:issue is:closed closed:>=$since"; } 2>/dev/null)" \
      || { echo "intake-select: the wait items read (GraphQL search) failed for $REPO" >&2; exit 2; }
    witems="$(printf '%s' "$raw" | jq -sc '
      def who: {login: (.login // ""), is_bot: (.__typename == "Bot")};
      [ .[] | .data.search.nodes[]? | select(.number != null)
        | {number, title, body, state, createdAt, updatedAt, closedAt, author: ((.author // {}) | who),
           labels: [.labels.nodes[] | {name}],
           comments: [.comments.nodes[] | {id: .databaseId, createdAt, body, author: ((.author // {}) | who)}],
           events: [.timelineItems.nodes[] | {type: .__typename, createdAt, label: (.label.name // null), actor: ((.actor // {}) | who)}]} ]
      | unique_by(.number)')" || { echo "intake-select: the wait items answer is not JSON" >&2; exit 2; }
  fi
  # a failed read already exited above; an empty array is an island with nothing parked (the pile's rule)
  printf '%s' "$witems" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || { echo "intake-select: the wait items read is not an array (not a verdict)" >&2; exit 2; }
}

# The jq the wait source runs twice — `targets` (the numbers whose state decides staleness) then `select`.
# shellcheck disable=SC2016  # a jq program, not a shell expansion
JQ_WAIT='
  def bot: ((.is_bot // false) == true) or ((.login // "") | test("^app/|\\[bot\\]$"));
  def outcome: ((. // "") | split("\n")[0] | capture("^intake:\\s*(?<o>[a-z-]+)") | .o) // "";
  def kind_of: (. // "") | blocked_on_kind;
  def parking: (.body | kind_of) == "human" or ((.body | outcome) == "seat" and (.body | kind_of) == "");
  def writer: if (.body | outcome) != "" then "intake" elif (.author | bot) then "lane" else "human" end;
  def by_kind($a; $o): if ($a | bot | not) then "operator" elif $o != "" then "reread" else "lane" end;
  def ts: try fromdateiso8601 catch 0;
  def releases:
      [ (.comments // [])[] | select(((.body | outcome) as $o | $o != "" and $o != "seat") or ((.body | kind_of) | test("^(issue|pr)=")))
        | {at: .createdAt, via: "comment", by: .author.login, release: by_kind(.author; (.body | outcome)),
           line: (.body | split("\n")[0] | .[0:200])} ]
    + [ (.events // [])[] | select(.type == "UnlabeledEvent" and .label == "agent/blocked" and (.actor | bot | not))
        | {at: .createdAt, via: "label", by: .actor.login, release: "operator", line: "agent/blocked removed"} ]
    + [ (.events // [])[] | select(.type == "ClosedEvent")
        | {at: .createdAt, via: "close", by: .actor.login, release: by_kind(.actor; ""), line: "closed"} ]
    | sort_by(.at | ts);
  def parkings:
    . as $i | [ (.comments // [])[] | select(parking)
      | {at: .createdAt, by: .author.login, writer: writer, comment_id: .id, marker: (.body | kind_of),
         line: (.body | split("\n")[0] | .[0:200]), refs: (.body | refs_in($i.number))} ] | sort_by(.at | ts);
  def released_of($p; $rels): [ $rels[] | select((.at | ts) > ($p.at | ts)) ] | first;
  # per item: its parkings, each with its release (or null), and the newest marker comment
  def walk_item:
    . as $i | releases as $rels | parkings as $ps
    | {i: $i, ps: [ $ps[] | . + {rel: released_of(.; $rels)} ],
       marker: ([ (.comments // [])[] | select((.body | kind_of) != "") | {at: .createdAt, kind: (.body | kind_of)} ] | sort_by(.at | ts) | last)};
  def targets_of:   # the stale candidates of one walked OPEN item: [{n, why, since}]
    if .i.state != "OPEN" then [] else
      ([ .marker // empty | select(.kind | test("^(issue|pr)=")) | {n: (.kind | sub("^[a-z]+="; "") | tonumber), why: ("marker " + .kind), since: null} ]
       + [ ([ .ps[] | select(.rel == null and .marker == "human") ] | last) // empty | .at as $at | .refs[] | {n: ., why: "named in the parking comment", since: $at} ])
    end;
'

cmd_wait() {
  local now dmax lookback stand wmax receipts since sel ts today members bod targets refs isl
  island_members "$ISLAND" >/dev/null || { echo "intake-select: no membership row for island '$ISLAND'" >&2; exit 2; }
  now="${INTAKE_NOW:-$(date -u +%s)}"; dmax="${INTAKE_DAILY_MAX:-2}"; lookback="${INTAKE_WAIT_LOOKBACK_D:-30}"
  stand="${INTAKE_WAIT_STANDING_D:-${INTAKE_REREAD_AGE_D:-3}}"; wmax="${INTAKE_WAIT_MAX:-6}"
  ts="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"; today="$(date -u -d "@$now" +%Y-%m-%d)"
  since="$(date -u -d "@$(( now - lookback * 86400 ))" +%Y-%m-%d)"
  bod="$(blocked_on_def)"
  ts_probe
  receipts="$(read_receipts "$now" "$lookback")"
  read_wait_items "$since"
  printf '%s' "$witems" > "${TMPDIR:-/tmp}/intake-wait-items.$$.json"
  members="$(island_numbers "${TMPDIR:-/tmp}/intake-wait-items.$$.json" | jq -R 'tonumber' | jq -sc .)" \
    || { rm -f "${TMPDIR:-/tmp}/intake-wait-items.$$.json"; echo "intake-select: wait membership failed" >&2; exit 2; }
  rm -f "${TMPDIR:-/tmp}/intake-wait-items.$$.json"
  local re="$REPO_RE"
  # phase 1: the targets whose state decides staleness — read in ONE batched call
  targets="$(jq -r --argjson m "$members" --arg repo_re "$re" "$bod $JQ_REFS $JQ_WAIT"'
    [ .[] | select(.number as $n | $m | index($n)) | walk_item | targets_of[] | .n ] | unique | .[]' <<< "$witems")" \
    || { echo "intake-select: wait targets jq failed" >&2; exit 2; }
  # shellcheck disable=SC2086  # one number per word
  refs="$(ref_states $targets)" || exit 2
  sel="$(jq -n --arg island "$ISLAND" --arg repo "$REPO" --arg repo_re "$re" --arg ts "$ts" --arg today "$today" \
      --argjson now "$now" --argjson lookback "$lookback" --argjson stand "$stand" --argjson wmax "$wmax" --argjson dmax "$dmax" \
      --argjson m "$members" --argjson refs "$refs" --slurpfile items <(printf '%s' "$witems") \
      --slurpfile r <(printf '%s' "$receipts" | grep -v '^$' || true) "$bod $JQ_REFS $JQ_WAIT $JQ_RECEIPTS"'
    ($now - $lookback * 86400) as $cut | ($now - $stand * 86400) as $old
    | ruled_ids($r) as $read
    | [ applied($r) | (.ts // "") as $t | .ruled[]? | select(.outcome != "deferred") | {id: .input, t: ($t | ts), o: .outcome} ] as $lines
    | [ $items[0][] | select(.number as $n | $m | index($n)) | walk_item ] as $walked
    | def row($w; $p; $state):
        {id: ($repo + "#" + ($w.i.number | tostring) + "@" + $p.at + "/" + $state), kind: "wait", wait: $state,
         number: $w.i.number, title: $w.i.title, item_state: $w.i.state,
         parked_at: $p.at, parked_by: $p.by, writer: $p.writer, marker: $p.marker, parking: $p.line, comment_id: $p.comment_id}
        + (if $p.rel == null then {} else {released_at: $p.rel.at, released_by: $p.rel.by, release: $p.rel.release,
                                            release_via: $p.rel.via, release_line: $p.rel.line} end);
      [ $walked[] | . as $w | .ps[] | select(.rel != null and ((.rel.at | ts) >= $cut)) | row($w; .; "released") ]
      | sort_by(.released_at | ts) as $released
    | [ $walked[] | . as $w | select(.i.state == "OPEN") | (.ps | last) // empty
        | select(.rel == null and ((.at | ts) <= $old)) | . as $p
        | ([ $lines[] | select(.id == ($repo + "#" + ($w.i.number | tostring)) and .o == "unchanged" and .t > ($p.at | ts)) ] | length) as $u
        | select($u > 0) | row($w; $p; "standing") + {unchanged_reads: $u} ]
      # an agent/blocked item that no comment parks and no `intake:` ruling or marker explains (a marker naming an
      # issue or PR is a dependency, not a human wait): dated by the newest label event (else updatedAt), its actor
      # the writer
      + [ $walked[] | select(.i.state == "OPEN" and (.ps | length) == 0 and .marker == null and ([.i.labels[].name] | index("agent/blocked"))
                             and ([(.i.comments // [])[] | select((.body | outcome) != "")] | length) == 0) | . as $w
          | ([ (.i.events // [])[] | select(.type == "LabeledEvent" and .label == "agent/blocked") ] | sort_by(.createdAt | ts) | last) as $e
          | {at: ($e.createdAt // .i.updatedAt), by: ($e.actor.login // ""),
             writer: (if $e == null then "unknown" elif ($e.actor | bot) then "lane" else "human" end),
             marker: "", line: "agent/blocked with no parking comment", comment_id: null, rel: null}
          | select((.at | ts) <= $old) | row($w; .; "standing") + {unchanged_reads: 0} ]
      | sort_by(.parked_at | ts) as $standing
    | [ ($released + $standing)[] | select(.id as $i | $read | index($i) | not) ] as $free
    | [ $walked[] | . as $w | targets_of[] | . as $t | ($refs[($t.n | tostring)] // {state: "missing"}) as $s
        | select($s.state == "CLOSED" or $s.state == "MERGED")
        | select($t.since == null or (($s.closed_at // "") | ts) > ($t.since | ts))
        | ($repo + "#" + ($w.i.number | tostring)) as $id
        | select(any($lines[]; .id == $id and .t > (($s.closed_at // "") | ts)) | not)
        | {id: $id, kind: "reread", number: $w.i.number, title: $w.i.title, wait: "stale",
           stale: {target: $t.n, target_state: $s.state, target_closed_at: $s.closed_at, why: $t.why}} ]
      | unique_by(.id) as $stale
    | {schema: "island-intake-select/v1", island: $island, source: "wait", ts: $ts,
       counts: {released: ($released | length), standing: ($standing | length),
                read: (($released | length) + ($standing | length) - ($free | length)),
                over_cap: ([($free | length) - $wmax, 0] | max), waits: ([$free | length, $wmax] | min),
                stale: ($stale | length), inputs: (([$free | length, $wmax] | min) + ($stale | length))},
       wait_max: $wmax, lookback_d: $lookback, standing_d: $stand,
       sittings_today: sittings($r; $today), daily_max: $dmax,
       inputs: ($free[0:$wmax] + $stale), prior: [ applied($r) | (.waits // [])[] ]}')" \
    || { echo "intake-select: wait selection jq failed" >&2; exit 2; }
  printf '%s' "$sel" | jq -r '.inputs[] | if .kind == "wait" then "\(.id)\t\(.writer)\t\(.release // "-")"
    else "\(.id)\tstale\t\(.stale.why) #\(.stale.target) \(.stale.target_state)" end' >&2
  emit_sel "$sel" "waits to read or stale waits"
}

case "$SOURCE" in
  issues|pile) ;;
  dig) cmd_dig; exit $?;;
  gaps) cmd_gaps; exit $?;;
  escape) cmd_escape; exit $?;;
  wait) cmd_wait; exit $?;;
  *) echo "intake-select: unknown --source $SOURCE (issues|dig|pile|gaps|escape|wait)" >&2; exit 2;;
esac

# ── the issue pile (--source issues, --source pile) ──────────────────────────────────────────────
island_members "$ISLAND" >/dev/null || { echo "intake-select: no membership row for island '$ISLAND'" >&2; exit 2; }
PARSER="$ROOT/agents/issue_body.py"
[ -f "$PARSER" ] || { echo "intake-select: $PARSER missing (run from a homelab checkout)" >&2; exit 2; }

# One list call (REST, paginated by gh); the body rides it so membership needs no second read.
read_issues

now="${INTAKE_NOW:-$(date -u +%s)}"
# REREAD=1 (--source pile) also collects the waits: the SAME walk, the same container/Goal and
# membership predicates — a wait differs from a candidate only in which label/ruling it carries.
REREAD=0; [ "$SOURCE" = pile ] && REREAD=1
REREAD_AGE_D="${INTAKE_REREAD_AGE_D:-3}"
count="$(printf '%s' "$issues" | jq 'length')"

# Every per-issue field the walk reads, in ONE jq pass and ONE parser run (no fork per issue or
# per field). Each field is exactly what `jq -r <expr>` printed into "$(…)" (trailing newlines
# stripped). The fields the walk reads only
# for SOME issues (life, ruling, since, author) carry a `=` prefix, or `!` when their expression
# errors — the walk dies as the per-field read did (jq's error line, exit 5) only on reaching one.
# shellcheck disable=SC2016  # a jq program, not a shell expansion
JQ_FIELDS='def r: if type == "string" then . else tojson end | until(endswith("\n") | not; .[:-1]);
  def lazy(e): try ("=" + (e | r)) catch ("!" + tostring);
  . as $all | range(0; length) as $i | $all[$i]
  | "F_num[\($i)]=\(.number | r | @sh); F_title[\($i)]=\(.title | r | @sh); "
  + "F_life[\($i)]=\(lazy([.labels[].name] as $l
      | if ($l | index("task/goal")) then "other"
        elif ($l | index("agent/blocked")) then "blocked"
        elif ($l | any(startswith("agent/"))) then "loop" else "none" end) | @sh); "
  + "F_bot[\($i)]=\(if (try ((.author.is_bot == true) or ((.author.login // "") | test("^app/|\\[bot\\]$"))) catch false) then 1 else "" end | @sh); "
  + "F_ruling[\($i)]=\(lazy([.comments[]? | .body | split("\n")[0] | select(startswith("intake:"))] | last // "") | @sh); "
  + "F_since[\($i)]=\(lazy(([.comments[]? | select((.body | split("\n")[0] | startswith("intake:")) or (.body | test("(^|\n)blocked-on:")))
      | .createdAt | select(. != null)] | max) // .updatedAt // .createdAt) | @sh); "
  + "F_refs[\($i)]=\((try ((.number) as $self | [.comments[]? | select(((.body // "") | split("\n")[0] | startswith("intake:")) or ((.body // "") | test("(^|\n)blocked-on:")))]
      | sort_by(.createdAt // "") | last // {} | (.body // "")
      | [refs_in($self)[], (scan("(?:^|\n)blocked-on: (?:issue|pr)=([0-9]+)") | .[0] | tonumber)] | unique
      | map(select(. != $self) | tostring) | join(" ")) catch "") | @sh); "
  + "F_fwd[\($i)]=\([.comments[]? | (.body // "") | split("\n")[0] | select(test("^intake:\\s*forward\\b"))] | length); "
  + "F_author[\($i)]=\(lazy(.author.login) | @sh); F_created[\($i)]=\(.createdAt | r | @sh)"'
F_num=(); F_title=(); F_life=(); F_bot=(); F_ruling=(); F_since=(); F_author=(); F_created=(); F_touches=(); F_fwd=(); F_refs=()
fields="$(printf '%s' "$issues" | jq -r --arg repo_re "$REPO_RE" "$JQ_REFS $JQ_FIELDS")"
eval "$fields"
eval "$(printf '%s' "$issues" | python3 -I -c "$PY_TOUCHES" "$ROOT/agents" 2>/dev/null || true)"

# The title rows, matched once per island over every title (grep -iE, as island_of_issue reads
# them): TMATCH[<island>:<index>] = 1. A multi-line title is matched on its own (island_of_issue).
load_table
declare -A TMATCH=()
_ti=0
for isl in $ISLANDS; do
  while IFS=: read -r ln _; do TMATCH["$isl:$((ln - 1))"]=1; done < <(
    for t in "${F_title[@]}"; do case "$t" in *$'\n'*) echo;; *) printf '%s\n' "$t";; esac; done \
      | { grep -anE -i "${TRES[$_ti]}" || true; })
  _ti=$((_ti + 1))
done

lazy() { # <value> → the field, or jq's own error line + exit 5 where the per-field read would have died
  case "$1" in =*) printf '%s' "${1#=}";; *) echo "jq: error (at <stdin>:0): ${1#!}" >&2; exit 5;; esac
}
# The PR-level waits (--source pile only): PRHOLD_PR[<issue>] = the OPEN PR whose newest
# `blocked-on:` marker is `human`, PRHOLD_SINCE[<issue>] = that comment's date. ONE list call; a
# failed read is exit 2 (an unread PR list is never "no holds"). The marker grammar is the scan's
# ONE definition, not a copy: `blocked_on_kind` is read out of agents/coordinator-scan.sh's
# >>>REPLAY:blocked-on-jq>>> block (§BLOCKED-ON PREDICATE — the seam the replay harnesses already
# extract by), so the two readers cannot drift; a definition that cannot be read is exit 2. The
# newest comment carrying a marker rules.
# Offered only under INTAKE_PR_HOLDS=1 (default off: gateway/intake.md step R rules these rows in
# the report only, until the release of a PR-level hold has a rule — the cron does not set it).
declare -A PRHOLD_PR=() PRHOLD_SINCE=()
if [ "$REREAD" = 1 ] && [ "${INTAKE_PR_HOLDS:-0}" = 1 ]; then
  if [ -n "${INTAKE_PRS_JSON:-}" ]; then
    open_prs="$(cat "$INTAKE_PRS_JSON" 2>/dev/null)" || { echo "intake-select: INTAKE_PRS_JSON unreadable" >&2; exit 2; }
  else
    open_prs="$(gh pr list --repo "$REPO" --state open --limit 300 \
      --json number,state,headRefName,body,closingIssuesReferences,comments 2>/dev/null)" \
      || { echo "intake-select: gh pr list failed for $REPO" >&2; exit 2; }
  fi
  printf '%s' "$open_prs" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "intake-select: the PR list is not a JSON array (not a verdict)" >&2; exit 2; }
  blocked_on_def="$(blocked_on_def)"
  # shellcheck disable=SC2016  # a jq program, not a shell expansion
  holds="$(printf '%s' "$open_prs" | jq -r "$blocked_on_def"'
    .[] | select((.state // "OPEN") == "OPEN")
    | ([ .comments[]? | select(((.body // "") | blocked_on_kind) != "") ] | sort_by(.createdAt // "") | last) as $m
    | select($m != null and (($m.body // "") | blocked_on_kind) == "human")
    | .number as $pr
    | ( [ (.closingIssuesReferences // [])[] | .number ]
      + [ (.headRefName // "") | match("(^|[/-])issue-(?<n>[0-9]+)($|[^0-9])"; "g") | .captures[] | select(.name == "n") | .string | tonumber ]
      + [ (.body // "") | match("(?i)\\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\\s*:?\\s+#(?<n>[0-9]+)\\b"; "g") | .captures[] | select(.name == "n") | .string | tonumber ]
      ) | unique | .[]
    | "PRHOLD_PR[\(.)]=\($pr); PRHOLD_SINCE[\(.)]=\(($m.createdAt // "") | @sh)"')" \
    || { echo "intake-select: PR-hold jq failed" >&2; exit 2; }
  eval "$holds"
fi
cand_args=(); reread_args=()
i=0
while [ "$i" -lt "$count" ]; do
  ix=$i; i=$((i + 1))
  num="${F_num[$ix]}"
  title="${F_title[$ix]}"
  # containers and lifecycle-labelled items are never candidates
  case "$title" in post-launch:*|stint:*) continue;; esac
  # lifecycle: none | blocked (`agent/blocked` — a wait, the reread's) | other (a Goal) | loop (any
  # other `agent/*` label: the loop's own state, nobody's input — unless its open PR is parked on
  # a human, which is a wait the labels do not show: PRHOLD_PR above)
  life="$(lazy "${F_life[$ix]}")" || exit 5
  case "$life" in
    other) continue;;
    blocked) [ "$REREAD" = 1 ] || continue;;
    loop) [ -n "${PRHOLD_PR[$num]:-}" ] || continue;;
  esac
  # membership: the island table (island_of_issue — title, else every Touches entry, first row wins)
  touches="${F_touches[$ix]:-}"
  kind=member
  case "$(island_of_issue "$title" "$touches" "$ix")" in
    "$ISLAND") ;;
    "") # nobody's: an attribution input for ATTRIBUTION_ISLAND when bot-filed (not author type User)
      [ "$ISLAND" = "$ATTRIBUTION_ISLAND" ] || continue
      [ -n "${F_bot[$ix]}" ] || continue
      kind=attribution;;
    *) continue;;
  esac
  # a standing ruling: a comment whose first line starts with `intake:` (the LATEST one is the ruling)
  ruling="$(lazy "${F_ruling[$ix]}")" || exit 5
  # …except `intake: forward → <island>`: another sitting passed the item on (gateway/intake.md
  # step 0) and retitled it, so it is an UNRULED candidate of whichever island its title names now
  # (the SAME test as F_fwd's count above: `forward` as the outcome word, whatever follows it)
  [[ "$ruling" =~ ^intake:[[:space:]]*forward($|[^[:alnum:]_]) ]] && ruling=""
  if [ "$life" = blocked ] || [ "$life" = loop ] || [ -n "$ruling" ]; then
    # ruled or blocked: never a candidate; a reread when it is a member's WAIT, old enough
    [ "$REREAD" = 1 ] && [ "$kind" = member ] || continue
    wait_kind=""
    w="${ruling#intake:}"; w="${w#"${w%%[![:space:]]*}"}"; read -r w _ <<< "$w" || true
    [ "$w" = seat ] && wait_kind=seat
    [ "$life" = blocked ] && wait_kind=agent/blocked
    pr=""
    [ "$life" = loop ] && { wait_kind="pr-hold"; pr="${PRHOLD_PR[$num]}"; ruling="blocked-on: human (PR #${pr})"; }
    [ -n "$wait_kind" ] || continue
    if [ -n "$pr" ]; then since="${PRHOLD_SINCE[$num]}"; else since="$(lazy "${F_since[$ix]}")" || exit 5; fi
    sts="$(date -u -d "$since" +%s 2>/dev/null || echo "$now")"
    wait_d=$(( (now - sts) / 86400 ))
    [ "$wait_d" -ge "$REREAD_AGE_D" ] || continue
    author="$(lazy "${F_author[$ix]}")" || exit 5
    reread_args+=("${REPO}#${num}" "$num" "$title" "$author" "$wait_kind" "$since" "$wait_d" "$ruling" "$pr" "${F_refs[$ix]:-}")
    continue
  fi
  created="${F_created[$ix]}"
  cts="$(date -u -d "$created" +%s 2>/dev/null || echo "$now")"
  age_h=$(( (now - cts) / 3600 ))
  author="$(lazy "${F_author[$ix]}")" || exit 5
  cand_args+=("$num" "$age_h" "$title" "$author" "$kind" "${F_fwd[$ix]:-0}")
done
# The selections, built once from the walk's rows (the per-row `--argjson` reads are `fromjson`
# here). Each value rides as an `x`-prefixed positional, so a leading `-` is never an option.
rows_json() { # <width> <jq object over the row .[0..]> <values…>
  local w="$1" obj="$2"; shift 2
  [ $# -gt 0 ] || { printf '[]'; return 0; }
  jq -nc --argjson w "$w" "\$ARGS.positional | map(.[1:]) | [range(0; length; \$w) as \$k | .[\$k:\$k + \$w] | $obj]" --args "${@/#/x}"
}
cands="$(rows_json 6 '{number: (.[0] | fromjson), age_h: (.[1] | fromjson), author: .[3], title: .[2], kind: .[4]}
    + ((.[5] | fromjson) as $f | if $f > 0 then {forwards: $f} else {} end)' \
  ${cand_args[@]+"${cand_args[@]}"})"
# `_refs` (the numbers the comment that dates the wait names — `#<n>`, `blocked-on: issue|pr=<n>`) is the
# ledger's input below, never part of the row the sitting reads
rereads="$(rows_json 10 '{id: .[0], kind: "reread", number: (.[1] | fromjson), title: .[2], author: .[3], wait: .[4],
  since: .[5], wait_d: (.[6] | fromjson), parked_by: .[7]} + (if .[8] == "" then {} else {pr: (.[8] | fromjson)} end)
  + {_refs: (.[9] | split(" ") | map(select(. != "") | tonumber))}' ${reread_args[@]+"${reread_args[@]}"})"

if [ "$SOURCE" = pile ]; then
  dmax="${INTAKE_DAILY_MAX:-2}"; every="${INTAKE_REREAD_EVERY_D:-7}"
  ts_probe
  receipts="$(read_receipts "$now" "$every")"
  # re-read in the last $every days: an APPLY receipt lists the id with an outcome other than deferred —
  # UNLESS a target the wait names (`_refs`) closed or merged after the newest such receipt: the fact the
  # `unchanged` tested has moved since, so the receipt no longer hides it. Only the hidden waits' targets
  # are read (ref_states, one batched call; none when nothing hidden names one).
  # shellcheck disable=SC2016  # a jq program, not a shell expansion
  JQ_LASTREAD='def lastread($r): [ $r[] | select(.schema == "island-intake-receipt/v1" and .mode == "apply")
      | ((.ts // "") | (try fromdateiso8601 catch 0)) as $t | select($t >= ($now - $every * 86400))
      | .ruled[]? | select(.outcome != "deferred") | {id: .input, t: $t} ] | group_by(.id) | map({(.[0].id): (map(.t) | max)}) | add // {};'
  hidden_refs="$(jq -rn --argjson now "$now" --argjson every "$every" --argjson rereads "$rereads" \
      --slurpfile r <(printf '%s' "$receipts" | grep -v '^$' || true) "$JQ_LASTREAD"'
    lastread($r) as $lr | [ $rereads[] | select($lr[.id] != null) | ._refs[] ] | unique | .[]')" \
    || { echo "intake-select: re-read ledger jq failed" >&2; exit 2; }
  # shellcheck disable=SC2086  # one number per word
  prefs="$(ref_states $hidden_refs)" || exit 2
  sel="$(jq -n --arg island "$ISLAND" --arg repo "$REPO" --arg today "$(date -u -d "@$now" +%Y-%m-%d)" \
      --argjson now "$now" --argjson every "$every" --argjson age "$REREAD_AGE_D" --argjson dmax "$dmax" \
      --arg ts "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" --argjson cands "$cands" --argjson rereads "$rereads" --argjson refs "$prefs" \
      --slurpfile r <(printf '%s' "$receipts" | grep -v '^$' || true) "$JQ_RECEIPTS $JQ_LASTREAD"'
    lastread($r) as $lr
    | [ $rereads[] | . as $w
        | ([ ._refs[] | tostring | . as $n | ($refs[$n] // {}) | select(.state == "CLOSED" or .state == "MERGED")
             | select(((.closed_at // "") | (try fromdateiso8601 catch 0)) > ($lr[$w.id] // 0))
             | {target: ($n | tonumber), target_state: .state, target_closed_at: .closed_at, why: "closed after the last re-read"} ] | first) as $moved
        | select($lr[.id] == null or $moved != null)
        | del(._refs) + (if $lr[.id] != null then {stale: $moved} else {} end) ] as $rr
    | ($rereads | map(del(._refs))) as $rereads
    | ([ $cands[] | {id: ($repo + "#" + (.number | tostring))} + . ] + $rr) as $inputs
    | {schema: "island-intake-select/v1", island: $island, source: "pile", ts: $ts,
       counts: {members: ($cands | length), rereads: ($rr | length), reread_recent: (($rereads | length) - ($rr | length)),
                inputs: ($inputs | length)},
       reread_age_d: $age, reread_every_d: $every, sittings_today: sittings($r; $today), daily_max: $dmax, inputs: $inputs}')" \
    || { echo "intake-select: selection jq failed" >&2; exit 2; }
  if [ -n "$OUT" ]; then printf '%s\n' "$sel" > "$OUT"; else printf '%s\n' "$sel"; fi
  printf '%s' "$sel" | jq -r '.inputs[] | "\(.id)\t\(.kind)\t\(if .kind == "reread" then "\(.wait) \(.wait_d)d" else "\(.age_h)h" end)\t\(.title | .[0:70])"' >&2
  n="$(printf '%s' "$sel" | jq '.counts.inputs')"; sittings="$(printf '%s' "$sel" | jq '.sittings_today')"
  if [ "$n" -eq 0 ]; then
    echo "hold: nothing in island $ISLAND's pile to rule or re-read ($(printf '%s' "$sel" | jq -c .counts))" >&2; exit 1
  elif [ "$sittings" -ge "$dmax" ]; then
    echo "hold: daily cap — $sittings apply sitting(s) today (INTAKE_DAILY_MAX=$dmax); $n input(s) wait for tomorrow" >&2; exit 1
  fi
  echo "fire: $n pile input(s) for island $ISLAND ($(printf '%s' "$sel" | jq -c .counts))" >&2; exit 0
fi

n="$(printf '%s' "$cands" | jq 'length')"
oldest="$(printf '%s' "$cands" | jq '[.[].age_h] | max // 0')"
if [ "$JSON" = 1 ]; then
  printf '%s\n' "$cands" | jq .
else
  printf '%s' "$cands" | jq -r '.[] | "\(.number)\t\(.age_h)h\t\(.author)\t\(.title)\(if .kind == "attribution" then "\tattribution" else "" end)"'
fi
if [ "$n" -ge "$MIN" ]; then
  echo "fire: $n unruled $ISLAND issues (min $MIN)" >&2; exit 0
elif [ "$n" -gt 0 ] && [ "$oldest" -ge "$AGE_H" ]; then
  echo "fire: oldest unruled $ISLAND issue is ${oldest}h (≥ ${AGE_H}h)" >&2; exit 0
else
  echo "hold: $n unruled $ISLAND issues, oldest ${oldest}h" >&2; exit 1
fi
