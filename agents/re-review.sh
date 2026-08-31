#!/usr/bin/env bash
# re-review.sh — sonnet time-travel re-review of Go-served review snapshots (homelab#424, 2026-08-13 ruling)
#
# Purpose: Every Go-served review records an input-state snapshot to S3. After the Anthropic pool
# resets, sonnet re-reviews the EXACT recorded state and verdicts are compared — the model-quality
# evidence channel.
#
# Snapshot layout (s3://agent-transcripts/<project>/<TASK_KEY>/review-state-<headsha8>-<ts>/):
#   pr.json             — gh pr view JSON (number,title,body,headRefOid,baseRefName,state,reviews,comments,files)
#   diff.patch          — gh pr diff
#   head-sha.txt        — the 8-char head sha
#   rubric.sha.txt      — git blob sha of .agents/review.md at review time
#   snapshot-manifest.json — {project,task,pr,round,model,headsha8,timestamp,files}
#
# Usage:
#   bash agents/re-review.sh --project homelab --pr 437 [--since YYYYMMDD] [--dry-run] [--model sonnet] [--shadow]
#
# Flags:
#   --project <p>     Filter to this project (required with --pr)
#   --pr <n>          Filter to this PR number
#   --since YYYYMMDD  Only snapshots after this date (UTC)
#   --dry-run         Do discovery + fetch + assembly, print the claude command + prompt skeleton instead of invoking
#   --model <m>       Model to use for re-review (default: sonnet). Full model id parsed via model_id.py for rail derivation.
#   --shadow          Advisory-only mode: NEVER posts to the PR. Writes report to stdout with shadow-re-review marker.
#
# Idempotency: Posts comparison as PR comment with <!-- re-review:<headsha8>-<ts> --> tag; skips snapshots whose tag already exists.
# PAT trap: Never uses statusCheckRollup in any API call (403s on App installation tokens).
#
# Shadow mode (--shadow): The re-review NEVER posts a verdict, review, or comment to the PR.
# Report is written to stdout with a shadow-re-review marker, model + rail attributed.
# The live reviewer identity split is exactly what the A5 evidence will decide; the shadow
# must not contaminate it.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# This tool IS the sonnet benchmark channel — it must never inherit a claude-go jail's
# rail plumbing. That plumbing is TWO layers, and both must go (live 2026-08-18, one hour
# apart): the shim (ANTHROPIC_BASE_URL) routed "sonnet" to kimi-k3 on the Go rail ($0.17,
# caught on the CONSOLE — the homelab#515 requested≠served class, jail edition), and the
# CLI-side slot map (ANTHROPIC_DEFAULT_*_MODEL) kept resolving --model sonnet to the literal
# id `opencode-go/kimi-k3` even with the shim unset — which api.anthropic.com 404s, so the
# "clean" re-run failed every invocation. Pin the rail: strip both layers; plain claude then
# auths with the seat's own OAuth straight to the API and sonnet means claude-sonnet-5.
unset ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL \
      ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
      ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL

# Defaults
PROJECT=""
PR=""
SINCE=""
DRY_RUN=0
SHADOW=0
MODEL="sonnet"

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2;;
    --pr)      PR="$2"; shift 2;;
    --since)   SINCE="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --shadow)  SHADOW=1; shift;;
    --model)   MODEL="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# --pr requires --project (bot review r3: empty project builds s3://agent-transcripts// → silent vacuous exit)
if [ -n "$PR" ] && [ -z "$PROJECT" ]; then
  echo "re-review: --pr requires --project (the bucket is keyed <project>/<task>/...)" >&2
  exit 2
fi

# Derive rail from model id via model_id.py (ADR-096 §M10 explicit-override semantics).
# The --model flag IS the override — the route call is skipped entirely.
eval "$(python3 "$HERE/model_id.py" --shell "$MODEL")"
# MODEL_RAIL, MODEL_HARNESS, MODEL_MODEL are now set.
# For shadow mode, attribute the rail in the report header.
echo "→ re-review: model=$MODEL rail=$MODEL_RAIL harness=$MODEL_HARNESS resolved=$MODEL_MODEL"

