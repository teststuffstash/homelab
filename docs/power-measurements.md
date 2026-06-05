# Power measurements

Max-power (stress) measurements of homelab nodes, taken at the wall via the Tuya smart plugs
(`sensor.plug_<box>_power`, see `homeassistant/ha-config/packages/power.yaml`) while all CPU cores
are maxed. Reproducible.

## Method

Talos nodes have no shell, so "prime95" is a **stress-ng pod pinned to the node** (`nodeName`,
tolerating all taints). Cordon the node first (laptops: full `drain` — they're the ephemeral tier
and hold no Longhorn data; storage nodes get cordon-only to avoid disrupting replicas).

```bash
# pinned all-core stressor (nodeName bypasses scheduler, so cordon/taints don't block it)
kubectl run powertest --restart=Never --image=colinianking/stress-ng \
  --overrides='{"spec":{"nodeName":"<node>","tolerations":[{"operator":"Exists"}]}}' \
  -- --cpu 0 --cpu-method all --timeout 220s --metrics-brief
```

Poll the node's plug power for ~3 min (`homeassistant_sensor_power_w{entity="sensor.plug_<box>_power"}`
or the HA `/api/states`), record the peak, then `delete pod` + `uncordon`.

## Results — 2026-06-05

| Node | Hardware | CPUs | Idle (W) | Full-load (W) | CPU delta |
|---|---|---|---|---|---|
| `thinkcentre` | Lenovo ThinkCentre Edge (desktop) | 2 | 27.9 | **52.5** (~50 steady) | ~+25 W |
| `wk-metal-01` | ThinkPad **X240** (laptop) | 4 | 9.1 | **23.3** (flat) | ~+14 W |

Notes:
- The **X240's draw held a dead-flat 23.3 W** under sustained load — a laptop's AC draw is
  battery-buffered and regulated, so this is the wall draw at full load with a charged battery
  (a mobile low-TDP CPU → small delta). The desktop ThinkCentre scales more (~2× idle).
- **Plug identification (bonus):** stressing the X240 made **`laptop3`** jump (9→23 W) while
  `laptop4` stayed flat → **`laptop3` = X240 (wk-metal-01)**, **`laptop4` = X250 (wk-metal-02)**.
- Not measured: `hp-01` (no smart plug); `pve` / `opnsense` (didn't want to stress the
  hypervisor / router). Their idle draws (from the dashboard): pve ~127 W, opnsense ~57 W.
