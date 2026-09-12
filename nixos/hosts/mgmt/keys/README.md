# Authorized keys for the management box

One `*.pub` per key, read at build time by `../default.nix`. Public keys are **config, not
secrets** (`docs/secrets.md` §Minting doctrine) — they belong in git.

Keep **two** at all times: the operator's and the jail's. That is what makes rotation a diff with
no lockout window — add the new key, rebuild, verify you can log in with it, then remove the old
one in a second commit.

An empty directory fails the build on purpose: no console, no password and no key is a brick.
