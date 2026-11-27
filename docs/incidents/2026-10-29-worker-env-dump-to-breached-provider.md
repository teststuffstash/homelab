# 2026-10-29 — A worker printed its env into a prompt; the provider that served it was breached

**Status: CLOSED with a residual — the exposed key is rotated (#3684, 2026-11-22) and the new key
uploads (ride `issue-3408/worker-r2-20261125T235900Z` is in the bucket); the class is open.**
Tracked by: FU-325 (the belt, then the boundary). Dated by first symptom (the ride);
the signal arrived 2026-11-22 as a vendor notice. Trigger class: **silent failure** — no belt of
ours saw a credential enter a prompt; an email from OpenRouter did.

**Impact.** One cluster credential reached a third party: the Garage key `agent-transcripts-writer`
(`GK2da874…`, write-only on the single bucket `agent-transcripts`, endpoint `s3.teststuff.net` =
`192.168.3.16`, an HAProxy VIP with no public DNS record and no WAN forward). It is unusable from
outside the LAN; inside, its whole reach is appending objects to the transcripts bucket. No
credential valid outside the cluster (GitHub token, OpenRouter key, Anthropic token, wallet value)
was in any of the affected requests. Rotation is hygiene, not containment.

**Timeline (UTC).**

- 2026-10-21/22 and from 10-27 — per the vendor: an attacker holds two compromised credentials on
  GMI Cloud's internal system, which kept ~3 days of request content "for troubleshooting", and
  searches it for credentials in prompts.
- 10-22 07:02, 17:26; 10-24 19:01 — the gateway's entry canaries admit three OpenRouter cells whose
  selected endpoint is `gmicloud` (`deepseek-v4-flash`, `z-ai/glm-5.3-flash`,
  `xiaomi/mimo-v2.6-flash`): 9 synthetic-prompt requests.
- 10-27 21:51 — platform worker ride `issue-2981` r1 on `z-ai/glm-5.3-flash`, 3 requests served by
  `gmicloud`. Transcript clean.
- 10-28 17:32 — circles worker ride `issue-135` r1 through the old proxy (`deepseek-v4-flash`,
  requested `:exacto`), 53 requests served by GMICloud. Transcript clean; the pod's OpenRouter
  credential was a `ref:` (ADR-087 A), nothing to leak.
- 10-29 06:51 — platform worker `issue-3011` r1, 7 requests. Clean.
- **10-29 17:17–18:11 — platform worker `issue-3016` r1** (`z-ai/glm-5.3-flash`, opencode, gateway
  session `f7456ff3…`), 436 requests to `gmicloud`, 388k prompt tokens. At `run.log` line 4537 the
  model's first shell command ends in `printenv` ("let me check the environment's capabilities");
  at line 12409 `env | sort | head -60`. Both tool results — `AGENT_TS_ACCESS_KEY_ID`,
  `AGENT_TS_SECRET_ACCESS_KEY`, the gateway session token inside `OPENCODE_CONFIG_CONTENT`,
  `AGENT_SESSION_KEY`, `OPENROUTER_KEY_HASH` — sit in the context of every later request of the
  ride. `GH_TOKEN` is absent (fetched per op by the broker helper, never in env).
- 11-17 — last attacker access the vendor saw; 11-18 the credentials are revoked; 11-20 OpenRouter
  disables every GMI Cloud endpoint.
- 11-22 — the notice ("your account sent 505 requests to GMI Cloud between October 22 and
  October 29"). Our own books close it: gateway `requests` 455 (`provider='gmicloud'`) + old-proxy
  `generations` 53 = 508. The transcripts of all four rides pulled from the bucket and scanned
  (gitleaks + a token-shape grep): findings only in `issue-3016`'s `run.log`, listed above.

**Root cause.** The model-facing container of a ride held a long-lived credential in its
environment, and a model's environment is one tool call away from its context. ADR-087 moved the
LLM and git credentials out of the pod (refs, a broker) but the transcript writer key stayed as
"the one documented Secret exception" ([agentstack.md](../agents/agentstack.md) §perStack), and
the shape has other members. Nothing in the pipeline tells a prompt's recipient apart from a
trusted party: the provider sees everything the model sees.

*Ruled out:* an OpenRouter key leaving (OpenRouter re-authenticates to the provider with its own
key; the pod held none); the jail (wallet-bearing) transcripts (jail LLM traffic never routes to
OpenRouter — `scripts/claude-model-shim.py` knows Anthropic and OpenCode only); a GitHub token in
those requests (none in any of the four logs). *Not verifiable:* whether the key was ever used by
the attacker — Garage keeps no per-key access log and Loki's lookback is 7 days; the endpoint's
LAN-only reach makes use from the attacker's side impossible, not merely unobserved.

**Collateral.** None observed. The LAN-only gateway session token in the same dump expired with
the ride (`released 18:11:22Z`).

**Fixes.**

- **Belt — rotate `agent-transcripts-writer`** (this PR): `agents/coordinator/garage-workspace.yaml`
  gets a new `garage_key` resource address; provider-terraform creates the new key, rewrites the
  Crossplane connection Secret, destroys the old; the per-namespace ESO mirrors
  (`argocd/resources/agentstack/transcripts-store.yaml`) refresh within their interval. A ride in
  flight at the switch loses its upload (non-fatal in `agent-finalize`) — a maintenance window
  around the merge, the `garage key list` before/after as the check.
- **Root-cause fix — the credential boundary:** no credential valid outside the cluster ever
  exists in a pod whose model traffic can reach a third party; the pod's identity leaves the
  model-facing container. The design is written and sits with the private platform security
  review until its build steps land (this repo is public; the design is also an inventory); it
  registers here as an ADR with the last step.
- **Belt — the transcript leak scanner** (the design's first step): gitleaks + an env tripwire over
  every new transcript object, `AgentTranscriptLeak`, positive control = this ride's log with
  synthetic values. The quiet alert is what lets the next vendor notice go to trash unread.

**Probe lesson.** "Are we immune?" was answerable in minutes from our own books — the gateway's
`requests.provider` column and the proxy's `generations` table name the serving provider per
request, and the bucket holds every transcript — but only because someone asked. The class is
detectable at write time: a credential in a transcript is a regex match at upload. What *looked*
fine: the key was documented as harmless ("all it can do is append exhaust"), which is true of its
reach and says nothing about it being read by a third party; and the brief's "check the
environment first" habit is exactly what a model does with `printenv`.

**Residual.** FU-325, minted by the primary seat from the second-jail handoff of 2026-11-22: the scanner
belt and the boundary rollout. The rotation is verified (Status). This file owns the story.
