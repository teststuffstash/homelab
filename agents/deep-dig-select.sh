#!/usr/bin/env bash
# deep-dig-select — the deterministic half of the grouped deep dig (ADR-148 (3), FU-249 step 4).
#
#   bash agents/deep-dig-select.sh select [--out /tmp/dig.json]   # the digest: what to dig, grouped
#   DIG_DIGEST=/tmp/dig.json bash agents/deep-dig-select.sh harvest <session-log> <outdir>   # finding blocks → files
#
# WHY A SEPARATE SCRIPT. The responder (agents/coordinator/responder-argo.yaml) is per-fingerprint
# and real-time, and the 2026-10-03 audit (docs/spikes/responder-week-audit.md §2026-10-03) found
# that every real win of the paused week was a STANDING alert the seat had seen for days, each
# needing 20–50 tool calls — a shape a per-fire session cannot pay for and a 12/day budget cannot
# afford. ADR-148 splits the lane: `triage: now` stays per-fingerprint, `triage: dig` goes to THIS
# — a scheduled, GROUPED investigation (agents/coordinator/deep-dig-argo.yaml runs it daily). The
# selection is deterministic shell so it is replayable (agents/deep-dig-test.sh) and so the LLM
# never decides what it looks at (ADR-094: the shell selects, the model judges).
#
# WHAT `select` DOES, in order:
#   1. CANDIDATES — every firing Alertmanager alert with `triage: dig` that has STOOD for
#      ≥ DIG_STANDING_H hours, plus every alertname that fired on ≥ DIG_RECUR_DAYS of the last
#      DIG_LOOKBACK_D days (Prometheus's ALERTS series, one instant read per day) — recurrence counts
#      even when it is quiet right now. A stock-chart name has no `triage` label in Prometheus (the
#      relabel map adds it at SEND time), so a Prometheus-only candidate's triage is resolved from
#      argocd/platform/values/kube-prometheus-stack-triage.yaml exactly as Alertmanager would see it.
#   2. SUBJECT — the responder's own cascade, EXTRACTED from responder-argo.yaml at run time (the
#      `>>>REPLAY:responder-subject>>>` block), never transcribed: one home for "what is this alert
#      about", and the responder's fixtures pin it.
#   3. EXPLAINED — a candidate is dropped (and RECORDED as dropped, with the reason) when something
#      already owns it: a declared seat window naming the alert (FU-230 leg b), an OPEN issue in the
#      org whose title names the alert, an OPEN follow-up item (docs/follow-ups.md) or the seat's
#      meta-state naming it, or a dig finding for the same (alert, subject) within DIG_REDIG_DAYS.
#      "Not explained by an FU/issue/meta-state" is the ADR's own wording.
#   4. GROUPED by ONSET and HOST — the two correlation keys the audit named: alerts that started in
#      the same DIG_ONSET_BUCKET_MIN window on the same node/instance are one story. A recurring,
#      currently-quiet alert groups under onset "recurring". At most DIG_MAX_GROUPS groups go to the
#      session (largest, then longest-standing, first); the rest are listed as deferred.
#
# OUTPUT: one JSON digest (`deep-dig-digest/v1`) on --out (default stdout), plus a human summary
# on stderr. Rule #6 throughout — an unreadable Alertmanager is a loud exit 1, never an empty
# candidate set; an unreadable Prometheus day, window record, search or docs grep degrades to
# "no evidence of an explanation" (the direction that costs one more look, never a dropped alert).
#
# SEAMS (for agents/deep-dig-test.sh and for a jail run): every outside read has an env override
# that serves a FILE instead — DIG_AM_FILE (the Alertmanager /api/v2/alerts array), DIG_PROM_DAY_DIR
# (day-0.json … day-N.json, each a Prometheus instant-query result), DIG_WINDOW_FILE (the
# responder-window ConfigMap JSON), DIG_PRIOR_FILE (a JSON array of earlier dig findings). `gh` is
# reached through PATH, so a stub serves it. Nothing here mutates anything.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIG_REPO="${DIG_REPO:-$(cd "$HERE/.." && pwd)}"
ORG="${ORG:-teststuffstash}"
DIG_AM_URL="${DIG_AM_URL:-http://kube-prometheus-stack-alertmanager.monitoring.svc:9093}"
DIG_PROM_URL="${DIG_PROM_URL:-http://kube-prometheus-stack-prometheus.monitoring.svc:9090}"
DIG_STANDING_H="${DIG_STANDING_H:-6}"
DIG_RECUR_DAYS="${DIG_RECUR_DAYS:-3}"
DIG_LOOKBACK_D="${DIG_LOOKBACK_D:-7}"
DIG_ONSET_BUCKET_MIN="${DIG_ONSET_BUCKET_MIN:-60}"
DIG_MAX_GROUPS="${DIG_MAX_GROUPS:-4}"
DIG_REDIG_DAYS="${DIG_REDIG_DAYS:-7}"
DIG_NOW="${DIG_NOW:-$(date -u +%s)}"   # pinned by the test so onset buckets and ages are stable
RESPONDER_YAML="${RESPONDER_YAML:-$DIG_REPO/agents/coordinator/responder-argo.yaml}"
TRIAGE_MAP="${TRIAGE_MAP:-$DIG_REPO/argocd/platform/values/kube-prometheus-stack-triage.yaml}"

