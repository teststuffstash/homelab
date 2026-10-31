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
# Identity (FU-013): every play runs as the router's `automation` API user — wallet entries
# opnsense-automation-api-{key,secret}, privileges = `opnsense_api_users` in
# ansible/group_vars/opnsense.yml — so its config revisions are attributed and the click detector
# (OpnsenseConfigUnattributedRevision, docs/runbook.md §OPNsense config backup) stays quiet for them.
# A play that 403s needs a privilege added to that list (+ scripts/opnsense-api-users.sh), never root.
#
# The ONE root act: OPN_AS_ROOT=1 reads root's key (opnsense-api-{key,secret}) and is accepted for
# ansible/opnsense-users.yml only — creating users and minting their keys is user management,
# a root act by design (scripts/opnsense-api-users.sh sets it). Any other play refuses it.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 ansible/opnsense-<play>.yml [extra ansible-playbook args]" >&2; exit 2; }

cd "$(dirname "$0")/.."   # repo root (nix build path:./... and ansible/ are relative to it)

export NIX_CONFIG="experimental-features = nix-command flakes"
export ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg"   # inventory + roles_path (paths are repo-root-relative)

case "$1" in */opnsense-users.yml|opnsense-users.yml) _users_play=1 ;; *) _users_play=0 ;; esac
if [ "${OPN_AS_ROOT:-0}" = 1 ] && [ "$_users_play" = 0 ]; then
  echo "REFUSING: OPN_AS_ROOT=1 is for ansible/opnsense-users.yml only — every other play runs as \`automation\` (FU-013); a 403 means a missing privilege in opnsense_api_users" >&2
  exit 2
fi
if [ "${OPN_AS_ROOT:-0}" = 1 ]; then _entry=opnsense-api; else _entry=opnsense-automation-api; fi

_kp_db="$HOME/.claude/homelab-keepass/homelab.kdbx"
# A pre-set pair wins: the management box carries no wallet — its units get the automation pair
# from /var/lib/mgmt/env (mgmt/scripts/mgmt-provision-secrets.sh). Otherwise the wallet is the source.
# The root act always reads the wallet (a jail act — the box holds no root pair).
if [ "${OPN_AS_ROOT:-0}" = 1 ]; then unset OPN_API_KEY OPN_API_SECRET; fi
if [ -n "${OPN_API_KEY:-}" ] && [ -n "${OPN_API_SECRET:-}" ]; then
  :
elif [ -f "$_kp_db" ]; then
  # the box carries no wallet — its pair is pre-set (above), so only the jail reaches this devbox
  _kp_get() { DEVBOX_QUIET=1 devbox run --quiet -- keepassxc-cli show -q --no-password -k "$HOME/.claude/homelab-keepass/homelab.keyx" -a Password "$_kp_db" "$1" 2>/dev/null; }   # jail-only fallback (FU-305)
  export OPN_API_KEY="$(_kp_get "$_entry-key")"
  export OPN_API_SECRET="$(_kp_get "$_entry-secret")"
fi
[ -n "${OPN_API_KEY:-}" ] && [ -n "${OPN_API_SECRET:-}" ] || { echo "empty OPNsense API creds (wallet entries $_entry-{key,secret} missing? scripts/opnsense-api-users.sh mints the automation pair)" >&2; exit 1; }

PYBIN="$(nix build --no-link --print-out-paths path:./ansible/controller-env)/bin/python3"

# ax = how an ansible tool runs: the lock-resolved bin dir first on PATH when OPN_ANSIBLE_BIN is set, else devbox
if [ -n "${OPN_ANSIBLE_BIN:-}" ]; then
  [ -x "$OPN_ANSIBLE_BIN/ansible-playbook" ] || { echo "OPN_ANSIBLE_BIN=$OPN_ANSIBLE_BIN has no executable ansible-playbook" >&2; exit 1; }
  PATH="$OPN_ANSIBLE_BIN:$PATH"; ax=()
else
  ax=(devbox run --)   # jail-only fallback (FU-305): the box's belt passes OPN_ANSIBLE_BIN
fi

# Fresh jails don't have the collection installed; cheap to ensure each run.
"${ax[@]}" ansible-galaxy collection install -r ansible/collections/requirements.yml >/dev/null 2>&1 || true

# The opnsense-* playbooks target the `opnsense` inventory host (connection: local);
# roles live in ansible/roles, config in ansible/group_vars (auto-loaded).
exec "${ax[@]}" ansible-playbook "$@" -e ansible_python_interpreter="$PYBIN"
