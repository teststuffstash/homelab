#!/usr/bin/env bash
# new-stack — scaffold a NEW STACK's codifiable onboarding, end to end (FU-052's two layers).
#
#   devbox run new-stack <stack> [--main-repo <name>] [--iac <name>] [--public]
#                          [--from <donor-main-repo>] [--chainless]
#
#   --from      FU-070 middle ground: mechanically copy the shared surfaces from the donor's
#               jail checkout (../<donor>) + emit a VANILLA deployable chart/Dockerfile —
#               pipeline-proof on day one; the LLM-adaptation worklist prints at the end.
#   --chainless ADR-096 P5: seed the stacks.json mirror with NO workerModel +
#               routerMode: authoritative (router-routed per dispatch).
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

STACK=""; MAIN=""; IAC=""; VIS="--private"; FROM=""; CHAINLESS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --main-repo) MAIN="$2"; shift 2;;
    --iac)       IAC="$2"; shift 2;;
    --from)      FROM="$2"; shift 2;;      # donor stack MAIN repo for the surface copy (FU-070 middle ground)
    --chainless) CHAINLESS=1; shift;;      # ADR-096 P5: no workerModel, routerMode authoritative
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
# --no-labels: stack repo labels are claim-owned (FU-068) — the AgentStack claim's spec.repos[].labels
# renders an AUTHORITATIVE IssueLabels; a label_repos entry would be a second, fighting manager.
bash scripts/new-agent-repo.sh "$MAIN" "$VIS" --no-labels
# --public applies to BOTH repos (operator 2026-08-03, circles ruling): an -iac carries
# references-never-values by hard rule, so visibility is a per-stack choice, not a safety one.
# Bonus of a public -iac: ArgoCD needs NO repo credential for it.
bash scripts/new-agent-repo.sh "$IAC" "$VIS" --no-labels
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
  if [ "$CHAINLESS" = "1" ]; then
    # ADR-096 P5: no chain — the router's rotation universe supplies candidates; the launcher
    # REFUSES a chainless dispatch unless routerMode is authoritative.
    jq --arg s "$STACK" --arg main "$MAIN" --arg iac "$IAC" '.stacks += [{
      "_migrated": ("MIRROR of the claim in " + $iac + "//" + $main + "/agent/agentstack.yaml (see _comment). Sync on claim changes."),
      "name": $s,
      "repos": [$iac, $main],
      "mainRepo": $main,
      "coordinatorModel": "sonnet",
      "routerMode": "authoritative"
    }]' agents/stacks.json > agents/stacks.json.tmp && mv agents/stacks.json.tmp agents/stacks.json
    echo "  stacks.json: added $STACK (CHAINLESS — router-routed per dispatch, routerMode authoritative)"
  else
    jq --arg s "$STACK" --arg main "$MAIN" --arg iac "$IAC" '.stacks += [{
      "_migrated": ("MIRROR of the claim in " + $iac + "//" + $main + "/agent/agentstack.yaml (see _comment). Sync on claim changes."),
      "name": $s,
      "repos": [$iac, $main],
      "mainRepo": $main,
      "coordinatorModel": "sonnet",
      "workerModel": "deepseek/deepseek-v4-flash-0731",
      "workerModelFallbacks": ["xiaomi/mimo-v2.5", "tencent/hy3", "claude/haiku"]
    }]' agents/stacks.json > agents/stacks.json.tmp && mv agents/stacks.json.tmp agents/stacks.json
    echo "  stacks.json: added $STACK (models = the current evidence-based default chain)"
  fi
fi

# ── 5. -iac sibling skeleton (jail only; oracle-iac is the reference) ─────────────────────────────
if [ -d "../$IAC" ] && [ -d ../oracle-iac ]; then
  subst() { sed -e "s/oracle-iac/$IAC/g" -e "s/oracle-fleet/$MAIN/g" -e "s/oracle/$STACK/g"; }
  scaffold() { # <src-rel-to-oracle-iac> <dst-rel-to-iac>
    if [ -f "../$IAC/$2" ]; then echo "  $IAC: $2 already present — skip"
    else mkdir -p "$(dirname "../$IAC/$2")"; subst < "../oracle-iac/$1" > "../$IAC/$2"; echo "  $IAC: wrote $2"; fi
  }
  scaffold apps/oracle-fleet.yaml                   "apps/$MAIN.yaml"
  # Collision guard (circles lesson, 2026-08-03): the ROOT app-of-apps in tofu/argocd.tf is
  # named <stack>. When MAIN == STACK the scaffolded child Application inherits that same name
  # and the root SYNCS OVER ITSELF (then self-prunes once the name changes). Rename the child.
  if [ "$MAIN" = "$STACK" ] && grep -q "^  name: $MAIN$" "../$IAC/apps/$MAIN.yaml" 2>/dev/null; then
    sed -i "s/^  name: $MAIN$/  name: $MAIN-infra/" "../$IAC/apps/$MAIN.yaml"
    echo "  $IAC: apps/$MAIN.yaml child renamed → $MAIN-infra (root app-of-apps is named '$STACK' — identical child name makes the root sync over itself)"
  fi
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

