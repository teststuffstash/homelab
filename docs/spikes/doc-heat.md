# Spike — doc-heat: measure which markdown actually gets read

_Opened 2026-08-11 (operator + jail design session). Status: **v0 BUILT** — jail-transcript
parser + static report: `devbox run doc-heat` → `~/.claude/doc-heat/report.html`. Tracker
pointer: FU-164._

## Question

Can transcript-derived read/grep heat over the repo's markdown identify documentation that is
worthless (never consulted, no class excuse) or misplaced (search lands in A, the answer is
read from B) — reliably enough to drive docs-cleanup deletions with evidence instead of taste?

## Heat doctrine (from the founding session)

- **The living/historical split already exists** (`scripts/docs-graph-lint.sh` `is_historical()`
  + the docs-cleanup Hard rules + /design layer 4) — the report CONSUMES it, never re-invents
  it. Cold sediment is the system working. (Second consumer of the split — promotion of the
  case list to one shared home is now warranted.)
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

Same parser over `s3://agent-transcripts` slices (transcripts-sync; FU-140 notes the one-PVC
coverage gap) with `/work/repo` + `/work/context/<name>` path normalization. **Operator
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

## What would settle it

One docs-cleanup pass that cites heat evidence for ≥3 delete/merge/move decisions the operator
accepts — or a pass showing heat added nothing over the existing lint + judgment. Then either
promote (serve it, wire it into the docs-cleanup skill as a standing input) or close the spike
and delete the generator.

## Links

FU-164 (pointer) · [context-repos.md](context-repos.md) + FU-117 (shared sweep) · FU-163 (hot
ungreppable terms could feed the glossary) · FU-058 (retro transcript slices precedent) ·
FU-140 (cluster capture gap) · docs-cleanup skill (the consumer) · `scripts/docs-graph-lint.sh`
(the living/historical split).