# Pin-by-DECLARATION, not pin-to-anthropic (homelab#946's first run, 2026-08-30): the unset
# block above strips INHERITED plumbing — right for the default sonnet duty, but an explicit
# opencode-rail --model (the A5 shadow instrument, `opencode/big-pickle`) then has no rail at
# all and plain claude 404s it against api.anthropic.com on every snapshot, with stderr
# discarded. For an explicitly-declared opencode/* or opencode-go/* model, the jail shim
# (scripts/claude-model-shim.py — routes by body model id, credential per rail) IS the rail:
# require a live listener and point claude at it deliberately. Fail loudly, never fall back —
# a shadow report silently produced by the wrong model is worse than no report (#515 class).
case "$MODEL" in
  opencode/*|opencode-go/*)
    SHIM_PORT="${SHIM_PORT:-18091}"
    if ! curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${SHIM_PORT}/" 2>/dev/null && \
       ! (exec 3<>"/dev/tcp/127.0.0.1/${SHIM_PORT}") 2>/dev/null; then
      echo "re-review: model $MODEL rides the jail shim and no listener is up on 127.0.0.1:${SHIM_PORT}" >&2
      echo "           start one (scripts/claude-go.sh spawns it, or run scripts/claude-model-shim.py) and retry" >&2
      exit 3
    fi
    export ANTHROPIC_BASE_URL="http://127.0.0.1:${SHIM_PORT}"
    echo "→ re-review: opencode rail — ANTHROPIC_BASE_URL pinned to the jail shim (:${SHIM_PORT})"
    ;;
esac

# Temp dir with cleanup trap
TMPDIR_BASE="${TMPDIR:-/tmp}"
WORK_DIR=$(mktemp -d "${TMPDIR_BASE}/re-review.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

# MAX_ARG_STRLEN = 32 * 4096 = 131072 bytes (argv-guard.sh, homelab#242)
MAX_ARG_LEN=131072
# Leave headroom for the rest of the command line
MAX_PROMPT_LEN=120000

# PAT trap comment: all gh api calls below avoid statusCheckRollup — it 403s on App installation tokens.
# Use reviews + comments + files instead.

echo "→ re-review: discovering snapshots..."

# Step 1: Discover snapshots from S3
if [ -n "$PROJECT" ]; then
  S3_PREFIX="s3://agent-transcripts/${PROJECT}/"
else
  S3_PREFIX="s3://agent-transcripts/"
fi

# List all review-state- prefixes (extract unique directory paths)
# S3 output format: DATE TIME SIZE path/to/file
# Run from REPO_ROOT for devbox context
# BOT REVIEW R4 #5: S3 listing failure → loud error (not vacuous exit)
# Filter out "Info:" lines from devbox output before processing
# `if ! var=$(…)` — under set -e a bare failing assignment exits BEFORE the diagnostics
# below ever run (bot review r5: the r4 guard was dead code).
if ! S3_RAW_OUT="$(cd "$REPO_ROOT" && devbox run garage-s3 s3 ls "$S3_PREFIX" --recursive 2>&1)"; then
  # ($? after `if !` is the negation's 0 — don't report a fake exit code)
  echo "re-review: S3 listing FAILED — garage-s3 creds/endpoint/bucket error; raw output follows" >&2
  echo "$S3_RAW_OUT" >&2
  exit 3
fi
# Strip devbox "Info:" lines and extract review-state- paths
S3_LS_OUT="$(echo "$S3_RAW_OUT" | grep -v '^Info:')"
SNAPSHOT_PATHS="$(echo "$S3_LS_OUT" | grep 'review-state-' | awk '{print $4}' | awk -F'/' '{for(i=1;i<=NF;i++) if($i ~ /^review-state-/) {for(j=1;j<=i;j++) printf "%s", (j>1?"/":"") $j; print ""; next}}' | sort -u)" || true

if [ -z "$SNAPSHOT_PATHS" ]; then
  echo "→ no snapshots found under $S3_PREFIX"
  exit 0
fi

# Apply filters — BOT REVIEW R4 #2: --pr must match manifest .pr field, not S3 task-key
# (agent-loop snapshots key by issue-<N> per reviewer-session.sh:155, not pr-<N>)
FILTERED=""
for path in $SNAPSHOT_PATHS; do
  # Extract project from path
  proj=$(echo "$path" | sed 's|s3://agent-transcripts/||' | cut -d'/' -f1)

  # Filter by project
  if [ -n "$PROJECT" ] && [ "$proj" != "$PROJECT" ]; then
    continue
  fi

  # Fetch manifest FIRST to filter by .pr field (not task-key)
  TEMP_MANIFEST="$WORK_DIR/temp-manifest.json"
  if ! (cd "$REPO_ROOT" && devbox run garage-s3 s3 cp "s3://agent-transcripts/$path/snapshot-manifest.json" "$TEMP_MANIFEST" 2>/dev/null); then
    echo "  WARN: failed to fetch manifest for $path — skipping"
    continue
  fi

  snap_pr=$(jq -r '.pr' "$TEMP_MANIFEST" 2>/dev/null || echo "")

  # Filter by PR (if specified)
  if [ -n "$PR" ] && [ "$snap_pr" != "$PR" ]; then
    continue
  fi

  # Extract timestamp from prefix name for --since filter
  ts_part=$(echo "$path" | sed 's|.*/review-state-[^-]*-||')
  ts_date=$(echo "$ts_part" | sed 's|T.*||;s|-||g')

  # Filter by --since
  if [ -n "$SINCE" ] && [ "$ts_date" -lt "$SINCE" ]; then
    continue
  fi

  FILTERED="$FILTERED $path"
