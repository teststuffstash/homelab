#!/bin/bash
# meta-watch-loop — liveness-aware watch of the ACTIVE agent loop (sleep stack, router live test).
# Emits ONLY on change: scan-tick summaries, agent pod lifecycle, PR review/commit state, stalls,
# proxy auth-circuit events. Override STACK_NS/RIDE_NS/REPO to point at another stack.
# Lessons wired in (2026-08-02): a redispatched ride pod REUSES its name — key pod state on
# startTime, not name; a ride nearing its 4h key/deadline window is a failure signal, not calm;
# an armed PR sitting BEHIND >15min means the updater backstop failed (FU-124).
cd /workspace/homelab || { echo "PROBE-FAIL: repo missing"; exit 1; }
K="devbox run -- kubectl --kubeconfig tofu/kubeconfig"
STACK_NS="${STACK_NS:-sleep-agents}"; RIDE_NS="${RIDE_NS:-sleep-tracking}"
REPO="${REPO:-teststuffstash/sleep-tracking}"; SCAN_PREFIX="${SCAN_PREFIX:-coordinate-sleep-}"
last_scan=""; last_pods=""; last_pr=""; last_emitted_sum=""; last_scan_seen=$(date +%s)
probe_fails=0; last_keywarn=""; behind_since=0; last_am=""; last_wrongbase=""; last_armed=""; last_loopwarn=""
seen_deaths=""   # pod@startTime@phase keys already judged by the harness-death clause
while true; do
  now=$(date +%s)
  # --- newest scan tick (pod name == workflow name) ---
  # ⚠ BOTH naming schemes, keyed on START TIME (2026-08-06). The cron emits
  # `coordinate-<stack>-<epoch>`; a DOORBELL emits `coordinate-perstack-<rand>`, which carries no
  # digits and so was invisible to the old `${SCAN_PREFIX}[0-9]*` grep. Two consequences, both bad:
  # a doorbell-driven tick never got summarised, and the stall clause below counted only CRON ticks
  # — which `concurrencyPolicy: Forbid` SUPPRESSES whenever a scan pod is already running. So the
  # watch cried STALL precisely when the loop was busiest and healthiest (first false fire 09:18,
  # while a dispatch was mid-flight). A repeating false alarm IS a broken probe.
  wf=$($K get pods -n "$STACK_NS" -o json 2>/dev/null \
       | jq -r '[.items[] | select(.metadata.name | startswith("coordinate"))
                | select(.metadata.name | test("-janitor-") | not)]
                | sort_by(.status.startTime // "") | last | .metadata.name // empty' 2>/dev/null)
  if [ -z "$wf" ]; then
    probe_fails=$((probe_fails+1))
    [ "$probe_fails" -eq 3 ] && echo "PROBE-FAIL x3: cannot list $STACK_NS pods (kubectl/devbox dead — NOT 'no work')"
  else
    probe_fails=0
    if [ "$wf" != "$last_scan" ]; then
      last_scan="$wf"; last_scan_seen=$now
      sleep 45  # let the tick clone + finish writing
      sum=$($K logs -n "$STACK_NS" "$wf" -c main 2>/dev/null \
            | grep -E "actionable|spawn|dispatch|REPORT-ONLY|agent/error|WIP busy|probe FAILED|reaping|blocked|Base:|PREFLIGHT REFUSED" \
            | grep -vE "^time=" | head -8)
      # idle ticks are liveness-only; emit on CHANGE of the report block
      if [ "$sum" != "$last_emitted_sum" ]; then
        echo "scan tick ${wf##*-}: ${sum:-<no summary line — read logs>}"
        last_emitted_sum="$sum"
      fi
    fi
  fi
  # FU-086(2): cron is */30 since 2026-08-02 (edge-primary) — stall = a missed cron + slack.
  # Now that `wf` tracks doorbell ticks too, a genuine 40-min silence means NEITHER edge nor cron
  # produced a scan. A scan pod that is still RUNNING is not silence, so do not alarm on it.
  if [ -n "$wf" ] && [ "$($K get pod -n "$STACK_NS" "$wf" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; then
    last_scan_seen=$now
  fi
  if [ $((now - last_scan_seen)) -gt 2400 ]; then
    echo "STALL: no new ${SCAN_PREFIX}* tick observed in 40 min (last: $last_scan; cron is */30 + edges)"
    last_scan_seen=$now
  fi
  # --- ride/coordinator/reviewer pod lifecycle (startTime in the key: same-name redispatch emits) ---
  pods=$({ $K get pods -n "$RIDE_NS" -l app=agent-session \
             -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}@{.status.startTime}{"\n"}{end}' 2>/dev/null; \
           $K get pods -n "$STACK_NS" --no-headers 2>/dev/null | grep -E '^coordinator-' | awk '$3!="Completed"{print $1"="$3}'; \
           $K get pods -n agent-coordinator --no-headers 2>/dev/null | grep -E '^reviewer-' | awk '$3!="Completed"{print $1"="$3}'; } \
         | sort | tr '\n' ' ')
  if [ "$pods" != "$last_pods" ]; then
    echo "pods: ${pods:-<none>} (was: ${last_pods:-<none>})"
    last_pods="$pods"
  fi
  # --- a ride pod that SUCCEEDED but whose harness DIED (2026-08-06, circles#32 round 1) ---
  # The wrapper handles a harness death gracefully and exits 0, so the pod phase reads `Succeeded`
  # and the lifecycle line above is indistinguishable from a real success. The death is only
  # visible in the AGENT_RUN_STATS json the ride emits as its last words. circles#32 died with
  # goose-32602-truncation after 1757s, banked NOTHING, and read as calm — and because a goal
  # child is held out of C4/C5 by the FU-143 containment, nothing would have re-dispatched it.
  # Emit once per pod+startTime, same key discipline as the lifecycle clause.
  # ⚠ BEST-EFFORT, with a known race: ride pods are garbage-collected minutes after they finish,
  # and this reads the pod's own log. If GC wins, the clause never fires and prints nothing — so
  # its SILENCE is not evidence of a healthy ride. It could not be tested against circles#32's
  # round 1 for exactly this reason (pod already reaped when the clause was written). The DURABLE
  # signal is the `AGENT_STRIKE:` comment the ride posts to its issue, which survives GC; treat
  # this clause as an early warning on top of that, never as the only detector.
  for rp in $($K get pods -n "$RIDE_NS" -l app=agent-session \
      -o jsonpath='{range .items[*]}{.metadata.name}@{.status.startTime}@{.status.phase}{"\n"}{end}' 2>/dev/null); do
    case "$rp" in *@Succeeded|*@Failed) : ;; *) continue ;; esac
    rpod="${rp%%@*}"
    case " $seen_deaths " in *" $rp "*) continue ;; esac
    stats=$($K logs -n "$RIDE_NS" "$rpod" -c agent --tail=40 2>/dev/null | grep -o 'AGENT_RUN_STATS .*' | tail -1)
    if [ -z "$stats" ]; then
      echo "RIDE-PROBE-FAIL: $rpod is terminal but emitted no AGENT_RUN_STATS — read its log by hand, do NOT read this as success"
      seen_deaths="$seen_deaths $rp"
      continue
    fi
    ex=$(printf '%s' "$stats" | sed -n 's/.*"exit_status":"\([^"]*\)".*/\1/p')
    ec=$(printf '%s' "$stats" | sed -n 's/.*"error_class":"\([^"]*\)".*/\1/p')
    # ⚠ The clean value is literally `clean` (agent-finalize). Guarding against "ok"/"success"
    # — neither of which the harness ever emits — made this fire on the FIRST healthy ride it saw
    # (circles#32 r2, exit_status=clean). Match the real vocabulary, and keep the aliases only as
    # tolerance. A watch that cries wolf on every good ride is worse than no watch: it trains the
    # reader to skip exactly the line that will one day be true.
    if [ -z "$ex" ]; then
      echo "RIDE-PROBE-FAIL: $rpod emitted AGENT_RUN_STATS with no exit_status — parser or schema drift, judge the ride by hand"
      seen_deaths="$seen_deaths $rp"; continue
    fi
    case "$ex" in clean|ok|success) ok_exit=1 ;; *) ok_exit=0 ;; esac
    if [ "$ok_exit" = "0" ]; then
      echo "RIDE DIED (pod phase says ${rp##*@}): $rpod exit_status=$ex error_class=${ec:-none} — nothing may have been banked; a goal child will NOT self-redispatch (FU-143 containment), re-queue it by hand"
    fi
    seen_deaths="$seen_deaths $rp"
  done
  # --- ride age vs its REAL bound: the session key TTL and activeDeadlineSeconds are both 4h ---
  # ⚠ FIXED 2026-08-07: this warned "expires at 2h" and fired at 100min. That constant was WRONG —
  # circles-issue-42-round-1 carried expiresAt 4h after start, matching activeDeadlineSeconds=14400.
  # The false alarm cost a real investigation, and worse, it pointed AWAY from the actual fault:
  # that ride was not near a key death, it had been in a degenerate repetition loop since minute 10.
  # So the age threshold moved to 3h (still ahead of the 4h reap, no longer crying at 100min) and a
  # SEPARATE clause below watches for the thing age cannot see.
  ride_start=$($K get pods -n "$RIDE_NS" -l app=agent-session \
      -o jsonpath='{.items[0].status.startTime}' 2>/dev/null)
  if [ -n "$ride_start" ]; then
    age=$(( now - $(date -d "$ride_start" +%s 2>/dev/null || echo "$now") ))
    if [ "$age" -gt 10800 ] && [ "$last_keywarn" != "$ride_start" ]; then
      echo "RIDE-AGE: ride started $ride_start is ${age}s old — session key + activeDeadline both 4h; no PR yet means a deadline reap is near"
      last_keywarn="$ride_start"
    fi
  fi
  # --- degenerate repetition: a ride can be DEAD while its pod reads Running (agent-runtime#13) ---
  # circles#42 r1 looped one line 65× from minute 10 to the 4h deadline — phase Running throughout,
  # so every liveness view called it healthy while it held a WIP slot and ~5Gi of kata memory.
  # Cheap proxy: the last 40 log lines collapsing to almost no distinct content.
  for rp in $($K get pods -n "$RIDE_NS" -l app=agent-session --no-headers 2>/dev/null \
                | awk '$3=="Running"{print $1}'); do
    tail40=$($K logs -n "$RIDE_NS" "$rp" -c agent --tail=40 2>/dev/null)
    [ -n "$tail40" ] || continue
    # Nix closure warm-up ("copying path '/nix/store/…'") is 40 lines that differ ONLY in the
    # store hash — the digit-strip normalizer collapses them to ~2 distinct and false-fired on a
    # healthy 3-min-old pod (2026-08-08, homelab#164 ride). Distinct progress, not repetition —
    # drop them before counting; a pod emitting ONLY those is bootstrapping, not looping.
    tail40=$(printf '%s\n' "$tail40" | grep -v "^copying path ")
    [ -n "$tail40" ] || continue
    distinct=$(printf '%s\n' "$tail40" | sed 's/[0-9]//g' | sort -u | wc -l)
    if [ "${distinct:-99}" -le 3 ] && [ "$last_loopwarn" != "$rp" ]; then
      echo "RIDE-LOOPING: $rp last 40 log lines collapse to ${distinct} distinct — degenerate repetition (agent-runtime#13); pod reads Running but is not progressing"
      last_loopwarn="$rp"
    fi
  done
  # --- Alertmanager firing set (AWARENESS only — the responder owns triage; this exists because
  #     dedup'd repeat fingerprints never re-escalate, so the meta session was blind to a live
  #     symptom unless the operator pasted it, 2026-08-02 egress-drop) ---
  am=$(curl -fsS --max-time 10 "${AM_URL:-http://192.168.40.14:9093}/api/v2/alerts?active=true&silenced=false&inhibited=false" 2>/dev/null \
       | jq -r '[.[].labels.alertname | select(. != "InfoInhibitor")] | unique | if length==0 then "NONE" else join(",") end')
  if [ -z "$am" ] && [ "$last_am" != "PROBE_FAILED" ]; then
    echo "PROBE-FAIL: Alertmanager unreachable (firing-set clause blind)"; last_am="PROBE_FAILED"
  elif [ -n "$am" ] && [ "$am" != "$last_am" ]; then
    echo "ALERTS firing set changed: [${am}] (was: [${last_am:-<none>}]) — check responder verdict before hand-triage"
    last_am="$am"
  fi
  # --- proxy auth-circuit events (rare, always actionable) ---
  circ=$($K -n agent-egress logs deploy/openrouter-proxy --since=3m 2>/dev/null | grep -E 'circuit OPEN|circuit.*close' | head -3)
  [ -n "$circ" ] && echo "PROXY: $circ"
  # --- open-PR set (jail PAT pool, ~30 req/h) + FU-124 armed-BEHIND clause ---
  pr=$(gh pr list --repo "$REPO" --state open \
        --json number,mergeStateStatus,reviewDecision,labels,baseRefName,headRefName,autoMergeRequest 2>/dev/null \
        | jq -c '[.[] | {n:.number, m:.mergeStateStatus, rd:.reviewDecision, b:.baseRefName, h:.headRefName, am:(.autoMergeRequest!=null), l:[.labels[].name]}]')
  if [ -z "$pr" ]; then
    echo "PROBE-FAIL: gh pr list returned nothing"
  else
    [ "$pr" != "$last_pr" ] && { echo "open PRs: $pr"; last_pr="$pr"; }
    # --- BASE_EXPECT: a stack whose RIDE work must land on a NON-default branch (circles' woven
    #     spec contract, 2026-08-05). The launcher forks the clone from the declared base, but
    #     "open the PR against it" is recipe PROSE — `gh pr create` with no --base silently
    #     targets the repo default and drags the whole base branch into the diff. Scoped to ride
    #     heads (BASE_HEADS, default ^(agent|fix)/) so the human-gated research/* PRs stay quiet.
    #     ⚠ ^agent/ ALONE IS WRONG (my bug, 2026-08-05): the launcher only falls back to
    #     agent/<ts>; the RECIPES name their branch fix/<slug>, so every real ride PR today —
    #     circles fix/bake-and-page-p0-mvp, openrouter-operator fix/issue-14-rbac-delete — was
    #     invisible to this clause. A guard scoped to the branch name the rides do not use.
    #     ⚠ `major/awaiting-human` is EXCLUDED (2026-08-06, goal #29's bootstrap): a PR the loop is
    #     forbidden to touch cannot be a ride that drifted. circles#21 — the FROZEN one-shot
    #     benchmark arm of goal #17, based on `goal/17-p0-mvp` — matched `^fix/` and a stale
    #     BASE_EXPECT forever, so every future drift would have arrived bundled with a permanent
    #     false member. That is the noise-floor shape, not a widened guard: the label is the marker
    #     for "human-reserved, out of the loop's reach", and a drift on such a PR is not actionable
    #     by this session anyway. A REAL ride never carries it (only `unarmed-major` applies it).
    if [ -n "${BASE_EXPECT:-}" ]; then
      wrong=$(jq -c --arg b "$BASE_EXPECT" --arg hp "${BASE_HEADS:-^(agent|fix)/}" \
                '[.[] | select((.h|test($hp)) and .b != $b and ((.l|index("major/awaiting-human"))|not))]' <<<"$pr")
      if [ "$wrong" != "[]" ] && [ "$wrong" != "$last_wrongbase" ]; then
        echo "BASE DRIFT: open PR(s) NOT based on '$BASE_EXPECT': $wrong — a ride ignored --base; close/retarget before it merges"
        last_wrongbase="$wrong"
      fi
      # ⚠ Armed-per-se is NOT the hazard any more (2026-08-05, the goal lane): a child ride
      # SHOULD arm into `goal/**` — that prefix is what carries the tofu ruleset, and C9 arms on
      # it deliberately. Warning on every armed ride would fire on the happy path all day, and a
      # repeating false alarm IS a broken probe. The hazard is arming into the WRONG base: an
      # unprotected branch merges ON OPEN. So: armed AND base-drifted.
      armed=$(jq -c --arg b "$BASE_EXPECT" --arg hp "${BASE_HEADS:-^(agent|fix)/}" \
                '[.[] | select(.am == true and (.h|test($hp)) and .b != $b) | {n:.n, b:.b}]' <<<"$pr")
      if [ "$armed" != "[]" ] && [ "$armed" != "$last_armed" ]; then
        echo "AUTO-MERGE ARMED on a PR NOT based on '$BASE_EXPECT': $armed — it will merge into that base; disarm/retarget NOW"
        last_armed="$armed"
      fi
    fi
    # The backstop only owns PRs something is trying to MERGE: an armed one, or a ride head whose
    # arm is still pending. An APPROVED-but-unarmed research/* PR sitting BEHIND is a human gate
    # doing its job, not a missed update — circles' four issue-1 arms tripped this every 15 min
    # on 2026-08-05 until the predicate was scoped (a repeating false alarm IS a broken probe).
    if jq -e --arg hp "${BASE_HEADS:-^(agent|fix)/}" \
         '.[] | select(.m=="BEHIND" and .rd=="APPROVED" and (.am == true or (.h|test($hp))))' \
         >/dev/null 2>&1 <<<"$pr"; then
      [ "$behind_since" -eq 0 ] && behind_since=$now
      if [ $((now - behind_since)) -gt 900 ]; then
        echo "FU-124: an APPROVED PR has sat BEHIND >15min — the updater backstop likely missed; dispatch it by hand"
        behind_since=$now
      fi
    else
      behind_since=0
    fi
  fi
  sleep 90
done