# ── 5c. Main-repo surfaces (FU-070 MIDDLE GROUND, operator 2026-08-03): mechanical copy from
# the LIVING donor + a printed LLM-adaptation worklist. A template repo staleness-rots; a copy
# script does not — the CONTENT comes from the donor at run time, so only the SURFACE LIST here
# can stale, and it fails/warns LOUDLY when it does (missing expected file = list is stale;
# donor grew an unlisted workflow = named warning). PRODUCT SHAPE IS DELIBERATELY NOT COPIED:
# the chart/Dockerfile below are a VANILLA deployable (hello page) that proves build→deploy→
# sync E2E on day one; the real shape arrives via specs + the goal issue, and convergence is
# the cross-stack drift role's job — not this script's, not a template's.
if [ -n "$FROM" ]; then
  if [ ! -d "../$FROM" ] || [ ! -d "../$MAIN" ]; then
    echo "  --from $FROM: ../$FROM and/or ../$MAIN not checked out here — surfaces SKIPPED (jail step)"
  else
    FROM_US="$(printf '%s' "$FROM" | tr '-' '_')"; MAIN_US="$(printf '%s' "$MAIN" | tr '-' '_')"
    dsub() { sed -e "s/$FROM/$MAIN/g" -e "s/$FROM_US/$MAIN_US/g"; }
    LIST_STALE=0
    dcopy() { # dcopy <req|opt> <path>
      if [ ! -f "../$FROM/$2" ]; then
        if [ "$1" = req ]; then echo "  ✗ donor ../$FROM/$2 MISSING — the surface list in new-stack.sh is STALE; fix the list" >&2; LIST_STALE=1
        else echo "  donor lacks optional $2 — skip"; fi
        return 0
      fi
      if [ -f "../$MAIN/$2" ]; then echo "  $MAIN: $2 already present — skip"
      else mkdir -p "$(dirname "../$MAIN/$2")"; dsub < "../$FROM/$2" > "../$MAIN/$2"; echo "  $MAIN: wrote $2 (from $FROM)"; fi
    }
    SURFACES_REQ=".github/workflows/ci.yaml .github/workflows/deploy.yaml devbox.json devbox.lock .gitignore"
    SURFACES_OPT=".github/workflows/devbox-cache.yml .github/workflows/ghcr-cleanup.yaml
      .github/workflows/renovate-approve.yaml .github/workflows/update-pr-branch.yml
      .pre-commit-config.yaml .dockerignore
      .agents/fix.yaml .agents/review.yaml .agents/review.md .agents/research.yaml .agents/build.yaml
      scripts/ci.sh scripts/test-chart.sh scripts/validate-chart.sh scripts/package-chart.sh
      scripts/build-image.sh scripts/deploy-pin.sh"
    for f in $SURFACES_REQ; do dcopy req "$f"; done
    for f in $SURFACES_OPT; do dcopy opt "$f"; done
    # donor growth: workflows the donor has that the list does not know
    ALL_SURFACES=$(echo $SURFACES_REQ $SURFACES_OPT) # unquoted on purpose: newlines → single spaces
    for wf in "../$FROM/.github/workflows/"*; do
      b=".github/workflows/$(basename "$wf")"
      case " $ALL_SURFACES " in *" $b "*) ;; *)
        echo "  ⚠ donor has $b — NOT in the surface list (product-specific like integration.yaml, or the list is behind; judge)";;
      esac
    done
    [ "$LIST_STALE" = 1 ] && echo "  ⚠ STALE SURFACE LIST above — extend it in scripts/new-stack.sh before trusting this copy"

    # A donor defect is inherited SILENTLY: sleep-tracking's research.yaml carried a missing
    # colon-space here, latent (its own rides used the claude harness, which never YAML-parses the
    # recipe) until circles' goose arms all died on it. Parse what we just copied, at copy time.
    for f in "../$MAIN/.agents/"*.yaml; do
      [ -f "$f" ] || continue
      bash "$ROOT/agents/recipe-lint.sh" "$f" \
        || echo "  ⚠ INHERITED a broken recipe from $FROM — fix it in BOTH repos (the donor is still shipping it)"
    done

    # Vanilla deployable: chart + Dockerfile + hello page (only if absent)
    if [ ! -d "../$MAIN/chart" ]; then
      mkdir -p "../$MAIN/chart/templates" "../$MAIN/chart/tests" "../$MAIN/public"
      cat > "../$MAIN/chart/Chart.yaml" <<CH