done

if [ -z "$(echo $FILTERED | tr -d ' ')" ]; then
  echo "→ no snapshots match filters (project=$PROJECT pr=$PR since=$SINCE)"
  exit 0
fi

echo "→ found $(echo $FILTERED | wc -w) snapshot(s)"

# Step 2-8: Process each snapshot
for snapshot_path in $FILTERED; do
  echo ""
  echo "=== Processing $snapshot_path ==="

  # Step 2: Fetch snapshot files
  SNAP_DIR="$WORK_DIR/snapshot"
  mkdir -p "$SNAP_DIR"

  echo "→ fetching snapshot files..."
  for f in pr.json diff.patch head-sha.txt rubric.sha.txt snapshot-manifest.json; do
    cd "$REPO_ROOT" && devbox run garage-s3 s3 cp "s3://agent-transcripts/$snapshot_path/$f" "$SNAP_DIR/$f" 2>/dev/null || {
      echo "  WARN: failed to fetch $f"
      : > "$SNAP_DIR/$f"
    }
  done

  # Parse manifest
  if [ ! -s "$SNAP_DIR/snapshot-manifest.json" ]; then
    echo "  SKIP: no manifest"
    continue
  fi

  headsha8=$(jq -r '.headsha8' "$SNAP_DIR/snapshot-manifest.json")
  recorded_model=$(jq -r '.model' "$SNAP_DIR/snapshot-manifest.json")
  snap_pr=$(jq -r '.pr' "$SNAP_DIR/snapshot-manifest.json")
  snap_project=$(jq -r '.project' "$SNAP_DIR/snapshot-manifest.json")
  snap_ts=$(jq -r '.timestamp' "$SNAP_DIR/snapshot-manifest.json")

  echo "  headsha8=$headsha8 model=$recorded_model ts=$snap_ts"

  # BOT REVIEW R4 #1: Incomplete snapshot guard — pr.json and diff.patch may be empty/non-fatal
  # per producer contract (reviewer-session.sh:267-287). If either is empty, skip claude call
  # and mark as INCOMPLETE-SNAPSHOT (no comment posted).
  pr_json_size=$(wc -c < "$SNAP_DIR/pr.json" | tr -d '[:space:]')
  diff_size=$(wc -c < "$SNAP_DIR/diff.patch" | tr -d '[:space:]')
  if [ "$pr_json_size" -eq 0 ] || [ "$diff_size" -eq 0 ]; then
    echo "  INCOMPLETE-SNAPSHOT: pr.json=$pr_json_size bytes, diff.patch=$diff_size bytes — skipping (producer contract allows empty captures)"
    continue
  fi

  # Step 3: Recover recorded verdict from GitHub API
  echo "→ fetching recorded verdict..."
  REVIEWER_LOGIN="homelab-reviewer"

  # BOT REVIEW R4 #4: Add --paginate to reviews fetch (>30 reviews per page)
  # --slurp + flatten: --paginate emits one JSON array PER PAGE — without slurping, jq runs
  # per page and every >30-review PR reads a garbage multi-line verdict (bot review r5).
  reviews_json=$(gh api "/repos/teststuffstash/${snap_project}/pulls/${snap_pr}/reviews" --paginate --slurp 2>/dev/null | jq '[.[][]]' 2>/dev/null || echo "[]")

  # Find review by reviewer bot at/after snapshot timestamp
  snap_iso=$(echo "$snap_ts" | sed 's|\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)T\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)Z|\1-\2-\3T\4:\5:\6Z|')

  recorded_verdict=""
  recorded_body=""

  recorded_verdict=$(echo "$reviews_json" | jq -r --arg login "$REVIEWER_LOGIN" --arg ts "$snap_iso" '
    [.[] | select((.user.login | contains($login)) and (.submitted_at >= $ts)
           and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))]
    | sort_by(.submitted_at)
    | .[0]
    | .state // ""
  ' 2>/dev/null || true)

  recorded_body=$(echo "$reviews_json" | jq -r --arg login "$REVIEWER_LOGIN" --arg ts "$snap_iso" '
    [.[] | select((.user.login | contains($login)) and (.submitted_at >= $ts)
           and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))]
    | sort_by(.submitted_at)
    | .[0]
    | .body // ""
  ' 2>/dev/null || true)

  if [ -z "$recorded_verdict" ] || [ "$recorded_verdict" = "null" ]; then
    echo "  no-recorded-verdict found for this snapshot"
    recorded_verdict="UNKNOWN"
  fi

  echo "  recorded: $recorded_verdict"

  # Step 4: Recover rubric
  echo "→ recovering rubric..."
  rubric_sha=$(cat "$SNAP_DIR/rubric.sha.txt" | tr -d '\n')
  rubric_text=""

  if [ "$rubric_sha" != "no-rubric-file" ] && [ "$rubric_sha" != "hash-failed" ]; then
    rubric_text=$(cd "$REPO_ROOT" && git cat-file blob "$rubric_sha" 2>/dev/null) || {
      echo "  WARN: rubric blob $rubric_sha not found — falling back to current .agents/review.md"
      rubric_text="[RUBRIC DRIFT: using current .agents/review.md instead of snapshot blob]"
      if [ -f "$REPO_ROOT/.agents/review.md" ]; then
        rubric_text="$rubric_text"$'\n\n'"$(cat "$REPO_ROOT/.agents/review.md")"
      else
        rubric_text="$rubric_text"$'\n'"[No .agents/review.md in repo]"
      fi
    }
  else
    echo "  no rubric at snapshot time"
    rubric_text="[No rubric at snapshot time]"
  fi

  # Step 5: Build re-review prompt
  pr_json=$(cat "$SNAP_DIR/pr.json")
  diff_content=$(cat "$SNAP_DIR/diff.patch")

  # Build prompt file
  PROMPT_FILE="$WORK_DIR/prompt.txt"
  cat > "$PROMPT_FILE" <<EOF
