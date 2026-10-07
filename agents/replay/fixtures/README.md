# Fixture notes

## FU-249 — the responder paused for a week (PR#1746)

No fixture applies. The change is a data filter on the `responder` Sensor's `alert-dep`
(`agents/coordinator/responder-argo.yaml`) that no Alertmanager webhook can satisfy, so Argo Events
never submits a `respond-*` Workflow. It sits entirely in the Sensor object — before any code the
replay harness exercises (the harness replays the WorkflowTemplate's pod-side blocks; it does not
model Argo Events dependency filtering). The `respond` WorkflowTemplate itself is byte-identical,
so every existing responder fixture keeps asserting exactly what it asserted before. What pins the
pause is live: `responder_triage_sessions_today` flat at 0 while alerts fire, and no `respond-*`
Workflows in `agent-coordinator` (`argo list`). Re-enabling (delete the filter) is the same
no-fixture change in reverse. **Removed 2026-10-04 (ADR-148, FU-249 steps 2–4):** the lane was
replaced rather than un-paused — the route carries `triage = "now"` and the Sensor is unfiltered
(pinned by `responder-behaviour-test.sh` §routing, which reads the Sensor out of the manifest);
the subject residuals the audit found are pinned by six new `responder-subject/*` fixtures
(`ksm-pod-uid`, `ksm-object-no-pod`, `cronjob`, `pushgateway-pushed-job`,
`github-exporter-repo`, and `witness-pod-owned` re-recorded in the live KubePodNotReady shape);
the [grouped deep dig](../../../docs/agents/roles.md)'s selector has its own behavioural harness (`agents/deep-dig-test.sh`),
not a clause fixture — it is a standalone script, not a sentinel block.

## FU-072 — removing the kata endpoint-IP rewrite and `dnsPolicy: None`

No fixture applies. The deleted code (`resolve_ep` plus the three docker-mode rewrites of
`PROXY_URL`/`TS_ENDPOINT`/`PGW_URL`, and the `dnsPolicy: None` + LAN-resolver lines in
`KATA_BLOCK`) sits **outside every `>>>REPLAY:` sentinel** in `agents/agent-session.sh`, and the
harness composes a clause only from marker-delimited blocks (`run.sh` §the sentinel extractor) —
so no fixture can reach it, and none could before the change either.

Marking it would not help. What is left at the first site is a comment; the second is a single
static string assignment (`KATA_BLOCK=$'  runtimeClassName: kata'`). Neither makes a call, so the
action-stream model — the harness's only assertion mode — has nothing to record. Asserting "the
rendered pod spec carries no `dnsPolicy`" needs an assertion over the ASSEMBLED manifest, which is
the same `mode: exec` / template-snapshot extension homelab#1113 asks for below.

