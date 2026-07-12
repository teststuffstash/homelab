#!/usr/bin/env bash
# new-stack — scaffold a NEW STACK's codifiable onboarding, end to end (FU-052's two layers).
#
#   devbox run new-stack <stack> [--main-repo <name>] [--iac <name>] [--public]
#
# Defaults: main repo = <stack>, -iac = <stack>-iac, both private.
#
# The sibling of `stack-lint` (the checklist-as-checks): this script makes the checklist go green
# where a script can, idempotently ("already present — skip" is its idle state), and PRINTS the
# steps that cannot be codified. There is deliberately no runbook doc: scaffold here, then loop
# `devbox run stack-lint <stack>` until green — the lint defines done.
#
# What it edits (homelab):
#   tofu/github/            via new-agent-repo.sh ×2 (+ require_approval=false for the -iac:
#                           deploy-bump PRs gate on CI, not review — the sleep-iac shape)
#   argocd/platform/        <stack>-project.yaml + <stack>-namespaces.yaml (AppProject + precreated
#                           ns, oracle shape) + the agent-fixer ApplicationSet generator for the -iac
#   agents/stacks.json      the committed claim mirror (CI lint universe + probe-failed belt)
# What it scaffolds (the -iac SIBLING checkout, jail only — ../<iac>):
#   apps/<main>.yaml, <main>/agent/{agentstack.yaml,workbench.yaml}, devbox/ci/yamllint/workflows —
#   copied from oracle-iac (the reference stack) with names substituted; REVIEW the diff there,
#   especially the claim's budget/egress (starts in MONITOR: enforce=false).
# What it can only print: the tofu/argocd.tf root app + repo credential (hand-written HCL), the
#   out-of-jail applies, the App-install clicks, the main repo's content (CLAUDE.md, .agents/,
#   devbox ci — copy from oracle-fleet until a stack-template repo exists), the PAT + jail entry.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ORG="teststuffstash"

STACK=""; MAIN=""; IAC=""; VIS="--private"
while [ $# -gt 0 ]; do
  case "$1" in
    --main-repo) MAIN="$2"; shift 2;;
    --iac)       IAC="$2"; shift 2;;
    --public)    VIS="--public"; shift;;
    -h|--help)   sed -n '2,26p' "$0"; exit 0;;
    -*)          echo "unknown flag: $1" >&2; exit 2;;
    *)           [ -z "$STACK" ] || { echo "one stack name only" >&2; exit 2; }; STACK="$1"; shift;;
  esac
done
[ -n "$STACK" ] || { echo "usage: new-stack.sh <stack> [--main-repo <name>] [--iac <name>] [--public]" >&2; exit 2; }
MAIN="${MAIN:-$STACK}"
IAC="${IAC:-$STACK-iac}"

echo "→ scaffolding stack '$STACK' (main: $MAIN, iac: $IAC)"

# ── 1. tofu/github — both repos (idempotent; new-agent-repo.sh prints its own next-steps) ─────────
bash scripts/new-agent-repo.sh "$MAIN" "$VIS"
bash scripts/new-agent-repo.sh "$IAC" --private
# -iac protected_repos entry → CI-gated only (deploy-bump PRs auto-merge on ci, no approver)
if grep -qE "^\s+$IAC\s*=\s*\{ required_checks = \[\"ci\"\] \}\s*$" tofu/github/variables.tf; then
  sed -E -i "s|^(\s+)$IAC(\s*= \{ required_checks = \[\"ci\"\] \})\s*$|\1$IAC\2 # CI-gated deploy target (sleep-iac shape)|" tofu/github/variables.tf
  sed -E -i "s|^(\s+$IAC\s*= \{ required_checks = \[\"ci\"\])( \})|\1, require_approval = false\2|" tofu/github/variables.tf
  echo "  variables.tf: $IAC → require_approval = false (deploy target)"
fi

# ── 2. argocd/platform — AppProject + precreated namespace (tenancy, oracle shape) ────────────────
if [ -f "argocd/platform/$STACK-project.yaml" ]; then
  echo "  argocd: $STACK-project.yaml already present — skip"
else
  sed -e "s/oracle-fleet/$MAIN/g" -e "s/oracle-iac/$IAC/g" -e "s/oracle/$STACK/g" \
    argocd/platform/oracle-project.yaml > "argocd/platform/$STACK-project.yaml"
  echo "  argocd: wrote $STACK-project.yaml (AppProject — review sourceRepos/destinations)"
fi
if [ -f "argocd/platform/$STACK-namespaces.yaml" ]; then
  echo "  argocd: $STACK-namespaces.yaml already present — skip"
else
  sed -e "s/oracle-fleet/$MAIN/g" -e "s/oracle/$STACK/g" \
    argocd/platform/oracle-namespaces.yaml > "argocd/platform/$STACK-namespaces.yaml"
  echo "  argocd: wrote $STACK-namespaces.yaml (platform-precreated ns $MAIN)"
fi

# ── 3. agent-fixer ApplicationSet — git generator for the new -iac ────────────────────────────────
if grep -q "$IAC.git" argocd/platform/agent-fixer.yaml; then
  echo "  agent-fixer: generator for $IAC already present — skip"
