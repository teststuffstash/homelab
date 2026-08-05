#!/usr/bin/env bash
# stack-lint — the stack-onboarding CHECKLIST as deterministic checks (FU-052's two layers).
#
#   devbox run stack-lint [<stack>|--all]        (default --all)
#
# There is deliberately NO new-stack.md runbook: a checklist doc rots silently, a red check drains
# itself (the merge-gate doctrine, teststuff specs-for-agentic-delivery). Every onboarding
# requirement is a probe here; the lint's output IS the checklist. Scaffold with
# `devbox run new-stack`, then loop this until green.
#
# Check states (the meta-5 probe principle — "cannot see" is never "missing"):
#   OK            requirement verified
#   FAIL          requirement missing → exit 1
#   CLICK-PENDING browser-only step not done (App install) → exit 1; this check reads the SERVED
#                 live install matrix (github-exporter /apps, FU-098) via the apiserver proxy
#   WARN          recommended, not yet required platform-wide (doesn't fail)
#   PROBE-FAILED  the check could not see (no cluster creds / 404-as-403 / not on the operator
#                 machine) — never counted as missing, but listed so nothing hides
#
# Sources of truth probed:
#   agents/stacks.json          build-time stack universe (committed mirror of the claims)
#   kubectl get agentstacks     runtime truth (claim exists + READY)
#   tofu/github/*.tf            repos / protected_repos / label_repos (labels move into the
#                               claim with FU-068 — swap GH-03's source then)
#   gh api                      repo content probes (visibility probe FIRST, per registration-lint)
#   github-exporter /apps       SERVED live App-install matrix (click-only surface, FU-098)
#   ../tools/stack-jail.sh      operator-machine jail wiring (claude-jail repo, jail only)
#
# Fixer vs context-only: *-iac repos and homelab are context/deploy targets (FU-052 exclusion,
# same rule as agents-registration-lint's CALLERS_EXEMPT) — they skip fixer-only checks.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ORG="${ORG:-teststuffstash}"

TARGET="${1:---all}"
fails=0 clicks=0

say() { # <state> <id> <stack> <msg>
  printf '%-13s %-8s %-9s %s\n' "$1" "$2" "$3" "$4"
  case "$1" in FAIL) fails=$((fails+1));; CLICK-PENDING) clicks=$((clicks+1));; esac
}

is_fixer() { case "$1" in *-iac|homelab) return 1;; *) return 0;; esac; }

# ── cluster reachability (once) ────────────────────────────────────────────────
KUBE_OK=0
if timeout 10 kubectl get --raw /readyz >/dev/null 2>&1; then KUBE_OK=1; fi

# ── gh reachability is probed per repo (visibility first) ─────────────────────
HAVE_GH=0; command -v gh >/dev/null 2>&1 && HAVE_GH=1

# ── ghcr reachability (once) — the CACHE-01 disambiguator. agent-base always exists, so a failure
# here means "no ghcr from this box", never "the package is missing".
GHCR_OK=0
timeout 10 curl -fsS "https://ghcr.io/token?scope=repository:$ORG/agent-base:pull" >/dev/null 2>&1 && GHCR_OK=1

# App-install matrix lookup: prints INSTALLED / MISSING / NO-ROW / NO-SOURCE for <repo> <app-base>.
# Source is the SERVED live view (github-exporter /apps, FU-098 finale) — docs/github-apps.md is
# no longer committed (the deep-verify report goes to /tmp). Fetched ONCE via the apiserver
# service proxy; without a cluster the check degrades to PROBE-FAILED, never "missing".
APPS_HTML="/tmp/stack-lint-apps.$$"
trap 'rm -f "$APPS_HTML"' EXIT
if [ "$KUBE_OK" = 1 ]; then
  timeout 15 kubectl get --raw \
    "/api/v1/namespaces/monitoring/services/github-exporter:9504/proxy/apps" \
    >"$APPS_HTML" 2>/dev/null || true
