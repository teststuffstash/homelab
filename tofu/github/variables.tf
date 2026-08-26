variable "org" {
  description = "GitHub organization that owns the repos."
  type        = string
  default     = "teststuffstash"
}

# Rollout. ⚠ "evaluate" (dry-run) AND its Insights are GitHub Enterprise-only — on Team the API accepts
# evaluate but the ruleset is inert and uninspectable (looks protected, isn't). On Team the only
# meaningful values are "active" and "disabled"; there is no observe-first mode. Default is "active":
# protection is this root's whole purpose, so a bare `apply` must KEEP it on — never silently disable
# it by omitting a flag. The admin bypass is verified live (a direct owner push shows "Bypassed rule
# violations"). For a deliberate rollback: `apply -var enforcement=disabled`.
variable "enforcement" {
  description = "Ruleset enforcement: active or disabled (evaluate is Enterprise-only — inert on Team)."
  type        = string
  default     = "active"
  validation {
    condition     = contains(["evaluate", "active", "disabled"], var.enforcement)
    error_message = "enforcement must be one of: evaluate, active, disabled (evaluate needs Enterprise)."
  }
}

# Per-repo required status checks. Key = repo, value = the PR-triggered check (job) names that must
# pass before merge. ⚠ Only list checks that actually run on `pull_request` — a required check that
# never reports leaves every PR un-mergeable. (e.g. sleep-tracking's build-image runs on push only,
# so it can't be required; its `ci` job does run on PRs.) Add repos here as they grow PR CI + the
# full-stack confidence gate.
variable "protected_repos" {
  description = "Map of repo => required PR status-check contexts (+ whether the repo also requires an approving review)."
  type = map(object({
    required_checks = list(string)
    # require_approval=false → the repo gets required-checks (ci) but NOT required-approval. Used by
    # sleep-iac: its PRs are mechanical deploy bumps (opened by the homelab-deploy App) that must gate
    # on CI, not a review. GitHub's App/Integration ruleset bypass does NOT waive the "required
    # approvals" rule on a merge (only OrganizationAdmin does), so a bypass can't make the App's merge
    # go through — dropping the requirement is the correct fix, and matches "gate the bump with CI".
    require_approval = optional(bool, true)
    # require_code_owner_review=true → PRs touching CODEOWNERS-matched paths additionally need a
    # review from a code OWNER. The reviewer bot's approval is NOT a code-owner review (the bot isn't
    # in CODEOWNERS), so such PRs block on the human — the intended spec gate. PRs touching NO owned
    # path are unaffected: bot approval + green CI still auto-merge. Only meaningful where
    # require_approval=true (the rule rides the required-approval ruleset's pull_request block).
    require_code_owner_review = optional(bool, false)
    # restrict_workflow_pushes=true → a PUSH ruleset rejects any push touching
    # `.github/workflows/**` (iac-lane.md §L0b: the enforcement-grade native version of the
    # sentinel's path rule — the sleep-iac#28 self-merge hole). Applies to every branch and
    # every actor except the bypass list (OrgAdmin; Renovate, whose SHA-pinning PRs edit
    # workflows; homelab-merge, whose update-branch merge commits can carry master's workflow
    # edits onto a PR head). The worker App is deliberately NOT bypassed — that is the point.
    # ⚠ PRIVATE REPOS ONLY — GitHub rejects push rules on public repos outright ("Source
    # public repos cannot have push rules", 422 at the 2026-08-18 flip apply), so this flag
    # is a capability statement, not a policy choice: setting it on a public repo can never
    # apply. On public repos the fence is the required `iac-sentinel` check instead — workflow
    # edits only LAND via a PR (org ruleset), and the sentinel's path-rule reds any
    # worker-authored PR touching `.github/workflows/**`.
    restrict_workflow_pushes = optional(bool, false)
  }))
  default = {
    # rasmus-soot-cv is deliberately ABSENT: it is a push-only mirror (Forgejo deploy-key sync from
    # the private teststuff master; org PR-ruleset exclusion in org_ruleset.tf). Its render workflow
    # runs on push, so a required PR check would never report and would wedge any PR ever opened.
    # The four sentinel repos (SENTINEL_REPOS in scripts/iac-sentinel.sh) carry the required
    # `iac-sentinel` context — the IAC-G01 enforcement flip (2026-08-18, iac-lane.md §L0b). The
    # status is posted by the sentinel CronWorkflow (*/5) under the homelab-REVIEWER App, so a
    # PR waits ≤ one tick for it; probe failures post `error` (fail-closed) and heal next tick.
    circles-iac = { required_checks = ["ci", "iac-sentinel"], require_approval = false } # CI-gated deploy target (sleep-iac shape); public → no push ruleset possible
    # circles: codeowner gate ON (2026-08-06, the #29 goal lane) — /specs/ + /.agents/ on Rasmus
    # (CODEOWNERS at the repo root). Master-targeted only after the required-approval split, so
    # child PRs into goal/** stay bot-approved; the goal→master assembly PR (always touches
    # /specs/ via the provenance requirement) blocks on the human, who merges via OrgAdmin.
    circles = { required_checks = ["ci"], require_code_owner_review = true }
    # homelab — the platform lane's gate (docs/agents/iac-lane.md §The platform lane).
    # FLIPPED 2026-08-04, once its three preconditions held: homelab joined the platform claim as a
    # context-only repo (so review-reflex.sh, which derives its scan set from the claims, finally
    # SEES its PRs and a bot approval exists at all); both merge-path callers are present
    # (renovate-approve added with the claim, update-pr-branch already there); and CODEOWNERS
    # encodes the path tiers. Flipping before that would have stalled every armed PR on an approval
    # nothing could give — an App/Integration bypass cannot waive required-approval, only an
    # OrganizationAdmin can (ADR-084).
    #
    # require_approval is repo-WIDE; only require_code_owner_review is path-scoped. So every PR now
    # needs SOME approving review (the reviewer bot's counts), and PRs touching an OWNED path
    # additionally need a human code owner. Deliberate consequences, both verified against the
    # actual automation before flipping:
    #   • agents/images.env is UNOWNED — the deploy-pin lane keeps auto-merging on the bot approval.
    #   • devbox-update touches devbox.lock/json — unowned, unaffected.
    #   • the arc-runner auto-bump commits argocd/platform/ + agents/coordinator/ — OWNED, so it now
    #     waits for a human. That is the intended reading of those tiers, not an accident.
    #   • Renovate's Actions SHA-pinning PRs touch .github/workflows/ — OWNED, likewise. Arguably
    #     the single change you most want eyes on (the Trivy-class mitigation, renovate.md).
    homelab = { required_checks = ["ci", "iac-sentinel"], require_approval = true, require_code_owner_review = true } # public → no push ruleset possible (flag comment above)
    # The three below flipped require_code_owner_review=true 2026-08-11 (the reviewer-enable
    # retrace): with the platform stack's bot reviewer ON, require_approval alone lets a bot
    # approval auto-merge — the codeowner flag is what turns the bot review into input-only on
    # owned paths. agent-runtime's CODEOWNERS (its PR#37) had been DECORATIVE without this flag
    # — the 2026-08-08 "codeowner gate guards the governor paths" record was wrong at the
    # enforcement layer; this flip makes it true. openrouter-operator + agent-coordinator got
    # whole-repo CODEOWNERS the same day (their gate = human on everything, bot review as input;
    # relax per-path later via carve-outs, never by dropping the flag).
    agent-coordinator   = { required_checks = ["ci"], require_code_owner_review = true }
    agent-runtime       = { required_checks = ["ci"], require_code_owner_review = true }
    openrouter-operator = { required_checks = ["ci"], require_code_owner_review = true }
    oracle-fleet        = { required_checks = ["ci"], require_code_owner_review = true }                                          # CODEOWNERS gates /specs/ + /.agents/ on Rasmus
    oracle-iac          = { required_checks = ["ci", "iac-sentinel"], require_approval = false, restrict_workflow_pushes = true } # sleep-iac shape: CI + sentinel, no review; PRIVATE → the one repo the push guard can exist on
    sleep-iac           = { required_checks = ["ci", "iac-sentinel"], require_approval = false }                                  # public → no push ruleset possible
    sleep-tracking      = { required_checks = ["ci"] }
    snore-recorder      = { required_checks = ["ci"] } # PR `ci` check confirmed live 2026-07-24 (PR #8 era runs)
    # agent-runtime  = { required_checks = [...] }     # needs a pull_request-triggered check first
  }
}