for t in jq sed awk; do command -v "$t" >/dev/null 2>&1 || { echo "deep-dig-select: needs $t" >&2; exit 2; }; done

# ── the subject cascade, straight out of the responder manifest ──────────────────────────────────
# The block sits inside a YAML block scalar at a fixed 14-space indent (the per-alert loop body);
# strip exactly that and the shell underneath is the shipped one. It reads $a (the alert JSON),
# $NAME and $FP, and prints `→ NAME (FP): subject=…` which is discarded here — SUBJ is the value.
SUBJECT_BLOCK="$(sed -n '/>>>REPLAY:responder-subject>>>/,/<<<REPLAY:responder-subject<<</p' "$RESPONDER_YAML" 2>/dev/null | sed 's/^              //')"
[ -n "$SUBJECT_BLOCK" ] || { echo "deep-dig-select: could not extract the responder-subject block from $RESPONDER_YAML" >&2; exit 2; }
dig_subject() { # <alert-json> → "<subject>\t<host>"
  local a="$1" NAME FP SUBJ host=""
  NAME="$(printf '%s' "$a" | jq -r '.labels.alertname // "unknown-alert"')"
  FP="$(printf '%s' "$a" | jq -r '.fingerprint // "-"')"
  eval "$SUBJECT_BLOCK" >/dev/null 2>&1
  # The HOST, by the cascade's own reporter rules (its helpers are in scope after the eval): a
  # node label, else an `instance` that names a host — never a reporter's own address (kube-
  # state-metrics' pod IP would otherwise make every object-level alert "one host").
  if [ -n "${_node:-}" ]; then host="$_node"
  elif [ -n "${_inst:-}" ] && { ! _reporter_target || _instance_is_host; }; then host="${_inst%:*}"
  else host="cluster"; fi
  printf '%s\t%s' "${SUBJ:-alert:$NAME}" "$host"
}

# ── triage resolution for a label set Prometheus holds (no relabel applied yet) ─────────────────
# Alertmanager's view = the rule's own label, else the relabel map's first match for
# `<triage>;<alertname>[;<severity>]` with an EMPTY triage (fill-if-empty, severity-specific lines
# first — the map's own contract). Absent everywhere ⇒ "" (an unlabelled stack rule: nobody's).
dig_triage() { # <alertname> <severity> <label-triage>
  [ -n "${3:-}" ] && { printf '%s' "$3"; return; }
  [ -f "$TRIAGE_MAP" ] || return 0
  local hit
  hit="$(grep -E "regex: ';$1;$2'" "$TRIAGE_MAP" | head -1 | sed -E 's/.*replacement: ([a-z]+).*/\1/')"
  [ -n "$hit" ] || hit="$(grep -E "regex: ';$1'" "$TRIAGE_MAP" | head -1 | sed -E 's/.*replacement: ([a-z]+).*/\1/')"
  printf '%s' "$hit"
}

