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
#   bash agents/re-review.sh --project homelab --pr 437 [--since YYYYMMDD] [--dry-run] [--model sonnet]
#
# Flags:
#   --project <p>     Filter to this project (required for discovery without --pr)
#   --pr <n>          Filter to this PR number
#   --since YYYYMMDD  Only snapshots after this date (UTC)
#   --dry-run         Do discovery + fetch + assembly, print the claude command + prompt skeleton instead of invoking
#   --model <m>       Model to use for re-review (default: sonnet)
#
# Idempotency: Posts comparison as PR comment with <!-- re-review:<headsha8>-<ts> --> tag; skips snapshots whose tag already exists.
# PAT trap: Never uses statusCheckRollup in any API call (403s on App installation tokens).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# Defaults
PROJECT=""
PR=""
SINCE=""
DRY_RUN=0
MODEL="sonnet"

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2;;
    --pr)      PR="$2"; shift 2;;
    --since)   SINCE="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --model)   MODEL="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# Temp dir with cleanup trap
TMPDIR_BASE="${TMPDIR:-/tmp}"
WORK_DIR=$(mktemp -d "${TMPDIR_BASE}/re-review.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

# PAT trap comment: all gh api calls below avoid statusCheckRollup — it 403s on App installation tokens.
# Use reviews + comments + files instead.

echo "→ re-review: discovering snapshots..."

# Step 1: Discover snapshots from S3
if [ -n "$PR" ]; then
  # Filter to specific project+pr if provided
  S3_PREFIX="s3://agent-transcripts/${PROJECT}/"
else
  S3_PREFIX="s3://agent-transcripts/"
fi

# List all review-state- prefixes (extract unique directory paths)
# S3 output format: DATE TIME SIZE path/to/file
# Run from REPO_ROOT for devbox context
SNAPSHOT_PATHS="$(cd "$REPO_ROOT" && devbox run garage-s3 s3 ls "$S3_PREFIX" --recursive 2>/dev/null | grep 'review-state-' | awk '{print $4}' | awk -F'/' '{for(i=1;i<=NF;i++) if($i ~ /^review-state-/) {for(j=1;j<=i;j++) printf "%s", (j>1?"/":"") $j; print ""; next}}' | sort -u)" || true

if [ -z "$SNAPSHOT_PATHS" ]; then
  echo "→ no snapshots found under $S3_PREFIX"
  exit 0
fi

# Apply filters
FILTERED=""
for path in $SNAPSHOT_PATHS; do
  # Extract project/pr from path: s3://agent-transcripts/<project>/<task>/review-state-<sha8>-<ts>
  proj=$(echo "$path" | sed 's|s3://agent-transcripts/||' | cut -d'/' -f1)
  task=$(echo "$path" | sed 's|s3://agent-transcripts/||' | cut -d'/' -f2)
  pr_num=$(echo "$task" | sed 's/pr-//')

  # Filter by project
  if [ -n "$PROJECT" ] && [ "$proj" != "$PROJECT" ]; then
    continue
  fi

  # Filter by PR
  if [ -n "$PR" ] && [ "$pr_num" != "$PR" ]; then
    continue
  fi

  # Extract timestamp from prefix name
  ts_part=$(echo "$path" | sed 's|.*/review-state-[^-]*-||')
  # Convert YYYYMMDDTHHMMSSZ to YYYYMMDD for comparison
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

# Step 2-6: Process each snapshot
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

  # Step 3: Recover recorded verdict from GitHub API
  echo "→ fetching recorded verdict..."
  REVIEWER_LOGIN="homelab-reviewer"

  # Get reviews via REST API (no statusCheckRollup)
  reviews_json=$(gh api "/repos/teststuffstash/${snap_project}/pulls/${snap_pr}/reviews" 2>/dev/null || echo "[]")

  # Find review by reviewer bot at/after snapshot timestamp
  # Convert snapshot timestamp to ISO for comparison
  snap_iso=$(echo "$snap_ts" | sed 's|\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)T\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)Z|\1-\2-\3T\4:\5:\6Z|')

  recorded_verdict=""
  recorded_body=""

  # Parse reviews to find matching one (author.login contains reviewer login, submitted_at >= snapshot)
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

  # Build prompt file (never inline large text)
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
  echo "  prompt: $prompt_words words"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "=== DRY-RUN MODE ==="
    echo "Would run:"
    echo "  claude -p \"@$PROMPT_FILE\" --model $MODEL --output-format json"
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
    echo "AGREE/DISAGREE (pending)"
    echo "========================"
    continue
  fi

  # Step 5: Invoke claude for re-review
  echo "→ invoking claude for re-review..."
  # ⚠ claude -p takes the prompt VALUE (no @file convention — "@path" would BE the prompt);
  # load the file into the arg, the reviewer-session idiom.
  PROMPT_CONTENT="$(cat "$PROMPT_FILE")"
  claude_reply=$(claude -p "$PROMPT_CONTENT" --model "$MODEL" --output-format json 2>/dev/null) || {
    echo "  ERROR: claude invocation failed"
    continue
  }

  # Parse claude response: the --output-format json ENVELOPE carries the model text in .result
  # (the reviewer-session.sh:497 shape) — the {verdict, findings} JSON we asked for is INSIDE
  # that text, possibly ```json-fenced. Strip fences, then parse; anything unparseable = UNKNOWN.
  result_text=$(printf '%s' "$claude_reply" | jq -r '.result // ""' 2>/dev/null || echo "")
  result_json=$(printf '%s' "$result_text" | sed -e 's/^```json$//' -e 's/^```$//')
  sonnet_verdict=$(printf '%s' "$result_json" | jq -r '.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
  sonnet_findings=$(printf '%s' "$result_json" | jq -r '.findings // ""' 2>/dev/null || echo "")
  [ -n "$sonnet_verdict" ] || sonnet_verdict="UNKNOWN"

  # Step 6: Compare verdicts — normalize the recorded GitHub .state vocabulary (APPROVED /
  # CHANGES_REQUESTED) onto the prompt's (APPROVE / REQUEST_CHANGES) or equality never holds.
  recorded_norm="$recorded_verdict"
  case "$recorded_verdict" in
    APPROVED) recorded_norm="APPROVE";;
    CHANGES_REQUESTED) recorded_norm="REQUEST_CHANGES";;
  esac
  if [ "$recorded_norm" = "$sonnet_verdict" ]; then
    compare_result="AGREE"
  else
    compare_result="DISAGREE"
  fi

  echo "  sonnet: $sonnet_verdict → $compare_result"

  # Check for existing comment (idempotency)
  idem_tag="<!-- re-review:${headsha8}-${snap_ts} -->"
  existing_comments=$(gh api "/repos/teststuffstash/${snap_project}/issues/${snap_pr}/comments" 2>/dev/null || echo "[]")
  tag_exists=$(echo "$existing_comments" | jq -r --arg tag "$idem_tag" '[.[] | select(.body | contains($tag))] | length' 2>/dev/null || echo "0")

  if [ "$tag_exists" != "0" ]; then
    echo "  SKIP: comment with tag already exists"
    continue
  fi

  # Build comparison comment
  COMMENT_FILE="$WORK_DIR/comment.md"
  cat > "$COMMENT_FILE" <<EOF
$idem_tag

## Re-review Comparison

| Recorded | Sonnet Re-review |
|----------|------------------|
| $recorded_model / $recorded_verdict | $MODEL / $sonnet_verdict |

### Sonnet Findings

$sonnet_findings

### Verdict

**$compare_result**
EOF

  # Post comment
  echo "→ posting comparison comment..."
  gh pr comment "$snap_pr" --repo "teststuffstash/${snap_project}" --body-file "$COMMENT_FILE"

  # Print summary line
  echo ""
  echo "${snap_project}#${snap_pr} ${headsha8} recorded=${recorded_model}/${recorded_verdict} sonnet=${sonnet_verdict} ${compare_result}"
done

echo ""
echo "→ re-review complete"
