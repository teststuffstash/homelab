#!/usr/bin/env bash
# Run an OPNsense ansible playbook with the pinned httpx interpreter + API creds.
#
# Encapsulates the non-obvious recipe (see docs/runbook.md "OPNsense as code"):
#   - oxlorg.opnsense needs `httpx`, provided by the nix flake ansible/controller-env/
#   - `devbox run` STRIPS ANSIBLE_PYTHON_INTERPRETER, and the env var is ignored for the
#     implicit localhost anyway -> the interpreter MUST be passed as `-e`.
#   - the collection isn't preinstalled in a fresh jail.
#
# Usage:
#   bash scripts/opnsense-playbook.sh ansible/opnsense-haproxy.yml [extra ansible args]
#
# Creds live outside the repo at ~/.claude/homelab-opnsense/{key,secret}.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 ansible/opnsense-<play>.yml [extra ansible-playbook args]" >&2; exit 2; }

cd "$(dirname "$0")/.."   # repo root (nix build path:./... and ansible/ are relative to it)

export NIX_CONFIG="experimental-features = nix-command flakes"
export ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg"   # inventory + roles_path (paths are repo-root-relative)
export OPN_API_KEY="$(cat "$HOME/.claude/homelab-opnsense/key")"
export OPN_API_SECRET="$(cat "$HOME/.claude/homelab-opnsense/secret")"

PYBIN="$(nix build --no-link --print-out-paths path:./ansible/controller-env)/bin/python3"

# Fresh jails don't have the collection installed; cheap to ensure each run.
devbox run -- ansible-galaxy collection install -r ansible/collections/requirements.yml >/dev/null 2>&1 || true

# The opnsense-* playbooks target the `opnsense` inventory host (connection: local);
# roles live in ansible/roles, config in ansible/group_vars (auto-loaded).
exec devbox run -- ansible-playbook "$@" -e ansible_python_interpreter="$PYBIN"