# ── the reads, each with its file seam ───────────────────────────────────────────────────────────
dig_fetch_am() {
  if [ -n "${DIG_AM_FILE:-}" ]; then cat "$DIG_AM_FILE"; return; fi
  curl -fsS --max-time 15 "$DIG_AM_URL/api/v2/alerts?active=true&silenced=false&inhibited=false"
}
dig_fetch_prom_day() { # <k days ago> → the instant result at (now - k d) of every alert firing in that day
  if [ -n "${DIG_PROM_DAY_DIR:-}" ]; then
    [ -f "$DIG_PROM_DAY_DIR/day-$1.json" ] && cat "$DIG_PROM_DAY_DIR/day-$1.json"; return
  fi
  curl -fsS --max-time 20 -G "$DIG_PROM_URL/api/v1/query" \
    --data-urlencode 'query=max_over_time(ALERTS{alertstate="firing"}[1d])' \
    --data-urlencode "time=$(( DIG_NOW - $1 * 86400 ))"
}
dig_window_json() {
  if [ -n "${DIG_WINDOW_FILE:-}" ]; then cat "$DIG_WINDOW_FILE" 2>/dev/null; return; fi
  kubectl -n agent-coordinator get cm responder-window -o json 2>/dev/null
}
dig_prior_findings() { # a JSON array of earlier harvested dig findings (members, ts, verdict) — empty when unreadable
  if [ -n "${DIG_PRIOR_FILE:-}" ]; then cat "$DIG_PRIOR_FILE" 2>/dev/null; return; fi
  [ -n "${AGENT_TS_READER_ID:-}" ] && command -v s5cmd >/dev/null 2>&1 || return 0
  local d k tmp; tmp="$(mktemp -d)"
  for k in $(seq 0 "$DIG_REDIG_DAYS"); do
    d="$(date -u -d "@$(( DIG_NOW - k * 86400 ))" +%Y-%m-%d)"
    AWS_ACCESS_KEY_ID="$AGENT_TS_READER_ID" AWS_SECRET_ACCESS_KEY="$AGENT_TS_READER_SECRET" AWS_REGION=garage \
      s5cmd --endpoint-url "${AGENT_TS_ENDPOINT:-http://garage.garage.svc.cluster.local:3900}" \
        cp "s3://${AGENT_TS_BUCKET:-agent-transcripts}/homelab/dig-$d/*/finding-*.json" "$tmp/$d/" >/dev/null 2>&1 || true
  done
  find "$tmp" -name 'finding-*.json' -exec cat {} + 2>/dev/null | jq -s '.' 2>/dev/null
  rm -rf "$tmp"
}