# The homelab-merge App id — still needed as the ruleset BYPASS ACTOR (repo_rulesets.tf ×3:
# required_checks, required_approval_goal, workflow_push_guard), which is why it survived the
# 2026-08-26 retirement of the MERGE_GH_APP_* org secrets (ADR-111 cutover, homelab#745 — the
# in-cluster updater sources the App KEY via Infisical→ESO; the private-key var is gone).
# The id is NOT sensitive, so it lives here as a default instead of a github-tf.sh injection —
# a bare `tofu apply` works without the cred dir.
variable "merge_gh_app_id" {
  description = "homelab-merge GitHub App id (ruleset bypass actor; not sensitive)."
  type        = string
  default     = "4207260"
}

# The homelab-deploy App id — NOT sensitive (the key is). Published as the DEPLOY_APP_ID Actions secret
# (actions_secrets.tf) the sleep-tracking deploy workflow reads to mint a sleep-iac-scoped token. Empty
# until the App is bootstrapped (scripts/github-deploy-app-bootstrap.sh) — while empty the secrets are
# skipped, so the github root applies cleanly before the App exists. Injected by scripts/github-tf.sh when
# the cred dir is present. (It no longer drives a ruleset bypass: sleep-iac has no required-approval — the
# deploy bump gates on CI, and an App's Integration bypass can't waive an approval on a merge anyway.)
variable "deploy_app_id" {
  description = "homelab-deploy GitHub App id (drives the DEPLOY_APP_ID Actions secret). Empty until bootstrapped; injected by scripts/github-tf.sh."
  type        = string
  default     = ""
}

