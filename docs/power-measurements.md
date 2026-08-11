# Power measurements

_Part of the [homelab docs](README.md). Structured inventory + generated tables:
[`../machines/`](../machines/README.md). Why the laptops are the compute tier: [`adr.md`](adr.md) ADR-044._

Max-power (stress) measurements of homelab nodes, taken at the wall via the Tuya smart plugs
(`sensor.plug_<box>_power`, see `homeassistant/ha-config/packages/power.yaml`) while all CPU cores
are maxed. Reproducible.

> ✅ **RESOLVED 2026-08-07 — the plugs are back on LOCAL polling** (`tuya_local`, FU-038 archived;
> the cutover + verification is below at §tuya_local). Kept for the record of the outage: Every Tuya entity
> froze between 2026-07-29 and 2026-08-01 — cloud-side `API_QPS_LIMIT_OR_DEGRADE`, so
> `tuya_sharing`'s MQTT channel never connects. **The entities still report `available=1` and serve
> their last value**, which is why nine days passed unnoticed and why a "measurement" taken today
> returns a plausible constant. Reloading the config entry republishes the cached value once
> (`last_updated` moves, the number does not) — not a fix. `HomeAssistantPowerSensorStale`
> (`argocd/resources/homeassistant-alerts/`) now catches this. Existing results below were taken
> while the plugs worked and remain valid; NEW wall measurements are blocked until Tuya is
> restored or the plugs move to local control.

### Restoring them: `tuya-local` only — reflashing is ruled out

Three ways back: re-auth the cloud integration, `tuya-local` (LAN polling after a one-time
`local_key` extraction), or reflashing the plugs to ESPHome-LibreTiny/OpenBeken. **Only
`tuya-local` is eligible**, and the reason is not convenience.

This plug fleet is the **dev/test ground for the edge/appliance product's device tier** (product
thinking lives in the private business repo — `CONTEXT.md` §2). That device strategy is built on a
*one-time app step and no per-device flashing*, because per-device flashing does not survive
contact with a non-technical household. Reflashing the lab's plugs would leave the lab testing a
path the product will never ship — the test bed would stop testing the thing under test. So
firmware-as-code stays an optional per-device upgrade elsewhere and is **excluded here by design**,
not by effort.

What the HA config entry tells us about the job (read from `.storage/core.config_entries`):

- **One `tuya` config entry, one user code** ⇒ all 7 devices sit in a **single Tuya account**, so
  one IoT-project link yields every `local_key` in one pass. Region: EU (`apigw.tuyaeu.com`),
  added 2026-06-04, `tuya_sharing` (user-code flow).
- HA does **not** record which phone app onboarded them — the user code is issued per *account*,
  and Tuya Smart / Smart Life / OEM white-labels (Nous Smart) share one account backend. To
  identify it, compare the stored `user_code` against the code each app shows under Me/Settings.
- Two hardware families, which is why `power.yaml` carries a `/10` correction for only some:
  **`Smart Socket A1`** (`m6ei1t46nqn0p0p9`) = Konditsioneer + Aquarium, the "old plugs" needing
  the correction, and Nous-A1-class hardware; **`Smart plug`** (`9y0qx7npuny0pnwt`) = the four
  node plugs. Plus a `Temp-5` sensor.

**Restoring the cloud is not as simple as it looks** (2026-08-07, in this order): reloading the
config entry republishes the cached values ONCE — `last_updated` moves, the number does not — and
the operator re-logging into the Tuya phone app refreshes the *account* but not HA's own stored
session, so a reload after it still failed. It needs a full **re-auth** (remove and re-add the
entry with a fresh user code). This also revises the earlier guess that FU-038's 2026-07-28
`tinytuya wizard` run triggered the QPS state: an expired session that kept retrying fits the
evidence better. Re-run key extraction sparingly anyway.

⚠ Which app: the operator re-authenticated via the **Tuya** app (not Nous Smart), which settles the
open question — the account backing all seven devices is the Tuya-app account.

