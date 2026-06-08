# Pre-publish checklist

Goal: make this repo public. **Do not push public until everything below is done.**

> NOTE: Infra has drifted since this audit (e.g. Telia router is gone). Re-verify
> each item against the *current* setup before acting — some secrets/hosts here
> may no longer exist.

## Git history — decided approach (no history rewrite)

Secrets exist in old commits (`8fd6127`, `Init`). **Decision (2026-05-24): don't bother
rewriting history.** Instead, the safety net is:

1. **Rotate every secret** in the "Must remove + rotate" list *before* publishing — once
   rotated, the historical copies are dead/harmless. **Rotation is the real requirement.**
2. **Preferred: publish as a brand-new repo** (fresh `git init`, single clean commit) and
   leave this private repo (with its history) behind. That sidesteps the history question
   entirely — rotation still applies as belt-and-suspenders in case anything was reused.

So: history rewrite / `git filter-repo` is **off the table**; rotate-then-(ideally)-fresh-repo.

## Must remove + rotate

- [ ] `rocky/kickstart` — real SHA-512 password hash for user `rasmus`
      (`--password=$6$Z5GsMtLGy6kfB8LG$...`). Remove the hash (use a placeholder
      or `--plaintext`-free template) and change that password wherever reused.
- [ ] `pfsense/config.pem` — full OPNsense/pfSense config backup, OpenSSL-encrypted
      (`Salted__`). Contains firewall rules, certs/keys, VPN PSKs, user hashes.
      pfSense is legacy now — most likely just delete the file entirely.

## Device-local secrets — move to `!secret` (esphome/config/secrets.yaml is gitignored)

- [ ] OTA password in `esphome/droplet.yml` (`fe5fe756...`)
- [ ] OTA password + AP password in `esphome/config/trash/droplet.yaml`
      (`a997e595...`, AP `dUMrorGA0W8i`) — or just delete the `trash/` folder
- [ ] HA API encryption keys: `2PdhhSba...` (`droplet.yml`, `droplettest.yaml`),
      `gsjkTt0H...` (`trash/droplet.yaml`)

## Hardcoded creds to template

- [ ] `ansible/roles/ubiquiti-appliance/tasks/main.yml` — `root_password` /
      `unifi_password` inline. **Confirm whether these are the real running
      values; if so, change them.** Move to Ansible vars/vault either way.

## Info disclosure — decide whether to scrub

- [ ] `*.teststuff.net` domain (real domain you own?) across README / CLAUDE.md / docs
- [ ] **Cloudflare account ID + zone ID** now committed as variable defaults in
      `tofu/cloudflare/` and `tofu/cloudflare-token/` (identifiers, not secrets — decide whether to
      move to gitignored tfvars before publishing). The CF API **tokens** themselves are out of git
      (`~/.claude/cloudflare/`), as is the AWS account ID in `scripts/aws-*.sh` (decide).
- [ ] `machines/machines.yaml` lists hardware models, IPs and the like (inventory disclosure).
- [ ] ISP, hardware inventory, location (`Europe/Tallinn`), username/email
- [x] README network layout refreshed to current reality (no longer lists the old Telia router /
      retired T61). `docs/network-physical.md` still shows the Telia **ONT** (the actual fibre box).

## Hygiene (not security)

- [ ] `ansible/get-pip.py` — 28k-line vendored pip bootstrap; delete, document
      `curl https://bootstrap.pypa.io/get-pip.py` instead
- [ ] `esphome/config/arial.ttf` — Arial is proprietary (Monotype); replace with
      an open font (e.g. DejaVuSans) before publishing
- [ ] `esphome/config/trash/` — remove
- [ ] typo `netoobtxyz` in `ansible/roles/netbootxyz/tasks/main.yml` volume paths

## Safe to publish as-is (no action)

- SSH **public** keys in `cloud-init.yml` / `burger.yml`
- `rootpw --iscrypted thereisnopasswordanditslocked` in Rocky `.ks` (placeholder, root locked)
- Private `192.168.x.x` IPs

## Final step before going public

- [ ] Add a `LICENSE`
- [ ] Run a secret scanner over the cleaned repo (e.g. `gitleaks detect`) as a last check
