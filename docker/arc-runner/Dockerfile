# Custom ARC runner image (FU-015). The stock ghcr.io/actions/actions-runner is slim (no xz/gh)
# and has no Nix — every job on `homelab-ephemeral` paid ~454s of a 610s wall installing
# nix+devbox from the WAN (measured: oracle-fleet ci, run 30101073645). This image bakes the
# whole toolchain so workflows go straight to `devbox run <task>`:
#   - xz/jq/gh — the tools GitHub-hosted runners bundle but the slim image omits (docs/ci.md)
#   - single-user (daemonless) Nix — the only install that works in the ARC pod (no systemd;
#     the daemon installer dies under dind — docs/ci.md "The fix that works on the ARC pod")
#   - devbox, pinned binary
#   - nix.conf pointing at the LAN pull-through cache first (argocd/resources/nix-cache)
# Built+pushed by .github/workflows/runner-image.yaml; consumed by the scale set image pin in
# argocd/platform/arc-runners.yaml (keep the runner version compatible with the ARC chart there), the
# iac-sentinel WorkflowTemplate, and the runner-image-prepull DaemonSet (every worker holds the 4.9 GiB
# image before a pod asks — a first pull cost 429–909 s and failed a sentinel run, 2026-09-03).
# Phase 2 (FU-015): a warm /nix store layer per devbox.lock closure.
FROM ghcr.io/actions/actions-runner:2.336.0

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends xz-utils jq git \
 && rm -rf /var/lib/apt/lists/*

# gh CLI from the official apt repo
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# devbox — pinned binary, not the install script (script pulls whatever is latest)
ARG DEVBOX_VERSION=0.17.5
RUN curl -fsSL "https://github.com/jetify-com/devbox/releases/download/${DEVBOX_VERSION}/devbox_${DEVBOX_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin devbox \
 && chmod 0755 /usr/local/bin/devbox

# /nix owned by runner (uid 1001) — required for the single-user install below
RUN install -d -m 0755 -o runner -g runner /nix

USER runner
ENV HOME=/home/runner
ARG NIX_VERSION=2.35.1
RUN curl -fsSL "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" \
      | sh -s -- --no-daemon --no-channel-add \
 && rm -rf /home/runner/.cache

COPY --chown=runner:runner nix.conf /home/runner/.config/nix/nix.conf
ENV PATH="/home/runner/.nix-profile/bin:${PATH}"

# Phase 2 (FU-015): warm /nix with the fleet's devbox closures so jobs skip realization
# (~340s of oracle-fleet's ci was closure fetch+xz-decompress on the ThinkPads). The workflow
# fetches each repo's default-branch devbox.{json,lock} into warm/ with a minted App token
# (most fleet repos are PRIVATE — anonymous raw fetch 404s, first warm build shipped hollow)
# and the per-repo COPYs below bake whatever it found (a repo that failed to fetch stages an
# EMPTY dir — warm-one skips it). Deliberately not lockfile-coupled: a stale warm store
# still works, jobs realize the delta via the LAN mirror. Rebuild (push to this dir or
# workflow_dispatch) whenever the drift gets noticeable. The store paths persist without GC
# roots (no nix GC ever runs in the image); the /tmp/warm profiles are discarded on purpose.
# ONE LAYER PER REPO CLOSURE (#80): the warm store was a single ~3.4G RUN keyed on ALL seven
# repos' lockfiles — any one lock change re-digested the whole layer, so consecutive pins
# shared only 0.55G of 4G and every bump pushed ~3.5G of "new" bytes through ghcr, the LAN
# mirror and every node. Per-repo COPY+RUN pairs + the buildx registry cache
# (runner-image.yaml) mean an unchanged lockfile REUSES its cached layer (digest stays
# stable); only the changed closure re-bakes. Layer order = cache invalidation order:
# homelab goes LAST (its lock merge is the frequent rebuild trigger — the fleet layers
# ahead of it stay cached); the rest is alphabetical, invalidated together on the Monday
# devbox-update rebake anyway.
# KEEP ~/.cache/{nix,devbox} from these installs: with the store fully warm, a job's
# `devbox install` still burned 94s (oracle-fleet ci, run 30165878479) — measured to be
# nix EVALUATION, not fetching (cold-cache repro: 127s wall/84s CPU on a fast desktop with
# a complete /nix; 7.7s with the eval cache warm). Deleting the cache here was phase 2's
# whole residual cost. The cache rides inside each closure's layer — churny content, but
# layer REUSE (not content determinism) is what keeps unchanged digests stable.
COPY --chown=runner:runner warm-one.sh /usr/local/bin/warm-one
COPY --chown=runner:runner warm/agent-coordinator/ /tmp/warm/agent-coordinator/
RUN warm-one agent-coordinator
COPY --chown=runner:runner warm/openrouter-operator/ /tmp/warm/openrouter-operator/
RUN warm-one openrouter-operator
COPY --chown=runner:runner warm/oracle-fleet/ /tmp/warm/oracle-fleet/
RUN warm-one oracle-fleet
COPY --chown=runner:runner warm/oracle-iac/ /tmp/warm/oracle-iac/
RUN warm-one oracle-iac
COPY --chown=runner:runner warm/sleep-iac/ /tmp/warm/sleep-iac/
RUN warm-one sleep-iac
COPY --chown=runner:runner warm/sleep-tracking/ /tmp/warm/sleep-tracking/
RUN warm-one sleep-tracking
COPY --chown=runner:runner warm/homelab/ /tmp/warm/homelab/
RUN warm-one homelab && rm -rf /tmp/warm

# Phase 3 (FU-015 / #518): warm the GitHub Actions archive cache so Set-up-job resolves
# actions from the local tarballs instead of downloading from GitHub on every job.
# The ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE env var (set by the operator in
# argocd/platform/arc-runners.yaml — pin-only-guarded, operator-direct) points the runner
# at /home/runner/_actions/_cache. Actions are SHA-pinned org-wide
# (helpers:pinGitHubActionDigests in renovate-global.json), so cache keys are stable
# between renovate bumps. Rebuild this image when renovate bumps an action pin.
COPY --chown=runner:runner warm-actions.sh /usr/local/bin/warm-actions
RUN mkdir -p /home/runner/_actions/_cache && chown -R runner:runner /home/runner/_actions
RUN warm-actions /home/runner/_actions/_cache
