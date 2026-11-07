---
id: IF-REREVIEW
use-cases: []
schema: re-review.schema.json
---
# The time-travel re-review — a Go-served review's exact input, re-judged later

*Would the subscription reviewer have reached the same verdict on exactly what the Go-served
reviewer saw?* When a code review is served from the [Go rail](../../../../docs/glossary.md) instead of the subscription, the pod
records the review's input state to S3. Later, after the Anthropic pool resets, a jail operator
runs [`agents/re-review.sh`](../../../re-review.sh). It re-judges the recorded state with a chosen
model (default `sonnet`) and compares the verdicts (homelab#424, ruled 2026-08-13). This is the
island's model-quality evidence channel. No dispatcher calls it, and the gateway does not admit it:
it pins its own rail on purpose, because it IS the benchmark. Under the gateway path the Go-served
flag comes from the admitted rail (`GO_SERVED=1` when `rail = opencode`,
[REVIEW-ADMIT-GATEWAY](dispatch.md#review-admit-gateway)), so the channel survives the cutover. No
use case walks it.

## Interface — the machine half

**[`re-review.schema.json`](re-review.schema.json)**.

| Requirement | interface | Governs (schema) | Status |
|---|---|---|---|
| [REVIEW-REREVIEW-SNAPSHOT](#review-rereview-snapshot) | `s3://<bucket>/<project>/<task>/review-state-<sha8>-<ts>/` | `snapshot` | 🚧 |
| [REVIEW-REREVIEW-SHADOW](#review-rereview-shadow) | `re-review.sh --shadow --model <id>` | `argv`, `invocation`, `verdict` | 🚧 (fixture: harness-run-cmd/re-review-shadow*) |
| [REVIEW-REREVIEW-IDEMPOTENT](#review-rereview-idempotent) | the comparison comment | `comparison_tag` | 🚧 (fixture: harness-run-cmd/re-review-shadow-skip-tag) |

## Requirement index

| Requirement | Section | Status |
|---|---|---|
| [REVIEW-REREVIEW-SNAPSHOT](#review-rereview-snapshot) | the record | 🚧 WIP — no evidence pipeline yet (no fixture) |
| [REVIEW-REREVIEW-SHADOW](#review-rereview-shadow) | the re-judgement | 🚧 WIP — no evidence pipeline yet (fixtures: harness-run-cmd/re-review-shadow, -zen, -zen-empty, -zen-malformed, -zen-prose) |
| [REVIEW-REREVIEW-IDEMPOTENT](#review-rereview-idempotent) | the re-judgement | 🚧 WIP — no evidence pipeline yet (fixture: harness-run-cmd/re-review-shadow-skip-tag) |

## The record

### REVIEW-REREVIEW-SNAPSHOT

A review whose model was served from the Go rail (`GO_SERVED=1`) uploads its input state before
the model runs, to `s3://<AGENT_TS_BUCKET>/<project>/<TASK_KEY>/review-state-<head sha8>-<UTC ts>/`.
The upload holds `pr.json` (number, title, body, head, base, state, reviews, comments, files),
`diff.patch`, `head-sha.txt`, `rubric.sha.txt` (the rubric's git blob sha, `no-rubric-file`, or
`hash-failed`) and `snapshot-manifest.json`
(`{project, task, pr, round, model, headsha8, timestamp, files}`). Every step is non-fatal, and the
review proceeds whatever the snapshot does. A subscription-served review, a pod without the S3
key, and an image without `s5cmd` all skip the snapshot with one line
(`reviewer-session.sh` `record_review_state`).

| description | world | GO_SERVED | S3 key | s5cmd | snapshot? |
|---|---|---|---|---|---|
| a Go-served review records its input | pr-green-armed | 1 | present | present | the five files under `review-state-<sha8>-<ts>/` |
| a subscription review records nothing | pr-green-armed | 0 | present | present | `GO_SERVED!=1 — snapshot skipped` |
| no key is a skip, not a failure | pr-green-armed | 1 | absent | present | `no S3 key in pod — snapshot skipped` |
| a failed capture still uploads the rest | pr-green-armed | 1 | present | present (`gh pr diff` fails) | four files; `diff.patch capture FAILED (non-fatal)` |

_Evidence: none yet — unverified._

## The re-judgement

### REVIEW-REREVIEW-SHADOW

`re-review.sh --project <p> [--pr <n>] [--since YYYYMMDD] [--model <id>] [--shadow] [--dry-run]`
discovers snapshots, rebuilds the reviewer's prompt over the recorded state, and invokes the
model. Before it runs, it strips the jail's rail plumbing (the shim's `ANTHROPIC_BASE_URL` and the
CLI slot map `ANTHROPIC_DEFAULT_*_MODEL`), so `sonnet` means the seat's own subscription and
nothing else. The model id passes through verbatim. An `opencode/<id>` (Zen) model is invoked
through `opencode run -m <id>`, because the vendor admits no API client to its free tier. Every
other id goes through `claude -p --model <id>`. In `--shadow` mode it NEVER writes to the PR:
there is no comment and no verdict, only a stdout report carrying a `shadow-re-review` marker. An
empty Zen reply is retried exactly once and then skipped loudly. A reply that is not parseable
JSON is read for the closed verdict token. A prose reply is `UNKNOWN` / `INCOMPARABLE`, never a
guessed verdict, and its first 600 bytes are printed as evidence. `--pr` requires `--project`.

| description | model | reply | invocation? | posts? | verdict? |
|---|---|---|---|---|---|
| re-review-shadow | `opencode-go/kimi-k3` | a JSON verdict | `claude -p … --model opencode-go/kimi-k3` | no | the reply's |
| re-review-shadow-zen | `opencode/big-pickle` | framed CLI output with a JSON verdict | `opencode run -m opencode/big-pickle` | no | the reply's |
| re-review-shadow-zen-empty | `opencode/big-pickle` | empty, twice | `opencode run` ×2 | no | skipped loudly |
| re-review-shadow-zen-malformed | `opencode/big-pickle` | `"verdict": "APPROVE"` inside invalid JSON | `opencode run` | no | `APPROVE` (recovered, said so) |
| re-review-shadow-zen-prose | `opencode/big-pickle` | prose, no brace span | `opencode run` | no | `UNKNOWN` + the first 600 bytes |

_Evidence: none yet — unverified._

### REVIEW-REREVIEW-IDEMPOTENT

Outside shadow mode, the comparison is posted as ONE PR comment tagged
`<!-- re-review:<head sha8>-<snapshot ts> -->`. The tag is keyed by the snapshot, not by the model.
The PR's comments are read paginated BEFORE the model runs, and a snapshot whose tag already exists
is skipped. A comments read that fails, or a tag count that cannot be computed, skips the snapshot
(`IDEMPOTENCY-UNKNOWN`), and the snapshot is never re-posted. Shadow mode skips the gate entirely,
because it posts nothing. That lets a different model re-judge a snapshot that already carries a
live comparison (homelab#945).

| description | mode | tag on the PR | comments read | model runs? | posts? |
|---|---|---|---|---|---|
| a fresh snapshot is judged and posted | live | absent | ok | yes | one tagged comment |
| an already-compared snapshot is skipped | live | present | ok | no | no |
| an unreadable PR is not a fresh one | live | — | fails | no | no (`IDEMPOTENCY-UNKNOWN`) |
| re-review-shadow-skip-tag | shadow | present | (not read) | yes | no |

Only the last row has a fixture.

_Evidence: none yet — unverified._
