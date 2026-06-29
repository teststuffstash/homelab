# agent-coordinator — Claude Code as the coordinator, in a pod.
#
# Bundles just what the coordinator runbook (README.md) needs: the `claude` CLI (subscription auth
# via CLAUDE_CODE_OAUTH_TOKEN), kubectl (talks to the cluster via the pod's ServiceAccount — see
# rbac.yaml), gh + git (read/label issues, merge PRs), and python3/jq (the budget estimator + JSON).
# The homelab repo (brief + launchers + estimator) is cloned at runtime by coordinator-session.sh,
# not baked in, so the coordinator always runs the current main.
#
# Build + push (until a CI workflow owns it, à la agent-base):
#   docker build -t ghcr.io/teststuffstash/agent-coordinator:latest agents/coordinator
#   docker push  ghcr.io/teststuffstash/agent-coordinator:latest
FROM node:22-bookworm-slim

ARG KUBECTL_VERSION=v1.36.1

# OS tools + gh (official apt repo) + kubectl (pinned to the cluster minor).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git jq python3 gnupg less bash; \
    # gh
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; apt-get install -y --no-install-recommends gh; \
    # kubectl
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    chmod +x /usr/local/bin/kubectl; \
    # Claude Code CLI
    npm install -g @anthropic-ai/claude-code; \
    rm -rf /var/lib/apt/lists/*

# Pre-seed onboarding so a fresh container doesn't stop on the first-run wizard (auth itself comes
# from CLAUDE_CODE_OAUTH_TOKEN at runtime). Owned by the non-root node user (uid 1000).
RUN mkdir -p /home/node/.claude /work \
    && printf '{"hasCompletedOnboarding":true}\n' > /home/node/.claude.json \
    && chown -R node:node /home/node/.claude /home/node/.claude.json /work

USER node
ENV HOME=/home/node
WORKDIR /work
