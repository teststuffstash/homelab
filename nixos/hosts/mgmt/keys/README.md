# Authorized keys for [the management box](../../../../docs/management-box.md)

One `*.pub` per key, read at build time by `../default.nix`. Public keys are **config, not
secrets** (`docs/secrets.md` §Minting doctrine) — they belong in git.

Keep **two** at all times: the operator's and the jail's (`jail.pub` = the pve-ssh-seed key,
`~/.claude/homelab-pve-ssh/id_ed25519.pub`, the one Proxmox root already trusts; `operator.pub` = the
wallet's `forgejo-keys` key, the one the operator's laptop already uses via `~/.ssh/config` —
host-side at `~/Projects/.claude-data/homelab-forgejo/id_ed25519`). That is what makes rotation a diff with
no lockout window — add the new key, rebuild, verify you can log in with it, then remove the old
one in a second commit.

An empty directory fails the build on purpose: no console, no password and no key is a brick.

⚠ **`git add` them.** A flake sees only *tracked* files, so a key merely dropped in this directory
is invisible to the build — and the empty-keys assertion will still fire, which is the intended
failure but a confusing one if you have just copied a file in.
