# shellcheck shell=bash
# The specs-site build and upload steps that do not depend on WHICH spec root is being rendered —
# ONE home for the pins (mermaid, the mkdocs toolchain) and for the object-store lessons, shared by
# this island's scripts/specs-build.sh + scripts/specs-publish.sh and by the other islands' sites
# (islands/scripts/specs-site.sh). Every function runs with the spec root's island directory as cwd
# (the directory that holds mkdocs.yml, specs/, allure-results/). Callers source
# scripts/lib/snippets.sh (site_join_pages) and scripts/lib/s3-publish.sh (site_upload,
# site_purge_prefix) themselves.
SITE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# site_join_pages <rule-prefix> <report-url>
# The joined render (allure-evidence --spec-page-out; pin in scripts/lib/snippets.sh): every spec
# page heading rules (`## <PREFIX>-…`) is rewritten in the STAGED copy (.site-src/) — a rule whose
# decision tables join the run's evidence (≥1 description cell == a case id) keeps its own columns,
# each description linking to its case in the single-file report the site serves (<report-url>), a
# mark only on a row that is not fine (∅ unproven, ≠ cell mismatch); that rule's `<details>`
# evidence embed is dropped (the table IS the evidence). A rule whose tables join nothing keeps its
# authored tables and its fragment. The committed spec text is never touched. Reads allure-results/
# and allure-report-single/index.html (scripts/allure-report.sh — Allure uids are per-generate, so
# the index.html the links were read from must be the one shipped).
site_join_pages() {
  local prefix="$1" report_url="$2" scratch page rules
  scratch=$(mktemp -d)
  while IFS= read -r page; do
    mapfile -t rules < <(sed -nE "s/^#{2,6} (${prefix}-[A-Z0-9-]+)\s*\$/\1/p" "$page")
    allure_evidence --results allure-results --out "$scratch/$(echo "${page#specs/}" | tr '/' '_')" \
      --spec "$page" --rules "$(IFS=,; echo "${rules[*]}")" --spec-page-out ".site-src/$page" \
      --report allure-report-single/index.html --report-url "$report_url" >/dev/null
  done < <(grep -rlE "^#{2,6} ${prefix}-[A-Z0-9-]+\s*\$" specs --include='*.md' --exclude-dir=evidence | sort)
  rm -rf "$scratch"
}

# site_stage_mermaid
# The pinned flowchart renderer into .site-src/javascripts/ (javascripts/mermaid-init.js loads it;
# the oracle-fleet scripts/specs-build.sh shape, oracle-fleet#955). Fetched through npm (a pod's
# $NPM_CONFIG_REGISTRY cache applies automatically), then sha256-checked so a republished tarball
# cannot change the site silently. Bump version + sha together.
SITE_MERMAID_VERSION=11.12.0
SITE_MERMAID_SHA256=07e37dfa97b337ccc85365d57eddf99b9706f09db3b59b260d0333b23b343c4b
site_stage_mermaid() {
  local mm
  mm=$(mktemp -d)
  (cd "$mm" && npm pack "mermaid@$SITE_MERMAID_VERSION" --silent >/dev/null && tar -xzf ./*.tgz package/dist/mermaid.min.js)
  echo "$SITE_MERMAID_SHA256  $mm/package/dist/mermaid.min.js" | sha256sum -c --quiet - \
    || { echo "specs-build: mermaid@$SITE_MERMAID_VERSION sha256 mismatch" >&2; return 1; }
  mkdir -p .site-src/javascripts
  cp "$mm/package/dist/mermaid.min.js" .site-src/javascripts/mermaid.min.js
  cp "$SITE_LIB_DIR/../../site-assets/mermaid-init.js" .site-src/javascripts/mermaid-init.js
  rm -rf "$mm"
}

# site_mkdocs_build
# mkdocs via uv --no-project, not an island's lock and not devbox: pymdownx/material must live in
# the same python env as mkdocs, which the nix-packaged mkdocs can't host, and an island's uv.lock
# is the SERVICE's closure, not the docs toolchain's. EXACT pins, the same three oracle-fleet
# builds with (its specs-build.sh): the mkdocs ecosystem forked in 2026-07 (mkdocs 2.0 vs
# properdocs) — unpinned resolution can silently swap the engine under the site.
site_mkdocs_build() {
  rm -rf specs-site
  uv run --no-project --with mkdocs==1.6.1 --with mkdocs-material==9.7.6 \
    --with pymdown-extensions==11.0.1 mkdocs build --quiet
}

# site_dir_indexes
# Directory links in spec text (specs/worlds/, use-cases/uc-1/) must resolve on an object store
# with no listing support: give every directory of specs-site/ that lacks an index.html a
# generated one.
site_dir_indexes() {
  local d e n
  find specs-site -type d | while read -r d; do
    [ -f "$d/index.html" ] && continue
    {
      echo "<!doctype html><meta charset=utf-8><title>${d#specs-site/}</title><h1>${d#specs-site/}/</h1><ul>"
      for e in "$d"/*; do
        n=$(basename "$e"); [ -d "$e" ] && n="$n/"
        echo "<li><a href=\"$n\">$n</a></li>"
      done
      echo "</ul>"
    } > "$d/index.html"
  done
}

# site_upload <dest> <prefix>
# specs-site/ → <dest> (`<remote>:<bucket>[/<prefix>]`, the remote defined by s3_publish_remote).
# report/ stays out of the mirror (never uploaded without its headers) and is put after it; rclone
# sync never deletes dest keys its filters exclude. Filters are anchored ('/…/**') so they match
# only the top-level directories. The run's single-file Allure report rides beside the site at
# report/index.html GZIPPED (oracle-fleet#547) and put apart from the mirror, because
# Content-Encoding is a per-object header a mirror cannot set.
site_upload() {
  local dest="$1" prefix="$2" scratch
  if [ -n "$prefix" ]; then
    # A PR prefix is wholly owned by its PR: --remove keeps it an exact mirror of this build.
    s3_publish_mirror --remove --exclude '/report/**' specs-site/ "$dest"
  else
    # NEVER --remove on the root: we own the root, not the pr-*/ directories PR runs write.
    s3_publish_mirror --exclude '/pr-*/**' --exclude '/report/**' specs-site/ "$dest"
  fi
  if [ -f specs-site/report/index.html ]; then
    echo "== upload: the run's Allure report (gzipped single-file) → report/index.html =="
    scratch=$(mktemp -d)
    mkdir -p "$scratch/report"
    gzip -9 -c specs-site/report/index.html > "$scratch/report/index.html"
    echo "   $(stat --format=%s specs-site/report/index.html) bytes → $(stat --format=%s "$scratch/report/index.html") bytes gzipped"
    # Plain "gzip": the "aws-chunked,gzip" prefix (oracle-fleet PR #551) was an mc artefact — mc
    # signed with Garage's STREAMING signature, which required it. rclone sends a plain signed PUT,
    # and Garage stores + serves Content-Encoding: gzip as given (live round-trip, 2026-10-28).
    s3_publish_put --header "Content-Encoding: gzip" --header "Content-Type: text/html" \
      "$scratch/report/index.html" "$dest/report/index.html"
    rm -rf "$scratch"
  else
    echo "specs-publish: no Allure report in this build (no allure-results/) — report/ left as is"
  fi
}

# site_purge_prefix <remote:bucket/prefix>
# Close-time removal of one prefix. The listing probe's exit status is captured SEPARATELY from its
# output (oracle-fleet#529): a failing probe must NOT read as "prefix empty" and skip silently.
# Precondition, NOT an error-swallow: removal is attempted only when the prefix holds objects — a
# PR whose CI never published must not turn a close into a failure.
site_purge_prefix() {
  local prefix="$1" listing=""
  if ! listing="$(s3_publish_ls lsf -R --files-only "$prefix")"; then
    echo "::error::listing probe failed for ${prefix}/" >&2
    return 1
  fi
  if [ -n "$listing" ]; then
    echo "purging ${prefix}/ (close-time cleanup)"
    rclone delete --checkers "$S3_PUBLISH_WORKERS" "$prefix"
  else
    echo "no objects under ${prefix}/ — nothing to purge"
  fi
}
