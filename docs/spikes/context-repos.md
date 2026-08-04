# Spike — context repos: mount more, let the ride grep

_Opened 2026-08-04 (operator + jail session). Status: **pilot designed, not yet built** — blocked
only on a free homelab workdir for the launcher edit. Sightings home: `docs/agents/roles.md`
§Context delivery (FU-117); this spike is that item's first deliberate data-gathering leg._

## Question

Should rides get read-only **context repos** cloned next to `/work/repo` (for circles: circles-iac
+ homelab on every ride, workers included), instead of the current doctrine that ALL cross-repo
context is injected into the issue by its author?

Operator hypothesis, stated 2026-08-04: *mount as much context as possible, let the agent grep if
it wants to* — the failure class to eliminate is "I did not know due to the environment". That
class has already-paid instances on record: #71-r1 downloaded a kind binary into a read-only nix
profile; the #48 rounds never configured the registry mirror (both CLAUDE.md-rule gaps that never
reached the goose worker — roles.md §Context delivery).

## What the record shows (history dig, 2026-08-04)

The single `/work/repo` clone **was never decided — no ADR owns it**:

- **ADR-004** (apps live in their own repos) and **ADR-078/081** (agent-sandbox pods; minted
  per-repo ~1h tokens + Cilium egress, 2026-06-25) shaped the *boundary*, but none of them says
  "one repo per ride". The clone step (agent-runtime entrypoint, one `REPO_URL` from the
  launcher) made it an implementation fact, not a ruling.
- It hardened into doctrine via the **FU-117 sighting 2026-07-28**: "the ride clones ONLY
  `/work/repo` — and it *shouldn't* grep SERVICES.md; service context is the issue author's job
  to inject" (the meta-15 add-then-remove flip-flop). Stack CLAUDE.md files then stated it as an
  invariant ("Workers clone ONLY this repo; the dispatched issue carries all cross-repo context").
- The early argument — *"homelab is public; an agent that needs it can clone it from GitHub"* —
  survives only as a comment (`agents/coordinator-session.sh:145`) and **remains network-true**:
  `github.com` / `codeload.github.com` / `*.githubusercontent.com` are in the baseline `toFQDNs`
  allowlist (agentstack `composition.yaml` §egress). What forbids the clone today is recipe text
  ("no homelab checkout" — the research recipes) — **prompt, not policy**. We are one sentence
  away from either world.
- **ADR-094** already formalized the adjacent notion for the *scan*: "context-only repos become a
  visible predicate, not an implicit clone-but-can't-work state" — claims can mark a repo as
  context, but nothing delivers it to the ride's filesystem.

## The tension (why a spike, not a decision)

- **For issue-injection (status quo):** "Elicit, don't inject" (lean worker context; FU-095
  model-comparison purity); the coordinator/issue-author is *supposed* to distill; more mounted
  text = more tokens burned grepping.
- **For mounting:** the paid "didn't know" incidents; **FU-134's 2026-08-04 ruling generalizes
  here** — "nothing that decides whether a ride can SEE something should be a property of the
  binary we happened to spawn"; an issue author cannot predict every fact a ride will need
  (that's the same golden-master trap as perfect upfront specs).

Both positions are on record. Neither has data. Hence: pilot + measure.

## Pilot design (circles stack ONLY)

- Launcher `--context-repo <url>` (repeatable) on `agents/agent-session.sh`; for circles rides
  default it to `teststuffstash/circles-iac` + `teststuffstash/homelab`. **Anonymous depth-1
  https clones into `/work/context/<name>`** — public repos, no token, so no push path exists:
  ADR-081 credential scoping and the org-pin rule are untouched, and no egress change is needed
  (github.com is baseline).
- Env card gains a line: `Context repos: /work/context/{circles-iac,homelab} — read-only
  reference; grep freely (SERVICES.md lives in homelab).` Capability truth in the card, per the
  FU-126 folklore lesson.
- Circles recipes drop the "you have ONLY this repo" sentence (folklore removal, same move as
  the egress sighting).
- NOT in the pilot: claim knob, other stacks, private context repos (a forgejo read credential is
  a credential-boundary extension needing its own ruling — see the org-pin HARD RULE).

## Measurement (the point of the pilot)

Transcripts land in `s3://agent-transcripts` (transcripts-sync). After ~2–4 weeks or ≥10 circles
rides, sweep the transcripts for tool calls touching `/work/context/` and classify per ride:

1. **(a) load-bearing** — a fact from a context repo shaped the work AND was not in the issue;
2. **(b) redundant** — context repo consulted, but the issue already carried the fact;
3. **(c) untouched** — mounted, never read.

Secondary signal: tokens/rounds per ride vs pre-pilot circles rides (mounting is not free if
models compulsively re-grep).

## Decision criteria

- Mostly **(a)** → promote: `contextRepos:` claim knob rendered by the Composition + an ADR;
  retire the "issue carries ALL cross-repo context" invariant (issue-injection stays for facts
  that live in no repo).
- Mostly **(c)** → close the spike: keep the doctrine, delete the flag, and the FU-117 refactor
  proceeds on the issue-injection model with confidence.
- Mixed / **(b)**-heavy → the FU-117 role × context × source map decides per context class.

## Links

FU-117 (sightings + eventual refactor) · FU-134 (capability-belongs-to-platform ruling) ·
ADR-004 · ADR-081 · ADR-094 · `docs/agents/roles.md` §Context delivery ·
`docs/agents/fixer-context.md`