What pins this change instead is a live probe, recorded in the PR (#1372) and in
`docs/spikes/kata-service-vip.md`: a kata pod under the enforced fixer CNP reaching
`openrouter-proxy`, `garage` and `prometheus-pushgateway` through their service VIPs, with
`openrouter.ai:443` still denied as the negative control. The regression signature is
`AgentWorkerEgressDropped` carrying a bare pod IP as its Hubble destination.

## homelab#1113 — dispatch-time `bash -n` assembly guard

No fixture applies. The guard added in `agents/reviewer-session.sh` runs **host-side** before a
pod is spawned — it checks the assembled heredocs (`$PREP`, `$TOUCHESPART`, `$UPLOADER`,
`$RUNPART`) with `bash -n` and exits with a FATAL diagnostic before reaching any code that the
replay harness exercises (the pod-side blocks extracted via sentinel markers). The guard's
entire effect is "exit 1 before pod creation", which is outside the replay harness's scope
(the harness stubs `gh`/`kubectl` and replays pod-side blocks; it does not stub `bash -n` or
simulate heredoc assembly).

A fixture that tested the guard would need to:
1. Set up the four heredoc variables with controlled content
2. Run the `bash -n` check
3. Assert the FATAL message on syntax error or silent pass on clean syntax

This is a pure-bash operation with no external calls, so the action-stream assertion model
(the harness's only assertion mode) has nothing to record. A future `mode: exec` or
`mode: exit-code` extension could cover this class.

## The eventbus anti-affinity + PDB (PR#1774)

No fixture applies. The change adds a `podAntiAffinity` to the `EventBus` CR's JetStream pod
template and a `PodDisruptionBudget` beside it in `agents/coordinator/review-argo.yaml` — a
ratchet clause file because the review reflex's Sensor and WorkflowTemplate live there too. Both
added objects are **scheduler and eviction** inputs: they decide which node a bus replica lands on
and how many may be evicted at once. Neither is read by any code the harness replays — the
`Sensor`, the `EventSource` and the reflex's WorkflowTemplate are byte-identical, so every existing
review fixture keeps asserting exactly what it asserted before, and no action stream anywhere in
the tree changes.

There is also nothing for the action-stream model to record: the harness stubs `gh`/`kubectl` and
replays pod-side blocks, so a fixture here could only assert that a manifest the harness never
applies contains the fields it plainly contains — a tautology over the diff, which is the cosmetic
fixture this ratchet exists to prevent.

What pins the change is live, and the pre-state was the finding. Before the merge (2026-09-19,
ArgoCD had not seen the branch): `kubectl -n agent-coordinator get pods -l eventbus-name=default
-o wide` put `-js-1` and `-js-2` both on **hp-01**, and `get pdb` returned nothing — so a single
drain of hp-01 took two of three JetStream replicas, i.e. the bus's quorum and with it the agent
loop. After (same two commands, 07:56Z): `-js-2` moved to wk-02, one replica per node, and
`eventbus-default-js` reports `ALLOWED DISRUPTIONS 1`. The drain of hp-01 — last in the upgrade
order, for this reason — is the real exercise.

## 2026-09-27 — reviewer no-container rule: operator-only paths read from CODEOWNERS (homelab#2031)

No fixture applies. The change edits PROMPT PROSE inside `agents/reviewer-session.sh`'s no-container
rule — the hard-coded list `(.github/**, .agents/**, devbox.json, CI-invoked scripts/**, pin-only
guarded files)` becomes an instruction to read the repo's CODEOWNERS — and no shell branch, exit code,
label, comment or `gh` call changes. The replay harness records the launcher's action stream and
pod-side blocks; a prompt string is opaque to it, so a fixture here could only assert that the prompt
contains the words it contains — the cosmetic fixture this ratchet exists to prevent.

What pins the change is the reviewer's behaviour on the next dependency PR of a repo whose CODEOWNERS
un-owns a member of the version set (openrouter-operator: `devbox.json`, replaced by deps-pin-guard):
a finding on it must be classified as a worker's adaptation, not as `Operator-lane (no container):`.
The pre-state is the finding — openrouter-operator#80 (2026-09-27), where the hard-coded list read
`devbox.json` as operator-only on a repo where it was not, and #81 then merged on the bot alone.

## sigpipe-lint — the three clause files' here-string conversion (homelab#2371)

No fixture applies. Each site trades `printf|echo … | grep -q`/`| head` for `grep … <<< "$x"` /
`head -N <<< "$x"` — the same lines in, the same verdict out (a here-string carries
`printf '%s\n'`'s bytes; the `$(…)` around each `head` strips the one newline it adds).
- `agents/reviewer-session.sh` — the PREP lens selection on `$CHANGED` (×3) sits OUTSIDE every
  `>>>REPLAY:` sentinel, so no fixture can compose it (the FU-072 note above). It is also the one
  site with real exposure: a PR listing enough files to outrun the writer's buffer, matching early,
  could drop a lens under `pipefail`.
- `agents/agent-session.sh` (image-volumes fence ×3, transcript-mirror-probe `head -1`) and
  `agents/machine-comment.sh` (`mc_event`'s oldest-id `head -1`) are inside sentinels, but the
  race needs a multi-line haystack larger than the writer's buffer with an early match. The
  image-volume fields are single lines (the claim parser strips newlines), and the ids and error
  text run a few lines. No recorded world reaches the race, and a contrived >8 KB world would pin
  the harness rather than the clause.

The class itself is held by `scripts/sigpipe-lint.py`, which the `sigpipe-lint` suite fixture runs.
