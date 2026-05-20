# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Environment

Running inside a Docker jail — see `/workspace/CLAUDE.md` for container setup, permissions, and available tools.

## What this is

Infrastructure-as-code for a home network. No build step or test suite — changes are applied directly to live machines.

## Network layout

| Host | IP | Role |
|---|---|---|
| Lenovo T61 | 192.168.2.2 | netboot.xyz, Ubiquiti controller |
| HP desktop | 192.168.2.1 (OPNsense) | Router/firewall |
| Raspberry Pi 3B | — | OctoPi (3D printer) |

OPNsense web UI: `https://opnsense.teststuff.net`
Ubiquiti web UI: `https://ubiquiti.teststuff.net:8443/`

## Ansible

Inventory: `ansible/homelab` (two groups: `netbootxyz` and `ubiquiti`, both pointing at 192.168.2.2)

```bash
# Apply everything
ansible-playbook -i homelab site.yml --become

# Single host / single playbook
ansible-playbook -i homelab --limit 192.168.2.2 sudoers.yml -b -K
```

Roles are in `ansible/` alongside the playbooks (no separate `roles/` dir visible).

## Provisioning new machines

**Rocky 9** — kickstart files in `rocky/`, served by the T61 at `http://192.168.2.2:8000/`. Set the netboot kickstart URL to:
- `http://192.168.2.2:8000/r9.ks` — standard node
- `http://192.168.2.2:8000/r9-k3s-master.ks` — k3s master

**Ubuntu** — `ubuntu/burger.yml` is a cloud-init autoinstall config.

**Generic cloud-init** — `cloud-init.yml` at repo root; adds `rasmus` user with SSH key.

## Docker-composed services

Each service has its own `docker-compose.yml`. Run from the service subdirectory:

```bash
docker compose up -d   # netboot.xyz, esphome, homeassistant
```

- `netboot.xyz/` — TFTP server (UDP 69) + web UI (port 3000) + nginx (port 8080)
- `esphome/` — ESPHome dashboard; device configs in `esphome/config/`
- `homeassistant/` — Home Assistant

**Note:** the `esphome/` and `homeassistant/` compose files have volume paths hardcoded to `/home/rasmus/IdeaProjects/homelab/...` — update these if the repo moves.

## ESPHome devices

Device YAML files live in `esphome/config/`. The `droplettest.yaml` / `droplet.yml` are for the `pricelesstoolkit.droplet` project (ESP32, OLED display). Edit via the ESPHome dashboard or directly in `esphome/config/`.

## Notes

- `pfsense/` contains a legacy PEM file; OPNsense has replaced pfSense as the router.
- To suppress laptop display blanking on a console machine: `setterm -blank 1 >> /etc/issue`