**Extraction done 2026-08-07.** All 7 devices' `device_id` + `local_key` + LAN IP + protocol
version live in the KeePass wallet as `tuya-local` / attachment `devices.json`, materialized to
`~/.claude/tuya/devices.json` by `scripts/wallet-files.sh`. That file is everything local control
needs — **no Tuya account and no IoT project at runtime**.

Two things the cloud could NOT tell us, both resolved locally:

- **LAN IPs.** The cloud reports every device at the site's WAN address. The two NOUS A1 sockets
  and the temp sensor answer UDP discovery (6666/6667); the four `9y0qx7npuny0pnwt` plugs **never
  broadcast**, even over 150 s. They were found by scanning TCP **6668** and then identified by
  handshaking each candidate IP with each key — each match cross-checked against that device's HA
  power reading (e.g. `.215` returned 124.6 W, exactly `sensor.plug_pve_power`). Pin all seven as
  DHCP reservations; there is no reliable rediscovery path for the quiet four.
- **Protocol versions**, which tuya-local needs: the four plugs are **3.5**, the NOUS A1 pair
  **3.3**, the temp sensor **3.4**.

⚠ `local_key` **rotates on re-pair or factory reset**. A device that suddenly stops responding
locally needs re-extraction via the IoT project — not debugging. That, plus the trial project's
expiry, is the standing fragility of this path.

**Cut over to LAN polling 2026-08-07.** `tuya_local` 2026.7.2 (pinned, installed by
`scripts/ha-tuya-local.sh`) with one config entry per device from the wallet material
(`scripts/ha-tuya-local-devices.sh`, idempotent). Auto-detected profiles: `smartplugv2_energy`
for the four plugs, `smartplugv1` for the NOUS A1 pair, and a thermostat profile for Gaas —
⚠ that last one is a guess by the integration and worth eyeballing against the real device.

Verified against the cloud entities before switching the templates over — every device matched
exactly (pve 124.6, opnsense 56.4, laptop3 11.9, laptop4 8.0, aquarium 35.8, konditsioneer 32.9),
**including the scaling**: raw cloud 358.0 → tuya_local 35.8, so the old `/10` correction is
applied by the device profile and was deleted rather than ported. Re-adding it would make those
two readings ten times too small.

`sensor.tuyalocal_*` is excluded from the Prometheus scrape alongside the old cloud raws — it
pushes every few **seconds** where the cloud reported ~25×/day, so leaving it in would multiply
both cardinality and churn for series that duplicate `plug_*` exactly. The public
`sensor.plug_<box>_*` names did not change; only what feeds them did, which is the whole reason
that indirection exists.

## The pve GPU: −6 °C on the NVMe for nothing (2026-08-07)

pve carries a **GeForce 9600 GT** (G94, 2008) that cannot be removed — the X99-P4 board refuses to
POST without it — and it sits between the CPU cooler and the M.2, so its heat rises straight onto
the NVMe. It ran with **`driver=none`**, which is the worst case: no driver means no power
management at all, so it idled at power-on clocks doing nothing but holding a console.

Wall watts were unmeasurable (plugs dead, above), so the experiment used NVMe temperature as the
proxy and **CPU package power via `intel-rapl` as a control** — the GPU is not in that domain, so a
flat CPU figure rules out load as the explanation.

Run as **A/B/A** — D0, then vfio D3hot, then unbound back to D0 — because a one-way drop could
just be the drive still cooling from earlier storage IO. The reversal is what settles it.

| metric | A: `D0` | B: `vfio-pci` `D3hot` | A2: back to `D0` |
|---|---|---|---|
| NVMe sensor 1 (controller) | 75.8 °C (n=20, 71–78) | **69.8 °C** (n=26, **69–72**) | returns to a 75 °C plateau |
| NVMe composite | 54.4 °C | 48.8 °C | 50.6 °C (mean incl. warm-up) |
| NVMe sensor 2 | 47.2 °C | 42.8 °C | 44.0 °C |
| CPU package (control) | 22.6 W | 22.1 W | 22.1 W |

