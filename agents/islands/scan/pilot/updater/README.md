# Pilot: `agents/update-pr-branch.sh` → Python, against the replay fixtures as oracle

A spike artifact (2026-11-08), not a member of the island: one updater, ported to Python in the
functional-core / imperative-shell shape, run against the existing
[`agents/replay/fixtures/updater`](../../../../replay/fixtures/updater) family through a test
double that serves the recorded worlds and records the action stream the harness would. It exists
to answer "what would the Python version look like mechanically" for the undecided question in
[ADR-113](../../../../../docs/adr.md#adr-113--bash-is-glue-logic-is-python-shellcheck-gates-the-glue-no-wholesale-rewrite) (bash is glue, logic is Python; the wholesale rewrite
was rejected 2026-08-24). Nothing here runs in production; `update-pr-branch.sh` is unchanged.

| File | Role |
|---|---|
| [`gh_types.py`](gh_types.py) | frozen slotted dataclasses parsed from the `gh --json` wire via `from_wire`; `WireError` names (call, key, what) |
| [`github.py`](github.py) | the `GitHub` Protocol (7 reads + `write(Mutation)`), `GhCli` (the one `subprocess` site), `Recorded` (serves a replay world, records `CALL`/`OUT`/`ERR`/`RC`) |
| [`updater.py`](updater.py) | pure predicates (`breakered`, `leg1_candidate`, `leg2_domain`, `sweep_domain`, `lanes`) + `run()`, the only function that does I/O |
| [`test_updater.py`](test_updater.py) | one parametrized test over the family's `rows.psv`, `rule()`-labelled from [`../../specs/updater.md`](../../specs/updater.md), gateway-chassis conventions (markers degrade to no-ops without allure) |
| [`count_lines.py`](count_lines.py) | the line counter behind the table below |
| [`bash-family-run.txt`](bash-family-run.txt) | the real bash family's run in the same session, 43/43 |

