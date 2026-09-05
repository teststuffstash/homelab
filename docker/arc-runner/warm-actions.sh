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
  sha=
  tag_data=$(curl -sS --fail -H "User-Agent: arc-runner-warm-actions/1.0" \
    "https://api.github.com/repos/$owner/$repo/git/ref/tags/$ref" 2>/dev/null) || tag_data=
  if [ -n "$tag_data" ]; then
    obj_type=$(echo "$tag_data" | jq -r '.object.type' 2>/dev/null) || obj_type=""
    obj_sha=$(echo "$tag_data" | jq -r '.object.sha' 2>/dev/null) || obj_sha=""
    if [ "$obj_type" = "tag" ]; then
      # Annotated tag — follow to the underlying commit
      sha=$(curl -sS --fail -H "User-Agent: arc-runner-warm-actions/1.0" \
        "https://api.github.com/repos/$owner/$repo/git/tags/$obj_sha" 2>/dev/null \
        | jq -r '.object.sha' 2>/dev/null) || sha=""
    else
      sha="$obj_sha"
    fi
  fi
  # Fallback: try as a commit ref (for SHA-pinned references)
  if [ -z "$sha" ]; then
    sha=$(curl -sS --fail -H "User-Agent: arc-runner-warm-actions/1.0" \
      "https://api.github.com/repos/$owner/$repo/commits/$ref" 2>/dev/null \
      | jq -r '.sha' 2>/dev/null) || sha=""
  fi

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

# Fail loudly if nothing was cached — a resolution regression must break the build
find "$CACHE_DIR" -name '*.tar.gz' | grep -q . || {
  echo "── FATAL: no action tarballs cached — resolution regression or network failure"
  exit 1
}

echo "── action archive cache warmed: $(du -sh "$CACHE_DIR" | cut -f1)"
echo "── contents:"
find "$CACHE_DIR" -name '*.tar.gz' | sort