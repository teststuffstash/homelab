# Pilot: a recorder, and a full-shape world for the `updater` family

A spike artifact (2026-11-08), sibling of the [updater port](../updater/README.md). It tests one
direction mechanically on one family ([`agents/replay/fixtures/updater`](../../../../replay/fixtures/updater),
43 rows): **the raw world is always full data** (every key gh sends), **the parser is strict on
every field**, and **a spec page renders only the fields its rows read**. Nothing here runs in CI;
the real family is unchanged.

| File | Role |
|---|---|
| [`recorder.py`](recorder.py) | runs the REAL gh argv, writes `<world>/gh/<stub key>.json` (sanitised) + `provenance.yaml` |
| [`live-shape/`](live-shape) | the two sanitised live recordings (`class: recorded`) — the shape source |
| [`fullshape.py`](fullshape.py) | trimmed family + live shape → full-shape family; `--check`, `--mode naive`, `--naive-rule`, `--live-spelling` |
| [`render.py`](render.py) | a row's persona: its full world projected onto one requirement's read set |
| [`../updater/family/`](../updater/family) | the CONSTRUCTED full-shape copy of the family (generated; `fill-log.json` names every filled key) |

## Results

| check | result |
|---|---|
| (a) real bash harness, `devbox run -- bash agents/replay/run.sh agents/islands/scan/pilot/updater/family` | **43/43** (real family, same session: 43/43) |
| (b) Python port, `from_wire` requiring ALL 12 PR keys, `UPDATER_FAMILY=…/family` | **43/43** |
| (b′) same strict port against the TRIMMED family | **0/43** — every row: `gh pr list body unreadable` (base PRs carry 7 of 12 keys) |
| (c) must-change: every regenerated patch changes the full base | **23/23** (and run.sh's own NO-OP gate stayed silent on 43 rows) |
| full-shape check (`fullshape.py --check`): every PR has the 12 keys, every object the key set of its live counterpart | **43/43 rows** |
| `--live-spelling` (persona logins rewritten to what live gh sends on each read) | 43/43 bash, 43/43 Python |

`run.sh` takes any fixture dir as an argument, so the copy needed no harness change. Why a copy and
not the real family: ADR-103's pin-vacuity gate (`.github/workflows/ci.yaml`, "Changed clauses
carry replay changes") runs only when a CLAUSE file changes, and `update-pr-branch.sh` is not in its
clause regex, so re-worlding the real family would NOT trip it — but a spike PR should not silently
replace a live pin's world; promoting the copy is a separate, reviewable act.

Budget: **6 `gh` calls** (homelab `pr list`; oracle-fleet `pr list`, `pr view 965 --json
commits,reviews`, `commits/<sha>/check-runs` → **403**, `commits/<sha>/status`, `pulls/965`) + 2
anonymous REST GETs for check-runs (oracle-fleet → 404, private; homelab → 200). No loop, no poll.
Wall-clock ≈ 45 min, of which the ablation runs (14 harness passes) ≈ 4 min.

## The recorder

`recorder.py record --world <dir> [--source o/r] [--key <shorter key>] -- gh <argv as the script spells it>`

- **Key = the stub's key, sourced not ported**: `_rp_slug "$(_rp_words …)"` from
  [`stubs/_common.sh`](../../../../replay/stubs/_common.sh), over the SANITISED argv — a SHA or repo
  inside an `api` path is part of the key, so argv and payload share one rewrite and
  `commits/<sha>/check-runs` keys on the same fake SHA the board's `headRefOid` carries.
- `--jq`/`-q` are dropped from the live call: the stub evaluates the script's `--jq` at serve
  time, so the world holds the raw answer.
- `--key pr-list` for the board: `--state` is not in the stub's value-flag list, so the full key is
  `pr-list-open`; the recorder accepts a shorter key only if it is a prefix the stub falls back to.
- The raw answer goes to a cache OUTSIDE the tree (`--raw-cache`); `sanitize` re-derives every world
  file and the provenance from it, so a rewrite-list change costs no network call.
- **Provenance lives in one `provenance.yaml` per world**, not a sidecar per file: run.sh's table
  mode already strips that file when it materialises a world, `run.sh --rerecord` already reads its
  `  - path:`/`    cmd:` entries, and a `<key>.meta.json` sidecar would sit in the stub's served
  directory. Each entry: `{path, cmd (the live argv), at, source, via}` — `via` says when the answer
  was fetched another way (hand-run `--raw-file`; anonymous REST for check-runs). `run.sh --rerecord`
  can replay the `cmd`s, but its byte diff will always read DRIFTED (the stored file is sanitised);
  the useful re-record check for a sanitised world is a key-SET diff, not built here.

### Sanitiser rewrite list (mechanical, `SANITISE_DOC` in recorder.py)

1. repo: `teststuffstash/{homelab,oracle-fleet}` → `teststuffstash/testrepo` everywhere (path-anchored)
2. every 40-hex SHA → `sha1(salt:sha)` (stateless, so stable across files and calls)
3. `id`/`databaseId`/`fullDatabaseId`/`node_id`/`external_id` → hashed, same type and node-id prefix; an empty id stays `""`
4. logins kept when the scripts read them (`app/…`, `…[bot]`, `homelab-*`, `renovate*`, `github`, `github-actions`, `ghost`, the org); every other login → `human-<h6>`, in every string
5. person `name` → `Human <h6>`; `email` → `<login>@users.noreply.invalid`
6. prose (`title`, `body`, `messageBody`, `commitHeadline`, `commit_title`, `description`, check `output` text, …) → `sanitized <key>`, keeping HTML-comment marker lines (`<!-- rebase-check -->`), base64 runs inside them blanked, short hex runs (SHA prefixes, session ids) hashed
7. `messageHeadline` keeps `Merge branch '<b>' into <b>` / a conventional-commit prefix
8. branch names keep their first `/` segment (`renovate/`, `fix/`, `goal/`)
9. repository objects' `name` → `testrepo`; numeric ids inside URL paths → the same fake id
10. avatars → `avatars.invalid`

Kept as-is: dates, enums, label names, check/status names, PR numbers. Five iterations of the
leak-grep were needed (org login mapped to a human and rewritten inside every URL; `github` the
App owner likewise; repo `name` fields; ids inside URLs; short SHAs in `<!-- specs-review head=… -->` markers and an ssh_url eaten by the e-mail rule) — the grep is the real gate, not the list.

## What live gh actually sends (null vs absent vs empty)

Observed 2026-11-08 across 9 open PRs (gh 2.103.3). **No top-level key is ever absent** — every
absence in the trimmed worlds is a fixture artifact.

| key | live answer |
|---|---|
| `number`, `createdAt`, `mergeStateStatus`, `headRefOid`, `headRefName`, `baseRefName` | always a string/int |
| `reviewDecision` | always a string; `""` for a repo with no review policy (gh's Go zero value — not in this sample, all three repos require review) |
| `autoMergeRequest` | `null` when un-armed (6/9); else an object in gh's STRUCT order `authorEmail, commitBody, commitHeadline, mergeMethod, enabledAt, enabledBy` — `authorEmail`/`commitBody` null, `commitHeadline` null or a string |
| `labels`, `reviews`, `latestReviews` | always an array, `[]` when none (6/9) |
| `labels[]` | `{id, name, description, color}` |
| `reviews[]` | `{id, author:{login}, authorAssociation, body, submittedAt, includesCreatedEdit, reactionGroups, state, commit:{oid}}` |
| `latestReviews[]` | the same 10 keys, but `id: ""` and `commit.oid: ""` — unqueried fields arrive as EMPTY STRINGS, not null, not absent |
| `author` | two live shapes: bot `{is_bot, login}` (login `app/…`), user `{id, is_bot, login, name}` — "all keys" is persona-dependent one level down |
| `pr view --json commits,reviews` | `{commits:[{authoredDate, authors:[{email,id,login,name}], committedDate, messageBody, messageHeadline, oid}], reviews:[…as above]}` |
| check-runs | `{total_count, check_runs:[16 keys: id … conclusion, started_at, completed_at, output, check_suite, app, pull_requests]}`; `conclusion` null while not completed (GitHub docs; the fixtures' `pending` row) |
| combined status | `{state, statuses:[10 keys], sha, total_count, repository (46 keys), commit_url, url}` |
| `pulls/N` | 50 keys |

Key ORDER: `pr list`/`pr view` top level is alphabetical (gh marshals a map); nested objects keep
gh's struct order; REST keeps GitHub's order. The full-shape world follows each.

Login spelling per read (the scripts normalise all three): `pr list` author = `app/X`; GraphQL
`reviews[].author.login` = bare `X` (no `[bot]`); `pr view` commit authors = `X[bot]`.

## The full-shape base world (the crux)

`fullshape.py` takes SHAPE from `live-shape/` and PERSONA from the trimmed family: every value a
fixture wrote wins untouched; a key the fixture LEFT OUT is filled by a named rule, logged per
file/path in `family/fill-log.json` (1553 fills: P9 commit 329, P13 pull 322, P11 check-run 275,
P6 review 265, P7 autoMergeRequest 130, P12 status 107, P1 author 27, P10 pr-view reviews 27,
P5 headRefName 22, P3 latestReviews 21, P2 reviews 12, P8 label 12, P4 headRefOid 2; 2 non-JSON
files copied verbatim). The rules that carry meaning:

- **P1** absent `author` → the agent App, bot form (`app/homelab-agents-1234`). jq read the absence
  as login null = not Renovate; so does this.
- **P2** absent board `reviews` → the reviews this row's `pr view` recording carries (one GraphQL
  connection; all rows sharing the patch must agree), else the `latestReviews`, else `[]`.
- **P3** absent `latestReviews` → last review per author, with live's `""` id/oid.
- **P10** absent `pr view` `reviews` → the board PR's reviews (same connection, other direction).
- **P9** commit `oid` of the last commit = the board's `headRefOid`; check-run `head_sha`/status
  `sha` = the SHA in the file's key; REST `pulls/N` head/base/user/auto_merge derived from the board.

Patches are re-emitted, never hand-edited: an adding patch as `. + [<completed PRs>]`, a modifying
one as a top-level-key delta with completed values (`label-conflict-90` → `. + {labels: [<full
label>]}`); the original comment header is kept. Size: worlds+rows+patches 36 KB → 417 KB.

## Findings — every row that broke on the way, and why

The principled build passed 43/43 first time, so the breaks come from the controls that remove
one principle at a time (`--naive-rule <rule>`: that rule's keys take the live exemplar's value
verbatim, everything else principled; both suites agree row-for-row).

1. **Strict parser × trimmed world: 43/43 rows red.** The base world's PRs omit `author`,
   `headRefOid`, `headRefName`, `latestReviews`, `reviews`; the 4-required compromise in the port
   existed only to tolerate that.
2. **Absent `author` IS the "not Renovate" persona — 43/43 rows red** under naive P1 with the
   richest live PR (#965, a Renovate PR) as exemplar. Base #90 (armed, CLEAN) becomes Renovate,
   leg 1b's hand-back sweep probes it, and every stream grows `CALL gh pr view 90` + a HOLD line.
   The trimmed world relied on `.author.login // ""` / `renovate_login(null)` to mean "ordinary PR".
3. **Absent `reviews` IS the "unreviewed" persona — 2 rows red** under naive P2 with exemplar #1032
   (a live PR with a fresh `homelab-reviewer` APPROVED): `unreviewed-behind-no-update`,
   `non-automerge-unreviewed-no-update`. `.reviews[]?` over a missing key = "no bot approval";
   a real approval post-dating every fixture commit makes both PRs merge-ready.
4. **Naive fills are exemplar-dependent.** The same P2 ablation with exemplar #965 (only
   CHANGES_REQUESTED reviews) is 43/43 green. Whether a "fill with live data" migration breaks a row
   depends on which live PR was the template — a filler must be persona-aware, not data-driven.
5. **A missing per-PR recording passes as a HOLD.** Deleting `rows/probe-unreadable/gh/pr-view-141.json`
   and `rows/unstrand-unreadable/gh/pr-view-120.json` keeps both rows GREEN: the stub's "an
   unrecorded READ dies loudly (exit 9)" is swallowed by the script's `2>/dev/null … || cj=""`
   (rule #6), so absence and the garbage recording are indistinguishable. Same mechanism made the
   ablation breaks above show up as HOLD lines rather than fixture errors.
6. **Impossible board personas.** #120, #151, #163 are `reviewDecision: CHANGES_REQUESTED` with no
   reviews on the board — the CR review lived only in the row's `pr view` file. Harmless here
   (leg 1 excludes CR before reading reviews; leg 2 reads `pr view`), but a world a strict reader
   could reject; P2 reconciled them.
7. **One key, two argv spellings.** `pr view N --json commits` (leg 1) and `--json commits,reviews`
   (leg 2) key to the same `pr-view-N.json`; the stub serves the file whole, so a full world must
   hold the union — the leg-1 recording no longer matches what live gh would print for that argv.
8. **Spellings live gh never sends on that read** (no row broke — every reader normalises):
   37 `homelab-reviewer[bot]` in board reviews (live: bare); 15 `app/homelab-renovate-1234` in
   `pr view` commit authors (live: `[bot]`); and `renovate-untouched-cr-no-update`'s board author
   `homelab-renovate-1234[bot]`, which the family header says "keeps the plain `[bot]` shape so both
   spellings stay pinned" — both bot authors seen on the live `pr list` were `app/…`, so that row
   pins a spelling this read does not produce. Under `--live-spelling`, 43/43.
9. **`null-author-no-crash`'s `author: null`** is kept as a persona but is probably not a live wire
   shape: gh serialises unqueried/zero fields as `""` (finding 10), so a deleted reviewer likely
   arrives as `{login: ""}` or `ghost`. Unverified — needs one recording of a deleted-account review.
10. **Zero values, not nulls**: `latestReviews[].id` and `.commit.oid` are `""` live. A reader that
    wants "approved at head" by OID (`commit.oid == headRefOid`) has it on `reviews`, never on
    `latestReviews`.
11. **Combined status `state: "success"` with `statuses: []`** in 11 of the 15 status files; GitHub documents
    a zero-status combined state as `pending`. The updater never reads it (not verified live).
12. **Port residue**: with all 12 keys required, `updater.py`'s `pr.author is None`,
    `head_ref_oid or ""`, `base_ref_name or ""` and `jq_text(review_decision)` are dead defaults.
13. **The jail PAT cannot record check-runs** (403, no Checks: read) even on a public repo — the
    exact read the updater's App makes. Recording it needs the App token, or anonymous REST on a
    public repo (used here, homelab only). The homelab board itself was too thin (3 open PRs, none
    armed, no reviews/labels → no element shapes), so oracle-fleet's board was recorded as well.

## Rendered personas (requirement read sets)

Read sets are derived from the **jq paths** in
[`update-pr-branch.sh`](../../../../update-pr-branch.sh) and
[`renovate-currency.sh`](../../../../renovate-currency.sh) (line refs in `render.py`).
[`updater.schema.json`](../../specs/updater.schema.json)'s `x-requirements` do not agree at the
needed grain: they annotate `/properties/pr` as a whole for PICK, UNSTRAND, CONFLICT and RENOVATE
alike, its `pr.required` omits `labels` (leg 3 reads every PR's), and it models none of the per-PR
reads (`pr view`, check-runs, status, body). Board PRs the row did not touch render with leg 3's
set; `"…"` = read for presence only. A static read set over-includes on short-circuit paths
(`human-approved-pick` never reaches `reviews` — APPROVED returns first).

**`fifo-pick` (PICK)** — 2 PRs added, 12 keys each on the wire:

```json
{"number":90,"autoMergeRequest":"…","mergeStateStatus":"CLEAN","labels":[]}
{"number":91,"autoMergeRequest":null,"mergeStateStatus":"BEHIND","labels":[]}
{"number":101,"createdAt":"2026-08-19T09:00:00Z","mergeStateStatus":"BEHIND","autoMergeRequest":"…","reviewDecision":"",
 "labels":[],"latestReviews":[{"author":{"login":"homelab-reviewer"},"state":"APPROVED"}],
 "reviews":[{"author":{"login":"homelab-reviewer"},"state":"APPROVED","submittedAt":"2026-08-19T09:30:00Z"}],
 "headRefOid":"abc123def456","baseRefName":"master","author":{"login":"app/homelab-agents-1234"}}
{"number":102, …same shape, reviewer "homelab-reviewer[bot]", APPROVED 10:30, oid 789012ghi345}
pr-view-101: commits [{"fix: the thing", 09:00}, {"Merge branch 'master' into fix/x", 12:00}]
pr-view-102: commits [{"fix: the other thing", 10:00}]
```

**`renovate-untouched-green-update` (RENOVATE)**:

```json
{"number":150,"createdAt":"2026-09-27T06:00:00Z","mergeStateStatus":"BEHIND","autoMergeRequest":"…","reviewDecision":"APPROVED",
 "labels":[],"latestReviews":[{"author":{"login":"homelab-reviewer[bot]"},"state":"APPROVED"}],
 "headRefOid":"ren150oid789","baseRefName":"master","author":{"login":"app/homelab-renovate-1234"}}
pr-view-150: commits [{"chore(deps): update actions/checkout action to v7", 06:00, authors ["app/homelab-renovate-1234"]}]
check-runs:  [{"name":"ci","status":"completed","conclusion":"success"}]
status:      [{"context":"renovate/stability-days","state":"success"}]
```

**`human-approved-pick` (UNSPECIFIED on the spec page; its behaviour is PICK's APPROVED arm)**:

```json
{"number":131,"createdAt":"2026-09-03T13:00:00Z","mergeStateStatus":"BEHIND","autoMergeRequest":"…","reviewDecision":"APPROVED",
 "labels":[],"latestReviews":[{"author":{"login":"RasmusSoot"},"state":"APPROVED"}],
 "reviews":[{"author":{"login":"RasmusSoot"},"state":"APPROVED","submittedAt":"2026-09-03T13:30:00Z"}],
 "headRefOid":"human131oid456","baseRefName":"master","author":{"login":"app/homelab-agents-1234"}}
```

(The `reviews` and `author` lines of #101/#102/#131 are FILLS — P2/P3/P1 — rendered beside persona
values; a page should mark fills, which `fill-log.json` makes possible. The trimmed persona's real
login `RasmusSoot` passes through: personas are not sanitised, only recordings are.)

## Next family, differently

1. Record BEFORE designing the sanitiser, with a leak-grep as the gate; record a board with
   armed/reviewed/labelled PRs (pick the repo by that, not by name), and get an App token or a
   public repo for check-runs up front.
2. Write the persona-aware fill rules first as "what did jq read for the absent key" — each rule is
   a reader default made explicit; then run the per-rule ablation with TWO exemplars (finding 4).
3. Add a stub mode where an unrecorded READ cannot be swallowed (finding 5) before trusting any
   HOLD row.
4. Put the read sets in the schema at field grain (one `x-requirements` entry per field path, the
   per-PR reads modelled) so `render.py` derives them instead of carrying a hand table.
5. Keep patches as persona deltas and let a template layer complete them at materialisation, rather
   than generating 400 KB of literal patches — this pilot generated literals only because run.sh has
   no completion step.