fi
app_installed() { # <repo> <app-base>
  # NB the page file is argv[3], NOT piped: `python3 -` takes its PROGRAM from stdin (the
  # heredoc), so piping data into the same stdin silently reads empty.
  [ -s "$APPS_HTML" ] || { echo "NO-SOURCE"; return; }
  python3 - "$1" "$2" "$APPS_HTML" <<'PY'
import html, re, sys
repo, app = sys.argv[1], sys.argv[2]
text = html.unescape(open(sys.argv[3]).read())
# page shape per app: <h2><code>NAME</code></h2> … <p>installs: selected → r1, r2, …</p>
for sec in re.split(r"<h2><code>", text)[1:]:
    if sec.split("</code>", 1)[0] != app:
        continue
    m = re.search(r"installs:\s*(all|selected)\s*(?:→)?\s*([^<]*)", sec)
    if not m:
        print("NO-ROW"); raise SystemExit
    repos = [r.strip() for r in m.group(2).split(",") if r.strip()]
    print("INSTALLED" if (m.group(1) == "all" or repo in repos) else "MISSING")
    raise SystemExit
print("NO-ROW")
PY
}

lint_stack() { # <name>
  local stack="$1"
  local repos mainRepo
  repos=$(jq -r --arg s "$stack" '.stacks[] | select(.name==$s) | .repos[]' agents/stacks.json)
  mainRepo=$(jq -r --arg s "$stack" '.stacks[] | select(.name==$s) | .mainRepo // "homelab"' agents/stacks.json)
  if [ -z "$repos" ]; then
    say FAIL REG-01 "$stack" "no entry in agents/stacks.json (the committed claim mirror)"
    return
  fi
  say OK REG-01 "$stack" "stacks.json entry (repos: $(echo $repos | tr '\n' ' '))"

  # REG-02 — cluster claim exists + READY (runtime truth)
  if [ "$KUBE_OK" = 1 ]; then
    local ready
    ready=$(timeout 10 kubectl get agentstack "$stack" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    case "$ready" in
      True)  say OK REG-02 "$stack" "AgentStack claim Ready" ;;
      "")    say FAIL REG-02 "$stack" "no AgentStack claim in cluster — declare it in the -iac repo (agentstack.md)" ;;
      *)     say FAIL REG-02 "$stack" "AgentStack claim exists but Ready=$ready (composed git-token not minted?)" ;;
    esac
  else
    say PROBE-FAILED REG-02 "$stack" "cluster unreachable — claim state unknown"
  fi

  # REG-04 — the AgentStack's ArgoCD app is Synced. An OutOfSync app almost always means the claim
  # OMITS a server-default field the API server stamps into the stored object (the claim must
  # declare EVERY defaulted field it relies on — arrays, enums AND bools; see agent-fixer.yaml's
  # ignoreDifferences note). The app name is carried on the claim's own tracking-id annotation.
  if [ "$KUBE_OK" = 1 ]; then
    local app appsync
    app=$(timeout 10 kubectl get agentstack "$stack" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null | cut -d: -f1)
    if [ -z "$app" ]; then
      say PROBE-FAILED REG-04 "$stack" "no ArgoCD tracking-id on the claim — managing app unknown"
    else
      appsync=$(timeout 10 kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null)
      case "$appsync" in
        Synced) say OK REG-04 "$stack" "ArgoCD app $app Synced" ;;
        "")     say PROBE-FAILED REG-04 "$stack" "ArgoCD app $app not found/readable" ;;
        *)      say FAIL REG-04 "$stack" "ArgoCD app $app is $appsync — claim likely omits a server-default field (declare it explicitly; see agent-fixer.yaml)" ;;
      esac
    fi
  else
    say PROBE-FAILED REG-04 "$stack" "cluster unreachable — app sync unknown"
  fi

  local repo res
  for repo in $repos; do
    res=$(printf '%s' "$repo" | tr '-' '_')

    # GH-01/02/03 — tofu/github coverage (local files, no network)
    if grep -qE "resource \"github_repository\" \"$res\"" tofu/github/repos.tf; then
      say OK GH-01 "$stack" "$repo in repos.tf"
    else
      say FAIL GH-01 "$stack" "$repo missing from tofu/github/repos.tf — scripts/new-agent-repo.sh $repo"
    fi
    if grep -qE "^\s+\"?$repo\"?\s*=\s*\{" tofu/github/variables.tf; then
      say OK GH-02 "$stack" "$repo in protected_repos (required checks)"
    else
      say FAIL GH-02 "$stack" "$repo missing from protected_repos (tofu/github/variables.tf) — unprotected: agent PRs could stall or bypass CI"
    fi
    # Labels are claim-owned for stack repos (FU-068, shipped 2026-07-16): the claim's composed
    # IssueLabels is AUTHORITATIVE, so a label_repos entry is a second manager that fights it.
    if [ ! -f tofu/github/labels.tf ]; then
      # The file is GONE (FU-068 handoff complete, 2026-08-04) — there is no second manager left.
      say OK GH-03 "$stack" "$repo labels claim-owned (FU-068) — tofu/github/labels.tf retired"
    elif grep -qE "^\s*label_repos\s*=.*\"$repo\"" tofu/github/labels.tf; then
      say FAIL GH-03 "$stack" "$repo in label_repos — labels are claim-owned (FU-068); drop it (if ever applied: tofu state rm scoped to ^github_issue_label\\. first)"
    else
      say OK GH-03 "$stack" "$repo labels claim-owned (FU-068) — label_repos clean"
    fi

    # GH-04 — App installs (generated matrix; a miss is a CLICK, then `devbox run github-apps`)
    local need_apps="homelab-merge"
    if is_fixer "$repo"; then need_apps="homelab-agents homelab-merge homelab-reviewer"
    elif [ "$repo" != "homelab" ]; then need_apps="homelab-deploy homelab-merge"; fi
    local app st
    for app in $need_apps; do
      st=$(app_installed "$repo" "$app")
      case "$st" in
        INSTALLED) say OK GH-04 "$stack" "$app installed on $repo (live exporter /apps view)" ;;
        MISSING)   say CLICK-PENDING GH-04 "$stack" "$app NOT installed on $repo — browser install (exporter /apps refreshes on its next poll)" ;;
        NO-SOURCE) say PROBE-FAILED GH-04 "$stack" "$repo/$app unknown — exporter /apps unreachable (needs cluster access)" ;;
        *)         say PROBE-FAILED GH-04 "$stack" "$repo/$app not resolvable on the exporter /apps page ($st)" ;;
      esac
    done
    if is_fixer "$repo" && [ "$(app_installed "$repo" homelab-renovate)" = MISSING ]; then
      say WARN GH-04 "$stack" "homelab-renovate not installed on $repo — no dep-bump lane (policy choice)"
    fi

    # REPO-* — content probes (probe visibility FIRST; an unreadable repo is never "missing")
    if [ "$HAVE_GH" = 1 ] && timeout 15 gh api "repos/$ORG/$repo" --jq .name >/dev/null 2>&1; then
      local wf found
      found=0
      for wf in ci.yaml ci.yml; do
        timeout 15 gh api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq .name >/dev/null 2>&1 && found=1 && break
      done
      if [ "$found" = 1 ]; then say OK REPO-04 "$stack" "$repo has a ci workflow"
      else say FAIL REPO-04 "$stack" "$repo has no .github/workflows/ci.y(a)ml — required check can never report"; fi

      # CACHE-01 — the FU-096 stack devbox-cache must be PUBLICLY pullable, because that is the
      # condition the launcher actually tests (agent-session.sh: anonymous ghcr token + a manifest
      # HEAD) before mounting it at /stack-cache. Without it every ride pays cold bring-up — 55s of
      # nix EVAL vs 4s seeded (FU-015/FU-096 measurements) — and the only signal today is one line
      # in a pod log. Two failure modes it catches, and they look identical from outside: the
      # devbox-cache workflow never ran, or the package exists but is still private. FU-130.
      if is_fixer "$repo"; then
        local sc_tok sc_code
        sc_tok=$(timeout 10 curl -fsS "https://ghcr.io/token?scope=repository:$ORG/$repo/devbox-cache:pull" 2>/dev/null \
                 | jq -r '.token // empty' 2>/dev/null)
        if [ -z "$sc_tok" ]; then
          # ghcr's token endpoint also fails for a package that does not exist, so a bare failure is
          # ambiguous. GHCR_OK (probed once against a package that definitely exists) resolves it:
          # ghcr reachable ⇒ the devbox-cache package was never published; unreachable ⇒ cannot see.
          if [ "$GHCR_OK" = 1 ]; then
            say WARN CACHE-01 "$stack" "$repo has no devbox-cache package at ghcr — every ride pays cold nix eval; add .github/workflows/devbox-cache.yml, run it, then make the package public (FU-096/FU-130)"
          else
            say PROBE-FAILED CACHE-01 "$stack" "$repo — ghcr unreachable from here; devbox-cache visibility unknown"
          fi
        else
          sc_code=$(timeout 10 curl -o /dev/null -s -w '%{http_code}' -I -H "Authorization: Bearer $sc_tok" \
            -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json" \
            "https://ghcr.io/v2/$ORG/$repo/devbox-cache/manifests/latest" 2>/dev/null)
          case "$sc_code" in
            200) say OK CACHE-01 "$stack" "$repo devbox-cache:latest is public at ghcr (rides mount it — warm bring-up)" ;;
            403|404) say WARN CACHE-01 "$stack" "$repo has no PUBLIC devbox-cache:latest at ghcr (HTTP $sc_code) — every ride pays cold nix eval; run the devbox-cache workflow, then make the ghcr package public (FU-096/FU-130)" ;;
            *) say PROBE-FAILED CACHE-01 "$stack" "$repo devbox-cache manifest probe returned HTTP $sc_code — visibility unknown" ;;
          esac
        fi
        local f
        for f in .agents/fix.yaml .agents/review.md; do
          if timeout 15 gh api "repos/$ORG/$repo/contents/$f" --jq .name >/dev/null 2>&1; then
            say OK REPO-03 "$stack" "$repo has $f"
          else
            say FAIL REPO-03 "$stack" "$repo missing $f (worker/reviewer recipe — repo content, versioned with the code)"
          fi
        done
        # REPO-06 — every recipe must PARSE. An unparseable one is invisible until ~30s into a
        # ride (goose "Invalid recipe"), by which time the pod, the token and the spend are gone;
        # the missing colon-space that new-stack.sh copied sleep-tracking→circles killed all four
        # FU-126 goose arms that way. Same gate the launcher runs pre-dispatch (agents/recipe-lint.sh).
        local y tmp why
        # NB process substitution, NOT a pipe: `... | while read` runs the loop in a SUBSHELL and
        # every say FAIL would be lost from the exit code.
        while read -r y; do
          [ -n "$y" ] || continue
          tmp="$(mktemp)"
          if timeout 15 gh api "repos/$ORG/$repo/contents/.agents/$y" --jq .content 2>/dev/null \
               | base64 -d > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
            if why="$(bash "$ROOT/agents/recipe-lint.sh" "$tmp" 2>&1)"; then
              say OK REPO-06 "$stack" "$repo .agents/$y parses"
            else
              say FAIL REPO-06 "$stack" "$repo .agents/$y is UNPARSEABLE — ${why#*— }"
            fi
          else
            say PROBE-FAILED REPO-06 "$stack" "$repo .agents/$y unreadable — parse check skipped"
          fi
          rm -f "$tmp"
        done < <(timeout 15 gh api "repos/$ORG/$repo/contents/.agents" \
                   --jq '.[]|select(.name|endswith(".yaml"))|.name' 2>/dev/null)
      fi
      if [ "$repo" = "$mainRepo" ]; then
        if timeout 15 gh api "repos/$ORG/$repo/contents/CLAUDE.md" --jq .name >/dev/null 2>&1; then
          say OK REPO-05 "$stack" "$repo has CLAUDE.md (coordinator cwd context)"
        else
          say FAIL REPO-05 "$stack" "mainRepo $repo has no CLAUDE.md — the coordinator's cwd context is empty"
        fi
      fi
    else
      say PROBE-FAILED REPO-0x "$stack" "$repo unreadable with this token — content checks skipped (probe failure ≠ missing)"
    fi

    # K8S-01 — fixer namespace (belongs to the repo's deployment, precreated by the platform)
    if is_fixer "$repo"; then
      if [ "$KUBE_OK" = 1 ]; then
        if timeout 10 kubectl get ns "$repo" >/dev/null 2>&1; then
          say OK K8S-01 "$stack" "namespace $repo exists"
        else
          say FAIL K8S-01 "$stack" "namespace $repo missing — the claim's composed resources have nowhere to land"
        fi
      else
        say PROBE-FAILED K8S-01 "$stack" "cluster unreachable — namespace $repo unknown"
      fi
    fi

    # KEY-01 — the standing funding key: Secret present AND the guardrail the proxy will enforce
    # equals the one the claim asks for. Both halves are bootstrap traps that cost live rides:
    # a missing Secret 401s every completion, and a guardrail mismatch 403s them pre-spend
    # (circles-iac#1, FU-138). The proxy resolves the guardrail from the OpenRouterKey CR, so the
    # CR is what gets compared; a stale Secret field is a WARN, not a FAIL, since it no longer
    # decides anything. Claim (cluster) is the source for "asked for" — the mirror carries no fixer.
    if is_fixer "$repo"; then
      if [ "$KUBE_OK" = 1 ]; then
        local want_gr have_gr sec_gr
        want_gr=$(timeout 10 kubectl get agentstack "$stack" -o json 2>/dev/null \
          | jq -r --arg r "$repo" '[.spec.repos[]|select(.name==$r)|select(.fixer)|.fixer.guardrail // "only-free"][0] // "NO-FIXER"')
        if [ "$want_gr" = "NO-FIXER" ]; then
          : # context-only repo in a claim: no standing key is expected
        elif ! timeout 10 kubectl -n "$repo" get secret "$repo-openrouter" >/dev/null 2>&1; then
          say FAIL KEY-01 "$stack" "no Secret $repo-openrouter in ns $repo — the fixer block asks for a standing key; every ride would 401 (operator mints it: the OpenRouterKey CR is composed, so check the openrouter-operator logs)"
        else
          have_gr=$(timeout 10 kubectl -n "$repo" get openrouterkeys -o json 2>/dev/null \
            | jq -r --arg s "$repo-openrouter" '[.items[]|select((.spec.secretName // (.spec.project + "-openrouter"))==$s)|.spec.guardrail // "none"][0] // "NO-CR"')
          sec_gr=$(timeout 10 kubectl -n "$repo" get secret "$repo-openrouter" -o jsonpath='{.data.GUARDRAIL}' 2>/dev/null | base64 -d 2>/dev/null)
          if [ "$have_gr" = "NO-CR" ]; then
            say FAIL KEY-01 "$stack" "Secret $repo-openrouter exists but no OpenRouterKey CR owns it — nothing renders the guardrail the claim asks for ($want_gr); the key is unmanaged (FU-138)"
          elif [ "$have_gr" = "$want_gr" ]; then
            say OK KEY-01 "$stack" "standing key $repo-openrouter, guardrail $have_gr matches the claim"
            [ "${sec_gr:-none}" = "$want_gr" ] || say WARN KEY-01 "$stack" "$repo-openrouter Secret still says GUARDRAIL='${sec_gr:-<absent>}' — inert since FU-138 (the proxy reads the CR), left from a pre-fix hand patch"
            # KEY-02 — only-free × a PAID chain is a guaranteed-dead lane: the guardrail 403s every
            # completion before spend, so the ride cannot start and burns a round on each retry.
            # This became visible only once FU-138 made guardrails actually take effect; the
            # homelab fixer block already records the reasoning ("only-free would 403 every
            # completion before spend"), which applies to any stack whose chain is paid.
            if [ "$have_gr" = "only-free" ]; then
              local paid
              paid=$(jq -r --arg s "$stack" '[.stacks[]|select(.name==$s)|(.workerModel // empty),(.workerModelFallbacks // [])[]]|map(select(endswith(":free")|not))|join(", ")' agents/stacks.json)
              if [ -n "$paid" ]; then
                say FAIL KEY-02 "$stack" "$repo is guardrailed only-free but the stack chain is PAID ($paid) — every ride 403s pre-spend (FU-024/FU-138); either open the guardrail (budgetUSD is the real bound, as homelab's fixer block argues) or give the repo a :free chain"
              else
                say OK KEY-02 "$stack" "$repo only-free and the chain is all :free"
              fi
            fi
          else
            say FAIL KEY-01 "$stack" "guardrail MISMATCH on $repo: claim asks '$want_gr', OpenRouterKey CR says '$have_gr' — the proxy enforces the CR, so rides get the wrong answer (FU-138)"
          fi
        fi
      else
        say PROBE-FAILED KEY-01 "$stack" "cluster unreachable — standing key/guardrail unknown"
      fi
    fi
  done

  # PVC-01 — the loop's transcripts PVC must sit on a SINGLE-replica StorageClass. Predicate is the
  # class's numberOfReplicas, not its name: homelab#94 wedged because a 2-replica volume could not
  # place (only one schedulable `std` disk), the janitor hung 40 min on the attach, and
  # `storageClassName` is IMMUTABLE — so a wrong class here is only fixable by delete+recreate.
  # Transcripts are mirrored to Garage by transcripts-sync, so replication buys nothing (FU-132).
  if [ "$KUBE_OK" = 1 ]; then
    local tsc trepl
    tsc=$(timeout 10 kubectl -n "$stack-agents" get pvc coordinator-transcripts \
      -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
    if [ -z "$tsc" ]; then
      say PROBE-FAILED PVC-01 "$stack" "no coordinator-transcripts PVC in ns $stack-agents (per-stack loop not rendered?) — storage class unknown"
    else
      trepl=$(timeout 10 kubectl get sc "$tsc" -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null)
      case "$trepl" in
        1)  say OK PVC-01 "$stack" "transcripts PVC on $tsc (numberOfReplicas=1)" ;;
        "") say PROBE-FAILED PVC-01 "$stack" "storage class $tsc declares no numberOfReplicas — replica count unknown" ;;  # NB: a bare `?` here would MATCH "2" (single-char glob)
        *)  say FAIL PVC-01 "$stack" "transcripts PVC is on $tsc (numberOfReplicas=$trepl) — a replicated class can leave the volume unplaceable and hang every tick (homelab#94); storageClassName is immutable, so fix = delete+recreate onto longhorn-single (FU-132)" ;;
      esac
    fi
  else
    say PROBE-FAILED PVC-01 "$stack" "cluster unreachable — transcripts storage class unknown"
  fi

  # K8S-02 — workbench SA (the stack-jail kubectl identity; new pattern, WARN until platform-wide).
  # mainRepo=homelab means the stack is driven from the mono jail — no per-stack workbench applies.
  if [ "$mainRepo" = "homelab" ]; then
    say WARN K8S-02 "$stack" "mainRepo is homelab (mono-jail stack) — per-stack workbench/jail pattern not adopted"
  elif [ "$KUBE_OK" = 1 ]; then
    if timeout 10 kubectl get sa "$stack-workbench" -n "$mainRepo" >/dev/null 2>&1; then
      say OK K8S-02 "$stack" "workbench SA $stack-workbench@$mainRepo (stack-jail kubectl)"
    else
      say WARN K8S-02 "$stack" "no $stack-workbench SA in ns $mainRepo — stack jail runs without kubectl (add <iac>//$mainRepo/agent/workbench.yaml)"
    fi
  else
    say PROBE-FAILED K8S-02 "$stack" "cluster unreachable — workbench SA unknown"
  fi

  # ── WEB-01..03 — per-stack subdomain delegation + specs publishing (ADR-092) ────────────
  # OPT-IN: only checked once the stack shows intent — a `stack_gateways` entry here, or a
  # specs-publish workflow in its main repo. A stack with neither is not behind on anything.
  #
  # Why there is no "are the repo Actions secrets set?" check: the jail PAT deliberately lacks the
  # Secrets permission (docs/github-setup.md, verified 403 again 2026-08-04), so such a probe could
  # only ever be PROBE-FAILED — and "cannot see" is never "missing". The END STATE is visible
  # instead, and it is strictly better evidence: if specs.<stack> serves 200, then the secrets, CI,
  # Garage, the Gateway, HAProxy and DNS all work. That matters here because the publish script
  # SOFT-SKIPS on absent credentials (`specs-publish: no S3 credentials in env — skipping`), so a
  # stack with unset secrets has GREEN CI and an empty site. Green-and-doing-nothing is the failure
  # this check exists to make loud.
  local gw_entry="" specs_wf=0
  # yq, not grep: the stack_gateways entries wrap across two lines, so a line-oriented match
  # silently reports "no entry" for one that is right there (caught on circles, 2026-08-04).
  if command -v yq >/dev/null 2>&1; then
    gw_entry=$(yq -r ".stack_gateways[] | select(.name == \"${stack}-gw\") | .vip" ansible/group_vars/opnsense.yml 2>/dev/null | grep -E '^[0-9.]+$' || true)
  fi
  if [ "$HAVE_GH" = 1 ] && gh api "repos/$ORG/$mainRepo/contents/.github/workflows/specs-site.yaml" >/dev/null 2>&1; then specs_wf=1; fi

  if [ -n "$gw_entry" ] || [ "$specs_wf" = 1 ]; then
    # WEB-01 — homelab's half: the wildcard cert + the 3.x↔40.x HAProxy VIP entry.
    if [ -z "$gw_entry" ]; then
      say FAIL WEB-01 "$stack" "$mainRepo publishes a specs site but there is no ${stack}-gw in ansible/group_vars/opnsense.yml — add the wildcard cert + a free 3.x↔40.x pair, then run opnsense-{acme,haproxy}.yml"
    elif ! grep -q "\*\.${stack}\.teststuff\.net" ansible/group_vars/opnsense.yml 2>/dev/null; then
      say FAIL WEB-01 "$stack" "${stack}-gw exists but no *.${stack}.teststuff.net wildcard in acme_cert_specs — HAProxy will serve the wrong cert"
    else
      say OK WEB-01 "$stack" "wildcard cert + ${stack}-gw VIP $gw_entry in group_vars"
    fi

    # WEB-02 — the wildcard override actually resolves. Probed with a name nobody would ever add,
    # so this proves the WILDCARD, not a leftover per-name override.
    if command -v dig >/dev/null 2>&1 && [ -n "$gw_entry" ]; then
      local got
      got=$(timeout 8 dig +short "stack-lint-probe.${stack}.teststuff.net" @192.168.2.1 2>/dev/null | tail -1)
      if [ "$got" = "$gw_entry" ]; then
        say OK WEB-02 "$stack" "*.${stack}.teststuff.net resolves to $gw_entry (wildcard, not per-name)"
      elif [ -z "$got" ]; then
        say FAIL WEB-02 "$stack" "*.${stack}.teststuff.net does not resolve — run opnsense-haproxy.yml (it writes the wildcard Unbound override)"
      else
        say FAIL WEB-02 "$stack" "*.${stack}.teststuff.net resolves to $got, expected $gw_entry — stale override, API-delete it (runbook: retire a per-name HTTPS entry)"
      fi
    else
      say PROBE-FAILED WEB-02 "$stack" "no dig / no gateway entry — wildcard DNS unknown"
    fi

    # WEB-03 — the whole chain, end to end. 000/timeout = TLS terminates but 40.x has no BGP route
    # (the stack's Gateway is missing); 404 = Gateway up, no HTTPRoute; 200 = published.
    if command -v curl >/dev/null 2>&1 && [ "$specs_wf" = 1 ]; then
      local code
      code=$(timeout 15 curl -sk -o /dev/null -w '%{http_code}' "https://specs.${stack}.teststuff.net" 2>/dev/null || echo 000)
      case "$code" in
        200) say OK WEB-03 "$stack" "specs.${stack}.teststuff.net serves 200 — secrets, CI, Garage, Gateway and HAProxy all work" ;;
        404) say WARN WEB-03 "$stack" "specs.${stack}.teststuff.net → 404: Gateway is up but no HTTPRoute yet (stack's -iac owes it)" ;;
        000) say WARN WEB-03 "$stack" "specs.${stack}.teststuff.net terminates TLS then hangs — nothing owns the 40.x VIP yet (stack's -iac owes the Gateway)" ;;
        403) say FAIL WEB-03 "$stack" "specs.${stack}.teststuff.net → 403 — bucket not website-enabled, or the site was published with the READER key (publishing needs writer_access_key_id)" ;;
        *)   say WARN WEB-03 "$stack" "specs.${stack}.teststuff.net → HTTP $code" ;;
      esac
    fi
  fi

  # JAIL-01 — operator-machine wiring (visible only from the claude-jail checkout)
  if [ -f ../tools/stack-jail.sh ]; then
    if grep -qE "^\s+$stack\)" ../tools/stack-jail.sh; then
      say OK JAIL-01 "$stack" "stack-jail.sh has a '$stack' entry"
    else
      say WARN JAIL-01 "$stack" "no '$stack' entry in tools/stack-jail.sh — no per-stack jail yet"
    fi
    if [ -f "../.env.$stack" ]; then
      say OK JAIL-02 "$stack" ".env.$stack present (PAT wallet)"
    else
      say WARN JAIL-02 "$stack" "no ../.env.$stack — stack jail has no git credentials on this machine"
    fi
  else
    say PROBE-FAILED JAIL-01 "$stack" "not on the operator machine (no ../tools/stack-jail.sh) — jail wiring unknown"
  fi
}

# ── REG-03 once: the registration lint (token lists + merge-path callers, all stacks) ──
if bash scripts/agents-registration-lint.sh >/tmp/stack-lint-reg.$$ 2>&1; then
  say OK REG-03 all "agents-registration-lint (token lists + merge-path callers)"
else
  say FAIL REG-03 all "agents-registration-lint failed:"
  sed 's/^/    /' /tmp/stack-lint-reg.$$
fi
rm -f /tmp/stack-lint-reg.$$

if [ "$TARGET" = "--all" ]; then
  for s in $(jq -r '.stacks[].name' agents/stacks.json); do lint_stack "$s"; done
else
  lint_stack "$TARGET"
fi

echo
if [ $((fails + clicks)) -gt 0 ]; then
  echo "stack-lint: $fails FAIL, $clicks CLICK-PENDING — onboarding incomplete"
  exit 1
fi
echo "stack-lint: green (WARN/PROBE-FAILED lines above, if any, are non-blocking)"
