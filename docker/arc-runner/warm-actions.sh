#!/bin/sh
# Warm the GitHub Actions archive cache (FU-015 phase 3) — download SHA-pinned action
# tarballs into the runner's archive cache so Set-up-job stops touching the network
# for the common actions. Invoked once per Docker build.
#
# The ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE env var (set by the operator in
# argocd/platform/arc-runners.yaml — pin-only-guarded, operator-direct) points the
# runner at this directory. With the cache pre-seeded, every job's Set-up-job step
# resolves actions from the local tarballs instead of downloading from GitHub.
#
# Actions are SHA-pinned org-wide (helpers:pinGitHubActionDigests in renovate-global.json),
# so cache keys (the SHA digests) are stable between renovate bumps. When renovate bumps
# a pin, rebuild this image to refresh the cache for that action.
#
# The list below covers every marketplace action used across homelab's workflows
# (.github/workflows/*.yaml). Add new actions here as they are introduced.
set -e

CACHE_DIR="${1:-/home/runner/_actions/_cache}"
mkdir -p "$CACHE_DIR"

# owner/repo@ref for every marketplace action used in homelab's workflows.
# When renovate bumps a pin, update the ref here and rebuild the image.
ACTIONS="
actions/checkout@v4
actions/create-github-app-token@v1
docker/login-action@v3
docker/setup-buildx-action@v3
renovatebot/github-action@v46.1.17
"

for action in $ACTIONS; do
  owner=$(echo "$action" | cut -d/ -f1)
  repo=$(echo "$action" | cut -d/ -f2 | cut -d@ -f1)
  ref=$(echo "$action" | cut -d@ -f2)

  echo "── resolving $owner/$repo@$ref"

  # Resolve the ref to a commit SHA via the GitHub API.
  # Lightweight tag → object.sha is the commit SHA directly.
  # Annotated tag → object.sha is the tag object; follow git/tags to the commit.
  sha=$(python3 -c "
import json, urllib.request, sys

owner = '$owner'
repo = '$repo'
ref = '$ref'

# Try as a tag ref first
url = f'https://api.github.com/repos/{owner}/{repo}/git/ref/tags/{ref}'
try:
    req = urllib.request.Request(url)
    # GitHub API requires a User-Agent
    req.add_header('User-Agent', 'arc-runner-warm-actions/1.0')
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.load(resp)
        obj = data['object']
        sha = obj['sha']
        if obj['type'] == 'tag':
            # Annotated tag — follow to the underlying commit
            url2 = f'https://api.github.com/repos/{owner}/{repo}/git/tags/{sha}'
            req2 = urllib.request.Request(url2)
            req2.add_header('User-Agent', 'arc-runner-warm-actions/1.0')
            with urllib.request.urlopen(req2, timeout=15) as resp2:
                data2 = json.load(resp2)
                sha = data2['object']['sha']
        print(sha)
        sys.exit(0)
except Exception as e:
    # Fallback: try as a commit ref (for SHA-pinned references)
    url = f'https://api.github.com/repos/{owner}/{repo}/commits/{ref}'
    try:
        req = urllib.request.Request(url)
        req.add_header('User-Agent', 'arc-runner-warm-actions/1.0')
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.load(resp)
            print(data['sha'])
            sys.exit(0)
    except Exception as e2:
        print('', end='')
        sys.exit(1)
" 2>/dev/null) || sha=""

  if [ -z "$sha" ]; then
    echo "── could not resolve $owner/$repo@$ref — skipping (will be fetched at runtime)"
    continue
  fi

  # Download the tarball keyed by commit SHA (the runner's cache key)
  echo "── downloading $owner/$repo@$sha"
  mkdir -p "$CACHE_DIR/$owner/$repo"
  curl -sS --fail -L "https://github.com/$owner/$repo/archive/$sha.tar.gz" \
    -o "$CACHE_DIR/$owner/$repo/$sha.tar.gz" || {
    echo "── download failed for $owner/$repo@$sha — skipping"
    rm -f "$CACHE_DIR/$owner/$repo/$sha.tar.gz"
    continue
  }
  size=$(du -sh "$CACHE_DIR/$owner/$repo/$sha.tar.gz" | cut -f1)
  echo "── cached $owner/$repo/$sha.tar.gz ($size)"
done

echo "── action archive cache warmed: $(du -sh "$CACHE_DIR" | cut -f1)"
echo "── contents:"
find "$CACHE_DIR" -name '*.tar.gz' | sort