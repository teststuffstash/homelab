# `ansible/` — OPNsense + Matchbox as code (roles layout)

Two control targets, each driven by **thin playbooks that call roles**:
- **`opnsense`** — the router @ `192.168.2.1`, configured via its REST API *from the controller*
  (`connection: local`, the `oxlorg.opnsense` collection).
- **`matchbox`** — the PXE provisioning LXC @ `192.168.2.30`, configured over SSH.

There is no `site.yml`-style "apply everything" — each concern is its own playbook.

## Layout

```
ansible/
  ansible.cfg            # inventory + roles_path (paths relative to this dir)
  inventory.yml          # the opnsense + matchbox hosts
  group_vars/
    opnsense.yml         # CONFIG values: API conn, BGP/ACME/HAProxy/Unbound settings
    matchbox.yml         # CONFIG values: SSH conn, matchbox + Talos-asset settings
  collections/requirements.yml   # oxlorg.opnsense pin (tracks os-frr/OPNsense version)
  requirements.yml       # role pins — empty; the seam for extracting a role to its own repo
  controller-env/        # nix flake: python + httpx for the oxlorg modules
  <play>.yml             # thin role-callers (hosts + module_defaults + roles)
  roles/<name>/          # the LOGIC: tasks/ (+ handlers/, defaults/)
```

**Config vs logic split:** the **roles** hold the tasks; the **values** live in `group_vars`.
That keeps the playbooks one-liners and makes it easy to eyeball when a role has grown big enough
to extract to its own git repo (then pin it via `requirements.yml` by git tag — roles stay portable
because their real values are here, not baked in).

## Playbooks

| Playbook | Role | Manages |
|---|---|---|
| `opnsense-bgp.yml` | `opnsense-bgp` | FRR/BGP peering Cilium (AS 64512 ↔ 64513), LB VIPs `192.168.40.0/24` |
| `opnsense-acme.yml` | `opnsense-acme` | Let's Encrypt certs (DNS-01 via **Cloudflare** — `ACME_CF_TOKEN`) |
| `opnsense-haproxy.yml` | `opnsense-haproxy` | HTTPS reverse proxy → in-cluster service VIPs |
| `opnsense-unbound.yml` | `opnsense-unbound` | static Unbound host overrides (e.g. `ubiquiti.teststuff.net`) |
| `matchbox.yml` | `matchbox` | install Matchbox on the PXE LXC |
| `matchbox-ipxe-tftp.yml` | `matchbox-ipxe-tftp` | iPXE binaries + TFTP (PXE stage-1) |
| `matchbox-proxydhcp.yml` | `matchbox-proxydhcp` | dnsmasq proxy-DHCP boot server |
| `matchbox-talos-assets.yml` | `matchbox-talos-assets` | Talos kernel/initramfs into Matchbox assets |

## Running

**OPNsense** — through the wrapper (handles the httpx interpreter, API creds, and `ANSIBLE_CONFIG`):

```bash
bash scripts/opnsense-playbook.sh ansible/opnsense-haproxy.yml          # or any opnsense-*.yml
```

**Matchbox** — over SSH (uses the Proxmox seed key from `group_vars/matchbox.yml`; no httpx needed):

```bash
export ANSIBLE_CONFIG=ansible/ansible.cfg
devbox run -- ansible-playbook ansible/matchbox.yml          # see docs/provisioning.md
```

To change a value, edit `group_vars/{opnsense,matchbox}.yml`. To change behaviour, edit the role's
`roles/<name>/tasks/main.yml`. LAN DHCP is **not** Ansible — it's `../opnsense/dnsmasq-dhcp.py`.

## Why the wrapper exists (the non-obvious bits)

`oxlorg.opnsense` needs **`httpx`** (the pinned `controller-env/` flake provides it); `devbox run`
strips `ANSIBLE_PYTHON_INTERPRETER`, so the interpreter is passed as `-e`; the collection isn't
preinstalled in a fresh jail. Full detail in `../docs/runbook.md`. API/module gotchas (the `raw`
module needs `action: post`; `unbound_host` needs a reconfigure handler) are documented in the
role tasks + the runbook.
