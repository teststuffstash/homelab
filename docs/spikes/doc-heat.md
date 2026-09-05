# Spike — doc-heat: measure which markdown actually gets read

_Opened 2026-08-11 (operator + jail design session). Status: **PROMOTED 2026-08-30 (operator
ruling — the settle bar was met by run 1, S5 #983)**: doc-heat is a STANDING docs-cleanup
input (the skill's comb step names it), not an open experiment. v0 = jail-transcript parser +
static report: `devbox run doc-heat` → `~/.claude/doc-heat/report.html`. ⚠ Heat data from
before the S5 rewrite describes text that no longer exists — the first post-S5 read is dated
on the tracker (due ~2026-09-06). Tracker pointer: FU-164._

## Question

Can transcript-derived read/grep heat over the repo's markdown identify documentation that is
worthless (never consulted, no class excuse) or misplaced (search lands in A, the answer is
read from B) — reliably enough to drive docs-cleanup deletions with evidence instead of taste?

## Heat doctrine (from the founding session)

- **The living/historical split already exists** (`scripts/docs-graph-lint.sh` `is_historical()`
  + the docs-cleanup Hard rules + /design layer 4) — the report CONSUMES it, never re-invents
  it. Cold sediment is the system working. (A second consumer of the split now exists; if a
  third arrives, promoting the case list to one shared home rides an ordinary docs-cleanup —
  the ≥2-pattern rule's call, not a deferral.)
- **Deletion signal = heat × class × age — never heat alone.** Recovery runbooks are rare-read,
  highest-value (boot-from-git); brand-new files are cold by age, not by worth (v0's own first
  run listed the just-committed skills files as cold-living — correctly, and uselessly without
  the age column).
- **Blind spots, declared on the report itself:** auto-injected context (CLAUDE.md, memory,
  skill bodies) never appears as a Read; the OPERATOR's own reading (GitHub/editor) is
  invisible; /design mandates full-file reads of owning docs, flattening their line signal
  (sessions are taggable by skill markers to separate the modes).
- **Line heat is approximate**: counts anchor to line numbers at read time; files drift. Good
  enough for "which section of runbook.md earns its place", not for forensic line claims.
- **Misplacement signatures** (future analysis, data already captured): grep-hit-in-A →
  Read-B chains; a hot single section inside an otherwise-cold large doc (split/move candidate).

## Measured (2026-08-11, 66 jail sessions)

891 Read calls (477 ranged, 332 on `.md`) vs **2,787 grep/bash calls touching `.md`** — the
grep channel is 8× the Read channel; a Read-only heatmap would be untruthful. First full run:
80/104 repo `.md` files touched; hottest = `docs/follow-ups.md` (6 whole + 98 ranged reads +
197 grep hits) — the tracker-as-hub, as designed.

## v0 (BUILT) — jail only

`scripts/doc-heat.py`: Read channel (file_path + offset/limit) + grep channel (`path.md:NNN`
refs in tool results) → per-file/per-line counts with the historical class + git age →
`data.json` + a self-contained coverage-style `report.html` (sequential-ramp line gutter,
light/dark, blind-spot banner, cold-living table framed as "candidates to judge, not a delete
list"). The data schema carries a `source` dimension from day one (`jail` today).

## v1 (next) — cluster leg, separate + combined views

Same parser over `s3://agent-transcripts` slices (transcripts-sync; the one-PVC coverage gap
closed with FU-140, archived 2026-08-12 — cluster slices are complete) with `/work/repo` + `/work/context/<name>` path normalization. **Operator
requirement (2026-08-11): jail and cluster stay viewable separately AND combined — not a full
merge.** This leg simultaneously delivers the [context-repos](context-repos.md) spike's overdue
measurement sweep (its load-bearing / redundant / untouched classification) — one parser, two
consumers.

## Serving (when the report earns it)

The bookmarkable page (= the CONTEXT.md "webservice" contract) rides the existing static-site
seam: a Crossplane-declared Garage bucket + scoped write key (wallet-delivered to the jail;
`GARAGE_S3_ENDPOINT` port-forward fallback as in `garage-s3.sh`), website-enable with a
namespaced alias (`homelab-doc-heat` — the alias IS the hostname, `docs/garage.md`
§Static-website serving), then the OPNsense cert/HAProxy/Unbound name (runbook §HTTPS name,
sign-before-haproxy order). Deliberately NOT built in v0 — the report must first prove it
changes docs-cleanup decisions.

## What would settle it — MET (settle test run 1, below)

The bar was: one docs-cleanup pass citing heat evidence for ≥3 delete/merge/move decisions the
operator accepts. Run 1 (2026-08-26, the S5 #983 trims) met it. What remains is the OPERATOR's
promote-vs-close call (FU-164): serve the report + wire it into the docs-cleanup skill, or
close the spike and delete the generator.

## Settle test — run 1 (2026-08-26, S5 #983)

150 sessions, 101/125 files. The pass used per-line heat (cold spans = lines never TARGETED by
a ranged read or grep — whole-file corpus loads do not flatten it), which turned out to be the
yield; file-level cold mostly survived on class excuses, as the doctrine predicted.

**Heat-cited decisions (3 accepted trims, −214 lines from the two hottest corpus docs):**
model-routing §M10's superseded narrative (a 74-line measured-cold span → the what-stands
block); issue-authoring's FU-143 implementation contract + soak forensics (88 cold lines of
shipped-and-archived history → the invariant + two lessons + FSM pointers); issue-authoring's
two-hop cascade (40 cold lines — where heat ALSO caught a staleness no lint could see: the
section still described the ADR-111-retired hosted updater). Every line cut here was paid on
every design-agents corpus load (then believed ~110k tokens; measured 300–350k in run 2).

**Candidates correctly REJECTED on class excuse (the doctrine working):**
`tofu/cloudflare/README.md` (0 heat since 07-13 — root-README/recovery class, rare-read
highest-value) and `spikes/no-human-in-the-loop.md` (1 hit — live spike backing FU-097, two
inbound links). Blind spots confirmed as declared: skills/`ground-rules.md` (auto-injected,
never Read) and cluster-consumed docs (recipes, lenses, the coordinator brief) are invisible
to the jail-only v0 — do not judge those from this report; the v1 cluster leg is what makes
them measurable.

**Verdict input:** heat changed decisions — the ≥3 bar is met, and the line-level channel
found both trim mass and a staleness class the lints structurally miss. The promote-vs-close
call (serve the report; wire it into docs-cleanup as a standing input) is the operator's.

## Settle test — run 2 (2026-09-05, the post-S5 read — FU-164's scheduled follow-up)

Two runs from one sitting: all-time (218 sessions, 106/143 files) and a **windowed** run
(`DOC_HEAT_SRC` = a symlink dir of the 37 transcripts modified since 2026-08-31 — the
generator takes the source dir from the environment, so a window costs nothing to build).
The window is the one that matters post-S5: pre-S5 heat describes text the #984 comb rewrote.

**The load itself, measured for the first time** (`scripts/session-ctx.sh --big` on the
2026-09-03 and 2026-09-04 corpus sessions): **299k and 346k cache-creation tokens** per
design-agents corpus load — not the ~110k the skill had carried since the 2026-08-18 trim.
The read plan is ~820 KB / 9,900 lines; docs/agents grew 516→645 KB between 08-19 and 09-05,
45 % of it meta-state.md (17→75 KB, pruned to its contract the same day). Ten loads in the
six windowed days.

**Windowed heat over the design-agents read plan:** 72 % of its 9,900 lines were never
targeted by a ranged read or grep — whole-loaded only. Longest never-targeted runs:
replay README 385 (below the index — already grep-only by the read plan), merge-path 370,
observability-and-retro 331, issue-authoring 328, iac-lane 277, chainless-redesign 271,
roles 218, model-routing 171. The coordinator brief shows 0 % cold because its whole reads
arrive as ranged chunks — an instrument artifact, so it is unmeasured rather than clean
(the v1 cluster leg is also what would measure it from the consumer side).

**Decisions:** none cut in this run — it is the measurement that files the trims as the S5
stint's fifth original (homelab#1393, #983's method), so the accepted decisions land as
run 3 there. What run 2 settles: the windowing recipe (environment-driven source dir), and
that the corpus cost line in the skill is a measured figure from now on.

## Links

FU-164 (pointer) · [context-repos.md](context-repos.md) (the shared sweep — FU-117 archived) ·
[`docs/glossary.md`](../glossary.md) (live — hot ungreppable terms feed it; FU-163 archived) ·
FU-058 (retro transcript slices precedent) · docs-cleanup skill (the consumer) · `scripts/docs-graph-lint.sh`
(the living/historical split).