You are reviewing a PR snapshot exactly as it appeared at review time. Do NOT fetch anything live — the snapshot is the whole world.

RUBRIC:
$rubric_text

PR STATE (from pr.json):
$(echo "$pr_json" | jq -r '"Pull Request #\(.number): \(.title)\nState: \(.state)\nHead: \(.headRefOid)\nBase: \(.baseRefName)\n\nBody:\n\(.body)"')

PR FILES CHANGED:
$(echo "$pr_json" | jq -r '.files[]?.filename' 2>/dev/null || echo "(no files data)")

FULL DIFF:
$diff_content

---
TASK: Produce a verdict (APPROVE or REQUEST_CHANGES) + your findings.
Format your response as JSON with this structure:
{
  "verdict": "APPROVE" or "REQUEST_CHANGES",
  "findings": "your detailed findings as text"
}
EOF

  prompt_words=$(wc -w < "$PROMPT_FILE")
  prompt_bytes=$(wc -c < "$PROMPT_FILE" | tr -d '[:space:]')
  echo "  prompt: $prompt_words words, $prompt_bytes bytes"

  # BOT REVIEW R4 #6: argv ceiling guard (MAX_ARG_STRLEN = 131072)
  # If prompt exceeds ~120KB, truncate diff section (keep head+tail with marker)
  prompt_truncated=0
  if [ "$prompt_bytes" -gt "$MAX_PROMPT_LEN" ]; then
    echo "  WARN: prompt ($prompt_bytes bytes) exceeds argv ceiling guard ($MAX_PROMPT_LEN) — truncating diff section"
    # Calculate how much to trim from diff
    # Reserve ~2000 bytes for rubric/pr.json overhead + truncation marker
    reserve=2500
    half_avail=$(( (MAX_PROMPT_LEN - reserve) / 2 ))

    # Get diff length and calculate truncation
    diff_bytes=${#diff_content}
    trim_bytes=$(( diff_bytes - (MAX_PROMPT_LEN - prompt_bytes + diff_bytes - reserve) ))
    if [ $trim_bytes -lt 0 ]; then trim_bytes=0; fi

    # Keep head and tail of diff
    head_len=$(( diff_bytes / 2 - trim_bytes / 2 ))
    tail_len=$head_len
    diff_head="${diff_content:0:$head_len}"
    diff_tail="${diff_content: -$tail_len}"
    omitted_bytes=$(( diff_bytes - head_len - tail_len ))

    # Rewrite prompt with truncated diff
    cat > "$PROMPT_FILE" <<EOF
You are reviewing a PR snapshot exactly as it appeared at review time. Do NOT fetch anything live — the snapshot is the whole world.

RUBRIC:
$rubric_text

PR STATE (from pr.json):
$(echo "$pr_json" | jq -r '"Pull Request #\(.number): \(.title)\nState: \(.state)\nHead: \(.headRefOid)\nBase: \(.baseRefName)\n\nBody:\n\(.body)"')

PR FILES CHANGED:
$(echo "$pr_json" | jq -r '.files[]?.filename' 2>/dev/null || echo "(no files data)")

FULL DIFF (truncated — argv ceiling MAX_ARG_STRLEN=131072):
$diff_head

[...diff truncated: $omitted_bytes bytes omitted for the argv ceiling (MAX_PROMPT_LEN=$MAX_PROMPT_LEN)...]

$diff_tail

---
TASK: Produce a verdict (APPROVE or REQUEST_CHANGES) + your findings.
Format your response as JSON with this structure:
{
  "verdict": "APPROVE" or "REQUEST_CHANGES",
  "findings": "your detailed findings as text"
}
EOF
    prompt_truncated=1
    echo "  diff truncated: $omitted_bytes bytes omitted"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "=== DRY-RUN MODE ==="
    # BOT REVIEW R4 #7: Print real invocation (claude -p "<prompt>" not @file)
    echo "Would run:"
    echo "  claude -p \"<prompt content: $prompt_words words, $prompt_bytes bytes>\" --model $MODEL --output-format json"
    [ $prompt_truncated -eq 1 ] && echo "  (prompt would be truncated for argv ceiling)"
    echo ""
    echo "Comparison comment skeleton:"
    echo "<!-- re-review:${headsha8}-${snap_ts} -->"
    echo ""
    echo "## Re-review Comparison"
    echo "| Recorded | Sonnet Re-review |"
    echo "|----------|------------------|"
    echo "| $recorded_model / $recorded_verdict | $MODEL / (pending) |"
    echo ""
    echo "### Sonnet Findings"
    echo "(pending)"
    echo ""
    echo "### Verdict"
    echo "AGREE/DISAGREE/INCOMPARABLE (pending)"
    echo "========================"
    continue
  fi

  # >>>REPLAY:re-review-shadow-skip-tag>>>
  # BOT REVIEW R4 #3: Idempotency check BEFORE claude call (with --paginate, fail loud on gh error)
  idem_tag="<!-- re-review:${headsha8}-${snap_ts} -->"
  # Shadow mode (--shadow) NEVER posts to the PR — the idempotency tag exists to prevent
  # double-posting comments, so there is nothing to guard against. Skip the gate entirely
  # in shadow mode, allowing --shadow --model <X> to re-review a snapshot that already
  # carries a live re-review comment from a different model (homelab#945 — the A5 evidence
  # instrument needs exactly this: divergence measurement against already-landed verdicts).
  if [ "$SHADOW" -eq 0 ]; then
    # Same set -e pattern as the S3 guard (bot review r5): the failure branch must be reachable.
    if ! existing_comments_out="$(gh api "/repos/teststuffstash/${snap_project}/issues/${snap_pr}/comments" --paginate --slurp 2>&1)"; then
      echo "  IDEMPOTENCY-UNKNOWN: gh api comments failed — skipping this snapshot"
      echo "  $existing_comments_out" >&2
      continue
    fi
    existing_comments="$existing_comments_out"
    # Flatten slurped pages first — per-page jq yields "0\n0" on >30-comment PRs, which != "0",
    # silently skipping the snapshot FOREVER (bot review r5, the fail-silent half).
    tag_exists=$(echo "$existing_comments" | jq -r --arg tag "$idem_tag" '[.[][] | select(.body | contains($tag))] | length' 2>/dev/null || echo "ERR")
    if [ "$tag_exists" = "ERR" ]; then
      echo "  IDEMPOTENCY-UNKNOWN: tag-count jq failed — skipping this snapshot"
      continue
    fi

    if [ "$tag_exists" != "0" ]; then
      echo "  SKIP: comment with tag already exists"
      continue
    fi
  fi

  # Step 6: Invoke claude for re-review
  echo "→ invoking claude for re-review..."
  # claude -p takes the prompt VALUE (no @file convention — "@path" would BE the prompt)
  PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

  # >>>REPLAY:re-review-shadow>>>
  # Re-review command assembly: model id passed through verbatim, no verdict-posting call in shadow mode.
  # Inputs: MODEL, SHADOW, PROMPT_CONTENT, MODEL_RAIL (set by bridge.sh or the script flow)
  # Outputs: claude_reply captured, shadow report to stdout in shadow mode.
  #
  # The model id is passed through verbatim — no transformation, no alias resolution.
  # In shadow mode, no verdict-posting call (gh pr comment) is made.
  # Reasoning-model accommodation: no tight output cap is inherited (max_tokens headroom).
  claude_reply=$(claude -p "$PROMPT_CONTENT" --model "$MODEL" --output-format json 2>/dev/null) || {
    echo "  ERROR: claude invocation failed"
    # In replay, the bridge provides a valid prompt and claude stub; this is a test failure.
    continue
  }
  # <<<REPLAY:re-review-shadow<<<

  # Parse claude response: the --output-format json ENVELOPE carries the model text in .result
  # (the reviewer-session.sh:497 shape) — the {verdict, findings} JSON we asked for is INSIDE
  # that text, possibly ```json-fenced. Strip fences, then parse; anything unparseable = UNKNOWN.
  result_text=$(printf '%s' "$claude_reply" | jq -r '.result // ""' 2>/dev/null || echo "")
  result_json=$(printf '%s' "$result_text" | sed -e 's/^```json$//' -e 's/^```$//')
  sonnet_verdict=$(printf '%s' "$result_json" | jq -r '.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
  sonnet_findings=$(printf '%s' "$result_json" | jq -r '.findings // ""' 2>/dev/null || echo "")
  [ -n "$sonnet_verdict" ] || sonnet_verdict="UNKNOWN"

  # Step 7: Compare verdicts — normalize the recorded GitHub .state vocabulary (APPROVED /
  # CHANGES_REQUESTED) onto the prompt's (APPROVE / REQUEST_CHANGES) or equality never holds.
  recorded_norm="$recorded_verdict"
  case "$recorded_verdict" in
    APPROVED) recorded_norm="APPROVE";;
    CHANGES_REQUESTED) recorded_norm="REQUEST_CHANGES";;
  esac
  # UNKNOWN on EITHER side (verdict unrecoverable / sonnet output unparseable) is not a model
  # disagreement — give it its own outcome so the evidence channel never dresses a parse
  # failure as a DISAGREE row (bot review r3).
  if [ "$recorded_verdict" = "UNKNOWN" ] || [ "$sonnet_verdict" = "UNKNOWN" ]; then
    compare_result="INCOMPARABLE"
  elif [ "$recorded_norm" = "$sonnet_verdict" ]; then
    compare_result="AGREE"
  else
    compare_result="DISAGREE"
  fi

  echo "  sonnet: $sonnet_verdict → $compare_result"

  # Build comparison comment
  COMMENT_FILE="$WORK_DIR/comment.md"
  cat > "$COMMENT_FILE" <<EOF