# The homelab-deploy App private key. SENSITIVE — injected by scripts/github-tf.sh from the cred dir
# (durable copy: Infisical DEPLOY_GH_APP_PRIVATE_KEY). Published to the DEPLOY_APP_PRIVATE_KEY Actions
# secret, scoped to sleep-tracking ONLY (it grants contents+PR write on sleep-iac). Empty until bootstrapped.
variable "deploy_app_private_key" {
  description = "homelab-deploy GitHub App PEM private key. Set via TF_VAR_deploy_app_private_key (scripts/github-tf.sh)."
  type        = string
  sensitive   = true
  default     = ""
}

# homelab-renovate App (FU-014) — the identity the self-hosted Renovate runner (homelab
# .github/workflows/renovate.yaml) runs as. id → RENOVATE_APP_ID secret, key → RENOVATE_APP_PRIVATE_KEY,
# both scoped to the HOMELAB repo (where the runner lives). Empty until bootstrapped
# (scripts/github-renovate-app-bootstrap.sh); injected by scripts/github-tf.sh from the cred dir.
variable "renovate_app_id" {
  description = "homelab-renovate GitHub App id (drives RENOVATE_APP_ID). Empty until bootstrapped."
  type        = string
  default     = ""
}

variable "renovate_app_private_key" {
  description = "homelab-renovate GitHub App PEM private key (durable copy: Infisical RENOVATE_GH_APP_PRIVATE_KEY)."
  type        = string
  sensitive   = true
  default     = ""
}

# homelab-reviewer App — REUSED (not a new App) for the reviewer-approves-Renovate reflex
# (sleep-tracking .github/workflows/renovate-approve.yaml). id → REVIEWER_APP_ID, key →
# REVIEWER_APP_PRIVATE_KEY, both scoped to sleep-tracking. The reviewer bot posts an approving review on
# Renovate's automerge PRs, SATISFYING required-approval (distinct identity) so auto-merge completes.
# Injected by scripts/github-tf.sh from ~/.claude/homelab-github-reviewer.
variable "reviewer_app_id" {
  description = "homelab-reviewer GitHub App id (drives REVIEWER_APP_ID for the renovate-approve reflex). Empty until wired."
  type        = string
  default     = ""
}

variable "reviewer_app_private_key" {
  description = "homelab-reviewer GitHub App PEM private key (durable copy: Infisical REVIEWER_GH_APP_PRIVATE_KEY)."
  type        = string
  sensitive   = true
  default     = ""
}
