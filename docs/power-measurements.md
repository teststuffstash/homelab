# Power measurements

_Part of the [homelab docs](README.md). Structured inventory + generated tables:
[`../machines/`](../machines/README.md). Why the laptops are the compute tier: [`adr.md`](adr.md) ADR-044._

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

## Results — 2026-06-05 (stress-ng `matrixprod`)

The full structured inventory + regenerated tables live in
[`../machines/`](../machines/README.md) (source: `machines/machines.yaml`). Headline:

| Node | Hardware | Cores | Idle (W) | Load (W) | 1-core (bogo/s) | Multi (bogo/s) | **Perf/W** |
|---|---|---|---|---|---|---|---|
| `thinkcentre` | ThinkCentre Edge (desktop) | 2 | 27.9 | 54.5 | 1200.4 | 2231.7 | **40.9** |
| `wk-metal-01` | ThinkPad X240 (laptop) | 4 | 9.1 | 28.8 | 1182.1 | 1932.2 | **67.1** |

**The laptop is ~64% more power-efficient** (67 vs 41 bogo-ops/s per watt) and idles ~3× lower
(9 W vs 28 W). Per-core throughput is basically tied (1200 vs 1182), so the win is purely power:
mobile silicon + a ~29 W power cap vs the desktop's ~54 W. The desktop has higher *absolute*
throughput (2232 vs 1932) but pays far more watts for it.

Notes:
- The X240's AC draw is battery-buffered + power-capped (held a flat ~29 W), so that's its wall
  draw at full load with a charged battery.
- **Plug identification (bonus):** stressing the X240 made `laptop3` jump while `laptop4` stayed
  flat → `laptop3` = X240 (wk-metal-01), `laptop4` = X250 (wk-metal-02).
- Not measured: `hp-01` (no smart plug); `pve` / `opnsense` (didn't want to stress the
  hypervisor / router) — idle draws from the dashboard are ~127 W / ~57 W.
