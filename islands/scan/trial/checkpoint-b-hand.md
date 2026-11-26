# Trigger (b) — the hand-authored table (goal #3656 child 2, moved here by child 3, pin 7)

The table child 2 wrote on the page, cell for cell, kept outside the specs root where it still feeds the same
tests (arm `hand`). The page's table is generated from `specs/models/scan-clause-goal-b.yaml`.

#### Does trigger (b) fire while an assembly pull request is open?

| description | world | open assembly PR | (b) markers on it | since the marker | fault | lane winner | (b) this wake? | marker write? | (b) next wake? |
|---|---|---|---|---|---|---|---|---|---|
| child-set-complete | goal-checkpoint | none | — | — | — | this Goal | fires-no-pr | none | fires-no-pr |
| lane-lost-stays-eligible ⚖ | goal-checkpoint | A | none | — | — | another unit | fires-unmarked | none | fires-unmarked |
| selected-marks ⚖ | goal-checkpoint | A | none | — | — | this Goal | fires-unmarked | on A | held |
| goal-checkpoint-b-held | goal-checkpoint | A | the marker for A | — | — | this Goal | held | none | held |
| old-fold-markers-not-identity ⚖ | goal-checkpoint | A | the ten recorded on #3270, none of them the marker for A | — | — | this Goal | fires-unmarked | on A | held |
| marker-write-refused ⚖ | goal-checkpoint | A | none | — | the comment write answers 403 | this Goal | fires-unmarked | refused | fires-unmarked |
| marker-read-fails ⚖ | goal-checkpoint | A | the marker for A | — | the read of A's comments fails | another unit | fires-unreadable | none | held |
| pr-list-unreadable ⚖ | goal-checkpoint | A | none | — | the open-list read fails | this Goal | no-decision | none | fires-unmarked |
| goal-checkpoint-b-replaced-releases | goal-checkpoint | B (A is closed: not in the open list) | none on B; the marker for A stays on A | — | — | this Goal | fires-unmarked | on B | held |
| quoted-marker-is-inert ⚖ | goal-checkpoint | A | the marker for A, quoted (each line starts `> `) | — | — | this Goal | fires-unmarked | on A | held |
| head-not-goal-branch-is-no-assembly-pr ⚖ | goal-checkpoint | A, its head branch is not a `goal/**` branch | none | — | — | this Goal | fires-no-pr | none | fires-no-pr |
| goal-checkpoint-b-verdict-held | goal-checkpoint | A | the marker for A | the reviewer bot's APPROVED, newer than the marker | — | another unit | held | none | held |
| goal-checkpoint-b-content-push-held | goal-checkpoint | A | the marker for A | a new head commit id and a second, non-merge commit | — | another unit | held | none | held |
| goal-checkpoint-b-check-flip-held | goal-checkpoint | A | the marker for A | `ci` settled on FAILURE | — | another unit | held | none | held |
| goal-checkpoint-b-inflight-check-held | goal-checkpoint | A | the marker for A | a new head commit id, `ci` with no conclusion yet | — | another unit | held | none | held |
| goal-checkpoint-b-red-rerun-held | goal-checkpoint | A | the marker for A | `ci` re-run after FAILURE, no conclusion yet | — | another unit | held | none | held |
| goal-checkpoint-b-c-armed | goal-checkpoint | A | the marker for A | one open member of the Goal is undispositioned | — | this Goal | held | none | held |
| assembly-cr-wake-b-silent ⚖ | goal-checkpoint | A | the marker for A, and the three `state-fp:assembly-cr:` markers recorded on #3270 | CHANGES_REQUESTED on A | — | this Goal | held | none | held |