# ── the explanation ledger ───────────────────────────────────────────────────────────────────────
# Each returns the explanation (one short string) on stdout, nothing when none applies.
explain_window() { # <alertname>
  printf '%s' "$WINDOWS" | jq -r --arg n "$1" '[ .[] | select((.alerts // []) | index($n)) ] | first | if . == null then "" else "window \(.id) (\(.reason))" end' 2>/dev/null
}
explain_issue() { # <alertname> <subject> — an OPEN issue anywhere in the org that names the alert AND its object
  # Org-wide, because the responder routes by fix surface and the record may sit in another repo.
  # The object token is the subject's last component (`node:hp-01` → hp-01, `workload:ns/x` → x,
  # `instance:ip:port` → ip); a per-class subject (`alert:<name>`) has none, so the title alone
  # decides. An issue about the SAME alert on ANOTHER object is a different record — not explained.
  local tok="${2#*:}"
  case "$2" in alert:*) tok="";; instance:*) tok="${tok%:*}";; *) tok="${tok##*/}";; esac
  gh search issues --owner "$ORG" "$1" --match title --state open --json repository,number,title,body --limit 10 2>/dev/null \
    | jq -r --arg n "$1" --arg t "$tok" '
        [ .[] | select((.title // "") | contains($n))
              | select($t == "" or (((.title // "") + "\n" + (.body // "")) | contains($t))) ]
        | first | if . == null then "" else "issue \(.repository.nameWithOwner)#\(.number)" end' 2>/dev/null
}
explain_fu() { # <alertname> — an OPEN follow-up item mentioning the alert by name
  [ -f "$DIG_REPO/docs/follow-ups.md" ] || return 0
  awk -v n="$1" '
    /^- \[ \] \*\*FU-[0-9]+\*\*/ { match($0, /FU-[0-9]+/); id = substr($0, RSTART, RLENGTH) }
    /^- \[x\] / || /^## / { id = "" }
    id != "" && index($0, n) { print "follow-up " id; exit }' "$DIG_REPO/docs/follow-ups.md"
}
explain_meta() { # <alertname>
  [ -f "$DIG_REPO/docs/agents/meta-state.md" ] || return 0
  grep -qF "$1" "$DIG_REPO/docs/agents/meta-state.md" 2>/dev/null && printf 'meta-state'
}
explain_prior() { # <alertname> <subject>
  # The key is the finding's `members` — [{alertname, subject}], stamped by `harvest` from the
  # run's OWN digest (the shell's key, never the session's prose). A finding harvested before the
  # stamp existed (pre-2026-10-09) has only the session's `alerts` strings, "<alertname> (<subject>)"
  # per the brief — parsed as the fallback so the already-stored week still dedups. The gate
  # matched a top-level .alertname/.subject no harvested record ever carried, so the same group
  # was re-dug daily (2026-10-06…09) while the fixture fed the never-produced shape.
  printf '%s' "$PRIOR" | jq -r --arg n "$1" --arg s "$2" --argjson cut "$(( DIG_NOW - DIG_REDIG_DAYS * 86400 ))" '
    def keys_of: if (.members | type) == "array" and (.members | length) > 0 then .members
      else [ (.alerts // [])[]? | strings | capture("^(?<alertname>[^ (]+) \\((?<subject>.*)\\)$")? ] end;
    [ .[]? | select(type == "object") | select(keys_of | any(.alertname == $n and .subject == $s))
      | select(((.ts // "") | if . == "" then 0 else (fromdateiso8601? // 0) end) > $cut) ]
    | first | if . == null then "" else "dug \(.ts) (\(.verdict // "?"))" end' 2>/dev/null
}

# ── select ───────────────────────────────────────────────────────────────────────────────────────
cmd_select() {
  local OUT="" ; while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift 2;; *) echo "deep-dig-select: unknown arg $1" >&2; exit 2;; esac; done
  local AM; AM="$(dig_fetch_am)" || { echo "PROBE_FAILED: Alertmanager unreadable ($DIG_AM_URL) — no digest, that is itself the finding" >&2; exit 1; }
  printf '%s' "$AM" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo "PROBE_FAILED: Alertmanager returned no alert array" >&2; exit 1; }

  # Days-present per alertname over the lookback, and the freshest label set per name.
  local k DAYS='{}' LATEST='{}' day
  for k in $(seq 0 $(( DIG_LOOKBACK_D - 1 ))); do
    day="$(dig_fetch_prom_day "$k" 2>/dev/null)" || day=""
    [ -n "$day" ] || { echo "note: Prometheus day -$k unreadable — recurrence under-counted for that day" >&2; continue; }
    DAYS="$(jq -n --argjson d "$DAYS" --argjson r "$day" '
      ($r.data.result // []) | map(.metric.alertname) | unique
      | reduce .[] as $n ($d; .[$n] = ((.[$n] // 0) + 1))')"
    LATEST="$(jq -n --argjson l "$LATEST" --argjson r "$day" '
      ($r.data.result // []) | map(.metric) | reduce .[] as $m ($l; if .[$m.alertname] then . else .[$m.alertname] = $m end)')"
  done

  WINDOWS="$(dig_window_json | jq -c --arg now "$(date -u -d "@$DIG_NOW" +%Y-%m-%dT%H:%M:%SZ)" \
      '[ (.data // {}) | to_entries[] | (.value | fromjson?) // empty | select((.until // "") > $now) ]' 2>/dev/null || true)"
  [ -n "$WINDOWS" ] || WINDOWS='[]'
  PRIOR="$(dig_prior_findings)"; printf '%s' "$PRIOR" | jq -e 'type == "array"' >/dev/null 2>&1 || PRIOR='[]'

  local tmp; tmp="$(mktemp -d)"; : > "$tmp/cand.jsonl"
  # (1a) firing + standing
  printf '%s' "$AM" | jq -c '.[] | select(.labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor")' \
  | while read -r a; do
      local name tri started age
      name="$(printf '%s' "$a" | jq -r '.labels.alertname')"
      tri="$(printf '%s' "$a" | jq -r '.labels.triage // ""')"
      [ "$tri" = "dig" ] || continue
      started="$(printf '%s' "$a" | jq -r '.startsAt // ""')"
      age=$(( (DIG_NOW - $(date -u -d "$started" +%s 2>/dev/null || echo "$DIG_NOW")) / 3600 ))
      [ "$age" -ge "$DIG_STANDING_H" ] || [ "$(printf '%s' "$DAYS" | jq -r --arg n "$name" '.[$n] // 0')" -ge "$DIG_RECUR_DAYS" ] || continue
      local sh; sh="$(dig_subject "$a")"
      printf '%s' "$a" | jq -c --arg subj "${sh%	*}" --arg host "${sh#*	}" --argjson age "$age" --arg started "$started" \
          --argjson days "$(printf '%s' "$DAYS" | jq -r --arg n "$name" '.[$n] // 0')" \
          '{alertname: .labels.alertname, subject: $subj, host: $host, triage: "dig", severity: (.labels.severity // ""),
            firing: true, standing_h: $age, days_present: $days, startsAt: $started,
            fingerprint: (.fingerprint // ""), labels: .labels, annotations: (.annotations // {})}' >> "$tmp/cand.jsonl"
    done
  # (1b) recurring but quiet now — a name present on enough days with no firing entry above
  local firing_names; firing_names="$(printf '%s' "$AM" | jq -r '[.[].labels.alertname] | unique | .[]')"
  printf '%s' "$DAYS" | jq -r --argjson min "$DIG_RECUR_DAYS" 'to_entries[] | select(.value >= $min) | .key' \
  | while read -r name; do
      case "$name" in Watchdog|InfoInhibitor) continue;; esac
      grep -qxF "$name" <<< "$firing_names" && continue
      local m tri sev
      m="$(printf '%s' "$LATEST" | jq -c --arg n "$name" '.[$n] // {}')"
      sev="$(printf '%s' "$m" | jq -r '.severity // ""')"
      tri="$(dig_triage "$name" "$sev" "$(printf '%s' "$m" | jq -r '.triage // ""')")"
      [ "$tri" = "dig" ] || continue
      local a sh; a="$(jq -nc --argjson m "$m" '{status: "quiet", labels: $m}')"; sh="$(dig_subject "$a")"
      jq -nc --arg name "$name" --arg subj "${sh%	*}" --arg host "${sh#*	}" --arg sev "$sev" --argjson m "$m" \
         --argjson days "$(printf '%s' "$DAYS" | jq -r --arg n "$name" '.[$n] // 0')" \
         '{alertname: $name, subject: $subj, host: $host, triage: "dig", severity: $sev, firing: false, standing_h: 0,
           days_present: $days, startsAt: "", fingerprint: "", labels: $m, annotations: {}}' >> "$tmp/cand.jsonl"
    done

  # (3) explained?
  : > "$tmp/keep.jsonl"; : > "$tmp/expl.jsonl"
  while read -r c; do
    [ -n "$c" ] || continue
    local name subj why
    name="$(printf '%s' "$c" | jq -r '.alertname')"; subj="$(printf '%s' "$c" | jq -r '.subject')"
    why="$(explain_window "$name")"
    [ -n "$why" ] || why="$(explain_prior "$name" "$subj")"
    [ -n "$why" ] || why="$(explain_issue "$name" "$subj")"
    [ -n "$why" ] || why="$(explain_fu "$name")"
    [ -n "$why" ] || why="$(explain_meta "$name")"
    if [ -n "$why" ]; then printf '%s' "$c" | jq -c --arg why "$why" '{alertname, subject, firing, standing_h, days_present, explained_by: $why}' >> "$tmp/expl.jsonl"
    else printf '%s\n' "$c" >> "$tmp/keep.jsonl"; fi
  done < "$tmp/cand.jsonl"

  # (4) group by onset bucket + host, rank, cap
  local bucket=$(( DIG_ONSET_BUCKET_MIN * 60 ))
  jq -sc --argjson b "$bucket" --argjson max "$DIG_MAX_GROUPS" --argjson now "$DIG_NOW" \
     --arg ts "$(date -u -d "@$DIG_NOW" +%Y-%m-%dT%H:%M:%SZ)" --slurpfile expl "$tmp/expl.jsonl" \
     --argjson p "$(jq -n --argjson sh "$DIG_STANDING_H" --argjson rd "$DIG_RECUR_DAYS" --argjson lb "$DIG_LOOKBACK_D" --argjson ob "$DIG_ONSET_BUCKET_MIN" --argjson mg "$DIG_MAX_GROUPS" --argjson rg "$DIG_REDIG_DAYS" \
        '{standing_h: $sh, recur_days: $rd, lookback_d: $lb, onset_bucket_min: $ob, max_groups: $mg, redig_days: $rg}')" '
    def onset: if .firing and .startsAt != "" then
        ((.startsAt | fromdateiso8601? // $now) as $t | (($t / $b) | floor) * $b | todate)
      else "recurring" end;
    map(. + {onset: onset})
    | group_by(.onset + "|" + .host)
    | map({key: (.[0].onset + "|" + .[0].host), onset: .[0].onset, host: .[0].host,
           alerts: (sort_by(-.standing_h, .alertname)),
           max_standing_h: (map(.standing_h) | max)})
    | sort_by(-(.alerts | length), -.max_standing_h, .key)
    | {schema: "deep-dig-digest/v1", ts: $ts, params: $p,
       groups: .[:$max], deferred: (.[$max:] | map({key, alerts: (.alerts | map("\(.alertname) (\(.subject))"))})),
       explained: $expl,
       counts: {candidates: (((map(.alerts | length) | add) // 0) + ($expl | length)),
                unexplained: ((map(.alerts | length) | add) // 0), explained: ($expl | length),
                groups: length, selected: (.[:$max] | length)}}' "$tmp/keep.jsonl" > "$tmp/digest.json" \
  || { echo "deep-dig-select: building the digest FAILED (jq) — no digest written" >&2; rm -rf "$tmp"; exit 1; }
  # Never an empty digest on exit 0: the pod and the harness both read this file, and an empty
  # one read as "nothing to dig" is the silent failure the reviewer caught on PR#2212 (the jq
  # above compiled on jq 1.7 and not on the image's 1.6 — every object value with a trailing
  # binary operator needs its own parentheses there).
  jq -e '.schema == "deep-dig-digest/v1"' "$tmp/digest.json" >/dev/null 2>&1 \
    || { echo "deep-dig-select: the digest is not a deep-dig-digest/v1 document — refusing to emit it" >&2; rm -rf "$tmp"; exit 1; }

  if [ -n "$OUT" ]; then cp "$tmp/digest.json" "$OUT"; else cat "$tmp/digest.json"; fi
  jq -r '"deep-dig: \(.counts.candidates) candidate(s) — \(.counts.unexplained) unexplained in \(.counts.groups) group(s) (\(.counts.selected) selected), \(.counts.explained) explained"
         , (.groups[] | "  group \(.key): " + (.alerts | map("\(.alertname) [\(.subject)] standing \(.standing_h)h, \(.days_present)/7d") | join("; ")))
         , (.explained[] | "  explained \(.alertname) [\(.subject)] ← \(.explained_by)")
         , (.deferred[] | "  deferred \(.key): " + (.alerts | join("; ")))' "$tmp/digest.json" >&2
  rm -rf "$tmp"
}

# ── harvest ──────────────────────────────────────────────────────────────────────────────────────
# The session is told to wrap each group's finding in BEGIN-DIG-FINDING / END-DIG-FINDING lines
# with ONE JSON object between them (`dig-finding/v1`). The shell extracts them, validates the
# shape, stamps `members` from the run's digest (DIG_DIGEST), and writes finding-N.json — the only
# artifact a later selection or the seat reads, so a block that does not parse is dropped loudly
# rather than uploaded as a record.
cmd_harvest() {
  local log="$1" out="$2" n=0 bad=0 blk digest='{}'
  mkdir -p "$out"
  # DIG_DIGEST: the run's own `select` output (the pod's /tmp/dig.json). Each finding is stamped
  # with `members` — the {alertname, subject} pairs of the digest group its `group` key names —
  # the machine key explain_prior dedups on. Unreadable ⇒ no stamp (loud), never a dropped finding.
  if [ -n "${DIG_DIGEST:-}" ] && jq -e '.schema == "deep-dig-digest/v1"' "$DIG_DIGEST" >/dev/null 2>&1; then
    digest="$(jq -c '{groups: [ .groups[]? | {key, alerts: [ .alerts[]? | {alertname, subject} ]} ]}' "$DIG_DIGEST")"
  else
    echo "harvest: no readable digest (DIG_DIGEST=${DIG_DIGEST:-unset}) — findings carry no members key" >&2
  fi
  awk '/^BEGIN-DIG-FINDING/{f=1; next} /^END-DIG-FINDING/{f=0; print "\x1e"; next} f' "$log" \
  | awk -v RS='\x1e' 'NF {print > ("'"$out"'/raw-" NR ".json")}'
  for blk in "$out"/raw-*.json; do
    [ -f "$blk" ] || continue
    if jq -e '.schema == "dig-finding/v1" and (.group | type) == "string" and (.verdict | IN("explained","unexplained","cause-found","fix-proposed"))' "$blk" >/dev/null 2>&1; then
      n=$((n+1))
      jq --arg ts "${DIG_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" --arg run "${DIG_RUN:-}" --argjson d "$digest" \
        '. as $f | . + {ts: $ts, run: $run, members: ([ ($d.groups // [])[] | select(.key == $f.group) | .alerts[] | {alertname, subject} ])}' \
        "$blk" > "$out/finding-$n.json"
      jq -e '.members | length > 0' "$out/finding-$n.json" >/dev/null 2>&1 \
        || echo "harvest: finding-$n's group \"$(jq -r .group "$blk")\" is not a group of the run's digest — no members stamped (re-dig dedup falls back to its alerts strings)" >&2
    else
      bad=$((bad+1)); echo "harvest: a finding block did not validate (schema/group/verdict) — dropped: $(head -c 200 "$blk" | tr '\n' ' ')" >&2
    fi
    rm -f "$blk"
  done
  echo "harvest: $n finding(s) written to $out ($bad dropped)"
  [ "$n" -gt 0 ]
}

case "${1:-}" in
  select)  shift; cmd_select "$@";;
  harvest) shift; [ $# -eq 2 ] || { echo "usage: $0 harvest <session-log> <outdir>" >&2; exit 2; }; cmd_harvest "$@";;
  *) echo "usage: $0 select [--out file] | harvest <log> <outdir>" >&2; exit 2;;
esac
