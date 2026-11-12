#!/usr/bin/env bash
# specs-site leg — a rendered-browser check that every spec page's Mermaid diagrams render and that
# each flowchart's node links navigate to their requirement headings (the oracle-fleet
# scripts/e2e-specs-site.sh shape, oracle-fleet#955). Builds the site (scripts/specs-build.sh),
# serves specs-site/ with python's static server INSIDE the playwright image (named-volume plumbing,
# no bind mounts, so it works under dind), runs scripts/e2e/test_specs_site.py over every page that
# carries a ```mermaid fence. Evidence: e2e-specs-site-evidence/<ts>/ (screenshot + the asserted
# fragments). The repo-root diff-ci runs it (`gateway-specs-site-e2e`) when mkdocs.yml, site-assets/,
# a spec page or this leg change; `devbox run specs-site-e2e` runs it by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

# The browser is the playwright image's, never one assembled here (oracle-fleet#629: a driver looks
# for the browser build IT was released with, so the pip pin and the image tag are ONE version,
# spent twice). The image is pulled through the LAN MCR mirror; a docker image ref cannot carry a
# URL scheme, so the mirror value's scheme is stripped (`:-` first — required under `set -u`).
PLAYWRIGHT_VERSION="1.62.0"
PLAYWRIGHT_IMAGE="${REGISTRY_MIRROR_MCR:-http://192.168.40.31}"
PLAYWRIGHT_IMAGE="${PLAYWRIGHT_IMAGE#*://}/playwright/python:v${PLAYWRIGHT_VERSION}"

TS=$(date -u +%Y%m%dT%H%M%SZ)
EVID="e2e-specs-site-evidence/$TS"
INSTANT=0
grep -qE '^\s*-\s*navigation\.instant\s*$' mkdocs.yml && INSTANT=1

# page path on the built site → the number of ```mermaid fences it carries (the test waits for
# exactly that many rendered diagrams, so a fence that fails to render is a red, not a skip).
PAGES=$(python3 - <<'PY'
import json, pathlib
specs = pathlib.Path("specs")
pages = {}
for md in sorted(specs.rglob("*.md")):
    if (specs / "evidence") in md.parents:
        continue
    n = sum(1 for line in md.read_text(encoding="utf-8").splitlines() if line.startswith("```mermaid"))
    if n:
        pages["/" + str(md.with_suffix(".html"))] = n
print(json.dumps(pages))
PY
)
[ "$PAGES" != "{}" ] || { echo "e2e-specs-site: no spec page carries a mermaid fence — nothing to check"; exit 0; }

# No daemon is a red, never a skip (a ride's gates equal CI's). In a worker ride the daemon
# exists only when the issue's `Touches:` reaches the claim's fixer.dockerPaths (gateway/**).
docker info >/dev/null 2>&1 || {
  echo "e2e-specs-site: no docker daemon. This leg runs the pinned playwright image. In a worker ride that means the issue's Touches: did not reach gateway/** — stop and report the footprint; do not skip this gate." >&2
  exit 1
}

bash scripts/specs-build.sh >/dev/null

docker pull -q "$PLAYWRIGHT_IMAGE" >/dev/null
vol="gw-specs-site-check-$$-$RANDOM"
docker volume create "$vol" >/dev/null
trap 'docker volume rm "$vol" >/dev/null 2>&1 || true' EXIT
tar -cf - specs-site scripts/e2e/test_specs_site.py | docker run --rm -i -v "$vol:/repo" "$PLAYWRIGHT_IMAGE" tar -xf - -C /repo
rc=0
docker run --rm -v "$vol:/repo" -w /repo -e PLAYWRIGHT_VERSION="$PLAYWRIGHT_VERSION" -e INSTANT="$INSTANT" -e PAGES="$PAGES" \
  "$PLAYWRIGHT_IMAGE" bash -c '
set -e
pip install --no-cache-dir -q "playwright==${PLAYWRIGHT_VERSION}"
(cd specs-site && python3 -m http.server 8000 --bind 127.0.0.1 >/dev/null 2>&1 &)
for _ in $(seq 1 20); do python3 -c "import urllib.request;urllib.request.urlopen(\"http://127.0.0.1:8000/\")" 2>/dev/null && break; sleep 0.5; done
mkdir -p evid
python3 scripts/e2e/test_specs_site.py --base-url http://127.0.0.1:8000 --evidence-out evid --instant "$INSTANT" --pages "$PAGES"
' || rc=$?
mkdir -p "$EVID"
docker run --rm -v "$vol:/repo" "$PLAYWRIGHT_IMAGE" sh -c 'cd /repo/evid 2>/dev/null && tar -cf - . || true' | tar -xf - -C "$EVID" || true
if [ "$rc" -eq 0 ]; then echo "E2E-SPECS-SITE GREEN — evidence: $EVID"; else echo "E2E-SPECS-SITE FAILED — evidence: $EVID" >&2; fi
exit "$rc"
