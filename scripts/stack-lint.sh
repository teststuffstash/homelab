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
#   CLICK-PENDING browser-only step not done (App install) → exit 1; after the click, regenerate
#                 the matrix (`devbox run github-apps`) — this check reads that generated snapshot
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
#   docs/github-apps.md         generated App-install matrix (click-only surface)
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

# App-install matrix lookup: prints INSTALLED / MISSING / NO-COLUMN / NO-ROW for <repo> <app-base>
app_installed() { # <repo> <app-base>
  python3 - "$1" "$2" <<'PY'
import re, sys
repo, app = sys.argv[1], sys.argv[2]
rows = [l for l in open("docs/github-apps.md") if l.lstrip().startswith("|")]
if not rows: print("NO-ROW"); raise SystemExit
hdr = [c.strip() for c in rows[0].strip().strip("|").split("|")]
if repo not in hdr: print("NO-COLUMN"); raise SystemExit
col = hdr.index(repo)
for l in rows[2:]:
    cells = [c.strip() for c in l.strip().strip("|").split("|")]
    m = re.match(r"`([a-z-]+?)(?:-\d+)?`", cells[0])
    if m and m.group(1) == app:
        print("INSTALLED" if (len(cells) > col and "✓" in cells[col]) else "MISSING")
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
    if grep -qE "label_repos\s*=.*\"$repo\"" tofu/github/labels.tf; then
      say OK GH-03 "$stack" "$repo in label_repos (state-machine labels)"
    else
      say FAIL GH-03 "$stack" "$repo missing from label_repos (tofu/github/labels.tf; moves into the claim with FU-068)"
    fi

    # GH-04 — App installs (generated matrix; a miss is a CLICK, then `devbox run github-apps`)
    local need_apps="homelab-merge"
    if is_fixer "$repo"; then need_apps="homelab-agents homelab-merge homelab-reviewer"
    elif [ "$repo" != "homelab" ]; then need_apps="homelab-deploy homelab-merge"; fi
    local app st
    for app in $need_apps; do
      st=$(app_installed "$repo" "$app")
      case "$st" in
        INSTALLED) say OK GH-04 "$stack" "$app installed on $repo (per matrix snapshot)" ;;
        MISSING)   say CLICK-PENDING GH-04 "$stack" "$app NOT installed on $repo — browser install, then devbox run github-apps" ;;
        *)         say PROBE-FAILED GH-04 "$stack" "$repo/$app not resolvable in docs/github-apps.md ($st) — devbox run github-apps" ;;
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

      if is_fixer "$repo"; then
        local f
        for f in .agents/fix.yaml .agents/review.md; do
          if timeout 15 gh api "repos/$ORG/$repo/contents/$f" --jq .name >/dev/null 2>&1; then
            say OK REPO-03 "$stack" "$repo has $f"
          else
            say FAIL REPO-03 "$stack" "$repo missing $f (worker/reviewer recipe — repo content, versioned with the code)"
          fi
        done
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
  done

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