$idem_tag

## Re-review Comparison

| Recorded | Re-review |
|----------|----------|
| $recorded_model / $recorded_verdict | $MODEL / $sonnet_verdict |

<details><summary>Recorded review body (as submitted)</summary>

$recorded_body

</details>

### Findings

$sonnet_findings
EOF

  if [ $prompt_truncated -eq 1 ]; then
    cat >> "$COMMENT_FILE" <<EOF

**Note:** The re-review prompt was truncated to fit the Linux argv ceiling (MAX_ARG_STRLEN=131072). The diff section was shortened, keeping head and tail portions with an explicit omission marker.
EOF
  fi

  cat >> "$COMMENT_FILE" <<EOF

### Verdict

**$compare_result**
EOF

  if [ "$SHADOW" -eq 1 ]; then
    # Shadow mode: advisory-only — NEVER post to the PR. Write report to stdout with
    # shadow-re-review marker, model + rail attributed. The live reviewer identity split
    # is exactly what the A5 evidence will decide; the shadow must not contaminate it.
    echo ""
    echo "=== shadow-re-review ==="
    echo "snapshot: ${snapshot_path}"
    echo "project: ${snap_project}"
    echo "pr: ${snap_pr}"
    echo "headsha: ${headsha8}"
    echo "model: ${MODEL}"
    echo "rail: ${MODEL_RAIL}"
    echo "recorded_model: ${recorded_model}"
    echo "recorded_verdict: ${recorded_verdict}"
    echo "re-review_verdict: ${sonnet_verdict}"
    echo "compare_result: ${compare_result}"
    echo ""
    echo "--- findings ---"
    echo "${sonnet_findings}"
    echo "--- end findings ---"
    echo "=== end shadow-re-review ==="
  else
    # Post comment — BOT REVIEW R4 #8: transient failure warns and continues (don't abort batch)
    echo "→ posting comparison comment..."
    if ! gh pr comment "$snap_pr" --repo "teststuffstash/${snap_project}" --body-file "$COMMENT_FILE" 2>/dev/null; then
      echo "  POST-FAILED: gh pr comment returned non-zero — snapshot processed but comment not posted" >&2
    fi
  fi
  # <<<REPLAY:re-review-shadow-skip-tag<<<

  # Print summary line
  echo ""
  echo "${snap_project}#${snap_pr} ${headsha8} recorded=${recorded_model}/${recorded_verdict} re-review=${sonnet_verdict} ${compare_result}"
done

echo ""
echo "→ re-review complete"