apiVersion: v2
name: $MAIN
description: $STACK stack — vanilla bootstrap chart (shape arrives via specs; chart-is-deployable-unit)
type: application
version: 0.0.0-dev # CI stamps calver-gsha (deploy.yaml)
appVersion: 0.0.0-dev
CH
      cat > "../$MAIN/chart/values.yaml" <<CH
image:
  repository: ghcr.io/$ORG/$MAIN
  pullPolicy: IfNotPresent
  tag: "" # chart appVersion by default
port: 8080
resources:
  requests: { cpu: 25m, memory: 32Mi }
  limits: { memory: 64Mi }
CH
      cat > "../$MAIN/chart/values.schema.json" <<'CH'
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "image": {
      "type": "object",
      "properties": {
        "repository": { "type": "string" },
        "pullPolicy": { "type": "string", "enum": ["Always", "IfNotPresent", "Never"] },
        "tag": { "type": "string" }
      }
    },
    "port": { "type": "integer" },
    "resources": { "type": "object" }
  }
}
CH
      cat > "../$MAIN/chart/templates/deployment.yaml" <<CH
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels: { app.kubernetes.io/name: {{ .Chart.Name }} }
spec:
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: {{ .Chart.Name }} }
  template:
    metadata:
      labels: { app.kubernetes.io/name: {{ .Chart.Name }} }
    spec:
      securityContext: { runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports: [{ containerPort: {{ .Values.port }}, name: http }]
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
          readinessProbe: { httpGet: { path: /, port: http } }
          resources: {{- toYaml .Values.resources | nindent 12 }}
CH
      cat > "../$MAIN/chart/templates/service.yaml" <<CH
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels: { app.kubernetes.io/name: {{ .Chart.Name }} }
spec:
  selector: { app.kubernetes.io/name: {{ .Chart.Name }} }
  ports: [{ name: http, port: 80, targetPort: http }]
CH
      cat > "../$MAIN/chart/tests/deployment_test.yaml" <<CH
suite: vanilla deployment
templates: [deployment.yaml]
tests:
  - it: renders a Deployment with the pinned image
    set: { image: { tag: 1.2.3 } }
    asserts:
      - isKind: { of: Deployment }
      # block style on purpose: '[0]' brackets are invalid in a flow-mapping plain scalar
      - equal:
          path: spec.template.spec.containers[0].image
          value: "ghcr.io/$ORG/$MAIN:1.2.3"
CH
      cat > "../$MAIN/Dockerfile" <<CH
# Vanilla bootstrap image ($STACK): serves the hello page so the deploy pipeline is E2E-provable
# on day one. Replaced by the real product image via specs — never grow it in place.
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY public/ /usr/share/nginx/html/
CH
      cat > "../$MAIN/public/index.html" <<CH
<!doctype html><title>$MAIN</title>
<h1>$MAIN — vanilla bootstrap</h1>
<p>The $STACK stack's deploy pipeline works. The real page arrives via specs.</p>
CH
      echo "  $MAIN: vanilla chart + Dockerfile + hello page written (pipeline-proof; shape via specs)"
    else
      echo "  $MAIN: chart/ already present — vanilla deployable skipped"
    fi
    [ -f "../$MAIN/CLAUDE.md" ] || cat > "../$MAIN/CLAUDE.md" <<CH
# CLAUDE.md — $MAIN ($STACK stack)

SKELETON (new-stack --from $FROM): the LLM-adaptation pass fills this — read order, the CI
gate (\`devbox run ci\` green before any PR), invariants, related repos as GitHub URLs
(workers clone ONLY this repo — the issue carries all cross-repo context).
CH
    echo ""
    echo "  LLM-ADAPTATION WORKLIST (the judgment half of FU-070 — do this in a homelab session):"
    echo "    1. Donor remnants:   grep -rniE '$FROM|$FROM_US' ../$MAIN — judge each (names, product ci steps)"
    echo "    2. scripts/ci.sh:    trim $FROM-product test invocations the vanilla chart can't satisfy"
    echo "    3. CLAUDE.md:        fill the skeleton"
    echo "    4. .agents/*.yaml:   recipe text mentions of $FROM paths/domains"
    echo "    5. devbox.json:      drop $FROM-only scripts; devbox run ci must pass on the vanilla chart"
  fi
fi

# ── The un-codifiable remainder ───────────────────────────────────────────────────────────────────
cat <<EOF

Codifiable scaffolding done. The remainder, in order (then loop the lint):

  A. Review + commit:  git diff  (homelab)   and   git -C ../$IAC diff  (the skeleton)
  B. tofu/argocd.tf — hand-write two blocks (oracle is the reference, ~lines 147+274):
       - repo credential 'repo-$IAC-github' — ONLY if the -iac is PRIVATE (public needs no
         credential; skip the block and the ArgoCD PAT list entry entirely)
       - the root '$STACK' app-of-apps Application over $IAC//apps
  C. OUT-OF-JAIL applies:
       devbox run github-tofu apply       (repos + rulesets + labels; untaint recipe in new-agent-repo output)
       devbox run tf-apply                (argocd.tf credential + root app)
  D. CLICK-ONLY — App installs on $MAIN (+$IAC for homelab-deploy/merge), then regenerate the matrix:
       https://github.com/organizations/$ORG/settings/installations
       devbox run github-apps
  E. Main-repo content ($MAIN): if you ran --from <donor>, the surfaces are copied and the
       LLM-ADAPTATION WORKLIST above is the remaining judgment half (homelab session).
       Without --from: copy by hand from the freshest graduated stack.

  E2. WARM THE TOOLCHAIN (FU-096/FU-130) — run the devbox-cache workflow on $MAIN, then make the
       ghcr package PUBLIC (Packages → devbox-cache → visibility). The launcher mounts it at
       /stack-cache only if an ANONYMOUS pull works, and until then every ride pays cold nix
       eval (55s vs 4s seeded). stack-lint CACHE-01 probes exactly what the launcher probes:
         gh workflow run devbox-cache.yml -R $ORG/$MAIN
         https://github.com/orgs/$ORG/packages/container/$MAIN%2Fdevbox-cache/settings
  F. Stack jail (operator machine, claude-jail repo): an overlay entry (UPLOAD_PORT/PRIMARY
       [+ private mounts]) in tools/stack-jail.sh — repos/ns derive from stacks.json since
       2026-08-03 — + mint the per-stack PAT into .env.$STACK (template in the script header).

  G. OPTIONAL, and only if the stack serves a specs site under its own subdomain (ADR-092 —
       the WEB-01..03 checks stay silent for stacks that don't). Three parts, in this order:
       1. homelab wildcard — add to ansible/group_vars/opnsense.yml a wildcard cert
          ({ name: $STACK.teststuff.net, alt_names: ["*.$STACK.teststuff.net"], … }; the CN must
          be a real domain, the wildcard rides alt_names) and a stack_gateways entry on a FREE
          3.x <-> 40.x mirror pair. Then:
            bash scripts/opnsense-playbook.sh ansible/opnsense-acme.yml
            bash scripts/opnsense-playbook.sh ansible/opnsense-haproxy.yml
          The VIP-alias reconfigure can flush FRR's kernel routes and black-hole every 40.x while
          BGP still reads Established — re-probe a couple of existing VIPs after (runbook).
          If the site is served from Garage, add a ReferenceGrant in ns garage for HTTPRoutes
          from the stack's ns (argocd/platform/<stack>-gateway-refgrant.yaml).
       2. the stack's -iac — a Gateway on the 40.x VIP + one HTTPRoute per hostname. NOT homelab's.
       3. OPERATOR, once, and the jail cannot do it: the repo Actions secrets for the publish
          workflow, from the Crossplane-minted connection Secret. The jail PAT deliberately lacks
          the Secrets permission (docs/github-setup.md), so this is a host-side step:
            kubectl get secret <stack>-specs-s3 -n <stack> \
              -o jsonpath='{.data.writer_access_key_id}' | base64 -d \
              | gh secret set SPECS_S3_ACCESS_KEY_ID -R $ORG/$MAIN
            # …and writer_secret_access_key -> SPECS_S3_SECRET_ACCESS_KEY
          Use the WRITER pair. The reader pair authenticates fine and then 403s on upload.
       WHY THIS IS EASY TO MISS: specs-publish.sh SOFT-SKIPS when the credentials are absent, so
       until step 3 lands CI is green and the site is empty. WEB-03 probes the served site rather
       than the secrets (which the jail cannot read) precisely to catch that.

  Definition of done:   devbox run stack-lint $STACK
EOF
