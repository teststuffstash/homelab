#!/usr/bin/env bash
# new-agent-repo — scaffold a new agent/stack repo into tofu/github/ (FU-039 ergonomics).
#
# "Add a repo" touches three files that must stay in lockstep (repos.tf, variables.tf's
# protected_repos, labels.tf's label_repos). This turns that tribal sequence into one command:
# it edits all three (idempotently) and prints the two steps that CANNOT be codified — the GitHub
# App installs (a click, see docs/github-setup.md §"click-only") and the out-of-jail `apply`.
#
#   scripts/new-agent-repo.sh <repo-name> [--public|--private] [--no-labels] [--description "..."]
#
# Defaults: --private, agent/* labels ON. Generates the repo as CREATE (no `import` block) unless the
# repo already exists on GitHub (auto-detected via `gh`, then an import block is emitted to ADOPT it).
#
# This only writes HCL in the jail; NOTHING is applied here. Review `git diff tofu/github/`, then run
# the apply OUTSIDE the jail with the admin-PAT wallet:  devbox run github-tofu apply  (see README.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="$ROOT/tofu/github"
ORG="teststuffstash"

NAME=""; VIS="private"; LABELS=1; DESC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --public)      VIS="public"; shift;;
    --private)     VIS="private"; shift;;
    --no-labels)   LABELS=0; shift;;
    --description) DESC="$2"; shift 2;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0;;
    -*)            echo "unknown flag: $1" >&2; exit 2;;
    *)             [ -z "$NAME" ] || { echo "one repo name only" >&2; exit 2; }; NAME="$1"; shift;;
  esac
done
[ -n "$NAME" ] || { echo "usage: $(basename "$0") <repo-name> [--public|--private] [--no-labels] [--description ...]" >&2; exit 2; }

RES="$(printf '%s' "$NAME" | tr '-' '_')"   # tofu resource name: hyphens → underscores

# Does the repo already exist? (adopt-via-import vs create). Best-effort — no gh / offline ⇒ assume new.
EXISTS=0
if command -v gh >/dev/null 2>&1 && gh repo view "$ORG/$NAME" >/dev/null 2>&1; then EXISTS=1; fi

echo "→ scaffolding repo '$NAME' (resource github_repository.$RES, visibility=$VIS, labels=$LABELS, exists=$EXISTS)"

# ── 1. repos.tf — the repository resource (+ import block iff the repo already exists) ──────────────
if grep -qE "resource \"github_repository\" \"$RES\"" "$TF/repos.tf"; then
  echo "  repos.tf: github_repository.$RES already present — skip"
else
  {
    echo ""
    if [ "$EXISTS" = 1 ]; then
      echo "import {"
      echo "  to = github_repository.$RES"
      echo "  id = \"$NAME\""
      echo "}"
      echo ""
    fi
    cat <<EOF
resource "github_repository" "$RES" {
  name         = "$NAME"
  description  = "$DESC"
  homepage_url = ""
  topics       = []
  visibility   = "$VIS"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = false
  delete_branch_on_merge      = true # clean up the worker's agent/* branch after merge
  web_commit_signoff_required = false

  merge_commit_title          = "MERGE_MESSAGE"
  merge_commit_message        = "PR_TITLE"
  squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"

  archive_on_destroy = true

  security_and_analysis {
    secret_scanning { status = "disabled" }
    secret_scanning_push_protection { status = "disabled" }
  }

  lifecycle {
    # has_downloads is a deprecated no-op attribute: declaring it warns, omitting it perpetually
    # diffs true->false. So we neither set nor reconcile it (see the header repos in this file).
    ignore_changes = [has_downloads]
  }
}
EOF
  } >> "$TF/repos.tf"
  echo "  repos.tf: appended github_repository.$RES$([ "$EXISTS" = 1 ] && echo ' (+import — adopts existing repo)')"
fi

# ── 2. variables.tf — protected_repos (branch protection + the approval gate, via repo_rulesets.tf) ─
if grep -qE "^[[:space:]]*$NAME[[:space:]]*=[[:space:]]*\{[[:space:]]*required_checks" "$TF/variables.tf"; then
  echo "  variables.tf: protected_repos already has $NAME — skip"
else
  awk -v name="$NAME" '
    /variable "protected_repos"/ { invar = 1 }
    { print }
    invar && !added && /default = \{/ {
      print "    " name " = { required_checks = [\"ci\"] }"
      added = 1; invar = 0
    }
  ' "$TF/variables.tf" > "$TF/variables.tf.tmp" && mv "$TF/variables.tf.tmp" "$TF/variables.tf"
  echo "  variables.tf: added $NAME = { required_checks = [\"ci\"] } to protected_repos"
fi

# ── 3. labels.tf — label_repos (the agent/* state-machine labels) ──────────────────────────────────
if [ "$LABELS" = 0 ]; then
  echo "  labels.tf: --no-labels — skip (repo won't carry the agent/* taxonomy)"
elif grep -qE "label_repos = \[[^]]*\"$NAME\"" "$TF/labels.tf"; then
  echo "  labels.tf: label_repos already includes $NAME — skip"
else
  sed -E -i "s/(label_repos = \[[^]]*)\]/\1, \"$NAME\"]/" "$TF/labels.tf"
  echo "  labels.tf: added \"$NAME\" to label_repos"
fi

# ── Manual follow-ups (cannot be codified with the admin PAT — see docs/github-setup.md) ────────────
cat <<EOF

Next (in order):
  1. Review the generated HCL:   git -C "$ROOT" diff tofu/github/
     (run \`tofu -chdir=tofu/github fmt\` if the spacing needs tidying)
  2. Apply OUTSIDE the jail (admin-PAT wallet):   devbox run github-tofu apply
     → creates/adopts the repo, its ruleset, and (if labels) the agent/* labels.
     ⚠ Known 422 on CREATING a --private repo: the org disallows private-repo forking, so the
       provider's create-time PATCH fails ("This organization does not allow private repository
       forking") AFTER the repo is already fully created+configured — and leaves the resource
       TAINTED. Do NOT re-apply while tainted (archive_on_destroy would archive it, then the
       recreate name-collides). Instead:  tofu -chdir=tofu/github untaint github_repository.$RES
       then re-plan (expect no repo diff; ordinary later updates PATCH fine — seen 2026-07-08 on
       oracle-fleet/oracle-iac).
  3. CLICK-ONLY — install the Apps on '$NAME' (App scopes need NO change; you only add the repo to
     each installation's repository access). docs/github-setup.md §"click-only":
       https://github.com/organizations/$ORG/settings/installations
       → homelab-agents, homelab-reviewer, homelab-merge → Configure → Repository access → add '$NAME'
EOF
