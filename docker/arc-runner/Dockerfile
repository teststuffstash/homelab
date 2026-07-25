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
# argocd/platform/arc-runners.yaml (keep the runner version compatible with the ARC chart there).
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