Run (from the repo root; the gateway's uv env supplies pytest + allure-pytest):

```sh
cd gateway && devbox run -- uv run --frozen pytest -c ../agents/islands/scan/pilot/updater/pytest.ini \
  --rootdir ../agents/islands/scan/pilot/updater -p no:cacheprovider ../agents/islands/scan/pilot/updater/test_updater.py -q
```

## Result: 43/43, and the real bash family 43/43

- Interpreters: Python 3.15.0 (gateway uv env, with allure-pytest) and Python 3.11.2
  (`uv run --no-project --with pytest`, markers degrade to no-ops). Both pass.
- jq 1.8.2 (devbox) and 1.6 (`/usr/bin/jq`) both pass; jq applies the row patches and the stub's `--jq`.
- Negative controls, nine hand-applied mutations of the port: seven went red on exactly the rows
  that pin them (pre-#2203 lane → `lane-hop-wedged-oldest`; drop stderr passthrough →
  `update-fail`, `lane-hop-wedged-oldest`; drop the #1649 park guard →
  `parked-approved-head-no-update`; pre-#2007 raw login prefix → 15 Renovate rows; pre-#3058 red =
  not-green → `…-pending-noop`, `…-nochecks-noop`; reversed lane order → `two-lanes-two-updates`).
  Two stayed green — see "Harness format".
- Live read-only check: `GhCli` made 3 GraphQL reads against teststuffstash/homelab; strict
  `from_wire` parsed 3 live PRs; a bad PR number gave a typed `GitHubError(rc=1)`. `run()` never
  touched a live repo.

## Line counts (`count_lines.py`: comment = first non-space char `#`, plus ast-found docstrings)

| file | total | comment | code |
|---|---|---|---|
| `update-pr-branch.sh` | 428 | 257 | 161 |
| + `renovate-currency.sh` (sourced) | 109 | 43 | 58 |
| + `machine-comment.sh` label functions (:148-188) | 41 | 17 | 22 |
| **bash total** | **578** | **317** | **241** |
| `gh_types.py` | 258 | 34 | 158 |
| `github.py` (Protocol, GhCli, Recorded) | 392 | 31 | 272 |
| `updater.py` | 412 | 47 | 280 |
| **Python total (excl. tests)** | **1062** | **112** | **710** |
| `test_updater.py` | 208 | 20 | 143 |

~3× the bash in code lines; ~130 lines of `github.py` are `Recorded` (re-implements the replay
stub) — without it ~580 code lines, 2.4×. The bash's 257 comment lines of incident history were
not carried over; the port cites bash line refs instead.

## The typed boundary — and the open question it raises

See `gh_types.py` (`PullRequest`) and `github.py` (`GitHub` Protocol). Compromise taken in the
pilot: only 4 of the 12 `--json` fields are REQUIRED (number, createdAt, mergeStateStatus, labels).
The fixture worlds record a sparser wire than gh sends (base-world PRs carry 7 of 12 keys; live gh
sends all 12), so 8 fields read "absent == null", as jq does, and the typed layer cannot catch
fixture drift on those 8.

This is the unsolved fixture-shape question across oracle and homelab (operator, 2026-11-08): so
far fixtures carry only what the case needs and readers default the rest, so a recording never has
to spell out the unimportant. The direction proposed instead: **the raw data is always full** — a
world holds the complete wire answer, the parser is strict on every field — **and a world renders
only its required fields** to the spec page / test documentation. On the wire it is still full
data; what the reader sees is the projection. For this island that means: (a) worlds are recorded
from live `gh`, never hand-typed; (b) a row's "world" column names the full world, its displayed
persona is a rendered subset; (c) `from_wire` can require all 12 fields; (d) the existing
hand-trimmed worlds (`agents/replay/fixtures/*/world/gh/*.json`) are the migration cost — the
world-mining pass over them found 391 item-bearing worlds with most persona fields unknown,
because each records only what its clause read. Not decided here.

## Pass/fail per row: 43/43

PICK 12 · UNSTRAND 3 · CONFLICT 3 · RENOVATE 9 · UNSPECIFIED 16 (conflict-*-graphql-drained,
human-approved-pick, null-author-no-crash, the 4 automerge rows (#1896), renovate-untouched-cr-no-update,
renovate-other-class-no-update, renovate-updater-merged-ticked-noop, renovate-updater-merged-cr-handback,
renovate-merged-current-green-noop, renovate-untouched-current-red-noop, renovate-merged-park-red-handback,
renovate-merged-current-nochecks-noop). No failures to diagnose; every divergence below is outside
what the fixtures exercise.

## What the port surfaced that the bash hides (`.sh` = update-pr-branch.sh, `rc` = renovate-currency.sh)

1. `jq -r` prints null as the TEXT "null" (`.sh:235,243,260,356`): a null reviewDecision is neither
   "" nor APPROVED, so arm 2 fails closed; inside jq (`:204-211`) null stays null. Port needs `jq_text()`.
2. `REVIEWER_LOGIN` reaches only arm 2 (`:264`); the pre-filter (`:208`) and leg 2 (`:393`) hard-code
   `startswith("homelab-reviewer")` — three reviewer identities in one script. Arguably a bug.
3. Leg 2's verdict has no null guards (`:390-396`): a null-author review or a headline-less commit
   throws in jq and the PR holds forever. `add-null-author.jq` fixed leg 1 only. Likely a bug, no row
   pins it. Port MATCHES the bash.
4. The commit probe is checked three ways: leg 1 truthy (`:271`), renovate_probe is-array (`rc:40`),
   leg 2 non-empty (`:377`). Leg 1's at-head check is `jq -e … 2>/dev/null` (`:277`), so a malformed
   probe is a silent skip — contradicting the comment at `:268-269` ("both HOLD"). DELIBERATE
   DIVERGENCE: the port turns any malformed probe into `Unreadable` + the HOLD line.
5. `renovate_untouched` treats "no authors" as untouched (`rc:74-77`, `all([])`): fails open toward
   the safe side.
6. Lanes are pipe-delimited strings (`:326 join("|")`, `:325 tr`, `:308 ${member%% *}`); `-` stands
   in for a missing SHA; unquoted `${pick_oid:+-f …}` (`:316,:403`) relies on word splitting.
7. Leg 3 can crash AFTER writes: a PR with no `labels` fails jq inside the `| while` subshell
   (`:416-428`) → exit 5 after legs 1/1b/2 wrote; the same error at `:261` is swallowed.
   DIVERGENCE: `from_wire` refuses such a board before any write.
8. `gh pr list --limit 100` truncates silently (`:55`), newest first — the FIFO heads vanish on a
   100+ PR repo. Neither version handles it.
9. The hand-back drops the body's trailing newline (`rc:91` → `rc:103`); port matches; harness
   cannot see it.
10. With `UPDATER_LABEL_TOKEN` and `GH_TOKEN` unset, gh gets `GH_TOKEN=""` (`:130,:426`).
11. Exit codes on a bad board: `pr list` failure → gh's rc (both); 200-but-not-JSON → jq's rc and
    version-specific message in bash, exit 2 in the port.
12. jq 1.6 vs 1.8: identical on all 43 rows (jq-1.5-era builtins only).

## Harness format: subtler than it looked

- STDERR IS PART OF THE ASSERTED STREAM: gh's stderr must pass through at exactly the three
  un-redirected sites; dropping it reds 2 rows. Order is checked per stream, not interleaved
  (CALL*, OUT*, ERR*, RC).
- Two mutations stayed green: (a) trailing newline in the PATCH body — `_rp_record`'s sed eats one
  trailing newline per argument, so no fixture can pin whether the live PATCH body ends in `\n`;
  (b) `--state` is not in the stub's value-taking flag list, so the board read keys as
  `pr list open` and a per-call fault would be `STUB_GH_pr_list_open` — no row uses it.
- Template rendering is `sed "s|{{k}}|v|g"` (`run.sh:211-213`): `&`, `\`, `|` in values are special
  and keys are regexes. The port's renderer refuses such params (none exist today).
- The row env column is expanded unquoted (`run.sh:224`).
- `--jq` is evaluated with the real jq by both the stub and `Recorded`.

## Exec boundary

- Production subprocess sites: 1 (`GhCli._exec`). Test-only: one jq in `Recorded`, one in the materialiser.
- Bash: 13 gh + 41 jq call sites across three files (+ sed/grep/tr); leg 3 spawns 4 jq per PR.
- `GhCli` handles once: argv spelling (shared with `Recorded`, so a recorded stream pins the live
  argv), one `GitHubError(rc, stderr)`, non-JSON / wrong-shape → `Unreadable`, timeout, the
  label-token swap, `$(…)` newline stripping.
- Not handled, and where it goes: pagination (REST `/pulls?per_page=100` + Link), GraphQL-pool
  drain / rate limits (typed `RateLimited` classified from stderr in `_exec`), the 500k-node cap
  (`:48-54`, typed `NodeCapExceeded`), a per-pass call budget (transport).

## What a spec-page reviewer sees ([`../../specs/updater.md`](../../specs/updater.md))

27 of 43 rows map to a `SCAN-UPDATER-*` requirement; 16 unspecified. PICK's prose names the
APPROVED and `automerge` arms, its table has neither `human-approved-pick` nor the 4 automerge rows;
GraphQL-drain rows, `null-author-no-crash` and 7 Renovate rows are absent; the table has no
`params` column though a row cannot render without one; `parked-approved-head-no-update`'s patch
cell is prose; `probe-unreadable`'s env cell says "(probe fails)" but the real row has no env (the
failure is the garbage world file); `update-fail` sits under CONFLICT but tests leg 1's 422 path.

## Next script (review-reflex.sh, 560 lines), if the direction holds

~20 min wall-clock for this one. Bash family run ≈ 1 min; the port's suite < 3 s. Next time:
(1) move `Recorded` + the materialiser into one shared module first (~40% of this pilot, same for
every family); (2) write down per jq call site how strictly it reads its input BEFORE typing, so
every behaviour change is named up front; (3) assert per row which stderr sites pass through;
(4) get a ruling on fixing items 2, 3, 4 in the bash first, so the port has a clean oracle;
(5) settle the full-world question above before recording any new world.