A2's sensor-1 trace: `69 69 69 69 73 71 70 69 69 69 73 75 75 75 75 75 75 75 73 71 70 70 70 70` —
about five minutes of thermal lag, then a plateau at **75 °C, reproducing A**. Its *mean* (71.6)
understates the effect because it averages the warm-up ramp in. Note the distributions rather than
just the means: **D0 is wide and noisy (70–78 °C), D3hot is tight (69–72 °C)** — so call it ~5–6 °C,
not a precise 6.0.

**What did NOT work:** `power/control = auto`. `runtime_status` flips to `suspended` and it looks
like a win, but `power_state` stays `D0` and PMCSR reads `0000` — with no driver bound the PCI core
marks the device suspended without transitioning the D-state. **Always confirm with PMCSR, not
`runtime_status`.**

**What worked:** binding the card to `vfio-pci`, which actively idles it into D3hot
(`PMCSR=0003`). Applied at runtime and **deliberately NOT persisted** — pve is not
config-managed, so a reboot restores the stock state rather than leaving undocumented drift:

```bash
modprobe vfio-pci
echo vfio-pci > /sys/bus/pci/devices/0000:04:00.0/driver_override
echo 0000:04:00.0 > /sys/bus/pci/drivers/vfio-pci/bind
cat /sys/bus/pci/devices/0000:04:00.0/power_state   # want: D3hot
setpci -s 04:00.0 CAP_PM+4.w                        # want: 0003
```

Safe on this box: the card is `boot_vga=1` but nothing was using it (no `/proc/fb` entry, no
driver), firmware still drives POST, and all four VMs kept running throughout. The residual-cooling
caveat that a one-way test would have left open is closed by the A/B/A above: the temperature
tracks the GPU's D-state, not the clock.

### And the watts: ~7 W, not the "tens" I guessed

Measured once the plugs came back, as a second A/B/A at 5-second resolution (48 samples):

| leg | state | n | mean | median | range |
|---|---|---|---|---|---|
| 1 | `D3hot` | 16 | 127.81 W | 126.70 | 124.4–136.1 |
| 2 | **`D0`** | 16 | **134.94 W** | 133.45 | 132.0–146.1 |
| 3 | `D3hot` | 16 | 130.28 W | 131.55 | 126.2–134.8 |

**≈7 W**, from the two adjacent legs. Leg 3 is knowingly contaminated: the cluster got busier
during it (load 1-min 3.04 vs 15-min 2.09, CPU package 25.7 W vs ~22 W), which lifts it toward D0
levels and drags the naive 3-leg mean down to 5.9 W. Treat the answer as **6–7 W** — the signal is
genuinely small next to pve's own ±5 W of load variation, so a tighter figure would be false
precision.

Worth recording that the **prediction was wrong**: "tens of watts" was the expectation from a
9600 GT's idle spec, and the truth is roughly a quarter of that. With `driver=none` the card was
evidently not at full clocks after all. The thermal win (−5–6 °C on the NVMe) is the better
justification for keeping it bound; ~7 W ≈ €8/year is a rounding error by comparison.

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

> ⚠ **Reporting cadence is per-MODEL, and the newer plugs barely report at all when idle.**
> Learned the hard way 2026-08-07: 18 consecutive "samples" of a GPU A/B were one frozen value,
> because the plug had last reported 12 minutes earlier. Measured cadence with every device open
> in the app:
>
> | model | devices | cadence |
> |---|---|---|
> | `Smart Socket A1` (old) | aquarium, konditsioneer | **3–9 s, continuous** |
> | `Smart plug` (new) | pve, opnsense, laptop3, laptop4 | **~3–5 min**, deadbanded on change |
>
> The new plugs burst to **5-second** updates only while *that device's detail page* is open in
> the phone app — opening the app's device LIST is not enough. A stress test still measures fine
> unattended (a ~30 W jump crosses the report-on-change threshold), but any **small** delta — a
> few watts — is invisible unless that device's page is held open for the whole run. **Verify you
> are seeing DISTINCT values before trusting a mean.** (Local polling — shipped 2026-08-07 —
> samples on our schedule, not the vendor's.)

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
