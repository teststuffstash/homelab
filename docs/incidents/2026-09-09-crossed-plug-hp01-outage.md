# 2026-09-09 — crossed smart-plug ids: a thinkcentre window took hp-01 down too

**First symptom:** 17:17Z, hp-01 `NotReady` in the middle of a planned thinkcentre maintenance
window; alerts firing; Alertmanager itself (on hp-01) stuck terminating.
**Class:** cascade (both `std`-tier zones dark at once → three CNPG volumes with no replica
online, evictions across Argo/ArgoCD/agent-loop namespaces) — and silent: the plug telemetry that
should have said "that box is running" was labelled as the other box.

## Timeline (UTC)

| when | what |
|---|---|
| 16:31–16:45 | window 1: `node-maintenance down thinkcentre` (settle → drain → shutdown, first run of the settle step). Power pulled for the RAM/NVMe work. |
| 17:06–17:10 | `up thinkcentre`: Ready, uncordoned, Longhorn healthy. The Intel 7600p in the x16 slot never enumerated. |
| 17:12:55–17:13:20 | window 2: `down thinkcentre` for the drive swap. Operator pulls thinkcentre's mains. `sensor.plug_hp_power` drops 32 → 0 W at 17:13:29 — **that sensor was on thinkcentre's socket**. |
| ~17:16:30 | Operator: "power it on". Seat reads `switch.tuyalocal_thinkcentre` = on, no ping → cycles that switch off/on. **That switch was on hp-01's socket.** `sensor.plug_thinkcentre_power` 24 → 0 W at 17:16:42. hp-01 does not come back on AC restore (its documented flaky behaviour). |
| 17:17:17 | hp-01 `Ready=Unknown`; TaintManager evicts its pods at 17:22. Both std zones dark; `oracle-pg-1`, `forgejo-pg-4`, `grafana-pg-1` have no replica online; Alertmanager gone. |
| 17:27 | Seat reads it as a power-button shutdown (graceful 32→21→0 ramp) and sends WoL. Wrong box again: the 32 W ramp was thinkcentre's shutdown on the `hp` sensor. |
| 17:28:20 | Operator powers thinkcentre back on (46.6 W on the `hp` sensor). Operator: "hp-01 never lost power" — contradiction that forced the history read. |
| 17:3x | Plug histories compared (4 transitions on `plug_hp` = thinkcentre's power states; `plug_thinkcentre` steady 24 W until the seat's cycle). Cause identified. Entity ids swapped in the HA registry via the websocket API; draw per name verified (`thinkcentre` 32.8 W up, `hp` 0 W off). |
| — | hp-01 recovery = power button (WoL cannot follow an AC cut). |

## Root cause

The 2026-08-18 plug rename (`aquarium`/`konditsioneer` → `thinkcentre`/`hp`, HA entity registry)
put each name on the **other** box's socket. Every plug-derived fact recorded since — idle draws,
"boots on AC restore", the WoL-at-full-draw observation — was attributed to the wrong machine, and
the remote-power recipe in `machines.yaml` (`switch.tuyalocal_thinkcentre` = "cycle to boot
thinkcentre") pointed at hp-01.

## Why the seat did not catch it

It checked the switch state (on) and the ping (none) before cycling — but not the **draw**. A
socket carrying 24 W behind a box believed dark is a one-line contradiction, and it was available.
The `remote_power` note was trusted as a recipe; the plug sensor was never used as evidence.

## Collateral

- Both std zones down ~17:17–(hp-01's return): the three 2-replica CNPG volumes shared between
  thinkcentre and hp-01 offline; Alertmanager, Argo server/controller, ArgoCD dex, the agent-loop
  sensors evicted and stuck on volumes until a zone returned. Exactly the "not simultaneously"
  case the seat had ruled out an hour earlier for a planned hp-01 window.
- Alerts fired unsilenced (Alertmanager was on the dead node).

## Fixes

- **HA registry:** the twelve `tuyalocal_{thinkcentre,hp}_*` entity ids swapped (through a temp
  id), so names match sockets. `homeassistant/ha-config/packages/power.yaml` and
  `docs/power-measurements.md` carry the correction; `plug_*` history 08-18→09-09 belongs to the
  other box.
- **`scripts/node-maintenance.sh power <node> [status|cycle]`:** reads the box's plug draw from
  `machines.yaml`'s `plug:` and **refuses to cycle a socket that is carrying load** (FORCE=1
  overrides). `up` prints the draw before sending WoL.
- `machines.yaml` remote-power notes corrected (hp-01: a plug cycle ends at the power button).

## Probe lesson

Before any remote power action, read the **measurement**, not the label: a plug's draw is the
box's own testimony. And a contradiction from the operator ("it never lost power") is a stop
signal, not a discrepancy to explain away — the history read that settled it took one query.