else
  awk -v iac="$IAC" -v org="$ORG" '
    /^  template:/ && !added {
      print "    - git:"
      print "        repoURL: https://github.com/" org "/" iac ".git"
      print "        revision: master"
      print "        directories:"
      print "          - path: \"*/agent\""
      print "        values:"
      print "          repoURL: https://github.com/" org "/" iac ".git"
      added = 1
    }
    { print }
  ' argocd/platform/agent-fixer.yaml > argocd/platform/agent-fixer.yaml.tmp \
    && mv argocd/platform/agent-fixer.yaml.tmp argocd/platform/agent-fixer.yaml
  echo "  agent-fixer: added git generator for $IAC (private repo ⇒ needs the argocd repo credential, step B below)"
fi

# ── 4. agents/stacks.json — the committed claim mirror ────────────────────────────────────────────
if jq -e --arg s "$STACK" '.stacks[] | select(.name==$s)' agents/stacks.json >/dev/null; then
  echo "  stacks.json: $STACK already present — skip"
else
  jq --arg s "$STACK" --arg main "$MAIN" --arg iac "$IAC" '.stacks += [{
    "_migrated": ("MIRROR of the claim in " + $iac + "//" + $main + "/agent/agentstack.yaml (see _comment). Sync on claim changes."),
    "name": $s,
    "repos": [$iac, $main],
    "mainRepo": $main,
    "coordinatorModel": "sonnet",
    "workerModel": "openrouter/deepseek/deepseek-v4-flash",
    "workerModelFallbacks": ["qwen/qwen3-coder", "tencent/hy3"]
  }]' agents/stacks.json > agents/stacks.json.tmp && mv agents/stacks.json.tmp agents/stacks.json
  echo "  stacks.json: added $STACK (models = current default chain; adjust per stack policy)"
fi

# ── 5. -iac sibling skeleton (jail only; oracle-iac is the reference) ─────────────────────────────
if [ -d "../$IAC" ] && [ -d ../oracle-iac ]; then
  subst() { sed -e "s/oracle-iac/$IAC/g" -e "s/oracle-fleet/$MAIN/g" -e "s/oracle/$STACK/g"; }
  scaffold() { # <src-rel-to-oracle-iac> <dst-rel-to-iac>
    if [ -f "../$IAC/$2" ]; then echo "  $IAC: $2 already present — skip"
    else mkdir -p "$(dirname "../$IAC/$2")"; subst < "../oracle-iac/$1" > "../$IAC/$2"; echo "  $IAC: wrote $2"; fi
  }
  scaffold apps/oracle-fleet.yaml                   "apps/$MAIN.yaml"
  scaffold oracle-fleet/agent/agentstack.yaml       "$MAIN/agent/agentstack.yaml"
  scaffold oracle-fleet/agent/workbench.yaml        "$MAIN/agent/workbench.yaml"
  scaffold devbox.json                              devbox.json
  scaffold scripts/ci.sh                            scripts/ci.sh
  scaffold .yamllint                                .yamllint
  scaffold .github/workflows/ci.yaml                .github/workflows/ci.yaml
  scaffold .gitignore                               .gitignore
  # New stacks start the egress dial in MONITOR (agentstack.md §The egress dial)
  sed -i 's/enforce: true/enforce: false/' "../$IAC/$MAIN/agent/agentstack.yaml" 2>/dev/null || true
  echo "  $IAC: REVIEW the diff — especially $MAIN/agent/agentstack.yaml (budget, egress profile; enforce starts false)"
else
  echo "  -iac skeleton SKIPPED (../$IAC or ../oracle-iac not checked out here) — scaffold it from oracle-iac by hand"
fi

# ── The un-codifiable remainder ───────────────────────────────────────────────────────────────────
cat <<EOF

Codifiable scaffolding done. The remainder, in order (then loop the lint):

  A. Review + commit:  git diff  (homelab)   and   git -C ../$IAC diff  (the skeleton)
  B. tofu/argocd.tf — hand-write two blocks (oracle is the reference, ~lines 147+274):
       - repo credential 'repo-$IAC-github' (private -iac; also add $IAC to the ArgoCD PAT's repo list)
       - the root '$STACK' app-of-apps Application over $IAC//apps
  C. OUT-OF-JAIL applies:
       devbox run github-tofu apply       (repos + rulesets + labels; untaint recipe in new-agent-repo output)
       devbox run tf-apply                (argocd.tf credential + root app)
  D. CLICK-ONLY — App installs on $MAIN (+$IAC for homelab-deploy/merge), then regenerate the matrix:
       https://github.com/organizations/$ORG/settings/installations
       devbox run github-apps
  E. Main-repo content ($MAIN): CLAUDE.md, .agents/{fix.yaml,review.md}, devbox ci + scan-secrets,
       merge-path callers (.github/workflows/{update-pr-branch,renovate-approve}.yml) —
       oracle-fleet is the reference shape (stack-template repo = the future collapse of this step).
  F. Stack jail (operator machine, claude-jail repo): a '$STACK' case entry in tools/stack-jail.sh
       + mint the per-stack PAT into .env.$STACK (template in the script header).

  Definition of done:   devbox run stack-lint $STACK
EOF
